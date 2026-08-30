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
