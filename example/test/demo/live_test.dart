import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/live.dart';
import 'package:paycross_demo/demo/presets.dart';
import 'package:paycross_demo/demo/surface.dart';

/// The smoke body, to the byte, as it has been charging real cards.
///
/// A literal rather than another call to the helper that builds it: a
/// comparison against `liveBody(...)` compares the helper with itself and
/// passes however the helper changed, and this is the one body in the app
/// whose bytes were proven on a production merchant. Two tiles were added
/// beside it; this is what says the first one did not move.
///
/// `{{timestamp}}` is still a placeholder here -- the minter substitutes it
/// at the moment of sending -- so the two strings are comparable.
const String _smokeBodyAsShipped = '''
{
  "amount": 100,
  "currency": "EUR",
  "transaction_type": "sale",
  "merchant_reference": "LIVE-SMOKE-{{timestamp}}",
  "return_url": "https://merchant.example.com/payment/return",
  "success_url": "https://merchant.example.com/payment/success",
  "customer": {
    "email": "ada@example.org",
    "first_name": "Ada",
    "last_name": "Lovelace",
    "merchant_reference": "paycross_live_smoke"
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
        jsonDecode(
              liveScenarioBody(
                LiveScenario.smoke,
                identity,
                liveDefaultCurrency,
              ),
            )
            as Map<String, Object?>;

    expect(body['amount'], 100);
    expect(body['currency'], 'EUR');
    expect(body['transaction_type'], 'sale');
    // Unmistakable in a back office full of sandbox noise, and the string
    // somebody searches for when they are looking for the charge to refund.
    expect(body['merchant_reference'], startsWith('LIVE-SMOKE-'));
  });

  test('every tile charges one unit of the chosen currency', () {
    // The whole point of the currency choice: the production merchant may
    // only be able to take one of the three, and until this was passed
    // through, a smoke on a GBP-only merchant could not run at all. All
    // three tiles, because a saved-card tile that fell back to the default
    // would be refused on that same merchant.
    for (final scenario in LiveScenario.values) {
      final gbp =
          jsonDecode(liveScenarioBody(scenario, identity, 'GBP'))
              as Map<String, Object?>;

      expect(gbp['currency'], 'GBP', reason: scenario.name);
      // Minor units, so one pound is the same 100 one euro is. A currency
      // choice that also moved the amount would be an amount editor, which
      // is the one thing Live deliberately does not have.
      expect(gbp['amount'], 100, reason: scenario.name);
    }
  });

  test('the smoke body is the bytes that have been charging real cards', () {
    // Byte for byte against a literal, not against the helper that builds
    // it. Two tiles were added beside this one and both reach the same
    // helper through a new argument; this is the case that says the tile
    // which was already spending money did not change by a comma.
    expect(
      liveScenarioBody(LiveScenario.smoke, identity, liveDefaultCurrency),
      _smokeBodyAsShipped,
    );
  });

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
          jsonDecode(liveScenarioBody(entry.key, identity, liveDefaultCurrency))
              as Map<String, Object?>;
      final withoutKey = Map<String, Object?>.of(body)..remove(entry.value);

      expect(body.containsKey(entry.value), isTrue, reason: entry.key.name);
      expect(
        jsonEncode(withoutKey),
        jsonEncode(jsonDecode(_smokeBodyAsShipped)),
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
        jsonDecode(
              liveScenarioBody(
                LiveScenario.storeCard,
                identity,
                liveDefaultCurrency,
              ),
            )
            as Map<String, Object?>;
    final pay =
        jsonDecode(
              liveScenarioBody(
                LiveScenario.paySavedCard,
                identity,
                liveDefaultCurrency,
              ),
            )
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
          (jsonDecode(liveScenarioBody(scenario, identity, 'GBP'))
                  as Map<String, Object?>)['customer']!
              as Map<String, Object?>;

      expect(
        customer['merchant_reference'],
        liveSmokeCustomerReference,
        reason: scenario.name,
      );
      // And the same identity, not the sandbox fake, on every one of them.
      expect(customer['email'], identity.email, reason: scenario.name);
    }
  });

  test('the amount label is the one place the figure is written', () {
    // Three currencies, one figure, three symbols. Pinned as whole strings
    // because these are what a human reads on the tile and in the dialog
    // before deciding to spend money.
    expect(liveSmokeAmountLabel('EUR'), '€1.00');
    expect(liveSmokeAmountLabel('USD'), r'$1.00');
    expect(liveSmokeAmountLabel('GBP'), '£1.00');
    // Every currency the Live form can offer has a symbol, so the fallback
    // below is unreachable from the app. It is here for the day a fourth is
    // added to the list and nobody remembers this map.
    for (final code in currencies) {
      expect(liveSmokeAmountLabel(code), isNot(contains(code)), reason: code);
    }
    // And that day: the code, not a euro sign borrowed from the default. An
    // unknown currency printed under the wrong symbol is the one failure
    // worth ruling out here.
    expect(liveSmokeAmountLabel('JPY'), '1.00 JPY');
  });

  test('every tile quotes the same amount as its body, in every currency', () {
    // The single-source rule, at the three copy sites that live in this
    // file. The rest are on Home and are pinned there, against the widgets a
    // tester actually reads.
    for (final scenario in LiveScenario.values) {
      for (final code in currencies) {
        final label = liveSmokeAmountLabel(code);
        final quoted = <String>[
          liveScenarioName(scenario, code),
          liveScenarioExpectation(scenario, code),
          liveConfirmQuestion(scenario, code),
        ];

        for (final line in quoted) {
          expect(line, contains(label), reason: '${scenario.name}: $line');
          // And no other currency's figure is anywhere near it.
          for (final other in currencies.where((c) => c != code)) {
            expect(
              line,
              isNot(contains(liveSmokeAmountLabel(other))),
              reason: '${scenario.name} $code / $other: $line',
            );
          }
        }

        final body =
            jsonDecode(liveScenarioBody(scenario, identity, code))
                as Map<String, Object?>;
        expect(body['currency'], code, reason: '${scenario.name} / $code');
      }
    }
  });

  test('the three tiles are three distinct, self-describing names', () {
    // A run is recorded in History by its preset name, so two tiles sharing
    // one name are two charges nobody can tell apart afterwards.
    for (final code in currencies) {
      final names = LiveScenario.values
          .map((s) => liveScenarioName(s, code))
          .toList();

      expect(names.toSet(), hasLength(3), reason: code);
      // Every one of them says Live, because that name is the title of the
      // run screen and the row in History.
      for (final name in names) {
        expect(name, contains('Live'), reason: name);
      }
    }
    // And each says what it does, in the words the README uses for it.
    expect(
      liveScenarioName(LiveScenario.smoke, 'GBP'),
      'Live smoke — £1.00 charge',
    );
    expect(
      liveScenarioName(LiveScenario.storeCard, 'GBP'),
      'Live — store card, £1.00 charge',
    );
    expect(
      liveScenarioName(LiveScenario.paySavedCard, 'GBP'),
      'Live — pay with saved card, £1.00 charge',
    );
  });

  test('the dialog says what the tile will do, beyond the amount', () {
    // The smoke's question is the one that shipped, unchanged. The other two
    // add one sentence each, because "charge a real card £1.00" is not the
    // whole truth about a tile that also stores the card.
    expect(
      liveConfirmQuestion(LiveScenario.smoke, 'EUR'),
      'This will charge a real card €1.00. Continue?',
    );
    expect(
      liveConfirmQuestion(LiveScenario.storeCard, 'EUR'),
      contains('stores the card'),
    );
    expect(
      liveConfirmQuestion(LiveScenario.paySavedCard, 'EUR'),
      contains('already stored'),
    );
    // All three still ask, rather than announce.
    for (final scenario in LiveScenario.values) {
      final question = liveConfirmQuestion(scenario, 'EUR');
      expect(question, contains('charge a real card'), reason: scenario.name);
      expect(question, endsWith('Continue?'), reason: scenario.name);
    }
  });

  test('the subtitles tell a tester the order and the refund', () {
    for (final code in currencies) {
      // Every tile is money that has to be handed back, and the subtitle is
      // where a tester reads it before tapping.
      for (final scenario in LiveScenario.values) {
        expect(
          liveScenarioExpectation(scenario, code),
          contains('Refund'),
          reason: '${scenario.name} / $code',
        );
      }
      // The pair is ordered: the list of cards in the sheet is snapshotted
      // at session creation, so nothing is there to pay with until the store
      // tile has settled.
      expect(
        liveScenarioExpectation(LiveScenario.paySavedCard, code),
        contains('store card'),
        reason: code,
      );
    }
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
      // Every currency, since the expectation is built from one now and a
      // symbol at the front of it would be a different string each time.
      for (final scenario in LiveScenario.values) {
        for (final code in currencies) {
          expect(
            liveScenarioExpectation(scenario, code).startsWith(prefix),
            isFalse,
            reason: '${scenario.name} / $code / $prefix',
          );
        }
      }
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

  test('a name the JSON template cannot hold raw still parses', () {
    // The typed fields are interpolated into a hand-built JSON string, so
    // anything with a quote or a backslash in it has to be escaped rather
    // than pasted. Nobody picks their surname to suit our template.
    //
    // Through `parse` and `liveScenarioBody`, not `liveBody` directly: the
    // split now sits between what a human types and what is encoded, and
    // that is the path a real awkward surname takes.
    const awkward = r'Ada Smith "Bud" O\Jones';

    final typed = LiveIdentity.parse(name: awkward, email: 'ada@example.org')!;

    // Every tile, because all three interpolate the same fields and a body
    // that escaped one of them and not the others would be invalid JSON on
    // exactly the tile nobody tried.
    for (final scenario in LiveScenario.values) {
      final customer =
          (jsonDecode(liveScenarioBody(scenario, typed, liveDefaultCurrency))
                  as Map<String, Object?>)['customer']!
              as Map<String, Object?>;

      expect(customer['first_name'], r'Ada Smith "Bud"', reason: scenario.name);
      expect(customer['last_name'], r'O\Jones', reason: scenario.name);
    }
  });

  test('no tile body carries the sandbox customer or its address', () {
    for (final scenario in LiveScenario.values) {
      final raw = liveScenarioBody(scenario, identity, liveDefaultCurrency);
      final body = jsonDecode(raw) as Map<String, Object?>;
      final customer = body['customer']! as Map<String, Object?>;

      // The fake the sandbox presets use. A New York billing address and a
      // john.doe address are what production AVS and fraud rules are for.
      expect(customer['email'], isNot('john.doe@example.com'));
      expect(raw, isNot(contains('123 Main Street')), reason: scenario.name);
      expect(customer['first_name'], identity.firstName);
      // `last_name` is in the create schema's `customer.required` list beside
      // the other two, so a body that loses it is a 1.00 smoke that 400s on
      // production -- the one place this app has no cheap way to find out.
      expect(customer['last_name'], identity.lastName);
      // Omitted outright, not replaced with a plausible one. The sandbox
      // default is `+12025551234` -- the reserved fictional Washington-DC 555
      // range -- and on a real charge from a European device that is the same
      // fabricated-contact-detail risk the billing address is omitted for,
      // plus a wrong number written onto a real person's production customer
      // record. `phone` is not in the create schema's `customer.required`
      // list, so leaving it out costs nothing. If a real internal number is
      // ever wanted it is a third typed field beside the name and the email,
      // never an inherited sandbox default.
      expect(customer.containsKey('phone'), isFalse, reason: scenario.name);
    }
  });

  test('every tile body is a template until it is minted', () {
    // `{{timestamp}}` is substituted by the minter at the moment of
    // sending, like every other body in this app.
    for (final scenario in LiveScenario.values) {
      expect(
        liveScenarioBody(scenario, identity, liveDefaultCurrency),
        contains('{{timestamp}}'),
        reason: scenario.name,
      );
    }
  });

  test('a preset carries the three strings of the tile it belongs to', () {
    // What `RunScreen` is handed, and what History records. A preset built
    // from the wrong scenario is a saved-card charge filed under the smoke.
    for (final scenario in LiveScenario.values) {
      final preset = livePreset(scenario, identity, 'USD');

      expect(preset.name, liveScenarioName(scenario, 'USD'));
      expect(preset.body, liveScenarioBody(scenario, identity, 'USD'));
      expect(preset.expected, liveScenarioExpectation(scenario, 'USD'));
      // Nothing about a sandbox card belongs on a production tile.
      expect(preset.cardHint, isNull, reason: scenario.name);
    }
  });

  group('what the confirmation dialog says about where it happens', () {
    test('the sheet asks exactly what it always asked', () {
      // Every call written before the surface existed keeps its wording, and
      // the default is what makes that true rather than a promise about it.
      for (final scenario in LiveScenario.values) {
        expect(
          liveConfirmQuestion(scenario, 'EUR'),
          liveConfirmQuestion(
            scenario,
            'EUR',
            surface: PaymentSurface.sdkSheet,
          ),
          reason: scenario.name,
        );
        expect(
          liveConfirmQuestion(scenario, 'EUR'),
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
          scenario,
          'EUR',
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
          LiveScenario.storeCard,
          'EUR',
          surface: PaymentSurface.webCheckout,
        ),
        stringContainsInOrder([
          'charge a real card',
          'stores the card',
          'opens in your browser',
          'Continue?',
        ]),
      );
    });
  });
}
