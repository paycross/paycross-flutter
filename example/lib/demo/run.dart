import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:paycross_flutter/paycross_flutter.dart';

import '../e2e_mode.dart';
import 'environment.dart';
import 'history.dart';
import 'minter.dart';
import 'present.dart';
import 'presets.dart';
import 'version_panel.dart';

/// Mint, pay, show what happened.
///
/// Every platform edge is a constructor argument: the mint, the payment, the
/// history and the version read. That is what lets the whole screen be
/// tested with no device and no network.
class RunScreen extends StatefulWidget {
  const RunScreen({
    super.key,
    required this.preset,
    required this.body,
    required this.mintSession,
    this.present = PayCross.presentPayment,
    this.history = const HistoryStore(),
    this.readVersions = platformVersions,
    this.e2e = kE2e,
    this.live = false,
  });

  final Preset preset;

  /// What is actually minted -- the preset's body, or the editor's edit of it.
  final String body;

  /// Mints [body]. Takes it as an argument rather than closing over it, so
  /// the screen and its minter cannot disagree about what is being sent.
  final Future<MintedSession> Function(String body) mintSession;
  final Future<PayCrossResult> Function(String sessionToken) present;
  final HistoryStore history;
  final Future<DemoVersions> Function() readVersions;
  final bool e2e;

  /// Whether this run charges a real card.
  ///
  /// Passed in at push time rather than read from the environment scope, and
  /// that is deliberate: a run that started in Live stays a Live run in what
  /// it shows and what it writes to History, even if somebody switches back
  /// to Test while the sheet is open.
  final bool live;

  @override
  State<RunScreen> createState() => _RunScreenState();
}

class _RunScreenState extends State<RunScreen> {
  String _stage = 'Minting a session…';
  String? _contractLabel;
  String? _human;
  String? _sessionId;
  String? _transactionId;

  /// Whether the sheet came back with a refusal.
  ///
  /// Read only by the refund block, and only to stop it claiming a refund is
  /// owed. A decline carries a transaction id, so it satisfies that block's
  /// guard as readily as an approval does -- and it is the one outcome that
  /// is not unknown.
  bool _refused = false;
  HistoryEntry? _entry;

  @override
  void initState() {
    super.initState();
    _go();
  }

  Future<void> _go() async {
    final MintedSession minted;
    try {
      minted = await widget.mintSession(widget.body);
    } on MinterError catch (problem) {
      // MinterError never carries a credential; see minter.dart.
      if (mounted) {
        setState(() {
          _stage = 'Could not mint a session.';
          _human = problem.message;
        });
      }
      return;
    }

    if (!mounted) return;
    setState(() {
      _stage = 'Waiting for the payment sheet…';
      _sessionId = minted.id;
    });

    final run = await presentSession(widget.present, minted.token);

    if (!mounted) return;
    // The outcome, the moment it is known and before anything else is asked
    // for. What follows is bookkeeping -- a version read and a store write --
    // and a payment that may have taken money must not wait on either, nor be
    // lost to one that never answers.
    setState(() {
      _stage = 'Done.';
      _contractLabel = run.label;
      _human = run.human;
      _transactionId = run.transactionId;
      _refused = run.result is PayCrossFailure;
    });

    final entry = await recordRun(
      history: widget.history,
      readVersions: widget.readVersions,
      scenario: widget.preset.name,
      sessionId: minted.id,
      transactionId: run.transactionId,
      outcome: run.human,
      live: widget.live,
    );

    if (!mounted) return;
    // Only now: the bug report quotes the versions, so the button appears
    // once there is a complete entry behind it.
    setState(() => _entry = entry);
  }

