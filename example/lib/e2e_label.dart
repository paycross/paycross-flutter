import 'package:paycross_flutter/paycross_flutter.dart';

/// The E2E automation contract's label vocabulary.
///
/// Frozen in Phase 0 of the merchant-readiness campaign. The matrix runner in
/// `tool/e2e/` reads these strings straight out of the platform accessibility
/// tree, so every cell file compares against them and a change here is a
/// change to all of them.
///
///     result:success:<txn>
///     result:failure:<recovery>:<txn>
///     result:cancelled
///     error:<PayCrossErrorCode.name>
///
/// `<txn>` may be empty: a failure before a transaction existed carries none,
/// and a success on an already-complete session with no transaction to resume
/// carries none either.
String labelForResult(PayCrossResult result) => switch (result) {
  PayCrossSuccess(:final transactionId) => 'result:success:$transactionId',
  PayCrossFailure(:final transactionId, :final recovery) =>
    'result:failure:${recoveryToken(recovery)}:${transactionId ?? ''}',
  PayCrossCancelled() => 'result:cancelled',
};

/// An integration mistake, which is a thrown exception rather than a result.
String labelForError(PayCrossIntegrationError error) =>
    'error:${error.code.name}';

/// Renders a [PayCrossRecovery] back as the server's own token.
///
/// The package parses the token one way only — `PayCrossRecovery.fromApiValue`
/// has no inverse — so the example owns the reverse mapping. Using the wire
/// token rather than the Dart class name is what lets a label be compared
/// directly against the merchant API's `failure.recovery`.
///
/// Exhaustive over the sealed class on purpose: a seventh recovery case
/// becomes a compile error here rather than a silently wrong label in a cell
/// that has already been signed off.
String recoveryToken(PayCrossRecovery recovery) => switch (recovery) {
  RecoveryRetry() => 'retry',
  RecoveryChangeMethod() => 'change_method',
  RecoveryRestart() => 'restart',
  RecoveryDoNotRetry() => 'do_not_retry',
  RecoveryContactSupport() => 'contact_support',
  RecoveryUnrecognized(:final value) => 'unrecognized($value)',
};
