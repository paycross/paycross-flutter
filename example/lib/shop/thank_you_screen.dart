import 'package:flutter/material.dart';

import '../demo/money.dart';
import 'catalogue.dart';

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
    required this.item,
    required this.amount,
  });

  /// The order number, stamped when the order was placed.
  final String reference;

  /// What was bought. A receipt that names only a number is a receipt
  /// nobody can check.
  final String item;

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
          _Line(label: 'Item', value: item),
          const SizedBox(height: 8),
          _Line(label: 'Paid', value: formatMoney(amount, shopCurrency)),
          const SizedBox(height: 32),
          Semantics(
            identifier: 'shop.continue',
            child: FilledButton(
              // One pop, because there is one route to pop. The checkout
              // removed itself and the product page when it opened this, so
              // that a paid order cannot be paid a second time by pressing
              // back -- which means the shop is already the route underneath.
              //
              // Guarded, because a stack with nothing under it is a widget
              // test or a screen pushed some way nobody has written yet, and
              // popping it would leave a Navigator with nothing in it.
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

/// One labelled fact about the order.
class _Line extends StatelessWidget {
  const _Line({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Both children take a share of the width rather than their own
        // intrinsic size, and that is what makes this row incapable of
        // overflowing. An order number is nineteen characters: loose in a
        // `spaceBetween` row it drew clean off the right edge of every
        // phone -- stripes in a debug build, silently clipped in a release
        // one, on the one screen this whole flow exists to photograph. The
        // label went over on its own once the phone's font scale was up.
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
