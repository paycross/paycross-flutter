import 'dart:convert';

import 'package:flutter/material.dart';

import 'environment.dart';
import 'live.dart';
import 'preset_store.dart';
import 'presets.dart';

const String rawBodySectionLabel = 'Advanced: raw body';

const String rawBodyValidLabel = 'Valid JSON.';

const String rawBodyInvalidLabel = 'The body is not valid JSON.';

const String _couldNotSave = 'Could not save — nothing was written.';

class _Bound {
  _Bound({
    required this.name,
    required this.label,
    required this.read,
    required this.write,
    required this.problemWith,
    this.helper,
    this.keyboard,
  });

  final String name;
  final String label;
  final String? helper;
  final TextInputType? keyboard;

  final String Function(Map<String, Object?> body) read;

  final void Function(Map<String, Object?> body, String typed) write;

  final String? Function(String typed) problemWith;

  final TextEditingController controller = TextEditingController();

  String? problem;
}

Map<String, Object?>? _customerOf(Map<String, Object?> body) {
  final customer = body['customer'];
  return customer is Map<String, Object?> ? customer : null;
}

String _customerText(Map<String, Object?> body, String field) {
  final value = _customerOf(body)?[field];
  return value is String ? value : '';
}

class EditorScreen extends StatefulWidget {
  const EditorScreen({
    super.key,
    required this.preset,
    required this.onRun,
    this.kind = PresetKind.builtIn,
    this.savedBody,
    this.environment = DemoEnvironment.test,
    this.store = const PresetStore(),
  });

  final Preset preset;

  final Future<void> Function(String body) onRun;

  final PresetKind kind;

  final String? savedBody;

  final DemoEnvironment environment;

  final PresetStore store;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  late final TextEditingController _raw = TextEditingController(text: _opening);

  final _newName = TextEditingController();

  late PresetKind _kind = widget.kind;
  late String? _id = widget.preset.id;
  late String _name = widget.preset.name;

  late String _savedBody = _opening;

  String? _problem;

  bool _syncing = false;

  bool _running = false;

  String get _opening => widget.savedBody ?? widget.preset.body;

  bool get _live => widget.environment == DemoEnvironment.live;

