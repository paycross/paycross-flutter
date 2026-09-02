import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/history.dart';
import 'package:paycross_demo/demo/minter.dart';
import 'package:paycross_demo/demo/presets.dart';
import 'package:paycross_demo/demo/surface.dart';
import 'package:paycross_demo/demo/web_run.dart';

import '_surface.dart';

final _preset = demoPresets.first;

/// The shape of a real checkout URL, with a token-shaped tail.
///
/// A stand-in, and it has to be one: the real thing is
/// `…/pay?session=<token>`, so a fixture holding a live value would be the
/// leak this feature is written to avoid. What matters to these tests is
/// that the tail is distinctive enough for a finder to prove it is *not* on
/// screen, in History or in a bug report.
const String _url = 'https://pay.example.com/pay?session=NOT-A-REAL-TOKEN';

/// Records every URL it was handed and answers what a test told it to.
class _Launcher {
  _Launcher({this.answer = true, this.throws = false});

  final bool answer;
  final bool throws;
  final List<Uri> opened = <Uri>[];

  Future<bool> call(Uri url) async {
    opened.add(url);
    if (throws) {
      throw StateError('MissingPluginException: no url_launcher on this build');
    }
    return answer;
  }
}

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

MintedSession _minted({String? checkoutUrl = _url}) => MintedSession(
  id: 'sess-9',
  token: 'a-session-token',
  sentBody: '{}',
  checkoutUrl: checkoutUrl,
);

Widget _screen({
  Future<MintedSession> Function(String)? mint,
  _Launcher? launcher,
  HistoryStore? history,
  bool live = false,
}) => MaterialApp(
  home: WebCheckoutRunScreen(
    preset: _preset,
    body: _preset.body,
    live: live,
    mintSession: mint ?? (_) async => _minted(),
    launch: (launcher ?? _Launcher()).call,
    history: history ?? HistoryStore(backend: InMemoryHistoryBackend()),
    readVersions: () async =>
        (demo: '0.1.4+1', plugin: '0.1.0', nativeSdk: 'unknown'),
  ),
);

