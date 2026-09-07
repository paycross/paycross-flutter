import 'package:flutter/material.dart';

import '../demo/money.dart';
import 'catalogue.dart';
import 'product_screen.dart';

/// The name the shop's own route carries.
///
/// It exists so the thank-you page can come back here rather than one screen
/// back, past a checkout an order has already been paid on.
const String shopRouteName = 'shop';

/// The shop, as a route that can be returned to by name.
///
/// A function rather than a `MaterialApp.routes` entry: the demo has no route
/// table, every screen in it is pushed, and a table declared for one screen
/// would be a second way of navigating that only the shop used.
Route<void> shopRoute() => MaterialPageRoute<void>(
  settings: const RouteSettings(name: shopRouteName),
  builder: (_) => const ShopScreen(),
);

/// What the shop sells, and the way in to buying one of them.
///
/// The first of the five screens a wallet review walks through. Nothing on it
/// comes from the demo's environment, the credential store or the preset
/// list: a reviewer sees a shop, and a shop is all there is here to see.
class ShopScreen extends StatelessWidget {
  const ShopScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text(shopName)),
    body: ListView(
      padding: const EdgeInsets.all(12),
      children: [
        for (final product in catalogue) _ProductTile(product: product),
      ],
    ),
  );
}

class _ProductTile extends StatelessWidget {
  const _ProductTile({required this.product});

  final Product product;

  @override
  Widget build(BuildContext context) => Semantics(
    identifier: product.semanticsId,
    child: Card(
      child: ListTile(
        leading: Text(
          product.illustration,
          style: const TextStyle(fontSize: 34),
        ),
        title: Text(product.name),
        subtitle: Text(product.blurb),
        trailing: Text(
          formatMoney(product.price, shopCurrency),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        // The tile is the control, so the whole row reads as one button
        // rather than as four things that happen to be next to each other.
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ProductScreen(product: product),
          ),
        ),
      ),
    ),
  );
}
