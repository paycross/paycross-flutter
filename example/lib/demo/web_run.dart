import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'environment.dart';
import 'history.dart';
import 'minter.dart';
import 'presets.dart';
import 'surface.dart';
import 'version_panel.dart';

/// How long the two bookkeeping steps after a launch get before the screen
/// stops waiting on them.
///
/// The same deadline `run.dart` puts on the same two steps, and for the same
/// reason: a platform store with nothing behind it never answers rather than
/// failing, and without this the "Copy bug report" button would simply never
/// appear.
const Duration _bookkeepingTimeout = Duration(seconds: 5);

/// What History records for a session the browser opened.
///
/// Deliberately a description of what the *app* did, not of what happened to
/// the money. The app hands the page to the browser and stops watching; it
/// has no idea whether the shopper paid, gave up or closed the tab. A row
/// that said "approved" would be a guess written down as a fact, in the one
/// place somebody goes to find out what happened.
const String webOpenedOutcome = 'Opened in web checkout';

/// What History records for a session the browser would not take.
const String webLaunchFailedOutcome = 'Could not open the web checkout';

/// What the screen says when the mint came back with no page to open.
///
/// A closed session, or a backend older than the field. Neither is worth
/// telling apart here: there is nothing to open either way, and the sheet is
/// one Settings change away.
const String noCheckoutUrlMessage = 'This session has no web checkout URL.';

/// Hands a URL to whatever browser the phone has.
///
/// `externalApplication` rather than the default: an in-app web view would
/// put the page back inside this app, which is the one thing this surface
/// exists not to do -- the wallets are approved for the browser, and a
/// wallet sheet in a web view is a different test with a different answer.
typedef LaunchCheckout = Future<bool> Function(Uri url);

/// The real one. Injected everywhere else so no test reaches a platform
/// channel.
Future<bool> openInBrowser(Uri url) =>
    launchUrl(url, mode: LaunchMode.externalApplication);

/// The checkout page as a URL, or null if there is not one to open.
///
/// Absent, null, empty, unparseable and not-web all collapse to null, and
/// the screen refuses the same way for every one of them. The scheme check
/// is the load-bearing part: `launchUrl` with `externalApplication` hands
/// whatever it is given to the platform, so a non-web scheme arriving in a
/// response field would be this app opening an arbitrary application on
/// somebody's phone. The merchant API builds an `https` URL; anything else
/// is a backend that has changed under us, and refusing is the honest answer.
///
/// Public so a test can exercise the rule without a screen. It never returns
/// the URL to anything that renders or stores -- the caller hands it to the
/// browser and drops it.
Uri? checkoutUri(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  final uri = Uri.tryParse(raw);
  // A host rather than merely an authority. `https:///pay` parses, and it
  // has an authority -- an empty one -- so an authority check alone lets a
  // hostless string through to the platform as though it were a page.
  if (uri == null || uri.host.isEmpty) return null;
  return uri.scheme == 'https' || uri.scheme == 'http' ? uri : null;
}

/// Mint, hand the session to the browser, say what is now true.
///
/// A screen of its own rather than a branch inside [RunScreen], and that is
/// the whole design. The sheet's run screen reports a payment: it has a
/// contract label the matrix runner reads, a transaction id, and an outcome
/// the SDK told it. This one has none of those and must not look as though
/// it does -- the app hands over a URL and stops knowing anything. Two
/// screens cannot drift into describing each other's outcome; one screen
/// with a flag in it eventually does.
///
/// It carries no automation label, by construction rather than by rule. The
/// matrix runner drives the deep link, the deep link never selects this
/// surface, and a screen with no label cannot pass a cell it never reached.
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

  /// What is actually minted -- the preset's body, or the editor's edit of
  /// it. Byte for byte what the sheet's run screen would have sent, which is
  /// what makes a web run and a sheet run comparable.
  final String body;

  /// Mints [body]. Takes it as an argument rather than closing over it, so
  /// the screen and its minter cannot disagree about what is being sent.
  final Future<MintedSession> Function(String body) mintSession;

  final LaunchCheckout launch;
  final HistoryStore history;
  final Future<DemoVersions> Function() readVersions;

  /// Whether this run charges a real card. Passed in at push time rather
  /// than read from the scope, for the reason `run.dart` gives: a run that
  /// started in Live stays a Live run in what it shows and what it writes.
  final bool live;

  @override
  State<WebCheckoutRunScreen> createState() => _WebCheckoutRunScreenState();
}

