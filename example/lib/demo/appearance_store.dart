import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:paycross_flutter/paycross_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where the chosen appearance is written.
///
/// Plain `SharedPreferences`, like the language and the presets: how a sheet
/// looks is not a secret, and the secure store is slower and smaller.
///
/// Public, for the reason the language key is public: changing it silently
/// resets every colleague's theme, and a rule that matters that much is worth
/// being able to assert on directly.
const String appearanceKey = 'paycross_demo_appearance';

/// The narrowest scale `PayCross.configure` accepts.
///
/// Not this app's opinion. The bound is `PayCrossTypography.sizeScaleFactor`'s
/// own, and anything outside it is a `PayCrossErrorCode.invalidAppearance`
/// thrown out of `configure` — which `main` awaits before `runApp`, so a bad
/// number here is a launch that never draws rather than a sheet with odd type.
/// Both this and [maxFontScale] are duplicated from the plugin deliberately:
/// the plugin keeps its own copy private, and a demo that guessed the bound
/// would be a demo that stops refusing the day the bound moves.
const double minFontScale = 0.8;

/// The widest scale `PayCross.configure` accepts. See [minFontScale].
const double maxFontScale = 1.3;

/// How the native payment sheet should look, as this app stores it.
///
/// A flat six fields rather than the plugin's nested `PayCrossAppearance`,
/// because this is what one screen of text fields can write and one
/// preference string can hold. It is the demo's side of
/// `PayCross.configure(appearance:)` and covers the part of that API a
/// merchant evaluating the SDK most wants to try: their own brand colour,
/// their own corners, and whether the sheet follows the phone.
///
/// Every field is nullable and null means "leave it alone", which is the same
/// thing null means everywhere in `PayCrossAppearance`.
@immutable
class DemoAppearance {
  const DemoAppearance({
    this.brandLight,
    this.brandDark,
    this.themeMode = PayCrossThemeMode.system,
    this.cornerRadius,
    this.buttonCornerRadius,
    this.fontScale,
  });

  /// The stored string, read back.
  ///
  /// Never throws and never returns a value `PayCross.configure` would
  /// refuse. Both matter for the same reason: this is read at launch, before
  /// `runApp`, so anything that escapes here is a blank app rather than an
  /// unthemed sheet — and the string is not always one this build wrote. It
  /// can come from an older build, from the `PAYCROSS_APPEARANCE` define
  /// somebody typed by hand, or from a store that was never written at all.
  ///
  /// A string that cannot be read at all becomes [none] and says so through
  /// [debugPrint], because a define with a typo in it is otherwise
  /// indistinguishable from a sheet that ignored it. A string that reads but
  /// carries one impossible number keeps everything else and drops that one
  /// field: a hand-edited scale of 5 should cost the scale, not the colours.
  factory DemoAppearance.fromJson(String? stored) {
    if (stored == null || stored.isEmpty) return none;
    final Object? decoded;
    try {
      decoded = jsonDecode(stored);
    } catch (problem) {
      debugPrint('Ignoring an unreadable appearance: ${problem.runtimeType}.');
      return none;
    }
    if (decoded is! Map<String, Object?>) {
      debugPrint('Ignoring an appearance that is not a JSON object.');
      return none;
    }
    return DemoAppearance(
      brandLight: colorFromHex(decoded['brandLight']),
      brandDark: colorFromHex(decoded['brandDark']),
      themeMode: _themeModeFromName(decoded['themeMode']),
      cornerRadius: _length(decoded['cornerRadius']),
      buttonCornerRadius: _length(decoded['buttonCornerRadius']),
      fontScale: _fontScale(decoded['fontScale']),
    );
  }

  /// No opinion about anything, which is the sheet as it comes.
  static const DemoAppearance none = DemoAppearance();

  /// What the one themed preset tile runs with, as this store holds it.
  ///
  /// The same six numbers the tile carries, and `appearance_store_test`
  /// asserts they are still the same: the tile is the thing a colleague sees
  /// first, and a Settings button offering to load "the themed preset" has to
  /// load that one rather than something that used to be it.
  ///
  /// No font scale, because the tile sets none. Loading this therefore leaves
  /// the sheet's type at its ordinary size rather than at a size the tile
  /// never showed.
  static const DemoAppearance themedPreset = DemoAppearance(
    brandLight: Color(0xFF00875A),
    brandDark: Color(0xFF57D9A3),
    themeMode: PayCrossThemeMode.dark,
    cornerRadius: 16,
    buttonCornerRadius: 28,
  );

  /// The brand colour while the sheet is in light mode, or null for the
  /// merchant's back-office colour and the platform's default after it.
  final Color? brandLight;

