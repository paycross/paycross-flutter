import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'surface.dart';

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
/// cannot leak one into a report someone pastes into an issue. There is no
/// field for a checkout URL either, and that is the same rule rather than a
/// second one -- the URL is `…/pay?session=<token>`, so a type that could
/// hold it could leak the token by another name.
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
    // Optional and defaulted on purpose. This factory is strict and
    // `HistoryStore.read` drops any row whose parse throws, so a required
    // field here would make every row written by demo-v0.1.0 unreadable and
    // wipe each tester's history on upgrade.
    live: json['live'] as bool? ?? false,
    // The same rule again, for the same reason: every row written before
    // demo-v0.1.4 was an SDK-sheet run, and reading them back as one is both
    // true and what keeps them readable at all.
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

  /// Whether this run charged a real card.
  ///
  /// Recorded so a history full of sandbox runs cannot hide the one that
  /// needs refunding. It is a flag, not a credential: Live credentials are
  /// in no store to leak, and this row holds the same ids and outcome every
  /// other row holds.
  final bool live;

  /// Which surface the session was presented on: [sdkSurfaceName] or
  /// [webSurfaceName].
  ///
  /// A stored word rather than the [PaymentSurface] enum, because this is a
  /// row that outlives the build that wrote it and an enum's ordinal is not
  /// a format. It matters to whoever reads the row: a web run's outcome is
  /// what the app *did*, never what the payment did, and a report that does
  /// not say which surface it was invites reading one as the other.
  final String surface;

  /// Whether this run handed the session to the browser instead of the sheet.
  ///
  /// Named once and read by both the screen and the report, so the two
  /// cannot disagree about which rows are web runs -- and so an unrecognised
  /// word from a newer build reads as "not web" in exactly one place.
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

/// What a colleague pastes into an issue.
///
/// The two conditional lines are conditional rather than always present, and
/// that is deliberate: a sandbox sheet run's report is the bytes it always
/// was, so nothing that quotes one has to be re-read. What is added is added
/// where it changes the reading -- LIVE means money moved, and web means the
/// app never learned the outcome and the line below is only what it did.
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
  /// purpose. The queue is keyed on the backend rather than held in a field
  /// because these stores are cheap `const` values built at each call site,
  /// so an instance field would not be shared between them.
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
