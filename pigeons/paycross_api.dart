// Regenerate: dart run pigeon --input pigeons/paycross_api.dart && dart format lib/src/generated. Pin pigeon exactly.
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/generated/paycross_api.g.dart',
    dartPackageName: 'paycross_flutter',
    kotlinOut:
        'android/src/main/kotlin/com/paycross/flutter/generated/PayCrossApi.g.kt',
    kotlinOptions: KotlinOptions(package: 'com.paycross.flutter.generated'),
    swiftOut:
        'ios/paycross_flutter/Sources/paycross_flutter/generated/PayCrossApi.g.swift',
  ),
)
/// The backend the native SDK talks to.
///
/// There is no custom case: Android has no equivalent of iOS's custom base
/// URL, so one here would send the same call to different backends.
enum PcEnvironment { sandbox, production }

/// Prefills the native card form for manual test runs.
///
/// Carries a PAN and a CVV, the only card data that crosses this channel.
/// The native SDKs drop it outside the sandbox environment.
///
/// Shopper card data (CardData, CardFormState, BrowserInfo) never crosses.
class PcTestCardPrefill {
  PcTestCardPrefill({
    required this.cardholderName,
    required this.pan,
    required this.expireMonth,
    required this.expireYear,
    required this.cvv,
    required this.saveCard,
  });

  String cardholderName;
  String pan;

  /// "MM".
  String expireMonth;

  /// Four digits, e.g. "2028". Both natives use the last two.
  String expireYear;

  String cvv;
  bool saveCard;
}

/// Which palette the payment sheet draws with.
///
/// It applies to the sheet only, never to the host app.
enum PcThemeMode { system, light, dark }

