import 'wire.dart';

/// What the shopper can do after a declined payment.
///
/// Parsed in Dart from the server's raw token, not sent as a closed enum: an
/// unknown token degrades to [RecoveryUnrecognized], which is not retryable but
/// is still reported verbatim.
sealed class PayCrossRecovery {
  const PayCrossRecovery();

  /// Whether the shopper may try again in the same session.
  ///
  /// An allow-list: anything unrecognised is not retryable.
  bool get isRetryable => this is RecoveryRetry || this is RecoveryChangeMethod;

  /// Parses the server's token. An absent token means retry, and `contact_us`
  /// is an alias for `contact_support`.
  factory PayCrossRecovery.fromApiValue(String? value) {
    switch (normalizedWireToken(value)) {
      case null:
      case '':
      case 'retry':
        return const RecoveryRetry();
      case 'change_method':
        return const RecoveryChangeMethod();
      case 'restart':
        return const RecoveryRestart();
      case 'contact_support':
      case 'contact_us':
        return const RecoveryContactSupport();
      case 'do_not_retry':
        return const RecoveryDoNotRetry();
      case 'verify_before_retry':
        return const RecoveryVerifyBeforeRetry();
      default:
        return RecoveryUnrecognized(value!.trim());
    }
  }
}

/// Try the same payment again.
class RecoveryRetry extends PayCrossRecovery {
  const RecoveryRetry();
  @override
  String toString() => 'RecoveryRetry()';
}

/// Try a different card or method.
class RecoveryChangeMethod extends PayCrossRecovery {
  const RecoveryChangeMethod();
  @override
  String toString() => 'RecoveryChangeMethod()';
}

/// Start the checkout over; this session is spent.
class RecoveryRestart extends PayCrossRecovery {
  const RecoveryRestart();
  @override
  String toString() => 'RecoveryRestart()';
}

/// Direct the shopper to support.
class RecoveryContactSupport extends PayCrossRecovery {
  const RecoveryContactSupport();
  @override
  String toString() => 'RecoveryContactSupport()';
}

/// Terminal decline. Never offer a retry of this payment.
class RecoveryDoNotRetry extends PayCrossRecovery {
  const RecoveryDoNotRetry();
  @override
  String toString() => 'RecoveryDoNotRetry()';
}

/// The outcome was never observed.
///
/// Not returned by `PayCross.presentPayment`, which reports it as a
/// `PayCrossPending`. [PayCrossRecovery.fromApiValue] still parses the token for
/// anything that reads a server response directly, and never calls it retryable.
class RecoveryVerifyBeforeRetry extends PayCrossRecovery {
  const RecoveryVerifyBeforeRetry();
  @override
  String toString() => 'RecoveryVerifyBeforeRetry()';
}

/// A value this version of the SDK does not know.
///
/// Treated as not retryable. [value] is the server's token, kept for logging.
class RecoveryUnrecognized extends PayCrossRecovery {
  const RecoveryUnrecognized(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      other is RecoveryUnrecognized && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'RecoveryUnrecognized($value)';
}
