/// PayCross payment SDK for Flutter.
///
/// The card form, 3-D Secure and status polling run in the native Android and
/// iOS SDKs. This package presents them and returns one result.
///
/// `lib/src/generated/` is deliberately not exported: Pigeon's own docs advise
/// against putting generated code in a public API, and a regenerated field name
/// must never reach a merchant as a breaking change.
library;

export 'src/environment.dart' show PayCrossEnvironment;
export 'src/errors.dart' show PayCrossErrorCode, PayCrossIntegrationError;
export 'src/paycross.dart' show PayCross;
export 'src/recovery.dart'
    show
        PayCrossRecovery,
        RecoveryChangeMethod,
        RecoveryContactSupport,
        RecoveryDoNotRetry,
        RecoveryRestart,
        RecoveryRetry,
        RecoveryUnrecognized,
        RecoveryVerifyBeforeRetry;
export 'src/result.dart'
    show
        PayCrossAmount,
        PayCrossCancelled,
        PayCrossFailure,
        PayCrossPending,
        PayCrossPendingReason,
        PayCrossResult,
        PayCrossSuccess;
export 'src/test_card_prefill.dart' show PayCrossTestCardPrefill;