  late final List<_Bound> _fields = [
    _Bound(
      name: 'amount',
      label: 'Amount in minor units',
      keyboard: TextInputType.number,
      read: (body) {
        final amount = body['amount'];
        return amount is int ? '$amount' : '';
      },
      write: (body, typed) => body['amount'] = int.parse(typed.trim()),
      problemWith: (typed) => int.tryParse(typed.trim()) == null
          ? 'A whole number of minor units — 1000 is €10.00.'
          : null,
    ),
    if (!_live) ...[
      _Bound(
        name: 'customerEmail',
        label: 'Customer email',
        read: (body) => _customerText(body, 'email'),
        write: (body, typed) => customerFor(body)['email'] = typed.trim(),
        problemWith: (typed) => typed.trim().isEmpty
            ? 'The create schema requires an email address.'
            : null,
      ),
      _Bound(
        name: 'customerFirst',
        label: 'Customer first name',
        read: (body) => _customerText(body, 'first_name'),
        write: (body, typed) => customerFor(body)['first_name'] = typed.trim(),
        problemWith: (typed) => typed.trim().isEmpty
            ? 'The create schema requires a first name.'
            : null,
      ),
      _Bound(
        name: 'customerLast',
        label: 'Customer last name',
        read: (body) => _customerText(body, 'last_name'),
        write: (body, typed) => customerFor(body)['last_name'] = typed.trim(),
        problemWith: (typed) => typed.trim().isEmpty
            ? 'The create schema requires a last name.'
            : null,
      ),
    ],
    _Bound(
      name: 'customerReference',
      label: 'Customer reference',
      helper:
          'What a saved card is found by. The card-on-file presets pin it on '
          'purpose.',
      read: (body) => _customerText(body, 'merchant_reference'),
      write: (body, typed) =>
          customerFor(body)['merchant_reference'] = typed.trim(),
      problemWith: (typed) => typed.trim().isEmpty
          ? 'A saved card is found by this, so it cannot be empty.'
          : null,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _validateBody();
    _seedBoxes();
    _raw.addListener(_onRawChanged);
    for (final field in _fields) {
      field.controller.addListener(() => _onFieldChanged(field));
    }
  }

  @override
  void dispose() {
    _raw.dispose();
    _newName.dispose();
    for (final field in _fields) {
      field.controller.dispose();
    }
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

  void _validateBody() {
    if (_decoded == null) {
      _problem = rawBodyInvalidLabel;
      return;
    }
    _problem = _live ? liveBodyProblem(_raw.text) : null;
  }

  void _seedBoxes() {
    final body = _decoded;
    if (body == null) return;
    _syncing = true;
    for (final field in _fields) {
      field.controller.text = field.read(body);
      field.problem = null;
    }
    _syncing = false;
  }

  void _onRawChanged() => setState(() {
    _validateBody();
    _seedBoxes();
  });

  void _onFieldChanged(_Bound field) {
    if (_syncing) return;
    setState(() {
      final typed = field.controller.text;
      field.problem = field.problemWith(typed);
      if (field.problem == null) _rewrite((body) => field.write(body, typed));
    });
  }

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

  void _setOption(
    Map<String, Object?> Function() entry,
    Map<String, Object?> Function(Map<String, Object?> body) into,
    bool on,
  ) => setState(
    () => _rewrite((body) {
      final target = into(body);
      final option = entry();
      if (on) {
        target.addAll(option);
      } else {
        option.keys.forEach(target.remove);
      }
    }),
  );

  bool _hasOption(
    Map<String, Object?> Function() entry,
    Map<String, Object?>? Function(Map<String, Object?> body) into,
  ) {
    final body = _decoded;
    if (body == null) return false;
    final target = into(body);
    return target != null && entry().keys.every(target.containsKey);
  }

  Map<String, Object?> _topLevel(Map<String, Object?> body) => body;

  String get _currency {
    final currency = _decoded?['currency'];
    return currency is String && currency.isNotEmpty
        ? currency
        : currencies.first;
  }

  List<String> get _currencyChoices =>
      currencies.contains(_currency) ? currencies : [_currency, ...currencies];

  bool get _runnable =>
      _problem == null && _fields.every((field) => field.problem == null);

  bool get _dirty => _raw.text != _savedBody;

  Future<void> _run() async {
    if (_running) return;
    setState(() => _running = true);
    try {
      await widget.onRun(_raw.text);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<bool> _wrote(Future<void> Function() write, String problem) async {
    try {
      await write();
      return true;
    } catch (_) {
      if (mounted) _say(problem);
      return false;
    }
  }

  void _say(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  Future<void> _save() async {
    if (!_runnable) return;
    final body = _raw.text;
    final id = _id;
    if (id == null) return;
    if (body == _savedBody) {
      _say('Nothing to save.');
      return;
    }
    final wrote = switch (_kind) {
      PresetKind.builtIn => await _wrote(
        body == widget.preset.body
            ? () => widget.store.clearOverride(id)
            : () => widget.store.saveOverride(id, body),
        _couldNotSave,
      ),
      PresetKind.custom => await _wrote(
        () => widget.store.updateCustom(
          CustomPreset(id: id, name: _name, body: body),
        ),
        _couldNotSave,
      ),
      PresetKind.scratch => false,
    };
    if (!wrote || !mounted) return;
    setState(() => _savedBody = body);
    _say('Saved.');
  }

  Future<void> _saveAsNew() async {
    if (!_runnable) return;
    _newName.clear();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('saveAsNewDialog'),
        title: const Text('Name this preset'),
        content: TextField(
          key: const ValueKey('newPresetName'),
          controller: _newName,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Name',
            helperText: 'What the tile on Home will say.',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('saveAsNewCancel'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _newName,
            builder: (context, value, _) => FilledButton(
              key: const ValueKey('saveAsNewConfirm'),
              onPressed: value.text.trim().isEmpty
                  ? null
                  : () => Navigator.of(context).pop(value.text.trim()),
              child: const Text('Save'),
            ),
          ),
        ],
      ),
    );
    if (name == null || !mounted) return;
    final body = _raw.text;
    final CustomPreset made;
    try {
      made = await widget.store.addCustom(name: name, body: body);
    } catch (_) {
      if (mounted) _say(_couldNotSave);
      return;
    }
    if (!mounted) return;
    setState(() {
      _kind = PresetKind.custom;
      _id = made.id;
      _name = made.name;
      _savedBody = body;
    });
    _say('Saved as "$name".');
  }

  Future<void> _resetToDefault() async {
    final id = _id;
    if (_kind == PresetKind.builtIn && id != null) {
      final wrote = await _wrote(
        () => widget.store.clearOverride(id),
        'Could not reset — the saved body is still there.',
      );
      if (!wrote) return;
    }
    if (!mounted) return;
    _raw.removeListener(_onRawChanged);
    _raw.text = widget.preset.body;
    _raw.addListener(_onRawChanged);
    setState(() {
      _validateBody();
      _seedBoxes();
      _savedBody = widget.preset.body;
    });
  }

  Future<void> _delete() async {
    final id = _id;
    if (id == null) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('deleteConfirmDialog'),
        title: Text('Delete "$_name"?'),
        content: const Text('The tile and the body it holds go for good.'),
        actions: [
          FilledButton(
            key: const ValueKey('deleteCancel'),
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('deleteConfirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              'Delete',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    final wrote = await _wrote(
      () => widget.store.deleteCustom(id),
      'Could not delete — the tile is still there.',
    );
    if (!wrote || !mounted) return;
    Navigator.of(context).pop();
  }

  void _format() => setState(() => _rewrite((_) {}));

  Future<bool> _mayLeave() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('unsavedDialog'),
        title: const Text('Leave without saving?'),
        content: Text(
          _kind == PresetKind.scratch
              ? 'This body has no tile behind it, so what you typed goes '
                    'when you leave.'
              : 'The changes you made to "$_name" have not been saved.',
        ),
        actions: [
          FilledButton(
            key: const ValueKey('keepEditing'),
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            key: const ValueKey('discardChanges'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return go ?? false;
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) async {
      if (didPop) return;
      if (_dirty && !await _mayLeave()) return;
      if (context.mounted) Navigator.of(context).pop();
    },
    child: Scaffold(
      appBar: AppBar(title: Text('Edit — $_name')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          for (final field in _fields) ...[
            TextField(
              key: ValueKey(field.name),
              controller: field.controller,
              keyboardType: field.keyboard,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: field.label,
                helperText: field.helper,
                helperMaxLines: 2,
                errorText: field.problem,
                errorMaxLines: 2,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            if (field.name == 'amount') ...[
              DropdownButtonFormField<String>(
                key: ValueKey('currency-$_currency'),
                initialValue: _currency,
                decoration: const InputDecoration(
                  labelText: 'Currency',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final code in _currencyChoices)
                    DropdownMenuItem(value: code, child: Text(code)),
                ],
                onChanged: (code) => code == null ? null : _setCurrency(code),
              ),
              const SizedBox(height: 16),
            ],
          ],
          SwitchListTile(
            key: const ValueKey('saveCard'),
            title: const Text('Offer to save the card'),
            subtitle: const Text('Adds save_card_config to the body.'),
            value: _hasOption(saveCardConfigEntry, _topLevel),
            onChanged: (on) => _setOption(saveCardConfigEntry, _topLevel, on),
          ),
          SwitchListTile(
            key: const ValueKey('showSavedCards'),
            title: const Text('Show saved cards'),
            subtitle: const Text(
              'Adds saved_cards, so the sheet offers the cards this customer '
              'already has.',
            ),
            value: _hasOption(savedCardsEntry, _topLevel),
            onChanged: (on) => _setOption(savedCardsEntry, _topLevel, on),
          ),
          if (!_live)
            SwitchListTile(
              key: const ValueKey('sandboxBilling'),
              title: const Text('Send the sandbox billing address'),
              subtitle: const Text(
                'The fake New York address every sandbox preset ships with. '
                'A real merchant refuses it.',
              ),
              value: _hasOption(sandboxAddressEntry, _customerOf),
              onChanged: (on) =>
                  _setOption(sandboxAddressEntry, customerFor, on),
            ),
          const SizedBox(height: 8),
          Card(
            child: ExpansionTile(
              key: const ValueKey('rawBodySection'),
              title: const Text(rawBodySectionLabel),
              subtitle: Text(
                _problem ?? rawBodyValidLabel,
                style: _problem == null
                    ? null
                    : TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              children: [
                TextField(
                  key: const ValueKey('rawBody'),
                  controller: _raw,
                  minLines: 8,
                  maxLines: 24,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  decoration: const InputDecoration(
                    labelText: 'Session body',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton(
                    key: const ValueKey('format'),
                    onPressed: _problem == null ? _format : null,
                    child: const Text('Format'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              FilledButton(
                key: const ValueKey('run'),
                onPressed: _runnable && !_running ? _run : null,
                child: const Text('Run'),
              ),
              if (_kind != PresetKind.scratch)
                FilledButton.tonal(
                  key: const ValueKey('save'),
                  onPressed: _runnable ? _save : null,
                  child: const Text('Save'),
                ),
              OutlinedButton(
                key: const ValueKey('saveAsNew'),
                onPressed: _runnable ? _saveAsNew : null,
                child: const Text('Save as new…'),
              ),
              if (_kind != PresetKind.custom)
                OutlinedButton(
                  key: const ValueKey('resetToDefault'),
                  onPressed: _resetToDefault,
                  child: const Text('Reset to default'),
                ),
              if (_kind == PresetKind.custom)
                TextButton(
                  key: const ValueKey('delete'),
                  onPressed: _delete,
                  child: Text(
                    'Delete',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    ),
  );
}
