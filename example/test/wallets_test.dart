import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/wallets.dart';

void main() {
  test('a configured identifier passes through', () {
    expect(walletIdOrNull('merchant.pay-cross.com'), 'merchant.pay-cross.com');
  });

  test('an empty identifier reads as unconfigured', () {
    expect(walletIdOrNull(''), isNull);
  });

  test('the Live Google identifier is configured', () {
    expect(walletIdOrNull(liveGooglePayMerchantId), liveGooglePayMerchantId);
  });

  test('the Live Apple identifier is configured', () {
    expect(
      walletIdOrNull(liveApplePayMerchantId),
      'merchant.pay-cross.com.prod',
    );
  });

  test('the Test and Live Apple identifiers are not the same string', () {
    expect(liveApplePayMerchantId, isNot(testApplePayMerchantId));
  });
}
