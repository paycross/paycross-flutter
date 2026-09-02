import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_flutter/paycross_flutter.dart';
import 'package:paycross_flutter/src/generated/paycross_api.g.dart' as g;

/// Stands in for the native side. Nothing here compiles a line of Kotlin or
/// Swift, so these tests verify the contract's *shape* and the Dart facade's
/// behaviour — not that either platform implementation conforms. Only a real
/// device or simulator can do that.
///
/// Subclasses Pigeon's generated client directly, which is what Pigeon now
/// recommends over its own deprecated generated test handler.
class FakeHost extends g.PayCrossHostApi {
  FakeHost({this.result, this.error});

  final g.PcPaymentResult? result;
  final PlatformException? error;

  g.PcConfiguration? lastConfiguration;
  String? lastToken;
  int presentCalls = 0;

  @override
  Future<void> configure(g.PcConfiguration configuration) async {
    lastConfiguration = configuration;
  }

  @override
  Future<g.PcVersionInfo> versionInfo() async =>
      g.PcVersionInfo(pluginVersion: '0.2.0', nativeSdkVersion: null);

  @override
  Future<g.PcPaymentResult> presentPayment(String sessionToken) async {
    presentCalls++;
    lastToken = sessionToken;
    if (error != null) throw error!;
    return result!;
  }
}

