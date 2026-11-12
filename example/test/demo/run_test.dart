import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/history.dart';
import 'package:paycross_demo/demo/live.dart';
import 'package:paycross_demo/demo/minter.dart';
import 'package:paycross_demo/demo/presets.dart';
import 'package:paycross_demo/demo/run.dart';
import 'package:paycross_demo/demo/version_panel.dart';
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

class _ThrowingHistoryBackend implements HistoryBackend {
  @override
  Future<List<String>> read() async => const <String>[];

  @override
  Future<void> write(List<String> entries) async =>
      throw StateError('no store');
}

class _HangingHistoryBackend implements HistoryBackend {
  @override
  Future<List<String>> read() async => const <String>[];

  @override
  Future<void> write(List<String> entries) => Completer<void>().future;
}

Widget _run({
  required Future<PayCrossResult> Function(String) present,
  HistoryStore? history,
  bool e2e = false,
  bool live = false,
  Future<MintedSession> Function(String)? mint,
  Future<DemoVersions> Function()? readVersions,
}) => MaterialApp(
  home: RunScreen(
    preset: _preset,
    body: _preset.body,
    e2e: e2e,
    live: live,
    mintSession:
        mint ??
        (_) async => const MintedSession(
          id: 'sess-9',
          token: 'a-live-token',
          sentBody: '{}',
        ),
    present: present,
    history: history ?? HistoryStore(backend: InMemoryHistoryBackend()),
    readVersions:
        readVersions ??
        () async => (demo: '0.1.0+7', plugin: '0.1.0', nativeSdk: 'unknown'),
  ),
);

