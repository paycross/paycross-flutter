import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/endpoints.dart';
import 'package:paycross_demo/demo/environment.dart';
import 'package:paycross_demo/demo/minter.dart';
import 'package:paycross_demo/demo/secrets.dart';
import 'package:paycross_demo/demo/settings.dart';
import 'package:paycross_flutter/paycross_flutter.dart';

import '_environment.dart';
import '_surface.dart';

Widget _settings({
  required SecretStore store,
  Future<String> Function(Credentials)? verify,
}) => MaterialApp(
  home: SettingsScreen(
    store: store,
    verifyCredentials: verify ?? (_) async => 'ok',
    readVersions: () async =>
        (demo: '0.1.0+1', plugin: '0.1.0', nativeSdk: 'unknown'),
  ),
);

/// Settings under a live-mode scope, mounted where the app mounts it.
///
/// The existing `_settings` helper pumps a bare MaterialApp, which is
/// exactly what a Test-mode screen sees, so every test written before this
/// task keeps meaning what it meant.
Widget _settingsIn(
  DemoEnvironmentState state, {
  required SecretStore store,
  Future<String> Function(Credentials)? verify,
}) => appWithEnvironment(
  state: state,
  home: SettingsScreen(
    store: store,
    verifyCredentials: verify ?? (_) async => 'ok',
    readVersions: () async =>
        (demo: '0.1.0+1', plugin: '0.1.0', nativeSdk: 'unknown'),
  ),
);

/// Settings under a scope that is already switched to Live.
///
/// The Live twin of [_settingsIn]. `liveApp` switches before it builds, so
/// the screen's `initState` runs with Live already selected -- which is the
/// entrance task 04 creates and the one the prefill guard exists for.
Future<Widget> _liveSettings({
  required SecretStore store,
  DemoEnvironmentState? state,
}) => liveApp(
  state: state,
  home: SettingsScreen(
    store: store,
    verifyCredentials: (_) async => 'ok',
    readVersions: () async =>
        (demo: '0.1.0+1', plugin: '0.1.0', nativeSdk: 'unknown'),
  ),
);

/// Stores like the in-memory backend but fails the one operation a test
/// names -- which is what an iOS Keychain without the entitlement and an
/// Android KeyStore whose key is gone both look like from Dart.
class _FailingBackend implements SecretBackend {
  _FailingBackend({this.onWrite = false, this.onDelete = false});

  final bool onWrite;
  final bool onDelete;
  final Map<String, String> entries = <String, String>{};

  @override
  Future<String?> read(String key) async => entries[key];

  @override
  Future<void> write(String key, String value) async {
    if (onWrite) throw StateError('no keychain');
    entries[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (onDelete) throw StateError('no keychain');
    entries.remove(key);
  }
}

/// A backend whose reads wait on [gate], so a test can act on the screen
/// while the first load is still in flight.
class _SlowBackend implements SecretBackend {
  final Map<String, String> entries = <String, String>{};
  final Completer<void> gate = Completer<void>();

  @override
  Future<String?> read(String key) async {
    await gate.future;
    return entries[key];
  }

  @override
  Future<void> write(String key, String value) async => entries[key] = value;

  @override
  Future<void> delete(String key) async => entries.remove(key);
}

/// Stores like the in-memory backend, and counts every write and delete.
///
/// The spy the memory-only rule is checked against: in Live the count must
/// be zero, because there is no code path from that screen to a store.
class _CountingBackend implements SecretBackend {
  final Map<String, String> entries = <String, String>{};
  int writes = 0;
  int deletes = 0;

  @override
  Future<String?> read(String key) async => entries[key];

  @override
  Future<void> write(String key, String value) async {
    writes++;
    entries[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    deletes++;
    entries.remove(key);
  }
}

/// A state whose SDK will not go back to sandbox.
///
/// The half-failed exit, which is the one case where the environment and the
/// credentials part company: `leaveLive` drops them and then cannot re-point
/// the SDK, so the app is still in Live with nothing to pay with. Only the
/// way back throws -- an `enterLive` that also threw could never get a test
/// into Live to begin with.
DemoEnvironmentState _stuckInLive() => DemoEnvironmentState(
  configure:
      ({
        required PayCrossEnvironment environment,
        String? googlePayMerchantId,
      }) async {
        if (environment == PayCrossEnvironment.sandbox) {
          throw StateError('no channel');
        }
      },
);

/// A state whose SDK call parks until a test lets it finish.
///
/// The window a second tap lands in: `_busy` is set, the switch is in
/// flight, and nothing has come back yet. [parkOn] names the direction to
/// park -- the other one completes at once, so a test can get itself into
/// Live before parking the way out, or park the way in from the start.
class _ParkedSwitch {
  _ParkedSwitch(this.parkOn);

  final PayCrossEnvironment parkOn;
  final Completer<void> gate = Completer<void>();

