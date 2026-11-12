import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'surface.dart';

const int historyCap = 50;

const String _historyKey = 'paycross_demo_history';

const Duration _appendTimeout = Duration(seconds: 5);

final Expando<Future<void>> _writeQueues = Expando<Future<void>>();

class HistoryEntry {
  const HistoryEntry({
    required this.at,
    required this.presetName,
    required this.sessionId,
    required this.transactionId,
    required this.outcome,
    required this.demoVersion,
    required this.pluginVersion,
    required this.nativeSdkVersion,
    this.live = false,
    this.surface = sdkSurfaceName,
  });

  factory HistoryEntry.fromJson(Map<String, Object?> json) => HistoryEntry(
    at: DateTime.parse(json['at']! as String),
    presetName: json['presetName']! as String,
    sessionId: json['sessionId']! as String,
    transactionId: json['transactionId'] as String?,
    outcome: json['outcome']! as String,
    demoVersion: json['demoVersion']! as String,
    pluginVersion: json['pluginVersion']! as String,
    nativeSdkVersion: json['nativeSdkVersion']! as String,
    live: json['live'] as bool? ?? false,
    surface: json['surface'] as String? ?? sdkSurfaceName,
  );

  final DateTime at;
  final String presetName;
  final String sessionId;
  final String? transactionId;
  final String outcome;
  final String demoVersion;
  final String pluginVersion;
  final String nativeSdkVersion;

  final bool live;

  final String surface;

  bool get isWeb => surface == webSurfaceName;

  Map<String, Object?> toJson() => {
    'at': at.toIso8601String(),
    'presetName': presetName,
    'sessionId': sessionId,
    'transactionId': transactionId,
    'outcome': outcome,
    'demoVersion': demoVersion,
    'pluginVersion': pluginVersion,
    'nativeSdkVersion': nativeSdkVersion,
    'live': live,
    'surface': surface,
  };
}

String bugReport(HistoryEntry entry) =>
    '''
PayCross Demo run
  when:        ${entry.at.toIso8601String()}
  scenario:    ${entry.presetName}${entry.live ? '\n  mode:        LIVE — real money, refund it in the back office' : ''}${entry.isWeb ? '\n  surface:     web checkout in the browser — the app never saw the result' : ''}
  session:     ${entry.sessionId}
  transaction: ${entry.transactionId ?? '(none)'}
  outcome:     ${entry.outcome}
  demo:        ${entry.demoVersion}
  plugin:      ${entry.pluginVersion}
  native SDK:  ${entry.nativeSdkVersion}''';

abstract interface class HistoryBackend {
  Future<List<String>> read();
  Future<void> write(List<String> entries);
}

class SharedPreferencesHistoryBackend implements HistoryBackend {
  const SharedPreferencesHistoryBackend();

  @override
  Future<List<String>> read() async =>
      (await SharedPreferences.getInstance()).getStringList(_historyKey) ??
      const <String>[];

  @override
  Future<void> write(List<String> entries) async =>
      (await SharedPreferences.getInstance()).setStringList(
        _historyKey,
        entries,
      );
}

class InMemoryHistoryBackend implements HistoryBackend {
  List<String> entries = <String>[];

  @override
  Future<List<String>> read() async => List<String>.from(entries);

  @override
  Future<void> write(List<String> written) async =>
      entries = List<String>.from(written);
}

class HistoryStore {
  const HistoryStore({
    HistoryBackend backend = const SharedPreferencesHistoryBackend(),
  })
    // ignore: prefer_initializing_formals
    : _backend = backend;

  final HistoryBackend _backend;

  Future<List<HistoryEntry>> read() async {
    final List<String> lines;
    try {
      lines = await _backend.read();
    } catch (_) {
      return const <HistoryEntry>[];
    }
    final entries = <HistoryEntry>[];
    for (final line in lines) {
      try {
        entries.add(
          HistoryEntry.fromJson(jsonDecode(line) as Map<String, Object?>),
        );
      } catch (_) {
        continue;
      }
    }
    return entries;
  }

  Future<void> append(HistoryEntry entry) {
    final queued = _writeQueues[_backend] ?? Future<void>.value();
    final written = queued.then((_) async {
      final kept = [entry, ...await read()].take(historyCap);
      await _backend.write([for (final e in kept) jsonEncode(e.toJson())]);
    });
    _writeQueues[_backend] = written
        .timeout(_appendTimeout, onTimeout: () {})
        .catchError((Object _) {});
    return written;
  }
}
