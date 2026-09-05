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
///     result:pending:<reason>:<txn>
///     result:cancelled
///     error:<PayCrossErrorCode.name>
///
/// `<txn>` may be empty: a failure before a transaction existed carries none,
/// a success on an already-complete session with no transaction to resume
/// carries none either, and a pending outcome whose result was lost before a
/// transaction was known carries none.
///
/// Because of that, `result:success:` is a strict prefix of every other
/// success label, and `result:failure:<recovery>:` of every failure label with
/// the same recovery. Consumers must compare a label whole, with `==`; a
/// `startswith`/`contains` match reports the no-transaction case for a run
/// that in fact carried one.
///
/// These strings only reach the screen when the app is built with
/// `--dart-define=PAYCROSS_E2E=true`. `bool.fromEnvironment` accepts the
/// literal `true` and nothing else, so `PAYCROSS_E2E=1` leaves the contract
/// off and the app showing its human-readable outcome instead.
String labelForResult(PayCrossResult result) => switch (result) {
  PayCrossSuccess(:final transactionId) => 'result:success:$transactionId',
  PayCrossFailure(:final transactionId, :final recovery) =>
    'result:failure:${recoveryToken(recovery)}:${transactionId ?? ''}',
  PayCrossPending(:final transactionId, :final reason, :final reasonRaw) =>
    'result:pending:${pendingReasonToken(reason, reasonRaw)}:'
        '${transactionId ?? ''}',
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
/// Exhaustive over the sealed class on purpose: a new recovery case becomes a
/// compile error here rather than a silently wrong label in a cell that has
/// already been signed off.
///
/// Not quite an inverse in one case: the legacy alias `contact_us` parses to
/// [RecoveryContactSupport] and so labels as `contact_support`, which is not
/// the string the API sent.
String recoveryToken(PayCrossRecovery recovery) => switch (recovery) {
  RecoveryRetry() => 'retry',
  RecoveryChangeMethod() => 'change_method',
  RecoveryRestart() => 'restart',
  RecoveryDoNotRetry() => 'do_not_retry',
  RecoveryContactSupport() => 'contact_support',
  RecoveryVerifyBeforeRetry() => 'verify_before_retry',
  RecoveryUnrecognized(:final value) => 'unrecognized($value)',
};

/// Renders a [PayCrossPendingReason] back as the wire name the SDK sent.
///
/// Reads the enum rather than [PayCrossPending.reasonRaw] so the label carries
/// what the plugin *understood*, which is what a cell file is asserting. The
/// raw string only surfaces for a reason this version cannot read, where the
/// enum has nothing to say.
///
/// Exhaustive on purpose: a reason added to the vocabulary becomes a compile
/// error here rather than a silently wrong label in a signed-off cell.
String pendingReasonToken(PayCrossPendingReason reason, String raw) =>
    switch (reason) {
      PayCrossPendingReason.pollTimeout => 'poll_timeout',
      PayCrossPendingReason.resultLost => 'result_lost',
      PayCrossPendingReason.serverVerify => 'server_verify',
      PayCrossPendingReason.unrecognized => 'unrecognized($raw)',
    };
