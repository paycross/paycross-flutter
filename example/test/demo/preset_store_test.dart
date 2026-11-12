import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/environment.dart';
import 'package:paycross_demo/demo/live.dart';
import 'package:paycross_demo/demo/preset_store.dart';
import 'package:paycross_demo/demo/presets.dart';

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

    expect(saved.bodyFor(_builtIn), _builtIn.body);
    expect(saved.isEdited(_builtIn), isFalse);
  });

  test('an overridden preset reads back edited, and says so', () async {
    final store = PresetStore(backend: InMemoryPresetBackend());

    await store.saveOverride(_builtIn.id!, '{"amount":2500}');
    final saved = await store.read();

    expect(saved.bodyFor(_builtIn), '{"amount":2500}');
    expect(saved.isEdited(_builtIn), isTrue);
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
    expect(tile.expected, customPreset.expected);
  });

  test('one corrupt row does not take the rest of the store with it', () async {
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
    final saved = await PresetStore(backend: _ThrowingBackend()).read();

    expect(saved.overrides, isEmpty);
    expect(saved.custom, isEmpty);
  });

  test('two saves landing at once both survive', () async {
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
    final store = PresetStore(backend: _FailOnceBackend());

    await expectLater(
      store.addCustom(name: 'First', body: '{"amount":1}'),
      throwsStateError,
    );
    await store.addCustom(name: 'Second', body: '{"amount":2}');

    expect((await store.read()).custom.single.name, 'Second');
  });

  test('every built-in preset has a stable id, and no two share one', () {
    final ids = [for (final preset in demoPresets) preset.id];

    expect(ids, everyElement(isNotNull));
    expect(ids.toSet(), hasLength(ids.length));
  });

  test('a preset nothing can be saved into has no id', () {
    expect(customPreset.id, isNull);
  });

  group('the two halves of the store', () {
    test('Live and Test write different keys', () {
      const sandbox = SharedPreferencesPresetBackend(DemoEnvironment.test);
      const production = SharedPreferencesPresetBackend(DemoEnvironment.live);

      expect(sandbox.storageKey, isNot(production.storageKey));
    });

    test('the Test key is the one that shipped', () {
      expect(
        const SharedPreferencesPresetBackend(DemoEnvironment.test).storageKey,
        'paycross_demo_presets',
      );
    });

    test('Test is what a backend defaults to', () {
      expect(
        const SharedPreferencesPresetBackend().storageKey,
        const SharedPreferencesPresetBackend(DemoEnvironment.test).storageKey,
      );
    });

    test('a Live scenario round-trips like any other preset', () async {
      final store = PresetStore(backend: InMemoryPresetBackend());
      final preset = liveDefaultPresets.first;

      await store.saveOverride(preset.id!, '{"amount":4250}');
      final saved = await store.read();

      expect(saved.bodyFor(preset), '{"amount":4250}');
      expect(saved.isEdited(preset), isTrue);
    });

    test('a Test read drops rows a Live store wrote', () async {
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
      expect(read.bodyFor(demoPresets.first), demoPresets.first.body);
    });
  });
}
