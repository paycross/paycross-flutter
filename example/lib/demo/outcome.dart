import 'package:paycross_flutter/paycross_flutter.dart';

import '../e2e_label.dart';
import 'minter.dart';
import 'money.dart';

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
  // Written by the same formatter as the tile the person tapped, so a
  // "£1.00" on the way in cannot come back as "100 GBP" on the way out.
  PayCrossSuccess(:final transactionId, :final amount, :final savedCardToken) =>
    'Approved — ${formatMoney(amount.minorUnits, amount.currencyCode)}, '
        'transaction $transactionId'
        // In full, like the Android demo: a tester's next step is to read
        // it back off the API as `stored_credentials.saved_token`, which a
        // masked value cannot do. It charges nothing without the merchant
        // credentials, which this app does not show and never stores here.
        '${savedCardToken == null ? '' : ', saved card $savedCardToken'}',
  PayCrossFailure(:final transactionId, :final recovery)
      when recovery.isRetryable =>
    'Refused, worth another attempt — recovery ${recoveryToken(recovery)}'
        '${transactionId == null ? '' : ', transaction $transactionId'}',
  PayCrossFailure(:final transactionId, :final recovery) =>
    'Refused — recovery ${recoveryToken(recovery)}'
        '${transactionId == null ? '' : ', transaction $transactionId'}',
  // Not "Outcome unknown": the runner reads that prefix as a build made
  // without the automation define, and this screen is the one place where a
  // genuine unresolved payment would then be reported as a rig mistake.
  PayCrossPending(:final transactionId, :final reason, :final reasonRaw) =>
    'Unresolved — reconcile server-side, reason '
        '${pendingReasonToken(reason, reasonRaw)}'
        '${transactionId == null ? '' : ', transaction $transactionId'}',
  PayCrossCancelled() => 'Payment cancelled.',
};

/// An integration mistake, which arrives as a thrown exception.
///
/// Every code left here is a mistake in this app's own code. The unknown
/// outcome that used to need a branch of its own is a [PayCrossPending] result
/// now, and reads through [humanOutcome].
///
/// The message half goes through the minter's mask first. It comes from the
/// native SDK, which makes no promise about what it quotes, and what this
/// function returns is stored in History and copied into the bug-report
/// block -- so it gets the same treatment a response body gets, and the same
/// 400-character cut so one runaway message cannot become the whole report.
String humanError(PayCrossIntegrationError problem) =>
    'Integration problem (${problem.code.name}) — '
    '${maskAndTrim(problem.message)}';
