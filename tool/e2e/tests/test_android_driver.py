import importlib
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from tool.e2e import cells
from tool.e2e.cells import Card
from tool.e2e.drivers import android, base
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


def test_run_turns_a_timeout_into_a_driver_error(monkeypatch):
    # An emulator that has wedged raises TimeoutExpired out of subprocess,
    # which is not a DriverError -- so it escapes every polling loop and ends
    # the whole matrix where it should have failed one cell.
    def explode(argv, **kwargs):
        raise android.subprocess.TimeoutExpired(argv, android.RUN_TIMEOUT_SECONDS)

    monkeypatch.setattr(android.subprocess, "run", explode)

    with pytest.raises(DriverError) as excinfo:
        android._run(["shell", "getprop", "sys.boot_completed"])

    message = str(excinfo.value)
    assert "shell" in message
    assert str(android.RUN_TIMEOUT_SECONDS) in message


def test_run_turns_a_missing_adb_into_a_driver_error(monkeypatch):
    # adb.exe lives on the Windows side of a mount that is not always there.
    def explode(argv, **kwargs):
        raise FileNotFoundError(2, "No such file or directory", android.ADB)

    monkeypatch.setattr(android.subprocess, "run", explode)

    with pytest.raises(DriverError) as excinfo:
        android._run(["devices"])

    assert "devices" in str(excinfo.value)


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


def test_launch_quotes_adb_when_the_boot_check_cannot_be_read():
    # With no device attached, getprop's "answer" is adb's own complaint.
    # Reading that as "not 1" reported an emulator part-way through booting
    # when the truth was that there was no emulator to talk to.
    shell = FakeShell("adb: no devices/emulators found\n")

    with pytest.raises(DriverError) as excinfo:
        driver(shell).launch()

    message = str(excinfo.value)
    assert "no devices/emulators found" in message
    assert "booting" not in message


def test_launch_quotes_adb_when_the_locale_cannot_be_read():
    shell = FakeShell("1\n", "error: device offline\n")

    with pytest.raises(DriverError) as excinfo:
        driver(shell).launch()

    message = str(excinfo.value)
    assert "device offline" in message
    # And not dressed up as though adb's sentence were a locale.
    assert "expected 'en-US'" not in message


def test_launch_still_says_booting_when_the_property_is_merely_unset():
    # A device that is up but mid-boot answers with nothing at all, which is
    # a different thing from adb being unable to ask.
    shell = FakeShell("\n")

    with pytest.raises(DriverError) as excinfo:
        driver(shell).launch()

    assert "booting" in str(excinfo.value)


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
    # The shape check is shared with iOS; the verb is this transport's own
    # word, so the message still says what was about to happen.
    assert "Refusing to type it" in message
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
    carried = [
        (argv, s) for argv, s in zip(shell.calls, shell.stdins, strict=True) if s
    ]
    assert len(carried) == 1
    assert carried[0] == (["shell"], f"input text {TOKEN}\n")


