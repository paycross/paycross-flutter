import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/live.dart';
import 'package:paycross_demo/demo/presets.dart';

void main() {
  test('the shipped identity is a placeholder, and says so', () {
    // This test is expected to KEEP passing until the owner supplies the
    // real identity, and to be updated in the same commit that does.
    // Its job is to make sure the placeholder is detectable rather than
    // merely conventional -- a constant that looked real would sail
    // through review and reach a production charge.
    expect(liveSmokeIdentityUnset, isTrue);
  });

  test('the refusal names the constant somebody has to change', () {
    final problem = liveSmokeIdentityProblem;

    expect(problem, isNotNull);
    expect(problem, contains('liveSmokeIdentity'));
    // The whole path, and a path that resolves. The refusal's entire job is
    // to be believed by somebody holding a phone, so a message still naming
    // a file that has since moved is worse than no message.
    expect(problem, contains('lib/demo/live.dart'));
    expect(
      File('lib/demo/live.dart').existsSync(),
      isTrue,
      reason: 'the refusal names this path; it has to be real',
    );
  });

  test('one placeholder field anywhere is enough to refuse', () {
    // Partially filled is the shape a hurried edit actually leaves behind,
    // and every field is covered on purpose rather than one of them: the
    // list inside `isPlaceholder` is hand-maintained, so a field added to
    // LiveIdentity and forgotten there is a placeholder that reaches a real
    // charge with nothing left to object.
    const supplied = LiveIdentity(
      firstName: 'Ada',
      lastName: 'Lovelace',
      email: 'ada@example.org',
    );

    expect(supplied.isPlaceholder, isFalse);

    for (final half in const [
      LiveIdentity(
        firstName: 'REPLACE_ME',
        lastName: 'Lovelace',
        email: 'ada@example.org',
      ),
      LiveIdentity(
        firstName: 'Ada',
        lastName: 'REPLACE_ME',
        email: 'ada@example.org',
      ),
      // An ordinary domain, deliberately: on `.invalid` this case would pass
      // through the reserved-TLD clause and stop saying anything about
      // whether `email` is in the list at all.
      LiveIdentity(
        firstName: 'Ada',
        lastName: 'Lovelace',
        email: 'REPLACE_ME@example.org',
      ),
    ]) {
      expect(
        half.isPlaceholder,
        isTrue,
        reason: '${half.firstName}/${half.lastName}/${half.email}',
      );
    }
  });

  test('a half-edited email that keeps the reserved domain still refuses', () {
    // The shape of an edit that replaced the local part of
    // REPLACE_ME@paycross.invalid and left the domain alone. `.invalid` is a
    // reserved TLD that can never resolve, so this is an address no receipt
    // will ever reach -- on a charge whose whole point is being refunded by a
    // human who was told about it.
    const halfEdited = LiveIdentity(
      firstName: 'Ada',
      lastName: 'Lovelace',
      email: 'smoke@paycross.invalid',
    );

    expect(halfEdited.isPlaceholder, isTrue);
  });

  test('the smoke charges one euro, and says so in its reference', () {
    final body = jsonDecode(liveSmokeBody) as Map<String, Object?>;

    expect(body['amount'], 100);
    expect(body['currency'], 'EUR');
    expect(body['transaction_type'], 'sale');
    // Unmistakable in a back office full of sandbox noise, and the string
    // somebody searches for when they are looking for the charge to refund.
    expect(body['merchant_reference'], startsWith('LIVE-SMOKE-'));
  });

  test('the smoke body carries the identity, not the sandbox customer', () {
    final body = jsonDecode(liveSmokeBody) as Map<String, Object?>;
    final customer = body['customer']! as Map<String, Object?>;

    // The fake the sandbox presets use. A New York billing address and a
    // john.doe address are what production AVS and fraud rules are for.
    expect(customer['email'], isNot('john.doe@example.com'));
    expect(jsonEncode(body), isNot(contains('123 Main Street')));
    expect(customer['email'], liveSmokeIdentity.email);
    expect(customer['first_name'], liveSmokeIdentity.firstName);
    // `last_name` is in the create schema's `customer.required` list beside
    // the other two, so a body that loses it is a €1.00 smoke that 400s on
    // production -- the one place this app has no cheap way to find out.
    expect(customer['last_name'], liveSmokeIdentity.lastName);
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
      expect(liveSmokePreset.expected.startsWith(prefix), isFalse);
    }
  });

  test('a name the JSON template cannot hold raw still parses', () {
    // The three owner-supplied fields are interpolated into a hand-built JSON
    // string, so anything with a quote or a backslash in it has to be escaped
    // rather than pasted. Nobody picks their surname to suit our template.
    const awkward = r'Smith "Bud" O\Jones';

    final body = liveBody(
      amount: 100,
      email: 'ada@example.org',
      firstName: 'Ada',
      lastName: awkward,
      customerReference: 'ref',
    );
    final customer =
        (jsonDecode(body) as Map<String, Object?>)['customer']!
            as Map<String, Object?>;

    expect(customer['last_name'], awkward);
  });

  test('the smoke body is a template until it is minted', () {
    // `{{timestamp}}` is substituted by the minter at the moment of
    // sending, like every other body in this app.
    expect(liveSmokeBody, contains('{{timestamp}}'));
  });
}
