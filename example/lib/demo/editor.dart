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
  String? _problem;

  /// True from the moment Run is pressed until [EditorScreen.onRun] returns.
  ///
  /// What Run starts is a credential read and then a live mint, so a second
  /// press before the first has finished bills a second sandbox session and
  /// stacks a second Run screen on top of the first.
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _raw.addListener(_revalidate);
    _amount.addListener(
      () => _rewrite((body) => _setAmount(body, _amount.text)),
    );
    _customer.addListener(
      () => _rewrite((body) => _setCustomerReference(body, _customer.text)),
    );
    _revalidate();
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

  void _revalidate() => setState(
    () => _problem = _decoded == null ? 'The body is not valid JSON.' : null,
  );

  /// Applies one edit to the decoded body and writes it back.
  ///
  /// The raw editor is the single source of truth -- every field above it
  /// rewrites the JSON rather than keeping a parallel copy, so the two views
  /// cannot disagree about what will be minted.
  ///
  /// Removing the listener around the write keeps this out of a loop: the raw
  /// controller's own listener would otherwise re-run validation while this
  /// one is still on the stack.
  void _rewrite(bool Function(Map<String, Object?> body) edit) {
    final body = _decoded;
    if (body == null || !edit(body)) return;
    _raw.removeListener(_revalidate);
    _raw.text = const JsonEncoder.withIndent('  ').convert(body);
    _raw.addListener(_revalidate);
    _revalidate();
  }

  bool _setAmount(Map<String, Object?> body, String typed) {
    final amount = int.tryParse(typed.trim());
    if (amount == null) return false;
    body['amount'] = amount;
    return true;
  }

  bool _setCustomerReference(Map<String, Object?> body, String typed) {
    final reference = typed.trim();
    if (reference.isEmpty) return false;
    final customer = body['customer'];
    if (customer is! Map) return false;
    // The field a saved card is found by. Randomise it and the card stored by
    // one run can never be found by the next.
    customer['merchant_reference'] = reference;
    return true;
  }

  void _setCurrency(String currency) => _rewrite((body) {
    body['currency'] = currency;
    return true;
  });

  void _setSaveCard(bool save) => _rewrite((body) {
    if (save) {
      body['save_card_config'] = {'usage': 'card_on_file'};
    } else {
      body.remove('save_card_config');
    }
    return true;
  });

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

  void _reset() {
    _amount.clear();
    _customer.clear();
    _raw.text = widget.preset.body;
  }

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
          decoration: const InputDecoration(
            labelText: 'Amount in minor units',
            border: OutlineInputBorder(),
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
          decoration: const InputDecoration(
            labelText: 'Customer reference',
            helperText:
                'What a saved card is found by. Leave alone to keep '
                'the preset\'s.',
            helperMaxLines: 2,
            border: OutlineInputBorder(),
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
              onPressed: _problem == null && !_running ? _run : null,
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