  @override
  Widget build(BuildContext context) {
    final label = _contractLabel;
    final human = _human;
    return Scaffold(
      appBar: AppBar(title: Text(widget.preset.name)),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // Under the automation define only, and FIRST. The matrix runner's
          // `label_from_tree` returns the first node in document order whose
          // text starts with a contract prefix, so this has to precede
          // anything else that could match. It is a widget-test finder, not
          // a runner anchor: the runner matches by prefix, and this key is
          // invisible to uiautomator and WebDriverAgent alike.
          if (widget.e2e && label != null)
            Text(label, key: const ValueKey('e2eLabel')),
          Text(_stage, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          if (human != null)
            // A live region, like Settings' message line: the outcome lands
            // in place and can land minutes after the tap, because a
            // challenge waits on the shopper's bank. Nothing moves focus and
            // there is nothing to navigate to, so without this a
            // screen-reader user is never told the payment finished.
            Semantics(
              key: const ValueKey('runOutcome'),
              liveRegion: true,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(human, style: const TextStyle(height: 1.4)),
                      const SizedBox(height: 12),
                      Text('Session ${_sessionId ?? '(none)'}'),
                      Text('Transaction ${_transactionId ?? '(none)'}'),
                      // Both conditions carry weight. This block lives inside
                      // the outcome card, which is built only once there is an
                      // outcome; and a mint that failed sets that outcome
                      // while leaving both ids null, which is a run that took
                      // no money and has nothing to refund.
                      if (widget.live &&
                          (_transactionId ?? _sessionId) != null) ...[
                        const SizedBox(height: 12),
                        Container(
                          key: const ValueKey('refundInstruction'),
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: liveRed,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                // Not suppressed on a refusal, and not left
                                // saying "refund this" either. A decline
                                // means nothing was captured, so there is
                                // nothing to refund and the red block would
                                // be pure noise on the commonest first
                                // result a real card gives. But "refused" is
                                // the SDK's word, not the ledger's -- an auth
                                // that took and a capture that failed reads
                                // the same from here -- so the id stays and
                                // so does the instruction to go and look.
                                _refused
                                    ? 'Refused, so nothing should have been '
                                          'captured. Check the back office by '
                                          'this id before you assume it.'
                                    : 'Refund this in the back office now.',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                // One of the two always exists, because the
                                // session is minted before the sheet opens. A
                                // transaction id is what a refund takes;
                                // without one the session id is what the back
                                // office can be searched by, and an unknown
                                // outcome is exactly when somebody needs to be
                                // able to find the money.
                                _transactionId != null
                                    ? 'Transaction $_transactionId'
                                    : 'No transaction id — search the back '
                                          'office by this session id.\n'
                                          'Session $_sessionId',
                                style: const TextStyle(color: Colors.white),
                              ),
                              const SizedBox(height: 8),
                              OutlinedButton.icon(
                                key: const ValueKey('copyRefundId'),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.white,
                                  side: const BorderSide(color: Colors.white),
                                ),
                                icon: const Icon(Icons.copy, size: 18),
                                label: const Text('Copy id'),
                                onPressed: () async {
                                  await Clipboard.setData(
                                    ClipboardData(
                                      text: _transactionId ?? _sessionId!,
                                    ),
                                  );
                                  if (!context.mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('Copied.')),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                      ],
                      if (_entry != null) ...[
                        const SizedBox(height: 8),
                        // The same block History copies, offered where the run
                        // just happened: a colleague reporting a problem should
                        // not have to navigate away to quote it.
                        OutlinedButton.icon(
                          key: const ValueKey('copyBugReport'),
                          icon: const Icon(Icons.copy, size: 18),
                          label: const Text('Copy bug report'),
                          onPressed: () async {
                            await Clipboard.setData(
                              ClipboardData(text: bugReport(_entry!)),
                            );
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Copied.')),
                            );
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          const SizedBox(height: 16),
          Text('Expected: ${widget.preset.expected}'),
          if (widget.preset.cardHint != null) ...[
            const SizedBox(height: 8),
            Text('Card: ${widget.preset.cardHint}'),
          ],
        ],
      ),
    );
  }
}
