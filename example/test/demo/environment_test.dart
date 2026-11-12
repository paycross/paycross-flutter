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

class _RecordingConfigure {
  final List<PayCrossEnvironment> calls = <PayCrossEnvironment>[];
  final List<String?> merchantIds = <String?>[];

  final List<String?> appleMerchantIds = <String?>[];
  bool refuse = false;

  void Function()? duringTheCall;

  Completer<void>? hold;

  final List<PayCrossAppearance?> appearances = <PayCrossAppearance?>[];

  final List<String?> locales = <String?>[];

  Future<void> call({
    required PayCrossEnvironment environment,
    String? googlePayMerchantId,
    String? applePayMerchantId,
    PayCrossAppearance? appearance,
    String? locale,
  }) async {
    duringTheCall?.call();
    if (refuse) throw StateError('a payment is in flight');
    calls.add(environment);
    merchantIds.add(googlePayMerchantId);
    appleMerchantIds.add(applePayMerchantId);
    appearances.add(appearance);
    locales.add(locale);
    if (hold != null) await hold!.future;
  }
}

const Credentials _live = Credentials(
  clientId: 'live-id',
  clientSecret: 'live-secret',
);

const LiveIdentity _identity = LiveIdentity(
  firstName: 'Ada',
  lastName: 'Lovelace',
  email: 'ada@example.org',
);

