import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _the(String label, String path, RegExp pattern) {
  final text = File(path).readAsStringSync();
  final match = pattern.firstMatch(text);
  expect(
    match,
    isNotNull,
    reason:
        'No version found in $path for $label. The file was rewritten and this '
        'test no longer knows where to look, which is a broken guard rather '
        'than a passing one.',
  );
  return match!.group(1)!;
}

void main() {
  test('every version site agrees with the pubspec', () {
    final pubspec = _the(
      'pubspec',
      'pubspec.yaml',
      RegExp(r'^version:\s*(\S+)\s*$', multiLine: true),
    );

    final sites = <String, String>{
      'ios/paycross_flutter/Sources/paycross_flutter/PayCrossPlugin.swift': _the(
        'the Swift constant',
        'ios/paycross_flutter/Sources/paycross_flutter/PayCrossPlugin.swift',
        RegExp(r'pluginVersion\s*=\s*"(\S+)"'),
      ),
      'android/src/main/kotlin/com/paycross/flutter/PayCrossPlugin.kt': _the(
        'the Kotlin constant',
        'android/src/main/kotlin/com/paycross/flutter/PayCrossPlugin.kt',
        RegExp(r'PLUGIN_VERSION\s*=\s*"(\S+)"'),
      ),
      'android/src/test/kotlin/com/paycross/flutter/PayCrossPluginTest.kt': _the(
        'the Kotlin assertion',
        'android/src/test/kotlin/com/paycross/flutter/PayCrossPluginTest.kt',
        RegExp(r'assertEquals\("(\S+)",\s*info\.pluginVersion\)'),
      ),
    };

    final drifted = <String>[
      for (final site in sites.entries)
        if (site.value != pubspec) '${site.key} says ${site.value}',
    ];

    expect(
      drifted,
      isEmpty,
      reason:
          'pubspec.yaml says $pubspec. Bump every version site together, or '
          'versionInfo() reports one version to the merchant while pub '
          'resolves another.',
    );
  });
}
