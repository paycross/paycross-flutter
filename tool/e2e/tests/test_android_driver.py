from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from tool.e2e.cells import Card
from tool.e2e.drivers import android
from tool.e2e.drivers.base import DriverError

FIXTURES = Path(__file__).parent / "fixtures"


class FakeShell:
    """Records argv lists and replays canned stdout, so nothing runs.

    Explicit outputs are consumed in order; once they run out a tree read gets
    `tree` and everything else gets an empty string. That fallback is what lets
    a multi-step action be exercised without hand-counting how many round trips
    it happens to make -- `_tap` and `_key` consume one each while `dump_tree`
    consumes two, so a fixed `["", form] * n` list desynchronises after the
    first field and `parse_uiautomator` then dies on an empty string.
    """

    def __init__(self, *outputs, tree=None):
        self.outputs = list(outputs)
        self.tree = tree
        self.calls = []

    def __call__(self, argv, binary=False):
        self.calls.append(argv)
        if self.outputs:
            return self.outputs.pop(0)
        if binary:
            return b""
        return self.tree if (self.tree is not None and "cat" in argv) else ""

    def argv_text(self):
        return [" ".join(a) for a in self.calls]


def driver(shell):
    return android.AndroidDriver(shell=shell)


def test_install_stages_the_apk_where_the_windows_adb_can_read_it(tmp_path):
    apk = tmp_path / "app-debug.apk"
    apk.write_bytes(b"not really an apk")
    staging = tmp_path / "winstage"
    staging.mkdir()
    # uninstall, then install -- which must report Success or install() raises.
    shell = FakeShell("", "Success\n")
    d = android.AndroidDriver(shell=shell, staging_dir=staging, windows_staging=r"D:\stage")

    d.install(str(apk))

    # The APK really was copied, and adb was handed the *Windows* spelling.
    assert (staging / "paycross-e2e.apk").read_bytes() == b"not really an apk"
    text = shell.argv_text()
    assert any("uninstall com.paycross.paycross_flutter_example" in t for t in text)
    assert any(r"install D:\stage\paycross-e2e.apk" in t for t in text)


def test_shell_output_has_crlf_stripped():
    shell = FakeShell("1\r\n")
    assert driver(shell).getprop("sys.boot_completed") == "1"


def test_launch_refuses_a_device_that_is_not_en_us():
    shell = FakeShell("1\r\n", "de-DE\r\n")

    with pytest.raises(DriverError) as excinfo:
        driver(shell).launch()

    assert "en-US" in str(excinfo.value)
    assert "de-DE" in str(excinfo.value)


def test_launch_force_stops_before_starting():
    shell = FakeShell("1\r\n", "en-US\r\n", "", "")

    driver(shell).launch()

    text = shell.argv_text()
    assert any("force-stop com.paycross.paycross_flutter_example" in t for t in text)
    assert any("monkey -p com.paycross.paycross_flutter_example" in t for t in text)


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


def test_input_text_escapes_the_space_that_would_otherwise_split_the_argument():
    shell = FakeShell()

    driver(shell)._input_text("John Doe")

    assert shell.argv_text() == ["shell input text John%sDoe"]


def test_logs_since_takes_its_cutoff_from_the_device_not_the_host():
    # logcat's -v time stamps, and therefore -t, are in the DEVICE's zone.
    # The emulator runs Europe/Kiev while run_cell hands the driver UTC, so
    # formatting the UTC value here asks for a three-hour window: measured at
    # 110,082 lines against 2,187 for the correct cutoff.
    shell = FakeShell("08-28 18:24:27.000\r\n", "08-28 18:24:28.000 I x: y\n")
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
    shell = FakeShell('date: Max 1 argument (see "date --help")\r\n')

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


def test_dump_tree_gives_up_as_a_driver_error_not_a_parse_error():
    shell = FakeShell(*(["", ""] * 3))

    with pytest.raises(DriverError) as excinfo:
        driver(shell).dump_tree(attempts=3, interval=0)

    assert "dump" in str(excinfo.value)


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


def test_wait_label_timing_out_raises_rather_than_returning_none():
    shell = FakeShell(*(["", "<hierarchy></hierarchy>"] * 3))

    with pytest.raises(DriverError) as excinfo:
        driver(shell).wait_label(timeout=0, interval=0)

    assert "label" in str(excinfo.value)


def test_type_card_clears_then_fills_every_field():
    form = (FIXTURES / "android-rearmed.uix").read_text()
    # Every tree read returns the same form; typing is fire-and-forget.
    shell = FakeShell(tree=form)

    driver(shell).type_card(
        Card(pan="4111111111170000", expiry="12/28", cvv="123"), verify_pan=False
    )

    text = " | ".join(shell.argv_text())
    assert "input keyevent 67" in text  # KEYCODE_DEL, clearing the field
    assert "shell input text 1228" in text
    assert "shell input text 123" in text
    assert "shell input text John%sDoe" in text


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
