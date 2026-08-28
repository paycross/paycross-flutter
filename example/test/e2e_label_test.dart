import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_flutter/paycross_flutter.dart';
import 'package:paycross_flutter_example/e2e_label.dart';

PayCrossSuccess _success(String txn) => PayCrossSuccess(
  transactionId: txn,
  status: 'success',
  amount: const PayCrossAmount(minorUnits: 1000, currencyCode: 'EUR'),
);

void main() {
  group('recoveryToken', () {
    test('spells every case as the API token the server sent', () {
      expect(recoveryToken(const RecoveryRetry()), 'retry');
      expect(recoveryToken(const RecoveryChangeMethod()), 'change_method');
      expect(recoveryToken(const RecoveryRestart()), 'restart');
      expect(recoveryToken(const RecoveryDoNotRetry()), 'do_not_retry');
      expect(recoveryToken(const RecoveryContactSupport()), 'contact_support');
    });

    test('carries the raw value for a token this SDK does not know', () {
      expect(
        recoveryToken(const RecoveryUnrecognized('call_the_bank')),
        'unrecognized(call_the_bank)',
      );
    });

    test('round-trips every canonical token fromApiValue parses', () {
      for (final token in const [
        'retry',
        'change_method',
        'restart',
        'do_not_retry',
        'contact_support',
      ]) {
        expect(recoveryToken(PayCrossRecovery.fromApiValue(token)), token);
      }
    });
  });

  group('labelForResult', () {
    test('success carries the transaction id', () {
      expect(labelForResult(_success('txn_1')), 'result:success:txn_1');
    });

    test('success with no transaction reference ends in an empty field', () {
      expect(labelForResult(_success('')), 'result:success:');
    });

    test('failure carries the recovery token and the transaction id', () {
      expect(
        labelForResult(
          const PayCrossFailure(
            transactionId: 'txn_2',
            recovery: RecoveryDoNotRetry(),
          ),
        ),
        'result:failure:do_not_retry:txn_2',
      );
    });

    test('a failure before a transaction existed ends in an empty field', () {
      expect(
        labelForResult(const PayCrossFailure(recovery: RecoveryRestart())),
        'result:failure:restart:',
      );
    });

    test('cancelled has no fields', () {
      expect(labelForResult(const PayCrossCancelled()), 'result:cancelled');
    });
  });

  group('labelForError', () {
    test('names the error code', () {
      expect(
        labelForError(
          const PayCrossIntegrationError(
            PayCrossErrorCode.invalidToken,
            'The session token was empty.',
          ),
        ),
        'error:invalidToken',
      );
    });

    test('spells every declared code as a pinned literal', () {
      // Written out rather than derived from code.name: deriving the
      // expectation from the implementation's own expression would assert
      // nothing. These are the strings cell files compare against.
      const pinned = <PayCrossErrorCode, String>{
        PayCrossErrorCode.notConfigured: 'error:notConfigured',
        PayCrossErrorCode.testPrefillInProduction:
            'error:testPrefillInProduction',
        PayCrossErrorCode.busy: 'error:busy',
        PayCrossErrorCode.noActivity: 'error:noActivity',
        PayCrossErrorCode.noPresenter: 'error:noPresenter',
        PayCrossErrorCode.invalidToken: 'error:invalidToken',
        PayCrossErrorCode.resultUnknown: 'error:resultUnknown',
        PayCrossErrorCode.unknown: 'error:unknown',
      };

      pinned.forEach((code, label) {
        expect(labelForError(PayCrossIntegrationError(code, 'x')), label);
      });

      // A code added to the enum fails here rather than reaching a cell file
      // as an unpinned label; a renamed one fails on the map key above.
      expect(pinned.keys.toSet(), PayCrossErrorCode.values.toSet());
    });
  });
}
