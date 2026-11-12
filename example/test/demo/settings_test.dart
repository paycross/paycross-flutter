import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/appearance_store.dart';
import 'package:paycross_demo/demo/endpoints.dart';
import 'package:paycross_demo/demo/environment.dart';
import 'package:paycross_demo/demo/language.dart';
import 'package:paycross_demo/demo/minter.dart';
import 'package:paycross_demo/demo/secrets.dart';
import 'package:paycross_demo/demo/settings.dart';
import 'package:paycross_flutter/paycross_flutter.dart';

import '_environment.dart';
import '_surface.dart';

Widget _settings({
  required SecretStore store,
  Future<String> Function(Credentials)? verify,
  LanguageStore? languageStore,
  AppearanceStore? appearanceStore,
}) => MaterialApp(
  home: SettingsScreen(
    store: store,
    appearanceStore:
        appearanceStore ??
        AppearanceStore(backend: InMemoryAppearanceBackend()),
    languageStore:
        languageStore ?? LanguageStore(backend: InMemoryLanguageBackend()),
    verifyCredentials: verify ?? (_) async => 'ok',
    readVersions: () async =>
        (demo: '0.1.0+1', plugin: '0.1.0', nativeSdk: 'unknown'),
  ),
);

Widget _settingsIn(
  DemoEnvironmentState state, {
  required SecretStore store,
  Future<String> Function(Credentials)? verify,
}) => appWithEnvironment(
  state: state,
  home: SettingsScreen(
    store: store,
    appearanceStore: AppearanceStore(backend: InMemoryAppearanceBackend()),
    languageStore: LanguageStore(backend: InMemoryLanguageBackend()),
    verifyCredentials: verify ?? (_) async => 'ok',
    readVersions: () async =>
        (demo: '0.1.0+1', plugin: '0.1.0', nativeSdk: 'unknown'),
  ),
);

Future<Widget> _liveSettings({
  required SecretStore store,
  DemoEnvironmentState? state,
}) => liveApp(
  state: state,
  home: SettingsScreen(
    store: store,
    appearanceStore: AppearanceStore(backend: InMemoryAppearanceBackend()),
    languageStore: LanguageStore(backend: InMemoryLanguageBackend()),
    verifyCredentials: (_) async => 'ok',
    readVersions: () async =>
        (demo: '0.1.0+1', plugin: '0.1.0', nativeSdk: 'unknown'),
  ),
);

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

Future<void> _revealLanguageToggle(WidgetTester tester) =>
    _reveal(tester, const ValueKey('languageToggle'));

Future<void> _revealSettingsMessage(WidgetTester tester) =>
    _reveal(tester, const ValueKey('settingsMessage'), delta: -200);

Future<void> _reveal(WidgetTester tester, Key key, {double delta = 200}) =>
    tester.scrollUntilVisible(
      find.byKey(key),
      delta,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );

class _NeverAnsweringLanguageBackend implements LanguageBackend {
  final Completer<String?> gate = Completer<String?>();

  @override
  Future<String?> read() => gate.future;

  @override
  Future<void> write(String value) async {}
}

class _NeverAnsweringAppearanceBackend implements AppearanceBackend {
  final Completer<String?> gate = Completer<String?>();

  @override
  Future<String?> read() => gate.future;

  @override
  Future<void> write(String value) async {}
}

class _FailingAppearanceBackend implements AppearanceBackend {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async => throw StateError('no preferences');
}

class _FailingLanguageBackend implements LanguageBackend {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async => throw StateError('no preferences');
}

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

DemoEnvironmentState _stuckInLive() => DemoEnvironmentState(
  configure:
      ({
        required PayCrossEnvironment environment,
        String? googlePayMerchantId,
        String? applePayMerchantId,
        PayCrossAppearance? appearance,
        String? locale,
      }) async {
        if (environment == PayCrossEnvironment.sandbox) {
          throw StateError('no channel');
        }
      },
);

class _ParkedSwitch {
  _ParkedSwitch(this.parkOn);

  final PayCrossEnvironment parkOn;
  final Completer<void> gate = Completer<void>();

