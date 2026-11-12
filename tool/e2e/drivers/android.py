"""Drives the example app on the emulator through the Windows adb."""

from __future__ import annotations

import re
import shutil
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from xml.etree import ElementTree as ET

from .. import tree
from ..cells import DEVICE_LANGUAGE_DEFAULT, Card
from .base import Driver, DriverError, device_text, read_token, rig_path

# The Windows adb cannot open a WSL path, so the staging dir is given in
# both spellings.
ADB = rig_path("PAYCROSS_E2E_ADB", "adb.exe")
PACKAGE = "com.paycross.flutterdemo"

# A wedged emulator would otherwise hold the whole matrix on one adb round trip.
RUN_TIMEOUT_SECONDS = 300

STAGING_DIR = rig_path("PAYCROSS_E2E_STAGING_DIR", "/mnt/c/dev/tmp")
WINDOWS_STAGING = rig_path("PAYCROSS_E2E_WINDOWS_STAGING", r"C:\dev\tmp")
STAGED_APK = "paycross-e2e.apk"

_DUMP_PATH = "/sdcard/ui.xml"
_DUMP_ATTEMPTS = 3

_LAUNCHER = "android.intent.category.LAUNCHER"

# `input text` splits its argument on spaces; %s is the escape.
_SPACE = "%s"

# A faster pace reads as the caret bug returning on this emulator, a false
# finding against the SDK.
DIGIT_PACING_SECONDS = 0.4

SETTLE_SECONDS = 1
LAUNCH_SETTLE_SECONDS = 6

# The last `input text` chunk is still landing when the first read happens.
TOKEN_READBACK_SECONDS = 10

# `input text` does not reliably deliver more than this many characters at once.
TOKEN_CHUNK_CHARS = 80

_KEYCODE_ZERO = 7
_KEYCODE_DEL = 67
_KEYCODE_BACK = 4
_KEYCODE_MOVE_END = 123

# The example app's Pay is a Flutter widget, so it matches on
# content-desc, not text.
EXAMPLE_PAY = "Pay"

# The radios settle slowly; a shorter wait reads a half-applied state.
AIRPLANE_SETTLE_SECONDS = 8

# A look taken mid-animation reads the old screen.
BACKGROUND_SETTLE_SECONDS = 3
ROTATE_SETTLE_SECONDS = 3
_KEYCODE_HOME = 3

_FOCUSED = re.compile(r"([A-Za-z0-9_.]+)/[A-Za-z0-9_.$]+")
# Not the same deadline as runner's SAVED_CARD_TIMEOUT_SECONDS.
SAVE_BOX_TIMEOUT_SECONDS = 15

QUOTED_DEVICE_TEXT_CHARS = 80

# The testTag resource-ids reach a uiautomator dump only in a debuggable
# host app, not in a release build.
# A card field's content-desc sits on a non-clickable child View, so the
# tagged EditText is the tap target.
CARD_NUMBER = "paycross.cardNumber"
EXPIRY = "paycross.expiry"
CVV = "paycross.cvv"
CARDHOLDER = "paycross.cardholderName"
SAVE_CARD = "paycross.saveCard"
PAY_BUTTON = "paycross.payButton"
SAVED_CARDS = "paycross.savedCards"

# A dump taken while a dialog is up holds only the dialog, so checks after
# a dismissal need a second look.
CANCEL_DIALOG = "paycross.cancelDialog"
CANCEL_CONFIRM = "paycross.cancelConfirm"
CANCEL_DISMISS = "paycross.cancelDismiss"
REMOVE_DIALOG = "paycross.removeDialog"
REMOVE_CONFIRM = "paycross.removeConfirm"

# The delete bin's identifier starts with the row's prefix, so a row match
# must exclude it.
SAVED_CARD_PREFIX = "paycross.savedCard."
SAVED_CARD_DELETE_SUFFIX = ".delete"
# The page title never reaches the accessibility tree, so only rendered
# text is matched.
# Deployments lag the source, so the old heading phrase stays alongside the
# new one.
ACS_MARKERS = ("AUTHENTICATION OUTCOMES", "Sandbox 3DS Challenge")
# The wallet button has no resource-id in a uiautomator dump, so it
# matches on Google's description.
# Google Play services renders this text in the device language, so a cell
# that sets a language may not touch the wallet.
GOOGLE_PAY_DESC = "Pay with GPay"

