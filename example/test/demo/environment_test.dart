import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/endpoints.dart';
import 'package:paycross_demo/demo/environment.dart';
import 'package:paycross_demo/demo/live.dart';
import 'package:paycross_demo/demo/secrets.dart';
import 'package:paycross_demo/demo/wallets.dart';
import 'package:paycross_flutter/paycross_flutter.dart';

import '_environment.dart';
import '_surface.dart';

/// Records what the app asked the SDK to be pointed at, and can be told to
/// refuse -- which is what `configure` does when a payment is in flight.
class _RecordingConfigure {
  final List<PayCrossEnvironment> calls = <PayCrossEnvironment>[];
  final List<String?> merchantIds = <String?>[];

  /// The Apple identifier of each call, in its own list beside the Google
  /// one so a fix that remembers one wallet and forgets the other reads as
  /// two different lists rather than as one list that happens to be right.
  final List<String?> appleMerchantIds = <String?>[];
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
    String? applePayMerchantId,
  }) async {
    // Before the refusal, not after: this models a button being tapped while
    // the SDK call is in flight, and that happens whether the call goes on to
    // succeed or to throw. `calls` still records only the ones that did not.
    duringTheCall?.call();
    if (refuse) throw StateError('a payment is in flight');
    calls.add(environment);
    merchantIds.add(googlePayMerchantId);
    appleMerchantIds.add(applePayMerchantId);
    if (hold != null) await hold!.future;
  }
}

const Credentials _live = Credentials(
  clientId: 'live-id',
  clientSecret: 'live-secret',
);

