import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/endpoints.dart';
import 'package:paycross_demo/demo/environment.dart';
import 'package:paycross_demo/demo/secrets.dart';
import 'package:paycross_flutter/paycross_flutter.dart';

import '_environment.dart';
import '_surface.dart';

/// Records what the app asked the SDK to be pointed at, and can be told to
/// refuse -- which is what `configure` does when a payment is in flight.
class _RecordingConfigure {
  final List<PayCrossEnvironment> calls = <PayCrossEnvironment>[];
  final List<String?> merchantIds = <String?>[];
  bool refuse = false;

  /// Runs inside the call, before the caller's `await` resumes. This is the
  /// only way to reach the window a switch is open across.
  void Function()? duringTheCall;

  /// Parks the call until it is completed, so a second switch can be
  /// attempted while the first is still in flight.
  Completer<void>? hold;

  Future<void> call({
    required PayCrossEnvironment environment,
    String? googlePayMerchantId,
  }) async {
    if (refuse) throw StateError('a payment is in flight');
    calls.add(environment);
    merchantIds.add(googlePayMerchantId);
    duringTheCall?.call();
    if (hold != null) await hold!.future;
  }
}

const Credentials _live = Credentials(
  clientId: 'live-id',
  clientSecret: 'live-secret',
);

void main() {
  test('a fresh state is Test, with no credentials and Test endpoints', () {
    // The whole of "every cold start begins in Test": the state is built at
    // launch and nothing reads it back from anywhere, so there is no stored
    // value that could say otherwise.
    final state = DemoEnvironmentState(configure: _RecordingConfigure().call);

    expect(state.environment, DemoEnvironment.test);
    expect(state.isLive, isFalse);
    expect(state.liveCredentials, isNull);
    expect(state.endpoints, same(testEndpoints));
  });

  test('the wrong word does not switch, and says what is wanted', () async {
    final configure = _RecordingConfigure();
    final state = DemoEnvironmentState(configure: configure.call);

    expect(await state.enterLive('live'), contains('LIVE'));
    expect(await state.enterLive(''), isNotNull);
    expect(await state.enterLive('LIVE please'), isNotNull);

    expect(state.environment, DemoEnvironment.test);
    // And nothing was pointed anywhere: a refused gate is not a round trip.
    expect(configure.calls, isEmpty);
  });

  test('the word switches, and points the SDK before it says so', () async {
    final configure = _RecordingConfigure();
    final state = DemoEnvironmentState(configure: configure.call);

    expect(await state.enterLive('LIVE'), isNull);

    expect(state.environment, DemoEnvironment.live);
    expect(state.endpoints, same(liveEndpoints));
    expect(configure.calls, [PayCrossEnvironment.production]);
    // Null, not the launch id: there is no Google Pay tile in Live for it
    // to serve, and a wallet id is merchant configuration for one wallet.
    expect(configure.merchantIds, [null]);
  });

  test('surrounding whitespace is forgiven; the word is not', () async {
    final state = DemoEnvironmentState(configure: _RecordingConfigure().call);

    expect(await state.enterLive('  LIVE  '), isNull);
    expect(state.isLive, isTrue);
  });

  test('an SDK that refuses to switch leaves the app in Test', () async {
    // Being on Test while the banner says LIVE is a lie; so is the reverse.
    // The flip happens only on proof.
    final configure = _RecordingConfigure()..refuse = true;
    final state = DemoEnvironmentState(configure: configure.call);

    expect(await state.enterLive('LIVE'), isNotNull);

    expect(state.environment, DemoEnvironment.test);
  });

  test('credentials are held only in Live', () async {
    final state = DemoEnvironmentState(configure: _RecordingConfigure().call);

    state.useForThisSession(_live);
    expect(state.liveCredentials, isNull, reason: 'not in Live');

    await state.enterLive('LIVE');
    state.useForThisSession(_live);
    expect(state.liveCredentials?.clientId, 'live-id');
  });

  test('a wallet id cannot ride along with a Live credential', () async {
    final state = DemoEnvironmentState(configure: _RecordingConfigure().call);
    await state.enterLive('LIVE');

    state.useForThisSession(
      const Credentials(
        clientId: 'live-id',
        clientSecret: 'live-secret',
        googlePayMerchantId: 'gp-1',
      ),
    );

    expect(state.liveCredentials?.googlePayMerchantId, isNull);
  });

  test(
    'leaving Live drops the credentials and restores the wallet id',
    () async {
      final configure = _RecordingConfigure();
      final state = DemoEnvironmentState(
        configure: configure.call,
        googlePayMerchantId: 'gp-launch',
      );
      await state.enterLive('LIVE');
      state.useForThisSession(_live);

      expect(await state.leaveLive(), isNull);

      expect(state.environment, DemoEnvironment.test);
      expect(state.liveCredentials, isNull);
      expect(configure.calls.last, PayCrossEnvironment.sandbox);
      expect(configure.merchantIds.last, 'gp-launch');
    },
  );

  test(
    'an exit the SDK refuses drops the credentials and stays Live',
    () async {
      // Two failure modes, two right answers. The credentials are the human's
      // to revoke instantly, so they go first and unconditionally. The
      // environment is a claim about where the SDK is pointed, so it flips
      // only on proof -- and staying in Live with the banner up is the
      // recoverable half of a bad situation.
      final configure = _RecordingConfigure();
      final state = DemoEnvironmentState(configure: configure.call);
      await state.enterLive('LIVE');
      state.useForThisSession(_live);
      configure.refuse = true;

      expect(await state.leaveLive(), isNotNull);

      expect(state.liveCredentials, isNull);
      expect(state.environment, DemoEnvironment.live);
    },
  );

  test('every change tells its listeners', () async {
    final state = DemoEnvironmentState(configure: _RecordingConfigure().call);
    var heard = 0;
    state.addListener(() => heard++);

    await state.enterLive('LIVE');
    state.useForThisSession(_live);
    await state.leaveLive();

    // Three: the banner, the Settings surface and Home's grid all redraw
    // from these, and a missed notify is a screen that says Test on
    // production.
    expect(heard, 3);
  });
  test(
    'credentials armed while leaving Live do not survive the exit',
    () async {
      // The window is real: leaveLive drops the credentials, then awaits the
      // SDK, and until that await comes back the state still says Live. A tap
      // on the button that hands over credentials lands in that window, and
      // what it armed used to outlive the exit -- production credentials in
      // memory, in Test, under no banner.
      final configure = _RecordingConfigure();
      final state = DemoEnvironmentState(configure: configure.call);
      await state.enterLive('LIVE');
      configure.duringTheCall = () => state.useForThisSession(_live);

      expect(await state.leaveLive(), isNull);

      expect(state.environment, DemoEnvironment.test);
      expect(state.liveCredentials, isNull);

      // And re-entering Live must not resurrect them. Hiding them behind the
      // environment is not enough on its own: without dropping the reference
      // too, the next enterLive hands back a credential the human already
      // asked to forget.
      configure.duringTheCall = null;
      await state.enterLive('LIVE');
      expect(state.liveCredentials, isNull);
    },
  );

  test('a second switch while one is in flight is refused', () async {
    // Two switches racing end with the banner and the SDK disagreeing: the
    // last configure to land decides where payments go, the last assignment
    // to land decides what the screen says, and nothing makes those the same
    // call.
    final configure = _RecordingConfigure();
    final state = DemoEnvironmentState(configure: configure.call);
    configure.hold = Completer<void>();

    final entering = state.enterLive('LIVE');
    final refused = await state.leaveLive();

    expect(refused, isNotNull);

    configure.hold!.complete();
    expect(await entering, isNull);

    expect(state.isLive, isTrue);
    // One call, not two: the refused switch never reached the SDK.
    expect(configure.calls, [PayCrossEnvironment.production]);
  });

  test('a refused switch does not touch the credentials', () async {
    // leaveLive drops the credentials before it does anything else, so the
    // guard has to come first or a refused exit would still forget them.
    final configure = _RecordingConfigure();
    final state = DemoEnvironmentState(configure: configure.call);
    await state.enterLive('LIVE');
    state.useForThisSession(_live);
    configure.hold = Completer<void>();

    final entering = state.enterLive('LIVE');
    expect(await state.leaveLive(), isNotNull);

    expect(state.liveCredentials?.clientId, 'live-id');

    configure.hold!.complete();
    await entering;
  });

  group('LiveModeScope', () {
    testWidgets('Test shows no banner', (tester) async {
      await tester.pumpWidget(
        appWithEnvironment(
          home: const Scaffold(body: Text('a screen')),
          state: fakeEnvironment(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('liveBanner')), findsNothing);
      expect(find.text('a screen'), findsOneWidget);
    });

    testWidgets('Live shows the banner, and says what it means', (
      tester,
    ) async {
      await tester.pumpWidget(
        await liveApp(home: const Scaffold(body: Text('a screen'))),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('liveBanner')), findsOneWidget);
      expect(find.text('LIVE — REAL MONEY'), findsOneWidget);
      expect(find.text('a screen'), findsOneWidget);
    });

    testWidgets('the banner appears the moment the state says Live', (
      tester,
    ) async {
      final state = fakeEnvironment();
      await tester.pumpWidget(
        appWithEnvironment(
          home: const Scaffold(body: Text('a screen')),
          state: state,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('liveBanner')), findsNothing);

      await state.enterLive(liveConfirmationWord);
      await tester.pumpAndSettle();

      // No setState anywhere: the scope listens to the notifier, which is
      // what makes the banner arrive on every route at once.
      expect(find.byKey(const ValueKey('liveBanner')), findsOneWidget);
    });

    testWidgets('a pushed route is under the same banner', (tester) async {
      // The whole reason the scope is mounted in `builder`. Settings,
      // History and a Run screen are all pushed routes, and a scope inside
      // `home:` would be invisible to every one of them.
      await tester.pumpWidget(
        await liveApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const Scaffold(body: Text('pushed')),
                  ),
                ),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      expect(find.text('pushed'), findsOneWidget);
      expect(find.byKey(const ValueKey('liveBanner')), findsOneWidget);
    });

    testWidgets('a screen with no scope over it is Test', (tester) async {
      // Every widget test written before this plan pumps a bare MaterialApp,
      // and every one of them must keep meaning what it meant. Absent scope
      // reads as Test, which is also what the automation build gets.
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('a screen'))),
      );
      await tester.pumpAndSettle();

      final context = tester.element(find.text('a screen'));
      expect(LiveModeScope.maybeOf(context), isNull);
      expect(LiveModeScope.environmentOf(context), DemoEnvironment.test);
    });

    testWidgets('the banner does not push the screen off a phone', (
      tester,
    ) async {
      usePhoneSurface(tester);
      // A real notch, because without one this asserts nothing: the SafeArea
      // has no inset to take and removePadding has none to remove, so the
      // double gap the pair exists to prevent cannot appear either way.
      tester.view.viewPadding = const FakeViewPadding(top: 47);
      tester.view.padding = const FakeViewPadding(top: 47);

      await tester.pumpWidget(
        await liveApp(home: const Scaffold(body: Text('a screen'))),
      );
      await tester.pumpAndSettle();

      // The banner sits outside every Scaffold, so without the inset handling
      // the Scaffold below pads for the status bar a second time and the
      // result is a visible double gap. An overflow is an exception here.
      expect(tester.takeException(), isNull);
      // The banner cleared the notch,
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('liveBanner'))).dy,
        greaterThan(47.0),
      );
      // and the screen below is not asked to clear it a second time.
      expect(
        MediaQuery.of(tester.element(find.text('a screen'))).padding.top,
        0,
      );
    });
  });
}
