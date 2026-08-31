import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/endpoints.dart';
import 'package:paycross_demo/demo/environment.dart';
import 'package:paycross_demo/demo/minter.dart';
import 'package:paycross_demo/demo/secrets.dart';
import 'package:paycross_demo/demo/settings.dart';

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
      await liveApp(
        home: SettingsScreen(
          store: SecretStore(backend: InMemorySecretBackend()),
          verifyCredentials: (_) async => 'ok',
          readVersions: () async =>
              (demo: '0.1.0+1', plugin: '0.1.0', nativeSdk: 'unknown'),
        ),
      ),
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
      await liveApp(
        state: state,
        home: SettingsScreen(
          store: SecretStore(backend: InMemorySecretBackend()),
          verifyCredentials: (_) async => 'ok',
          readVersions: () async =>
              (demo: '0.1.0+1', plugin: '0.1.0', nativeSdk: 'unknown'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    state.useForThisSession(
      const Credentials(clientId: 'live-id', clientSecret: 'live-secret'),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Test'));
    await tester.pumpAndSettle();

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
      await liveApp(
        home: SettingsScreen(
          store: SecretStore(backend: backend),
          verifyCredentials: (_) async => 'ok',
          readVersions: () async =>
              (demo: '0.1.0+1', plugin: '0.1.0', nativeSdk: 'unknown'),
        ),
      ),
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
      await liveApp(
        home: SettingsScreen(
          store: SecretStore(backend: InMemorySecretBackend()),
          verifyCredentials: (_) async => 'ok',
          readVersions: () async =>
              (demo: '0.1.0+1', plugin: '0.1.0', nativeSdk: 'unknown'),
        ),
      ),
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
      await liveApp(
        state: state,
        home: SettingsScreen(
          store: SecretStore(backend: backend),
          verifyCredentials: (_) async => 'ok',
          readVersions: () async =>
              (demo: '0.1.0+1', plugin: '0.1.0', nativeSdk: 'unknown'),
        ),
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
    expect(backend.entries, isEmpty);
  });

  testWidgets('a Live session with half a credential is refused', (
    tester,
  ) async {
    final state = fakeEnvironment();
    await tester.pumpWidget(
      await liveApp(
        state: state,
        home: SettingsScreen(
          store: SecretStore(backend: InMemorySecretBackend()),
          verifyCredentials: (_) async => 'ok',
          readVersions: () async =>
              (demo: '0.1.0+1', plugin: '0.1.0', nativeSdk: 'unknown'),
        ),
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
      await liveApp(
        state: state,
        home: SettingsScreen(
          store: SecretStore(backend: backend),
          verifyCredentials: (_) async => 'ok',
          readVersions: () async =>
              (demo: '0.1.0+1', plugin: '0.1.0', nativeSdk: 'unknown'),
        ),
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
  });

  testWidgets('Live lays out and scrolls at ordinary phone width', (
    tester,
  ) async {
    // The switch, the gate field and the banner all landed on a screen that
    // was already a long list. An overflow stripe is an exception in a widget
    // test, and the default 800x600 surface every other case here uses is
    // wider than any phone.
    usePhoneSurface(tester);
    final state = fakeEnvironment();
    await tester.pumpWidget(
      await liveApp(
        state: state,
        home: SettingsScreen(
          store: SecretStore(backend: InMemorySecretBackend()),
          verifyCredentials: (_) async => 'ok',
          readVersions: () async =>
              (demo: '0.1.0+1', plugin: '0.1.0', nativeSdk: 'unknown'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('useForThisSession')),
      200,
      // Named, unlike Home's copy of this test, which lets it default to the
      // only `Scrollable` on that screen. Settings has three: the `ListView`
      // and one inside each `TextField`, since `EditableText` scrolls its own
      // content. The default finder matches all three and throws "Too many
      // elements" before it scrolls anything. The `ListView` is the outermost
      // of them, so it is the first in a depth-first walk.
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const ValueKey('useForThisSession')), findsOneWidget);

    // And the gate, which is the one piece of this task that is never on
    // screen in Live: it lives on the Test side of the switch, so reaching it
    // means going back through it first.
    await tester.tap(find.text('Test'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Live'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('liveConfirm')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