/// The IANA-reserved documentation domain. No test in this plan holds an
/// address that could belong to anybody.
const LiveIdentity _identity = LiveIdentity(
  firstName: 'Ada',
  lastName: 'Lovelace',
  email: 'ada@example.org',
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
    expect(state.liveIdentity, isNull);
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
    // Null, and not because Live has no wallets -- it has its own Apple
    // identifier, asserted below. Google's production merchant id is the one
    // value the owner has still to supply, so the constant is empty and
    // `walletIdOrNull` turns that into the null the SDK reads as "no button".
    expect(configure.merchantIds, [walletIdOrNull(liveGooglePayMerchantId)]);
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

  test('an identity is held only in Live', () async {
    final state = fakeEnvironment();

    // In Test the setter does nothing at all -- the same rule
    // `useForThisSession` follows, and for the same reason: it is reachable
    // only from a button that exists only in Live, so a Test-mode call is a
    // programming mistake and holding nothing is the safe answer.
    state.useIdentityForThisSession(_identity);
    expect(state.liveIdentity, isNull);

    await state.enterLive(liveConfirmationWord);
    state.useIdentityForThisSession(_identity);
    expect(state.liveIdentity?.email, 'ada@example.org');
    expect(state.liveIdentity?.firstName, 'Ada');
  });

  test('what a session holds is a credential and an identity, and no more', () {
    // This state also held a currency, set by the same button as the
    // identity, and the owner's word for that was "a lazy workaround": the
    // amount lived in a constant and the currency lived here, so the two
    // halves of one figure were set on two different screens. Both are
    // fields of the preset body now.
    //
    // Pinned as a set rather than by one absence, so the next thing that
    // tries to live for a session -- an amount, a transaction type -- has to
    // be argued for here first.
    final state = DemoEnvironmentState(configure: _RecordingConfigure().call);

    expect(state.liveCredentials, isNull);
    expect(state.liveIdentity, isNull);
    // The two setters that exist, and there is no third. A currency setter
    // would not compile against this file.
    expect(state.useForThisSession, isNotNull);
    expect(state.useIdentityForThisSession, isNotNull);
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
      state.useIdentityForThisSession(_identity);

      expect(await state.leaveLive(), isNull);

      expect(state.environment, DemoEnvironment.test);
      expect(state.liveCredentials, isNull);
      expect(state.liveIdentity, isNull);
      expect(configure.calls.last, PayCrossEnvironment.sandbox);
      expect(configure.merchantIds.last, 'gp-launch');
    },
  );

  group('the wallet identifiers', () {
    test('a state carries the Test identifier it was launched with', () async {
      final configure = _RecordingConfigure();
      final state = DemoEnvironmentState(
        configure: configure.call,
        applePayMerchantId: testApplePayMerchantId,
      );

      expect(state.applePayMerchantId, testApplePayMerchantId);
      // The first time this state points the SDK anywhere it points it at
      // Test, and the identifier `main` configured at launch has to travel
      // with it: re-pointing the SDK replaces the whole configuration, so an
      // identifier left out of a Test configure is a button that is gone.
      expect(await state.leaveLive(), isNull);

      expect(configure.calls.single, PayCrossEnvironment.sandbox);
      expect(configure.appleMerchantIds.single, testApplePayMerchantId);
    });

    test('entering Live sends the production Apple identifier', () async {
      final configure = _RecordingConfigure();
      final state = DemoEnvironmentState(
        configure: configure.call,
        applePayMerchantId: testApplePayMerchantId,
      );

      expect(await state.enterLive(liveConfirmationWord), isNull);

      // The literal on purpose. This is the string a real production payment
      // is encrypted under, and the same assertion written as
      // `walletIdOrNull(liveApplePayMerchantId)` would keep passing on the
      // day somebody replaced the constant with something that is not
      // registered with Apple.
      expect(configure.appleMerchantIds.single, 'merchant.pay-cross.com.prod');
    });

    test('entering Live sends the production Google identifier', () async {
      final configure = _RecordingConfigure();
      final state = DemoEnvironmentState(configure: configure.call);

      expect(await state.enterLive(liveConfirmationWord), isNull);

      // Against the constant rather than against null, so this test still
      // says what it means on the day the owner supplies the id: what is
      // pinned is that Live is configured from Live's own constant, not that
      // Google's wallet happens to be unconfigured today.
      expect(
        configure.merchantIds.single,
        walletIdOrNull(liveGooglePayMerchantId),
      );
    });

    test('entering Live never sends the Test Apple identifier', () async {
      final configure = _RecordingConfigure();
      final state = DemoEnvironmentState(
        configure: configure.call,
        applePayMerchantId: testApplePayMerchantId,
      );

      expect(await state.enterLive(liveConfirmationWord), isNull);

      // The leak guard, and the reason the demo holds two constants rather
      // than passing one field through: a production token minted under the
      // TEST identifier is encrypted to the TEST key, and no vault on
      // production can decrypt it. This is the case that would still pass if
      // somebody "simplified" the test above into forwarding the field.
      expect(
        configure.appleMerchantIds,
        isNot(contains(testApplePayMerchantId)),
      );
    });

    test('a round trip through Live restores both identifiers', () async {
      final configure = _RecordingConfigure();
      final state = DemoEnvironmentState(
        configure: configure.call,
        googlePayMerchantId: 'gp-launch',
        applePayMerchantId: testApplePayMerchantId,
      );

      expect(await state.enterLive(liveConfirmationWord), isNull);
      expect(await state.leaveLive(), isNull);

      // The whole recording, in order, rather than the way there or the way
      // back alone. Asserting only on entering Live passes against a
      // `leaveLive` that forgets, and the symptom of that bug is a button
      // that is present, then absent, and stays absent until the app is
      // relaunched -- which nobody reads as a configuration bug.
      expect(configure.calls, [
        PayCrossEnvironment.production,
        PayCrossEnvironment.sandbox,
      ]);
      expect(configure.appleMerchantIds, [
        liveApplePayMerchantId,
        testApplePayMerchantId,
      ]);
    });

    test(
      'the way back restores the Google identifier in the same call',
      () async {
        final configure = _RecordingConfigure();
        final state = DemoEnvironmentState(
          configure: configure.call,
          googlePayMerchantId: 'gp-launch',
          applePayMerchantId: testApplePayMerchantId,
        );

        await state.enterLive(liveConfirmationWord);
        expect(await state.leaveLive(), isNull);

        // One recording, both wallets, so a fix that restores one and forgets
        // the other fails here rather than passing two tests out of three.
        expect(configure.appleMerchantIds.last, testApplePayMerchantId);
        expect(configure.merchantIds.last, 'gp-launch');
      },
    );
  });

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
      state.useIdentityForThisSession(_identity);
      configure.refuse = true;

      expect(await state.leaveLive(), isNotNull);

      expect(state.liveCredentials, isNull);
      // Armed before the call, so what this pins is the drop at the top of
      // `leaveLive` -- the one before `_switching = true`. The drop inside
      // the `catch` is guarded by *an exit that fails still forgets what the
      // window armed*, which is the only case that reaches it holding
      // anything.
      expect(state.liveIdentity, isNull);
      expect(state.environment, DemoEnvironment.live);
    },
  );

  test('every change tells its listeners', () async {
    final state = DemoEnvironmentState(configure: _RecordingConfigure().call);
    var heard = 0;
    state.addListener(() => heard++);

    await state.enterLive('LIVE');
    state.useForThisSession(_live);
    state.useIdentityForThisSession(_identity);
    await state.leaveLive();

    // Four: the banner, the Settings surface and Home's grid all redraw
    // from these, and a missed notify is a screen that says Test on
    // production. Holding the identity is one of them -- the Live tile
    // stops refusing the moment it lands. It was five while a currency was
    // held for the session too; that is a field of the preset body now, so
    // there is one fewer thing to notify about.
    expect(heard, 4);
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

  test('an exit that fails still forgets what the window armed', () async {
    // The failure branch promises "the credentials are forgotten". It has to
    // be true when it is said: the app stays in Live on this path, so the
    // getter's gate hides nothing, and the drop at the top of the method
    // already happened before the window opened.
    final configure = _RecordingConfigure();
    final state = DemoEnvironmentState(configure: configure.call);
    await state.enterLive('LIVE');
    // Two statements, not a cascade: `..refuse` after an arrow body binds to
    // the closure's void result rather than to `configure`.
    configure.duringTheCall = () {
      state.useForThisSession(_live);
      state.useIdentityForThisSession(_identity);
    };
    configure.refuse = true;

    final said = await state.leaveLive();

    expect(said, contains('Still in Live'));
    expect(state.isLive, isTrue);
    expect(state.liveCredentials, isNull);
    // Armed inside the window, so this is the one case that reaches the
    // `catch` holding an identity -- and therefore the one that guards the
    // drop there.
    expect(state.liveIdentity, isNull);
  });

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
    testWidgets('a state that was passed in outlives the scope', (
      tester,
    ) async {
      // Disposing it here would take it out from under whoever passed it: in
      // a test, one that is still asserting on it; in the app, a state that
      // is meant to outlive one subtree.
      final state = fakeEnvironment();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        appWithEnvironment(
          home: const Scaffold(body: Text('a screen')),
          state: state,
        ),
      );
      await tester.pumpAndSettle();

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();

      expect(() => state.addListener(() {}), returnsNormally);
    });

    testWidgets('a state the scope made is disposed with it', (tester) async {
      // The other half of the same rule. The one this widget owns has no
      // other owner, so leaving it alive is a leak.
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => LiveModeScope(child: child!),
          home: const Scaffold(body: Text('a screen')),
        ),
      );
      await tester.pumpAndSettle();
      final own = LiveModeScope.maybeOf(tester.element(find.text('a screen')));
      expect(own, isNotNull);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();

      expect(() => own!.addListener(() {}), throwsFlutterError);
    });

    testWidgets('readOf finds the same state without subscribing to it', (
      tester,
    ) async {
      // The deep-link callback reads the environment outside build. If that
      // read registered a dependency, every credential change would rebuild
      // a widget that only ever wanted to look once.
      //
      // Already in Live before the first pump, on purpose: a Test-to-Live
      // switch reparents the whole subtree under the banner, which rebuilds
      // both builders and would prove nothing about either.
      final state = fakeEnvironment();
      await state.enterLive(liveConfirmationWord);
      addTearDown(state.dispose);
      var reads = 0;
      var watches = 0;
      DemoEnvironmentState? read;
      DemoEnvironmentState? watched;

      await tester.pumpWidget(
        appWithEnvironment(
          state: state,
          home: Scaffold(
            body: Column(
              children: [
                Builder(
                  builder: (context) {
                    reads++;
                    read = LiveModeScope.readOf(context);
                    return const Text('reader');
                  },
                ),
                Builder(
                  builder: (context) {
                    watches++;
                    watched = LiveModeScope.maybeOf(context);
                    return const Text('watcher');
                  },
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(read, same(state));
      expect(watched, same(state));
      expect(reads, 1);
      expect(watches, 1);

      state.useForThisSession(
        const Credentials(clientId: 'live-id', clientSecret: 'live-secret'),
      );
      await tester.pumpAndSettle();

      expect(watches, 2, reason: 'maybeOf subscribes');
      expect(reads, 1, reason: 'readOf does not');
    });

    testWidgets('environmentOf says Live under a Live scope', (tester) async {
      // Only the Test answer was pinned, and Test is also what an
      // environmentOf that ignored the scope entirely would return.
      await tester.pumpWidget(
        await liveApp(home: const Scaffold(body: Text('a screen'))),
      );
      await tester.pumpAndSettle();

      expect(
        LiveModeScope.environmentOf(tester.element(find.text('a screen'))),
        DemoEnvironment.live,
      );
    });
    testWidgets('a scope cannot change whether it owns its state', (
      tester,
    ) async {
      // The state is built once, in initState, so a rebuild that flipped this
      // would leave `_own` null and fail somewhere in `build` with nothing in
      // it about ownership. The assert is what turns that into a sentence.
      // Nothing in the app can reach it -- `main` never passes a state -- but
      // a suite that pumps a scope both ways at one position can.
      //
      // The scope is the root here on purpose: it is the same widget type at
      // the same position both times, which is what makes the framework
      // update the element rather than replace it, which is what runs
      // didUpdateWidget at all.
      const screen = Directionality(
        textDirection: TextDirection.ltr,
        child: Text('a screen'),
      );
      final state = fakeEnvironment();
      addTearDown(state.dispose);

      await tester.pumpWidget(LiveModeScope(state: state, child: screen));
      await tester.pump();

      await tester.pumpWidget(const LiveModeScope(child: screen));

      expect(
        tester.takeException(),
        isA<AssertionError>().having(
          (error) => error.message,
          'message',
          contains('fixed for its lifetime'),
        ),
      );
    });
  });
}
