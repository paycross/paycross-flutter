import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/secrets.dart';

/// A store whose every read fails, which is what an iOS Runner without the
/// Keychain Sharing entitlement and an Android device whose KeyStore key was
/// lost both look like from Dart.
class _ThrowingBackend implements SecretBackend {
  @override
  Future<String?> read(String key) async => throw StateError('no keychain');

  @override
  Future<void> write(String key, String value) async =>
      throw StateError('no keychain');

  @override
  Future<void> delete(String key) async => throw StateError('no keychain');
}

void main() {
  test('an empty store reads as "not configured"', () async {
    final store = SecretStore(backend: InMemorySecretBackend());

    expect(await store.read(), isNull);
  });

  test('what is written comes back', () async {
    final store = SecretStore(backend: InMemorySecretBackend());

    await store.write(
      const Credentials(
        clientId: 'id-1',
        clientSecret: 'secret-1',
        googlePayMerchantId: 'gp-1',
      ),
    );
    final read = await store.read();

    expect(read?.clientId, 'id-1');
    expect(read?.clientSecret, 'secret-1');
    expect(read?.googlePayMerchantId, 'gp-1');
  });

  test('an absent Google Pay merchant id stays null, not empty', () async {
    final store = SecretStore(backend: InMemorySecretBackend());

    await store.write(
      const Credentials(clientId: 'id-1', clientSecret: 'secret-1'),
    );

    expect((await store.read())?.googlePayMerchantId, isNull);
  });

  test('forget leaves nothing behind', () async {
    final backend = InMemorySecretBackend();
    final store = SecretStore(backend: backend);
    await store.write(
      const Credentials(clientId: 'id-1', clientSecret: 'secret-1'),
    );

    await store.forget();

    expect(await store.read(), isNull);
    expect(backend.entries, isEmpty);
  });

  test(
    'a backend that throws reads as "not configured", never rethrows',
    () async {
      final store = SecretStore(backend: _ThrowingBackend());

      expect(await store.read(), isNull);
    },
  );

  test('half a credential is no credential', () async {
    final backend = InMemorySecretBackend();
    backend.entries['paycross_demo_client_id'] = 'id-1';
    final store = SecretStore(backend: backend);

    // A store holding an id and no secret cannot mint. Answering "not
    // configured" routes to Settings; answering a half-built Credentials
    // would fail later with an HTTP 401 that reads as a backend problem.
    expect(await store.read(), isNull);
  });
}
