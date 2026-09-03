import 'dart:convert';

import 'package:flutter/material.dart';

import 'environment.dart';
import 'live.dart';
import 'preset_store.dart';
import 'presets.dart';

/// What the collapsible section holding the raw JSON is called.
///
/// Named once and read by the screen and its tests, so a test taps the words
/// the app actually shows rather than a copy of them that can drift.
const String rawBodySectionLabel = 'Advanced: raw body';

/// What that section says when the body parses.
///
/// It sits in the section's subtitle rather than beside the field, so the one
/// fact that decides whether Run works is on screen whether the section is
/// open or shut. A person who collapsed it and found Run dead would otherwise
/// have nothing telling them why.
const String rawBodyValidLabel = 'Valid JSON.';

/// Why the raw body cannot be minted.
const String rawBodyInvalidLabel = 'The body is not valid JSON.';

/// What a store write that the phone refused says.
///
/// One string for all three saving actions: the person can do exactly one
/// thing about any of them, which is try again, and three wordings would be
/// three chances to say it differently.
const String _couldNotSave = 'Could not save — nothing was written.';

/// One box over the body: what it shows, why what is in it cannot be minted,
/// and how it writes itself back.
///
/// A table rather than five copies of the same controller-plus-listener
/// paragraph. Every one of these boxes is a view of the raw body -- it is the
/// source of truth and they rewrite it, never the other way round -- and the
/// bugs this shape prevents are the ones the amount box had first: an empty
/// box that left the old value in the body and ran it, and a seed that read
/// itself back as if a human had typed it.
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

  /// The widget key, and what a test names this box by.
  final String name;
  final String label;
  final String? helper;
  final TextInputType? keyboard;

  /// This box's value as the decoded body has it, or '' when the body does
  /// not carry one.
  final String Function(Map<String, Object?> body) read;

  /// Writes what was typed into the decoded body. Called only when
  /// [problemWith] passed, so it may assume the text is usable.
  final void Function(Map<String, Object?> body, String typed) write;

  /// Why what is in the box cannot be minted, or null.
  final String? Function(String typed) problemWith;

  final TextEditingController controller = TextEditingController();

  /// The current complaint, shown against this box.
  String? problem;
}

/// The customer object of a decoded body, or null when there is not one.
Map<String, Object?>? _customerOf(Map<String, Object?> body) {
  final customer = body['customer'];
  return customer is Map<String, Object?> ? customer : null;
}

/// The customer object of a decoded body, building one if a hand edit
/// removed it.
///
/// For writes only, which is why it is separate from [_customerOf]. A field
/// that typed into nothing was the silent failure this whole screen is
/// designed against -- and a body with no customer is one the create schema
/// answers 400 to, so building it is the repair as much as the fix.
Map<String, Object?> _customerFor(Map<String, Object?> body) {
  final existing = body['customer'];
  if (existing is Map<String, Object?>) return existing;
  final made = <String, Object?>{};
  body['customer'] = made;
  return made;
}

/// One string field of the customer object, as text.
String _customerText(Map<String, Object?> body, String field) {
  final value = _customerOf(body)?[field];
  return value is String ? value : '';
}

