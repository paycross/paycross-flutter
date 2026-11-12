import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';

import 'environment.dart';
import 'presets.dart';

const String demoScheme = 'paycross-flutter-demo';

const String sheetSurface = 'sheet';

sealed class DeepLink {
  const DeepLink();
}

final class DeepLinkRun extends DeepLink {
  const DeepLinkRun(this.preset);

  final Preset preset;
}

final class DeepLinkIgnored extends DeepLink {
  const DeepLinkIgnored();
}

final class DeepLinkRejected extends DeepLink {
  const DeepLinkRejected(this.reason);

  final String reason;
}

String presetSlug(String name) => name
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
    .replaceAll(RegExp(r'^-+|-+$'), '');

DeepLink parseDeepLink(
  Uri uri, {
  DemoEnvironment environment = DemoEnvironment.test,
}) {
  if (uri.scheme != demoScheme || uri.host != 'run') {
    return const DeepLinkIgnored();
  }
  if (environment == DemoEnvironment.live) {
    return const DeepLinkRejected('Live mode — links are disabled');
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
  final slug = presetSlug(name);
  for (final preset in demoPresets) {
    if (presetSlug(preset.name) == slug) return DeepLinkRun(preset);
  }
  return DeepLinkRejected('No preset is called "$name".');
}

class DeepLinkListener extends StatefulWidget {
  const DeepLinkListener({
    super.key,
    required this.onRun,
    required this.child,
    this.links,
  });

  final void Function(Preset preset) onRun;
  final Widget child;

  final Stream<Uri>? links;

  @override
  State<DeepLinkListener> createState() => _DeepLinkListenerState();
}

class _DeepLinkListenerState extends State<DeepLinkListener> {
  StreamSubscription<Uri>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = (widget.links ?? AppLinks().uriLinkStream).listen(
      _handle,
      onError: _handleError,
    );
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _handle(Uri uri) {
    final environment =
        LiveModeScope.readOf(context)?.environment ?? DemoEnvironment.test;
    switch (parseDeepLink(uri, environment: environment)) {
      case DeepLinkRun(:final preset):
        widget.onRun(preset);
      case DeepLinkIgnored():
        break;
      case DeepLinkRejected(:final reason):
        _say(reason);
    }
  }

  void _handleError(Object error) =>
      _say('Could not read the link: ${error.runtimeType}');

  void _say(String message) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
