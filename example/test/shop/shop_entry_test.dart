import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/home.dart';
import 'package:paycross_demo/demo/presets.dart';
import 'package:paycross_demo/demo/secrets.dart';
import 'package:paycross_demo/shop/catalogue.dart';
import 'package:paycross_demo/shop/shop_screen.dart';

import '../demo/_environment.dart';
import '../demo/_surface.dart';

Widget _home() => MaterialApp(
  home: HomeScreen(store: SecretStore(backend: _empty())),
);

InMemorySecretBackend _empty() => InMemorySecretBackend();

void main() {
  testWidgets('the shop is the first tile on Home, above the scenarios', (
    tester,
  ) async {
    useTallSurface(tester);
    await tester.pumpWidget(_home());
    await tester.pumpAndSettle();

    final shop = tester.getTopLeft(find.text(shopName)).dy;
    final firstPreset = tester.getTopLeft(find.text(demoPresets.first.name)).dy;
    expect(shop, lessThan(firstPreset));
  });

  testWidgets('the shop tile opens the shop', (tester) async {
    useTallSurface(tester);
    await tester.pumpWidget(_home());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('shopTile')));
    await tester.pumpAndSettle();

    expect(find.byType(ShopScreen), findsOneWidget);
  });

  testWidgets('the bar action opens the shop too', (tester) async {
    await tester.pumpWidget(_home());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Shop'));
    await tester.pumpAndSettle();

    expect(find.byType(ShopScreen), findsOneWidget);
  });

  testWidgets('the shop route is named, so the thank-you page can return', (
    tester,
  ) async {
    useTallSurface(tester);
    await tester.pumpWidget(_home());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('shopTile')));
    await tester.pumpAndSettle();

    expect(
      ModalRoute.of(tester.element(find.byType(ShopScreen)))!.settings.name,
      shopRouteName,
    );
  });

  /// The storefront mints on the sandbox credentials in the secure store, and
  /// its Pay button asks nothing before it charges. In Live that would be a
  /// real card spent on one tap, past every refusal the Live tiles climb --
  /// and the red LIVE banner sits over every route, so a reviewer's
  /// screenshot of the shop would carry it. There is simply no way in.
  testWidgets('Live has no shop in it at all', (tester) async {
    useTallSurface(tester);
    await tester.pumpWidget(
      await liveApp(
        home: HomeScreen(store: SecretStore(backend: _empty())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('shopTile')), findsNothing);
    expect(find.byTooltip('Shop'), findsNothing);
    expect(find.text(shopName), findsNothing);
  });
}
