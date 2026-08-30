import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/deeplink.dart';
import 'package:paycross_demo/demo/presets.dart';

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
      // com.paycross.demo owns paycross-demo://run and ://result and lives
      // on the same phones. Answering one of its links would be worse than
      // ignoring it.
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
      // The one preset Home offers that is not in `demoPresets`: it opens the
      // editor because nobody but the person typing knows what body it should
      // carry, and a link cannot answer that. Refusing by name is what makes
      // the refusal say so on screen instead of the link doing nothing at all.
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
      // The whole point of telling a rejection from something ignored: a
      // colleague who mistypes a preset name over adb gets the reason on the
      // phone rather than an app that appears to have missed the link.
      final links = StreamController<Uri>();
      addTearDown(links.close);
      final started = <String>[];

      await tester.pumpWidget(
        MaterialApp(
          home: DeepLinkListener(
            links: links.stream,
            onRun: (preset) => started.add(preset.name),
            // A Scaffold, unlike the other three tests here, because that is
            // how the app mounts this: over Home. `showSnackBar` asserts it
            // has a Scaffold to present over, so a bare box would be testing
            // an arrangement the app never builds.
            child: const Scaffold(body: SizedBox.shrink()),
          ),
        ),
      );

      links.add(Uri.parse('paycross-flutter-demo://run?preset=nope'));
      await tester.pumpAndSettle();

      expect(find.textContaining('nope'), findsOneWidget);
      expect(started, isEmpty);
      expect(tester.takeException(), isNull);

      // Let the snack bar time itself out; a pending timer fails the test.
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
  });
}
