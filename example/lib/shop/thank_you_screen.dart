import 'package:flutter/material.dart';

import '../demo/money.dart';
import 'catalogue.dart';
import 'shop_screen.dart';

/// What a paid order looks like.
///
/// The last of the five review screens. It holds the order number and the
/// amount and nothing else: no transaction id, no session id, no recovery
/// token. Those belong to whoever is debugging a run, and History already
/// has them.
class ThankYouScreen extends StatelessWidget {
  const ThankYouScreen({
    super.key,
    required this.reference,
    required this.amount,
  });

  /// The order number, stamped when the order was placed.
  final String reference;

  /// What was paid, in minor units.
  final int amount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text(shopName)),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Icon(
            Icons.check_circle,
            size: 72,
            color: theme.colorScheme.primary,
            semanticLabel: 'Paid',
          ),
          const SizedBox(height: 24),
          Text(
            'Thank you for your order',
            style: theme.textTheme.headlineSmall,
          ),
          const SizedBox(height: 16),
          Text(
            'We have taken the payment and your order is on its way.',
            style: const TextStyle(height: 1.4),
          ),
          const SizedBox(height: 24),
          _Line(label: 'Order number', value: reference),
          const SizedBox(height: 8),
          _Line(label: 'Paid', value: formatMoney(amount, shopCurrency)),
          const SizedBox(height: 32),
          Semantics(
            identifier: 'shop.continue',
            child: FilledButton(
              // Back to the shop rather than back one screen: the checkout
              // and the product page are behind this, and an order that is
              // paid for should not be payable again by pressing back twice.
              //
              // `isFirst` is the floor, not a second destination. A stack
              // with no shop route in it is a widget test or a screen pushed
              // some way nobody has written yet, and popping it empty would
              // leave a Navigator with nothing in it.
              onPressed: () => Navigator.of(context).popUntil(
                (route) =>
                    route.settings.name == shopRouteName || route.isFirst,
              ),
              child: const Text('Continue shopping'),
            ),
          ),
        ],
      ),
    );
  }
}

/// One labelled fact about the order.
class _Line extends StatelessWidget {
  const _Line({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label),
        Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
      ],
    ),
  );
}
