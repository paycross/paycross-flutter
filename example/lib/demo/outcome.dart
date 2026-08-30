import 'package:paycross_flutter/paycross_flutter.dart';

import '../e2e_label.dart';

/// What an ordinary user reads, for every outcome the SDK can produce.
///
/// The wording is a constraint, not a style. `Driver.no_label_error` in the
/// matrix runner scans the accessibility tree for five prefixes -- "Paid ",
/// "Declined", "Cancelled", "Outcome unknown", "Integration error" -- to
/// diagnose a build made without the automation define. If a string here
/// began with one of them, a genuine hang on this screen would be reported
/// as the wrong build instead of as the finding it is.
///
/// The recovery token comes from `e2e_label.dart` rather than from a second
/// mapping here: one spelling of the server's vocabulary, not two.
String humanOutcome(PayCrossResult outcome) => switch (outcome) {
  PayCrossSuccess(:final transactionId, :final amount) =>
    'Approved — ${amount.minorUnits} ${amount.currencyCode}, '
        'transaction $transactionId',
  PayCrossFailure(:final transactionId, :final recovery)
      when recovery.isRetryable =>
    'Refused, worth another attempt — recovery ${recoveryToken(recovery)}'
        '${transactionId == null ? '' : ', transaction $transactionId'}',
  PayCrossFailure(:final transactionId, :final recovery) =>
    'Refused — recovery ${recoveryToken(recovery)}'
        '${transactionId == null ? '' : ', transaction $transactionId'}',
  PayCrossCancelled() => 'Payment cancelled.',
};

/// An integration mistake, which arrives as a thrown exception.
String humanError(PayCrossIntegrationError problem) =>
    problem.code == PayCrossErrorCode.resultUnknown
    // Distinct from a refusal on purpose: the payment may have gone through,
    // so the merchant reconciles rather than re-charging.
    ? 'Unknown outcome — reconcile server-side. ${problem.message}'
    : 'Integration problem (${problem.code.name}) — ${problem.message}';