  late final DemoEnvironmentState state = DemoEnvironmentState(
    configure:
        ({
          required PayCrossEnvironment environment,
          String? googlePayMerchantId,
        }) async {
          if (environment == parkOn) await gate.future;
        },
  );
}

/// Whether the button carrying [label] is live.
///
/// Found by predicate, not by type: `find.byType` matches the exact runtime
/// type, so it would never see a FilledButton as the ButtonStyleButton the
/// three buttons share.
bool _enabled(WidgetTester tester, String label) =>
    tester
        .widget<ButtonStyleButton>(
          find.ancestor(
            of: find.text(label),
            matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
          ),
        )
        .onPressed !=
    null;

String _message(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('settingsMessage'))).data!;

String _fieldText(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;

void main() {
  testWidgets('stores what is typed', (tester) async {
    final backend = InMemorySecretBackend();
    await tester.pumpWidget(_settings(store: SecretStore(backend: backend)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const ValueKey('clientId')), 'id-1');
    await tester.enterText(
      find.byKey(const ValueKey('clientSecret')),
      'secret-1',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(backend.entries['paycross_demo_client_id'], 'id-1');
    expect(backend.entries['paycross_demo_client_secret'], 'secret-1');
  });

  testWidgets('masks the secret until it is revealed', (tester) async {
    final backend = InMemorySecretBackend();
    backend.entries['paycross_demo_client_id'] = 'id-1';
    backend.entries['paycross_demo_client_secret'] = 'secret-1';
    await tester.pumpWidget(_settings(store: SecretStore(backend: backend)));
    await tester.pumpAndSettle();

    TextField secretField() =>
        tester.widget<TextField>(find.byKey(const ValueKey('clientSecret')));
    expect(secretField().obscureText, isTrue);

    await tester.tap(find.byKey(const ValueKey('revealSecret')));
    await tester.pumpAndSettle();

    expect(secretField().obscureText, isFalse);
  });

  testWidgets('forget empties the store', (tester) async {
    final backend = InMemorySecretBackend();
    backend.entries['paycross_demo_client_id'] = 'id-1';
    backend.entries['paycross_demo_client_secret'] = 'secret-1';
    await tester.pumpWidget(_settings(store: SecretStore(backend: backend)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Forget credentials'));
    await tester.pumpAndSettle();

    expect(backend.entries, isEmpty);
  });

  testWidgets('verify reports what the mint said', (tester) async {
    final backend = InMemorySecretBackend();
    backend.entries['paycross_demo_client_id'] = 'id-1';
    backend.entries['paycross_demo_client_secret'] = 'secret-1';
    await tester.pumpWidget(
      _settings(
        store: SecretStore(backend: backend),
        verify: (_) async => 'Minted session sess-9.',
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Verify credentials'));
    await tester.pumpAndSettle();

    expect(_message(tester), contains('Minted session sess-9.'));
  });

  testWidgets('a failed verify shows the reason and never the secret', (
    tester,
  ) async {
    final backend = InMemorySecretBackend();
    backend.entries['paycross_demo_client_id'] = 'id-1';
    backend.entries['paycross_demo_client_secret'] = 'secret-1';
    await tester.pumpWidget(
      _settings(
        store: SecretStore(backend: backend),
        verify: (_) async =>
            throw const MinterError('POST /payment-sessions -> HTTP 401'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Verify credentials'));
    await tester.pumpAndSettle();

    // Read the message widget, not the whole tree: the secret really is on
    // screen -- obscured, in the field it was typed into -- so a tree-wide
    // `findsNothing` asserts something false. What must hold is that the
    // MESSAGE never carries it.
    final message = tester.widget<Text>(
      find.byKey(const ValueKey('settingsMessage')),
    );
    expect(message.data, contains('HTTP 401'));
    expect(message.data, isNot(contains('secret-1')));
  });

  testWidgets('stores the Google Pay merchant id, and clears it', (
    tester,
  ) async {
    final backend = InMemorySecretBackend();
    await tester.pumpWidget(_settings(store: SecretStore(backend: backend)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const ValueKey('clientId')), 'id-1');
    await tester.enterText(
      find.byKey(const ValueKey('clientSecret')),
      'secret-1',
    );
    await tester.enterText(
      find.byKey(const ValueKey('googlePayMerchantId')),
      'gp-1',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(backend.entries['paycross_demo_google_pay_merchant_id'], 'gp-1');

    // Emptying the field must delete the key rather than store '', or the
    // next launch hands `configure` an empty merchant id instead of null.
    await tester.enterText(
      find.byKey(const ValueKey('googlePayMerchantId')),
      '',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(
      backend.entries.containsKey('paycross_demo_google_pay_merchant_id'),
      isFalse,
    );
  });

  testWidgets('tells the reader the merchant id is read at launch', (
    tester,
  ) async {
    // main() reads this once, before runApp. A field that looks live but is
    // not is worse than no field, so the screen has to say so.
    await tester.pumpWidget(
      _settings(store: SecretStore(backend: InMemorySecretBackend())),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('restart the app'), findsOneWidget);
  });

  testWidgets('a save that fails says so and keeps what was typed', (
    tester,
  ) async {
    final backend = _FailingBackend(onWrite: true);
    await tester.pumpWidget(_settings(store: SecretStore(backend: backend)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const ValueKey('clientId')), 'id-1');
    await tester.enterText(
      find.byKey(const ValueKey('clientSecret')),
      'secret-1',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(_message(tester), contains('save'));
    expect(_message(tester), contains('StateError'));
    expect(_message(tester), isNot(contains('secret-1')));
    // Still on screen to try again with: a failed write is the one moment a
    // human must not have to retype a secret.
    expect(_fieldText(tester, 'clientSecret'), 'secret-1');
  });

  testWidgets('a forget that fails says so and does not clear the fields', (
    tester,
  ) async {
    final backend = _FailingBackend(onDelete: true);
    backend.entries['paycross_demo_client_id'] = 'id-1';
    backend.entries['paycross_demo_client_secret'] = 'secret-1';
    await tester.pumpWidget(_settings(store: SecretStore(backend: backend)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Forget credentials'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(_message(tester), contains('forget'));
    expect(_message(tester), contains('StateError'));
    // Emptying the fields here would tell the human the credentials are gone
    // while they are still in the store.
    expect(_fieldText(tester, 'clientId'), 'id-1');
  });

  testWidgets('verify says only "Verified" when what is typed is stored', (
    tester,
  ) async {
    final backend = InMemorySecretBackend();
    backend.entries['paycross_demo_client_id'] = 'id-1';
    backend.entries['paycross_demo_client_secret'] = 'secret-1';
    await tester.pumpWidget(
      _settings(
        store: SecretStore(backend: backend),
        verify: (_) async => 'Minted session sess-9.',
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Verify credentials'));
    await tester.pumpAndSettle();

    expect(_message(tester), contains('Verified'));
    expect(_message(tester), isNot(contains('Save')));
  });

  testWidgets('verify says to press Save when what is typed is not stored', (
    tester,
  ) async {
    final backend = InMemorySecretBackend();
    backend.entries['paycross_demo_client_id'] = 'id-1';
    backend.entries['paycross_demo_client_secret'] = 'secret-1';
    await tester.pumpWidget(
      _settings(
        store: SecretStore(backend: backend),
        verify: (_) async => 'Minted session sess-9.',
      ),
    );
    await tester.pumpAndSettle();

    // Verify mints with what is on screen, so an edited secret that verifies
    // is still not the one the app will use on the next launch.
    await tester.enterText(
      find.byKey(const ValueKey('clientSecret')),
      'secret-2',
    );
    await tester.tap(find.text('Verify credentials'));
    await tester.pumpAndSettle();

    expect(_message(tester), contains('press Save'));

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Verify credentials'));
    await tester.pumpAndSettle();

    // And it stops saying so once they have, which is what proves the screen
    // tracks the save rather than only the first read.
    expect(_message(tester), contains('Verified'));
    expect(_message(tester), isNot(contains('press Save')));
  });

  testWidgets('a failed verify never claims the credentials are verified', (
    tester,
  ) async {
    final backend = InMemorySecretBackend();
    backend.entries['paycross_demo_client_id'] = 'id-1';
    backend.entries['paycross_demo_client_secret'] = 'secret-1';
    await tester.pumpWidget(
      _settings(
        store: SecretStore(backend: backend),
        verify: (_) async =>
            throw const MinterError('POST /payment-sessions -> HTTP 401'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Verify credentials'));
    await tester.pumpAndSettle();

    expect(_message(tester), isNot(contains('Verified')));
  });

  testWidgets('nothing can be saved before the store has answered', (
    tester,
  ) async {
    final backend = _SlowBackend();
    backend.entries['paycross_demo_client_id'] = 'id-1';
    backend.entries['paycross_demo_client_secret'] = 'secret-1';
    await tester.pumpWidget(_settings(store: SecretStore(backend: backend)));
    await tester.pump();

    // The fields are empty only because the read has not come back yet.
    // Saving now would write that emptiness over a good stored credential.
    expect(_enabled(tester, 'Save'), isFalse);
    expect(_enabled(tester, 'Verify credentials'), isFalse);
    expect(_enabled(tester, 'Forget credentials'), isFalse);

    await tester.tap(find.text('Save'), warnIfMissed: false);
    await tester.pump();

    expect(backend.entries['paycross_demo_client_secret'], 'secret-1');

    backend.gate.complete();
    await tester.pumpAndSettle();

    expect(_enabled(tester, 'Save'), isTrue);
    expect(_fieldText(tester, 'clientSecret'), 'secret-1');
  });

  testWidgets('a load that finds nothing still enables the buttons', (
    tester,
  ) async {
    // The empty store is the first-run case. Leaving the screen disabled
    // there would make a fresh install impossible to configure.
    await tester.pumpWidget(
      _settings(store: SecretStore(backend: InMemorySecretBackend())),
    );
    await tester.pumpAndSettle();

    expect(_enabled(tester, 'Save'), isTrue);
  });

  testWidgets('a save with no id or secret is refused, not reported saved', (
    tester,
  ) async {
    final backend = InMemorySecretBackend();
    await tester.pumpWidget(_settings(store: SecretStore(backend: backend)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(backend.entries, isEmpty);
    expect(_message(tester), isNot(contains('Saved')));
    expect(_message(tester), contains('client ID'));
  });

  testWidgets('a verify with no id or secret never reaches the network', (
    tester,
  ) async {
    var minted = false;
    await tester.pumpWidget(
      _settings(
        store: SecretStore(backend: InMemorySecretBackend()),
        verify: (_) async {
          minted = true;
          return 'Minted session sess-9.';
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Verify credentials'));
    await tester.pumpAndSettle();

    // An empty pair still builds a request: the token endpoint would get
    // Basic auth over a bare colon and answer 401, which reads as "these
    // credentials are wrong" rather than "you have not entered any".
    expect(minted, isFalse);
    expect(_message(tester), isNot(contains('Verified')));
    expect(_message(tester), contains('client ID'));
  });

  testWidgets('a load does not overwrite what a human has already typed', (
    tester,
  ) async {
    final backend = _SlowBackend();
    backend.entries['paycross_demo_client_id'] = 'id-1';
    backend.entries['paycross_demo_client_secret'] = 'secret-1';
    await tester.pumpWidget(_settings(store: SecretStore(backend: backend)));
    await tester.pump();

    await tester.enterText(find.byKey(const ValueKey('clientId')), 'typed-1');
    backend.gate.complete();
    await tester.pumpAndSettle();

    // A slow Keychain that answers after the human started typing must not
    // pull the text out from under them.
    expect(_fieldText(tester, 'clientId'), 'typed-1');
    expect(_fieldText(tester, 'clientSecret'), 'secret-1');
  });

  testWidgets('the outcome line announces itself to a screen reader', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _settings(store: SecretStore(backend: InMemorySecretBackend())),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // The message appears in place, with no focus change and nothing to
    // navigate to, so without this a screen-reader user gets no word that
    // the button they just pressed did anything at all.
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('settingsMessage')))
          .flagsCollection
          .isLiveRegion,
      isTrue,
    );
    semantics.dispose();
  });

  testWidgets('Test names the sandbox endpoint it will use', (tester) async {
    await tester.pumpWidget(
      _settings(store: SecretStore(backend: InMemorySecretBackend())),
    );
    await tester.pumpAndSettle();

    final copy = tester
        .widget<Text>(find.byKey(const ValueKey('settingsEnvironment')))
        .data!;
    expect(copy, contains(testEndpoints.sessionsUrl));
    expect(copy, contains('Test'));
    // The shipped promise this plan retires, gone rather than quietly false.
    expect(copy, isNot(contains('no production switch')));
  });

  testWidgets('Live names the production endpoint and what it costs', (
    tester,
  ) async {
    await tester.pumpWidget(
      await _liveSettings(store: SecretStore(backend: InMemorySecretBackend())),
    );
    await tester.pumpAndSettle();

    final copy = tester
        .widget<Text>(find.byKey(const ValueKey('settingsEnvironment')))
        .data!;
    expect(copy, contains(liveEndpoints.sessionsUrl));
    expect(copy, contains('real card'));
  });

  testWidgets('a slow store says why the buttons are dead', (tester) async {
    final backend = _SlowBackend();
    await tester.pumpWidget(_settings(store: SecretStore(backend: backend)));
    await tester.pump();

    // A cold Keychain read can take a visible moment on a real phone, and
    // three dead buttons over three empty fields look like a broken build
    // unless something on screen says the read has not come back yet.
    expect(_enabled(tester, 'Save'), isFalse);
    expect(find.text('Reading saved credentials…'), findsOneWidget);

    backend.gate.complete();
    await tester.pumpAndSettle();

    expect(find.text('Reading saved credentials…'), findsNothing);
    expect(_enabled(tester, 'Save'), isTrue);
  });

  testWidgets('choosing Live does not switch on its own', (tester) async {
    // A tap is not consent to spend money. What a tap does is reveal the
    // field that asks for it.
    final state = fakeEnvironment();
    await tester.pumpWidget(
      _settingsIn(state, store: SecretStore(backend: InMemorySecretBackend())),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Live'));
    await tester.pumpAndSettle();

    expect(state.environment, DemoEnvironment.test);
    expect(find.byKey(const ValueKey('liveConfirm')), findsOneWidget);
    expect(find.byKey(const ValueKey('liveBanner')), findsNothing);
    // The warning is the whole reason the gate is worth opening. Unpinned, a
    // refactor could delete it and the suite would stay green -- in a plan
    // whose stated purpose is that this app's copy stops being quietly false.
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('liveGateWarning'))).data,
      contains('real card'),
    );
  });

  testWidgets('the switch stays dead until the word is exactly right', (
    tester,
  ) async {
    final state = fakeEnvironment();
    await tester.pumpWidget(
      _settingsIn(state, store: SecretStore(backend: InMemorySecretBackend())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Live'));
    await tester.pumpAndSettle();

    expect(_enabled(tester, 'Switch to Live'), isFalse);

    await tester.enterText(find.byKey(const ValueKey('liveConfirm')), 'live');
    await tester.pumpAndSettle();
    expect(_enabled(tester, 'Switch to Live'), isFalse);

    await tester.enterText(find.byKey(const ValueKey('liveConfirm')), 'LIVE');
    await tester.pumpAndSettle();
    expect(_enabled(tester, 'Switch to Live'), isTrue);
  });

  testWidgets('typing the word and pressing it switches, banner and all', (
    tester,
  ) async {
    final state = fakeEnvironment();
    await tester.pumpWidget(
      _settingsIn(state, store: SecretStore(backend: InMemorySecretBackend())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Live'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('liveConfirm')), 'LIVE');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('switchToLive')));
    await tester.pumpAndSettle();

    expect(state.environment, DemoEnvironment.live);
    expect(find.byKey(const ValueKey('liveBanner')), findsOneWidget);
    expect(find.byKey(const ValueKey('liveConfirm')), findsNothing);
  });

  testWidgets('choosing Test comes straight back, and forgets', (tester) async {
    // Becoming safer needs no ceremony. The gate is on the way in only.
    final state = fakeEnvironment();
    await tester.pumpWidget(
      await _liveSettings(
        state: state,
        store: SecretStore(backend: InMemorySecretBackend()),
      ),
    );
    await tester.pumpAndSettle();
    state.useForThisSession(
      const Credentials(clientId: 'live-id', clientSecret: 'live-secret'),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Test'));
    await tester.pumpAndSettle();

    // The environment assertion is what carries this test. The line below
    // it reads like a proof that the credentials were dropped and is not
    // one: `liveCredentials` is `isLive ? _liveCredentials : null`, so once
    // the environment is Test it answers null whether or not the field was
    // cleared. The drop itself is task 01's to pin, and environment_test
    // does.
    expect(state.environment, DemoEnvironment.test);
    expect(state.liveCredentials, isNull);
    expect(find.byKey(const ValueKey('liveBanner')), findsNothing);
  });

  testWidgets('Settings opened in Live never prefills the stored credential', (
    tester,
  ) async {
    // The screen is pushed fresh from Live -- by the tile with no credentials
    // held, and by the profile strip -- so its `initState` load runs while
    // Live is already selected. Prefilling there puts a sandbox secret one
    // tap from the production merchant.
    final backend = _CountingBackend()
      ..entries['paycross_demo_client_id'] = 'test-id'
      ..entries['paycross_demo_client_secret'] = 'test-secret'
      ..entries['paycross_demo_google_pay_merchant_id'] = 'gp-1';

    await tester.pumpWidget(
      await _liveSettings(store: SecretStore(backend: backend)),
    );
    await tester.pumpAndSettle();

    // The fields, and only the fields. What the store holds is read; what it
    // holds is not shown.
    expect(_fieldText(tester, 'clientId'), '');
    expect(_fieldText(tester, 'clientSecret'), '');

    // And the guard is a snapshot, not a latch: coming back to Test has to
    // fill the fields from the store again. Without the `_openedInLive =
    // false` in `_chooseEnvironment`'s Test branch, this screen's fields stay
    // empty for the rest of its life and the human silently cannot see or
    // re-save the sandbox credential they had.
    await tester.tap(find.text('Test'));
    await tester.pumpAndSettle();

    expect(_fieldText(tester, 'clientId'), 'test-id');
    expect(_fieldText(tester, 'clientSecret'), 'test-secret');
  });

  testWidgets('Live hides Save, Verify, Forget and the wallet id', (
    tester,
  ) async {
    await tester.pumpWidget(
      await _liveSettings(store: SecretStore(backend: InMemorySecretBackend())),
    );
    await tester.pumpAndSettle();

    expect(find.text('Save'), findsNothing);
    // There is no Verify in Live on purpose: the €1.00 smoke is the
    // verification, and a probe would create a real production session as a
    // side effect.
    expect(find.text('Verify credentials'), findsNothing);
    expect(find.text('Forget credentials'), findsNothing);
    expect(find.byKey(const ValueKey('googlePayMerchantId')), findsNothing);
    expect(find.byKey(const ValueKey('useForThisSession')), findsOneWidget);
    // The two that stay: a credential still has to be typed somewhere.
    expect(find.byKey(const ValueKey('clientId')), findsOneWidget);
    expect(find.byKey(const ValueKey('clientSecret')), findsOneWidget);
  });

  testWidgets('a Live credential reaches memory and nothing else', (
    tester,
  ) async {
    final backend = _CountingBackend();
    final state = fakeEnvironment();
    await tester.pumpWidget(
      await _liveSettings(
        state: state,
        store: SecretStore(backend: backend),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const ValueKey('clientId')), 'live-id');
    await tester.enterText(
      find.byKey(const ValueKey('clientSecret')),
      'live-secret',
    );
    await tester.tap(find.byKey(const ValueKey('useForThisSession')));
    await tester.pumpAndSettle();

    expect(state.liveCredentials?.clientId, 'live-id');
    expect(state.liveCredentials?.clientSecret, 'live-secret');
    // The whole rule, in two lines: not one byte of a production credential
    // reached a store, so there is nothing on the device to leak, to back up,
    // or to forget to forget.
    expect(backend.writes, 0);
    // A delete is a store touch too, and the rule is that Live makes none.
    expect(backend.deletes, 0);
    expect(backend.entries, isEmpty);
  });

  testWidgets('a Live session with half a credential is refused', (
    tester,
  ) async {
    final state = fakeEnvironment();
    await tester.pumpWidget(
      await _liveSettings(
        state: state,
        store: SecretStore(backend: InMemorySecretBackend()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const ValueKey('clientId')), 'live-id');
    await tester.tap(find.byKey(const ValueKey('useForThisSession')));
    await tester.pumpAndSettle();

    expect(state.liveCredentials, isNull);
    expect(_message(tester), contains('client secret'));
  });

  testWidgets('switching to Live empties what Test had on screen', (
    tester,
  ) async {
    // A sandbox credential still in the field after the switch is one tap
    // away from being sent to production.
    final backend = InMemorySecretBackend()
      ..entries['paycross_demo_client_id'] = 'test-id'
      ..entries['paycross_demo_client_secret'] = 'test-secret';
    final state = fakeEnvironment();
    await tester.pumpWidget(
      _settingsIn(state, store: SecretStore(backend: backend)),
    );
    await tester.pumpAndSettle();
    expect(_fieldText(tester, 'clientId'), 'test-id');

    await tester.tap(find.text('Live'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('liveConfirm')), 'LIVE');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('switchToLive')));
    await tester.pumpAndSettle();

    expect(_fieldText(tester, 'clientId'), '');
    expect(_fieldText(tester, 'clientSecret'), '');
  });

  testWidgets('coming back to Test empties the fields and reloads the store', (
    tester,
  ) async {
    // And the direction that matters more: a production secret left in a
    // field in Test is one Save away from the platform secure store.
    final backend = _CountingBackend()
      ..entries['paycross_demo_client_id'] = 'test-id'
      ..entries['paycross_demo_client_secret'] = 'test-secret';
    final state = fakeEnvironment();
    await tester.pumpWidget(
      await _liveSettings(
        state: state,
        store: SecretStore(backend: backend),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('clientSecret')),
      'live-secret',
    );

    await tester.tap(find.text('Test'));
    await tester.pumpAndSettle();

    expect(_fieldText(tester, 'clientSecret'), 'test-secret');
    expect(backend.writes, 0);
    expect(backend.deletes, 0);
  });

  testWidgets('both branches lay out and scroll at ordinary phone width', (
    tester,
  ) async {
    // The switch, the gate field and the banner all landed on a screen that
    // was already a long list. An overflow stripe is an exception in a widget
    // test, and the default 800x600 surface every other case here uses is
    // wider than any phone.
    usePhoneSurface(tester);
    final state = fakeEnvironment();
    await tester.pumpWidget(
      await _liveSettings(
        state: state,
        store: SecretStore(backend: InMemorySecretBackend()),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('useForThisSession')), findsOneWidget);

    // Back to Test and straight into the gate, which is where this screen is
    // longest: three fields, the wallet id, three buttons and the gate's own
    // paragraph. Measured at 390x844 the Live branch has a maxScrollExtent of
    // 0 -- it fits -- so a scroll assertion there would scroll nothing and
    // pass with the call deleted. This branch overflows by ~423px.
    await tester.tap(find.text('Test'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Live'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('liveConfirm')), findsOneWidget);
    expect(tester.takeException(), isNull);

    final list = tester.widget<Scrollable>(find.byType(Scrollable).first);
    // Pinned, so that a screen which later shrinks back inside one phone
    // screen turns this into a failure to look at rather than a scroll
    // assertion that quietly stops meaning anything.
    expect(list.controller!.position.maxScrollExtent, greaterThan(0));

    await tester.scrollUntilVisible(
      find.text('Forget credentials'),
      200,
      // Named, unlike Home's copy of this test, which lets it default to the
      // only `Scrollable` on that screen. Settings has three: the `ListView`
      // and one inside each `TextField`, since `EditableText` scrolls its own
      // content. The default finder matches all three and throws "Too many
      // elements" before it scrolls anything. The `ListView` is the outermost
      // of them, so it is the first in a depth-first walk.
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.text('Forget credentials'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an exit the SDK refused is reported in full, not summarised', (
    tester,
  ) async {
    // The credentials are gone and the app is still in Live. Nothing on
    // screen can show that except this line, so the screen renders what the
    // state returned rather than a sentence of its own: the runtimeType says
    // which failure it was, and the tail says what to do about it. A refactor
    // that replaces either half with a tidier message of its own is what this
    // test exists to stop.
    final state = _stuckInLive();
    await tester.pumpWidget(
      await _liveSettings(
        state: state,
        store: SecretStore(backend: InMemorySecretBackend()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Test'));
    await tester.pumpAndSettle();

    expect(_message(tester), contains('The credentials are forgotten'));
    expect(_message(tester), contains('StateError'));
    // `endsWith`, not `contains`: rendering it as-is means nothing is
    // appended to it either.
    expect(_message(tester), endsWith('Still in Live — restart the app.'));

    // And the two halves the message is making a promise about, both true.
    expect(state.liveCredentials, isNull);
    expect(state.environment, DemoEnvironment.live);
    expect(find.byKey(const ValueKey('liveBanner')), findsOneWidget);
  });

  testWidgets('a store read still in flight cannot refill a Live screen', (
    tester,
  ) async {
    // The door an `initState` snapshot leaves open. `SecretStore.read` is
    // three sequential platform-channel round-trips, so on a real phone it
    // outlives a human deciding to switch. If the guard were the environment
    // at load START rather than the environment where the read LANDS, this
    // read would fill a Live screen from the Keychain -- and one tap on Use
    // for this session sends the sandbox pair to the production merchant.
    final backend = _SlowBackend()
      ..entries['paycross_demo_client_id'] = 'test-id'
      ..entries['paycross_demo_client_secret'] = 'test-secret';
    final state = fakeEnvironment();
    await tester.pumpWidget(
      _settingsIn(state, store: SecretStore(backend: backend)),
    );
    await tester.pump();

    await tester.tap(find.text('Live'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('liveConfirm')), 'LIVE');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('switchToLive')));
    await tester.pumpAndSettle();

    // Only now does the Keychain answer, with the app already in Live.
    backend.gate.complete();
    await tester.pumpAndSettle();

    expect(state.isLive, isTrue);
    expect(_fieldText(tester, 'clientId'), '');
    expect(_fieldText(tester, 'clientSecret'), '');
  });

  testWidgets('a reload started on the way to Test cannot refill Live either', (
    tester,
  ) async {
    // The wider door: `_chooseEnvironment` sets `_busy` back to false before
    // it awaits its reload, so the switch is fully usable for the whole
    // duration of that second read. Live -> Test -> Live, all before the
    // store answers, and both parked reads land on a Live screen.
    final backend = _SlowBackend()
      ..entries['paycross_demo_client_id'] = 'test-id'
      ..entries['paycross_demo_client_secret'] = 'test-secret';
    final state = fakeEnvironment();
    await tester.pumpWidget(
      await _liveSettings(
        state: state,
        store: SecretStore(backend: backend),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Test'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Live'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('liveConfirm')), 'LIVE');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('switchToLive')));
    await tester.pumpAndSettle();

    backend.gate.complete();
    await tester.pumpAndSettle();

    expect(state.isLive, isTrue);
    expect(_fieldText(tester, 'clientId'), '');
    expect(_fieldText(tester, 'clientSecret'), '');
  });

  testWidgets(
    'an environment moved by another surface still empties the fields',
    (tester) async {
      // The third door, and the one no mirror can close. `_load` used to guard
      // on a `bool` this screen maintained from its OWN switch paths, so an
      // environment moved by anything else left the mirror saying Test while
      // the app was in Live -- and a read landing then refilled a Live screen
      // from the Keychain.
      //
      // The environment is moved from outside the widget rather than through a
      // second SettingsScreen, because there is no second surface in the app
      // that moves it: `DemoEnvironmentState` is app-wide and this is what any
      // future one would do to it. The guarantee has to hold before something
      // does, which is the whole reason the mirror is gone.
      final backend = _SlowBackend()
        ..entries['paycross_demo_client_id'] = 'test-id'
        ..entries['paycross_demo_client_secret'] = 'test-secret';
      final state = fakeEnvironment();
      await tester.pumpWidget(
        _settingsIn(state, store: SecretStore(backend: backend)),
      );
      await tester.pump();

      // Not a tap on this screen's own switch: nothing here is touched.
      await state.enterLive(liveConfirmationWord);
      await tester.pumpAndSettle();

      // Only now does the Keychain answer, with the app already in Live.
      backend.gate.complete();
      await tester.pumpAndSettle();

      expect(state.isLive, isTrue);
      expect(_fieldText(tester, 'clientId'), '');
      expect(_fieldText(tester, 'clientSecret'), '');
    },
  );

  testWidgets('editing a credential retracts the claim that one is held', (
    tester,
  ) async {
    // A typo'd production secret is held, the human spots it and corrects the
    // field, and the screen goes on saying "Held for this session" about the
    // pair it no longer shows. They walk to Home and run the EUR 1.00 smoke
    // with the old secret, and the 401 reads as a bad production credential.
    // The Test side already solved this drift -- `_matchesStored` and the
    // "press Save to keep them" line exist for it -- and Live had no
    // equivalent.
    final state = fakeEnvironment();
    await tester.pumpWidget(
      await _liveSettings(
        state: state,
        store: SecretStore(backend: InMemorySecretBackend()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const ValueKey('clientId')), 'live-id');
    await tester.enterText(
      find.byKey(const ValueKey('clientSecret')),
      'live-secret',
    );
    await tester.tap(find.byKey(const ValueKey('useForThisSession')));
    await tester.pumpAndSettle();
    expect(_message(tester), contains('Held for this session'));

    await tester.enterText(
      find.byKey(const ValueKey('clientSecret')),
      'live-secret-corrected',
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('settingsMessage')), findsNothing);
    // Retracted, not silently re-held: the pair in memory is still the one
    // that was actually confirmed. Saying nothing is honest; saying "Held"
    // about text the human has since changed is not.
    expect(state.liveCredentials?.clientSecret, 'live-secret');

    // And the other field. Held again first, on purpose: with `_message`
    // already null there is nothing to retract, so an edit here would assert
    // findsNothing against a row that was never going to be there -- green
    // whether or not clientId retracts anything.
    await tester.tap(find.byKey(const ValueKey('useForThisSession')));
    await tester.pumpAndSettle();
    expect(_message(tester), contains('Held for this session'));

    await tester.enterText(find.byKey(const ValueKey('clientId')), 'live-id-2');
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('settingsMessage')), findsNothing);
  });

  testWidgets('the gate can be backed out of', (tester) async {
    // Once the gate is open there is otherwise no way out of it: the
    // environment is still Test, so Test is the selected segment, and
    // SegmentedButton makes tapping the already-selected one a no-op. An
    // unlabelled dead end, on the one screen whose job is to be unambiguous.
    final state = fakeEnvironment();
    await tester.pumpWidget(
      _settingsIn(state, store: SecretStore(backend: InMemorySecretBackend())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Live'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('liveConfirm')), 'LIVE');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('cancelLive')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('liveConfirm')), findsNothing);
    expect(state.environment, DemoEnvironment.test);

    // And it does not come back armed with the word still in it.
    await tester.tap(find.text('Live'));
    await tester.pumpAndSettle();
    expect(_enabled(tester, 'Switch to Live'), isFalse);
  });

  testWidgets('a gate reopened after a trip through Live is not pre-armed', (
    tester,
  ) async {
    // The door task 04 opens. A second surface drives the same state into
    // Live, which hides this screen's gate without closing it, and back to
    // Test, which shows it again -- with LIVE still typed, so the red button
    // is armed on arrival, one stray tap from production.
    final state = fakeEnvironment();
    await tester.pumpWidget(
      _settingsIn(state, store: SecretStore(backend: InMemorySecretBackend())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Live'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('liveConfirm')), 'LIVE');
    await tester.pumpAndSettle();

    // Not this screen's button: something else moved the environment.
    await state.enterLive(liveConfirmationWord);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('liveConfirm')), findsNothing);

    await tester.tap(find.text('Test'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Live'));
    await tester.pumpAndSettle();

    expect(_fieldText(tester, 'liveConfirm'), '');
    expect(_enabled(tester, 'Switch to Live'), isFalse);
  });

  testWidgets('a second tap mid-switch cannot un-gate the first', (
    tester,
  ) async {
    // `onSelectionChanged: _busy ? null : ...` disables the widget on the
    // NEXT build, so two taps inside one frame both reach the handler. The
    // second one gets `switchAlreadyInProgress` back and then, on its way
    // out, sets `_busy = false` underneath a switch that is still awaiting
    // the SDK -- re-enabling the toggle mid-flight and putting a refusal on
    // screen for a switch that has not failed.
    final parked = _ParkedSwitch(PayCrossEnvironment.sandbox);
    await tester.pumpWidget(
      await _liveSettings(
        state: parked.state,
        store: SecretStore(backend: InMemorySecretBackend()),
      ),
    );
    await tester.pumpAndSettle();

    // Both inside one frame: no pump between them.
    await tester.tap(find.text('Test'));
    await tester.tap(find.text('Test'), warnIfMissed: false);
    await tester.pump();

    // Mid-switch. The SDK has not answered, so nothing has failed and the
    // toggle must still be shut.
    expect(find.byKey(const ValueKey('settingsMessage')), findsNothing);
    expect(
      tester
          .widget<SegmentedButton<DemoEnvironment>>(
            find.byKey(const ValueKey('environmentToggle')),
          )
          .onSelectionChanged,
      isNull,
    );

    parked.gate.complete();
    await tester.pumpAndSettle();
    expect(parked.state.environment, DemoEnvironment.test);
  });

  testWidgets('a second tap mid-enter cannot report a refusal', (tester) async {
    // The same shape on the way in, where it is worse: the refusal on screen
    // would be for a switch to production that is still in flight and about
    // to succeed.
    //
    // Tall on purpose. The open gate adds a paragraph, a field and two
    // buttons, which pushes `settingsMessage` past the bottom of the default
    // 800x600 view -- and a `findsNothing` that passes because a ListView
    // never built the row is a green assertion that checks nothing.
    useTallSurface(tester);
    final parked = _ParkedSwitch(PayCrossEnvironment.production);
    await tester.pumpWidget(
      _settingsIn(
        parked.state,
        store: SecretStore(backend: InMemorySecretBackend()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Live'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('liveConfirm')), 'LIVE');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('switchToLive')));
    await tester.tap(
      find.byKey(const ValueKey('switchToLive')),
      warnIfMissed: false,
    );
    // Twice: the refused second call resolves on a microtask, and one pump
    // is not a guaranteed chance for it to land before the frame is drawn.
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('settingsMessage')), findsNothing);

    parked.gate.complete();
    await tester.pumpAndSettle();
    expect(parked.state.environment, DemoEnvironment.live);
  });

  testWidgets('a revealed secret does not stay revealed across a crossing', (
    tester,
  ) async {
    // Reveal is a decision taken about a sandbox secret, in a room the human
    // judged safe for one. Carrying it into Live renders the PRODUCTION
    // secret in plaintext by inheritance from that decision, in the one mode
    // where a shoulder over the shoulder costs real money.
    final state = fakeEnvironment();
    await tester.pumpWidget(
      _settingsIn(state, store: SecretStore(backend: InMemorySecretBackend())),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('revealSecret')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('clientSecret')))
          .obscureText,
      isFalse,
    );

    await tester.tap(find.text('Live'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('liveConfirm')), 'LIVE');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('switchToLive')));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('clientSecret')))
          .obscureText,
      isTrue,
    );
  });

  testWidgets('the dead switch says why it is dead, where it is dead', (
    tester,
  ) async {
    // A dimmed button with no reason attached is a dead end for a screen
    // reader: the instruction that explains it is a separate Text two
    // siblings up, reachable only by swiping back. The Test branch already
    // does this properly -- "Reading saved credentials…" sits inside the Wrap
    // beside the buttons it explains, and says so in a comment -- and the
    // gate did not inherit that care.
    final semantics = tester.ensureSemantics();
    final state = fakeEnvironment();
    await tester.pumpWidget(
      _settingsIn(state, store: SecretStore(backend: InMemorySecretBackend())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Live'));
    await tester.pumpAndSettle();

    expect(
      tester.getSemantics(find.byKey(const ValueKey('switchToLive'))).hint,
      contains(liveConfirmationWord),
    );

    // And it stops nagging once the word is there and the button is live.
    await tester.enterText(find.byKey(const ValueKey('liveConfirm')), 'LIVE');
    await tester.pumpAndSettle();

    expect(
      tester.getSemantics(find.byKey(const ValueKey('switchToLive'))).hint,
      isEmpty,
    );
    semantics.dispose();
  });

  testWidgets('typing in Test does not take away the last outcome', (
    tester,
  ) async {
    // The retraction is a Live rule and has to stay one. In Test the message
    // is a report of what just happened -- "Saved.", "Could not save:
    // StateError", the refusal below -- and it is exactly what the human is
    // reading while they fix the thing it names. Taking it away on the first
    // keystroke of the fix would delete the instructions mid-sentence.
    await tester.pumpWidget(
      _settings(store: SecretStore(backend: InMemorySecretBackend())),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(_message(tester), contains('client ID'));

    await tester.enterText(find.byKey(const ValueKey('clientId')), 'id-1');
    await tester.pumpAndSettle();

    expect(_message(tester), contains('client ID'));
  });
}
