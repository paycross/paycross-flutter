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

/// The order, the total, and the button that pays for it.
///
/// The third of the five review screens, and the only one in the shop that
/// touches the payment machinery. Every platform edge is a constructor
/// argument -- the credential read, the mint, the sheet, the history and the
/// version read -- which is what lets the whole flow be tested with no device
/// and no network, the way `RunScreen` is.
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

  /// Where the merchant credentials are read from, exactly as a preset run
  /// reads them.
  final SecretStore store;

  final Future<MintedSession> Function(Credentials, String body) mintWith;
  final Future<PayCrossResult> Function(String sessionToken) present;
  final HistoryStore history;
  final Future<DemoVersions> Function() readVersions;

  /// The clock the order number is stamped from.
  final DateTime Function() now;

  @override
  State<ShopCheckoutScreen> createState() => _ShopCheckoutScreenState();
}

class _ShopCheckoutScreenState extends State<ShopCheckoutScreen> {
  /// True from the tap until the payment has finished or been refused.
  ///
  /// The button goes dead rather than merely ignoring the second tap: the
  /// credential read and the mint both sit in that gap, and a second one
  /// would mint a second session and open a second sheet over the first.
  bool _paying = false;

  /// What to tell the shopper about a payment that did not complete, or null
  /// when there is nothing to say yet.
  String? _note;

  /// True once a payment came back unresolved.
  ///
  /// Its own field rather than a second reading of [_note], and the reason is
  /// the one outcome it stands for: nobody knows whether that payment took
  /// the money, so pressing Pay again can charge the shopper twice. The
  /// button stays dead for the life of this screen, because nothing that
  /// happens here can resolve it.
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
        // The demo's own answer to "not configured", and the same one both
        // preset entrances give: somewhere the human can act beats a refusal
        // they can only read. Nothing has been minted, so nothing is lost by
        // coming back here and pressing Pay again afterwards.
        await Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
        return;
      }

      // Stamped before the mint and held, because the body carries it and the
      // thank-you page shows it: a second reading of the clock would let the
      // number on the screen differ from the one the back office has.
      final reference = orderReference(widget.now());
      final MintedSession minted;
      try {
        minted = await widget.mintWith(
          credentials,
          orderBody(product: widget.product, reference: reference),
        );
      } on MinterError catch (problem) {
        // MinterError never carries a credential; see minter.dart.
        if (mounted) setState(() => _note = problem.message);
        return;
      }

      final run = await presentSession(widget.present, minted.token);
      if (!mounted) return;

      // Recorded, but never waited on. A payment that may have taken money
      // must not hold the shopper on a spinner while a store answers, and
      // `recordRun` swallows both its own failures -- so there is nothing
      // here for an unawaited future to lose.
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
        // The checkout and the product page go with it. A paid order that is
        // still one back-press from a live Pay button is an order somebody
        // can buy twice, and back is the first thing anybody walking a flow
        // presses.
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
      // Everything else -- cancelled, refused, unresolved, and a sheet that
      // threw -- lands back here in the shop's own words for it. The demo's
      // wording carries the server's recovery token and a transaction id,
      // which is what somebody debugging a scenario needs and exactly what a
      // shopper must never be shown. Nothing is lost by it: History records
      // the demo's wording, so the run is still reportable in full.
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
                // Flexible and Expanded for the reason the thank-you
                // page's rows carry them: two loose children in a
                // `spaceBetween` row have no width to give back, and this
                // one ran off the edge once the phone's font scale was up.
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
            // A live region, like the run screen's outcome card: the answer
            // lands in place minutes after the tap when a bank has asked the
            // shopper a question, and without this a screen-reader user is
            // never told the payment finished.
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
