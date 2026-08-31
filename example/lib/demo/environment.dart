import 'package:flutter/material.dart';
import 'package:paycross_flutter/paycross_flutter.dart';

import 'endpoints.dart';
import 'secrets.dart';

/// Which backend the app is pointed at right now.
///
/// Never persisted. The value lives in one object built at launch, so
/// "every cold start begins in Test" is a property of the construction
/// rather than a rule somebody has to remember to apply.
enum DemoEnvironment { test, live }

/// The word that has to be typed to leave Test.
///
/// Typed, not flicked and not tapped through: a switch can be brushed in a
/// pocket and a dialog can be dismissed by muscle memory, and what is on
/// the other side of this one spends money.
const String liveConfirmationWord = 'LIVE';

/// Points the native SDK at an environment. Injected so a widget test never
/// reaches a platform channel.
typedef ConfigureSdk =
    Future<void> Function({
      required PayCrossEnvironment environment,
      String? googlePayMerchantId,
    });

/// The real one.
Future<void> configurePayCross({
  required PayCrossEnvironment environment,
  String? googlePayMerchantId,
}) => PayCross.configure(
  environment: environment,
  googlePayMerchantId: googlePayMerchantId,
);

/// Which environment the app is in, and the Live credentials while it is
/// there.
///
/// One object, held above the Navigator, so Settings, Home, History and a
/// Run screen cannot disagree about where a payment is going.
///
/// The Live credentials are a plain field and that is the whole storage
/// design: they are never written to the secure store, to
/// `SharedPreferences`, to History or to a bug report, so process death
/// forgets them and leaving Live drops them. `secrets.dart` is untouched by
/// this class on purpose -- code that cannot reach the store cannot write
/// to it by mistake.
class DemoEnvironmentState extends ChangeNotifier {
  DemoEnvironmentState({
    this.configure = configurePayCross,
    this.googlePayMerchantId,
  });

  final ConfigureSdk configure;

  /// What `main` configured the SDK with at launch, kept so that returning
  /// to Test restores it. Re-pointing the SDK replaces the whole
  /// configuration, so a merchant id left out of the way back is a Google
  /// Pay button that stops appearing until the app is relaunched.
  final String? googlePayMerchantId;

  DemoEnvironment _environment = DemoEnvironment.test;
  DemoEnvironment get environment => _environment;
  bool get isLive => _environment == DemoEnvironment.live;

  Credentials? _liveCredentials;
  Credentials? get liveCredentials => _liveCredentials;

  /// The pair a mint in this environment must use.
  ///
  /// Derived rather than stored, so the URLs a run reaches cannot drift
  /// from the environment the banner is rendering.
  Endpoints get endpoints => isLive ? liveEndpoints : testEndpoints;

  /// Switches to Live, or returns why it did not.
  ///
  /// The SDK is re-pointed first and the state flips only if that call
  /// comes back: a banner that says LIVE over an SDK still on sandbox is a
  /// lie, and it is the kind that ends with somebody trusting a green
  /// result that never touched production.
  Future<String?> enterLive(String typed) async {
    if (typed.trim() != liveConfirmationWord) {
      return 'Type $liveConfirmationWord exactly to switch to production.';
    }
    try {
      await configure(
        environment: PayCrossEnvironment.production,
        // Null on purpose: Live has no Google Pay tile for a wallet id to
        // serve, and the id is configuration for one wallet on one
        // merchant.
        googlePayMerchantId: null,
      );
    } catch (problem) {
      // Only the type. A platform exception's message is the one thing on
      // this path that came from outside the app.
      return 'The SDK would not switch to production: ${problem.runtimeType}';
    }
    _environment = DemoEnvironment.live;
    notifyListeners();
    return null;
  }

  /// Holds a production credential for this session and no longer.
  ///
  /// A no-op outside Live rather than a throw: this is reachable only from
  /// a button that exists only in Live, so a Test-mode call would be a
  /// programming mistake, and the safe behaviour for one is to hold
  /// nothing. A Test credential belongs in the secure store, where the
  /// human can see it and forget it.
  void useForThisSession(Credentials credentials) {
    if (!isLive) return;
    _liveCredentials = Credentials(
      clientId: credentials.clientId,
      clientSecret: credentials.clientSecret,
      // Rebuilt rather than kept, so a merchant id typed in Test cannot
      // ride into Live on a copied object.
      googlePayMerchantId: null,
    );
    notifyListeners();
  }

  /// Returns to Test, or returns why it did not.
  ///
  /// The credentials go first and unconditionally -- they are the human's
  /// to revoke the moment they ask, whatever the SDK says next. The
  /// environment flips only on proof, for the same reason [enterLive]
  /// flips only on proof.
  Future<String?> leaveLive() async {
    _liveCredentials = null;
    try {
      await configure(
        environment: PayCrossEnvironment.sandbox,
        googlePayMerchantId: googlePayMerchantId,
      );
    } catch (problem) {
      notifyListeners();
      return 'The credentials are forgotten, but the SDK would not switch '
          'back: ${problem.runtimeType}. Still in Live — restart the app.';
    }
    _environment = DemoEnvironment.test;
    notifyListeners();
    return null;
  }
}
