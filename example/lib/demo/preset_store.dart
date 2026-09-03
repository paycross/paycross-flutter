import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'environment.dart';
import 'presets.dart';

/// The key the sandbox presets have always been written to.
///
/// Unchanged on purpose: moving it would silently empty every preset a
/// colleague has already saved, and an empty Home reads as the feature
/// having been taken away rather than as the key having moved.
const String _testPresetsKey = 'paycross_demo_presets';

/// Where the production presets go.
///
/// A second key rather than a `mode` column in one list, and that is what
/// makes "a body saved in one mode is never offered in the other" a fact
/// about storage rather than a filter somebody has to remember to apply. A
/// read in Live cannot see the sandbox rows at all.
const String _livePresetsKey = 'paycross_demo_presets_live';

/// The prefix every id this store generates carries.
///
/// So that nothing somebody saves can ever collide with a built-in id and
/// silently start overriding a shipped tile. Built-in ids are words a
/// maintainer typed; these are not.
const String customIdPrefix = 'custom-';

/// How long one queued write gets before the queue moves on without it.
///
/// A platform store with nothing behind it does not fail, it never answers --
/// and an unbounded queue would then never write another preset for the rest
/// of the process. The same bound `history.dart` puts on its own queue, for
/// the same reason.
const Duration _writeTimeout = Duration(seconds: 5);

/// The write in flight for a given backend, so two saves queue up instead of
/// overwriting each other.
///
/// Keyed on the backend rather than held in a field, exactly as
/// `history.dart` keys its own: every [SharedPreferencesPresetBackend] is the
/// same canonical const instance, so the app gets one queue over the one key
/// it writes, and a test's own backend is a distinct object with a queue of
/// its own.
final Expando<Future<void>> _writeQueues = Expando<Future<void>>();

/// What the editor is allowed to save this preset into.
///
/// An argument the screen is given rather than something it works out from
/// the preset in front of it. Home is the only place that knows which of the
/// three a tile is, and a guess made twice is a guess that can differ.
enum PresetKind {
  /// A tile from `demoPresets`. Save writes an override under its id;
  /// "Reset to default" removes it and the shipped body comes back.
  builtIn,

  /// A tile somebody made. Save writes it back in place; Delete removes it.
  custom,

  /// The Custom tile's blank body. There is nothing to save into, so
  /// "Save as new…" is the only way it becomes a tile.
  scratch,
}

/// One preset somebody made, as it is stored.
class CustomPreset {
  const CustomPreset({
    required this.id,
    required this.name,
    required this.body,
  });

  factory CustomPreset.fromJson(Map<String, Object?> json) => CustomPreset(
    id: json['id']! as String,
    name: json['name']! as String,
    body: json['body']! as String,
  );

  final String id;
  final String name;
  final String body;

  /// [kind] is the store's, not this record's: which word a row carries is
  /// the store's business, because it is the store that has to recognise it
  /// again on the way back.
  Map<String, Object?> toJson(String kind) => {
    'kind': kind,
    'id': id,
    'name': name,
    'body': body,
  };

  /// The tile this renders as on Home, and what the editor and a run are
  /// handed.
  ///
  /// [expected] defaults to `customPreset`'s sentence: a body somebody typed
  /// is a body only they know the outcome of, and that is as true of a saved
  /// one as of a scratch one. Live passes its own, because a body somebody
  /// typed is still a real charge and "whatever the edited body asks for" is
  /// not what a tester needs to read above a production Continue button.
  Preset asPreset({String? expected}) => Preset(
    id: id,
    name: name,
    body: body,
    expected: expected ?? customPreset.expected,
  );
}

/// The word a sandbox override row is filed under.
const String _overrideKind = 'override';

/// The word a sandbox custom-preset row is filed under.
const String _customKind = 'custom';

/// The same two for production, and deliberately different words.
///
/// The two halves are already separate `SharedPreferences` keys, so a build
/// reading the sandbox key never sees a production row. These are the second
/// line: if a Live row ever did land in the sandbox key -- a migration, a
/// merge, a bug -- reading it as a sandbox tile would put a production body
/// on a sandbox screen. [PresetStore.read] drops a row whose kind it does not
/// know rather than guessing, so the row is skipped instead.
///
/// It also makes a row self-describing. A record read out of context says
/// which environment it belongs to without anybody having to know which key
/// it came out of.
const String _liveOverrideKind = 'live-override';
const String _liveCustomKind = 'live-custom';

/// Everything a person has saved: their edits to the built-in tiles, and the
/// tiles they made.
///
/// One value read once, rather than two reads a screen has to keep in step.
class SavedPresets {
  const SavedPresets({
    this.overrides = const <String, String>{},
    this.custom = const <CustomPreset>[],
  });

