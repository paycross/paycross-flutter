import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A contract label as it appears in source: one of the two words, a colon,
/// and something other than whitespace after it.
///
/// The lookahead is what tells a label from Dart's own syntax. `dart format`
/// puts a space after a named argument's colon and no label carries one, so
/// `Foo(error: e)` is an argument and `'result:success:'` is a label. The
/// word boundary keeps an identifier that merely ends in one of the two
/// words out of it.
final RegExp labelShape = RegExp(r'\b(result|error):(?!\s)');

/// Every `.dart` file under [root] that spells a contract label, except the
/// one file allowed to.
///
/// Takes its root so the rule itself can be exercised over scratch files
/// rather than only over `lib/`, where a false positive would have to be
/// provoked by breaking the app.
List<String> filesSpellingALabel(Directory root) {
  final offenders = <String>[];
  for (final entity in root.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    if (entity.path.endsWith('lib/e2e_label.dart')) continue;
    if (labelShape.hasMatch(entity.readAsStringSync())) {
      offenders.add(entity.path);
    }
  }
  return offenders;
}

/// The frozen automation contract has exactly one source file. Everything
/// else consumes `labelForResult` / `labelForError` / `recoveryToken`.
///
/// A second place that spells a label is how the contract drifts: a screen
/// grows its own `'result:success:'`, the runner keeps matching it, and the
/// two definitions disagree the first time a case is added to only one of
/// them.
void main() {
  test('no file under lib/ but e2e_label.dart spells a contract label', () {
    expect(
      filesSpellingALabel(Directory('lib')),
      isEmpty,
      reason:
          'These files spell a contract label directly. Call labelForResult, '
          'labelForError or recoveryToken from lib/e2e_label.dart instead -- '
          'including in doc comments, which this check cannot tell from code.',
    );
  });

  test('the file the check exempts is still the file that defines them', () {
    // Without this the check above goes quietly vacuous the day
    // e2e_label.dart is renamed or emptied: nothing would spell a label,
    // every file would pass, and the invariant would be guarding nothing.
    final contract = File('lib/e2e_label.dart').readAsStringSync();
    expect(contract, contains('result:success:'));
    // Against the same pattern the check uses, so a lookahead that stopped
    // matching anything at all could not leave this guard green.
    expect(labelShape.allMatches(contract), isNotEmpty);
  });

  group('what counts as spelling a label', () {
    late Directory scratch;

    setUp(() => scratch = Directory.systemTemp.createTempSync('label-check'));
    tearDown(() => scratch.deleteSync(recursive: true));

    void write(String name, String source) =>
        File('${scratch.path}/$name').writeAsStringSync(source);

    test('a named argument is not a label', () {
      write('args.dart', 'Foo build() => Foo(error: e, result: r);\n');

      expect(filesSpellingALabel(scratch), isEmpty);
    });

    test('a longer word that merely ends in one is not', () {
      write('longer.dart', "const id = 'myresult:x';\nvar swallowerror = 1;\n");

      expect(filesSpellingALabel(scratch), isEmpty);
    });

    test('a label in a string or a doc comment is', () {
      write('spoken.dart', "const outcome = 'result:success:\$id';\n");
      write('commented.dart', '/// Renders error:sessionExpired.\n');

      expect(filesSpellingALabel(scratch), hasLength(2));
    });
  });
}
