import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/history.dart';
import 'package:paycross_demo/demo/minter.dart';
import 'package:paycross_demo/demo/presets.dart';
import 'package:paycross_demo/demo/run.dart';
import 'package:paycross_demo/e2e_label.dart';
import 'package:paycross_flutter/paycross_flutter.dart';

import '../automation_screen_test.dart' show spokenLabels;
import 'presets_test.dart' show legacyLabelPrefixes;

final _preset = demoPresets.first;

PayCrossSuccess _success(String txn) => PayCrossSuccess(
  transactionId: txn,
  status: 'success',
  amount: const PayCrossAmount(minorUnits: 1000, currencyCode: 'EUR'),
);

/// A history whose writes fail, which is what a full or unwritable store
/// looks like from Dart.
class _ThrowingHistoryBackend implements HistoryBackend {
  @override
  Future<List<String>> read() async => const <String>[];

  @override
  Future<void> write(List<String> entries) async =>
      throw StateError('no store');
}

Widget _run({
  required Future<PayCrossResult> Function(String) present,
  HistoryStore? history,
  bool e2e = false,
  Future<MintedSession> Function()? mint,
}) => MaterialApp(
  home: RunScreen(
    preset: _preset,
    body: _preset.body,
    e2e: e2e,
    mintSession:
        mint ??
        () async => const MintedSession(
          id: 'sess-9',
          token: 'a-live-token',
          sentBody: '{}',
        ),
    present: present,
    history: history ?? HistoryStore(backend: InMemoryHistoryBackend()),
    readVersions: () async =>
        (demo: '0.1.0+7', plugin: '0.1.0', nativeSdk: 'unknown'),
  ),
);

