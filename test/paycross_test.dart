import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_flutter/paycross_flutter.dart';
import 'package:paycross_flutter/src/generated/paycross_api.g.dart' as g;

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
      g.PcVersionInfo(pluginVersion: '0.2.1', nativeSdkVersion: null);

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

    test('success carries the token of a card this payment saved', () async {
      PayCross.debugHostApi = (FakeHost(
        result: g.PcSuccess(
          transactionId: 'txn_2',
          status: 'success',
          amount: _amount(),
          savedCardToken: 'tok_1',
        ),
      ));

      final result = await PayCross.presentPayment('token') as PayCrossSuccess;

      expect(result.savedCardToken, 'tok_1');
    });

    test('success saves no card when the session did not ask', () async {
      PayCross.debugHostApi = (FakeHost(
        result: g.PcSuccess(
          transactionId: 'txn_3',
          status: 'success',
          amount: _amount(),
        ),
      ));

      final result = await PayCross.presentPayment('token') as PayCrossSuccess;

      expect(result.savedCardToken, isNull);
    });

    test('cancellation maps to PayCrossCancelled', () async {
      PayCross.debugHostApi = (FakeHost(result: g.PcCancelled()));
      expect(await PayCross.presentPayment('token'), isA<PayCrossCancelled>());
    });

    test('a cancellation carries the attempt it walked away from', () async {
      PayCross.debugHostApi = (FakeHost(
        result: g.PcCancelled(transactionId: 'txn_9'),
      ));

      final result =
          await PayCross.presentPayment('token') as PayCrossCancelled;

      expect(result.transactionId, 'txn_9');
    });

    test('a cancellation before any transaction carries none', () async {
      PayCross.debugHostApi = (FakeHost(result: g.PcCancelled()));

      final result =
          await PayCross.presentPayment('token') as PayCrossCancelled;

      expect(result.transactionId, isNull);
    });

    test('a pending outcome maps to PayCrossPending with its reason', () async {
      PayCross.debugHostApi = (FakeHost(
        result: g.PcPending(transactionId: 'txn_1', reason: 'poll_timeout'),
      ));

      final result = await PayCross.presentPayment('token');

      expect(result, isA<PayCrossPending>());
      final pending = result as PayCrossPending;
      expect(pending.reason, PayCrossPendingReason.pollTimeout);
      expect(pending.transactionId, 'txn_1');
    });

    test('an unknown pending reason is preserved as unrecognized', () async {
      PayCross.debugHostApi = (FakeHost(
        result: g.PcPending(transactionId: 'txn_1', reason: 'later_value'),
      ));

      final pending = await PayCross.presentPayment('token') as PayCrossPending;

      expect(pending.reason, PayCrossPendingReason.unrecognized);
      expect(pending.reasonRaw, 'later_value');
    });

    test('a failure whose raw recovery is verify_before_retry is pending, not '
        'a decline', () async {
      PayCross.debugHostApi = (FakeHost(
        result: g.PcFailure(
          transactionId: 'txn_2',
          recovery: 'verify_before_retry',
        ),
      ));

      final result = await PayCross.presentPayment('token');

      expect(result, isA<PayCrossPending>());
      final pending = result as PayCrossPending;
      expect(pending.reason, PayCrossPendingReason.serverVerify);
      expect(pending.transactionId, 'txn_2');
      expect(pending.reasonRaw, 'verify_before_retry');
    });

    test(
      'a pending outcome mapped from a failure keeps the server spelling',
      () async {
        PayCross.debugHostApi = (FakeHost(
          result: g.PcFailure(
            transactionId: 'txn_2',
            recovery: '  VERIFY_BEFORE_RETRY ',
          ),
        ));

        final pending =
            await PayCross.presentPayment('token') as PayCrossPending;

        expect(pending.reason, PayCrossPendingReason.serverVerify);
        expect(pending.reasonRaw, '  VERIFY_BEFORE_RETRY ');
      },
    );

    test('a lost result is a pending outcome, not an exception', () async {
      PayCross.debugHostApi = (FakeHost(
        error: PlatformException(
          code: 'paycross_result_unknown',
          message: 'engine detached',
        ),
      ));

      final result = await PayCross.presentPayment('token');

      expect(result, isA<PayCrossPending>());
      final pending = result as PayCrossPending;
      expect(pending.reason, PayCrossPendingReason.resultLost);
      expect(pending.reasonRaw, 'result_lost');
      expect(pending.transactionId, isNull);
    });
  });

  group('pending reason parsing', () {
    test('the three wire names map to their cases', () {
      expect(
        PayCrossPendingReason.fromWireName('poll_timeout'),
        PayCrossPendingReason.pollTimeout,
      );
      expect(
        PayCrossPendingReason.fromWireName('result_lost'),
        PayCrossPendingReason.resultLost,
      );
      expect(
        PayCrossPendingReason.fromWireName('server_verify'),
        PayCrossPendingReason.serverVerify,
      );
    });

    test('names are trimmed and lowercased, matching recovery parsing', () {
      expect(
        PayCrossPendingReason.fromWireName('  POLL_TIMEOUT '),
        PayCrossPendingReason.pollTimeout,
      );
    });

    test('anything else is unrecognized', () {
      expect(
        PayCrossPendingReason.fromWireName('later_value'),
        PayCrossPendingReason.unrecognized,
      );
      expect(
        PayCrossPendingReason.fromWireName(''),
        PayCrossPendingReason.unrecognized,
      );
      expect(
        PayCrossPendingReason.fromWireName(null),
        PayCrossPendingReason.unrecognized,
      );
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
      expect(
        PayCrossRecovery.fromApiValue('verify_before_retry'),
        isA<RecoveryVerifyBeforeRetry>(),
      );
    });

    test('verify_before_retry is known, and is not retryable', () {
      final recovery = PayCrossRecovery.fromApiValue('verify_before_retry');

      expect(recovery, isA<RecoveryVerifyBeforeRetry>());
      expect(recovery, isNot(isA<RecoveryUnrecognized>()));
      expect(recovery.isRetryable, isFalse);
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
      expect(
        PayCrossRecovery.fromApiValue('verify_before_retry').isRetryable,
        isFalse,
      );
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

    test('a Google Pay merchant id reaches the platform', () async {
      final host = FakeHost();
      PayCross.debugHostApi = (host);

      await PayCross.configure(
        environment: PayCrossEnvironment.production,
        googlePayMerchantId: 'BCR2DN4T2ABCDEFG',
      );

      expect(host.lastConfiguration?.googlePayMerchantId, 'BCR2DN4T2ABCDEFG');
    });

    test('an absent Google Pay merchant id crosses as null', () async {
      final host = FakeHost();
      PayCross.debugHostApi = (host);

      await PayCross.configure(environment: PayCrossEnvironment.sandbox);

      expect(host.lastConfiguration?.googlePayMerchantId, isNull);
    });

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

    test('an absent Apple Pay merchant id crosses as null', () async {
      final host = FakeHost();
      PayCross.debugHostApi = (host);

      await PayCross.configure(environment: PayCrossEnvironment.sandbox);

      expect(host.lastConfiguration?.applePayMerchantId, isNull);
    });

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

    test('an empty Apple Pay merchant id crosses unchanged', () async {
      final host = FakeHost();
      PayCross.debugHostApi = (host);

      await PayCross.configure(
        environment: PayCrossEnvironment.sandbox,
        applePayMerchantId: '',
      );

      expect(host.lastConfiguration?.applePayMerchantId, '');
    });

    test('a locale reaches the platform', () async {
      final host = FakeHost();
      PayCross.debugHostApi = (host);

      await PayCross.configure(
        environment: PayCrossEnvironment.sandbox,
        locale: 'fr',
      );

      expect(host.lastConfiguration?.locale, 'fr');
    });

    test('an absent locale crosses as null', () async {
      final host = FakeHost();
      PayCross.debugHostApi = (host);

      await PayCross.configure(environment: PayCrossEnvironment.sandbox);

      expect(host.lastConfiguration?.locale, isNull);
    });

    test('a malformed tag crosses unchanged', () async {
      final host = FakeHost();
      PayCross.debugHostApi = (host);

      for (final tag in ['francais', 'fr-', 'f-r', '']) {
        await PayCross.configure(
          environment: PayCrossEnvironment.sandbox,
          locale: tag,
        );
        expect(host.lastConfiguration?.locale, tag);
      }
    });

    test('a locale is not normalised on the way across', () async {
      final host = FakeHost();
      PayCross.debugHostApi = (host);

      await PayCross.configure(
        environment: PayCrossEnvironment.sandbox,
        locale: 'FR_ca',
      );

      expect(host.lastConfiguration?.locale, 'FR_ca');
    });

    test('a locale and an appearance are independent', () async {
      final host = FakeHost();
      PayCross.debugHostApi = (host);

      await PayCross.configure(
        environment: PayCrossEnvironment.sandbox,
        appearance: PayCrossAppearance.brand(const Color(0xFF6750A4)),
      );
      expect(host.lastConfiguration?.locale, isNull);
      expect(host.lastConfiguration?.appearance, isNotNull);

      await PayCross.configure(
        environment: PayCrossEnvironment.sandbox,
        locale: 'fr',
      );
      expect(host.lastConfiguration?.appearance, isNull);
      expect(host.lastConfiguration?.locale, 'fr');
    });

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

    test('the prefill redacts itself', () {
      const prefill = PayCrossTestCardPrefill(
        pan: '4111111111111111',
        cvv: '123',
      );
      expect(prefill.toString(), isNot(contains('4111')));
      expect(prefill.toString(), isNot(contains('123')));
    });

    test('every appearance field crosses', () async {
      final host = FakeHost();
      PayCross.debugHostApi = (host);

      await PayCross.configure(
        environment: PayCrossEnvironment.sandbox,
        appearance: const PayCrossAppearance(
          light: PayCrossColors(
            brand: Color(0xFF1E88E5),
            onBrand: Color(0xFFFFFFFF),
            surface: Color(0xFFF7F7F7),
            component: Color(0x80FFFFFF),
            componentBorder: Color(0xFFD0D0D0),
            text: Color(0xFF111111),
            textSecondary: Color(0xFF666666),
            placeholder: Color(0xFF999999),
            icon: Color(0xFF444444),
            error: Color(0xFFB3261E),
          ),
          dark: PayCrossColors(
            brand: Color(0xFF64B5F6),
            onBrand: Color(0xFF000000),
            surface: Color(0xFF121212),
            component: Color(0xFF1E1E1E),
            componentBorder: Color(0xFF3A3A3A),
            text: Color(0xFFEEEEEE),
            textSecondary: Color(0xFFAAAAAA),
            placeholder: Color(0xFF777777),
            icon: Color(0xFFCCCCCC),
            error: Color(0xFFF2B8B5),
          ),
          themeMode: PayCrossThemeMode.dark,
          shapes: PayCrossShapes(
            cornerRadius: 16,
            buttonCornerRadius: 28,
            borderWidth: 2,
          ),
          primaryButton: PayCrossPrimaryButton(
            background: Color(0xFF1E88E5),
            textColor: Color(0xFFFFFFFF),
            disabledBackground: Color(0x611E88E5),
            disabledTextColor: Color(0x61FFFFFF),
            cornerRadius: 24,
            height: 56,
          ),
          typography: PayCrossTypography(sizeScaleFactor: 1.1),
        ),
      );

      final crossed = host.lastConfiguration?.appearance;
      expect(crossed, isNotNull);

      final light = crossed!.light!;
      expect(light.brand, 0xFF1E88E5);
      expect(light.onBrand, 0xFFFFFFFF);
      expect(light.surface, 0xFFF7F7F7);
      expect(light.component, 0x80FFFFFF);
      expect(light.componentBorder, 0xFFD0D0D0);
      expect(light.text, 0xFF111111);
      expect(light.textSecondary, 0xFF666666);
      expect(light.placeholder, 0xFF999999);
      expect(light.icon, 0xFF444444);
      expect(light.error, 0xFFB3261E);

      final dark = crossed.dark!;
      expect(dark.brand, 0xFF64B5F6);
      expect(dark.onBrand, 0xFF000000);
      expect(dark.surface, 0xFF121212);
      expect(dark.component, 0xFF1E1E1E);
      expect(dark.componentBorder, 0xFF3A3A3A);
      expect(dark.text, 0xFFEEEEEE);
      expect(dark.textSecondary, 0xFFAAAAAA);
      expect(dark.placeholder, 0xFF777777);
      expect(dark.icon, 0xFFCCCCCC);
      expect(dark.error, 0xFFF2B8B5);

      expect(crossed.themeMode, g.PcThemeMode.dark);
      expect(crossed.shapes?.cornerRadius, 16);
      expect(crossed.shapes?.buttonCornerRadius, 28);
      expect(crossed.shapes?.borderWidth, 2);
      expect(crossed.primaryButton?.background, 0xFF1E88E5);
      expect(crossed.primaryButton?.textColor, 0xFFFFFFFF);
      expect(crossed.primaryButton?.disabledBackground, 0x611E88E5);
      expect(crossed.primaryButton?.disabledTextColor, 0x61FFFFFF);
      expect(crossed.primaryButton?.cornerRadius, 24);
      expect(crossed.primaryButton?.height, 56);
      expect(crossed.typography?.sizeScaleFactor, 1.1);
    });

    test('unset roles cross as null, not as zero', () async {
      final host = FakeHost();
      PayCross.debugHostApi = (host);

      await PayCross.configure(
        environment: PayCrossEnvironment.sandbox,
        appearance: const PayCrossAppearance(
          light: PayCrossColors(brand: Color(0xFF1E88E5)),
        ),
      );

      final crossed = host.lastConfiguration!.appearance!;
      expect(crossed.light?.brand, 0xFF1E88E5);
      expect(crossed.light?.surface, isNull);
      expect(crossed.light?.onBrand, isNull);
      expect(crossed.dark, isNull);
      expect(crossed.shapes, isNull);
      expect(crossed.primaryButton, isNull);
      expect(crossed.typography, isNull);
    });

    test('the brand factory fills both palettes', () async {
      final host = FakeHost();
      PayCross.debugHostApi = (host);

      await PayCross.configure(
        environment: PayCrossEnvironment.sandbox,
        appearance: PayCrossAppearance.brand(const Color(0xFF6750A4)),
      );

      final crossed = host.lastConfiguration!.appearance!;
      expect(crossed.light?.brand, 0xFF6750A4);
      expect(crossed.dark?.brand, 0xFF6750A4);
      expect(crossed.light?.surface, isNull);
      expect(crossed.dark?.surface, isNull);
    });

    test('themeMode defaults to system on the wire', () async {
      final host = FakeHost();
      PayCross.debugHostApi = (host);

      await PayCross.configure(
        environment: PayCrossEnvironment.sandbox,
        appearance: PayCrossAppearance.brand(const Color(0xFF6750A4)),
      );

      expect(
        host.lastConfiguration?.appearance?.themeMode,
        g.PcThemeMode.system,
      );
    });

    test('brandColorArgb alone still crosses', () async {
      final host = FakeHost();
      PayCross.debugHostApi = (host);

      await PayCross.configure(
        environment: PayCrossEnvironment.sandbox,
        brandColorArgb: 0xFF6750A4,
      );

      expect(host.lastConfiguration?.brandColorArgb, 0xFF6750A4);
      expect(host.lastConfiguration?.appearance, isNull);
    });

    test(
      'appearance wins over brandColorArgb, which crosses as null',
      () async {
        final host = FakeHost();
        PayCross.debugHostApi = (host);

        await PayCross.configure(
          environment: PayCrossEnvironment.sandbox,
          brandColorArgb: 0xFFFF0000,
          appearance: PayCrossAppearance.brand(const Color(0xFF6750A4)),
        );

        expect(host.lastConfiguration?.brandColorArgb, isNull);
        expect(host.lastConfiguration?.appearance?.light?.brand, 0xFF6750A4);
      },
    );

    test(
      'a brandColorArgb merges into an appearance that names no brand',
      () async {
        final host = FakeHost();
        PayCross.debugHostApi = (host);

        await PayCross.configure(
          environment: PayCrossEnvironment.sandbox,
          // ignore: deprecated_member_use_from_same_package
          brandColorArgb: 0xFF6750A4,
          appearance: const PayCrossAppearance(
            shapes: PayCrossShapes(cornerRadius: 16),
          ),
        );

        final crossed = host.lastConfiguration!.appearance!;
        expect(crossed.light?.brand, 0xFF6750A4);
        expect(crossed.dark?.brand, 0xFF6750A4);
        expect(host.lastConfiguration?.brandColorArgb, isNull);
        expect(crossed.shapes?.cornerRadius, 16);
      },
    );

    test('a palette that names a brand is left alone', () async {
      final host = FakeHost();
      PayCross.debugHostApi = (host);

      await PayCross.configure(
        environment: PayCrossEnvironment.sandbox,
        // ignore: deprecated_member_use_from_same_package
        brandColorArgb: 0xFFFF0000,
        appearance: const PayCrossAppearance(
          light: PayCrossColors(brand: Color(0xFF6750A4)),
        ),
      );

      final crossed = host.lastConfiguration!.appearance!;
      expect(crossed.light?.brand, 0xFF6750A4);
      expect(crossed.dark, isNull);
      expect(host.lastConfiguration?.brandColorArgb, isNull);
    });

    test('the merge fills brand only', () async {
      final host = FakeHost();
      PayCross.debugHostApi = (host);

      await PayCross.configure(
        environment: PayCrossEnvironment.sandbox,
        // ignore: deprecated_member_use_from_same_package
        brandColorArgb: 0xFF6750A4,
        appearance: const PayCrossAppearance(
          light: PayCrossColors(surface: Color(0xFFFAFAFA)),
        ),
      );

      final light = host.lastConfiguration!.appearance!.light!;
      expect(light.brand, 0xFF6750A4);
      expect(light.surface, 0xFFFAFAFA);
      expect(light.onBrand, isNull);
      expect(light.text, isNull);
    });

    test('copyWith replaces only what it is given', () {
      const original = PayCrossColors(
        brand: Color(0xFF6750A4),
        surface: Color(0xFFFAFAFA),
      );

      final copy = original.copyWith(surface: const Color(0xFF121212));

      expect(copy.brand, const Color(0xFF6750A4));
      expect(copy.surface, const Color(0xFF121212));

      const appearance = PayCrossAppearance(
        themeMode: PayCrossThemeMode.dark,
        shapes: PayCrossShapes(cornerRadius: 16),
      );
      final wider = appearance.copyWith(light: original);
      expect(wider.light, original);
      expect(wider.themeMode, PayCrossThemeMode.dark);
      expect(wider.shapes?.cornerRadius, 16);
    });

    test('hasBrand is true when either palette names one', () {
      expect(const PayCrossAppearance().hasBrand, isFalse);
      expect(
        const PayCrossAppearance(
          shapes: PayCrossShapes(cornerRadius: 16),
        ).hasBrand,
        isFalse,
      );
      expect(
        const PayCrossAppearance(
          light: PayCrossColors(surface: Color(0xFFFAFAFA)),
        ).hasBrand,
        isFalse,
      );
      expect(
        const PayCrossAppearance(
          light: PayCrossColors(brand: Color(0xFF6750A4)),
        ).hasBrand,
        isTrue,
      );
      expect(
        const PayCrossAppearance(
          dark: PayCrossColors(brand: Color(0xFF6750A4)),
        ).hasBrand,
        isTrue,
      );
    });

    test('a size scale outside 0.8-1.3 is refused before it crosses', () async {
      final host = FakeHost();
      PayCross.debugHostApi = (host);

      for (final bad in <double>[
        0.79,
        1.31,
        0,
        -1,
        double.nan,
        double.infinity,
      ]) {
        await expectLater(
          PayCross.configure(
            environment: PayCrossEnvironment.sandbox,
            appearance: PayCrossAppearance(
              typography: PayCrossTypography(sizeScaleFactor: bad),
            ),
          ),
          throwsA(
            isA<PayCrossIntegrationError>().having(
              (e) => e.code,
              'code',
              PayCrossErrorCode.invalidAppearance,
            ),
          ),
          reason: 'sizeScaleFactor $bad should be refused',
        );
      }

      expect(host.lastConfiguration, isNull);
    });

    test('the size scale bounds are accepted', () async {
      final host = FakeHost();
      PayCross.debugHostApi = (host);

      for (final good in <double>[0.8, 1, 1.3]) {
        await PayCross.configure(
          environment: PayCrossEnvironment.sandbox,
          appearance: PayCrossAppearance(
            typography: PayCrossTypography(sizeScaleFactor: good),
          ),
        );
        expect(
          host.lastConfiguration?.appearance?.typography?.sizeScaleFactor,
          good,
        );
      }
    });

    test(
      'a negative or non-finite length is refused before it crosses',
      () async {
        final host = FakeHost();
        PayCross.debugHostApi = (host);

        final bad = <PayCrossAppearance>[
          const PayCrossAppearance(shapes: PayCrossShapes(cornerRadius: -1)),
          const PayCrossAppearance(
            shapes: PayCrossShapes(buttonCornerRadius: -0.5),
          ),
          const PayCrossAppearance(shapes: PayCrossShapes(borderWidth: -2)),
          PayCrossAppearance(
            shapes: const PayCrossShapes(cornerRadius: double.nan),
          ),
          const PayCrossAppearance(
            primaryButton: PayCrossPrimaryButton(cornerRadius: -1),
          ),
          const PayCrossAppearance(
            primaryButton: PayCrossPrimaryButton(height: -1),
          ),
          PayCrossAppearance(
            primaryButton: const PayCrossPrimaryButton(height: double.infinity),
          ),
        ];

        for (final appearance in bad) {
          await expectLater(
            PayCross.configure(
              environment: PayCrossEnvironment.sandbox,
              appearance: appearance,
            ),
            throwsA(
              isA<PayCrossIntegrationError>().having(
                (e) => e.code,
                'code',
                PayCrossErrorCode.invalidAppearance,
              ),
            ),
          );
        }

        expect(host.lastConfiguration, isNull);
      },
    );

    test('zero lengths are accepted', () async {
      final host = FakeHost();
      PayCross.debugHostApi = (host);

      await PayCross.configure(
        environment: PayCrossEnvironment.sandbox,
        appearance: const PayCrossAppearance(
          shapes: PayCrossShapes(
            cornerRadius: 0,
            buttonCornerRadius: 0,
            borderWidth: 0,
          ),
        ),
      );

      expect(host.lastConfiguration?.appearance?.shapes?.cornerRadius, 0);
      expect(host.lastConfiguration?.appearance?.shapes?.borderWidth, 0);
    });
  });
}
