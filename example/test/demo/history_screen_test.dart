import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/history.dart';
import 'package:paycross_demo/demo/history_screen.dart';

import '_surface.dart';

HistoryEntry _entry({
  required String session,
  required String preset,
  bool live = false,
}) => HistoryEntry(
  at: DateTime.utc(2026, 8, 29, 15, 4, 5),
  presetName: preset,
  sessionId: session,
  transactionId: 'txn-$session',
  outcome: 'Approved — 1000 EUR, transaction txn-$session',
  demoVersion: '0.1.0+7',
  pluginVersion: '0.1.0',
  nativeSdkVersion: 'unknown',
  live: live,
);

/// A backend already holding [entries], as a phone that has run before does.
InMemoryHistoryBackend _seeded(List<HistoryEntry> entries) =>
    InMemoryHistoryBackend()
      ..entries = [for (final e in entries) jsonEncode(e.toJson())];

void main() {
  testWidgets('lists the runs the store holds', (tester) async {
    useTallSurface(tester);
    final store = HistoryStore(
      backend: _seeded([
        _entry(session: 'sess-10', preset: 'Instant approve (no 3DS)'),
        _entry(session: 'sess-9', preset: '3DS challenge → approve'),
      ]),
    );

    await tester.pumpWidget(MaterialApp(home: HistoryScreen(store: store)));
    await tester.pumpAndSettle();

    expect(find.text('Instant approve (no 3DS)'), findsOneWidget);
    expect(find.text('3DS challenge → approve'), findsOneWidget);
    expect(find.textContaining('sess-10'), findsOneWidget);
  });

  testWidgets('a tap copies the bug report and no token with it', (
    tester,
  ) async {
    useTallSurface(tester);
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final store = HistoryStore(
      backend: _seeded([_entry(session: 'sess-9', preset: 'Frictionless 3DS')]),
    );

    await tester.pumpWidget(MaterialApp(home: HistoryScreen(store: store)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Frictionless 3DS'));
    await tester.pumpAndSettle();

    expect(copied, hasLength(1));
    expect(copied.single, contains('sess-9'));
    expect(copied.single, contains('txn-sess-9'));
    // The report is built from an entry, and an entry has no field that can
    // hold one -- this is the screen-level end of that guarantee.
    expect(copied.single.toLowerCase(), isNot(contains('token')));
    expect(find.text('Copied.'), findsOneWidget);
  });
  testWidgets('a Live run is marked, and a Test run is not', (tester) async {
    useTallSurface(tester);
    final store = HistoryStore(
      backend: _seeded([
        _entry(
          session: 'sess-live',
          preset: 'Live smoke — €1.00 charge',
          live: true,
        ),
        _entry(session: 'sess-9', preset: '3DS challenge → approve'),
      ]),
    );

    await tester.pumpWidget(MaterialApp(home: HistoryScreen(store: store)));
    await tester.pumpAndSettle();

    // Both rows are on screen, so the Test row being unmarked is a fact about
    // the row rather than about a row that never rendered.
    expect(find.text('Live smoke — €1.00 charge'), findsOneWidget);
    expect(find.text('3DS challenge → approve'), findsOneWidget);
    // One marking for one live row, whatever the rest of the list holds.
    expect(find.byKey(const ValueKey('historyLive')), findsOneWidget);
  });
}
