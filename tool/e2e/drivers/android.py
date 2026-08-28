"""Drives the example app on the emulator, from WSL, through the Windows adb.

Ported from the campaign's smoke-cell.sh / fill-card-raw.sh /
flutter-paste-token.sh. Three properties of this setup shape everything here:

* `adb.exe` is a Windows binary and cannot read WSL paths, so an APK has to be
  staged under /mnt/c and handed over in its Windows spelling.
* `adb shell` output arrives with CRLF line endings; `adb exec-out` does not.
* A Flutter widget surfaces as `content-desc` with an empty `text`, while the
  SDK's own Compose text surfaces as `text`. Matching the wrong one cost the
  2026-08-26 run a false 270-second timeout.
"""

from __future__ import annotations

import re
import shutil
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from xml.etree import ElementTree as ET

from .. import tree
from ..cells import Card
from .base import Driver, DriverError

ADB = "/mnt/c/Users/Syllo/AppData/Local/Android/Sdk/platform-tools/adb.exe"
PACKAGE = "com.paycross.paycross_flutter_example"

#: Staged here because the Windows adb cannot open a WSL path.
STAGING_DIR = "/mnt/c/dev/tmp"
WINDOWS_STAGING = r"C:\dev\tmp"
STAGED_APK = "paycross-e2e.apk"

#: Where `uiautomator dump` is told to write, and how many times a dump is
#: attempted before the driver calls the device unusable.
_DUMP_PATH = "/sdcard/ui.xml"
_DUMP_ATTEMPTS = 3

#: The category `monkey` needs in order to start the launcher activity.
_LAUNCHER = "android.intent.category.LAUNCHER"

#: `input text` splits its argument on spaces; %s is its escape.
_SPACE = "%s"

#: KEYCODE_0. Digit n is _KEYCODE_ZERO + n.
_KEYCODE_ZERO = 7
_KEYCODE_DEL = 67
_KEYCODE_BACK = 4
_KEYCODE_MOVE_END = 123

CARD_NUMBER = "Card number input"
EXPIRY = "Expiry date input"
CVV = "CVV input"
CARDHOLDER = "Cardholder name input"
ACS_TITLE = "Sandbox 3DS Challenge"
CANCEL_TITLE = "Cancel Payment?"
CANCEL_CONFIRM = "Yes, Cancel"

#: What `logcat -t` will accept. Validated rather than trusted, because an
#: unusable cutoff yields an empty log, which reads as "nothing crashed".
_LOGCAT_CUTOFF = re.compile(r"^\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}$")


def _run(argv: list[str], binary: bool = False):
    """Invokes adb once. Text results have their CRLF stripped."""
    done = subprocess.run([ADB, *argv], capture_output=True, timeout=300)
    if binary:
        return done.stdout
    return done.stdout.decode("utf-8", errors="replace").replace("\r\n", "\n")


