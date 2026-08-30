import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/test_cards.dart';
import 'package:paycross_demo/demo/test_cards_screen.dart';

import '_surface.dart';

void main() {
  testWidgets('renders both sections, and the gaps carry their reason', (
    tester,
  ) async {
    useTallSurface(tester);
    await tester.pumpWidget(const MaterialApp(home: TestCardsScreen()));
    await tester.pumpAndSettle();

    for (final card in [...usableTestCards, ...doNotUseTestCards]) {
      expect(find.text(card.grouped), findsOneWidget, reason: card.pan);
    }

    // The heading and the reason are the point of the section: without them
    // a colleague tries a "decline" card, watches it approve, and files an
    // SDK bug that is really a backend gap.
    expect(find.text('Do not use'), findsOneWidget);
    expect(find.textContaining('io.paycross#870'), findsNWidgets(3));
  });
}
