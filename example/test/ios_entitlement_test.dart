import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/wallets.dart';

/// The Keychain entitlement is three separate things in two files, and only
/// one of them fails loudly.
///
/// A missing build setting fails at signing time; a missing file reference
/// fails at nobody, it just leaves the file invisible in Xcode's navigator so
/// the next person edits a file they cannot find. None of it is reachable
/// from `flutter test` on Linux, so this reads the project the way the
/// contract-invariant check reads `lib/`.
void main() {
  late String project;
  late String entitlements;

  setUpAll(() {
    project = File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    entitlements = File('ios/Runner/Runner.entitlements').readAsStringSync();
  });

  test('exactly the three Runner configurations sign with it', () {
    // Debug, Release and Profile of the Runner app target. The three
    // RunnerTests configurations must not have it: the test bundle has no
    // Keychain group of its own, and signing it with the app's would fail.
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
    // Task 6 renames the bundle id. Written this way that rename is a no-op
    // here; written literally it would leave the app asking for a Keychain
    // group it no longer owns, and every read would throw on device.
    expect(
      entitlements,
      contains(r'$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)'),
    );
  });

  test('the Apple Pay entitlement is present', () {
    expect(entitlements, contains('com.apple.developer.in-app-payments'));
  });

  test('it names both merchant identifiers the app is configured with', () {
    // Both environments' identifiers, and each has to be identical in four
    // places: here, in the Apple Developer portal, on that environment's
    // merchant record, and in the Dart constant the SDK is configured with.
    // Reading them from the constants is what makes this a comparison rather
    // than a third copy.
    //
    // PassKit refuses to present a sheet for a merchant identifier the app's
    // entitlement does not list, and it refuses silently -- the button is
    // there and nothing happens. Missing the production string here is
    // therefore a bug that only appears on production, on a device, in front
    // of the tester.
    expect(entitlements, contains('<string>$testApplePayMerchantId</string>'));
    expect(entitlements, contains('<string>$liveApplePayMerchantId</string>'));
  });

  test('the entitlement is an array holding both', () {
    // An array, not a string, and both entries live in it. A scalar value
    // could hold only one environment, and the file would still be valid
    // plist with the production identifier quietly missing.
    final section = entitlements.split(
      'com.apple.developer.in-app-payments',
    )[1];

    expect(section.trimLeft(), startsWith('</key>'));
    expect(section, contains('<array>'));
    expect('<string>'.allMatches(section.split('</array>')[0]).length, 2);
  });
}
