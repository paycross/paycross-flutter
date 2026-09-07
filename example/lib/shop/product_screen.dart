import 'package:flutter/material.dart';

import '../demo/money.dart';
import 'catalogue.dart';
import 'checkout_screen.dart';

/// One product, and the decision to buy it.
///
/// The second of the five review screens: the pre-purchase page, where the
/// price is stated plainly and one button carries the shopper on.
class ProductScreen extends StatelessWidget {
  const ProductScreen({super.key, required this.product});

  final Product product;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(product.name)),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Center(
            child: Semantics(
              // A stand-in for a photograph, and named as one: read aloud,
              // the character itself is either silence or the wrong noun.
              label: 'Illustration of the ${product.name.toLowerCase()}',
              child: Text(
                product.illustration,
                style: const TextStyle(fontSize: 120),
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text(product.name, style: theme.textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(product.blurb, style: const TextStyle(height: 1.4)),
          const SizedBox(height: 16),
          Text(
            formatMoney(product.price, shopCurrency),
            style: theme.textTheme.headlineMedium,
          ),
          const SizedBox(height: 24),
          Semantics(
            identifier: 'shop.buy',
            child: FilledButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ShopCheckoutScreen(product: product),
                ),
              ),
              child: const Text('Buy now'),
            ),
          ),
        ],
      ),
    );
  }
}
