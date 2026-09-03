import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/editor.dart';
import 'package:paycross_demo/demo/preset_store.dart';
import 'package:paycross_demo/demo/presets.dart';

import '_surface.dart';

final _preset = demoPresets.first;

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
}) async {
  useTallSurface(tester);
  await tester.pumpWidget(
    MaterialApp(
      home: EditorScreen(
        preset: preset ?? _preset,
        onRun: onRun ?? (_) async {},
        kind: kind,
        savedBody: savedBody,
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
}
