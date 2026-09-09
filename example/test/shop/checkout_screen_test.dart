import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/history.dart';
import 'package:paycross_demo/demo/minter.dart';
import 'package:paycross_demo/demo/secrets.dart';
import 'package:paycross_demo/demo/settings.dart';
import 'package:paycross_demo/shop/catalogue.dart';
import 'package:paycross_demo/shop/checkout_screen.dart';
import 'package:paycross_demo/shop/shop_outcome.dart';
import 'package:paycross_demo/shop/shop_screen.dart';
import 'package:paycross_demo/shop/thank_you_screen.dart';
import 'package:paycross_flutter/paycross_flutter.dart';

import '../demo/_surface.dart';

final _tote = catalogue.first;

const MintedSession _minted = MintedSession(
  id: 'sess-1',
  token: 'a-live-token',
  sentBody: '{}',
);

PayCrossSuccess _approved() => const PayCrossSuccess(
  transactionId: 'txn-1',
  status: 'success',
  amount: PayCrossAmount(minorUnits: 2400, currencyCode: 'EUR'),
);

PayCrossFailure _refused() => const PayCrossFailure(
  transactionId: 'txn-2',
  recovery: RecoveryChangeMethod(),
);

PayCrossPending _pending() => const PayCrossPending(
  transactionId: 'txn-3',
  reason: PayCrossPendingReason.pollTimeout,
  reasonRaw: 'poll_timeout',
);

/// A secret store holding sandbox credentials, which is the ordinary state
/// of a phone somebody has already set the demo up on.
SecretStore _configured() {
  final backend = InMemorySecretBackend()
    ..entries['paycross_demo_client_id'] = 'client'
    ..entries['paycross_demo_client_secret'] = 'secret';
  return SecretStore(backend: backend);
}

Widget _app({
  SecretStore? store,
  Future<MintedSession> Function(Credentials, String)? mintWith,
  Future<PayCrossResult> Function(String)? present,
  HistoryStore? history,
  Product? product,
}) => MaterialApp(
  home: ShopCheckoutScreen(
    product: product ?? _tote,
    store: store ?? _configured(),
    mintWith: mintWith ?? (_, _) async => _minted,
    present: present ?? (_) async => _approved(),
    history: history ?? HistoryStore(backend: InMemoryHistoryBackend()),
    readVersions: () async =>
        (demo: '0.1.14+1', plugin: '0.7.2', nativeSdk: 'unknown'),
    now: () => DateTime.fromMillisecondsSinceEpoch(1757200000000),
  ),
);

