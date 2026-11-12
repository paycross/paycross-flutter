import 'package:flutter/material.dart';

import '../demo/money.dart';
import 'catalogue.dart';

class ThankYouScreen extends StatelessWidget {
  const ThankYouScreen({
    super.key,
    required this.reference,
    required this.item,
    required this.amount,
  });

  final String reference;

  final String item;

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
          _Line(label: 'Item', value: item),
          const SizedBox(height: 8),
          _Line(label: 'Paid', value: formatMoney(amount, shopCurrency)),
          const SizedBox(height: 32),
          Semantics(
            identifier: 'shop.continue',
            child: FilledButton(
              onPressed: () {
                final navigator = Navigator.of(context);
                if (navigator.canPop()) navigator.pop();
              },
              child: const Text('Continue shopping'),
            ),
          ),
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Flexible(child: Text(label)),
        const SizedBox(width: 16),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ],
    ),
  );
}
