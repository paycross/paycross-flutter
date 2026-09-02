/// How this app writes an amount for a person to read.
///
/// One function for every human-facing amount: the Live tiles, the Live
/// confirmation dialog and the result screen all go through it, so the app
/// cannot quote "£1.00" on the way in and "100 GBP" on the way out — which
/// is exactly what the result screen did until a tester's photo of it.
///
/// The automation screen is the deliberate exception. It writes
/// `Paid <minor units> <code>` because the matrix runner reads that string,
/// and its fixtures pin the raw form.
library;

/// Three entries rather than a package: this app shows amounts in one of
/// three currencies, and `intl` would bring a locale question -- whose
/// separators, whose symbol placement -- that nobody here has an answer for.
const Map<String, String> _currencySymbols = <String, String>{
  'EUR': '€',
  'USD': r'$',
  'GBP': '£',
};

/// `€10.00`, `$10.00`, `£1.00`; a code the map does not hold falls back to
/// `10.00 XXX`: unlovely, and honest, which is the trade worth making when
/// the alternative is an unknown currency printed under a euro sign.
///
/// Every currency this app offers is two-decimal, so dividing by 100 is
/// right for each of them. A zero-decimal currency (JPY, KRW) would print a
/// hundred times too small here; none can reach this app today, and the
/// day one can, this is the one place to teach.
String formatMoney(int minorUnits, String currency) {
  final amount = (minorUnits / 100).toStringAsFixed(2);
  final symbol = _currencySymbols[currency];
  return symbol == null ? '$amount $currency' : '$symbol$amount';
}
