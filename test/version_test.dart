import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The plugin writes its own version in five places, in four languages, and
/// nothing else checks that they agree.
///
/// `versionInfo()` reports the two native constants to the host app, so a
/// merchant debugging a wallet reads them out of a running build and compares
/// them to the version they think they installed. The Kotlin test is the only
/// other assertion that pins one, and CI runs no Gradle step, so it never
/// executes. Everything else -- format, analyze, the Pigeon freshness gate, the
/// macOS build -- passes happily on a tree whose five versions disagree.
///
/// The pubspec is the source of truth because it is the one a merchant's
/// `pub get` resolves against.
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
      'ios/paycross_flutter.podspec': _the(
        'podspec',
        'ios/paycross_flutter.podspec',
        RegExp(r"^\s*s\.version\s*=\s*'(\S+)'", multiLine: true),
      ),
      'ios/Classes/PayCrossPlugin.swift': _the(
        'the Swift constant',
        'ios/Classes/PayCrossPlugin.swift',
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

    // Every disagreement at once, rather than stopping at the first: a bump
    // that missed three files should say so in one run.
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
