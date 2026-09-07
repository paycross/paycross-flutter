"""Drives the example app on the simulator, from WSL, entirely over ssh.

Ports the campaign's wda.py and the three shell scripts beside it. The logic
lives here rather than on the Mac for two reasons: the Mac's system Python is
3.9, and the Mac has no GitHub credentials, so anything kept there has to be
shipped by tar and can drift from what is committed.

Every device interaction is one `ssh mac` round trip -- ~55 ms with the
configured ControlMaster, which is comfortable for a 1 Hz poll. Nothing on the
Mac runs under sudo, and the only path written there is REMOTE_DIR.

Three things shape everything here:

* An ssh session gets launchd's minimal PATH, so every remote command re-exports
  DEVELOPER_DIR and PATH or xcrun, curl and flutter are simply missing.
* WebDriverAgent reports a failure as HTTP 4xx with a JSON body, which `curl -s`
  prints and `json.loads` accepts. Unchecked, a failed tap is silent.
* The SDK emits no os_log, so the crash markers criterion 3 looks for reach the
  app's stdout and stderr and nowhere else. They are captured by launching
  through `simctl launch --console-pty` into a log file on the Mac. That log is
  truncated by each `launch()` and the capture is a process that outlives the
  app, which puts two obligations on a runner: **collect a cell's logs before
  the next launch**, and call `close()` when the run ends.
"""

from __future__ import annotations

import base64
import binascii
import json
import re
import shlex
import subprocess
import time
from collections.abc import Callable
from datetime import datetime, timezone
from pathlib import Path
from xml.etree import ElementTree as ET

from .. import tree
from ..cells import Card
from .base import Driver, DriverError, device_text, read_token, rig_path

#: The ssh alias for the Mac, overridable with PAYCROSS_E2E_SSH_HOST.
SSH_HOST = rig_path("PAYCROSS_E2E_SSH_HOST", "mac")
UDID = "C311AFDC-25FA-44A2-A800-10EB5A1039E3"
BUNDLE = "com.paycross.flutterdemo"
WDA = "http://127.0.0.1:8100"

#: An ssh session gets launchd's minimal PATH, so every remote command sets
#: these up front or xcrun, curl and flutter are all simply missing. The
#: prefixes are this Mac's; PAYCROSS_E2E_MAC_ENV replaces the whole preamble,
#: and an override must keep the trailing `; ` because it is concatenated
#: directly onto the command.
MAC_ENV = rig_path(
    "PAYCROSS_E2E_MAC_ENV",
    "export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer "
    "PATH=/opt/homebrew/bin:$HOME/development/flutter/bin:$PATH; ",
)

#: Longer than the ceiling every curl below carries, so a WDA call that times
#: out is reported by curl rather than by a killed ssh. Thirty seconds for the
#: curl itself: a `/source` that has not answered by then is not going to, and
#: every second of it is spent on top of a poll's deadline rather than inside
#: it.
SSH_TIMEOUT_SECONDS = 900
WDA_TIMEOUT_SECONDS = 30

#: The only directory this driver writes to on the Mac. `$HOME` is left for
#: the remote shell to expand, as MAC_ENV's PATH already is. The session token
#: is deliberately not among the things written here -- it goes to `pbcopy` on
#: ssh's stdin and never reaches the Mac's disk.
REMOTE_DIR = "$HOME/work/e2e/ios/run"
CONSOLE_LOG = f"{REMOTE_DIR}/console.log"
REMOTE_SHOT = f"{REMOTE_DIR}/shot.png"

#: Separates the base64 frame from whatever simctl said on stderr, in the one
#: answer that carries both. None of its characters are in the base64 alphabet,
#: so it can never appear inside a frame. The two cannot simply be merged:
#: simctl writes "Note: No display specified..." to stderr on success too.
SHOT_STDERR = "[simctl-stderr]"

#: Separates the console log's current size from the window read out of it.
#: The size is asked for rather than inferred from the window, because `tail`'s
#: own complaints are sent back too -- and "No such file or directory" is text,
#: so a window that looked non-empty would otherwise pass for app output.
CONSOLE_SIZE = "[console-size]"

#: The identifiers the SDK publishes, from 0.7.0. They are set in every build
#: -- an iOS `accessibilityIdentifier` is not surfaced to VoiceOver or to other
#: apps, so there is nothing to gate -- and WDA reports one as a node's `name`.
#: Android publishes the same strings as resource ids, so these names are the
#: cross-platform contract rather than this file's shorthand.
#:
#: They all gained the `paycross.` prefix in Train 4. What went with the switch
#: is every matcher that read a rendered STRING: the sheet draws French when
#: the session says so, and a driver written against English copy would have
#: passed on an English rig and failed on nobody's machine but the shopper's.
CARDHOLDER = "paycross.cardholderName"
CARD_NUMBER = "paycross.cardNumber"
EXPIRY = "paycross.expiry"
CVV = "paycross.cvv"
PAY_BUTTON = "paycross.payButton"
#: The sheet's own container, and -- on 0.7.0 -- the Pay button as well.
#:
#: `PaymentSheet.swift:923` puts `.payCrossIdentifier(.sheet)` on the `Group`
#: wrapping `CardFormView`. The Pay button is the pinned footer, a direct child
#: of that group rather than of the `ScrollView` inside it, so SwiftUI's outer
#: identifier overrides the `.payButton` set on the button itself
#: (`CardFormView.swift:453`). Everything inside the ScrollView keeps its own
#: name, because the ScrollView is an element carrying `.sheet` and propagation
#: stops there.
#:
#: Measured on the simulator 2026-09-07 -- `paycross.payButton` is not in the
#: tree at all, and `paycross.sheet` is on two elements. See `_pay_button`.
SHEET = "paycross.sheet"
#: Never interactive -- also the neutral target for the keyboard-dismissal
#: fallback. Its label carries a `Total, ` caption ahead of the amount.
AMOUNT = "paycross.amount"
#: The save-card `Toggle` (CardFormView.swift:119). Rendered only under
#: `allowsSaving && state.source.isNewCard`, and measured 2026-08-31 to sit at
#: y=840 on an 874-tall screen with `visible="false"` even before any keyboard
#: is up -- so it has to be scrolled to, where Android's checkbox does not.
SAVE_CARD = "paycross.saveCard"

#: The stored-card list and its rows. A row is `paycross.savedCard.<uuid>` and
#: its bin is that plus `.delete`, so the prefix finds a row the driver has not
#: read the session to learn the uuid of -- and the suffix is what keeps the
#: bin out of the answer.
#:
#: These rows used to be matched on the four U+2022 BULLETs in their rendered
#: label, because `SavedCardPicker` set no identifier on anything. That was the
#: accessibility gap D5 filed; 0.7.0 closed it.
SAVED_CARDS = "paycross.savedCards"
SAVED_CARD_PREFIX = "paycross.savedCard."
SAVED_CARD_DELETE_SUFFIX = ".delete"

THREE_DS_CANCEL = "paycross.threeDSCancel"
#: The sheet's own Cancel. iOS-only: Android has no close control and is
#: cancelled with the system back gesture.
SHEET_CANCEL = "paycross.cancel"

#: The two SDK-drawn confirmations and their buttons. Drawn in the sheet rather
#: than raised as `.alert`s, and that is what lets them carry identifiers at
#: all: SwiftUI does not forward a button's identifier onto the `UIAlertAction`
#: it builds, measured nil on iOS 26.5 for both actions and for the alert's
#: whole view tree.
CANCEL_DIALOG = "paycross.cancelDialog"
CANCEL_CONFIRM = "paycross.cancelConfirm"
CANCEL_DISMISS = "paycross.cancelDismiss"
REMOVE_DIALOG = "paycross.removeDialog"
REMOVE_CONFIRM = "paycross.removeConfirm"

PASTE_ITEM = "Paste"
TOKEN_FIELD = "Session token"
EXAMPLE_PAY = "Pay"

#: What the seed scripts waited after a tap, an entry or a cold start. Kept as
#: named values because the unit tests assert them rather than spend them: the
#: rig's timing stays pinned without the suite sleeping through it.
SETTLE_SECONDS = 0.5
PASTE_SETTLE_SECONDS = 1.5
LAUNCH_SETTLE_SECONDS = 6
SCROLL_SETTLE_SECONDS = 1.0
#: Between the keystrokes of a card field, and only there. `/wda/keys` takes
#: the whole string in one request and the SDK's formatter reflows the field
#: after every character it accepts -- inserting the expiry's `/`, which moves
#: the caret. Sent flat out, the expiry came back reading `12/2` from `1228`:
#: one character delivered into a field that was being rewritten underneath it.
#: The Android driver paces its digits for the same reason and calls it
#: DIGIT_PACING_SECONDS.
KEY_PACING_SECONDS = 0.15
ALERT_SETTLE_SECONDS = 1
POLL_INTERVAL_SECONDS = 1

#: How long the window server is given after a home-screen press, a
#: re-activation or a rotation. This rig's own numbers: the Android driver's
#: are three seconds, and a simulator settles faster than an emulator. Copying
#: one onto the other would hide which of them was measured.
BACKGROUND_SETTLE_SECONDS = 2
ROTATE_SETTLE_SECONDS = 2

#: How long the pasted field is given to show that it took anything at all.
TOKEN_READBACK_SECONDS = 10

#: How long the example's own screen and then the sheet are each given to come
#: up. Named rather than inline because the tests reach past them.
SCREEN_TIMEOUT_SECONDS = 60

#: The widest `log show --last <n>s` window this driver will ask for.
#:
#: The window is anchored to `launch()`, so it normally tracks the cell's own
#: duration -- measured across a D2 run it ranged from 10 s to 1313 s. What it
#: has no bound on is the HOST CLOCK JUMPING: one D2 cell straddled a WSL
#: sleep and asked simctl for `--last 35354s`, 9.8 hours.
#:
#: The harm is asking for the window at all, not what comes back. A sleeping
#: simulator logs almost nothing -- that cell's `logs.txt` came to 2.0 MB,
#: SMALLER than an ordinary cell's 4.8 MB -- so the earlier "hours of log in
#: one file" reading was measured and is false. What is true is that a
#: 9.8-hour `log show` is slow and fragile to ask of simctl however little it
#: returns.
#:
#: An hour, because it has to clear the longest cell the matrix can legitimately
#: run and stop well short of a clock jump: the widest per-cell budget is
#: `session_expired_server`'s ~3026 s, so an hour is above every real cell with
#: room to spare. Capping bounds the unified log ONLY. The console half is a
#: byte offset from this launch and is never capped, because `relaunch()`
#: deliberately keeps that mark so a cell that relaunches halfway keeps its own
#: criterion-3 evidence.
LOG_WINDOW_CAP_SECONDS = 3600

