import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/live.dart';
import 'package:paycross_demo/demo/presets.dart';
import 'package:paycross_demo/demo/surface.dart';

/// The smoke body as it is stored, to the byte.
///
/// A literal rather than another call to the helper that builds it: a
/// comparison against `liveBody(...)` compares the helper with itself and
/// passes however the helper changed.
///
/// It holds no identity. That is the change the addendum asked for and the
/// thing this literal is here to keep true: a Live body is a row on the
/// phone, and the name and email a charge is made under are typed in
/// Settings, held for one session, and spliced in at mint time.
///
/// `{{timestamp}}` is still a placeholder here -- the minter substitutes it
/// at the moment of sending -- so the two strings are comparable.
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

/// The smoke body as it is actually minted, to the byte.
///
/// The bytes that reach the API, which is the pair of this file's older
/// pin: the identity is spliced in and the whole thing is re-encoded, so
/// `merchant_reference` comes first and the three identity fields follow.
/// Semantically the body that has been charging real cards; a different
/// order of the same keys, which the create schema does not read.
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
    // The IANA-reserved documentation domain, as everywhere else in this
    // suite. No test in this plan holds an address that could belong to
    // anybody.
    email: 'ada@example.org',
  );

  /// One default tile's body with the identity in it, which is what the
  /// minter is actually handed.
  String minted(LiveScenario scenario) =>
      withLiveIdentity(liveDefaultBody(scenario), identity);

  test('a name is split on the last space', () {
    // The schema wants first_name and last_name; a human types one name.
    // The LAST space, not the first: a middle name or an initial belongs to
    // the given name, and "Ada B. Lovelace" is Lovelace.
    final one = LiveIdentity.parse(name: 'Ada Lovelace', email: 'a@b.c')!;
    expect(one.firstName, 'Ada');
    expect(one.lastName, 'Lovelace');

    final three = LiveIdentity.parse(name: 'Ada B. Lovelace', email: 'a@b.c')!;
    expect(three.firstName, 'Ada B.');
    expect(three.lastName, 'Lovelace');

    // Typed on a phone keyboard, where a trailing space is one thumb away.
    final padded = LiveIdentity.parse(
      name: '  Ada Lovelace  ',
      email: '  ada@example.org  ',
    )!;
    expect(padded.firstName, 'Ada');
    expect(padded.lastName, 'Lovelace');
    expect(padded.email, 'ada@example.org');
  });

  test('a single word is not a name', () {
    // `last_name` is in the create schema's customer.required list beside
    // the other two, so a one-word name is a body that 400s on production --
    // the one place this app has no cheap way to find out.
    expect(liveNameProblem('Ada'), isNotNull);
    expect(liveNameProblem('   '), isNotNull);
    expect(liveNameProblem(''), isNotNull);
    expect(liveNameProblem('Ada Lovelace'), isNull);
    // The parse and the reason are the same rule, not two that can drift.
    expect(LiveIdentity.parse(name: 'Ada', email: 'ada@example.org'), isNull);
  });

  test('an address with no @ is not an email', () {
    // The whole rule, deliberately. A stricter pattern refuses addresses
    // that are real, and the person typing this one is the person who knows
    // what it is.
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
    // Unmistakable in a back office full of sandbox noise, and the string
    // somebody searches for when they are looking for the charge to refund.
    expect(body['merchant_reference'], startsWith('LIVE-SMOKE-'));
  });

  test('the stored smoke body carries no identity at all', () {
    // The addendum's rule, structurally rather than by care: the three
    // fields are absent from the string that goes in the store, so a preset
    // row cannot hold a real person's name and email address.
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
    // Byte for byte against a literal, not against the helper that builds
    // it. The identity moved out of the stored body and into the splice;
    // this is the case that says the bytes reaching the API still say the
    // same thing.
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
      // `last_name` is in the create schema's `customer.required` list beside
      // the other two, so a body that loses it is a smoke that 400s on
      // production -- the one place this app has no cheap way to find out.
      expect(customer['last_name'], identity.lastName);
    }
  });

  test('the splice builds a customer when the body has no usable one', () {
    // A body somebody typed by hand can be missing it entirely. Dropping
    // the identity there would reproduce the 400 of PR #30 on the one
    // merchant nobody can retry cheaply.
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
      // The raw body is editable, so somebody can put an address in it by
      // hand. What is charged has to be the identity held for this session,
      // not a leftover in a preset saved last week.
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
    // Not "contains save_card_config": that would pass with the customer
    // object dropped, which is the 400 PR #30 was written about. The whole
    // rest of the body has to still be the smoke's.
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
    // The anti-drift rule, and the reason `presets.dart` names these two
    // strings: the Live tiles are the sandbox saved-card scenarios with a
    // production merchant behind them. A key spelled slightly differently
    // here would fail only on the merchant nobody can retry cheaply.
    expect(liveExtraOption(LiveScenario.smoke), isNull);
    expect(liveExtraOption(LiveScenario.storeCard), saveCardConfigOption);
    expect(liveExtraOption(LiveScenario.paySavedCard), savedCardsOption);

    final store =
        jsonDecode(liveDefaultBody(LiveScenario.storeCard))
            as Map<String, Object?>;
    final pay =
        jsonDecode(liveDefaultBody(LiveScenario.paySavedCard))
            as Map<String, Object?>;

    // The decoded values, which is what the backend reads. The sandbox
    // presets are pinned against the same two shapes in `presets_test`.
    expect(store['save_card_config'], {'usage': 'card_on_file'});
    expect(pay['saved_cards'], {'show': 'all'});
  });

  test('all three tiles charge one customer, so a stored card is found', () {
    // The whole reason the pair works across runs: the backend mints a
    // random customer when `customer.merchant_reference` is absent, and it
    // snapshots the saved-card list into a session once, at creation. A
    // store tile on one reference and a pay tile on another is a saved card
    // that can never be offered.
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
    // Three currencies, one figure, three symbols. Pinned as whole strings
    // because these are what a human reads on the tile and in the dialog
    // before deciding to spend money.
    String at(String currency) =>
        liveBodyAmountLabel('{"amount":100,"currency":"$currency"}')!;

    expect(at('EUR'), '€1.00');
    expect(at('USD'), r'$1.00');
    expect(at('GBP'), '£1.00');
    // Every currency the editor can offer has a symbol, so the fallback
    // below is unreachable from the app. It is here for the day a fourth is
    // added to the list and nobody remembers this map.
    for (final code in currencies) {
      expect(at(code), isNot(contains(code)), reason: code);
    }
    // And that day: the code, not a euro sign borrowed from the default. An
    // unknown currency printed under the wrong symbol is the one failure
    // worth ruling out here.
    expect(at('JPY'), '1.00 JPY');
    // An edited amount is quoted as edited. Before this, every figure came
    // from a constant and the currency came from a per-session picker, so
    // an edited body had no way to be quoted at all.
    expect(liveBodyAmountLabel('{"amount":4250,"currency":"GBP"}'), '£42.50');
  });

  test('a body this build cannot read quotes no figure at all', () {
    // Null rather than a guess. A confirmation dialog inventing an amount
    // over a real charge is the one failure worth being loud about, and the
    // callers refuse the run on this null.
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
    // The single-source rule, kept now that the figure is editable: both
    // sites read the body about to be minted, so an edited amount cannot be
    // quoted in one place and not the other.
    const edited = '{"amount":4250,"currency":"GBP"}';
    const label = '£42.50';

    expect(liveTileTitle('Live smoke', edited), contains(label));
    expect(liveConfirmQuestion(edited), contains(label));
    // And no other currency's figure is anywhere near either of them.
    for (final other in const ['€42.50', r'$42.50', '€1.00']) {
      expect(liveTileTitle('Live smoke', edited), isNot(contains(other)));
      expect(liveConfirmQuestion(edited), isNot(contains(other)));
    }
  });

  test('a title with an unreadable body is short, never invented', () {
    expect(liveTileTitle('Live smoke', '{ nope'), 'Live smoke');
  });

  test('the three tiles are three distinct, self-describing names', () {
    // A run is recorded in History by its preset name, so two tiles sharing
    // one name are two charges nobody can tell apart afterwards.
    final names = LiveScenario.values.map(liveScenarioName).toList();

    expect(names.toSet(), hasLength(3));
    // Every one of them says Live, because that name is the title of the
    // run screen and the row in History.
    for (final name in names) {
      expect(name, contains('Live'), reason: name);
    }
    // And each says what it does, in the words the README uses for it. No
    // figure in any of them: a name carrying one would lie the moment
    // somebody saved a different amount.
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
    // Read off the body rather than off the tile that was tapped, so it is
    // true of a preset somebody edited and of one they made from scratch.
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
    // A body somebody edited to do both says both.
    expect(
      liveConfirmQuestion(
        '{"amount":100,"currency":"EUR",'
        '"save_card_config":{"usage":"card_on_file"},'
        '"saved_cards":{"show":"all"}}',
      ),
      stringContainsInOrder(['stores the card', 'already stored']),
    );
    // All three still ask, rather than announce.
    for (final scenario in LiveScenario.values) {
      final question = liveConfirmQuestion(liveDefaultBody(scenario));
      expect(question, contains('charge a real card'), reason: scenario.name);
      expect(question, endsWith('Continue?'), reason: scenario.name);
    }
  });

  test('the subtitles tell a tester the order and the refund', () {
    // Every tile is money that has to be handed back, and the subtitle is
    // where a tester reads it before tapping.
    for (final scenario in LiveScenario.values) {
      expect(
        liveScenarioExpectation(scenario),
        contains('Refund'),
        reason: scenario.name,
      );
    }
    // The pair is ordered: the list of cards in the sheet is snapshotted
    // at session creation, so nothing is there to pay with until the store
    // tile has settled.
    expect(
      liveScenarioExpectation(LiveScenario.paySavedCard),
      contains('store card'),
    );
    // A tile somebody made says the same thing about the money.
    expect(liveCustomExpectation, contains('Refund'));
  });

  test('no tile expects anything a runner could misread', () {
    // The rule the sandbox presets are held to, kept here so the two sets
    // cannot diverge. The matrix runner never reads these: automation
    // always runs Test, and the E2E build never sees the toggle -- so this
    // is the sandbox convention held in one place, not a constraint the
    // runner imposes on Live.
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
    // Three tiles that a widget test has to be able to tap one of. The smoke
    // keeps the key it shipped with, so the cases written against it are
    // still about the tile they were written for.
    final keys = LiveScenario.values.map(liveTileKey).toList();

    expect(keys.toSet(), hasLength(3));
    expect(liveTileKey(LiveScenario.smoke), 'liveSmokeTile');
  });

  test('every tile has its own id, and none looks like a sandbox one', () {
    // The id is what a saved edit is filed under. Two tiles sharing one
    // would show each other's edits.
    final ids = LiveScenario.values.map(liveScenarioId).toList();

    expect(ids.toSet(), hasLength(3));
    for (final id in ids) {
      expect(id, startsWith('live-'), reason: id);
    }
    // Belt to the separate-key-space braces: the two halves of the store
    // are different keys, so a collision could not cross even if one of
    // these were spelled like a sandbox id.
    for (final preset in demoPresets) {
      expect(ids, isNot(contains(preset.id)), reason: preset.name);
    }
  });

  test('a name the JSON template cannot hold raw still parses', () {
    // The typed fields go into the body through a JSON encoder now rather
    // than being interpolated into a hand-built string, which is what makes
    // this safe -- but the rule is worth keeping: nobody picks their surname
    // to suit our template.
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

      // The fake the sandbox presets use. A New York billing address and a
      // john.doe address are what production AVS and fraud rules are for.
      expect(customer['email'], isNot('john.doe@example.com'));
      expect(raw, isNot(contains('123 Main Street')), reason: scenario.name);
      expect(customer.containsKey('address'), isFalse, reason: scenario.name);
      // Omitted outright, not replaced with a plausible one. The sandbox
      // default is `+12025551234` -- the reserved fictional Washington-DC 555
      // range -- and on a real charge from a European device that is the same
      // fabricated-contact-detail risk the billing address is omitted for,
      // plus a wrong number written onto a real person's production customer
      // record. `phone` is not in the create schema's `customer.required`
      // list, so leaving it out costs nothing.
      expect(customer.containsKey('phone'), isFalse, reason: scenario.name);
    }
  });

  test('a body carrying the sandbox billing address is refused', () {
    // The other half of the rule above, for a body somebody typed. It is a
    // refusal rather than a quiet strip: the raw body is the source of truth
    // on the editor screen, and silently deleting a line somebody typed is
    // how a tool stops being trustworthy.
    const withBilling =
        '{"amount":100,"currency":"EUR","customer":{"address":'
        '{"billing":{"line1":"123 Main Street","country":"US"}}}}';

    expect(liveBodyProblem(withBilling), isNotNull);
    expect(liveBodyProblem(withBilling), contains('billing address'));
    // And nothing else is refused: the rule is about that one key.
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
    // `{{timestamp}}` is substituted by the minter at the moment of
    // sending, like every other body in this app.
    for (final scenario in LiveScenario.values) {
      expect(
        liveDefaultBody(scenario),
        contains('{{timestamp}}'),
        reason: scenario.name,
      );
      // And it survives the splice, which re-encodes the whole body.
      expect(minted(scenario), contains('{{timestamp}}'));
    }
  });

  test('a default preset carries the three strings of its tile', () {
    // What `RunScreen` is handed, and what History records. A preset built
    // from the wrong scenario is a saved-card charge filed under the smoke.
    for (final scenario in LiveScenario.values) {
      final preset = liveDefaultPresets.firstWhere(
        (p) => p.id == liveScenarioId(scenario),
      );

      expect(preset.name, liveScenarioName(scenario));
      expect(preset.body, liveDefaultBody(scenario));
      expect(preset.expected, liveScenarioExpectation(scenario));
      // Nothing about a sandbox card belongs on a production tile.
      expect(preset.cardHint, isNull, reason: scenario.name);
    }
    expect(liveDefaultPresets, hasLength(LiveScenario.values.length));
  });

  group('what the confirmation dialog says about where it happens', () {
    final smoke = liveDefaultBody(LiveScenario.smoke);

    test('the sheet asks exactly what it always asked', () {
      // Every call written before the surface existed keeps its wording, and
      // the default is what makes that true rather than a promise about it.
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
      // Somebody who taps Continue expecting a sheet and gets a browser will
      // wonder whether they tapped the wrong thing. This is the one sentence
      // that stops that, and it sits before the money moves.
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
        // Added to the question, not instead of it: the amount and the
        // saved-card sentence are what the tap is actually authorising.
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
