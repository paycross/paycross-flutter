import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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
}