  /// Edited bodies, by the built-in preset's [Preset.id].
  final Map<String, String> overrides;

  /// The tiles somebody made, in the order they made them.
  final List<CustomPreset> custom;

  /// What [preset] should actually mint: the saved body if there is one, and
  /// otherwise the bytes it ships with.
  ///
  /// The one place the two are chosen between. `demoPresets` is what the
  /// automated matrix runs and its bodies are pinned to the byte, so an
  /// override lives here and never there.
  String bodyFor(Preset preset) => overrides[preset.id] ?? preset.body;

  /// Whether somebody has saved an edit to [preset].
  ///
  /// What the tile's "edited" marker reads. A preset with no id can never be
  /// edited, and `null` is not a key any override is filed under, so this is
  /// false for Custom and for every Live tile without asking.
  bool isEdited(Preset preset) => overrides.containsKey(preset.id);
}

/// The slice of a key-value store the presets need.
abstract interface class PresetBackend {
  Future<List<String>> read();
  Future<void> write(List<String> rows);
}

/// Plain `SharedPreferences`: a session body holds no credential, and the
/// secure store is slower and smaller.
///
/// A body can name a customer reference and an amount, which is exactly what
/// the same body already carries in code.
class SharedPreferencesPresetBackend implements PresetBackend {
  /// Defaulted to the sandbox half, because every call site written before
  /// Live had presets means that one -- and a default that meant production
  /// would file a sandbox edit where the Live tiles read.
  const SharedPreferencesPresetBackend([
    this.environment = DemoEnvironment.test,
  ]);

  /// Which half of the store this backend is.
  final DemoEnvironment environment;

  /// The one key this backend reads and writes.
  ///
  /// Public because which key a mode uses is the whole of the separation
  /// between the two halves, and a rule that matters that much is worth
  /// being able to assert on directly.
  String get storageKey => switch (environment) {
    DemoEnvironment.test => _testPresetsKey,
    DemoEnvironment.live => _livePresetsKey,
  };

  @override
  Future<List<String>> read() async =>
      (await SharedPreferences.getInstance()).getStringList(storageKey) ??
      const <String>[];

  @override
  Future<void> write(List<String> rows) async =>
      (await SharedPreferences.getInstance()).setStringList(storageKey, rows);
}

/// A [PresetBackend] in a list. Tests only.
class InMemoryPresetBackend implements PresetBackend {
  List<String> rows = <String>[];

  @override
  Future<List<String>> read() async => List<String>.from(rows);

  @override
  Future<void> write(List<String> written) async =>
      rows = List<String>.from(written);
}

/// The presets a person has saved on this phone.
///
/// One key holding a JSON row per record, which is `history.dart`'s shape and
/// is chosen for its reason: a row this build cannot parse costs that row
/// rather than everything somebody saved. Custom presets keep their order
/// because the rows do.
///
/// There is no cap, unlike History. A history grows by itself and nobody
/// prunes one; presets are made and deleted by hand, and a cap would throw
/// away the tile somebody made on the day they made too many.
class PresetStore {
  const PresetStore({
    this.environment = DemoEnvironment.test,
    PresetBackend? backend,
  }) // The lint's own fix does not compile: Dart forbids a private NAMED
    // parameter, so `this._backend` cannot appear in a `{...}` list, and a
    // public backend is not what this class is for.
    // ignore: prefer_initializing_formals
    : _given = backend;

  /// Which half of the store this is: which key it reads, and which words its
  /// rows carry.
  ///
  /// Defaulted to the sandbox, because every call site written before Live
  /// had presets means that one.
  final DemoEnvironment environment;

  /// The backend a test handed in, or null for the real one.
  final PresetBackend? _given;

  /// The backend this store actually uses.
  ///
  /// The two defaults are `const` literals rather than a value built per
  /// call, and that matters: the write queue below is keyed on the backend
  /// object, so a fresh instance each time would give every write a queue of
  /// its own and serialise nothing.
  PresetBackend get _backend =>
      _given ??
      switch (environment) {
        DemoEnvironment.test => const SharedPreferencesPresetBackend(
          DemoEnvironment.test,
        ),
        DemoEnvironment.live => const SharedPreferencesPresetBackend(
          DemoEnvironment.live,
        ),
      };

  /// The word this half files an override under.
  String get _overrideWord => switch (environment) {
    DemoEnvironment.test => _overrideKind,
    DemoEnvironment.live => _liveOverrideKind,
  };

  /// The word this half files a preset somebody made under.
  String get _customWord => switch (environment) {
    DemoEnvironment.test => _customKind,
    DemoEnvironment.live => _liveCustomKind,
  };

