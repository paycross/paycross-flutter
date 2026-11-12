import 'dart:ui' show Color;

import 'errors.dart';
import 'generated/paycross_api.g.dart' as g;

const double _minSizeScaleFactor = 0.8;
const double _maxSizeScaleFactor = 1.3;

/// Which palette the payment sheet draws with.
enum PayCrossThemeMode {
  /// Follows the device. The default.
  system,

  /// Pins the sheet to the light palette whatever the device is set to.
  light,

  /// Pins the sheet to the dark palette.
  dark,
}

/// One palette for light or dark mode.
///
/// A null role falls back to the brand colour set on the PayCross account, then
/// to the platform default.
class PayCrossColors {
  const PayCrossColors({
    this.brand,
    this.onBrand,
    this.surface,
    this.component,
    this.componentBorder,
    this.text,
    this.textSecondary,
    this.placeholder,
    this.icon,
    this.error,
  });

  /// The Pay button's fill, the selection controls and the focus ring on a card
  /// field.
  final Color? brand;

  /// The label and spinner drawn on [brand]. Null derives a readable one from
  /// the brand's luminance.
  final Color? onBrand;

  /// The sheet's background.
  final Color? surface;

  /// The fill behind the card inputs, stored-card rows and field groups.
  final Color? component;

  /// The border around those components. On iOS it paints only when
  /// [PayCrossShapes.borderWidth] is set.
  final Color? componentBorder;

  /// Primary text: the amount, field contents and button labels.
  final Color? text;

  /// Labels, hints and supporting text.
  final Color? textSecondary;

  /// The greyed text inside an empty input.
  final Color? placeholder;

  /// Icons the sheet draws itself, such as the stored-card delete glyph.
  final Color? icon;

  /// Error text, the error banner and an invalid field's border.
  final Color? error;

  /// This palette with the named roles replaced. A null keeps the current role,
  /// so build a new [PayCrossColors] to clear one.
  PayCrossColors copyWith({
    Color? brand,
    Color? onBrand,
    Color? surface,
    Color? component,
    Color? componentBorder,
    Color? text,
    Color? textSecondary,
    Color? placeholder,
    Color? icon,
    Color? error,
  }) => PayCrossColors(
    brand: brand ?? this.brand,
    onBrand: onBrand ?? this.onBrand,
    surface: surface ?? this.surface,
    component: component ?? this.component,
    componentBorder: componentBorder ?? this.componentBorder,
    text: text ?? this.text,
    textSecondary: textSecondary ?? this.textSecondary,
    placeholder: placeholder ?? this.placeholder,
    icon: icon ?? this.icon,
    error: error ?? this.error,
  );

  g.PcColors _toPigeon() => g.PcColors(
    brand: brand?.toARGB32(),
    onBrand: onBrand?.toARGB32(),
    surface: surface?.toARGB32(),
    component: component?.toARGB32(),
    componentBorder: componentBorder?.toARGB32(),
    text: text?.toARGB32(),
    textSecondary: textSecondary?.toARGB32(),
    placeholder: placeholder?.toARGB32(),
    icon: icon?.toARGB32(),
    error: error?.toARGB32(),
  );
}

/// Corner radii and border thickness, in each platform's own unit: density-
/// independent pixels on Android, points on iOS. The values are not converted.
class PayCrossShapes {
  const PayCrossShapes({
    this.cornerRadius,
    this.buttonCornerRadius,
    this.borderWidth,
  });

  /// The card inputs, stored-card rows, field groups and error banner. Zero is a
  /// square corner, not unset.
  final double? cornerRadius;

  /// The Pay button's corner radius, and the wallet buttons' radius. Falls back
  /// to [cornerRadius], then to the platform's own.
  final double? buttonCornerRadius;

  /// The thickness of the border around the card inputs. On iOS the border
  /// paints only when this is set.
  final double? borderWidth;

  g.PcShapes _toPigeon() => g.PcShapes(
    cornerRadius: cornerRadius,
    buttonCornerRadius: buttonCornerRadius,
    borderWidth: borderWidth,
  );
}

/// Overrides for the sheet's own Pay button. Wallet buttons keep the colours and
/// labels Apple and Google specify.
class PayCrossPrimaryButton {
  const PayCrossPrimaryButton({
    this.background,
    this.textColor,
    this.disabledBackground,
    this.disabledTextColor,
    this.cornerRadius,
    this.height,
  });

  /// The fill. Falls back to [PayCrossColors.brand], then to the platform default.
  final Color? background;

  /// The label and spinner. Falls back to [PayCrossColors.onBrand], then to the
  /// platform default.
  final Color? textColor;

  /// The fill while the button cannot be pressed.
  final Color? disabledBackground;

  /// The label while the button cannot be pressed.
  final Color? disabledTextColor;

  /// Falls back to [PayCrossShapes.buttonCornerRadius].
  final double? cornerRadius;

  /// The button's height, in the same unit as [PayCrossShapes]. Null keeps the
  /// platform's own: 56 on Android, 50 on iOS.
  final double? height;

