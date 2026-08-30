import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/home.dart';
import 'package:paycross_demo/demo/presets.dart';
import 'package:paycross_demo/demo/secrets.dart';
import 'package:paycross_demo/demo/settings.dart';
import 'package:paycross_demo/main.dart' as app;
import 'package:paycross_flutter/paycross_flutter.dart';
// The generated Pigeon client is deliberately not exported (see
// `lib/paycross_flutter.dart`), and `PayCross.debugHostApi` takes it. A test
// is the one place allowed to reach for it, and this is the only way to read
// back what `main` handed to `configure`.
// ignore: implementation_imports
import 'package:paycross_flutter/src/generated/paycross_api.g.dart' as g;

import 'demo/_surface.dart';

/// Records the configuration `main` builds. Nothing here reaches a platform.
class _RecordingHost extends g.PayCrossHostApi {
  g.PcConfiguration? lastConfiguration;

  @override
  Future<void> configure(g.PcConfiguration configuration) async =>
      lastConfiguration = configuration;
}

/// A store whose reads wait on [gate], so a link can arrive while a tile tap
/// is still reading -- the window the two entrances share.
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

/// A store whose reads throw, standing in for a device whose Keychain or
/// KeyStore is unavailable at launch.
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
  });

  tearDown(() => app.mainSecretStore = const SecretStore());

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

    // Nothing is stored, so the link lands exactly where a tile tap lands.
    // That is `runPreset`'s "not configured routes to Settings" rule, and
    // this is the whole point of the link going through `runPreset`: the
    // rule is written once and cannot be true of one entrance only.
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

    // The real assertion: had the second link been honoured there would be a
    // second route underneath this one, and one pop would land on it rather
    // than on Home. A link can arrive while a run is already open, which is
    // the one thing a tile on Home cannot do.
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.byType(SettingsScreen), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
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

    // The tap goes in through Home, the link goes in through DemoHome, and
    // the two carry different flags -- so the only thing that can refuse the
    // link here is the guard inside `runPreset` itself.
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
}
