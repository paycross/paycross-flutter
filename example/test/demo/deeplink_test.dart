import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/deeplink.dart';
import 'package:paycross_demo/demo/environment.dart';
import 'package:paycross_demo/demo/presets.dart';

import '_environment.dart';

void main() {
  group('parseDeepLink', () {
    test('names the preset a run link asks for', () {
      final parsed = parseDeepLink(
        Uri.parse(
          'paycross-flutter-demo://run?preset=Frictionless%203DS&surface=sheet',
        ),
      );

      expect(parsed, isA<DeepLinkRun>());
      expect((parsed as DeepLinkRun).preset.name, 'Frictionless 3DS');
    });

    test('surface defaults to the only surface this app has', () {
      final parsed = parseDeepLink(
        Uri.parse('paycross-flutter-demo://run?preset=Frictionless%203DS'),
      );

      expect(parsed, isA<DeepLinkRun>());
    });

    test("the native demo's scheme is not ours and is ignored", () {
      expect(
        parseDeepLink(Uri.parse('paycross-demo://run?scenario=x')),
        isA<DeepLinkIgnored>(),
      );
    });

    test('an unknown host is ignored', () {
      expect(
        parseDeepLink(Uri.parse('paycross-flutter-demo://result')),
        isA<DeepLinkIgnored>(),
      );
    });

    test('a missing preset is rejected with a reason', () {
      final parsed = parseDeepLink(
        Uri.parse('paycross-flutter-demo://run?surface=sheet'),
      );

      expect(parsed, isA<DeepLinkRejected>());
      expect((parsed as DeepLinkRejected).reason, contains('preset'));
    });

    test('an unknown preset names what it could not find', () {
      final parsed = parseDeepLink(
        Uri.parse('paycross-flutter-demo://run?preset=nope'),
      );

      expect(parsed, isA<DeepLinkRejected>());
      expect((parsed as DeepLinkRejected).reason, contains('nope'));
    });

    test('Custom is refused rather than silently ignored', () {
      final parsed = parseDeepLink(
        Uri.parse('paycross-flutter-demo://run?preset=${customPreset.name}'),
      );

      expect(parsed, isA<DeepLinkRejected>());
      expect((parsed as DeepLinkRejected).reason, contains(customPreset.name));
    });

    test('a surface this app cannot present is rejected, not guessed', () {
      final parsed = parseDeepLink(
        Uri.parse(
          'paycross-flutter-demo://run?preset=Frictionless%203DS&surface=browser',
        ),
      );

      expect(parsed, isA<DeepLinkRejected>());
      expect((parsed as DeepLinkRejected).reason, contains('browser'));
    });

    test('an arrow preset is reachable by its dashed slug', () {
      final parsed = parseDeepLink(
        Uri.parse('paycross-flutter-demo://run?preset=3ds-challenge-approve'),
      );

      expect(parsed, isA<DeepLinkRun>());
      expect(
        (parsed as DeepLinkRun).preset.name,
        '3DS challenge \u2192 approve',
      );
    });

    test('an arrow preset survives being percent-encoded by hand', () {
      final parsed = parseDeepLink(
        Uri.parse(
          'paycross-flutter-demo://run'
          '?preset=3DS%20challenge%20%E2%86%92%20approve',
        ),
      );

      expect(parsed, isA<DeepLinkRun>());
      expect(
        (parsed as DeepLinkRun).preset.name,
        '3DS challenge \u2192 approve',
      );
    });

    test('every preset is reachable by its slug as well as its name', () {
      for (final preset in demoPresets) {
        final uri = Uri(
          scheme: demoScheme,
          host: 'run',
          queryParameters: {'preset': presetSlug(preset.name)},
        );
        final parsed = parseDeepLink(uri);

        expect(parsed, isA<DeepLinkRun>(), reason: preset.name);
        expect((parsed as DeepLinkRun).preset.name, preset.name);
      }
    });

    test('no two presets share a slug', () {
      final slugs = [for (final p in demoPresets) presetSlug(p.name)];

      expect(slugs, everyElement(isNotEmpty));
      expect(slugs.toSet(), hasLength(slugs.length));
    });

    test('every preset is reachable by its own name', () {
      for (final preset in demoPresets) {
        final uri = Uri(
          scheme: demoScheme,
          host: 'run',
          queryParameters: {'preset': preset.name},
        );

        expect(parseDeepLink(uri), isA<DeepLinkRun>(), reason: preset.name);
      }
    });

    test('a run link is refused in Live, with the reason on it', () {
      final refused = parseDeepLink(
        Uri.parse('paycross-flutter-demo://run?preset=frictionless-3ds'),
        environment: DemoEnvironment.live,
      );

      expect(refused, isA<DeepLinkRejected>());
      expect(
        (refused as DeepLinkRejected).reason,
        'Live mode — links are disabled',
      );
    });

    test('a link that is not ours is still ignored in Live', () {
      expect(
        parseDeepLink(
          Uri.parse('paycross-demo://run?preset=x'),
          environment: DemoEnvironment.live,
        ),
        isA<DeepLinkIgnored>(),
      );
    });

    test('Test is exactly what it was', () {
      expect(
        parseDeepLink(
          Uri.parse('paycross-flutter-demo://run?preset=frictionless-3ds'),
        ),
        isA<DeepLinkRun>(),
      );
    });
  });

  group('DeepLinkListener', () {
    testWidgets('hands a run link to its callback', (tester) async {
      final links = StreamController<Uri>();
      addTearDown(links.close);
      final started = <String>[];

      await tester.pumpWidget(
        MaterialApp(
          home: DeepLinkListener(
            links: links.stream,
            onRun: (preset) => started.add(preset.name),
            child: const SizedBox.shrink(),
          ),
        ),
      );

      links.add(
        Uri.parse('paycross-flutter-demo://run?preset=Frictionless%203DS'),
      );
      await tester.pumpAndSettle();

      expect(started, ['Frictionless 3DS']);
    });

    testWidgets('a link that is not ours starts nothing', (tester) async {
      final links = StreamController<Uri>();
      addTearDown(links.close);
      final started = <String>[];

      await tester.pumpWidget(
        MaterialApp(
          home: DeepLinkListener(
            links: links.stream,
            onRun: (preset) => started.add(preset.name),
            child: const SizedBox.shrink(),
          ),
        ),
      );

      links.add(Uri.parse('paycross-demo://run?scenario=x'));
      await tester.pumpAndSettle();

      expect(started, isEmpty);
    });

    testWidgets('a link this app cannot honour says so on screen', (
      tester,
    ) async {
      final links = StreamController<Uri>();
      addTearDown(links.close);
      final started = <String>[];

      await tester.pumpWidget(
        MaterialApp(
          home: DeepLinkListener(
            links: links.stream,
            onRun: (preset) => started.add(preset.name),
            child: const Scaffold(body: SizedBox.shrink()),
          ),
        ),
      );

      links.add(Uri.parse('paycross-flutter-demo://run?preset=nope'));
      await tester.pumpAndSettle();

      expect(find.textContaining('nope'), findsOneWidget);
      expect(started, isEmpty);
      expect(tester.takeException(), isNull);

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('a stream error is reported rather than thrown', (
      tester,
    ) async {
      final links = StreamController<Uri>();
      addTearDown(links.close);

      await tester.pumpWidget(
        MaterialApp(
          home: DeepLinkListener(
            links: links.stream,
            onRun: (_) {},
            child: const Scaffold(body: SizedBox.shrink()),
          ),
        ),
      );

      links.addError(StateError('the platform said no'));
      await tester.pumpAndSettle();

      expect(find.text('Could not read the link: StateError'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(find.textContaining('the platform said no'), findsNothing);

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('the subscription is dropped on dispose', (tester) async {
      final links = StreamController<Uri>();
      addTearDown(links.close);

      await tester.pumpWidget(
        MaterialApp(
          home: DeepLinkListener(
            links: links.stream,
            onRun: (_) {},
            child: const SizedBox.shrink(),
          ),
        ),
      );
      expect(links.hasListener, isTrue);

      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

      expect(links.hasListener, isFalse);
    });

    testWidgets('a run link in Live starts nothing and says why', (
      tester,
    ) async {
      final links = StreamController<Uri>();
      addTearDown(links.close);
      final started = <String>[];

      await tester.pumpWidget(
        await liveApp(
          home: DeepLinkListener(
            links: links.stream,
            onRun: (preset) => started.add(preset.name),
            child: const Scaffold(body: SizedBox.shrink()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      links.add(
        Uri.parse('paycross-flutter-demo://run?preset=Frictionless%203DS'),
      );
      await tester.pumpAndSettle();

      expect(started, isEmpty);
      expect(find.text('Live mode — links are disabled'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });
  });
}
