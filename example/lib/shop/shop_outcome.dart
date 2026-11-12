import 'package:paycross_flutter/paycross_flutter.dart';

import '../demo/present.dart';

const String shopCancelledMessage = 'Payment cancelled.';

const String shopDeclinedMessage =
    'Your card was declined. Please try another card.';

const String shopTryAgainMessage =
    'The payment could not be completed. Please try again.';

const String shopContactUsMessage =
    'We could not take that payment. Please get in touch with us.';

const String shopUnresolvedMessage =
    'We have not been able to confirm this payment. Do not pay again — we '
    'will email you as soon as we know.';

const String shopWentWrongMessage =
    'Something went wrong and the payment did not go through. Please try '
    'again.';

String shopOutcomeMessage(PresentedRun run) => switch (run.result) {
  PayCrossFailure(:final recovery) => _refusalMessage(recovery),
  PayCrossPending() => shopUnresolvedMessage,
  PayCrossCancelled() => shopCancelledMessage,
  PayCrossSuccess() || null => shopWentWrongMessage,
};

bool shopMayPayAgain(PresentedRun run) => run.result is! PayCrossPending;

String _refusalMessage(PayCrossRecovery recovery) => switch (recovery) {
  RecoveryChangeMethod() || RecoveryDoNotRetry() => shopDeclinedMessage,
  RecoveryRetry() || RecoveryRestart() => shopTryAgainMessage,
  RecoveryContactSupport() => shopContactUsMessage,
  RecoveryVerifyBeforeRetry() => shopUnresolvedMessage,
  RecoveryUnrecognized() => shopTryAgainMessage,
};
