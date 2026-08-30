import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/test_cards.dart';

void main() {
  test('the usable cards are the seven that really route', () {
    expect(usableTestCards.map((c) => c.pan).toList(), <String>[
      '4111111111170000',
      '4111111111153063',
      '4111111111153220',
      '4111111111150002',
      '4111111111159995',
      '4111111111150119',
      '4111111111150051',
    ]);
  });

  test(
    'the three known sandbox gaps are listed as do-not-use, with a reason',
    () {
      expect(doNotUseTestCards.map((c) => c.pan).toSet(), {
        '4111111111153055',
        '4111111111150069',
        '4111111111150127',
      });
      for (final card in doNotUseTestCards) {
        expect(card.note, contains('approve'));
        expect(card.note, contains('870'));
      }
    },
  );

  test('no PAN appears in both lists', () {
    final usable = usableTestCards.map((c) => c.pan).toSet();
    final gaps = doNotUseTestCards.map((c) => c.pan).toSet();

    expect(usable.intersection(gaps), isEmpty);
  });

  test('a PAN is shown in the groups of four a card form takes', () {
    // What the cheat sheet renders is what somebody types. A grouping that
    // dropped or doubled a digit would be a wrong PAN on screen, and the
    // run that followed would look like an SDK bug.
    expect(
      usableTestCards.map((c) => c.grouped).toList(),
      everyElement(matches(RegExp(r'^(\d{4} ){3}\d{4}$'))),
    );
    expect(
      usableTestCards.map((c) => c.grouped.replaceAll(' ', '')).toList(),
      usableTestCards.map((c) => c.pan).toList(),
    );
  });
}
