import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/shop/catalogue.dart';
import 'package:paycross_demo/shop/product_screen.dart';
import 'package:paycross_demo/shop/shop_screen.dart';

import '../demo/_surface.dart';

Widget _app() => const MaterialApp(home: ShopScreen());

void main() {
  testWidgets('the shop is named on the bar', (tester) async {
    await tester.pumpWidget(_app());

    expect(find.text(shopName), findsOneWidget);
  });

  testWidgets('every product is listed with its name and its blurb', (
    tester,
  ) async {
    useTallSurface(tester);
    await tester.pumpWidget(_app());

    for (final product in catalogue) {
      expect(find.text(product.name), findsOneWidget, reason: product.slug);
      expect(find.text(product.blurb), findsOneWidget, reason: product.slug);
    }
  });

  testWidgets('prices are written the way the rest of the app writes money', (
    tester,
  ) async {
    useTallSurface(tester);
    await tester.pumpWidget(_app());

    expect(find.text('€24.00'), findsOneWidget);
    expect(find.text('€12.50'), findsOneWidget);
    expect(find.text('€9.90'), findsOneWidget);
  });

  testWidgets('every product carries its own semantics id', (tester) async {
    final handle = tester.ensureSemantics();
    useTallSurface(tester);
    await tester.pumpWidget(_app());

    for (final product in catalogue) {
      expect(
        find.bySemanticsIdentifier(product.semanticsId),
        findsOneWidget,
        reason: product.slug,
      );
    }

    handle.dispose();
  });

  testWidgets('tapping a product opens its page', (tester) async {
    useTallSurface(tester);
    await tester.pumpWidget(_app());

    await tester.tap(find.text('Ceramic mug'));
    await tester.pumpAndSettle();

    final page = tester.widget<ProductScreen>(find.byType(ProductScreen));
    expect(page.product.slug, 'ceramic-mug');
  });

  testWidgets('the whole catalogue is reachable on a phone-sized screen', (
    tester,
  ) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.text('Notebook set'), 200);
    expect(find.text('Notebook set'), findsOneWidget);
  });
}
