import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_flutter/paycross_flutter.dart';
import 'package:paycross_demo/e2e_label.dart';

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
      expect(
        recoveryToken(const RecoveryVerifyBeforeRetry()),
        'verify_before_retry',
      );
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
        'verify_before_retry',
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

    test('cancelled names no transaction, with or without one', () {
      expect(labelForResult(const PayCrossCancelled()), 'result:cancelled');
      expect(
        labelForResult(const PayCrossCancelled(transactionId: 'txn_1')),
        'result:cancelled',
      );
    });

    test('pending carries the reason and the transaction id', () {
      expect(
        labelForResult(
          const PayCrossPending(
            transactionId: 'txn_3',
            reason: PayCrossPendingReason.pollTimeout,
            reasonRaw: 'poll_timeout',
          ),
        ),
        'result:pending:poll_timeout:txn_3',
      );
    });

    test('pending with no transaction ends in an empty field', () {
      expect(
        labelForResult(
          const PayCrossPending(
            reason: PayCrossPendingReason.resultLost,
            reasonRaw: 'result_lost',
          ),
        ),
        'result:pending:result_lost:',
      );
    });

    test('an unreadable reason carries its raw value', () {
      expect(
        labelForResult(
          const PayCrossPending(
            transactionId: 'txn_3',
            reason: PayCrossPendingReason.unrecognized,
            reasonRaw: 'later_value',
          ),
        ),
        'result:pending:unrecognized(later_value):txn_3',
      );
    });
  });

  group('pendingReasonToken', () {
    test('spells every case as the wire name the SDK sent', () {
      expect(
        pendingReasonToken(PayCrossPendingReason.pollTimeout, 'poll_timeout'),
        'poll_timeout',
      );
      expect(
        pendingReasonToken(PayCrossPendingReason.resultLost, 'result_lost'),
        'result_lost',
      );
      expect(
        pendingReasonToken(PayCrossPendingReason.serverVerify, 'server_verify'),
        'server_verify',
      );
    });

    test('round-trips every canonical wire name the plugin parses', () {
      for (final name in const [
        'poll_timeout',
        'result_lost',
        'server_verify',
      ]) {
        expect(
          pendingReasonToken(PayCrossPendingReason.fromWireName(name), name),
          name,
        );
      }
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
      const pinned = <PayCrossErrorCode, String>{
        PayCrossErrorCode.notConfigured: 'error:notConfigured',
        PayCrossErrorCode.testPrefillInProduction:
            'error:testPrefillInProduction',
        PayCrossErrorCode.invalidAppearance: 'error:invalidAppearance',
        PayCrossErrorCode.busy: 'error:busy',
        PayCrossErrorCode.noActivity: 'error:noActivity',
        PayCrossErrorCode.noPresenter: 'error:noPresenter',
        PayCrossErrorCode.invalidToken: 'error:invalidToken',
        // ignore: deprecated_member_use
        PayCrossErrorCode.resultUnknown: 'error:resultUnknown',
        PayCrossErrorCode.unknown: 'error:unknown',
      };

      pinned.forEach((code, label) {
        expect(labelForError(PayCrossIntegrationError(code, 'x')), label);
      });

      expect(pinned.keys.toSet(), PayCrossErrorCode.values.toSet());
    });
  });
}
