import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/surface.dart';

void main() {
  group('what the two surfaces are called on the wire', () {
    test('the SDK sheet is "sdk" and the web checkout is "web"', () {
      // Pinned, because these two strings are written into History rows that
      // outlive the build that wrote them. Renaming one silently turns every
      // past row into a row of the other kind.
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
      // The label alone says where it opens, not what it opens -- which on a
      // production tile is the whole question. The tile has no room for the
      // longer sentence, so it hangs off the button instead.
      expect(openInBrowserHint, contains('Mint this scenario'));
      expect(openInBrowserHint, contains('browser'));
    });

    test('two tiles never share a key', () {
      // Built from the tile's own name rather than its position, so
      // reordering the preset list cannot make a test that names one tile
      // quietly start asserting about another.
      expect(browserActionKey('a'), isNot(browserActionKey('b')));
      expect(browserActionKey('Custom'), contains('Custom'));
    });
  });
}
