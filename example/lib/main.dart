import 'package:flutter/material.dart';
import 'package:paycross_flutter/paycross_flutter.dart';

import 'e2e_label.dart';

/// True when built with `--dart-define=PAYCROSS_E2E=true`.
///
/// Off by default and invisible to merchants: it swaps the human-readable
/// outcome line for the frozen contract label the matrix runner reads out of
/// the accessibility tree. Nothing else about the app changes.
const bool _e2e = bool.fromEnvironment('PAYCROSS_E2E');

/// Google Pay merchant id, passed straight to `PayCross.configure`.
///
/// Empty means "not supplied", which is the merchant-facing default and is
/// exactly what the app did before this define existed.
const String _googlePayMerchantId = String.fromEnvironment(
  'PAYCROSS_E2E_GOOGLE_PAY_MERCHANT_ID',
);

/// Runs a real payment against sandbox with no backend of your own.
///
/// Paste a session token your server minted and press Pay. That is the whole
/// integration: the SDK owns the card form, 3-D Secure and the polling.
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
    title: 'PayCross Example',
    theme: ThemeData(colorSchemeSeed: Colors.indigo),
    darkTheme: ThemeData.dark(useMaterial3: true),
    home: const CheckoutScreen(),
  );
}

class CheckoutScreen extends StatefulWidget {
  const CheckoutScreen({super.key});

  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  final _token = TextEditingController();
  String? _outcome;
  bool _busy = false;

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  Future<void> _pay() async {
    setState(() {
      _busy = true;
      _outcome = null;
    });

    String describe;
    try {
      final result = await PayCross.presentPayment(_token.text.trim());
      // Exhaustive: adding a result case makes this a compile error rather
      // than a silently unhandled outcome.
      describe = _e2e
          ? labelForResult(result)
          : switch (result) {
              PayCrossSuccess(:final transactionId, :final amount) =>
                'Paid ${amount.minorUnits} ${amount.currencyCode} — $transactionId',
              PayCrossFailure(:final recovery) when recovery.isRetryable =>
                'Declined, retryable — $recovery',
              PayCrossFailure(:final recovery) => 'Declined — $recovery',
              PayCrossCancelled() => 'Cancelled',
            };
    } on PayCrossIntegrationError catch (e) {
      describe = _e2e
          ? labelForError(e)
          : e.code == PayCrossErrorCode.resultUnknown
          // Distinct from a failure on purpose: the payment may have gone
          // through, so the merchant reconciles rather than re-charging.
          ? 'Outcome unknown — reconcile server-side. ${e.message}'
          : 'Integration error (${e.code.name}) — ${e.message}';
    }

    if (!mounted) return;
    setState(() {
      _busy = false;
      _outcome = describe;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('PayCross Example')),
    body: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Paste a sandbox session token minted by your server.'),
          const SizedBox(height: 12),
          TextField(
            controller: _token,
            minLines: 3,
            maxLines: 5,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'Session token',
              border: OutlineInputBorder(),
              hintText: 'eyJhbGciOi…',
            ),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy ? null : _pay,
            child: _busy
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Pay'),
          ),
          if (_outcome != null) ...[
            const SizedBox(height: 24),
            // Plain Text, and deliberately unwrapped. Verified against a
            // live simulator: SelectableText produces no node in the iOS
            // accessibility tree at all, and wrapping either widget in
            // Semantics suppressed it too -- only a bare Text surfaced. The
            // payment outcome is the one string here that must never be
            // silent, so it trades selection for being readable at all.
            // The E2E matrix runner reads this same node, so the shape of
            // this widget is part of a frozen contract -- see e2e_label.dart.
            Text(_outcome!, style: const TextStyle(height: 1.4)),
          ],
        ],
      ),
    ),
  );
}
