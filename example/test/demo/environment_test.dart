import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/endpoints.dart';
import 'package:paycross_demo/demo/environment.dart';
import 'package:paycross_demo/demo/secrets.dart';
import 'package:paycross_flutter/paycross_flutter.dart';

/// Records what the app asked the SDK to be pointed at, and can be told to
/// refuse -- which is what `configure` does when a payment is in flight.
class _RecordingConfigure {
  final List<PayCrossEnvironment> calls = <PayCrossEnvironment>[];
  final List<String?> merchantIds = <String?>[];
  bool refuse = false;

  Future<void> call({
    required PayCrossEnvironment environment,
    String? googlePayMerchantId,
  }) async {
    if (refuse) throw StateError('a payment is in flight');
    calls.add(environment);
    merchantIds.add(googlePayMerchantId);
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

  test('leaving Live drops the credentials and restores the wallet id', () async {
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
  });

  test('an exit the SDK refuses drops the credentials and stays Live', () async {
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
  });

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
}
