import 'dart:async';

import 'package:flutter/material.dart';
import 'package:paycross_flutter/paycross_flutter.dart';

import '../demo/history.dart';
import '../demo/home.dart';
import '../demo/minter.dart';
import '../demo/money.dart';
import '../demo/present.dart';
import '../demo/secrets.dart';
import '../demo/settings.dart';
import '../demo/version_panel.dart';
import 'catalogue.dart';
import 'shop_order.dart';
import 'shop_outcome.dart';
import 'shop_screen.dart';
import 'thank_you_screen.dart';

class ShopCheckoutScreen extends StatefulWidget {
  const ShopCheckoutScreen({
    super.key,
    required this.product,
    this.store = const SecretStore(),
    this.mintWith = mintWithCredentials,
    this.present = PayCross.presentPayment,
    this.history = const HistoryStore(),
    this.readVersions = platformVersions,
    this.now = DateTime.now,
  });

  final Product product;

  final SecretStore store;

  final Future<MintedSession> Function(Credentials, String body) mintWith;
  final Future<PayCrossResult> Function(String sessionToken) present;
  final HistoryStore history;
  final Future<DemoVersions> Function() readVersions;

  final DateTime Function() now;

  @override
  State<ShopCheckoutScreen> createState() => _ShopCheckoutScreenState();
}

class _ShopCheckoutScreenState extends State<ShopCheckoutScreen> {
  bool _paying = false;

  String? _note;

  bool _unresolved = false;

  Future<void> _pay() async {
    if (_paying) return;
    setState(() {
      _paying = true;
      _note = null;
    });
    try {
      final credentials = await widget.store.read().timeout(
        credentialReadTimeout,
        onTimeout: () => null,
      );
      if (!mounted) return;
      if (credentials == null) {
        await Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
        return;
      }

      final reference = orderReference(widget.now());
      final MintedSession minted;
      try {
        minted = await widget.mintWith(
          credentials,
          orderBody(product: widget.product, reference: reference),
        );
      } on MinterError catch (problem) {
        if (mounted) setState(() => _note = problem.message);
        return;
      }

      final run = await presentSession(widget.present, minted.token);
      if (!mounted) return;

      unawaited(
        recordRun(
          history: widget.history,
          readVersions: widget.readVersions,
          scenario: shopScenario(widget.product),
          sessionId: minted.id,
          transactionId: run.transactionId,
          outcome: run.human,
        ),
      );

      if (run.result is PayCrossSuccess) {
        await Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute<void>(
            builder: (_) => ThankYouScreen(
              reference: reference,
              item: widget.product.name,
              amount: widget.product.price,
            ),
          ),
          (route) => route.settings.name == shopRouteName || route.isFirst,
        );
        return;
      }
      if (mounted) {
        setState(() {
          _note = shopOutcomeMessage(run);
          _unresolved = !shopMayPayAgain(run);
        });
      }
    } finally {
      if (mounted) setState(() => _paying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final product = widget.product;
    final total = formatMoney(product.price, shopCurrency);
    final note = _note;
    return Scaffold(
      appBar: AppBar(title: const Text('Checkout')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('Your order', style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: Text(
                product.illustration,
                style: const TextStyle(fontSize: 30),
              ),
              title: Text(product.name),
              trailing: Text(formatMoney(product.price, shopCurrency)),
            ),
          ),
          const SizedBox(height: 16),
          MergeSemantics(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Flexible(
                  child: Text('Total', style: theme.textTheme.titleMedium),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    total,
                    textAlign: TextAlign.end,
                    style: theme.textTheme.titleLarge,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          if (note != null) ...[
            Semantics(
              liveRegion: true,
              child: Card(
                color: theme.colorScheme.surfaceContainerHighest,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(note, style: const TextStyle(height: 1.4)),
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
          Semantics(
            identifier: 'shop.pay',
            child: FilledButton(
              onPressed: _paying || _unresolved ? null : _pay,
              child: Text('Pay $total'),
            ),
          ),
        ],
      ),
    );
  }
}
