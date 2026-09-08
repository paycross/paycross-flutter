import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/appearance_store.dart';
import 'package:paycross_demo/demo/presets.dart';
import 'package:paycross_flutter/paycross_flutter.dart';

/// A backend whose read never answers.
///
/// The failure this store actually has. `SharedPreferences` with no platform
/// behind it does not throw, it goes quiet, which is what `preset_store.dart`
/// and `history.dart` both bound their own writes against.
class _NeverAnsweringBackend implements AppearanceBackend {
  final Completer<String?> gate = Completer<String?>();

  @override
  Future<String?> read() => gate.future;

  @override
  Future<void> write(String value) async {}
}

/// A backend whose reads and writes throw, standing in for a device whose
/// preference store is unavailable.
class _ThrowingBackend implements AppearanceBackend {
  @override
  Future<String?> read() async => throw StateError('no preferences');

  @override
  Future<void> write(String value) async => throw StateError('no preferences');
}

/// The theme the settings screen's preset button writes, and the one preset
/// tile's own appearance. Every field set, so a round-trip that drops one is
/// a failure rather than a value that happened to match its default.
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

    /// The demo passes no appearance at all rather than an empty one, so that
    /// a colleague who has set nothing sees exactly what a merchant who wrote
    /// no appearance code sees.
    test('a theme with nothing in it asks for no appearance', () {
      expect(DemoAppearance.none.isNone, isTrue);
      expect(DemoAppearance.none.toAppearance(), isNull);
      expect(DemoAppearance.fromJson('{}'), DemoAppearance.none);
      expect(DemoAppearance.fromJson(null), DemoAppearance.none);
      expect(DemoAppearance.fromJson(''), DemoAppearance.none);
    });

    /// Pinning the sheet to light is an opinion even though every nullable
    /// field is still null, so it must not read as "nothing set".
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

    /// Read at launch, before `runApp`, and not always from a string this
    /// build wrote: a corrupt store or a define with a typo in it must cost
    /// the sheet its theme rather than costing the app its launch.
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

    /// Every number `PayCross.configure` refuses has to be refused here
    /// first. `main` awaits `configure` before `runApp` and does not catch it,
    /// so a stored 5.0 would be a blank app rather than a large sheet.
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

    /// The plugin refuses a negative or non-finite radius for the same reason
    /// it refuses a scale, and out of the same call.
    test('a negative radius is refused', () {
      final read = DemoAppearance.fromJson(
        '{"cornerRadius":-4,"buttonCornerRadius":28}',
      );

      expect(read.cornerRadius, isNull);
      expect(read.buttonCornerRadius, 28);
      expect(isValidLength(0), isTrue);
      expect(isValidLength(double.infinity), isFalse);
    });

    /// Zero is a square corner rather than "unset", which is what the plugin
    /// documents, so it has to survive the store.
    test('a zero radius is kept', () {
      expect(DemoAppearance.fromJson('{"cornerRadius":0}').cornerRadius, 0);
      expect(DemoAppearance.fromJson('{"cornerRadius":0}').isNone, isFalse);
    });

    /// A store written by a build that shipped a mode this one does not.
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

    /// A define with a typo in it is otherwise indistinguishable from a sheet
    /// that ignored it, and the define is typed by hand on a command line.
    test('an unreadable string says so', () {
      final printed = <String>[];
      final real = debugPrint;
      debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');
      addTearDown(() => debugPrint = real);

      DemoAppearance.fromJson('not json at all');

      expect(printed, hasLength(1));
      expect(printed.single, contains('appearance'));
    });

    /// Nothing is printed for the ordinary cases, or every launch of a demo
    /// with no theme set would carry a warning about it.
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
    /// Settings offers to load "the themed preset", and the tile is what a
    /// colleague sees first. The two carry the same six numbers in two files,
    /// so this is what stops the button loading a theme the tile stopped
    /// running.
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

    /// The tile sets no font scale, so loading it must not set one either --
    /// the theme a colleague loads is the theme they watched run.
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
    /// Six digits is what a merchant copying a brand colour out of a style
    /// guide has, and the `#` is what they will paste with it.
    test('six digits, eight digits, and a leading hash all read', () {
      expect(colorFromHex('00875A'), const Color(0xFF00875A));
      expect(colorFromHex('#00875A'), const Color(0xFF00875A));
      expect(colorFromHex('00875a'), const Color(0xFF00875A));
      expect(colorFromHex('8000875A'), const Color(0x8000875A));
      expect(colorFromHex('#8000875A'), const Color(0x8000875A));
    });

    /// The signed strings are the ones a length check and `int.tryParse` let
    /// through together: six characters that parse to a number, and a colour
    /// nobody typed.
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

    /// An opaque colour writes back as the six digits it was typed as rather
    /// than as eight with `FF` bolted on the front.
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

    /// The settings screen writes into this backend, and a test that reads it
    /// back has to be reading the same one string the app reads.
    test('a write leaves one string in the backend', () async {
      final backend = InMemoryAppearanceBackend();

      await AppearanceStore(backend: backend).write(_themed);

      expect(backend.value, isNotNull);
      expect(DemoAppearance.fromJson(backend.value), _themed);
    });

    /// `main` awaits this before `runApp`, so a throw here would be a blank
    /// screen rather than a sheet with no theme on it.
    test('a store that throws reads back as none', () async {
      final store = AppearanceStore(backend: _ThrowingBackend());

      expect(await store.read(), DemoAppearance.none);
    });

    /// Silence is this store's real failure, and it is deliberately not
    /// bounded here: the bound lives in `main`, which is the caller that
    /// cannot afford to wait, and `main_test` pins it.
    testWidgets('a store that goes quiet is left waiting, not answered', (
      tester,
    ) async {
      final store = AppearanceStore(backend: _NeverAnsweringBackend());

      DemoAppearance? answer;
      unawaited(store.read().then((appearance) => answer = appearance));
      await tester.pump(const Duration(seconds: 30));

      expect(answer, isNull);
    });

    /// Public for the reason the language key is: changing it silently resets
    /// every colleague's theme, and nothing else in the app would notice.
    test('the storage key is the one already written to', () {
      expect(appearanceKey, 'paycross_demo_appearance');
    });

    /// A failed write is reported rather than swallowed: the screen that
    /// calls it says whether the theme will survive the next launch, and it
    /// cannot say so honestly if the failure never reaches it.
    test('a write that fails is not swallowed', () async {
      final store = AppearanceStore(backend: _ThrowingBackend());

      await expectLater(store.write(_themed), throwsA(isA<StateError>()));
    });
  });
}
