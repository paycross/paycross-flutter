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
      // U+2192 is E2 86 92 in UTF-8. This is what comes out of a shell when
      // somebody pastes the name off the screen, and it has to reach the
      // same preset the slug does.
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
      // Two that did would make one of them unreachable by slug, and which
      // one won would depend on the order of the list.
      final slugs = [for (final p in demoPresets) presetSlug(p.name)];

      // An empty slug would also match every degenerate link, so a preset
      // whose name slugifies away is a collision with all of them at once.
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

      // Rejected, never ignored: a link that quietly did nothing reads as a
      // broken build, and the person who fired it is holding the phone.
      expect(refused, isA<DeepLinkRejected>());
      expect(
        (refused as DeepLinkRejected).reason,
        'Live mode — links are disabled',
      );
    });

    test('a link that is not ours is still ignored in Live', () {
      // Addressed to another app. Rejecting it would put this app's snackbar
      // on somebody else's link.
      expect(
        parseDeepLink(
          Uri.parse('paycross-demo://run?preset=x'),
          environment: DemoEnvironment.live,
        ),
        isA<DeepLinkIgnored>(),
      );
    });

    test('Test is exactly what it was', () {
      // The default argument is what keeps every case above this one meaning
      // what it meant.
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

      // app_links forwards whatever the native EventChannel raises. With no
      // onError this is an async error with nobody to own it.
      links.addError(StateError('the platform said no'));
      await tester.pumpAndSettle();

      expect(find.text('Could not read the link: StateError'), findsOneWidget);
      expect(tester.takeException(), isNull);
      // The message itself stays off the screen: it is native text and the
      // one thing on this path that came from outside the app.
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
      // The composed half of the three parse cases above: the listener reads
      // the environment out of the scope the app mounts above the Navigator,
      // so a link that arrives in Live is refused with the reason on screen
      // rather than honoured or dropped.
      final links = StreamController<Uri>();
      addTearDown(links.close);
      final started = <String>[];

      await tester.pumpWidget(
        await liveApp(
          home: DeepLinkListener(
            links: links.stream,
            onRun: (preset) => started.add(preset.name),
            // A Scaffold for the same reason the rejection case above uses
            // one: `showSnackBar` needs something to present over, and this
            // is how the app mounts the listener -- over Home.
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
