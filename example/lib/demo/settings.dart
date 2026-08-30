import 'package:flutter/material.dart';

import 'endpoints.dart';
import 'minter.dart';
import 'secrets.dart';
import 'version_panel.dart';

/// Mints a throwaway session to prove the credentials work, and returns a
/// line to show the human. Injected so the widget tests never mint.
///
/// This is the only end-to-end check of `endpoints.dart` there is: a host
/// that does not resolve surfaces here, on the first person's phone, as a
/// message they can read and report.
typedef VerifyCredentials = Future<String> Function(Credentials credentials);

/// The real check: one session, minted and immediately abandoned.
///
/// Each tap mints a new session rather than replaying the last one -- the
/// minter generates a fresh `Idempotency-Key` per call -- so tapping twice
/// leaves two abandoned sandbox sessions and proves the credentials twice.
Future<String> mintThrowawaySession(Credentials credentials) async {
  final minter = Minter(credentials: credentials);
  try {
    final minted = await minter.mint(
      '{"amount":100,"currency":"EUR","transaction_type":"sale",'
      '"merchant_reference":"DEMO-VERIFY-{{timestamp}}",'
      '"return_url":"https://merchant.example.com/payment/return",'
      '"success_url":"https://merchant.example.com/payment/success"}',
    );
    return 'Minted session ${minted.id}.';
  } finally {
    // This minter owns its http client -- nothing was injected -- so the
    // socket stays open until somebody closes it.
    minter.close();
  }
}

/// Where the credentials are entered, checked and forgotten.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    this.store = const SecretStore(),
    this.verifyCredentials = mintThrowawaySession,
    this.readVersions = platformVersions,
  });

  final SecretStore store;
  final VerifyCredentials verifyCredentials;
  final Future<DemoVersions> Function() readVersions;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _clientId = TextEditingController();
  final _clientSecret = TextEditingController();
  final _googlePay = TextEditingController();
  bool _revealSecret = false;
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _clientId.dispose();
    _clientSecret.dispose();
    _googlePay.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final stored = await widget.store.read();
    if (!mounted || stored == null) return;
    setState(() {
      _clientId.text = stored.clientId;
      _clientSecret.text = stored.clientSecret;
      _googlePay.text = stored.googlePayMerchantId ?? '';
    });
  }

  Credentials get _typed => Credentials(
    clientId: _clientId.text.trim(),
    clientSecret: _clientSecret.text.trim(),
    googlePayMerchantId: _googlePay.text.trim().isEmpty
        ? null
        : _googlePay.text.trim(),
  );

  Future<void> _save() async {
    await widget.store.write(_typed);
    if (!mounted) return;
    setState(() => _message = 'Saved.');
  }

  Future<void> _forget() async {
    await widget.store.forget();
    if (!mounted) return;
    _clientId.clear();
    _clientSecret.clear();
    _googlePay.clear();
    setState(() => _message = 'Forgotten.');
  }

  Future<void> _verify() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    String said;
    try {
      said = await widget.verifyCredentials(_typed);
    } on MinterError catch (problem) {
      // MinterError never carries a credential -- see minter.dart's
      // _safeToEcho -- so this is safe to put on screen verbatim.
      said = problem.message;
    } catch (problem) {
      said = 'Could not reach the sandbox: ${problem.runtimeType}';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = said;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          'Sandbox only — $sessionsUrl. There is no production switch, and '
          'these credentials must be TEST credentials.',
        ),
        const SizedBox(height: 20),
        TextField(
          key: const ValueKey('clientId'),
          controller: _clientId,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(
            labelText: 'Client ID',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('clientSecret'),
          controller: _clientSecret,
          obscureText: !_revealSecret,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: 'Client secret',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              key: const ValueKey('revealSecret'),
              icon: Icon(
                _revealSecret ? Icons.visibility_off : Icons.visibility,
              ),
              onPressed: () => setState(() => _revealSecret = !_revealSecret),
              tooltip: _revealSecret ? 'Hide secret' : 'Reveal secret',
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('googlePayMerchantId'),
          controller: _googlePay,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(
            labelText: 'Google Pay merchant id (Android, optional)',
            helperText: 'Read at launch — restart the app after changing it.',
            helperMaxLines: 2,
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton(
              onPressed: _busy ? null : _save,
              child: const Text('Save'),
            ),
            OutlinedButton(
              onPressed: _busy ? null : _verify,
              child: const Text('Verify credentials'),
            ),
            TextButton(
              onPressed: _busy ? null : _forget,
              child: const Text('Forget credentials'),
            ),
          ],
        ),
        if (_message != null) ...[
          const SizedBox(height: 20),
          Text(_message!, key: const ValueKey('settingsMessage')),
        ],
        const SizedBox(height: 32),
        VersionPanel(readVersions: widget.readVersions),
      ],
    ),
  );
}