  /// The same for dark mode. Its own field rather than a derivation of
  /// [brandLight] because the plugin keeps them separate, and it keeps them
  /// separate because a colour that reads on white is often unreadable on
  /// near-black.
  final Color? brandDark;

  /// Whether the sheet follows the device or is pinned to one palette.
  final PayCrossThemeMode themeMode;

  /// The card inputs' and rows' corner radius. Zero is a square corner.
  final double? cornerRadius;

  /// The Pay button's corner radius, which falls back to [cornerRadius].
  final double? buttonCornerRadius;

  /// What every font size in the sheet is multiplied by.
  ///
  /// Between [minFontScale] and [maxFontScale] inclusive or null, and that is
  /// an invariant of this type rather than a hope: every way in bounds it.
  final double? fontScale;

  /// Whether this says nothing at all, in which case the demo passes no
  /// appearance rather than an empty one.
  ///
  /// Not the same question as "are all the fields null": pinning the sheet to
  /// light is an opinion, and [themeMode] holds it in a non-nullable field.
  bool get isNone =>
      brandLight == null &&
      brandDark == null &&
      themeMode == PayCrossThemeMode.system &&
      cornerRadius == null &&
      buttonCornerRadius == null &&
      fontScale == null;

  /// What `PayCross.configure` is handed, or null where there is nothing to
  /// say.
  ///
  /// Null rather than an empty `PayCrossAppearance`, because the two are not
  /// the same call: an appearance with no brand in it is what the plugin asks
  /// about before deciding what to do with a legacy brand colour beside it.
  PayCrossAppearance? toAppearance() => isNone
      ? null
      : PayCrossAppearance(
          light: brandLight == null ? null : PayCrossColors(brand: brandLight),
          dark: brandDark == null ? null : PayCrossColors(brand: brandDark),
          themeMode: themeMode,
          shapes: cornerRadius == null && buttonCornerRadius == null
              ? null
              : PayCrossShapes(
                  cornerRadius: cornerRadius,
                  buttonCornerRadius: buttonCornerRadius,
                ),
          typography: fontScale == null
              ? null
              : PayCrossTypography(sizeScaleFactor: fontScale),
        );

  /// What goes in the preference, and what the `PAYCROSS_APPEARANCE` define
  /// takes.
  ///
  /// One string rather than six keys, so a half-written theme is not a state
  /// the store can be left in: `SharedPreferences` writes one key at a time,
  /// and six writes can stop after three.
  ///
  /// Null fields are left out rather than written as `null`, which keeps the
  /// define short enough to type on a command line.
  String toJson() => jsonEncode(<String, Object?>{
    if (brandLight != null) 'brandLight': hexOf(brandLight!),
    if (brandDark != null) 'brandDark': hexOf(brandDark!),
    if (themeMode != PayCrossThemeMode.system) 'themeMode': themeMode.name,
    if (cornerRadius != null) 'cornerRadius': cornerRadius,
    if (buttonCornerRadius != null) 'buttonCornerRadius': buttonCornerRadius,
    if (fontScale != null) 'fontScale': fontScale,
  });

  @override
  bool operator ==(Object other) =>
      other is DemoAppearance &&
      other.brandLight == brandLight &&
      other.brandDark == brandDark &&
      other.themeMode == themeMode &&
      other.cornerRadius == cornerRadius &&
      other.buttonCornerRadius == buttonCornerRadius &&
      other.fontScale == fontScale;

  @override
  int get hashCode => Object.hash(
    brandLight,
    brandDark,
    themeMode,
    cornerRadius,
    buttonCornerRadius,
    fontScale,
  );
}

/// Six or eight hex digits, and nothing else at all.
///
/// Matched rather than left to `int.tryParse`, which accepts a leading sign:
/// `-00875` is six characters that parse to a number, and it would have become
/// a colour nobody typed rather than the refusal the field shows for `ZZZZZZ`.
final RegExp _hexDigits = RegExp(r'^[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$');

/// The colour a hex string names, or null for anything that is not one.
///
/// Takes `RRGGBB` and `AARRGGBB`, with or without a leading `#`, in either
/// case. Six digits mean an opaque colour, which is what a person copying a
/// brand colour out of a style guide has.
///
/// [Object] rather than [String] because it is called on whatever `jsonDecode`
/// produced, and a number there is not a colour.
Color? colorFromHex(Object? text) {
  if (text is! String) return null;
  final digits = text.startsWith('#') ? text.substring(1) : text;
  if (!_hexDigits.hasMatch(digits)) return null;
  // Unguarded, unlike the parse this replaced: the match above is what makes
  // it safe, and a `tryParse` here would suggest there is still a way through.
  final value = int.parse(digits, radix: 16);
  return Color(digits.length == 6 ? 0xFF000000 | value : value);
}

