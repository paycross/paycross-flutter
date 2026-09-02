import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/surface.dart';

/// A backend that will not answer, the way a platform store with nothing
/// behind it does not answer.
class _HangingBackend implements SurfaceBackend {
  @override
  Future<String?> read() => Completer<String?>().future;

  @override
  Future<void> write(String value) => Completer<void>().future;
}

/// A backend that throws, the way an unreadable store does.
class _ThrowingBackend implements SurfaceBackend {
  @override
  Future<String?> read() async => throw StateError('no store');

  @override
  Future<void> write(String value) async => throw StateError('no store');
}

void main() {
  group('what the two surfaces are called on the wire', () {
    test('the SDK sheet is "sdk" and the web checkout is "web"', () {
      // Pinned, because these two strings are written into History rows that
      // outlive the build that wrote them. Renaming one silently turns every
      // past row into a row of the other kind.
      expect(surfaceName(PaymentSurface.sdkSheet), 'sdk');
      expect(surfaceName(PaymentSurface.webCheckout), 'web');
    });

    test('every surface has a name, and every name a surface', () {
      for (final surface in PaymentSurface.values) {
        expect(surfaceFromName(surfaceName(surface)), surface);
      }
    });

    test('a name from a build that knew more reads as the sheet', () {
      // The safe answer for anything unrecognised: the sheet is what the app
      // did before this preference existed, and a row written by a newer
      // build must not turn into a web run in an older one.
      expect(surfaceFromName('paperclip'), PaymentSurface.sdkSheet);
      expect(surfaceFromName(''), PaymentSurface.sdkSheet);
      expect(surfaceFromName(null), PaymentSurface.sdkSheet);
    });
  });

  group('the store', () {
    test('a store that has never been written answers the sheet', () async {
      final store = SurfaceStore(backend: InMemorySurfaceBackend());

      expect(await store.read(), PaymentSurface.sdkSheet);
    });

    test('what was written is what comes back', () async {
      final store = SurfaceStore(backend: InMemorySurfaceBackend());

      await store.write(PaymentSurface.webCheckout);

      expect(await store.read(), PaymentSurface.webCheckout);
    });

    test('choosing the sheet again is a value, not an erasure', () async {
      final backend = InMemorySurfaceBackend();
      final store = SurfaceStore(backend: backend);

      await store.write(PaymentSurface.webCheckout);
      await store.write(PaymentSurface.sdkSheet);

      expect(backend.value, 'sdk');
      expect(await store.read(), PaymentSurface.sdkSheet);
    });

    test(
      'a store that throws reads as the sheet rather than throwing',
      () async {
        // The same rule `SecretStore.read` keeps: a store this app cannot read
        // is indistinguishable from one nobody has written, and both mean the
        // default. Under `flutter test` the real backend is exactly this case,
        // which is why every widget test that builds a screen with the default
        // store still renders.
        final store = SurfaceStore(backend: _ThrowingBackend());

        expect(await store.read(), PaymentSurface.sdkSheet);
      },
    );

    test('a store that will not answer does not answer either', () async {
      // A silence rather than a throw, which is what a platform channel with
      // nothing behind it gives. This read is deliberately unbounded, and
      // this case pins that rather than a deadline: every screen that reads
      // the preference already shows the sheet while it waits, so a wait
      // that never ends costs the same default a timeout would have
      // produced. The screens are where that is proved -- `home_test.dart`
      // and `settings_test.dart` both build over a store like this one.
      final store = SurfaceStore(backend: _HangingBackend());
      var answered = false;

      unawaited(store.read().then((_) => answered = true));
      await Future<void>.delayed(Duration.zero);

      expect(answered, isFalse);
    });

    test('a write that throws is reported rather than swallowed', () async {
      // The opposite rule to the read, and deliberately so: a read that
      // cannot answer has a safe default, but a write that did not happen is
      // a preference the next launch will not have. Settings says so.
      final store = SurfaceStore(backend: _ThrowingBackend());

      await expectLater(
        store.write(PaymentSurface.webCheckout),
        throwsA(isA<StateError>()),
      );
    });
  });
}
