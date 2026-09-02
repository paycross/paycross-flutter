import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/live.dart';
import 'package:paycross_demo/demo/presets.dart';

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
        jsonDecode(liveSmokeBody(identity, liveDefaultCurrency))
            as Map<String, Object?>;

    expect(body['amount'], 100);
    expect(body['currency'], 'EUR');
    expect(body['transaction_type'], 'sale');
    // Unmistakable in a back office full of sandbox noise, and the string
    // somebody searches for when they are looking for the charge to refund.
    expect(body['merchant_reference'], startsWith('LIVE-SMOKE-'));
  });

  test('the chosen currency reaches the body, and the amount does not', () {
    // The whole point of the currency choice: the production merchant may
    // only be able to take one of the three, and until this was passed
    // through, a smoke on a GBP-only merchant could not run at all.
    final gbp =
        jsonDecode(liveSmokeBody(identity, 'GBP')) as Map<String, Object?>;

    expect(gbp['currency'], 'GBP');
    // Minor units, so one pound is the same 100 one euro is. A currency
    // choice that also moved the amount would be an amount editor, which is
    // the one thing Live deliberately does not have.
    expect(gbp['amount'], 100);
  });

  test('the default currency mints the body it always did', () {
    // Byte for byte, not field by field: this is the body that has been
    // charging real cards, and the currency argument was threaded through
    // the helper every sandbox preset also uses. `{{timestamp}}` is still a
    // placeholder at this point, so the two strings are comparable.
    expect(
      liveSmokeBody(identity, liveDefaultCurrency),
      liveBody(
        amount: liveSmokeMinorUnits,
        currency: 'EUR',
        email: identity.email,
        firstName: identity.firstName,
        lastName: identity.lastName,
        customerReference: liveSmokeCustomerReference,
      ),
    );
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

  test('the tile and its subtitle quote the same amount as the body', () {
    // The single-source rule, at the two copy sites that live in this file.
    // The other two are on Home and are pinned there, against the widgets a
    // tester actually reads.
    for (final code in currencies) {
      final label = liveSmokeAmountLabel(code);
      expect(liveSmokeName(code), contains(label), reason: code);
      expect(liveSmokeExpectation(code), contains(label), reason: code);
      // And no other currency's figure is on the tile beside it.
      for (final other in currencies.where((c) => c != code)) {
        expect(
          liveSmokeName(code),
          isNot(contains(liveSmokeAmountLabel(other))),
          reason: '$code / $other',
        );
      }
      final body =
          jsonDecode(liveSmokeBody(identity, code)) as Map<String, Object?>;
      expect(body['currency'], code, reason: code);
    }
  });

  test('the smoke body carries the identity, not the sandbox customer', () {
    final body =
        jsonDecode(liveSmokeBody(identity, liveDefaultCurrency))
            as Map<String, Object?>;
    final customer = body['customer']! as Map<String, Object?>;

    // The fake the sandbox presets use. A New York billing address and a
    // john.doe address are what production AVS and fraud rules are for.
    expect(customer['email'], isNot('john.doe@example.com'));
    expect(jsonEncode(body), isNot(contains('123 Main Street')));
    expect(customer['email'], identity.email);
    expect(customer['first_name'], identity.firstName);
    // `last_name` is in the create schema's `customer.required` list beside
    // the other two, so a body that loses it is a €1.00 smoke that 400s on
    // production -- the one place this app has no cheap way to find out.
    expect(customer['last_name'], identity.lastName);
    // Omitted outright, not replaced with a plausible one. The sandbox
    // default is `+12025551234` -- the reserved fictional Washington-DC 555
    // range -- and on a real EUR charge from a European device that is the
    // same fabricated-contact-detail risk the billing address is omitted
    // for, plus a wrong number written onto a real person's production
    // customer record. `phone` is not in the create schema's
    // `customer.required` list, so leaving it out costs nothing. If a real
    // internal number is ever wanted it is a third typed field beside the
    // name and the email, never an inherited sandbox default.
    expect(customer.containsKey('phone'), isFalse);
  });

  test('the smoke preset expects nothing a runner could misread', () {
    // The rule the sandbox presets are held to, kept here so the two sets
    // cannot diverge. The matrix runner never reads this one: automation
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
      for (final code in currencies) {
        expect(
          liveSmokeExpectation(code).startsWith(prefix),
          isFalse,
          reason: '$code / $prefix',
        );
      }
    }
  });

  test('a name the JSON template cannot hold raw still parses', () {
    // The typed fields are interpolated into a hand-built JSON string, so
    // anything with a quote or a backslash in it has to be escaped rather
    // than pasted. Nobody picks their surname to suit our template.
    //
    // Through `parse` and `liveSmokeBody`, not `liveBody` directly: the
    // split now sits between what a human types and what is encoded, and
    // that is the path a real awkward surname takes.
    const awkward = r'Ada Smith "Bud" O\Jones';

    final typed = LiveIdentity.parse(name: awkward, email: 'ada@example.org')!;
    final customer =
        (jsonDecode(liveSmokeBody(typed, liveDefaultCurrency))
                as Map<String, Object?>)['customer']!
            as Map<String, Object?>;

    expect(customer['first_name'], r'Ada Smith "Bud"');
    expect(customer['last_name'], r'O\Jones');
  });

  test('the smoke body is a template until it is minted', () {
    // `{{timestamp}}` is substituted by the minter at the moment of
    // sending, like every other body in this app.
    expect(
      liveSmokeBody(identity, liveDefaultCurrency),
      contains('{{timestamp}}'),
    );
  });
}
