import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'editor.dart';
import 'endpoints.dart';
import 'environment.dart';
import 'history_screen.dart';
import 'live.dart';
import 'minter.dart';
import 'presets.dart';
import 'run.dart';
import 'secrets.dart';
import 'settings.dart';
import 'test_cards_screen.dart';

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
Future<void> runPreset(
  BuildContext context,
  Preset preset,
  String body, {
  SecretStore store = const SecretStore(),
  Future<MintedSession> Function(Credentials, String body) mintWith =
      mintWithCredentials,
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
      builder: (_) => RunScreen(
        preset: preset,
        body: body,
        mintSession: (body) => mintWith(credentials, body),
      ),
    ),
  );
}

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
    this.mintWith = mintWithCredentials,
    this.liveMintWith = liveMintWithCredentials,
    this.smokeProblem = _liveSmokeProblem,
  });

  final SecretStore store;

  /// The sandbox mint. Unchanged, and not given an environment.
  final Future<MintedSession> Function(Credentials, String body) mintWith;

  /// The Live mint, which is told where to send the session.
  final Future<MintedSession> Function(Credentials, String body, Endpoints)
  liveMintWith;

  /// Why the Live smoke cannot run, or null.
  ///
  /// A constructor argument only so a widget test can reach the dialog while
  /// the shipped `liveSmokeIdentity` is still the placeholder it is supposed
  /// to be. The app always passes the real predicate, and the test that the
  /// tile refuses uses the default.
  final String? Function() smokeProblem;

  /// The default, as a static tear-off.
  ///
  /// A closure -- `() => liveSmokeIdentityProblem` -- is not a constant
  /// expression, so it cannot be a default at all without dropping this
  /// class's `const` constructor, and four existing tests build
  /// `const MaterialApp(home: HomeScreen())`. A static method reference is
  /// constant, which is the same trick `RunScreen` already uses for
  /// `PayCross.presentPayment`. A function rather than a `String?` so the
  /// predicate is read at tap time, not at build time.
  static String? _liveSmokeProblem() => liveSmokeIdentityProblem;

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

  Future<void> _run(BuildContext context, Preset preset, String body) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await runPreset(
        context,
        preset,
        body,
        store: widget.store,
        mintWith: widget.mintWith,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Mints and runs the one Live scenario, past four refusals.
  ///
  /// Deliberately not routed through [runPreset]. That function exists to
  /// make "not configured routes to Settings" true of both entrances to a
  /// sandbox run, and it does it by reading `SecretStore` -- which is the one
  /// thing a Live run must never do. Threading an environment through it
  /// would put a production branch inside the function both sandbox
  /// entrances share.
  ///
  /// [runInFlight] is not needed here for the same reason: deep links are
  /// rejected in Live, so this tile is the only entrance and `_busy` is the
  /// only guard a single entrance needs.
  Future<void> _runLiveSmoke(BuildContext context) async {
    final state = LiveModeScope.maybeOf(context);
    if (state == null || !state.isLive) return;

    final problem = widget.smokeProblem();
    if (problem != null) {
      // Said on screen, naming the constant: a tile that quietly did nothing
      // is what a broken build looks like, and the person holding the phone
      // is the one who has to report what is missing.
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(problem)));
      return;
    }

    final credentials = state.liveCredentials;
    if (credentials == null) {
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

    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('liveConfirmDialog'),
        title: const Text('Charge a real card?'),
        content: Text(
          'This will charge a real card '
          '€${(liveSmokeMinorUnits / 100).toStringAsFixed(2)}. Continue?',
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
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => RunScreen(
            preset: liveSmokePreset,
            body: liveSmokePreset.body,
            live: true,
            // All three from the one instant above: the pair the person was
            // looking at when they pressed Continue. Derived from the same
            // field the banner renders, so the endpoints a run reaches cannot
            // say one thing while the screen that authorised it said another.
            mintSession: (body) =>
                widget.liveMintWith(credentials, body, endpoints),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final live = LiveModeScope.maybeOf(context)?.isLive ?? false;
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
            // The shipped line promised there was no way to reach production.
            // There is one now, so the promise is replaced rather than left
            // standing while being false.
            child: Text(
              key: const ValueKey('homeEnvironment'),
              live
                  ? 'Live — the PayCross production environment. The tile below '
                        'charges a real card €1.00. Refund it in the back '
                        'office as soon as it settles; this app cannot.'
                  : 'Test — this build talks to the PayCross TEST sandbox. '
                        'Switch to Live in Settings to reach production; it '
                        'starts in Test on every launch.',
            ),
          ),
          live
              ? const LiveProfileStrip()
              : ActiveProfileStrip(store: widget.store),
          if (live)
            Card(
              key: const ValueKey('liveSmokeTile'),
              color: Theme.of(context).colorScheme.errorContainer,
              child: ListTile(
                leading: const Icon(Icons.credit_card),
                title: Text(liveSmokePreset.name),
                subtitle: Text(liveSmokePreset.expected),
                isThreeLine: true,
                onTap: _busy ? null : () => _runLiveSmoke(context),
              ),
            ),
          if (!live)
            for (final preset in demoPresets)
              Card(
                child: ListTile(
                  title: Text(preset.name),
                  subtitle: Text(
                    [
                      preset.expected,
                      if (preset.cardHint != null) 'Card: ${preset.cardHint}',
                      if (preset.hint != null) preset.hint!,
                    ].join('\n'),
                  ),
                  isThreeLine: true,
                  trailing: IconButton(
                    icon: const Icon(Icons.edit),
                    tooltip: 'Edit the body',
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => EditorScreen(
                          preset: preset,
                          onRun: (body) => _run(context, preset, body),
                        ),
                      ),
                    ),
                  ),
                  onTap: _busy
                      ? null
                      : () => _run(context, preset, preset.body),
                ),
              ),
          // The way in for a scenario nobody wrote a preset for. It opens the
          // same editor the pencils do, on the ordinary body.
          if (!live)
            Card(
              child: ListTile(
                key: const ValueKey('customPreset'),
                leading: const Icon(Icons.tune),
                title: const Text('Custom'),
                subtitle: const Text('Edit a session body by hand and run it.'),
                onTap: _busy
                    ? null
                    : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => EditorScreen(
                            preset: customPreset,
                            onRun: (body) => _run(context, customPreset, body),
                          ),
                        ),
                      ),
              ),
            ),
        ],
      ),
    );
  }
}
