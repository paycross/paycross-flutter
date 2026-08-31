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

/// What a switch answers when another one has not finished yet.
///
/// An ordinary refusal string rather than an exception, so every caller
/// renders it the same way it renders the wrong-word message.
const String switchAlreadyInProgress = 'A switch is already in progress.';

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

  /// True while a switch is waiting on the SDK.
  ///
  /// One switch at a time. Two overlapping calls each re-point the SDK and
  /// each assign the environment, and nothing makes the last configure to
  /// land and the last assignment to land the same call -- so the banner
  /// ends up describing an environment the SDK is not in.
  ///
  /// There is no timeout on this, and that is a decision rather than an
  /// omission. A `configure` that never comes back leaves both switches
  /// refusing until the app is relaunched, which is the accepted trade: this
  /// is a tool a few people reach for a few times, relaunching is cheap, and
  /// a timeout would have to guess when the SDK has really given up. Guessing
  /// that wrong puts a second configure in flight beside the first, which is
  /// exactly the disagreement this flag exists to prevent.
  bool _switching = false;

  DemoEnvironment _environment = DemoEnvironment.test;
  DemoEnvironment get environment => _environment;
  bool get isLive => _environment == DemoEnvironment.live;

  Credentials? _liveCredentials;

  /// The production credentials, and only while the app is actually in Live.
  ///
  /// Gated on the environment rather than returning the field, because the
  /// field and the environment change at different moments: [leaveLive]
  /// awaits the SDK between dropping one and flipping the other, and
  /// [useForThisSession] is reachable from a button across that await. The
  /// gate makes "Test never has production credentials" true of every path
  /// through this class, including ones nobody has written yet.
  Credentials? get liveCredentials => isLive ? _liveCredentials : null;

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
    if (_switching) return switchAlreadyInProgress;
    if (typed.trim() != liveConfirmationWord) {
      return 'Type $liveConfirmationWord exactly to switch to production.';
    }
    _switching = true;
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
    } finally {
      _switching = false;
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
  /// On every exit this actually performs, the credentials go first: they
  /// are the human's to revoke the moment they ask, whatever the SDK says
  /// next. An exit refused at the door -- because another switch is already
  /// in flight -- returns before touching them, which is the point of
  /// refusing at the door: it performed nothing, so it forgets nothing.
  ///
  /// The environment flips only on proof, for the same reason [enterLive]
  /// flips only on proof.
  Future<String?> leaveLive() async {
    // Before the credentials are touched: a refused exit must not be an exit
    // that forgot them anyway.
    if (_switching) return switchAlreadyInProgress;
    _liveCredentials = null;
    _switching = true;
    try {
      await configure(
        environment: PayCrossEnvironment.sandbox,
        googlePayMerchantId: googlePayMerchantId,
      );
    } catch (problem) {
      // The same second drop the success path makes below, and for the same
      // reason: the app was in Live across that await, so a button could
      // have armed a fresh credential in the window. This path stays in
      // Live, so the getter's gate would not hide one -- and the message
      // returned here promises they are gone. Before the notify, so a
      // listener reading during it sees that promise already kept.
      _liveCredentials = null;
      notifyListeners();
      return 'The credentials are forgotten, but the SDK would not switch '
          'back: ${problem.runtimeType}. Still in Live — restart the app.';
    } finally {
      _switching = false;
    }
    // Again, and this is not the same drop as the one above. The app was
    // still in Live across that await, so a button could have armed a fresh
    // production credential in the window. Dropping the reference is what
    // stops it being handed back the next time Live is entered; the getter
    // only stops it being read in Test.
    _liveCredentials = null;
    _environment = DemoEnvironment.test;
    notifyListeners();
    return null;
  }
}

/// The colour of the banner, and of every Live marking that echoes it.
///
/// Material's own error red rather than a theme colour: the banner is
/// outside every `Scaffold` and has to read the same in the light theme and
/// the dark one, and "this is the dangerous mode" is not a brand decision.
const Color liveRed = Color(0xFFB3261E);

