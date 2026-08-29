from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from tool.e2e.cells import Card
from tool.e2e.drivers import android
from tool.e2e.drivers.base import DriverError

FIXTURES = Path(__file__).parent / "fixtures"

#: Shaped like the real thing -- base64url segments joined by dots -- because
#: the driver now refuses anything that is not, and short enough to fit one
#: chunk so the stdin assertion can name it exactly.
TOKEN = "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJzYW5kYm94In0.c2lnbmF0dXJlLWJ5dGVz"


def screen(token: str = "") -> str:
    """The example's token screen, with the sheet's card form behind it.

    Assembled here rather than checked in: no real dump holds the example's
    own field and the sheet's form at once, and a `paste_token` run reads
    both. Bounds are nominal -- only the centres are used.
    """
    return (
        "<hierarchy>"
        f'<node class="android.widget.EditText" text="{token}" content-desc=""'
        ' bounds="[0,0][100,50]"/>'
        '<node class="android.view.View" text="" content-desc="Pay"'
        ' bounds="[0,60][100,100]"/>'
        '<node class="android.view.View" text="" content-desc="Card number input"'
        ' bounds="[0,110][100,150]"/>'
        "</hierarchy>"
    )


class FakeShell:
    """Records calls and replays canned stdout, so nothing runs.

    Outputs are given **as `_run` would return them** -- CRLF already
    normalised -- so a test never restates the transport's job; `_run` itself
    is covered directly against a stubbed `subprocess.run`.

    Explicit `outputs` are consumed in order. Once they run out a tree read
    gets `tree`, or the next of `trees` (the last one repeats), and everything
    else gets an empty string. That fallback is what lets a multi-step action
    be exercised without hand-counting round trips: `_tap` and `_key` consume
    one each while `dump_tree` consumes two, so a fixed `["", form] * n` list
    desynchronises after the first field.
    """

    def __init__(self, *outputs, tree=None, trees=None):
        self.outputs = list(outputs)
        self.tree = tree
        self.trees = list(trees) if trees else None
        self.calls = []
        self.stdins = []

    def __call__(self, argv, *, binary=False, stdin=None):
        self.calls.append(argv)
        self.stdins.append(stdin)
        if self.outputs:
            return self.outputs.pop(0)
        if binary:
            return b""
        if "cat" not in argv:
            return ""
        if self.trees:
            return self.trees.pop(0) if len(self.trees) > 1 else self.trees[0]
        return self.tree if self.tree is not None else ""

    def argv_text(self):
        return [" ".join(a) for a in self.calls]


def driver(shell, naps=None):
    """The driver under test, with every wait recorded instead of taken.

    The rig's real durations are still pinned -- by asserting on `naps` -- but
    the suite no longer spends 17 seconds of wall clock actually sleeping.
    """
    return android.AndroidDriver(
        shell=shell, sleep=(naps if naps is not None else []).append
    )


def staged_driver(shell, tmp_path, naps=None):
    return android.AndroidDriver(
        shell=shell,
        staging_dir=tmp_path / "winstage",
        windows_staging=r"D:\stage",
        sleep=(naps if naps is not None else []).append,
    )


# -- _run, the one place the transport is real --------------------------------


def _stub_subprocess(monkeypatch, stdout=b"", stderr=b"", returncode=0):
    seen = {}

    class Done:
        pass

    def fake_run(argv, **kwargs):
        seen["argv"] = argv
        seen["kwargs"] = kwargs
        done = Done()
        done.stdout, done.stderr, done.returncode = stdout, stderr, returncode
        return done

    monkeypatch.setattr(android.subprocess, "run", fake_run)
    return seen


def test_run_calls_the_windows_adb_and_normalises_every_line(monkeypatch):
    seen = _stub_subprocess(monkeypatch, stdout=b"one\r\ntwo\r\nthree")

    out = android._run(["shell", "getprop", "x"])

    assert seen["argv"] == [android.ADB, "shell", "getprop", "x"]
    assert seen["kwargs"]["timeout"] == 300
    assert seen["kwargs"]["capture_output"] is True
    # Replaced throughout, not stripped off the end: a dump is thousands of
    # lines and every one of them arrives with a CR.
    assert out == "one\ntwo\nthree"


