import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/language.dart';

/// A backend whose reads and writes throw, standing in for a device whose
/// preference store is unavailable.
class _ThrowingBackend implements LanguageBackend {
  @override
  Future<String?> read() async => throw StateError('no preferences');

  @override
  Future<void> write(String value) async => throw StateError('no preferences');
}

void main() {
  group('DemoLanguage', () {
    /// These three strings are the whole contract with the SDK: null asks for
    /// nothing, and the other two are the two languages both native sheets
    /// ship. A tag typed wrong here would fall through the native ladder to
    /// English and look exactly like the setting having no effect.
    test('each choice carries the tag configure takes', () {
      expect(DemoLanguage.system.tag, isNull);
      expect(DemoLanguage.english.tag, 'en');
      expect(DemoLanguage.french.tag, 'fr');
    });

    /// System is not a request for English. Null leaves the payment session's
    /// own locale to decide, and the device after it -- so a demo left on
    /// System shows what a merchant who writes no code at all would see.
    test('system is the absence of an override', () {
      expect(DemoLanguage.system.tag, isNull);
      expect(DemoLanguage.values.where((l) => l.tag == null), hasLength(1));
    });

    /// A store written by a build that had a language this one does not.
    /// Falling back beats throwing at launch, which is where this is read.
    test('an unknown stored name reads back as system', () {
      expect(DemoLanguage.fromName('klingon'), DemoLanguage.system);
      expect(DemoLanguage.fromName(''), DemoLanguage.system);
      expect(DemoLanguage.fromName(null), DemoLanguage.system);
    });

    test('every choice round-trips through its stored name', () {
      for (final language in DemoLanguage.values) {
        expect(DemoLanguage.fromName(language.name), language);
      }
    });
  });

  group('LanguageStore', () {
    test('a choice survives a write and a read', () async {
      final store = LanguageStore(backend: InMemoryLanguageBackend());

      await store.write(DemoLanguage.french);

      expect(await store.read(), DemoLanguage.french);
    });

    test('an unwritten store reads back as system', () async {
      final store = LanguageStore(backend: InMemoryLanguageBackend());

      expect(await store.read(), DemoLanguage.system);
    });

    /// `main` awaits this before `runApp`, so a throw here would be a blank
    /// screen rather than a sheet in the wrong language.
    test('a store that throws reads back as system', () async {
      final store = LanguageStore(backend: _ThrowingBackend());

      expect(await store.read(), DemoLanguage.system);
    });

    /// A failed write is reported rather than swallowed: the screen that
    /// calls it says whether the choice will survive the next launch, and it
    /// cannot say so honestly if the failure never reaches it.
    test('a write that fails is not swallowed', () async {
      final store = LanguageStore(backend: _ThrowingBackend());

      await expectLater(
        store.write(DemoLanguage.french),
        throwsA(isA<StateError>()),
      );
    });
  });
}