void main() {
  group('which strings are a page this app will open', () {
    test('an https page is one', () {
      expect(checkoutUri(_url)?.scheme, 'https');
    });

    test('a plain http page is one too', () {
      // The sandbox is reachable over http on a developer machine, and
      // refusing it would refuse the environment this surface is tested in.
      expect(checkoutUri('http://localhost:8080/pay')?.scheme, 'http');
    });

    test('nothing at all is not a page', () {
      expect(checkoutUri(null), isNull);
      expect(checkoutUri(''), isNull);
    });

    test('a scheme that is not the web is refused', () {
      // The load-bearing case. `launchUrl` with `externalApplication` hands
      // whatever it is given to the platform, so a non-web scheme arriving
      // in a response field would be this app opening an arbitrary
      // application on somebody's phone on the strength of a JSON string.
      expect(checkoutUri('myapp://pay'), isNull);
      expect(checkoutUri('file:///etc/passwd'), isNull);
      expect(checkoutUri('javascript:alert(1)'), isNull);
      expect(checkoutUri('intent://scan#Intent;scheme=zxing;end'), isNull);
    });

    test('a string with no host is not a page', () {
      expect(checkoutUri('https:///pay'), isNull);
      expect(checkoutUri('not a url at all'), isNull);
    });
  });

  group('a session the browser took', () {
    testWidgets('hands the page over and says so without claiming a payment', (
      tester,
    ) async {
      final launcher = _Launcher();

      await tester.pumpWidget(_screen(launcher: launcher));
      await tester.pumpAndSettle();

      expect(launcher.opened.single.toString(), _url);
      expect(find.text('Handed over.'), findsOneWidget);
      expect(find.textContaining('Finish the payment there'), findsOneWidget);
      expect(find.textContaining('back office'), findsOneWidget);
      expect(find.text('Session sess-9'), findsOneWidget);
      // The whole discipline of this screen in one line: it says what the
      // app did, and says outright that it does not know what the payment
      // did. (The preset's own "Expected:" line further down the screen is
      // free to say "Approved" -- that is the scenario, not an outcome.)
      expect(
        find.textContaining('does not learn what happened'),
        findsOneWidget,
      );
    });

    testWidgets('offers the session id as something to copy', (tester) async {
      await tester.pumpWidget(_screen());
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('copySessionId')), findsOneWidget);
    });

    testWidgets('records the run as web, with no outcome it did not see', (
      tester,
    ) async {
      final backend = InMemoryHistoryBackend();

      await tester.pumpWidget(_screen(history: HistoryStore(backend: backend)));
      await tester.pumpAndSettle();

      final rows = await HistoryStore(backend: backend).read();
      expect(rows.single.sessionId, 'sess-9');
      expect(rows.single.surface, webSurfaceName);
      expect(rows.single.isWeb, isTrue);
      expect(rows.single.outcome, webOpenedOutcome);
      // There is no transaction, and there will not be one: a transaction is
      // created by the payment, and the payment is happening in another app.
      expect(rows.single.transactionId, isNull);
    });

    testWidgets('never lets the URL reach the screen, History or a report', (
      tester,
    ) async {
      // The URL is `…/pay?session=<token>`, so this is the token rule
      // spelled a different way. Asserted at all three exits at once, since
      // a leak into any one of them is the same leak.
      final backend = InMemoryHistoryBackend();

      await tester.pumpWidget(_screen(history: HistoryStore(backend: backend)));
      await tester.pumpAndSettle();

      expect(find.textContaining('NOT-A-REAL-TOKEN'), findsNothing);
      expect(find.textContaining('pay.example.com'), findsNothing);
      expect(backend.entries.join(), isNot(contains('NOT-A-REAL-TOKEN')));
      final rows = await HistoryStore(backend: backend).read();
      expect(bugReport(rows.single), isNot(contains('NOT-A-REAL-TOKEN')));
      expect(bugReport(rows.single), isNot(contains('pay.example.com')));
    });

    testWidgets('says in the report that the app never saw the result', (
      tester,
    ) async {
      final backend = InMemoryHistoryBackend();

      await tester.pumpWidget(_screen(history: HistoryStore(backend: backend)));
      await tester.pumpAndSettle();

      final rows = await HistoryStore(backend: backend).read();
      expect(bugReport(rows.single), contains('web checkout in the browser'));
    });
  });

  group('the ways it does not open', () {
    testWidgets('a mint that refused leaves no session and no row', (
      tester,
    ) async {
      final backend = InMemoryHistoryBackend();

      await tester.pumpWidget(
        _screen(
          mint: (_) async => throw const MinterError('HTTP 401 from /token.'),
          history: HistoryStore(backend: backend),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Could not mint a session.'), findsOneWidget);
      expect(find.textContaining('HTTP 401'), findsOneWidget);
      // Nothing was created, so there is no id to look up and nothing that
      // could have taken money.
      expect(backend.entries, isEmpty);
    });

    testWidgets('a session with no page is refused in the app itself', (
      tester,
    ) async {
      final launcher = _Launcher();
      final backend = InMemoryHistoryBackend();

      await tester.pumpWidget(
        _screen(
          mint: (_) async => _minted(checkoutUrl: null),
          launcher: launcher,
          history: HistoryStore(backend: backend),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining(noCheckoutUrlMessage), findsOneWidget);
      expect(launcher.opened, isEmpty);
      expect(backend.entries, isEmpty);
      // Still the only handle on what was created, so it stays on screen.
      expect(find.text('Session sess-9'), findsOneWidget);
    });

    testWidgets('a page in a scheme this app will not open is refused too', (
      tester,
    ) async {
      final launcher = _Launcher();

      await tester.pumpWidget(
        _screen(
          mint: (_) async => _minted(checkoutUrl: 'myapp://pay?session=x'),
          launcher: launcher,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining(noCheckoutUrlMessage), findsOneWidget);
      expect(launcher.opened, isEmpty);
    });

    testWidgets('a browser that would not take it is reported, with the id', (
      tester,
    ) async {
      final backend = InMemoryHistoryBackend();

      await tester.pumpWidget(
        _screen(
          launcher: _Launcher(answer: false),
          history: HistoryStore(backend: backend),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Not opened.'), findsOneWidget);
      expect(find.textContaining('Nothing was paid'), findsOneWidget);
      expect(find.text('Session sess-9'), findsOneWidget);

      final rows = await HistoryStore(backend: backend).read();
      expect(rows.single.outcome, webLaunchFailedOutcome);
      expect(rows.single.surface, webSurfaceName);
    });

    testWidgets('a launcher that throws does not strand the screen', (
      tester,
    ) async {
      // A plugin that is not registered on this build throws rather than
      // answering false. Unhandled it would leave the screen on "Opening the
      // browser…" for good.
      final backend = InMemoryHistoryBackend();

      await tester.pumpWidget(
        _screen(
          launcher: _Launcher(throws: true),
          history: HistoryStore(backend: backend),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Not opened.'), findsOneWidget);
      expect(find.text('Session sess-9'), findsOneWidget);
      // The type only. A platform exception is free to quote the URL it was
      // handed, and that URL is a credential.
      expect(find.textContaining('StateError'), findsOneWidget);
      expect(find.textContaining('NOT-A-REAL-TOKEN'), findsNothing);
      expect(find.textContaining('MissingPluginException'), findsNothing);

      final rows = await HistoryStore(backend: backend).read();
      expect(rows.single.outcome, webLaunchFailedOutcome);
    });
  });

  group('what the screen owes a person who may already be paying', () {
    testWidgets('a History store that throws does not cost the session id', (
      tester,
    ) async {
      await tester.pumpWidget(
        _screen(history: HistoryStore(backend: _ThrowingHistoryBackend())),
      );
      await tester.pumpAndSettle();

      expect(find.text('Handed over.'), findsOneWidget);
      expect(find.text('Session sess-9'), findsOneWidget);
    });

    testWidgets('a History store that never answers does not either', (
      tester,
    ) async {
      await tester.pumpWidget(
        _screen(history: HistoryStore(backend: _HangingHistoryBackend())),
      );
      // Past the hand-over and up to the bookkeeping deadline, which is what
      // lets the bug-report button appear at all on a wedged store.
      await tester.pump();
      await tester.pump();

      expect(find.text('Handed over.'), findsOneWidget);
      expect(find.text('Session sess-9'), findsOneWidget);

      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('copyBugReport')), findsOneWidget);
    });
  });

  group('a Live web run', () {
    testWidgets('names the session id in a red block, having no transaction', (
      tester,
    ) async {
      useTallSurface(tester);

      await tester.pumpWidget(_screen(live: true));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('refundInstruction')), findsOneWidget);
      expect(find.textContaining('No transaction id'), findsOneWidget);
      expect(find.textContaining('sess-9'), findsWidgets);
      expect(
        find.textContaining('refund anything it captured'),
        findsOneWidget,
      );
    });

    testWidgets('a Live run that never opened asks for a look, not a refund', (
      tester,
    ) async {
      // "Go and refund this" on a run that opened no browser would be noise
      // on the commonest way this surface fails.
      useTallSurface(tester);

      await tester.pumpWidget(
        _screen(live: true, launcher: _Launcher(answer: false)),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('refundInstruction')), findsOneWidget);
      expect(find.textContaining('Nothing was opened'), findsOneWidget);
      expect(find.textContaining('refund anything it captured'), findsNothing);
    });

    testWidgets('a sandbox run has no red block at all', (tester) async {
      await tester.pumpWidget(_screen());
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('refundInstruction')), findsNothing);
    });

    testWidgets('the row it writes is marked Live', (tester) async {
      useTallSurface(tester);
      final backend = InMemoryHistoryBackend();

      await tester.pumpWidget(
        _screen(live: true, history: HistoryStore(backend: backend)),
      );
      await tester.pumpAndSettle();

      final rows = await HistoryStore(backend: backend).read();
      expect(rows.single.live, isTrue);
      expect(rows.single.surface, webSurfaceName);
    });
  });

  testWidgets('it carries no automation label, on any build', (tester) async {
    // By construction rather than by rule: the matrix runner drives the deep
    // link, the deep link never selects this surface, and a screen with no
    // label cannot pass a cell it never reached.
    await tester.pumpWidget(_screen());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('e2eLabel')), findsNothing);
  });
}
