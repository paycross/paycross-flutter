import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/appearance_store.dart';
import 'package:paycross_demo/demo/presets.dart';
import 'package:paycross_flutter/paycross_flutter.dart';

class _NeverAnsweringBackend implements AppearanceBackend {
  final Completer<String?> gate = Completer<String?>();

  @override
  Future<String?> read() => gate.future;

  @override
  Future<void> write(String value) async {}
}

class _ThrowingBackend implements AppearanceBackend {
  @override
  Future<String?> read() async => throw StateError('no preferences');

  @override
  Future<void> write(String value) async => throw StateError('no preferences');
}

const DemoAppearance _themed = DemoAppearance(
  brandLight: Color(0xFF00875A),
  brandDark: Color(0xFF57D9A3),
  themeMode: PayCrossThemeMode.dark,
  cornerRadius: 16,
  buttonCornerRadius: 28,
  fontScale: 1.2,
);

void main() {
  group('DemoAppearance', () {
    test('a theme survives a round-trip through its stored string', () {
      expect(DemoAppearance.fromJson(_themed.toJson()), _themed);
    });

    test('a theme with nothing in it asks for no appearance', () {
      expect(DemoAppearance.none.isNone, isTrue);
      expect(DemoAppearance.none.toAppearance(), isNull);
      expect(DemoAppearance.fromJson('{}'), DemoAppearance.none);
      expect(DemoAppearance.fromJson(null), DemoAppearance.none);
      expect(DemoAppearance.fromJson(''), DemoAppearance.none);
    });

    test('a pinned theme mode alone is an appearance', () {
      const pinned = DemoAppearance(themeMode: PayCrossThemeMode.light);

      expect(pinned.isNone, isFalse);
      expect(pinned.toAppearance()?.themeMode, PayCrossThemeMode.light);
    });

    test('each field reaches the appearance configure is handed', () {
      final appearance = _themed.toAppearance();

      expect(appearance?.light?.brand, const Color(0xFF00875A));
      expect(appearance?.dark?.brand, const Color(0xFF57D9A3));
      expect(appearance?.themeMode, PayCrossThemeMode.dark);
      expect(appearance?.shapes?.cornerRadius, 16);
      expect(appearance?.shapes?.buttonCornerRadius, 28);
      expect(appearance?.typography?.sizeScaleFactor, 1.2);
    });

    test('a corrupt stored string is no appearance rather than a throw', () {
      for (final corrupt in <String>[
        'not json at all',
        '{"brandLight":',
        '[]',
        '"a string"',
        '7',
      ]) {
        expect(
          DemoAppearance.fromJson(corrupt),
          DemoAppearance.none,
          reason: corrupt,
        );
      }
    });

    test('an out-of-range font scale is refused, and the rest survives', () {
      for (final refused in <num>[0, -1, 0.79, 1.31, 100]) {
        final stored = jsonEncode(<String, Object?>{
          'brandLight': '00875A',
          'fontScale': refused,
        });

        final read = DemoAppearance.fromJson(stored);

        expect(read.fontScale, isNull, reason: '$refused');
        expect(read.brandLight, const Color(0xFF00875A), reason: '$refused');
      }
    });

    test('both ends of the font-scale bound are kept', () {
      expect(DemoAppearance.fromJson('{"fontScale":0.8}').fontScale, 0.8);
      expect(DemoAppearance.fromJson('{"fontScale":1.3}').fontScale, 1.3);
      expect(isValidFontScale(minFontScale), isTrue);
      expect(isValidFontScale(maxFontScale), isTrue);
      expect(isValidFontScale(double.nan), isFalse);
    });

    test('a negative radius is refused', () {
      final read = DemoAppearance.fromJson(
        '{"cornerRadius":-4,"buttonCornerRadius":28}',
      );

      expect(read.cornerRadius, isNull);
      expect(read.buttonCornerRadius, 28);
      expect(isValidLength(0), isTrue);
      expect(isValidLength(double.infinity), isFalse);
    });

    test('a zero radius is kept', () {
      expect(DemoAppearance.fromJson('{"cornerRadius":0}').cornerRadius, 0);
      expect(DemoAppearance.fromJson('{"cornerRadius":0}').isNone, isFalse);
    });

    test('an unknown theme mode reads back as system', () {
      expect(
        DemoAppearance.fromJson('{"themeMode":"sepia"}').themeMode,
        PayCrossThemeMode.system,
      );
      expect(
        DemoAppearance.fromJson('{"themeMode":7}').themeMode,
        PayCrossThemeMode.system,
      );
    });

    test('an unreadable string says so', () {
      final printed = <String>[];
      final real = debugPrint;
      debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');
      addTearDown(() => debugPrint = real);

      DemoAppearance.fromJson('not json at all');

      expect(printed, hasLength(1));
      expect(printed.single, contains('appearance'));
    });

    test('an empty or absent string says nothing', () {
      final printed = <String>[];
      final real = debugPrint;
      debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');
      addTearDown(() => debugPrint = real);

      DemoAppearance.fromJson(null);
      DemoAppearance.fromJson('');
      DemoAppearance.fromJson('{"brandLight":"00875A"}');

      expect(printed, isEmpty);
    });
  });

  group('the themed preset', () {
    test('the button loads what the tile runs', () {
      final tile = demoPresets.firstWhere(
        (preset) => preset.id == 'appearance',
      );
      final loaded = DemoAppearance.themedPreset.toAppearance();

      expect(tile.appearance, isNotNull);
      expect(loaded?.light?.brand, tile.appearance?.light?.brand);
      expect(loaded?.dark?.brand, tile.appearance?.dark?.brand);
      expect(loaded?.themeMode, tile.appearance?.themeMode);
      expect(
        loaded?.shapes?.cornerRadius,
        tile.appearance?.shapes?.cornerRadius,
      );
      expect(
        loaded?.shapes?.buttonCornerRadius,
        tile.appearance?.shapes?.buttonCornerRadius,
      );
    });

    test('the button sets no font scale', () {
      expect(DemoAppearance.themedPreset.fontScale, isNull);
      expect(
        demoPresets
            .firstWhere((preset) => preset.id == 'appearance')
            .appearance
            ?.typography,
        isNull,
      );
    });
  });

  group('hex colours', () {
    test('six digits, eight digits, and a leading hash all read', () {
      expect(colorFromHex('00875A'), const Color(0xFF00875A));
      expect(colorFromHex('#00875A'), const Color(0xFF00875A));
      expect(colorFromHex('00875a'), const Color(0xFF00875A));
      expect(colorFromHex('8000875A'), const Color(0x8000875A));
      expect(colorFromHex('#8000875A'), const Color(0x8000875A));
    });

    test('anything that is not a colour reads as none', () {
      for (final text in <Object?>[
        null,
        7,
        '',
        '#',
        '00875',
        '00875AA',
        'ZZZZZZ',
        '#GG0000',
        '-00875',
        '+00875',
        '#-00875',
        '-0087500',
      ]) {
        expect(colorFromHex(text), isNull, reason: '$text');
      }
    });

    test('a colour is written the way it is read', () {
      expect(hexOf(const Color(0xFF00875A)), '00875A');
      expect(hexOf(const Color(0x8000875A)), '8000875A');
      expect(hexOf(const Color(0xFF000000)), '000000');
      expect(
        colorFromHex(hexOf(const Color(0x1234ABCD))),
        const Color(0x1234ABCD),
      );
    });
  });

  group('AppearanceStore', () {
    test('a theme survives a write and a read', () async {
      final store = AppearanceStore(backend: InMemoryAppearanceBackend());

      await store.write(_themed);

      expect(await store.read(), _themed);
    });

    test('an unwritten store reads back as none', () async {
      final store = AppearanceStore(backend: InMemoryAppearanceBackend());

      expect(await store.read(), DemoAppearance.none);
    });

    test('a write leaves one string in the backend', () async {
      final backend = InMemoryAppearanceBackend();

      await AppearanceStore(backend: backend).write(_themed);

      expect(backend.value, isNotNull);
      expect(DemoAppearance.fromJson(backend.value), _themed);
    });

    test('a store that throws reads back as none', () async {
      final store = AppearanceStore(backend: _ThrowingBackend());

      expect(await store.read(), DemoAppearance.none);
    });

    testWidgets('a store that goes quiet is left waiting, not answered', (
      tester,
    ) async {
      final store = AppearanceStore(backend: _NeverAnsweringBackend());

      DemoAppearance? answer;
      unawaited(store.read().then((appearance) => answer = appearance));
      await tester.pump(const Duration(seconds: 30));

      expect(answer, isNull);
    });

    test('the storage key is the one already written to', () {
      expect(appearanceKey, 'paycross_demo_appearance');
    });

    test('a write that fails is not swallowed', () async {
      final store = AppearanceStore(backend: _ThrowingBackend());

      await expectLater(store.write(_themed), throwsA(isA<StateError>()));
    });
  });
}
