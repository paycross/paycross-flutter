/// One sandbox card and what it does.
class TestCard {
  const TestCard({required this.pan, required this.behaviour, this.note});

  final String pan;
  final String behaviour;
  final String? note;

  /// `4111 1111 1117 0000` -- what a person types.
  String get grouped {
    final groups = <String>[];
    for (var i = 0; i < pan.length; i += 4) {
      groups.add(pan.substring(i, i + 4 > pan.length ? pan.length : i + 4));
    }
    return groups.join(' ');
  }
}

/// Expiry `12/28`, CVV `123`, cardholder `John Doe` on every one of them.
const String testCardExpiry = '12/28';
const String testCardCvv = '123';
const String testCardholder = 'John Doe';

/// The sandbox cards that route to the outcome they claim.
const List<TestCard> usableTestCards = <TestCard>[
  TestCard(pan: '4111111111170000', behaviour: 'Approve, no 3-D Secure'),
  TestCard(pan: '4111111111153063', behaviour: 'Frictionless 3-D Secure'),
  TestCard(
    pan: '4111111111153220',
    behaviour: '3-D Secure challenge',
    note:
        'The sandbox ACS page decides the outcome, not the PAN: tap approve, '
        'authentication_failed, do_not_honor, fraud_suspected, and so on.',
  ),
  TestCard(pan: '4111111111150002', behaviour: 'Decline: do_not_honor'),
  TestCard(pan: '4111111111159995', behaviour: 'Decline: insufficient_funds'),
  TestCard(pan: '4111111111150119', behaviour: 'Decline: fraud_suspected'),
  TestCard(pan: '4111111111150051', behaviour: 'Provider timeout'),
];

/// Cards the sandbox does not route. **They approve.**
///
/// Listed rather than hidden: they appear in older harnesses and in the
/// Android demo's seed list, so somebody will try one, watch a "decline"
/// succeed, and file an SDK bug that is really a backend gap.
const List<TestCard> doNotUseTestCards = <TestCard>[
  TestCard(
    pan: '4111111111153055',
    behaviour: 'Was: 3-D Secure challenge then decline',
    note:
        'Unrouted in the TEST sandbox, so it approves without 3-D Secure at '
        'all. Reproduced on both platforms — io.paycross#870.',
  ),
  TestCard(
    pan: '4111111111150069',
    behaviour: 'Was: Decline card_expired',
    note:
        'Unrouted in the TEST sandbox, so it approves — io.paycross#870. '
        'Reach card_expired through the challenge card ACS page instead.',
  ),
  TestCard(
    pan: '4111111111150127',
    behaviour: 'Was: Decline invalid_cvv',
    note:
        'Unrouted in the TEST sandbox, so it approves — io.paycross#870. '
        'Reach invalid_cvv through the challenge card ACS page instead.',
  ),
];
