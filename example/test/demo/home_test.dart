import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:paycross_demo/demo/editor.dart';
import 'package:paycross_demo/demo/endpoints.dart';
import 'package:paycross_demo/demo/environment.dart';
import 'package:paycross_demo/demo/history_screen.dart';
import 'package:paycross_demo/demo/home.dart';
import 'package:paycross_demo/demo/live.dart';
import 'package:paycross_demo/demo/minter.dart';
import 'package:paycross_demo/demo/money.dart';
import 'package:paycross_demo/demo/preset_store.dart';
import 'package:paycross_demo/demo/presets.dart';
import 'package:paycross_demo/demo/run.dart';
import 'package:paycross_demo/demo/secrets.dart';
import 'package:paycross_demo/demo/settings.dart';
import 'package:paycross_demo/demo/surface.dart';
import 'package:paycross_demo/demo/test_cards_screen.dart';
import 'package:paycross_demo/demo/web_run.dart';
import 'package:paycross_flutter/paycross_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '_environment.dart';
import '_surface.dart';

class _ThrowingBackend implements SecretBackend {
  @override
  Future<String?> read(String key) async => throw StateError('no keychain');

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}
}

class _HangingBackend implements SecretBackend {
  @override
  Future<String?> read(String key) => Completer<String?>().future;

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}
}

class _SlowBackend implements SecretBackend {
  final Map<String, String> entries = <String, String>{};
  final Completer<void> gate = Completer<void>();

  @override
  Future<String?> read(String key) async {
    await gate.future;
    return entries[key];
  }

  @override
  Future<void> write(String key, String value) async => entries[key] = value;

  @override
  Future<void> delete(String key) async => entries.remove(key);
}

const LiveIdentity _liveIdentity = LiveIdentity(
  firstName: 'Ada',
  lastName: 'Lovelace',
  email: 'ada@example.org',
);

Future<DemoEnvironmentState> liveHolding(
  Credentials? credentials, {
  LiveIdentity? identity = _liveIdentity,
}) async {
  final state = fakeEnvironment();
  await state.enterLive(liveConfirmationWord);
  if (credentials != null) state.useForThisSession(credentials);
  if (identity != null) state.useIdentityForThisSession(identity);
  return state;
}

const Credentials _liveCredentials = Credentials(
  clientId: 'live-id',
  clientSecret: 'live-secret',
);

Finder liveTile(LiveScenario scenario, {bool skipOffstage = true}) =>
    find.byKey(ValueKey(liveTileKey(scenario)), skipOffstage: skipOffstage);

const String _checkoutUrl =
    'https://pay.example.com/pay?session=NOT-A-REAL-TOKEN';

MintedSession _mintedWithPage() => const MintedSession(
  id: 'sess-web',
  token: 'tok',
  sentBody: '{}',
  checkoutUrl: _checkoutUrl,
);

Future<SecretStore> _configuredStore() async {
  final store = SecretStore(backend: InMemorySecretBackend());
  await store.write(
    const Credentials(clientId: 'id-1', clientSecret: 'secret-1'),
  );
  return store;
}

Future<void> _drainBookkeeping(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 6));
  await tester.pump(const Duration(seconds: 6));
  await tester.pumpAndSettle();
}

String _titleText(ListTile tile) {
  final title = tile.title!;
  if (title is Text) return title.data!;
  final beside = (title as Row).children.first as Expanded;
  return (beside.child as Text).data!;
}

Finder _browserButton(String tile) =>
    find.byKey(ValueKey(browserActionKey(tile)));

