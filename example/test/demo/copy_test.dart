import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const List<String> retiredPromises = <String>[
  'no way to reach production',
  'no production switch',
  'no environment switch',
  'no production endpoints',
  'Sandbox only',
];

const String cheatSheet = 'lib/demo/test_cards_screen.dart';

const List<String> retiredIdentityMachinery = <String>[
  'liveSmokeIdentity',
  'REPLACE_ME',
  'is still a placeholder',
];

const List<String> retiredAmountMachinery = <String>[
  'four places',
  'four edits',
];

const List<String> retiredFixedAmountClaims = <String>[
  'The amount is fixed',
  'no editor anywhere near it',
  'liveSmokeAmountLabel',
  'pick the currency',
  'currency you picked',
];

const List<String> retiredSingleTileClaims = <String>[
  'no saved cards',
  'no saved-card scenarios',
  'Nothing but the smoke',
  'Home shows one tile',
  'shows one tile',
  'The tile below',
];

const List<String> retiredNativeWalletClaims = <String>[
  'not yet approved in the native sheet',
  'the only way to exercise either one',
  'no wallets in the sheet',
];

void main() {
  test('the tester guide makes no promise the app no longer keeps', () {
    final readme = File('README.md').readAsStringSync();

    for (final promise in retiredPromises) {
      expect(
        readme.contains(promise),
        isFalse,
        reason:
            '"$promise" is in example/README.md, and this build has a '
            'production switch. Describe Live mode instead.',
      );
    }
  });

  test('no screen in the app makes one either', () {
    final offenders = <String>[];
    var exempted = 0;
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.endsWith(cheatSheet)) {
        exempted++;
        continue;
      }
      final source = entity.readAsStringSync();
      if (retiredPromises.any(source.contains)) offenders.add(entity.path);
    }

    expect(offenders, isEmpty);
    expect(exempted, 1);
  });

  test('the exempt file is still the one the exemption was written for', () {
    final source = File(cheatSheet).readAsStringSync();

    expect(source, contains('Sandbox only'));
    expect(source, contains('testCardExpiry'));
  });

  test('the guide describes Live mode where a tester will look', () {
    final readme = File('README.md').readAsStringSync();

    expect(readme, contains('\n## Live mode\n'));
    expect(readme, contains('Type `LIVE`'));
    expect(readme, contains('held in memory'));
    expect(readme, contains('\n### Afterwards — refund it\n'));
    expect(readme, contains('starts in Test on every launch'));
    expect(readme, contains('\n### The credentials and the identity\n'));
    expect(readme, contains('a first and a last name'));
    expect(readme, contains('about the identity is saved'));
    expect(readme, contains('The currency is not picked here'));
    expect(readme, contains('The identity never goes into a preset'));
  });

  test('nothing still says Live offers a single tile', () {
    final readme = File('README.md').readAsStringSync();
    final offenders = <String>[];
    var scanned = 0;
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      scanned++;
      final source = entity.readAsStringSync();
      if (retiredSingleTileClaims.any(source.contains)) {
        offenders.add(entity.path);
      }
    }

    expect(offenders, isEmpty);
    for (final gone in retiredSingleTileClaims) {
      expect(readme.contains(gone), isFalse, reason: gone);
    }
    expect(scanned, greaterThan(10));
  });

  test('nothing still says the native sheet has no Apple Pay', () {
    final readme = File('README.md').readAsStringSync();
    final offenders = <String>[];
    var scanned = 0;
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      scanned++;
      final source = entity.readAsStringSync();
      if (retiredNativeWalletClaims.any(source.contains)) {
        offenders.add(entity.path);
      }
    }

    expect(offenders, isEmpty);
    for (final gone in retiredNativeWalletClaims) {
      expect(readme.contains(gone), isFalse, reason: gone);
    }
    expect(scanned, greaterThan(10));
  });

  test('the guide describes all three tiles, and the order of two', () {
    final readme = File('README.md').readAsStringSync();

    expect(readme, contains('\n### Running the tiles\n'));
    expect(readme, contains('Home shows three tiles'));
    expect(readme, contains('store card** first'));
    expect(readme, contains('three charges'));
  });

  test('nothing tells anyone to spell the amount out four times', () {
    final readme = File('README.md').readAsStringSync();
    final offenders = <String>[];
    var scanned = 0;
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      scanned++;
      final source = entity.readAsStringSync();
      if (retiredAmountMachinery.any(source.contains)) {
        offenders.add(entity.path);
      }
    }

    expect(offenders, isEmpty);
    for (final gone in retiredAmountMachinery) {
      expect(readme.contains(gone), isFalse, reason: gone);
    }
    expect(readme, contains('liveBodyAmountLabel'));
    expect(scanned, greaterThan(10));
  });

  test('nothing says a Live amount is fixed, or asks for a currency', () {
    final readme = File('README.md').readAsStringSync();
    final offenders = <String>[];
    var scanned = 0;
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      scanned++;
      final source = entity.readAsStringSync();
      if (retiredFixedAmountClaims.any(source.contains)) {
        offenders.add(entity.path);
      }
    }

    expect(offenders, isEmpty);
    for (final gone in retiredFixedAmountClaims) {
      expect(readme.contains(gone), isFalse, reason: gone);
    }
    expect(readme, contains('\n## Saving a preset\n'));
    expect(readme, contains('Changing an amount is an edit on the phone'));
    expect(readme, contains('neither mode ever offers a body'));
    expect(scanned, greaterThan(10));
  });

  test('nothing sends the reader to a constant that no longer exists', () {
    final readme = File('README.md').readAsStringSync();
    final offenders = <String>[];
    var scanned = 0;
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      scanned++;
      final source = entity.readAsStringSync();
      if (retiredIdentityMachinery.any(source.contains)) {
        offenders.add(entity.path);
      }
    }

    expect(offenders, isEmpty);
    for (final gone in retiredIdentityMachinery) {
      expect(readme.contains(gone), isFalse, reason: gone);
    }
    expect(scanned, greaterThan(10));
  });
}
