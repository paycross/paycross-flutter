import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/shop/catalogue.dart';

void main() {
  test('the shop offers three products', () {
    expect(catalogue, hasLength(3));
  });

  test('every slug is distinct, so a semantics id names one product', () {
    expect(
      catalogue.map((product) => product.slug).toSet(),
      hasLength(catalogue.length),
    );
  });

  test('the shipped products are the ones the copy names', () {
    expect(
      catalogue.map((product) => (product.slug, product.name, product.price)),
      [
        ('canvas-tote', 'Canvas tote', 2400),
        ('ceramic-mug', 'Ceramic mug', 1250),
        ('notebook-set', 'Notebook set', 990),
      ],
    );
  });

  test('every product carries a blurb and an illustration', () {
    for (final product in catalogue) {
      expect(product.blurb, isNotEmpty, reason: product.slug);
      expect(product.illustration, isNotEmpty, reason: product.slug);
    }
  });

  test('the shop charges in euros', () {
    expect(shopCurrency, 'EUR');
  });

  test('a product names its own semantics id', () {
    expect(catalogue.first.semanticsId, 'shop.product.canvas-tote');
  });

  /// The whole point of the storefront: a reviewer must see a shop, not the
  /// harness. Every one of these words belongs to the developer screens.
  test('no shop copy leaks the harness vocabulary', () {
    const forbidden = <String>[
      'sandbox',
      'test card',
      'scenario',
      'session',
      'token',
      '3DS',
      '3-D Secure',
      'preset',
    ];
    final copy = [
      shopName,
      for (final product in catalogue) ...[product.name, product.blurb],
    ].join('\n').toLowerCase();
    for (final word in forbidden) {
      expect(copy, isNot(contains(word.toLowerCase())), reason: word);
    }
  });
}
