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
  'no production endpoints',
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

/// Machinery this app had while the Live identity was a constant, and has
/// no longer.
///
/// A separate list from [retiredPromises] because it is a different kind
/// of wrong: those were promises about what the app cannot do, these are
/// instructions pointing at a constant that is not there. A tester told to
/// wait for the owner to edit `liveSmokeIdentity` waits forever.
const List<String> retiredIdentityMachinery = <String>[
  'liveSmokeIdentity',
  'REPLACE_ME',
  'is still a placeholder',
];

/// The hand-spelled-amount instruction this app had while four pieces of
/// copy each wrote the figure out, and has no longer.
///
/// A third list, and a third kind of wrong: somebody told to change the
/// amount in four places will change it in four places, and three of those
/// places are now one call to `liveSmokeAmountLabel`. The two extra edits
/// would land on nothing, or on the function, and the second is worse.
const List<String> retiredAmountMachinery = <String>[
  'four places',
  'four edits',
];

/// Claims Live mode made while its amount was a constant and its currency
/// was a per-session dropdown, and cannot make now that both are fields of
/// each tile's saveable body.
///
/// A fifth list, and a fifth kind of wrong: a tester who reads that the
/// amount is fixed will not go looking for the pencil that changes it, and
/// one sent to Settings for a currency dropdown will not find one. The
/// function name is in here for the reason `liveSmokeIdentity` was -- a
/// document pointing at a symbol that no longer exists sends a maintainer
/// to nothing.
const List<String> retiredFixedAmountClaims = <String>[
  'The amount is fixed',
  'no editor anywhere near it',
  'liveSmokeAmountLabel',
  'pick the currency',
  'currency you picked',
];

/// Claims Live mode made while it offered a single tile, and cannot make
/// now that it offers three.
///
/// A fourth list, and a fourth kind of wrong. These are not promises about
/// the environment but promises about the surface: a tester who reads that
/// Live has no saved-card scenarios will not go looking for the two tiles
/// under the smoke, and a tester who reads that Home shows one tile will
/// assume the other two are a bug.
const List<String> retiredSingleTileClaims = <String>[
  'no saved cards',
  'no saved-card scenarios',
  'Nothing but the smoke',
  'Home shows one tile',
  'shows one tile',
  'The tile below',
];

