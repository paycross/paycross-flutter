import 'package:flutter/material.dart';
import 'package:paycross_flutter/paycross_flutter.dart';

import 'automation_screen.dart';
import 'demo/home.dart';
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
/// cannot fail: no stored credentials are read, and the app goes straight to
/// the automation screen. An unguarded await here would take down all six D0
/// cells on both platforms, and the failure would look like an SDK hang.
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
  runApp(const ExampleApp());
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
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    // The automation build keeps the old title: it is the Android recents
    // label, and the frozen build should look to a runner exactly as it did
    // before. It reaches no accessibility tree either way.
    title: kE2e ? 'PayCross Example' : 'PayCross Demo',
    theme: ThemeData(colorSchemeSeed: Colors.indigo),
    darkTheme: ThemeData.dark(useMaterial3: true),
    home: kE2e ? const CheckoutScreen() : const HomeScreen(),
  );
}
