import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/live.dart';

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
    expect(problem, contains('live.dart'));
  });

  test('an identity with no placeholder left in it is ready', () {
    const supplied = LiveIdentity(
      firstName: 'Ada',
      lastName: 'Lovelace',
      email: 'ada@example.org',
    );

    expect(supplied.isPlaceholder, isFalse);
  });

  test('one placeholder field anywhere is enough to refuse', () {
    // Partially filled is the shape a hurried edit actually leaves behind.
    const half = LiveIdentity(
      firstName: 'Ada',
      lastName: 'REPLACE_ME',
      email: 'ada@example.org',
    );

    expect(half.isPlaceholder, isTrue);
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
    // Same rule the sandbox presets are held to: no expectation may start
    // with one of the five prefixes the matrix runner reads as "this build
    // has no automation define".
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

  test('the smoke body is a template until it is minted', () {
    // `{{timestamp}}` is substituted by the minter at the moment of
    // sending, like every other body in this app.
    expect(liveSmokeBody, contains('{{timestamp}}'));
  });
}
