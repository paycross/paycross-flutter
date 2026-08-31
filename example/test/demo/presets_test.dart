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
