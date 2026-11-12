import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/language.dart';

class _NeverAnsweringBackend implements LanguageBackend {
  final Completer<String?> gate = Completer<String?>();

  @override
  Future<String?> read() => gate.future;

  @override
  Future<void> write(String value) async {}
}

class _ThrowingBackend implements LanguageBackend {
  @override
  Future<String?> read() async => throw StateError('no preferences');

  @override
  Future<void> write(String value) async => throw StateError('no preferences');
}

void main() {
  group('DemoLanguage', () {
    test('each choice carries the tag configure takes', () {
      expect(DemoLanguage.system.tag, isNull);
      expect(DemoLanguage.english.tag, 'en');
      expect(DemoLanguage.french.tag, 'fr');
    });

    test('system is the absence of an override', () {
      expect(DemoLanguage.system.tag, isNull);
      expect(DemoLanguage.values.where((l) => l.tag == null), hasLength(1));
    });

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

    test('a store that throws reads back as system', () async {
      final store = LanguageStore(backend: _ThrowingBackend());

      expect(await store.read(), DemoLanguage.system);
    });

    testWidgets('a store that goes quiet is left waiting, not answered', (
      tester,
    ) async {
      final store = LanguageStore(backend: _NeverAnsweringBackend());

      DemoLanguage? answer;
      unawaited(store.read().then((language) => answer = language));
      await tester.pump(const Duration(seconds: 30));

      expect(answer, isNull);
    });

    test('the storage key is the one already written to', () {
      expect(languageKey, 'paycross_demo_language');
    });

    test('a write that fails is not swallowed', () async {
      final store = LanguageStore(backend: _ThrowingBackend());

      await expectLater(
        store.write(DemoLanguage.french),
        throwsA(isA<StateError>()),
      );
    });
  });
}
