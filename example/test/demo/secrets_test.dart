import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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

/// Fails the write of one named key and no other, which is how a store runs
/// out of room or loses its key part-way through a multi-key write.
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
    // The iOS mirror of the Android backup exclusion. An item written with
    // the plugin's default accessibility migrates to a new device on a
    // restore, where it belongs to a different install of the app --
    // exactly what data_extraction_rules.xml stops on the other platform.
    // `first_unlock` rather than `unlocked` so a launch before the first
    // manual unlock can still read it.
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

      // The dangerous state is not an empty store, it is `new-id` sitting
      // beside `old-secret`: a pair that reads back as configured, so nothing
      // routes the human to Settings, and that can never authenticate.
      expect(await store.read(), isNull);
      expect(backend.entries, isEmpty);
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
