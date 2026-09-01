import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'environment.dart';
import 'history.dart';

/// Past runs, newest first; a tap puts one on the clipboard as a bug report.
///
/// The store is a constructor argument for the same reason Home's and
/// Settings' stores are: the default reaches `SharedPreferences`, which under
/// `flutter test` has no platform behind it.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, this.store = const HistoryStore()});

  final HistoryStore store;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  /// Null until the first read comes back, so an empty store and a store
  /// that has not answered yet do not render the same way.
  List<HistoryEntry>? _entries;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // HistoryStore.read answers an empty list on a store it cannot parse, so
    // there is nothing here to guard against beyond what it already does.
    final read = await widget.store.read();
    if (!mounted) return;
    setState(() => _entries = read);
  }

  Future<void> _copy(HistoryEntry entry) async {
    await Clipboard.setData(ClipboardData(text: bugReport(entry)));
    if (!mounted) return;
    // A SnackBar rather than a line on the screen: it is already a live
    // region, so a screen reader hears that the tap did something.
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
      // Text, not a spinner: an indeterminate animation never settles, so a
      // widget test that pumps to settle on this screen would hang.
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
                  // The same red the banner uses. A list of forty sandbox
                  // runs is exactly where the one that took money has to be
                  // findable at a glance -- it is the row somebody is
                  // scrolling for when they are trying to remember whether
                  // they refunded it.
                  ? const Icon(Icons.warning_amber_rounded, color: liveRed)
                  : null,
              title: Row(
                children: [
                  Expanded(child: Text(entry.presetName)),
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
