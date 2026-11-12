/// Fills the native card form so manual test runs do not mean retyping a PAN.
///
/// Sandbox only. configure throws if set with production. toString is redacted.
class PayCrossTestCardPrefill {
  const PayCrossTestCardPrefill({
    this.cardholderName = '',
    this.pan = '',
    this.expireMonth = '',
    this.expireYear = '',
    this.cvv = '',
    this.saveCard = false,
  });

  final String cardholderName;
  final String pan;

  /// "MM".
  final String expireMonth;

  /// Four digits, e.g. "2030".
  final String expireYear;

  final String cvv;
  final bool saveCard;

  @override
  String toString() => 'PayCrossTestCardPrefill(redacted)';
}
