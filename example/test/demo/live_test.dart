import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/live.dart';
import 'package:paycross_demo/demo/presets.dart';
import 'package:paycross_demo/demo/surface.dart';

const String _smokeBodyAsStored = '''
{
  "amount": 100,
  "currency": "EUR",
  "transaction_type": "sale",
  "merchant_reference": "LIVE-SMOKE-{{timestamp}}",
  "return_url": "https://merchant.example.com/payment/return",
  "success_url": "https://merchant.example.com/payment/success",
  "customer": {
    "merchant_reference": "paycross_live_smoke"
  }
}''';

const String _smokeBodyAsMinted = '''
{
  "amount": 100,
  "currency": "EUR",
  "transaction_type": "sale",
  "merchant_reference": "LIVE-SMOKE-{{timestamp}}",
  "return_url": "https://merchant.example.com/payment/return",
  "success_url": "https://merchant.example.com/payment/success",
  "customer": {
    "merchant_reference": "paycross_live_smoke",
    "email": "ada@example.org",
    "first_name": "Ada",
    "last_name": "Lovelace"
  }
}''';

void main() {
  const identity = LiveIdentity(
    firstName: 'Ada',
    lastName: 'Lovelace',
    email: 'ada@example.org',
  );

  String minted(LiveScenario scenario) =>
      withLiveIdentity(liveDefaultBody(scenario), identity);

  test('a name is split on the last space', () {
    final one = LiveIdentity.parse(name: 'Ada Lovelace', email: 'a@b.c')!;
    expect(one.firstName, 'Ada');
    expect(one.lastName, 'Lovelace');

    final three = LiveIdentity.parse(name: 'Ada B. Lovelace', email: 'a@b.c')!;
    expect(three.firstName, 'Ada B.');
    expect(three.lastName, 'Lovelace');

    final padded = LiveIdentity.parse(
      name: '  Ada Lovelace  ',
      email: '  ada@example.org  ',
    )!;
    expect(padded.firstName, 'Ada');
    expect(padded.lastName, 'Lovelace');
    expect(padded.email, 'ada@example.org');
  });

  test('a single word is not a name', () {
    expect(liveNameProblem('Ada'), isNotNull);
    expect(liveNameProblem('   '), isNotNull);
    expect(liveNameProblem(''), isNotNull);
    expect(liveNameProblem('Ada Lovelace'), isNull);
    expect(LiveIdentity.parse(name: 'Ada', email: 'ada@example.org'), isNull);
  });

  test('an address with no @ is not an email', () {
    expect(liveEmailProblem('ada'), isNotNull);
    expect(liveEmailProblem(''), isNotNull);
    expect(liveEmailProblem('   '), isNotNull);
    expect(liveEmailProblem('ada@example.org'), isNull);
    expect(LiveIdentity.parse(name: 'Ada Lovelace', email: 'ada'), isNull);
  });

  test('the smoke charges one euro, and says so in its reference', () {
    final body =
        jsonDecode(liveDefaultBody(LiveScenario.smoke)) as Map<String, Object?>;

    expect(body['amount'], 100);
    expect(body['currency'], 'EUR');
    expect(body['transaction_type'], 'sale');
    expect(body['merchant_reference'], startsWith('LIVE-SMOKE-'));
  });

  test('the stored smoke body carries no identity at all', () {
    expect(liveDefaultBody(LiveScenario.smoke), _smokeBodyAsStored);

    for (final scenario in LiveScenario.values) {
      final customer =
          (jsonDecode(liveDefaultBody(scenario))
                  as Map<String, Object?>)['customer']!
              as Map<String, Object?>;

      for (final field in const ['email', 'first_name', 'last_name']) {
        expect(customer.containsKey(field), isFalse, reason: scenario.name);
      }
    }
  });

  test('the minted smoke body is the one that has been charging cards', () {
    expect(minted(LiveScenario.smoke), _smokeBodyAsMinted);
    expect(
      jsonDecode(minted(LiveScenario.smoke)),
      jsonDecode(_smokeBodyAsStored)
        ..['customer'] = {
          'merchant_reference': liveSmokeCustomerReference,
          'email': identity.email,
          'first_name': identity.firstName,
          'last_name': identity.lastName,
        },
    );
  });

  test('the splice puts the identity into a body that had none', () {
    for (final scenario in LiveScenario.values) {
      final customer =
          (jsonDecode(minted(scenario)) as Map<String, Object?>)['customer']!
              as Map<String, Object?>;

      expect(customer['email'], identity.email, reason: scenario.name);
      expect(customer['first_name'], identity.firstName);
      expect(customer['last_name'], identity.lastName);
    }
  });

  test('the splice builds a customer when the body has no usable one', () {
    final customer =
        (jsonDecode(withLiveIdentity('{"amount":100}', identity))
                as Map<String, Object?>)['customer']!
            as Map<String, Object?>;

    expect(customer['email'], identity.email);
    expect(customer['first_name'], identity.firstName);
    expect(customer['last_name'], identity.lastName);
  });

  test(
    'the splice overwrites an identity somebody typed into the raw body',
    () {
      const stale =
          '{"amount":100,"customer":{"email":"old@example.org",'
          '"first_name":"Old","last_name":"Name"}}';

      final customer =
          (jsonDecode(withLiveIdentity(stale, identity))
                  as Map<String, Object?>)['customer']!
              as Map<String, Object?>;

      expect(customer['email'], identity.email);
      expect(customer['first_name'], identity.firstName);
      expect(customer['last_name'], identity.lastName);
    },
  );

  test('each saved-card tile is the smoke body plus exactly one key', () {
    const keys = <LiveScenario, String>{
      LiveScenario.storeCard: 'save_card_config',
      LiveScenario.paySavedCard: 'saved_cards',
    };

    for (final entry in keys.entries) {
      final body =
          jsonDecode(liveDefaultBody(entry.key)) as Map<String, Object?>;
      final withoutKey = Map<String, Object?>.of(body)..remove(entry.value);

      expect(body.containsKey(entry.value), isTrue, reason: entry.key.name);
      expect(
        jsonEncode(withoutKey),
        jsonEncode(jsonDecode(_smokeBodyAsStored)),
        reason: entry.key.name,
      );
    }
  });

  test('the saved-card tiles send the keys the sandbox presets send', () {
    expect(liveExtraOption(LiveScenario.smoke), isNull);
    expect(liveExtraOption(LiveScenario.storeCard), saveCardConfigOption);
    expect(liveExtraOption(LiveScenario.paySavedCard), savedCardsOption);

    final store =
        jsonDecode(liveDefaultBody(LiveScenario.storeCard))
            as Map<String, Object?>;
    final pay =
        jsonDecode(liveDefaultBody(LiveScenario.paySavedCard))
            as Map<String, Object?>;

    expect(store['save_card_config'], {'usage': 'card_on_file'});
    expect(pay['saved_cards'], {'show': 'all'});
  });

  test('all three tiles charge one customer, so a stored card is found', () {
    for (final scenario in LiveScenario.values) {
      final customer =
          (jsonDecode(liveDefaultBody(scenario))
                  as Map<String, Object?>)['customer']!
              as Map<String, Object?>;

      expect(
        customer['merchant_reference'],
        liveSmokeCustomerReference,
        reason: scenario.name,
      );
    }
  });

  test('the amount a tile quotes is read off its own body', () {
    String at(String currency) =>
        liveBodyAmountLabel('{"amount":100,"currency":"$currency"}')!;

    expect(at('EUR'), '€1.00');
    expect(at('USD'), r'$1.00');
    expect(at('GBP'), '£1.00');
    for (final code in currencies) {
      expect(at(code), isNot(contains(code)), reason: code);
    }
    expect(at('JPY'), '1.00 JPY');
    expect(liveBodyAmountLabel('{"amount":4250,"currency":"GBP"}'), '£42.50');
  });

  test('a body this build cannot read quotes no figure at all', () {
    for (final unreadable in const [
      '{ nope',
      '[]',
      '{"currency":"EUR"}',
      '{"amount":"100","currency":"EUR"}',
      '{"amount":100}',
    ]) {
      expect(liveBodyMoney(unreadable), isNull, reason: unreadable);
      expect(liveBodyAmountLabel(unreadable), isNull, reason: unreadable);
    }
    expect(liveBodyMoney('{"amount":100,"currency":"EUR"}'), isNotNull);
  });

  test('the tile title and the dialog quote the same body', () {
    const edited = '{"amount":4250,"currency":"GBP"}';
    const label = '£42.50';

    expect(liveTileTitle('Live smoke', edited), contains(label));
    expect(liveConfirmQuestion(edited), contains(label));
    for (final other in const ['€42.50', r'$42.50', '€1.00']) {
      expect(liveTileTitle('Live smoke', edited), isNot(contains(other)));
      expect(liveConfirmQuestion(edited), isNot(contains(other)));
    }
  });

  test('a title with an unreadable body is short, never invented', () {
    expect(liveTileTitle('Live smoke', '{ nope'), 'Live smoke');
  });

  test('the three tiles are three distinct, self-describing names', () {
    final names = LiveScenario.values.map(liveScenarioName).toList();

    expect(names.toSet(), hasLength(3));
    for (final name in names) {
      expect(name, contains('Live'), reason: name);
    }
    expect(liveScenarioName(LiveScenario.smoke), 'Live smoke');
    expect(liveScenarioName(LiveScenario.storeCard), 'Live — store card');
    expect(
      liveScenarioName(LiveScenario.paySavedCard),
      'Live — pay with saved card',
    );
    for (final name in names) {
      expect(name, isNot(contains('1.00')), reason: name);
    }
  });

  test('the dialog says what the body will do, beyond the amount', () {
    expect(
      liveConfirmQuestion(liveDefaultBody(LiveScenario.smoke)),
      'This will charge a real card €1.00. Continue?',
    );
    expect(
      liveConfirmQuestion(liveDefaultBody(LiveScenario.storeCard)),
      contains('stores the card'),
    );
    expect(
      liveConfirmQuestion(liveDefaultBody(LiveScenario.paySavedCard)),
      contains('already stored'),
    );
    expect(
      liveConfirmQuestion(
        '{"amount":100,"currency":"EUR",'
        '"save_card_config":{"usage":"card_on_file"},'
        '"saved_cards":{"show":"all"}}',
      ),
      stringContainsInOrder(['stores the card', 'already stored']),
    );
    for (final scenario in LiveScenario.values) {
      final question = liveConfirmQuestion(liveDefaultBody(scenario));
      expect(question, contains('charge a real card'), reason: scenario.name);
      expect(question, endsWith('Continue?'), reason: scenario.name);
    }
  });

  test('the subtitles tell a tester the order and the refund', () {
    for (final scenario in LiveScenario.values) {
      expect(
        liveScenarioExpectation(scenario),
        contains('Refund'),
        reason: scenario.name,
      );
    }
    expect(
      liveScenarioExpectation(LiveScenario.paySavedCard),
      contains('store card'),
    );
    expect(liveCustomExpectation, contains('Refund'));
  });

  test('no tile expects anything a runner could misread', () {
    for (final prefix in const [
      'Paid ',
      'Declined',
      'Cancelled',
      'Outcome unknown',
      'Integration error',
    ]) {
      for (final scenario in LiveScenario.values) {
        expect(
          liveScenarioExpectation(scenario).startsWith(prefix),
          isFalse,
          reason: '${scenario.name} / $prefix',
        );
      }
      expect(liveCustomExpectation.startsWith(prefix), isFalse, reason: prefix);
    }
  });

  test('every tile has its own key on Home', () {
    final keys = LiveScenario.values.map(liveTileKey).toList();

    expect(keys.toSet(), hasLength(3));
    expect(liveTileKey(LiveScenario.smoke), 'liveSmokeTile');
  });

  test('every tile has its own id, and none looks like a sandbox one', () {
    final ids = LiveScenario.values.map(liveScenarioId).toList();

    expect(ids.toSet(), hasLength(3));
    for (final id in ids) {
      expect(id, startsWith('live-'), reason: id);
    }
    for (final preset in demoPresets) {
      expect(ids, isNot(contains(preset.id)), reason: preset.name);
    }
  });

  test('a name the JSON template cannot hold raw still parses', () {
    const awkward = r'Ada Smith "Bud" O\Jones';

    final typed = LiveIdentity.parse(name: awkward, email: 'ada@example.org')!;

    for (final scenario in LiveScenario.values) {
      final customer =
          (jsonDecode(withLiveIdentity(liveDefaultBody(scenario), typed))
                  as Map<String, Object?>)['customer']!
              as Map<String, Object?>;

      expect(customer['first_name'], r'Ada Smith "Bud"', reason: scenario.name);
      expect(customer['last_name'], r'O\Jones', reason: scenario.name);
    }
  });

  test('no tile body carries the sandbox customer or its address', () {
    for (final scenario in LiveScenario.values) {
      final raw = minted(scenario);
      final customer =
          (jsonDecode(raw) as Map<String, Object?>)['customer']!
              as Map<String, Object?>;

      expect(customer['email'], isNot('john.doe@example.com'));
      expect(raw, isNot(contains('123 Main Street')), reason: scenario.name);
      expect(customer.containsKey('address'), isFalse, reason: scenario.name);
      expect(customer.containsKey('phone'), isFalse, reason: scenario.name);
    }
  });

  test('a body carrying the sandbox billing address is refused', () {
    const withBilling =
        '{"amount":100,"currency":"EUR","customer":{"address":'
        '{"billing":{"line1":"123 Main Street","country":"US"}}}}';

    expect(liveBodyProblem(withBilling), isNotNull);
    expect(liveBodyProblem(withBilling), contains('billing address'));
    for (final scenario in LiveScenario.values) {
      expect(
        liveBodyProblem(liveDefaultBody(scenario)),
        isNull,
        reason: scenario.name,
      );
    }
    expect(liveBodyProblem('{ nope'), isNull);
  });

  test('every tile body is a template until it is minted', () {
    for (final scenario in LiveScenario.values) {
      expect(
        liveDefaultBody(scenario),
        contains('{{timestamp}}'),
        reason: scenario.name,
      );
      expect(minted(scenario), contains('{{timestamp}}'));
    }
  });

  test('a default preset carries the three strings of its tile', () {
    for (final scenario in LiveScenario.values) {
      final preset = liveDefaultPresets.firstWhere(
        (p) => p.id == liveScenarioId(scenario),
      );

      expect(preset.name, liveScenarioName(scenario));
      expect(preset.body, liveDefaultBody(scenario));
      expect(preset.expected, liveScenarioExpectation(scenario));
      expect(preset.cardHint, isNull, reason: scenario.name);
    }
    expect(liveDefaultPresets, hasLength(LiveScenario.values.length));
  });

  group('what the confirmation dialog says about where it happens', () {
    final smoke = liveDefaultBody(LiveScenario.smoke);

    test('the sheet asks exactly what it always asked', () {
      for (final scenario in LiveScenario.values) {
        final body = liveDefaultBody(scenario);
        expect(
          liveConfirmQuestion(body),
          liveConfirmQuestion(body, surface: PaymentSurface.sdkSheet),
          reason: scenario.name,
        );
        expect(
          liveConfirmQuestion(body),
          isNot(contains('browser')),
          reason: scenario.name,
        );
      }
    });

    test('the web surface adds where the card will be typed', () {
      for (final scenario in LiveScenario.values) {
        final asked = liveConfirmQuestion(
          liveDefaultBody(scenario),
          surface: PaymentSurface.webCheckout,
        );

        expect(
          asked,
          contains('It opens in your browser instead of the app.'),
          reason: scenario.name,
        );
        expect(asked, contains('charge a real card'), reason: scenario.name);
        expect(asked, endsWith('Continue?'), reason: scenario.name);
      }
    });

    test('a saved-card tile on the web says both things, in order', () {
      expect(
        liveConfirmQuestion(
          liveDefaultBody(LiveScenario.storeCard),
          surface: PaymentSurface.webCheckout,
        ),
        stringContainsInOrder([
          'charge a real card',
          'stores the card',
          'opens in your browser',
          'Continue?',
        ]),
      );
      expect(smoke, isNot(contains('save_card_config')));
    });
  });
}
