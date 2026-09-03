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

import '_environment.dart';
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

/// The identity every Live case in this file charges under.
///
/// The IANA-reserved documentation domain. No test in this plan holds an
/// address that could belong to anybody.
const LiveIdentity _liveIdentity = LiveIdentity(
  firstName: 'Ada',
  lastName: 'Lovelace',
  email: 'ada@example.org',
);

/// A Live state already holding what a smoke needs, or holding half of it.
///
/// The order is the whole reason this is a helper. Both setters are no-ops
/// outside Live -- deliberately, so a Test credential can never be held as
/// a production one -- so anything armed before the switch is silently
/// dropped and every tile tap lands on a refusal the test is not about.
///
/// Either argument may be null, which is the point: the tile refuses when
/// either half is missing, and a state that cannot be half-armed cannot
/// prove that.
Future<DemoEnvironmentState> liveHolding(
  Credentials? credentials, {
  LiveIdentity? identity = _liveIdentity,
}) async {
  final state = fakeEnvironment();
  await state.enterLive(liveConfirmationWord);
  if (credentials != null) state.useForThisSession(credentials);
  if (identity != null) state.useIdentityForThisSession(identity);
  // No currency. A session held one until the addendum; it is a field of
  // the preset body now, so what a tile charges comes out of the store
  // rather than out of this state.
  return state;
}

const Credentials _liveCredentials = Credentials(
  clientId: 'live-id',
  clientSecret: 'live-secret',
);

/// Finds the Live tile a scenario draws, by the key that scenario owns.
///
/// A helper rather than a literal per case, because Live has three tiles now
/// and the cases below are all "do this to every one of them". A finder built
/// from `liveTileKey` also cannot drift from the widget, which is built from
/// the same function.
Finder liveTile(LiveScenario scenario, {bool skipOffstage = true}) =>
    find.byKey(ValueKey(liveTileKey(scenario)), skipOffstage: skipOffstage);

/// A checkout URL shaped like the real one, with a token-shaped tail. Never
/// a real value: the real thing is `…/pay?session=<token>`.
const String _checkoutUrl =
    'https://pay.example.com/pay?session=NOT-A-REAL-TOKEN';

MintedSession _mintedWithPage() => const MintedSession(
  id: 'sess-web',
  token: 'tok',
  sentBody: '{}',
  checkoutUrl: _checkoutUrl,
);

/// A secret store already holding a sandbox credential, so a tile tap gets
/// past "not configured" and reaches the surface question this file is
/// about.
Future<SecretStore> _configuredStore() async {
  final store = SecretStore(backend: InMemorySecretBackend());
  await store.write(
    const Credentials(clientId: 'id-1', clientSecret: 'secret-1'),
  );
  return store;
}

/// Drains a run screen's bookkeeping deadline.
///
/// Both run screens bound their version read with a five-second timeout, and
/// under `flutter test` the platform behind that read never answers -- so a
/// test that leaves either of them open ends with a real timer still armed,
/// which the framework reports as a failure. Pumping past it is exactly what
/// the screen does on a phone whose channel is wedged.
Future<void> _drainBookkeeping(WidgetTester tester) async {
  // Twice, because the two deadlines are not armed at the same moment: the
  // version read is bounded first, and the History write is only started
  // once that has answered -- which on a wedged platform is when its own
  // five seconds run out.
  await tester.pump(const Duration(seconds: 6));
  await tester.pump(const Duration(seconds: 6));
  await tester.pumpAndSettle();
}

/// The words one tile's title is showing.
///
/// A bare `Text` on a tile nobody has edited and a `Row` carrying the
/// "edited" marker beside it on one somebody has, so a case that reads a
/// title has to cope with both rather than assert whichever shape it
/// happened to get.
String _titleText(ListTile tile) {
  final title = tile.title!;
  if (title is Text) return title.data!;
  final beside = (title as Row).children.first as Expanded;
  return (beside.child as Text).data!;
}

