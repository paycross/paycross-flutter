import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/surface.dart';

void main() {
  group('what the two surfaces are called on the wire', () {
    test('the SDK sheet is "sdk" and the web checkout is "web"', () {
      expect(surfaceName(PaymentSurface.sdkSheet), 'sdk');
      expect(surfaceName(PaymentSurface.webCheckout), 'web');
    });

    test('every surface has a name of its own', () {
      final names = {
        for (final surface in PaymentSurface.values) surfaceName(surface),
      };

      expect(names, hasLength(PaymentSurface.values.length));
    });
  });

  group('what a tile calls the second way to run it', () {
    test('the label is one string, so thirteen tiles cannot disagree', () {
      expect(openInBrowserLabel, 'Open in browser');
    });

    test('the tooltip says what the button is about to mint', () {
      expect(openInBrowserHint, contains('Mint this scenario'));
      expect(openInBrowserHint, contains('browser'));
    });

    test('two tiles never share a key', () {
      expect(browserActionKey('a'), isNot(browserActionKey('b')));
      expect(browserActionKey('Custom'), contains('Custom'));
    });
  });
}