def test_run_passes_binary_through_untouched(monkeypatch):
    png = b"\x89PNG\r\n\x1a\n\r\n"
    _stub_subprocess(monkeypatch, stdout=png)

    assert android._run(["exec-out", "screencap", "-p"], binary=True) == png


def test_run_surfaces_the_stderr_of_a_failed_adb(monkeypatch):
    # Discarding it was how an install failure could read as "no Success in
    # ''" instead of naming the ABI mismatch that actually happened.
    _stub_subprocess(
        monkeypatch, stdout=b"", stderr=b"adb: device offline\r\n", returncode=1
    )

    assert "device offline" in android._run(["install", "x"])


def test_run_refuses_to_return_binary_it_could_not_fetch(monkeypatch):
    # Appending stderr would corrupt a PNG, so the failure has to raise.
    _stub_subprocess(monkeypatch, stdout=b"", stderr=b"closed\r\n", returncode=1)

    with pytest.raises(DriverError) as excinfo:
        android._run(["exec-out", "screencap", "-p"], binary=True)

    assert "closed" in str(excinfo.value)


def test_run_hands_stdin_to_the_process_rather_than_the_command_line(monkeypatch):
    seen = _stub_subprocess(monkeypatch)

    android._run(["shell"], stdin="input text abc\n")

    assert seen["argv"] == [android.ADB, "shell"]
    assert seen["kwargs"]["input"] == b"input text abc\n"


# -- install ------------------------------------------------------------------


def test_install_stages_the_apk_where_the_windows_adb_can_read_it(tmp_path):
    apk = tmp_path / "app-debug.apk"
    apk.write_bytes(b"not really an apk")
    # uninstall, then install -- which must report Success or install() raises.
    shell = FakeShell("", "Success\n")
    d = staged_driver(shell, tmp_path)

    d.install(str(apk))

    # The APK really was copied, and adb was handed the *Windows* spelling.
    staged = tmp_path / "winstage" / "paycross-e2e.apk"
    assert staged.read_bytes() == b"not really an apk"
    text = shell.argv_text()
    assert any("uninstall com.paycross.paycross_flutter_example" in t for t in text)
    assert any(r"install D:\stage\paycross-e2e.apk" in t for t in text)


def test_install_reports_what_adb_actually_said(tmp_path):
    apk = tmp_path / "app-debug.apk"
    apk.write_bytes(b"x")
    failure = "adb: failed to install: INSTALL_FAILED_NO_MATCHING_ABIS\n"
    shell = FakeShell("", failure)

    with pytest.raises(DriverError) as excinfo:
        staged_driver(shell, tmp_path).install(str(apk))

    assert "INSTALL_FAILED_NO_MATCHING_ABIS" in str(excinfo.value)


def test_install_names_both_paths_when_the_apk_cannot_be_staged(tmp_path):
    missing = tmp_path / "never-built.apk"
    shell = FakeShell()

    with pytest.raises(DriverError) as excinfo:
        staged_driver(shell, tmp_path).install(str(missing))

    message = str(excinfo.value)
    assert str(missing) in message
    assert "paycross-e2e.apk" in message
    # The staging directory is created rather than assumed.
    assert (tmp_path / "winstage").is_dir()
    # Nothing was asked of the device once staging had failed.
    assert shell.calls == []


# -- launch -------------------------------------------------------------------


def test_launch_refuses_a_device_that_is_not_en_us():
    shell = FakeShell("1\n", "de-DE\n")

    with pytest.raises(DriverError) as excinfo:
        driver(shell).launch()

    assert "en-US" in str(excinfo.value)
    assert "de-DE" in str(excinfo.value)


def test_launch_force_stops_before_starting():
    shell = FakeShell("1\n", "en-US\n", "", "")
    naps = []

    driver(shell, naps).launch()

    text = shell.argv_text()
    assert any("force-stop com.paycross.paycross_flutter_example" in t for t in text)
    assert any("monkey -p com.paycross.paycross_flutter_example" in t for t in text)
    # Six real seconds on the rig, asserted here rather than spent.
    assert android.LAUNCH_SETTLE_SECONDS == 6
    assert naps == [6]


# -- typing -------------------------------------------------------------------