/// A colour written the way [colorFromHex] reads it and a person types it.
///
/// Six digits for an opaque colour and eight for anything else, so the
/// ordinary case round-trips as the string the merchant's style guide gave
/// them rather than as one with `FF` bolted on the front.
String hexOf(Color color) {
  final argb = color.toARGB32();
  final opaque = (argb & 0xFF000000) == 0xFF000000;
  return (opaque ? argb & 0xFFFFFF : argb)
      .toRadixString(16)
      .padLeft(opaque ? 6 : 8, '0')
      .toUpperCase();
}

/// Whether [scale] is one `PayCross.configure` will accept.
///
/// The screen asks this before it writes, so a number outside the bound is
/// refused where the person who typed it is looking rather than at the next
/// launch, which is the only other place it could surface.
bool isValidFontScale(double scale) =>
    !scale.isNaN && scale >= minFontScale && scale <= maxFontScale;

/// Whether [length] is a radius `PayCross.configure` will accept.
///
/// Non-negative and finite. The plugin refuses the rest before it reaches
/// either native SDK, and a native handed one draws nothing or fails a layout
/// pass deep inside the sheet.
bool isValidLength(double length) => length.isFinite && length >= 0;

/// The stored theme mode, or [PayCrossThemeMode.system] for anything else.
///
/// Anything else includes a store written by a build that shipped a mode this
/// one does not. Falling back beats throwing, for the reason
/// `DemoLanguage.fromName` falls back: this is read at launch.
PayCrossThemeMode _themeModeFromName(Object? name) =>
    PayCrossThemeMode.values.firstWhere(
      (mode) => mode.name == name,
      orElse: () => PayCrossThemeMode.system,
    );

/// A stored radius, or null where the number is one `configure` would refuse.
double? _length(Object? value) {
  if (value is! num) return null;
  final length = value.toDouble();
  return isValidLength(length) ? length : null;
}

/// A stored scale, or null where the number is one `configure` would refuse.
double? _fontScale(Object? value) {
  if (value is! num) return null;
  final scale = value.toDouble();
  return isValidFontScale(scale) ? scale : null;
}

/// The slice of a key-value store the appearance setting needs.
abstract interface class AppearanceBackend {
  Future<String?> read();
  Future<void> write(String value);
}

class SharedPreferencesAppearanceBackend implements AppearanceBackend {
  const SharedPreferencesAppearanceBackend();

  @override
  Future<String?> read() async =>
      (await SharedPreferences.getInstance()).getString(appearanceKey);

  @override
  Future<void> write(String value) async =>
      (await SharedPreferences.getInstance()).setString(appearanceKey, value);
}

/// An [AppearanceBackend] in a field. Tests only.
class InMemoryAppearanceBackend implements AppearanceBackend {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String written) async => value = written;
}

/// How the payment sheet looks, across launches.
class AppearanceStore {
  const AppearanceStore({
    AppearanceBackend backend = const SharedPreferencesAppearanceBackend(),
  }) // The lint's own fix does not compile: Dart forbids a private NAMED
    // parameter, so `this._backend` cannot appear in a `{...}` list, and a
    // public backend is not what this class is for.
    // ignore: prefer_initializing_formals
    : _backend = backend;

  final AppearanceBackend _backend;

  /// The stored theme, or [DemoAppearance.none].
  ///
  /// Guarded, so an unreadable store costs the sheet its theme rather than
  /// throwing at whoever asked. [DemoAppearance.fromJson] already answers
  /// [DemoAppearance.none] for a string it cannot read, so the catch here is
  /// for the store itself failing rather than for its contents.
  ///
  /// **Not bounded here**, for the reason `LanguageStore.read` is not: this
  /// store's real failure is silence rather than an exception, and silence
  /// costs different things to different callers. `main` awaits this before
  /// `runApp` and puts its own bound on it; the Settings screen only leaves
  /// its fields disabled, which is visible and harmless.
  Future<DemoAppearance> read() async {
    try {
      return DemoAppearance.fromJson(await _backend.read());
    } catch (_) {
      return DemoAppearance.none;
    }
  }

  /// Writes the theme, and lets a failure through.
  ///
  /// Unguarded, unlike [read]: the screen that calls this tells the human
  /// whether their theme will survive the next launch, and it cannot say so
  /// honestly if a failed write looks like a successful one.
  Future<void> write(DemoAppearance appearance) =>
      _backend.write(appearance.toJson());
}