/// One palette, used twice: once for light, once for dark.
///
/// Every role is a nullable packed ARGB int. Null means the platform default,
/// and 0x00000000 (transparent black) is a legal colour, not a sentinel.
class PcColors {
  PcColors({
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

  int? brand;

  /// Null derives the label colour from the brand's luminance on each native
  /// (the same 0.179 WCAG crossover on both). Dart does not compute it.
  int? onBrand;

  int? surface;
  int? component;
  int? componentBorder;
  int? text;
  int? textSecondary;
  int? placeholder;
  int? icon;
  int? error;
}

/// Corner radii and border thickness, in the platform's units: dp on Android,
/// points on iOS. Not converted between the two.
class PcShapes {
  PcShapes({this.cornerRadius, this.buttonCornerRadius, this.borderWidth});

  double? cornerRadius;
  double? buttonCornerRadius;
  double? borderWidth;
}

/// Pay button overrides. Each null falls back to the matching palette role.
class PcPrimaryButton {
  PcPrimaryButton({
    this.background,
    this.textColor,
    this.disabledBackground,
    this.disabledTextColor,
    this.cornerRadius,
    this.height,
  });

  int? background;
  int? textColor;
  int? disabledBackground;
  int? disabledTextColor;
  double? cornerRadius;
  double? height;
}

/// Type sizing. Font families are not sent: each platform resolves a name
/// differently, so one name would mean two fallbacks for the same string.
class PcTypography {
  PcTypography({this.sizeScaleFactor});

  /// Between 0.8 and 1.3. The Dart facade rejects values outside that range.
  double? sizeScaleFactor;
}

/// How the native payment sheet looks.
///
/// Colours resolve per role: the value set here, then the brand colour the
/// session carries, then the platform default. An absent appearance is not
/// "no theming".
class PcAppearance {
  PcAppearance({
    this.light,
    this.dark,
    required this.themeMode,
    this.shapes,
    this.primaryButton,
    this.typography,
  });

  PcColors? light;
  PcColors? dark;

  /// Required because Pigeon has no field defaults. A nullable mode would leave
  /// "follow the device" for each native to decide.
  PcThemeMode themeMode;

  PcShapes? shapes;
  PcPrimaryButton? primaryButton;
  PcTypography? typography;
}

class PcConfiguration {
  PcConfiguration({
    required this.environment,
    this.brandColorArgb,
    this.testCardPrefill,
    this.googlePayMerchantId,
    this.applePayMerchantId,
    this.appearance,
    this.locale,
  });

  PcEnvironment environment;

  /// Packed ARGB, sent unsigned. Null means "platform default" and must stay a
  /// real null: 0x00000000 is transparent black, a legal colour.
  ///
  /// Kotlin reads it as Long? and calls toInt(), which gives the signed
  /// @ColorInt Android needs.
  ///
  /// **Deprecated**, use [appearance]. The Dart facade sends this as null
  /// whenever an appearance is given.
  int? brandColorArgb;

  PcTestCardPrefill? testCardPrefill;

  /// Google Business Console merchant id for the Google Pay button the Android
  /// SDK renders when the session allows wallets. Android only: iOS accepts and
  /// ignores it.
  ///
  /// Google requires it for PRODUCTION requests; the TEST environment works
  /// without one. Null means "not configured".
  String? googlePayMerchantId;

  /// Apple Merchant ID for the Apple Pay button the iOS SDK renders when the
  /// session allows wallets. iOS only: Android accepts and ignores it.
  ///
  /// Apple hashes it into every payment token's key, so it must match the
  /// merchant id registered with Apple and in the app's Apple Pay entitlement.
  /// Null, empty and whitespace-only all mean "not configured".
  String? applePayMerchantId;

  /// How the payment sheet looks, on both platforms.
  PcAppearance? appearance;

  /// The language the payment sheet draws in, as a BCP 47 tag.
  ///
  /// Sent as written: Dart neither validates nor changes it. Each native
  /// resolves it through its own ladder (this override, the session's locale,
  /// the device, then English), and a tag neither SDK ships strings for is
  /// skipped. Null means not overridden.
  String? locale;
}

class PcVersionInfo {
  PcVersionInfo({required this.pluginVersion, this.nativeSdkVersion});

  String pluginVersion;

  /// Null on Android, which exposes no version constant.
  String? nativeSdkVersion;
}

/// A monetary amount in minor units.
///
/// Pigeon `int` maps to Kotlin Long and Swift Int64. Never use a double.
class PcAmount {
  PcAmount({required this.minorUnits, required this.currencyCode});

  int minorUnits;

  /// ISO 4217 currency code.
  String currencyCode;
}

/// How a payment ended.
///
/// An empty sealed parent with concrete subclasses: the only inheritance shape
/// Pigeon supports, in the Kotlin, Swift and Dart generators.
sealed class PcPaymentResult {}

class PcSuccess extends PcPaymentResult {
  PcSuccess({
    required this.transactionId,
    required this.status,
    required this.amount,
    this.savedCardToken,
  });

  /// Empty, not null, when the server returned no transaction reference.
  String transactionId;

  /// "success", "authorized", …
  String status;

  PcAmount amount;

  /// Token of the card this payment saved, when the session asked to save it.
  /// Null otherwise.
  String? savedCardToken;
}

class PcFailure extends PcPaymentResult {
  PcFailure({this.transactionId, required this.recovery});

  /// Null for failures that happen before a transaction exists.
  String? transactionId;

  /// The raw server token, not a parsed enum.
  ///
  /// Pigeon cannot express an enum with an associated value, and a closed enum
  /// would drop tokens the server adds later. An unknown token parses as
  /// "unrecognised, not retryable". Empty means the server sent nothing, which
  /// both SDKs read as retry.
  String recovery;
}

class PcCancelled extends PcPaymentResult {
  PcCancelled({this.transactionId});

  /// The last transaction this session created, or null when the sheet was
  /// dismissed before one existed.
  ///
  /// A cancel does not cancel the authorization: the shopper can leave after a
  /// decline or during a 3-D Secure challenge, and that transaction stays on
  /// the server.
  String? transactionId;
}

/// The outcome was never observed. The payment may have succeeded.
///
/// Neither a success nor a decline: a payment that completed looks the same as
/// one that never happened, so it is kept apart from [PcFailure].
class PcPending extends PcPaymentResult {
  PcPending({this.transactionId, required this.reason});

  /// The last transaction this session created, or null when the result was
  /// lost before one was known.
  String? transactionId;

  /// The raw wire name (`poll_timeout`, `result_lost`, `server_verify`), not a
  /// parsed enum.
  String reason;
}

@HostApi()
abstract class PayCrossHostApi {
  /// Applies configuration to the native SDK.
  ///
  /// Re-applied lazily inside presentPayment, because a hot restart or a second
  /// add-to-app engine can lose the Dart-side flag while the native process
  /// keeps running, and iOS then hits assertionFailure.
  void configure(PcConfiguration configuration);

  PcVersionInfo versionInfo();

  /// Presents the native payment UI, resolving when the payment reaches a
  /// terminal state or the shopper cancels. Declines arrive as PcFailure, not
  /// as errors: an error from this method means an integration mistake.
  ///
  /// Can take minutes (the poll deadline is 480s on both platforms). Do not
  /// wrap the returned Future in Future.timeout: a shorter timeout orphans a
  /// live payment that may still charge the card.
  @async
  PcPaymentResult presentPayment(String sessionToken);
}
