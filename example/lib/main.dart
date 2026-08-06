import 'package:flutter/material.dart';
import 'package:paycross_flutter/paycross_flutter.dart';

/// Runs a real payment against sandbox with no backend of your own.
///
/// Paste a session token your server minted and press Pay. That is the whole
/// integration: the SDK owns the card form, 3-D Secure and the polling.
void main() {
  PayCross.configure(environment: PayCrossEnvironment.sandbox);
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
      describe = switch (result) {
        PayCrossSuccess(:final transactionId, :final amount) =>
          'Paid ${amount.minorUnits} ${amount.currencyCode} — $transactionId',
        PayCrossFailure(:final recovery) when recovery.isRetryable =>
          'Declined, retryable — $recovery',
        PayCrossFailure(:final recovery) => 'Declined — $recovery',
        PayCrossCancelled() => 'Cancelled',
      };
    } on PayCrossIntegrationError catch (e) {
      describe = e.code == PayCrossErrorCode.resultUnknown
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
            SelectableText(_outcome!, style: const TextStyle(height: 1.4)),
          ],
        ],
      ),
    ),
  );
}
