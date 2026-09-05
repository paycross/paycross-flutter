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

CARD_NUMBER = "Card number input"
EXPIRY = "Expiry date input"
CVV = "CVV input"
CARDHOLDER = "Cardholder name input"
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
#: Rendered by Google Play services, not by the SDK -- so it moves with the
#: GMS version and with the device locale. The SDK's own testTag is invisible
#: to uiautomator because testTagsAsResourceId is never set; that is filed as
#: payment-android-sdk#26, and until it lands this is the only handle there
#: is. Confirmed
#: against this campaign's own dumps, most recently 2026-08-30.
GOOGLE_PAY_DESC = "Pay with GPay"

#: The `semantics { contentDescription = ... }` on the ExposedDropdownMenuBox
#: (SavedCardSelector.kt:35). Measured 2026-08-31: it DOES survive Compose's
#: semantics merging, as a non-clickable `android.view.View`, with a clickable
#: `android.widget.Spinner` at identical bounds carrying the collapsed text.
#: It is composed only when the session snapshot holds at least one stored
#: card, which is what makes its presence the whole `saved_card` predicate.
SAVED_CARD_SELECTOR = "Saved card selector"

#: The collapsed selector's text while nothing is chosen, and the menu row
#: that goes back to a fresh card. Neither SDK auto-selects a stored card
#: (PaymentSheet.swift:213-214, "auto-selecting a stored card is one
#: unnoticed tap from charging it"), so this is what the sheet opens showing.
NEW_CARD_ROW = "Use a new card"

#: CardFormScreen.kt:311 renders `Text("Enter CVV for ${savedCard?.maskedPan}")`
#: only on the saved-card branch, so this prefix appearing is the proof that
#: the form really switched. A prefix and not an exact match: the masked PAN
#: is part of the string and the driver has no way to know it.
SAVED_CARD_CVV_PROMPT = "Enter CVV for "

#: The shape the backend renders a stored card's PAN in -- six digits, a run of
#: asterisks, the last four (`411111******0000`, measured). Matched by SHAPE
#: because the driver cannot know which card a customer has stored.
#:
#: `fullmatch` and not `search`, deliberately: the COLLAPSED selector reads
#: `411111******0000 (12/2028)` once a card is chosen (`SavedCardSelector.kt:89`),
#: so a substring rule would re-find the selection it had just made and read a
#: no-op as a success.
_MASKED_PAN = re.compile(r"\d{6}\*+\d{4}")

