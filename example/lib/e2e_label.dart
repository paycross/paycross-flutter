import 'package:paycross_flutter/paycross_flutter.dart';

String labelForResult(PayCrossResult result) => switch (result) {
  PayCrossSuccess(:final transactionId) => 'result:success:$transactionId',
  PayCrossFailure(:final transactionId, :final recovery) =>
    'result:failure:${recoveryToken(recovery)}:${transactionId ?? ''}',
  PayCrossPending(:final transactionId, :final reason, :final reasonRaw) =>
    'result:pending:${pendingReasonToken(reason, reasonRaw)}:'
        '${transactionId ?? ''}',
  PayCrossCancelled() => 'result:cancelled',
};

String labelForError(PayCrossIntegrationError error) =>
    'error:${error.code.name}';

String recoveryToken(PayCrossRecovery recovery) => switch (recovery) {
  RecoveryRetry() => 'retry',
  RecoveryChangeMethod() => 'change_method',
  RecoveryRestart() => 'restart',
  RecoveryDoNotRetry() => 'do_not_retry',
  RecoveryContactSupport() => 'contact_support',
  RecoveryVerifyBeforeRetry() => 'verify_before_retry',
  RecoveryUnrecognized(:final value) => 'unrecognized($value)',
};

String pendingReasonToken(PayCrossPendingReason reason, String raw) =>
    switch (reason) {
      PayCrossPendingReason.pollTimeout => 'poll_timeout',
      PayCrossPendingReason.resultLost => 'result_lost',
      PayCrossPendingReason.serverVerify => 'server_verify',
      PayCrossPendingReason.unrecognized => 'unrecognized($raw)',
    };
