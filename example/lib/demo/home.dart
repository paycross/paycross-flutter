import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'editor.dart';
import 'endpoints.dart';
import 'environment.dart';
import 'history_screen.dart';
import 'live.dart';
import 'minter.dart';
import 'preset_store.dart';
import 'presets.dart';
import 'run.dart';
import 'secrets.dart';
import 'settings.dart';
import 'surface.dart';
import 'test_cards_screen.dart';
import 'web_run.dart';

/// The app's real mint: one [Minter] per run, closed when that run is done.
///
/// A named function rather than a closure inside [runPreset] so a widget test
/// can put something else in its place and never open a socket.
Future<MintedSession> mintWithCredentials(
  Credentials credentials,
  String body,
) {
  final minter = Minter(credentials: credentials);
  return minter.mint(body).whenComplete(minter.close);
}

/// The Live mint: one [Minter] pointed at an environment the caller names.
///
/// A second function rather than an `endpoints` parameter on
/// [mintWithCredentials]: that one is threaded through `DemoHome` and handed
/// 2-argument closures by two existing tests, and widening it would churn the
/// sandbox path for a Live feature. It is also the more honest shape -- the
/// sandbox path takes the default and the Live path takes what the
/// environment state says, and those are two decisions.
///
/// [endpoints] has no default and is passed on explicitly, so a Live mint
/// cannot fall back to the sandbox pair the way [mintWithCredentials]
/// deliberately does. A production credential sent to the sandbox token
/// endpoint comes back 401, and a 401 reads as a bad credential rather than
/// as a mint pointed at the wrong environment.
///
/// [client] is the same seam [mintThrowawaySession] carries, for the same
/// reason: it is how a test proves the paragraph above without opening a
/// socket. Passing one also makes it the caller's to close.
Future<MintedSession> liveMintWithCredentials(
  Credentials credentials,
  String body,
  Endpoints endpoints, {
  http.Client? client,
}) {
  final minter = Minter(
    credentials: credentials,
    endpoints: endpoints,
    client: client,
  );
  return minter.mint(body).whenComplete(minter.close);
}

/// How long the credential read gets before a run gives up on it.
///
/// A platform store with nothing behind it does not fail, it never answers --
/// the same shape `run.dart` bounds its bookkeeping against. Unbounded, one
/// wedged Keychain would leave [runInFlight] set for the rest of the process
/// and neither entrance could start a run again.
const Duration _credentialReadTimeout = Duration(seconds: 5);

/// True while [runPreset] is reading the credentials for a run.
///
/// Top-level because there are two entrances to a run -- a preset tile on
/// Home and a `paycross-flutter-demo://run` link -- and one app. A flag on
/// Home guards the tiles against each other and leaves a link free to land
/// inside the same window; on a cold Keychain that window is long enough for
/// the second entrance to mint a second live session against the same
/// credentials and stack a second Run screen on the first.
///
/// It covers the read and stops there. Held until the pushed route had been
/// popped instead, no run could ever be started from the screen the last one
/// pushed, and a widget test that pushes without popping would leak it into
/// the next test.
///
/// Four things guard a run between them, and this is the only one both
/// entrances share:
///
/// - This flag: the credential read, whichever entrance is doing the reading.
/// - `_HomeScreenState._busy`: one tile against another, and the visible
///   half -- every tile goes dead while a run is being set up.
/// - `_DemoHomeState._busy`: one link against another, for as long as the run
///   that link started is still on screen.
/// - `_DemoHomeState`'s `ModalRoute.isCurrent` check: a link against anything
///   already pushed over Home, a run a tile started included -- which is the
///   one case none of the other three can see.
@visibleForTesting
bool runInFlight = false;

