import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/automation_screen.dart';

/// What assistive technology -- and therefore `uiautomator` and
/// WebDriverAgent -- reaches, in the order it reaches it.
///
/// Nodes with no label are dropped: they are layout, and their count moves
/// with framework internals rather than with this app.
List<String> spokenLabels(WidgetTester tester) => tester.semantics
    .simulatedAccessibilityTraversal()
    .map((node) => node.label)
    .where((label) => label.isNotEmpty)
    .toList();

void main() {
  testWidgets('the automation screen presents the tree the runner froze', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(const MaterialApp(home: CheckoutScreen(e2e: true)));

    // Pinned, not derived. The E2E matrix runner reads this screen out of
    // the platform accessibility tree, so a change here is a change to
    // every cell file in tool/e2e/cells/.
    expect(spokenLabels(tester), <String>[
      'PayCross Example',
      'Paste a sandbox session token minted by your server.',
      'Session token',
      'Pay',
    ]);

    // Inline, not addTearDown: the framework's end-of-test verification runs at
    // the end of the test BODY, before package:test runs tearDowns, so a
    // deferred dispose is always too late and every semantics test fails with
    // "A SemanticsHandle was active at the end of the test."
    handle.dispose();
  });

  testWidgets('the screen builds under both branches of the define', (
    tester,
  ) async {
    // The labels themselves are exercised where they are produced, in
    // test/e2e_label_test.dart; what this adds is that the injected flag
    // changes no part of whether the screen builds or what it shows before a
    // payment has been made.
    await tester.pumpWidget(
      const MaterialApp(home: CheckoutScreen(key: ValueKey('e2e'), e2e: true)),
    );
    expect(find.text('Pay'), findsOneWidget);
    final underE2e = tester.state<State>(find.byType(CheckoutScreen));

    await tester.pumpWidget(
      const MaterialApp(
        home: CheckoutScreen(key: ValueKey('demo'), e2e: false),
      ),
    );
    expect(find.text('Pay'), findsOneWidget);

    // Two builds, not one rebuild: without distinct keys the second pump
    // updates the element in place and keeps the first State, so the second
    // branch would never be built from scratch and the test would be pinning
    // half of what it claims.
    expect(tester.state<State>(find.byType(CheckoutScreen)), isNot(underE2e));
  });
}
