import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paycross_demo/demo/editor.dart';
import 'package:paycross_demo/demo/history_screen.dart';
import 'package:paycross_demo/demo/home.dart';
import 'package:paycross_demo/demo/minter.dart';
import 'package:paycross_demo/demo/presets.dart';
import 'package:paycross_demo/demo/run.dart';
import 'package:paycross_demo/demo/secrets.dart';
import 'package:paycross_demo/demo/settings.dart';
import 'package:paycross_demo/demo/test_cards_screen.dart';

import '_surface.dart';

/// A store whose reads fail, which is what an iOS Runner missing the
/// Keychain Sharing entitlement looks like from Dart.
class _ThrowingBackend implements SecretBackend {
  @override
  Future<String?> read(String key) async => throw StateError('no keychain');

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}
}

/// A store whose reads never answer at all, which is what a wedged Keychain
/// looks like from Dart: not a failure, just silence.
class _HangingBackend implements SecretBackend {
  @override
  Future<String?> read(String key) => Completer<String?>().future;

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}
}

/// A store whose reads wait on [gate], so a test can tap again while the
/// first read is still in flight -- which on a cold Keychain is a real
/// window, not a theoretical one.
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

void main() {
  // `runInFlight` is top-level, so a test that ends while a read is still in
  // flight leaves it set and the next test silently cannot start a run at
  // all. Reset rather than tearDown: it also covers a test that dies.
  setUp(() => runInFlight = false);

  testWidgets('says the app is sandbox-only', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pumpAndSettle();

    expect(find.textContaining('Sandbox only'), findsOneWidget);
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
    // The default SettingsScreen reads the real secure store, which under
    // `flutter test` has no platform behind it. That read is guarded, so the
    // screen builds empty instead of throwing -- this is the "a null or
    // failed read means not configured" rule exercised against a genuinely
    // absent platform rather than against a fake that stands in for one.
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
    // The version read does not fail here, it never answers: the channel has
    // no handler and its future stays pending, so the panel holds its
    // pending row. That is the panel's own tested behaviour, and it is why
    // this asserts the pending row rather than 'unknown'.
    expect(find.text('Demo …'), findsOneWidget);
  });

  testWidgets('the other two actions open with no platform under them either', (
    tester,
  ) async {
    // Both defaults reach a real platform store -- History's is
    // SharedPreferences -- and neither route may throw. A route that did
    // would be a red screen on a colleague's phone rather than a screen
    // with nothing in it yet.
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));

    await tester.tap(find.byTooltip('History'));
    await tester.pumpAndSettle();
    expect(find.byType(HistoryScreen), findsOneWidget);
    // Pending, not empty and not failed: `SharedPreferences.getInstance()`
    // never answers under `flutter test`, exactly as the version read does
    // not. That is why the screen has a state for "has not answered yet"
    // that is distinct from "answered with nothing".
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

    // The environment is a constant and the id is truncated on purpose.
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

    // The store read sits between the tap and the push, so an impatient
    // second tap would otherwise mint a second live session and stack a
    // second Run screen on top of the first.
    await tester.tap(find.text(demoPresets.first.name));
    await tester.pump();
    await tester.tap(find.text(demoPresets.first.name), warnIfMissed: false);
    await tester.pump();

    backend.gate.complete();
    await tester.pumpAndSettle();

    expect(find.byType(RunScreen), findsOneWidget);
    expect(mints, 1);

    // Drain the two bookkeeping timeouts the pushed Run screen started
    // against platform stores that never answer under `flutter test`.
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

    // Silence is treated as "not configured": the same place a null read
    // goes, because it is the same thing a colleague can act on.
    expect(find.byType(SettingsScreen), findsOneWidget);
    // And the app-wide guard is not left set, or nothing could start a run
    // again for the rest of the process.
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

    // An overflow stripe is an exception in a widget test, and the tall
    // surface every other test here uses would never produce one.
    expect(tester.takeException(), isNull);
    expect(find.text(demoPresets.first.name), findsOneWidget);

    // And the far end of the list is reachable, which is the other thing the
    // tall surface hides: on a phone this is a list you have to scroll.
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('customPreset')),
      200,
    );

    expect(find.byKey(const ValueKey('customPreset')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
