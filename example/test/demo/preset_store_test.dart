import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/environment.dart';
import 'package:paycross_demo/demo/live.dart';
import 'package:paycross_demo/demo/preset_store.dart';
import 'package:paycross_demo/demo/presets.dart';

/// A store whose first write fails and whose later ones do not, which is
/// what a device that was briefly out of space looks like.
class _FailOnceBackend implements PresetBackend {
  bool _failed = false;
  List<String> rows = <String>[];

  @override
  Future<List<String>> read() async => List<String>.from(rows);

  @override
  Future<void> write(List<String> written) async {
    if (!_failed) {
      _failed = true;
      throw StateError('no space');
    }
    rows = List<String>.from(written);
  }
}

/// A store nothing is behind, which is what `SharedPreferences` is under
/// `flutter test` and what an app whose platform store is missing sees.
class _ThrowingBackend implements PresetBackend {
  @override
  Future<List<String>> read() async => throw StateError('no store');

  @override
  Future<void> write(List<String> written) async =>
      throw StateError('no store');
}

final _builtIn = demoPresets.first;

void main() {
  test('an override survives a round trip through the store', () async {
    final store = PresetStore(backend: InMemoryPresetBackend());

    await store.saveOverride(_builtIn.id!, '{"amount":2500}');
    final saved = await store.read();

    expect(saved.overrides[_builtIn.id], '{"amount":2500}');
  });

  test('a preset with no override reads as the bytes it ships with', () async {
    final saved = await PresetStore(backend: InMemoryPresetBackend()).read();

    // The whole point of keeping overrides in a store rather than in the
    // preset list: the automated matrix runs `demoPresets`, and an app with
    // an empty store has to hand back exactly what it always did.
    expect(saved.bodyFor(_builtIn), _builtIn.body);
    expect(saved.isEdited(_builtIn), isFalse);
  });

  test('an overridden preset reads back edited, and says so', () async {
    final store = PresetStore(backend: InMemoryPresetBackend());

    await store.saveOverride(_builtIn.id!, '{"amount":2500}');
    final saved = await store.read();

    expect(saved.bodyFor(_builtIn), '{"amount":2500}');
    expect(saved.isEdited(_builtIn), isTrue);
    // And the preset in code is untouched, which is what the matrix runs.
    expect(_builtIn.body, isNot('{"amount":2500}'));
  });

  test('saving an override twice keeps one row, the newer one', () async {
    final backend = InMemoryPresetBackend();
    final store = PresetStore(backend: backend);

    await store.saveOverride(_builtIn.id!, '{"amount":2500}');
    await store.saveOverride(_builtIn.id!, '{"amount":3000}');

    expect(backend.rows, hasLength(1));
    expect((await store.read()).overrides[_builtIn.id], '{"amount":3000}');
  });

  test('clearing an override puts the shipped body back', () async {
    final store = PresetStore(backend: InMemoryPresetBackend());

    await store.saveOverride(_builtIn.id!, '{"amount":2500}');
    await store.clearOverride(_builtIn.id!);
    final saved = await store.read();

    expect(saved.overrides, isEmpty);
    expect(saved.bodyFor(_builtIn), _builtIn.body);
  });

  test('custom presets come back in the order they were made', () async {
    final store = PresetStore(backend: InMemoryPresetBackend());

    await store.addCustom(name: 'First', body: '{"amount":1}');
    await store.addCustom(name: 'Second', body: '{"amount":2}');
    await store.addCustom(name: 'Third', body: '{"amount":3}');

    expect((await store.read()).custom.map((p) => p.name), [
      'First',
      'Second',
      'Third',
    ]);
  });

  test('a custom preset gets an id of its own', () async {
    final store = PresetStore(backend: InMemoryPresetBackend());

    final first = await store.addCustom(name: 'First', body: '{"amount":1}');
    final second = await store.addCustom(name: 'Second', body: '{"amount":2}');

    expect(first.id, isNot(second.id));
    // Prefixed, so nothing somebody makes can ever collide with a built-in
    // id and silently override a shipped tile.
    for (final preset in demoPresets) {
      expect(first.id, isNot(preset.id));
    }
  });

  test('updating a custom preset keeps its place in the list', () async {
    final store = PresetStore(backend: InMemoryPresetBackend());

    await store.addCustom(name: 'First', body: '{"amount":1}');
    final second = await store.addCustom(name: 'Second', body: '{"amount":2}');
    await store.addCustom(name: 'Third', body: '{"amount":3}');

    await store.updateCustom(
      CustomPreset(id: second.id, name: 'Renamed', body: '{"amount":22}'),
    );
    final custom = (await store.read()).custom;

    expect(custom.map((p) => p.name), ['First', 'Renamed', 'Third']);
    expect(custom[1].body, '{"amount":22}');
  });

  test('deleting a custom preset takes only that one', () async {
    final store = PresetStore(backend: InMemoryPresetBackend());

    await store.addCustom(name: 'First', body: '{"amount":1}');
    final second = await store.addCustom(name: 'Second', body: '{"amount":2}');
    await store.addCustom(name: 'Third', body: '{"amount":3}');

    await store.deleteCustom(second.id);

    expect((await store.read()).custom.map((p) => p.name), ['First', 'Third']);
  });

  test('a custom preset renders as a tile carrying its own id', () async {
    final store = PresetStore(backend: InMemoryPresetBackend());

    final saved = await store.addCustom(name: 'Mine', body: '{"amount":1}');
    final tile = saved.asPreset();

    expect(tile.id, saved.id);
    expect(tile.name, 'Mine');
    expect(tile.body, '{"amount":1}');
    // A tile with nothing to say about what should happen says who does.
    expect(tile.expected, customPreset.expected);
  });

  test('one corrupt row does not take the rest of the store with it', () async {
    // A process killed mid-write leaves a truncated last line, and a build
    // older than the current shape leaves a row this cannot parse. Neither
    // is worth throwing away the presets somebody saved correctly.
    final backend = InMemoryPresetBackend()
      ..rows = [
        jsonEncode({
          'kind': 'custom',
          'id': 'custom-1',
          'name': 'Mine',
          'body': '{"amount":1}',
        }),
        '{"kind": "custom", "id": "custom-2", "na',
      ];

    expect((await PresetStore(backend: backend).read()).custom, hasLength(1));
  });

  test('a row of an unknown kind is dropped, not guessed at', () async {
    final backend = InMemoryPresetBackend()
      ..rows = [
        jsonEncode({'kind': 'something-newer', 'id': 'x', 'body': '{}'}),
      ];

    final saved = await PresetStore(backend: backend).read();

    expect(saved.custom, isEmpty);
    expect(saved.overrides, isEmpty);
  });

  test('a store that cannot be read at all reads as empty', () async {
    // An app with no saved presets is a usable app; an exception on the way
    // to Home is not. `SharedPreferences` under `flutter test` is exactly
    // this, which is why every widget test gets the shipped bodies.
    final saved = await PresetStore(backend: _ThrowingBackend()).read();

    expect(saved.overrides, isEmpty);
    expect(saved.custom, isEmpty);
  });

  test('two saves landing at once both survive', () async {
    // Every mutator is read-modify-write over one key. Unserialised, both
    // reads see the old list and the second write drops the first one's row.
    final store = PresetStore(backend: InMemoryPresetBackend());

    await Future.wait([
      store.addCustom(name: 'First', body: '{"amount":1}'),
      store.addCustom(name: 'Second', body: '{"amount":2}'),
    ]);

    expect((await store.read()).custom.map((p) => p.name).toSet(), {
      'First',
      'Second',
    });
  });

  test('a write that fails does not stop the next one', () async {
    // The queue is what serialises the writes, so a link that threw must not
    // be what every later save is still waiting on. The caller still sees
    // the failure.
    final store = PresetStore(backend: _FailOnceBackend());

    await expectLater(
      store.addCustom(name: 'First', body: '{"amount":1}'),
      throwsStateError,
    );
    await store.addCustom(name: 'Second', body: '{"amount":2}');

    expect((await store.read()).custom.single.name, 'Second');
  });

  test('every built-in preset has a stable id, and no two share one', () {
    // The id is what an edit is filed under, and it is deliberately duller
    // than the name: a re-worded tile must not lose somebody's saved body,
    // and two tiles sharing an id would show each other's edits.
    final ids = [for (final preset in demoPresets) preset.id];

    expect(ids, everyElement(isNotNull));
    expect(ids.toSet(), hasLength(ids.length));
  });

  test('a preset nothing can be saved into has no id', () {
    // Custom is the blank body, and a Live tile is built per run from an
    // identity held in memory. Neither is a row in any store, and a null id
    // is what makes that true by construction rather than by care.
    expect(customPreset.id, isNull);
  });

  group('the two halves of the store', () {
    test('Live and Test write different keys', () {
      // The addendum's rule, and it is a rule about storage rather than
      // about care: a body saved in one mode is never offered in the other
      // because a read in one mode cannot see the other's rows at all.
      const sandbox = SharedPreferencesPresetBackend(DemoEnvironment.test);
      const production = SharedPreferencesPresetBackend(DemoEnvironment.live);

      expect(sandbox.storageKey, isNot(production.storageKey));
    });

    test('the Test key is the one that shipped', () {
      // Changing it would silently empty every preset a colleague has
      // already saved, and an empty Home reads as the feature having been
      // taken away rather than as the key having moved.
      expect(
        const SharedPreferencesPresetBackend(DemoEnvironment.test).storageKey,
        'paycross_demo_presets',
      );
    });

    test('Test is what a backend defaults to', () {
      // Every call site written before Live had presets means the sandbox
      // half, and a default that meant the other one would file a sandbox
      // edit where the production tiles read.
      expect(
        const SharedPreferencesPresetBackend().storageKey,
        const SharedPreferencesPresetBackend(DemoEnvironment.test).storageKey,
      );
    });

    test('a Live scenario round-trips like any other preset', () async {
      // The same store and the same code path. What makes a preset Live is
      // which half its row is in, not a second type with its own rules.
      final store = PresetStore(backend: InMemoryPresetBackend());
      final preset = liveDefaultPresets.first;

      await store.saveOverride(preset.id!, '{"amount":4250}');
      final saved = await store.read();

      expect(saved.bodyFor(preset), '{"amount":4250}');
      expect(saved.isEdited(preset), isTrue);
    });

    test('a Test read drops rows a Live store wrote', () async {
      // Defence in depth behind the separate key. If a Live row ever landed
      // in the sandbox key -- a migration, a merge, a bug -- reading it as a
      // sandbox tile would put a production body on a sandbox screen. The
      // kind word is not one this half knows, and an unknown kind is dropped
      // rather than guessed at.
      //
      // One backend deliberately, which is the only way to stage the mixing
      // the separate keys otherwise make impossible.
      final backend = InMemoryPresetBackend();
      final production = PresetStore(
        backend: backend,
        environment: DemoEnvironment.live,
      );
      await production.addCustom(name: 'Live only', body: '{"amount":1}');
      await production.saveOverride(
        liveDefaultPresets.first.id!,
        '{"amount":2}',
      );

      final asSandbox = await PresetStore(backend: backend).read();

      expect(asSandbox.custom, isEmpty);
      expect(asSandbox.overrides, isEmpty);
      // And the calibration: the rows are there, and the half that wrote
      // them reads them perfectly well.
      expect(backend.rows, hasLength(2));
      expect((await production.read()).custom, hasLength(1));
      expect((await production.read()).overrides, hasLength(1));
    });

    test('a Live read drops rows a Test store wrote', () async {
      final backend = InMemoryPresetBackend();
      final sandbox = PresetStore(backend: backend);
      await sandbox.addCustom(name: 'Sandbox only', body: '{"amount":1}');

      final asProduction = await PresetStore(
        backend: backend,
        environment: DemoEnvironment.live,
      ).read();

      expect(asProduction.custom, isEmpty);
      expect(backend.rows, hasLength(1));
    });

    test('a body saved in one half is not offered in the other', () async {
      final sandbox = PresetStore(backend: InMemoryPresetBackend());
      final production = PresetStore(
        backend: InMemoryPresetBackend(),
        environment: DemoEnvironment.live,
      );

      await production.addCustom(name: 'Live only', body: '{"amount":4250}');
      await production.saveOverride(
        liveDefaultPresets.first.id!,
        '{"amount":4250}',
      );
      final read = await sandbox.read();

      expect(read.custom, isEmpty);
      expect(read.overrides, isEmpty);
      // And the sandbox tiles still mint the bytes they ship with.
      expect(read.bodyFor(demoPresets.first), demoPresets.first.body);
    });
  });
}
