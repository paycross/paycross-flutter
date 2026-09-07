"""Drives the example app on the emulator, from WSL, through the Windows adb.

Ported from the campaign's smoke-cell.sh / fill-card-raw.sh /
flutter-paste-token.sh. Three properties of this setup shape everything here:

* `adb.exe` is a Windows binary and cannot read WSL paths, so an APK has to be
  staged under /mnt/c and handed over in its Windows spelling.
* `adb shell` output arrives with CRLF line endings; `adb exec-out` does not.
* A Flutter widget surfaces as `content-desc` with an empty `text`, while the
  SDK's own Compose text surfaces as `text`. Matching the wrong one cost the
  2026-08-26 run a false 270-second timeout.

The sheet itself is no longer matched either way: every control the SDK draws
carries a `paycross.*` identifier, published as a `resource-id`. What is left
on text and description is what has no identifier to use -- the example app's
own Flutter widgets, the sandbox challenge page, and Google's wallet button.
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
from .base import Driver, DriverError, device_text, read_token, rig_path

#: This rig's Windows adb, overridable with PAYCROSS_E2E_ADB.
ADB = rig_path(
    "PAYCROSS_E2E_ADB",
    "/mnt/c/Users/Syllo/AppData/Local/Android/Sdk/platform-tools/adb.exe",
)
PACKAGE = "com.paycross.flutterdemo"

#: Every adb call is bounded. A wedged emulator would otherwise hold the whole
#: matrix on one round trip.
RUN_TIMEOUT_SECONDS = 300

#: Staged here because the Windows adb cannot open a WSL path. The two
#: spellings are the same directory seen from either side of the fence, so a
#: rig that moves one must move both -- hence two variables rather than one
#: guessed from the other.
STAGING_DIR = rig_path("PAYCROSS_E2E_STAGING_DIR", "/mnt/c/dev/tmp")
WINDOWS_STAGING = rig_path("PAYCROSS_E2E_WINDOWS_STAGING", r"C:\dev\tmp")
STAGED_APK = "paycross-e2e.apk"

#: Where `uiautomator dump` is told to write, and how many times a dump is
#: attempted before the driver calls the device unusable.
_DUMP_PATH = "/sdcard/ui.xml"
_DUMP_ATTEMPTS = 3

#: The category `monkey` needs in order to start the launcher activity.
_LAUNCHER = "android.intent.category.LAUNCHER"

#: `input text` splits its argument on spaces; %s is its escape.
_SPACE = "%s"

#: The gap fill-card-raw.sh left after every keyevent, and therefore the timing
#: the 0.3.1 caret bug's fix, shipped in 0.3.2, was proven under on this
#: emulator. Typing flat out would let a formatter that merely cannot keep up
#: present as the caret bug returning -- a false finding against the SDK, which
#: is the expensive direction to be wrong in.
DIGIT_PACING_SECONDS = 0.4

#: What the seed scripts waited after a tap, an entry or a cold start. Kept
#: as named values because the unit tests assert them rather than spend them:
#: the rig's timing stays pinned without the suite sleeping through it.
SETTLE_SECONDS = 1
LAUNCH_SETTLE_SECONDS = 6

#: How long the token read-back is given to agree with the file. The field is
#: filled by ~13 `input text` calls and the last of them is still landing when
#: the first read happens.
TOKEN_READBACK_SECONDS = 10

#: `input text` does not reliably deliver much more than this at once.
TOKEN_CHUNK_CHARS = 80

#: KEYCODE_0. Digit n is _KEYCODE_ZERO + n.
_KEYCODE_ZERO = 7
_KEYCODE_DEL = 67
_KEYCODE_BACK = 4
_KEYCODE_MOVE_END = 123

#: The example app's own Pay, which is a Flutter widget and therefore a
#: content-desc. The SDK's Compose Pay carries the amount in `text` instead.
EXAMPLE_PAY = "Pay"

#: How long the radios take to settle after the toggle. Measured generously:
#: a cell that submits into a half-cut network measures neither state.
AIRPLANE_SETTLE_SECONDS = 8

#: How long the window manager is given to settle after a HOME, a resume or
#: a rotation. Generous: a look taken mid-animation reads the old screen.
BACKGROUND_SETTLE_SECONDS = 3
ROTATE_SETTLE_SECONDS = 3
_KEYCODE_HOME = 3

#: `mCurrentFocus=Window{... com.example/com.example.MainActivity}`.
_FOCUSED = re.compile(r"([A-Za-z0-9_.]+)/[A-Za-z0-9_.$]+")
#: How long the save-card checkbox is given to appear, and to read back as
#: ticked. Short: it is composed with the rest of the form, so a wait here is
#: covering a slow frame rather than a round trip.
#:
#: Named for the BOX, not for the saved-card list: `runner` separately has a
#: SAVED_CARD_TIMEOUT_SECONDS, which is the `expect saved_card` deadline and
#: a different number for a different thing.
SAVE_BOX_TIMEOUT_SECONDS = 15

#: How much raw device text a driver message may carry. These reach stdout and
#: the cell's `problems`, and a wedged adb answers with a screenful.
QUOTED_DEVICE_TEXT_CHARS = 80

#: The identifiers the SDK publishes, from 0.8.0. Compose is told to write a
#: node's `testTag` as its `resource-id`, once per window, so each of these
#: reaches a `uiautomator dump` -- but ONLY in a debuggable host app, which the
#: debug example APK is and a release build is not. iOS publishes the same
#: strings as accessibility identifiers, so the names below are the contract
#: rather than this file's shorthand.
#:
#: These replaced content-desc and rendered-text matchers throughout. Two
#: things measured against a real dump make that more than a tidy-up
#: (2026-09-07, `evidence/train4/t7-probe/02-paste_token.uix`):
#:
#: * a card field's `content-desc` sits on a NON-CLICKABLE child `View` of the
#:   tagged `EditText`, so the old matchers were tapping a wrapper and relying
#:   on the touch bubbling down;
#: * every rendered string the driver used to match is now drawn in French
#:   when the session says so, and would have taken the driver with it.
CARD_NUMBER = "paycross.cardNumber"
EXPIRY = "paycross.expiry"
CVV = "paycross.cvv"
CARDHOLDER = "paycross.cardholderName"
SAVE_CARD = "paycross.saveCard"
PAY_BUTTON = "paycross.payButton"
SAVED_CARDS = "paycross.savedCards"

#: The two SDK-drawn dialogs. Each is its own window and publishes its own
#: identifiers, which is what the 0.8.0 per-window flag fixed and what a dump
#: taken on this rig confirms (`evidence/train4/dialog-ids/`). A dump taken
#: while one is up holds ONLY the dialog -- the form behind it is not in the
#: tree -- so anything checked after a dismissal needs a second look.
CANCEL_DIALOG = "paycross.cancelDialog"
CANCEL_CONFIRM = "paycross.cancelConfirm"
CANCEL_DISMISS = "paycross.cancelDismiss"
REMOVE_DIALOG = "paycross.removeDialog"
REMOVE_CONFIRM = "paycross.removeConfirm"

#: One stored card's row is `paycross.savedCard.<uuid>` and its bin is that
#: plus `.delete`. The uuid is the session's own, so a driver that has not read
#: the session finds a row by its prefix -- and has to exclude the bin, whose
#: identifier starts with the row's.
SAVED_CARD_PREFIX = "paycross.savedCard."
SAVED_CARD_DELETE_SUFFIX = ".delete"
#: How the sandbox's challenge page is recognised. More than one marker, and
#: both of them text the page RENDERS, because this detector has already been
#: broken once by a change that was nobody's fault here.
#:
#: `payment-sandbox` 687bf4e ("Redesign challenge page to match payment page
#: design system") replaced `<strong>Sandbox 3DS Challenge</strong>` with
#: `<div class="sandbox-badge">Sandbox</div>`. The phrase survives only in
#: `<title>`, which never reaches an accessibility tree -- a WebView exposes
#: rendered DOM text, not the document title.
#:
#: What bit us was NOT that redesign landing. 687bf4e is dated 2026-04-13,
#: four months earlier: what happened mid-campaign was the TEST DEPLOYMENT
#: CATCHING UP to it. That is the worse failure mode, because a rig cannot see
#: which build is deployed -- reading `main` would have shown this markup all
#: along while the rig passed against an older deployed page. Source and
#: behaviour disagreed for four months and nothing here could tell. The page
#: carried the old text at 22:07Z and did not at 11:41Z the next morning, and
#: every android cell that waits for a challenge failed in between while the
#: frictionless control passed five times.
#:
#: `AUTHENTICATION OUTCOMES` is the section heading above the outcome buttons
#: and is present in both designs. The old phrase is kept because deployments
#: lag, and a detector that knew only the new wording would break every rig
#: still serving the old page -- the same mistake in the mirror.
#:
#: A bare `Sandbox` is deliberately NOT here: it is the badge text on the new
#: design and far too generic to be evidence of anything.
ACS_MARKERS = ("AUTHENTICATION OUTCOMES", "Sandbox 3DS Challenge")
#: The wallet button is the one thing on the sheet still matched by a rendered
#: string, and it is not a leftover.
#:
#: `paycross.walletButton` is attached (`GooglePaySection.kt:85`) and does NOT
#: reach a uiautomator dump: the tag sits on an `AndroidView`, and the node in
#: the dump belongs to Google's hosted `PayButton` rather than to a Compose
#: semantics node, so `testTagsAsResourceId` has nothing to write it onto. This
#: is the same shape as the dialog bug 0.8.0 fixed and it is still open --
#: measured 2026-09-07, `evidence/train4/t7-probe/02-paste_token.uix` has the
#: wallet row with `content-desc="Pay with GPay"` and no resource-id at all.
#: The Android README's "assert its presence by id" is not true today.
#:
#: So this string stays, with its old caveat intact: it is rendered by Google
#: Play services, so it moves with the GMS version and with the device locale,
#: and a French device would take it with it. Confirmed against this campaign's
#: own dumps, most recently 2026-09-07.
GOOGLE_PAY_DESC = "Pay with GPay"

#: What `logcat -t` will accept. Validated rather than trusted, because an
#: unusable cutoff yields an empty log, which reads as "nothing crashed".
_LOGCAT_CUTOFF = re.compile(r"^\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}$")


def _run(argv: list[str], *, binary: bool = False, stdin: str | None = None):
    """Invokes adb once, normalising CRLF and never discarding a failure.

    A non-zero exit has its stderr appended to the text result rather than
    raised: `uninstall` is expected to fail on a first install, and `install`
    reads this text to report what actually went wrong. Binary results cannot
    carry an explanation -- appending to a PNG would corrupt it -- so those
    raise instead.

    An emulator that has wedged raises TimeoutExpired rather than exiting
    non-zero, and adb.exe lives on a Windows mount that is not always there,
    which raises FileNotFoundError. Neither is a DriverError, so both escape
    every polling loop above and end the whole matrix where they should have
    failed one cell. The iOS driver's `_ssh` closes the same gap.
    """
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
        """One property, or a DriverError quoting what adb said instead.

        `getprop` answers with a bare value or with nothing at all, while
        every way the connection can fail puts a sentence on the wire --
        `no devices/emulators found`, `error: device offline`, `error:
        closed` -- which `_run` now appends rather than discards. Whitespace
        is the tell, and the text is quoted back rather than matched against
        a catalogue of adb's wording. Without this the boot check reads a
        dead connection as "still booting" and the locale check reports
        adb's sentence as though it were a locale. An empty answer is left
        alone: that is a real device with the property not set yet.
        """
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
        """One real key event per digit, at the seed script's pace.

        Bulk `input text` bypasses the formatter, which is precisely the code
        path a card form has to survive -- typing raw is what caught the 0.3.1
        caret bug, which 0.3.2 fixed, and what proves 0.3.3 still holds.
        """
        for digit in digits:
            self._key(_KEYCODE_ZERO + int(digit))
            # After each digit, last one included, as the seed script did.
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
            # The token field is looked up by class, with no needle to name.
            named = f"{what} {needle!r}" if needle else what
            raise DriverError(f"{named} never appeared within {timeout}s")
        return found

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
            self._find(
                tree.find_identifier, identifier, "no element named", **kw
            ).centre
        )

    def _saved_card_rows(self, nodes: list[tree.Node]) -> list[tree.Node]:
        """Every stored card's ROW, each card's bin excluded.

        Both carry an identifier starting with `SAVED_CARD_PREFIX` -- the bin's
        is the row's plus `.delete` -- so the suffix is what separates them.
        Matched by prefix because the uuid in the middle is the session's and
        the driver has not read the session.
        """
        return [
            n
            for n in nodes
            if n.identifier.startswith(SAVED_CARD_PREFIX)
            and not n.identifier.endswith(SAVED_CARD_DELETE_SUFFIX)
        ]

    # -- lifecycle -----------------------------------------------------------

    def install(self, app_path: str) -> None:
        staged = self._staging_dir / STAGED_APK
        try:
            self._staging_dir.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(app_path, staged)
        except OSError as exc:
            raise DriverError(f"could not stage {app_path} at {staged}: {exc}") from exc
        self._shell(["uninstall", PACKAGE])  # first install has nothing to remove
        out = self._shell(["install", f"{self._windows_staging}\\{STAGED_APK}"])
        if "Success" not in out:
            raise DriverError(
                f"adb install did not report Success: {out.strip()[:400]}"
            )

    def launch(self) -> None:
        if self.getprop("sys.boot_completed") != "1":
            raise DriverError("the emulator has not finished booting")
        # No locale guard. This used to refuse anything but `en-US`, because
        # the Pay button's rendered text was the only handle the SDK gave and
        # that text is NumberFormat output under the device locale. Every
        # control the driver touches is now reached by identifier, so the
        # device's language is the device's business -- and a French device is
        # a case this rig has to be able to MEASURE rather than refuse.
        #
        # `sheet_rearmed` still reads the amount, and still reads it in the
        # runner's en-US spelling; see `tree.format_amount_en_us` for what that
        # costs and which cells it excludes.
        #
        # Fails OPEN, and the read-back in `airplane()` fails closed. The
        # asymmetry is deliberate: a device that has never had this setting
        # written answers `null`, and refusing to launch on that would break
        # every rig where nothing has ever touched it -- whereas `null` from
        # the read-back means the write we just asked for did nothing. `null`
        # cannot reach `airplane('off')`, because `cell_rules` only lets a
        # cell turn it off after turning it on, which writes it.
        airplane = self._shell(["shell", "settings get global airplane_mode_on"])
        if airplane.strip() == "1":
            # A cell that failed between `airplane on` and `airplane off` left
            # it on, and every cell after it would fail for that reason while
            # looking like an SDK finding. Refusing here makes the interleaved
            # control fail too, which is exactly right: this is a rig fault,
            # and exit 3 says so.
            #
            # `run_cell` now replays a teardown the cell did not live to
            # reach, so arriving here means that replay was REACHED AND
            # FAILED -- or never ran, because the runner itself died. Either
            # way the device is dirty and nothing in this process knows how to
            # clean it. Which is why this still refuses rather than clearing
            # the setting: a run that silently repaired the rig would be a run
            # that had stopped reporting that it broke it.
            raise DriverError(
                "the device is in airplane mode: a previous cell left it on. "
                "Run: adb shell cmd connectivity airplane-mode disable"
            )
        # The same shape, for the same reason, one setting along. This one is
        # worse to inherit than airplane mode: the plugin's detach path fires
        # on EVERY cell that follows, so each of them reports
        # `result:pending:result_lost:` and each looks like an SDK finding
        # rather than like the one rig fault it is. Older runs show the same
        # fault as `error:resultUnknown`; plugin 0.4.0 made it an outcome.
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
        # And the third: a cell that rotated and did not rotate back. Both
        # settings are read, because `user_rotation` only takes effect while
        # `accelerometer_rotation` is 0 -- with the sensor in charge the device
        # is upright whatever `user_rotation` says, and refusing on that alone
        # would break a rig nothing had turned. `rotate()` writes both, so this
        # is exactly the state it leaves.
        #
        # Measured on the D3 probe: one un-restored rotation, and the
        # interleaved control after it failed with "no element named
        # 'payButton' within 60s" -- which reads as an SDK finding and is a rig
        # fault. `cell_rules` refuses a cell with an odd number of turns; this
        # catches the cell that died between two of them, where the teardown
        # replay cannot help because `rotate` has no on/off pair.
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

    # -- actions -------------------------------------------------------------

    def _type_token(self, text: str) -> None:
        """Enters the token without it ever entering this process's argv.

        A command line is world-readable for as long as the process lives, so
        the chunks go to `adb shell` on stdin instead. The device's own shell
        still sees them -- `input text` is the only channel there is -- but
        that exposure lasts as long as the keystrokes do.
        """
        script = "".join(
            f"input text {text[at : at + TOKEN_CHUNK_CHARS]}\n"
            for at in range(0, len(text), TOKEN_CHUNK_CHARS)
        )
        self._shell(["shell"], stdin=script)

    def _find_token_field(self):
        # By class, because the example's field carries no identifier: it is
        # the only EditText the screen has.
        return self._find(
            lambda nodes, _: [n for n in nodes if n.type.endswith("EditText")],
            "",
            "the token field",
        )

    def _enter_token_text(self, text: str) -> None:
        """Everything `paste_token` does up to and including the read-back."""
        field = self._find_token_field()
        self._tap(field.centre)
        self._sleep(SETTLE_SECONDS)

        self._type_token(text)

        self._key(_KEYCODE_BACK)  # drop the IME
        self._sleep(SETTLE_SECONDS)

        expected, seen = len(text), 0

        def agreed(nodes):
            nonlocal seen
            seen = max(
                (len(n.text) for n in nodes if n.type.endswith("EditText")), default=0
            )
            return True if seen == expected else None

        # Polled rather than read once: the last chunks are still arriving.
        if self._poll(agreed, TOKEN_READBACK_SECONDS, SETTLE_SECONDS) is None:
            # A truncated paste shows up as an instant 401, which would read as
            # an SDK bug. Fail here instead, without echoing the token.
            raise DriverError(
                f"token entry never agreed with the file: {seen} characters on "
                f"screen, {expected} expected"
            )

    def paste_token(self, token_path: Path) -> None:
        self._enter_token_text(read_token(Path(token_path), verb="type"))
        self.tap_example_pay()
        self._find(tree.find_identifier, CARD_NUMBER, "the card form", timeout=60)

    def present_token(self, token_path: Path) -> None:
        """The token and the example's Pay, with no wait for a sheet.

        `paste_token` ends by waiting 60 s for the SDK's card form. For a
        token the SDK is expected to refuse there is never going to be one --
        on iOS the refusal happens before `present` is called at all
        (PaymentSheet.swift:42-51 against line 65) -- so that wait spends a
        minute and then reports "the card form never appeared" instead of the
        label the app has been showing the whole time.
        """
        self._enter_token_text(read_token(Path(token_path), verb="type"))
        self.tap_example_pay()

    def tap_example_pay(self) -> None:
        # content-desc, not text: a Flutter widget surfaces as content-desc
        # with an empty text, and the SDK's own Compose Pay does the opposite.
        self._tap_desc(EXAMPLE_PAY)

    def enter_token(self, literal: str) -> None:
        """Types a short literal into the example's token field.

        Deliberately not through `read_token`: what the SDK does with
        something that is *not* a credential is the whole point of the cells
        that use this. `cells.py` caps the literal at 200 printable,
        space-free, colon-free characters, so nothing a live token could be
        fits through here.
        """
        field = self._find_token_field()
        self._tap(field.centre)
        self._sleep(SETTLE_SECONDS)
        self._input_text(literal)
        self._key(_KEYCODE_BACK)
        self._sleep(SETTLE_SECONDS)

    def airplane(self, on: bool) -> None:
        """Cuts the device's network, and proves it was cut.

        `cmd connectivity airplane-mode` rather than the older
        `settings put global airplane_mode_on` plus a broadcast: that
        broadcast needs a system permission on modern Android, and without it
        the setting flips while the radios stay up -- so a cell would report
        that the SDK "survived a network cut" having measured nothing at all.
        The read-back is what makes that impossible.

        API 30 and up. D6's API 24 floor image runs D0 only, which never
        reaches this.
        """
        want = "1" if on else "0"
        said = self._shell(
            ["shell", f"cmd connectivity airplane-mode {'enable' if on else 'disable'}"]
        )
        self._sleep(AIRPLANE_SETTLE_SECONDS)
        got = self._shell(["shell", "settings get global airplane_mode_on"]).strip()
        if got != want:
            # The toggle's own answer as well as the read-back. Below API 30
            # the service is not there and `cmd` says exactly that, while the
            # read-back reports a perfectly ordinary '0' -- so without this
            # the message describes the symptom and hides the cause. Both are
            # bounded: they are raw device text on their way to stdout.
            raise DriverError(
                f"airplane mode reads {got[:QUOTED_DEVICE_TEXT_CHARS]!r} after "
                f"asking for {want!r}: the cut did not take, so anything this "
                "cell measured is meaningless. The toggle said "
                f"{said.strip()[:QUOTED_DEVICE_TEXT_CHARS]!r}"
            )

    # -- the app process and the device --------------------------------------

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
        # Same deadline convention as `_poll`: with timeout=0 it looks once
        # and then gives up, which is how a test reaches the failure branch
        # without spending the wait.
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
        """HOME, wait, and bring the task back the way a shopper would.

        `monkey` with the LAUNCHER category, exactly as `launch()` uses --
        but WITHOUT the force-stop that precedes it there. That is the whole
        point: tapping the icon RESUMES the existing task with the SDK's
        PaymentActivity still on top of it, where `am start` on MainActivity
        would reorder the task and change what is being measured.

        Both halves are verified. A HOME that did not take would background
        nothing and the cell would report that the SDK survived something
        that never happened.
        """
        self._key(_KEYCODE_HOME)
        self._sleep(BACKGROUND_SETTLE_SECONDS)
        if self._foreground_package() == self.package:
            raise DriverError("the app is still in the foreground after HOME")
        self._sleep(seconds)
        self._shell(["shell", "monkey", "-p", self.package, "-c", _LAUNCHER, "1"])
        self._wait_foreground(self.package)
        self._sleep(BACKGROUND_SETTLE_SECONDS)

    def rotate(self) -> None:
        """A quarter turn, and it stays turned.

        Accelerometer rotation goes off first or the emulator's own sensor
        puts it straight back.

        What this actually exercises: the SDK's PaymentActivity declares no
        `android:configChanges` at all (sdk AndroidManifest.xml:12-15), so a
        rotation DESTROYS AND RECREATES it. The example app does the
        opposite -- its manifest lists orientation, screenSize and locale --
        so MainActivity absorbs the change and the plugin's
        onDetachedFromActivityForConfigChanges never fires. A rotation here
        measures the SDK's recreation, not the plugin's detach path.

        One consequence for cell authoring: the CVV field is a plain
        `remember`, not `rememberSaveable` (CardFormScreen.kt:91-95, citing
        PCI DSS 3.3.1), so rotating on the form clears it. Rotate after
        submitting, or retype.
        """
        self._shell(["shell", "settings put system accelerometer_rotation 0"])
        current = self._shell(["shell", "settings get system user_rotation"]).strip()
        target = "0" if current == "1" else "1"
        self._shell(["shell", f"settings put system user_rotation {target}"])
        self._sleep(ROTATE_SETTLE_SECONDS)

    def kill_activity(self) -> None:
        """Ends the app's process, sheet and all.

        `am force-stop`, not `am kill`: `am kill` only takes processes that
        are safe to kill, and this one is foreground with the SDK's activity
        on top, so it would do nothing at all and the cell would pass having
        killed nothing. What this stands in for is a low-memory kill -- the
        Dart isolate dies with the process and the pending call dies with it,
        which is the contract D3 exists to record. The verb's name is Phase
        0's; what it does is end the process.
        """
        self._shell(["shell", "am", "force-stop", self.package])
        self._sleep(SETTLE_SECONDS)

    def dont_keep_activities(self, on: bool) -> None:
        """The developer option, from the command line.

        With it on, MainActivity is destroyed the moment the SDK's
        PaymentActivity comes to the front, so the plugin's
        `onDetachedFromActivity` fires and finishes the pending call with
        `paycross_result_unknown` (PayCrossPlugin.kt:84-96) while the sheet
        is still up and the shopper can still pay. That code no longer reaches
        the merchant as an exception: Dart turns it into a pending result, so
        the label to look for is `result:pending:result_lost:`.

        Read back, because a setting that silently did not take would make
        the cell measure an ordinary payment. And left on it poisons every
        later cell, which is why `launch()` refuses to start while it is set.
        """
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
                # What was seen, not what it is blamed on: a caret bug and a
                # mistyped tap look identical from here.
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

        self._key(_KEYCODE_BACK)  # drop the IME so the Pay button is reachable
        self._sleep(SETTLE_SECONDS)

    def save_card(self, *, timeout: float = SAVE_BOX_TIMEOUT_SECONDS) -> None:
        """Makes sure the save-card box is ticked, and proves that it is.

        "Makes sure" rather than "taps": tapping a box that is already ticked
        UNticks it, and `TestCardPrefill.saveCard` pre-ticks it whenever a
        prefill is configured. A cell asking to save a card means the end
        state, not the gesture.

        The verification is the reason this is not two lines. A tap that lands
        beside the box -- on the label, which does nothing -- leaves the submit
        carrying `card.save: false`, so the payment succeeds, the cell reaches
        its label, and only `saved_card_saved` fails, twenty minutes later,
        against a merchant record that is telling the truth. Reading the state
        back turns that into a message naming the cause.

        This used to hunt the whole tree for anything two-state, because the
        SDK's checkbox carried no name and its caption was a separate,
        non-clickable sibling -- the label could not be tapped and the box
        could not be found. `paycross.saveCard` is on the `toggleable` Row that
        holds both, so one node now carries the identifier, the state and the
        click, and the search and its "which of these is the save box" guard
        are gone with it.
        """
        box = self._poll(
            lambda nodes: next(iter(tree.find_identifier(nodes, SAVE_CARD)), None),
            timeout,
            SETTLE_SECONDS,
        )
        if box is None:
            # Almost always the cell rather than the device: without
            # `save_card_config` on the session `canSaveCard` is false and the
            # box is never composed.
            raise DriverError(
                f"no {SAVE_CARD} on screen within {timeout}s: the session's "
                "options are missing save_card_config, or the form has not "
                "rendered"
            )
        if box.checked is None:
            # The identifier is there and the node under it is not two-state,
            # which means the tag moved off the toggleable row. Said out loud:
            # the tap below would otherwise land somewhere plausible and the
            # read-back would blame the tap.
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
        """Fills the CVV field and nothing else.

        The saved-card branch of the form is a prompt and one field
        (`CardFormScreen.SavedCardCvvInput`), so `type_card` cannot serve: its
        first act is to clear a card-number field that is not on this screen,
        and it would raise looking for it.

        The field itself is the same one -- both branches render `CvvField`,
        so `CVV` is one matcher rather than two. What differs is the
        validation behind it: the saved-card branch passes `CardType.UNKNOWN`,
        which is three digits whatever the stored card's brand is.

        No clearing pass. The field starts empty on this path, and a DEL sweep
        would be the one way to lose digits that are about to be asked for
        again.
        """
        self._tap_id(CVV)
        self._sleep(SETTLE_SECONDS)
        self._input_text(cvv)
        self._sleep(SETTLE_SECONDS)
        # The numeric pad covers the Pay button's bounds, and `tap_pay` taps a
        # centre rather than pressing a control -- behind the pad that lands on
        # a digit key. `type_card` ends the same way for the same reason.
        self._key(_KEYCODE_BACK)
        self._sleep(SETTLE_SECONDS)

    def tap_pay(self, amount_text: str) -> None:
        """Taps the sheet's Pay button. `amount_text` is not read.

        It used to be the whole matcher -- `Pay €10.00`, exact, because the
        button tagged nothing and its rendered text was the only handle. That
        is what made the `en-US` guard in `launch` necessary and what a French
        sheet would have broken. The parameter stays because the base class and
        the runner pass it on both platforms, and iOS ignores it for the same
        reason.
        """
        self._tap_id(PAY_BUTTON)

    def tap_google_pay(self, **kw) -> None:
        # Tapped by bounds and found by description, not by identifier: see
        # GOOGLE_PAY_DESC for why `paycross.walletButton` is not in the dump.
        # The node carrying the description is a non-clickable wrapper, because
        # the click handler lives on the AndroidView rather than on a Compose
        # node. `**kw` reaches `_find`'s timeout, exactly as `_tap_text` and
        # `_tap_desc` pass theirs -- the runner never uses it, and a test that
        # means to reach the deadline would otherwise spend thirty real seconds
        # getting there.
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
        """Waits for the sandbox ACS page without answering it.

        Any of `ACS_MARKERS` identifies it. See that constant for why this is
        a list rather than the single title it used to be.
        """
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
        """Chooses the first stored card, and proves the form switched.

        Three lines of matching where there used to be thirty, because the
        sheet is a different shape and publishes identifiers now.

        It is a **radio list**, not the `ExposedDropdownMenuBox` this drove
        until Train 2. There is no popup window to open, no collapsed text to
        read and no masked PAN to recognise by shape: every row is a
        `paycross.savedCard.<uuid>` node, tagged on the `selectable` Row
        itself, so the first of them is tapped where it stands.

        The verification is `paycross.cardNumber` going away while
        `paycross.cvv` stays. The two branches of the form are mutually
        exclusive, so the card-number field is present before the selection and
        gone after it -- and requiring the CVV field to still be there is what
        keeps that from also being satisfied by a form that failed to render at
        all. It replaces the old `Enter CVV for ` prompt check for one reason:
        that prompt is a rendered string and reads
        `Entrez le code de sécurité pour …` on a French sheet.

        Without this check a selection that silently failed would leave the
        cell typing its CVV into the FRESH form, submitting a blank card, and
        reporting a saved-card payment -- with `saved_card_used` the only
        assertion that would ever notice, an hour into a matrix run. So this
        raises rather than returns.
        """
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
        """Deletes the first stored card, and proves the row is gone.

        The proof is the point, and it is not theoretical. Train 2 measured
        exactly this path failing on TEST while looking like it had worked:
        confirming the dialog left the row on the sheet and put
        `Could not remove the card. Try again.` in the error banner, because
        the web API lacked the IAM grant to write the session blob back. A
        driver that tapped Confirm and moved on would have reported a removal
        that never happened.

        So the row's own identifier is read before the bin is tapped and waited
        out afterwards. It carries the card's uuid, which makes it exact: this
        is not "a row went away", it is "the row for the card whose bin was
        tapped went away".

        The dialog is its own window and a dump taken while it is up holds
        NOTHING ELSE -- not the picker, not the form. So "the row is not in the
        tree" is true of the dialog itself, and a check that asked only that
        would answer yes the instant Confirm was tapped, whatever the backend
        then did. The sheet has to be back first, which is what
        `paycross.payButton` says: it is on the form in every state, including
        the one where the last stored card has gone and the picker with it.
        """
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
        """Whether the sheet is offering a stored card.

        The list's presence is the whole predicate, because the SDK composes
        `SavedCardSelector` only under `if (savedCards.isNotEmpty())` -- there
        is no separate signal to read, and an empty list is not a state that
        exists.

        Answers False rather than raising, unlike `wait_acs`. "No stored card
        was offered" is a cell verdict -- the finding a D5 cell is there to
        make -- and a DriverError would be classified as a broken device and
        spend an interleaved control check proving a rig that was never in
        doubt. A device that will not dump *does* still raise, out of `_poll`:
        that is not the same answer.

        The default is the literal `runner.EXPECT_TIMEOUT_SECONDS` uses, and a
        test pins the pair equal.
        """
        found = self._poll(
            lambda nodes: next(iter(tree.find_identifier(nodes, SAVED_CARDS)), None),
            timeout,
            SETTLE_SECONDS,
        )
        return found is not None

    def acs(self, outcome: str) -> None:
        self.wait_acs()
        # The outcome is chosen by which button is tapped, not by the PAN.
        self._tap_text(outcome)

    def cancel_challenge(self) -> None:
        self.wait_acs()
        self._raise_cancel_dialog()
        self._tap_id(CANCEL_CONFIRM)

    def cancel_form(self) -> None:
        self._raise_cancel_dialog()
        self._tap_id(CANCEL_CONFIRM)

    def dismiss_cancel(self) -> None:
        """Raises the cancel dialog, backs out of it, and proves the form is back.

        The path a shopper takes when they nearly abandoned the payment and
        then did not. It is worth driving because it is the one dialog button
        no cell ever pressed: `cancel_form` and `cancel_challenge` both confirm,
        so `paycross.cancelDismiss` was shipped untested from this side.

        The last check is not decoration. The dialog is its own window and a
        dump taken while it is up holds only the dialog, so "the dialog closed"
        and "the sheet came back" are two different observations and only the
        second one says the cell can carry on paying.
        """
        self._raise_cancel_dialog()
        self._tap_id(CANCEL_DISMISS)
        self._sleep(SETTLE_SECONDS)
        self._find(
            tree.find_identifier, PAY_BUTTON, "the form after a dismissed cancel"
        )

    def _raise_cancel_dialog(self) -> None:
        """Back, then the dialog the SDK catches it with.

        Android's sheet has no cancel control of its own -- `paycross.cancel`
        is iOS-only -- so the gesture is the affordance and the dialog is the
        first thing here that can be named. `BackHandler` is unconditional on
        both screens (`PaymentActivity.kt`), so this reaches it from the form
        and from the challenge alike.
        """
        self._key(_KEYCODE_BACK)
        self._find(tree.find_identifier, CANCEL_DIALOG, "the cancel dialog", timeout=30)

    def wait_rearmed(
        self, amount_text: str, timeout: float, *, interval: float = 2
    ) -> bool:
        # A device that will not dump raises out of _poll rather than answering
        # False: "the sheet did not re-arm" is a cell verdict and this is not.
        found = self._poll(
            lambda nodes: tree.sheet_rearmed(nodes, amount_text) or None,
            timeout,
            interval,
        )
        if found is None:
            self._blame_the_amount(amount_text)
        return found is not None

    def _blame_the_amount(self, amount_text: str) -> None:
        """Raises when a re-arm failed only because the amount is spelled elsewise.

        The guard this replaces refused to launch on any locale but `en-US`,
        because the Pay button's rendered text was the driver's only handle.
        Nothing renders a handle any more -- but the amount is still computed in
        one region's spelling, so a French device turns a re-arm that happened
        into a cell reporting that it did not. That is a rig fault reading as an
        SDK finding, and this is where it gets named instead.
        """
        showing = tree.rearm_amount_mismatch(self._nodes(tolerate=True), amount_text)
        if showing is not None:
            raise DriverError(
                f"the sheet re-armed showing {showing!r} where this cell expects "
                f"{amount_text!r}: the device is not drawing amounts in the "
                "spelling `tree.format_amount_en_us` computes, so the re-arm "
                "check cannot answer. This is the rig, not the SDK."
            )

    def wait_google_pay(self, timeout: float = 30) -> bool:
        found = self._poll(
            lambda nodes: bool(tree.find_content_desc(nodes, GOOGLE_PAY_DESC)) or None,
            timeout,
            2,
        )
        return found is not None

    def wait_no_google_pay(self, timeout: float = 20) -> bool:
        """True only if the button is absent for the WHOLE window.

        Absence has to be waited out rather than waited for. Readiness is a
        LaunchedEffect that runs after the session loads and after an
        asynchronous isReadyToPay (PaymentActivity.kt), so a button that is
        merely late would satisfy a single look -- and this expectation would
        then pass on every session, which is the one thing it must never do.

        Written out rather than expressed through `_poll`, which answers as
        soon as its `look` finds something: here finding something is the
        answer False, and finding nothing has to keep going. Tolerating a
        refused dump while the deadline is live is the one rule it does share,
        because a device that will not dump is not a device with no button.
        """
        deadline = time.monotonic() + timeout
        while True:
            live = time.monotonic() < deadline
            if tree.find_content_desc(self._nodes(tolerate=live), GOOGLE_PAY_DESC):
                return False
            if not live:
                return True
            self._sleep(2)

    # -- evidence ------------------------------------------------------------

    def dump_tree(
        self, *, attempts: int = _DUMP_ATTEMPTS, interval: float = 1
    ) -> bytes:
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
        if attempts < 1:
            raise ValueError(f"attempts must be at least 1, got {attempts}")
        for attempt in range(attempts):
            # One round trip, so this stays two adb invocations: a dump that
            # never ran cannot leave the previous one behind to be read.
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