  /// Everything saved on this phone, or nothing at all.
  ///
  /// Per row, so one unreadable record costs one record. A store this cannot
  /// reach at all reads as empty rather than throwing: `SharedPreferences`
  /// under `flutter test` has no platform behind it, and Home has to build
  /// either way -- with the shipped bodies, which is the honest answer when
  /// nothing could be read.
  Future<SavedPresets> read() async {
    final List<String> rows;
    try {
      rows = await _backend.read();
    } catch (_) {
      return const SavedPresets();
    }
    final overrides = <String, String>{};
    final custom = <CustomPreset>[];
    for (final row in rows) {
      try {
        final json = jsonDecode(row) as Map<String, Object?>;
        final kind = json['kind'];
        if (kind == _overrideWord) {
          overrides[json['id']! as String] = json['body']! as String;
        } else if (kind == _customWord) {
          custom.add(CustomPreset.fromJson(json));
        } else {
          // A row a newer build wrote, or one belonging to the other half of
          // the store. Dropped rather than guessed at: rendering it as one of
          // the two shapes this half knows would show somebody a tile that is
          // not the one they saved -- and, across halves, would put a
          // production body on a sandbox screen.
          continue;
        }
      } catch (_) {
        // This one row only.
        continue;
      }
    }
    return SavedPresets(overrides: overrides, custom: custom);
  }

  /// Files [body] as the edit to the built-in preset called [id].
  Future<void> saveOverride(String id, String body) => _rewrite(
    (rows) => [
      ...rows.where((row) => !_isOverrideOf(row, id)),
      jsonEncode({'kind': _overrideWord, 'id': id, 'body': body}),
    ],
  );

  /// Forgets the edit to the built-in preset called [id], so the bytes it
  /// ships with come back.
  Future<void> clearOverride(String id) =>
      _rewrite((rows) => rows.where((row) => !_isOverrideOf(row, id)).toList());

  /// Makes a new tile, at the end of the list, and answers what was made.
  ///
  /// The id is generated here rather than taken from the caller: it is the
  /// one field nobody types and the one field two tiles must not share.
  Future<CustomPreset> addCustom({
    required String name,
    required String body,
  }) async {
    final preset = CustomPreset(
      // The clock, prefixed. Unique enough for a list somebody edits by hand
      // -- two taps cannot land in the same microsecond -- and no new package
      // for a value that is only ever compared for equality.
      id: '$customIdPrefix${DateTime.now().microsecondsSinceEpoch}',
      name: name,
      body: body,
    );
    await _rewrite((rows) => [...rows, jsonEncode(preset.toJson(_customWord))]);
    return preset;
  }

  /// Writes [preset] back over the row with its id, keeping its place.
  ///
  /// In place rather than removed and appended: the order on Home is the
  /// order somebody made their tiles in, and a tile that jumped to the bottom
  /// every time it was saved would be a list that never settles.
  Future<void> updateCustom(CustomPreset preset) => _rewrite(
    (rows) => [
      for (final row in rows)
        if (_isCustomWithId(row, preset.id))
          jsonEncode(preset.toJson(_customWord))
        else
          row,
    ],
  );

  /// Removes the tile called [id].
  Future<void> deleteCustom(String id) => _rewrite(
    (rows) => rows.where((row) => !_isCustomWithId(row, id)).toList(),
  );

  /// Whether [row] is the override filed under [id].
  ///
  /// Read off the row rather than by re-encoding the whole store, so a row
  /// this build cannot parse is left exactly as it is instead of being
  /// dropped by a save that had nothing to do with it.
  bool _isOverrideOf(String row, String id) => _rowIs(row, _overrideWord, id);

  bool _isCustomWithId(String row, String id) => _rowIs(row, _customWord, id);

  bool _rowIs(String row, String kind, String id) {
    try {
      final json = jsonDecode(row) as Map<String, Object?>;
      return json['kind'] == kind && json['id'] == id;
    } catch (_) {
      return false;
    }
  }

  /// Reads the rows, applies [edit], and writes them back -- one write at a
  /// time across the whole process.
  ///
  /// Every mutator above is read-modify-write over a single key. Two saves
  /// landing at once would both read the old rows and the second write would
  /// drop the first one's, silently and only under a race nobody would
  /// reproduce on purpose.
  Future<void> _rewrite(List<String> Function(List<String> rows) edit) {
    final queued = _writeQueues[_backend] ?? Future<void>.value();
    final written = queued.then((_) async {
      // Unguarded, unlike [read]: a save built on an empty list because the
      // store could not be read would delete everything that is actually in
      // it. Better that this one save fails and the caller is told.
      await _backend.write(edit(await _backend.read()));
    });
    // What the queue waits on is deliberately neither this write's failure
    // nor its silence: one unwritable or unanswering store must not stop
    // every save after it. The caller still sees both.
    _writeQueues[_backend] = written
        .timeout(_writeTimeout, onTimeout: () {})
        .catchError((Object _) {});
    return written;
  }
}
