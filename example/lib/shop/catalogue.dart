const String shopName = 'PayCross Store';

const String shopCurrency = 'EUR';

class Product {
  const Product({
    required this.slug,
    required this.name,
    required this.price,
    required this.blurb,
    required this.illustration,
  });

  final String slug;

  final String name;

  final int price;

  final String blurb;

  final String illustration;

  String get semanticsId => 'shop.product.$slug';
}

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
