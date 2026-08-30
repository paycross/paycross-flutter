import 'package:flutter/material.dart';

import 'editor.dart';
import 'history_screen.dart';
import 'minter.dart';
import 'presets.dart';
import 'run.dart';
import 'secrets.dart';
import 'settings.dart';
import 'test_cards_screen.dart';

/// Reads the stored credentials and pushes a run, or pushes Settings.
///
/// Top-level, and the only path to a run: the preset tiles call it and so
/// does the deep link, so "not configured routes to Settings" is written
/// once and cannot be true of one entry point and false of the other.
///
/// A null **or failed** read means "not configured". Routing to Settings is
/// what a colleague can act on; minting anyway would fail later with an
/// HTTP 401 that reads as a backend problem.
Future<void> runPreset(
  BuildContext context,
  Preset preset,
  String body, {
  SecretStore store = const SecretStore(),
}) async {
  final credentials = await store.read();
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
        mintSession: (body) {
          final minter = Minter(credentials: credentials);
          return minter.mint(body).whenComplete(minter.close);
        },
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

/// Where an ordinary build lands: pick a scenario, run it.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, this.store = const SecretStore()});

  final SecretStore store;

  Future<void> _run(BuildContext context, Preset preset, String body) =>
      runPreset(context, preset, body, store: store);

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('PayCross Demo'),
      actions: [
        IconButton(
          icon: const Icon(Icons.credit_card),
          tooltip: 'Test cards',
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const TestCardsScreen()),
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
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          child: Text(
            'Sandbox only. This build talks to the PayCross TEST '
            'environment and has no way to reach production.',
          ),
        ),
        ActiveProfileStrip(store: store),
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
              onTap: () => _run(context, preset, preset.body),
            ),
          ),
        // The way in for a scenario nobody wrote a preset for. It opens the
        // same editor the pencils do, on the ordinary body.
        Card(
          child: ListTile(
            key: const ValueKey('customPreset'),
            leading: const Icon(Icons.tune),
            title: const Text('Custom'),
            subtitle: const Text('Edit a session body by hand and run it.'),
            onTap: () => Navigator.of(context).push(
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