CANCEL_TITLE = "Cancel Payment?"
CANCEL_CONFIRM = "Yes, Cancel"

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
        locale = self.getprop("ro.product.locale")
        if locale != "en-US":
            # The Pay button's text is the only handle the SDK gives, and it
            # is NumberFormat output under the device locale.
            raise DriverError(
                f"device locale is {locale!r}, expected 'en-US': the sheet's Pay "
                "button text would not match"
            )
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
        self._find(tree.find_content_desc, CARD_NUMBER, "the card form", timeout=60)

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
            self._tap_desc(field)
            self._sleep(SETTLE_SECONDS)
            self._key(_KEYCODE_MOVE_END)
            for _ in range(24):
                self._key(_KEYCODE_DEL)

        self._tap_desc(CARD_NUMBER)
        self._sleep(SETTLE_SECONDS)
        self._type_digits(card.pan)
        self._sleep(SETTLE_SECONDS)

        if verify_pan:
            nodes = self._nodes()
            if not any(n.text.replace(" ", "") == card.pan for n in nodes):
                # What was seen, not what it is blamed on: a caret bug and a
                # mistyped tap look identical from here.
                field = tree.find_content_desc(nodes, CARD_NUMBER)
                reads = field[0].text if field else None
                raise DriverError(
                    f"after typing {card.pan} the card number field reads {reads!r}"
                )

        for field, value in (
            (EXPIRY, card.expiry_digits),
            (CVV, card.cvv),
            (CARDHOLDER, card.holder),
        ):
            self._tap_desc(field)
            self._sleep(SETTLE_SECONDS)
            self._input_text(value)
            self._sleep(SETTLE_SECONDS)

        self._key(_KEYCODE_BACK)  # drop the IME so the Pay button is reachable
        self._sleep(SETTLE_SECONDS)

    def _checkboxes(self, nodes: list[tree.Node]) -> list[tree.Node]:
        """Every two-state control on screen.

        By state rather than by anything readable, because the SDK's save
        checkbox has nothing readable: it is a Compose `Checkbox` in a `Row`
        whose only sibling is a separate, non-clickable `Text`, so the node
        that toggles carries an empty `text` and an empty `content-desc`. Its
        `checkable` flag is the only handle it has, and `tree.Node.checked` is
        None for everything that is not one.
        """
        return [n for n in nodes if n.checked is not None]

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
        """
        found = self._poll(
            lambda nodes: self._checkboxes(nodes) or None,
            timeout,
            SETTLE_SECONDS,
        )
        if not found:
            # Almost always the cell rather than the device: without
            # `save_card_config` on the session `canSaveCard` is false and the
            # box is never composed.
            raise DriverError(
                "the save-card checkbox never appeared within "
                f"{timeout}s: the session's options are "
                "missing save_card_config, or the form has not rendered"
            )
        if len(found) > 1:
            # One today. Said out loud rather than silently taking the first,
            # because a field group gaining a checkbox would otherwise make
            # this tick an arbitrary one.
            raise DriverError(
                f"{len(found)} checkboxes on screen at "
                f"{[n.bounds for n in found]}; refusing to guess which one saves "
                "the card"
            )
        box = found[0]
        if box.checked:
            return

        self._tap(box.centre)
        self._sleep(SETTLE_SECONDS)

        after = self._poll(
            lambda nodes: next((n for n in self._checkboxes(nodes) if n.checked), None),
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
        self._tap_desc(CVV)
        self._sleep(SETTLE_SECONDS)
        self._input_text(cvv)
        self._sleep(SETTLE_SECONDS)
        # The numeric pad covers the Pay button's bounds, and `tap_pay` taps a
        # centre rather than pressing a control -- behind the pad that lands on
        # a digit key. `type_card` ends the same way for the same reason.
        self._key(_KEYCODE_BACK)
        self._sleep(SETTLE_SECONDS)

    def tap_pay(self, amount_text: str) -> None:
        self._tap_text(f"Pay {amount_text}")

    def tap_google_pay(self, **kw) -> None:
        # Tapped by bounds: the node carrying the description is a
        # non-clickable wrapper, because the click handler lives on the
        # AndroidView rather than on a Compose node. `**kw` reaches `_find`'s
        # timeout, exactly as `_tap_text` and `_tap_desc` pass theirs -- the
        # runner never uses it, and a test that means to reach the deadline
        # would otherwise spend thirty real seconds getting there.
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

        Three measured facts shape this (2026-08-31 dumps).

        The dropdown opens as **its own window**: the dump taken after the
        selector is tapped is 3.4 KB and holds only the popup -- the form
        behind it is not in the tree at all. So the row search runs against
        something that contains nothing else, which is why matching a PAN
        shape is safe here and would not be on the full sheet.

        The row's text sits on a **non-clickable** `TextView` inside a
        clickable `android.view.View`. Tapping the label nevertheless works,
        because it is a CHILD of the clickable row and the touch bubbles up --
        unlike the save checkbox, whose label is a SIBLING and where the same
        tap does nothing. That difference is why this is three lines and
        `save_card` is thirty.

        And the verification is the `Enter CVV for ` prompt rather than the
        absence of the card-number field. Both are true after a selection, but
        the prompt is the positive signal: it proves the saved-card branch
        actually rendered, where an absence would also be satisfied by a form
        that failed to render at all.
        """
        self._tap_desc(SAVED_CARD_SELECTOR, timeout=timeout)
        self._sleep(SETTLE_SECONDS)

        row = self._poll(
            lambda nodes: next(
                (n for n in nodes if _MASKED_PAN.fullmatch(n.text)), None
            ),
            timeout,
            SETTLE_SECONDS,
        )
        if row is None:
            raise DriverError(
                f"no stored-card row in the selector within {timeout}s: the "
                "session's options are missing saved_cards, or this customer "
                "has no stored card"
            )
        self._tap(row.centre)
        self._sleep(SETTLE_SECONDS)

        switched = self._poll(
            lambda nodes: next(
                (n for n in nodes if n.text.startswith(SAVED_CARD_CVV_PROMPT)),
                None,
            ),
            timeout,
            SETTLE_SECONDS,
        )
        if switched is None:
            raise DriverError(
                f"after tapping the stored card at {row.centre} the sheet is "
                f"still showing the new-card form ({SAVED_CARD_CVV_PROMPT!r} "
                "never appeared); the CVV would be typed into a fresh card and "
                "the payment would not use the stored one"
            )

    def wait_saved_card(self, timeout: float = 30) -> bool:
        """Whether the sheet is offering a stored card.

        The selector's presence is the whole predicate, because the SDK
        composes `SavedCardSelector` only under `if (savedCards.isNotEmpty())`
        (`CardFormScreen.kt:161`) -- there is no separate signal to read, and
        an empty selector is not a state that exists.

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
            lambda nodes: next(
                iter(tree.find_content_desc(nodes, SAVED_CARD_SELECTOR)), None
            ),
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
        self._confirm_cancel()

    def cancel_form(self) -> None:
        self._confirm_cancel()

    def _confirm_cancel(self) -> None:
        # BackHandler is unconditional on both screens (PaymentActivity.kt).
        self._key(_KEYCODE_BACK)
        self._find(tree.find_text_exact, CANCEL_TITLE, "the cancel dialog", timeout=30)
        self._tap_text(CANCEL_CONFIRM)

    def wait_rearmed(
        self, amount_text: str, timeout: float, *, interval: float = 2
    ) -> bool:
        # A device that will not dump raises out of _poll rather than answering
        # False: "the sheet did not re-arm" is a cell verdict and this is not.
        found = self._poll(
            lambda nodes: tree.sheet_rearmed(nodes, "android", amount_text) or None,
            timeout,
            interval,
        )
        return found is not None

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
