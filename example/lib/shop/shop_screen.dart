import 'package:flutter/material.dart';

import '../demo/money.dart';
import 'catalogue.dart';
import 'product_screen.dart';

const String shopRouteName = 'shop';

Route<void> shopRoute() => MaterialPageRoute<void>(
  settings: const RouteSettings(name: shopRouteName),
  builder: (_) => const ShopScreen(),
);

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
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ProductScreen(product: product),
          ),
        ),
      ),
    ),
  );
}