g.PcAmount _amount([int minor = 1250, String code = 'EUR']) =>
    g.PcAmount(minorUnits: minor, currencyCode: code);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('result mapping', () {
    test('success carries the transaction, status and amount', () async {
      PayCross.debugHostApi = (FakeHost(
        result: g.PcSuccess(
          transactionId: 'txn_1',
          status: 'success',
          amount: _amount(),
        ),
      ));

      final result = await PayCross.presentPayment('token');

      expect(result, isA<PayCrossSuccess>());
      final success = result as PayCrossSuccess;
      expect(success.transactionId, 'txn_1');
      expect(success.status, 'success');
      expect(success.amount.minorUnits, 1250);
      expect(success.amount.currencyCode, 'EUR');
      expect(success.hasTransactionReference, isTrue);
    });

    /// The already-complete-session case. Both native SDKs report an empty
    /// transaction id rather than a null, so the flag exists to make the
    /// difference checkable instead of merchants comparing to ''.
    test('success with no transaction reference is flagged', () async {
      PayCross.debugHostApi = (FakeHost(
        result: g.PcSuccess(
          transactionId: '',
          status: 'success',
          amount: _amount(0, ''),
        ),
      ));

      final result = await PayCross.presentPayment('token') as PayCrossSuccess;
      expect(result.hasTransactionReference, isFalse);
    });

    test('cancellation maps to PayCrossCancelled', () async {
      PayCross.debugHostApi = (FakeHost(result: g.PcCancelled()));
      expect(await PayCross.presentPayment('token'), isA<PayCrossCancelled>());
    });
  });

  group('recovery parsing', () {
    Future<PayCrossRecovery> parse(String raw) async {
      PayCross.debugHostApi = (FakeHost(
        result: g.PcFailure(transactionId: 'txn_1', recovery: raw),
      ));
      final result = await PayCross.presentPayment('token');
      return (result as PayCrossFailure).recovery;
    }

    test('known tokens map to their cases', () async {
      expect(await parse('retry'), isA<RecoveryRetry>());
      expect(await parse('change_method'), isA<RecoveryChangeMethod>());
      expect(await parse('restart'), isA<RecoveryRestart>());
      expect(await parse('do_not_retry'), isA<RecoveryDoNotRetry>());
    });

    test('contact_us is an alias for contact_support', () async {
      expect(await parse('contact_support'), isA<RecoveryContactSupport>());
      expect(await parse('contact_us'), isA<RecoveryContactSupport>());
    });

    test('absent recovery means retry, matching both native SDKs', () async {
      expect(await parse(''), isA<RecoveryRetry>());
    });

    test('tokens are trimmed and lowercased', () async {
      expect(await parse('  CHANGE_METHOD '), isA<RecoveryChangeMethod>());
    });

    /// The reason recovery crosses as a string rather than a Pigeon enum. A
    /// closed enum would have rewritten this to something wrong; instead the
    /// raw value survives for telemetry and is not retryable.
    test('an unknown token is preserved and is not retryable', () async {
      final recovery = await parse('issuer_wants_a_phone_call');
      expect(recovery, isA<RecoveryUnrecognized>());
      expect(
        (recovery as RecoveryUnrecognized).value,
        'issuer_wants_a_phone_call',
      );
      expect(recovery.isRetryable, isFalse);
    });

    test('only retry and change_method are retryable', () async {
      expect((await parse('retry')).isRetryable, isTrue);
      expect((await parse('change_method')).isRetryable, isTrue);
      for (final token in ['restart', 'contact_support', 'do_not_retry']) {
        expect((await parse(token)).isRetryable, isFalse, reason: token);
      }
    });
  });

  group('integration errors', () {
    test('a platform error becomes a typed PayCrossIntegrationError', () async {
      PayCross.debugHostApi = (FakeHost(
        error: PlatformException(
          code: 'paycross_no_activity',
          message: 'not attached',
        ),
      ));

      await expectLater(
        PayCross.presentPayment('token'),
        throwsA(
          isA<PayCrossIntegrationError>().having(
            (e) => e.code,
            'code',
            PayCrossErrorCode.noActivity,
          ),
        ),
      );
    });

    /// Distinct from a failure on purpose: the payment may have succeeded, so
    /// the merchant must reconcile rather than re-charge.
    test('a lost result surfaces as resultUnknown', () async {
      PayCross.debugHostApi = (FakeHost(
        error: PlatformException(
          code: 'paycross_result_unknown',
          message: 'engine detached',
        ),
      ));

      await expectLater(
        PayCross.presentPayment('token'),
        throwsA(
          isA<PayCrossIntegrationError>().having(
            (e) => e.code,
            'code',
            PayCrossErrorCode.resultUnknown,
          ),
        ),
      );
    });

    test('an unrecognised code does not crash the mapping', () async {
      PayCross.debugHostApi = FakeHost(
        error: PlatformException(code: 'something_new'),
      );

      await expectLater(
        PayCross.presentPayment('token'),
        throwsA(
          isA<PayCrossIntegrationError>().having(
            (e) => e.code,
            'code',
            PayCrossErrorCode.unknown,
          ),
        ),
      );
    });
  });

  group('configure', () {
    /// Its own code, not `notConfigured`: configure *was* called here, and
    /// reusing the "never called" code sent merchants looking for a missing
    /// call that is right in front of them.
    test('a test card prefill is refused in production', () async {
      PayCross.debugHostApi = FakeHost();

      await expectLater(
        PayCross.configure(
          environment: PayCrossEnvironment.production,
          testCardPrefill: const PayCrossTestCardPrefill(
            pan: '4111111111111111',
          ),
        ),
        throwsA(
          isA<PayCrossIntegrationError>().having(
            (e) => e.code,
            'code',
            PayCrossErrorCode.testPrefillInProduction,
          ),
        ),
      );
    });

    /// A PAN in a crash report is the failure mode this guard exists to
    /// prevent, so the refusal it throws must not carry one either — not the
    /// full number, not the last four, not the CVV. Both the raw message and
    /// toString() are checked, since either can reach a log.
    test('the production-prefill refusal leaks no card data', () async {
      PayCross.debugHostApi = FakeHost();

      const pan = '4111111111111111';
      const cvv = '737';
      final lastFour = pan.substring(pan.length - 4);

      await expectLater(
        PayCross.configure(
          environment: PayCrossEnvironment.production,
          testCardPrefill: const PayCrossTestCardPrefill(pan: pan, cvv: cvv),
        ),
        throwsA(
          isA<PayCrossIntegrationError>().having(
            (e) => '${e.message}|$e',
            'message and toString',
            allOf(
              isNot(contains(pan)),
              isNot(contains(lastFour)),
              isNot(contains(cvv)),
            ),
          ),
        ),
      );
    });

    test('a prefill is allowed in sandbox and reaches the platform', () async {
      final host = FakeHost();
      PayCross.debugHostApi = (host);

      await PayCross.configure(
        environment: PayCrossEnvironment.sandbox,
        brandColorArgb: 0xFF6750A4,
        testCardPrefill: const PayCrossTestCardPrefill(
          pan: '4111111111111111',
          cvv: '123',
        ),
      );

      expect(host.lastConfiguration?.environment, g.PcEnvironment.sandbox);
      expect(host.lastConfiguration?.brandColorArgb, 0xFF6750A4);
      expect(host.lastConfiguration?.testCardPrefill?.pan, '4111111111111111');
    });

    /// Google requires the merchant id in `merchantInfo` for production Google
    /// Pay requests. Losing it between Dart and the native SDK is invisible in
    /// sandbox and breaks the wallet only once the merchant goes live.
    test('a Google Pay merchant id reaches the platform', () async {
      final host = FakeHost();
      PayCross.debugHostApi = (host);

      await PayCross.configure(
        environment: PayCrossEnvironment.production,
        googlePayMerchantId: 'BCR2DN4T2ABCDEFG',
      );

      expect(host.lastConfiguration?.googlePayMerchantId, 'BCR2DN4T2ABCDEFG');
    });

    /// Null is what "not configured" means: the native SDK adds `merchantId` to
    /// `merchantInfo` only when a non-blank id is present.
    test('an absent Google Pay merchant id crosses as null', () async {
      final host = FakeHost();
      PayCross.debugHostApi = (host);

      await PayCross.configure(environment: PayCrossEnvironment.sandbox);

      expect(host.lastConfiguration?.googlePayMerchantId, isNull);
    });

    /// Apple's key derivation hashes this string into every payment token's
    /// key, so losing it between Dart and the native SDK does not produce a
    /// missing-field error anywhere: the edge reads the payment as a web
    /// token, the vault derives the wrong key, and the shopper sees a generic
    /// decline.
    test('an Apple Pay merchant id reaches the platform', () async {
      final host = FakeHost();
      PayCross.debugHostApi = (host);

      await PayCross.configure(
        environment: PayCrossEnvironment.sandbox,
        applePayMerchantId: 'merchant.pay-cross.com',
      );

      expect(
        host.lastConfiguration?.applePayMerchantId,
        'merchant.pay-cross.com',
      );
    });

    /// Null is what "not configured" means, and the native SDK renders no
    /// button at all for it.
    test('an absent Apple Pay merchant id crosses as null', () async {
      final host = FakeHost();
      PayCross.debugHostApi = (host);

      await PayCross.configure(environment: PayCrossEnvironment.sandbox);

      expect(host.lastConfiguration?.applePayMerchantId, isNull);
    });

    /// Two wallets, two platforms, one call. Setting either must not disturb
    /// the other -- a merchant with Google Pay on Android and Apple Pay on iOS
    /// configures both in the same place, and the demo app is one.
    test('the two wallet ids are independent', () async {
      final host = FakeHost();
      PayCross.debugHostApi = (host);

      await PayCross.configure(
        environment: PayCrossEnvironment.sandbox,
        applePayMerchantId: 'merchant.pay-cross.com',
      );
      expect(host.lastConfiguration?.googlePayMerchantId, isNull);

      await PayCross.configure(
        environment: PayCrossEnvironment.sandbox,
        googlePayMerchantId: 'BCR2DN4T2ABCDEFG',
      );
      expect(host.lastConfiguration?.applePayMerchantId, isNull);
    });

    /// Unchanged, not normalised. The native SDK treats an empty identifier as
    /// unconfigured and refuses to build a token with one; a plugin that
    /// quietly turned '' into null would be a second opinion about the same
    /// question, in a layer that has no way to be right.
    test('an empty Apple Pay merchant id crosses unchanged', () async {
      final host = FakeHost();
      PayCross.debugHostApi = (host);

      await PayCross.configure(
        environment: PayCrossEnvironment.sandbox,
        applePayMerchantId: '',
      );

      expect(host.lastConfiguration?.applePayMerchantId, '');
    });

    /// The production guard is about test card prefill and nothing else. A
    /// production Apple Pay configuration is the normal case, not an error.
    test('a production Apple Pay configuration is allowed', () async {
      final host = FakeHost();
      PayCross.debugHostApi = (host);

      await PayCross.configure(
        environment: PayCrossEnvironment.production,
        applePayMerchantId: 'merchant.pay-cross.com',
      );

      expect(
        host.lastConfiguration?.applePayMerchantId,
        'merchant.pay-cross.com',
      );
      expect(host.lastConfiguration?.environment, g.PcEnvironment.production);
    });

    /// A PAN must not be reachable through a log line or a crash report.
    test('the prefill redacts itself', () {
      const prefill = PayCrossTestCardPrefill(
        pan: '4111111111111111',
        cvv: '123',
      );
      expect(prefill.toString(), isNot(contains('4111')));
      expect(prefill.toString(), isNot(contains('123')));
    });
  });
}
