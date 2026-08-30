import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// How many runs to keep. A demo phone accumulates these forever otherwise,
/// and nobody reads past the last few.
const int historyCap = 50;

const String _historyKey = 'paycross_demo_history';

/// How long one queued write gets before the queue moves on without it.
///
/// A platform store with nothing behind it does not fail, it never answers --
/// and an unbounded queue would then never write another row for the rest of
/// the process.
const Duration _appendTimeout = Duration(seconds: 5);

/// The write in flight for a given backend, so appends to one store queue up
/// instead of overwriting each other.
///
/// Keyed on the backend rather than held in a static field. Every
/// [SharedPreferencesHistoryBackend] is the same canonical const instance, so
/// the app gets exactly one queue over the one key it writes; a test's own
/// backend is a distinct object and gets a queue of its own, so a write left
/// in flight by one test cannot stall the next one.
final Expando<Future<void>> _writeQueues = Expando<Future<void>>();

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
  }) // The lint's own fix does not compile: Dart forbids a private NAMED
    // parameter, so `this._backend` cannot appear in a `{...}` list, and a
    // public backend is not what this class is for.
    // ignore: prefer_initializing_formals
    : _backend = backend;

  final HistoryBackend _backend;

  /// Every run this store can still make sense of, newest first.
  ///
  /// Per line, so one unreadable row costs one row. A process the system
  /// killed mid-write leaves a truncated last line, and a build older than
  /// the current shape leaves rows this cannot parse -- neither is worth
  /// throwing away the runs that were written correctly, which are the ones
  /// somebody wants when they open this screen.
  Future<List<HistoryEntry>> read() async {
    final List<String> lines;
    try {
      lines = await _backend.read();
    } catch (_) {
      // No store to read at all. An empty history is a usable screen; an
      // exception here is not.
      return const <HistoryEntry>[];
    }
    final entries = <HistoryEntry>[];
    for (final line in lines) {
      try {
        entries.add(
          HistoryEntry.fromJson(jsonDecode(line) as Map<String, Object?>),
        );
      } catch (_) {
        // This one row only.
        continue;
      }
    }
    return entries;
  }

  /// Appends [entry], one write at a time across the whole process.
  ///
  /// This is read-modify-write over a single key. Two runs finishing at once
  /// would both read the old list and the second write would drop the first
  /// one's row -- silently, and only under a race nobody would reproduce on
  /// purpose. The chain is static because these stores are cheap `const`
  /// values built at each call site, so an instance field would not be
  /// shared between them.
  Future<void> append(HistoryEntry entry) {
    final queued = _writeQueues[_backend] ?? Future<void>.value();
    final written = queued.then((_) async {
      final kept = [entry, ...await read()].take(historyCap);
      await _backend.write([for (final e in kept) jsonEncode(e.toJson())]);
    });
    // What the queue waits on is deliberately neither this write's failure
    // nor its silence: one unwritable or unanswering store must not stop
    // every run after it from being recorded. The caller still sees both.
    _writeQueues[_backend] = written
        .timeout(_appendTimeout, onTimeout: () {})
        .catchError((Object _) {});
    return written;
  }
}
