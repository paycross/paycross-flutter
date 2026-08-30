import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/editor.dart';
import 'package:paycross_demo/demo/presets.dart';

import '_surface.dart';

final _preset = demoPresets.first;

void main() {
  testWidgets('opens on the preset body and hands it back unchanged', (
    tester,
  ) async {
    useTallSurface(tester);
    String? ran;
    await tester.pumpWidget(
      MaterialApp(
        home: EditorScreen(preset: _preset, onRun: (body) => ran = body),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();

    expect(jsonDecode(ran!), jsonDecode(_preset.body));
  });

  testWidgets('changing the amount rewrites the body', (tester) async {
    useTallSurface(tester);
    String? ran;
    await tester.pumpWidget(
      MaterialApp(
        home: EditorScreen(preset: _preset, onRun: (body) => ran = body),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const ValueKey('amount')), '2500');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();

    expect((jsonDecode(ran!) as Map)['amount'], 2500);
  });

  testWidgets('Run is refused while the body is not JSON', (tester) async {
    useTallSurface(tester);
    var ranCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: EditorScreen(preset: _preset, onRun: (_) => ranCount++),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const ValueKey('rawBody')), '{ nope');
    await tester.pumpAndSettle();

    expect(find.textContaining('not valid JSON'), findsOneWidget);
    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();
    expect(ranCount, 0);
  });

  testWidgets('the currency dropdown rewrites the body', (tester) async {
    useTallSurface(tester);
    String? ran;
    await tester.pumpWidget(
      MaterialApp(
        home: EditorScreen(preset: _preset, onRun: (body) => ran = body),
      ),
    );
    await tester.pumpAndSettle();

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
    useTallSurface(tester);
    String? ran;
    await tester.pumpWidget(
      MaterialApp(
        home: EditorScreen(preset: _preset, onRun: (body) => ran = body),
      ),
    );
    await tester.pumpAndSettle();

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

  testWidgets('the save-card switch adds and removes save_card_config', (
    tester,
  ) async {
    useTallSurface(tester);
    String? ran;
    await tester.pumpWidget(
      MaterialApp(
        home: EditorScreen(preset: _preset, onRun: (body) => ran = body),
      ),
    );
    await tester.pumpAndSettle();

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

  testWidgets('reset puts the currency dropdown back too, not just the body', (
    tester,
  ) async {
    useTallSurface(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: EditorScreen(preset: _preset, onRun: (_) {}),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('currency-EUR')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('USD').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('currency-USD')), findsOneWidget);

    await tester.tap(find.text('Reset to preset'));
    await tester.pumpAndSettle();

    // Without the value in the key this still reads USD while the body says
    // EUR -- nothing mints wrongly, but the screen contradicts itself.
    expect(find.byKey(const ValueKey('currency-EUR')), findsOneWidget);
  });

  testWidgets('reset to preset undoes an edit', (tester) async {
    useTallSurface(tester);
    String? ran;
    await tester.pumpWidget(
      MaterialApp(
        home: EditorScreen(preset: _preset, onRun: (body) => ran = body),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const ValueKey('rawBody')), '{"a":1}');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset to preset'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();

    expect(jsonDecode(ran!), jsonDecode(_preset.body));
  });
}
