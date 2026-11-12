import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../shop/catalogue.dart';
import '../shop/shop_screen.dart';
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

Future<MintedSession> mintWithCredentials(
  Credentials credentials,
  String body,
) {
  final minter = Minter(credentials: credentials);
  return minter.mint(body).whenComplete(minter.close);
}

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

const Duration credentialReadTimeout = Duration(seconds: 5);

@visibleForTesting
bool runInFlight = false;

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
      .timeout(credentialReadTimeout, onTimeout: () => null)
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
  final environment = LiveModeScope.readOf(context);
  final themed = preset.appearance;

  try {
    if (themed != null) {
      await environment?.applyTestAppearance(themed);
      if (!context.mounted) return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
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
  } finally {
    if (themed != null) {
      await environment?.applyTestAppearance(null);
    }
  }
}

String editedMarkerKey(String id) => 'edited:$id';

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

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.store = const SecretStore(),
    this.presetStore = const PresetStore(),
    this.livePresetStore = const PresetStore(environment: DemoEnvironment.live),
    this.mintWith = mintWithCredentials,
    this.liveMintWith = liveMintWithCredentials,
    this.launch = openInBrowser,
  });

  final SecretStore store;

  final PresetStore presetStore;

  final PresetStore livePresetStore;

  final LaunchCheckout launch;

  final Future<MintedSession> Function(Credentials, String body) mintWith;

  final Future<MintedSession> Function(Credentials, String body, Endpoints)
  liveMintWith;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _busy = false;

  SavedPresets _saved = const SavedPresets();

  SavedPresets _savedLive = const SavedPresets();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() => Future.wait([
    widget.presetStore.read().then((read) {
      if (mounted) setState(() => _saved = read);
    }),
    widget.livePresetStore.read().then((read) {
      if (mounted) setState(() => _savedLive = read);
    }),
  ]);

  List<Preset> get _liveTiles => [
    ...liveDefaultPresets,
    for (final saved in _savedLive.custom)
      saved.asPreset(expected: liveCustomExpectation),
  ];

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

  Future<void> _runLive(
    BuildContext context,
    Preset preset,
    String body, {
    PaymentSurface surface = PaymentSurface.sdkSheet,
  }) async {
    if (_busy) return;
    final state = LiveModeScope.maybeOf(context);
    if (state == null || !state.isLive) return;

    final identity = state.liveIdentity;
    final credentials = state.liveCredentials;
    if (identity == null || credentials == null) {
      await Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
      return;
    }

    final endpoints = state.endpoints;
    if (liveBodyMoney(body) == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'This tile\'s body has no amount this build can read. Open it '
            'with the pencil and fix it before running it.',
          ),
        ),
      );
      return;
    }

    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('liveConfirmDialog'),
        title: const Text('Charge a real card?'),
        content: Text(liveConfirmQuestion(body, surface: surface)),
        actions: [
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
    final charged = withLiveIdentity(body, identity);
    Future<MintedSession> mint(String body) =>
        widget.liveMintWith(credentials, body, endpoints);
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => switch (surface) {
            PaymentSurface.sdkSheet => RunScreen(
              preset: preset,
              body: charged,
              live: true,
              mintSession: mint,
            ),
            PaymentSurface.webCheckout => WebCheckoutRunScreen(
              preset: preset,
              body: charged,
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

  Future<void> _edit(
    BuildContext context,
    Preset preset, {
    required PresetKind kind,
    String? savedBody,
    DemoEnvironment environment = DemoEnvironment.test,
    PaymentSurface surface = PaymentSurface.sdkSheet,
  }) async {
    final live = environment == DemoEnvironment.live;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => EditorScreen(
          preset: preset,
          kind: kind,
          savedBody: savedBody,
          environment: environment,
          store: live ? widget.livePresetStore : widget.presetStore,
          onRun: (body) => live
              ? _runLive(context, preset, body, surface: surface)
              : _run(context, preset, body, surface: surface),
        ),
      ),
    );
    await _load();
  }

  Widget? _editedMarker(Preset preset, {bool live = false}) {
    final id = preset.id;
    final saved = live ? _savedLive : _saved;
    if (id == null || !saved.isEdited(preset)) return null;
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Text(
        'edited',
        key: ValueKey(editedMarkerKey(id)),
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _pencil(
    BuildContext context,
    Preset preset, {
    required PresetKind kind,
    String? savedBody,
    DemoEnvironment environment = DemoEnvironment.test,
  }) => IconButton(
    icon: const Icon(Icons.edit),
    tooltip: 'Edit the body',
    onPressed: () => _edit(
      context,
      preset,
      kind: kind,
      savedBody: savedBody,
      environment: environment,
    ),
  );

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

  String _liveBody(Preset preset) => _savedLive.bodyFor(preset);

  String _liveTileKey(Preset preset) {
    for (final scenario in LiveScenario.values) {
      if (preset.id == liveScenarioId(scenario)) return liveTileKey(scenario);
    }
    return preset.id ?? preset.name;
  }

  PresetKind _liveKind(Preset preset) =>
      liveDefaultPresets.any((p) => p.id == preset.id)
      ? PresetKind.builtIn
      : PresetKind.custom;

  Widget _customTile(BuildContext context, CustomPreset saved) {
    final preset = saved.asPreset();
    return _tile(
      context,
      cardKey: ValueKey('customTile:${saved.id}'),
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('PayCross Demo'),
        actions: [
          if (!live)
            IconButton(
              icon: const Icon(Icons.storefront),
              tooltip: 'Shop',
              onPressed: () => Navigator.of(context).push(shopRoute()),
            ),
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
            child: Text(
              key: const ValueKey('homeEnvironment'),
              live
                  ? 'Live — the PayCross production environment. Every tile '
                        'below charges a real card what its own title says. '
                        'Refund every one you run in the back office as soon '
                        'as it settles; this app cannot. The pencil edits '
                        'what a tile charges.'
                  : 'Test — this build talks to the PayCross TEST sandbox. '
                        'Switch to Live in Settings to reach production; it '
                        'starts in Test on every launch.',
            ),
          ),
          live
              ? const LiveProfileStrip()
              : ActiveProfileStrip(store: widget.store),
          if (!live)
            Card(
              key: const ValueKey('shopTile'),
              child: ListTile(
                leading: const Icon(Icons.storefront),
                title: const Text(shopName),
                subtitle: const Text(
                  'Buy something, the way a shopper would. The same mint and '
                  'the same sheet as the scenarios below.',
                ),
                onTap: _busy
                    ? null
                    : () => Navigator.of(context).push(shopRoute()),
              ),
            ),
          if (live)
            for (final preset in _liveTiles)
              _tile(
                context,
                cardKey: ValueKey(_liveTileKey(preset)),
                actionKey: _liveTileKey(preset),
                color: Theme.of(context).colorScheme.errorContainer,
                onBrowser: Theme.of(context).colorScheme.onErrorContainer,
                leading: const Icon(Icons.credit_card),
                title: liveTileTitle(preset.name, _liveBody(preset)),
                marker: _editedMarker(preset, live: true),
                subtitle: preset.expected,
                trailing: _pencil(
                  context,
                  preset,
                  kind: _liveKind(preset),
                  savedBody: _savedLive.overrides[preset.id],
                  environment: DemoEnvironment.live,
                ),
                onTap: () => _runLive(context, preset, _liveBody(preset)),
                onOpenInBrowser: () => _runLive(
                  context,
                  preset,
                  _liveBody(preset),
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
                onTap: () => _run(context, preset, _saved.bodyFor(preset)),
                onOpenInBrowser: () => _run(
                  context,
                  preset,
                  _saved.bodyFor(preset),
                  surface: PaymentSurface.webCheckout,
                ),
              ),
          if (!live)
            for (final saved in _saved.custom) _customTile(context, saved),
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