/// Reads the stored credentials and pushes a run, or pushes Settings.
///
/// Top-level, and the only path to a run: the preset tiles call it and so
/// does the deep link, so "not configured routes to Settings" is written
/// once and cannot be true of one entry point and false of the other, and
/// [runInFlight] is one guard rather than one per entrance.
///
/// A null read, a failed one, or one that never answers all mean "not
/// configured". Routing to Settings is what a colleague can act on; minting
/// anyway would fail later with an HTTP 401 that reads as a backend problem.
///
/// [surface] decides which screen the minted session is handed to, and
/// nothing else: the credential read, the guard, the routing to Settings and
/// the body are one code path whichever it is. It defaults to the sheet, and
/// that default is what keeps the deep link out of the browser -- the link
/// path calls this without naming a surface, so it cannot select one even by
/// accident. Only the tiles pass a surface, because only a human tapping a
/// tile has chosen one.
Future<void> runPreset(
  BuildContext context,
  Preset preset,
  String body, {
  SecretStore store = const SecretStore(),
  Future<MintedSession> Function(Credentials, String body) mintWith =
      mintWithCredentials,
  PaymentSurface surface = PaymentSurface.sdkSheet,
  LaunchCheckout launch = openInBrowser,
}) async {
  if (runInFlight) return;
  runInFlight = true;
  final credentials = await store
      .read()
      .timeout(_credentialReadTimeout, onTimeout: () => null)
      .whenComplete(() {
        runInFlight = false;
      });
  if (!context.mounted) return;
  if (credentials == null) {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
    return;
  }
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      // One mint closure, built once and handed to whichever screen is
      // pushed: the two surfaces cannot end up sending different bodies,
      // because there is only one thing here that sends anything.
      builder: (_) => switch (surface) {
        PaymentSurface.sdkSheet => RunScreen(
          preset: preset,
          body: body,
          mintSession: (body) => mintWith(credentials, body),
        ),
        PaymentSurface.webCheckout => WebCheckoutRunScreen(
          preset: preset,
          body: body,
          launch: launch,
          mintSession: (body) => mintWith(credentials, body),
        ),
      },
    ),
  );
}

/// The key one built-in tile's "edited" marker carries.
///
/// Built from the preset's id rather than its position or its name, for the
/// reason `browserActionKey` is: reordering the list does not move a key, and
/// a test that names a tile cannot quietly start asserting about another one.
String editedMarkerKey(String id) => 'edited:$id';

/// Which credentials a run would use, and where to change them.
///
/// The environment half is a constant, not a reading: this build has no
/// production endpoints. The credential half shows only the leading characters
/// of the client id -- enough to tell two merchants apart, and not a value
/// worth putting on a screenshot in full.
class ActiveProfileStrip extends StatefulWidget {
  const ActiveProfileStrip({super.key, this.store = const SecretStore()});

  final SecretStore store;

  @override
  State<ActiveProfileStrip> createState() => _ActiveProfileStripState();
}

class _ActiveProfileStripState extends State<ActiveProfileStrip> {
  String _profile = 'Sandbox — checking…';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final credentials = await widget.store.read();
    if (!mounted) return;
    final id = credentials?.clientId;
    setState(
      () => _profile = id == null
          ? 'Sandbox — not configured'
          : 'Sandbox — client ${id.length <= 6 ? id : '${id.substring(0, 6)}…'}',
    );
  }

  @override
  Widget build(BuildContext context) => Card(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: ListTile(
      key: const ValueKey('activeProfile'),
      dense: true,
      leading: const Icon(Icons.badge_outlined),
      title: Text(_profile),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        await Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
        await _load();
      },
    ),
  );
}

/// Which credentials a Live run would use -- from memory, and only memory.
///
/// A separate widget rather than a branch inside [ActiveProfileStrip]: that
/// one reads the secure store in `initState`, and the guarantee worth having
/// here is that nothing on a screen saying LIVE came from a store. Code that
/// cannot reach it cannot show it.
class LiveProfileStrip extends StatelessWidget {
  const LiveProfileStrip({super.key});

  @override
  Widget build(BuildContext context) {
    final credentials = LiveModeScope.maybeOf(context)?.liveCredentials;
    final id = credentials?.clientId;
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: ListTile(
        key: const ValueKey('liveProfile'),
        dense: true,
        leading: const Icon(Icons.warning_amber_rounded),
        title: Text(
          id == null
              ? 'Live — no credentials this session'
              : 'Live — client ${id.length <= 6 ? id : '${id.substring(0, 6)}…'}',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen())),
      ),
    );
  }
}

