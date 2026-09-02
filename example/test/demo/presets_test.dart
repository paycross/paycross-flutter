import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/presets.dart';

/// The five strings `Driver.no_label_error` scans for to decide that a build
/// was made without `--dart-define=PAYCROSS_E2E=true`. Pinned here as
/// literals rather than imported, because they live in Python
/// (`tool/e2e/tree.py`) and this is the Dart side of the same contract.
const List<String> legacyLabelPrefixes = <String>[
  'Paid ',
  'Declined',
  'Cancelled',
  'Outcome unknown',
  'Integration error',
];

/// The body every sandbox preset without special needs sends, to the byte.
///
/// A literal rather than another call to `defaultBody()`, which would compare
/// the helper with itself and pass however the helper changed. This is what
/// the automated matrix has been running against; Live mode borrowing the
/// helper's `extraTopLevel` argument must not move a comma of it.
const String _defaultBodyAsShipped = '''
{
  "amount": 1000,
  "currency": "EUR",
  "transaction_type": "sale",
  "merchant_reference": "DEMO-{{timestamp}}",
  "return_url": "https://merchant.example.com/payment/return",
  "success_url": "https://merchant.example.com/payment/success",
  "customer": {
    "email": "john.doe@example.com",
    "first_name": "John",
    "last_name": "Doe",
    "phone": "+12025551234",
    "merchant_reference": "CUST-{{timestamp}}",
    "address": {
      "billing": {
        "line1": "123 Main Street",
        "line2": "Apt 4B",
        "city": "New York",
        "state": "NY",
        "postal_code": "10001",
        "country": "US"
      }
    }
  }
}''';

/// The store-card body, to the byte. The `save_card_config` line is the one
/// Live's store-card tile now sends too, so a change here is a change there.
const String _cofStoreBodyAsShipped = '''
{
  "amount": 1000,
  "currency": "EUR",
  "transaction_type": "sale",
  "merchant_reference": "DEMO-{{timestamp}}",
  "return_url": "https://merchant.example.com/payment/return",
  "success_url": "https://merchant.example.com/payment/success",
  "save_card_config": { "usage": "card_on_file" },
  "customer": {
    "email": "john.doe@example.com",
    "first_name": "John",
    "last_name": "Doe",
    "phone": "+12025551234",
    "merchant_reference": "harness_cof_customer",
    "address": {
      "billing": {
        "line1": "123 Main Street",
        "line2": "Apt 4B",
        "city": "New York",
        "state": "NY",
        "postal_code": "10001",
        "country": "US"
      }
    }
  }
}''';

/// The pay-with-saved-card body, to the byte.
const String _cofPaySavedBodyAsShipped = '''
{
  "amount": 1000,
  "currency": "EUR",
  "transaction_type": "sale",
  "merchant_reference": "DEMO-{{timestamp}}",
  "return_url": "https://merchant.example.com/payment/return",
  "success_url": "https://merchant.example.com/payment/success",
  "saved_cards": { "show": "all" },
  "customer": {
    "email": "john.doe@example.com",
    "first_name": "John",
    "last_name": "Doe",
    "phone": "+12025551234",
    "merchant_reference": "harness_cof_customer",
    "address": {
      "billing": {
        "line1": "123 Main Street",
        "line2": "Apt 4B",
        "city": "New York",
        "state": "NY",
        "postal_code": "10001",
        "country": "US"
      }
    }
  }
}''';

/// The body "Verify credentials" mints and abandons, to the byte.
const String _verifyProbeBodyAsShipped = '''
{
  "amount": 100,
  "currency": "EUR",
  "transaction_type": "sale",
  "merchant_reference": "DEMO-VERIFY-{{timestamp}}",
  "return_url": "https://merchant.example.com/payment/return",
  "success_url": "https://merchant.example.com/payment/success",
  "customer": {
    "email": "john.doe@example.com",
    "first_name": "John",
    "last_name": "Doe",
    "phone": "+12025551234",
    "merchant_reference": "CUST-{{timestamp}}",
    "address": {
      "billing": {
        "line1": "123 Main Street",
        "line2": "Apt 4B",
        "city": "New York",
        "state": "NY",
        "postal_code": "10001",
        "country": "US"
      }
    }
  }
}''';

