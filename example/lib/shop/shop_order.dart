import '../demo/presets.dart';
import 'catalogue.dart';

/// What one order is called, on the thank-you page and in the back office.
///
/// Stamped from the moment the order was placed rather than left as the
/// `{{timestamp}}` placeholder the preset bodies carry. That placeholder is
/// resolved inside the minter, which does not hand the resolved body back to
/// anything -- so a shop that used it would have no reference to put on the
/// screen it has to show the shopper.
String orderReference(DateTime placed) =>
    'ORDER-${placed.millisecondsSinceEpoch}';

/// What the shop mints for one order.
///
/// Built by the presets' own helper rather than written out here, so the
/// storefront and the scenarios send one shape between them. A shop order is
/// the ordinary body at the product's price, filed under an order number: no
/// stored cards offered, none asked for, nothing else different.
String orderBody({required Product product, required String reference}) =>
    defaultBody(
      amount: product.price,
      currency: shopCurrency,
      reference: reference,
    );

/// What History files a shop run under.
///
/// The slug rather than the product name, for the reason History files a
/// preset under its own dull id: a row written today is read months later,
/// and a name that gets re-worded takes its rows with it.
String shopScenario(Product product) => 'shop:${product.slug}';
