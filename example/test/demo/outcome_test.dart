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
      'Approved — 1000 EUR, transaction txn_1',
    );
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
      // The sixth variant, and the one a server can invent: a recovery
      // token this SDK does not know still has to render as something no
      // runner would read as a build without the define.
      humanOutcome(
        const PayCrossFailure(recovery: RecoveryUnrecognized('call_the_bank')),
      ),
      humanOutcome(const PayCrossCancelled()),
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

  test('an unknown outcome is distinct from a refusal', () {
    final unknown = humanError(
      const PayCrossIntegrationError(
        PayCrossErrorCode.resultUnknown,
        'The app was killed mid-flight.',
      ),
    );

    // The payment may have gone through: reconcile, do not re-charge.
    expect(unknown, contains('reconcile'));
    expect(unknown, isNot(contains('Refused')));
  });
}