void main() {
  test('a fresh state is Test, with no credentials and Test endpoints', () {
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
    expect(configure.calls, isEmpty);
  });

  test('the word switches, and points the SDK before it says so', () async {
    final configure = _RecordingConfigure();
    final state = DemoEnvironmentState(configure: configure.call);

    expect(await state.enterLive('LIVE'), isNull);

    expect(state.environment, DemoEnvironment.live);
    expect(state.endpoints, same(liveEndpoints));
    expect(configure.calls, [PayCrossEnvironment.production]);
    expect(configure.merchantIds, [walletIdOrNull(liveGooglePayMerchantId)]);
  });

  test('surrounding whitespace is forgiven; the word is not', () async {
    final state = DemoEnvironmentState(configure: _RecordingConfigure().call);

    expect(await state.enterLive('  LIVE  '), isNull);
    expect(state.isLive, isTrue);
  });

  test('an SDK that refuses to switch leaves the app in Test', () async {
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

    state.useIdentityForThisSession(_identity);
    expect(state.liveIdentity, isNull);

    await state.enterLive(liveConfirmationWord);
    state.useIdentityForThisSession(_identity);
    expect(state.liveIdentity?.email, 'ada@example.org');
    expect(state.liveIdentity?.firstName, 'Ada');
  });

  test('what a session holds is a credential and an identity, and no more', () {
    final state = DemoEnvironmentState(configure: _RecordingConfigure().call);

    expect(state.liveCredentials, isNull);
    expect(state.liveIdentity, isNull);
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

      expect(configure.appleMerchantIds.single, 'merchant.pay-cross.com.prod');
    });

    test('entering Live sends the production Google identifier', () async {
      final configure = _RecordingConfigure();
      final state = DemoEnvironmentState(configure: configure.call);

      expect(await state.enterLive(liveConfirmationWord), isNull);

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

        expect(configure.appleMerchantIds.last, testApplePayMerchantId);
        expect(configure.merchantIds.last, 'gp-launch');
      },
    );
  });

  test(
    'an exit the SDK refuses drops the credentials and stays Live',
    () async {
      final configure = _RecordingConfigure();
      final state = DemoEnvironmentState(configure: configure.call);
      await state.enterLive('LIVE');
      state.useForThisSession(_live);
      state.useIdentityForThisSession(_identity);
      configure.refuse = true;

      expect(await state.leaveLive(), isNotNull);

      expect(state.liveCredentials, isNull);
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

    expect(heard, 4);
  });
  test(
    'credentials armed while leaving Live do not survive the exit',
    () async {
      final configure = _RecordingConfigure();
      final state = DemoEnvironmentState(configure: configure.call);
      await state.enterLive('LIVE');
      configure.duringTheCall = () => state.useForThisSession(_live);

      expect(await state.leaveLive(), isNull);

      expect(state.environment, DemoEnvironment.test);
      expect(state.liveCredentials, isNull);

      configure.duringTheCall = null;
      await state.enterLive('LIVE');
      expect(state.liveCredentials, isNull);
    },
  );

  test('an exit that fails still forgets what the window armed', () async {
    final configure = _RecordingConfigure();
    final state = DemoEnvironmentState(configure: configure.call);
    await state.enterLive('LIVE');
    configure.duringTheCall = () {
      state.useForThisSession(_live);
      state.useIdentityForThisSession(_identity);
    };
    configure.refuse = true;

    final said = await state.leaveLive();

    expect(said, contains('Still in Live'));
    expect(state.isLive, isTrue);
    expect(state.liveCredentials, isNull);
    expect(state.liveIdentity, isNull);
  });

  test('a second switch while one is in flight is refused', () async {
    final configure = _RecordingConfigure();
    final state = DemoEnvironmentState(configure: configure.call);
    configure.hold = Completer<void>();

    final entering = state.enterLive('LIVE');
    final refused = await state.leaveLive();

    expect(refused, isNotNull);

    configure.hold!.complete();
    expect(await entering, isNull);

    expect(state.isLive, isTrue);
    expect(configure.calls, [PayCrossEnvironment.production]);
  });

  test('a refused switch does not touch the credentials', () async {
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

      expect(find.byKey(const ValueKey('liveBanner')), findsOneWidget);
    });

    testWidgets('a pushed route is under the same banner', (tester) async {
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
      tester.view.viewPadding = const FakeViewPadding(top: 47);
      tester.view.padding = const FakeViewPadding(top: 47);

      await tester.pumpWidget(
        await liveApp(home: const Scaffold(body: Text('a screen'))),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('liveBanner'))).dy,
        greaterThan(47.0),
      );
      expect(
        MediaQuery.of(tester.element(find.text('a screen'))).padding.top,
        0,
      );
    });
    testWidgets('a state that was passed in outlives the scope', (
      tester,
    ) async {
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

  group('a themed run', () {
    const themed = PayCrossAppearance(
      light: PayCrossColors(brand: Color(0xFF00875A)),
    );

    test('applies the appearance and puts the SDK back', () async {
      final configure = _RecordingConfigure();
      final state = DemoEnvironmentState(
        configure: configure.call,
        googlePayMerchantId: 'BCR2DN4T2ABCDEFG',
        applePayMerchantId: 'merchant.pay-cross.com',
      );

      await state.applyTestAppearance(themed);
      await state.applyTestAppearance(null);

      expect(configure.appearances, <PayCrossAppearance?>[themed, null]);
      expect(configure.merchantIds, <String?>[
        'BCR2DN4T2ABCDEFG',
        'BCR2DN4T2ABCDEFG',
      ]);
      expect(configure.appleMerchantIds, <String?>[
        'merchant.pay-cross.com',
        'merchant.pay-cross.com',
      ]);
    });

    test('is a sandbox call even when the app is in Live', () async {
      final configure = _RecordingConfigure();
      final state = DemoEnvironmentState(configure: configure.call);
      expect(await state.enterLive(liveConfirmationWord), isNull);

      await state.applyTestAppearance(themed);

      expect(configure.calls.last, PayCrossEnvironment.sandbox);
    });
  });

  group('the launch locale', () {
    test('rides into Live and back out again', () async {
      final configure = _RecordingConfigure();
      final state = DemoEnvironmentState(
        configure: configure.call,
        locale: 'fr',
      );

      expect(await state.enterLive(liveConfirmationWord), isNull);
      expect(await state.leaveLive(), isNull);

      expect(configure.calls, [
        PayCrossEnvironment.production,
        PayCrossEnvironment.sandbox,
      ]);
      expect(configure.locales, ['fr', 'fr']);
    });

    test('survives a themed run in both directions', () async {
      final configure = _RecordingConfigure();
      final state = DemoEnvironmentState(
        configure: configure.call,
        locale: 'fr',
      );

      await state.applyTestAppearance(
        PayCrossAppearance.brand(const Color(0xFF1E88E5)),
      );
      await state.applyTestAppearance(null);

      expect(configure.locales, ['fr', 'fr']);
      expect(configure.appearances.first, isNotNull);
      expect(configure.appearances.last, isNull);
    });

    test('is null when nothing was chosen', () async {
      final configure = _RecordingConfigure();
      final state = DemoEnvironmentState(configure: configure.call);

      expect(await state.enterLive(liveConfirmationWord), isNull);

      expect(configure.locales, [isNull]);
    });
  });

  group('the launch appearance', () {
    test('is what a themed run is restored to, not nothing', () async {
      final configure = _RecordingConfigure();
      final launch = PayCrossAppearance.brand(const Color(0xFF1E88E5));
      final state = DemoEnvironmentState(
        configure: configure.call,
        appearance: launch,
      );

      await state.applyTestAppearance(
        PayCrossAppearance.brand(const Color(0xFF00875A)),
      );
      await state.applyTestAppearance(null);

      expect(
        configure.appearances.first?.light?.brand,
        const Color(0xFF00875A),
      );
      expect(configure.appearances.last, same(launch));
    });

    test('is restored on the way out of Live', () async {
      final configure = _RecordingConfigure();
      final launch = PayCrossAppearance.brand(const Color(0xFF1E88E5));
      final state = DemoEnvironmentState(
        configure: configure.call,
        appearance: launch,
      );

      expect(await state.enterLive(liveConfirmationWord), isNull);
      expect(await state.leaveLive(), isNull);

      expect(configure.appearances.last, same(launch));
    });

    test('does not ride into Live', () async {
      final configure = _RecordingConfigure();
      final state = DemoEnvironmentState(
        configure: configure.call,
        appearance: PayCrossAppearance.brand(const Color(0xFF1E88E5)),
      );

      expect(await state.enterLive(liveConfirmationWord), isNull);

      expect(configure.calls, [PayCrossEnvironment.production]);
      expect(configure.appearances, [isNull]);
    });

    test('is null when nothing was set', () async {
      final configure = _RecordingConfigure();
      final state = DemoEnvironmentState(configure: configure.call);

      await state.applyTestAppearance(null);

      expect(configure.appearances, [isNull]);
    });
  });
}
