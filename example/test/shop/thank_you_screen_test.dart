import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/shop/shop_screen.dart';
import 'package:paycross_demo/shop/thank_you_screen.dart';

Widget _app() => const MaterialApp(
  home: ThankYouScreen(
    reference: 'ORDER-1757200000000',
    item: 'Canvas tote',
    amount: 2400,
  ),
);

void main() {
  testWidgets('the page thanks the shopper and names the order', (
    tester,
  ) async {
    await tester.pumpWidget(_app());

    expect(find.textContaining('Thank you'), findsOneWidget);
    expect(find.text('ORDER-1757200000000'), findsOneWidget);
  });

  testWidgets('the receipt names what was bought', (tester) async {
    await tester.pumpWidget(_app());

    expect(find.text('Canvas tote'), findsOneWidget);
  });

  testWidgets('the amount is written the way the shop wrote the price', (
    tester,
  ) async {
    await tester.pumpWidget(_app());

    expect(find.text('€24.00'), findsOneWidget);
  });

  testWidgets('Continue shopping carries its semantics id', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_app());

    expect(find.bySemanticsIdentifier('shop.continue'), findsOneWidget);

    handle.dispose();
  });

  testWidgets('Continue shopping goes back to the shop, not to the demo', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(shopRoute()),
            child: const Text('open the shop'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open the shop'));
    await tester.pumpAndSettle();

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const ThankYouScreen(
            reference: 'ORDER-9',
            item: 'Notebook set',
            amount: 990,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Continue shopping'));
    await tester.pumpAndSettle();

    expect(find.byType(ShopScreen), findsOneWidget);
    expect(find.byType(ThankYouScreen), findsNothing);
  });

  testWidgets('Continue shopping does not empty a stack with no shop in it', (
    tester,
  ) async {
    await tester.pumpWidget(_app());

    await tester.tap(find.text('Continue shopping'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(ThankYouScreen), findsOneWidget);
  });

  testWidgets('the order number fits a phone, at every text size', (
    tester,
  ) async {
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
}
