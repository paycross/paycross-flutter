import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'environment.dart';
import 'history.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, this.store = const HistoryStore()});

  final HistoryStore store;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<HistoryEntry>? _entries;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final read = await widget.store.read();
    if (!mounted) return;
    setState(() => _entries = read);
  }

  Future<void> _copy(HistoryEntry entry) async {
    await Clipboard.setData(ClipboardData(text: bugReport(entry)));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Copied.')));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('History')),
    body: _body(),
  );

  Widget _body() {
    final entries = _entries;
    if (entries == null) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: Text('Reading past runs…'),
      );
    }
    if (entries.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: Text(
          'No runs yet. Every scenario you run from Home lands here, with '
          'the ids a bug report needs.',
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          child: Text(
            'Tap a run to copy its bug report. Nothing kept here is a '
            'credential or a session token.',
          ),
        ),
        for (final entry in entries)
          Card(
            child: ListTile(
              leading: entry.live
                  ? const Icon(Icons.warning_amber_rounded, color: liveRed)
                  : null,
              title: Row(
                children: [
                  Expanded(child: Text(entry.presetName)),
                  if (entry.isWeb)
                    const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: Text(
                        'WEB',
                        key: ValueKey('historyWeb'),
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  if (entry.live)
                    const Text(
                      'LIVE',
                      key: ValueKey('historyLive'),
                      style: TextStyle(
                        color: liveRed,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                ],
              ),
              subtitle: Text(
                [
                  entry.outcome,
                  'Session ${entry.sessionId}',
                  'Transaction ${entry.transactionId ?? '(none)'}',
                  '${entry.at.toIso8601String()} — demo ${entry.demoVersion}, '
                      'plugin ${entry.pluginVersion}, '
                      'native SDK ${entry.nativeSdkVersion}',
                ].join('\n'),
              ),
              isThreeLine: true,
              trailing: const Icon(Icons.copy),
              onTap: () => _copy(entry),
            ),
          ),
      ],
    );
  }
}