void main() {
  test('the sandbox bodies are the bytes the matrix has been running', () {
    // Four literals cover every shape the sandbox side produces, because
    // every preset but the two saved-card ones is `defaultBody()`. The case
    // below proves that claim rather than assuming it.
    expect(defaultBody(), _defaultBodyAsShipped);
    expect(cofStoreBody, _cofStoreBodyAsShipped);
    expect(cofPaySavedBody, _cofPaySavedBodyAsShipped);
    expect(verifyProbeBody, _verifyProbeBodyAsShipped);
  });

  test('every preset on Home sends one of those four bodies, unchanged', () {
    // The other half: a preset that stopped calling `defaultBody()` and
    // started building its own would slip past the pins above, which only
    // look at the helpers. `customPreset` is in here for the same reason --
    // it is what the editor opens on.
    const pinned = <String>[
      _defaultBodyAsShipped,
      _cofStoreBodyAsShipped,
      _cofPaySavedBodyAsShipped,
    ];

    for (final preset in [...demoPresets, customPreset]) {
      expect(pinned, contains(preset.body), reason: preset.name);
    }
  });

  test('the saved-card keys are named once and sent from that name', () {
    // Live mode's two saved-card tiles send these same two strings. Named
    // constants rather than a second pair of literals over there: the Live
    // tiles are these scenarios with a production merchant behind them, and
    // a key that drifted between the two would fail only on the merchant
    // nobody can retry cheaply.
    expect(
      saveCardConfigOption,
      '"save_card_config": { "usage": "card_on_file" }',
    );
    expect(savedCardsOption, '"saved_cards": { "show": "all" }');
    expect(cofStoreBody, contains(saveCardConfigOption));
    expect(cofPaySavedBody, contains(savedCardsOption));
  });

  test('every preset body is valid JSON with an amount and a currency', () {
    for (final preset in demoPresets) {
      final body = jsonDecode(preset.body);
      expect(body, isA<Map<String, Object?>>(), reason: preset.name);
      expect((body as Map)['amount'], isA<int>(), reason: preset.name);
      expect(body['currency'], 'EUR', reason: preset.name);
    }
  });

  test('every body the app mints carries the customer the schema requires', () {
    // Measured against TEST on 2026-08-31, not assumed:
    //   no `customer`                       -> 400 "The required properties
    //                                          (customer) are missing", param "/"
    //   `"customer": {}`                    -> 400 "The data (array) must match
    //                                          the type: object"
    //   customer with merchant_reference    -> 400 "The required properties
    //                                          (first_name, last_name, email)
    //                                          are missing", param "/customer"
    //   customer with those three           -> created
    // "Verify credentials" shipped in demo-v0.1.0 build 26 without a customer
    // at all and 400d on the first tester's phone. Every body the app can send
    // is pinned here, the probe included, because the probe's own test drives a
    // stub client and a stub accepts a body the API would refuse.
    final bodies = <String, String>{
      for (final preset in demoPresets) preset.name: preset.body,
      customPreset.name: customPreset.body,
      'Verify credentials probe': verifyProbeBody,
    };

    for (final entry in bodies.entries) {
      final body = jsonDecode(entry.value);
      expect(body, isA<Map<String, Object?>>(), reason: entry.key);
      final customer = (body as Map)['customer'];
      expect(customer, isA<Map<String, Object?>>(), reason: entry.key);
      for (final field in const ['first_name', 'last_name', 'email']) {
        expect(
          (customer as Map)[field],
          isA<String>(),
          reason: '${entry.key} is missing customer.$field',
        );
      }
    }
  });

  test('the two saved-card presets share the pinned customer', () {
    final store = demoPresets.firstWhere((p) => p.name.contains('Store card'));
    final pay = demoPresets.firstWhere((p) => p.name.contains('saved card'));

    String customerRef(String body) =>
        ((jsonDecode(body) as Map)['customer'] as Map)['merchant_reference']
            as String;

    // Omit or randomise this and the backend mints a fresh customer, so the
    // card stored by the first preset can never be found by the second.
    expect(customerRef(store.body), cofCustomerReference);
    expect(customerRef(pay.body), cofCustomerReference);
    expect(pay.hint, contains('Store card'));
  });

  test('storing needs save_card_config, paying needs saved_cards', () {
    final store = demoPresets.firstWhere((p) => p.name.contains('Store card'));
    final pay = demoPresets.firstWhere((p) => p.name.contains('saved card'));

    expect(jsonDecode(store.body), contains('save_card_config'));
    expect(jsonDecode(pay.body), contains('saved_cards'));
  });

  test('no preset expectation could be read as a build without the define', () {
    for (final preset in demoPresets) {
      for (final prefix in legacyLabelPrefixes) {
        expect(
          preset.expected.startsWith(prefix),
          isFalse,
          reason:
              '"${preset.expected}" starts with "$prefix", which is what the '
              'matrix runner scans for to report a build missing '
              'the automation define.',
        );
      }
    }
  });

  test('preset names are unique -- a deep link resolves one of them', () {
    final names = demoPresets.map((p) => p.name).toList();

    expect(names.toSet(), hasLength(names.length));
  });
}