def test_type_pan_sends_one_keycode_per_digit():
    # KEYCODE_0 is 7, so "4111" is 11, 8, 8, 8.
    shell = FakeShell()

    driver(shell)._type_digits("4111")

    assert shell.argv_text() == [
        "shell input keyevent 11",
        "shell input keyevent 8",
        "shell input keyevent 8",
        "shell input keyevent 8",
    ]


def test_type_digits_paces_itself_so_the_formatter_can_keep_up():
    # fill-card-raw.sh slept 0.4 s after every keyevent, and that is the timing
    # the 0.3.2 caret fix was proven under. Typing flat out would let a
    # formatter that merely cannot keep up read as a returning caret bug --
    # a false finding against the SDK, which is the expensive direction.
    naps = []

    driver(FakeShell(), naps)._type_digits("4111")

    assert android.DIGIT_PACING_SECONDS == 0.4
    # One after each digit, last one included: that is what the seed did.
    assert naps == [0.4] * 4


def test_input_text_escapes_the_space_that_would_otherwise_split_the_argument():
    shell = FakeShell()

    driver(shell)._input_text("John Doe")

    assert shell.argv_text() == ["shell input text John%sDoe"]


def test_type_card_clears_then_fills_every_field():
    form = (FIXTURES / "android-rearmed.uix").read_text()
    # Every tree read returns the same form; typing is fire-and-forget.
    shell = FakeShell(tree=form)
    naps = []

    driver(shell, naps).type_card(
        Card(pan="4111111111170000", expiry="12/28", cvv="123"), verify_pan=False
    )

    text = " | ".join(shell.argv_text())
    assert "input keyevent 67" in text  # KEYCODE_DEL, clearing the field
    assert "shell input text 1228" in text
    assert "shell input text 123" in text
    assert "shell input text John%sDoe" in text
    # 17.4 s on the rig: eleven settling pauses and sixteen paced digits.
    assert naps.count(android.SETTLE_SECONDS) == 11
    assert naps.count(android.DIGIT_PACING_SECONDS) == 16
    assert sum(naps) == pytest.approx(17.4)


def test_verify_pan_reports_what_the_field_actually_reads():
    # One digit short of the PAN: what a caret bug leaves behind.
    form = (
        "<hierarchy>"
        '<node class="android.widget.EditText" text="4111 1111 1111 000"'
        ' content-desc="Card number input" bounds="[0,0][100,50]"/>'
        '<node class="android.view.View" text="" content-desc="Expiry date input"'
        ' bounds="[0,60][100,100]"/>'
        '<node class="android.view.View" text="" content-desc="CVV input"'
        ' bounds="[0,110][100,150]"/>'
        '<node class="android.view.View" text="" content-desc="Cardholder name input"'
        ' bounds="[0,160][100,200]"/>'
        "</hierarchy>"
    )

    with pytest.raises(DriverError) as excinfo:
        driver(FakeShell(tree=form)).type_card(
            Card(pan="4111111111170000", expiry="12/28", cvv="123")
        )

    message = str(excinfo.value)
    assert "4111 1111 1111 000" in message
    # What was seen, not what it is blamed on: the cause is Task 10's to find.
    assert "formatter" not in message


# -- paste_token --------------------------------------------------------------


def test_paste_token_refuses_an_empty_token_file(tmp_path):
    path = tmp_path / "token"
    path.write_text("   \n")
    shell = FakeShell()

    with pytest.raises(DriverError) as excinfo:
        driver(shell).paste_token(path)

    assert "empty" in str(excinfo.value)
    assert shell.calls == []


def test_paste_token_refuses_something_that_is_not_shaped_like_a_token(tmp_path):
    # adb re-splits what it is handed, on the host and again on the device, so
    # anything but base64url-and-dots is a command rather than a credential.
    path = tmp_path / "token"
    path.write_text("not a token; rm -rf /sdcard")
    shell = FakeShell()

    with pytest.raises(DriverError) as excinfo:
        driver(shell).paste_token(path)

    message = str(excinfo.value)
    assert "JWT" in message
    # The value is never echoed, whatever it turned out to be.
    assert "rm -rf" not in message
    assert shell.calls == []


def test_paste_token_sends_the_token_on_stdin_never_in_an_argv(tmp_path):
    path = tmp_path / "token"
    path.write_text(TOKEN)
    shell = FakeShell(tree=screen(TOKEN))

    driver(shell).paste_token(path)

    # A command line is world-readable for as long as the process lives.
    assert not any(TOKEN in " ".join(argv) for argv in shell.calls)
    carried = [(argv, s) for argv, s in zip(shell.calls, shell.stdins) if s]
    assert len(carried) == 1
    assert carried[0] == (["shell"], f"input text {TOKEN}\n")


