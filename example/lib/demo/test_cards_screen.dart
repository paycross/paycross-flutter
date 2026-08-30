import 'package:flutter/material.dart';

import 'test_cards.dart';

/// The sandbox cheat sheet: what to type, and what never to.
///
/// The do-not-use section is the half worth having. Those three PANs approve
/// instead of declining, so a colleague who tries one without reading the
/// reason files an SDK bug that is really a backend gap.
class TestCardsScreen extends StatelessWidget {
  const TestCardsScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Test cards')),
    body: ListView(
      padding: const EdgeInsets.all(12),
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          child: Text(
            'Sandbox only. Expiry $testCardExpiry, CVV $testCardCvv and '
            'cardholder $testCardholder work on every card below.',
          ),
        ),
        for (final card in usableTestCards) _CardTile(card: card),
        _Heading(
          title: 'Do not use',
          note:
              'The sandbox does not route these, so they approve instead of '
              'doing what their name says. Listed rather than hidden, '
              'because they appear in older harnesses and somebody will try '
              'one.',
        ),
        for (final card in doNotUseTestCards) _CardTile(card: card),
      ],
    ),
  );
}

class _Heading extends StatelessWidget {
  const _Heading({required this.title, required this.note});

  final String title;
  final String note;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 24, 8, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(note),
      ],
    ),
  );
}

class _CardTile extends StatelessWidget {
  const _CardTile({required this.card});

  final TestCard card;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      title: Text(card.grouped),
      subtitle: Text(
        [card.behaviour, if (card.note != null) card.note!].join('\n'),
      ),
      isThreeLine: card.note != null,
    ),
  );
}