class AndroidDriver(Driver):
    package = PACKAGE

    def __init__(
        self,
        shell=_run,
        staging_dir: str | Path = STAGING_DIR,
        windows_staging: str = WINDOWS_STAGING,
    ):
        self._shell = shell
        self._staging_dir = Path(staging_dir)
        self._windows_staging = windows_staging

    # -- primitives ----------------------------------------------------------

    def getprop(self, name: str) -> str:
        return self._shell(["shell", "getprop", name]).strip()

    def _tap(self, point: tuple[int, int]) -> None:
        self._shell(["shell", "input", "tap", str(point[0]), str(point[1])])

    def _key(self, code: int) -> None:
        self._shell(["shell", "input", "keyevent", str(code)])

    def _input_text(self, text: str) -> None:
        self._shell(["shell", "input", "text", text.replace(" ", _SPACE)])

    def _type_digits(self, digits: str) -> None:
        """One real key event per digit.

        Bulk `input text` bypasses the formatter, which is precisely the code
        path a card form has to survive -- typing raw is what caught the 0.3.1
        caret bug and what proves 0.3.3 fixed it.
        """
        for digit in digits:
            self._key(_KEYCODE_ZERO + int(digit))

    def _nodes(self):
        return tree.parse_uiautomator(self.dump_tree())

    def _find(
        self, finder, needle: str, what: str, timeout: float = 30, interval: float = 2
    ):
        deadline = time.monotonic() + timeout
        while True:
            hits = finder(self._nodes(), needle)
            if hits:
                return hits[0]
            if time.monotonic() >= deadline:
                raise DriverError(f"{what} {needle!r} never appeared within {timeout}s")
            time.sleep(interval)

    def _tap_text(self, text: str, **kw) -> None:
        # An empty needle matches every node whose text is empty, which is
        # most of the tree: the tap would land on an arbitrary one instead
        # of failing. Nothing in Phase 0 passes one, so this is about the
        # caller a later phase adds.
        if not text:
            raise DriverError("refusing to tap on an empty text match")
        self._tap(self._find(tree.find_text_exact, text, "node with text", **kw).centre)

    def _tap_desc(self, desc: str, **kw) -> None:
        if not desc:
            raise DriverError("refusing to tap on an empty content-desc match")
        self._tap(
            self._find(
                tree.find_content_desc, desc, "node with content-desc", **kw
            ).centre
        )

    # -- lifecycle -----------------------------------------------------------

    def install(self, app_path: str) -> None:
        staged = self._staging_dir / STAGED_APK
        shutil.copyfile(app_path, staged)
        self._shell(["uninstall", PACKAGE])  # first install has nothing to remove
        out = self._shell(["install", f"{self._windows_staging}\\{STAGED_APK}"])
        if "Success" not in out:
            raise DriverError(f"adb install did not report Success: {out.strip()[:400]}")

    def launch(self) -> None:
        if self.getprop("sys.boot_completed") != "1":
            raise DriverError("the emulator has not finished booting")
        locale = self.getprop("ro.product.locale")
        if locale != "en-US":
            # The Pay button's text is the only handle the SDK gives, and it
            # is NumberFormat output under the device locale.
            raise DriverError(
                f"device locale is {locale!r}, expected 'en-US': the sheet's Pay "
                "button text would not match"
            )
        self._shell(["shell", "am", "force-stop", PACKAGE])
        self._shell(["shell", "monkey", "-p", PACKAGE, "-c", _LAUNCHER, "1"])
        time.sleep(6)

    # -- actions -------------------------------------------------------------

    def paste_token(self, token_path: Path) -> None:
        token_path = Path(token_path)
        # Compared in characters against what the field shows, and stripped:
        # a trailing newline in the minted file would otherwise be typed into
        # the form and then read back as a one-character truncation.
        text = token_path.read_text(encoding="utf-8").strip()
        expected = len(text)

        field = self._find(
            lambda nodes, _: [n for n in nodes if n.type.endswith("EditText")],
            "",
            "the token field",
        )
        self._tap(field.centre)
        time.sleep(1)

        # ~1011 characters, well past what one `input text` reliably delivers.
        for start in range(0, len(text), 80):
            self._input_text(text[start : start + 80])

        self._key(_KEYCODE_BACK)  # drop the IME
        time.sleep(1)

        on_screen = max(
            (len(n.text) for n in self._nodes() if n.type.endswith("EditText")), default=0
        )
        if on_screen != expected:
            # A truncated paste shows up as an instant 401, which would read as
            # an SDK bug. Fail here instead.
            raise DriverError(
                f"token entry was truncated: {on_screen} characters on screen, "
                f"{expected} in the file"
            )

        self._tap_desc("Pay")
        self._find(tree.find_content_desc, CARD_NUMBER, "the card form", timeout=60)

    def type_card(self, card: Card, verify_pan: bool = True) -> None:
        for field in (CARD_NUMBER, CARDHOLDER):
            self._tap_desc(field)
            time.sleep(1)
            self._key(_KEYCODE_MOVE_END)
            for _ in range(24):
                self._key(_KEYCODE_DEL)

        self._tap_desc(CARD_NUMBER)
        time.sleep(1)
        self._type_digits(card.pan)
        time.sleep(1)

        if verify_pan:
            grouped = {
                n.text for n in self._nodes() if n.text.replace(" ", "") == card.pan
            }
            if not grouped:
                raise DriverError(
                    f"the card field does not hold {card.pan} after typing -- "
                    "the formatter is corrupting input"
                )

        for field, value in (
            (EXPIRY, card.expiry_digits),
            (CVV, card.cvv),
            (CARDHOLDER, card.holder),
        ):
            self._tap_desc(field)
            time.sleep(1)
            self._input_text(value)
            time.sleep(1)

        self._key(_KEYCODE_BACK)  # drop the IME so the Pay button is reachable
        time.sleep(1)

    def tap_pay(self, amount_text: str) -> None:
        self._tap_text(f"Pay {amount_text}")

    def wait_label(
        self,
        timeout: float,
        interval: float = 2,
        prefixes: tuple[str, ...] = tree.LABEL_PREFIXES,
    ) -> str:
        deadline = time.monotonic() + timeout
        while True:
            label = tree.label_from_tree(self._nodes(), prefixes)
            if label is not None:
                return label
            if time.monotonic() >= deadline:
                raise DriverError(f"no contract label within {timeout}s")
            time.sleep(interval)

    def acs(self, outcome: str) -> None:
        self._find(tree.find_text_exact, ACS_TITLE, "the sandbox ACS page", timeout=120)
        # The outcome is chosen by which button is tapped, not by the PAN.
        self._tap_text(outcome)

    def cancel_challenge(self) -> None:
        self._find(tree.find_text_exact, ACS_TITLE, "the sandbox ACS page", timeout=120)
        self._confirm_cancel()

    def cancel_form(self) -> None:
        self._confirm_cancel()

    def _confirm_cancel(self) -> None:
        # BackHandler is unconditional on both screens (PaymentActivity.kt).
        self._key(_KEYCODE_BACK)
        self._find(tree.find_text_exact, CANCEL_TITLE, "the cancel dialog", timeout=30)
        self._tap_text(CANCEL_CONFIRM)

    def wait_rearmed(self, amount_text: str, timeout: float, interval: float = 2) -> bool:
        deadline = time.monotonic() + timeout
        while True:
            if tree.sheet_rearmed(self._nodes(), "android", amount_text):
                return True
            if time.monotonic() >= deadline:
                return False
            time.sleep(interval)

    # -- evidence ------------------------------------------------------------

    def dump_tree(self, attempts: int = _DUMP_ATTEMPTS, interval: float = 1) -> bytes:
        """One accessibility dump, retaken until it parses.

        Two failures hide behind a plain dump-then-cat. `uiautomator dump`
        refuses while the UI is animating -- it prints `ERROR: could not get
        idle state.` and writes nothing -- so the previous dump is still on
        the device and `cat` hands back a *stale* tree that parses perfectly.
        A polling caller then matches a screen that is already gone and taps
        its coordinates. Removing the file in the same round trip turns that
        into an empty read, which is detectable.

        A partly-flushed `cat` is the other failure and presents the same
        way. Untreated it raises `ParseError` out of `_nodes`, which is not a
        `DriverError` and so escapes every polling loop -- one transient read
        would abort the cell.
        """
        problem = "the device wrote no dump"
        for attempt in range(attempts):
            # One round trip, so this stays two adb invocations: a dump that
            # never ran cannot leave the previous one behind to be read.
            self._shell(
                ["shell", f"rm -f {_DUMP_PATH}; uiautomator dump {_DUMP_PATH}"]
            )
            raw = self._shell(["shell", "cat", _DUMP_PATH]).encode("utf-8")
            try:
                ET.fromstring(raw)
            except ET.ParseError as exc:
                problem = str(exc)
            else:
                return raw
            if attempt + 1 < attempts:
                time.sleep(interval)
        raise DriverError(
            f"no parsable uiautomator dump in {attempts} attempts: {problem}"
        )

    def screenshot(self) -> bytes:
        """Black for the whole sheet: PaymentActivity sets FLAG_SECURE.

        Kept anyway -- the black frame is itself evidence that the flag is on,
        and the .uix dump is what actually proves what was on screen.
        """
        return self._shell(["exec-out", "screencap", "-p"], binary=True)

    def logs_since(self, since: datetime) -> str:
        """Logcat from `since` to now, with the cutoff asked of the device.

        `logcat -v time` stamps -- and therefore the `-t` cutoff -- are in the
        **device's** zone, while `run_cell` hands us UTC. The emulator runs
        `Europe/Kiev`, so formatting the UTC value here asks for a window three
        hours too wide: measured at 110,082 lines against 2,187 for the correct
        cutoff. That is not just evidence bloat -- `crash_lines` would then scan
        hours of an emulator that has been up for days, and one unrelated
        `FATAL EXCEPTION` fails the cell, fails the interleaved control for the
        same reason, and aborts the run as a rig fault. A device whose zone is
        *behind* UTC is worse still: the cutoff lands in the future, the log
        comes back empty, and criterion 3 passes on nothing.

        So the device computes it, for the same reason the iOS driver uses
        `--last <n>s`: there is no timezone left to get wrong.
        """
        seconds = max(1, int((datetime.now(timezone.utc) - since).total_seconds()) + 5)
        # Quoted as ONE argument. The device shell re-splits on spaces, and
        # toybox `date` then answers "Max 1 argument (see date --help)".
        cutoff = self._shell(
            ["shell", f"date -d @$(( $(date +%s) - {seconds} )) '+%m-%d %H:%M:%S.000'"]
        ).strip()
        if not _LOGCAT_CUTOFF.match(cutoff):
            raise DriverError(
                f"the device returned no usable logcat cutoff, got {cutoff!r}; "
                "refusing to fetch, because an empty window would let criterion 3 "
                "pass on an empty log"
            )
        return self._shell(["logcat", "-d", "-v", "time", "-t", cutoff])