def test_paste_token_waits_for_the_field_to_agree_with_the_file(tmp_path):
    path = tmp_path / "token"
    path.write_text(TOKEN)
    # The find, then a read that catches the field mid-entry, then agreement.
    shell = FakeShell(
        trees=[screen(TOKEN[:10]), screen(TOKEN[:10]), screen(TOKEN)]
    )

    driver(shell).paste_token(path)  # a single early read would have raised


def test_paste_token_reports_a_paste_that_never_agreed(tmp_path, monkeypatch):
    monkeypatch.setattr(android, "TOKEN_READBACK_SECONDS", 0)
    path = tmp_path / "token"
    path.write_text(TOKEN)
    shell = FakeShell(tree=screen(TOKEN[:10]))

    with pytest.raises(DriverError) as excinfo:
        driver(shell).paste_token(path)

    message = str(excinfo.value)
    assert "10" in message and str(len(TOKEN)) in message
    # A truncated paste presents as an instant 401, so it is named here and
    # not left to look like an SDK bug -- without echoing the token.
    assert TOKEN not in message


def test_a_find_with_no_needle_does_not_say_it_was_looking_for_nothing():
    d = driver(FakeShell(tree="<hierarchy></hierarchy>"))

    with pytest.raises(DriverError) as excinfo:
        d._find(lambda nodes, _: [], "", "the token field", timeout=0)

    assert str(excinfo.value) == "the token field never appeared within 0s"


# -- logs, screenshots, dumps -------------------------------------------------


def test_logs_since_takes_its_cutoff_from_the_device_not_the_host():
    # logcat's -v time stamps, and therefore -t, are in the DEVICE's zone.
    # The emulator runs Europe/Kiev while run_cell hands the driver UTC, so
    # formatting the UTC value here asks for a three-hour window: measured at
    # 110,082 lines against 2,187 for the correct cutoff.
    shell = FakeShell("08-28 18:24:27.000\n", "08-28 18:24:28.000 I x: y\n")
    when = datetime.now(timezone.utc) - timedelta(seconds=60)

    driver(shell).logs_since(when)

    asked, fetched = shell.argv_text()
    assert asked.startswith("shell date -d @$(( $(date +%s) - 6")
    # Quoted as ONE argument: the device shell re-splits on spaces and toybox
    # date then answers "Max 1 argument".
    assert "'+%m-%d %H:%M:%S.000'" in asked
    # The device's own answer goes through verbatim; nothing is reformatted.
    assert fetched == "logcat -d -v time -t 08-28 18:24:27.000"


def test_logs_since_refuses_a_cutoff_the_device_could_not_produce():
    # An empty or error cutoff would make logcat return nothing, and criterion
    # 3 would then pass on an empty log -- the worse of the two failures.
    shell = FakeShell('date: Max 1 argument (see "date --help")\n')

    with pytest.raises(DriverError) as excinfo:
        driver(shell).logs_since(datetime.now(timezone.utc))

    assert "cutoff" in str(excinfo.value)


def test_screenshot_is_read_as_binary_and_not_line_ending_mangled():
    png = b"\x89PNG\r\n\x1a\n\r\n"
    shell = FakeShell(png)

    assert driver(shell).screenshot() == png
    assert shell.calls[0] == ["exec-out", "screencap", "-p"]


def test_dump_tree_returns_the_device_xml():
    xml = (FIXTURES / "android-rearmed.uix").read_bytes()
    shell = FakeShell("", xml.decode())

    assert driver(shell).dump_tree() == xml


def test_dump_tree_clears_the_stale_dump_in_the_same_round_trip():
    # `uiautomator dump` writes nothing when it cannot get an idle state. If
    # the previous file survived, `cat` would hand back a stale tree that
    # parses perfectly and the caller would tap a screen that is already gone.
    xml = (FIXTURES / "android-rearmed.uix").read_text()
    shell = FakeShell("", xml)

    driver(shell).dump_tree()

    dumped, fetched = shell.argv_text()
    assert dumped == "shell rm -f /sdcard/ui.xml; uiautomator dump /sdcard/ui.xml"
    assert fetched == "shell cat /sdcard/ui.xml"


