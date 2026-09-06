import 'dart:ui' show Color;

import 'errors.dart';
import 'generated/paycross_api.g.dart' as g;

/// The smallest and largest font scale the native sheets will draw.
///
/// Below 0.8 the card fields stop being legible on a phone held at arm's
/// length; above 1.3 the Pay button and the amount stop fitting together on a
/// small screen. Both natives clamp to the same pair for callers that reach
/// them directly; this package refuses instead, because a Flutter merchant who
/// typed 3.0 asked for something no sheet will ever draw and should be told.
const double _minSizeScaleFactor = 0.8;
const double _maxSizeScaleFactor = 1.3;

/// Which palette the payment sheet draws with.
enum PayCrossThemeMode {
  /// Follows the device. The default.
  system,

  /// Pins the sheet to the light palette whatever the device is set to.
  ///
  /// The sheet only. The host app's own appearance is never touched: Android
  /// overrides the configuration of the payment Activity alone, and iOS sets
  /// `overrideUserInterfaceStyle` on the presented controller.
  light,

  /// Pins the sheet to the dark palette. See [light].
  dark,
}

/// One palette, used twice: once for light, once for dark.
///
/// Every role is nullable and null is not "black" — it means "take the next
/// source". Colours resolve per role in this order:
///
/// 1. what is set here,
/// 2. the brand colour the merchant set in the PayCross back office, which
///    arrives with the session and applies to [brand] in both modes,
/// 3. the platform default the sheet already draws.
///
/// So an empty palette changes nothing, and a palette that names one colour
/// changes one colour.
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

  /// The Pay button's fill, the selection controls, and the focus ring on a
  /// card field.
  ///
  /// The one role the back-office brand colour also feeds, so leaving it null
  /// is how a merchant hands the choice to whoever configures the account.
  final Color? brand;

  /// The label and spinner drawn on top of [brand].
  ///
  /// Null derives it from [brand]'s own luminance, so a light brand gets a
  /// dark label rather than an unreadable white one. Set it only to overrule
  /// that.
  final Color? onBrand;

  /// The sheet's own background.
  final Color? surface;

  /// The fill behind the card inputs, the stored-card rows and the field
  /// groups.
  final Color? component;

  /// The border around those same components.
  ///
  /// On iOS the sheet draws no border at all unless
  /// [PayCrossShapes.borderWidth] is set, so this colour has nothing to paint
  /// until it is.
  final Color? componentBorder;

  /// Primary text: the amount, the field contents, the button labels.
  final Color? text;

  /// Labels, hints and supporting text.
  final Color? textSecondary;

  /// The greyed text inside an empty input.
  final Color? placeholder;

  /// Icons the sheet draws itself, such as the stored-card row's delete glyph.
  ///
  /// Separate from [textSecondary], which stays a text colour, because a tint
  /// that reads well as a word can disappear as a 20-point symbol.
  final Color? icon;

  /// Error text, the error banner and an invalid field's border.
  final Color? error;

  /// This palette with the named roles replaced.
  ///
  /// Passing null for a role keeps the one already there rather than clearing
  /// it, which is the usual Flutter `copyWith` bargain: there is no way to
  /// spell "unset this". Build a fresh [PayCrossColors] to clear a role.
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

/// Corner radii and border thickness.
///
/// In the platform's own unit — density-independent pixels on Android, points
/// on iOS — and deliberately not converted between them. Neither is a pixel
/// count, and a merchant who sets 16 wants the same visual weight on both.
///
/// Null keeps the platform's value for that property.
class PayCrossShapes {
  const PayCrossShapes({
    this.cornerRadius,
    this.buttonCornerRadius,
    this.borderWidth,
  });

  /// The card inputs, the stored-card rows, the field groups and the error
  /// banner. Zero is a square corner, not "unset".
  final double? cornerRadius;

  /// The Pay button, and the wallet buttons' radius — the only property of an
  /// Apple Pay or Google Pay button this SDK will change, because their
  /// colours and labels are fixed by Apple's and Google's own guidelines.
  ///
  /// Falls back to [cornerRadius], then to the platform's own.
  final double? buttonCornerRadius;

  /// The thickness of the border around the card inputs.
  ///
  /// On Android this replaces Material's 1dp unfocused and 2dp focused
  /// thickness in both states. On iOS the inputs have no border at all until
  /// this is set, so setting it is what makes [PayCrossColors.componentBorder]
  /// visible.
  final double? borderWidth;

  g.PcShapes _toPigeon() => g.PcShapes(
    cornerRadius: cornerRadius,
    buttonCornerRadius: buttonCornerRadius,
    borderWidth: borderWidth,
  );
}

