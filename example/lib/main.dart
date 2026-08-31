import 'package:flutter/material.dart';
import 'package:paycross_flutter/paycross_flutter.dart';

import 'automation_screen.dart';
import 'demo/deeplink.dart';
import 'demo/environment.dart';
import 'demo/home.dart';
import 'demo/minter.dart';
import 'demo/presets.dart';
import 'demo/secrets.dart';
import 'e2e_mode.dart';

/// Google Pay merchant id, passed straight to `PayCross.configure`.
///
/// Empty means "not supplied", which is the merchant-facing default and is
/// exactly what the app did before this define existed.
const String _googlePayMerchantId = String.fromEnvironment(
  'PAYCROSS_E2E_GOOGLE_PAY_MERCHANT_ID',
);

/// The secure store `main` reads the saved merchant id from.
///
/// A variable rather than a parameter: `main` is the entrypoint and cannot
/// take one, and the read has to happen inside the compile-time conditional
/// below rather than above it. `PayCross.debugHostApi` is the same shape for
/// the same reason -- a seam a test replaces, and nothing else touches.
@visibleForTesting
SecretStore mainSecretStore = const SecretStore();

/// Runs a real payment against sandbox with no backend of your own.
///
/// Under `--dart-define=PAYCROSS_E2E=true` this awaits exactly one thing and
/// cannot fail: no stored credentials are read, no deep-link subscription is
/// opened, and the app goes straight to the automation screen. An unguarded
/// await here would take down all six D0 cells on both platforms, and the
/// failure would look like an SDK hang.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Under the define this whole expression is the constant branch -- no
  // storage read, no extra await -- so the frozen build still awaits exactly
  // one thing and still cannot fail before runApp.
  final merchantId = kE2e
      ? (_googlePayMerchantId.isEmpty ? null : _googlePayMerchantId)
      : await _storedGooglePayMerchantId();
  // Awaited so a fast first tap on Pay cannot race the configure call.
  await PayCross.configure(
    environment: PayCrossEnvironment.sandbox,
    googlePayMerchantId: merchantId,
  );
  runApp(ExampleApp(googlePayMerchantId: merchantId));
}

/// The Google Pay merchant id a colleague saved in Settings, or null.
///
/// `PayCross.configure` is called once per launch, so this is read here and
/// nowhere else -- which is why Settings tells the reader that a change takes
/// effect next launch. Guarded twice over: `SecretStore.read` already answers
/// null on any failure, and this catches anything it could still throw,
/// because an exception here would kill the app before `runApp`.
Future<String?> _storedGooglePayMerchantId() async {
  try {
    return (await mainSecretStore.read())?.googlePayMerchantId;
  } catch (_) {
    return null;
  }
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key, this.googlePayMerchantId});

  /// What `configure` was given at launch, carried down so that returning
  /// from Live to Test restores it rather than clearing it.
  final String? googlePayMerchantId;

  @override
  Widget build(BuildContext context) => MaterialApp(
    // The automation build keeps the old title: it is the Android recents
    // label, and the frozen build should look to a runner exactly as it did
    // before. It reaches no accessibility tree either way.
    title: kE2e ? 'PayCross Example' : 'PayCross Demo',
    theme: ThemeData(colorSchemeSeed: Colors.indigo),
    darkTheme: ThemeData.dark(useMaterial3: true),
    // Wraps the Navigator, so every pushed route reads one environment and
    // sits under one banner. Null under the define: the frozen build has no
    // environment toggle in it at all, which is a stronger statement than
    // having one that is switched off.
    builder: kE2e
        ? null
        : (context, child) => LiveModeScope(
            googlePayMerchantId: googlePayMerchantId,
            child: child!,
          ),
    home: kE2e ? const CheckoutScreen() : const DemoHome(),
  );
}

/// Home, wrapped in the deep-link subscription.
///
/// Separate from [ExampleApp] so the subscription is opened under a
/// `Navigator` and a `ScaffoldMessenger` -- a rejected link has somewhere to
/// report itself, and a run link has somewhere to push to.
///
/// Reached only from the demo branch above, so the automation build registers
/// no deep-link handler at all rather than one that is switched off.
class DemoHome extends StatefulWidget {
  const DemoHome({
    super.key,
    this.links,
    this.store = const SecretStore(),
    this.mintWith = mintWithCredentials,
  });

  /// Injected by tests. Null means the real platform stream.
  final Stream<Uri>? links;

  /// The one store both entrances to a run read, so a link and a tile cannot
  /// disagree about whether this build is configured.
  ///
  /// A constructor argument rather than a `main`-level variable like
  /// [mainSecretStore]: that one exists only because `main` is an entrypoint
  /// and cannot take parameters. This is a widget, and every other widget in
  /// this app reaches its platform edges the same way.
  final SecretStore store;
  final Future<MintedSession> Function(Credentials, String body) mintWith;

  @override
  State<DemoHome> createState() => _DemoHomeState();
}

class _DemoHomeState extends State<DemoHome> {
  /// True from a link's arrival until the run it started has been left.
  ///
  /// Home's own tiles go dead while a run is being set up, but a tile cannot
  /// be tapped from under a pushed Run screen and a link can arrive at any
  /// moment. Without this a second `am start` while the first run is still
  /// open mints a second live session and stacks a second Run screen on it.
  ///
  /// Deliberately not `setState`: nothing renders this, and a link that
  /// rebuilt the tree under an open run would be a worse bug than this one.
  bool _busy = false;

  /// Says something on the channel a malformed link already uses.
  ///
  /// Silence reads as a broken build: the phone is in somebody's hand and the
  /// link they just fired did nothing they can see. What is said names the
  /// way out, or a type -- never a platform message, which can carry the URL
  /// that failed.
  void _say(BuildContext context, String message) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  /// The one refusal with a way out to name: something is over Home.
  void _refuse(BuildContext context) =>
      _say(context, 'Link ignored — close the open screen first.');

  Future<void> _run(BuildContext context, Preset preset) async {
    if (_busy) {
      _refuse(context);
      return;
    }
    // Anything pushed over Home -- a Run screen a tile started, Settings, the
    // editor -- makes Home no longer the current route; `_busy` only knows
    // about runs this widget started.
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) {
      _refuse(context);
      return;
    }
    _busy = true;
    try {
      await runPreset(
        context,
        preset,
        preset.body,
        store: widget.store,
        mintWith: widget.mintWith,
      );
    } catch (problem) {
      // A link is fire-and-forget -- `onRun` returns void -- so anything that
      // escapes here has no owner and lands as an async error with no screen
      // attached. Only the type, for the reason `_say` gives.
      if (context.mounted) {
        _say(context, 'Could not start the run: ${problem.runtimeType}');
      }
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) => DeepLinkListener(
    links: widget.links,
    onRun: (preset) => _run(context, preset),
    child: HomeScreen(store: widget.store, mintWith: widget.mintWith),
  );
}
