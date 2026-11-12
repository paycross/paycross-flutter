import 'package:flutter/material.dart';
import 'package:paycross_flutter/paycross_flutter.dart';

import 'endpoints.dart';
import 'live.dart';
import 'secrets.dart';
import 'wallets.dart';

enum DemoEnvironment { test, live }

const String liveConfirmationWord = 'LIVE';

const String switchAlreadyInProgress = 'A switch is already in progress.';

typedef ConfigureSdk =
    Future<void> Function({
      required PayCrossEnvironment environment,
      String? googlePayMerchantId,
      String? applePayMerchantId,
      PayCrossAppearance? appearance,
      String? locale,
    });

Future<void> configurePayCross({
  required PayCrossEnvironment environment,
  String? googlePayMerchantId,
  String? applePayMerchantId,
  PayCrossAppearance? appearance,
  String? locale,
}) => PayCross.configure(
  environment: environment,
  googlePayMerchantId: googlePayMerchantId,
  applePayMerchantId: applePayMerchantId,
  appearance: appearance,
  locale: locale,
);

/// Live credentials are a plain field, never persisted. Process death forgets them; leaving Live drops them.
class DemoEnvironmentState extends ChangeNotifier {
  DemoEnvironmentState({
    this.configure = configurePayCross,
    this.googlePayMerchantId,
    this.applePayMerchantId,
    this.locale,
    this.appearance,
  });

  final ConfigureSdk configure;

  final String? googlePayMerchantId;

  final String? applePayMerchantId;

  final String? locale;

  final PayCrossAppearance? appearance;

  bool _switching = false;

  DemoEnvironment _environment = DemoEnvironment.test;
  DemoEnvironment get environment => _environment;
  bool get isLive => _environment == DemoEnvironment.live;

  Credentials? _liveCredentials;

  Credentials? get liveCredentials => isLive ? _liveCredentials : null;

  LiveIdentity? _liveIdentity;

  LiveIdentity? get liveIdentity => isLive ? _liveIdentity : null;

  Endpoints get endpoints => isLive ? liveEndpoints : testEndpoints;

  Future<String?> enterLive(String typed) async {
    if (_switching) return switchAlreadyInProgress;
    if (typed.trim() != liveConfirmationWord) {
      return 'Type $liveConfirmationWord exactly to switch to production.';
    }
    _switching = true;
    try {
      await configure(
        environment: PayCrossEnvironment.production,
        googlePayMerchantId: walletIdOrNull(liveGooglePayMerchantId),
        applePayMerchantId: walletIdOrNull(liveApplePayMerchantId),
        locale: locale,
      );
    } catch (problem) {
      return 'The SDK would not switch to production: ${problem.runtimeType}';
    } finally {
      _switching = false;
    }
    _environment = DemoEnvironment.live;
    notifyListeners();
    return null;
  }

  void useForThisSession(Credentials credentials) {
    if (!isLive) return;
    _liveCredentials = Credentials(
      clientId: credentials.clientId,
      clientSecret: credentials.clientSecret,
      googlePayMerchantId: null,
    );
    notifyListeners();
  }

  void useIdentityForThisSession(LiveIdentity identity) {
    if (!isLive) return;
    _liveIdentity = identity;
    notifyListeners();
  }

  Future<void> applyTestAppearance(PayCrossAppearance? forThisRun) => configure(
    environment: PayCrossEnvironment.sandbox,
    googlePayMerchantId: googlePayMerchantId,
    applePayMerchantId: applePayMerchantId,
    appearance: forThisRun ?? appearance,
    locale: locale,
  );

  Future<String?> leaveLive() async {
    if (_switching) return switchAlreadyInProgress;
    _liveCredentials = null;
    _liveIdentity = null;
    _switching = true;
    try {
      await configure(
        environment: PayCrossEnvironment.sandbox,
        googlePayMerchantId: googlePayMerchantId,
        applePayMerchantId: applePayMerchantId,
        locale: locale,
        appearance: appearance,
      );
    } catch (problem) {
      _liveCredentials = null;
      _liveIdentity = null;
      notifyListeners();
      return 'The credentials are forgotten, but the SDK would not switch '
          'back: ${problem.runtimeType}. Still in Live — restart the app.';
    } finally {
      _switching = false;
    }
    _liveCredentials = null;
    _liveIdentity = null;
    _environment = DemoEnvironment.test;
    notifyListeners();
    return null;
  }
}

const Color liveRed = Color(0xFFB3261E);

class LiveModeScope extends StatefulWidget {
  const LiveModeScope({
    super.key,
    required this.child,
    this.state,
    this.googlePayMerchantId,
    this.applePayMerchantId,
    this.locale,
    this.appearance,
  });

  final Widget child;

  final DemoEnvironmentState? state;

  final String? googlePayMerchantId;

  final String? applePayMerchantId;

  final String? locale;

  final PayCrossAppearance? appearance;

  static DemoEnvironmentState? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_EnvironmentScope>()?.state;

  static DemoEnvironmentState? readOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_EnvironmentScope>()?.state;

  static DemoEnvironment environmentOf(BuildContext context) =>
      maybeOf(context)?.environment ?? DemoEnvironment.test;

  @override
  State<LiveModeScope> createState() => _LiveModeScopeState();
}

class _LiveModeScopeState extends State<LiveModeScope> {
  DemoEnvironmentState? _own;

  @override
  void initState() {
    super.initState();
    if (widget.state == null) {
      _own = DemoEnvironmentState(
        googlePayMerchantId: widget.googlePayMerchantId,
        applePayMerchantId: widget.applePayMerchantId,
        locale: widget.locale,
        appearance: widget.appearance,
      );
    }
  }

  DemoEnvironmentState get _state => widget.state ?? _own!;

  @override
  void didUpdateWidget(LiveModeScope old) {
    super.didUpdateWidget(old);
    assert(
      (widget.state == null) == (old.state == null),
      'Whether a scope owns its state is fixed for its lifetime.',
    );
  }

  @override
  void dispose() {
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

class _LiveFrame extends StatelessWidget {
  const _LiveFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!(LiveModeScope.maybeOf(context)?.isLive ?? false)) return child;
    return Column(
      children: [
        const Material(
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
