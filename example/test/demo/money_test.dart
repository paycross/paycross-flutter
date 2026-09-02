import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/live.dart';
import 'package:paycross_demo/demo/money.dart';

void main() {
  test('the three offered currencies get their symbol in front', () {
    expect(formatMoney(100, 'GBP'), '£1.00');
    expect(formatMoney(1000, 'EUR'), '€10.00');
    expect(formatMoney(2550, 'USD'), r'$25.50');
  });

  test(
    'an unknown code is written as amount then code, never a wrong symbol',
    () {
      expect(formatMoney(100, 'CHF'), '1.00 CHF');
    },
  );

  test('zero and single minor units keep two decimals', () {
    expect(formatMoney(0, 'EUR'), '€0.00');
    expect(formatMoney(5, 'GBP'), '£0.05');
  });

  test('the Live tile label is the same formatter at the smoke amount', () {
    for (final currency in ['EUR', 'USD', 'GBP', 'CHF']) {
      expect(
        liveSmokeAmountLabel(currency),
        formatMoney(liveSmokeMinorUnits, currency),
      );
    }
  });
}
