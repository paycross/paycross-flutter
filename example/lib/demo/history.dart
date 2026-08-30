// ignore_for_file: prefer_initializing_formals
// The lint's own fix does not compile: Dart forbids a private NAMED
// parameter, so `this._x` cannot appear in a `{...}` list, and the backend stays private.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// How many runs to keep. A demo phone accumulates these forever otherwise,
/// and nobody reads past the last few.
const int historyCap = 50;

const String _historyKey = 'paycross_demo_history';

/// One past run, as a bug report needs it.
///
/// There is deliberately no field for a session token: the token is handed
/// to `presentPayment` once and dropped, and a type that cannot hold one
/// cannot leak one into a report someone pastes into an issue.
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
  );

  final DateTime at;
  final String presetName;
  final String sessionId;
  final String? transactionId;
  final String outcome;
  final String demoVersion;
  final String pluginVersion;
  final String nativeSdkVersion;

  Map<String, Object?> toJson() => {
    'at': at.toIso8601String(),
    'presetName': presetName,
    'sessionId': sessionId,
    'transactionId': transactionId,
    'outcome': outcome,
    'demoVersion': demoVersion,
    'pluginVersion': pluginVersion,
    'nativeSdkVersion': nativeSdkVersion,
  };
}

/// What a colleague pastes into an issue.
String bugReport(HistoryEntry entry) =>
    '''
PayCross Demo run
  when:        ${entry.at.toIso8601String()}
  scenario:    ${entry.presetName}
  session:     ${entry.sessionId}
  transaction: ${entry.transactionId ?? '(none)'}
  outcome:     ${entry.outcome}
  demo:        ${entry.demoVersion}
  plugin:      ${entry.pluginVersion}
  native SDK:  ${entry.nativeSdkVersion}''';

/// The slice of a key-value store History needs.
abstract interface class HistoryBackend {
  Future<List<String>> read();
  Future<void> write(List<String> entries);
}

/// Plain `SharedPreferences`: a history holds no secrets, and the secure
/// store is slower and smaller.
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

/// A [HistoryBackend] in a list. Tests only.
class InMemoryHistoryBackend implements HistoryBackend {
  List<String> entries = <String>[];

  @override
  Future<List<String>> read() async => List<String>.from(entries);

  @override
  Future<void> write(List<String> written) async =>
      entries = List<String>.from(written);
}

/// Past runs, newest first.
class HistoryStore {
  const HistoryStore({
    HistoryBackend backend = const SharedPreferencesHistoryBackend(),
  }) : _backend = backend;

  final HistoryBackend _backend;

  Future<List<HistoryEntry>> read() async {
    try {
      return [
        for (final line in await _backend.read())
          HistoryEntry.fromJson(jsonDecode(line) as Map<String, Object?>),
      ];
    } catch (_) {
      // A store written by an older build, or half-written by a process the
      // system killed. Losing a history is not worth an unusable screen.
      return const <HistoryEntry>[];
    }
  }

  Future<void> append(HistoryEntry entry) async {
    final kept = [entry, ...await read()].take(historyCap);
    await _backend.write([for (final e in kept) jsonEncode(e.toJson())]);
  }
}
