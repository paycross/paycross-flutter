import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/present.dart';
import 'package:paycross_demo/shop/shop_outcome.dart';
import 'package:paycross_flutter/paycross_flutter.dart';

PresentedRun _run(PayCrossResult? result) =>
    PresentedRun(human: 'the demo wording', result: result);

PresentedRun _refused(PayCrossRecovery recovery) =>
    _run(PayCrossFailure(transactionId: 'txn-2', recovery: recovery));

/// Everything a shopper must never be shown, gathered once so every message
/// below is checked against all of it.
const List<String> _wireVocabulary = <String>[
  'recovery',
  'change_method',
  'do_not_retry',
  'contact_support',
  'verify_before_retry',
  'poll_timeout',
  'unrecognized',
  'transaction',
  'txn-',
  'reconcile',
  'server-side',
  'sandbox',
  'scenario',
  'session',
  'token',
  'preset',
];

void main() {
  group('a refusal', () {
    test('a card that might work next time is a decline', () {
      expect(_refusalFor(const RecoveryChangeMethod()), shopDeclinedMessage);
      expect(_refusalFor(const RecoveryDoNotRetry()), shopDeclinedMessage);
    });

    test('an attempt worth repeating asks for one', () {
      expect(_refusalFor(const RecoveryRetry()), shopTryAgainMessage);
      expect(_refusalFor(const RecoveryRestart()), shopTryAgainMessage);
    });

    test('a refusal only support can settle sends them to support', () {
      expect(_refusalFor(const RecoveryContactSupport()), shopContactUsMessage);
    });

    test('a recovery that means nobody knows is not read as a decline', () {
      expect(
        _refusalFor(const RecoveryVerifyBeforeRetry()),
        shopUnresolvedMessage,
      );
    });

    test('a token this build has no sentence for still says what happened', () {
      expect(
        _refusalFor(const RecoveryUnrecognized('something_new')),
        shopTryAgainMessage,
      );
    });
  });

  group('everything else the sheet can come back with', () {
    test('a cancellation says so', () {
      expect(
        shopOutcomeMessage(_run(const PayCrossCancelled())),
        shopCancelledMessage,
      );
    });

    test('an unresolved payment tells the shopper not to pay again', () {
      expect(
        shopOutcomeMessage(
          _run(
            const PayCrossPending(
              transactionId: 'txn-3',
              reason: PayCrossPendingReason.pollTimeout,
              reasonRaw: 'poll_timeout',
            ),
          ),
        ),
        shopUnresolvedMessage,
      );
    });

    test('a sheet that threw reads as something going wrong', () {
      expect(shopOutcomeMessage(_run(null)), shopWentWrongMessage);
    });
  });

  group('paying again', () {
    test('is refused after an unresolved payment', () {
      expect(
        shopMayPayAgain(
          _run(
            const PayCrossPending(
              reason: PayCrossPendingReason.resultLost,
              reasonRaw: 'result_lost',
            ),
          ),
        ),
        isFalse,
      );
    });

    test('is allowed after a decline, a cancellation and a throw', () {
      expect(shopMayPayAgain(_refused(const RecoveryDoNotRetry())), isTrue);
      expect(shopMayPayAgain(_run(const PayCrossCancelled())), isTrue);
      expect(shopMayPayAgain(_run(null)), isTrue);
    });
  });

  test('no shop message carries the wire vocabulary', () {
    final messages = <String>[
      shopCancelledMessage,
      shopDeclinedMessage,
      shopTryAgainMessage,
      shopContactUsMessage,
      shopUnresolvedMessage,
      shopWentWrongMessage,
    ];
    for (final message in messages) {
      for (final word in _wireVocabulary) {
        expect(
          message.toLowerCase(),
          isNot(contains(word.toLowerCase())),
          reason: '"$message" carries "$word"',
        );
      }
    }
  });
}

String _refusalFor(PayCrossRecovery recovery) =>
    shopOutcomeMessage(_refused(recovery));
