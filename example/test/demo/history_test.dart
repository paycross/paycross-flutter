import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/history.dart';

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
    });
  });
}
