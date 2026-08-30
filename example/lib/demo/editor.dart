import 'dart:convert';

import 'package:flutter/material.dart';

import 'presets.dart';

/// The raw session body, with the two fields people change most given their
/// own boxes.
///
/// The raw editor is the source of truth: the amount and currency boxes
/// rewrite it, rather than the other way round, so there is one body and no
/// way for the two views to disagree.
class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.preset, required this.onRun});

  final Preset preset;

  /// Runs [body]. It returns only once the run has been started, so this
  /// screen knows to keep its own button dead until then.
  final Future<void> Function(String body) onRun;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  late final TextEditingController _raw = TextEditingController(
    text: widget.preset.body,
  );
  final _amount = TextEditingController();
  final _customer = TextEditingController();

  /// Why the raw body cannot be minted, or null.
  String? _problem;

  /// Why the amount box or the customer box cannot be minted, or null.
  ///
  /// Separate from [_problem] because they are shown against their own field
  /// and because an empty box is a different mistake from a broken body.
  String? _amountProblem;
  String? _customerProblem;

  /// True while this screen is writing the boxes from the body.
  ///
  /// The boxes are a view of the raw body, so seeding them fires their own
  /// listeners; without this the seed would be read back as if a human had
  /// typed it, and an empty box seeded from a body with no amount would
  /// report itself as a mistake.
  bool _syncing = false;

  /// True from the moment Run is pressed until [EditorScreen.onRun] returns.
  ///
  /// What Run starts is a credential read and then a live mint, so a second
  /// press before the first has finished bills a second sandbox session and
  /// stacks a second Run screen on top of the first.
  bool _running = false;

  @override
  void initState() {
    super.initState();
    // Assigned rather than set through setState: this runs before the first
    // build, so there is no frame yet to rebuild.
    _validateBody();
    _seedBoxes();
    _raw.addListener(_onRawChanged);
    _amount.addListener(_onAmountChanged);
    _customer.addListener(_onCustomerChanged);
  }

  @override
  void dispose() {
    _raw.dispose();
    _amount.dispose();
    _customer.dispose();
    super.dispose();
  }

  Map<String, Object?>? get _decoded {
    try {
      final decoded = jsonDecode(_raw.text);
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  void _validateBody() =>
      _problem = _decoded == null ? 'The body is not valid JSON.' : null;

  /// Writes the boxes from the body, which is the only source of truth here.
  ///
  /// Clears their problems too: whatever a human had typed has just been
  /// replaced by what the body actually says, so the old complaint is stale.
  void _seedBoxes() {
    final body = _decoded;
    if (body == null) return;
    _syncing = true;
    final amount = body['amount'];
    _amount.text = amount is int ? '$amount' : '';
    final customer = body['customer'];
    final reference = customer is Map ? customer['merchant_reference'] : null;
    _customer.text = reference is String ? reference : '';
    _syncing = false;
    _amountProblem = null;
    _customerProblem = null;
  }

  /// The raw body was edited by hand, so the boxes follow it.
  void _onRawChanged() => setState(() {
    _validateBody();
    _seedBoxes();
  });

  void _onAmountChanged() {
    if (_syncing) return;
    setState(() {
      final amount = int.tryParse(_amount.text.trim());
      // Not silently ignored the way an unparsed value used to be: an empty
      // box over a body that still said 1000 ran 1000 without saying so.
      _amountProblem = amount == null
          ? 'A whole number of minor units — 1000 is €10.00.'
          : null;
      if (amount != null) _rewrite((body) => body['amount'] = amount);
    });
  }

  void _onCustomerChanged() {
    if (_syncing) return;
    setState(() {
      final reference = _customer.text.trim();
      _customerProblem = reference.isEmpty
          ? 'A saved card is found by this, so it cannot be empty.'
          : null;
      if (reference.isEmpty) return;
      _rewrite((body) {
        final customer = body['customer'];
        if (customer is! Map) return;
        // Randomise this and the card stored by one run can never be found
        // by the next.
        customer['merchant_reference'] = reference;
      });
    });
  }

  /// Applies one edit to the decoded body and writes it back.
  ///
  /// The raw editor is the single source of truth -- every field above it
  /// rewrites the JSON rather than keeping a parallel copy, so the two views
  /// cannot disagree about what will be minted.
  ///
  /// Removing the listener around the write keeps this out of a loop: the raw
  /// controller's own listener would otherwise re-run validation while this
  /// one is still on the stack.
  /// Callers are already inside a `setState`, so this does not open its own,
  /// and it deliberately does not re-seed the boxes: the human is typing in
  /// one of them, and re-seeding would rewrite what they are part-way through.
  void _rewrite(void Function(Map<String, Object?> body) edit) {
    final body = _decoded;
    if (body == null) return;
    edit(body);
    _raw.removeListener(_onRawChanged);
    _raw.text = const JsonEncoder.withIndent('  ').convert(body);
    _raw.addListener(_onRawChanged);
    _validateBody();
  }

  void _setCurrency(String currency) =>
      setState(() => _rewrite((body) => body['currency'] = currency));

  void _setSaveCard(bool save) => setState(
    () => _rewrite((body) {
      if (save) {
        body['save_card_config'] = {'usage': 'card_on_file'};
      } else {
        body.remove('save_card_config');
      }
    }),
  );

  String get _currency {
    final currency = _decoded?['currency'];
    return currency is String && currencies.contains(currency)
        ? currency
        : currencies.first;
  }

  bool get _savesCard => _decoded?['save_card_config'] != null;

  Future<void> _run() async {
    if (_running) return;
    setState(() => _running = true);
    try {
      await widget.onRun(_raw.text);
    } finally {
      // Even if the run threw: a dead Run button with nothing in flight is a
      // screen a person can only escape from by going back.
      if (mounted) setState(() => _running = false);
    }
  }

  /// Puts the body and every view of it back to the preset's.
  ///
  /// Explicit rather than leaning on the raw controller's listener: a reset
  /// that only had a complaint about an empty box to clear would change no
  /// text at all, so the listener would never fire and the complaint would
  /// stand over a body that no longer deserved it.
  void _reset() {
    _raw.removeListener(_onRawChanged);
    _raw.text = widget.preset.body;
    _raw.addListener(_onRawChanged);
    setState(() {
      _validateBody();
      _seedBoxes();
    });
  }

  /// Whether what is on screen can be minted at all.
  bool get _runnable =>
      _problem == null && _amountProblem == null && _customerProblem == null;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('Edit — ${widget.preset.name}')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        TextField(
          key: const ValueKey('amount'),
          controller: _amount,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: 'Amount in minor units',
            errorText: _amountProblem,
            errorMaxLines: 2,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          // Keyed on the value, not a constant: `initialValue` seeds the
          // FormField's own state once, so after "Reset to preset" the body
          // would revert while the dropdown still showed the last choice. A
          // changed key rebuilds the field from the body.
          key: ValueKey('currency-$_currency'),
          initialValue: _currency,
          decoration: const InputDecoration(
            labelText: 'Currency',
            border: OutlineInputBorder(),
          ),
          items: [
            for (final code in currencies)
              DropdownMenuItem(value: code, child: Text(code)),
          ],
          onChanged: (code) => code == null ? null : _setCurrency(code),
        ),
        const SizedBox(height: 16),
        TextField(
          key: const ValueKey('customerReference'),
          controller: _customer,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: 'Customer reference',
            helperText:
                'What a saved card is found by. The card-on-file presets '
                'pin it on purpose.',
            helperMaxLines: 2,
            errorText: _customerProblem,
            errorMaxLines: 2,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          key: const ValueKey('saveCard'),
          title: const Text('Offer to save the card'),
          subtitle: const Text('Adds save_card_config to the body.'),
          value: _savesCard,
          onChanged: _setSaveCard,
        ),
        const SizedBox(height: 16),
        TextField(
          key: const ValueKey('rawBody'),
          controller: _raw,
          minLines: 10,
          maxLines: 24,
          autocorrect: false,
          enableSuggestions: false,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          decoration: const InputDecoration(
            labelText: 'Session body',
            border: OutlineInputBorder(),
          ),
        ),
        if (_problem != null) ...[
          const SizedBox(height: 8),
          Text(
            _problem!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 20),
        Wrap(
          spacing: 12,
          children: [
            FilledButton(
              onPressed: _runnable && !_running ? _run : null,
              child: const Text('Run'),
            ),
            OutlinedButton(
              onPressed: _reset,
              child: const Text('Reset to preset'),
            ),
          ],
        ),
      ],
    ),
  );
}
