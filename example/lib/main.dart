import 'package:flutter/material.dart';
import 'package:paycross_flutter/paycross_flutter.dart';

import 'automation_screen.dart';
import 'demo/appearance_store.dart';
import 'demo/deeplink.dart';
import 'demo/environment.dart';
import 'demo/home.dart';
import 'demo/language.dart';
import 'demo/minter.dart';
import 'demo/presets.dart';
import 'demo/secrets.dart';
import 'demo/wallets.dart';
import 'e2e_mode.dart';

const String _googlePayMerchantId = String.fromEnvironment(
  'PAYCROSS_E2E_GOOGLE_PAY_MERCHANT_ID',
);

const String _locale = String.fromEnvironment('PAYCROSS_LOCALE');

const String _appearance = String.fromEnvironment('PAYCROSS_APPEARANCE');

@visibleForTesting
SecretStore mainSecretStore = const SecretStore();

@visibleForTesting
LanguageStore mainLanguageStore = const LanguageStore();

@visibleForTesting
AppearanceStore mainAppearanceStore = const AppearanceStore();

const Duration _launchReadTimeout = Duration(seconds: 5);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final merchantId = kE2e
      ? (_googlePayMerchantId.isEmpty ? null : _googlePayMerchantId)
      : await _storedGooglePayMerchantId();
  final locale = kE2e
      ? (_locale.isEmpty ? null : _locale)
      : await _storedLocale();
  final appearance = kE2e
      ? DemoAppearance.fromJson(_appearance).toAppearance()
      : await _storedAppearance();
  await PayCross.configure(
    environment: PayCrossEnvironment.sandbox,
    googlePayMerchantId: merchantId,
    applePayMerchantId: testApplePayMerchantId,
    locale: locale,
    appearance: appearance,
  );
  runApp(
    ExampleApp(
      googlePayMerchantId: merchantId,
      applePayMerchantId: testApplePayMerchantId,
      locale: locale,
      appearance: appearance,
    ),
  );
}

Future<String?> _storedGooglePayMerchantId() async {
  try {
    return (await mainSecretStore.read().timeout(
      _launchReadTimeout,
    ))?.googlePayMerchantId;
  } catch (_) {
    return null;
  }
}

Future<String?> _storedLocale() async =>
    (await mainLanguageStore.read().timeout(
      _launchReadTimeout,
      onTimeout: () => DemoLanguage.system,
    )).tag;

Future<PayCrossAppearance?> _storedAppearance() async =>
    (await mainAppearanceStore.read().timeout(
      _launchReadTimeout,
      onTimeout: () => DemoAppearance.none,
    )).toAppearance();

class ExampleApp extends StatelessWidget {
  const ExampleApp({
    super.key,
    this.googlePayMerchantId,
    this.applePayMerchantId,
    this.locale,
    this.appearance,
  });

  final String? googlePayMerchantId;

  final String? applePayMerchantId;

  final String? locale;

  final PayCrossAppearance? appearance;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: kE2e ? 'PayCross Example' : 'PayCross Demo',
    theme: ThemeData(colorSchemeSeed: Colors.indigo),
    darkTheme: ThemeData.dark(useMaterial3: true),
    builder: kE2e
        ? null
        : (context, child) => LiveModeScope(
            googlePayMerchantId: googlePayMerchantId,
            applePayMerchantId: applePayMerchantId,
            locale: locale,
            appearance: appearance,
            child: child!,
          ),
    home: kE2e ? const CheckoutScreen() : const DemoHome(),
  );
}

class DemoHome extends StatefulWidget {
  const DemoHome({
    super.key,
    this.links,
    this.store = const SecretStore(),
    this.mintWith = mintWithCredentials,
  });

  final Stream<Uri>? links;

  final SecretStore store;
  final Future<MintedSession> Function(Credentials, String body) mintWith;

  @override
  State<DemoHome> createState() => _DemoHomeState();
}

class _DemoHomeState extends State<DemoHome> {
  bool _busy = false;

  void _say(BuildContext context, String message) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  void _refuse(BuildContext context) =>
      _say(context, 'Link ignored — close the open screen first.');

  Future<void> _run(BuildContext context, Preset preset) async {
    if (LiveModeScope.readOf(context)?.isLive ?? false) {
      _say(context, 'Live mode — links are disabled');
      return;
    }
    if (_busy) {
      _refuse(context);
      return;
    }
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
