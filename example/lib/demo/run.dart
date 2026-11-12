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

  final String body;

  final Future<MintedSession> Function(String body) mintSession;
  final Future<PayCrossResult> Function(String sessionToken) present;
  final HistoryStore history;
  final Future<DemoVersions> Function() readVersions;
  final bool e2e;

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
          if (widget.e2e && label != null)
            Text(label, key: const ValueKey('e2eLabel')),
          Text(_stage, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          if (human != null)
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
