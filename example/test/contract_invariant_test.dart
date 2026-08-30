import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The frozen automation contract has exactly one source file. Everything
/// else consumes `labelForResult` / `labelForError` / `recoveryToken`.
///
/// A second place that spells a label is how the contract drifts: a screen
/// grows its own `'result:success:'`, the runner keeps matching it, and the
/// two definitions disagree the first time a case is added to only one of
/// them.
void main() {
  test('no file under lib/ but e2e_label.dart spells a contract label', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.endsWith('lib/e2e_label.dart')) continue;
      final source = entity.readAsStringSync();
      if (source.contains('result:') || source.contains('error:')) {
        offenders.add(entity.path);
      }
    }

    expect(
      offenders,
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
    expect(contract, contains('error:'));
  });
}
