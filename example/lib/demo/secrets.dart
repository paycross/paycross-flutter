import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const String _clientIdKey = 'paycross_demo_client_id';
const String _clientSecretKey = 'paycross_demo_client_secret';
const String _googlePayKey = 'paycross_demo_google_pay_merchant_id';

/// The demo's merchant credentials.
///
/// Held in memory for as long as a screen needs them and nowhere else. The
/// only durable copy is in `flutter_secure_storage`; there is deliberately
/// no `toString`/`toJson` on this class, so a credential cannot reach a log
/// or a bug report by being interpolated into a string.
class Credentials {
  const Credentials({
    required this.clientId,
    required this.clientSecret,
    this.googlePayMerchantId,
  });

  final String clientId;
  final String clientSecret;

  /// Android-only, and optional: sandbox Google Pay works without one.
  final String? googlePayMerchantId;
}

/// The narrow slice of a secure store this app uses.
///
/// One interface so the widget tests never reach a platform channel, and so
/// the "every read is guarded" rule lives in exactly one place above it
/// rather than at every call site.
abstract interface class SecretBackend {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Keychain on iOS, EncryptedSharedPreferences on Android.
class SecureStorageBackend implements SecretBackend {
  const SecureStorageBackend([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// A [SecretBackend] in a Map. Tests only.
class InMemorySecretBackend implements SecretBackend {
  final Map<String, String> entries = <String, String>{};

  @override
  Future<String?> read(String key) async => entries[key];

  @override
  Future<void> write(String key, String value) async => entries[key] = value;

  @override
  Future<void> delete(String key) async => entries.remove(key);
}

/// Where the demo's credentials live.
///
/// Every read is guarded and answers null on any failure. A wiped store, an
/// undecryptable one and an empty one are indistinguishable from here, and
/// all three mean the same thing to the app: not configured, go to Settings.
/// That is the load-bearing rule -- it holds whatever the storage plugin's
/// `resetOnError` default happens to be in the version resolved today.
class SecretStore {
  const SecretStore({SecretBackend backend = const SecureStorageBackend()})
    // The lint's own fix does not compile: Dart forbids a private NAMED
    // parameter, so `this._backend` cannot appear in a `{...}` list, and a
    // public backend is not what this class is for.
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
      // Three keys, written in turn, so a failure part-way can leave a new
      // id beside the old secret. That pair is worse than an empty store:
      // it reads back as configured, so nothing sends the human to Settings,
      // and it can never authenticate. "Not configured" is the only state
      // this class can still promise, and the guarded read already knows how
      // to answer it.
      try {
        await forget();
      } catch (_) {
        // The store is beyond reach entirely. The write's own failure is the
        // one worth reporting, so let it be the one that escapes.
      }
      rethrow;
    }
  }

  Future<void> forget() async {
    await _backend.delete(_clientIdKey);
    await _backend.delete(_clientSecretKey);
    await _backend.delete(_googlePayKey);
  }
}
