"""Drives the example app on the simulator, from WSL, over ssh."""

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
from ..cells import DEVICE_LANGUAGE_DEFAULT, Card
from .base import Driver, DriverError, device_text, read_token, rig_path

SSH_HOST = rig_path("PAYCROSS_E2E_SSH_HOST", "mac")
UDID = "C311AFDC-25FA-44A2-A800-10EB5A1039E3"
BUNDLE = "com.paycross.flutterdemo"
WDA = "http://127.0.0.1:8100"

# An ssh session gets launchd's minimal PATH, so xcrun, curl and flutter
# are missing unless exported here.
MAC_ENV = rig_path(
    "PAYCROSS_E2E_MAC_ENV",
    "export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer "
    "PATH=/opt/homebrew/bin:$HOME/development/flutter/bin:$PATH; ",
)

# The ssh ceiling is longer than the curl timeout, so a stalled WDA call
# is reported by curl, not by a killed ssh.
SSH_TIMEOUT_SECONDS = 900
WDA_TIMEOUT_SECONDS = 30

# The session token is never written here; it goes to pbcopy on ssh's stdin.
REMOTE_DIR = "$HOME/work/e2e/ios/run"
CONSOLE_LOG = f"{REMOTE_DIR}/console.log"
REMOTE_SHOT = f"{REMOTE_DIR}/shot.png"

# Simctl writes a note to stderr on success too, so the frame and stderr
# are split by a marker outside the base64 alphabet.
SHOT_STDERR = "[simctl-stderr]"

# The console size is asked for, because tail's own error text would
# otherwise pass for app output.
CONSOLE_SIZE = "[console-size]"

# These identifiers match on Android too, so they are matched rather than
# rendered text, which is localised.
CARDHOLDER = "paycross.cardholderName"
CARD_NUMBER = "paycross.cardNumber"
EXPIRY = "paycross.expiry"
CVV = "paycross.cvv"
PAY_BUTTON = "paycross.payButton"
# On iOS the sheet's outer identifier overrides the Pay button's, so the
# Pay button is found another way.
# The pay button is not in the simulator tree under its own identifier;
# see _is_pay_button.
SHEET = "paycross.sheet"
# The amount label carries a "Total, " caption ahead of the amount.
AMOUNT = "paycross.amount"
# The save toggle sits below the fold until scrolled to, unlike Android's checkbox.
SAVE_CARD = "paycross.saveCard"

SAVED_CARDS = "paycross.savedCards"
SAVED_CARD_PREFIX = "paycross.savedCard."
SAVED_CARD_DELETE_SUFFIX = ".delete"

THREE_DS_CANCEL = "paycross.threeDSCancel"
SHEET_CANCEL = "paycross.cancel"

# SwiftUI drops a button's identifier on the UIAlertAction, so the dialogs
# are drawn in the sheet.
CANCEL_DIALOG = "paycross.cancelDialog"
CANCEL_CONFIRM = "paycross.cancelConfirm"
CANCEL_DISMISS = "paycross.cancelDismiss"
REMOVE_DIALOG = "paycross.removeDialog"
REMOVE_CONFIRM = "paycross.removeConfirm"

# UIKit's edit menu takes the app's language, so every spelling is listed.
PASTE_ITEMS = ("Paste", "Coller")
PASTE_ITEM = "/".join(PASTE_ITEMS)

TOKEN_FIELD = "Session token"
EXAMPLE_PAY = "Pay"

SETTLE_SECONDS = 0.5
PASTE_SETTLE_SECONDS = 1.5
LAUNCH_SETTLE_SECONDS = 6
SCROLL_SETTLE_SECONDS = 1.0
# The card field reflows after every character, so keys are sent one at a time.
KEY_PACING_SECONDS = 0.15
ALERT_SETTLE_SECONDS = 1
POLL_INTERVAL_SECONDS = 1

BACKGROUND_SETTLE_SECONDS = 2
ROTATE_SETTLE_SECONDS = 2

TOKEN_READBACK_SECONDS = 10

SCREEN_TIMEOUT_SECONDS = 60

# A host clock jump would otherwise ask simctl for a log window of hours.
LOG_WINDOW_CAP_SECONDS = 3600

_CONSOLE_STOP_TRIES = 25
_CONSOLE_STOP_INTERVAL = 0.2

