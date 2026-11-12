library;

const Map<String, String> _currencySymbols = <String, String>{
  'EUR': '€',
  'USD': r'$',
  'GBP': '£',
};

String formatMoney(int minorUnits, String currency) {
  final amount = (minorUnits / 100).toStringAsFixed(2);
  final symbol = _currencySymbols[currency];
  return symbol == null ? '$amount $currency' : '$symbol$amount';
}
