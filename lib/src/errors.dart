/// Something is wrong with the integration, not with the payment.
///
/// A decline is never this — it arrives as a `PayCrossFailure`. Every code here
/// means the SDK was asked to do something it cannot, and every one is fixable
/// in merchant code except [PayCrossErrorCode.resultUnknown].
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

  /// A payment is already in flight. One at a time, per process.
  busy,

  /// Android: the plugin is not attached to an Activity, or the host Activity
  /// uses a launchMode that cannot receive results.
  noActivity,

  /// iOS: no view controller to present from.
  noPresenter,

  /// The session token was empty.
  invalidToken,

  /// The payment's outcome is genuinely unknown — the engine or Activity was
  /// destroyed mid-flight, or the result payload did not survive.
  ///
  /// It MAY have succeeded. Reconcile server-side rather than re-charging. The
  /// one code here that does not imply a mistake in merchant code.
  resultUnknown,

  /// Anything the plugin did not recognise.
  unknown,
}

PayCrossErrorCode payCrossErrorCodeFrom(String? raw) => switch (raw) {
  'paycross_not_configured' => PayCrossErrorCode.notConfigured,
  'paycross_busy' => PayCrossErrorCode.busy,
  'paycross_no_activity' => PayCrossErrorCode.noActivity,
  'paycross_no_presenter' => PayCrossErrorCode.noPresenter,
  'paycross_invalid_token' => PayCrossErrorCode.invalidToken,
  'paycross_result_unknown' => PayCrossErrorCode.resultUnknown,
  _ => PayCrossErrorCode.unknown,
};