_DUMP_ATTEMPTS = 3
_DUMP_RETRY_SECONDS = 1

# A pan that starts on a text field does nothing, so the drag starts above it.
_DRAG_FROM = 0.75
_DRAG_TO = 0.30
_DRAG_DURATION = 0.4
_MAX_SWIPES = 12

_DRAG_FLOOR = 0.35

_EXCERPT = 200

_DEVICE_STATE = re.compile(r"\(([^()]+)\)\s*$")


def _is_pay_button(node: tree.Node) -> bool:
    if node.identifier == PAY_BUTTON:
        return True
    # The SDK does not set the Pay button's identifier, so the sheet's
    # Button is matched.
    return node.identifier == SHEET and node.type == "Button"


def _is_token_field(node: tree.Node) -> bool:
    # A focused, empty field's label carries the hint, so the name is
    # matched by prefix.
    name = node.identifier or node.content_desc
    return name == TOKEN_FIELD or name.startswith(TOKEN_FIELD + "\n")


def _is_paste_item(node: tree.Node) -> bool:
    return (node.identifier or node.content_desc) in PASTE_ITEMS


def _ssh(command: str, *, stdin: bytes | None = None) -> str:
    what = (command.removeprefix(MAC_ENV).split() or ["ssh"])[0]
    # Stdin carries the session token, since a command line is world-readable.
    # A timeout or a missing ssh must be a DriverError, or it escapes every
    # polling loop.
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
    device_noun = "simulator"

    _parse_dump = staticmethod(tree.parse_wda)

    def __init__(
        self, ssh=_ssh, udid: str = UDID, bundle: str = BUNDLE, sleep=time.sleep
    ):
        # A driver built for another bundle scopes its crash markers to that
        # bundle.
        super().__init__(package=bundle, sleep=sleep)
        self._ssh = ssh
        self._udid = udid
        self._quoted_udid = shlex.quote(udid)
        self._bundle = bundle
        self._session_id: str | None = None
        self._window: tuple[int, int] | None = None
        # Reading from byte 0 would hand a previous cell's console output to
        # crash_lines.
        self._console_from: int | None = None
        self._console_pid: int | None = None
        self._launch_languages: tuple[str, ...] = ()

    def _remote(self, command: str, *, stdin: bytes | None = None) -> str:
        return self._ssh(MAC_ENV + command, stdin=stdin)

    def _wda(self, method: str, path: str, body: dict | None = None) -> dict:
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
        # WDA reports a failure as HTTP 4xx with a JSON body that json.loads
        # accepts.
        value = parsed.get("value")
        if isinstance(value, dict) and "error" in value:
            # The traceback runs to ~10 KB, so the message is cut short.
            raise DriverError(
                f"{method} {path}: {value['error']} - "
                f"{str(value.get('message', ''))[:_EXCERPT]}"
            )
        return parsed

    def _session(self, path: str) -> str:
        if self._session_id is None:
            raise DriverError("no WebDriverAgent session; call launch() first")
        return f"/session/{self._session_id}{path}"

    def _close_open_session(self) -> None:
        # A stale session bound to the bundle terminates the app that launch()
        # starts next.
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
            # Simctl install prints nothing on success, so any output is an error.
            raise DriverError(
                f"simctl install said {out.strip()[:400]!r}; it says nothing when "
                "it succeeds"
            )

    def _device_state(self) -> str:
        """Returns the simulator's state as simctl names it."""
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
        # The older capture still owns the app, so it must be dead before this
        # one starts.
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
        """Launches the app with its console captured, and returns the log mark."""
        # The SDK emits no os_log, so crash markers reach the console, not
        # `log show`.
        # A pty, not --stdout, because NSLog writes to stderr only when stderr
        # is a terminal.
        said = self._remote(
            f"mkdir -p {REMOTE_DIR} && "
            + (f": > {CONSOLE_LOG} && " if truncate else "")
            + f"wc -c < {CONSOLE_LOG} && "
            f"( nohup xcrun simctl launch --console-pty {self._quoted_udid} "
            f"{self._bundle}{self._language_argv()} "
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
        """Asserts the console capture outlived the session request."""
        # Without this check a dead capture leaves logs_since with nothing to scan.
        if self._console_pid is None:
            return
        said = self._remote(
            f"kill -0 {self._console_pid} 2>/dev/null && echo alive || echo dead"
        ).strip()
        if said != "alive":
            # The log is named, not quoted: app output is redacted only on the
            # evidence path.
            raise DriverError(
                "the app's console capture is not running, so a crash would go "
                f"unseen; simctl launch --console-pty exited, see {CONSOLE_LOG} "
                f"on {SSH_HOST}"
            )

    def close(self) -> None:
        """Stops the console capture and deletes the WDA session on the Mac."""
        try:
            self._stop_console()
        finally:
            session_id, self._session_id = self._session_id, None
            if session_id:
                self._wda("DELETE", f"/session/{session_id}")

    def launch(self, *, truncate_console: bool = True) -> None:
        """Cold-starts the example app with its console captured."""
        # Truncate before anything that can fail, or a failed launch leaves the
        # last log readable.
        if truncate_console:
            self._console_from = None
        state = self._device_state()
        if state != "Booted":
            raise DriverError(f"simulator {self._udid} is {state!r}, not booted")
        # The old capture still owns the app until it is stopped.
        self._stop_console()
        # A stale bundle-bound session would terminate the app under a new capture.
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
                        # No bundleId, or WDA relaunches the app and drops its
                        # console capture.
                        # The Flutter engine never quiesces, so the wait times
                        # out every request.
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
        self._window = None
        self._check_console()
        # /orientation needs the session, and a cell that dies rotated leaves
        # the simulator turned.
        pose = self._wda("GET", self._session("/orientation")).get("value")
        if pose not in (None, "PORTRAIT"):
            raise DriverError(
                f"the simulator is not upright: WebDriverAgent reports {pose!r}, "
                "so a previous cell rotated and did not rotate back. Every cell "
                "after it looks for buttons that are off screen"
            )

    def relaunch(self) -> None:
        self.launch(truncate_console=False)

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
        # Without visibility data, on-screen matching is inert and taps land at
        # raw coordinates.
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
        """Matches `name`, which is the identifier when one is set."""
        # WDA's name falls back to the label when an element has no identifier.
        if not name:
            # Untagged elements all have name="", so a blank name would tap an
            # arbitrary one.
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
        match: Callable[[tree.Node], bool] | None = None,
    ) -> None:
        """Taps the element `name` finds, with `match` replacing the name comparison."""
        self._tap_node(
            self._find(
                name,
                timeout=timeout,
                interval=interval,
                identifier_only=identifier_only,
                match=match,
            )
        )

    def scroll_to(
        self,
        name: str,
        *,
        max_swipes: int = _MAX_SWIPES,
        settle: float = SCROLL_SETTLE_SECONDS,
    ) -> tree.Node:
        """Swipes the sheet up until `name` is on screen, then returns it."""
        # A name match alone finds ACS buttons below the fold, which cannot be
        # tapped.
        width, height = self._window_size()
        for attempt in range(max_swipes + 1):
            # A WDA that will not answer must not read as a button that never
            # came up.
            nodes = self._nodes(tolerate=attempt < max_swipes)
            node = self._pick(nodes, name, False, True)
            if node is not None:
                return node
            if attempt == max_swipes:
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
        """Where a pan has to start for the sheet to receive it at all."""
        # A pan that starts on a text field is swallowed, so the drag starts on
        # a label.
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
        """Scrolls the form back up until `amount` is below the navigation bar."""
        # A form left scrolled leaves the next cell's taps on dead space.
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
        """The keyboard node, so a caller can ask where it is, not just whether."""
        for node in self._nodes():
            if node.type == "Keyboard" and node.visible:
                return node
        return None

    def dismiss_keyboard(
        self, *, settle: float = SETTLE_SECONDS, required: bool = True
    ) -> bool:
        """Puts away the keyboard the CVV field raised. True if it went."""
        # A keyboard left up over the sheet's bottom stops scroll_to's drag from
        # moving the page.
        if self._keyboard() is None:
            # acs() calls this with no keyboard up, where dismissKeyboard only
            # errors.
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
        # One character at a time, since WDA's /wda/keys takes a list.
        self._wda("POST", self._session("/wda/keys"), {"value": list(text)})

    def _paced_keys(self, text: str) -> None:
        """One request per character, at the pace a formatted field can take."""
        # Bulk keys arrive faster than the SDK reflows a formatted field, which
        # drops characters.
        for character in text:
            self._keys(character)
            self._sleep(KEY_PACING_SECONDS)

    def _enter_token_text(self, text: str) -> None:
        """Pastes the token into the token field, up to the read-back."""
        # The token goes over ssh stdin, so it is never an argument or on the
        # Mac's disk.
        field = self._find(
            TOKEN_FIELD, timeout=SCREEN_TIMEOUT_SECONDS, match=_is_token_field
        )
        try:
            self._remote(
                f"xcrun simctl pbcopy {self._quoted_udid}", stdin=text.encode("utf-8")
            )
            self._tap_node(field)
            self._sleep(PASTE_SETTLE_SECONDS)
            # The keyboard the tap raises can scroll the field, so its centre is
            # read again.
            x, y = self._find(TOKEN_FIELD, timeout=15, match=_is_token_field).centre
            self._wda(
                "POST",
                self._session("/wda/touchAndHold"),
                {"x": float(x), "y": float(y), "duration": 1.2},
            )
            self._sleep(PASTE_SETTLE_SECONDS)
            self.tap_identifier(PASTE_ITEM, timeout=15, match=_is_paste_item)
        finally:
            # Anything on the simulator can read the pasteboard, so clear it even
            # on failure.
            self._remote(f"xcrun simctl pbcopy {self._quoted_udid}", stdin=b" ")
        self._sleep(SETTLE_SECONDS)

        def took(nodes):
            for node in self._matches_in(nodes, TOKEN_FIELD, False, _is_token_field):
                if node.value:
                    return True
            return None

        # An empty pasteboard would surface later as a 401 that reads as an SDK
        # bug.
        # Only presence is checked, since WDA does not promise all 1011
        # characters back.
        if self._poll(took, TOKEN_READBACK_SECONDS, SETTLE_SECONDS) is None:
            raise DriverError(
                f"the {TOKEN_FIELD!r} field is still empty after the paste; the "
                "pasteboard or the paste item did not take"
            )

    def paste_token(self, token_path: Path) -> None:
        self._enter_token_text(read_token(Path(token_path), verb="paste"))
        self.tap_example_pay()
        self._pay_button(timeout=SCREEN_TIMEOUT_SECONDS)

    def present_token(self, token_path: Path) -> None:
        """Pastes the token and taps the example's Pay, without waiting for a sheet."""
        # A refused token never gets a sheet, so paste_token's 60 s wait would
        # be wasted.
        self._enter_token_text(read_token(Path(token_path), verb="paste"))
        self.tap_example_pay()

    def tap_example_pay(self) -> None:
        # Identifier only, so a label match cannot reach a second screen's Pay
        # button.
        self.tap_identifier(EXAMPLE_PAY, identifier_only=True)

    def enter_token(self, literal: str) -> None:
        """Types a short literal into the example's token field."""
        # Not read_token, since a live token must never be typed through this path.
        self._tap_node(
            self._find(
                TOKEN_FIELD, timeout=SCREEN_TIMEOUT_SECONDS, match=_is_token_field
            )
        )
        self._sleep(SETTLE_SECONDS)
        self._keys(literal)
        self._sleep(SETTLE_SECONDS)

    def airplane(self, on: bool) -> None:
        # Cutting the simulator's network needs sudo or the GUI, so this raises
        # instead.
        raise NotImplementedError(
            "airplane mode does not exist on the iOS simulator: it shares the "
            "host's network, and cutting that needs sudo or the GUI"
        )

    def _foreground_bundle(self) -> str:
        """Returns the bundle id of the frontmost app, or an empty string."""
        # /source's root carries the app's display name, not its bundle id.
        value = self._wda("GET", "/wda/activeAppInfo").get("value") or {}
        return str(value.get("bundleId") or "") if isinstance(value, dict) else ""

    def _wait_foreground(
        self, *, timeout: float = 30, interval: float = POLL_INTERVAL_SECONDS
    ) -> None:
        # With timeout=0 this looks once and gives up, so a test reaches the
        # failure branch.
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
        """Home screen, wait, then re-activate -- never re-launch."""
        # Activate keeps the running process; a relaunch would drop the console
        # capture.
        # /wda/homescreen takes no session; /wda/apps/activate needs one.
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
        """A quarter turn through WebDriverAgent."""
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

    def device_language(self, tag: str) -> None:
        """Sets the languages the app sees from its next cold start."""
        self._launch_languages = () if tag == DEVICE_LANGUAGE_DEFAULT else (tag,)

    def _language_argv(self) -> str:
        """Returns the `-AppleLanguages` launch argument, or an empty string."""
        if not self._launch_languages:
            return ""
        listed = ",".join(self._launch_languages)
        return f" -AppleLanguages {shlex.quote(f'({listed})')}"

    def _pay_buttons(self, nodes: list[tree.Node]) -> list[tree.Node]:
        """Returns every node that `_is_pay_button` accepts."""
        return [node for node in nodes if _is_pay_button(node)]

    _NO_WALLET = "Google Pay is Android-only; the iOS SDK has no wallet yet"

    def tap_google_pay(self) -> None:
        raise NotImplementedError(self._NO_WALLET)

    def wait_google_pay(self, timeout: float) -> bool:
        raise NotImplementedError(self._NO_WALLET)

    def wait_no_google_pay(self, timeout: float) -> bool:
        raise NotImplementedError(self._NO_WALLET)

    def _focus_field(self, name: str) -> None:
        """Taps a field, and taps it again if the sheet scrolled under the tap."""
        node = self._find(name)
        self._tap_node(node)
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
        """Focuses a field and types into it, retrying once if its value stays put."""
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
        # WDA reports a SecureField as bullets, so the CVV cannot be read back.
        self._focus_field(CVV)
        self._paced_keys(card.cvv)
        self._sleep(SETTLE_SECONDS)
        self.dismiss_keyboard(required=False)
        self._sleep(SETTLE_SECONDS)

    def type_cvv(self, cvv: str) -> None:
        """Fills the CVV field and nothing else."""
        self._focus_field(CVV)
        self._paced_keys(cvv)
        self._sleep(SETTLE_SECONDS)
        self.dismiss_keyboard(required=False)
        self._sleep(SETTLE_SECONDS)

    def tap_pay(self, amount_text: str) -> None:
        self._tap_node(self._pay_button())

    def _pay_button(self, *, timeout: float = 30) -> tree.Node:
        """Returns the Pay button, by its identifier or the sheet fallback."""
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
        """Returns the two-state control with that identifier, or None if absent."""
        for node in self._nodes(tolerate=True):
            if node.checked is not None and node.identifier == identifier:
                return node
        return None

    def _toggle_control(self, row: tree.Node) -> tree.Node:
        """Returns the inner switch that toggles a `Toggle` row, or the row itself."""
        # SwiftUI exposes a Toggle as two switch nodes, and only the unnamed
        # inner one responds to a tap.
        # The inner control's centre is tested, because it can overhang the
        # row's right edge.
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
        """Turns the save-card toggle on if it is off, then checks that it is on."""
        # A tap on an on toggle turns it off, so the toggle is tapped only when
        # it is off.
        # A numeric pad left up swallows the drag that scroll_to makes, so it is
        # dismissed first.
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
        """Taps the first stored card and raises unless the form switched to it."""
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
        """Returns the on-screen stored-card rows, without each card's bin."""
        # SwiftUI's container identifier overrides the row and bin identifiers.
        tagged = [
            n
            for n in nodes
            if n.identifier.startswith(SAVED_CARD_PREFIX)
            and not n.identifier.endswith(SAVED_CARD_DELETE_SUFFIX)
            and self._on_screen(n)
        ]
        return tagged if tagged else self._picker_rows(nodes)[:-1]

    def _picker_rows(self, nodes: list[tree.Node]) -> list[tree.Node]:
        """Returns the picker's full-width buttons, rows first, in composition order."""
        # A bin is told from a row by its x position, because its label is
        # translated.
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
        """Returns the remove button belonging to `row`, or None if there is none."""
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
        """Deletes the first stored card and raises unless its row is gone."""
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
            # The dialog is drawn inside the sheet, so it must be gone before the
            # rows are read.
            if self._matches_in(nodes, REMOVE_DIALOG, True):
                return None
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
        """Returns whether the sheet is offering a stored card, without raising."""
        found = self._poll(
            lambda nodes: self._pick(nodes, SAVED_CARDS, True, False),
            timeout,
            POLL_INTERVAL_SECONDS,
        )
        return found is not None

    def wait_acs(self, timeout: float = 120) -> bool:
        """Waits for the ACS challenge page to load, without answering it."""
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
        self._find(outcome, timeout=timeout)
        # An outcome button is in the tree before it is on screen, so it is
        # scrolled to.
        # A keyboard left up swallows the swipes that scroll_to makes.
        self.dismiss_keyboard(settle=settle)
        self._tap_node(self.scroll_to(outcome, max_swipes=max_swipes, settle=settle))

    def cancel_challenge(self) -> None:
        self.tap_identifier(THREE_DS_CANCEL, timeout=120, identifier_only=True)
        self._sleep(ALERT_SETTLE_SECONDS)
        self.tap_identifier(CANCEL_CONFIRM, timeout=30, identifier_only=True)

    def cancel_form(self) -> None:
        # Both cancel buttons are labelled "Cancel", so only identifiers are
        # matched.
        self.tap_identifier(SHEET_CANCEL, timeout=30, identifier_only=True)
        self._sleep(ALERT_SETTLE_SECONDS)
        self.tap_identifier(CANCEL_CONFIRM, timeout=30, identifier_only=True)

    def dismiss_cancel(self, *, timeout: float = 30) -> None:
        """Opens the cancel dialog, dismisses it, and raises unless the form is back."""
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
        # A WDA that does not answer raises rather than returning False.
        found = self._poll(
            lambda nodes: tree.sheet_rearmed(nodes, amount_text) or None,
            timeout,
            interval,
        )
        if found is None:
            self._blame_the_amount(amount_text)
        return found is not None

    def dump_tree(
        self, *, attempts: int = _DUMP_ATTEMPTS, interval: float = _DUMP_RETRY_SECONDS
    ) -> bytes:
        """Returns one accessibility dump, re-fetched until it parses."""
        if attempts < 1:
            raise ValueError(f"attempts must be at least 1, got {attempts}")
        # WDA can answer mid-transition with a truncated body, and that raises
        # ParseError.
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
        """Returns a PNG of the simulator screen, or raises if none was captured."""
        # this Xcode writes a file named `-` instead of stdout, so the shot goes
        # to a file.
        raw = self._remote(
            f"mkdir -p {REMOTE_DIR}; "
            f"said=$(xcrun simctl io {self._quoted_udid} screenshot {REMOTE_SHOT} "
            f"2>&1 >/dev/null) && base64 < {REMOTE_SHOT} 2>&1; "
            f"printf '\\n%s\\n%s\\n' {shlex.quote(SHOT_STDERR)} \"$said\"; "
            f"rm -f {REMOTE_SHOT}"
        )
        frame, marker, said = raw.partition(SHOT_STDERR)
        # Base64 wraps its output, so the newlines are removed before the check.
        packed = "".join(frame.split())
        if not packed:
            raise DriverError(
                f"the simulator returned no screenshot for {self._udid}: simctl "
                f"said {(said if marker else raw).strip()[:_EXCERPT]!r}"
            )
        # Without validate=True, b64decode silently drops characters outside
        # the alphabet.
        try:
            return base64.b64decode(packed, validate=True)
        except (binascii.Error, ValueError) as exc:
            raise DriverError(
                "the simulator returned no usable screenshot: "
                f"{frame.strip()[:_EXCERPT]!r}"
            ) from exc

    def logs_since(self, since: datetime) -> str:
        """Returns the app console since this launch, followed by the unified log."""
        # The SDK emits no os_log, so crashes reach only the console capture.
        if self._console_from is None:
            # From byte 0 a previous cell's crash would count against this cell.
            raise DriverError(
                "no console mark; call launch() first, or the window would "
                "start at a previous cell's output"
            )
        elapsed = max(1, int((datetime.now(timezone.utc) - since).total_seconds()) + 5)
        seconds = min(elapsed, LOG_WINDOW_CAP_SECONDS)
        # The size is asked for separately, so an error message is not read as
        # app output.
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
            # A Flutter app prints on every launch, so no growth means the capture
            # did not attach.
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
        # The header shows the capped window, not the cell's elapsed time.
        capped = f" (capped from {elapsed}s)" if seconds < elapsed else ""
        return (
            f"--- app console (simctl launch --console-pty), since this launch ---\n"
            f"{console}\n"
            f"--- log show --last {seconds}s{capped}, "
            f'predicate process == "Runner" ---\n'
            f"{unified}"
        )
