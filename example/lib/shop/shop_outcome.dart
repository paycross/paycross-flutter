import 'package:paycross_flutter/paycross_flutter.dart';

import '../demo/present.dart';

/// What the shop says when the shopper closed the sheet themselves.
const String shopCancelledMessage = 'Payment cancelled.';

/// What the shop says when the card was turned down and another might work.
const String shopDeclinedMessage =
    'Your card was declined. Please try another card.';

/// What the shop says when the attempt failed but the card is not the
/// problem.
const String shopTryAgainMessage =
    'The payment could not be completed. Please try again.';

/// What the shop says when the shopper has to talk to somebody.
const String shopContactUsMessage =
    'We could not take that payment. Please get in touch with us.';

/// What the shop says when nobody knows whether the money moved.
///
/// The one outcome where paying again can charge the shopper twice, so this
/// is the one message that tells them not to. The checkout keeps its Pay
/// button dead after it, because copy that says "do not pay again" beside a
/// live button says nothing at all.
const String shopUnresolvedMessage =
    'We have not been able to confirm this payment. Do not pay again — we '
    'will email you as soon as we know.';

/// What the shop says when the payment never reached the sheet.
const String shopWentWrongMessage =
    'Something went wrong and the payment did not go through. Please try '
    'again.';

/// What a shopper is told about a payment that did not end in an approval.
///
/// A mapping of its own rather than `humanOutcome`, and that is the whole
/// point of it: the demo's wording carries the server's own tokens and a
/// transaction id, which is what somebody debugging a scenario needs and
/// exactly what must not appear on a storefront. The raw wording is not lost
/// -- History records it, so a run is still reportable in full.
///
/// Exhaustive over both sealed types on purpose: a recovery or a result the
/// SDK adds later becomes a compile error here rather than silently reaching
/// a shopper as the wrong sentence.
String shopOutcomeMessage(PresentedRun run) => switch (run.result) {
  PayCrossFailure(:final recovery) => _refusalMessage(recovery),
  PayCrossPending() => shopUnresolvedMessage,
  PayCrossCancelled() => shopCancelledMessage,
  // A success belongs on the thank-you page and never reaches here; null is
  // a sheet that threw. Both read as "it did not go through", which is the
  // honest thing to tell somebody either way.
  PayCrossSuccess() || null => shopWentWrongMessage,
};

/// Whether the shopper may press Pay again after [run].
///
/// False on an unresolved payment only. Every other outcome is one the
/// server has a verdict for, so a second attempt is a second attempt rather
/// than a possible second charge.
bool shopMayPayAgain(PresentedRun run) => run.result is! PayCrossPending;

String _refusalMessage(PayCrossRecovery recovery) => switch (recovery) {
  RecoveryChangeMethod() || RecoveryDoNotRetry() => shopDeclinedMessage,
  RecoveryRetry() || RecoveryRestart() => shopTryAgainMessage,
  RecoveryContactSupport() => shopContactUsMessage,
  // The outcome was never observed, which is the unresolved case wearing a
  // refusal's clothes. It is unreachable through `presentPayment`, which
  // turns every one of these into a pending result -- but a recovery that
  // says nobody knows must never read as a decline if it ever arrives.
  RecoveryVerifyBeforeRetry() => shopUnresolvedMessage,
  // A token this build has no sentence for. "Try again" is the safe reading:
  // it is not retryable as far as the SDK is concerned, and the shopper is
  // told the truth either way -- it did not go through.
  RecoveryUnrecognized() => shopTryAgainMessage,
};
