import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/minter.dart';
import 'package:paycross_demo/demo/secrets.dart';
import 'package:paycross_demo/demo/settings.dart';

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

  testWidgets('says the app is sandbox-only', (tester) async {
    await tester.pumpWidget(
      _settings(store: SecretStore(backend: InMemorySecretBackend())),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Sandbox only'), findsOneWidget);
  });
}
