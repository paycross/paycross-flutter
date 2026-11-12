import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'environment.dart';
import 'presets.dart';

const String _testPresetsKey = 'paycross_demo_presets';

const String _livePresetsKey = 'paycross_demo_presets_live';

const String customIdPrefix = 'custom-';

const Duration _writeTimeout = Duration(seconds: 5);

final Expando<Future<void>> _writeQueues = Expando<Future<void>>();

enum PresetKind { builtIn, custom, scratch }

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

  Map<String, Object?> toJson(String kind) => {
    'kind': kind,
    'id': id,
    'name': name,
    'body': body,
  };

  Preset asPreset({String? expected}) => Preset(
    id: id,
    name: name,
    body: body,
    expected: expected ?? customPreset.expected,
  );
}

const String _overrideKind = 'override';

const String _customKind = 'custom';

const String _liveOverrideKind = 'live-override';
const String _liveCustomKind = 'live-custom';

class SavedPresets {
  const SavedPresets({
    this.overrides = const <String, String>{},
    this.custom = const <CustomPreset>[],
  });

  final Map<String, String> overrides;

  final List<CustomPreset> custom;

  String bodyFor(Preset preset) => overrides[preset.id] ?? preset.body;

  bool isEdited(Preset preset) => overrides.containsKey(preset.id);
}

abstract interface class PresetBackend {
  Future<List<String>> read();
  Future<void> write(List<String> rows);
}

class SharedPreferencesPresetBackend implements PresetBackend {
  const SharedPreferencesPresetBackend([
    this.environment = DemoEnvironment.test,
  ]);

  final DemoEnvironment environment;

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

class InMemoryPresetBackend implements PresetBackend {
  List<String> rows = <String>[];

  @override
  Future<List<String>> read() async => List<String>.from(rows);

  @override
  Future<void> write(List<String> written) async =>
      rows = List<String>.from(written);
}

class PresetStore {
  const PresetStore({
    this.environment = DemoEnvironment.test,
    PresetBackend? backend,
  })
    // ignore: prefer_initializing_formals
    : _given = backend;

  final DemoEnvironment environment;

  final PresetBackend? _given;

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

  String get _overrideWord => switch (environment) {
    DemoEnvironment.test => _overrideKind,
    DemoEnvironment.live => _liveOverrideKind,
  };

  String get _customWord => switch (environment) {
    DemoEnvironment.test => _customKind,
    DemoEnvironment.live => _liveCustomKind,
  };

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
          continue;
        }
      } catch (_) {
        continue;
      }
    }
    return SavedPresets(overrides: overrides, custom: custom);
  }

  Future<void> saveOverride(String id, String body) => _rewrite(
    (rows) => [
      ...rows.where((row) => !_isOverrideOf(row, id)),
      jsonEncode({'kind': _overrideWord, 'id': id, 'body': body}),
    ],
  );

  Future<void> clearOverride(String id) =>
      _rewrite((rows) => rows.where((row) => !_isOverrideOf(row, id)).toList());

  Future<CustomPreset> addCustom({
    required String name,
    required String body,
  }) async {
    final preset = CustomPreset(
      id: '$customIdPrefix${DateTime.now().microsecondsSinceEpoch}',
      name: name,
      body: body,
    );
    await _rewrite((rows) => [...rows, jsonEncode(preset.toJson(_customWord))]);
    return preset;
  }

  Future<void> updateCustom(CustomPreset preset) => _rewrite(
    (rows) => [
      for (final row in rows)
        if (_isCustomWithId(row, preset.id))
          jsonEncode(preset.toJson(_customWord))
        else
          row,
    ],
  );

  Future<void> deleteCustom(String id) => _rewrite(
    (rows) => rows.where((row) => !_isCustomWithId(row, id)).toList(),
  );

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

  Future<void> _rewrite(List<String> Function(List<String> rows) edit) {
    final queued = _writeQueues[_backend] ?? Future<void>.value();
    final written = queued.then((_) async {
      await _backend.write(edit(await _backend.read()));
    });
    _writeQueues[_backend] = written
        .timeout(_writeTimeout, onTimeout: () {})
        .catchError((Object _) {});
    return written;
  }
}