  g.PcPrimaryButton _toPigeon() => g.PcPrimaryButton(
    background: background?.toARGB32(),
    textColor: textColor?.toARGB32(),
    disabledBackground: disabledBackground?.toARGB32(),
    disabledTextColor: disabledTextColor?.toARGB32(),
    cornerRadius: cornerRadius,
    height: height,
  );
}

/// Type sizing. There is no font family option: the two platforms resolve one
/// name to different fallbacks.
class PayCrossTypography {
  const PayCrossTypography({this.sizeScaleFactor});

  /// Multiplies every font size in the sheet, on top of the device's text-size
  /// setting. Must be between 0.8 and 1.3 inclusive; anything else throws
  /// [PayCrossErrorCode.invalidAppearance] from `PayCross.configure`.
  final double? sizeScaleFactor;

  g.PcTypography _toPigeon() =>
      g.PcTypography(sizeScaleFactor: sizeScaleFactor);
}

/// How the native payment sheet looks. Each colour resolves per role: a value
/// set here, then the brand colour set on the PayCross account, then the
/// platform default.
class PayCrossAppearance {
  const PayCrossAppearance({
    this.light,
    this.dark,
    this.themeMode = PayCrossThemeMode.system,
    this.shapes,
    this.primaryButton,
    this.typography,
  });

  /// One brand colour in both modes, with platform defaults for everything else.
  factory PayCrossAppearance.brand(Color color) => PayCrossAppearance(
    light: PayCrossColors(brand: color),
    dark: PayCrossColors(brand: color),
  );

  /// The palette used while the sheet is in light mode.
  final PayCrossColors? light;

  /// The palette used in dark mode. Set separately from [light]: a brand colour
  /// that reads on white often does not read on black.
  final PayCrossColors? dark;

  /// Whether the sheet follows the device or is pinned. Defaults to
  /// [PayCrossThemeMode.system].
  final PayCrossThemeMode themeMode;

  /// Corner radii and border thickness. Null keeps the platform's.
  final PayCrossShapes? shapes;

  /// Overrides for the Pay button. Null derives it from the palette.
  final PayCrossPrimaryButton? primaryButton;

  /// Type sizing. Null leaves every size alone.
  final PayCrossTypography? typography;

  /// Whether either palette names a brand colour.
  bool get hasBrand => light?.brand != null || dark?.brand != null;

  /// This appearance with the named fields replaced. A null keeps the current
  /// field.
  PayCrossAppearance copyWith({
    PayCrossColors? light,
    PayCrossColors? dark,
    PayCrossThemeMode? themeMode,
    PayCrossShapes? shapes,
    PayCrossPrimaryButton? primaryButton,
    PayCrossTypography? typography,
  }) => PayCrossAppearance(
    light: light ?? this.light,
    dark: dark ?? this.dark,
    themeMode: themeMode ?? this.themeMode,
    shapes: shapes ?? this.shapes,
    primaryButton: primaryButton ?? this.primaryButton,
    typography: typography ?? this.typography,
  );
}

/// Converts an appearance to its channel form, refusing values no sheet can draw.
extension PayCrossAppearanceCrossing on PayCrossAppearance {
  g.PcAppearance toPigeon() {
    final scale = typography?.sizeScaleFactor;
    if (scale != null &&
        (scale.isNaN ||
            scale < _minSizeScaleFactor ||
            scale > _maxSizeScaleFactor)) {
      throw PayCrossIntegrationError(
        PayCrossErrorCode.invalidAppearance,
        'sizeScaleFactor must be between $_minSizeScaleFactor and '
        '$_maxSizeScaleFactor inclusive; got $scale.',
      );
    }

    _requireLength('shapes.cornerRadius', shapes?.cornerRadius);
    _requireLength('shapes.buttonCornerRadius', shapes?.buttonCornerRadius);
    _requireLength('shapes.borderWidth', shapes?.borderWidth);
    _requireLength('primaryButton.cornerRadius', primaryButton?.cornerRadius);
    _requireLength('primaryButton.height', primaryButton?.height);

    return g.PcAppearance(
      light: light?._toPigeon(),
      dark: dark?._toPigeon(),
      // Pigeon has no field defaults, so the value is always sent.
      themeMode: switch (themeMode) {
        PayCrossThemeMode.system => g.PcThemeMode.system,
        PayCrossThemeMode.light => g.PcThemeMode.light,
        PayCrossThemeMode.dark => g.PcThemeMode.dark,
      },
      shapes: shapes?._toPigeon(),
      primaryButton: primaryButton?._toPigeon(),
      typography: typography?._toPigeon(),
    );
  }
}

void _requireLength(String field, double? value) {
  if (value == null) return;
  if (value.isNaN || value.isInfinite || value < 0) {
    throw PayCrossIntegrationError(
      PayCrossErrorCode.invalidAppearance,
      '$field must be a finite, non-negative number; got $value.',
    );
  }
}
