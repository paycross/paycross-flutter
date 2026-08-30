import 'package:flutter/material.dart';
import 'package:paycross_flutter/paycross_flutter.dart';

import 'automation_screen.dart';
import 'demo/home.dart';
import 'e2e_mode.dart';

/// Google Pay merchant id, passed straight to `PayCross.configure`.
///
/// Empty means "not supplied", which is the merchant-facing default and is
/// exactly what the app did before this define existed.
const String _googlePayMerchantId = String.fromEnvironment(
  'PAYCROSS_E2E_GOOGLE_PAY_MERCHANT_ID',
);

/// Runs a real payment against sandbox with no backend of your own.
///
/// Under `--dart-define=PAYCROSS_E2E=true` this awaits exactly one thing and
/// cannot fail, and the app goes straight to the automation screen. An
/// unguarded await here would take down all six D0 cells on both platforms,
/// and the failure would look like an SDK hang.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Awaited so a fast first tap on Pay cannot race the configure call.
  await PayCross.configure(
    environment: PayCrossEnvironment.sandbox,
    googlePayMerchantId: _googlePayMerchantId.isEmpty
        ? null
        : _googlePayMerchantId,
  );
  runApp(const ExampleApp());
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
