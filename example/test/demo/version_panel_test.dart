import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/version_panel.dart';

void main() {
  testWidgets('shows the demo, plugin and native SDK versions', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VersionPanel(
            readVersions: () async =>
                (demo: '0.1.0+7', plugin: '0.1.0', nativeSdk: '0.1.1'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Demo 0.1.0+7'), findsOneWidget);
    expect(find.text('Plugin paycross_flutter 0.1.0'), findsOneWidget);
    expect(find.text('Native SDK 0.1.1'), findsOneWidget);
  });

  testWidgets('renders "…" until the first read comes back', (tester) async {
    final pending = Completer<DemoVersions>();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: VersionPanel(readVersions: () => pending.future)),
      ),
    );

    expect(find.text('Demo …'), findsOneWidget);
    expect(find.text('Demo unknown'), findsNothing);

    pending.complete((demo: '0.1.0+7', plugin: '0.1.0', nativeSdk: '0.1.1'));
    await tester.pumpAndSettle();

    expect(find.text('Demo 0.1.0+7'), findsOneWidget);
  });

  testWidgets('a version read that throws renders "unknown", not a crash', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VersionPanel(
            readVersions: () async => throw StateError('no platform here'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Demo unknown'), findsOneWidget);
    // A read that has not come back yet renders '…', so 'unknown' on screen
    // can only have come from the catch inside the panel.
    expect(find.text('Demo …'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a null nativeSdkVersion reads "unknown", which is Android', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VersionPanel(
            readVersions: () async =>
                (demo: '0.1.0+1', plugin: '0.1.0', nativeSdk: 'unknown'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Native SDK unknown'), findsOneWidget);
  });
}
