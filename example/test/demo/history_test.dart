import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/history.dart';
import 'package:paycross_demo/demo/live.dart';

HistoryEntry _entry() => HistoryEntry(
  at: DateTime.utc(2026, 8, 29, 15, 4, 5),
  presetName: '3DS challenge → approve',
  sessionId: 'sess-9',
  transactionId: 'txn-9',
  outcome: 'Approved — 1000 EUR, transaction txn-9',
  demoVersion: '0.1.0+7',
  pluginVersion: '0.1.0',
  nativeSdkVersion: '0.1.1',
);

/// A store whose first write fails and whose later ones do not, which is
/// what a device that was briefly out of space looks like.
class _FailOnceBackend implements HistoryBackend {
  bool _failed = false;
  List<String> entries = <String>[];

  @override
  Future<List<String>> read() async => List<String>.from(entries);

  @override
  Future<void> write(List<String> written) async {
    if (!_failed) {
      _failed = true;
      throw StateError('no space');
    }
    entries = List<String>.from(written);
  }
}

void main() {
  test('an entry survives a round trip through the store', () async {
    final store = HistoryStore(backend: InMemoryHistoryBackend());

    await store.append(_entry());
    final read = await store.read();

    expect(read, hasLength(1));
    expect(read.single.sessionId, 'sess-9');
    expect(read.single.at, DateTime.utc(2026, 8, 29, 15, 4, 5));
  });

  test('the newest run is first', () async {
    final store = HistoryStore(backend: InMemoryHistoryBackend());

    await store.append(_entry());
    await store.append(
      HistoryEntry(
        at: DateTime.utc(2026, 8, 29, 16),
        presetName: 'Instant approve (no 3DS)',
        sessionId: 'sess-10',
        transactionId: null,
        outcome: 'Payment cancelled.',
        demoVersion: '0.1.0+7',
        pluginVersion: '0.1.0',
        nativeSdkVersion: 'unknown',
      ),
    );

    expect((await store.read()).first.sessionId, 'sess-10');
  });

  test('a corrupt store reads as empty, never as a crash', () async {
    final backend = InMemoryHistoryBackend()..entries = ['not json'];
    final store = HistoryStore(backend: backend);

    expect(await store.read(), isEmpty);
  });

  test('the store keeps at most the cap, dropping the oldest', () async {
    final store = HistoryStore(backend: InMemoryHistoryBackend());

    for (var i = 0; i < historyCap + 5; i++) {
      await store.append(
        HistoryEntry(
          at: DateTime.utc(2026, 8, 29).add(Duration(minutes: i)),
          presetName: 'p',
          sessionId: 'sess-$i',
          transactionId: null,
          outcome: 'Payment cancelled.',
          demoVersion: '0.1.0+7',
          pluginVersion: '0.1.0',
          nativeSdkVersion: 'unknown',
        ),
      );
    }
    final read = await store.read();

    expect(read, hasLength(historyCap));
    expect(read.first.sessionId, 'sess-${historyCap + 4}');
  });

  test('the bug report carries the ids and the versions', () {
    final report = bugReport(_entry());

    expect(report, contains('sess-9'));
    expect(report, contains('txn-9'));
    expect(report, contains('0.1.0+7'));
    expect(report, contains('3DS challenge → approve'));
  });

  test('nothing an entry can hold is a token', () {
    // Structural, not textual: the type has no field for one, so no future
    // edit can add a token to a bug report without failing here first.
    final fields = _entry().toJson().keys.toSet();

    expect(fields.where((f) => f.contains('token')), isEmpty);
    expect(fields, {
      'at',
      'presetName',
      'sessionId',
      'transactionId',
      'outcome',
      'demoVersion',
      'pluginVersion',
      'nativeSdkVersion',
      'live',
    });
  });

  test('one corrupt line does not take the rest of the history with it', () {
    // A process killed mid-write leaves a truncated last line. Reading the
    // whole store as empty threw away every run that had been written
    // correctly, which is the history somebody wanted that morning.
    final backend = InMemoryHistoryBackend()
      ..entries = [
        jsonEncode(_entry().toJson()),
        '{"at": "2026-08-29T15:04:05.000Z", "presetNam',
      ];

    expect(HistoryStore(backend: backend).read(), completion(hasLength(1)));
  });

  test('two runs finishing at once both survive', () async {
    // `append` is read-modify-write over one key. Unserialised, both reads
    // see the old list and the second write drops the first one's row.
    final store = HistoryStore(backend: InMemoryHistoryBackend());

    await Future.wait([
      store.append(_entry()),
      store.append(
        HistoryEntry(
          at: DateTime.utc(2026, 8, 29, 16),
          presetName: 'Instant approve (no 3DS)',
          sessionId: 'sess-10',
          transactionId: null,
          outcome: 'Payment cancelled.',
          demoVersion: '0.1.0+7',
          pluginVersion: '0.1.0',
          nativeSdkVersion: 'unknown',
        ),
      ),
    ]);

    expect((await store.read()).map((e) => e.sessionId).toSet(), {
      'sess-9',
      'sess-10',
    });
  });

  test('a write that fails does not stop the next one', () async {
    // The queue is what serialises appends, so a link that threw must not be
    // what every later append is still waiting on. The caller sees the
    // failure; the queue does not keep it.
    final store = HistoryStore(backend: _FailOnceBackend());

    await expectLater(store.append(_entry()), throwsStateError);
    await store.append(
      HistoryEntry(
        at: DateTime.utc(2026, 8, 29, 16),
        presetName: 'Instant approve (no 3DS)',
        sessionId: 'sess-10',
        transactionId: null,
        outcome: 'Payment cancelled.',
        demoVersion: '0.1.0+7',
        pluginVersion: '0.1.0',
        nativeSdkVersion: 'unknown',
      ),
    );

    expect((await store.read()).single.sessionId, 'sess-10');
  });
  test('a run is a Test run unless it says otherwise', () {
    // The default is the whole upgrade story: `fromJson` is strict and
    // `read` drops rows it cannot parse, so a required field here would
    // silently wipe every tester's existing sandbox history.
    expect(_entry().live, isFalse);
  });

  test('a row written before Live mode existed still reads', () async {
    final old = <String, Object?>{
      'at': '2026-08-29T15:04:05.000Z',
      'presetName': 'Instant approve (no 3DS)',
      'sessionId': 'sess-1',
      'transactionId': 'txn-1',
      'outcome': 'Approved.',
      'demoVersion': '0.1.0+26',
      'pluginVersion': '0.1.0',
      'nativeSdkVersion': 'unknown',
    };
    final backend = InMemoryHistoryBackend()..entries = [jsonEncode(old)];

    final read = await HistoryStore(backend: backend).read();

    expect(read, hasLength(1));
    expect(read.single.live, isFalse);
  });

  test('a Live run survives a round trip marked live', () async {
    final store = HistoryStore(backend: InMemoryHistoryBackend());

    await store.append(
      HistoryEntry(
        at: DateTime.utc(2026, 8, 31, 12),
        presetName: liveScenarioName(LiveScenario.smoke, liveDefaultCurrency),
        sessionId: 'sess-live',
        transactionId: 'txn-live',
        outcome: 'Approved.',
        demoVersion: '0.1.1+27',
        pluginVersion: '0.1.0',
        nativeSdkVersion: 'unknown',
        live: true,
      ),
    );

    expect((await store.read()).single.live, isTrue);
  });

  test('a Live bug report says so, and a Test one is unchanged', () {
    final live = bugReport(
      HistoryEntry(
        at: DateTime.utc(2026, 8, 31, 12),
        presetName: liveScenarioName(LiveScenario.smoke, liveDefaultCurrency),
        sessionId: 'sess-live',
        transactionId: 'txn-live',
        outcome: 'Approved.',
        demoVersion: '0.1.1+27',
        pluginVersion: '0.1.0',
        nativeSdkVersion: 'unknown',
        live: true,
      ),
    );

    expect(live, contains('LIVE'));
    // A Test report keeps exactly the shape people are already pasting into
    // issues: the extra line appears only where it means something.
    expect(bugReport(_entry()), isNot(contains('LIVE')));
  });
}
