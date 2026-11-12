import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:paycross_flutter/paycross_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String appearanceKey = 'paycross_demo_appearance';

const double minFontScale = 0.8;

const double maxFontScale = 1.3;

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

  static const DemoAppearance none = DemoAppearance();

  static const DemoAppearance themedPreset = DemoAppearance(
    brandLight: Color(0xFF00875A),
    brandDark: Color(0xFF57D9A3),
    themeMode: PayCrossThemeMode.dark,
    cornerRadius: 16,
    buttonCornerRadius: 28,
  );

  final Color? brandLight;

  final Color? brandDark;

  final PayCrossThemeMode themeMode;

  final double? cornerRadius;

  final double? buttonCornerRadius;

  final double? fontScale;

  bool get isNone =>
      brandLight == null &&
      brandDark == null &&
      themeMode == PayCrossThemeMode.system &&
      cornerRadius == null &&
      buttonCornerRadius == null &&
      fontScale == null;

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

final RegExp _hexDigits = RegExp(r'^[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$');

Color? colorFromHex(Object? text) {
  if (text is! String) return null;
  final digits = text.startsWith('#') ? text.substring(1) : text;
  if (!_hexDigits.hasMatch(digits)) return null;
  final value = int.parse(digits, radix: 16);
  return Color(digits.length == 6 ? 0xFF000000 | value : value);
}

String hexOf(Color color) {
  final argb = color.toARGB32();
  final opaque = (argb & 0xFF000000) == 0xFF000000;
  return (opaque ? argb & 0xFFFFFF : argb)
      .toRadixString(16)
      .padLeft(opaque ? 6 : 8, '0')
      .toUpperCase();
}

bool isValidFontScale(double scale) =>
    !scale.isNaN && scale >= minFontScale && scale <= maxFontScale;

bool isValidLength(double length) => length.isFinite && length >= 0;

PayCrossThemeMode _themeModeFromName(Object? name) =>
    PayCrossThemeMode.values.firstWhere(
      (mode) => mode.name == name,
      orElse: () => PayCrossThemeMode.system,
    );

double? _length(Object? value) {
  if (value is! num) return null;
  final length = value.toDouble();
  return isValidLength(length) ? length : null;
}

double? _fontScale(Object? value) {
  if (value is! num) return null;
  final scale = value.toDouble();
  return isValidFontScale(scale) ? scale : null;
}

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

class InMemoryAppearanceBackend implements AppearanceBackend {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String written) async => value = written;
}

class AppearanceStore {
  const AppearanceStore({
    AppearanceBackend backend = const SharedPreferencesAppearanceBackend(),
  })
    // ignore: prefer_initializing_formals
    : _backend = backend;

  final AppearanceBackend _backend;

  Future<DemoAppearance> read() async {
    try {
      return DemoAppearance.fromJson(await _backend.read());
    } catch (_) {
      return DemoAppearance.none;
    }
  }

  Future<void> write(DemoAppearance appearance) =>
      _backend.write(appearance.toJson());
}
