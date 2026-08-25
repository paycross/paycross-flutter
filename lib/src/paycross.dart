import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

import 'environment.dart';
import 'errors.dart';
import 'generated/paycross_api.g.dart' as g;
import 'recovery.dart';
import 'result.dart';
import 'test_card_prefill.dart';

/// The PayCross SDK.
///
/// ```dart
/// PayCross.configure(environment: PayCrossEnvironment.sandbox);
///
/// final result = await PayCross.presentPayment(sessionToken);
/// switch (result) {
///   case PayCrossSuccess(:final transactionId): await fulfil(transactionId);
///   case PayCrossFailure(:final recovery) when recovery.isRetryable: retry();
///   case PayCrossFailure(): showDeclined();
///   case PayCrossCancelled(): break;
/// }
/// ```
///
/// The card form, 3-D Secure and status polling all run in the native SDK. No
/// card data passes through Dart, which is deliberate: it keeps the PAN out of
/// the Flutter engine's heap and out of any platform-channel trace.
abstract final class PayCross {
  static g.PayCrossHostApi _api = g.PayCrossHostApi();

  /// Replaces the platform binding with a fake.
  ///
  /// `flutter test` runs with no engine, so an unfaked call throws a channel
  /// error. Pigeon's generated client is a plain class, so a test subclasses it
  /// and overrides the three methods - which is what Pigeon now recommends over
  /// its own (deprecated) generated test handler.
  @visibleForTesting
  static set debugHostApi(g.PayCrossHostApi api) => _api = api;

  /// Guards against two overlapping payments from Dart.
  ///
  /// The native side enforces this too, process-wide. This one exists so the
  /// common case fails fast with a Dart stack trace pointing at the caller.
  static bool _inFlight = false;

  /// Points the SDK at an environment. Call once, before [presentPayment].
  ///
  /// [brandColorArgb] currently applies on Android only; the iOS SDK exposes
  /// no brand-colour hook, so it is ignored there.
  ///
  /// [googlePayMerchantId] is Android-only for now. It is the merchant id from
  /// the Google Business Console, and Google **requires** it for
  /// [PayCrossEnvironment.production] Google Pay requests; sandbox works
  /// without one. iOS ignores it until Apple Pay and Google Pay land there.
  ///
  /// Throws [PayCrossIntegrationError] if a payment is in flight, or if a test
  /// card prefill is supplied alongside [PayCrossEnvironment.production].
  static Future<void> configure({
    required PayCrossEnvironment environment,
    int? brandColorArgb,
    PayCrossTestCardPrefill? testCardPrefill,
    String? googlePayMerchantId,
  }) async {
    if (testCardPrefill != null &&
        environment == PayCrossEnvironment.production) {
      throw const PayCrossIntegrationError(
        PayCrossErrorCode.notConfigured,
        'A test card prefill cannot be used with the production environment.',
      );
    }

    return _guard(
      () => _api.configure(
        g.PcConfiguration(
          environment: environment == PayCrossEnvironment.sandbox
              ? g.PcEnvironment.sandbox
              : g.PcEnvironment.production,
          brandColorArgb: brandColorArgb,
          testCardPrefill: testCardPrefill == null
              ? null
              : g.PcTestCardPrefill(
                  cardholderName: testCardPrefill.cardholderName,
                  pan: testCardPrefill.pan,
                  expireMonth: testCardPrefill.expireMonth,
                  expireYear: testCardPrefill.expireYear,
                  cvv: testCardPrefill.cvv,
                  saveCard: testCardPrefill.saveCard,
                ),
          googlePayMerchantId: googlePayMerchantId,
        ),
      ),
    );
  }

  /// Presents the native payment sheet and resolves when the payment reaches a
  /// terminal state or the shopper cancels.
  ///
  /// **This can take minutes.** The server is polled for up to eight, and a 3-D
  /// Secure challenge waits on the shopper's bank. Do not wrap the returned
  /// Future in `Future.timeout`: a shorter timeout abandons a live payment
  /// while the native SDK keeps polling, and the card may still be charged.
  ///
  /// A decline is a [PayCrossFailure], not a thrown error. Anything thrown from
  /// here is a [PayCrossIntegrationError].
  static Future<PayCrossResult> presentPayment(String sessionToken) async {
    if (_inFlight) {
      throw const PayCrossIntegrationError(
        PayCrossErrorCode.busy,
        'A payment is already in flight.',
      );
    }
    _inFlight = true;
    try {
      return _toPublic(await _api.presentPayment(sessionToken));
    } on PlatformException catch (e) {
      throw PayCrossIntegrationError(
        payCrossErrorCodeFrom(e.code),
        e.message ?? 'The payment could not be presented.',
      );
    } finally {
      _inFlight = false;
    }
  }

  /// Plugin and native SDK versions, for support tickets.
  ///
  /// `nativeSdkVersion` is null on Android, which declares no version constant.
  static Future<({String pluginVersion, String? nativeSdkVersion})>
  versionInfo() async {
    final info = await _guard(() => _api.versionInfo());
    return (
      pluginVersion: info.pluginVersion,
      nativeSdkVersion: info.nativeSdkVersion,
    );
  }

  static Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on PlatformException catch (e) {
      throw PayCrossIntegrationError(
        payCrossErrorCodeFrom(e.code),
        e.message ?? 'The PayCross SDK rejected the call.',
      );
    }
  }

  static PayCrossResult _toPublic(g.PcPaymentResult raw) => switch (raw) {
    g.PcSuccess() => PayCrossSuccess(
      transactionId: raw.transactionId,
      status: raw.status,
      amount: PayCrossAmount(
        minorUnits: raw.amount.minorUnits,
        currencyCode: raw.amount.currencyCode,
      ),
    ),
    // The raw token is parsed here rather than crossing as an enum, so a
    // recovery value the server adds later degrades to "unrecognised, not
    // retryable" instead of being silently rewritten.
    g.PcFailure() => PayCrossFailure(
      transactionId: raw.transactionId,
      recovery: PayCrossRecovery.fromApiValue(raw.recovery),
    ),
    g.PcCancelled() => const PayCrossCancelled(),
  };
}
