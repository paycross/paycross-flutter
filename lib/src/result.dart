import 'recovery.dart';
import 'wire.dart';

/// How much, in the smallest unit of the currency.
class PayCrossAmount {
  const PayCrossAmount({required this.minorUnits, required this.currencyCode});

  /// Amount in minor units: 1250 is €12.50.
  final int minorUnits;

  /// ISO 4217 currency code. Empty when the session was already complete and no transaction reference was returned.
  final String currencyCode;

  @override
  String toString() => 'PayCrossAmount($minorUnits $currencyCode)';
}

/// The outcome of a payment.
///
/// A decline is a [PayCrossFailure], not a thrown exception. Exceptions are
/// reserved for integration mistakes.
sealed class PayCrossResult {
  const PayCrossResult();
}

/// The payment completed.
class PayCrossSuccess extends PayCrossResult {
  const PayCrossSuccess({
    required this.transactionId,
    required this.status,
    required this.amount,
    this.savedCardToken,
  });

  /// The transaction reference. Empty when the session was already complete and
  /// no reference was returned; check [hasTransactionReference] before using it
  /// as a key.
  final String transactionId;

  /// "success", "authorized", …
  final String status;

  final PayCrossAmount amount;

  /// Token for the card this payment saved, for charging that card again.
  /// Null when no new card was saved, including when the shopper paid with a
  /// stored card. A null does not mean the card was forgotten.
  final String? savedCardToken;

  /// False when the session was already complete and no reference was returned.
  bool get hasTransactionReference => transactionId.isNotEmpty;

  @override
  String toString() =>
      'PayCrossSuccess($transactionId, $status, $amount, $savedCardToken)';
}

/// The payment did not complete. A decline is an outcome, not an error; see
/// [PayCrossResult].
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

/// The outcome is unknown and the payment **may have succeeded**. Reconcile
/// server-side against [transactionId] before charging again, since a retry can
/// charge the shopper twice. Never present it to the shopper as a decline.
class PayCrossPending extends PayCrossResult {
  const PayCrossPending({
    this.transactionId,
    required this.reason,
    required this.reasonRaw,
  });

  /// The transaction to reconcile against, or null when the result was lost
  /// before one was known.
  final String? transactionId;

  /// Why the outcome is unknown. Every reason calls for the same merchant action.
  final PayCrossPendingReason reason;

  /// The reason token as it arrived, unparsed, so a value this version does not
  /// know stays loggable. A failure that carried the older `verify_before_retry`
  /// recovery keeps that token. When the plugin fills in the reason itself, it
  /// is `result_lost`.
  final String reasonRaw;

  @override
  String toString() =>
      'PayCrossPending($transactionId, ${reason.name}, $reasonRaw)';
}

/// Why a payment's outcome is unknown. Every reason calls for the same merchant
/// action; [PayCrossPending.reasonRaw] holds the wire value.
enum PayCrossPendingReason {
  /// The native SDK's status poll reached its deadline without a verdict.
  pollTimeout,

  /// The native result never reached Dart, for example because the engine or
  /// host Activity went away.
  resultLost,

  /// The server answered `verify_before_retry`, so it has no verdict either.
  serverVerify,

  /// A wire name this version of the plugin does not know.
  unrecognized;

  /// Parses the wire name a native SDK sends. An empty or missing value is
  /// [unrecognized].
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
  /// Dismissing the sheet does not cancel the authorization, so reconcile
  /// against this transaction.
  final String? transactionId;

  @override
  String toString() => 'PayCrossCancelled($transactionId)';
}
