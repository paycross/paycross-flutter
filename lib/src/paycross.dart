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
  /// [appearance] themes the native payment sheets on both platforms: colours
  /// per mode, a pinned or system theme mode, corner radii, the Pay button and
  /// a font scale. Every role left null keeps the next source — the brand
  /// colour set in the PayCross back office, then the platform default — so
  /// omitting it entirely is not "no theming" and a merchant who sets their
  /// brand colour in the back office needs no code here at all.
  ///
  /// [brandColorArgb] is deprecated in favour of
  /// `appearance: PayCrossAppearance.brand(color)`, which sets the same colour
  /// in both light and dark and opens the rest of the palette. It is still
  /// honoured on its own, on both platforms.
  ///
  /// When both are given, the appearance decides only what it actually names.
  /// If either palette sets `brand`, that wins outright. If neither does — an
  /// appearance that is only shapes, or only a font scale, which is exactly
  /// what a half-finished migration looks like — the legacy colour is merged
  /// into `brand` in both palettes rather than dropped. Either way the legacy
  /// value itself is not sent, so neither native SDK has to hold a second
  /// opinion about which colour is the brand.
  ///
  /// The `@Deprecated` on it is documentation rather than a warning: Dart does
  /// not report a deprecated named parameter at a call site, so this note, the
  /// README and the release notes are the deprecation. The Android SDK says
  /// the same about `brandColor`, which Kotlin cannot annotate at all.
  ///
  /// [locale] pins the language the native payment sheet draws in, as a
  /// BCP 47 tag such as `fr` or `fr-CA`. Both SDKs ship English and French.
  /// It is the first rung of a ladder they own: this override, then the
  /// payment session's own `locale`, then the shopper's device languages,
  /// then English. Each candidate is matched on its own — the whole tag, then
  /// its primary subtag — and one that names a language neither SDK ships
  /// falls through to the next rather than ending the ladder.
  ///
  /// The amount is not clamped to those two languages: it is formatted with
  /// the first *well-formed* locale anyone named, region intact, so a German
  /// shopper reads an English sheet over an amount written the way they
  /// expect. A malformed tag is passed over for the amount too, so a typo
  /// cannot both pick the wrong language and misprint the price.
  ///
  /// The string crosses exactly as it is written. This package does not
  /// resolve it, validate it, lower-case it or turn `_` into `-`, because
  /// both SDKs already do all four and a second opinion here could only
  /// disagree with them. A malformed tag is skipped by the native resolver
  /// rather than thrown on, so nothing passed here can fail a payment.
  ///
  /// Null means "not overridden", which lets the session's locale decide. It
  /// is not a request for English.
  ///
  /// The sheet's language never touches the host app's. See LOCALIZATION.md
  /// in either native SDK for the full rule and the string keys.
  ///
  /// [googlePayMerchantId] is Android-only. It is the merchant id from the
  /// Google Business Console, and Google **requires** it for
  /// [PayCrossEnvironment.production] Google Pay requests; sandbox works
  /// without one. iOS ignores it, because Google Pay's in-app API is Android
  /// and web only.
  ///
  /// [applePayMerchantId] is iOS-only, and Android ignores it. It is the Apple
  /// Merchant ID the iOS SDK renders its Apple Pay button for. Null, empty and
  /// whitespace-only all mean not configured, and no button appears. It must
  /// otherwise be the same string that is saved on the merchant's PayCross
  /// record — the edge compares the two and refuses the payment when they
  /// differ.
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

    // Before the channel call, and before the busy guard reports anything: an
    // appearance a sheet cannot draw is a mistake in merchant code, and it is
    // cheaper to name here than as a layout failure inside a native sheet.
    final crossing = _withLegacyBrand(appearance, brandColorArgb)?.toPigeon();

    return _guard(
      () => _api.configure(
        g.PcConfiguration(
          environment: environment == PayCrossEnvironment.sandbox
              ? g.PcEnvironment.sandbox
              : g.PcEnvironment.production,
          // Dropped when an appearance is given: two brand colours on the wire
          // would make the precedence a decision each native re-derived, and
          // the two would eventually disagree.
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
  /// **This can take minutes.** The server is polled for up to eight, and a 3-D
  /// Secure challenge waits on the shopper's bank. Do not wrap the returned
  /// Future in `Future.timeout`: a shorter timeout abandons a live payment
  /// while the native SDK keeps polling, and the card may still be charged.
  ///
  /// A decline is a [PayCrossFailure], not a thrown error, and an outcome the
  /// SDK never observed is a [PayCrossPending]. Anything thrown from here is a
  /// [PayCrossIntegrationError].
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
      // A lost result is an outcome, not an integration mistake: the payment
      // may have been authorized. Returning it as a value puts it in the
      // merchant's exhaustive switch, where the compiler asks for a decision,
      // rather than in a catch block written once and forgotten.
      if (e.code == payCrossResultLostCode) {
        // The canonical name, because nothing sent one: a native side that
        // has lost its result has only an error code left to send.
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

  /// Folds a deprecated [brandColorArgb] into an appearance that names no
  /// brand of its own.
  ///
  /// Without this, adding two corner radii to a `configure` call that still
  /// used `brandColorArgb` would silently drop the merchant's brand colour:
  /// the appearance would win, and it would win with nothing to say about the
  /// brand. A half-migrated call is the normal state of a migration, and it
  /// must not be the state that loses a colour.
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
    // Defensive, and deliberately before the general failure case. Both native
    // SDKs send this outcome as PcPending now, but a merchant can pin an older
    // native SDK under a newer plugin, and reading this one recovery as a
    // decline is what put a double charge one retry away.
    g.PcFailure()
        when PayCrossRecovery.fromApiValue(raw.recovery)
            is RecoveryVerifyBeforeRetry =>
      PayCrossPending(
        transactionId: raw.transactionId,
        reason: PayCrossPendingReason.serverVerify,
        // The recovery token exactly as it arrived, spacing and casing and
        // all. Not 'server_verify': that is the pending vocabulary, and
        // nothing sent it.
        reasonRaw: raw.recovery,
      ),
    // The raw token is parsed here rather than crossing as an enum, so a
    // recovery value the server adds later degrades to "unrecognised, not
    // retryable" instead of being silently rewritten.
    g.PcFailure() => PayCrossFailure(
      transactionId: raw.transactionId,
      recovery: PayCrossRecovery.fromApiValue(raw.recovery),
    ),
    g.PcCancelled() => PayCrossCancelled(transactionId: raw.transactionId),
  };
}
