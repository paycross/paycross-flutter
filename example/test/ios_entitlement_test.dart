import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/wallets.dart';

void main() {
  late String project;
  late String entitlements;

  setUpAll(() {
    project = File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    entitlements = File('ios/Runner/Runner.entitlements').readAsStringSync();
  });

  test('exactly the three Runner configurations sign with it', () {
    expect(
      RegExp(
        r'CODE_SIGN_ENTITLEMENTS = Runner/Runner\.entitlements;',
      ).allMatches(project).length,
      3,
    );
  });

  test('the entitlement is a file Xcode can see', () {
    expect(
      RegExp(
        r'/\* Runner\.entitlements \*/ = \{isa = PBXFileReference',
      ).allMatches(project).length,
      1,
    );
    expect(project, contains('/* Runner.entitlements */,'));
  });

  test('it grants the group by build setting, not by literal id', () {
    expect(entitlements, contains('keychain-access-groups'));
    expect(
      entitlements,
      contains(r'$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)'),
    );
  });

  test('the Apple Pay entitlement is present', () {
    expect(entitlements, contains('com.apple.developer.in-app-payments'));
  });

  test('it names both merchant identifiers the app is configured with', () {
    expect(entitlements, contains('<string>$testApplePayMerchantId</string>'));
    expect(entitlements, contains('<string>$liveApplePayMerchantId</string>'));
  });

  test('the entitlement is an array holding both', () {
    final section = entitlements.split(
      'com.apple.developer.in-app-payments',
    )[1];

    expect(section.trimLeft(), startsWith('</key>'));
    expect(section, contains('<array>'));
    expect('<string>'.allMatches(section.split('</array>')[0]).length, 2);
  });
}
