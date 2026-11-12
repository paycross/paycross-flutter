import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/appearance_store.dart';
import 'package:paycross_demo/demo/environment.dart';
import 'package:paycross_demo/demo/home.dart';
import 'package:paycross_demo/demo/language.dart';
import 'package:paycross_demo/demo/minter.dart';
import 'package:paycross_demo/demo/presets.dart';
import 'package:paycross_demo/demo/run.dart';
import 'package:paycross_demo/demo/secrets.dart';
import 'package:paycross_demo/demo/settings.dart';
import 'package:paycross_demo/demo/wallets.dart';
import 'package:paycross_demo/main.dart' as app;
import 'package:paycross_flutter/paycross_flutter.dart';
// ignore: implementation_imports
import 'package:paycross_flutter/src/generated/paycross_api.g.dart' as g;

import 'demo/_environment.dart';
import 'demo/_surface.dart';

class _RecordingHost extends g.PayCrossHostApi {
  g.PcConfiguration? lastConfiguration;

  @override
  Future<void> configure(g.PcConfiguration configuration) async =>
      lastConfiguration = configuration;
}

class _ThrowsAfterFirstRead extends SecretStore {
  int reads = 0;

  @override
  Future<Credentials?> read() async {
    reads++;
    if (reads > 1) throw StateError('the keychain locked');
    return null;
  }
}

class _SlowBackend implements SecretBackend {
  final Completer<void> gate = Completer<void>();

  @override
  Future<String?> read(String key) async {
    await gate.future;
    return null;
  }

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}
}

class _NeverAnsweringSecretBackend implements SecretBackend {
  final Completer<String?> gate = Completer<String?>();

  @override
  Future<String?> read(String key) => gate.future;

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}
}

class _NeverAnsweringLanguageBackend implements LanguageBackend {
  final Completer<String?> gate = Completer<String?>();

  @override
  Future<String?> read() => gate.future;

  @override
  Future<void> write(String value) async {}
}

class _ThrowingLanguageBackend implements LanguageBackend {
  @override
  Future<String?> read() async => throw StateError('no preferences');

  @override
  Future<void> write(String value) async => throw StateError('no preferences');
}

class _NeverAnsweringAppearanceBackend implements AppearanceBackend {
  final Completer<String?> gate = Completer<String?>();

  @override
  Future<String?> read() => gate.future;

  @override
  Future<void> write(String value) async {}
}

class _ThrowingAppearanceBackend implements AppearanceBackend {
  @override
  Future<String?> read() async => throw StateError('no preferences');

  @override
  Future<void> write(String value) async => throw StateError('no preferences');
}

class _ThrowingBackend implements SecretBackend {
  @override
  Future<String?> read(String key) async => throw StateError('no keychain');

  @override
  Future<void> write(String key, String value) async =>
      throw StateError('no keychain');

  @override
  Future<void> delete(String key) async => throw StateError('no keychain');
}

