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
import 'package:paycross_demo/demo/presets.dart';
import 'package:paycross_demo/demo/run.dart';
import 'package:paycross_demo/demo/secrets.dart';
import 'package:paycross_demo/demo/settings.dart';
import 'package:paycross_demo/demo/test_cards_screen.dart';

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

/// A Live state that is already holding a session credential.
///
/// The order is the whole reason this is a helper. `useForThisSession` is a
/// no-op outside Live -- deliberately, so a Test credential can never be held
/// as a production one -- so a pair armed before the switch is silently
/// dropped and every tile tap lands on the no-credentials refusal instead of
/// the one the test is about.
Future<DemoEnvironmentState> liveHolding(Credentials credentials) async {
  final state = fakeEnvironment();
  await state.enterLive(liveConfirmationWord);
  state.useForThisSession(credentials);
  return state;
}

const Credentials _liveCredentials = Credentials(
  clientId: 'live-id',
  clientSecret: 'live-secret',
);

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
  testWidgets('Live replaces the whole grid with one tile', (tester) async {
    useTallSurface(tester);
    await tester.pumpWidget(
      await liveApp(
        home: HomeScreen(store: SecretStore(backend: InMemorySecretBackend())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('liveSmokeTile')), findsOneWidget);
    // No editor, no custom preset, no stored-card pair, no decline
    // scenarios, no Google Pay tile. Live is deliberately tiny.
    expect(find.byKey(const ValueKey('customPreset')), findsNothing);
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

  testWidgets('the tile refuses while the identity is a placeholder', (
    tester,
  ) async {
    // The blocking owner input, enforced where it costs nothing to be wrong.
    // This case passes today because the constant ships as a placeholder, and
    // it is expected to be rewritten in the commit that supplies the real
    // identity.
    //
    // No credentials are armed, and that is what pins the ORDER rather than
    // just the refusal: with a pair in memory the second refusal cannot fire
    // either way and the case survives the two being swapped. Without one,
    // a swap pushes Settings and never names the constant.
    final state = fakeEnvironment();
    await tester.pumpWidget(
      await liveApp(
        state: state,
        home: HomeScreen(store: SecretStore(backend: InMemorySecretBackend())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('liveSmokeTile')));
    await tester.pumpAndSettle();

    expect(find.textContaining('liveSmokeIdentity'), findsOneWidget);
    // Loudly, and without minting: no dialog, no run, and not the
    // no-credentials branch either.
    expect(find.byType(SettingsScreen), findsNothing);
    expect(find.byKey(const ValueKey('liveConfirmDialog')), findsNothing);
    expect(find.byType(RunScreen), findsNothing);

    // Let the snack bar time itself out; a pending timer fails the test.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('with no Live credentials the tile opens Settings', (
    tester,
  ) async {
    final state = fakeEnvironment();
    await tester.pumpWidget(
      await liveApp(
        state: state,
        home: HomeScreen(
          store: SecretStore(backend: InMemorySecretBackend()),
          // Past refusal 1. The shipped identity is a placeholder, and
          // `_runLiveSmoke` returns after that snackbar -- so without this
          // the credentials branch is never reached and no Settings screen
          // is ever pushed.
          smokeProblem: () => null,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('liveSmokeTile')));
    await tester.pumpAndSettle();

    // The same rule `runPreset` applies in Test: route somewhere the human
    // can act, rather than mint and fail with a 401 that reads as a backend
    // problem. Ordered after the identity check because a placeholder is
    // wrong for everybody, and missing credentials are wrong for one session.
    expect(find.byType(SettingsScreen), findsOneWidget);
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
        home: HomeScreen(
          store: SecretStore(backend: InMemorySecretBackend()),
          // Past refusal 1, so the tap reaches the no-credentials branch and
          // actually pushes the screen this test is about.
          smokeProblem: () => null,
        ),
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

  testWidgets('the dialog defaults to not spending money', (tester) async {
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
          // Injected so this case is reachable while the shipped identity is
          // still a placeholder; the tile's own refusal is pinned above.
          // A function, not a bare null: the field is `String? Function()`.
          smokeProblem: () => null,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The other half of the strip, where a credential IS held: truncated to
    // six characters, the same rule the sandbox strip follows, and read from
    // memory rather than from any store.
    expect(find.text('Live — client live-i…'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('liveSmokeTile')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('liveConfirmDialog')), findsOneWidget);
    expect(find.textContaining('charge a real card'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('liveCancel')));
    await tester.pumpAndSettle();

    expect(minted, 0);
    expect(find.byType(RunScreen), findsNothing);
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
          smokeProblem: () => null,
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
          smokeProblem: () => null,
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
    // still mounted under the pushed route, and its one tile is dead for as
    // long as the run it started is on screen. `skipOffstage: false` because
    // that is exactly where Home now is.
    expect(
      tester
          .widget<ListTile>(
            find.descendant(
              of: find.byKey(
                const ValueKey('liveSmokeTile'),
                skipOffstage: false,
              ),
              matching: find.byType(ListTile, skipOffstage: false),
            ),
          )
          .onTap,
      isNull,
    );

    // Drain the two bookkeeping timeouts the pushed Run screen started
    // against platform stores that never answer under `flutter test`.
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  });

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
    expect(find.byKey(const ValueKey('liveSmokeTile')), findsOneWidget);
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
        liveSmokeBody,
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
}