/// The finder for one tile's "Open in browser" button.
Finder _browserButton(String tile) =>
    find.byKey(ValueKey(browserActionKey(tile)));

void main() {
  // `runInFlight` is top-level, so a test that ends while a read is still in
  // flight leaves it set and the next test silently cannot start a run at
  // all. Reset rather than tearDown: it also covers a test that dies.
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
    // The shipped promise this plan retires, gone rather than left false.
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
    // The default SettingsScreen reads the real secure store, which under
    // `flutter test` has no platform behind it. That read is guarded, so the
    // screen builds empty instead of throwing -- this is the "a null or
    // failed read means not configured" rule exercised against a genuinely
    // absent platform rather than against a fake that stands in for one.
    //
    // Tall, because the version panel this ends by asserting on is the last
    // row of a screen that has since grown a surface preference under the
    // buttons. A `ListView` never builds what is below the fold, so at the
    // default 800x600 the panel would be missing rather than pending -- and
    // "missing because it scrolled" is not what this case is about. The
    // default store is left in place on purpose: reaching a genuinely absent
    // platform is the whole point of the case, and `SurfaceStore` answers
    // the sheet on one exactly as `SecretStore` answers null.
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
  testWidgets('Live replaces the whole grid with three tiles', (tester) async {
    useTallSurface(tester);
    await tester.pumpWidget(
      await liveApp(
        home: HomeScreen(store: SecretStore(backend: InMemorySecretBackend())),
      ),
    );
    await tester.pumpAndSettle();

    // Three, and every one of them named by its own scenario: a screen that
    // drew the smoke three times would satisfy a bare count.
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
    // No Custom tile, no decline scenarios and no Google Pay tile. Live is
    // still deliberately small -- but every tile has a pencil now, because
    // what it charges is a body somebody can edit and keep.
    expect(find.byKey(const ValueKey('customPreset')), findsNothing);
    expect(
      find.byTooltip('Edit the body'),
      findsNWidgets(LiveScenario.values.length),
    );
    expect(find.byType(IconButton), findsWidgets); // the app bar still exists
    for (final preset in demoPresets) {
      expect(find.text(preset.name), findsNothing, reason: preset.name);
    }
  });

  testWidgets('Live hides the sandbox card cheat sheet', (tester) async {
    // Seven sandbox PANs that do nothing on a production merchant, under a
    // heading that says "test cards", on the one screen where a real card is
    // required. The screen itself is untouched; only the way in is.
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
    // The credential IS armed and the identity is not, which is the whole
    // point: a state holding neither would be refused by either check, so
    // the assertion would survive the identity half being deleted. Half-armed
    // is the only shape that pins this one.
    //
    // Every tile, because the refusal is one function that all three call and
    // a fourth tile pasted beside them is exactly how it stops being.
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

      // Somewhere the human can act, rather than a message they can only
      // read: the identity is typed on the screen this pushes.
      expect(
        find.byType(SettingsScreen),
        findsOneWidget,
        reason: scenario.name,
      );
      // And without minting: no dialog, no run.
      expect(find.byKey(const ValueKey('liveConfirmDialog')), findsNothing);
      expect(find.byType(RunScreen), findsNothing, reason: scenario.name);

      // Back to Home before the next tile. `pumpWidget` reuses the element
      // tree, so a Settings left pushed here would still be on screen for
      // the next pass -- and the assertion above would pass on it without
      // that pass having tapped anything at all.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsNothing, reason: scenario.name);
    }
  });

  testWidgets('no tile with no Live credentials mints anything either', (
    tester,
  ) async {
    // The mirror of the case above: the identity is armed and the credential
    // is not, so this one is what pins the credential half of the check.
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

      // The same rule `runPreset` applies in Test: route somewhere the human
      // can act, rather than mint and fail with a 401 that reads as a backend
      // problem.
      expect(
        find.byType(SettingsScreen),
        findsOneWidget,
        reason: scenario.name,
      );
      expect(find.byType(RunScreen), findsNothing, reason: scenario.name);

      // Back to Home before the next tile, for the reason the case above
      // pops: a Settings left pushed would satisfy the next pass by itself.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsNothing, reason: scenario.name);
    }
  });

  testWidgets('Settings pushed from the Live tile shows no stored credential', (
    tester,
  ) async {
    // The composed version of task 02's guard: this is the push that exists
    // only because of this task, and the credential fields it lands on are
    // one tap from "Use for this session".
    //
    // The credential goes behind the plugin's own test platform rather than
    // into a `SecretStore(backend: ...)`, because the screen this test is
    // about is the `const SettingsScreen()` the tile pushes -- exactly as
    // the app pushes it, with the default store. An injected backend never
    // reaches it, and a version of this test that used one passed with the
    // prefill guard deleted.
    FlutterSecureStorage.setMockInitialValues({
      'paycross_demo_client_id': 'test-id',
      'paycross_demo_client_secret': 'test-secret',
    });
    // Emptied rather than uninstalled: the plugin offers no way back to the
    // real platform, and an empty store is what every other case in this
    // file already sees from one that is not there.
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

    // The other half of the strip, where a credential IS held: truncated to
    // six characters, the same rule the sandbox strip follows, and read from
    // memory rather than from any store.
    expect(find.text('Live — client live-i…'), findsOneWidget);

    // All three tiles, and the same Cancel each time. A tile that skipped the
    // dialog would be the one way this app spends money on a single tap.
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
    // What `showDialog` answers when nothing was tapped is null, and on this
    // app's first-class platform the commonest way to produce it is the
    // system back button. `go != true` is what makes null a Cancel; the other
    // plausible spelling, `go == false`, turns back into a payment button and
    // leaves every other case in this file green.
    //
    // `handlePopRoute` rather than a tap on the `ModalBarrier`: the LIVE
    // banner sits above the Navigator, so the top-left of this screen is the
    // banner and a barrier tap lands on it. Back is also the gesture that
    // actually matters.
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

    // Production endpoints, and the credential that is in memory -- never
    // the one in the secure store, which this screen did not read.
    expect(used, same(liveEndpoints));
    expect(sentWith?.clientId, 'live-id');
    expect(find.byType(RunScreen), findsOneWidget);
    // Marked at push time, which is the only moment Home can say it: what
    // the run shows and what it writes to History both hang off this, and a
    // Live run recorded as a Test one is a charge nobody goes looking for.
    expect(tester.widget<RunScreen>(find.byType(RunScreen)).live, isTrue);
    // The fourth refusal, which is the only place it can be seen: Home is
    // still mounted under the pushed route, and EVERY tile is dead for as
    // long as the run one of them started is on screen. `skipOffstage: false`
    // because that is exactly where Home now is.
    //
    // All three, because the busy flag is one flag and three tiles: a guard
    // that only killed the tile that was tapped would leave the other two
    // live, and a second tap would mint a second production session and
    // stack a second Run screen on the first.
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

    // Drain the two bookkeeping timeouts the pushed Run screen started
    // against platform stores that never answer under `flutter test`.
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  });

  testWidgets('the smoke charges the identity that was typed', (tester) async {
    // The end of the whole chain: what a tester typed in Settings is what
    // the production merchant is asked to charge. Asserted against the
    // literals this test typed, never against values read back out of the
    // same state object the code read -- that would pass with the identity
    // dropped on the floor and a constant put back in its place.
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
    // Not the sandbox fake, which is what a body built from `defaultBody()`
    // would carry.
    expect(customer['email'], isNot('john.doe@example.com'));

    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  });

  testWidgets('every place quotes the amount in the body it will mint', (
    tester,
  ) async {
    // The hazard the single source was written for. The figure used to be
    // spelled out by hand at most of these sites, so an edit to one of them
    // left the app quoting two different numbers to the person about to
    // spend the money -- on the tile they tapped and in the dialog asking
    // them to confirm it. Three tiles multiply that hazard by three.
    //
    // Now that the amount is editable there is a second hazard on top: a
    // site still reading the old constant would quote €1.00 over a tile
    // somebody had saved at £42.50. So the bodies here are overridden, and
    // what is checked is that every site followed them.
    //
    // Read off the rendered widgets rather than off the functions that build
    // them: `live_test` already pins what the functions return, and a screen
    // that called the wrong one, or none, would pass that and fail this.
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
            // Keyed per pass. `pumpWidget` reuses the element tree, so a
            // HomeScreen swapped for another of the same type keeps the
            // State it had -- and `initState` would not run again, leaving
            // this pass reading the previous pass's store.
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

        // Nothing is minted here: Cancel, so the next tile is tapped on a
        // screen with no dialog over it.
        await tester.tap(find.byKey(const ValueKey('liveCancel')));
        await tester.pumpAndSettle();
      }

      // A title and a dialog for each of three tiles. Counted here so that a
      // copy site quietly deleted from the screen turns into a failure
      // rather than into a shorter loop.
      expect(quoted, hasLength(6), reason: code);
      for (final line in quoted) {
        expect(line, contains(label), reason: line);
        // And nothing on screen quotes the shipped figure, which is what a
        // site still reading the constant would say.
        expect(line, isNot(contains('1.00')), reason: line);
        // Nor one of the other two currencies. Without this a screen that
        // ignored the body and always said €42.50 would pass the EUR pass of
        // this loop and be caught only by the other two.
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
    // The paragraph quoted a constant while every tile charged it. It cannot
    // now: three tiles can hold three different amounts, so a paragraph with
    // a figure in it would be wrong for at least two of them.
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
    // Where the figure is, rather than the figure.
    expect(said, contains('its own title'));
    expect(said, isNot(contains('1.00')));
  });

  testWidgets('each tile mints its own body, not the tile above it', (
    tester,
  ) async {
    // The end of the chain for the two new tiles: what a tester tapped is
    // what the production merchant is asked for. The failure this rules out
    // is the cheap one -- three tiles wired to one scenario, which looks
    // right on screen and stores no card at all.
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
      // And the run is filed under the tile that was tapped, because History
      // records a run by its preset name and two charges under one name are
      // two charges nobody can tell apart afterwards.
      expect(
        tester.widget<RunScreen>(find.byType(RunScreen)).preset.name,
        liveScenarioName(scenario),
        reason: scenario.name,
      );

      // Drain the two bookkeeping timeouts the pushed Run screen started
      // against platform stores that never answer under `flutter test`.
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();

      // Back to Home before the next tile. `pumpWidget` reuses the element
      // tree, so the run this pass started is still on top of Home and every
      // tile under it is still dead -- which is the guard working, and is
      // also why the next pass cannot tap anything until this pops.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(RunScreen), findsNothing, reason: scenario.name);
    }
  });

  testWidgets('the smoke charges what its saved body says', (tester) async {
    // The other end of the same edit: not what the tester was shown, but
    // what the production merchant is asked for. A merchant that can only
    // take pounds is the reason this exists -- a body that said EUR would
    // be refused for a reason that says nothing about the SDK. It used to
    // come from a per-session dropdown; it is a saved body now, which is
    // what makes it survive a restart.
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
    // And the identity is spliced in at this moment rather than stored, so
    // the saved row holds none and the minted body holds all three.
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
      // The three facts one Live run is made of -- the credential, the Live
      // flag and the endpoints -- must come from one instant. The endpoints
      // used to be sampled last and lazily, inside the mint closure, so an
      // environment moved between Continue and the mint sent a PRODUCTION
      // credential to the SANDBOX token host, on a run displayed as Live and
      // recorded in History as Live.
      //
      // Nothing in the app can move it there today: the dialog is modal and
      // Settings is under it. This drives the state directly, which is how a
      // Retry button on RunScreen -- or any second surface that can leave Live
      // -- would reach it tomorrow.
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

      // Something that is not this screen leaves Live while the dialog is open.
      await state.leaveLive();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('liveContinue')));
      await tester.pumpAndSettle();

      expect(state.isLive, isFalse);
      // Production, because that is what the person authorised. The failure
      // this rules out is the opposite one: the sandbox host, reached with a
      // production client id and secret.
      expect(used, same(liveEndpoints));
      expect(sentWith?.clientId, 'live-id');

      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('the profile strip in Live never shows what a store holds', (
    tester,
  ) async {
    // A stored sandbox client id on a screen that says LIVE would be the
    // single most misleading thing this app could show. Both stores within
    // reach hold one: the screen's own, and the default one the plugin's
    // test platform stands in for.
    //
    // `find.textContaining('Live —')` is deliberately NOT the assertion: the
    // Live copy paragraph above the strip starts with those same two words,
    // so it matches with the sandbox strip still in place.
    final backend = InMemorySecretBackend()
      ..entries['paycross_demo_client_id'] = 'abcdef0123456789'
      ..entries['paycross_demo_client_secret'] = 'test-secret';
    FlutterSecureStorage.setMockInitialValues({
      'paycross_demo_client_id': 'abcdef0123456789',
      'paycross_demo_client_secret': 'test-secret',
    });
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

    // The banner is above the Scaffold, so this is where a double status-bar
    // inset or an overflowing tile shows up.
    expect(tester.takeException(), isNull);
    expect(liveTile(LiveScenario.smoke), findsOneWidget);

    // And the list reaches the bottom of itself. Three tiles are taller than
    // one, and the last of them is the one a phone is most likely to hide --
    // a tile nobody can scroll to is a tile nobody can run.
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
      // M5, carried forward from task 01's quality review. `mintWithCredentials`
      // builds its `Minter` with no `endpoints:` at all and so takes the Test
      // default deliberately; this one must not. A missing argument here would
      // send a production credential to the sandbox token endpoint, and the 401
      // that came back would read as a bad credential rather than as a mint
      // pointed at the wrong environment.
      //
      // Driven through the `client` seam rather than through the widget, because
      // the widget test above pins what the SCREEN passes into the seam and this
      // one pins what the default seam does with it. Between them there is no
      // step where the Test default could come back.
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
      // Named rather than left to the pair above: `testEndpoints` is what a
      // dropped argument falls back to, and this is the assertion that fails
      // when it does.
      expect(urls, isNot(contains(testEndpoints.tokenUrl)));
      expect(urls, isNot(contains(testEndpoints.sessionsUrl)));
    },
  );

  group('the second way to run every tile', () {
    testWidgets('every Test tile offers it, Custom included', (tester) async {
      // Nine tiles, one builder. A tile added later cannot quietly lack the
      // button, because there is no per-tile copy of it to forget.
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
      // The row where the mistake costs a production charge is the last row
      // to put an unlabelled icon on, so the words are on screen and the
      // longer sentence hangs off it as a tooltip.
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
      // The whole point of the feature: one mint, two surfaces. If the
      // bodies differ the two runs are not comparable and the wallet answer
      // means nothing.
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
      // The surface is decided before the body is typed and carried through,
      // so the editor keeps its single Run button.
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
      // The deep link's path. `main.dart` calls `runPreset` without naming a
      // surface, so this default is the whole of what keeps an automated run
      // out of the browser: the link cannot express the question.
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
  });

  group('the busy guard covers both of a tile\'s actions', () {
    testWidgets('a run in flight kills every browser button on the screen', (
      tester,
    ) async {
      // One flag for all of them, which is what makes them dead together
      // rather than one at a time: a second session is just as unwanted when
      // the second press lands on another tile's other button.
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
      // Nothing is minted until Continue. Cancel is still the default action
      // of a dialog about real money.
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

      // Scoped to the dialog: the tiles behind it all carry the words "Open
      // in browser", which is the point of them and not this assertion.
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
      // The barrier, which returns null rather than false.
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
      // Marked at push time, like the sheet's run: a Live run recorded as a
      // Test one is a charge nobody goes looking for.
      expect(
        tester
            .widget<WebCheckoutRunScreen>(find.byType(WebCheckoutRunScreen))
            .live,
        isTrue,
      );
      // The red block, naming the session id, since there is no transaction.
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
      // The first refusal, and the browser button is behind it exactly as
      // the tile is.
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
    /// A Home whose two stores are both in memory, so no case here reaches
    /// the Keychain or `SharedPreferences`.
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

      // The whole of what the owner asked for: a scenario edited once stays
      // edited, rather than needing the currency picked again every run.
      expect((jsonDecode(sent.single) as Map)['amount'], 4242);
    });

    testWidgets('an edited preset says so on its tile', (tester) async {
      final presets = PresetStore(backend: InMemoryPresetBackend());
      final preset = demoPresets.first;
      await presets.saveOverride(preset.id!, '{"amount":4242}');
      await pumpHome(tester, presets);

      // Without it the tile is indistinguishable from the shipped scenario,
      // and a run that behaves oddly reads as a bug in the SDK rather than
      // as the body somebody edited last week.
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

      // Byte for byte, because this is what the automated matrix runs.
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
      // And before Custom, which is the way in to a body nobody has typed
      // yet rather than one of the tiles.
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
      // Nothing shipped it, so there is no default to go back to.
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

      // Home re-reads when the editor closes. Without that the tile somebody
      // just made is not there until the app is restarted, which reads as
      // the save having failed.
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
      // The addendum's separation, at the screen. The two halves are two
      // SharedPreferences keys, so this is not a filter somebody has to
      // remember to apply -- but the screen is where a wiring mistake would
      // show, and a sandbox body on a production tile is a body nobody
      // reviewed against a real merchant.
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
      // And nothing sandbox-shaped at all: no Custom tile, no preset names.
      expect(find.byKey(const ValueKey('customPreset')), findsNothing);
      for (final preset in demoPresets) {
        expect(find.text(preset.name), findsNothing, reason: preset.name);
      }
      // What Live does show is its own half, which is the calibration: the
      // absences above are a separation rather than a screen that drew
      // nothing. By its full title, because a Live tile quotes what its own
      // body charges beside the name.
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
      // Through Home, not by wiring the editor by hand, because the bug was
      // in the wiring: Home substituted the override into the preset it
      // handed the pencil, so the editor reset to the override. It cleared
      // the store, changed nothing on screen, and did not mark the screen
      // dirty -- so the next Save wrote the edit straight back.
      //
      // Reset is exactly the control a tester reaches for after mistyping an
      // amount on a production tile.
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
      // It opens on what was saved, which is the other half of the wiring.
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('amount')))
            .controller!
            .text,
        '9999',
      );

      await tester.tap(find.text('Reset to default'));
      await tester.pumpAndSettle();

      // The shipped amount, on screen, not merely in the store.
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('amount')))
            .controller!
            .text,
        '$liveSmokeMinorUnits',
      );
      expect((await presets.read()).overrides, isEmpty);

      // And back on Home the tile is no longer marked edited, and quotes the
      // figure it ships with.
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

    testWidgets('an edited Live tile still mints what it says', (tester) async {
      // The calibration for the case above: the reset fix must not have
      // stopped Home reading the override at all.
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

      // The tile quotes the edit before it is tapped.
      expect(find.textContaining('£99.99'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('liveSmokeTile')));
      await tester.pumpAndSettle();
      // And so does the question it asks.
      expect(find.textContaining('£99.99'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('liveContinue')));
      await tester.pumpAndSettle();

      expect((jsonDecode(sent!) as Map)['amount'], 9999);

      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
    });

    testWidgets('Test never shows what was saved in Live', (tester) async {
      // The mirror, so the separation is pinned from both sides rather than
      // by one screen that happens to read the right field.
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
      // The sandbox tile the production store holds an override for is not
      // marked edited, because that override is not in this half.
      expect(
        find.byKey(ValueKey(editedMarkerKey(demoPresets.first.id!))),
        findsNothing,
      );
    });
  });
}
