import 'package:flutter/material.dart';
import 'package:paycross_demo/demo/environment.dart';
import 'package:paycross_flutter/paycross_flutter.dart';

/// A [DemoEnvironmentState] that reaches no platform channel.
///
/// `PayCross.configure` goes to a Pigeon host API that `flutter test` has
/// nothing behind, so every state in a widget test takes this instead.
DemoEnvironmentState fakeEnvironment({
  String? googlePayMerchantId,
  String? applePayMerchantId,
}) => DemoEnvironmentState(
  configure:
      ({
        required PayCrossEnvironment environment,
        String? googlePayMerchantId,
        String? applePayMerchantId,
      }) async {},
  googlePayMerchantId: googlePayMerchantId,
  applePayMerchantId: applePayMerchantId,
);

/// A [MaterialApp] with the environment mounted where the app mounts it:
/// in `builder`, which wraps the Navigator, so a route pushed later reads
/// the same state and carries the same banner.
///
/// Mounting it in `home:` instead would put it beside every pushed route
/// rather than above them, and a test that did so would pass while the app
/// it stands for showed no banner on Settings.
MaterialApp appWithEnvironment({
  required Widget home,
  required DemoEnvironmentState state,
}) => MaterialApp(
  builder: (context, child) => LiveModeScope(state: state, child: child!),
  home: home,
);

/// The same, already switched to Live.
Future<MaterialApp> liveApp({
  required Widget home,
  DemoEnvironmentState? state,
}) async {
  final live = state ?? fakeEnvironment();
  await live.enterLive(liveConfirmationWord);
  return appWithEnvironment(home: home, state: live);
}