def test_dump_tree_retries_a_read_that_came_back_unparsable():
    # A partly-flushed `cat` raises ParseError out of _nodes -- which is not a
    # DriverError, so it escapes every polling loop and aborts the cell for one
    # transient read.
    good = (FIXTURES / "android-rearmed.uix").read_text()
    shell = FakeShell("", "<hierarchy><node ", "", good)

    assert driver(shell).dump_tree(interval=0) == good.encode("utf-8")


def test_dump_tree_gives_up_as_a_driver_error_carrying_what_it_saw():
    shell = FakeShell(*(["ERROR: could not get idle state.\n", "no such file"] * 3))

    with pytest.raises(DriverError) as excinfo:
        driver(shell).dump_tree(attempts=3, interval=0)

    message = str(excinfo.value)
    # Both halves: what uiautomator said, and what came back off the disk.
    assert "could not get idle state" in message
    assert "no such file" in message


# -- the polling waits --------------------------------------------------------


def test_wait_rearmed_polls_until_the_banner_appears():
    empty = "<hierarchy></hierarchy>"
    rearmed = (FIXTURES / "android-rearmed.uix").read_text()
    shell = FakeShell("", empty, "", rearmed)

    assert driver(shell).wait_rearmed("€10.00", timeout=30, interval=0) is True


def test_wait_rearmed_gives_up_and_says_so():
    shell = FakeShell(*(["", "<hierarchy></hierarchy>"] * 3))

    assert driver(shell).wait_rearmed("€10.00", timeout=0, interval=0) is False


def test_wait_label_returns_the_contract_label():
    tree_xml = (FIXTURES / "android-result.uix").read_text()
    shell = FakeShell("", tree_xml)

    # The fixture predates the contract, so ask for the legacy prefix set --
    # this is the same code path the real cells take.
    label = driver(shell).wait_label(
        timeout=10, interval=0, prefixes=("Paid ", "result:")
    )

    assert label.startswith("Paid 1000 EUR")


def test_a_wait_rides_out_a_device_that_will_not_dump():
    # uiautomator refuses while the UI animates, which is exactly what it is
    # doing during the waits that matter -- the 120 s ACS wait, the 60 s sheet
    # wait. Three refusals in a row must not end a cell that still has 10 s of
    # its own deadline left; the poll's next round gets a clean tree.
    refused = ["", ""] * 3  # one whole dump_tree's worth of attempts
    tree_xml = (FIXTURES / "android-result.uix").read_text()
    shell = FakeShell(*refused, "", tree_xml)

    label = driver(shell).wait_label(
        timeout=10, interval=0, prefixes=("Paid ", "result:")
    )

    assert label.startswith("Paid 1000 EUR")


def test_a_wait_past_its_deadline_blames_the_dump_not_the_missing_node():
    # Once the deadline is gone the tolerance goes with it, so the error names
    # the device rather than reporting a node that was never looked for.
    shell = FakeShell(*(["", ""] * 3))

    with pytest.raises(DriverError) as excinfo:
        driver(shell).wait_label(timeout=0, interval=0)

    assert "dump" in str(excinfo.value)


def test_wait_label_timing_out_raises_rather_than_returning_none():
    shell = FakeShell(*(["", "<hierarchy></hierarchy>"] * 3))

    with pytest.raises(DriverError) as excinfo:
        driver(shell).wait_label(timeout=0, interval=0)

    assert "label" in str(excinfo.value)


def test_tapping_an_empty_needle_is_refused_rather_than_matching_every_node():
    # find_text_exact("") matches every node whose text is empty, which is most
    # of a real tree, so the tap would land on an arbitrary one.
    shell = FakeShell(tree=(FIXTURES / "android-rearmed.uix").read_text())
    d = driver(shell)

    for call in (lambda: d._tap_text(""), lambda: d._tap_desc("")):
        with pytest.raises(DriverError):
            call()

    assert shell.calls == []


def test_the_d3_actions_are_declared_and_refuse_rather_than_no_op():
    d = driver(FakeShell())

    for call in (lambda: d.background(5), d.rotate, lambda: d.airplane(True), d.kill_activity):
        with pytest.raises(NotImplementedError):
            call()
