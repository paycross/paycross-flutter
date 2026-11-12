import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final RegExp labelShape = RegExp(r'\b(result|error):(?!\s)');

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
    final contract = File('lib/e2e_label.dart').readAsStringSync();
    expect(contract, contains('result:success:'));
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
      write(
        'longer.dart',
        "const id = 'myresult:x';\nconst tag = 'swallowerror:x';\n",
      );

      expect(filesSpellingALabel(scratch), isEmpty);
    });

    test('a label in a string or a doc comment is', () {
      write('spoken.dart', "const outcome = 'result:success:\$id';\n");
      write('commented.dart', '/// Renders error:sessionExpired.\n');

      expect(filesSpellingALabel(scratch), hasLength(2));
    });
  });
}
