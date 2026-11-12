import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/outcome.dart';
import 'package:paycross_flutter/paycross_flutter.dart';

import 'presets_test.dart' show legacyLabelPrefixes;

PayCrossSuccess _success(String txn) => PayCrossSuccess(
  transactionId: txn,
  status: 'success',
  amount: const PayCrossAmount(minorUnits: 1000, currencyCode: 'EUR'),
);

void main() {
  test('a success names the amount and the transaction', () {
    expect(
      humanOutcome(_success('txn_1')),
      'Approved — €10.00, transaction txn_1',
    );
    expect(
      humanOutcome(
        const PayCrossSuccess(
          transactionId: 'txn_gbp',
          status: 'success',
          amount: PayCrossAmount(minorUnits: 100, currencyCode: 'GBP'),
        ),
      ),
      'Approved — £1.00, transaction txn_gbp',
    );
  });

  test('a success that saved a card names the token', () {
    expect(
      humanOutcome(
        const PayCrossSuccess(
          transactionId: 'txn_2',
          status: 'success',
          amount: PayCrossAmount(minorUnits: 1000, currencyCode: 'EUR'),
          savedCardToken: 'tok_1',
        ),
      ),
      'Approved — €10.00, transaction txn_2, saved card tok_1',
    );
  });

  test('a success that saved nothing names no token', () {
    expect(humanOutcome(_success('txn_3')), isNot(contains('saved card')));
  });

  test('a refusal names the recovery the server sent', () {
    expect(
      humanOutcome(
        const PayCrossFailure(
          transactionId: 'txn_2',
          recovery: RecoveryDoNotRetry(),
        ),
      ),
      'Refused — recovery do_not_retry, transaction txn_2',
    );
    expect(
      humanOutcome(const PayCrossFailure(recovery: RecoveryChangeMethod())),
      'Refused, worth another attempt — recovery change_method',
    );
  });

  test('no human outcome could be read as a build without the define', () {
    final everyOutcome = <String>[
      humanOutcome(_success('txn_1')),
      humanOutcome(_success('')),
      humanOutcome(const PayCrossFailure(recovery: RecoveryRetry())),
      humanOutcome(const PayCrossFailure(recovery: RecoveryChangeMethod())),
      humanOutcome(const PayCrossFailure(recovery: RecoveryRestart())),
      humanOutcome(const PayCrossFailure(recovery: RecoveryDoNotRetry())),
      humanOutcome(const PayCrossFailure(recovery: RecoveryContactSupport())),
      humanOutcome(
        const PayCrossFailure(recovery: RecoveryUnrecognized('call_the_bank')),
      ),
      humanOutcome(const PayCrossCancelled()),
      for (final reason in PayCrossPendingReason.values)
        humanOutcome(
          PayCrossPending(
            transactionId: 'txn_1',
            reason: reason,
            reasonRaw: 'a_reason',
          ),
        ),
      for (final code in PayCrossErrorCode.values)
        humanError(PayCrossIntegrationError(code, 'a message')),
    ];

    for (final text in everyOutcome) {
      for (final prefix in legacyLabelPrefixes) {
        expect(
          text.startsWith(prefix),
          isFalse,
          reason:
              '"$text" starts with "$prefix". The matrix runner reads that '
              'as "this build is missing --dart-define=PAYCROSS_E2E=true", '
              'so a genuine hang here would be misreported as a wrong build.',
        );
      }
    }
  });

  test('an unresolved outcome is distinct from a refusal', () {
    final unknown = humanOutcome(
      const PayCrossPending(
        transactionId: 'txn_4',
        reason: PayCrossPendingReason.pollTimeout,
        reasonRaw: 'poll_timeout',
      ),
    );

    expect(unknown, contains('reconcile'));
    expect(unknown, contains('txn_4'));
    expect(unknown, isNot(contains('Refused')));
  });

  test('an unresolved outcome with no transaction says so cleanly', () {
    expect(
      humanOutcome(
        const PayCrossPending(
          reason: PayCrossPendingReason.resultLost,
          reasonRaw: 'result_lost',
        ),
      ),
      'Unresolved — reconcile server-side, reason result_lost',
    );
  });

  const jwt =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.'
      'eyJzdWIiOiIxMjM0NTY3ODkwIn0.'
      'dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXkg';

  test('a native error message cannot carry a token into a bug report', () {
    final text = humanError(
      const PayCrossIntegrationError(
        PayCrossErrorCode.unknown,
        'the session was refused: $jwt',
      ),
    );

    expect(text, isNot(contains(jwt)));
    expect(text, contains('<redacted>'));
  });

  test('a runaway native message is cut short rather than pasted whole', () {
    final text = humanError(
      PayCrossIntegrationError(PayCrossErrorCode.unknown, 'x' * 5000),
    );

    expect(text.length, lessThan(500));
    expect(text, endsWith('…'));
  });
}
