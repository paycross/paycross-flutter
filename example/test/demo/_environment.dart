import 'package:flutter/material.dart';
import 'package:paycross_demo/demo/environment.dart';
import 'package:paycross_flutter/paycross_flutter.dart';

DemoEnvironmentState fakeEnvironment({
  String? googlePayMerchantId,
  String? applePayMerchantId,
  String? locale,
}) => DemoEnvironmentState(
  configure:
      ({
        required PayCrossEnvironment environment,
        String? googlePayMerchantId,
        String? applePayMerchantId,
        PayCrossAppearance? appearance,
        String? locale,
      }) async {},
  googlePayMerchantId: googlePayMerchantId,
  applePayMerchantId: applePayMerchantId,
  locale: locale,
);

MaterialApp appWithEnvironment({
  required Widget home,
  required DemoEnvironmentState state,
}) => MaterialApp(
  builder: (context, child) => LiveModeScope(state: state, child: child!),
  home: home,
);

Future<MaterialApp> liveApp({
  required Widget home,
  DemoEnvironmentState? state,
}) async {
  final live = state ?? fakeEnvironment();
  await live.enterLive(liveConfirmationWord);
  return appWithEnvironment(home: home, state: live);
}
