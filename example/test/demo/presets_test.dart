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

void main() {
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
