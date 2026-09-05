/// Something is wrong with the integration, not with the payment.
///
/// A decline is never this — it arrives as a `PayCrossFailure`, and an unknown
/// outcome as a `PayCrossPending`. Every code here means the SDK was asked to
/// do something it cannot, and every one points at a mistake that is fixable in
/// merchant code.
class PayCrossIntegrationError implements Exception {
  const PayCrossIntegrationError(this.code, this.message);

  final PayCrossErrorCode code;
  final String message;

  @override
  String toString() => 'PayCrossIntegrationError(${code.name}: $message)';
}

enum PayCrossErrorCode {
  /// `PayCross.configure` was never called in this process.
  notConfigured,

  /// `PayCross.configure` was given a `testCardPrefill` alongside
  /// `PayCrossEnvironment.production`.
  ///
  /// Raised in Dart, before anything crosses to the native side. A prefill is a
  /// sandbox-only debugging aid; both native SDKs drop it outside sandbox
  /// anyway, so accepting it here would silently do nothing.
  testPrefillInProduction,

  /// A payment is already in flight. One at a time, per process.
  busy,

  /// Android: the plugin is not attached to an Activity, or the host Activity
  /// uses a launchMode that cannot receive results.
  noActivity,

  /// iOS: no view controller to present from.
  noPresenter,

  /// The session token was empty.
  invalidToken,

  /// A lost result. No longer thrown: it arrives as a `PayCrossPending` with
  /// `PayCrossPendingReason.resultLost`, because the payment may have
  /// succeeded and that is an outcome to reconcile, not an integration
  /// mistake to catch.
  ///
  /// Kept, with its code mapping, for one minor so a `switch` over this enum
  /// in merchant code still compiles.
  @Deprecated('Never thrown since 0.4.0; a lost result is PayCrossPending')
  resultUnknown,

  /// Anything the plugin did not recognise.
  unknown,
}

/// The platform-error code both native sides send when a result was lost.
///
/// Not an error to merchants since 0.4.0: `presentPayment` turns it into a
/// `PayCrossPending` value instead of throwing. It stays a platform error on
/// the wire because that is the only channel a native side has once it no
/// longer has a result to return.
const String payCrossResultLostCode = 'paycross_result_unknown';

PayCrossErrorCode payCrossErrorCodeFrom(String? raw) => switch (raw) {
  'paycross_not_configured' => PayCrossErrorCode.notConfigured,
  'paycross_busy' => PayCrossErrorCode.busy,
  'paycross_no_activity' => PayCrossErrorCode.noActivity,
  'paycross_no_presenter' => PayCrossErrorCode.noPresenter,
  'paycross_invalid_token' => PayCrossErrorCode.invalidToken,
  // Unreachable from presentPayment, which intercepts this code first. Kept
  // for the deprecation window so a merchant still matching on the enum member
  // sees the value they used to.
  // ignore: deprecated_member_use_from_same_package
  payCrossResultLostCode => PayCrossErrorCode.resultUnknown,
  _ => PayCrossErrorCode.unknown,
};
