import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Claims this app made when it could not reach production, and cannot make
/// any more.
///
/// A string check rather than a review note, because a promise that quietly
/// stops being true is the exact failure this whole plan is careful about:
/// the app got a production switch, and a tester reading a document that
/// says it has none is a tester who will not think to check which
/// environment they are in.
const List<String> retiredPromises = <String>[
  'no way to reach production',
  'no production switch',
  'no environment switch',
  'Sandbox only',
];

/// The one file allowed to say "Sandbox only", because there it is true.
///
/// The test-card cheat sheet lists seven sandbox PANs, and the sentence
/// `'Sandbox only. Expiry …'` describes those cards, not the app: they do
/// nothing on a production merchant, which is exactly why Live hides the
/// way in to that screen. Sweeping it up would send somebody to edit a
/// true sentence in a file this plan freezes.
const String cheatSheet = 'lib/demo/test_cards_screen.dart';

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
    // Every `.dart` under lib/, the same sweep the contract invariant does.
    // Comments count, because a grep cannot tell a sentence a tester reads
    // from a sentence a maintainer reads, and neither can this one.
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
    // The sweep reached the one file it is required to reach. Without this
    // the whole case goes quietly vacuous the day the directory name, the
    // extension filter or the working directory changes: nothing would be
    // scanned, no offender could be found, and an empty list looks the same
    // either way. The exemption is the calibration, because it is the one
    // path this file already knows must exist.
    expect(exempted, 1);
  });

  test('the exempt file is still the one the exemption was written for', () {
    // Without this the exemption goes quietly vacuous the day that file is
    // renamed: nothing would be skipped, nothing would be checked there,
    // and the sweep would look the same either way. The same guard
    // `contract_invariant_test.dart` puts on its own exemption.
    final source = File(cheatSheet).readAsStringSync();

    expect(source, contains('Sandbox only'));
    expect(source, contains('testCardExpiry'));
  });

  test('the guide describes Live mode where a tester will look', () {
    // The other half: not merely that the false claim is gone, but that
    // something true replaced it. A document that says nothing about Live
    // mode is not honest, it is just quiet.
    final readme = File('README.md').readAsStringSync();

    // The heading, not the phrase. `Live mode` on its own is already
    // satisfied by the deep-link bullet quoting the on-screen refusal, so a
    // section renamed out of existence left this green -- and it is a section
    // a tester goes looking for, and the target of the link in the opening
    // paragraph. Break-verified: renaming the heading now fails here.
    expect(readme, contains('## Live mode'));
    // The four facts a tester has to know before they touch it.
    expect(readme, contains('LIVE'));
    expect(readme, contains('memory'));
    expect(readme, contains('refund'));
    expect(readme, contains('Test on every launch'));
  });
}
