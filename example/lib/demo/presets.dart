import 'dart:convert';
import 'dart:ui' show Color;

import 'package:paycross_flutter/paycross_flutter.dart';

const List<String> currencies = <String>['EUR', 'USD', 'GBP'];

const String cofCustomerReference = 'harness_cof_customer';

const String saveCardConfigOption =
    '"save_card_config": { "usage": "card_on_file" }';

const String savedCardsOption = '"saved_cards": { "show": "all" }';

const String _sandboxBilling = '''
      "billing": {
        "line1": "123 Main Street",
        "line2": "Apt 4B",
        "city": "New York",
        "state": "NY",
        "postal_code": "10001",
        "country": "US"
      }''';

Map<String, Object?> saveCardConfigEntry() =>
    jsonDecode('{$saveCardConfigOption}') as Map<String, Object?>;

Map<String, Object?> savedCardsEntry() =>
    jsonDecode('{$savedCardsOption}') as Map<String, Object?>;

Map<String, Object?> sandboxAddressEntry() => <String, Object?>{
  'address': jsonDecode('{$_sandboxBilling}'),
};

const String _sandboxCurrency = 'EUR';

const String _demoReference = 'DEMO-{{timestamp}}';

String _body({
  required int amount,
  String currency = _sandboxCurrency,
  String? extraTopLevel,
  String? customer,
  String reference = _demoReference,
  String? email = 'john.doe@example.com',
  String? firstName = 'John',
  String? lastName = 'Doe',
  String? phone = '+12025551234',
  String? billing = _sandboxBilling,
}) =>
    '''
{
  "amount": $amount,
  "currency": "$currency",
  "transaction_type": "sale",
  "merchant_reference": "$reference",
  "return_url": "https://merchant.example.com/payment/return",
  "success_url": "https://merchant.example.com/payment/success",${extraTopLevel == null ? '' : '\n  $extraTopLevel,'}
  "customer": {${email == null ? '' : '\n    "email": ${jsonEncode(email)},'}${firstName == null ? '' : '\n    "first_name": ${jsonEncode(firstName)},'}${lastName == null ? '' : '\n    "last_name": ${jsonEncode(lastName)},'}${phone == null ? '' : '\n    "phone": ${jsonEncode(phone)},'}
    "merchant_reference": "${customer ?? 'CUST-{{timestamp}}'}"${billing == null ? '' : ',\n    "address": {\n$billing\n    }'}
  }
}''';

String defaultBody({
  int amount = 1000,
  String currency = _sandboxCurrency,
  String reference = _demoReference,
}) => _body(amount: amount, currency: currency, reference: reference);

final String cofStoreBody = _body(
  amount: 1000,
  extraTopLevel: saveCardConfigOption,
  customer: cofCustomerReference,
);

final String cofPaySavedBody = _body(
  amount: 1000,
  extraTopLevel: savedCardsOption,
  customer: cofCustomerReference,
);

final String verifyProbeBody = _body(
  amount: 100,
  reference: 'DEMO-VERIFY-{{timestamp}}',
);

String liveBody({
  required int amount,
  required String currency,
  required String customerReference,
  String? extraTopLevel,
}) => _body(
  amount: amount,
  currency: currency,
  extraTopLevel: extraTopLevel,
  reference: 'LIVE-SMOKE-{{timestamp}}',
  customer: customerReference,
  email: null,
  firstName: null,
  lastName: null,
  phone: null,
  billing: null,
);

Map<String, Object?> customerFor(Map<String, Object?> body) {
  final existing = body['customer'];
  if (existing is Map<String, Object?>) return existing;
  final made = <String, Object?>{};
  body['customer'] = made;
  return made;
}

class Preset {
  const Preset({
    required this.name,
    required this.body,
    required this.expected,
    this.id,
    this.cardHint,
    this.hint,
    this.appearance,
  });

  final String? id;

  final String name;

  final String body;

  final String expected;

  final String? cardHint;

  final String? hint;

  final PayCrossAppearance? appearance;
}

final List<Preset> demoPresets = <Preset>[
  Preset(
    id: 'instant-approve',
    name: 'Instant approve (no 3DS)',
    body: defaultBody(),
    expected: 'Approved with no 3-D Secure step at all.',
    cardHint: '4111 1111 1117 0000',
  ),
  Preset(
    id: 'frictionless-3ds',
    name: 'Frictionless 3DS',
    body: defaultBody(),
    expected: 'Approved after a frictionless 3-D Secure check — no challenge.',
    cardHint: '4111 1111 1115 3063',
  ),
  Preset(
    id: 'challenge-approve',
    name: '3DS challenge → approve',
    body: defaultBody(),
    expected: 'Approved after the challenge.',
    cardHint: '4111 1111 1115 3220, then tap approve on the sandbox ACS page',
  ),
  Preset(
    id: 'challenge-decline',
    name: '3DS challenge → decline',
    body: defaultBody(),
    expected: 'Refused after the challenge — recovery do_not_retry.',
    cardHint:
        '4111 1111 1115 3220, then tap fraud_suspected on the sandbox ACS page',
  ),
  Preset(
    id: 'challenge-retryable',
    name: '3DS challenge → retryable decline',
    body: defaultBody(),
    expected:
        'The sheet re-arms for another attempt (recovery change_method). '
        'Cancel it to come back here.',
    cardHint:
        '4111 1111 1115 3220, then tap authentication_failed on the '
        'sandbox ACS page',
  ),
  Preset(
    id: 'cof-store',
    name: 'Store card (COF)',
    body: cofStoreBody,
    expected: 'Approved, and the card is stored for $cofCustomerReference.',
    cardHint: '4111 1111 1117 0000, and tick "Save card for future use"',
    hint: 'Re-running this is safe: the same PAN returns already_existing.',
  ),
  Preset(
    id: 'cof-pay-saved',
    name: 'Pay with saved card (COF)',
    body: cofPaySavedBody,
    expected: 'Charged the stored card without retyping it.',
    hint: 'Run "Store card (COF)" first, or the card list will be empty.',
  ),
  Preset(
    id: 'appearance',
    name: 'Themed sheet (appearance)',
    body: defaultBody(),
    expected:
        'The same approval as the first tile, on a sheet with a green brand '
        'colour, rounder corners and dark mode pinned on whatever the phone '
        'is set to. The sheet goes back to normal when the run ends.',
    cardHint: '4111 1111 1117 0000',
    appearance: const PayCrossAppearance(
      light: PayCrossColors(brand: Color(0xFF00875A)),
      dark: PayCrossColors(brand: Color(0xFF57D9A3)),
      themeMode: PayCrossThemeMode.dark,
      shapes: PayCrossShapes(cornerRadius: 16, buttonCornerRadius: 28),
    ),
  ),
  Preset(
    id: 'google-pay',
    name: 'Google Pay (Android)',
    body: defaultBody(),
    expected:
        'Google Pay shows only when the TEST merchant has the wallet '
        'enabled. Its absence is merchant configuration, not a bug.',
  ),
];

final Preset customPreset = Preset(
  name: 'Custom',
  body: defaultBody(),
  expected: 'Whatever the edited body asks for.',
);