/// Claims that the native sheet has no Apple Pay, which it now has.
///
/// A separate list again, and the newest kind of wrong: the browser button
/// arrived while Apple Pay in the sheet was still being built, so the guide
/// explains that button by saying the sheet cannot do wallets. Half of that
/// is still true -- Google Pay is browser-only -- and the Apple half is not.
/// A tester who reads that the sheet has no Apple Pay is a tester who will
/// press "Open in browser" for the one proof this plan exists to get, and
/// the production payment will be made on the hosted page instead of
/// through the SDK.
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

    // Sentences, not words. Every assertion here started as a bare word and
    // every one of them survived a mutation that gutted the section it was
    // supposed to be guarding, because the word turned up somewhere
    // incidental: `Live mode` in the deep-link bullet quoting the on-screen
    // refusal, `LIVE` in "marked LIVE in red", `memory` in the profile-strip
    // paragraph, `refund` in a heading two sections away. A guide can lose
    // the whole of "Getting in" and still contain all four.
    //
    // So each one is pinned at the length of the thing it is actually about,
    // and the two headings are pinned with their surrounding newlines --
    // `'## Live mode'` is a substring of `'### Live mode'`, so without the
    // newlines a section could be demoted into a subsection of the one above
    // it and nothing here would notice.
    expect(readme, contains('\n## Live mode\n'));
    // The gate, not the word: this lives in "Getting in" and nowhere else.
    expect(readme, contains('Type `LIVE`'));
    // The storage rule, not the noun.
    expect(readme, contains('held in memory'));
    // The section that tells a tester money has to be handed back, pinned by
    // its heading because the instruction itself is a wrapped quotation of
    // the shipped string and a line break would make a substring test lie.
    expect(readme, contains('\n### Afterwards — refund it\n'));
    // The one fact that makes a forgotten toggle survivable.
    expect(readme, contains('starts in Test on every launch'));
    // The identity, which is typed rather than committed. Its own heading,
    // pinned with its newlines like the two above.
    expect(readme, contains('\n### The credentials and the identity\n'));
    // Two rules a substring pin has to respect, both learned the hard way in
    // this very file. The phrase must not straddle a line break -- the README
    // is hand-wrapped at 80 and `contains` sees the newline -- so the
    // paragraph below keeps this one whole on its line. And `contains` is
    // case-sensitive, so the second pin starts one word after a
    // sentence-initial capital rather than trying to match it.
    expect(readme, contains('a first and a last name'));
    expect(readme, contains('about the identity is saved'));
    // The currency, and where it went. It was picked on this screen once
    // per session, so a tester who has done this before will come back
    // looking for the dropdown -- and the sentence that tells them it is a
    // field of the tile now is the one thing that stops them concluding the
    // feature broke. Pinned as a sentence for the reason every pin above is:
    // the bare word turns up in the sandbox editor's paragraph as well.
    expect(readme, contains('The currency is not picked here'));
    // And the rule that makes a saved Live body safe to keep at all.
    expect(readme, contains('The identity never goes into a preset'));
  });

  test('nothing still says Live offers a single tile', () {
    // Both halves, the way the retired-promise cases above do it: the guide
    // a tester reads and every screen they read it on.
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
    // The sweep reached something, so an empty offender list means the files
    // were read rather than that none were found.
    expect(scanned, greaterThan(10));
  });

  test('nothing still says the native sheet has no Apple Pay', () {
    // The same two halves as the case above: the guide, and every screen.
    // The sheet's Apple Pay button is what task 09's production payment is
    // made with, so a sentence sending the tester to the browser instead is
    // a sentence that loses the proof rather than one that reads oddly.
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
    // The sweep reached something, so an empty offender list means the files
    // were read rather than that none were found.
    expect(scanned, greaterThan(10));
  });

  test('the guide describes all three tiles, and the order of two', () {
    // The other half again: not merely that the single-tile claim is gone,
    // but that something true replaced it. Sentences rather than words, for
    // the reason every pin in this file is a sentence -- "saved card" alone
    // turns up in the sandbox preset list two sections away.
    final readme = File('README.md').readAsStringSync();

    expect(readme, contains('\n### Running the tiles\n'));
    expect(readme, contains('Home shows three tiles'));
    // The pair is ordered, and a tester who runs them the other way round
    // finds an empty list and reports it as a bug.
    expect(readme, contains('store card** first'));
    // Three charges are three refunds, which is the one thing this section
    // exists to make unmissable.
    expect(readme, contains('three charges'));
  });

  test('nothing tells anyone to spell the amount out four times', () {
    // The single-source rule, guarded the way the retired identity constant
    // is: the instruction and the machinery it describes have to go together,
    // or a maintainer follows a document to three places that no longer
    // exist.
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
    // The one source, named where a maintainer will look for it. Without
    // this the case above is satisfied by a README that says nothing about
    // the amount at all.
    expect(readme, contains('liveBodyAmountLabel'));
    // The sweep reached something, so an empty offender list means the files
    // were read rather than that none were found.
    expect(scanned, greaterThan(10));
  });

  test('nothing says a Live amount is fixed, or asks for a currency', () {
    // The same two halves as every case above: the guide, and every screen.
    // A tester who reads that the figure cannot be changed will not look for
    // the pencil, and one told to pick a currency in Settings will look for
    // a dropdown that is not there.
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
    // The other half: something true replaced it. Sentences rather than
    // words, for the reason every pin in this file is a sentence.
    expect(readme, contains('\n## Saving a preset\n'));
    expect(readme, contains('Changing an amount is an edit on the phone'));
    // The separation, which is the rule a tester most needs to know about
    // before they save anything in Live.
    expect(readme, contains('neither mode ever offers a body'));
    // The sweep reached something, so an empty offender list means the files
    // were read rather than that none were found.
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
    // The sweep reached something. Without this the case goes quietly
    // vacuous the day the directory name or the extension filter changes:
    // nothing scanned, no offender found, and an empty list looks the same
    // either way.
    expect(scanned, greaterThan(10));
  });
}
