import 'package:flutter/material.dart';
import 'package:paycross_flutter/paycross_flutter.dart';

import 'e2e_label.dart';
import 'e2e_mode.dart';

/// The E2E matrix runner's entry point: paste a token, press Pay, read the
/// outcome out of the accessibility tree.
///
/// Frozen. Its widget tree, its strings and the shape of its outcome node
/// are a contract every cell file in `tool/e2e/cells/` compares against, and
/// `test/automation_screen_test.dart` pins the tree the runner sees. It kept
/// the name `CheckoutScreen` and the title `PayCross Example` through the
/// rename to PayCross Demo for that reason.
class CheckoutScreen extends StatefulWidget {
  const CheckoutScreen({super.key, this.e2e = kE2e});

  /// Renders the contract label instead of the human-readable outcome.
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
      // Exhaustive: adding a result case makes this a compile error rather
      // than a silently unhandled outcome.
      describe = widget.e2e
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
      describe = widget.e2e
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