#: How long the previous cell's console capture is given to die, polled on the
#: Mac so it costs one round trip rather than one per look.
_CONSOLE_STOP_TRIES = 25
_CONSOLE_STOP_INTERVAL = 0.2

#: How many times a `/source` body is re-fetched before the driver calls
#: WebDriverAgent unusable, and how long it waits between attempts.
_DUMP_ATTEMPTS = 3
_DUMP_RETRY_SECONDS = 1

#: The sheet is 402x874; the ACS page is taller. A drag from three quarters
#: down to just under a third of the way up moves it by about half a screen.
#:
#: `_DRAG_FROM` is now a ceiling rather than the origin -- see `_drag_origin`
#: for what a pan that starts on a text field does, which is nothing.
_DRAG_FROM = 0.75
_DRAG_TO = 0.30
_DRAG_DURATION = 0.4
_MAX_SWIPES = 12

#: A drag that starts above this is not worth taking: it would move the sheet
#: by less than a fifth of a screen and burn one of the twelve swipes doing it.
_DRAG_FLOOR = 0.35

#: How much of an unexpected answer is quoted back. A `/source` body holds the
#: example's token field, so the excerpt is deliberately short and always a
#: prefix -- a truncated read loses its tail, never its head.
_EXCERPT = 200

#: `xcrun simctl list devices` puts the state last: `iPhone 17 (UDID) (Booted)`.
_DEVICE_STATE = re.compile(r"\(([^()]+)\)\s*$")


def _is_pay_button(node: tree.Node) -> bool:
    """The Pay button, by its own name where the SDK publishes one.

    On PayCross 0.7.0 it does not: the button answers to `paycross.sheet`, for
    the reason written at that constant. So the second branch takes the one
    element that can only be the Pay button -- a `Button` carrying the sheet's
    identifier, which the sheet's own container, a `ScrollView`, is not.

    Temporary, and it removes itself: the moment the SDK sets
    `paycross.payButton` on that button the first branch matches and the second
    is never reached. It is here because without it no iOS cell runs at all --
    `paste_token`, `tap_pay` and `dismiss_cancel` all need this element.
    """
    if node.identifier == PAY_BUTTON:
        return True
    return node.identifier == SHEET and node.type == "Button"


def _is_token_field(node: tree.Node) -> bool:
    """The example's token field, in both shapes its accessible name takes.

    Unfocused, and once it holds anything, the name is just "Session token"
    and the content is in `value`. Focused and still empty it is
    "Session token\neyJhbGciOi…": Flutter merges an empty field's hint into
    its semantics label, and the example's hint is a sample JWT prefix
    (example/lib/main.dart:124). That is exactly the state the long press has
    to be aimed from, so an exact match finds nothing at the one moment it is
    asked to -- measured on the rig 2026-08-29 against Flutter 3.47.0 and
    iOS 26.5, where it failed the first live paste.

    A prefix rather than either literal, so the hint can be reworded without
    this following it. Untagged, so `name` is WDA's fallback to the label.
    """
    name = node.identifier or node.content_desc
    return name == TOKEN_FIELD or name.startswith(TOKEN_FIELD + "\n")


def _ssh(command: str, *, stdin: bytes | None = None) -> str:
    """One remote command, bounded, never discarding a failure.

    A non-zero exit has its stderr appended rather than raised: `terminate` is
    expected to fail when nothing is running, and `grep` exits 1 when it
    matches nothing. The callers that care read this text and say what they
    saw. Discarding it is how "no route to host" would read as an empty log,
    and an empty log is how criterion 3 passes on nothing.

    `stdin` is the channel the session token travels on. A command line is
    world-readable for as long as the process lives, on both machines.

    A Mac that has gone to sleep raises TimeoutExpired rather than exiting
    non-zero, and a missing ssh raises FileNotFoundError. Neither is a
    DriverError, so both escape every polling loop above and end the whole
    matrix where they should have failed one cell.
    """
    what = (command.removeprefix(MAC_ENV).split() or ["ssh"])[0]
    try:
        done = subprocess.run(
            ["ssh", SSH_HOST, command],
            capture_output=True,
            timeout=SSH_TIMEOUT_SECONDS,
            input=stdin,
        )
    except subprocess.TimeoutExpired as exc:
        raise DriverError(
            f"{SSH_HOST} did not answer {what!r} within {SSH_TIMEOUT_SECONDS}s"
        ) from exc
    except OSError as exc:
        raise DriverError(f"could not run ssh for {what!r}: {exc}") from exc
    out = device_text(done.stdout)
    if done.returncode != 0:
        out += device_text(done.stderr)
    return out