/// How far a web run got. What the screen renders, and what decides whether
/// the red block asks for a refund or for a look.
enum _Stage {
  /// Still minting, or still handing the URL over.
  working,

  /// The mint itself refused. There is no session and nothing to record.
  mintFailed,

  /// A session exists and there is no page to open it at.
  noPage,

  /// A session exists, there is a page, and the browser would not take it.
  launchFailed,

  /// The browser has the page. What happens next is not this app's to know.
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
      // MinterError never carries a credential; see minter.dart. Nothing is
      // written to History: no session was created, so there is no id for
      // anybody to look up and nothing that could have taken money.
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
      // The same clean refusal the mint failure above gets, and no History
      // row for the same reason: a session with no checkout page is a
      // session that is not open, so nothing can be paid against it and
      // there is nothing for anybody to go and refund. The id is still shown
      // -- it costs nothing and it is the only handle on what was created.
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
      // The one place the URL is used, and it goes straight to the platform.
      // It is `…/pay?session=<token>`, so it is the session token spelled
      // out: it is never put on screen, never written to History and never
      // quoted in a message from this file.
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
      // A plugin that is not registered on this build throws rather than
      // answering false, and unhandled it would leave this screen on
      // "Opening the browser…" for good. The type only, never the message: a
      // platform exception is free to quote the URL it was handed, and that
      // URL is a credential.
      stage = _Stage.launchFailed;
      outcome = webLaunchFailedOutcome;
      human =
          'The browser could not be opened: ${problem.runtimeType}. Nothing '
          'was paid.';
    }

    if (!mounted) return;
    // What is now true, before anything is asked of a store or a channel.
    // The same order `run.dart` uses, and for the same reason: a person may
    // already be paying in the browser, and that fact must not wait on
    // bookkeeping nor be lost to a store that never answers.
    setState(() {
      _stage = stage;
      _heading = stage == _Stage.opened ? 'Handed over.' : 'Not opened.';
      _human = human;
    });

    final versions = await _versionsOrUnknown();
    final entry = HistoryEntry(
      at: DateTime.now(),
      presetName: widget.preset.name,
      sessionId: minted.id,
      // There is not one, and there will not be one: a transaction is
      // created by the payment, and the payment is happening somewhere this
      // app cannot see. Recorded as absent rather than invented.
      transactionId: null,
      outcome: outcome,
      demoVersion: versions.demo,
      pluginVersion: versions.plugin,
      nativeSdkVersion: versions.nativeSdk,
      live: widget.live,
      surface: webSurfaceName,
    );
    await _remember(entry);

    if (!mounted) return;
    setState(() => _entry = entry);
  }

  /// Writes the run to History, and never lets that failure lose the screen.
  ///
  /// A payment may already be under way in the browser by the time this
  /// runs. A store that cannot be written costs a missing row; letting it
  /// throw would cost the session id, which is the only thing anybody has to
  /// find that payment by.
  Future<void> _remember(HistoryEntry entry) async {
    try {
      await widget.history.append(entry).timeout(_bookkeepingTimeout);
    } catch (_) {
      // Nothing to say on screen: the entry is held in memory either way, so
      // the card and its bug report render unchanged.
    }
  }

  Future<DemoVersions> _versionsOrUnknown() async {
    try {
      return await widget.readVersions().timeout(_bookkeepingTimeout);
    } catch (_) {
      return unknownVersions;
    }
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
            // A live region, like the sheet's run screen and Settings'
            // message line: the browser launch lands in place, nothing moves
            // focus, and there is nothing to navigate to. Without this a
            // screen-reader user is never told the hand-over happened.
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
                        // The one thing a tester needs off this screen, and
                        // the reason it is a button: the id is what the back
                        // office is searched by, it is long, and it is the
                        // only handle on a payment happening in another app.
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

  /// The red block, which asks for two different things.
  ///
  /// There is no transaction id here and there never will be, so unlike the
  /// sheet's version this one is always searched by the session id.
  ///
  /// What it asks depends on whether the page was actually handed over. A
  /// run that never opened a browser cannot have charged anything, and "go
  /// and refund this" on one would be noise on the commonest way this
  /// surface fails. A run that did open one is the opposite case: the app
  /// does not know whether money moved, and *not knowing* is exactly when
  /// somebody has to go and look.
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
