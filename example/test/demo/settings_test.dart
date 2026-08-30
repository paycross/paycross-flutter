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

    expect(find.text('Minted session sess-9.'), findsOneWidget);
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

  testWidgets('says the app is sandbox-only', (tester) async {
    await tester.pumpWidget(
      _settings(store: SecretStore(backend: InMemorySecretBackend())),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Sandbox only'), findsOneWidget);
  });
}