class IosDriver(Driver):
    #: WebDriverAgent's `/source` on this side of the fence; base._nodes
    #: calls it.
    _parse_dump = staticmethod(tree.parse_wda)

    def __init__(
        self, ssh=_ssh, udid: str = UDID, bundle: str = BUNDLE, sleep=time.sleep
    ):
        # `bundle`, not BUNDLE: a driver constructed against another build
        # scopes its crash markers to that one.
        super().__init__(package=bundle, sleep=sleep)
        self._ssh = ssh
        self._udid = udid
        #: Every interpolation into a remote command goes through this. A udid
        #: is a constructor argument, not a constant, once the runner grows a
        #: --udid flag.
        self._quoted_udid = shlex.quote(udid)
        self._bundle = bundle
        self._session_id: str | None = None
        self._window: tuple[int, int] | None = None
        #: Where the console log stood at this cell's launch. None until then,
        #: because reading from byte 0 would hand a previous cell's output to
        #: crash_lines and fail every later cell in the matrix.
        self._console_from: int | None = None
        self._console_pid: int | None = None

    # -- transport -----------------------------------------------------------

    def _remote(self, command: str, *, stdin: bytes | None = None) -> str:
        return self._ssh(MAC_ENV + command, stdin=stdin)

    def _wda(self, method: str, path: str, body: dict | None = None) -> dict:
        """One WebDriverAgent call, made by curl on the Mac.

        The body is piped in rather than passed as an argument: it is the same
        channel the token would travel on if it ever needed to, and keeping one
        shape means there is no second, less careful path.
        """
        url = WDA + path
        if body is None:
            command = f"curl -s -m {WDA_TIMEOUT_SECONDS} -X {method} {shlex.quote(url)}"
        else:
            payload = json.dumps(body)
            command = (
                f"printf %s {shlex.quote(payload)} | curl -s -m {WDA_TIMEOUT_SECONDS} "
                f"-X {method} -H 'Content-Type: application/json' "
                f"--data-binary @- {shlex.quote(url)}"
            )
        raw = self._remote(command)
        if not raw.strip():
            raise DriverError(f"WebDriverAgent returned nothing for {method} {path}")
        try:
            parsed = json.loads(raw)
        except json.JSONDecodeError as exc:
            # curl's own failures arrive as a sentence. json.loads answers those
            # with a JSONDecodeError, which is not a DriverError and so escapes
            # every polling loop in this file.
            raise DriverError(
                f"WebDriverAgent's answer to {method} {path} was not JSON: "
                f"{raw.strip()[:_EXCERPT]!r}"
            ) from exc
        if not isinstance(parsed, dict):
            raise DriverError(
                f"WebDriverAgent's answer to {method} {path} was not an envelope: "
                f"{raw.strip()[:_EXCERPT]!r}"
            )
        # WDA reports a failure as HTTP 4xx with a JSON body -- `curl -s` prints
        # it and json.loads accepts it -- so without this check a failed tap,
        # keys, drag or keyboard dismissal is completely silent, and the damage
        # surfaces one caller later as a KeyError in _window_size or an
        # AttributeError in dump_tree. Neither is a DriverError, which is how a
        # single bad cell would take a 40-minute matrix down with it.
        value = parsed.get("value")
        if isinstance(value, dict) and "error" in value:
            # Truncated on purpose: the envelope's traceback is ~10 KB (10,842
            # characters when measured) and would otherwise land in `problems`
            # and in every result.json.
            raise DriverError(
                f"{method} {path}: {value['error']} - "
                f"{str(value.get('message', ''))[:_EXCERPT]}"
            )
        return parsed

    def _session(self, path: str) -> str:
        if self._session_id is None:
            raise DriverError("no WebDriverAgent session; call launch() first")
        return f"/session/{self._session_id}{path}"

    # -- lifecycle -----------------------------------------------------------

    def _close_open_session(self) -> None:
        """Closes whatever session WebDriverAgent already has open.

        A session bound to a bundleId terminates its app under test when a new
        session displaces it, and on this rig the app it terminates is the
        instance `launch()` started one step later -- taking the --console-pty
        capture with it and failing the cell in `_check_console`. Measured
        2026-08-29: it is what the first live iOS run died of, twice, and it
        survives across runs because the stale session outlives the process
        that opened it.

        Called before the capture exists, so the termination it provokes is
        spent on an app nobody is watching. WebDriverAgent reports the open
        session at the top level of /status, and null when there is none.

        Whatever it reports is what gets deleted -- this does not check that
        the session is one of ours, because WebDriverAgent has exactly one and
        a foreign session would break this run just as thoroughly. That makes
        one run per WebDriverAgent the standing rule, the same way one run per
        emulator is on Android.

        Either way no session is open when this returns, so the id held from
        the previous cell is dropped rather than left to name something that
        no longer exists.
        """
        open_session = self._wda("GET", "/status").get("sessionId")
        if open_session:
            self._wda("DELETE", f"/session/{open_session}")
        self._session_id = None

    def install(self, app_path: str) -> None:
        """`app_path` is a path **on the Mac**: the .app is built there."""
        self._remote(
            f"xcrun simctl uninstall {self._quoted_udid} {self._bundle} "
            "2>/dev/null || true"
        )
        out = self._remote(
            f"xcrun simctl install {self._quoted_udid} {shlex.quote(app_path)} 2>&1"
        )
        if out.strip():
            # simctl install says nothing at all when it works, so anything at
            # all is quoted back rather than matched against a catalogue of its
            # wording.
            raise DriverError(
                f"simctl install said {out.strip()[:400]!r}; it says nothing when "
                "it succeeds"
            )

    def _device_state(self) -> str:
        """`Booted`, or whatever simctl called it -- and never a guess.

        An unknown UDID makes grep exit 1 with nothing on stdout. Reading that
        as a state would report a simulator part-way through booting when the
        truth is that there is no such simulator, which is the Android boot
        check's lesson transposed.
        """
        said = self._remote(
            f"xcrun simctl list devices | grep -F -- {self._quoted_udid}"
        ).strip()
        if not said:
            raise DriverError(
                f"simctl list devices names no simulator {self._udid}: the udid is "
                "wrong or its runtime is gone"
            )
        found = _DEVICE_STATE.search(said)
        if not found:
            raise DriverError(f"simctl reported no state for {self._udid}: {said!r}")
        return found.group(1)

    def _stop_console(self) -> None:
        """Kills the previous cell's capture and waits for it to be gone.

        Two of them interleave into one log, and the older one still owns the
        app it launched -- so the terminate below would be taking the app out
        from under a capture that is still writing. The wait is done on the
        Mac so it costs one round trip rather than one per look.
        """
        if self._console_pid is None:
            return
        pid = self._console_pid
        self._console_pid = None
        said = self._remote(
            f"kill {pid} 2>/dev/null; n=0; "
            f"while kill -0 {pid} 2>/dev/null && "
            f"[ $n -lt {_CONSOLE_STOP_TRIES} ]; "
            f"do sleep {_CONSOLE_STOP_INTERVAL}; n=$((n+1)); done; "
            f"kill -0 {pid} 2>/dev/null && echo alive || echo gone"
        ).strip()
        if said != "gone":
            raise DriverError(
                f"the previous console capture (pid {pid}) is still running "
                f"after {_CONSOLE_STOP_TRIES * _CONSOLE_STOP_INTERVAL:.0f}s; two "
                "of them would interleave into one log"
            )

    def _start_console(self, *, truncate: bool = True) -> int | None:
        """Launches the app with its console captured, and returns the log mark.

        The SDK emits no os_log, so `log show` never sees the markers criterion
        3 looks for -- Swift's `Fatal error:`, ObjC's `*** Terminating app due
        to uncaught exception`, Dart's `Unhandled Exception:`. They reach the
        app's stdout and stderr, which is what `--console-pty` copies. A pty
        rather than `--stdout=`/`--stderr=` because NSLog writes to stderr when
        stderr is a terminal, and a plain file is not one.

        `--console-pty` blocks for the app's whole lifetime, so it is
        backgrounded.

        The log is truncated first, so a 40-minute matrix cannot grow one
        without bound -- see `launch()` for the contract that rests on. The
        byte length is still read afterwards and used as the offset, so a
        truncation that did not take is a smaller window rather than a previous
        cell's output.

        `truncate=False` is a relaunch mid-cell: the log keeps what this cell
        has already written and the existing mark stands, because honouring
        the new one would start the cell's window halfway through itself.
        """
        said = self._remote(
            f"mkdir -p {REMOTE_DIR} && "
            + (f": > {CONSOLE_LOG} && " if truncate else "")
            + f"wc -c < {CONSOLE_LOG} && "
            f"( nohup xcrun simctl launch --console-pty {self._quoted_udid} "
            f"{self._bundle} "
            f">> {CONSOLE_LOG} 2>&1 < /dev/null & echo $! )"
        )
        fields = said.split()
        if len(fields) != 2 or not all(f.isdigit() for f in fields):
            raise DriverError(
                f"could not start the console capture: {said.strip()[:400]!r}"
            )
        mark, self._console_pid = int(fields[0]), int(fields[1])
        return mark if truncate else self._console_from

    def _check_console(self) -> None:
        """Asserts the console capture outlived the session request.

        A POST /session naming a bundleId makes WDA terminate-then-launch that
        app, which takes the capture with it; `launch()` therefore names none.
        This is what proves that held -- and it is not theoretical: the first
        live iOS run, with a bundleId and `forceAppLaunch: false`, failed here
        on every cell. Without the check a silently dead capture leaves
        `logs_since` with nothing to scan, and "nothing crashed" passes on an
        empty window.
        """
        if self._console_pid is None:
            return
        said = self._remote(
            f"kill -0 {self._console_pid} 2>/dev/null && echo alive || echo dead"
        ).strip()
        if said != "alive":
            # The log is named, never quoted: whatever the app printed is
            # redacted on its way into evidence, and this message is not on
            # that path.
            raise DriverError(
                "the app's console capture is not running, so a crash would go "
                f"unseen; simctl launch --console-pty exited, see {CONSOLE_LOG} "
                f"on {SSH_HOST}"
            )

    def close(self) -> None:
        """Ends this run on the Mac: the console capture, then the session.

        launch() clears the *previous* cell's capture, so without this the last
        one of a run outlives it: a simctl still holding the app, and a log
        still being written to. Task 9 calls this in a `finally`.

        The session goes too, so the next run does not inherit one -- see
        `_close_open_session` for what an inherited one costs. The `finally`
        is why: a capture that will not die must not strand a session as well.
        Idempotent, and safe before launch.
        """
        try:
            self._stop_console()
        finally:
            session_id, self._session_id = self._session_id, None
            if session_id:
                self._wda("DELETE", f"/session/{session_id}")

    def launch(self, *, truncate_console: bool = True) -> None:
        """Cold-starts the example app with its console captured.

        **Contract with the runner: a cell's logs are collected before the next
        launch.** The console log is truncated here so a 40-minute matrix
        cannot grow one without bound, which is also the moment the previous
        cell's console stops being readable. `logs_since` is therefore called
        once per cell, before the next `launch()`, and `close()` at the end of
        the run.

        `truncate_console=False` is `relaunch()`, which is a cold start *in
        the middle of* a cell: the window it has already written is its own
        evidence and is kept.
        """
        # Before anything that can fail. The log is truncated by
        # _start_console and by nothing else, so a launch that gives up ahead
        # of it would leave the previous cell's window in place and readable,
        # and logs_since would hand that back as this cell's -- failing this
        # cell for the last one's crash, and the interleaved control after it.
        # A relaunch keeps the mark for exactly the mirrored reason: that
        # window belongs to the cell now running.
        if truncate_console:
            self._console_from = None
        state = self._device_state()
        if state != "Booted":
            raise DriverError(f"simulator {self._udid} is {state!r}, not booted")
        # No locale guard. This refused anything but English, because the Pay
        # button and the re-arm banner were matched as English strings. Both
        # are identifiers now, and a simulator drawing French is a case this
        # rig has to be able to MEASURE rather than refuse. What the guard was
        # really protecting -- a re-arm that reads as a miss because the amount
        # is spelled another way -- is diagnosed in `wait_rearmed` instead,
        # where it can name the amount the sheet was actually showing.
        # Before the terminate: the old capture still owns the app.
        self._stop_console()
        # Before the capture is started, so the termination a stale bundle-bound
        # session provokes lands on an app nobody is capturing.
        self._close_open_session()
        self._remote(
            f"xcrun simctl terminate {self._quoted_udid} {self._bundle} "
            "2>/dev/null || true"
        )
        self._console_from = self._start_console(truncate=truncate_console)
        self._sleep(LAUNCH_SETTLE_SECONDS)

        raw = self._wda(
            "POST",
            "/session",
            {
                "capabilities": {
                    "alwaysMatch": {
                        # No bundleId, deliberately. WDA treats one as "launch
                        # this", and for XCUIApplication launching means
                        # terminate-then-launch, which takes the --console-pty
                        # capture of the instance started just above with it.
                        # `forceAppLaunch: false` is a literal in the 16.2.2
                        # binary but does not stop it -- measured on the rig
                        # 2026-08-29, where it failed every cell in
                        # _check_console. A session naming no bundle launches
                        # nothing and attaches to whatever is foreground, and
                        # everything asked of a session here is coordinate- or
                        # device-level (tap, drag, keys, keyboard/dismiss,
                        # window/size) while /source is unscoped, so nothing
                        # needs the binding.
                        #
                        # The Flutter engine never fully quiesces, so waiting
                        # for it times every session request out.
                        "shouldWaitForQuiescence": False,
                    }
                }
            },
        )
        value = raw.get("value") or {}
        session_id = raw.get("sessionId") or (
            value.get("sessionId") if isinstance(value, dict) else None
        )
        if not session_id:
            raise DriverError(
                f"WebDriverAgent gave no sessionId: {json.dumps(raw)[:300]}"
            )
        self._session_id = session_id
        # A new session can mean a new window; the cached size is not carried.
        self._window = None
        self._check_console()
        # Last, because /orientation needs the session. A cell that rotated and
        # did not rotate back leaves the simulator turned, and every cell after
        # it looks for buttons that are off screen -- measured on the D3 probe,
        # where the interleaved control failed with "no element named
        # 'payButton' within 60s", which reads as an SDK finding and is a rig
        # fault. `cell_rules` refuses a cell with an odd number of turns; this
        # catches the cell that died between two of them, where the runner's
        # teardown replay cannot help because `rotate` has no on/off pair.
        pose = self._wda("GET", self._session("/orientation")).get("value")
        if pose not in (None, "PORTRAIT"):
            raise DriverError(
                f"the simulator is not upright: WebDriverAgent reports {pose!r}, "
                "so a previous cell rotated and did not rotate back. Every cell "
                "after it looks for buttons that are off screen"
            )

    def relaunch(self) -> None:
        self.launch(truncate_console=False)

    # -- finding and tapping -------------------------------------------------

    def _window_size(self) -> tuple[int, int]:
        if self._window is None:
            value = self._wda("GET", self._session("/window/size")).get("value") or {}
            try:
                self._window = (int(value["width"]), int(value["height"]))
            except (KeyError, TypeError, ValueError) as exc:
                raise DriverError(
                    "WebDriverAgent gave no window size: "
                    f"{json.dumps(value)[:_EXCERPT]}"
                ) from exc
        return self._window

    def _on_screen(self, node: tree.Node) -> bool:
        """Visible *and* inside the window.

        Both halves are needed. WebKit keeps the whole ACS page addressable, so
        a node can be in the tree at y=1402 on an 874pt sheet; tapping its
        centre then lands on whatever is really at those pixels -- the keyboard,
        or nothing.
        """
        width, height = self._window_size()
        x, y = node.centre
        return node.visible and 0 <= x <= width and 0 <= y <= height

    def _matches_in(
        self,
        nodes: list[tree.Node],
        name: str,
        identifier_only: bool,
        match: Callable[[tree.Node], bool] | None = None,
    ) -> list[tree.Node]:
        def by_name(node):
            if node.identifier == name:
                return True
            return not identifier_only and node.content_desc == name

        chosen = match or by_name
        return [n for n in nodes if chosen(n)]

    def _matches(self, name: str, *, identifier_only: bool = False) -> list[tree.Node]:
        return self._matches_in(self._nodes(), name, identifier_only)

    def _pick(
        self,
        nodes: list[tree.Node],
        name: str,
        identifier_only: bool,
        require_on_screen: bool,
        match: Callable[[tree.Node], bool] | None = None,
    ) -> tree.Node | None:
        """The best match in one tree: on screen if there is one."""
        hits = self._matches_in(nodes, name, identifier_only, match)
        if not hits:
            return None
        for node in hits:
            if self._on_screen(node):
                return node
        # Nothing matched on screen, which only means anything while WDA is
        # reporting visibility at all. If nothing in the whole source carries
        # it, the on-screen preference is inert: every fallback tap lands at
        # raw coordinates and scroll_to burns all twelve swipes before blaming
        # the button. Checked before `require_on_screen` answers, so both
        # callers see the rig fault rather than a plausible wrong diagnosis.
        if not any(n.visible for n in nodes):
            raise DriverError(
                "no node in the whole source is marked visible, so nothing can "
                "be found on screen; WebDriverAgent is not reporting visibility "
                f"(looking for {name!r})"
            )
        if require_on_screen:
            return None
        return hits[0]

    def _find(
        self,
        name: str,
        *,
        timeout: float = 30,
        interval: float = POLL_INTERVAL_SECONDS,
        identifier_only: bool = False,
        require_on_screen: bool = False,
        match: Callable[[tree.Node], bool] | None = None,
    ) -> tree.Node:
        """Matches `name`, which is the identifier when one is set.

        WDA falls the `name` attribute back to the label when an element has no
        accessibilityIdentifier, so this reaches both the SDK's tagged controls
        and the example app's untagged Pay button with one matcher -- exactly
        what wda.py's by_name did. `identifier_only` turns the label half off,
        which is what everything on the SDK's sheet now passes: both cancels are
        *labelled* "Cancel", and every other label on that sheet is drawn in
        whatever language the session asked for. What is left matching a label
        is the example app's own Pay and the sandbox challenge's outcome
        buttons, neither of which the SDK draws or translates.

        `match` replaces the comparison for the one element whose name is not
        stable -- see `_is_token_field`. `name` is still what a failure is
        reported as, so the message names the field rather than a lambda.
        """
        if not name:
            # Every untagged element carries name="" and label="", which is most
            # of a real source, so a tap would land on an arbitrary one instead
            # of failing. Nothing in Phase 0 passes one; this is about the
            # caller a later phase adds.
            raise DriverError("refusing to match on an empty name")
        found = self._poll(
            lambda nodes: self._pick(
                nodes, name, identifier_only, require_on_screen, match
            ),
            timeout,
            interval,
        )
        if found is None:
            where = " on screen" if require_on_screen else ""
            raise DriverError(f"no element named {name!r}{where} within {timeout}s")
        return found

    def _tap_node(self, node: tree.Node) -> None:
        x, y = node.centre
        self._wda("POST", self._session("/wda/tap"), {"x": float(x), "y": float(y)})

    def tap_identifier(
        self,
        name: str,
        *,
        timeout: float = 30,
        interval: float = POLL_INTERVAL_SECONDS,
        identifier_only: bool = False,
    ) -> None:
        self._tap_node(
            self._find(
                name,
                timeout=timeout,
                interval=interval,
                identifier_only=identifier_only,
            )
        )

    def scroll_to(
        self,
        name: str,
        *,
        max_swipes: int = _MAX_SWIPES,
        settle: float = SCROLL_SETTLE_SECONDS,
    ) -> tree.Node:
        """Swipes the sheet up until `name` is on screen, then returns it.

        The sandbox ACS page is taller than the sheet. On the 402x874 simulator
        only AUTHENTICATION OUTCOMES fits -- `approve` through
        `authentication_required` -- and every ISSUER DECLINES button, which is
        where `fraud_suspected` lives, starts below the fold. A name match alone
        finds a node that cannot be tapped, so this is not optional for D0.

        Driver-internal deliberately: the cell action vocabulary is frozen in
        Phase 0, and nothing in it should have to know that one platform's ACS
        page scrolls.
        """
        width, height = self._window_size()
        for attempt in range(max_swipes + 1):
            # The tolerance expires with the last look, as a poll's does with
            # its deadline: a WDA that will not answer is reported as itself
            # rather than as a button that never came up.
            nodes = self._nodes(tolerate=attempt < max_swipes)
            node = self._pick(nodes, name, False, True)
            if node is not None:
                return node
            if attempt == max_swipes:
                # A look before the first drag and after the last, so
                # `max_swipes` is a count of drags rather than of looks.
                break
            self._wda(
                "POST",
                self._session("/wda/dragfromtoforduration"),
                {
                    "fromX": width / 2,
                    "fromY": self._drag_origin(nodes, height),
                    "toX": width / 2,
                    "toY": height * _DRAG_TO,
                    "duration": _DRAG_DURATION,
                },
            )
            self._sleep(settle)
        raise DriverError(f"{name!r} never came on screen after {max_swipes} swipes")

    def _drag_origin(self, nodes: list[tree.Node], height: int) -> float:
        """Where a pan has to start for the sheet to receive it at all.

        Measured on the simulator 2026-09-07, and it is not a tuning knob. A
        drag from `height * _DRAG_FROM` -- y=655 on an 874-tall screen -- moves
        the card form by nothing whatever, twelve times in a row, because the
        email `TextField` occupies 632..677 and a UIKit text field swallows the
        pan. The same drag from y=612 scrolled the sheet by 228 points. The two
        differ only in which node is underneath: 612 is inside that field's
        `StaticText` label, which is inert.

        So the origin is read off the tree rather than off the screen: the
        LOWEST on-screen `StaticText` between the floor and the ceiling, which
        is as far down as a drag can start without landing on a control and
        therefore the longest swipe available. A label is the right shape for
        this on both surfaces -- the sheet's field captions and the ACS page's
        headings are both `StaticText`.

        The old fraction stays as the fallback, for a screen with no label on
        it at all. It is no worse than what this replaced.
        """
        labels = [
            node.centre[1]
            for node in nodes
            if node.type == "StaticText"
            and self._on_screen(node)
            and height * _DRAG_FLOOR <= node.centre[1] <= height * _DRAG_FROM
        ]
        return float(max(labels)) if labels else height * _DRAG_FROM

    def scroll_back_to_top(
        self,
        *,
        max_swipes: int = _MAX_SWIPES,
        settle: float = SCROLL_SETTLE_SECONDS,
    ) -> None:
        """Undoes `scroll_to`, so an action that scrolled leaves no trace.

        `scroll_to` is the only thing in this driver that moves the sheet, and
        until D5 nothing called it on the *form* -- only on the ACS page, which
        the cell then leaves. `save_card` broke that: it scrolls the form to
        reach the toggle, and a form left scrolled poisons every action after
        it.

        Measured, and it cost a live cell. With the sheet left scrolled,
        `amount` sat at y=37 -- under the navigation bar -- and
        `dismiss_keyboard`'s fallback tap on `amount` hit dead space. The CVV
        pad then survived onto the ACS page, where `acs()` requires it gone, and
        `saved_card_3_challenge_save` failed while its interleaved control
        passed.

        The anchor is `amount`: the SDK tags it, it is the first thing in the
        form, and it never moves within it. Best effort and bounded -- a sheet
        that will not scroll back is not worth failing a cell that has
        otherwise done what it was asked.
        """
        width, height = self._window_size()
        for _ in range(max_swipes):
            nodes = self._nodes(tolerate=True)
            anchor = self._pick(nodes, AMOUNT, False, False)
            floor = max(
                (n.bounds[3] for n in nodes if n.type == "NavigationBar"),
                default=0,
            )
            if anchor is not None and anchor.bounds[1] >= floor:
                return
            self._wda(
                "POST",
                self._session("/wda/dragfromtoforduration"),
                {
                    "fromX": width / 2,
                    "fromY": height * _DRAG_TO,
                    "toX": width / 2,
                    "toY": height * _DRAG_FROM,
                    "duration": _DRAG_DURATION,
                },
            )
            self._sleep(settle)

    def _keyboard(self) -> tree.Node | None:
        """The keyboard node, so a caller can ask where it is, not just whether.

        Its bounds are the whole point: a fallback tap on a node the keyboard
        covers types into the keyboard.
        """
        for node in self._nodes():
            if node.type == "Keyboard" and node.visible:
                return node
        return None

    def dismiss_keyboard(
        self, *, settle: float = SETTLE_SECONDS, required: bool = True
    ) -> bool:
        """Puts away the keyboard the CVV field raised. True if it went.

        It covers the bottom ~35% of the sheet, which is where the ACS page's
        decline outcomes land -- and `scroll_to` drags from `height * 0.75`,
        which is *inside* that area, so a keyboard left up also stops the swipe
        from moving the page and the cell burns every swipe before giving up.
        Android's `type_card` drops the IME with a back key for the same reason.

        The fallback is not decoration. The CVV pad is numeric and has no Done
        or Return key, so `XCUIApplication.dismissKeyboard` may find nothing to
        press and WDA answers with an error envelope. Tapping a neutral node
        above the keyboard is the way out: `amount` is tagged by the SDK
        (`CardFormView.swift:179`) and is never interactive. Above is checked
        rather than assumed -- tapping a node the keyboard covers types into
        the keyboard.

        On the card form none of that works, measured on the rig 2026-08-29:
        dismissKeyboard answers "invalid element state", and taps on `amount`,
        on TOTAL and on the navigation bar, and a drag down the form, all leave
        the pad up -- the SwiftUI form offers no affordance at all. So
        `required` says whether a pad that stays is fatal. `type_card` passes
        False, because on the form the pad covers nothing that matters:
        payButton sits above it. `acs()` keeps the default, because there it
        covers the answer.
        """
        if self._keyboard() is None:
            # acs() calls this on a page that has no keyboard, where
            # dismissKeyboard costs two round trips to answer with an error
            # envelope and change nothing.
            return True
        try:
            self._wda("POST", self._session("/wda/keyboard/dismiss"), {})
        except DriverError:
            pass
        self._sleep(settle)
        keyboard = self._keyboard()
        if keyboard is None:
            return True

        target = self._find(AMOUNT, timeout=5)
        x, y = target.centre
        left, top, right, bottom = keyboard.bounds
        if left <= x <= right and top <= y <= bottom:
            if not required:
                return False
            raise DriverError(
                f"the only way out of the keyboard is {AMOUNT!r}, and it is "
                f"behind the keyboard at {target.centre}; tapping it would type "
                "into the keyboard rather than dismiss it"
            )
        self._tap_node(target)
        self._sleep(settle)
        if self._keyboard() is None:
            return True
        if not required:
            return False
        raise DriverError(
            "the keyboard is still up after dismissKeyboard and a tap on "
            "'amount'; it covers the ACS page's decline outcomes and blocks "
            "the scroll, so failing here beats burning every swipe"
        )

    def _keys(self, text: str) -> None:
        # One character at a time, as wda.py does: WDA's /wda/keys takes a list.
        self._wda("POST", self._session("/wda/keys"), {"value": list(text)})

    def _paced_keys(self, text: str) -> None:
        """One request per character, at the pace a formatted field can take.

        `_keys` hands WDA the whole string and it arrives faster than the SDK
        reflows the field, which loses characters -- see KEY_PACING_SECONDS.
        Only the card fields need this; the token field is not formatted and is
        thirteen times longer, so it keeps the bulk path.
        """
        for character in text:
            self._keys(character)
            self._sleep(KEY_PACING_SECONDS)

    # -- actions -------------------------------------------------------------

    def _enter_token_text(self, text: str) -> None:
        """Everything `paste_token` does up to and including the read-back.

        The token reaches `simctl pbcopy` on ssh's stdin, so it is never an
        argument on either machine and never lands on the Mac's disk at all.
        The pasteboard is overwritten in a `finally`: left alone it outlives
        the cell and anything on the simulator can read it.
        """
        field = self._find(
            TOKEN_FIELD, timeout=SCREEN_TIMEOUT_SECONDS, match=_is_token_field
        )
        try:
            self._remote(
                f"xcrun simctl pbcopy {self._quoted_udid}", stdin=text.encode("utf-8")
            )
            self._tap_node(field)
            self._sleep(PASTE_SETTLE_SECONDS)
            # Re-resolved: the tap raised the keyboard, which on a short screen
            # scrolls the field out from under the coordinates it had before.
            x, y = self._find(TOKEN_FIELD, timeout=15, match=_is_token_field).centre
            self._wda(
                "POST",
                self._session("/wda/touchAndHold"),
                {"x": float(x), "y": float(y), "duration": 1.2},
            )
            self._sleep(PASTE_SETTLE_SECONDS)
            self.tap_identifier(PASTE_ITEM, timeout=15)
        finally:
            # The token outlives nothing: not the paste, not a failure.
            self._remote(f"xcrun simctl pbcopy {self._quoted_udid}", stdin=b" ")
        self._sleep(SETTLE_SECONDS)

        def took(nodes):
            for node in self._matches_in(nodes, TOKEN_FIELD, False, _is_token_field):
                if node.value:
                    return True
            return None

        # An empty pasteboard or a long-press that missed leaves the field as
        # it was, and the run would only find out as a 401 that reads as an SDK
        # bug. Only presence is checked: WDA is not promised to hand back all
        # 1011 characters of a text field's value.
        if self._poll(took, TOKEN_READBACK_SECONDS, SETTLE_SECONDS) is None:
            raise DriverError(
                f"the {TOKEN_FIELD!r} field is still empty after the paste; the "
                "pasteboard or the Paste item did not take"
            )

    def paste_token(self, token_path: Path) -> None:
        self._enter_token_text(read_token(Path(token_path), verb="paste"))
        self.tap_example_pay()
        self._pay_button(timeout=SCREEN_TIMEOUT_SECONDS)

    def present_token(self, token_path: Path) -> None:
        """The token and the example's Pay, with no wait for a sheet.

        `paste_token` ends by waiting 60 s for the sheet. For a token the SDK
        is expected to refuse there is never going to be one -- the refusal
        happens before `present` is called at all (PaymentSheet.swift:42-51
        against line 65) -- so that wait spends a minute and then reports
        "payButton never appeared" instead of the label the app has been
        showing the whole time.
        """
        self._enter_token_text(read_token(Path(token_path), verb="paste"))
        self.tap_example_pay()

    def tap_example_pay(self) -> None:
        # Identifier-only, like every other tap in here that could reach two
        # screens: the example's Pay is untagged, so `name` is WDA's fallback
        # to the label, and the sheet's own payButton is a different element.
        self.tap_identifier(EXAMPLE_PAY, identifier_only=True)

    def enter_token(self, literal: str) -> None:
        """Types a short literal into the example's token field.

        Deliberately not through `read_token`: what the SDK does with
        something that is *not* a credential is the whole point of the cells
        that use this. `cells.py` caps the literal at 200 printable,
        space-free, colon-free characters, so nothing a live token could be
        fits through here.
        """
        self._tap_node(
            self._find(
                TOKEN_FIELD, timeout=SCREEN_TIMEOUT_SECONDS, match=_is_token_field
            )
        )
        self._sleep(SETTLE_SECONDS)
        self._keys(literal)
        self._sleep(SETTLE_SECONDS)

    def airplane(self, on: bool) -> None:
        # R6. The simulator shares the host's network, and every route to
        # cutting it -- Network Link Conditioner, pfctl -- needs sudo or the
        # GUI, neither of which this rig has. Raising rather than pretending:
        # the runner reads NotImplementedError as a cell-authoring fault and
        # spends no control check on it, and every network-cut cell is
        # `platforms: [android]` for exactly this reason.
        raise NotImplementedError(
            "airplane mode does not exist on the iOS simulator: it shares the "
            "host's network, and cutting that needs sudo or the GUI"
        )

    # -- the app process and the device --------------------------------------

    def _foreground_bundle(self) -> str:
        """The bundle id of whatever is frontmost, or "".

        Asked of `GET /wda/activeAppInfo`, which answers with the bundle id
        directly. NOT read off `/source`'s root element, which is where an
        earlier design put it: measured on this rig 2026-08-31, WebDriverAgent
        roots the source at an XCUIElementTypeApplication whose `name` is the
        app's DISPLAY name -- `PayCross Demo`, and `Paycross Flutter` before
        the rename, both of which are in the committed fixture. Comparing that
        against `self._bundle` would never match, `_wait_foreground` would
        time out on every resume, and `background` would fail every cell that
        used it while looking like an SDK finding.

        Unsessioned, which matters: `background`'s first half asks this about
        a moment when the app under test is deliberately not frontmost. One
        small JSON answer rather than a whole `/source` body, which on the
        sheet is large.
        """
        value = self._wda("GET", "/wda/activeAppInfo").get("value") or {}
        return str(value.get("bundleId") or "") if isinstance(value, dict) else ""

    def _wait_foreground(
        self, *, timeout: float = 30, interval: float = POLL_INTERVAL_SECONDS
    ) -> None:
        # Same deadline convention as `_poll`: with timeout=0 it looks once
        # and then gives up, which is how a test reaches the failure branch
        # without spending the wait.
        deadline = time.monotonic() + timeout
        while True:
            live = time.monotonic() < deadline
            seen = self._foreground_bundle()
            if seen == self._bundle:
                return
            if not live:
                raise DriverError(
                    f"{self._bundle} is not frontmost after {timeout}s; "
                    f"WebDriverAgent reports {seen!r}"
                )
            self._sleep(interval)

    def background(self, seconds: float) -> None:
        """Home screen, wait, then re-activate -- never re-launch.

        `activate` attaches to the running process. Anything named "launch"
        here means terminate-then-launch for XCUIApplication, which would
        take the --console-pty capture with it and leave criterion 3 reading
        an empty log -- the same trap `launch()`'s bundle-less session
        capabilities exist to avoid.

        Both halves are verified, for the reason the Android side has: a home
        press that did not take would background nothing, and the cell would
        report that the SDK survived something that never happened.

        The two endpoints have different shapes and this WDA is strict about
        it, so they are written out rather than made uniform: `/wda/homescreen`
        is UNSESSIONED and `/wda/apps/activate` is SESSIONED. Measured against
        the running 16.2.2 on 2026-08-31 -- each answers `unknown command -
        Unhandled endpoint` to the other's form, and the sessioned homescreen
        is what failed the first probe run.
        """
        self._wda("POST", "/wda/homescreen", {})
        self._sleep(BACKGROUND_SETTLE_SECONDS)
        if self._foreground_bundle() == self._bundle:
            raise DriverError("the app is still frontmost after /wda/homescreen")
        self._sleep(seconds)
        self._wda(
            "POST", self._session("/wda/apps/activate"), {"bundleId": self._bundle}
        )
        self._wait_foreground()
        self._sleep(BACKGROUND_SETTLE_SECONDS)

    def rotate(self) -> None:
        """A quarter turn through WebDriverAgent.

        Nothing in the SDK locks an orientation and nothing resets on a
        rotation: the sheet's state lives in a PaymentSheetModel held by the
        awaiting frame, and `load()` runs from a `.task` that re-fires only
        on a view-identity change. A challenge survives too -- it is a child
        view controller pinned with a flexible autoresizing mask, not a
        separate presentation. So on iOS this cell asserts that nothing
        happens, which is a real assertion.
        """
        current = self._wda("GET", self._session("/orientation")).get("value")
        target = "PORTRAIT" if current == "LANDSCAPE" else "LANDSCAPE"
        self._wda("POST", self._session("/orientation"), {"orientation": target})
        self._sleep(ROTATE_SETTLE_SECONDS)

    def kill_activity(self) -> None:
        """Ends the app's process, sheet and all.

        `simctl terminate` rather than anything through WebDriverAgent: this
        stands in for a low-memory kill, and what the cell measures is that
        the pending Dart call dies with the isolate.
        """
        self._remote(
            f"xcrun simctl terminate {self._quoted_udid} {self._bundle} "
            "2>/dev/null || true"
        )
        self._sleep(SETTLE_SECONDS)

    def dont_keep_activities(self, on: bool) -> None:
        raise NotImplementedError(
            "'Don't keep activities' is an Android developer option and iOS has "
            "no equivalent: there is no activity to not keep. A cell using it "
            "must be platforms: [android]."
        )

    # D4's whole vocabulary, refused here rather than left to `Driver`'s
    # declaration for the same reason `airplane` is: the refusal names this
    # platform's own reason. There is no wallet in the iOS SDK at all, and
    # Apple Pay is an explicit campaign non-goal -- so every D4 cell is
    # `platforms: [android]`, and a cell that forgets is an authoring fault
    # the runner spends no control check on.
    _NO_WALLET = "Google Pay is Android-only; the iOS SDK has no wallet yet"

    def tap_google_pay(self) -> None:
        raise NotImplementedError(self._NO_WALLET)

    def wait_google_pay(self, timeout: float) -> bool:
        raise NotImplementedError(self._NO_WALLET)

    def wait_no_google_pay(self, timeout: float) -> bool:
        raise NotImplementedError(self._NO_WALLET)

    def _focus_field(self, name: str) -> None:
        """Taps a field, and taps it again if the sheet moved under the tap.

        Measured on the simulator 2026-09-07: tapping `paycross.cardNumber`
        scrolls the form 54 points, because SwiftUI brings the field it has
        just focused clear of the keyboard. So the coordinates the tap was
        computed from are stale by the time it lands, and the NEXT field is
        looked up against a tree read while that scroll was still settling --
        which is how expiry and CVV came back EMPTY from a `type_card` that
        raised nothing. An empty expiry is a Pay button that never enables, so
        the cell then fails at `tap_pay` with a message about the button.

        Two taps rather than a longer sleep: the sheet only moves when a tap
        lands, so the second look is the settled one by construction, and a
        sleep long enough to be sure would be spent on every field.
        A second tap on a field that is already focused does nothing.
        """
        node = self._find(name)
        self._tap_node(node)
        # A scroll animation, not a frame: SCROLL_SETTLE_SECONDS rather than
        # the tap settle, or the second look is as stale as the first.
        self._sleep(SCROLL_SETTLE_SECONDS)
        settled = self._find(name)
        if settled.centre != node.centre:
            self._tap_node(settled)
            self._sleep(SETTLE_SECONDS)

    def _value_of(self, name: str) -> str | None:
        for node in self._nodes(tolerate=True):
            if node.identifier == name:
                return node.value
        return None

    def _fill(self, name: str, value: str) -> None:
        """Focuses a field and types into it, once more if the first go missed.

        The read-back is the point. `type_card` left EXPIRY empty on this sheet
        and raised nothing -- the form scrolls under the tap that focuses a
        field, so the next tap is computed against a stale tree and lands
        somewhere else, and the keys then go to whatever had focus before. An
        empty expiry is a Pay button that never enables, so the cell fails much
        later at `tap_pay`, with a message about the button.

        A field that is empty reports its PLACEHOLDER as its value -- `12/30`
        for the expiry, `NAME ON CARD` for the holder -- so "the value changed"
        is what says the keys landed, without the driver needing to know what
        the SDK will have formatted them into.
        """
        before = self._value_of(name)
        for _ in range(2):
            self._focus_field(name)
            self._paced_keys(value)
            self._sleep(SETTLE_SECONDS)
            if self._value_of(name) != before:
                return
        raise DriverError(
            f"{name} still reads {before!r} after two attempts at typing into "
            "it; the tap is not reaching the field"
        )

    def type_card(self, card: Card) -> None:
        for name, value in (
            (CARDHOLDER, card.holder),
            (CARD_NUMBER, card.pan),
            (EXPIRY, card.expiry_digits),
        ):
            self._fill(name, value)
        # The CVV is a `SecureField`: WDA reports its value as bullets however
        # many digits went in, and an empty one reports bullets too, so there
        # is nothing to read back. `_focus_field` is all this one gets, and the
        # Pay button's own enablement is what says it validated.
        self._focus_field(CVV)
        self._paced_keys(card.cvv)
        self._sleep(SETTLE_SECONDS)
        # CVV is typed last and leaves a numeric keyboard over the bottom of
        # the sheet, which then covers the ACS page's decline outcomes. Tried
        # here so it is already gone by the time a challenge page loads, but
        # not required: on the form the pad covers nothing (payButton is above
        # it), and on this build nothing dismisses it. `acs()` is where it has
        # to be gone, and `acs()` asks again.
        self.dismiss_keyboard(required=False)
        self._sleep(SETTLE_SECONDS)

    def type_cvv(self, cvv: str) -> None:
        """Fills the CVV field and nothing else.

        `cvvField` is declared once in `CardFormView` and rendered by both
        branches of the form, identifier included, so this reuses `type_card`'s
        matcher rather than adding a saved-card variant of it. What differs is
        behind the field: on the saved-card path `cvvBrand` is forced to
        `.unknown`, which is three digits whatever the stored card's brand is.

        Nothing is read back. It is a `SecureField`, so WDA reports its value
        masked or empty however many digits went in -- a read-back would either
        always fail or pass on the bullets, which is worse. The Pay button's
        own enablement is what says the field validated, and `tap_pay` is where
        that is found out.
        """
        self._focus_field(CVV)
        self._paced_keys(cvv)
        self._sleep(SETTLE_SECONDS)
        # The same bargain `type_card` strikes: tried, because the pad covers
        # the bottom of the sheet, and not required, because on this build
        # nothing dismisses it and on the form it covers nothing that matters.
        self.dismiss_keyboard(required=False)
        self._sleep(SETTLE_SECONDS)

    def tap_pay(self, amount_text: str) -> None:
        # `amount_text` is not read on either platform any more: Android taps
        # the same identifier. The parameter stays because the base class and
        # the runner pass it, and `wait_rearmed` still needs the amount.
        self._tap_node(self._pay_button())

    def _pay_button(self, *, timeout: float = 30) -> tree.Node:
        """The Pay button, by its own name where the SDK publishes one.

        On PayCross 0.7.0 it does not: the button answers to `paycross.sheet`,
        for the reason written at that constant. So this prefers the contract
        and falls back to the one element that can only be the Pay button --
        a `Button` carrying the sheet's identifier, which the sheet's own
        container (a `ScrollView`) is not.

        The fallback is temporary and removes itself: the moment the SDK sets
        `paycross.payButton` on that button, the first branch matches and the
        second is never reached. It is here because without it no iOS cell runs
        at all -- `paste_token`, `tap_pay` and `dismiss_cancel` all need this
        element, and every one of them would time out.
        """

        return self._find(PAY_BUTTON, timeout=timeout, match=_is_pay_button)

    def wait_label(
        self,
        timeout: float,
        *,
        interval: float = POLL_INTERVAL_SECONDS,
        prefixes: tuple[str, ...] = tree.LABEL_PREFIXES,
    ) -> str:
        label = self._poll(
            lambda nodes: tree.label_from_tree(nodes, prefixes), timeout, interval
        )
        if label is None:
            raise self.no_label_error(timeout)
        return label

    def _switch(self, identifier: str) -> tree.Node | None:
        """The two-state control with that identifier, wherever it is in the tree.

        Not `_find`: that prefers an on-screen node and this is asked before
        anything has been scrolled, when the answer is legitimately off-screen.
        `checked is not None` is what makes it the switch rather than the
        StaticText beside it, which sits inside the same row.

        Identifier only. It used to accept a label too, back when the toggle
        was addressed as `"Save this card"`; a label match now could only ever
        find the English sheet.
        """
        for node in self._nodes(tolerate=True):
            if node.checked is not None and node.identifier == identifier:
                return node
        return None

    def _toggle_control(self, row: tree.Node) -> tree.Node:
        """The part of a `Toggle` that actually toggles.

        SwiftUI exposes one `Toggle` as TWO switch nodes: the labelled row, and
        the control sitting inside it with no name and no label at all.
        Measured on the simulator 2026-08-31, and it failed first -- tapping
        the row's centre did nothing and the probe came back with "the tap at
        (201, 715) did not turn on 'Save this card'". Only the control responds.

        Which makes this the exact iOS twin of the Android hazard: on both
        platforms the node you can name is not the node you can tap, for two
        entirely different framework reasons.

        Falls back to the row rather than raising when no inner control is
        found. A tap there is what this did before and is no worse than
        nothing, and the verification below catches it either way -- naming the
        coordinates, so the next reader can see which of the two was hit.

        "Inside" is the control's **centre** within the row, not its box within
        the row's box. Measured, the control is (321, 440, 384, 468) against a
        row of (20, 440, 382, 468) -- it overhangs the right edge by two
        points, so strict containment finds nothing and silently falls back to
        the very tap that does not work.
        """
        left, top, right, bottom = row.bounds
        inside = [
            n
            for n in self._nodes(tolerate=True)
            if n.checked is not None
            and n.bounds != row.bounds
            and left <= n.centre[0] <= right
            and top <= n.centre[1] <= bottom
        ]
        return inside[0] if inside else row

    def save_card(self, *, timeout: float = 30) -> None:
        """Makes sure the save-card toggle is on, and proves that it is.

        Three differences from Android, all measured rather than assumed.

        It has to be **scrolled to**: the toggle sits at y=840 on an 874-tall
        screen, below the pinned Pay bar, and WDA reports it not visible even
        with no keyboard up. Android's checkbox is at y=1125 of 2400 and needs
        nothing.

        It is **found** by its identifier and **tapped** somewhere else.
        SwiftUI exposes the row as an `XCUIElementTypeSwitch` carrying the
        identifier as its name, and its state as `value` "0"/"1" -- which
        `tree.parse_wda` normalises into `checked` -- but tapping that row does
        nothing at all. Only the unnamed control inside it responds, so
        `_toggle_control` is not a nicety. Android no longer has this split:
        `paycross.saveCard` is on the `toggleable` row there and the row is
        what responds.

        And "makes sure" rather than "taps", for the reason Android has too:
        tapping an already-on toggle turns it off, and the cell would assert a
        save its own action had just undone.

        It is found by identifier rather than by `"Save this card"`, which is
        what this matched until Train 4 and what a French sheet renders as
        `Enregistrer cette carte`.

        The keyboard is dismissed first, best effort. `scroll_to` drags from
        `height * 0.75`, which is inside where a numeric pad sits, so a pad
        left up swallows every swipe -- but nothing on this build reliably
        dismisses that pad, which is why the cell runs `save_card` BEFORE
        `type_card` and there is no pad to fight.
        """
        self.dismiss_keyboard(required=False)
        if self._switch(SAVE_CARD) is None:
            raise DriverError(
                f"no {SAVE_CARD!r} toggle anywhere in the tree: the "
                "session's options are missing save_card_config, or the form "
                "has not rendered"
            )
        node = self.scroll_to(SAVE_CARD)
        if node.checked:
            self.scroll_back_to_top()
            return

        target = self._toggle_control(node)
        self._tap_node(target)
        self._sleep(SETTLE_SECONDS)

        after = self._poll(
            lambda nodes: next(
                (n for n in nodes if n.checked and n.identifier == SAVE_CARD),
                None,
            ),
            timeout,
            POLL_INTERVAL_SECONDS,
        )
        if after is None:
            raise DriverError(
                f"the tap at {target.centre} did not turn on "
                f"{SAVE_CARD!r}; "
                "the submit would carry card.save false and the payment would "
                "store nothing"
            )
        # Only once the tick is confirmed: a failure above has a verdict to
        # report and putting the sheet back would not change it, while a
        # successful tick must leave the form exactly as the next action
        # expects to find it.
        self.scroll_back_to_top()

    def select_saved_card(self, *, timeout: float = 30) -> None:
        """Chooses the first stored card, and proves the form switched.

        Matched on `paycross.savedCard.<uuid>`, tagged on the row's `Button`
        (`SavedCardPicker.swift:86`). Until 0.7.0 the picker set no identifier
        on anything and the only handle was the four U+2022 bullets inside the
        rendered label -- the gap D5 filed and this train closed.

        The verification is the point. `cardNumber` is in the tree before the
        selection and gone after it, because the two branches of the form are
        mutually exclusive (`state.source.isNewCard`), and `cvv` being still
        there is what keeps "the form switched" from also being satisfied by a
        form that failed to render at all. Without that check a selection that
        silently failed would leave the cell typing its CVV into the FRESH
        form, submitting a blank card, and reporting a saved-card payment --
        with `saved_card_used` the only assertion that would ever notice, an
        hour into a matrix run. So this raises rather than returns.
        """
        row = self._poll(
            lambda nodes: next(iter(self._saved_card_rows(nodes)), None),
            timeout,
            POLL_INTERVAL_SECONDS,
        )
        if row is None:
            raise DriverError(
                f"no stored-card row on the sheet within {timeout}s: the "
                "session's options are missing saved_cards, or this customer "
                "has no stored card"
            )
        self._tap_node(row)
        self._sleep(SETTLE_SECONDS)

        switched = self._poll(
            lambda nodes: (
                True
                if not self._matches_in(nodes, CARD_NUMBER, True)
                and self._matches_in(nodes, CVV, True)
                else None
            ),
            timeout,
            POLL_INTERVAL_SECONDS,
        )
        if switched is None:
            raise DriverError(
                f"after tapping {row.identifier} at {row.centre} the sheet is "
                f"still showing the new-card form ({CARD_NUMBER} is present); "
                "the CVV would be typed into a fresh card and the payment would "
                "not use the stored one"
            )

    def _saved_card_rows(self, nodes: list[tree.Node]) -> list[tree.Node]:
        """Every stored card's ROW that is on screen, each card's bin excluded.

        The contract is `paycross.savedCard.<uuid>`, with the bin at that plus
        `.delete`, so the suffix separates them. On screen, because a scrolled
        sheet keeps nodes in the tree at coordinates a tap cannot reach.

        On SDK 0.7.0 neither identifier is in the tree. `SavedCardPicker.swift`
        puts `.payCrossIdentifier(.savedCards)` on the `VStack` holding all of
        them, and SwiftUI's outer identifier overrides the one on each row and
        each bin -- the same mechanism that costs the Pay button its name, one
        container along. Three buttons come back answering to
        `paycross.savedCards` and none answers to its own. So the fallback
        reads the picker's SHAPE, which `_picker_rows` describes.
        """
        tagged = [
            n
            for n in nodes
            if n.identifier.startswith(SAVED_CARD_PREFIX)
            and not n.identifier.endswith(SAVED_CARD_DELETE_SUFFIX)
            and self._on_screen(n)
        ]
        return tagged if tagged else self._picker_rows(nodes)[:-1]

    def _picker_rows(self, nodes: list[tree.Node]) -> list[tree.Node]:
        """The picker's full-width buttons, in composition order.

        Every stored card's row, then `Use a new card` last -- which is how
        `SavedCardPicker` composes them, and why the caller drops the tail.

        A bin is told from a row by GEOMETRY rather than by its label, because
        a label is copy: measured 2026-09-07, a row is `x=20 w=318` and its bin
        `x=338 w=44` in the same vertical band, while `Use a new card` is `x=20
        w=362` and has no bin. So the buttons at the picker's left edge are the
        rows and the ones inset from it are the bins. Reading `Remove card, …`
        would work today and stop working on the French sheet this train
        shipped.
        """
        buttons = [
            n
            for n in nodes
            if n.identifier == SAVED_CARDS and n.type == "Button" and self._on_screen(n)
        ]
        if not buttons:
            return []
        left = min(n.bounds[0] for n in buttons)
        return [n for n in buttons if n.bounds[0] == left]

    def _remove_button_for(
        self, row: tree.Node, nodes: list[tree.Node]
    ) -> tree.Node | None:
        """The bin belonging to `row`, by its name where the SDK publishes one.

        Where it does not -- see `_saved_card_rows` -- the bin is the button
        that is NOT at the picker's left edge and whose centre sits in the
        row's own vertical band. There is exactly one per row.
        """
        named = self._matches_in(nodes, row.identifier + SAVED_CARD_DELETE_SUFFIX, True)
        if named:
            return named[0]
        left = {n.bounds[0] for n in self._picker_rows(nodes)}
        inset = [
            n
            for n in nodes
            if n.identifier == SAVED_CARDS
            and n.type == "Button"
            and n.bounds[0] not in left
            and row.bounds[1] <= n.centre[1] <= row.bounds[3]
        ]
        return inset[0] if inset else None

    def remove_saved_card(self, *, timeout: float = 30) -> None:
        """Deletes the first stored card, and proves the row is gone.

        The proof is the point, and it is not theoretical: Train 2 measured
        this exact path failing on TEST while looking like it had worked, the
        row staying on the sheet with `Could not remove the card. Try again.`
        in the banner, because the web API could not write the session blob
        back. A driver that tapped Confirm and moved on would have reported a
        removal that never happened.

        The row's own identifier carries the card's uuid where the SDK
        publishes one, so the check is exact: not "a row went away" but "the
        row for the card whose bin was tapped went away". Where it does not --
        see `_saved_card_rows` -- there is no name to wait out, so the picker
        is COUNTED instead, and the count has to be taken before anything is
        tapped: a removal that lands promptly would otherwise be compared
        against its own result.
        """
        before = self._poll(
            lambda nodes: self._saved_card_rows(nodes) or None,
            timeout,
            POLL_INTERVAL_SECONDS,
        )
        if before is None:
            raise DriverError(
                f"no stored-card row on the sheet within {timeout}s: the "
                "session's options are missing saved_cards, or this customer "
                "has no stored card"
            )
        row = before[0]
        bin_button = self._remove_button_for(row, self._nodes())
        if bin_button is None:
            raise DriverError(
                f"the row {row.identifier} has no remove button beside it: the "
                "session's saved_cards options are missing allow_removal"
            )
        self._tap_node(bin_button)
        self._sleep(ALERT_SETTLE_SECONDS)

        self._find(REMOVE_DIALOG, timeout=timeout, identifier_only=True)
        self.tap_identifier(REMOVE_CONFIRM, timeout=timeout, identifier_only=True)

        named = row.identifier != SAVED_CARDS
        rows_before = len(before)

        def is_gone(nodes: list[tree.Node]) -> bool | None:
            if named:
                return (
                    True if not self._matches_in(nodes, row.identifier, True) else None
                )
            return True if len(self._saved_card_rows(nodes)) < rows_before else None

        gone = self._poll(is_gone, timeout, POLL_INTERVAL_SECONDS)
        if gone is None:
            raise DriverError(
                f"{row.identifier} is still on the sheet {timeout}s after "
                "confirming its removal; the card was not removed and the "
                "shopper is being told so in the error banner"
            )

    def wait_saved_card(self, timeout: float = 30) -> bool:
        """Whether the sheet is offering a stored card.

        The picker's own container is the whole predicate: `SavedCardPicker` is
        composed only under `if !savedCards.isEmpty`, so `paycross.savedCards`
        being in the tree is exactly "at least one stored card is offered".
        Android reads the same identifier for the same reason.

        This used to match the "Use a new card" row, which was equivalent and
        was English.

        False rather than a raise, for the reason Android's says: "no stored
        card was offered" is a cell verdict, not a broken device.
        """
        found = self._poll(
            lambda nodes: self._pick(nodes, SAVED_CARDS, True, False),
            timeout,
            POLL_INTERVAL_SECONDS,
        )
        return found is not None

    def wait_acs(self, timeout: float = 120) -> bool:
        """Waits for the sandbox ACS page without answering it.

        Matched on `threeDSCancel` rather than on the page's own title:
        `ThreeDSWebViewController` gives the challenge nav bar the title
        "Payment", which says nothing, and sets `accessibilityViewIsModal`, so
        the rest of the tree is gone anyway (R12). The cancel bar exists for a
        challenge and only for a challenge, and it is inside the modal either
        way.
        """
        self._find(THREE_DS_CANCEL, timeout=timeout, identifier_only=True)
        return True

    def acs(
        self,
        outcome: str,
        *,
        timeout: float = 120,
        max_swipes: int = _MAX_SWIPES,
        settle: float = SCROLL_SETTLE_SECONDS,
    ) -> None:
        # The ACS page's buttons are exposed by name in the tree from 0.1.1
        # onwards, which is what makes this a name match rather than a tap at
        # remembered coordinates. Waiting for the page and then scrolling to
        # the outcome are two different things: `fraud_suspected` is in the
        # tree from the moment the page loads, and off-screen for just as long.
        self._find(outcome, timeout=timeout)
        # And a keyboard left up would swallow every swipe, because the drag
        # starts inside it.
        self.dismiss_keyboard(settle=settle)
        self._tap_node(self.scroll_to(outcome, max_swipes=max_swipes, settle=settle))

    def cancel_challenge(self) -> None:
        # installCancelBar() in PayCross v0.1.1,
        # Sources/PayCross/UI/ThreeDSWebViewController.swift. Read that
        # version and no earlier: 0.1.0 has no such thing, no affordance at
        # all here, and held the shopper to the 480-second poll deadline.
        self.tap_identifier(THREE_DS_CANCEL, timeout=120, identifier_only=True)
        self._sleep(ALERT_SETTLE_SECONDS)
        self.tap_identifier(CANCEL_CONFIRM, timeout=30, identifier_only=True)

    def cancel_form(self) -> None:
        # Identifier-only throughout. Both cancels are *labelled* "Cancel", so
        # a label match could reach the challenge bar's item from the form; and
        # the confirmation's buttons are labelled in whatever language the
        # sheet is drawing, which is the whole reason this train happened.
        self.tap_identifier(SHEET_CANCEL, timeout=30, identifier_only=True)
        self._sleep(ALERT_SETTLE_SECONDS)
        self.tap_identifier(CANCEL_CONFIRM, timeout=30, identifier_only=True)

    def dismiss_cancel(self, *, timeout: float = 30) -> None:
        """Raises the cancel dialog, backs out of it, and proves the form is back.

        The path a shopper takes when they nearly abandoned the payment and
        then did not. It is worth driving because it is the one dialog button
        no cell ever pressed: `cancel_form` and `cancel_challenge` both confirm,
        so `paycross.cancelDismiss` was shipped untested from this side.

        `cancelDialog` is checked before the dismissal, and afterwards the
        dialog has to be GONE as well as the Pay button present. Here the
        second half proves nothing on its own: the confirmation is drawn inside
        the sheet rather than raised as an alert, so the Pay button is in the
        source the whole time it is up. Android's dialog is its own window and
        has the opposite asymmetry, which is why both drivers ask for both.
        """
        self.tap_identifier(SHEET_CANCEL, timeout=timeout, identifier_only=True)
        self._sleep(ALERT_SETTLE_SECONDS)
        self._find(CANCEL_DIALOG, timeout=timeout, identifier_only=True)
        self.tap_identifier(CANCEL_DISMISS, timeout=timeout, identifier_only=True)
        self._sleep(ALERT_SETTLE_SECONDS)

        def back(nodes: list[tree.Node]) -> bool | None:
            gone = not self._matches_in(nodes, CANCEL_DIALOG, True)
            return True if gone and any(map(_is_pay_button, nodes)) else None

        if self._poll(back, timeout, POLL_INTERVAL_SECONDS) is None:
            raise DriverError(
                "the sheet did not come back after the cancel dialog was "
                "dismissed; the cell cannot carry on paying"
            )

    def wait_rearmed(
        self,
        amount_text: str,
        timeout: float,
        *,
        interval: float = POLL_INTERVAL_SECONDS,
    ) -> bool:
        # A WDA that will not answer raises out of _poll rather than returning
        # False: "the sheet did not re-arm" is a cell verdict and this is not.
        found = self._poll(
            lambda nodes: tree.sheet_rearmed(nodes, amount_text) or None,
            timeout,
            interval,
        )
        if found is None:
            # See AndroidDriver._blame_the_amount: the launch-time locale guard
            # is gone from both drivers and this is what took its place.
            showing = tree.rearm_amount_mismatch(
                self._nodes(tolerate=True), amount_text
            )
            if showing is not None:
                raise DriverError(
                    f"the sheet re-armed showing {showing!r} where this cell "
                    f"expects {amount_text!r}: the simulator is not drawing "
                    "amounts in the spelling `tree.format_amount_en_us` "
                    "computes, so the re-arm check cannot answer. This is the "
                    "rig, not the SDK."
                )
        return found is not None

    # -- evidence ------------------------------------------------------------

    def dump_tree(
        self, *, attempts: int = _DUMP_ATTEMPTS, interval: float = _DUMP_RETRY_SECONDS
    ) -> bytes:
        """One accessibility dump, re-fetched until it parses.

        WDA wraps the XML in a JSON envelope, and answers mid-transition with a
        body that stops halfway. Untreated that raises `ParseError` out of
        `_nodes`, which is not a `DriverError` and so escapes every polling loop
        -- one transient read would abort the cell.
        """
        if attempts < 1:
            raise ValueError(f"attempts must be at least 1, got {attempts}")
        for attempt in range(attempts):
            value = self._wda("GET", "/source").get("value")
            if not isinstance(value, str):
                problem = f"the envelope's value was a {type(value).__name__}"
                saw = json.dumps(value)[:_EXCERPT]
            else:
                raw = value.encode("utf-8")
                try:
                    ET.fromstring(raw)
                except ET.ParseError as exc:
                    problem = str(exc)
                    # An excerpt, and always a prefix: a truncated body loses
                    # its tail, so this cannot reach the example's token field.
                    saw = value[:_EXCERPT]
                else:
                    return raw
            if attempt + 1 < attempts:
                self._sleep(interval)
        raise DriverError(
            f"no parsable WebDriverAgent source in {attempts} attempts: {problem}; "
            f"it read back as {saw!r}"
        )

    def screenshot(self) -> bytes:
        """A PNG of whatever is on the simulator, fetched as base64.

        base64 rather than raw bytes because the same text transport carries
        everything else, and a PNG that travelled as text would be mangled.

        simctl's stderr is captured and sent back after SHOT_STDERR rather than
        discarded, and an empty frame is refused. Discarding it made every
        failure silent: `&&` skipped base64, `rm -f` made the exit status 0, so
        the answer was an empty string -- and `b64decode("")` is `b""`, which
        evidence.write() would file as a 0-byte frame of the sheet. The two
        halves are separated rather than merged because simctl writes to stderr
        on success as well.
        """
        # Through a file rather than `screenshot -`: this Xcode writes a file
        # literally named `-` in the working directory instead of to stdout.
        raw = self._remote(
            f"mkdir -p {REMOTE_DIR}; "
            f"said=$(xcrun simctl io {self._quoted_udid} screenshot {REMOTE_SHOT} "
            f"2>&1 >/dev/null) && base64 < {REMOTE_SHOT} 2>&1; "
            f"printf '\\n%s\\n%s\\n' {shlex.quote(SHOT_STDERR)} \"$said\"; "
            f"rm -f {REMOTE_SHOT}"
        )
        frame, marker, said = raw.partition(SHOT_STDERR)
        # `base64` wraps its output, so the newlines go before the alphabet is
        # checked.
        packed = "".join(frame.split())
        if not packed:
            raise DriverError(
                f"the simulator returned no screenshot for {self._udid}: simctl "
                f"said {(said if marker else raw).strip()[:_EXCERPT]!r}"
            )
        # Validated rather than trusted: without `validate` b64decode discards
        # every character outside the alphabet, so a complaint that reached the
        # frame half would decode to a few bytes of garbage and be written into
        # evidence as though it were a frame.
        try:
            return base64.b64decode(packed, validate=True)
        except (binascii.Error, ValueError) as exc:
            raise DriverError(
                "the simulator returned no usable screenshot: "
                f"{frame.strip()[:_EXCERPT]!r}"
            ) from exc

    def logs_since(self, since: datetime) -> str:
        """The app's console since this launch, plus the unified log window.

        Both, because neither is enough on its own. The SDK emits no os_log, so
        `log show` never carries Swift's `Fatal error:`, ObjC's `*** Terminating
        app due to uncaught exception` or Dart's `Unhandled Exception:` -- those
        reach stdout and stderr, which is what the `--console-pty` capture
        holds. The unified log is kept for everything the system says about the
        process, which the console cannot see.

        `--last <n>s` rather than `--start`: there is no timezone left to get
        wrong, which is the same reason the Android driver asks the device to
        compute its own logcat cutoff.
        """
        if self._console_from is None:
            # Byte 0 is a previous cell's output, and crash_lines would count
            # it: one cell's crash would then fail every later cell.
            raise DriverError(
                "no console mark; call launch() first, or the window would "
                "start at a previous cell's output"
            )
        elapsed = max(1, int((datetime.now(timezone.utc) - since).total_seconds()) + 5)
        seconds = min(elapsed, LOG_WINDOW_CAP_SECONDS)
        # Complaints are kept rather than discarded: a `tail` that found no file
        # and a `log show` that refused both read as a quiet run otherwise. The
        # size is therefore asked for separately -- "No such file or directory"
        # is text, and a window holding only that would otherwise pass for app
        # output.
        answer = self._remote(
            f"wc -c < {CONSOLE_LOG} 2>&1; printf '%s\\n' "
            f"{shlex.quote(CONSOLE_SIZE)}; "
            f"tail -c +{self._console_from + 1} {CONSOLE_LOG} 2>&1"
        )
        measured, _, console = answer.partition(CONSOLE_SIZE)
        try:
            grown = int(measured.strip()) > self._console_from
        except ValueError:
            grown = False
        if not grown:
            # A Flutter app prints on every launch, so a window that never grew
            # means the capture did not attach, and criterion 3 would pass on
            # nothing. Liveness is asked here rather than up front on purpose:
            # the capture exits when the app does, and an app that died is
            # exactly what criterion 3 is looking for -- checking first would
            # report the one cell that really crashed as a rig fault and throw
            # away the console that holds the evidence.
            self._check_console()
            raise DriverError(
                f"the console log has not grown past byte {self._console_from} "
                f"since launch; {CONSOLE_LOG} measures "
                f"{measured.strip()[:_EXCERPT]!r}. The app prints on every "
                "start, so there is nothing here a crash could have been "
                "recorded in"
            )
        unified = self._remote(
            f"xcrun simctl spawn {self._quoted_udid} log show --last {seconds}s "
            "--info --debug --predicate 'process == \"Runner\"' 2>&1"
        )
        # The header names the number actually asked for, and says when that
        # is not the cell's own elapsed time -- otherwise whoever reads the
        # log later measures the cell's duration from a capped window.
        capped = f" (capped from {elapsed}s)" if seconds < elapsed else ""
        return (
            f"--- app console (simctl launch --console-pty), since this launch ---\n"
            f"{console}\n"
            f"--- log show --last {seconds}s{capped}, "
            f'predicate process == "Runner" ---\n'
            f"{unified}"
        )
