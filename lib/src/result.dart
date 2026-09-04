import 'recovery.dart';

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
