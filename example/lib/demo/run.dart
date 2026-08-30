import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:paycross_flutter/paycross_flutter.dart';

import '../e2e_label.dart';
import '../e2e_mode.dart';
import 'history.dart';
import 'minter.dart';
import 'outcome.dart';
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
  });

  final Preset preset;

  /// What is actually minted -- the preset's body, or the editor's edit of it.
  final String body;
  final Future<MintedSession> Function() mintSession;
  final Future<PayCrossResult> Function(String sessionToken) present;
  final HistoryStore history;
  final Future<DemoVersions> Function() readVersions;
  final bool e2e;

  @override
  State<RunScreen> createState() => _RunScreenState();
}

class _RunScreenState extends State<RunScreen> {
  String _stage = 'Minting a session…';
  String? _contractLabel;
  String? _human;
  String? _sessionId;
  String? _transactionId;
  HistoryEntry? _entry;

  @override
  void initState() {
    super.initState();
    _go();
  }

  Future<void> _go() async {
    final MintedSession minted;
    try {
      minted = await widget.mintSession();
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

    String? label;
    String human;
    String? transactionId;
    try {
      final paid = await widget.present(minted.token);
      label = labelForResult(paid);
      human = humanOutcome(paid);
      transactionId = switch (paid) {
        PayCrossSuccess(:final transactionId) => transactionId,
        PayCrossFailure(:final transactionId) => transactionId,
        PayCrossCancelled() => null,
      };
    } on PayCrossIntegrationError catch (problem) {
      label = labelForError(problem);
      human = humanError(problem);
    }

    final versions = await _versionsOrUnknown();
    final entry = HistoryEntry(
      at: DateTime.now(),
      presetName: widget.preset.name,
      sessionId: minted.id,
      transactionId: transactionId,
      outcome: human,
      demoVersion: versions.demo,
      pluginVersion: versions.plugin,
      nativeSdkVersion: versions.nativeSdk,
    );
    await _remember(entry);

    if (!mounted) return;
    setState(() {
      _stage = 'Done.';
      _contractLabel = label;
      _human = human;
      _transactionId = transactionId;
      _entry = entry;
    });
  }

  /// Writes the run to History, and never lets that failure lose the outcome.
  ///
  /// A payment has already happened by the time this runs, and it may have
  /// taken money. A store that cannot be written costs a missing row; letting
  /// it throw would cost the screen, which would sit on "Waiting for the
  /// payment sheet…" with no way to tell a hang from a completed charge.
  Future<void> _remember(HistoryEntry entry) async {
    try {
      await widget.history.append(entry);
    } catch (_) {
      // Nothing to say on screen: the entry is held in memory either way, so
      // the outcome card and its bug report render unchanged.
    }
  }

  Future<DemoVersions> _versionsOrUnknown() async {
    try {
      return await widget.readVersions();
    } catch (_) {
      return unknownVersions;
    }
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
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(human, style: const TextStyle(height: 1.4)),
                    const SizedBox(height: 12),
                    Text('Session ${_sessionId ?? '(none)'}'),
                    Text('Transaction ${_transactionId ?? '(none)'}'),
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
