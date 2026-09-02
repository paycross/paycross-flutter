import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/wallets.dart';

/// The wallet identifiers this app is built with, and the one rule about
/// them: a Test identifier must never reach production.
void main() {
  test('a configured identifier passes through', () {
    expect(walletIdOrNull('merchant.pay-cross.com'), 'merchant.pay-cross.com');
  });

  test('an empty identifier reads as unconfigured', () {
    // The Live Google merchant id is still the owner's to supply. Until they
    // do the constant is empty, and the app must read that as "no wallet"
    // rather than as an identifier -- an id Google does not know produces a
    // rejected request rather than a sheet.
    expect(walletIdOrNull(''), isNull);
    expect(walletIdOrNull(liveGooglePayMerchantId), isNull);
  });

  test('the Live Apple identifier is configured', () {
    // Apple's production identifier is not a placeholder: it is registered,
    // it has a certificate, and it is saved on the PROD merchant record. A
    // Live Apple Pay button that never appears is the symptom of this
    // constant regressing to a placeholder.
    expect(
      walletIdOrNull(liveApplePayMerchantId),
      'merchant.pay-cross.com.prod',
    );
  });

  test('the Test and Live Apple identifiers are not the same string', () {
    // The leak this guards is the reason the demo has two constants rather
    // than one variable: a production payment made under the Test identifier
    // would be encrypted to the TEST key and could never be decrypted.
    expect(liveApplePayMerchantId, isNot(testApplePayMerchantId));
  });
}
