import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/automation_screen.dart';

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

    expect(spokenLabels(tester), <String>[
      'PayCross Example',
      'Paste a sandbox session token minted by your server.',
      'Session token',
      'Pay',
    ]);

    handle.dispose();
  });

  testWidgets('the screen builds under both branches of the define', (
    tester,
  ) async {
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

    expect(tester.state<State>(find.byType(CheckoutScreen)), isNot(underE2e));
  });
}
