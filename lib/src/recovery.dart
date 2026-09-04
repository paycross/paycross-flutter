/// What the shopper can do after a declined payment.
///
/// Deliberately a sealed class rather than an enum, and deliberately parsed in
/// Dart from the server's raw token rather than crossing the platform channel
/// as a closed enum.
///
/// The reason is forward compatibility. Pigeon cannot express an enum with an
/// associated value, so a closed enum on the boundary would silently rewrite
/// any recovery value the server adds after this package ships. Carrying the
/// raw string and parsing it here means an unknown token degrades to
/// [RecoveryUnrecognized] - not retryable, but still reported verbatim, so
/// merchant telemetry can tell "this SDK is out of date" apart from "the bank
/// said stop".
sealed class PayCrossRecovery {
  const PayCrossRecovery();

  /// Whether the shopper may reasonably try again in the same session.
  ///
  /// A whitelist, not a blacklist: anything unrecognised fails closed. Both
  /// native SDKs make the same call the same way.
  bool get isRetryable => this is RecoveryRetry || this is RecoveryChangeMethod;

  /// Parses the server's token.
  ///
  /// Mirrors `Recovery.fromString` on Android and `Recovery(apiValue:)` on iOS,
  /// including the trim, the lowercasing, the `contact_us` alias and the
  /// absent-means-retry default.
  factory PayCrossRecovery.fromApiValue(String? value) {
    switch (value?.trim().toLowerCase()) {
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

/// The outcome was never observed. Check the transaction before re-collecting.
///
/// Raised when the native SDK's status poll runs out of time, which a lost
/// network makes indistinguishable from a blip. The payment may well have
/// succeeded and shifted liability, so this is the one case where retrying can
/// charge a shopper twice. Not retryable, and the failure carries a
/// transaction id precisely so the outcome can be resolved out of band.
class RecoveryVerifyBeforeRetry extends PayCrossRecovery {
  const RecoveryVerifyBeforeRetry();
  @override
  String toString() => 'RecoveryVerifyBeforeRetry()';
}

/// A value this version of the SDK does not know.
///
/// Treated as not retryable. [value] is the server's token, kept so it can be
/// logged and acted on without shipping a new SDK first.
///
/// Reachable on both platforms. iOS has always kept the raw string inside its
/// enum, as `unrecognized(String)`; Android used to discard it, and from SDK
/// 0.4.0 keeps it beside the enum on `Failure.recoveryRaw`, which the plugin
/// passes through.
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