void main() {
  late _RecordingHost host;

  setUp(() {
    host = _RecordingHost();
    PayCross.debugHostApi = host;
    app.mainLanguageStore = LanguageStore(backend: InMemoryLanguageBackend());
    app.mainAppearanceStore = AppearanceStore(
      backend: InMemoryAppearanceBackend(),
    );
    runInFlight = false;
  });

  tearDown(() {
    app.mainSecretStore = const SecretStore();
    app.mainLanguageStore = const LanguageStore();
    app.mainAppearanceStore = const AppearanceStore();
  });

  testWidgets('the demo build configures with the stored merchant id', (
    tester,
  ) async {
    final backend = InMemorySecretBackend();
    await SecretStore(backend: backend).write(
      const Credentials(
        clientId: 'id-1',
        clientSecret: 'secret-1',
        googlePayMerchantId: 'gp-1',
      ),
    );
    app.mainSecretStore = SecretStore(backend: backend);

    await app.main();
    await tester.pump();

    expect(host.lastConfiguration?.googlePayMerchantId, 'gp-1');
    expect(host.lastConfiguration?.environment, g.PcEnvironment.sandbox);
  });

  testWidgets('a store with no merchant id configures with null', (
    tester,
  ) async {
    final backend = InMemorySecretBackend();
    await SecretStore(
      backend: backend,
    ).write(const Credentials(clientId: 'id-1', clientSecret: 'secret-1'));
    app.mainSecretStore = SecretStore(backend: backend);

    await app.main();
    await tester.pump();

    expect(host.lastConfiguration?.googlePayMerchantId, isNull);
  });

  testWidgets('a store that throws configures with null and does not fail', (
    tester,
  ) async {
    app.mainSecretStore = SecretStore(backend: _ThrowingBackend());

    await app.main();
    await tester.pump();

    expect(host.lastConfiguration, isNotNull);
    expect(host.lastConfiguration?.googlePayMerchantId, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the launch configure carries the Test Apple identifier', (
    tester,
  ) async {
    app.mainSecretStore = SecretStore(backend: InMemorySecretBackend());

    await app.main();
    await tester.pump();

    expect(host.lastConfiguration?.applePayMerchantId, testApplePayMerchantId);
    expect(host.lastConfiguration?.environment, g.PcEnvironment.sandbox);
  });

  testWidgets('the demo build configures with the stored language', (
    tester,
  ) async {
    final backend = InMemoryLanguageBackend();
    await LanguageStore(backend: backend).write(DemoLanguage.french);
    app.mainSecretStore = SecretStore(backend: InMemorySecretBackend());
    app.mainLanguageStore = LanguageStore(backend: backend);

    await app.main();
    await tester.pump();

    expect(host.lastConfiguration?.locale, 'fr');
  });

  testWidgets('a store with no language configures with null', (tester) async {
    app.mainSecretStore = SecretStore(backend: InMemorySecretBackend());
    app.mainLanguageStore = LanguageStore(backend: InMemoryLanguageBackend());

    await app.main();
    await tester.pump();

    expect(host.lastConfiguration, isNotNull);
    expect(host.lastConfiguration?.locale, isNull);
  });

  testWidgets('three stores that go quiet do not stall the launch', (
    tester,
  ) async {
    app.mainSecretStore = SecretStore(backend: _NeverAnsweringSecretBackend());
    app.mainLanguageStore = LanguageStore(
      backend: _NeverAnsweringLanguageBackend(),
    );
    app.mainAppearanceStore = AppearanceStore(
      backend: _NeverAnsweringAppearanceBackend(),
    );

    var launched = false;
    unawaited(app.main().then((_) => launched = true));
    await tester.pump(const Duration(seconds: 16));
    await tester.pump();

    expect(launched, isTrue);
    expect(host.lastConfiguration, isNotNull);
    expect(host.lastConfiguration?.googlePayMerchantId, isNull);
    expect(host.lastConfiguration?.locale, isNull);
    expect(host.lastConfiguration?.appearance, isNull);
  });

  testWidgets('the demo build configures with the stored appearance', (
    tester,
  ) async {
    final backend = InMemoryAppearanceBackend();
    await AppearanceStore(backend: backend).write(DemoAppearance.themedPreset);
    app.mainSecretStore = SecretStore(backend: InMemorySecretBackend());
    app.mainAppearanceStore = AppearanceStore(backend: backend);

    await app.main();
    await tester.pump();

    final appearance = host.lastConfiguration?.appearance;
    expect(appearance?.light?.brand, 0xFF00875A);
    expect(appearance?.dark?.brand, 0xFF57D9A3);
    expect(appearance?.themeMode, g.PcThemeMode.dark);
    expect(appearance?.shapes?.cornerRadius, 16);
    expect(appearance?.shapes?.buttonCornerRadius, 28);
  });

  testWidgets('a store with no appearance configures with null', (
    tester,
  ) async {
    app.mainSecretStore = SecretStore(backend: InMemorySecretBackend());
    app.mainAppearanceStore = AppearanceStore(
      backend: InMemoryAppearanceBackend(),
    );

    await app.main();
    await tester.pump();

    expect(host.lastConfiguration, isNotNull);
    expect(host.lastConfiguration?.appearance, isNull);
  });

  testWidgets('an appearance store that throws configures with null', (
    tester,
  ) async {
    app.mainSecretStore = SecretStore(backend: InMemorySecretBackend());
    app.mainAppearanceStore = AppearanceStore(
      backend: _ThrowingAppearanceBackend(),
    );

    await app.main();
    await tester.pump();

    expect(host.lastConfiguration, isNotNull);
    expect(host.lastConfiguration?.appearance, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a language store that throws configures with null', (
    tester,
  ) async {
    app.mainSecretStore = SecretStore(backend: InMemorySecretBackend());
    app.mainLanguageStore = LanguageStore(backend: _ThrowingLanguageBackend());

    await app.main();
    await tester.pump();

    expect(host.lastConfiguration, isNotNull);
    expect(host.lastConfiguration?.locale, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a run link reaches a run down the same path a tile does', (
    tester,
  ) async {
    final links = StreamController<Uri>();
    addTearDown(links.close);

    await tester.pumpWidget(
      MaterialApp(
        home: app.DemoHome(
          links: links.stream,
          store: SecretStore(backend: InMemorySecretBackend()),
        ),
      ),
    );

    links.add(
      Uri.parse('paycross-flutter-demo://run?preset=Frictionless%203DS'),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('a second link while the first is still opening is dropped', (
    tester,
  ) async {
    final links = StreamController<Uri>();
    addTearDown(links.close);

    await tester.pumpWidget(
      MaterialApp(
        home: app.DemoHome(
          links: links.stream,
          store: SecretStore(backend: InMemorySecretBackend()),
        ),
      ),
    );

    final uri = Uri.parse(
      'paycross-flutter-demo://run?preset=Frictionless%203DS',
    );
    links.add(uri);
    await tester.pump();
    links.add(uri);
    await tester.pumpAndSettle();

    expect(find.byType(SettingsScreen), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.byType(SettingsScreen), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('a link over a run a tile started starts nothing and says so', (
    tester,
  ) async {
    useTallSurface(tester);
    final links = StreamController<Uri>();
    addTearDown(links.close);
    final backend = InMemorySecretBackend();
    backend.entries['paycross_demo_client_id'] = 'id-1';
    backend.entries['paycross_demo_client_secret'] = 'secret-1';
    var mints = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: app.DemoHome(
          links: links.stream,
          store: SecretStore(backend: backend),
          mintWith: (credentials, body) async {
            mints++;
            return const MintedSession(
              id: 'sess-9',
              token: 'a-live-token',
              sentBody: '{}',
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(demoPresets.first.name));
    await tester.pumpAndSettle();
    expect(find.byType(RunScreen), findsOneWidget);
    expect(mints, 1);

    links.add(
      Uri.parse('paycross-flutter-demo://run?preset=Frictionless%203DS'),
    );
    await tester.pumpAndSettle();

    expect(mints, 1);
    expect(find.byType(RunScreen), findsOneWidget);
    expect(
      find.text('Link ignored — close the open screen first.'),
      findsOneWidget,
    );

    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  });

  testWidgets('a link in Live starts nothing and says why', (tester) async {
    useTallSurface(tester);
    final links = StreamController<Uri>();
    addTearDown(links.close);
    final backend = InMemorySecretBackend();
    backend.entries['paycross_demo_client_id'] = 'id-1';
    backend.entries['paycross_demo_client_secret'] = 'secret-1';
    var mints = 0;

    await tester.pumpWidget(
      await liveApp(
        home: app.DemoHome(
          links: links.stream,
          store: SecretStore(backend: backend),
          mintWith: (credentials, body) async {
            mints++;
            return const MintedSession(
              id: 'sess-9',
              token: 'a-live-token',
              sentBody: '{}',
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    links.add(
      Uri.parse('paycross-flutter-demo://run?preset=Frictionless%203DS'),
    );
    await tester.pumpAndSettle();

    expect(mints, 0);
    expect(find.byType(RunScreen), findsNothing);
    expect(find.text('Live mode — links are disabled'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('a run that throws is reported rather than left unhandled', (
    tester,
  ) async {
    final links = StreamController<Uri>();
    addTearDown(links.close);

    await tester.pumpWidget(
      MaterialApp(
        home: app.DemoHome(links: links.stream, store: _ThrowsAfterFirstRead()),
      ),
    );
    await tester.pumpAndSettle();

    links.add(
      Uri.parse('paycross-flutter-demo://run?preset=Frictionless%203DS'),
    );
    await tester.pumpAndSettle();

    expect(find.text('Could not start the run: StateError'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(runInFlight, isFalse);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('a link arriving during a tap starts nothing', (tester) async {
    useTallSurface(tester);
    final links = StreamController<Uri>();
    addTearDown(links.close);
    final backend = _SlowBackend();

    await tester.pumpWidget(
      MaterialApp(
        home: app.DemoHome(
          links: links.stream,
          store: SecretStore(backend: backend),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(demoPresets.first.name));
    await tester.pump();

    links.add(
      Uri.parse('paycross-flutter-demo://run?preset=Frictionless%203DS'),
    );
    await tester.pump();

    backend.gate.complete();
    await tester.pumpAndSettle();

    expect(find.byType(SettingsScreen), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.byType(SettingsScreen), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
  });
  testWidgets('the demo build mounts the environment scope over Home', (
    tester,
  ) async {
    useTallSurface(tester);

    await tester.pumpWidget(const app.ExampleApp());
    await tester.pumpAndSettle();

    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).builder,
      isNotNull,
    );

    final home = tester.element(find.byType(HomeScreen));
    expect(LiveModeScope.maybeOf(home), isNotNull);
    expect(LiveModeScope.environmentOf(home), DemoEnvironment.test);
  });

  testWidgets('the Apple identifier reaches the scope and its state', (
    tester,
  ) async {
    useTallSurface(tester);

    await tester.pumpWidget(
      const app.ExampleApp(applePayMerchantId: testApplePayMerchantId),
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<LiveModeScope>(find.byType(LiveModeScope))
          .applePayMerchantId,
      testApplePayMerchantId,
    );
    final home = tester.element(find.byType(HomeScreen));
    expect(
      LiveModeScope.maybeOf(home)?.applePayMerchantId,
      testApplePayMerchantId,
    );
  });

  test('launch hands both wallet identifiers on to the widget tree', () {
    final source = File('lib/main.dart').readAsStringSync();
    final start = source.indexOf('Future<void> main() async {');
    expect(start, isNot(-1));
    final body = source
        .substring(start, source.indexOf('\n}', start))
        .split('\n')
        .map((line) => line.replaceAll(RegExp('//.*\$'), ''))
        .join('\n')
        .replaceAll(RegExp(r'\s+'), ' ');
    final at = body.indexOf('runApp(');
    expect(at, isNot(-1));
    final handedOn = body.substring(at);

    expect(handedOn, contains('googlePayMerchantId: merchantId'));
    expect(handedOn, contains('applePayMerchantId: testApplePayMerchantId'));
    expect(handedOn, contains('locale: locale'));
    expect(handedOn, contains('appearance: appearance'));
  });

  test('the frozen build still awaits one thing and reads no storage', () {
    final source = File('lib/main.dart').readAsStringSync();
    final start = source.indexOf('Future<void> main() async {');
    expect(start, isNot(-1));
    final body = source.substring(start, source.indexOf('\n}', start));
    final code = body
        .split('\n')
        .map((line) => line.replaceAll(RegExp('//.*\$'), ''))
        .join('\n');
    final collapsed = code.replaceAll(RegExp(r'\s+'), ' ');

    expect('await '.allMatches(collapsed).length, 4);
    expect(collapsed, contains('await PayCross.configure('));
    expect(collapsed, contains(': await _storedGooglePayMerchantId();'));
    expect(collapsed, contains(': await _storedLocale();'));
    expect(collapsed, contains(': await _storedAppearance();'));
    expect(
      collapsed,
      contains('? DemoAppearance.fromJson(_appearance).toAppearance()'),
    );

    expect(code, isNot(contains('mainSecretStore')));
    expect(code, isNot(contains('mainLanguageStore')));
    expect(code, isNot(contains('mainAppearanceStore')));
  });

  test('the automation build installs no environment scope', () {
    final source = File('lib/main.dart').readAsStringSync();

    expect(
      source.replaceAll(RegExp(r'\s+'), ' '),
      contains('builder: kE2e ? null :'),
    );
  });
}
