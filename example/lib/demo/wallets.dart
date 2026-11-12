library;

const String testApplePayMerchantId = 'merchant.pay-cross.com';

const String liveApplePayMerchantId = 'merchant.pay-cross.com.prod';

const String liveGooglePayMerchantId = 'BCR2DN5T52B53JQD';

String? walletIdOrNull(String value) => value.isEmpty ? null : value;
