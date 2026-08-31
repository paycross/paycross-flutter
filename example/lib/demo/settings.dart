import 'package:flutter/material.dart';

import 'endpoints.dart';
import 'environment.dart';
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
  final _liveConfirm = TextEditingController();
  bool _revealSecret = false;
  bool _busy = false;

  /// True from the moment Live is chosen until it is either confirmed or
  /// abandoned. It is not the environment -- the environment lives in
  /// [DemoEnvironmentState] and only the typed word moves it.
  bool _askingForLive = false;

  /// Whether the app is in Live, as far as this screen has moved it.
  ///
  /// A mirror of the environment, not a snapshot of it at load time, and the
  /// distinction is the whole point: `SecretStore.read` is three sequential
  /// platform-channel round-trips, so a load started in Test can easily land
  /// after the human has crossed into Live. Guarding on where the load began
  /// would refill a Live screen from the Keychain, and one tap on Use for
  /// this session would then send the sandbox pair to the production
  /// merchant. Every path that moves the environment maintains this:
  /// [initState] seeds it, [_enterLive] sets it, [_chooseEnvironment] clears
  /// it. Guards the prefill and nothing else. See [_load].
  bool _inLive = false;

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
    // `readOf`, not `maybeOf`: `initState` is outside build, where
    // registering an inherited dependency is an error. The environment
    // cannot change between here and the load anyway -- this screen is what
    // changes it.
    _inLive = LiveModeScope.readOf(context)?.isLive ?? false;
    _load();
  }

  @override
  void dispose() {
    _clientId.dispose();
    _clientSecret.dispose();
    _googlePay.dispose();
    _liveConfirm.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final stored = await widget.store.read();
    if (!mounted) return;
    setState(() {
      _stored = stored;
      // Read, but not shown. A screen pushed from Live -- by the tile with
      // no credentials, or by the profile strip -- would otherwise arrive
      // with the sandbox client id and secret already in its fields, one tap
      // from being sent to the production merchant. `_stored` is still set,
      // so the screen still knows what the next Test launch will use.
      if (stored != null && !_inLive) {
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
    setState(() {
      _busy = true;
      _message = null;
    });
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
      _busy = false;
      _stored = nowStored;
      _message = said;
    });
  }

  Future<void> _forget() async {
    setState(() {
      _busy = true;
      _message = null;
    });
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
      _busy = false;
      _stored = null;
      _message = said;
    });
  }

  /// What a tap on the switch does, which is never the switch itself.
  ///
  /// Choosing Live opens the gate. Choosing Test walks straight back through
  /// it, dropping the Live credentials on the way -- the ceremony is on the
  /// way in, because that is the direction that costs money.
  Future<void> _chooseEnvironment(
    DemoEnvironmentState state,
    DemoEnvironment chosen,
  ) async {
    // The handler, not just the widget. `onSelectionChanged: _busy ? null`
    // and `onPressed: _busy ? null` only take effect on the NEXT build, so
    // two taps inside one frame both arrive here. The second would get
    // `switchAlreadyInProgress` back, render it for a switch that has not
    // failed, and set `_busy` back to false underneath the first -- reopening
    // the toggle while the SDK call is still in flight.
    if (_busy) return;
    if (chosen == DemoEnvironment.live) {
      setState(() {
        _askingForLive = true;
        _message = null;
      });
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    final refused = await state.leaveLive();
    if (!mounted) return;
    _forgetTypedCredentials();
    setState(() {
      _busy = false;
      _askingForLive = false;
      // With it, not just beside it: this screen cannot be in Live with the
      // gate open, but a second surface driving the same state can flip to
      // Live and back, which hides the gate and shows it again. A word left
      // in the field across that round trip is a red button armed the moment
      // it reappears.
      _liveConfirm.clear();
      _message = refused;
      // Cleared before the reload below, or the prefill guard would keep
      // this screen's fields empty for the rest of its life. Only on
      // success: a refused exit is still in Live.
      if (refused == null) _inLive = false;
    });
    // Only once back in Test is there a store to read: the fields fill again
    // from the sandbox credentials the human saved, which are the ones the
    // next Test run will use.
    if (refused == null) await _load();
  }

  Future<void> _enterLive(DemoEnvironmentState state) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    final refused = await state.enterLive(_liveConfirm.text);
    if (!mounted) return;
    // Emptied only when the switch actually happened: what was in these
    // fields is a sandbox credential, and in Live it must not be one
    // keystroke away from being sent to production. A refused switch left
    // the app in Test, where that credential still belongs.
    if (refused == null) {
      // Before the clear, and this is the half that makes the sentence above
      // stay true past the next await: a store read started in Test can land
      // after this line, and it fills any empty field it finds.
      _inLive = true;
      _forgetTypedCredentials();
    }
    setState(() {
      _busy = false;
      _askingForLive = refused != null;
      _message = refused;
      _liveConfirm.clear();
    });
  }

  /// Closes the gate without switching, forgetting what was typed into it.
  ///
  /// The word is cleared rather than left for next time, and that is the
  /// whole value of the button: a gate that reopens with [liveConfirmationWord]
  /// already in it is a red button armed on arrival.
  void _abandonTheGate() {
    setState(() {
      _askingForLive = false;
      _liveConfirm.clear();
      _message = null;
    });
  }

  /// Empties the three credential fields without touching any store.
  ///
  /// Crossing between environments in either direction: a sandbox credential
  /// left on screen in Live is one Save away from the wrong place, and a
  /// production credential left on screen in Test is one Save away from a
  /// worse one.
  void _forgetTypedCredentials() {
    _clientId.clear();
    _clientSecret.clear();
    _googlePay.clear();
    // The reveal goes with them. It is a decision the human took about a
    // sandbox secret, in a room they judged safe for one; inheriting it puts
    // the next environment's secret on screen in plaintext without anybody
    // choosing that.
    _revealSecret = false;
    _stored = null;
  }

  /// Holds what is typed for this session, in memory, and says so.
  ///
  /// The Live counterpart of Save, and deliberately not called one: nothing
  /// is saved. There is no Verify beside it because the €1.00 smoke is the
  /// verification -- a Live probe would create a real production session as
  /// a side effect of checking a password.
  void _useForThisSession(DemoEnvironmentState state) {
    final typed = _typed;
    final unusable = _whyUnusable(typed);
    if (unusable != null) {
      setState(() => _message = unusable);
      return;
    }
    state.useForThisSession(typed);
    setState(
      () => _message =
          'Held for this session. Nothing is saved — closing the app, or '
          'switching back to Test, forgets it.',
    );
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
  Widget build(BuildContext context) {
    final state = LiveModeScope.maybeOf(context);
    final live = state?.isLive ?? false;
    // Named once and read twice, by the gate's button and by the hint that
    // explains it, so the reason given and the reason applied cannot drift.
    final armed = _liveConfirm.text.trim() == liveConfirmationWord;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // Absent in a tree with no scope, which is what the automation
          // build and every widget test written before Live mode gets: there
          // is nothing to toggle there, so the screen stays exactly what it
          // was.
          if (state != null) ...[
            SegmentedButton<DemoEnvironment>(
              key: const ValueKey('environmentToggle'),
              segments: const [
                ButtonSegment(
                  value: DemoEnvironment.test,
                  label: Text('Test'),
                  icon: Icon(Icons.science_outlined),
                ),
                ButtonSegment(
                  value: DemoEnvironment.live,
                  label: Text('Live'),
                  icon: Icon(Icons.warning_amber_rounded),
                ),
              ],
              selected: {state.environment},
              onSelectionChanged: _busy
                  ? null
                  : (chosen) => _chooseEnvironment(state, chosen.single),
            ),
            const SizedBox(height: 16),
            if (_askingForLive && !live) ...[
              Text(
                'Live is the PayCross production environment. A payment there '
                'charges a real card, and this app has no way to refund one. '
                'Type $liveConfirmationWord to switch.',
                key: const ValueKey('liveGateWarning'),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('liveConfirm'),
                controller: _liveConfirm,
                autocorrect: false,
                enableSuggestions: false,
                textCapitalization: TextCapitalization.characters,
                // The button wakes on the keystroke that completes the word,
                // rather than on a submit nobody would think to press.
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'Type $liveConfirmationWord',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  // The reason travels with the button. Sighted, the
                  // instruction is a paragraph three rows up and obviously
                  // related; to a screen reader it is two nodes back, so a
                  // dimmed button with nothing attached is a dead end. The
                  // Test branch keeps "Reading saved credentials…" inside the
                  // Wrap beside the buttons it explains for the same reason.
                  // Empty once the button is live: a hint that outlives the
                  // condition it describes is noise on every later swipe.
                  // Merged, so the hint lands on the button's own node rather
                  // than on a parent one a screen reader reaches separately.
                  MergeSemantics(
                    child: Semantics(
                      hint: armed
                          ? ''
                          : 'Type $liveConfirmationWord in the field above to '
                                'enable this.',
                      child: FilledButton(
                        key: const ValueKey('switchToLive'),
                        style: FilledButton.styleFrom(backgroundColor: liveRed),
                        onPressed: _busy || !armed
                            ? null
                            : () => _enterLive(state),
                        child: const Text('Switch to Live'),
                      ),
                    ),
                  ),
                  // Without this the gate is a dead end: the environment is
                  // still Test, so Test is the selected segment, and a
                  // SegmentedButton makes tapping the selected one a no-op.
                  // Nothing is at risk while it is open, but a screen whose
                  // job is to be unambiguous should not have a corner with no
                  // way out of it.
                  TextButton(
                    key: const ValueKey('cancelLive'),
                    onPressed: _busy ? null : _abandonTheGate,
                    child: const Text('Cancel'),
                  ),
                ],
              ),
              const SizedBox(height: 20),
            ],
          ],
          // Names the environment it is configuring and the host it will
          // reach, in both directions. The shipped line promised there was no
          // production switch; there is one now, immediately above this, and
          // a promise left standing after it stopped being true is worse than
          // no promise at all.
          Text(
            live
                ? 'Live — ${liveEndpoints.sessionsUrl}. These must be '
                      'PRODUCTION credentials. They are held in memory for '
                      'this session only, nothing is saved, and a payment '
                      'here charges a real card that this app cannot refund.'
                : 'Test — ${testEndpoints.sessionsUrl}. Sandbox credentials, '
                      'saved in the platform secure store. The switch above '
                      'is how this build reaches production; it starts in '
                      'Test on every launch.',
            key: const ValueKey('settingsEnvironment'),
          ),
          const SizedBox(height: 20),
          TextField(
            key: const ValueKey('clientId'),
            controller: _clientId,
            autocorrect: false,
            enableSuggestions: false,
            // In Live only, and only while there is something to retract:
            // "Held for this session" describes a pair that has just stopped
            // being what is on screen. Silence is the honest state -- the
            // human presses the button again when they are ready, and the
            // pair actually held is never changed behind their back.
            onChanged: live && _message != null
                ? (_) => setState(() => _message = null)
                : null,
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
            // In Live only, and only while there is something to retract:
            // "Held for this session" describes a pair that has just stopped
            // being what is on screen. Silence is the honest state -- the
            // human presses the button again when they are ready, and the
            // pair actually held is never changed behind their back.
            onChanged: live && _message != null
                ? (_) => setState(() => _message = null)
                : null,
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
          // Test only: there is no Google Pay tile in Live for a wallet id to
          // serve, and the id is configuration for one wallet on one
          // merchant.
          if (!live) ...[
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('googlePayMerchantId'),
              controller: _googlePay,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Google Pay merchant id (Android, optional)',
                helperText:
                    'Read at launch — restart the app after changing it.',
                helperMaxLines: 2,
                border: OutlineInputBorder(),
              ),
            ),
          ],
          const SizedBox(height: 20),
          if (live)
            // Not gated on `_loaded`, unlike the three below it: there is no
            // store read to wait for in Live, and a button dead until a
            // Keychain answers would be a button dead for a reason that does
            // not apply.
            FilledButton(
              key: const ValueKey('useForThisSession'),
              onPressed: _busy ? null : () => _useForThisSession(state!),
              child: const Text('Use for this session'),
            )
          else
            Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
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
                // Beside the buttons rather than above the fields, because it is
                // the buttons being dead that needs explaining: three empty
                // fields under three grey buttons is what a broken build looks
                // like, and a cold Keychain read takes a visible moment on a
                // real phone. Gone the moment the read lands, whatever it found.
                if (!_loaded) const Text('Reading saved credentials…'),
              ],
            ),
          if (_message != null) ...[
            const SizedBox(height: 20),
            Semantics(
              liveRegion: true,
              child: Text(_message!, key: const ValueKey('settingsMessage')),
            ),
          ],
          const SizedBox(height: 32),
          VersionPanel(readVersions: widget.readVersions),
        ],
      ),
    );
  }
}