# An unusable logcat cutoff prints nothing, which reads as "nothing crashed".
_LOGCAT_CUTOFF = re.compile(r"^\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}$")

# A package the device does not hold exits 0 with no brackets, so the
# output is parsed, not trusted.
_APP_LOCALES = re.compile(r"\bare \[(?P<tags>[^\]]*)\]")


def parse_app_locales(said: str) -> list[str]:
    """Returns the tags `cmd locale get-app-locales` reported."""
    match = _APP_LOCALES.search(said)
    if match is None:
        raise DriverError(
            "could not read the app's locales: `cmd locale get-app-locales "
            f"{PACKAGE}` said {said.strip()[:QUOTED_DEVICE_TEXT_CHARS]!r}"
        )
    return [tag.strip() for tag in match.group("tags").split(",") if tag.strip()]


def _run(argv: list[str], *, binary: bool = False, stdin: str | None = None):
    """Runs adb once and returns its output, with CRLF normalised."""
    what = argv[0] if argv else "adb"
    try:
        done = subprocess.run(
            [ADB, *argv],
            capture_output=True,
            timeout=RUN_TIMEOUT_SECONDS,
            input=stdin.encode("utf-8") if stdin is not None else None,
        )
    except subprocess.TimeoutExpired as exc:
        raise DriverError(
            f"adb {what!r} did not answer within {RUN_TIMEOUT_SECONDS}s"
        ) from exc
    except OSError as exc:
        raise DriverError(f"could not run adb for {what!r}: {exc}") from exc
    if binary:
        if done.returncode != 0:
            raise DriverError(
                f"adb {argv[0]} exited {done.returncode}: "
                f"{device_text(done.stderr).strip()}"
            )
        return done.stdout
    out = device_text(done.stdout)
    if done.returncode != 0:
        out += device_text(done.stderr)
    return out


