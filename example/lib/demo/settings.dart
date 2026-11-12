import 'package:flutter/material.dart';
import 'package:paycross_flutter/paycross_flutter.dart';

import 'appearance_store.dart';
import 'endpoints.dart';
import 'environment.dart';
import 'language.dart';
import 'live.dart';
import 'minter.dart';
import 'secrets.dart';
import 'version_panel.dart';

typedef VerifyCredentials = Future<String> Function(Credentials credentials);

const String _liveInputsHint =
    'Fill in the client ID, the client secret, a first and last name, '
    'and an email address to enable this.';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    this.store = const SecretStore(),
    this.languageStore = const LanguageStore(),
    this.appearanceStore = const AppearanceStore(),
    this.verifyCredentials = mintThrowawaySession,
    this.readVersions = platformVersions,
  });

  final SecretStore store;

  final LanguageStore languageStore;

  final AppearanceStore appearanceStore;
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
  final _liveName = TextEditingController();
  final _liveEmail = TextEditingController();
  final _brandLight = TextEditingController();
  final _brandDark = TextEditingController();
  final _cornerRadius = TextEditingController();
  final _buttonCornerRadius = TextEditingController();
  final _fontScale = TextEditingController();

  bool _revealSecret = false;
  bool _busy = false;

  bool _askingForLive = false;

  bool _loaded = false;
  String? _message;

  Credentials? _stored;

  DemoLanguage _language = DemoLanguage.system;

  bool _languageLoaded = false;

  PayCrossThemeMode _themeMode = PayCrossThemeMode.system;

  bool _appearanceLoaded = false;

  @override
  void initState() {
    super.initState();
    _load();
    _loadLanguage();
    _loadAppearance();
  }

  @override
  void dispose() {
    _clientId.dispose();
    _clientSecret.dispose();
    _googlePay.dispose();
    _liveConfirm.dispose();
    _liveName.dispose();
    _liveEmail.dispose();
    _brandLight.dispose();
    _brandDark.dispose();
    _cornerRadius.dispose();
    _buttonCornerRadius.dispose();
    _fontScale.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final stored = await widget.store.read();
    if (!mounted) return;
    final live = LiveModeScope.readOf(context)?.isLive ?? false;
    setState(() {
      _stored = stored;
      if (stored != null && !live) {
        if (_clientId.text.isEmpty) _clientId.text = stored.clientId;
        if (_clientSecret.text.isEmpty) {
          _clientSecret.text = stored.clientSecret;
        }
        if (_googlePay.text.isEmpty) {
          _googlePay.text = stored.googlePayMerchantId ?? '';
        }
      }
      _loaded = true;
    });
  }

  Future<void> _loadLanguage() async {
    final language = await widget.languageStore.read();
    if (!mounted) return;
    setState(() {
      _language = language;
      _languageLoaded = true;
    });
  }

  Future<void> _chooseLanguage(DemoLanguage language) async {
    setState(() {
      _language = language;
      _message = null;
    });
    try {
      await widget.languageStore.write(language);
    } catch (problem) {
      if (!mounted) return;
      setState(
        () => _message =
            'Could not save the language: ${problem.runtimeType}. It applies '
            'to this session only.',
      );
    }
  }

  Future<void> _loadAppearance() async {
    final appearance = await widget.appearanceStore.read();
    if (!mounted) return;
    setState(() {
      _showAppearance(appearance);
      _appearanceLoaded = true;
    });
  }

  void _showAppearance(DemoAppearance appearance) {
    _brandLight.text = appearance.brandLight == null
        ? ''
        : hexOf(appearance.brandLight!);
    _brandDark.text = appearance.brandDark == null
        ? ''
        : hexOf(appearance.brandDark!);
    _themeMode = appearance.themeMode;
    _cornerRadius.text = _lengthText(appearance.cornerRadius);
    _buttonCornerRadius.text = _lengthText(appearance.buttonCornerRadius);
    _fontScale.text = _lengthText(appearance.fontScale);
  }

  DemoAppearance get _typedAppearance => DemoAppearance(
    brandLight: colorFromHex(_brandLight.text.trim()),
    brandDark: colorFromHex(_brandDark.text.trim()),
    themeMode: _themeMode,
    cornerRadius: _typedLength(_cornerRadius, isValidLength),
    buttonCornerRadius: _typedLength(_buttonCornerRadius, isValidLength),
    fontScale: _typedLength(_fontScale, isValidFontScale),
  );

  Future<void> _writeAppearance() async {
    setState(() => _message = null);
    try {
      await widget.appearanceStore.write(_typedAppearance);
    } catch (problem) {
      if (!mounted) return;
      setState(
        () => _message =
            'Could not save the appearance: ${problem.runtimeType}. It '
            'applies to this session only.',
      );
    }
  }

  Future<void> _chooseThemeMode(PayCrossThemeMode mode) async {
    setState(() => _themeMode = mode);
    await _writeAppearance();
  }

  Future<void> _loadThemedPreset() async {
    setState(() => _showAppearance(DemoAppearance.themedPreset));
    await _writeAppearance();
  }

  String? _whyUnusable(Credentials typed) =>
      typed.clientId.isEmpty || typed.clientSecret.isEmpty
      ? 'Enter both a client ID and a client secret first.'
      : null;

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

  LiveIdentity? get _typedIdentity =>
      LiveIdentity.parse(name: _liveName.text, email: _liveEmail.text);

  bool get _liveInputsComplete =>
      _whyUnusable(_typed) == null && _typedIdentity != null;

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

  Future<void> _chooseEnvironment(
    DemoEnvironmentState state,
    DemoEnvironment chosen,
  ) async {
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
    _forgetWhatWasTyped();
    setState(() {
      _busy = false;
      _askingForLive = false;
      _liveConfirm.clear();
      _message = refused;
    });
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
    if (refused == null) _forgetWhatWasTyped();
    setState(() {
      _busy = false;
      _askingForLive = refused != null;
      _message = refused;
      _liveConfirm.clear();
    });
  }

  void _abandonTheGate() {
    setState(() {
      _askingForLive = false;
      _liveConfirm.clear();
      _message = null;
    });
  }

  void _forgetWhatWasTyped() {
    _clientId.clear();
    _clientSecret.clear();
    _googlePay.clear();
    _liveName.clear();
    _liveEmail.clear();
    _revealSecret = false;
    _stored = null;
  }

  void _useForThisSession(DemoEnvironmentState state) {
    final identity = _typedIdentity;
    if (identity == null) return;
    state.useForThisSession(_typed);
    state.useIdentityForThisSession(identity);
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
      said = _matchesStored(typed)
          ? '$minted Verified.'
          : '$minted Verified — press Save to keep them.';
    } on MinterError catch (problem) {
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
    final armed = _liveConfirm.text.trim() == liveConfirmationWord;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
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
            onChanged: live ? (_) => setState(() => _message = null) : null,
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
            onChanged: live ? (_) => setState(() => _message = null) : null,
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
          if (live) ...[
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('liveName'),
              controller: _liveName,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.words,
              onChanged: (_) => setState(() => _message = null),
              decoration: InputDecoration(
                labelText: 'Name on the charge',
                helperText: 'First and last, split on the last space.',
                helperMaxLines: 2,
                errorText: _liveName.text.trim().isEmpty
                    ? null
                    : liveNameProblem(_liveName.text),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('liveEmail'),
              controller: _liveEmail,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.emailAddress,
              onChanged: (_) => setState(() => _message = null),
              decoration: InputDecoration(
                labelText: 'Email on the charge',
                helperText: 'A real internal address. It receives the receipt.',
                helperMaxLines: 2,
                errorText: _liveEmail.text.trim().isEmpty
                    ? null
                    : liveEmailProblem(_liveEmail.text),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              key: ValueKey('liveAmountNote'),
              'The amount and the currency belong to each Live tile. Open a '
              'tile with the pencil to change what it charges, and Save to '
              'keep it.',
            ),
          ],
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
            Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                MergeSemantics(
                  child: Semantics(
                    hint: _liveInputsComplete ? '' : _liveInputsHint,
                    child: FilledButton(
                      key: const ValueKey('useForThisSession'),
                      onPressed: _busy || !_liveInputsComplete
                          ? null
                          : () => _useForThisSession(state!),
                      child: const Text('Use for this session'),
                    ),
                  ),
                ),
                if (!_liveInputsComplete) const Text(_liveInputsHint),
              ],
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
          Semantics(
            header: true,
            child: const Text(
              'Payment sheet language',
              key: ValueKey('languageHeading'),
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 8),
          SegmentedButton<DemoLanguage>(
            key: const ValueKey('languageToggle'),
            segments: [
              for (final language in DemoLanguage.values)
                ButtonSegment(value: language, label: Text(language.label)),
            ],
            selected: {_language},
            onSelectionChanged: _busy || !_languageLoaded
                ? null
                : (chosen) => _chooseLanguage(chosen.single),
          ),
          const SizedBox(height: 8),
          if (!_languageLoaded)
            const Text(
              key: ValueKey('languageLoading'),
              'Reading the saved language…',
            ),
          const Text(
            key: ValueKey('languageNote'),
            'The language the native payment sheet draws in. System sets no '
            'override, which leaves the payment session\'s own locale to '
            'decide and the device after that. Read at launch — restart the '
            'app after changing it. This app\'s own screens stay in English '
            'either way.',
          ),
          const SizedBox(height: 32),
          Semantics(
            header: true,
            child: const Text(
              'Payment sheet appearance',
              key: ValueKey('appearanceHeading'),
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 8),
          Semantics(
            identifier: 'settings.appearance.brandLight',
            child: TextField(
              key: const ValueKey('brandLight'),
              controller: _brandLight,
              enabled: _appearanceLoaded,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (_) => _writeAppearance(),
              decoration: InputDecoration(
                labelText: 'Brand colour, light mode (hex)',
                helperText:
                    'The Pay button and the selection controls. Empty leaves '
                    'the colour set in the back office.',
                helperMaxLines: 2,
                errorText: _hexProblem(_brandLight),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Semantics(
            identifier: 'settings.appearance.brandDark',
            child: TextField(
              key: const ValueKey('brandDark'),
              controller: _brandDark,
              enabled: _appearanceLoaded,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (_) => _writeAppearance(),
              decoration: InputDecoration(
                labelText: 'Brand colour, dark mode (hex)',
                helperText:
                    'Its own colour rather than the light one dimmed: a brand '
                    'that reads on white is often unreadable on near-black.',
                helperMaxLines: 3,
                errorText: _hexProblem(_brandDark),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Semantics(
            identifier: 'settings.appearance.themeMode',
            child: SegmentedButton<PayCrossThemeMode>(
              key: const ValueKey('appearanceThemeMode'),
              segments: [
                for (final mode in PayCrossThemeMode.values)
                  ButtonSegment(value: mode, label: Text(themeModeLabel(mode))),
              ],
              selected: {_themeMode},
              onSelectionChanged: _busy || !_appearanceLoaded
                  ? null
                  : (chosen) => _chooseThemeMode(chosen.single),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            key: ValueKey('appearanceThemeModeNote'),
            'System follows the phone. Light and Dark pin the sheet, and only '
            'the sheet — this app\'s own screens follow the phone either way.',
          ),
          const SizedBox(height: 12),
          Semantics(
            identifier: 'settings.appearance.cornerRadius',
            child: TextField(
              key: const ValueKey('cornerRadius'),
              controller: _cornerRadius,
              enabled: _appearanceLoaded,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onChanged: (_) => _writeAppearance(),
              decoration: InputDecoration(
                labelText: 'Corner radius',
                helperText:
                    'The card inputs, the saved-card rows and the field '
                    'groups. Zero is a square corner; empty is the '
                    'platform\'s own.',
                helperMaxLines: 3,
                errorText: _numberProblem(
                  _cornerRadius,
                  isValidLength,
                  'Zero or more.',
                ),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Semantics(
            identifier: 'settings.appearance.buttonCornerRadius',
            child: TextField(
              key: const ValueKey('buttonCornerRadius'),
              controller: _buttonCornerRadius,
              enabled: _appearanceLoaded,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onChanged: (_) => _writeAppearance(),
              decoration: InputDecoration(
                labelText: 'Button corner radius',
                helperText:
                    'The Pay button and the wallet buttons. Empty falls back '
                    'to the corner radius above.',
                helperMaxLines: 2,
                errorText: _numberProblem(
                  _buttonCornerRadius,
                  isValidLength,
                  'Zero or more.',
                ),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Semantics(
            identifier: 'settings.appearance.fontScale',
            child: TextField(
              key: const ValueKey('fontScale'),
              controller: _fontScale,
              enabled: _appearanceLoaded,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onChanged: (_) => _writeAppearance(),
              decoration: InputDecoration(
                labelText: 'Font scale',
                helperText:
                    'Multiplies every size in the sheet, on top of the '
                    'phone\'s own text-size setting. Between $minFontScale '
                    'and $maxFontScale; empty leaves every size alone.',
                helperMaxLines: 3,
                errorText: _numberProblem(
                  _fontScale,
                  isValidFontScale,
                  'Between $minFontScale and $maxFontScale.',
                ),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Semantics(
            identifier: 'settings.appearance.preset',
            child: OutlinedButton(
              key: const ValueKey('appearancePreset'),
              onPressed: _busy || !_appearanceLoaded ? null : _loadThemedPreset,
              child: const Text('Load the themed preset'),
            ),
          ),
          const SizedBox(height: 8),
          if (!_appearanceLoaded)
            const Text(
              key: ValueKey('appearanceLoading'),
              'Reading the saved appearance…',
            ),
          const Text(
            key: ValueKey('appearanceNote'),
            'How the native payment sheet looks. Every field is optional and '
            'an empty one changes nothing: the colour the merchant set in the '
            'back office applies first, and the platform\'s own default after '
            'that. "Load the themed preset" fills these in with what the '
            'Themed sheet tile on Home runs, which you can then edit. Read at '
            'launch — restart the app after changing it.',
          ),
          const SizedBox(height: 32),
          VersionPanel(readVersions: widget.readVersions),
        ],
      ),
    );
  }
}

String _lengthText(double? value) {
  if (value == null) return '';
  return value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toString();
}

double? _typedLength(TextEditingController field, bool Function(double) valid) {
  final typed = double.tryParse(field.text.trim());
  return typed != null && valid(typed) ? typed : null;
}

String? _hexProblem(TextEditingController field) {
  final typed = field.text.trim();
  if (typed.isEmpty || colorFromHex(typed) != null) return null;
  return 'Six or eight hex digits, like 00875A.';
}

String? _numberProblem(
  TextEditingController field,
  bool Function(double) valid,
  String rule,
) {
  final typed = field.text.trim();
  if (typed.isEmpty) return null;
  final value = double.tryParse(typed);
  if (value == null) return 'Type a number.';
  return valid(value) ? null : rule;
}

String themeModeLabel(PayCrossThemeMode mode) => switch (mode) {
  PayCrossThemeMode.system => 'System',
  PayCrossThemeMode.light => 'Light',
  PayCrossThemeMode.dark => 'Dark',
};