void main() {
  group('the summary', () {
    testWidgets('names the item, its price and the total', (tester) async {
      await tester.pumpWidget(_app());

      expect(find.text('Canvas tote'), findsOneWidget);
      expect(find.text('Total'), findsOneWidget);
      expect(find.text('€24.00'), findsWidgets);
    });

    testWidgets('the Pay button says what it will charge', (tester) async {
      await tester.pumpWidget(_app());

      expect(find.text('Pay €24.00'), findsOneWidget);
    });

    testWidgets('Pay carries the semantics id an automated cell taps', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_app());

      expect(find.bySemanticsIdentifier('shop.pay'), findsOneWidget);

      handle.dispose();
    });
  });

  group('minting', () {
    testWidgets('sends the product price under an order reference', (
      tester,
    ) async {
      String? sent;
      await tester.pumpWidget(
        _app(
          mintWith: (_, body) async {
            sent = body;
            return _minted;
          },
        ),
      );

      await tester.tap(find.text('Pay €24.00'));
      await tester.pumpAndSettle();

      final body = jsonDecode(sent!) as Map<String, Object?>;
      expect(body['amount'], 2400);
      expect(body['currency'], 'EUR');
      expect(body['merchant_reference'], 'ORDER-1757200000000');
    });

    testWidgets('presents the minted session exactly once', (tester) async {
      var presented = 0;
      final held = Completer<PayCrossResult>();
      await tester.pumpWidget(
        _app(
          present: (_) {
            presented++;
            return held.future;
          },
        ),
      );

      await tester.tap(find.text('Pay €24.00'));
      await tester.pump();

      // Dead while the sheet is open, which is what stops a second tap
      // minting a second session and stacking a second sheet on the first.
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.tap(find.text('Pay €24.00'), warnIfMissed: false);
      await tester.pump();
      expect(presented, 1);

      held.complete(_approved());
      await tester.pumpAndSettle();
    });

    testWidgets('a mint that fails says so and leaves Pay usable', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          mintWith: (_, _) async => throw const MinterError('The shop is shut'),
        ),
      );

      await tester.tap(find.text('Pay €24.00'));
      await tester.pumpAndSettle();

      expect(find.text('The shop is shut'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
    });
  });

  group('what the sheet came back with', () {
    testWidgets('an approval opens the thank-you page for this order', (
      tester,
    ) async {
      await tester.pumpWidget(_app());

      await tester.tap(find.text('Pay €24.00'));
      await tester.pumpAndSettle();

      final page = tester.widget<ThankYouScreen>(find.byType(ThankYouScreen));
      expect(page.reference, 'ORDER-1757200000000');
      expect(page.amount, 2400);
    });

    testWidgets('a cancellation comes back to checkout with Pay re-enabled', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(present: (_) async => const PayCrossCancelled()),
      );

      await tester.tap(find.text('Pay €24.00'));
      await tester.pumpAndSettle();

      expect(find.byType(ThankYouScreen), findsNothing);
      expect(find.text('Payment cancelled.'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
    });

    testWidgets('a refusal speaks to the shopper, not to an engineer', (
      tester,
    ) async {
      await tester.pumpWidget(_app(present: (_) async => _refused()));

      await tester.tap(find.text('Pay €24.00'));
      await tester.pumpAndSettle();

      expect(find.byType(ThankYouScreen), findsNothing);
      expect(find.text(shopDeclinedMessage), findsOneWidget);
      expect(find.textContaining('change_method'), findsNothing);
      expect(find.textContaining('txn-2'), findsNothing);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
    });

    testWidgets('an unresolved payment tells the shopper not to pay again', (
      tester,
    ) async {
      await tester.pumpWidget(_app(present: (_) async => _pending()));

      await tester.tap(find.text('Pay €24.00'));
      await tester.pumpAndSettle();

      expect(find.byType(ThankYouScreen), findsNothing);
      expect(find.text(shopUnresolvedMessage), findsOneWidget);
      expect(find.textContaining('poll_timeout'), findsNothing);
    });

    testWidgets('Pay stays dead after an unresolved payment', (tester) async {
      await tester.pumpWidget(_app(present: (_) async => _pending()));

      await tester.tap(find.text('Pay €24.00'));
      await tester.pumpAndSettle();

      // Nobody knows whether that payment took the money, so a second one
      // can charge the same card twice for the same basket.
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
    });

    testWidgets('a sheet that throws does not leave the screen waiting', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(present: (_) async => throw StateError('no plugin')),
      );

      await tester.tap(find.text('Pay €24.00'));
      await tester.pumpAndSettle();

      expect(find.text(shopWentWrongMessage), findsOneWidget);
      expect(find.textContaining('StateError'), findsNothing);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
    });

    testWidgets('a paid order cannot be paid again by pressing back', (
      tester,
    ) async {
      // The real stack, not a checkout mounted on its own: what the success
      // path removes is everything above the shop, so a test that starts at
      // the checkout would be asserting about a stack the app never has.
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(navigator.push(shopRoute()));
      await tester.pumpAndSettle();
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => ShopCheckoutScreen(
              product: _tote,
              store: _configured(),
              mintWith: (_, _) async => _minted,
              present: (_) async => _approved(),
              history: HistoryStore(backend: InMemoryHistoryBackend()),
              readVersions: () async =>
                  (demo: '0.1.14+1', plugin: '0.7.2', nativeSdk: 'unknown'),
              now: () => DateTime.fromMillisecondsSinceEpoch(1757200000000),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Pay €24.00'));
      await tester.pumpAndSettle();
      expect(find.byType(ThankYouScreen), findsOneWidget);

      navigator.pop();
      await tester.pumpAndSettle();

      // The checkout went with the push. Back from a paid order lands on the
      // shop, and there is no live Pay button anywhere behind it.
      expect(find.byType(ShopCheckoutScreen), findsNothing);
      expect(find.byType(ShopScreen), findsOneWidget);
    });

    testWidgets('Continue shopping lands on the shop too', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(navigator.push(shopRoute()));
      await tester.pumpAndSettle();
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => ShopCheckoutScreen(
              product: _tote,
              store: _configured(),
              mintWith: (_, _) async => _minted,
              present: (_) async => _approved(),
              history: HistoryStore(backend: InMemoryHistoryBackend()),
              readVersions: () async =>
                  (demo: '0.1.14+1', plugin: '0.7.2', nativeSdk: 'unknown'),
              now: () => DateTime.fromMillisecondsSinceEpoch(1757200000000),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Pay €24.00'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue shopping'));
      await tester.pumpAndSettle();

      expect(find.byType(ShopScreen), findsOneWidget);
      expect(find.byType(ThankYouScreen), findsNothing);
      expect(find.byType(ShopCheckoutScreen), findsNothing);
    });
  });

  group('history', () {
    testWidgets('records the run under the product slug on the sheet', (
      tester,
    ) async {
      final backend = InMemoryHistoryBackend();
      await tester.pumpWidget(_app(history: HistoryStore(backend: backend)));

      await tester.tap(find.text('Pay €24.00'));
      await tester.pumpAndSettle();

      final rows = await HistoryStore(backend: backend).read();
      expect(rows, hasLength(1));
      expect(rows.single.presetName, 'shop:canvas-tote');
      expect(rows.single.sessionId, 'sess-1');
      expect(rows.single.transactionId, 'txn-1');
      expect(rows.single.surface, 'sdk');
      expect(rows.single.live, isFalse);
    });

    testWidgets('keeps the detail the shop screen does not show', (
      tester,
    ) async {
      final backend = InMemoryHistoryBackend();
      await tester.pumpWidget(
        _app(
          history: HistoryStore(backend: backend),
          present: (_) async => _refused(),
        ),
      );

      await tester.tap(find.text('Pay €24.00'));
      await tester.pumpAndSettle();

      // The shopper reads a sentence; whoever reports the run still gets the
      // recovery token and the transaction id.
      final rows = await HistoryStore(backend: backend).read();
      expect(rows.single.outcome, contains('change_method'));
      expect(rows.single.outcome, contains('txn-2'));
    });

    testWidgets('a cancelled order is recorded too', (tester) async {
      final backend = InMemoryHistoryBackend();
      await tester.pumpWidget(
        _app(
          history: HistoryStore(backend: backend),
          present: (_) async => const PayCrossCancelled(),
        ),
      );

      await tester.tap(find.text('Pay €24.00'));
      await tester.pumpAndSettle();

      final rows = await HistoryStore(backend: backend).read();
      expect(rows.single.outcome, 'Payment cancelled.');
    });
  });

  group('a phone nobody has configured', () {
    testWidgets('Pay sends the colleague to Settings rather than minting', (
      tester,
    ) async {
      useTallSurface(tester);
      var minted = false;
      await tester.pumpWidget(
        _app(
          store: SecretStore(backend: InMemorySecretBackend()),
          mintWith: (_, _) async {
            minted = true;
            return _minted;
          },
        ),
      );

      await tester.tap(find.text('Pay €24.00'));
      await tester.pumpAndSettle();

      expect(minted, isFalse);
      expect(find.byType(SettingsScreen), findsOneWidget);
    });
  });

  group('what a reviewer must not see', () {
    /// Every state the checkout can be left in, because the note is where
    /// the harness words would actually appear and the initial render never
    /// has one.
    for (final state in <(String, Future<PayCrossResult> Function(String))>[
      ('a refusal', (_) async => _refused()),
      ('an unresolved payment', (_) async => _pending()),
      ('a cancellation', (_) async => const PayCrossCancelled()),
      ('a sheet that threw', (_) async => throw StateError('no plugin')),
    ]) {
      testWidgets('no harness vocabulary survives ${state.$1}', (tester) async {
        await tester.pumpWidget(_app(present: state.$2));

        await tester.tap(find.text('Pay €24.00'));
        await tester.pumpAndSettle();

        for (final word in const <String>[
          'sandbox',
          'Test card',
          'scenario',
          'preset',
          'session',
          'token',
          'recovery',
          'transaction',
          'reconcile',
          'Refused',
          'Unresolved',
          'txn-',
        ]) {
          expect(find.textContaining(word), findsNothing, reason: word);
        }
      });
    }

    testWidgets('the checkout carries no harness vocabulary before a tap', (
      tester,
    ) async {
      await tester.pumpWidget(_app());

      for (final word in const <String>[
        'sandbox',
        'Test card',
        'scenario',
        'preset',
        'session',
        'token',
      ]) {
        expect(find.textContaining(word), findsNothing, reason: word);
      }
    });

    testWidgets('the checkout fits a phone', (tester) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('the summary fits a phone at every text size', (tester) async {
      for (final width in const <double>[360, 390]) {
        for (final scale in const <double>[1.0, 1.8]) {
          tester.view.physicalSize = Size(width, 844);
          tester.view.devicePixelRatio = 1.0;
          await tester.pumpWidget(
            MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: _app(),
            ),
          );
          await tester.pumpAndSettle();

          expect(
            tester.takeException(),
            isNull,
            reason: 'width $width at ${scale}x',
          );
        }
      }
      addTearDown(tester.view.reset);
    });
  });
}