def test_paste_token_chunks_a_long_token_and_loses_nothing(tmp_path):
    # The real token is ~1011 characters, well past what one `input text`
    # delivers. Chunking is only safe if the pieces reassemble exactly, and
    # nothing downstream would notice a dropped character except as a 401.
    long_token = ".".join("x" * 70 for _ in range(3))
    assert len(long_token) > android.TOKEN_CHUNK_CHARS
    path = tmp_path / "token"
    path.write_text(long_token)
    shell = FakeShell(tree=screen(long_token))

    driver(shell).paste_token(path)

    script = next(s for s in shell.stdins if s)
    lines = script.splitlines()
    wanted = -(-len(long_token) // android.TOKEN_CHUNK_CHARS)
    assert len(lines) == wanted == 3
    assert all(line.startswith("input text ") for line in lines)
    assert "".join(ln.removeprefix("input text ") for ln in lines) == long_token


def test_paste_token_waits_for_the_field_to_agree_with_the_file(tmp_path):
    path = tmp_path / "token"
    path.write_text(TOKEN)
    # The find, then a read that catches the field mid-entry, then agreement.
    shell = FakeShell(trees=[screen(TOKEN[:10]), screen(TOKEN[:10]), screen(TOKEN)])

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


def test_close_is_a_no_op_for_a_driver_with_nothing_to_release():
    # Concrete on the ABC rather than abstract: only iOS holds anything across
    # a cell, and Task 9 calls this in a finally for both.
    shell = FakeShell()

    assert driver(shell).close() is None
    assert shell.calls == []


def test_the_d3_actions_are_declared_and_refuse_rather_than_no_op():
    # `airplane` is no longer among them: D2 needs a real network cut, and
    # this driver implements one. The rest still belong to D3.
    d = driver(FakeShell())

    for call in (
        lambda: d.background(5),
        d.rotate,
        d.kill_activity,
    ):
        with pytest.raises(NotImplementedError):
            call()


def test_a_wait_that_times_out_on_a_legacy_label_names_the_missing_define():
    # The expensive failure this replaces: a build made without
    # --dart-define=PAYCROSS_E2E=true renders "Paid 1000 EUR - ..." instead of
    # "result:success:<txn>", so wait_result spends its whole 180 s and then
    # reports "no contract label", which reads as an SDK hang. The screen was
    # showing the answer the entire time.
    shell = FakeShell(tree=(FIXTURES / "android-result.uix").read_text())

    with pytest.raises(DriverError) as excinfo:
        driver(shell).wait_label(timeout=0, interval=0)

    assert "PAYCROSS_E2E" in str(excinfo.value)


def test_a_wait_that_times_out_on_nothing_at_all_does_not_blame_the_build():
    # The diagnosis has to be earned: an empty screen is not a wrong build.
    shell = FakeShell(tree="<hierarchy></hierarchy>")

    with pytest.raises(DriverError) as excinfo:
        driver(shell).wait_label(timeout=0, interval=0)

    assert "PAYCROSS_E2E" not in str(excinfo.value)


def test_the_rig_paths_are_overridable_from_the_environment(monkeypatch):
    # Every constant here is one workstation's. A second rig -- a nightly
    # runner, another laptop -- must not need a fork of this file.
    monkeypatch.setenv("PAYCROSS_E2E_ADB", "/opt/android/adb")
    monkeypatch.setenv("PAYCROSS_E2E_STAGING_DIR", "/mnt/d/stage")
    monkeypatch.setenv("PAYCROSS_E2E_WINDOWS_STAGING", r"D:\stage")
    try:
        importlib.reload(android)
        assert android.ADB == "/opt/android/adb"
        assert android.STAGING_DIR == "/mnt/d/stage"
        assert android.WINDOWS_STAGING == r"D:\stage"
    finally:
        monkeypatch.undo()
        importlib.reload(android)


def test_the_rig_paths_fall_back_to_this_workstation():
    assert android.ADB.endswith("adb.exe")
    assert android.STAGING_DIR == "/mnt/c/dev/tmp"
    assert android.WINDOWS_STAGING == r"C:\dev\tmp"


# --- Plan B: the Driver contract is enforced at construction --------------


def test_a_driver_that_skips_super_init_has_no_package_at_all():
    # Bare annotations let a driver forget one and fail mid-run instead.
    class Forgetful(base.Driver):
        _parse_dump = staticmethod(lambda dump: [])

        def __init__(self):
            pass

        install = launch = paste_token = type_card = tap_pay = lambda *a, **k: None
        wait_label = acs = cancel_challenge = cancel_form = lambda *a, **k: None
        wait_rearmed = dump_tree = screenshot = logs_since = lambda *a, **k: None

    with pytest.raises(AttributeError, match="package"):
        # The access is the assertion: nothing set the attribute.
        assert Forgetful().package


def test_the_android_driver_exposes_what_it_was_constructed_with():
    slept = []
    made = android.AndroidDriver(shell=FakeShell(), sleep=slept.append)

    assert made.package == android.PACKAGE
    made._sleep(1.5)
    assert slept == [1.5]


# --- Plan B: watching for a label that must not arrive --------------------


def test_wait_no_label_hands_back_the_label_that_appeared():
    # Naming it means the failure says what showed up, not only that
    # something did.
    resolved = (
        "<hierarchy>"
        '<node class="android.view.View" text=""'
        ' content-desc="result:success:txn-1" bounds="[0,0][100,50]"/>'
        "</hierarchy>"
    )
    shell = FakeShell(tree=resolved)

    assert driver(shell).wait_no_label(0) == "result:success:txn-1"


def test_wait_no_label_answers_none_when_the_app_said_nothing():
    # The Android process-kill cell's pass: the pending Dart call dies with
    # the isolate and no result is delivered, by design.
    shell = FakeShell(tree=screen())

    assert driver(shell).wait_no_label(0) is None


def test_relaunch_on_android_is_exactly_launch():
    # Nothing on this side is truncated by a launch, so there is nothing for a
    # relaunch to preserve. The base implementation is the whole answer.
    # Two launches' worth: FakeShell pops one output per call, and a launch
    # spends five -- boot, locale, airplane, force-stop, monkey.
    shell = FakeShell("1\n", "en-US\n", "0\n", "", "", "1\n", "en-US\n", "0\n", "", "")
    made = driver(shell)

    made.launch()
    launched = list(shell.calls)
    shell.calls.clear()
    made.relaunch()

    assert shell.calls == launched


# --- Plan B: the four actions with no unit coverage on this side ----------
#
# The iOS driver has the equivalents; the asymmetry was an accident, not a
# decision. Each one asserts the exact `input tap X Y` argv, so a matcher that
# starts finding the wrong node is caught here rather than on a device.


def sheet(*rows: tuple[str, str, str]) -> str:
    """A tree of `(text, content-desc, bounds)` nodes and nothing else."""
    return (
        "<hierarchy>"
        + "".join(
            f'<node class="android.view.View" text="{text}" content-desc="{desc}"'
            f' bounds="{bounds}"/>'
            for text, desc, bounds in rows
        )
        + "</hierarchy>"
    )


def taps(shell):
    return [c for c in shell.argv_text() if c.startswith("shell input tap")]


def test_tap_pay_taps_the_sheets_own_pay_button_and_not_the_examples():
    # The example's own Pay is a content-desc; the sheet's is Compose `text`
    # carrying the formatted amount. Matching the wrong one cost the
    # 2026-08-26 run a false 270-second timeout.
    shell = FakeShell(
        tree=sheet(
            ("€10.00", "", "[0,0][100,40]"),
            ("Pay €10.00", "", "[0,60][100,100]"),
            ("", "Pay", "[0,120][100,160]"),
        )
    )

    driver(shell).tap_pay("€10.00")

    assert taps(shell) == ["shell input tap 50 80"]


def test_acs_waits_for_the_sandbox_page_before_it_taps_an_outcome():
    shell = FakeShell(
        tree=sheet(
            (android.ACS_TITLE, "", "[0,0][100,40]"),
            ("approve", "", "[0,200][100,240]"),
            ("authentication_failed", "", "[0,260][100,300]"),
        )
    )

    driver(shell).acs("authentication_failed")

    # The outcome is chosen by which button is tapped, never by the PAN.
    assert taps(shell) == ["shell input tap 50 280"]


def test_cancel_challenge_backs_out_of_the_acs_page_then_confirms():
    shell = FakeShell(
        trees=[
            sheet((android.ACS_TITLE, "", "[0,0][100,40]")),
            sheet(
                (android.CANCEL_TITLE, "", "[0,300][100,340]"),
                (android.CANCEL_CONFIRM, "", "[0,400][100,440]"),
            ),
        ]
    )

    driver(shell).cancel_challenge()

    assert "shell input keyevent 4" in shell.argv_text()
    assert taps(shell) == ["shell input tap 50 420"]


def test_cancel_form_confirms_without_waiting_for_the_acs_page():
    # BackHandler is unconditional on both screens (PaymentActivity.kt), and
    # the card form is not the ACS page -- so this one must not look for it.
    shell = FakeShell(
        tree=sheet(
            (android.CANCEL_TITLE, "", "[0,300][100,340]"),
            (android.CANCEL_CONFIRM, "", "[0,400][100,440]"),
        )
    )

    driver(shell).cancel_form()

    assert "shell input keyevent 4" in shell.argv_text()
    assert taps(shell) == ["shell input tap 50 420"]
    assert not any(android.ACS_TITLE in c for c in shell.argv_text())


# -- present_token, tap_example_pay, enter_token -------------------------------


def token_screen_without_the_form(token: str) -> str:
    """The example's own screen: its field and its Pay, and no sheet behind it.

    What a cell using `present_token` actually sees. The SDK is expected to
    refuse the token, so the card form is never going to appear -- which is
    the one thing `screen()` above cannot say, since it always carries one.
    """
    return (
        "<hierarchy>"
        f'<node class="android.widget.EditText" text="{token}" content-desc=""'
        ' bounds="[0,0][100,50]"/>'
        '<node class="android.view.View" text="" content-desc="Pay"'
        ' bounds="[0,60][100,100]"/>'
        "</hierarchy>"
    )


def test_present_token_does_not_wait_for_a_card_form_that_will_never_come(tmp_path):
    # `paste_token` ends by giving the sheet 60 s. For a token the SDK is
    # expected to refuse there is no sheet coming, so that wait spends a
    # minute and then reports "the card form never appeared" instead of the
    # label the app has been showing the whole time.
    path = tmp_path / "token"
    path.write_text(TOKEN)
    shell = FakeShell(tree=token_screen_without_the_form(TOKEN))

    driver(shell).present_token(path)

    # The example's Pay is the last thing it does; nothing waits after it.
    assert taps(shell)[-1] == "shell input tap 50 80"
    assert shell.calls[-1] == ["shell", "input", "tap", "50", "80"]


def test_present_token_enters_the_token_exactly_as_paste_token_does(tmp_path):
    path = tmp_path / "token"
    path.write_text(TOKEN)
    shell = FakeShell(tree=token_screen_without_the_form(TOKEN))

    driver(shell).present_token(path)

    carried = [
        (argv, s) for argv, s in zip(shell.calls, shell.stdins, strict=True) if s
    ]
    assert carried == [(["shell"], f"input text {TOKEN}\n")]
    assert not any(TOKEN in " ".join(argv) for argv in shell.calls)


def test_present_token_still_refuses_something_that_is_not_a_token(tmp_path):
    path = tmp_path / "token"
    path.write_text("not a token; rm -rf /sdcard")
    shell = FakeShell()

    with pytest.raises(DriverError, match="JWT"):
        driver(shell).present_token(path)

    assert shell.calls == []


def test_tap_example_pay_matches_the_content_desc_not_the_sheets_text():
    # A Flutter widget surfaces as content-desc with an empty text, and the
    # SDK's own Compose Pay does the opposite.
    shell = FakeShell(
        tree=sheet(
            ("Pay €10.00", "", "[0,0][100,40]"),
            ("", "Pay", "[0,60][100,100]"),
        )
    )

    driver(shell).tap_example_pay()

    assert taps(shell) == ["shell input tap 50 80"]


def test_enter_token_types_the_literal_verbatim():
    shell = FakeShell(tree=screen())

    driver(shell).enter_token("not.a.real.token")

    assert "shell input text not.a.real.token" in shell.argv_text()


def test_enter_token_never_reads_a_file(tmp_path):
    # Deliberately not through `read_token`: what the SDK does with something
    # that is *not* a credential is the whole point of the cells that use
    # this. A literal that looks like a path is typed, not opened.
    missing = str(tmp_path / "absent.token")
    shell = FakeShell(tree=screen())

    driver(shell).enter_token(missing)

    assert f"shell input text {missing}" in shell.argv_text()


def test_enter_token_takes_a_literal_that_paste_token_would_refuse(tmp_path):
    # `paste_token` refuses anything that is not JWT-shaped, because a mint
    # that answered with an error document would otherwise be typed as though
    # it were a credential. `enter_token` exists to type exactly that.
    path = tmp_path / "token"
    path.write_text("short")
    shell = FakeShell(tree=screen())

    with pytest.raises(DriverError, match="JWT"):
        driver(shell).paste_token(path)

    driver(FakeShell(tree=screen())).enter_token("short")


# -- airplane -----------------------------------------------------------------


def test_airplane_cuts_the_network_and_reads_the_setting_back():
    shell = FakeShell("", "1\n")
    naps = []

    driver(shell, naps).airplane(True)

    assert shell.argv_text() == [
        "shell cmd connectivity airplane-mode enable",
        "shell settings get global airplane_mode_on",
    ]
    assert naps == [android.AIRPLANE_SETTLE_SECONDS]


def test_airplane_off_asks_for_disable_and_expects_zero():
    shell = FakeShell("", "0\n")

    driver(shell).airplane(False)

    assert shell.argv_text() == [
        "shell cmd connectivity airplane-mode disable",
        "shell settings get global airplane_mode_on",
    ]


def test_airplane_refuses_a_cut_that_did_not_take():
    # `cmd connectivity` rather than `settings put` plus a broadcast: that
    # broadcast needs a system permission, and without it the setting flips
    # while the radios stay up -- so a cell would report that the SDK
    # "survived a network cut" having measured nothing at all.
    shell = FakeShell("", "0\n")

    with pytest.raises(DriverError) as excinfo:
        driver(shell).airplane(True)

    assert "meaningless" in str(excinfo.value)


def test_launch_refuses_a_device_a_previous_cell_left_in_airplane_mode():
    # Neither a failure nor an exception turns it off again, and every cell
    # after it would fail for that reason while looking like an SDK finding.
    shell = FakeShell("1\n", "en-US\n", "1\n")

    with pytest.raises(DriverError) as excinfo:
        driver(shell).launch()

    message = str(excinfo.value)
    assert "airplane mode" in message
    assert "airplane-mode disable" in message
    # Nothing was started: the interleaved control fails here too, which is
    # exactly right -- this is a rig fault.
    assert not any("monkey" in c for c in shell.argv_text())


# -- wait_acs -----------------------------------------------------------------


def test_wait_acs_waits_for_the_page_without_answering_it():
    shell = FakeShell(
        tree=sheet(
            (android.ACS_TITLE, "", "[0,0][100,40]"),
            ("approve", "", "[0,200][100,240]"),
        )
    )

    assert driver(shell).wait_acs(timeout=5) is True
    assert taps(shell) == []


def test_wait_acs_says_which_page_never_came():
    shell = FakeShell(tree=sheet(("something else", "", "[0,0][100,40]")))

    with pytest.raises(DriverError) as excinfo:
        driver(shell).wait_acs(timeout=0)

    assert "sandbox ACS page" in str(excinfo.value)


# -- the vocabulary that later dimensions fill in ------------------------------


#: Everything `cells.py` accepts today whose driver method belongs to a later
#: dimension, with the arguments `runner._perform` calls it with. Declared on
#: `Driver` and raising, rather than simply absent: `run_cell` reads
#: NotImplementedError as a cell-authoring fault and spends no control check on
#: it, where an AttributeError reads as a device problem -- and two of those in
#: a row abort a forty-minute matrix as a rig fault.
NOT_LANDED_YET = [
    ("background", (5,)),
    ("rotate", ()),
    ("kill_activity", ()),
    ("dont_keep_activities", (True,)),
    ("type_cvv", ("123",)),
    ("tap_google_pay", ()),
    ("select_saved_card", ()),
    ("save_card", ()),
    ("wait_google_pay", (30,)),
    ("wait_no_google_pay", (20,)),
    ("wait_saved_card", (30,)),
]


@pytest.mark.parametrize("name, args", NOT_LANDED_YET)
def test_a_verb_or_predicate_from_a_later_dimension_refuses(name, args):
    d = driver(FakeShell())

    with pytest.raises(NotImplementedError):
        getattr(d, name)(*args)


def test_every_expectation_reaches_a_driver_attribute():
    # `EXPECTATIONS` is what a cell author may write and this is what the
    # runner will call, so the two cannot be allowed to drift: an expectation
    # with no method behind it raises AttributeError, which the runner reads
    # as a broken device rather than as the authoring mistake it is.
    for expectation in cells.EXPECTATIONS:
        method = (
            "wait_no_label" if expectation == "no_result" else f"wait_{expectation}"
        )
        assert hasattr(driver(FakeShell()), method), expectation