class AndroidDriver(Driver):
    #: `uiautomator dump` on this side of the fence; base._nodes calls it.
    _parse_dump = staticmethod(tree.parse_uiautomator)

    def __init__(
        self,
        shell=_run,
        staging_dir: str | Path = STAGING_DIR,
        windows_staging: str = WINDOWS_STAGING,
        sleep=time.sleep,
    ):
        super().__init__(package=PACKAGE, sleep=sleep)
        self._shell = shell
        self._staging_dir = Path(staging_dir)
        self._windows_staging = windows_staging

    # -- primitives ----------------------------------------------------------

    def getprop(self, name: str) -> str:
        """Returns one property, or raises DriverError quoting what adb said instead."""
        answer = self._shell(["shell", "getprop", name]).strip()
        if any(character.isspace() for character in answer):
            raise DriverError(f"adb could not read {name}: {answer!r}")
        return answer

    def _tap(self, point: tuple[int, int]) -> None:
        self._shell(["shell", "input", "tap", str(point[0]), str(point[1])])

    def _key(self, code: int) -> None:
        self._shell(["shell", "input", "keyevent", str(code)])

    def _input_text(self, text: str) -> None:
        self._shell(["shell", "input", "text", text.replace(" ", _SPACE)])

    def _type_digits(self, digits: str) -> None:
        """Sends one key event per digit, paced by DIGIT_PACING_SECONDS."""
        # Bulk `input text` bypasses the card formatter, so digits are sent one
        # key event at a time.
        for digit in digits:
            self._key(_KEYCODE_ZERO + int(digit))
            self._sleep(DIGIT_PACING_SECONDS)

    def _find(
        self,
        finder,
        needle: str,
        what: str,
        *,
        timeout: float = 30,
        interval: float = 2,
    ):
        found = self._poll(
            lambda nodes: next(iter(finder(nodes, needle)), None), timeout, interval
        )
        if found is None:
            # The token field is found by class, so an empty needle is valid.
            named = f"{what} {needle!r}" if needle else what
            raise DriverError(f"{named} never appeared within {timeout}s")
        return found

    def _tap_text(self, text: str, **kw) -> None:
        # An empty needle matches every node with empty text, so the tap would
        # land on an arbitrary one.
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

    def _tap_id(self, identifier: str, **kw) -> None:
        """Taps the node the SDK published under `identifier`.

        The centre of the tagged node, and not of anything around it. Every
        control this reaches carries the tag on the clickable node itself --
        the card fields on their `EditText`, the Pay button and the dialog
        buttons on their own `View`, the save-card row on the `toggleable` Row
        -- so unlike the content-desc matchers this replaced there is no
        wrapper to bubble a touch down through.
        """
        if not identifier:
            # An untagged node carries resource-id="", which is most of a real
            # tree, so a tap would land on an arbitrary one instead of failing.
            raise DriverError("refusing to tap on an empty identifier match")
        self._tap(
            self._find(tree.find_identifier, identifier, "the element", **kw).centre
        )

    def _saved_card_rows(self, nodes: list[tree.Node]) -> list[tree.Node]:
        """Returns each stored card's row, excluding its delete bin."""
        return [
            n
            for n in nodes
            if n.identifier.startswith(SAVED_CARD_PREFIX)
            and not n.identifier.endswith(SAVED_CARD_DELETE_SUFFIX)
        ]

    def _pay_buttons(self, nodes: list[tree.Node]) -> list[tree.Node]:
        """Returns the Pay button, found by its identifier."""
        return tree.find_identifier(nodes, PAY_BUTTON)

    # -- lifecycle -----------------------------------------------------------

    def install(self, app_path: str) -> None:
        staged = self._staging_dir / STAGED_APK
        try:
            self._staging_dir.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(app_path, staged)
        except OSError as exc:
            raise DriverError(f"could not stage {app_path} at {staged}: {exc}") from exc
        # Uninstall fails on a first install, and that failure is expected.
        self._shell(["uninstall", PACKAGE])
        out = self._shell(["install", f"{self._windows_staging}\\{STAGED_APK}"])
        if "Success" not in out:
            raise DriverError(
                f"adb install did not report Success: {out.strip()[:400]}"
            )

    def launch(self) -> None:
        if self.getprop("sys.boot_completed") != "1":
            raise DriverError("the emulator has not finished booting")
        # The device language is not refused, since a French device is a case
        # the rig must measure.
        # sheet_rearmed reads the amount in the en-US spelling; see
        # tree.format_amount_en_us.
        # A device never written to answers null, so this read fails open;
        # airplane() fails closed.
        airplane = self._shell(["shell", "settings get global airplane_mode_on"])
        if airplane.strip() == "1":
            # Airplane mode left on by an earlier cell is a rig fault; refusing
            # here keeps it from reading as an SDK finding.
            # Clearing the setting here would hide that the rig was left dirty,
            # so this refuses instead.
            raise DriverError(
                "the device is in airplane mode: a previous cell left it on. "
                "Run: adb shell cmd connectivity airplane-mode disable"
            )
        # A leftover detach on the plugin makes every following cell
        # report result:pending:result_lost:, a rig fault.
        if (
            self._shell(
                ["shell", "settings get global always_finish_activities"]
            ).strip()
            == "1"
        ):
            raise DriverError(
                "'Don't keep activities' is on: a previous cell left it set, and "
                "every cell after it would fail for that reason while looking "
                "like an SDK finding. Run: adb shell settings put global "
                "always_finish_activities 0"
            )
        # user_rotation only applies while accelerometer_rotation is 0,
        # so both settings are read.
        # An un-restored rotation leaves the Pay button off screen, which
        # reads as an SDK finding.
        sensor = self._shell(
            ["shell", "settings get system accelerometer_rotation"]
        ).strip()
        turned = self._shell(["shell", "settings get system user_rotation"]).strip()
        if sensor == "0" and turned not in ("0", "null", ""):
            raise DriverError(
                f"the device is not upright: user_rotation reads {turned!r} with "
                "accelerometer_rotation off, so a previous cell rotated and did "
                "not rotate back. Every cell after it looks for buttons that are "
                "off screen. Run: adb shell settings put system user_rotation 0"
            )
        self._shell(["shell", "am", "force-stop", PACKAGE])
        self._shell(["shell", "monkey", "-p", PACKAGE, "-c", _LAUNCHER, "1"])
        self._sleep(LAUNCH_SETTLE_SECONDS)

    def _type_token(self, text: str) -> None:
        """Types the token through `adb shell` stdin."""
        # A command line is world-readable, so the token chunks stay out of argv.
        script = "".join(
            f"input text {text[at : at + TOKEN_CHUNK_CHARS]}\n"
            for at in range(0, len(text), TOKEN_CHUNK_CHARS)
        )
        self._shell(["shell"], stdin=script)

    def _find_token_field(self):
        # The example's token field has no identifier, so it is found by class.
        return self._find(
            lambda nodes, _: [n for n in nodes if n.type.endswith("EditText")],
            "",
            "the token field",
        )

    def _enter_token_text(self, text: str) -> None:
        """Types the token and waits until the field reads it back."""
        field = self._find_token_field()
        self._tap(field.centre)
        self._sleep(SETTLE_SECONDS)

        self._type_token(text)

        self._key(_KEYCODE_BACK)
        self._sleep(SETTLE_SECONDS)

        expected, seen = len(text), 0

        def agreed(nodes):
            nonlocal seen
            seen = max(
                (len(n.text) for n in nodes if n.type.endswith("EditText")), default=0
            )
            return True if seen == expected else None

        # Polled, because the last chunks are still arriving.
        if self._poll(agreed, TOKEN_READBACK_SECONDS, SETTLE_SECONDS) is None:
            # A truncated paste shows up as an instant 401, which would read as
            # an SDK bug.
            raise DriverError(
                f"token entry never agreed with the file: {seen} characters on "
                f"screen, {expected} expected"
            )

    def paste_token(self, token_path: Path) -> None:
        self._enter_token_text(read_token(Path(token_path), verb="type"))
        self.tap_example_pay()
        self._find(tree.find_identifier, CARD_NUMBER, "the card form", timeout=60)

    def present_token(self, token_path: Path) -> None:
        """Enters the token and taps the example's Pay, not waiting for a card form."""
        # A token the SDK refuses never shows a card form, so waiting for
        # one only delays the report.
        self._enter_token_text(read_token(Path(token_path), verb="type"))
        self.tap_example_pay()

    def tap_example_pay(self) -> None:
        self._tap_desc(EXAMPLE_PAY)

    def enter_token(self, literal: str) -> None:
        """Types a short literal into the example's token field."""
        # The literal is not read through read_token, and cells.py caps it
        # so no live token fits.
        field = self._find_token_field()
        self._tap(field.centre)
        self._sleep(SETTLE_SECONDS)
        self._input_text(literal)
        self._key(_KEYCODE_BACK)
        self._sleep(SETTLE_SECONDS)

    def airplane(self, on: bool) -> None:
        """Cuts the device's network, and reads back that it was cut."""
        # The cmd connectivity command is used because a settings broadcast
        # needs a system permission and leaves the radios up.
        # Cmd connectivity exists only from API 30.
        want = "1" if on else "0"
        said = self._shell(
            ["shell", f"cmd connectivity airplane-mode {'enable' if on else 'disable'}"]
        )
        self._sleep(AIRPLANE_SETTLE_SECONDS)
        got = self._shell(["shell", "settings get global airplane_mode_on"]).strip()
        if got != want:
            # Below API 30 the read-back reports '0' while cmd reports
            # the service is missing, so both are quoted.
            raise DriverError(
                f"airplane mode reads {got[:QUOTED_DEVICE_TEXT_CHARS]!r} after "
                f"asking for {want!r}: the cut did not take, so anything this "
                "cell measured is meaningless. The toggle said "
                f"{said.strip()[:QUOTED_DEVICE_TEXT_CHARS]!r}"
            )

    def _foreground_package(self) -> str:
        """Which app the window manager says is focused, or "".

        Asked of the window manager rather than inferred from a tree dump:
        a dump of the launcher and a dump of an app mid-transition look alike
        from up here, and this is the question both `background` halves
        actually have.
        """
        said = self._shell(
            ["shell", "dumpsys window | grep -E 'mCurrentFocus|mFocusedApp'"]
        )
        found = _FOCUSED.search(said)
        return found.group(1) if found else ""

    def _wait_foreground(
        self, package: str, *, timeout: float = 30, interval: float = 1
    ) -> None:
        # As in _poll, timeout=0 looks once and then gives up.
        deadline = time.monotonic() + timeout
        while True:
            live = time.monotonic() < deadline
            seen = self._foreground_package()
            if seen == package:
                return
            if not live:
                raise DriverError(
                    f"{package} is not in the foreground after {timeout}s; the "
                    f"window manager reports {seen!r}"
                )
            self._sleep(interval)

    def background(self, seconds: float) -> None:
        """Sends HOME, waits, and brings the task back as a shopper's icon tap would."""
        # `am start` on MainActivity would reorder the task and drop the
        # SDK's activity from the top.
        self._key(_KEYCODE_HOME)
        self._sleep(BACKGROUND_SETTLE_SECONDS)
        if self._foreground_package() == self.package:
            raise DriverError("the app is still in the foreground after HOME")
        self._sleep(seconds)
        self._shell(["shell", "monkey", "-p", self.package, "-c", _LAUNCHER, "1"])
        self._wait_foreground(self.package)
        self._sleep(BACKGROUND_SETTLE_SECONDS)

    def rotate(self) -> None:
        """Turns the screen a quarter turn and leaves it turned."""
        # The sensor would turn the screen straight back, so auto-rotate
        # goes off first.
        # PaymentActivity declares no configChanges, so a rotation recreates it.
        # The CVV field is not saved across a recreation, so rotate after
        # submitting or retype.
        self._shell(["shell", "settings put system accelerometer_rotation 0"])
        current = self._shell(["shell", "settings get system user_rotation"]).strip()
        target = "0" if current == "1" else "1"
        self._shell(["shell", f"settings put system user_rotation {target}"])
        self._sleep(ROTATE_SETTLE_SECONDS)

    def kill_activity(self) -> None:
        """Ends the app's process, sheet and all."""
        # `am kill` skips foreground processes, so only force-stop ends this one.
        self._shell(["shell", "am", "force-stop", self.package])
        self._sleep(SETTLE_SECONDS)

    def dont_keep_activities(self, on: bool) -> None:
        """Sets the "don't keep activities" developer option and reads it back."""
        # With it on, the host activity is destroyed under the open sheet
        # and the pending call comes back as result_lost.
        want = "1" if on else "0"
        self._shell(["shell", f"settings put global always_finish_activities {want}"])
        self._sleep(SETTLE_SECONDS)
        got = self._shell(
            ["shell", "settings get global always_finish_activities"]
        ).strip()
        if got != want:
            raise DriverError(
                f"always_finish_activities reads {got!r} after asking for {want!r}"
            )

    def device_language(self, tag: str) -> None:
        """Sets the app's own language list to `tag`, or clears it for the default."""
        # The system language cannot be set on this image, so the app's own
        # list is the one the SDK reads.
        # The list is cleared in teardown because it outlives the cell
        # and the app's process.
        # Set-app-locales prints nothing on failure, so the list is read
        # back below.
        # The running app keeps its old language until it relaunches;
        # cell_rules requires a relaunch step.
        wanted = [] if tag == DEVICE_LANGUAGE_DEFAULT else [tag]
        # The empty list must reach the device shell as an empty quoted argument.
        listed = ",".join(wanted)
        self._shell(
            ["shell", f"cmd locale set-app-locales {PACKAGE} --locales '{listed}'"]
        )
        self._sleep(SETTLE_SECONDS)
        got = parse_app_locales(
            self._shell(["shell", f"cmd locale get-app-locales {PACKAGE}"])
        )
        # The system stores tags as given, so this compares tags, not
        # canonical forms.
        if [t.lower() for t in got] != [t.lower() for t in wanted]:
            raise DriverError(
                f"the app's languages read {got} after asking for {wanted}: "
                f"`cmd locale set-app-locales {PACKAGE} --locales "
                f"{','.join(wanted)!r}` did not take"
            )

    def type_card(self, card: Card, *, verify_pan: bool = True) -> None:
        for field in (CARD_NUMBER, CARDHOLDER):
            self._tap_id(field)
            self._sleep(SETTLE_SECONDS)
            self._key(_KEYCODE_MOVE_END)
            for _ in range(24):
                self._key(_KEYCODE_DEL)

        self._tap_id(CARD_NUMBER)
        self._sleep(SETTLE_SECONDS)
        self._type_digits(card.pan)
        self._sleep(SETTLE_SECONDS)

        if verify_pan:
            nodes = self._nodes()
            if not any(n.text.replace(" ", "") == card.pan for n in nodes):
                # A caret bug and a mistyped tap look identical here, so the
                # value read is reported.
                field = tree.find_identifier(nodes, CARD_NUMBER)
                reads = field[0].text if field else None
                raise DriverError(
                    f"after typing {card.pan} the card number field reads {reads!r}"
                )

        for field, value in (
            (EXPIRY, card.expiry_digits),
            (CVV, card.cvv),
            (CARDHOLDER, card.holder),
        ):
            self._tap_id(field)
            self._sleep(SETTLE_SECONDS)
            self._input_text(value)
            self._sleep(SETTLE_SECONDS)

        # The keyboard covers the Pay button, so it is dismissed.
        self._key(_KEYCODE_BACK)
        self._sleep(SETTLE_SECONDS)

    def save_card(self, *, timeout: float = SAVE_BOX_TIMEOUT_SECONDS) -> None:
        """Ensures the save-card box is ticked and checks that it is."""
        # Tapping a ticked box unticks it, so the state is checked before the tap.
        # A tap that misses the box leaves the submit with card.save false,
        # and only the saved-card check fails later.
        box = self._poll(
            lambda nodes: next(iter(tree.find_identifier(nodes, SAVE_CARD)), None),
            timeout,
            SETTLE_SECONDS,
        )
        if box is None:
            # Without save_card_config on the session, canSaveCard is false
            # and the box is never composed.
            raise DriverError(
                f"no {SAVE_CARD} on screen within {timeout}s: the session's "
                "options are missing save_card_config, or the form has not "
                "rendered"
            )
        if box.checked is None:
            # The tap would land somewhere plausible and the read-back would
            # blame the tap.
            raise DriverError(
                f"{SAVE_CARD} is on screen at {box.bounds} but is not a "
                "two-state control; the tag is no longer on the toggleable row"
            )
        if box.checked:
            return

        self._tap(box.centre)
        self._sleep(SETTLE_SECONDS)

        after = self._poll(
            lambda nodes: next(
                (n for n in tree.find_identifier(nodes, SAVE_CARD) if n.checked), None
            ),
            timeout,
            SETTLE_SECONDS,
        )
        if after is None:
            raise DriverError(
                f"the tap at {box.centre} did not tick the save-card checkbox; "
                "the submit would carry card.save false and the payment would "
                "store nothing"
            )

    def type_cvv(self, cvv: str) -> None:
        """Fills the saved-card CVV field and nothing else."""
        # type_card cannot serve here, its first act clears a card-number
        # field that is not on this screen.
        self._tap_id(CVV)
        self._sleep(SETTLE_SECONDS)
        self._input_text(cvv)
        self._sleep(SETTLE_SECONDS)
        # The numeric pad covers the Pay button, so it is dismissed
        # before the Pay tap.
        self._key(_KEYCODE_BACK)
        self._sleep(SETTLE_SECONDS)

    def tap_pay(self, amount_text: str) -> None:
        """Taps the sheet's Pay button. `amount_text` is not read."""
        self._tap_id(PAY_BUTTON)

    def tap_google_pay(self, **kw) -> None:
        # The wallet button is found by description; its identifier is
        # not in the dump.
        # The description sits on a non-clickable wrapper, so the tap
        # goes by bounds.
        self._tap(
            self._find(
                tree.find_content_desc, GOOGLE_PAY_DESC, "the Google Pay button", **kw
            ).centre
        )

    def wait_label(
        self,
        timeout: float,
        *,
        interval: float = 2,
        prefixes: tuple[str, ...] = tree.LABEL_PREFIXES,
    ) -> str:
        label = self._poll(
            lambda nodes: tree.label_from_tree(nodes, prefixes), timeout, interval
        )
        if label is None:
            raise self.no_label_error(timeout)
        return label

    def wait_acs(self, timeout: float = 120) -> bool:
        """Waits for the sandbox ACS page without answering it."""
        # The page's title varies by locale, so any of ACS_MARKERS identifies it.
        found = self._poll(
            lambda nodes: next(
                (n for n in nodes if n.text in ACS_MARKERS),
                None,
            ),
            timeout,
            2,
        )
        if found is None:
            raise DriverError(
                f"the sandbox ACS page never appeared within {timeout}s; looked "
                f"for any of {list(ACS_MARKERS)}"
            )
        return True

    def select_saved_card(self, *, timeout: float = 30) -> None:
        """Chooses the first stored card and checks that the form switched."""
        # The saved-card rows are a radio list tagged with identifiers,
        # so the first is tapped where it stands.
        # The card-number field must be gone and the CVV field must remain,
        # or the switch did not happen.
        # The prompt text is localised, so the switch is checked by
        # identifier rather than by prompt.
        row = self._poll(
            lambda nodes: next(iter(self._saved_card_rows(nodes)), None),
            timeout,
            SETTLE_SECONDS,
        )
        if row is None:
            raise DriverError(
                f"no stored-card row on the sheet within {timeout}s: the "
                "session's options are missing saved_cards, or this customer "
                "has no stored card"
            )
        self._tap(row.centre)
        self._sleep(SETTLE_SECONDS)

        switched = self._poll(
            lambda nodes: (
                True
                if not tree.find_identifier(nodes, CARD_NUMBER)
                and tree.find_identifier(nodes, CVV)
                else None
            ),
            timeout,
            SETTLE_SECONDS,
        )
        if switched is None:
            raise DriverError(
                f"after tapping {row.identifier} at {row.centre} the sheet is "
                f"still showing the new-card form ({CARD_NUMBER} is present); "
                "the CVV would be typed into a fresh card and the payment would "
                "not use the stored one"
            )

    def remove_saved_card(self, *, timeout: float = 30) -> None:
        """Deletes the first stored card and checks that its row is gone."""
        # A removal can fail after Confirm and leave the row on the sheet,
        # so the row is checked, not the dialog.
        # The row's identifier carries the card's uuid, so the check is
        # for this card only.
        # The dialog's dump holds nothing else, so the check waits until
        # the pay button is back on the sheet.
        row = self._poll(
            lambda nodes: next(iter(self._saved_card_rows(nodes)), None),
            timeout,
            SETTLE_SECONDS,
        )
        if row is None:
            raise DriverError(
                f"no stored-card row on the sheet within {timeout}s: the "
                "session's options are missing saved_cards, or this customer "
                "has no stored card"
            )
        self._tap_id(row.identifier + SAVED_CARD_DELETE_SUFFIX, timeout=timeout)
        self._sleep(SETTLE_SECONDS)

        self._find(
            tree.find_identifier, REMOVE_DIALOG, "the remove dialog", timeout=timeout
        )
        self._tap_id(REMOVE_CONFIRM, timeout=timeout)

        def is_gone(nodes: list[tree.Node]) -> bool | None:
            back = tree.find_identifier(nodes, PAY_BUTTON)
            return (
                True
                if back and not tree.find_identifier(nodes, row.identifier)
                else None
            )

        if self._poll(is_gone, timeout, SETTLE_SECONDS) is None:
            raise DriverError(
                f"{row.identifier} is still on the sheet {timeout}s after "
                "confirming its removal; the card was not removed and the "
                "shopper is being told so in the error banner"
            )

    def wait_saved_card(self, timeout: float = 30) -> bool:
        """Returns whether the sheet is offering a stored card."""
        # No stored card is a cell verdict, so it returns False rather than
        # raising a device error.
        found = self._poll(
            lambda nodes: next(iter(tree.find_identifier(nodes, SAVED_CARDS)), None),
            timeout,
            SETTLE_SECONDS,
        )
        return found is not None

    def acs(self, outcome: str) -> None:
        self.wait_acs()
        # The outcome is chosen by the button tapped, not by the card number.
        self._tap_text(outcome)

    def cancel_challenge(self) -> None:
        self.wait_acs()
        self._raise_cancel_dialog()
        self._tap_id(CANCEL_CONFIRM)

    def cancel_form(self) -> None:
        self._raise_cancel_dialog()
        self._tap_id(CANCEL_CONFIRM)

    def dismiss_cancel(self, *, timeout: float = 30) -> None:
        """Raises the cancel dialog, dismisses it, and checks that the form is back."""
        # The dialog must be gone and the Pay button back; on iOS the
        # dialog is drawn inside the sheet.
        self._raise_cancel_dialog(timeout=timeout)
        self._tap_id(CANCEL_DISMISS, timeout=timeout)
        self._sleep(SETTLE_SECONDS)

        def back(nodes: list[tree.Node]) -> bool | None:
            gone = not tree.find_identifier(nodes, CANCEL_DIALOG)
            return True if gone and tree.find_identifier(nodes, PAY_BUTTON) else None

        if self._poll(back, timeout, SETTLE_SECONDS) is None:
            raise DriverError(
                "the sheet did not come back after the cancel dialog was "
                "dismissed; the cell cannot carry on paying"
            )

    def _raise_cancel_dialog(self, *, timeout: float = 30) -> None:
        """Presses Back and waits for the cancel dialog."""
        # The sheet has no cancel control on Android, so the Back gesture
        # is the only way to raise the dialog.
        self._key(_KEYCODE_BACK)
        self._find(
            tree.find_identifier, CANCEL_DIALOG, "the cancel dialog", timeout=timeout
        )

    def wait_rearmed(
        self, amount_text: str, timeout: float, *, interval: float = 2
    ) -> bool:
        # A device that will not dump raises rather than answering False,
        # which would read as a verdict.
        found = self._poll(
            lambda nodes: tree.sheet_rearmed(nodes, amount_text) or None,
            timeout,
            interval,
        )
        if found is None:
            self._blame_the_amount(amount_text)
        return found is not None

    def wait_google_pay(self, timeout: float = 30) -> bool:
        found = self._poll(
            lambda nodes: bool(tree.find_content_desc(nodes, GOOGLE_PAY_DESC)) or None,
            timeout,
            2,
        )
        return found is not None

    def wait_no_google_pay(self, timeout: float = 20) -> bool:
        """Returns True only if the Google Pay button is absent for the whole window."""
        # The button can appear late after an async readiness check,
        # so absence must hold for the whole window.
        deadline = time.monotonic() + timeout
        while True:
            live = time.monotonic() < deadline
            if tree.find_content_desc(self._nodes(tolerate=live), GOOGLE_PAY_DESC):
                return False
            if not live:
                return True
            self._sleep(2)

    def dump_tree(
        self, *, attempts: int = _DUMP_ATTEMPTS, interval: float = 1
    ) -> bytes:
        """Returns one parsable accessibility dump, retaken while the UI is busy."""
        if attempts < 1:
            raise ValueError(f"attempts must be at least 1, got {attempts}")
        for attempt in range(attempts):
            # Uiautomator dump leaves the previous file in place when the
            # UI is animating, so it is removed in the same call.
            said = self._shell(
                ["shell", f"rm -f {_DUMP_PATH}; uiautomator dump {_DUMP_PATH}"]
            )
            raw = self._shell(["shell", "cat", _DUMP_PATH]).encode("utf-8")
            try:
                ET.fromstring(raw)
            except ET.ParseError as exc:
                problem = exc
            else:
                return raw
            if attempt + 1 < attempts:
                self._sleep(interval)
        raise DriverError(
            f"no parsable uiautomator dump in {attempts} attempts: {problem}; "
            f"the dump said {said.strip()[:200]!r} and the file read back as "
            f"{raw[:200]!r}"
        ) from problem

    def screenshot(self) -> bytes:
        """Returns a screenshot, black on the sheet because it is FLAG_SECURE."""
        return self._shell(["exec-out", "screencap", "-p"], binary=True)

    def logs_since(self, since: datetime) -> str:
        """Returns logcat lines from `since` to now; the device computes the cutoff."""
        # Logcat stamps are in the device's zone, so the cutoff is
        # computed on the device.
        seconds = max(1, int((datetime.now(timezone.utc) - since).total_seconds()) + 5)
        # The device shell re-splits on spaces, so the date format is
        # quoted as one argument.
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
