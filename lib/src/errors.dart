/// Something is wrong with the integration, not with the payment.
///
/// Declines arrive as a `PayCrossFailure`, and unknown outcomes as a
/// `PayCrossPending`. Each code here points at a mistake in merchant code.
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
  /// Raised in Dart, before the native side is called.
  testPrefillInProduction,

  /// `PayCross.configure` was given an appearance no sheet can draw: a
  /// `sizeScaleFactor` outside 0.8-1.3, or a negative or non-finite radius,
  /// border width or height.
  ///
  /// Raised in Dart rather than clamped natively, so the merchant learns about
  /// the value instead of getting a silently corrected one.
  invalidAppearance,

  /// A payment is already in flight. One at a time, per process.
  busy,

  /// Android: the plugin is not attached to an Activity, or the host Activity
  /// uses a launchMode that cannot receive results.
  noActivity,

  /// iOS: no view controller to present from.
  noPresenter,

  /// The session token was empty.
  invalidToken,

  /// A lost result. Not thrown: it arrives as a `PayCrossPending`.
  @Deprecated('Never thrown since 0.4.0; a lost result is PayCrossPending')
  resultUnknown,

  /// Anything the plugin did not recognise.
  unknown,
}

/// The platform-error code both native sides send when a result was lost.
///
/// Not thrown to merchants: `presentPayment` turns it into a `PayCrossPending`.
const String payCrossResultLostCode = 'paycross_result_unknown';

PayCrossErrorCode payCrossErrorCodeFrom(String? raw) => switch (raw) {
  'paycross_not_configured' => PayCrossErrorCode.notConfigured,
  'paycross_busy' => PayCrossErrorCode.busy,
  'paycross_no_activity' => PayCrossErrorCode.noActivity,
  'paycross_no_presenter' => PayCrossErrorCode.noPresenter,
  'paycross_invalid_token' => PayCrossErrorCode.invalidToken,
  // presentPayment intercepts this code first, so it is only reached from other callers.
  // ignore: deprecated_member_use_from_same_package
  payCrossResultLostCode => PayCrossErrorCode.resultUnknown,
  _ => PayCrossErrorCode.unknown,
};
