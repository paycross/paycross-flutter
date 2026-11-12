import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const String _clientIdKey = 'paycross_demo_client_id';
const String _clientSecretKey = 'paycross_demo_client_secret';
const String _googlePayKey = 'paycross_demo_google_pay_merchant_id';

/// Credentials, held in memory; the only durable copy is in flutter_secure_storage. No toString or toJson, so none reaches a log.
class Credentials {
  const Credentials({
    required this.clientId,
    required this.clientSecret,
    this.googlePayMerchantId,
  });

  final String clientId;
  final String clientSecret;

  final String? googlePayMerchantId;
}

abstract interface class SecretBackend {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureStorageBackend implements SecretBackend {
  const SecureStorageBackend([this._storage = const FlutterSecureStorage()]);

  /// Keychain item stays on the writing device (no restore). Reads and deletes pass the same options.
  static const IOSOptions iosOptions = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
  );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) =>
      _storage.read(key: key, iOptions: iosOptions);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value, iOptions: iosOptions);

  @override
  Future<void> delete(String key) =>
      _storage.delete(key: key, iOptions: iosOptions);
}

class InMemorySecretBackend implements SecretBackend {
  final Map<String, String> entries = <String, String>{};

  @override
  Future<String?> read(String key) async => entries[key];

  @override
  Future<void> write(String key, String value) async => entries[key] = value;

  @override
  Future<void> delete(String key) async => entries.remove(key);
}

class SecretStore {
  const SecretStore({SecretBackend backend = const SecureStorageBackend()})
    // ignore: prefer_initializing_formals
    : _backend = backend;

  final SecretBackend _backend;

  Future<Credentials?> read() async {
    try {
      final id = await _backend.read(_clientIdKey);
      final secret = await _backend.read(_clientSecretKey);
      if (id == null || id.isEmpty || secret == null || secret.isEmpty) {
        return null;
      }
      final merchantId = await _backend.read(_googlePayKey);
      return Credentials(
        clientId: id,
        clientSecret: secret,
        googlePayMerchantId: (merchantId?.isEmpty ?? true) ? null : merchantId,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> write(Credentials credentials) async {
    try {
      await _backend.write(_clientIdKey, credentials.clientId);
      await _backend.write(_clientSecretKey, credentials.clientSecret);
      final merchantId = credentials.googlePayMerchantId;
      if (merchantId == null || merchantId.isEmpty) {
        await _backend.delete(_googlePayKey);
      } else {
        await _backend.write(_googlePayKey, merchantId);
      }
    } catch (_) {
      // A failed write can leave a new id beside the old secret; forget clears both, so the state reads as not configured.
      try {
        await forget();
        // Best effort: a failed forget must not hide the original error, which rethrow passes on.
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> forget() async {
    await _backend.delete(_clientIdKey);
    await _backend.delete(_clientSecretKey);
    await _backend.delete(_googlePayKey);
  }
}
