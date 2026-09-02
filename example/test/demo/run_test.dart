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

/// A history whose writes fail, which is what a full or unwritable store
/// looks like from Dart.
class _ThrowingHistoryBackend implements HistoryBackend {
  @override
  Future<List<String>> read() async => const <String>[];

  @override
  Future<void> write(List<String> entries) async =>
      throw StateError('no store');
}

/// A history whose write never answers, which is what a store wedged behind
/// a stuck platform channel looks like from Dart.
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

    expect(find.text('Approved — €10.00, transaction txn-9'), findsOneWidget);
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
      _run(mint: (_) => mint.future, present: (_) => paid.future, e2e: true),
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
      Future<MintedSession> Function(String)? mint,
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
    // Bookkeeping must never gate the result of a payment that has already
    // happened. The outcome is on screen before the version read is even
    // asked for; what the read gates is only the bug report.
    await tester.pumpWidget(
      _run(
        present: (_) async => _success('txn-9'),
        readVersions: () => Completer<DemoVersions>().future,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Approved — €10.00, transaction txn-9'), findsOneWidget);
    expect(find.byKey(const ValueKey('copyBugReport')), findsNothing);

    // And the read is not allowed to hang for good: the timeout hands back
    // "unknown" versions, so the report becomes copyable anyway.
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

    // The entry exists in memory whether or not it reached the store, so the
    // report is copyable once the write has been given up on.
    expect(find.byKey(const ValueKey('copyBugReport')), findsOneWidget);
  });

  testWidgets('a mint that failed offers no bug report to copy', (
    tester,
  ) async {
    // There is no session and no entry, so there is nothing to quote. A
    // button that copied a half-filled report would be worse than none.
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
    // The plugin documents that only a PayCrossIntegrationError escapes
    // `presentPayment`, and MissingPluginException is the counterexample it
    // cannot rule out: it is not a PlatformException, so the plugin's own
    // guard does not convert it. Unhandled, it left the screen on "Waiting
    // for the payment sheet…" forever after a payment that may have charged.
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
    // There is no outcome to name, so there is nothing the runner could
    // honestly compare. A label invented here would be a cell that passed on
    // a run that never reached the sheet.
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
    // `body` is what the editor hands back, and it is the whole point of the
    // editor: an edited amount that never reached the mint would be a screen
    // that quietly ran the preset instead of what was typed.
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
    // The body that is minted carries a real person's name and address. The
    // history row and the bug-report block are the two things that outlive
    // the run -- one on the device, one on a clipboard headed for a ticket
    // -- and neither may carry either.
    const identity = LiveIdentity(
      firstName: 'Ada',
      lastName: 'Lovelace',
      email: 'ada@example.org',
    );
    final preset = livePreset(
      LiveScenario.smoke,
      identity,
      liveDefaultCurrency,
    );
    final backend = InMemoryHistoryBackend();
    // The precondition this case rests on: the body really does contain
    // both, so finding neither downstream means something.
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
    // Cancelled sheet, thrown error, timeout mid-poll: one of the two ids
    // always exists, because the session is minted before the sheet opens.
    // The money is findable either way, and that is the whole point of this
    // block.
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
    // No id at all -- and also no charge, so there is nothing to refund. The
    // ordinary scrubbed error is the whole story.
    await tester.pumpWidget(
      _run(
        live: true,
        mint: (_) async => throw const MinterError('POST -> HTTP 401'),
        present: (_) async => _success('never'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('refundInstruction')), findsNothing);
    // Not vacuous: the outcome card itself IS on screen, so the block above
    // was skipped by its own guard rather than by there being no card to put
    // it in.
    expect(find.byKey(const ValueKey('runOutcome')), findsOneWidget);
    expect(find.textContaining('HTTP 401'), findsOneWidget);
  });

  testWidgets('a refused Live run is not told to refund itself', (
    tester,
  ) async {
    // A decline carries a transaction id, so it satisfies the block's guard
    // -- and "Refund this in the back office now." then sends somebody to
    // look for a charge that is not there. A declined smoke is an ordinary
    // first result on a real card, so this would fire early and often, and
    // this is the one red block in the app whose whole value is that it is
    // never noise.
    //
    // Not suppressed, though: the SDK saying "refused" is not proof that no
    // money moved -- an auth that took and a capture that failed look like
    // this too -- so the id and the copy button stay exactly where they are
    // and only the claim changes.
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
    // The id a lookup needs, and the button that copies it, are the half of
    // this block that is right on a decline.
    expect(find.textContaining('txn_declined'), findsWidgets);
    expect(find.byKey(const ValueKey('copyRefundId')), findsOneWidget);
  });

  testWidgets('a Test run says nothing about refunds', (tester) async {
    await tester.pumpWidget(_run(present: (_) async => _success('txn-9')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('refundInstruction')), findsNothing);
    // Same guard against a vacuous findsNothing: everything the Live version
    // of this run would have rendered the block beside is here.
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
    // The id is what a refund needs, and retyping a transaction id off a
    // phone screen is how a refund lands on the wrong charge.
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

    // Inside the block, not anywhere on screen: the outcome card prints its
    // own `Session sess-9` and `Transaction txn-live` lines above this, and
    // a finder that matched those would pass with the block showing either.
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

    // And the other branch, in the same case on purpose: the display and the
    // clipboard are two separate expressions of one rule, and a screen that
    // shows one id while copying the other is exactly how a refund lands on
    // the wrong charge.
    //
    // Torn down first. Pumping a second `_run` straight over the first is a
    // widget UPDATE at the same position, not a new screen -- `initState`
    // never runs again and the first run's transaction id stays on screen.
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
