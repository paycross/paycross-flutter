import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/home.dart';
import 'package:paycross_demo/demo/settings.dart';

void main() {
  testWidgets('says the app is sandbox-only', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));

    expect(find.textContaining('Sandbox only'), findsOneWidget);
  });

  testWidgets('the gear opens Settings', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('Settings opens with no platform under it and never throws', (
    tester,
  ) async {
    // The default SettingsScreen reads the real secure store, which under
    // `flutter test` has no platform behind it. That read is guarded, so the
    // screen builds empty instead of throwing -- this is the "a null or
    // failed read means not configured" rule exercised against a genuinely
    // absent platform rather than against a fake that stands in for one.
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('clientId')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('clientId')))
          .controller!
          .text,
      isEmpty,
    );
    // The version read does not fail here, it never answers: the channel has
    // no handler and its future stays pending, so the panel holds its
    // pending row. That is the panel's own tested behaviour, and it is why
    // this asserts the pending row rather than 'unknown'.
    expect(find.text('Demo …'), findsOneWidget);
  });
}