void main() {
  setUp(() => runInFlight = false);

  testWidgets('Test says where it is pointed, and Live says what it costs', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pumpAndSettle();

    final test = tester
        .widget<Text>(find.byKey(const ValueKey('homeEnvironment')))
        .data!;
    expect(test, contains('Test'));
    expect(test, isNot(contains('no way to reach production')));

    await tester.pumpWidget(
      await liveApp(
        home: HomeScreen(store: SecretStore(backend: InMemorySecretBackend())),
      ),
    );
    await tester.pumpAndSettle();

    final live = tester
        .widget<Text>(find.byKey(const ValueKey('homeEnvironment')))
        .data!;
    expect(live, contains('real card'));
    expect(live, contains('Refund'));
  });

  testWidgets('the gear opens Settings', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('Settings opens with no platform under it and never throws', (
    tester,
  ) async {
    useTallSurface(tester);
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('clientId')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('clientId')))
          .controller!
          .text,
      isEmpty,
    );
    expect(find.text('Demo …'), findsOneWidget);
  });

  testWidgets('the other two actions open with no platform under them either', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));

    await tester.tap(find.byTooltip('History'));
    await tester.pumpAndSettle();
    expect(find.byType(HistoryScreen), findsOneWidget);
    expect(find.text('Reading past runs…'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Test cards'));
    await tester.pumpAndSettle();
    expect(find.byType(TestCardsScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('lists every preset with its expectation', (tester) async {
    useTallSurface(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(store: SecretStore(backend: InMemorySecretBackend())),
      ),
    );
    await tester.pumpAndSettle();

    for (final preset in demoPresets) {
      expect(find.text(preset.name), findsOneWidget, reason: preset.name);
    }
  });

  testWidgets('the active-profile strip says what a run would use', (
    tester,
  ) async {
    useTallSurface(tester);
    final backend = InMemorySecretBackend();
    backend.entries['paycross_demo_client_id'] = 'abcdef0123456789';
    backend.entries['paycross_demo_client_secret'] = 'secret-1';
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(store: SecretStore(backend: backend)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sandbox — client abcdef…'), findsOneWidget);
    expect(find.textContaining('secret-1'), findsNothing);
  });

  testWidgets('an unconfigured profile says so rather than looking broken', (
    tester,
  ) async {
    useTallSurface(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(store: SecretStore(backend: InMemorySecretBackend())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sandbox — not configured'), findsOneWidget);
  });

  testWidgets('Custom opens the editor on the ordinary body', (tester) async {
    useTallSurface(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(store: SecretStore(backend: InMemorySecretBackend())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('customPreset')));
    await tester.pumpAndSettle();

    expect(find.byType(EditorScreen), findsOneWidget);
    expect(find.text('Edit — Custom'), findsOneWidget);
  });

  testWidgets('an unconfigured store routes a run to Settings', (tester) async {
    useTallSurface(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(store: SecretStore(backend: InMemorySecretBackend())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(demoPresets.first.name));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('a storage read that throws routes to Settings, not a crash', (
    tester,
  ) async {
    useTallSurface(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(store: SecretStore(backend: _ThrowingBackend())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(demoPresets.first.name));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a second tap while the first run is starting does nothing', (
    tester,
  ) async {
    useTallSurface(tester);
    final backend = _SlowBackend()
      ..entries['paycross_demo_client_id'] = 'id-1'
      ..entries['paycross_demo_client_secret'] = 'secret-1';
    var mints = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
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
    await tester.pump();
    await tester.tap(find.text(demoPresets.first.name), warnIfMissed: false);
    await tester.pump();

    backend.gate.complete();
    await tester.pumpAndSettle();

    expect(find.byType(RunScreen), findsOneWidget);
    expect(mints, 1);

    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a store that never answers routes to Settings, not a wedge', (
    tester,
  ) async {
    useTallSurface(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(store: SecretStore(backend: _HangingBackend())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(demoPresets.first.name));
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(runInFlight, isFalse);
  });

  testWidgets('Home lays out and scrolls at ordinary phone width', (
    tester,
  ) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(store: SecretStore(backend: InMemorySecretBackend())),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text(demoPresets.first.name), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('customPreset')),
      200,
    );

    expect(find.byKey(const ValueKey('customPreset')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Live replaces the whole grid with three tiles', (tester) async {
    useTallSurface(tester);
    await tester.pumpWidget(
      await liveApp(
        home: HomeScreen(store: SecretStore(backend: InMemorySecretBackend())),
      ),
    );
    await tester.pumpAndSettle();

    for (final scenario in LiveScenario.values) {
      expect(liveTile(scenario), findsOneWidget, reason: scenario.name);
      expect(
        find.text(
          liveTileTitle(liveScenarioName(scenario), liveDefaultBody(scenario)),
        ),
        findsOneWidget,
        reason: scenario.name,
      );
    }
    expect(find.byKey(const ValueKey('customPreset')), findsNothing);
    expect(
      find.byTooltip('Edit the body'),
      findsNWidgets(LiveScenario.values.length),
    );
    expect(find.byType(IconButton), findsWidgets);
    for (final preset in demoPresets) {
      expect(find.text(preset.name), findsNothing, reason: preset.name);
    }
  });

  testWidgets('Live hides the sandbox card cheat sheet', (tester) async {
    await tester.pumpWidget(
      await liveApp(
        home: HomeScreen(store: SecretStore(backend: InMemorySecretBackend())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('Test cards'), findsNothing);
    expect(find.byTooltip('History'), findsOneWidget);
    expect(find.byTooltip('Settings'), findsOneWidget);
  });

  testWidgets('no tile with no identity held mints anything', (tester) async {
    useTallSurface(tester);
    for (final scenario in LiveScenario.values) {
      final state = await liveHolding(_liveCredentials, identity: null);
      await tester.pumpWidget(
        await liveApp(
          state: state,
          home: HomeScreen(
            store: SecretStore(backend: InMemorySecretBackend()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(liveTile(scenario));
      await tester.pumpAndSettle();

      expect(
        find.byType(SettingsScreen),
        findsOneWidget,
        reason: scenario.name,
      );
      expect(find.byKey(const ValueKey('liveConfirmDialog')), findsNothing);
      expect(find.byType(RunScreen), findsNothing, reason: scenario.name);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsNothing, reason: scenario.name);
    }
  });

  testWidgets('no tile with no Live credentials mints anything either', (
    tester,
  ) async {
    useTallSurface(tester);
    for (final scenario in LiveScenario.values) {
      final state = await liveHolding(null);
      await tester.pumpWidget(
        await liveApp(
          state: state,
          home: HomeScreen(
            store: SecretStore(backend: InMemorySecretBackend()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(liveTile(scenario));
      await tester.pumpAndSettle();

      expect(
        find.byType(SettingsScreen),
        findsOneWidget,
        reason: scenario.name,
      );
      expect(find.byType(RunScreen), findsNothing, reason: scenario.name);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsNothing, reason: scenario.name);
    }
  });

  testWidgets('Settings pushed from the Live tile shows no stored credential', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({
      'paycross_demo_client_id': 'test-id',
      'paycross_demo_client_secret': 'test-secret',
    });
    SharedPreferences.setMockInitialValues(<String, Object>{});
    addTearDown(
      () => FlutterSecureStorage.setMockInitialValues(<String, String>{}),
    );

    await tester.pumpWidget(
      await liveApp(
        home: HomeScreen(store: SecretStore(backend: InMemorySecretBackend())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('liveSmokeTile')));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('clientId')))
          .controller!
          .text,
      '',
    );
  });

  testWidgets('every dialog defaults to not spending money', (tester) async {
    useTallSurface(tester);
    final state = await liveHolding(_liveCredentials);
    var minted = 0;
    await tester.pumpWidget(
      await liveApp(
        state: state,
        home: HomeScreen(
          store: SecretStore(backend: InMemorySecretBackend()),
          liveMintWith: (_, _, _) async {
            minted++;
            return const MintedSession(id: 'x', token: 'y', sentBody: '{}');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Live — client live-i…'), findsOneWidget);

    for (final scenario in LiveScenario.values) {
      await tester.tap(liveTile(scenario));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('liveConfirmDialog')),
        findsOneWidget,
        reason: scenario.name,
      );
      expect(find.textContaining('charge a real card'), findsWidgets);

      await tester.tap(find.byKey(const ValueKey('liveCancel')));
      await tester.pumpAndSettle();

      expect(minted, 0, reason: scenario.name);
      expect(find.byType(RunScreen), findsNothing, reason: scenario.name);
    }
  });

  testWidgets('a dismissed dialog is a Cancel, back button included', (
    tester,
  ) async {
    final state = await liveHolding(_liveCredentials);
    var minted = 0;
    await tester.pumpWidget(
      await liveApp(
        state: state,
        home: HomeScreen(
          store: SecretStore(backend: InMemorySecretBackend()),
          liveMintWith: (_, _, _) async {
            minted++;
            return const MintedSession(id: 'x', token: 'y', sentBody: '{}');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('liveSmokeTile')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('liveConfirmDialog')), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('liveConfirmDialog')), findsNothing);
    expect(minted, 0);
    expect(find.byType(RunScreen), findsNothing);
  });

  testWidgets('Continue mints against the live endpoints and runs', (
    tester,
  ) async {
    useTallSurface(tester);
    final state = await liveHolding(_liveCredentials);
    Endpoints? used;
    Credentials? sentWith;
    await tester.pumpWidget(
      await liveApp(
        state: state,
        home: HomeScreen(
          store: SecretStore(backend: InMemorySecretBackend()),
          liveMintWith: (credentials, body, endpoints) async {
            used = endpoints;
            sentWith = credentials;
            return const MintedSession(
              id: 'sess-live',
              token: 'tok',
              sentBody: '{}',
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('liveSmokeTile')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('liveContinue')));
    await tester.pumpAndSettle();

    expect(used, same(liveEndpoints));
    expect(sentWith?.clientId, 'live-id');
    expect(find.byType(RunScreen), findsOneWidget);
    expect(tester.widget<RunScreen>(find.byType(RunScreen)).live, isTrue);
    for (final scenario in LiveScenario.values) {
      expect(
        tester
            .widget<ListTile>(
              find.descendant(
                of: liveTile(scenario, skipOffstage: false),
                matching: find.byType(ListTile, skipOffstage: false),
              ),
            )
            .onTap,
        isNull,
        reason: scenario.name,
      );
    }

    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  });

  testWidgets('the smoke charges the identity that was typed', (tester) async {
    final state = await liveHolding(_liveCredentials);
    String? sent;
    await tester.pumpWidget(
      await liveApp(
        state: state,
        home: HomeScreen(
          store: SecretStore(backend: InMemorySecretBackend()),
          liveMintWith: (credentials, body, endpoints) async {
            sent = body;
            return const MintedSession(
              id: 'sess-live',
              token: 'tok',
              sentBody: '{}',
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('liveSmokeTile')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('liveContinue')));
    await tester.pumpAndSettle();

    final customer =
        (jsonDecode(sent!) as Map<String, Object?>)['customer']!
            as Map<String, Object?>;
    expect(customer['first_name'], 'Ada');
    expect(customer['last_name'], 'Lovelace');
    expect(customer['email'], 'ada@example.org');
    expect(customer['email'], isNot('john.doe@example.com'));

    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  });

  testWidgets('every place quotes the amount in the body it will mint', (
    tester,
  ) async {
    useTallSurface(tester);
    for (final code in currencies) {
      final presets = PresetStore(
        backend: InMemoryPresetBackend(),
        environment: DemoEnvironment.live,
      );
      for (final scenario in LiveScenario.values) {
        await presets.saveOverride(
          liveScenarioId(scenario),
          '{"amount":4250,"currency":"$code",'
          '"customer":{"merchant_reference":"r"}}',
        );
      }
      final label = formatMoney(4250, code);

      await tester.pumpWidget(
        await liveApp(
          state: await liveHolding(_liveCredentials),
          home: HomeScreen(
            key: ValueKey(code),
            store: SecretStore(backend: InMemorySecretBackend()),
            livePresetStore: presets,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final quoted = <String>[];
      for (final scenario in LiveScenario.values) {
        final tile = tester.widget<ListTile>(
          find.descendant(
            of: liveTile(scenario),
            matching: find.byType(ListTile),
          ),
        );
        await tester.tap(liveTile(scenario));
        await tester.pumpAndSettle();
        final dialog = tester.widget<AlertDialog>(
          find.byKey(const ValueKey('liveConfirmDialog')),
        );

        quoted
          ..add(_titleText(tile))
          ..add((dialog.content! as Text).data!);

        await tester.tap(find.byKey(const ValueKey('liveCancel')));
        await tester.pumpAndSettle();
      }

      expect(quoted, hasLength(6), reason: code);
      for (final line in quoted) {
        expect(line, contains(label), reason: line);
        expect(line, isNot(contains('1.00')), reason: line);
        for (final other in currencies.where((c) => c != code)) {
          expect(
            line,
            isNot(contains(formatMoney(4250, other))),
            reason: '$code / $other: $line',
          );
        }
      }
    }
  });

  testWidgets('Home points at the tiles rather than quoting one figure', (
    tester,
  ) async {
    useTallSurface(tester);
    await tester.pumpWidget(
      await liveApp(
        state: await liveHolding(_liveCredentials),
        home: HomeScreen(store: SecretStore(backend: InMemorySecretBackend())),
      ),
    );
    await tester.pumpAndSettle();

    final said = tester
        .widget<Text>(find.byKey(const ValueKey('homeEnvironment')))
        .data!;

    expect(said, contains('Live'));
    expect(said, contains('Refund'));
    expect(said, contains('its own title'));
    expect(said, isNot(contains('1.00')));
  });

  testWidgets('each tile mints its own body, not the tile above it', (
    tester,
  ) async {
    useTallSurface(tester);
    for (final scenario in LiveScenario.values) {
      final state = await liveHolding(_liveCredentials);
      String? sent;
      await tester.pumpWidget(
        await liveApp(
          state: state,
          home: HomeScreen(
            store: SecretStore(backend: InMemorySecretBackend()),
            liveMintWith: (credentials, body, endpoints) async {
              sent = body;
              return const MintedSession(
                id: 'sess-live',
                token: 'tok',
                sentBody: '{}',
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(liveTile(scenario));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('liveContinue')));
      await tester.pumpAndSettle();

      expect(
        sent,
        withLiveIdentity(liveDefaultBody(scenario), _liveIdentity),
        reason: scenario.name,
      );
      expect(
        tester.widget<RunScreen>(find.byType(RunScreen)).preset.name,
        liveScenarioName(scenario),
        reason: scenario.name,
      );

      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(RunScreen), findsNothing, reason: scenario.name);
    }
  });

  testWidgets('the smoke charges what its saved body says', (tester) async {
    final presets = PresetStore(
      backend: InMemoryPresetBackend(),
      environment: DemoEnvironment.live,
    );
    await presets.saveOverride(
      liveScenarioId(LiveScenario.smoke),
      '{"amount":4250,"currency":"GBP",'
      '"customer":{"merchant_reference":"paycross_live_smoke"}}',
    );
    String? sent;
    await tester.pumpWidget(
      await liveApp(
        state: await liveHolding(_liveCredentials),
        home: HomeScreen(
          store: SecretStore(backend: InMemorySecretBackend()),
          livePresetStore: presets,
          liveMintWith: (credentials, body, endpoints) async {
            sent = body;
            return const MintedSession(
              id: 'sess-live',
              token: 'tok',
              sentBody: '{}',
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('liveSmokeTile')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('liveContinue')));
    await tester.pumpAndSettle();

    final body = jsonDecode(sent!) as Map<String, Object?>;
    expect(body['currency'], 'GBP');
    expect(body['amount'], 4250);
    final customer = body['customer']! as Map<String, Object?>;
    expect(customer['email'], _liveIdentity.email);
    expect(customer['first_name'], _liveIdentity.firstName);
    expect(customer['last_name'], _liveIdentity.lastName);
    final saved = (await presets.read()).overrides.values.single;
    expect(saved, isNot(contains(_liveIdentity.email)));

    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'a run authorised in Live keeps the pair it was authorised with',
    (tester) async {
      final state = await liveHolding(_liveCredentials);
      Endpoints? used;
      Credentials? sentWith;
      await tester.pumpWidget(
        await liveApp(
          state: state,
          home: HomeScreen(
            store: SecretStore(backend: InMemorySecretBackend()),
            liveMintWith: (credentials, body, endpoints) async {
              used = endpoints;
              sentWith = credentials;
              return const MintedSession(
                id: 'sess-live',
                token: 'tok',
                sentBody: '{}',
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('liveSmokeTile')));
      await tester.pumpAndSettle();

      await state.leaveLive();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('liveContinue')));
      await tester.pumpAndSettle();

      expect(state.isLive, isFalse);
      expect(used, same(liveEndpoints));
      expect(sentWith?.clientId, 'live-id');

      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('the profile strip in Live never shows what a store holds', (
    tester,
  ) async {
    final backend = InMemorySecretBackend()
      ..entries['paycross_demo_client_id'] = 'abcdef0123456789'
      ..entries['paycross_demo_client_secret'] = 'test-secret';
    FlutterSecureStorage.setMockInitialValues({
      'paycross_demo_client_id': 'abcdef0123456789',
      'paycross_demo_client_secret': 'test-secret',
    });
    SharedPreferences.setMockInitialValues(<String, Object>{});
    addTearDown(
      () => FlutterSecureStorage.setMockInitialValues(<String, String>{}),
    );
    final state = fakeEnvironment();
    await tester.pumpWidget(
      await liveApp(
        state: state,
        home: HomeScreen(store: SecretStore(backend: backend)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('liveProfile')), findsOneWidget);
    expect(find.byKey(const ValueKey('activeProfile')), findsNothing);
    expect(find.text('Live — no credentials this session'), findsOneWidget);
    expect(find.textContaining('abcdef'), findsNothing);
    expect(find.textContaining('Sandbox'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Live lays out and scrolls at ordinary phone width', (
    tester,
  ) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      await liveApp(
        home: HomeScreen(store: SecretStore(backend: InMemorySecretBackend())),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(liveTile(LiveScenario.smoke), findsOneWidget);

    await tester.scrollUntilVisible(
      liveTile(LiveScenario.paySavedCard, skipOffstage: false),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(liveTile(LiveScenario.paySavedCard), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test(
    'the Live mint reaches the pair it was handed, not the Test default',
    () async {
      final urls = <String>[];
      final client = MockClient((request) async {
        urls.add(request.url.toString());
        if (request.url.path.endsWith('/token')) {
          return http.Response(
            jsonEncode({'access_token': 'not-a-jwt', 'expires_in': 3600}),
            200,
          );
        }
        return http.Response(
          jsonEncode({'id': 'sess-live', 'session_token': 'tok'}),
          200,
        );
      });

      final minted = await liveMintWithCredentials(
        const Credentials(clientId: 'live-id', clientSecret: 'live-secret'),
        withLiveIdentity(liveDefaultBody(LiveScenario.smoke), _liveIdentity),
        liveEndpoints,
        client: client,
      );

      expect(minted.id, 'sess-live');
      expect(urls, [liveEndpoints.tokenUrl, liveEndpoints.sessionsUrl]);
      expect(urls, isNot(contains(testEndpoints.tokenUrl)));
      expect(urls, isNot(contains(testEndpoints.sessionsUrl)));
    },
  );

  group('the second way to run every tile', () {
    testWidgets('every Test tile offers it, Custom included', (tester) async {
      useTallSurface(tester);

      await tester.pumpWidget(
        MaterialApp(home: HomeScreen(store: await _configuredStore())),
      );
      await tester.pumpAndSettle();

      for (final preset in demoPresets) {
        expect(
          _browserButton(preset.name),
          findsOneWidget,
          reason: preset.name,
        );
      }
      expect(_browserButton('customPreset'), findsOneWidget);
      expect(
        find.text(openInBrowserLabel),
        findsNWidgets(demoPresets.length + 1),
      );
    });

    testWidgets('every Live tile offers it too', (tester) async {
      useTallSurface(tester);

      await tester.pumpWidget(
        await liveApp(
          state: await liveHolding(_liveCredentials),
          home: HomeScreen(
            store: SecretStore(backend: InMemorySecretBackend()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      for (final scenario in LiveScenario.values) {
        expect(
          _browserButton(liveTileKey(scenario)),
          findsOneWidget,
          reason: scenario.name,
        );
      }
    });

    testWidgets('it is a labelled button, not a bare glyph', (tester) async {
      useTallSurface(tester);

      await tester.pumpWidget(
        MaterialApp(home: HomeScreen(store: await _configuredStore())),
      );
      await tester.pumpAndSettle();

      final button = _browserButton(demoPresets.first.name);
      expect(
        find.descendant(of: button, matching: find.text(openInBrowserLabel)),
        findsOneWidget,
      );
      expect(
        find.ancestor(of: button, matching: find.byType(Tooltip)),
        findsOneWidget,
      );
    });

    testWidgets('it sends the tile to the browser, and the tap to the sheet', (
      tester,
    ) async {
      useTallSurface(tester);
      final opened = <Uri>[];

      Future<void> pump() async => tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            store: await _configuredStore(),
            mintWith: (_, _) async => _mintedWithPage(),
            launch: (url) async {
              opened.add(url);
              return true;
            },
          ),
        ),
      );

      await pump();
      await tester.pumpAndSettle();
      await tester.tap(find.text(demoPresets.first.name));
      await tester.pumpAndSettle();
      expect(find.byType(RunScreen), findsOneWidget);
      expect(find.byType(WebCheckoutRunScreen), findsNothing);
      expect(opened, isEmpty);
      await _drainBookkeeping(tester);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(_browserButton(demoPresets.first.name));
      await tester.pumpAndSettle();
      expect(find.byType(WebCheckoutRunScreen), findsOneWidget);
      expect(opened.single.toString(), _checkoutUrl);
      await _drainBookkeeping(tester);
    });

    testWidgets('both ways mint the same body, byte for byte', (tester) async {
      useTallSurface(tester);
      final sent = <String>[];

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            store: await _configuredStore(),
            mintWith: (_, body) async {
              sent.add(body);
              return _mintedWithPage();
            },
            launch: (_) async => true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text(demoPresets.first.name));
      await tester.pumpAndSettle();
      await _drainBookkeeping(tester);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(_browserButton(demoPresets.first.name));
      await tester.pumpAndSettle();
      await _drainBookkeeping(tester);

      expect(sent, hasLength(2));
      expect(sent.first, sent.last);
    });

    testWidgets('Custom opens the editor, and its Run goes to the browser', (
      tester,
    ) async {
      useTallSurface(tester);

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            store: await _configuredStore(),
            mintWith: (_, _) async => _mintedWithPage(),
            launch: (_) async => true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(_browserButton('customPreset'));
      await tester.pumpAndSettle();
      expect(find.byType(EditorScreen), findsOneWidget);

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();

      expect(find.byType(WebCheckoutRunScreen), findsOneWidget);
      await _drainBookkeeping(tester);
    });

    testWidgets('the pencil still runs an edited body in the sheet', (
      tester,
    ) async {
      useTallSurface(tester);

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            store: await _configuredStore(),
            mintWith: (_, _) async => _mintedWithPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Edit the body').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();

      expect(find.byType(RunScreen), findsOneWidget);
      expect(find.byType(WebCheckoutRunScreen), findsNothing);
      await _drainBookkeeping(tester);
    });

    testWidgets('a run that names no surface is a sheet run', (tester) async {
      late BuildContext held;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              held = context;
              return const Scaffold();
            },
          ),
        ),
      );

      unawaited(
        runPreset(
          held,
          demoPresets.first,
          demoPresets.first.body,
          store: await _configuredStore(),
          mintWith: (_, _) async => _mintedWithPage(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(RunScreen), findsOneWidget);
      expect(find.byType(WebCheckoutRunScreen), findsNothing);
      await _drainBookkeeping(tester);
    });

    testWidgets('a themed tile paints the sheet and puts it back', (
      tester,
    ) async {
      final applied = <PayCrossAppearance?>[];
      final state = DemoEnvironmentState(
        configure:
            ({
              required PayCrossEnvironment environment,
              String? googlePayMerchantId,
              String? applePayMerchantId,
              PayCrossAppearance? appearance,
              String? locale,
            }) async {
              applied.add(appearance);
            },
      );
      addTearDown(state.dispose);

      final themed = demoPresets.firstWhere((p) => p.id == 'appearance');
      expect(themed.appearance, isNotNull);

      late BuildContext held;
      await tester.pumpWidget(
        appWithEnvironment(
          state: state,
          home: Builder(
            builder: (context) {
              held = context;
              return const Scaffold();
            },
          ),
        ),
      );

      final run = runPreset(
        held,
        themed,
        themed.body,
        store: await _configuredStore(),
        mintWith: (_, _) async => _mintedWithPage(),
      );
      await tester.pumpAndSettle();

      expect(find.byType(RunScreen), findsOneWidget);
      expect(applied, <PayCrossAppearance?>[themed.appearance]);

      await _drainBookkeeping(tester);
      Navigator.of(held).pop();
      await tester.pumpAndSettle();
      await run;

      expect(applied, <PayCrossAppearance?>[themed.appearance, null]);
    });

    testWidgets('a themed run that bails after applying still restores', (
      tester,
    ) async {
      final applied = <PayCrossAppearance?>[];
      final gate = Completer<void>();
      var heldOpen = true;
      final state = DemoEnvironmentState(
        configure:
            ({
              required PayCrossEnvironment environment,
              String? googlePayMerchantId,
              String? applePayMerchantId,
              PayCrossAppearance? appearance,
              String? locale,
            }) async {
              applied.add(appearance);
              if (heldOpen) {
                heldOpen = false;
                await gate.future;
              }
            },
      );
      addTearDown(state.dispose);

      final themed = demoPresets.firstWhere((p) => p.id == 'appearance');

      late BuildContext held;
      await tester.pumpWidget(
        appWithEnvironment(
          state: state,
          home: Builder(
            builder: (context) {
              held = context;
              return const Scaffold();
            },
          ),
        ),
      );

      final run = runPreset(
        held,
        themed,
        themed.body,
        store: await _configuredStore(),
        mintWith: (_, _) async => _mintedWithPage(),
      );
      await tester.pump();
      await tester.pump();
      expect(applied, <PayCrossAppearance?>[themed.appearance]);

      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      gate.complete();
      await tester.pumpAndSettle();
      await run;

      expect(find.byType(RunScreen), findsNothing);
      expect(applied, <PayCrossAppearance?>[themed.appearance, null]);
    });

    testWidgets('an unthemed tile does not touch the SDK configuration', (
      tester,
    ) async {
      final applied = <PayCrossAppearance?>[];
      final state = DemoEnvironmentState(
        configure:
            ({
              required PayCrossEnvironment environment,
              String? googlePayMerchantId,
              String? applePayMerchantId,
              PayCrossAppearance? appearance,
              String? locale,
            }) async {
              applied.add(appearance);
            },
      );
      addTearDown(state.dispose);

      final plain = demoPresets.firstWhere((p) => p.appearance == null);

      late BuildContext held;
      await tester.pumpWidget(
        appWithEnvironment(
          state: state,
          home: Builder(
            builder: (context) {
              held = context;
              return const Scaffold();
            },
          ),
        ),
      );

      final run = runPreset(
        held,
        plain,
        plain.body,
        store: await _configuredStore(),
        mintWith: (_, _) async => _mintedWithPage(),
      );
      await tester.pumpAndSettle();
      await _drainBookkeeping(tester);
      Navigator.of(held).pop();
      await tester.pumpAndSettle();
      await run;

      expect(applied, isEmpty);
    });
  });

  group('the busy guard covers both of a tile\'s actions', () {
    testWidgets('a run in flight kills every browser button on the screen', (
      tester,
    ) async {
      useTallSurface(tester);
      final gate = Completer<MintedSession>();

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            store: await _configuredStore(),
            mintWith: (_, _) => gate.future,
            launch: (_) async => true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(_browserButton(demoPresets.first.name));
      await tester.pump();

      for (final preset in demoPresets) {
        expect(
          tester.widget<TextButton>(_browserButton(preset.name)).onPressed,
          isNull,
          reason: preset.name,
        );
      }
      expect(
        tester.widget<TextButton>(_browserButton('customPreset')).onPressed,
        isNull,
      );

      gate.complete(_mintedWithPage());
      await tester.pumpAndSettle();
      await _drainBookkeeping(tester);
    });
  });

  group('a Live run reached by the browser button', () {
    testWidgets('the dialog comes first, and says where it happens', (
      tester,
    ) async {
      useTallSurface(tester);
      var minted = 0;

      await tester.pumpWidget(
        await liveApp(
          state: await liveHolding(_liveCredentials),
          home: HomeScreen(
            store: SecretStore(backend: InMemorySecretBackend()),
            launch: (_) async => true,
            liveMintWith: (_, _, _) async {
              minted++;
              return _mintedWithPage();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(_browserButton(liveTileKey(LiveScenario.smoke)));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('liveConfirmDialog')), findsOneWidget);
      expect(
        find.textContaining('It opens in your browser instead of the app.'),
        findsOneWidget,
      );
      expect(minted, 0);
      expect(find.byKey(const ValueKey('liveCancel')), findsOneWidget);
    });

    testWidgets('the tile tap asks the question without that sentence', (
      tester,
    ) async {
      useTallSurface(tester);

      await tester.pumpWidget(
        await liveApp(
          state: await liveHolding(_liveCredentials),
          home: HomeScreen(
            store: SecretStore(backend: InMemorySecretBackend()),
            liveMintWith: (_, _, _) async => _mintedWithPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(liveTile(LiveScenario.smoke));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('liveConfirmDialog')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('liveConfirmDialog')),
          matching: find.textContaining('browser'),
        ),
        findsNothing,
      );
    });

    testWidgets('Cancel mints nothing at all', (tester) async {
      useTallSurface(tester);
      var minted = 0;

      await tester.pumpWidget(
        await liveApp(
          state: await liveHolding(_liveCredentials),
          home: HomeScreen(
            store: SecretStore(backend: InMemorySecretBackend()),
            launch: (_) async => true,
            liveMintWith: (_, _, _) async {
              minted++;
              return _mintedWithPage();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(_browserButton(liveTileKey(LiveScenario.smoke)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('liveCancel')));
      await tester.pumpAndSettle();

      expect(minted, 0);
      expect(find.byType(WebCheckoutRunScreen), findsNothing);
    });

    testWidgets('a dismissed dialog mints nothing either', (tester) async {
      useTallSurface(tester);
      var minted = 0;

      await tester.pumpWidget(
        await liveApp(
          state: await liveHolding(_liveCredentials),
          home: HomeScreen(
            store: SecretStore(backend: InMemorySecretBackend()),
            launch: (_) async => true,
            liveMintWith: (_, _, _) async {
              minted++;
              return _mintedWithPage();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(_browserButton(liveTileKey(LiveScenario.smoke)));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(minted, 0);
      expect(find.byType(WebCheckoutRunScreen), findsNothing);
    });

    testWidgets('Continue opens the browser on a run marked Live', (
      tester,
    ) async {
      useTallSurface(tester);
      final opened = <Uri>[];

      await tester.pumpWidget(
        await liveApp(
          state: await liveHolding(_liveCredentials),
          home: HomeScreen(
            store: SecretStore(backend: InMemorySecretBackend()),
            launch: (url) async {
              opened.add(url);
              return true;
            },
            liveMintWith: (_, _, _) async => _mintedWithPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(_browserButton(liveTileKey(LiveScenario.smoke)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('liveContinue')));
      await tester.pumpAndSettle();

      expect(find.byType(WebCheckoutRunScreen), findsOneWidget);
      expect(opened.single.toString(), _checkoutUrl);
      expect(
        tester
            .widget<WebCheckoutRunScreen>(find.byType(WebCheckoutRunScreen))
            .live,
        isTrue,
      );
      expect(find.byKey(const ValueKey('refundInstruction')), findsOneWidget);
      expect(find.textContaining('sess-web'), findsWidgets);
      await _drainBookkeeping(tester);
    });

    testWidgets('a Live browser run sends the tile tap\'s production body', (
      tester,
    ) async {
      useTallSurface(tester);
      final sent = <String>[];

      Future<void> pressAndContinue(Finder control) async {
        await tester.tap(control);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('liveContinue')));
        await tester.pumpAndSettle();
        await _drainBookkeeping(tester);
        await tester.pageBack();
        await tester.pumpAndSettle();
      }

      await tester.pumpWidget(
        await liveApp(
          state: await liveHolding(_liveCredentials),
          home: HomeScreen(
            store: SecretStore(backend: InMemorySecretBackend()),
            launch: (_) async => true,
            liveMintWith: (_, body, _) async {
              sent.add(body);
              return _mintedWithPage();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await pressAndContinue(liveTile(LiveScenario.smoke));
      await pressAndContinue(_browserButton(liveTileKey(LiveScenario.smoke)));

      expect(sent, hasLength(2));
      expect(sent.first, sent.last);
    });

    testWidgets('a tile with nothing held goes to Settings, not the browser', (
      tester,
    ) async {
      useTallSurface(tester);

      await tester.pumpWidget(
        await liveApp(
          state: await liveHolding(null, identity: null),
          home: HomeScreen(
            store: SecretStore(backend: InMemorySecretBackend()),
            launch: (_) async => true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(_browserButton(liveTileKey(LiveScenario.smoke)));
      await tester.pumpAndSettle();

      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('liveConfirmDialog')), findsNothing);
      expect(find.byType(WebCheckoutRunScreen), findsNothing);
    });
  });

  group('presets somebody saved', () {
    Future<void> pumpHome(
      WidgetTester tester,
      PresetStore presets, {
      List<String>? sent,
    }) async {
      useTallSurface(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            store: await _configuredStore(),
            presetStore: presets,
            mintWith: (_, body) async {
              sent?.add(body);
              return _mintedWithPage();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('an edited preset mints the body that was saved', (
      tester,
    ) async {
      final presets = PresetStore(backend: InMemoryPresetBackend());
      final preset = demoPresets.first;
      await presets.saveOverride(
        preset.id!,
        '{"amount":4242,"currency":"GBP",'
        '"customer":{"merchant_reference":"CUST-1"}}',
      );
      final sent = <String>[];
      await pumpHome(tester, presets, sent: sent);

      await tester.tap(find.text(preset.name));
      await tester.pumpAndSettle();
      await _drainBookkeeping(tester);

      expect((jsonDecode(sent.single) as Map)['amount'], 4242);
    });

    testWidgets('an edited preset says so on its tile', (tester) async {
      final presets = PresetStore(backend: InMemoryPresetBackend());
      final preset = demoPresets.first;
      await presets.saveOverride(preset.id!, '{"amount":4242}');
      await pumpHome(tester, presets);

      expect(find.byKey(ValueKey(editedMarkerKey(preset.id!))), findsOneWidget);
      expect(
        find.byKey(ValueKey(editedMarkerKey(demoPresets[1].id!))),
        findsNothing,
      );
    });

    testWidgets('a preset nobody edited mints the bytes it ships with', (
      tester,
    ) async {
      final presets = PresetStore(backend: InMemoryPresetBackend());
      final sent = <String>[];
      await pumpHome(tester, presets, sent: sent);

      await tester.tap(find.text(demoPresets.first.name));
      await tester.pumpAndSettle();
      await _drainBookkeeping(tester);

      expect(sent.single, demoPresets.first.body);
    });

    testWidgets('the pencil opens a built-in on the body that was saved', (
      tester,
    ) async {
      final presets = PresetStore(backend: InMemoryPresetBackend());
      await presets.saveOverride(demoPresets.first.id!, '{"amount":4242}');
      await pumpHome(tester, presets);

      await tester.tap(find.byTooltip('Edit the body').first);
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('amount')))
            .controller!
            .text,
        '4242',
      );
    });

    testWidgets('the tiles somebody made come after the built-in ones', (
      tester,
    ) async {
      final presets = PresetStore(backend: InMemoryPresetBackend());
      await presets.addCustom(name: 'My scenario', body: defaultBody());
      await pumpHome(tester, presets);

      expect(find.text('My scenario'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('My scenario')).dy,
        greaterThan(tester.getTopLeft(find.text(demoPresets.last.name)).dy),
      );
      expect(
        tester.getTopLeft(find.text('My scenario')).dy,
        lessThan(tester.getTopLeft(find.text('Custom')).dy),
      );
    });

    testWidgets('a tile somebody made mints its own body', (tester) async {
      final presets = PresetStore(backend: InMemoryPresetBackend());
      await presets.addCustom(name: 'My scenario', body: '{"amount":777}');
      final sent = <String>[];
      await pumpHome(tester, presets, sent: sent);

      await tester.tap(find.text('My scenario'));
      await tester.pumpAndSettle();
      await _drainBookkeeping(tester);

      expect(sent.single, '{"amount":777}');
    });

    testWidgets('its pencil opens an editor that can delete it', (
      tester,
    ) async {
      final presets = PresetStore(backend: InMemoryPresetBackend());
      await presets.addCustom(name: 'My scenario', body: defaultBody());
      await pumpHome(tester, presets);

      await tester.tap(find.byTooltip('Edit the body').last);
      await tester.pumpAndSettle();

      expect(find.text('Edit — My scenario'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      expect(find.text('Reset to default'), findsNothing);
    });

    testWidgets('Custom opens an editor with nothing to save into', (
      tester,
    ) async {
      final presets = PresetStore(backend: InMemoryPresetBackend());
      await pumpHome(tester, presets);

      await tester.tap(find.text('Custom'));
      await tester.pumpAndSettle();

      expect(find.text('Save as new…'), findsOneWidget);
      expect(find.text('Save'), findsNothing);
      expect(find.text('Delete'), findsNothing);
    });

    testWidgets('a tile saved in the editor is on Home when it closes', (
      tester,
    ) async {
      final presets = PresetStore(backend: InMemoryPresetBackend());
      await pumpHome(tester, presets);

      await tester.tap(find.text('Custom'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save as new…'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('newPresetName')),
        'My scenario',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('saveAsNewConfirm')));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.text('My scenario'), findsOneWidget);
    });

    testWidgets('an edit saved on a built-in shows on Home when it closes', (
      tester,
    ) async {
      final presets = PresetStore(backend: InMemoryPresetBackend());
      await pumpHome(tester, presets);

      await tester.tap(find.byTooltip('Edit the body').first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('amount')), '4242');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('save')));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(
        find.byKey(ValueKey(editedMarkerKey(demoPresets.first.id!))),
        findsOneWidget,
      );
    });

    testWidgets('Live never shows what was saved in Test', (tester) async {
      final sandbox = PresetStore(backend: InMemoryPresetBackend());
      final production = PresetStore(
        backend: InMemoryPresetBackend(),
        environment: DemoEnvironment.live,
      );
      await sandbox.addCustom(name: 'Sandbox only', body: defaultBody());
      await sandbox.saveOverride(demoPresets.first.id!, '{"amount":4242}');
      await production.addCustom(
        name: 'Production only',
        body: liveDefaultBody(LiveScenario.smoke),
      );
      useTallSurface(tester);

      await tester.pumpWidget(
        await liveApp(
          state: await liveHolding(_liveCredentials),
          home: HomeScreen(
            store: SecretStore(backend: InMemorySecretBackend()),
            presetStore: sandbox,
            livePresetStore: production,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Sandbox only'), findsNothing);
      expect(find.byKey(const ValueKey('customPreset')), findsNothing);
      for (final preset in demoPresets) {
        expect(find.text(preset.name), findsNothing, reason: preset.name);
      }
      expect(
        find.text(
          liveTileTitle('Production only', liveDefaultBody(LiveScenario.smoke)),
        ),
        findsOneWidget,
      );
      expect(
        find.byTooltip('Edit the body'),
        findsNWidgets(LiveScenario.values.length + 1),
      );
    });

    testWidgets('Reset on an edited Live tile brings the shipped body back', (
      tester,
    ) async {
      final presets = PresetStore(
        backend: InMemoryPresetBackend(),
        environment: DemoEnvironment.live,
      );
      await presets.saveOverride(
        liveScenarioId(LiveScenario.smoke),
        '{"amount":9999,"currency":"GBP",'
        '"customer":{"merchant_reference":"paycross_live_smoke"}}',
      );
      useTallSurface(tester);

      await tester.pumpWidget(
        await liveApp(
          state: await liveHolding(_liveCredentials),
          home: HomeScreen(
            store: SecretStore(backend: InMemorySecretBackend()),
            livePresetStore: presets,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Edit the body').first);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('amount')))
            .controller!
            .text,
        '9999',
      );

      await tester.tap(find.text('Reset to default'));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('amount')))
            .controller!
            .text,
        '$liveSmokeMinorUnits',
      );
      expect((await presets.read()).overrides, isEmpty);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          ValueKey(editedMarkerKey(liveScenarioId(LiveScenario.smoke))),
        ),
        findsNothing,
      );
      expect(
        find.text(
          liveTileTitle(
            liveScenarioName(LiveScenario.smoke),
            liveDefaultBody(LiveScenario.smoke),
          ),
        ),
        findsOneWidget,
      );
    });

    testWidgets('editing a Live tile back to its default clears the override', (
      tester,
    ) async {
      final presets = PresetStore(
        backend: InMemoryPresetBackend(),
        environment: DemoEnvironment.live,
      );
      await presets.saveOverride(
        liveScenarioId(LiveScenario.smoke),
        '{"amount":9999,"currency":"GBP",'
        '"customer":{"merchant_reference":"paycross_live_smoke"}}',
      );
      useTallSurface(tester);

      await tester.pumpWidget(
        await liveApp(
          state: await liveHolding(_liveCredentials),
          home: HomeScreen(
            store: SecretStore(backend: InMemorySecretBackend()),
            livePresetStore: presets,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Edit the body').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(rawBodySectionLabel));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('rawBody')),
        liveDefaultBody(LiveScenario.smoke),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('save')));
      await tester.pumpAndSettle();

      expect((await presets.read()).overrides, isEmpty);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          ValueKey(editedMarkerKey(liveScenarioId(LiveScenario.smoke))),
        ),
        findsNothing,
      );
    });

    testWidgets('an edited Live tile still mints what it says', (tester) async {
      final presets = PresetStore(
        backend: InMemoryPresetBackend(),
        environment: DemoEnvironment.live,
      );
      await presets.saveOverride(
        liveScenarioId(LiveScenario.smoke),
        '{"amount":9999,"currency":"GBP",'
        '"customer":{"merchant_reference":"paycross_live_smoke"}}',
      );
      String? sent;
      useTallSurface(tester);

      await tester.pumpWidget(
        await liveApp(
          state: await liveHolding(_liveCredentials),
          home: HomeScreen(
            store: SecretStore(backend: InMemorySecretBackend()),
            livePresetStore: presets,
            liveMintWith: (credentials, body, endpoints) async {
              sent = body;
              return const MintedSession(
                id: 'sess-live',
                token: 'tok',
                sentBody: '{}',
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('£99.99'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('liveSmokeTile')));
      await tester.pumpAndSettle();
      expect(find.textContaining('£99.99'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('liveContinue')));
      await tester.pumpAndSettle();

      expect((jsonDecode(sent!) as Map)['amount'], 9999);

      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
    });

    testWidgets('Test never shows what was saved in Live', (tester) async {
      final sandbox = PresetStore(backend: InMemoryPresetBackend());
      final production = PresetStore(
        backend: InMemoryPresetBackend(),
        environment: DemoEnvironment.live,
      );
      await production.addCustom(
        name: 'Production only',
        body: liveDefaultBody(LiveScenario.smoke),
      );
      await production.saveOverride(
        liveScenarioId(LiveScenario.smoke),
        '{"amount":4250,"currency":"GBP"}',
      );
      await sandbox.addCustom(name: 'Sandbox only', body: defaultBody());
      useTallSurface(tester);

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            store: await _configuredStore(),
            presetStore: sandbox,
            livePresetStore: production,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Production only'), findsNothing);
      expect(find.text('Sandbox only'), findsOneWidget);
      expect(
        find.byKey(ValueKey(editedMarkerKey(demoPresets.first.id!))),
        findsNothing,
      );
    });
  });
}
