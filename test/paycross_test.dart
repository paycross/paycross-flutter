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

    /// The token the merchant stores against their customer. It is the only
    /// place the vault reference reaches Dart -- the sheet that saved the card
    /// is the native SDK's, and nothing else in this API names it.
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

    /// The ordinary case. Saving is asked for at session creation, so most
    /// payments save nothing and the field must not invent a value.
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

    /// Dismissing the sheet does not cancel the authorization, so a shopper who
    /// walks away after a decline leaves a transaction the host has to be able
    /// to name.
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

    /// The outcome that can charge a shopper twice. It is its own result case
    /// rather than a decline, so an exhaustive switch cannot fall into the
    /// "declined, offer a retry" branch with it.
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

    /// Same reason recovery crosses as a string: a reason added to the wire
    /// vocabulary later must not be rewritten into one this version knows.
    test('an unknown pending reason is preserved as unrecognized', () async {
      PayCross.debugHostApi = (FakeHost(
        result: g.PcPending(transactionId: 'txn_1', reason: 'later_value'),
      ));

      final pending = await PayCross.presentPayment('token') as PayCrossPending;

      expect(pending.reason, PayCrossPendingReason.unrecognized);
      expect(pending.reasonRaw, 'later_value');
    });

    /// Defensive. Both native SDKs send this outcome as a pending result from
    /// 0.4.0 / 0.5.0, but a merchant can be running an older native SDK behind
    /// a newer plugin, and this is the one recovery where reading a decline
    /// instead of an unknown outcome ends in a double charge.
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

    /// reasonRaw is what arrived, not what the plugin decided it meant. The
    /// parse normalises; the record of the server's own spelling does not.
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

    /// A lost result is not an integration mistake: the payment may have been
    /// authorized. It returns as a value so the merchant's own switch has to
    /// decide what to do about it, instead of landing in a catch block that
    /// most integrations write once and forget.
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
    /// The wire vocabulary, agreed verbatim with both native SDKs. Renaming a
    /// value here is a wire break, not a rename, so it is pinned by a test
    /// rather than only by the enum's own spelling.
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

    /// Unlike recovery, an absent reason has no safe default to fall back on:
    /// there is no "the server said nothing" reading of an unknown outcome.
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
    /// Round-trips the token through the platform channel, which is what a
    /// merchant actually sees. `verify_before_retry` cannot be read this way
    /// any more — it maps to `PayCrossPending`, not to a failure — so that one
    /// token is parsed directly below.
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

    /// The parser still knows the token, and still refuses to call it
    /// retryable. What changed is where it lands: a result carrying it is a
    /// pending outcome now, so no merchant reaches this case through
    /// `presentPayment`. The rule is kept because the parser is public API.
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

    /// Every role, every shape, every button override and the scale, in one
    /// call: the wire is the whole contract, and a field that silently stops
    /// crossing is invisible until a merchant's sheet is the wrong colour.
    ///
    /// The colours are deliberately not all opaque. Alpha is the top byte of
    /// the packed value, so a packing that dropped or reordered it would still
    /// look right for every 0xFF colour anybody tests by hand.
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

    /// A role nobody set must arrive as a real null rather than as a zero:
    /// 0x00000000 is transparent black, a legal colour, and the natives read
    /// null as "keep the platform default".
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

    /// The whole migration path off the deprecated brandColorArgb: one colour,
    /// both modes, platform defaults for everything else.
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

    /// Pigeon has no field defaults, so a themeMode the merchant never named
    /// has to be written by the Dart wrapper. Without this the natives would
    /// receive whatever the generated code initialises, and "follow the
    /// device" would stop being the default the moment anyone set a colour.
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

    /// The deprecated parameter still works for a whole minor release. A
    /// merchant who has not migrated must not lose their brand colour to the
    /// deprecation.
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

    /// Both set is a migration half-done, and it has exactly one sensible
    /// reading: the newer, richer parameter wins. The old one is sent as null
    /// rather than alongside, so neither native has to hold a second opinion
    /// about which colour is the brand.
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

    /// Refused in Dart, before anything crosses. Both natives clamp too, for
    /// callers that reach them directly, but a clamp is a silent correction:
    /// a Flutter merchant who typed 3.0 wanted something the sheet will never
    /// do, and should be told rather than quietly given 1.3.
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

    /// The bounds themselves are legal. A test that only proved the refusal
    /// would pass just as well against a wrapper that refused everything.
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

    /// A negative radius is not a style, it is a mistake, and a native that
    /// took one would draw nothing or crash a layout pass deep inside the
    /// sheet where the message names none of this.
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

    /// Zero is a real value for all three: a zero radius is a square corner
    /// and a zero border width is no border. Only negatives are the mistake.
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
