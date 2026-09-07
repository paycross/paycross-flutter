import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/presets.dart';
import 'package:paycross_demo/shop/catalogue.dart';
import 'package:paycross_demo/shop/shop_order.dart';

final _tote = catalogue.first;

Map<String, Object?> _decoded(String body) =>
    jsonDecode(body) as Map<String, Object?>;

void main() {
  group('the order reference', () {
    test('is stamped with the moment the order was placed', () {
      expect(
        orderReference(DateTime.fromMillisecondsSinceEpoch(1757200000000)),
        'ORDER-1757200000000',
      );
    });

    test('two orders placed at different moments do not share a reference', () {
      final first = orderReference(DateTime.fromMillisecondsSinceEpoch(1000));
      final second = orderReference(DateTime.fromMillisecondsSinceEpoch(2000));
      expect(first, isNot(second));
    });
  });

  group('the order body', () {
    test('charges the product price in the shop currency', () {
      final body = _decoded(orderBody(product: _tote, reference: 'ORDER-1'));

      expect(body['amount'], 2400);
      expect(body['currency'], 'EUR');
    });

    test('carries the order reference the thank-you page shows', () {
      final body = _decoded(orderBody(product: _tote, reference: 'ORDER-77'));

      expect(body['merchant_reference'], 'ORDER-77');
    });

    test('is an ordinary sale with a customer on it', () {
      final body = _decoded(orderBody(product: _tote, reference: 'ORDER-1'));

      expect(body['transaction_type'], 'sale');
      final customer = body['customer']! as Map<String, Object?>;
      expect(customer['email'], isNotNull);
      expect(customer['address'], isNotNull);
    });

    test('asks for no stored cards and offers to store none', () {
      final body = _decoded(orderBody(product: _tote, reference: 'ORDER-1'));

      expect(body.containsKey('saved_cards'), isFalse);
      expect(body.containsKey('save_card_config'), isFalse);
    });

    test('is the shape the presets mint, price and reference aside', () {
      final order = _decoded(orderBody(product: _tote, reference: 'ORDER-1'));
      final preset = _decoded(defaultBody());

      expect(order.keys, preset.keys);
    });

    test('every product mints its own price', () {
      for (final product in catalogue) {
        final body = _decoded(orderBody(product: product, reference: 'O'));
        expect(body['amount'], product.price, reason: product.slug);
      }
    });
  });

  group('the history scenario', () {
    test('names the product by its slug', () {
      expect(shopScenario(_tote), 'shop:canvas-tote');
    });
  });

  group('the shipped presets are untouched', () {
    test('the ordinary body still mints ten euros under a demo reference', () {
      final body = _decoded(defaultBody());

      expect(body['amount'], 1000);
      expect(body['currency'], 'EUR');
      expect(body['merchant_reference'], 'DEMO-{{timestamp}}');
    });
  });
}