  late final DemoEnvironmentState state = DemoEnvironmentState(
    configure:
        ({
          required PayCrossEnvironment environment,
          String? googlePayMerchantId,
          String? applePayMerchantId,
          PayCrossAppearance? appearance,
          String? locale,
        }) async {
          if (environment == parkOn) await gate.future;
        },
  );
}

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

String? _errorOn(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(ValueKey(key))).decoration!.errorText;

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
    await tester.pumpWidget(
      _settings(store: SecretStore(backend: InMemorySecretBackend())),
    );
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('googlePayMerchantId')),
        matching: find.textContaining('restart the app'),
      ),
      findsOneWidget,
    );
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

    expect(_enabled(tester, 'Save'), isFalse);
    expect(find.text('Reading saved credentials…'), findsOneWidget);

    backend.gate.complete();
    await tester.pumpAndSettle();

    expect(find.text('Reading saved credentials…'), findsNothing);
    expect(_enabled(tester, 'Save'), isTrue);
  });

  testWidgets('choosing Live does not switch on its own', (tester) async {
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

    expect(state.environment, DemoEnvironment.test);
    expect(state.liveCredentials, isNull);
    expect(find.byKey(const ValueKey('liveBanner')), findsNothing);
  });

  testWidgets('Settings opened in Live never prefills the stored credential', (
    tester,
  ) async {
    final backend = _CountingBackend()
      ..entries['paycross_demo_client_id'] = 'test-id'
      ..entries['paycross_demo_client_secret'] = 'test-secret'
      ..entries['paycross_demo_google_pay_merchant_id'] = 'gp-1';

    await tester.pumpWidget(
      await _liveSettings(store: SecretStore(backend: backend)),
    );
    await tester.pumpAndSettle();

    expect(_fieldText(tester, 'clientId'), '');
    expect(_fieldText(tester, 'clientSecret'), '');

    await tester.tap(find.text('Test'));
    await tester.pumpAndSettle();

    expect(_fieldText(tester, 'clientId'), 'test-id');
    expect(_fieldText(tester, 'clientSecret'), 'test-secret');
  });

  testWidgets('Live hides Save, Verify, Forget and the wallet id', (
    tester,
  ) async {
    useTallSurface(tester);
    await tester.pumpWidget(
      await _liveSettings(store: SecretStore(backend: InMemorySecretBackend())),
    );
    await tester.pumpAndSettle();

    expect(find.text('Save'), findsNothing);
    expect(find.text('Verify credentials'), findsNothing);
    expect(find.text('Forget credentials'), findsNothing);
    expect(find.byKey(const ValueKey('googlePayMerchantId')), findsNothing);
    expect(find.byKey(const ValueKey('useForThisSession')), findsOneWidget);
    expect(find.byKey(const ValueKey('clientId')), findsOneWidget);
    expect(find.byKey(const ValueKey('clientSecret')), findsOneWidget);
    expect(find.byKey(const ValueKey('liveName')), findsOneWidget);
    expect(find.byKey(const ValueKey('liveEmail')), findsOneWidget);
    expect(find.byKey(const ValueKey('liveCurrency')), findsNothing);
    expect(find.byKey(const ValueKey('liveAmountNote')), findsOneWidget);
  });

  testWidgets('Test never asks for a name or an email', (tester) async {
    useTallSurface(tester);
    final state = fakeEnvironment();
    await tester.pumpWidget(
      _settingsIn(state, store: SecretStore(backend: InMemorySecretBackend())),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('liveName')), findsNothing);
    expect(find.byKey(const ValueKey('liveEmail')), findsNothing);
    expect(find.byKey(const ValueKey('liveAmountNote')), findsNothing);
    expect(find.byKey(const ValueKey('googlePayMerchantId')), findsOneWidget);

    await tester.tap(find.text('Live'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('liveConfirm')), 'LIVE');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('switchToLive')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('liveName')), findsOneWidget);
    expect(find.byKey(const ValueKey('liveEmail')), findsOneWidget);
    expect(find.byKey(const ValueKey('liveAmountNote')), findsOneWidget);
  });

  testWidgets('Live says where the amount and the currency now live', (
    tester,
  ) async {
    useTallSurface(tester);
    await tester.pumpWidget(
      await _liveSettings(store: SecretStore(backend: InMemorySecretBackend())),
    );
    await tester.pumpAndSettle();

    final note = tester
        .widget<Text>(find.byKey(const ValueKey('liveAmountNote')))
        .data!;

    expect(note, contains('amount'));
    expect(note, contains('currency'));
    expect(note, contains('pencil'));
    expect(note, contains('Save'));
  });

  testWidgets('a Live credential reaches memory and nothing else', (
    tester,
  ) async {
    useTallSurface(tester);
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
    await tester.enterText(
      find.byKey(const ValueKey('liveName')),
      'Ada Lovelace',
    );
    await tester.enterText(
      find.byKey(const ValueKey('liveEmail')),
      'ada@example.org',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('useForThisSession')));
    await tester.pumpAndSettle();

    expect(state.liveCredentials?.clientId, 'live-id');
    expect(state.liveCredentials?.clientSecret, 'live-secret');
    expect(state.liveIdentity?.firstName, 'Ada');
    expect(state.liveIdentity?.lastName, 'Lovelace');
    expect(state.liveIdentity?.email, 'ada@example.org');
    expect(backend.writes, 0);
    expect(backend.deletes, 0);
    expect(backend.entries, isEmpty);
  });

  testWidgets(
    'a Live session with half a credential cannot be started at all',
    (tester) async {
      useTallSurface(tester);
      final state = fakeEnvironment();
      await tester.pumpWidget(
        await _liveSettings(
          state: state,
          store: SecretStore(backend: InMemorySecretBackend()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const ValueKey('clientId')), 'live-id');
      await tester.pumpAndSettle();

      expect(_enabled(tester, 'Use for this session'), isFalse);
      expect(state.liveCredentials, isNull);
      expect(state.liveIdentity, isNull);
    },
  );

  testWidgets('the session button is dead until all four fields are right', (
    tester,
  ) async {
    useTallSurface(tester);
    final state = fakeEnvironment();
    await tester.pumpWidget(
      await _liveSettings(
        state: state,
        store: SecretStore(backend: InMemorySecretBackend()),
      ),
    );
    await tester.pumpAndSettle();

    expect(_enabled(tester, 'Use for this session'), isFalse);
    await tester.enterText(find.byKey(const ValueKey('clientId')), 'live-id');
    await tester.pumpAndSettle();
    expect(_enabled(tester, 'Use for this session'), isFalse);
    await tester.enterText(
      find.byKey(const ValueKey('clientSecret')),
      'live-secret',
    );
    await tester.pumpAndSettle();
    expect(_enabled(tester, 'Use for this session'), isFalse);
    await tester.enterText(
      find.byKey(const ValueKey('liveName')),
      'Ada Lovelace',
    );
    await tester.pumpAndSettle();
    expect(_enabled(tester, 'Use for this session'), isFalse);

    await tester.enterText(
      find.byKey(const ValueKey('liveEmail')),
      'ada@example.org',
    );
    await tester.pumpAndSettle();
    expect(_enabled(tester, 'Use for this session'), isTrue);

    await tester.enterText(find.byKey(const ValueKey('liveEmail')), 'ada');
    await tester.pumpAndSettle();
    expect(_enabled(tester, 'Use for this session'), isFalse);
  });

  testWidgets('a one-word name says so on its own field', (tester) async {
    final state = fakeEnvironment();
    await tester.pumpWidget(
      await _liveSettings(
        state: state,
        store: SecretStore(backend: InMemorySecretBackend()),
      ),
    );
    await tester.pumpAndSettle();

    expect(_errorOn(tester, 'liveName'), isNull);

    await tester.enterText(find.byKey(const ValueKey('liveName')), 'Ada');
    await tester.pumpAndSettle();

    expect(_errorOn(tester, 'liveName'), isNotNull);
    expect(_errorOn(tester, 'liveEmail'), isNull);

    await tester.enterText(
      find.byKey(const ValueKey('liveName')),
      'Ada Lovelace',
    );
    await tester.pumpAndSettle();

    expect(_errorOn(tester, 'liveName'), isNull);
  });

  testWidgets('an address with no @ says so on its own field', (tester) async {
    final state = fakeEnvironment();
    await tester.pumpWidget(
      await _liveSettings(
        state: state,
        store: SecretStore(backend: InMemorySecretBackend()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const ValueKey('liveEmail')), 'ada');
    await tester.pumpAndSettle();

    expect(_errorOn(tester, 'liveEmail'), isNotNull);
    expect(_errorOn(tester, 'liveName'), isNull);

    await tester.enterText(
      find.byKey(const ValueKey('liveEmail')),
      'ada@example.org',
    );
    await tester.pumpAndSettle();

    expect(_errorOn(tester, 'liveEmail'), isNull);
  });

  testWidgets('a trip through Test empties the name and the email', (
    tester,
  ) async {
    useTallSurface(tester);
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
    await tester.enterText(
      find.byKey(const ValueKey('liveName')),
      'Ada Lovelace',
    );
    await tester.enterText(
      find.byKey(const ValueKey('liveEmail')),
      'ada@example.org',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('useForThisSession')));
    await tester.pumpAndSettle();
    expect(state.liveIdentity, isNotNull);

    await tester.tap(find.text('Test'));
    await tester.pumpAndSettle();
    expect(state.liveIdentity, isNull);

    await tester.tap(find.text('Live'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('liveConfirm')), 'LIVE');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('switchToLive')));
    await tester.pumpAndSettle();

    expect(_fieldText(tester, 'liveName'), '');
    expect(_fieldText(tester, 'liveEmail'), '');
  });

  testWidgets('switching to Live empties what Test had on screen', (
    tester,
  ) async {
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
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('useForThisSession')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const ValueKey('useForThisSession')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('environmentToggle')),
      -200,
      scrollable: find.byType(Scrollable).first,
    );

    await tester.tap(find.text('Test'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Live'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('liveConfirm')), findsOneWidget);
    expect(tester.takeException(), isNull);

    final list = tester.widget<Scrollable>(find.byType(Scrollable).first);
    expect(list.controller!.position.maxScrollExtent, greaterThan(0));

    await tester.scrollUntilVisible(
      find.text('Forget credentials'),
      200,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.text('Forget credentials'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an exit the SDK refused is reported in full, not summarised', (
    tester,
  ) async {
    useTallSurface(tester);
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
    expect(_message(tester), endsWith('Still in Live — restart the app.'));

    expect(state.liveCredentials, isNull);
    expect(state.environment, DemoEnvironment.live);
    expect(find.byKey(const ValueKey('liveBanner')), findsOneWidget);
  });

  testWidgets('a store read still in flight cannot refill a Live screen', (
    tester,
  ) async {
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

    backend.gate.complete();
    await tester.pumpAndSettle();

    expect(state.isLive, isTrue);
    expect(_fieldText(tester, 'clientId'), '');
    expect(_fieldText(tester, 'clientSecret'), '');
  });

  testWidgets('a reload started on the way to Test cannot refill Live either', (
    tester,
  ) async {
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
      final backend = _SlowBackend()
        ..entries['paycross_demo_client_id'] = 'test-id'
        ..entries['paycross_demo_client_secret'] = 'test-secret';
      final state = fakeEnvironment();
      await tester.pumpWidget(
        _settingsIn(state, store: SecretStore(backend: backend)),
      );
      await tester.pump();

      await state.enterLive(liveConfirmationWord);
      await tester.pumpAndSettle();

      backend.gate.complete();
      await tester.pumpAndSettle();

      expect(state.isLive, isTrue);
      expect(_fieldText(tester, 'clientId'), '');
      expect(_fieldText(tester, 'clientSecret'), '');
    },
  );

  testWidgets('editing anything retracts the claim that a session is held', (
    tester,
  ) async {
    useTallSurface(tester);
    final state = fakeEnvironment();
    await tester.pumpWidget(
      await _liveSettings(
        state: state,
        store: SecretStore(backend: InMemorySecretBackend()),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> hold() async {
      await tester.tap(find.byKey(const ValueKey('useForThisSession')));
      await tester.pumpAndSettle();
      expect(_message(tester), contains('Held for this session'));
    }

    await tester.enterText(find.byKey(const ValueKey('clientId')), 'live-id');
    await tester.enterText(
      find.byKey(const ValueKey('clientSecret')),
      'live-secret',
    );
    await tester.enterText(
      find.byKey(const ValueKey('liveName')),
      'Ada Lovelace',
    );
    await tester.enterText(
      find.byKey(const ValueKey('liveEmail')),
      'ada@example.org',
    );
    await tester.pumpAndSettle();
    await hold();

    await tester.enterText(
      find.byKey(const ValueKey('clientSecret')),
      'live-secret-corrected',
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('settingsMessage')), findsNothing);
    expect(state.liveCredentials?.clientSecret, 'live-secret');

    await hold();
    await tester.enterText(find.byKey(const ValueKey('clientId')), 'live-id-2');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settingsMessage')), findsNothing);

    await hold();
    await tester.enterText(
      find.byKey(const ValueKey('liveName')),
      'Ada B. Lovelace',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settingsMessage')), findsNothing);
    expect(state.liveIdentity?.firstName, 'Ada');

    await hold();
    await tester.enterText(
      find.byKey(const ValueKey('liveEmail')),
      'ada.lovelace@example.org',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settingsMessage')), findsNothing);
  });

  testWidgets('the gate can be backed out of', (tester) async {
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

    await tester.tap(find.text('Live'));
    await tester.pumpAndSettle();
    expect(_enabled(tester, 'Switch to Live'), isFalse);
  });

  testWidgets('a gate reopened after a trip through Live is not pre-armed', (
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
    final parked = _ParkedSwitch(PayCrossEnvironment.sandbox);
    await tester.pumpWidget(
      await _liveSettings(
        state: parked.state,
        store: SecretStore(backend: InMemorySecretBackend()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Test'));
    await tester.tap(find.text('Test'), warnIfMissed: false);
    await tester.pump();

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

    await tester.enterText(find.byKey(const ValueKey('liveConfirm')), 'LIVE');
    await tester.pumpAndSettle();

    expect(
      tester.getSemantics(find.byKey(const ValueKey('switchToLive'))).hint,
      isEmpty,
    );
    semantics.dispose();
  });

  testWidgets('the dead session button says why it is dead, where it is dead', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    useTallSurface(tester);
    final state = fakeEnvironment();
    await tester.pumpWidget(
      await _liveSettings(
        state: state,
        store: SecretStore(backend: InMemorySecretBackend()),
      ),
    );
    await tester.pumpAndSettle();

    final hint = tester
        .getSemantics(find.byKey(const ValueKey('useForThisSession')))
        .hint;
    expect(hint, isNotEmpty);
    expect(hint, contains('client ID'));
    expect(hint, contains('client secret'));
    expect(hint, contains('name'));
    expect(hint, contains('email'));
    expect(find.text(hint), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('clientId')), 'live-id');
    await tester.enterText(
      find.byKey(const ValueKey('clientSecret')),
      'live-secret',
    );
    await tester.enterText(
      find.byKey(const ValueKey('liveName')),
      'Ada Lovelace',
    );
    await tester.enterText(
      find.byKey(const ValueKey('liveEmail')),
      'ada@example.org',
    );
    await tester.pumpAndSettle();

    expect(_enabled(tester, 'Use for this session'), isTrue);
    expect(
      tester.getSemantics(find.byKey(const ValueKey('useForThisSession'))).hint,
      isEmpty,
    );
    expect(find.text(hint), findsNothing);
    semantics.dispose();
  });

  testWidgets('typing in Test does not take away the last outcome', (
    tester,
  ) async {
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

  group('the payment sheet language', () {
    testWidgets('opens on the stored choice', (tester) async {
      final backend = InMemoryLanguageBackend();
      await LanguageStore(backend: backend).write(DemoLanguage.french);

      await tester.pumpWidget(
        _settings(
          store: SecretStore(backend: InMemorySecretBackend()),
          languageStore: LanguageStore(backend: backend),
        ),
      );
      await tester.pumpAndSettle();
      await _revealLanguageToggle(tester);

      final toggle = tester.widget<SegmentedButton<DemoLanguage>>(
        find.byKey(const ValueKey('languageToggle')),
      );
      expect(toggle.selected, {DemoLanguage.french});
    });

    testWidgets('opens on System when nothing was chosen', (tester) async {
      await tester.pumpWidget(
        _settings(store: SecretStore(backend: InMemorySecretBackend())),
      );
      await tester.pumpAndSettle();
      await _revealLanguageToggle(tester);

      final toggle = tester.widget<SegmentedButton<DemoLanguage>>(
        find.byKey(const ValueKey('languageToggle')),
      );
      expect(toggle.selected, {DemoLanguage.system});
    });

    testWidgets('choosing a language writes it', (tester) async {
      final backend = InMemoryLanguageBackend();

      await tester.pumpWidget(
        _settings(
          store: SecretStore(backend: InMemorySecretBackend()),
          languageStore: LanguageStore(backend: backend),
        ),
      );
      await tester.pumpAndSettle();
      await _revealLanguageToggle(tester);

      await tester.tap(find.text(DemoLanguage.french.label));
      await tester.pumpAndSettle();

      expect(backend.value, DemoLanguage.french.name);
      final toggle = tester.widget<SegmentedButton<DemoLanguage>>(
        find.byKey(const ValueKey('languageToggle')),
      );
      expect(toggle.selected, {DemoLanguage.french});
    });

    testWidgets('is dead until the stored choice has been read', (
      tester,
    ) async {
      final backend = _NeverAnsweringLanguageBackend();

      await tester.pumpWidget(
        _settings(
          store: SecretStore(backend: InMemorySecretBackend()),
          languageStore: LanguageStore(backend: backend),
        ),
      );
      await tester.pump();
      await _revealLanguageToggle(tester);

      final toggle = tester.widget<SegmentedButton<DemoLanguage>>(
        find.byKey(const ValueKey('languageToggle')),
      );
      expect(toggle.onSelectionChanged, isNull);
      expect(find.byKey(const ValueKey('languageLoading')), findsOneWidget);
    });

    testWidgets('the reason it was dead goes away once the read lands', (
      tester,
    ) async {
      await tester.pumpWidget(
        _settings(store: SecretStore(backend: InMemorySecretBackend())),
      );
      await tester.pumpAndSettle();
      await _revealLanguageToggle(tester);

      expect(find.byKey(const ValueKey('languageLoading')), findsNothing);
    });

    testWidgets('a write that fails is reported', (tester) async {
      await tester.pumpWidget(
        _settings(
          store: SecretStore(backend: InMemorySecretBackend()),
          languageStore: LanguageStore(backend: _FailingLanguageBackend()),
        ),
      );
      await tester.pumpAndSettle();
      await _revealLanguageToggle(tester);

      await tester.tap(find.text(DemoLanguage.french.label));
      await tester.pumpAndSettle();
      await _revealSettingsMessage(tester);

      expect(
        tester.widget<Text>(find.byKey(const ValueKey('settingsMessage'))).data,
        contains('language'),
      );
    });

    testWidgets('its heading is a heading', (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        _settings(store: SecretStore(backend: InMemorySecretBackend())),
      );
      await tester.pumpAndSettle();
      await _revealLanguageToggle(tester);

      expect(
        tester
            .getSemantics(find.byKey(const ValueKey('languageHeading')))
            .flagsCollection
            .isHeader,
        isTrue,
      );
      semantics.dispose();
    });

    testWidgets('is offered in Live as well as Test', (tester) async {
      await tester.pumpWidget(
        await _liveSettings(
          store: SecretStore(backend: InMemorySecretBackend()),
        ),
      );
      await tester.pumpAndSettle();
      await _revealLanguageToggle(tester);

      expect(find.byKey(const ValueKey('languageToggle')), findsOneWidget);
    });
  });

  group('the payment sheet appearance', () {
    testWidgets('every control is on the screen', (tester) async {
      useTallSurface(tester);
      await tester.pumpWidget(
        _settings(store: SecretStore(backend: InMemorySecretBackend())),
      );
      await tester.pumpAndSettle();

      for (final key in <String>[
        'brandLight',
        'brandDark',
        'appearanceThemeMode',
        'cornerRadius',
        'buttonCornerRadius',
        'fontScale',
        'appearancePreset',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
    });

    testWidgets('every control carries its semantics id', (tester) async {
      useTallSurface(tester);
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        _settings(store: SecretStore(backend: InMemorySecretBackend())),
      );
      await tester.pumpAndSettle();

      for (final field in <String>[
        'brandLight',
        'brandDark',
        'themeMode',
        'cornerRadius',
        'buttonCornerRadius',
        'fontScale',
        'preset',
      ]) {
        expect(
          find.bySemanticsIdentifier('settings.appearance.$field'),
          findsOneWidget,
          reason: field,
        );
      }
      semantics.dispose();
    });

    testWidgets('a stored theme is what the fields show', (tester) async {
      useTallSurface(tester);
      final backend = InMemoryAppearanceBackend();
      await AppearanceStore(
        backend: backend,
      ).write(DemoAppearance.themedPreset);

      await tester.pumpWidget(
        _settings(
          store: SecretStore(backend: InMemorySecretBackend()),
          appearanceStore: AppearanceStore(backend: backend),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('00875A'), findsOneWidget);
      expect(find.text('57D9A3'), findsOneWidget);
      expect(find.text('16'), findsOneWidget);
      expect(find.text('28'), findsOneWidget);
      final toggle = tester.widget<SegmentedButton<PayCrossThemeMode>>(
        find.byKey(const ValueKey('appearanceThemeMode')),
      );
      expect(toggle.selected, {PayCrossThemeMode.dark});
    });

    testWidgets('a typed colour is written', (tester) async {
      useTallSurface(tester);
      final backend = InMemoryAppearanceBackend();
      await tester.pumpWidget(
        _settings(
          store: SecretStore(backend: InMemorySecretBackend()),
          appearanceStore: AppearanceStore(backend: backend),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('brandLight')),
        '1E88E5',
      );
      await tester.pumpAndSettle();

      expect(
        DemoAppearance.fromJson(backend.value).brandLight,
        const Color(0xFF1E88E5),
      );
    });

    testWidgets('a chosen theme mode is written', (tester) async {
      useTallSurface(tester);
      final backend = InMemoryAppearanceBackend();
      await tester.pumpWidget(
        _settings(
          store: SecretStore(backend: InMemorySecretBackend()),
          appearanceStore: AppearanceStore(backend: backend),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text(themeModeLabel(PayCrossThemeMode.dark)));
      await tester.pumpAndSettle();

      expect(
        DemoAppearance.fromJson(backend.value).themeMode,
        PayCrossThemeMode.dark,
      );
    });

    testWidgets('an out-of-range font scale is refused, and said so', (
      tester,
    ) async {
      useTallSurface(tester);
      final backend = InMemoryAppearanceBackend();
      await tester.pumpWidget(
        _settings(
          store: SecretStore(backend: InMemorySecretBackend()),
          appearanceStore: AppearanceStore(backend: backend),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const ValueKey('fontScale')), '5');
      await tester.pumpAndSettle();

      expect(DemoAppearance.fromJson(backend.value).fontScale, isNull);
      expect(find.text('Between 0.8 and 1.3.'), findsOneWidget);
    });

    testWidgets('a scale inside the bound is written', (tester) async {
      useTallSurface(tester);
      final backend = InMemoryAppearanceBackend();
      await tester.pumpWidget(
        _settings(
          store: SecretStore(backend: InMemorySecretBackend()),
          appearanceStore: AppearanceStore(backend: backend),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const ValueKey('fontScale')), '1.2');
      await tester.pumpAndSettle();

      expect(DemoAppearance.fromJson(backend.value).fontScale, 1.2);
      expect(find.text('Between 0.8 and 1.3.'), findsNothing);
    });

    testWidgets('an empty field is not an error', (tester) async {
      useTallSurface(tester);
      await tester.pumpWidget(
        _settings(store: SecretStore(backend: InMemorySecretBackend())),
      );
      await tester.pumpAndSettle();

      expect(find.text('Between 0.8 and 1.3.'), findsNothing);
      expect(find.text('Six or eight hex digits, like 00875A.'), findsNothing);
      expect(find.text('Zero or more.'), findsNothing);
    });

    testWidgets('the preset button loads the themed tile and writes it', (
      tester,
    ) async {
      useTallSurface(tester);
      final backend = InMemoryAppearanceBackend();
      await tester.pumpWidget(
        _settings(
          store: SecretStore(backend: InMemorySecretBackend()),
          appearanceStore: AppearanceStore(backend: backend),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('appearancePreset')));
      await tester.pumpAndSettle();

      expect(
        DemoAppearance.fromJson(backend.value),
        DemoAppearance.themedPreset,
      );
      expect(DemoAppearance.fromJson(backend.value).fontScale, isNull);
      expect(find.text('00875A'), findsOneWidget);
    });

    testWidgets('the controls are dead until the stored theme has been read', (
      tester,
    ) async {
      useTallSurface(tester);
      await tester.pumpWidget(
        _settings(
          store: SecretStore(backend: InMemorySecretBackend()),
          appearanceStore: AppearanceStore(
            backend: _NeverAnsweringAppearanceBackend(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('brandLight')))
            .enabled,
        isFalse,
      );
      expect(
        tester
            .widget<SegmentedButton<PayCrossThemeMode>>(
              find.byKey(const ValueKey('appearanceThemeMode')),
            )
            .onSelectionChanged,
        isNull,
      );
      expect(find.byKey(const ValueKey('appearanceLoading')), findsOneWidget);
    });

    testWidgets('the reason it was dead goes away once the read lands', (
      tester,
    ) async {
      useTallSurface(tester);
      await tester.pumpWidget(
        _settings(store: SecretStore(backend: InMemorySecretBackend())),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('appearanceLoading')), findsNothing);
    });

    testWidgets('a write that fails is reported', (tester) async {
      useTallSurface(tester);
      await tester.pumpWidget(
        _settings(
          store: SecretStore(backend: InMemorySecretBackend()),
          appearanceStore: AppearanceStore(
            backend: _FailingAppearanceBackend(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text(themeModeLabel(PayCrossThemeMode.dark)));
      await tester.pumpAndSettle();

      expect(
        tester.widget<Text>(find.byKey(const ValueKey('settingsMessage'))).data,
        contains('appearance'),
      );
    });

    testWidgets('its heading is a heading', (tester) async {
      useTallSurface(tester);
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        _settings(store: SecretStore(backend: InMemorySecretBackend())),
      );
      await tester.pumpAndSettle();

      expect(
        tester
            .getSemantics(find.byKey(const ValueKey('appearanceHeading')))
            .flagsCollection
            .isHeader,
        isTrue,
      );
      semantics.dispose();
    });

    testWidgets('the section fits a phone', (tester) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(
        _settings(store: SecretStore(backend: InMemorySecretBackend())),
      );
      await tester.pumpAndSettle();
      await _reveal(tester, const ValueKey('appearanceThemeMode'), delta: 60);

      expect(find.byKey(const ValueKey('appearanceThemeMode')), findsOneWidget);
      expect(find.text(themeModeLabel(PayCrossThemeMode.dark)), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('is offered in Live as well as Test', (tester) async {
      useTallSurface(tester);
      await tester.pumpWidget(
        await _liveSettings(
          store: SecretStore(backend: InMemorySecretBackend()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('appearanceHeading')), findsOneWidget);
    });
  });
}