/// Overrides for the sheet's own Pay button.
///
/// The wallet buttons are not this button and are not affected: Apple and
/// Google specify their own colours and labels, and only their corner radius
/// is ours to set. See [PayCrossShapes.buttonCornerRadius].
class PayCrossPrimaryButton {
  const PayCrossPrimaryButton({
    this.background,
    this.textColor,
    this.disabledBackground,
    this.disabledTextColor,
    this.cornerRadius,
    this.height,
  });

  /// Falls back to [PayCrossColors.brand], then to the platform default.
  final Color? background;

  /// Falls back to [PayCrossColors.onBrand] — which is itself derived from
  /// whatever fill won when it is null — then to the platform default.
  final Color? textColor;

  /// The fill while the button cannot be pressed. Falls back to the platform's
  /// own disabled treatment of [background].
  final Color? disabledBackground;

  /// The label while the button cannot be pressed. See [disabledBackground].
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

/// Type sizing.
///
/// A font family is deliberately not exposed in this release: resolving one
/// differs enough between the two platforms that a single name would mean two
/// different fallbacks for the same string.
class PayCrossTypography {
  const PayCrossTypography({this.sizeScaleFactor});

  /// Multiplies every font size in the sheet.
  ///
  /// It composes with the device's own text-size setting rather than replacing
  /// it, so a shopper who has enlarged their type keeps the enlargement.
  ///
  /// Must be between 0.8 and 1.3 inclusive. Anything else — including zero, a
  /// negative, a NaN or an infinity — is a
  /// [PayCrossErrorCode.invalidAppearance] from `PayCross.configure`, thrown
  /// before the appearance reaches either native SDK.
  final double? sizeScaleFactor;

  g.PcTypography _toPigeon() =>
      g.PcTypography(sizeScaleFactor: sizeScaleFactor);
}

/// How the native payment sheet looks.
///
/// Roles, not per-element styling. The sheet's layout, the card inputs'
/// internals, the wallet buttons' colours and labels, the 3-D Secure page and
/// the error copy are fixed by design and no field here reaches them.
///
/// Every colour resolves per role: what is set here first, then the brand
/// colour the merchant set in the PayCross back office, then the platform
/// default. Passing no appearance at all is therefore not "no theming" — the
/// back-office colour still applies, and it needs no code.
///
/// ```dart
/// await PayCross.configure(
///   environment: PayCrossEnvironment.production,
///   appearance: const PayCrossAppearance(
///     light: PayCrossColors(brand: Color(0xFF1E88E5)),
///     dark: PayCrossColors(brand: Color(0xFF64B5F6)),
///     shapes: PayCrossShapes(cornerRadius: 16, buttonCornerRadius: 28),
///   ),
/// );
/// ```
class PayCrossAppearance {
  const PayCrossAppearance({
    this.light,
    this.dark,
    this.themeMode = PayCrossThemeMode.system,
    this.shapes,
    this.primaryButton,
    this.typography,
  });

  /// One brand colour in both modes, and platform defaults for everything
  /// else. The whole migration path off the deprecated `brandColorArgb`.
  factory PayCrossAppearance.brand(Color color) => PayCrossAppearance(
    light: PayCrossColors(brand: color),
    dark: PayCrossColors(brand: color),
  );

  /// The palette used while the sheet is in light mode.
  final PayCrossColors? light;

  /// The palette used while the sheet is in dark mode.
  ///
  /// Its own palette rather than a derivation of [light], because a brand
  /// colour that reads on white is often unreadable on near-black, and only
  /// the merchant knows what their dark-mode brand is. Leaving it null keeps
  /// the platform's dark palette, which is a working sheet rather than a
  /// guess.
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
  ///
  /// The question `PayCross.configure` asks before deciding what to do with a
  /// legacy `brandColorArgb` beside this appearance: an appearance with no
  /// opinion about the brand must not be what silently discards one.
  bool get hasBrand => light?.brand != null || dark?.brand != null;

  /// This appearance with the named fields replaced.
  ///
  /// Passing null for a field keeps the one already there rather than clearing
  /// it. See [PayCrossColors.copyWith].
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

/// Packs an appearance for the channel, refusing the values no sheet can draw.
///
/// Not part of the public API: this extension is deliberately absent from
/// `lib/paycross_flutter.dart`'s export list, because its return type is
/// generated code and a merchant must never be handed one.
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
      // Always written, never left to the generated code: Pigeon has no field
      // defaults, so "follow the device" is a default this side owns.
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

/// A radius, a thickness or a height must be a real, non-negative measurement.
///
/// Zero is legal for all of them — a square corner, no border, and a height
/// the platform decides — so only negatives and non-finite values are refused.
/// A native handed one of those draws nothing or fails a layout pass deep
/// inside the sheet, where the message names nothing a merchant can act on.
void _requireLength(String field, double? value) {
  if (value == null) return;
  if (value.isNaN || value.isInfinite || value < 0) {
    throw PayCrossIntegrationError(
      PayCrossErrorCode.invalidAppearance,
      '$field must be a finite, non-negative number; got $value.',
    );
  }
}