/// Where an ordinary build lands: pick a scenario, run it.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.store = const SecretStore(),
    this.presetStore = const PresetStore(),
    this.mintWith = mintWithCredentials,
    this.liveMintWith = liveMintWithCredentials,
    this.launch = openInBrowser,
  });

  final SecretStore store;

  /// The bodies somebody saved, and the tiles they made.
  ///
  /// A constructor argument for the same reason [store] is: the default
  /// reaches `SharedPreferences`, which under `flutter test` has no platform
  /// behind it -- and a store that cannot be read answers empty, so every
  /// existing case here draws the tiles it always drew.
  final PresetStore presetStore;

  /// Handed to a web run so a widget test never opens a browser.
  final LaunchCheckout launch;

  /// The sandbox mint. Unchanged, and not given an environment.
  final Future<MintedSession> Function(Credentials, String body) mintWith;

  /// The Live mint, which is told where to send the session.
  final Future<MintedSession> Function(Credentials, String body, Endpoints)
  liveMintWith;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// True from the tap until the run has been pushed or refused.
  ///
  /// The credential read sits in that gap and a cold Keychain makes it a real
  /// window, so an impatient second tap would mint a second live session and
  /// stack a second Run screen. Every tile goes dead rather than only the one
  /// that was tapped: the second session is just as unwanted when the second
  /// tap lands on a different scenario.
  bool _busy = false;

  /// The bodies somebody saved and the tiles they made, as of the last read.
  ///
  /// Empty until the first read comes back, and empty for good on a build
  /// whose store cannot be reached -- which is the shipped scenarios, drawn
  /// from `demoPresets` exactly as they always were.
  SavedPresets _saved = const SavedPresets();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // `PresetStore.read` answers empty on a store it cannot reach, so there
    // is nothing here to guard against beyond what it already does.
    final read = await widget.presetStore.read();
    if (!mounted) return;
    setState(() => _saved = read);
  }

  /// Runs [preset] on the surface the pressed control names.
  ///
  /// [surface] is an argument rather than a field, and that is the whole of
  /// how this screen decides: there is nothing here to read, nothing to keep
  /// in step with another screen and nothing that can be stale. The tile's
  /// body says the sheet, its browser button says the browser, and what runs
  /// is whichever of the two was pressed.
  Future<void> _run(
    BuildContext context,
    Preset preset,
    String body, {
    PaymentSurface surface = PaymentSurface.sdkSheet,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await runPreset(
        context,
        preset,
        body,
        store: widget.store,
        mintWith: widget.mintWith,
        surface: surface,
        launch: widget.launch,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Mints and runs one Live scenario, past three refusals.
  ///
  /// Three rungs, the first holding two conditions: nothing held for this
  /// session -- an identity or a credential, checked together because one
  /// button holds both -- then the confirmation dialog, then `_busy`.
  ///
  /// One function for all three tiles rather than one per tile. Every rung
  /// above is a rung a copied tile could be pasted without, and the tile that
  /// forgot one would be the tile that spends money on a single tap.
  ///
  /// Deliberately not routed through [runPreset]. That function exists to
  /// make "not configured routes to Settings" true of both entrances to a
  /// sandbox run, and it does it by reading `SecretStore` -- which is the one
  /// thing a Live run must never do. Threading an environment through it
  /// would put a production branch inside the function both sandbox
  /// entrances share.
  ///
  /// [runInFlight] is not needed here for the same reason it never was: deep
  /// links are rejected in Live, so these tiles are the only entrance and
  /// `_busy` is the only guard one entrance needs. `_busy` is one flag for
  /// all three tiles, which is what makes them dead together rather than one
  /// at a time -- a second production session is just as unwanted when the
  /// second tap lands on a different tile.
  Future<void> _runLiveScenario(
    BuildContext context,
    LiveScenario scenario, {
    PaymentSurface surface = PaymentSurface.sdkSheet,
  }) async {
    // Belt to the disabled tiles' braces. They are what a tester sees, and
    // this is what holds if a tap is ever delivered to one anyway.
    if (_busy) return;
    final state = LiveModeScope.maybeOf(context);
    if (state == null || !state.isLive) return;

    final identity = state.liveIdentity;
    final credentials = state.liveCredentials;
    // Together, because one button holds both: a session that has one and
    // not the other is a state the app cannot reach, and both are fixed on
    // the same screen. Settings rather than a message, for the same reason
    // `runPreset` routes there in Test -- somewhere the human can act beats
    // a refusal they can only read.
    if (identity == null || credentials == null) {
      await Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
      return;
    }

    // Sampled here, beside the credential, and not read again. One Live run
    // is made of three facts -- which credential, which endpoints, and that
    // it is Live at all -- and a confirmation dialog sits between this line
    // and the mint. Read lazily inside the mint closure instead, `endpoints`
    // would answer whatever the app-wide state said when the mint ran, so an
    // environment moved across that dialog would send this production
    // credential to the sandbox token host on a run still displayed and
    // recorded as Live. Task 02 removed exactly this shape from Settings; it
    // does not belong in the function that spends money.
    final endpoints = state.endpoints;
    // Sampled at the same instant and for the same reason: the dialog below
    // quotes this figure and the body minted after it is built from it, so
    // reading it twice would let a currency changed across the dialog make
    // the two disagree about what the person authorised.
    final currency = state.liveCurrency;

    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('liveConfirmDialog'),
        title: const Text('Charge a real card?'),
        // The whole question, from `live.dart`: the amount, one sentence for
        // the saved-card tiles about what else this tap does, and one more
        // for the web surface about where it happens. Built there rather than
        // here so the dialog and the tile above it cannot end up describing
        // different tiles.
        content: Text(
          liveConfirmQuestion(scenario, currency, surface: surface),
        ),
        actions: [
          // Cancel is the filled button and holds the focus: the default
          // action of this dialog is to not spend money. A dismissed barrier
          // answers null, which reads the same way below.
          FilledButton(
            key: const ValueKey('liveCancel'),
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('liveContinue'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              'Continue',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (go != true || !context.mounted) return;

    setState(() => _busy = true);
    final preset = livePreset(scenario, identity, currency);
    // All three from the one instant above, and the surface from the control
    // that was pressed. Built once and handed to whichever screen is pushed,
    // so the two surfaces mint the same production body through the same
    // closure -- a Live web run and a Live sheet run differ in where the card
    // is typed and in nothing else.
    Future<MintedSession> mint(String body) =>
        widget.liveMintWith(credentials, body, endpoints);
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => switch (surface) {
            PaymentSurface.sdkSheet => RunScreen(
              preset: preset,
              body: preset.body,
              live: true,
              mintSession: mint,
            ),
            PaymentSurface.webCheckout => WebCheckoutRunScreen(
              preset: preset,
              body: preset.body,
              live: true,
              launch: widget.launch,
              mintSession: mint,
            ),
          },
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Opens the editor on one preset, and re-reads the store when it closes.
  ///
  /// One function for all three ways in -- a built-in's pencil, a saved
  /// tile's pencil and the Custom tile -- so the re-read cannot be forgotten
  /// on one of them. Without it a tile somebody just made is not on Home
  /// until the app is restarted, which reads as the save having failed.
  ///
  /// The surface is decided before the body is typed and carried through, so
  /// the editor itself has no opinion about it: one Run button, and it runs
  /// wherever the press that opened this said.
  Future<void> _edit(
    BuildContext context,
    Preset preset, {
    required PresetKind kind,
    String? savedBody,
    PaymentSurface surface = PaymentSurface.sdkSheet,
  }) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => EditorScreen(
          preset: preset,
          kind: kind,
          savedBody: savedBody,
          store: widget.presetStore,
          onRun: (body) => _run(context, preset, body, surface: surface),
        ),
      ),
    );
    await _load();
  }

  /// The word one tile carries to say its body is not the shipped one.
  ///
  /// Quiet, and the same shape History's WEB marker is: it is a fact about
  /// the row rather than a warning, and a run that behaves unexpectedly is a
  /// great deal easier to read when the tile admits somebody edited it.
  Widget? _editedMarker(Preset preset) {
    final id = preset.id;
    if (id == null || !_saved.isEdited(preset)) return null;
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Text(
        'edited',
        key: ValueKey(editedMarkerKey(id)),
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
    );
  }

  /// The pencil, which is the same affordance on a shipped tile and on one
  /// somebody made.
  Widget _pencil(
    BuildContext context,
    Preset preset, {
    required PresetKind kind,
    String? savedBody,
  }) => IconButton(
    icon: const Icon(Icons.edit),
    tooltip: 'Edit the body',
    // The pencil is the edit affordance, so its Run is the ordinary run:
    // the sheet. Custom's browser button below is the way to an edited body
    // in the browser, and it says so on the button.
    onPressed: () => _edit(context, preset, kind: kind, savedBody: savedBody),
  );

  /// One tile: what it is, and the two ways to run it.
  ///
  /// A single builder for all thirteen -- eight presets, Custom and the three
  /// Live ones -- rather than a browser button pasted onto each. The button
  /// that spends real money on a production tile and the button that opens a
  /// sandbox preset are then the same widget with different arguments: a tile
  /// added later cannot quietly lack one, none of them can drift into a
  /// different word for the same action, and the busy guard is written once
  /// instead of thirteen times.
  ///
  /// The action sits under the tile rather than in `trailing` beside the
  /// pencil. Eight of these already carry three lines of subtitle, and an
  /// icon-only button in that corner would be a second unlabelled glyph next
  /// to the first -- on the row where the mistake costs a production charge.
  /// Under it there is room for the words.
  Widget _tile(
    BuildContext context, {
    required String actionKey,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    required VoidCallback onOpenInBrowser,
    Key? cardKey,
    Color? color,
    Color? onBrowser,
    Widget? leading,
    Widget? trailing,
    Widget? marker,
  }) => Card(
    key: cardKey,
    color: color,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: leading,
          // A Row only when there is something beside the title, so the
          // twelve tiles that carry no marker are the widget they were.
          title: marker == null
              ? Text(title)
              : Row(
                  children: [
                    Expanded(child: Text(title)),
                    marker,
                  ],
                ),
          subtitle: Text(subtitle),
          isThreeLine: true,
          trailing: trailing,
          onTap: _busy ? null : onTap,
        ),
        Padding(
          padding: const EdgeInsets.only(left: 8, right: 8, bottom: 8),
          child: Tooltip(
            message: openInBrowserHint,
            child: TextButton.icon(
              key: ValueKey(browserActionKey(actionKey)),
              icon: const Icon(Icons.open_in_browser, size: 20),
              label: const Text(openInBrowserLabel),
              style: TextButton.styleFrom(foregroundColor: onBrowser),
              onPressed: _busy ? null : onOpenInBrowser,
            ),
          ),
        ),
      ],
    ),
  );

  /// One tile somebody made.
  ///
  /// Built through the same [_tile] the shipped scenarios use, so it carries
  /// the browser button and the busy guard without either being pasted here.
  /// Its body is the saved one -- there is no other -- so it needs no
  /// `savedBody` and has no default to be marked as edited against.
  Widget _customTile(BuildContext context, CustomPreset saved) {
    final preset = saved.asPreset();
    return _tile(
      context,
      cardKey: ValueKey('customTile:${saved.id}'),
      // The id, not the name: two tiles somebody named the same thing would
      // otherwise carry the same key as each other and as a built-in.
      actionKey: saved.id,
      leading: const Icon(Icons.bookmark_outline),
      title: preset.name,
      subtitle: preset.expected,
      trailing: _pencil(context, preset, kind: PresetKind.custom),
      onTap: () => _run(context, preset, preset.body),
      onOpenInBrowser: () => _run(
        context,
        preset,
        preset.body,
        surface: PaymentSurface.webCheckout,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = LiveModeScope.maybeOf(context);
    final live = state?.isLive ?? false;
    // What the two Live copy sites below quote. The tile is drawn before
    // anything has been held for the session, so this is the default until
    // "Use for this session" has been pressed -- and there is no scope at
    // all in the automation build, where it is never read.
    final currency = state?.liveCurrency ?? liveDefaultCurrency;
    return Scaffold(
      appBar: AppBar(
        title: const Text('PayCross Demo'),
        actions: [
          // Seven sandbox PANs, under a heading that says "test cards", on the
          // one screen where a real card is what is required. The sheet itself
          // is untouched; in Live there is simply no way in.
          if (!live)
            IconButton(
              icon: const Icon(Icons.credit_card),
              tooltip: 'Test cards',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const TestCardsScreen(),
                ),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'History',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const HistoryScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            // The line shipped in v0.1.0 promised this build could not
            // reach production. It can now, so the promise is replaced
            // rather than left standing while being false.
            child: Text(
              key: const ValueKey('homeEnvironment'),
              live
                  ? 'Live — the PayCross production environment. Each of the '
                        'three tiles below charges a real card '
                        '${liveSmokeAmountLabel(currency)}. Refund every one '
                        'you run in the back office as soon as it settles; '
                        'this app cannot.'
                  : 'Test — this build talks to the PayCross TEST sandbox. '
                        'Switch to Live in Settings to reach production; it '
                        'starts in Test on every launch.',
            ),
          ),
          live
              ? const LiveProfileStrip()
              : ActiveProfileStrip(store: widget.store),
          // Three tiles, drawn from one list and run by one function. The
          // order is the order they are worth running: the smoke first, then
          // the pair, whose second half has nothing to offer until the first
          // half has settled.
          if (live)
            for (final scenario in LiveScenario.values)
              _tile(
                context,
                cardKey: ValueKey(liveTileKey(scenario)),
                actionKey: liveTileKey(scenario),
                color: Theme.of(context).colorScheme.errorContainer,
                onBrowser: Theme.of(context).colorScheme.onErrorContainer,
                leading: const Icon(Icons.credit_card),
                title: liveScenarioName(scenario, currency),
                subtitle: liveScenarioExpectation(scenario, currency),
                // Every tile goes dead while any run is being set up, not
                // just the one that was tapped, and both of a tile's actions
                // go together: a second production session is just as
                // unwanted when the second press lands on the other button.
                onTap: () => _runLiveScenario(context, scenario),
                onOpenInBrowser: () => _runLiveScenario(
                  context,
                  scenario,
                  surface: PaymentSurface.webCheckout,
                ),
              ),
          if (!live)
            for (final preset in demoPresets)
              _tile(
                context,
                actionKey: preset.name,
                title: preset.name,
                marker: _editedMarker(preset),
                subtitle: [
                  preset.expected,
                  if (preset.cardHint != null) 'Card: ${preset.cardHint}',
                  if (preset.hint != null) preset.hint!,
                ].join('\n'),
                trailing: _pencil(
                  context,
                  preset,
                  kind: PresetKind.builtIn,
                  savedBody: _saved.overrides[preset.id],
                ),
                // The saved body if somebody saved one, and the shipped bytes
                // otherwise. Both buttons take it from the same place, so an
                // edited scenario cannot run edited in the sheet and shipped
                // in the browser.
                onTap: () => _run(context, preset, _saved.bodyFor(preset)),
                onOpenInBrowser: () => _run(
                  context,
                  preset,
                  _saved.bodyFor(preset),
                  surface: PaymentSurface.webCheckout,
                ),
              ),
          // The tiles somebody made, after the shipped ones and before
          // Custom: the built-ins are what the guide names and the matrix
          // runs, and Custom is the way in to a body nobody has typed yet
          // rather than one of the scenarios.
          if (!live)
            for (final saved in _saved.custom) _customTile(context, saved),
          // The way in for a scenario nobody wrote a preset for. It opens the
          // same editor the pencils do, on the ordinary body. Both of its
          // actions go through that editor, because a body nobody has typed
          // yet is the one thing this tile is for -- the surface is decided
          // by which of the two was pressed, and carried into the editor's
          // Run.
          if (!live)
            _tile(
              context,
              cardKey: const ValueKey('customPreset'),
              actionKey: 'customPreset',
              leading: const Icon(Icons.tune),
              title: 'Custom',
              subtitle:
                  'Edit a session body by hand and run it. "Save as new…" '
                  'keeps it as a tile of its own.',
              onTap: () =>
                  _edit(context, customPreset, kind: PresetKind.scratch),
              onOpenInBrowser: () => _edit(
                context,
                customPreset,
                kind: PresetKind.scratch,
                surface: PaymentSurface.webCheckout,
              ),
            ),
        ],
      ),
    );
  }
}