void main() {
  testWidgets('an ordinary build shows the human outcome and no label', (
    tester,
  ) async {
    await tester.pumpWidget(_run(present: (_) async => _success('txn-9')));
    await tester.pumpAndSettle();

    expect(find.text('Approved — €10.00, transaction txn-9'), findsOneWidget);
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
    final spoken = spokenLabels(tester);
    final label = spoken.indexWhere(
      (s) => s.startsWith(
        'resu'
        'lt:',
      ),
    );
    final human = spoken.indexWhere((s) => s.startsWith('Approved — €10.00'));
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
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_run(present: present, e2e: true));
      await tester.pumpAndSettle();
      return tester.widget<Text>(find.byKey(const ValueKey('e2eLabel'))).data;
    }

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
        mint: (_) async => throw const MinterError('POST -> HTTP 401'),
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

  testWidgets('a cancelled run keeps the transaction it abandoned', (
    tester,
  ) async {
    final backend = InMemoryHistoryBackend();
    final history = HistoryStore(backend: backend);

    await tester.pumpWidget(
      _run(
        present: (_) async =>
            const PayCrossCancelled(transactionId: 'txn-abandoned'),
        history: history,
      ),
    );
    await tester.pumpAndSettle();

    final stored = await history.read();
    expect(stored.single.transactionId, 'txn-abandoned');
  });

  testWidgets('a cancelled run before any transaction records none', (
    tester,
  ) async {
    final backend = InMemoryHistoryBackend();
    final history = HistoryStore(backend: backend);

    await tester.pumpWidget(
      _run(present: (_) async => const PayCrossCancelled(), history: history),
    );
    await tester.pumpAndSettle();

    final stored = await history.read();
    expect(stored.single.transactionId, isNull);
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
    await tester.pumpWidget(
      _run(
        present: (_) async => _success('txn-9'),
        history: HistoryStore(backend: _ThrowingHistoryBackend()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Approved — €10.00, transaction txn-9'), findsOneWidget);
    expect(find.byKey(const ValueKey('copyBugReport')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the outcome announces itself to a screen reader', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(_run(present: (_) async => _success('txn-9')));
    await tester.pumpAndSettle();

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

    final mint = Completer<MintedSession>();
    final paid = Completer<PayCrossResult>();
    await tester.pumpWidget(
      _run(mint: (_) => mint.future, present: (_) => paid.future, e2e: true),
    );
    await tester.pump();
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
      Future<MintedSession> Function(String)? mint,
    }) async {
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
        PayCrossErrorCode.noActivity,
        'The plugin is not attached to an Activity.',
      ),
    );
    await settle(
      'an unexpected throw',
      (_) async => throw MissingPluginException('no implementation found'),
    );
    await settle(
      'a mint that failed',
      (_) async => _success('txn-9'),
      mint: (_) async => throw const MinterError('POST -> HTTP 401'),
    );

    semantics.dispose();
  });

  testWidgets('a version read that never answers still shows the outcome', (
    tester,
  ) async {
    await tester.pumpWidget(
      _run(
        present: (_) async => _success('txn-9'),
        readVersions: () => Completer<DemoVersions>().future,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Approved — €10.00, transaction txn-9'), findsOneWidget);
    expect(find.byKey(const ValueKey('copyBugReport')), findsNothing);

    await tester.pump(const Duration(seconds: 10));

    expect(find.byKey(const ValueKey('copyBugReport')), findsOneWidget);
  });

  testWidgets('a history write that never answers still shows the outcome', (
    tester,
  ) async {
    await tester.pumpWidget(
      _run(
        present: (_) async => _success('txn-9'),
        history: HistoryStore(backend: _HangingHistoryBackend()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Approved — €10.00, transaction txn-9'), findsOneWidget);

    await tester.pump(const Duration(seconds: 10));

    expect(find.byKey(const ValueKey('copyBugReport')), findsOneWidget);
  });

  testWidgets('a mint that failed offers no bug report to copy', (
    tester,
  ) async {
    await tester.pumpWidget(
      _run(
        mint: (_) async => throw const MinterError('POST -> HTTP 401'),
        present: (_) async => _success('txn-9'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('HTTP 401'), findsOneWidget);
    expect(find.byKey(const ValueKey('copyBugReport')), findsNothing);
  });

  testWidgets('a version read that throws is reported as unknown, not lost', (
    tester,
  ) async {
    final backend = InMemoryHistoryBackend();
    await tester.pumpWidget(
      _run(
        present: (_) async => _success('txn-9'),
        readVersions: () async => throw StateError('no package info'),
        history: HistoryStore(backend: backend),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Approved — €10.00, transaction txn-9'), findsOneWidget);
    final stored = HistoryEntry.fromJson(
      jsonDecode(backend.entries.single) as Map<String, Object?>,
    );
    expect(stored.demoVersion, 'unknown');
    expect(stored.pluginVersion, 'unknown');
    expect(stored.nativeSdkVersion, 'unknown');
  });

  testWidgets('an unexpected throw from the sheet is shown, not swallowed', (
    tester,
  ) async {
    await tester.pumpWidget(
      _run(
        present: (_) async =>
            throw MissingPluginException('no implementation found'),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(
        'The payment sheet failed unexpectedly: MissingPluginException',
      ),
      findsOneWidget,
    );
    expect(find.text('Done.'), findsOneWidget);
  });

  testWidgets('an unexpected throw carries no contract label', (tester) async {
    await tester.pumpWidget(
      _run(
        present: (_) async =>
            throw MissingPluginException('no implementation found'),
        e2e: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('e2eLabel')), findsNothing);
  });

  testWidgets('the body the screen was given is the body that is minted', (
    tester,
  ) async {
    String? sent;
    await tester.pumpWidget(
      MaterialApp(
        home: RunScreen(
          preset: _preset,
          body: '{"amount":2500,"currency":"USD"}',
          mintSession: (body) async {
            sent = body;
            return const MintedSession(
              id: 'sess-9',
              token: 'a-live-token',
              sentBody: '{}',
            );
          },
          present: (_) async => _success('txn-9'),
          history: HistoryStore(backend: InMemoryHistoryBackend()),
          readVersions: () async =>
              (demo: '0.1.0+7', plugin: '0.1.0', nativeSdk: 'unknown'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(sent, '{"amount":2500,"currency":"USD"}');
  });
  testWidgets('a Live run records no identity in History or its bug report', (
    tester,
  ) async {
    const identity = LiveIdentity(
      firstName: 'Ada',
      lastName: 'Lovelace',
      email: 'ada@example.org',
    );
    final preset = Preset(
      id: liveScenarioId(LiveScenario.smoke),
      name: liveScenarioName(LiveScenario.smoke),
      body: withLiveIdentity(liveDefaultBody(LiveScenario.smoke), identity),
      expected: liveScenarioExpectation(LiveScenario.smoke),
    );
    final backend = InMemoryHistoryBackend();
    expect(preset.body, contains('ada@example.org'));
    expect(preset.body, contains('Lovelace'));

    await tester.pumpWidget(
      MaterialApp(
        home: RunScreen(
          preset: preset,
          body: preset.body,
          live: true,
          mintSession: (body) async => const MintedSession(
            id: 'sess-live',
            token: 'a-live-token',
            sentBody: 'ignored',
          ),
          present: (_) async => _success('txn-1'),
          history: HistoryStore(backend: backend),
          readVersions: () async =>
              (demo: '0.1.0+7', plugin: '0.1.0', nativeSdk: 'unknown'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final stored = backend.entries.join('\n');
    expect(stored, isNotEmpty);
    expect(stored, isNot(contains('ada@example.org')));
    expect(stored, isNot(contains('Lovelace')));
  });

  testWidgets('a Live run says to refund it, and gives the transaction id', (
    tester,
  ) async {
    await tester.pumpWidget(
      _run(live: true, present: (_) async => _success('txn-live')),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('refundInstruction')), findsOneWidget);
    expect(find.textContaining('Refund this in the back office'), findsWidgets);
    expect(find.textContaining('txn-live'), findsWidgets);
    expect(find.byKey(const ValueKey('copyRefundId')), findsOneWidget);
  });

  testWidgets('a Live run with no transaction id falls back to the session', (
    tester,
  ) async {
    await tester.pumpWidget(
      _run(live: true, present: (_) async => const PayCrossCancelled()),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('refundInstruction')), findsOneWidget);
    expect(find.textContaining('No transaction id'), findsOneWidget);
    expect(find.textContaining('sess-9'), findsWidgets);
  });

  testWidgets('a Live mint that failed offers nothing to refund', (
    tester,
  ) async {
    await tester.pumpWidget(
      _run(
        live: true,
        mint: (_) async => throw const MinterError('POST -> HTTP 401'),
        present: (_) async => _success('never'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('refundInstruction')), findsNothing);
    expect(find.byKey(const ValueKey('runOutcome')), findsOneWidget);
    expect(find.textContaining('HTTP 401'), findsOneWidget);
  });

  testWidgets('a refused Live run is not told to refund itself', (
    tester,
  ) async {
    await tester.pumpWidget(
      _run(
        live: true,
        present: (_) async => const PayCrossFailure(
          transactionId: 'txn_declined',
          recovery: RecoveryDoNotRetry(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('refundInstruction')), findsOneWidget);
    expect(find.textContaining('Refund this in the back office'), findsNothing);
    expect(
      find.textContaining('nothing should have been captured'),
      findsOneWidget,
    );
    expect(find.textContaining('txn_declined'), findsWidgets);
    expect(find.byKey(const ValueKey('copyRefundId')), findsOneWidget);
  });

  testWidgets('a Test run says nothing about refunds', (tester) async {
    await tester.pumpWidget(_run(present: (_) async => _success('txn-9')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('refundInstruction')), findsNothing);
    expect(find.byKey(const ValueKey('runOutcome')), findsOneWidget);
    expect(find.textContaining('txn-9'), findsWidgets);
  });

  testWidgets('a Live run is written to history as a Live run', (tester) async {
    final backend = InMemoryHistoryBackend();
    await tester.pumpWidget(
      _run(
        live: true,
        history: HistoryStore(backend: backend),
        present: (_) async => _success('txn-live'),
      ),
    );
    await tester.pumpAndSettle();

    final row = jsonDecode(backend.entries.single) as Map<String, Object?>;
    expect(row['live'], isTrue);
  });

  testWidgets('the copy button puts the id on the clipboard', (tester) async {
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

    await tester.pumpWidget(
      _run(live: true, present: (_) async => _success('txn-live')),
    );
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('refundInstruction')),
        matching: find.textContaining('Transaction txn-live'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('copyRefundId')));
    await tester.pumpAndSettle();

    expect(copied, ['txn-live']);

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      _run(live: true, present: (_) async => const PayCrossCancelled()),
    );
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('refundInstruction')),
        matching: find.textContaining('Session sess-9'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('copyRefundId')));
    await tester.pumpAndSettle();

    expect(copied, ['txn-live', 'sess-9']);
  });
}