/// A session body, edited as a form, with the raw JSON underneath it.
///
/// The raw body is the source of truth: every box and switch above it
/// rewrites the JSON rather than keeping a parallel copy, so the two views
/// cannot disagree about what will be minted. The raw field itself is shut
/// away in a section a person opens when they want it -- it was a 24-line
/// wall of JSON above the buttons, which is most of what made this screen
/// hard to use.
///
/// What it saves into is [kind], and that is Home's to decide rather than
/// this screen's to work out: a built-in preset's edit is an override filed
/// under its id, a preset somebody made is written back in place, and the
/// Custom body has nothing behind it until "Save as new…" gives it a tile.
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

  /// The preset as it ships: for a built-in, the bytes `presets.dart` holds
  /// and "Reset to default" goes back to.
  final Preset preset;

  /// Runs [body]. It returns only once the run has been started, so this
  /// screen knows to keep its own button dead until then.
  final Future<void> Function(String body) onRun;

  /// Which of the saving actions this preset can offer.
  final PresetKind kind;

  /// The body somebody saved for this preset, or null for the shipped one.
  ///
  /// Handed down rather than read here. Home has already read the store to
  /// draw its tiles, and a second read on the way in would be a second answer
  /// this screen could show while the tile behind it showed the first.
  final String? savedBody;

  /// Which mode's preset this is, which decides two things and nothing else.
  ///
  /// A Live body carries no identity -- it is typed in Settings, held for
  /// one session and spliced in at mint time -- so there are no boxes here
  /// to type one into. And a Live body must not carry the sandbox billing
  /// address, which `liveBodyProblem` refuses rather than quietly strips.
  ///
  /// Everything else is the same screen: the same fields, the same raw body,
  /// the same four saving actions. Designing two editors is how the two
  /// modes end up with different bugs.
  final DemoEnvironment environment;

  /// Where Save, "Save as new…", "Reset to default" and Delete write.
  ///
  /// A constructor argument for the same reason History's is: the default
  /// reaches `SharedPreferences`, which under `flutter test` has no platform
  /// behind it.
  final PresetStore store;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  late final TextEditingController _raw = TextEditingController(text: _opening);

  /// The name a new tile is being given, while the dialog asking for it is up.
  final _newName = TextEditingController();

  /// What this screen is editing now, which is not always what it opened on:
  /// "Save as new…" turns a built-in's body or the Custom one into a tile of
  /// its own, and from then on Save writes back to that tile.
  late PresetKind _kind = widget.kind;
  late String? _id = widget.preset.id;
  late String _name = widget.preset.name;

  /// The body as the store has it, which is what an unsaved change is
  /// measured against.
  late String _savedBody = _opening;

  /// Why the raw body cannot be minted, or null.
  String? _problem;

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

  /// What the screen opens on: what was saved, or what the preset ships with.
  String get _opening => widget.savedBody ?? widget.preset.body;

  /// The boxes, in the order they are read down the screen.
  ///
  /// The three customer fields carry the same rule as the amount and the
  /// reference did first, and they carry it for a measured reason: the create
  /// schema's required list holds `first_name`, `last_name` and `email`, and
  /// a body missing one answers 400 rather than minting. Clearing a box and
  /// running the old value anyway is the bug this whole shape exists to make
  /// impossible.
  /// Whether this screen is editing a body that will charge a real card.
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
    // Test only, all three. In Live the identity is typed in Settings and
    // spliced in at mint time, so a box here would be a box whose value is
    // either ignored or -- worse -- saved into a row that outlives the
    // session the name was given for.
    if (!_live) ...[
      _Bound(
        name: 'customerEmail',
        label: 'Customer email',
        read: (body) => _customerText(body, 'email'),
        write: (body, typed) => _customerFor(body)['email'] = typed.trim(),
        problemWith: (typed) => typed.trim().isEmpty
            ? 'The create schema requires an email address.'
            : null,
      ),
      _Bound(
        name: 'customerFirst',
        label: 'Customer first name',
        read: (body) => _customerText(body, 'first_name'),
        write: (body, typed) => _customerFor(body)['first_name'] = typed.trim(),
        problemWith: (typed) => typed.trim().isEmpty
            ? 'The create schema requires a first name.'
            : null,
      ),
      _Bound(
        name: 'customerLast',
        label: 'Customer last name',
        read: (body) => _customerText(body, 'last_name'),
        write: (body, typed) => _customerFor(body)['last_name'] = typed.trim(),
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
          // Randomise this and the card stored by one run can never be found
          // by the next.
          _customerFor(body)['merchant_reference'] = typed.trim(),
      problemWith: (typed) => typed.trim().isEmpty
          ? 'A saved card is found by this, so it cannot be empty.'
          : null,
    ),
  ];

  @override
  void initState() {
    super.initState();
    // Assigned rather than set through setState: this runs before the first
    // build, so there is no frame yet to rebuild.
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

  /// Why the body cannot be minted, or null.
  ///
  /// Two rules, one field, because they answer one question: whether Run and
  /// Save work. The second is Live only and is a refusal rather than a quiet
  /// strip -- see `liveBodyProblem`.
  void _validateBody() {
    if (_decoded == null) {
      _problem = rawBodyInvalidLabel;
      return;
    }
    _problem = _live ? liveBodyProblem(_raw.text) : null;
  }

  /// Writes the boxes from the body, which is the only source of truth here.
  ///
  /// Clears their problems too: whatever a human had typed has just been
  /// replaced by what the body actually says, so the old complaint is stale.
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

  /// The raw body was edited by hand, so the boxes follow it.
  void _onRawChanged() => setState(() {
    _validateBody();
    _seedBoxes();
  });

  void _onFieldChanged(_Bound field) {
    if (_syncing) return;
    setState(() {
      final typed = field.controller.text;
      // Not silently ignored the way an unparsed value used to be: an empty
      // box over a body that still said 1000 ran 1000 without saying so.
      field.problem = field.problemWith(typed);
      if (field.problem == null) _rewrite((body) => field.write(body, typed));
    });
  }

  /// Applies one edit to the decoded body and writes it back.
  ///
  /// Removing the listener around the write keeps this out of a loop: the raw
  /// controller's own listener would otherwise re-run validation while this
  /// one is still on the stack.
  ///
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

  /// Adds or removes the keys [entry] stands for, on the object [into] picks.
  ///
  /// One function for all three switches, taking the option from
  /// `presets.dart` rather than spelling it here: the switch and the preset
  /// bodies then send one shape for one feature, which is the rule Live
  /// mode's two saved-card tiles already follow.
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

  /// Whether the keys [entry] stands for are all on the object [into] picks.
  bool _hasOption(
    Map<String, Object?> Function() entry,
    Map<String, Object?>? Function(Map<String, Object?> body) into,
  ) {
    final body = _decoded;
    if (body == null) return false;
    final target = into(body);
    return target != null && entry().keys.every(target.containsKey);
  }

  /// The body itself, for the two top-level options.
  Map<String, Object?> _topLevel(Map<String, Object?> body) => body;

  /// The currency the body says, whatever it says.
  ///
  /// Not narrowed to [currencies] any more. It used to fall back to the
  /// first of the three, so a body hand-edited to `"currency": "PLN"` was
  /// shown as EUR -- the screen contradicting itself, which is the one thing
  /// every field on it is built not to do. Nothing minted wrongly, because
  /// the dropdown only writes when it is changed, but the person could not
  /// see that.
  String get _currency {
    final currency = _decoded?['currency'];
    return currency is String && currency.isNotEmpty
        ? currency
        : currencies.first;
  }

  /// What the dropdown offers: the three this app knows, plus whatever the
  /// body says if that is something else.
  ///
  /// Offered rather than merely displayed because a
  /// `DropdownButtonFormField` whose value is not among its items throws.
  /// Picking one of the three replaces the odd one, which is the way back.
  List<String> get _currencyChoices =>
      currencies.contains(_currency) ? currencies : [_currency, ...currencies];

  /// Whether what is on screen can be minted at all.
  bool get _runnable =>
      _problem == null && _fields.every((field) => field.problem == null);

  /// Whether what is on screen differs from what the store has.
  ///
  /// Measured against the text rather than against the decoded body, because
  /// a person who reformatted the JSON and left would want to be asked too.
  bool get _dirty => _raw.text != _savedBody;

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

  /// Runs one store write, and says so when the phone refuses it.
  ///
  /// `PresetStore` rethrows to its caller on purpose -- "better that this one
  /// save fails and the caller is told" -- and this screen is that caller. It
  /// used to tell nobody: no message, no "Saved.", and an unhandled async
  /// error in the zone, leaving the person to infer a failure from the
  /// absence of a confirmation.
  ///
  /// The same shape `run.dart` catches its History write with, and it answers
  /// whether the write landed so that every caller below can decline to act
  /// as though it had.
  Future<bool> _wrote(Future<void> Function() write, String problem) async {
    try {
      await write();
      return true;
    } catch (_) {
      // The type is not named. Nothing here came from outside the app, and
      // the person can only do one thing about any of it: try again.
      if (mounted) _say(problem);
      return false;
    }
  }

  /// Says what just happened, on the channel the rest of this app says it on.
  void _say(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  /// Writes the body over whatever this screen is editing.
  ///
  /// Refused while the body does not parse: a saved body that cannot be
  /// minted is a tile that fails every time somebody presses it, and nothing
  /// on Home would say why.
  Future<void> _save() async {
    if (!_runnable) return;
    final body = _raw.text;
    final id = _id;
    if (id == null) return;
    // Nothing has changed since this screen opened or last saved. Writing
    // anyway filed an override identical to the shipped bytes, after which
    // the tile read "edited" for good -- and a later release that changed
    // that preset would have been silently masked by the stale copy.
    if (body == _savedBody) {
      _say('Nothing to save.');
      return;
    }
    final wrote = switch (_kind) {
      // Back to the bytes it ships with is the absence of an edit rather
      // than an edit that happens to match, so the override goes instead of
      // being rewritten to agree with it.
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
    // The baseline only moves on a write that landed. Advancing it after a
    // refusal would disarm the unsaved-changes guard, which is the one thing
    // standing between a failed save and a lost edit.
    if (!wrote || !mounted) return;
    setState(() => _savedBody = body);
    _say('Saved.');
  }

  /// Makes a tile of its own out of what is on screen, and edits that from
  /// then on.
  ///
  /// Becoming the new tile is the point: without it a second Save would make
  /// a second tile, and somebody adjusting a body they had just named would
  /// end up with a row of near-identical presets.
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
          // Dead until there is a name. A nameless tile is a blank row on
          // Home that nobody can tell from another one.
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
      // Becoming a tile that was never written would leave the next Save
      // writing to an id nothing holds.
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

  /// Puts the body, every view of it and the store back to what the preset
  /// ships with.
  ///
  /// Explicit rather than leaning on the raw controller's listener: a reset
  /// that only had a complaint about an empty box to clear would change no
  /// text at all, so the listener would never fire and the complaint would
  /// stand over a body that no longer deserved it.
  Future<void> _resetToDefault() async {
    final id = _id;
    if (_kind == PresetKind.builtIn && id != null) {
      // The screen and the store have to agree. Putting the body back while
      // the override survived would show the shipped bytes here and "edited"
      // on the tile behind it.
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

  /// Removes the tile, then leaves: staying would leave this screen editing
  /// something that is no longer on Home, and Save would quietly put it back.
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
          // Cancel is the filled button and holds the focus, the way the Live
          // confirmation does: the default action of this dialog is to keep
          // what somebody made.
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
    // Leaving would say the tile had gone when it had not.
    if (!wrote || !mounted) return;
    // Straight `pop`, which does not consult the guard below -- there is
    // nothing left to save the changes into.
    Navigator.of(context).pop();
  }

  /// Lays the raw body out again. Dead while it does not parse.
  void _format() => setState(() => _rewrite((_) {}));

  /// Asks before an edit is lost, and answers whether to go.
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
    // Always false, with the decision made in the callback. `canPop` is read
    // as the pop happens, so a flag flipped a frame earlier would be a race;
    // and `Navigator.pop` from inside the callback pops for real, because
    // only `maybePop` -- the back button and the system gesture -- consults
    // this at all.
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
            // The currency belongs with the amount, so the two halves of one
            // figure are read together. It is also the field the owner named:
            // picking it again on every run is what made this screen a chore.
            if (field.name == 'amount') ...[
              DropdownButtonFormField<String>(
                // Keyed on the value, not a constant: `initialValue` seeds the
                // FormField's own state once, so after a reset the body would
                // revert while the dropdown still showed the last choice. A
                // changed key rebuilds the field from the body.
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
          // Test only. On a production merchant a fabricated New York
          // address is what AVS and fraud rules exist to refuse, so a switch
          // that adds one would cost a smoke run and teach nothing about the
          // SDK.
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
                  _setOption(sandboxAddressEntry, _customerFor, on),
            ),
          const SizedBox(height: 8),
          Card(
            child: ExpansionTile(
              key: const ValueKey('rawBodySection'),
              title: const Text(rawBodySectionLabel),
              // Whether the body parses, on screen whether the section is open
              // or shut. It is the one fact that decides if Run works.
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
              // Absent rather than dead on the Custom body: there is no tile
              // behind it to write over, and a button that could never work
              // is a button that only raises the question.
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
              // A preset somebody made has no default to go back to; a
              // built-in and the Custom body both do.
              if (_kind != PresetKind.custom)
                OutlinedButton(
                  key: const ValueKey('resetToDefault'),
                  onPressed: _resetToDefault,
                  child: const Text('Reset to default'),
                ),
              // Only what somebody made. Deleting a built-in would take a
              // scenario out of the app that the matrix still runs and the
              // guide still names.
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
