import 'package:shared_preferences/shared_preferences.dart';

/// Where a minted session is presented to the person paying.
///
/// Two surfaces over one mint. Every tile builds the same body and sends it
/// through the same minter whichever of these is chosen -- the choice lands
/// after the session exists, on what happens to it next, which is what makes
/// the two comparable at all.
enum PaymentSurface {
  /// The native SDK sheet, in the app. What this demo has always done, and
  /// the default on every install.
  sdkSheet,

  /// The hosted checkout page, in the phone's own browser.
  ///
  /// It exists because the production checkout page is already approved for
  /// Google Pay and Apple Pay: a tester can exercise both wallets from the
  /// same demo session and the same identity today, and hold the result up
  /// against what the sheet does on the same merchant.
  webCheckout,
}

const String _surfaceKey = 'paycross_demo_payment_surface';

/// What a surface is called in a History row.
///
/// Short strings rather than the enum's own `name`, and pinned by a test: a
/// row written today is read by a build shipped months later, so these two
/// words are a stored format rather than an implementation detail. They are
/// also deliberately not the deep link's vocabulary -- `deeplink.dart` spells
/// its one surface `sheet` -- because a link's grammar and a stored row are
/// two things that happen to be about the same idea, and tying them together
/// would mean a link could never be renamed without rewriting history.
String surfaceName(PaymentSurface surface) => switch (surface) {
  PaymentSurface.sdkSheet => sdkSurfaceName,
  PaymentSurface.webCheckout => webSurfaceName,
};

/// The stored word for [PaymentSurface.sdkSheet].
const String sdkSurfaceName = 'sdk';

/// The stored word for [PaymentSurface.webCheckout].
const String webSurfaceName = 'web';

/// What [PaymentSurface.sdkSheet] is called on screen.
const String sdkSurfaceLabel = 'SDK sheet';

/// What [PaymentSurface.webCheckout] is called on screen.
const String webSurfaceLabel = 'Web checkout';

/// A surface's name as a human reads it.
///
/// Separate from [surfaceName], which is what a stored row holds: one of
/// these two may be reworded whenever the copy is improved, and the other
/// may never be. Named here rather than written at each site so the segment
/// somebody presses and the sentence that reports what they pressed cannot
/// call the same thing two different things.
String surfaceLabel(PaymentSurface surface) => switch (surface) {
  PaymentSurface.sdkSheet => sdkSurfaceLabel,
  PaymentSurface.webCheckout => webSurfaceLabel,
};

/// The surface a stored word names, or the sheet for anything else.
///
/// Unrecognised means the sheet rather than a throw, and null means it too.
/// The sheet is what this app did before the preference existed, so it is
/// the answer that cannot surprise anybody: a word from a build that knew
/// about a third surface must not turn into a browser launch here, and a
/// truncated write must not either.
PaymentSurface surfaceFromName(String? name) => switch (name) {
  webSurfaceName => PaymentSurface.webCheckout,
  _ => PaymentSurface.sdkSheet,
};

/// The slice of a key-value store this preference needs.
///
/// One interface, so the widget tests never reach a platform channel -- the
/// same shape `SecretBackend` and `HistoryBackend` have, and for the same
/// reason.
abstract interface class SurfaceBackend {
  Future<String?> read();
  Future<void> write(String value);
}

/// Plain `SharedPreferences`, beside History and not beside the credentials.
///
/// This is a display choice, not a secret: it says which of two screens a
/// session is presented on, and knowing it tells an attacker nothing they
/// could not learn by watching somebody use the app. `SecretStore` is for
/// the things that would matter -- the client id and secret -- and putting a
/// preference in there would make the secure store the place preferences
/// live, which is how a credential ends up somewhere it can be read.
class SharedPreferencesSurfaceBackend implements SurfaceBackend {
  const SharedPreferencesSurfaceBackend();

  @override
  Future<String?> read() async =>
      (await SharedPreferences.getInstance()).getString(_surfaceKey);

  @override
  Future<void> write(String value) async =>
      (await SharedPreferences.getInstance()).setString(_surfaceKey, value);
}

/// A [SurfaceBackend] in a field. Tests only.
class InMemorySurfaceBackend implements SurfaceBackend {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String written) async => value = written;
}

/// Which surface the tiles present on, across launches.
///
/// Read guarded and bounded, written bare, and those are two decisions
/// rather than an inconsistency. A read that cannot answer has a safe
/// default -- the sheet, which is what the app did before this existed -- so
/// swallowing the failure costs nothing anybody would notice. A write that
/// did not happen is a preference the next launch will not have, and the
/// only place that can say so is the screen the human pressed it on.
class SurfaceStore {
  const SurfaceStore({
    SurfaceBackend backend = const SharedPreferencesSurfaceBackend(),
  }) // The lint's own fix does not compile: Dart forbids a private NAMED
    // parameter, so `this._backend` cannot appear in a `{...}` list, and a
    // public backend is not what this class is for.
    // ignore: prefer_initializing_formals
    : _backend = backend;

  final SurfaceBackend _backend;

  /// The stored surface, or the sheet if there is not one to read.
  ///
  /// A wiped store, an unreadable one and one nobody has written are
  /// indistinguishable from here, and all three mean the same thing: the
  /// sheet. Under `flutter test` the real backend is the unreadable case,
  /// which is why a screen built with the default store still renders.
  ///
  /// **No deadline, deliberately**, unlike the credential read `home.dart`
  /// bounds. A timeout is only worth having where the wait blocks something,
  /// and this one blocks nothing: every screen that reads this already shows
  /// the sheet while it waits, because the sheet is what the app does when
  /// nobody has chosen. A store that never answers therefore costs exactly
  /// the default it would have cost after the deadline. What a deadline
  /// would cost is a real `Timer` armed on every build of every screen that
  /// reads a preference -- one that fires on nobody's phone and that every
  /// widget test then has to wind past.
  Future<PaymentSurface> read() async {
    try {
      return surfaceFromName(await _backend.read());
    } catch (_) {
      return PaymentSurface.sdkSheet;
    }
  }

  /// Stores [surface], and lets a failure escape.
  ///
  /// Both surfaces are written as a value; choosing the sheet again is not a
  /// delete. A key that goes missing reads as the sheet either way, but a
  /// stored word is what lets a later build tell "chose the sheet" from
  /// "never chose".
  Future<void> write(PaymentSurface surface) =>
      _backend.write(surfaceName(surface));
}
