import 'package:paycross_flutter/paycross_flutter.dart';

import '../e2e_label.dart';
import 'minter.dart';
import 'money.dart';

String humanOutcome(PayCrossResult outcome) => switch (outcome) {
  PayCrossSuccess(:final transactionId, :final amount, :final savedCardToken) =>
    'Approved — ${formatMoney(amount.minorUnits, amount.currencyCode)}, '
        'transaction $transactionId'
        '${savedCardToken == null ? '' : ', saved card $savedCardToken'}',
  PayCrossFailure(:final transactionId, :final recovery)
      when recovery.isRetryable =>
    'Refused, worth another attempt — recovery ${recoveryToken(recovery)}'
        '${transactionId == null ? '' : ', transaction $transactionId'}',
  PayCrossFailure(:final transactionId, :final recovery) =>
    'Refused — recovery ${recoveryToken(recovery)}'
        '${transactionId == null ? '' : ', transaction $transactionId'}',
  PayCrossPending(:final transactionId, :final reason, :final reasonRaw) =>
    'Unresolved — reconcile server-side, reason '
        '${pendingReasonToken(reason, reasonRaw)}'
        '${transactionId == null ? '' : ', transaction $transactionId'}',
  PayCrossCancelled() => 'Payment cancelled.',
};

String humanError(PayCrossIntegrationError problem) =>
    'Integration problem (${problem.code.name}) — '
    '${maskAndTrim(problem.message)}';