/// Publishes [DemoEnvironmentState] to the whole app and paints the LIVE
/// banner over every route.
///
/// Mounted from `MaterialApp.builder`, which wraps the **Navigator**: a
/// route pushed later is a descendant, so Settings, History and a Run
/// screen all read one environment and all sit under one banner. A scope
/// mounted inside `home:` would be a sibling of every pushed route and
/// invisible to all of them.
///
/// Not mounted at all under the automation define -- `main.dart` passes no
/// builder there -- so the frozen build has no toggle in it rather than a
/// toggle that is switched off.
class LiveModeScope extends StatefulWidget {
  const LiveModeScope({
    super.key,
    required this.child,
    this.state,
    this.googlePayMerchantId,
  });

  final Widget child;

  /// Injected by tests. Null means this widget owns one.
  final DemoEnvironmentState? state;

  /// Passed on to a state this widget builds itself, so returning to Test
  /// restores what `main` configured at launch.
  final String? googlePayMerchantId;

  /// The state above [context], or null where there is none.
  ///
  /// Subscribes: a widget that calls this rebuilds when the environment or
  /// the held credentials change.
  static DemoEnvironmentState? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_EnvironmentScope>()?.state;

  /// The state above [context] without subscribing to it.
  ///
  /// For a callback that runs outside `build` -- the deep-link stream is
  /// the one that matters -- where registering a dependency would be a
  /// rebuild nobody asked for.
  static DemoEnvironmentState? readOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_EnvironmentScope>()?.state;

  /// The environment above [context], or Test where there is no scope.
  ///
  /// Absent-means-Test is what keeps every widget test written before Live
  /// mode existed meaning exactly what it meant, and it is also what the
  /// automation build gets.
  static DemoEnvironment environmentOf(BuildContext context) =>
      maybeOf(context)?.environment ?? DemoEnvironment.test;

  @override
  State<LiveModeScope> createState() => _LiveModeScopeState();
}

class _LiveModeScopeState extends State<LiveModeScope> {
  /// The state this widget made, or null when one was passed in.
  ///
  /// Non-null exactly when there is something to dispose, which is what
  /// [dispose] below reads it for.
  DemoEnvironmentState? _own;

  @override
  void initState() {
    super.initState();
    // Here rather than lazily in `build`, so that building this widget is
    // not what brings its state into existence. Nothing depended on the
    // laziness -- `build` runs immediately after this -- and a `build` with
    // no side effects is one that can be called twice safely.
    if (widget.state == null) {
      _own = DemoEnvironmentState(
        googlePayMerchantId: widget.googlePayMerchantId,
      );
    }
  }

  DemoEnvironmentState get _state => widget.state ?? _own!;

  @override
  void didUpdateWidget(LiveModeScope old) {
    super.didUpdateWidget(old);
    // Whether a scope owns its state is decided once, in initState, so a
    // rebuild that changes the answer would find `_own` null and read as a
    // null-check failure somewhere in `build` rather than as the misuse it
    // is. Nothing in the app does this -- `main` never passes a state -- but
    // a suite that pumps a scope both ways at one position would.
    assert(
      (widget.state == null) == (old.state == null),
      'Whether a scope owns its state is fixed for its lifetime.',
    );
  }

  @override
  void dispose() {
    // Only the one this widget made. A state that was passed in belongs to
    // whoever passed it, and disposing it here would take it out from under
    // a test that is still asserting on it.
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _EnvironmentScope(
    state: _state,
    child: _LiveFrame(child: widget.child),
  );
}

class _EnvironmentScope extends InheritedNotifier<DemoEnvironmentState> {
  const _EnvironmentScope({
    required DemoEnvironmentState state,
    required super.child,
  }) : super(notifier: state);

  DemoEnvironmentState get state => notifier!;
}

/// The red bar, and nothing at all in Test.
class _LiveFrame extends StatelessWidget {
  const _LiveFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!(LiveModeScope.maybeOf(context)?.isLive ?? false)) return child;
    return Column(
      children: [
        const Material(
          // Its own Material: this is above every Scaffold, so there is no
          // ancestor to take a colour or a text style from.
          color: liveRed,
          child: SafeArea(
            bottom: false,
            child: SizedBox(
              width: double.infinity,
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 10, horizontal: 16),
                child: Text(
                  'LIVE — REAL MONEY',
                  key: ValueKey('liveBanner'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5,
                  ),
                ),
              ),
            ),
          ),
        ),
        // The banner has already taken the status-bar inset. Without this
        // the Scaffold below takes it a second time and leaves a visible
        // double gap under the bar on a real phone.
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: child,
          ),
        ),
      ],
    );
  }
}