void main() {
  testWidgets('an ordinary build shows the human outcome and no label', (
    tester,
  ) async {
    await tester.pumpWidget(_run(present: (_) async => _success('txn-9')));
    await tester.pumpAndSettle();

    expect(find.text('Approved — 1000 EUR, transaction txn-9'), findsOneWidget);
    expect(find.byKey(const ValueKey('e2eLabel')), findsNothing);
  });

  testWidgets('the E2E build puts the contract label before the human card', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(
      _run(present: (_) async => _success('txn-9'), e2e: true),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('e2eLabel')), findsOneWidget);
    // `tree.label_from_tree` returns the FIRST node whose text starts with
    // the contract prefixes, so anything that could also match must come
    // after this node.
    final spoken = spokenLabels(tester);
    final label = spoken.indexWhere(
      (s) => s.startsWith(
        'resu'
        'lt:',
      ),
    );
    // startsWith, not indexOf: the human card is a Card wrapping a Column and
    // its three Text children merge into one semantics node whose label is all
    // three joined by newlines, so an exact match returns -1.
    final human = spoken.indexWhere((s) => s.startsWith('Approved — 1000 EUR'));
    expect(label, isNonNegative);
    expect(human, isNonNegative);
    expect(label, lessThan(human));

    handle.dispose();
  });

  testWidgets('the label node holds exactly what e2e_label.dart produces', (
    tester,
  ) async {
    const paid = PayCrossSuccess(
      transactionId: 'txn-9',
      status: 'success',
      amount: PayCrossAmount(minorUnits: 1000, currencyCode: 'EUR'),
    );
    const problem = PayCrossIntegrationError(
      PayCrossErrorCode.invalidToken,
      'The session token was empty.',
    );

    Future<String?> labelAfter(
      Future<PayCrossResult> Function(String) present,
    ) async {
      // A bare tree first, so the second pump builds a new State rather than
      // updating the one that already holds the first outcome.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_run(present: present, e2e: true));
      await tester.pumpAndSettle();
      return tester.widget<Text>(find.byKey(const ValueKey('e2eLabel'))).data;
    }

    // The golden. The runner compares a label whole, with `==`, so the node
    // must carry what e2e_label.dart produces and nothing else -- no prefix,
    // no trailing space, no decoration. Pinned against the function rather
    // than a literal so the contract still has exactly one spelling.
    expect(await labelAfter((_) async => paid), labelForResult(paid));
    expect(
      await labelAfter((_) async => throw problem),
      labelForError(problem),
    );
  });

  testWidgets('an integration error renders as a problem, not a refusal', (
    tester,
  ) async {
    await tester.pumpWidget(
      _run(
        present: (_) async => throw const PayCrossIntegrationError(
          PayCrossErrorCode.invalidToken,
          'The session token was empty.',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Integration problem'), findsOneWidget);
  });

  testWidgets('a mint that fails never reaches presentPayment', (tester) async {
    var presented = false;
    await tester.pumpWidget(
      _run(
        mint: () async => throw const MinterError('POST -> HTTP 401'),
        present: (_) async {
          presented = true;
          return _success('txn-9');
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(presented, isFalse);
    expect(find.textContaining('HTTP 401'), findsOneWidget);
  });

  testWidgets('the run is appended to history with its ids', (tester) async {
    final backend = InMemoryHistoryBackend();
    final history = HistoryStore(backend: backend);

    await tester.pumpWidget(
      _run(present: (_) async => _success('txn-9'), history: history),
    );
    await tester.pumpAndSettle();

    final stored = await history.read();
    expect(stored, hasLength(1));
    expect(stored.single.sessionId, 'sess-9');
    expect(stored.single.transactionId, 'txn-9');
    expect(stored.single.presetName, _preset.name);
  });

  testWidgets('the bug report is copyable from the run itself', (tester) async {
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

    await tester.pumpWidget(_run(present: (_) async => _success('txn-9')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('copyBugReport')));
    await tester.pumpAndSettle();

    expect(copied, hasLength(1));
    expect(copied.single, contains('sess-9'));
    expect(copied.single, contains('txn-9'));
    expect(copied.single, isNot(contains('a-live-token')));
  });

  testWidgets('the session token never reaches the screen', (tester) async {
    await tester.pumpWidget(_run(present: (_) async => _success('txn-9')));
    await tester.pumpAndSettle();

    expect(find.textContaining('a-live-token'), findsNothing);
  });

  testWidgets('a history that cannot be written never hides the outcome', (
    tester,
  ) async {
    // A real payment has already happened by the time the write is tried,
    // and it may have taken money. Losing the row is a nuisance; losing the
    // outcome would leave the screen on "Waiting for the payment sheet..."
    // with no way to tell a hang from a completed charge.
    await tester.pumpWidget(
      _run(
        present: (_) async => _success('txn-9'),
        history: HistoryStore(backend: _ThrowingHistoryBackend()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Approved — 1000 EUR, transaction txn-9'), findsOneWidget);
    // And the report is still copyable: the entry exists in memory whether
    // or not it reached the store.
    expect(find.byKey(const ValueKey('copyBugReport')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the outcome announces itself to a screen reader', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(_run(present: (_) async => _success('txn-9')));
    await tester.pumpAndSettle();

    // The outcome can land minutes after the tap -- a challenge waits on the
    // shopper's bank -- and it lands in place, with no focus change and
    // nothing to navigate to. Without this a screen-reader user is never
    // told the payment finished.
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('runOutcome')))
          .flagsCollection
          .isLiveRegion,
      isTrue,
    );

    semantics.dispose();
  });

  testWidgets('nothing the screen says reads as a build without the define', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();

    void sweep(String where) {
      final spoken = spokenLabels(tester);
      // Without this the sweep goes quietly vacuous the day the tree stops
      // producing labels: zero nodes pass every prefix.
      expect(spoken, isNotEmpty, reason: where);
      for (final label in spoken) {
        for (final prefix in legacyLabelPrefixes) {
          expect(
            label.startsWith(prefix),
            isFalse,
            reason: '$where -- "$label" starts with "$prefix".',
          );
        }
      }
    }

    // A12 is a rule about the whole screen, not about `humanOutcome` alone:
    // `Driver.no_label_error` scans the accessibility tree, and it runs when
    // the runner could NOT find a label -- so the two in-flight stages are
    // the ones that matter most, and a settled screen alone would miss them.
    final mint = Completer<MintedSession>();
    final paid = Completer<PayCrossResult>();
    await tester.pumpWidget(
      _run(mint: () => mint.future, present: (_) => paid.future, e2e: true),
    );
    await tester.pump();
    // Each stage is pinned before it is swept. Without that the sweep passes
    // by never reaching the frame it means to check, which is how a mutation
    // to this very string went unnoticed the first time.
    expect(find.text('Minting a session…'), findsOneWidget);
    sweep('while minting');

    mint.complete(
      const MintedSession(id: 'sess-9', token: 'a-live-token', sentBody: '{}'),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Waiting for the payment sheet…'), findsOneWidget);
    sweep('while waiting for the sheet');

    paid.complete(_success('txn-9'));
    await tester.pumpAndSettle();
    expect(find.text('Done.'), findsOneWidget);
    sweep('when done');

    Future<void> settle(
      String where,
      Future<PayCrossResult> Function(String) present, {
      Future<MintedSession> Function()? mint,
    }) async {
      // A bare tree first, so each case builds a new State rather than
      // updating the one that already settled.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_run(present: present, mint: mint, e2e: true));
      await tester.pumpAndSettle();
      sweep(where);
    }

    await settle(
      'a refusal',
      (_) async => const PayCrossFailure(recovery: RecoveryDoNotRetry()),
    );
    await settle('a cancellation', (_) async => const PayCrossCancelled());
    await settle(
      'an integration problem',
      (_) async => throw const PayCrossIntegrationError(
        PayCrossErrorCode.resultUnknown,
        'The app was killed mid-flight.',
      ),
    );
    await settle(
      'a mint that failed',
      (_) async => _success('txn-9'),
      mint: () async => throw const MinterError('POST -> HTTP 401'),
    );

    semantics.dispose();
  });
}
