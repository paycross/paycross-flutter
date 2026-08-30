import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';

import 'presets.dart';

/// This app's own URL scheme.
///
/// Its own, and not `paycross-demo`, because the native Android demo
/// (`com.paycross.demo`) already owns that scheme with the hosts `run` and
/// `result`, and both apps live on the same colleagues' phones. Two
/// activities answering one VIEW intent gives a disambiguation chooser at
/// best and, once somebody has picked a default, the wrong app silently.
const String demoScheme = 'paycross-flutter-demo';

/// The only surface this app can present. Named in the link so the grammar
/// has somewhere to grow if a browser surface is ever added, and rejected
/// rather than ignored when it is anything else.
const String sheetSurface = 'sheet';

/// What a link turned out to be.
sealed class DeepLink {
  const DeepLink();
}

/// Run this scenario.
final class DeepLinkRun extends DeepLink {
  const DeepLinkRun(this.preset);

  final Preset preset;
}

/// Not addressed to this app. Say nothing.
final class DeepLinkIgnored extends DeepLink {
  const DeepLinkIgnored();
}

/// Ours, and wrong. Say what was wrong with it.
final class DeepLinkRejected extends DeepLink {
  const DeepLinkRejected(this.reason);

  final String reason;
}

/// `paycross-flutter-demo://run?preset=<name>&surface=sheet`
///
/// A link carries a preset's name and nothing else. It cannot carry a
/// credential, a token or a body: the run it starts reads the same secure
/// store a tile tap reads, so a link that leaked out of a shell history says
/// only which scenario somebody ran.
DeepLink parseDeepLink(Uri uri) {
  if (uri.scheme != demoScheme || uri.host != 'run') {
    return const DeepLinkIgnored();
  }

  final surface = uri.queryParameters['surface'] ?? sheetSurface;
  if (surface != sheetSurface) {
    return DeepLinkRejected(
      'This demo presents the native sheet only; "$surface" is not a '
      'surface it has.',
    );
  }

  final name = uri.queryParameters['preset'];
  if (name == null || name.isEmpty) {
    return const DeepLinkRejected('The link carries no preset= to run.');
  }

  for (final preset in demoPresets) {
    if (preset.name == name) return DeepLinkRun(preset);
  }
  // `customPreset` is deliberately not searched: it is the one entry on Home
  // that opens the editor rather than a run, because its body is whatever the
  // person typing decides. It falls through to here and is named back.
  return DeepLinkRejected('No preset is called "$name".');
}

/// Subscribes to incoming links for as long as its child is mounted.
///
/// `uriLinkStream` rather than `getInitialLink()`: the stream replays the
/// link that launched a cold start, and the one-shot getter races it.
///
/// Mounted only in an ordinary build. Under the automation define no
/// handler is registered at all, so the frozen build opens no subscription
/// and `main()` awaits exactly what it always did.
class DeepLinkListener extends StatefulWidget {
  const DeepLinkListener({
    super.key,
    required this.onRun,
    required this.child,
    this.links,
  });

  final void Function(Preset preset) onRun;
  final Widget child;

  /// Injected by tests. Null means the real platform stream.
  final Stream<Uri>? links;

  @override
  State<DeepLinkListener> createState() => _DeepLinkListenerState();
}

class _DeepLinkListenerState extends State<DeepLinkListener> {
  StreamSubscription<Uri>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = (widget.links ?? AppLinks().uriLinkStream).listen(_handle);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _handle(Uri uri) {
    switch (parseDeepLink(uri)) {
      case DeepLinkRun(:final preset):
        widget.onRun(preset);
      case DeepLinkIgnored():
        break;
      case DeepLinkRejected(:final reason):
        // Said on screen rather than only in a log: the person who typed the
        // link is holding the phone, and a link that quietly did nothing
        // reads as a broken build.
        final messenger = ScaffoldMessenger.maybeOf(context);
        messenger?.showSnackBar(SnackBar(content: Text(reason)));
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
