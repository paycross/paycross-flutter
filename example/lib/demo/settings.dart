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

  /// Whether the first read has come back, whatever it found.
  ///
  /// Every button is dead until it has. Before that the fields are empty
  /// because nothing has been read yet, not because nothing is stored, and
  /// a Save on that emptiness would write it straight over a good
  /// credential -- silently, since an empty pair reads back as "not
  /// configured" and looks exactly like a store that was never set up.
  bool _loaded = false;
  String? _message;

  /// What the store is believed to hold, so "Verify credentials" can say
  /// whether what was just proven is also what the next launch will use.
  ///
  /// After a write or a delete that threw, this goes back to null rather than
  /// staying as it was: `SecretStore.write` and `forget` touch three keys in
  /// turn, so a failure part-way leaves a store this screen can no longer
  /// describe -- and null is both the honest answer and the one a guarded
  /// read will most likely give, since it needs the id and the secret to
  /// return anything at all.
  Credentials? _stored;

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
    if (!mounted) return;
    setState(() {
      _stored = stored;
      if (stored != null) {
        // Only what is still empty: a slow Keychain that answers after the
        // human started typing must not pull the text out from under them.
        if (_clientId.text.isEmpty) _clientId.text = stored.clientId;
        if (_clientSecret.text.isEmpty) {
          _clientSecret.text = stored.clientSecret;
        }
        if (_googlePay.text.isEmpty) {
          _googlePay.text = stored.googlePayMerchantId ?? '';
        }
      }
      // Set on the empty path too -- a store with nothing in it is the
      // first-run case, and leaving the screen dead there would make a fresh
      // install impossible to configure.
      _loaded = true;
    });
  }

  /// Why what is typed cannot be used yet, or null if it can.
  ///
  /// Both halves or neither. An empty pair does not fail early on its own:
  /// the minter would send Basic auth over a bare colon and the token
  /// endpoint would answer 401, which reads as "these credentials are wrong"
  /// rather than "you have not entered any".
  String? _whyUnusable(Credentials typed) =>
      typed.clientId.isEmpty || typed.clientSecret.isEmpty
      ? 'Enter both a client ID and a client secret first.'
      : null;

  /// Whether what is on screen is what the store holds.
  ///
  /// Nothing stored counts as a difference: there is something to save. The
  /// merchant id is compared too even though minting does not use it, because
  /// an unsaved change to it is lost just as quietly as an unsaved secret.
  bool _matchesStored(Credentials typed) {
    final stored = _stored;
    return stored != null &&
        stored.clientId == typed.clientId &&
        stored.clientSecret == typed.clientSecret &&
        stored.googlePayMerchantId == typed.googlePayMerchantId;
  }

  Credentials get _typed => Credentials(
    clientId: _clientId.text.trim(),
    clientSecret: _clientSecret.text.trim(),
    googlePayMerchantId: _googlePay.text.trim().isEmpty
        ? null
        : _googlePay.text.trim(),
  );

  Future<void> _save() async {
    final typed = _typed;
    final unusable = _whyUnusable(typed);
    if (unusable != null) {
      setState(() => _message = unusable);
      return;
    }
    String said;
    Credentials? nowStored;
    try {
      await widget.store.write(typed);
      nowStored = typed;
      said = 'Saved.';
    } catch (problem) {
      // Only the type: the thing that failed to be written is a credential,
      // and a store's exception is free to quote what it was handed.
      said = 'Could not save: ${problem.runtimeType}';
    }
    if (!mounted) return;
    setState(() {
      _stored = nowStored;
      _message = said;
    });
  }

  Future<void> _forget() async {
    String said;
    var forgotten = false;
    try {
      await widget.store.forget();
      forgotten = true;
      said = 'Forgotten.';
    } catch (problem) {
      said = 'Could not forget: ${problem.runtimeType}';
    }
    if (!mounted) return;
    // Only on success: emptying the fields after a delete that threw would
    // tell the human the credentials are gone while they are still there.
    if (forgotten) {
      _clientId.clear();
      _clientSecret.clear();
      _googlePay.clear();
    }
    setState(() {
      _stored = null;
      _message = said;
    });
  }

  Future<void> _verify() async {
    final typed = _typed;
    final unusable = _whyUnusable(typed);
    if (unusable != null) {
      setState(() => _message = unusable);
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    String said;
    try {
      final minted = await widget.verifyCredentials(typed);
      // Verify mints with what is on screen, not with what is stored, and
      // deliberately does not save -- the mint is a throwaway. So a human who
      // edits a field, verifies and walks away has proven a credential the
      // next launch will not use. This line is the only thing that says so.
      said = _matchesStored(typed)
          ? '$minted Verified.'
          : '$minted Verified — press Save to keep them.';
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
              onPressed: _busy || !_loaded ? null : _save,
              child: const Text('Save'),
            ),
            OutlinedButton(
              onPressed: _busy || !_loaded ? null : _verify,
              child: const Text('Verify credentials'),
            ),
            TextButton(
              onPressed: _busy || !_loaded ? null : _forget,
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
