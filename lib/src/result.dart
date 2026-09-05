import 'recovery.dart';
import 'wire.dart';

/// How much, in the smallest unit of the currency.
class PayCrossAmount {
  const PayCrossAmount({required this.minorUnits, required this.currencyCode});

  /// Integer, never a double. 1250 EUR minor units is €12.50.
  final int minorUnits;

  /// ISO 4217. May be empty when the session was already complete and the
  /// server returned no transaction reference.
  final String currencyCode;

  @override
  String toString() => 'PayCrossAmount($minorUnits $currencyCode)';
}

/// The outcome of a payment.
///
/// A decline is a [PayCrossFailure], not a thrown exception: it is an ordinary
/// outcome of taking a payment, and making it an error would push every
/// merchant into a try/catch where the compiler stops helping them. Exceptions
/// are reserved for integration mistakes.
///
/// Switch over this exhaustively — Dart will tell you if a case is missing:
///
/// ```dart
/// switch (result) {
///   case PayCrossSuccess(:final transactionId):
///     await fulfil(transactionId);
///   case PayCrossFailure(:final recovery) when recovery.isRetryable:
///     showRetryPrompt();
///   case PayCrossFailure():
///     showDeclined();
///   case PayCrossPending(:final transactionId):
///     await reconcile(transactionId);
///   case PayCrossCancelled(:final transactionId):
///     if (transactionId != null) await reconcile(transactionId);
/// }
/// ```
sealed class PayCrossResult {
  const PayCrossResult();
}

/// The payment completed.
class PayCrossSuccess extends PayCrossResult {
  const PayCrossSuccess({
    required this.transactionId,
    required this.status,
    required this.amount,
  });

  /// Empty in the edge case where the session was already complete and the
  /// server had no transaction reference to give. Check [hasTransactionReference]
  /// before using it as a key.
  final String transactionId;

  /// "success", "authorized", …
  final String status;

  final PayCrossAmount amount;

  /// False in the already-complete-session case above.
  bool get hasTransactionReference => transactionId.isNotEmpty;

  @override
  String toString() => 'PayCrossSuccess($transactionId, $status, $amount)';
}

/// The payment did not complete. Not an error — see [PayCrossResult].
class PayCrossFailure extends PayCrossResult {
  const PayCrossFailure({this.transactionId, required this.recovery});

  /// Null when the payment failed before a transaction existed.
  final String? transactionId;

  /// What to offer the shopper next. Check [PayCrossRecovery.isRetryable]
  /// rather than matching on specific cases.
  final PayCrossRecovery recovery;

  @override
  String toString() => 'PayCrossFailure($transactionId, $recovery)';
}

/// The outcome was never observed. The payment **may have succeeded**.
///
/// Neither a success nor a decline. The SDK never saw a verdict, and a payment
/// that completed and shifted liability is indistinguishable from one that
/// never happened, so this is the one outcome where charging again can charge
/// the shopper twice.
///
/// Reconcile server-side against [transactionId] before collecting anything
/// else. Never retry blindly, and never present it to the shopper as a
/// decline.
class PayCrossPending extends PayCrossResult {
  const PayCrossPending({
    this.transactionId,
    required this.reason,
    required this.reasonRaw,
  });

  /// The transaction to reconcile against, or null when the result was lost
  /// before one was known.
  final String? transactionId;

  /// Why the outcome is unknown. Informational: every reason means the same
  /// thing for what the merchant must do next.
  final PayCrossPendingReason reason;

  /// The token this outcome arrived with, unparsed, kept for the same reason
  /// [PayCrossRecovery] keeps its own: a value added after this version ships
  /// is still loggable rather than lost to
  /// [PayCrossPendingReason.unrecognized].
  ///
  /// Usually the wire name a native SDK sent, verbatim. A failure still
  /// carrying the older `verify_before_retry` recovery keeps that recovery
  /// token, because it is what actually arrived. One case has no value to
  /// carry: a result lost on the way out of a native SDK, where the plugin
  /// fills in the canonical `result_lost`.
  final String reasonRaw;

  @override
  String toString() =>
      'PayCrossPending($transactionId, ${reason.name}, $reasonRaw)';
}

/// Why a payment's outcome is unknown.
///
/// A closed enum here, unlike [PayCrossRecovery], because nothing branches on
/// it: the answer to every reason is the same, and [PayCrossPending.reasonRaw]
/// carries the value a future reason would need. What the enum buys is a
/// readable log line and a switchable value for telemetry.
enum PayCrossPendingReason {
  /// The native SDK's status poll reached its deadline without a verdict.
  pollTimeout,

  /// A result existed but never reached Dart — the engine or the host Activity
  /// went away, or the result payload did not survive the platform channel.
  resultLost,

  /// The server answered `verify_before_retry`, which says it has no verdict
  /// to give either.
  serverVerify,

  /// A wire name this version of the plugin does not know. Read
  /// [PayCrossPending.reasonRaw] for what actually arrived.
  unrecognized;

  /// Parses the wire name both native SDKs send.
  ///
  /// Reads the token through the same normaliser [PayCrossRecovery.fromApiValue]
  /// uses, so the two vocabularies cannot drift in how they are read. Unlike
  /// recovery there is no absent-means-something default: an empty or missing
  /// reason is [unrecognized], because there is no safe reading of an unknown
  /// outcome to fall back on.
  static PayCrossPendingReason fromWireName(String? value) =>
      switch (normalizedWireToken(value)) {
        'poll_timeout' => pollTimeout,
        'result_lost' => resultLost,
        'server_verify' => serverVerify,
        _ => unrecognized,
      };
}

/// The shopper dismissed the payment sheet.
class PayCrossCancelled extends PayCrossResult {
  const PayCrossCancelled({this.transactionId});

  /// The last transaction this session created, or null when the sheet was
  /// dismissed before one existed.
  ///
  /// Dismissing the sheet does not cancel the authorization. A shopper can walk
  /// away after a decline or part-way through a 3-D Secure challenge, and the
  /// server keeps its own record of the attempt, so this is what lets you
  /// reconcile the one they left behind.
  final String? transactionId;

  @override
  String toString() => 'PayCrossCancelled($transactionId)';
}
