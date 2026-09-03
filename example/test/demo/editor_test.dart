import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/editor.dart';
import 'package:paycross_demo/demo/environment.dart';
import 'package:paycross_demo/demo/live.dart';
import 'package:paycross_demo/demo/preset_store.dart';
import 'package:paycross_demo/demo/presets.dart';

import '_surface.dart';

final _preset = demoPresets.first;

/// A store the phone refuses to write to, which is what a device out of
/// space, or one whose platform store is wedged, looks like from Dart.
class _FailingPresetBackend implements PresetBackend {
  @override
  Future<List<String>> read() async => <String>[];

  @override
  Future<void> write(List<String> rows) async => throw StateError('no space');
}

/// The text a keyed field is showing.
String _fieldText(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;

/// Opens the collapsible section the raw body lives in.
///
/// The section is shut when the screen opens, which is the whole of what
/// makes the editor a form rather than a wall of JSON. Every case that wants
/// the raw field has to say so, exactly as a person does.
Future<void> _openRawBody(WidgetTester tester) async {
  await tester.tap(find.text(rawBodySectionLabel));
  await tester.pumpAndSettle();
}

/// The editor on its own, the way most of these cases want it.
Future<void> _pumpEditor(
  WidgetTester tester, {
  Preset? preset,
  Future<void> Function(String body)? onRun,
  PresetKind kind = PresetKind.builtIn,
  PresetStore? store,
  String? savedBody,
  DemoEnvironment environment = DemoEnvironment.test,
}) async {
  useTallSurface(tester);
  await tester.pumpWidget(
    MaterialApp(
      home: EditorScreen(
        preset: preset ?? _preset,
        onRun: onRun ?? (_) async {},
        kind: kind,
        savedBody: savedBody,
        environment: environment,
        store: store ?? PresetStore(backend: InMemoryPresetBackend()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The editor with something under it, for the cases about leaving it.
///
/// A pushed route rather than `home:`: the unsaved-changes guard is about
/// what happens on the way back, and a screen with nothing behind it has no
/// back to test.
Future<void> _pushEditor(
  WidgetTester tester, {
  PresetKind kind = PresetKind.builtIn,
  PresetStore? store,
  Preset? preset,
}) async {
  useTallSurface(tester);
  final editor = EditorScreen(
    preset: preset ?? _preset,
    onRun: (_) async {},
    kind: kind,
    store: store ?? PresetStore(backend: InMemoryPresetBackend()),
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute<void>(builder: (_) => editor)),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('opens on the preset body and hands it back unchanged', (
    tester,
  ) async {
    String? ran;
    await _pumpEditor(tester, onRun: (body) async => ran = body);

    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();

    expect(jsonDecode(ran!), jsonDecode(_preset.body));
  });

  testWidgets('opens on the saved body when there is one', (tester) async {
    String? ran;
    await _pumpEditor(
      tester,
      onRun: (body) async => ran = body,
      savedBody: '{"amount":4242,"currency":"GBP"}',
    );

    // The whole point of saving one: a scenario somebody edited opens the way
    // they left it, rather than making them type the currency again.
    expect(_fieldText(tester, 'amount'), '4242');
    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();
    expect((jsonDecode(ran!) as Map)['amount'], 4242);
  });

  testWidgets('changing the amount rewrites the body', (tester) async {
    String? ran;
    await _pumpEditor(tester, onRun: (body) async => ran = body);

    await tester.enterText(find.byKey(const ValueKey('amount')), '2500');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();

    expect((jsonDecode(ran!) as Map)['amount'], 2500);
  });

  testWidgets('Run is refused while the body is not JSON', (tester) async {
    var ranCount = 0;
    await _pumpEditor(tester, onRun: (_) async => ranCount++);

    await _openRawBody(tester);
    await tester.enterText(find.byKey(const ValueKey('rawBody')), '{ nope');
    await tester.pumpAndSettle();

    expect(find.textContaining('not valid JSON'), findsOneWidget);
    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();
    expect(ranCount, 0);
  });

  testWidgets('the raw body is out of the way until it is asked for', (
    tester,
  ) async {
    await _pumpEditor(tester);

    // The complaint the owner made about this screen was that it is clunky,
    // and a 24-line JSON field above the buttons is most of why.
    expect(find.byKey(const ValueKey('rawBody')), findsNothing);

    await _openRawBody(tester);

    expect(find.byKey(const ValueKey('rawBody')), findsOneWidget);
  });

  testWidgets('the section says whether the body parses without opening it', (
    tester,
  ) async {
    await _pumpEditor(tester);

    expect(find.text(rawBodyValidLabel), findsOneWidget);

    await _openRawBody(tester);
    await tester.enterText(find.byKey(const ValueKey('rawBody')), '{ nope');
    await tester.pumpAndSettle();
    await tester.tap(find.text(rawBodySectionLabel));
    await tester.pumpAndSettle();

    // Shut again, and the reason Run is dead is still on screen. A person who
    // collapsed the section would otherwise be left with a dead button and
    // nothing saying why.
    expect(find.byKey(const ValueKey('rawBody')), findsNothing);
    expect(find.textContaining('not valid JSON'), findsOneWidget);
  });

  testWidgets('Format lays the body out again', (tester) async {
    await _pumpEditor(tester);

    await _openRawBody(tester);
    await tester.enterText(
      find.byKey(const ValueKey('rawBody')),
      '{"amount":1,"customer":{"merchant_reference":"CUST-1"}}',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Format'));
    await tester.pumpAndSettle();

    final text = _fieldText(tester, 'rawBody');
    expect(text, contains('\n'));
    expect(jsonDecode(text), {
      'amount': 1,
      'customer': {'merchant_reference': 'CUST-1'},
    });
  });

  testWidgets('the currency dropdown rewrites the body', (tester) async {
    String? ran;
    await _pumpEditor(tester, onRun: (body) async => ran = body);

    await tester.tap(find.byKey(const ValueKey('currency-EUR')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('USD').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();

    expect((jsonDecode(ran!) as Map)['currency'], 'USD');
  });

  testWidgets('the customer reference is what a saved card is found by', (
    tester,
  ) async {
    String? ran;
    await _pumpEditor(tester, onRun: (body) async => ran = body);

    await tester.enterText(
      find.byKey(const ValueKey('customerReference')),
      'harness_cof_customer',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();

    final customer = (jsonDecode(ran!) as Map)['customer'] as Map;
    expect(customer['merchant_reference'], 'harness_cof_customer');
  });

  testWidgets('the three customer name fields rewrite the body', (
    tester,
  ) async {
    String? ran;
    await _pumpEditor(tester, onRun: (body) async => ran = body);

    await tester.enterText(
      find.byKey(const ValueKey('customerEmail')),
      'ada@example.com',
    );
    await tester.enterText(find.byKey(const ValueKey('customerFirst')), 'Ada');
    await tester.enterText(
      find.byKey(const ValueKey('customerLast')),
      'Lovelace',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();

    final customer = (jsonDecode(ran!) as Map)['customer'] as Map;
    expect(customer['email'], 'ada@example.com');
    expect(customer['first_name'], 'Ada');
    expect(customer['last_name'], 'Lovelace');
  });

  testWidgets('the save-card switch adds and removes save_card_config', (
    tester,
  ) async {
    String? ran;
    await _pumpEditor(tester, onRun: (body) async => ran = body);

    await tester.tap(find.byKey(const ValueKey('saveCard')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();
    expect((jsonDecode(ran!) as Map)['save_card_config'], {
      'usage': 'card_on_file',
    });

    await tester.tap(find.byKey(const ValueKey('saveCard')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();
    expect((jsonDecode(ran!) as Map).containsKey('save_card_config'), isFalse);
  });

  testWidgets('the saved-cards switch adds and removes saved_cards', (
    tester,
  ) async {
    String? ran;
    await _pumpEditor(tester, onRun: (body) async => ran = body);

    await tester.tap(find.byKey(const ValueKey('showSavedCards')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();
    expect((jsonDecode(ran!) as Map)['saved_cards'], {'show': 'all'});

    await tester.tap(find.byKey(const ValueKey('showSavedCards')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();
    expect((jsonDecode(ran!) as Map).containsKey('saved_cards'), isFalse);
  });

  testWidgets('the billing switch sends the sandbox address, or nothing', (
    tester,
  ) async {
    String? ran;
    await _pumpEditor(tester, onRun: (body) async => ran = body);

    // Every sandbox preset ships with it, so the switch opens on.
    await tester.tap(find.byKey(const ValueKey('sandboxBilling')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();
    expect(
      ((jsonDecode(ran!) as Map)['customer'] as Map).containsKey('address'),
      isFalse,
    );

    await tester.tap(find.byKey(const ValueKey('sandboxBilling')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();
    final address =
        ((jsonDecode(ran!) as Map)['customer'] as Map)['address'] as Map;
    expect(((address['billing'] as Map)['city']), 'New York');
  });

  testWidgets('reset puts the currency dropdown back too, not just the body', (
    tester,
  ) async {
    await _pumpEditor(tester);

    await tester.tap(find.byKey(const ValueKey('currency-EUR')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('USD').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('currency-USD')), findsOneWidget);

    await tester.tap(find.text('Reset to default'));
    await tester.pumpAndSettle();

    // Without the value in the key this still reads USD while the body says
    // EUR -- nothing mints wrongly, but the screen contradicts itself.
    expect(find.byKey(const ValueKey('currency-EUR')), findsOneWidget);
  });

  testWidgets('reset to default undoes an edit', (tester) async {
    String? ran;
    await _pumpEditor(tester, onRun: (body) async => ran = body);

    await _openRawBody(tester);
    await tester.enterText(find.byKey(const ValueKey('rawBody')), '{"a":1}');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset to default'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();

    expect(jsonDecode(ran!), jsonDecode(_preset.body));
  });

  testWidgets('Run cannot be pressed twice while the first is still going', (
    tester,
  ) async {
    var runs = 0;
    final gate = Completer<void>();
    await _pumpEditor(
      tester,
      onRun: (_) async {
        runs++;
        await gate.future;
      },
    );

    // What Run starts is a credential read and then a live mint. A second
    // press before the first has finished bills a second sandbox session and
    // stacks a second Run screen.
    await tester.tap(find.text('Run'));
    await tester.pump();
    await tester.tap(find.text('Run'), warnIfMissed: false);
    await tester.pump();

    expect(runs, 1);

    gate.complete();
    await tester.pumpAndSettle();

    // And it comes back afterwards: this is a guard, not a one-shot button.
    await tester.tap(find.text('Run'));
    await tester.pump();

    expect(runs, 2);
  });

  testWidgets('the boxes open showing what the body already says', (
    tester,
  ) async {
    await _pumpEditor(tester);

    // Empty boxes over a filled body made the screen contradict itself: the
    // amount said nothing while the body said 1000.
    final body = jsonDecode(_preset.body) as Map<String, Object?>;
    final customer = body['customer']! as Map;
    expect(_fieldText(tester, 'amount'), '${body['amount']}');
    expect(
      _fieldText(tester, 'customerReference'),
      customer['merchant_reference'],
    );
    expect(_fieldText(tester, 'customerEmail'), customer['email']);
    expect(_fieldText(tester, 'customerFirst'), customer['first_name']);
    expect(_fieldText(tester, 'customerLast'), customer['last_name']);
  });

  testWidgets('clearing the amount is refused, not silently ignored', (
    tester,
  ) async {
    var ranCount = 0;
    await _pumpEditor(tester, onRun: (_) async => ranCount++);

    await tester.enterText(find.byKey(const ValueKey('amount')), '2500');
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('amount')), '');
    await tester.pumpAndSettle();

    // Before this, an empty box left 2500 in the body and ran it anyway.
    expect(find.textContaining('whole number'), findsOneWidget);
    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();
    expect(ranCount, 0);
  });

  testWidgets('clearing the customer reference is refused too', (tester) async {
    var ranCount = 0;
    await _pumpEditor(tester, onRun: (_) async => ranCount++);

    await tester.enterText(find.byKey(const ValueKey('customerReference')), '');
    await tester.pumpAndSettle();

    expect(find.textContaining('cannot be empty'), findsOneWidget);
    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();
    expect(ranCount, 0);
  });

  testWidgets('editing the raw body moves the boxes with it', (tester) async {
    await _pumpEditor(tester);

    await _openRawBody(tester);
    await tester.enterText(
      find.byKey(const ValueKey('rawBody')),
      '{"amount":7777,"currency":"GBP","saved_cards":{"show":"all"},'
      '"customer":{"merchant_reference":"CUST-9","email":"ada@example.com",'
      '"first_name":"Ada","last_name":"Lovelace"}}',
    );
    await tester.pumpAndSettle();

    // The raw body is the source of truth; the boxes above it are a view of
    // it, so a hand edit must not leave them showing the old values.
    expect(_fieldText(tester, 'amount'), '7777');
    expect(_fieldText(tester, 'customerReference'), 'CUST-9');
    expect(_fieldText(tester, 'customerEmail'), 'ada@example.com');
    expect(_fieldText(tester, 'customerFirst'), 'Ada');
    expect(_fieldText(tester, 'customerLast'), 'Lovelace');
    expect(find.byKey(const ValueKey('currency-GBP')), findsOneWidget);
    expect(
      tester
          .widget<SwitchListTile>(find.byKey(const ValueKey('saveCard')))
          .value,
      isFalse,
    );
    expect(
      tester
          .widget<SwitchListTile>(find.byKey(const ValueKey('showSavedCards')))
          .value,
      isTrue,
    );
  });

  testWidgets('reset puts the boxes back as well as the body', (tester) async {
    await _pumpEditor(tester);

    await tester.enterText(find.byKey(const ValueKey('amount')), '');
    await tester.pumpAndSettle();
    expect(find.textContaining('whole number'), findsOneWidget);

    await tester.tap(find.text('Reset to default'));
    await tester.pumpAndSettle();

    final body = jsonDecode(_preset.body) as Map<String, Object?>;
    expect(_fieldText(tester, 'amount'), '${body['amount']}');
    expect(find.textContaining('whole number'), findsNothing);
  });

  group('saving', () {
    testWidgets('Save files the body against the built-in preset', (
      tester,
    ) async {
      final store = PresetStore(backend: InMemoryPresetBackend());
      await _pumpEditor(tester, store: store);

      await tester.enterText(find.byKey(const ValueKey('amount')), '2500');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved = await store.read();
      expect((jsonDecode(saved.overrides[_preset.id]!) as Map)['amount'], 2500);
      // And the shipped bytes are untouched, which is what the matrix runs.
      expect((jsonDecode(_preset.body) as Map)['amount'], 1000);
    });

    testWidgets('Save says it saved', (tester) async {
      await _pumpEditor(tester);

      await tester.enterText(find.byKey(const ValueKey('amount')), '2500');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.text('Saved.'), findsOneWidget);
    });

    testWidgets('Save is refused while the body is not JSON', (tester) async {
      final store = PresetStore(backend: InMemoryPresetBackend());
      await _pumpEditor(tester, store: store);

      await _openRawBody(tester);
      await tester.enterText(find.byKey(const ValueKey('rawBody')), '{ nope');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      // A saved body that cannot be minted is a tile that fails every time it
      // is pressed, and nothing on Home would say why.
      expect((await store.read()).overrides, isEmpty);
    });

    testWidgets('Save as new makes a tile of its own', (tester) async {
      final store = PresetStore(backend: InMemoryPresetBackend());
      await _pumpEditor(tester, store: store);

      await tester.enterText(find.byKey(const ValueKey('amount')), '2500');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save as new…'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('newPresetName')),
        'Two fifty',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('saveAsNewConfirm')));
      await tester.pumpAndSettle();

      final saved = await store.read();
      expect(saved.custom.single.name, 'Two fifty');
      expect((jsonDecode(saved.custom.single.body) as Map)['amount'], 2500);
      // The built-in it was made from keeps the body it shipped with.
      expect(saved.overrides, isEmpty);
    });

    testWidgets('a new tile needs a name', (tester) async {
      final store = PresetStore(backend: InMemoryPresetBackend());
      await _pumpEditor(tester, store: store);

      await tester.tap(find.text('Save as new…'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('saveAsNewConfirm')));
      await tester.pumpAndSettle();

      // A nameless tile is a blank row on Home nobody can tell from another.
      expect((await store.read()).custom, isEmpty);
      expect(find.byKey(const ValueKey('saveAsNewDialog')), findsOneWidget);
    });

    testWidgets('after Save as new, Save writes back to the new tile', (
      tester,
    ) async {
      final store = PresetStore(backend: InMemoryPresetBackend());
      await _pumpEditor(tester, store: store);

      await tester.tap(find.text('Save as new…'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('newPresetName')),
        'Mine',
      );
      // Settled before the tap, because the confirm button is dead until
      // there is a name and it takes a frame to hear that there is one.
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('saveAsNewConfirm')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const ValueKey('amount')), '4242');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('save')));
      await tester.pumpAndSettle();

      final saved = await store.read();
      // One tile, edited -- not a second tile every time Save is pressed.
      expect(saved.custom, hasLength(1));
      expect((jsonDecode(saved.custom.single.body) as Map)['amount'], 4242);
    });

    testWidgets('Reset to default forgets the saved body', (tester) async {
      final store = PresetStore(backend: InMemoryPresetBackend());
      await store.saveOverride(_preset.id!, '{"amount":2500}');
      await _pumpEditor(tester, store: store, savedBody: '{"amount":2500}');

      expect(_fieldText(tester, 'amount'), '2500');
      await tester.tap(find.text('Reset to default'));
      await tester.pumpAndSettle();

      expect((await store.read()).overrides, isEmpty);
      expect(_fieldText(tester, 'amount'), '1000');
    });

    testWidgets('a built-in preset cannot be deleted', (tester) async {
      await _pumpEditor(tester);

      // Deleting one would take a scenario out of the app that the matrix
      // still runs and the guide still names.
      expect(find.text('Delete'), findsNothing);
    });

    testWidgets('the Custom body has nothing to save into', (tester) async {
      await _pumpEditor(tester, preset: customPreset, kind: PresetKind.scratch);

      // Custom is the blank body somebody types afresh. "Save as new…" is how
      // it becomes a tile, and there is no tile behind it to save over.
      expect(find.text('Save'), findsNothing);
      expect(find.text('Delete'), findsNothing);
      expect(find.text('Save as new…'), findsOneWidget);
    });

    testWidgets('Delete asks first, and a refusal keeps the tile', (
      tester,
    ) async {
      final store = PresetStore(backend: InMemoryPresetBackend());
      final saved = await store.addCustom(name: 'Mine', body: _preset.body);
      await _pumpEditor(
        tester,
        preset: saved.asPreset(),
        kind: PresetKind.custom,
        store: store,
      );

      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('deleteCancel')));
      await tester.pumpAndSettle();

      expect((await store.read()).custom, hasLength(1));
    });

    testWidgets('Delete removes the tile and leaves the screen', (
      tester,
    ) async {
      final store = PresetStore(backend: InMemoryPresetBackend());
      final saved = await store.addCustom(name: 'Mine', body: _preset.body);
      useTallSurface(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => EditorScreen(
                      preset: saved.asPreset(),
                      onRun: (_) async {},
                      kind: PresetKind.custom,
                      store: store,
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('deleteConfirm')));
      await tester.pumpAndSettle();

      expect((await store.read()).custom, isEmpty);
      // Staying would leave the screen editing a tile that is no longer on
      // Home, and Save would quietly put it back.
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('a custom preset has no default to reset to', (tester) async {
      final store = PresetStore(backend: InMemoryPresetBackend());
      final saved = await store.addCustom(name: 'Mine', body: _preset.body);
      await _pumpEditor(
        tester,
        preset: saved.asPreset(),
        kind: PresetKind.custom,
        store: store,
      );

      expect(find.text('Reset to default'), findsNothing);
      expect(find.text('Delete'), findsOneWidget);
    });
  });

  group('leaving with unsaved changes', () {
    testWidgets('leaving an untouched editor asks nothing', (tester) async {
      await _pushEditor(tester);

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('an edited body is asked about before it is lost', (
      tester,
    ) async {
      await _pushEditor(tester);

      await tester.enterText(find.byKey(const ValueKey('amount')), '2500');
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('unsavedDialog')), findsOneWidget);
    });

    testWidgets('keep editing stays on the screen', (tester) async {
      await _pushEditor(tester);

      await tester.enterText(find.byKey(const ValueKey('amount')), '2500');
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('keepEditing')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('amount')), findsOneWidget);
      expect(_fieldText(tester, 'amount'), '2500');
    });

    testWidgets('discard leaves', (tester) async {
      await _pushEditor(tester);

      await tester.enterText(find.byKey(const ValueKey('amount')), '2500');
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('discardChanges')));
      await tester.pumpAndSettle();

      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('a saved body is not an unsaved change', (tester) async {
      await _pushEditor(tester);

      await tester.enterText(find.byKey(const ValueKey('amount')), '2500');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.text('open'), findsOneWidget);
    });
  });

  group('the same editor in Live', () {
    final smoke = liveDefaultPresets.first;

    /// The Live editor on one of the three production tiles.
    Future<void> pumpLive(
      WidgetTester tester, {
      PresetStore? store,
      String? savedBody,
      Future<void> Function(String body)? onRun,
    }) => _pumpEditor(
      tester,
      preset: smoke,
      onRun: onRun,
      // A Live-mode store, as Home hands it: its rows carry the production
      // kind words, so a case here exercises what the app writes.
      store:
          store ??
          PresetStore(
            backend: InMemoryPresetBackend(),
            environment: DemoEnvironment.live,
          ),
      savedBody: savedBody,
      environment: DemoEnvironment.live,
    );

    testWidgets('the amount and the currency are ordinary fields', (
      tester,
    ) async {
      // The whole of the addendum: the owner called setting a currency once
      // per session a lazy workaround, and this is what replaced it.
      String? ran;
      await pumpLive(tester, onRun: (body) async => ran = body);

      await tester.enterText(find.byKey(const ValueKey('amount')), '4250');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('currency-EUR')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('GBP').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();

      expect((jsonDecode(ran!) as Map)['amount'], 4250);
      expect((jsonDecode(ran!) as Map)['currency'], 'GBP');
    });

    testWidgets('there is nowhere to type an identity', (tester) async {
      // A preset is a row on the phone and the identity is held for one
      // session. A field that wrote a real person's name into a saved body
      // is the one thing this screen must not offer in Live.
      await pumpLive(tester);

      expect(find.byKey(const ValueKey('customerEmail')), findsNothing);
      expect(find.byKey(const ValueKey('customerFirst')), findsNothing);
      expect(find.byKey(const ValueKey('customerLast')), findsNothing);
      // The reference stays: it is what a stored card is found by, and it is
      // not anybody's name.
      expect(find.byKey(const ValueKey('customerReference')), findsOneWidget);
    });

    testWidgets('a Live body it saves carries no identity', (tester) async {
      final store = PresetStore(
        backend: InMemoryPresetBackend(),
        environment: DemoEnvironment.live,
      );
      await pumpLive(tester, store: store);

      await tester.enterText(find.byKey(const ValueKey('amount')), '4250');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('save')));
      await tester.pumpAndSettle();

      final saved = (await store.read()).overrides[smoke.id]!;
      final customer = (jsonDecode(saved) as Map)['customer'] as Map;
      for (final field in const ['email', 'first_name', 'last_name']) {
        expect(customer.containsKey(field), isFalse, reason: field);
      }
    });

    testWidgets('the sandbox billing switch is not offered', (tester) async {
      // Production AVS and fraud rules exist to refuse a fabricated New York
      // address, and a switch that adds one is a switch that costs a smoke
      // run for a reason that says nothing about the SDK.
      await pumpLive(tester);

      expect(find.byKey(const ValueKey('sandboxBilling')), findsNothing);
      // The two saved-card switches are the same in both modes.
      expect(find.byKey(const ValueKey('saveCard')), findsOneWidget);
      expect(find.byKey(const ValueKey('showSavedCards')), findsOneWidget);
    });

    testWidgets('a hand-typed billing address refuses Run and Save', (
      tester,
    ) async {
      // A refusal rather than a quiet strip. The raw body is the source of
      // truth on this screen, and silently deleting a line somebody typed is
      // how a tool stops being trustworthy.
      final store = PresetStore(
        backend: InMemoryPresetBackend(),
        environment: DemoEnvironment.live,
      );
      var ranCount = 0;
      await pumpLive(tester, store: store, onRun: (_) async => ranCount++);

      await _openRawBody(tester);
      await tester.enterText(
        find.byKey(const ValueKey('rawBody')),
        '{"amount":100,"currency":"EUR","customer":'
        '{"merchant_reference":"r","address":{"billing":{"city":"NY"}}}}',
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('billing address'), findsOneWidget);
      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('save')));
      await tester.pumpAndSettle();

      expect(ranCount, 0);
      expect((await store.read()).overrides, isEmpty);
    });

    testWidgets('the sandbox editor still offers both', (tester) async {
      // The mirror of the two cases above: nothing was taken away from Test.
      await _pumpEditor(tester);

      expect(find.byKey(const ValueKey('sandboxBilling')), findsOneWidget);
      expect(find.byKey(const ValueKey('customerEmail')), findsOneWidget);
    });

    testWidgets('Save as new makes a production tile of its own', (
      tester,
    ) async {
      final store = PresetStore(
        backend: InMemoryPresetBackend(),
        environment: DemoEnvironment.live,
      );
      await pumpLive(tester, store: store);

      await tester.enterText(find.byKey(const ValueKey('amount')), '4250');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save as new…'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('newPresetName')),
        'Forty-two fifty',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('saveAsNewConfirm')));
      await tester.pumpAndSettle();

      final saved = await store.read();
      expect(saved.custom.single.name, 'Forty-two fifty');
      expect((jsonDecode(saved.custom.single.body) as Map)['amount'], 4250);
    });

    testWidgets('Reset to default puts the shipped Live body back', (
      tester,
    ) async {
      final store = PresetStore(
        backend: InMemoryPresetBackend(),
        environment: DemoEnvironment.live,
      );
      await store.saveOverride(smoke.id!, '{"amount":4250,"currency":"GBP"}');
      await pumpLive(
        tester,
        store: store,
        savedBody: '{"amount":4250,"currency":"GBP"}',
      );

      expect(_fieldText(tester, 'amount'), '4250');
      await tester.tap(find.text('Reset to default'));
      await tester.pumpAndSettle();

      expect((await store.read()).overrides, isEmpty);
      expect(_fieldText(tester, 'amount'), '$liveSmokeMinorUnits');
    });
  });

  group('a save the phone refuses', () {
    testWidgets('Save says so, rather than failing silently', (tester) async {
      // `PresetStore` rethrows to its caller on purpose, and this screen is
      // that caller. Before this it told nobody: no message, no "Saved.",
      // and an unhandled async error in the zone. The person had to infer a
      // failure from the absence of a confirmation.
      await _pumpEditor(
        tester,
        store: PresetStore(backend: _FailingPresetBackend()),
      );

      await tester.enterText(find.byKey(const ValueKey('amount')), '2500');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('save')));
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not save'), findsOneWidget);
      expect(find.text('Saved.'), findsNothing);
    });

    testWidgets('the edit is still there to try again with', (tester) async {
      // The body must not be treated as saved: the unsaved-changes guard is
      // what stops the edit being lost on the way back, and a failed write
      // that advanced the baseline would disarm it.
      await _pushEditor(
        tester,
        store: PresetStore(backend: _FailingPresetBackend()),
      );

      await tester.enterText(find.byKey(const ValueKey('amount')), '2500');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('save')));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('unsavedDialog')), findsOneWidget);
    });

    testWidgets('Save as new says so too', (tester) async {
      await _pumpEditor(
        tester,
        store: PresetStore(backend: _FailingPresetBackend()),
      );

      await tester.tap(find.text('Save as new…'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('newPresetName')),
        'Mine',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('saveAsNewConfirm')));
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not save'), findsOneWidget);
      // And the screen is still editing what it was editing. Becoming a tile
      // that was never written would leave a later Save writing to an id
      // nothing holds.
      expect(find.text('Edit — ${_preset.name}'), findsOneWidget);
    });

    testWidgets('a refused delete keeps the tile and the screen', (
      tester,
    ) async {
      final store = PresetStore(backend: _FailingPresetBackend());
      await _pumpEditor(
        tester,
        preset: const CustomPreset(
          id: 'custom-1',
          name: 'Mine',
          body: '{"amount":1}',
        ).asPreset(),
        kind: PresetKind.custom,
        store: store,
      );

      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('deleteConfirm')));
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not delete'), findsOneWidget);
      // Still here. Leaving would say the tile had gone when it had not.
      expect(find.text('Edit — Mine'), findsOneWidget);
    });

    testWidgets('a refused reset leaves the body alone', (tester) async {
      // The screen and the store have to agree. Putting the body back while
      // the override survived would show the shipped bytes here and "edited"
      // on the tile behind it.
      await _pumpEditor(
        tester,
        store: PresetStore(backend: _FailingPresetBackend()),
        savedBody:
            '{"amount":2500,"currency":"EUR",'
            '"customer":{"merchant_reference":"CUST-1"}}',
      );

      await tester.tap(find.text('Reset to default'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not reset'), findsOneWidget);
      expect(_fieldText(tester, 'amount'), '2500');
    });
  });

  group('saving what nobody changed', () {
    testWidgets('Save on an untouched preset writes nothing', (tester) async {
      // It used to file an override identical to the shipped bytes, after
      // which the tile read "edited" for good -- and a later release that
      // changed that preset would be silently masked by the stale copy.
      final store = PresetStore(
        backend: InMemoryPresetBackend(),
        environment: DemoEnvironment.live,
      );
      await _pumpEditor(tester, store: store);

      await tester.tap(find.byKey(const ValueKey('save')));
      await tester.pumpAndSettle();

      expect((await store.read()).overrides, isEmpty);
      expect(find.text('Nothing to save.'), findsOneWidget);
    });

    testWidgets('putting the shipped body back drops the override', (
      tester,
    ) async {
      // Back to what it ships with is the absence of an edit, not an edit
      // that happens to match. Rewriting the override would leave the tile
      // marked "edited" over bytes nobody had changed -- and would go on
      // masking that preset if a later release changed it.
      //
      // Through the raw field, because that is the way a person actually
      // gets here: they open a tile they edited last week and paste the
      // original back.
      final store = PresetStore(
        backend: InMemoryPresetBackend(),
        environment: DemoEnvironment.live,
      );
      const override =
          '{"amount":2500,"currency":"EUR",'
          '"customer":{"merchant_reference":"CUST-1"}}';
      await store.saveOverride(_preset.id!, override);
      await _pumpEditor(tester, store: store, savedBody: override);

      await _openRawBody(tester);
      await tester.enterText(
        find.byKey(const ValueKey('rawBody')),
        _preset.body,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('save')));
      await tester.pumpAndSettle();

      expect((await store.read()).overrides, isEmpty);
      expect(find.text('Saved.'), findsOneWidget);
    });

    testWidgets('an edit that is a real change still writes', (tester) async {
      // The calibration for the two cases above: the guard refuses a
      // no-change Save, and this is what says it has not started refusing
      // every Save.
      final store = PresetStore(
        backend: InMemoryPresetBackend(),
        environment: DemoEnvironment.live,
      );
      await _pumpEditor(tester, store: store);

      await tester.enterText(find.byKey(const ValueKey('amount')), '2500');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('save')));
      await tester.pumpAndSettle();

      expect((await store.read()).overrides, hasLength(1));
    });
  });

  group('a body somebody hand-edited', () {
    testWidgets('a currency the app does not offer is shown, not hidden', (
      tester,
    ) async {
      // The dropdown fell back to EUR over a body that said PLN: the screen
      // contradicting itself, which is the one thing every field on it is
      // built not to do. Nothing minted wrongly, because the dropdown only
      // writes on change -- but the person could not see that.
      await _pumpEditor(tester);

      await _openRawBody(tester);
      await tester.enterText(
        find.byKey(const ValueKey('rawBody')),
        '{"amount":1000,"currency":"PLN",'
        '"customer":{"merchant_reference":"CUST-1"}}',
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('currency-PLN')), findsOneWidget);
      expect(find.byKey(const ValueKey('currency-EUR')), findsNothing);
    });

    testWidgets('picking a known currency replaces the unknown one', (
      tester,
    ) async {
      String? ran;
      await _pumpEditor(tester, onRun: (body) async => ran = body);

      await _openRawBody(tester);
      await tester.enterText(
        find.byKey(const ValueKey('rawBody')),
        '{"amount":1000,"currency":"PLN",'
        '"customer":{"merchant_reference":"CUST-1"}}',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('currency-PLN')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('GBP').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();

      expect((jsonDecode(ran!) as Map)['currency'], 'GBP');
    });

    testWidgets('a customer block deleted by hand is rebuilt, not ignored', (
      tester,
    ) async {
      // Typing into a field that wrote nowhere is the silent failure this
      // screen's whole design rule is against -- and a body with no customer
      // is one the create schema answers 400 to, so rebuilding it is the
      // repair as well as the fix.
      String? ran;
      await _pumpEditor(tester, onRun: (body) async => ran = body);

      await _openRawBody(tester);
      await tester.enterText(
        find.byKey(const ValueKey('rawBody')),
        '{"amount":1000,"currency":"EUR"}',
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('customerEmail')),
        'ada@example.com',
      );
      await tester.enterText(
        find.byKey(const ValueKey('customerReference')),
        'CUST-9',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();

      final customer = (jsonDecode(ran!) as Map)['customer'] as Map;
      expect(customer['email'], 'ada@example.com');
      expect(customer['merchant_reference'], 'CUST-9');
    });

    testWidgets('the billing switch rebuilds it too', (tester) async {
      String? ran;
      await _pumpEditor(tester, onRun: (body) async => ran = body);

      await _openRawBody(tester);
      await tester.enterText(
        find.byKey(const ValueKey('rawBody')),
        '{"amount":1000,"currency":"EUR"}',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sandboxBilling')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();

      final customer = (jsonDecode(ran!) as Map)['customer'] as Map;
      expect((customer['address'] as Map)['billing'], isA<Map>());
    });
  });
}
