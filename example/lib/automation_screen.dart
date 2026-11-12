import 'package:flutter/material.dart';
import 'package:paycross_flutter/paycross_flutter.dart';

import 'e2e_label.dart';
import 'e2e_mode.dart';

class CheckoutScreen extends StatefulWidget {
  const CheckoutScreen({super.key, this.e2e = kE2e});

  final bool e2e;

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
      describe = widget.e2e
          ? labelForResult(result)
          : switch (result) {
              PayCrossSuccess(:final transactionId, :final amount) =>
                'Paid ${amount.minorUnits} ${amount.currencyCode} — $transactionId',
              PayCrossFailure(:final recovery) when recovery.isRetryable =>
                'Declined, retryable — $recovery',
              PayCrossFailure(:final recovery) => 'Declined — $recovery',
              PayCrossPending(:final transactionId, :final reasonRaw) =>
                'Outcome unknown ($reasonRaw) — reconcile server-side'
                    '${transactionId == null ? '' : ': $transactionId'}',
              PayCrossCancelled() => 'Cancelled',
            };
    } on PayCrossIntegrationError catch (e) {
      describe = widget.e2e
          ? labelForError(e)
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
            Text(_outcome!, style: const TextStyle(height: 1.4)),
          ],
        ],
      ),
    ),
  );
}
