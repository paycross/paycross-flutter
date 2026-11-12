import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/secrets.dart';

class _ThrowingBackend implements SecretBackend {
  @override
  Future<String?> read(String key) async => throw StateError('no keychain');

  @override
  Future<void> write(String key, String value) async =>
      throw StateError('no keychain');

  @override
  Future<void> delete(String key) async => throw StateError('no keychain');
}

class _FailOneWriteBackend implements SecretBackend {
  _FailOneWriteBackend(this.failKey);

  final String failKey;
  final Map<String, String> entries = <String, String>{};

  @override
  Future<String?> read(String key) async => entries[key];

  @override
  Future<void> write(String key, String value) async {
    if (key == failKey) throw StateError('no keychain');
    entries[key] = value;
  }

  @override
  Future<void> delete(String key) async => entries.remove(key);
}

void main() {
  test('the Keychain item stays on the device that wrote it', () {
    expect(
      SecureStorageBackend.iosOptions.accessibility,
      KeychainAccessibility.first_unlock_this_device,
    );
  });

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

  test(
    'a write that fails half way leaves nothing, not a mismatched pair',
    () async {
      final backend = _FailOneWriteBackend('paycross_demo_client_secret');
      backend.entries['paycross_demo_client_id'] = 'old-id';
      backend.entries['paycross_demo_client_secret'] = 'old-secret';
      final store = SecretStore(backend: backend);

      await expectLater(
        store.write(
          const Credentials(clientId: 'new-id', clientSecret: 'new-secret'),
        ),
        throwsStateError,
      );

      expect(await store.read(), isNull);
      expect(backend.entries, isEmpty);
    },
  );

  test('half a credential is no credential', () async {
    final backend = InMemorySecretBackend();
    backend.entries['paycross_demo_client_id'] = 'id-1';
    final store = SecretStore(backend: backend);

    expect(await store.read(), isNull);
  });
}
