import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'environment.dart';
import 'history.dart';
import 'minter.dart';
import 'present.dart';
import 'presets.dart';
import 'surface.dart';
import 'version_panel.dart';

const String webOpenedOutcome = 'Opened in web checkout';

const String webLaunchFailedOutcome = 'Could not open the web checkout';

const String noCheckoutUrlMessage = 'This session has no web checkout URL.';

typedef LaunchCheckout = Future<bool> Function(Uri url);

Future<bool> openInBrowser(Uri url) =>
    launchUrl(url, mode: LaunchMode.externalApplication);

Uri? checkoutUri(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  final uri = Uri.tryParse(raw);
  if (uri == null || uri.host.isEmpty) return null;
  return uri.scheme == 'https' || uri.scheme == 'http' ? uri : null;
}

class WebCheckoutRunScreen extends StatefulWidget {
  const WebCheckoutRunScreen({
    super.key,
    required this.preset,
    required this.body,
    required this.mintSession,
    this.launch = openInBrowser,
    this.history = const HistoryStore(),
    this.readVersions = platformVersions,
    this.live = false,
  });

  final Preset preset;

  final String body;

  final Future<MintedSession> Function(String body) mintSession;

  final LaunchCheckout launch;
  final HistoryStore history;
  final Future<DemoVersions> Function() readVersions;

  final bool live;

  @override
  State<WebCheckoutRunScreen> createState() => _WebCheckoutRunScreenState();
}

enum _Stage {
  working,

  mintFailed,

  noPage,

  launchFailed,

  opened,
}

class _WebCheckoutRunScreenState extends State<WebCheckoutRunScreen> {
  _Stage _stage = _Stage.working;
  String _heading = 'Minting a session…';
  String? _human;
  String? _sessionId;
  HistoryEntry? _entry;

  @override
  void initState() {
    super.initState();
    _go();
  }

  Future<void> _go() async {
    final MintedSession minted;
    try {
      minted = await widget.mintSession(widget.body);
    } on MinterError catch (problem) {
      if (mounted) {
        setState(() {
          _stage = _Stage.mintFailed;
          _heading = 'Could not mint a session.';
          _human = problem.message;
        });
      }
      return;
    }

    if (!mounted) return;
    setState(() {
      _heading = 'Opening the browser…';
      _sessionId = minted.id;
    });

    final url = checkoutUri(minted.checkoutUrl);
    if (url == null) {
      if (mounted) {
        setState(() {
          _stage = _Stage.noPage;
          _heading = 'Nothing to open.';
          _human =
              '$noCheckoutUrlMessage The session was created, but the API '
              'offered no hosted page for it — a session that is not open '
              'has none. Switch back to the SDK sheet in Settings to run '
              'this scenario.';
        });
      }
      return;
    }

    String human;
    _Stage stage;
    String outcome;
    try {
      final opened = await widget.launch(url);
      if (opened) {
        stage = _Stage.opened;
        outcome = webOpenedOutcome;
        human =
            'Opened in the browser. Finish the payment there; the result '
            'lands in the back office under this session id. This app does '
            'not learn what happened — nothing on this screen means the '
            'payment was approved.';
      } else {
        stage = _Stage.launchFailed;
        outcome = webLaunchFailedOutcome;
        human =
            'The phone would not open a browser for this session. Nothing '
            'was paid. Check that a browser is installed, or switch back to '
            'the SDK sheet in Settings.';
      }
    } catch (problem) {
      stage = _Stage.launchFailed;
      outcome = webLaunchFailedOutcome;
      human =
          'The browser could not be opened: ${problem.runtimeType}. Nothing '
          'was paid.';
    }

    if (!mounted) return;
    setState(() {
      _stage = stage;
      _heading = stage == _Stage.opened ? 'Handed over.' : 'Not opened.';
      _human = human;
    });

    final entry = await recordRun(
      history: widget.history,
      readVersions: widget.readVersions,
      scenario: widget.preset.name,
      sessionId: minted.id,
      transactionId: null,
      outcome: outcome,
      live: widget.live,
      surface: webSurfaceName,
    );

    if (!mounted) return;
    setState(() => _entry = entry);
  }

  Future<void> _copy(String text, String said) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(said)));
  }

  @override
  Widget build(BuildContext context) {
    final human = _human;
    final sessionId = _sessionId;
    return Scaffold(
      appBar: AppBar(title: Text(widget.preset.name)),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(_heading, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          if (human != null)
            Semantics(
              key: const ValueKey('webRunOutcome'),
              liveRegion: true,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(human, style: const TextStyle(height: 1.4)),
                      const SizedBox(height: 12),
                      Text('Session ${sessionId ?? '(none)'}'),
                      if (sessionId != null) ...[
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          key: const ValueKey('copySessionId'),
                          icon: const Icon(Icons.copy, size: 18),
                          label: const Text('Copy session id'),
                          onPressed: () =>
                              _copy(sessionId, 'Session id copied.'),
                        ),
                      ],
                      if (widget.live && sessionId != null) ...[
                        const SizedBox(height: 12),
                        _refundBlock(sessionId),
                      ],
                      if (_entry != null) ...[
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          key: const ValueKey('copyBugReport'),
                          icon: const Icon(Icons.copy, size: 18),
                          label: const Text('Copy bug report'),
                          onPressed: () => _copy(bugReport(_entry!), 'Copied.'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          const SizedBox(height: 16),
          Text('Expected: ${widget.preset.expected}'),
          if (widget.preset.cardHint != null) ...[
            const SizedBox(height: 8),
            Text('Card: ${widget.preset.cardHint}'),
          ],
        ],
      ),
    );
  }

  Widget _refundBlock(String sessionId) => Container(
    key: const ValueKey('refundInstruction'),
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: liveRed,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _stage == _Stage.opened
              ? 'This app cannot see what the browser did. Find this session '
                    'in the back office and refund anything it captured.'
              : 'Nothing was opened, so nothing should have been charged. '
                    'Check the back office by this id before you assume it.',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'No transaction id — search the back office by this session id.\n'
          'Session $sessionId',
          style: const TextStyle(color: Colors.white),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const ValueKey('copyRefundId'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white,
            side: const BorderSide(color: Colors.white),
          ),
          icon: const Icon(Icons.copy, size: 18),
          label: const Text('Copy id'),
          onPressed: () => _copy(sessionId, 'Copied.'),
        ),
      ],
    ),
  );
}
