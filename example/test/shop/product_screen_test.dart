import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/shop/catalogue.dart';
import 'package:paycross_demo/shop/checkout_screen.dart';
import 'package:paycross_demo/shop/product_screen.dart';

import '../demo/_surface.dart';

final _mug = catalogue.firstWhere((product) => product.slug == 'ceramic-mug');

Widget _app([Product? product]) =>
    MaterialApp(home: ProductScreen(product: product ?? _mug));

void main() {
  testWidgets('the page shows the product, its blurb and its price', (
    tester,
  ) async {
    await tester.pumpWidget(_app());

    expect(find.text('Ceramic mug'), findsWidgets);
    expect(find.text(_mug.blurb), findsOneWidget);
    expect(find.text('€12.50'), findsOneWidget);
    expect(find.text(_mug.illustration), findsOneWidget);
  });

  testWidgets('Buy now carries the semantics id an automated cell taps', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_app());

    expect(find.bySemanticsIdentifier('shop.buy'), findsOneWidget);

    handle.dispose();
  });

  testWidgets('Buy now says what it costs', (tester) async {
    await tester.pumpWidget(_app());

    expect(find.widgetWithText(FilledButton, 'Buy now'), findsOneWidget);
  });

  testWidgets('Buy now opens the checkout for this product', (tester) async {
    await tester.pumpWidget(_app());

    await tester.tap(find.text('Buy now'));
    await tester.pumpAndSettle();

    final checkout = tester.widget<ShopCheckoutScreen>(
      find.byType(ShopCheckoutScreen),
    );
    expect(checkout.product.slug, 'ceramic-mug');
  });

  testWidgets('the page fits a phone', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(_app(catalogue.first));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
