import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

import 'appearance.dart';
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
///   case PayCrossPending(:final transactionId): reconcile(transactionId);
///   case PayCrossCancelled(): break;
/// }
/// ```
///
/// No card data passes through Dart: it keeps the PAN out of the Flutter engine heap and platform-channel traces.
abstract final class PayCross {
  static g.PayCrossHostApi _api = g.PayCrossHostApi();

  /// Replaces the platform binding, for tests.
  @visibleForTesting
  static set debugHostApi(g.PayCrossHostApi api) => _api = api;

  static bool _inFlight = false;

  /// Points the SDK at an environment. Call once, before [presentPayment].
  ///
  /// [appearance] themes the native payment sheets. A role left null falls back
  /// to the brand colour set on the merchant's PayCross account, then to the
  /// platform default.
  ///
  /// [brandColorArgb] is deprecated in favour of
  /// `appearance: PayCrossAppearance.brand(color)`. It is still honoured on its
  /// own, on both platforms.
  ///
  /// [locale] is a BCP 47 tag such as `fr` or `fr-CA` that pins the language of
  /// the native payment sheet. Null lets the session's locale decide. Both SDKs
  /// ship English and French.
  ///
  /// [googlePayMerchantId] is Android-only, and production Google Pay requests
  /// require it. [applePayMerchantId] is iOS-only: the Apple Merchant ID for the
  /// Apple Pay button. Null, empty or blank hides the button. It must match the
  /// ID saved on the merchant's PayCross account, or the payment is refused.
  ///
  /// Throws [PayCrossIntegrationError] with
  /// [PayCrossErrorCode.testPrefillInProduction] if [testCardPrefill] is
  /// supplied alongside [PayCrossEnvironment.production], with
  /// [PayCrossErrorCode.invalidAppearance] if [appearance] holds a value no
  /// sheet can draw, or with [PayCrossErrorCode.busy] if a payment is in
  /// flight.
  static Future<void> configure({
    required PayCrossEnvironment environment,
    @Deprecated(
      'Use appearance: PayCrossAppearance.brand(color). Passed beside an '
      'appearance that names no brand, this colour is merged into both '
      'palettes rather than dropped.',
    )
    int? brandColorArgb,
    PayCrossTestCardPrefill? testCardPrefill,
    String? googlePayMerchantId,
    String? applePayMerchantId,
    PayCrossAppearance? appearance,
    String? locale,
  }) async {
    if (testCardPrefill != null &&
        environment == PayCrossEnvironment.production) {
      throw const PayCrossIntegrationError(
        PayCrossErrorCode.testPrefillInProduction,
        'A test card prefill cannot be used with the production environment.',
      );
    }

    final crossing = _withLegacyBrand(appearance, brandColorArgb)?.toPigeon();

    return _guard(
      () => _api.configure(
        g.PcConfiguration(
          environment: environment == PayCrossEnvironment.sandbox
              ? g.PcEnvironment.sandbox
              : g.PcEnvironment.production,
          brandColorArgb: appearance == null ? brandColorArgb : null,
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
          applePayMerchantId: applePayMerchantId,
          appearance: crossing,
          locale: locale,
        ),
      ),
    );
  }

  /// Presents the native payment sheet and resolves when the payment reaches a
  /// terminal state or the shopper cancels.
  ///
  /// **This can take minutes.** Do not wrap the returned Future in
  /// `Future.timeout`: the native SDK keeps polling, so the card may still be
  /// charged after the timeout abandons the call.
  ///
  /// A decline is a [PayCrossFailure] and an unobserved outcome a
  /// [PayCrossPending]. A platform rejection is thrown as a [PayCrossIntegrationError].
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
      // Returned, not thrown: the payment may have been authorized.
      if (e.code == payCrossResultLostCode) {
        // Nothing was sent, so the plugin supplies the canonical name.
        return const PayCrossPending(
          transactionId: null,
          reason: PayCrossPendingReason.resultLost,
          reasonRaw: 'result_lost',
        );
      }
      throw PayCrossIntegrationError(
        payCrossErrorCodeFrom(e.code),
        e.message ?? 'The payment could not be presented.',
      );
    } finally {
      _inFlight = false;
    }
  }

  /// Plugin and native SDK versions. `nativeSdkVersion` is null on Android.
  static Future<({String pluginVersion, String? nativeSdkVersion})>
  versionInfo() async {
    final info = await _guard(() => _api.versionInfo());
    return (
      pluginVersion: info.pluginVersion,
      nativeSdkVersion: info.nativeSdkVersion,
    );
  }

  static PayCrossAppearance? _withLegacyBrand(
    PayCrossAppearance? appearance,
    int? brandColorArgb,
  ) {
    if (appearance == null) return null;
    if (brandColorArgb == null || appearance.hasBrand) return appearance;

    final legacy = Color(brandColorArgb);
    return appearance.copyWith(
      light: (appearance.light ?? const PayCrossColors()).copyWith(
        brand: legacy,
      ),
      dark: (appearance.dark ?? const PayCrossColors()).copyWith(brand: legacy),
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
      savedCardToken: raw.savedCardToken,
    ),
    g.PcPending() => PayCrossPending(
      transactionId: raw.transactionId,
      reason: PayCrossPendingReason.fromWireName(raw.reason),
      reasonRaw: raw.reason,
    ),
    // Must precede the general failure case, or it is read as a decline.
    g.PcFailure()
        when PayCrossRecovery.fromApiValue(raw.recovery)
            is RecoveryVerifyBeforeRetry =>
      PayCrossPending(
        transactionId: raw.transactionId,
        reason: PayCrossPendingReason.serverVerify,
        // The wire token as it arrived, not the pending name 'server_verify'.
        reasonRaw: raw.recovery,
      ),
    // Parsed here: a recovery value added later is unrecognised, not
    // retryable.
    g.PcFailure() => PayCrossFailure(
      transactionId: raw.transactionId,
      recovery: PayCrossRecovery.fromApiValue(raw.recovery),
    ),
    g.PcCancelled() => PayCrossCancelled(transactionId: raw.transactionId),
  };
}
