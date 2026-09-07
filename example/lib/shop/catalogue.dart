/// The shop's own name, on the list screen and in the thank-you copy.
const String shopName = 'PayCross Store';

/// What the shop charges in, on both environments.
///
/// Spelled here rather than read from `live.dart`'s `liveDefaultCurrency`,
/// and that is the same call `presets.dart` makes about its own default: the
/// two are one value by coincidence rather than by rule, and a shop whose
/// prices moved because somebody changed what Live mode defaults to would be
/// a surprise with no visible cause.
const String shopCurrency = 'EUR';

/// One thing on sale.
///
/// A plain value with no image and no network behind it. The illustration is
/// a character rather than an asset because the whole catalogue has to render
/// on a phone with no connection, in a build nobody has added an asset bundle
/// to, and be legible in a screenshot at any size.
class Product {
  const Product({
    required this.slug,
    required this.name,
    required this.price,
    required this.blurb,
    required this.illustration,
  });

  /// The dull, stable name for this product.
  ///
  /// Separate from [name] and deliberately duller than it, for the reason
  /// `Preset.id` is separate from `Preset.name`: the name is copy and will be
  /// re-worded, and a semantics id or a History row filed under a name would
  /// move the day somebody improves the wording.
  final String slug;

  final String name;

  /// The price in minor units, the way the merchant API takes an amount.
  final int price;

  /// The one line under the name. Merchant copy, never a note about the
  /// harness: the shop screens are what a reviewer sees.
  final String blurb;

  /// A character standing in for a photograph.
  final String illustration;

  /// What an automated cell would tap to open this product.
  ///
  /// Built from the slug rather than the position, so re-ordering the
  /// catalogue does not move an identifier and a cell that names a product
  /// cannot quietly start driving a different one.
  String get semanticsId => 'shop.product.$slug';
}

/// Everything the shop sells, in the order it is shown.
const List<Product> catalogue = <Product>[
  Product(
    slug: 'canvas-tote',
    name: 'Canvas tote',
    price: 2400,
    blurb: 'Heavy cotton, roomy enough for a laptop and a lunch.',
    illustration: '👜',
  ),
  Product(
    slug: 'ceramic-mug',
    name: 'Ceramic mug',
    price: 1250,
    blurb: 'Glazed stoneware, 350 ml, safe in the dishwasher.',
    illustration: '☕',
  ),
  Product(
    slug: 'notebook-set',
    name: 'Notebook set',
    price: 990,
    blurb: 'Three pocket notebooks, dotted pages, stitched spines.',
    illustration: '📓',
  ),
];
