import importlib
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from tool.e2e import tree
from tool.e2e.cells import Card
from tool.e2e.drivers import android, base
from tool.e2e.drivers.base import DriverError

FIXTURES = Path(__file__).parent / "fixtures"

TOKEN = "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJzYW5kYm94In0.c2lnbmF0dXJlLWJ5dGVz"


def screen(token: str = "") -> str:
    return (
        "<hierarchy>"
        f'<node class="android.widget.EditText" text="{token}" content-desc=""'
        ' bounds="[0,0][100,50]"/>'
        '<node class="android.view.View" text="" content-desc="Pay"'
        ' bounds="[0,60][100,100]"/>'
        '<node class="android.widget.EditText" resource-id="paycross.cardNumber"'
        ' text="" content-desc="" bounds="[0,110][100,150]"/>'
        "</hierarchy>"
    )


class FakeShell:
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
    assert out == "one\ntwo\nthree"


def test_run_passes_binary_through_untouched(monkeypatch):
    png = b"\x89PNG\r\n\x1a\n\r\n"
    _stub_subprocess(monkeypatch, stdout=png)

    assert android._run(["exec-out", "screencap", "-p"], binary=True) == png


def test_run_surfaces_the_stderr_of_a_failed_adb(monkeypatch):
    _stub_subprocess(
        monkeypatch, stdout=b"", stderr=b"adb: device offline\r\n", returncode=1
    )

    assert "device offline" in android._run(["install", "x"])


def test_run_refuses_to_return_binary_it_could_not_fetch(monkeypatch):
    _stub_subprocess(monkeypatch, stdout=b"", stderr=b"closed\r\n", returncode=1)

    with pytest.raises(DriverError) as excinfo:
        android._run(["exec-out", "screencap", "-p"], binary=True)

    assert "closed" in str(excinfo.value)


def test_run_turns_a_timeout_into_a_driver_error(monkeypatch):
    def explode(argv, **kwargs):
        raise android.subprocess.TimeoutExpired(argv, android.RUN_TIMEOUT_SECONDS)

    monkeypatch.setattr(android.subprocess, "run", explode)

    with pytest.raises(DriverError) as excinfo:
        android._run(["shell", "getprop", "sys.boot_completed"])

    message = str(excinfo.value)
    assert "shell" in message
    assert str(android.RUN_TIMEOUT_SECONDS) in message


def test_run_turns_a_missing_adb_into_a_driver_error(monkeypatch):
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


def test_install_stages_the_apk_where_the_windows_adb_can_read_it(tmp_path):
    apk = tmp_path / "app-debug.apk"
    apk.write_bytes(b"not really an apk")
    shell = FakeShell("", "Success\n")
    d = staged_driver(shell, tmp_path)

    d.install(str(apk))

    staged = tmp_path / "winstage" / "paycross-e2e.apk"
    assert staged.read_bytes() == b"not really an apk"
    text = shell.argv_text()
    assert any("uninstall com.paycross.flutterdemo" in t for t in text)
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
    assert (tmp_path / "winstage").is_dir()
    assert shell.calls == []


def test_launch_no_longer_refuses_a_device_that_is_not_en_us():
    shell = FakeShell("1\n", "0\n", "0\n", "0\n", "0\n", "", "")

    driver(shell).launch()

    assert any("monkey" in call for call in shell.argv_text())
    assert len([c for c in shell.argv_text() if "getprop" in c]) == 1


def test_launch_quotes_adb_when_the_boot_check_cannot_be_read():
    shell = FakeShell("adb: no devices/emulators found\n")

    with pytest.raises(DriverError) as excinfo:
        driver(shell).launch()

    message = str(excinfo.value)
    assert "no devices/emulators found" in message
    assert "booting" not in message


def test_launch_still_says_booting_when_the_property_is_merely_unset():
    shell = FakeShell("\n")

    with pytest.raises(DriverError) as excinfo:
        driver(shell).launch()

    assert "booting" in str(excinfo.value)


def test_launch_force_stops_before_starting():
    shell = FakeShell("1\n", "0\n", "0\n", "0\n", "0\n", "", "")
    naps = []

    driver(shell, naps).launch()

    text = shell.argv_text()
    assert any("force-stop com.paycross.flutterdemo" in t for t in text)
    assert any("monkey -p com.paycross.flutterdemo" in t for t in text)
    assert android.LAUNCH_SETTLE_SECONDS == 6
    assert naps == [6]


def test_type_pan_sends_one_keycode_per_digit():
    shell = FakeShell()

    driver(shell)._type_digits("4111")

    assert shell.argv_text() == [
        "shell input keyevent 11",
        "shell input keyevent 8",
        "shell input keyevent 8",
        "shell input keyevent 8",
    ]


def test_type_digits_paces_itself_so_the_formatter_can_keep_up():
    naps = []

    driver(FakeShell(), naps)._type_digits("4111")

    assert android.DIGIT_PACING_SECONDS == 0.4
    assert naps == [0.4] * 4


def test_input_text_escapes_the_space_that_would_otherwise_split_the_argument():
    shell = FakeShell()

    driver(shell)._input_text("John Doe")

    assert shell.argv_text() == ["shell input text John%sDoe"]


def test_type_card_clears_then_fills_every_field():
    form = (FIXTURES / "android-rearmed.uix").read_text()
    shell = FakeShell(tree=form)
    naps = []

    driver(shell, naps).type_card(
        Card(pan="4111111111170000", expiry="12/28", cvv="123"), verify_pan=False
    )

    text = " | ".join(shell.argv_text())
    assert "input keyevent 67" in text
    assert "shell input text 1228" in text
    assert "shell input text 123" in text
    assert "shell input text John%sDoe" in text
    assert naps.count(android.SETTLE_SECONDS) == 11
    assert naps.count(android.DIGIT_PACING_SECONDS) == 16
    assert sum(naps) == pytest.approx(17.4)


def test_verify_pan_reports_what_the_field_actually_reads():
    form = (
        "<hierarchy>"
        '<node class="android.widget.EditText" resource-id="paycross.cardNumber"'
        ' text="4111 1111 1111 000" content-desc="" bounds="[0,0][100,50]"/>'
        '<node class="android.view.View" resource-id="paycross.expiry" text=""'
        ' content-desc="" bounds="[0,60][100,100]"/>'
        '<node class="android.view.View" resource-id="paycross.cvv" text=""'
        ' content-desc="" bounds="[0,110][100,150]"/>'
        '<node class="android.view.View" resource-id="paycross.cardholderName"'
        ' text="" content-desc="" bounds="[0,160][100,200]"/>'
        "</hierarchy>"
    )

    with pytest.raises(DriverError) as excinfo:
        driver(FakeShell(tree=form)).type_card(
            Card(pan="4111111111170000", expiry="12/28", cvv="123")
        )

    message = str(excinfo.value)
    assert "4111 1111 1111 000" in message
    assert "formatter" not in message


SAVED_SHEET = (FIXTURES / "android-saved-card-sheet.uix").read_text()

SAVED_CHOSEN = (FIXTURES / "android-saved-card-chosen.uix").read_text()

REMOVE_DIALOG = (FIXTURES / "android-remove-dialog.uix").read_text()

STORED = "paycross.savedCard.01a0763c-d401-737c-bbb9-948af4e0f60b"


def test_select_saved_card_taps_the_stored_row_where_it_stands():
    shell = FakeShell(trees=[SAVED_SHEET, SAVED_CHOSEN])

    driver(shell).select_saved_card()

    taps = [a for a in shell.argv_text() if a.startswith("shell input tap")]
    assert taps == ["shell input tap 540 495"]


def test_select_saved_card_does_not_mistake_a_bin_for_a_row():
    nodes = tree.parse_uiautomator(SAVED_SHEET)

    rows = driver(FakeShell())._saved_card_rows(nodes)

    assert [n.identifier for n in rows] == [STORED]


def test_select_saved_card_verifies_the_form_really_switched():
    shell = FakeShell(trees=[SAVED_SHEET, SAVED_SHEET])

    with pytest.raises(DriverError) as excinfo:
        driver(shell).select_saved_card(timeout=0)

    assert "still showing the new-card form" in str(excinfo.value)


def test_select_saved_card_is_not_satisfied_by_a_form_that_rendered_nothing():
    empty = "<hierarchy></hierarchy>"
    shell = FakeShell(trees=[SAVED_SHEET, empty])

    with pytest.raises(DriverError):
        driver(shell).select_saved_card(timeout=0)


def test_select_saved_card_says_so_when_no_stored_row_is_offered():
    ordinary = (FIXTURES / "android-rearmed.uix").read_text()
    shell = FakeShell(tree=ordinary)

    with pytest.raises(DriverError) as excinfo:
        driver(shell).select_saved_card(timeout=0)

    assert "no stored-card row" in str(excinfo.value)


SAVED_GONE = SAVED_SHEET.replace(STORED, "paycross.somethingElse")


def test_remove_saved_card_taps_the_bin_of_the_row_it_read():
    shell = FakeShell(
        trees=[SAVED_SHEET, SAVED_SHEET, REMOVE_DIALOG, REMOVE_DIALOG, SAVED_GONE]
    )

    driver(shell).remove_saved_card()

    taps = [a for a in shell.argv_text() if a.startswith("shell input tap")]
    assert taps == ["shell input tap 975 500", "shell input tap 799 1348"]


def test_remove_saved_card_raises_when_the_row_survives_the_confirmation():
    shell = FakeShell(
        trees=[SAVED_SHEET, SAVED_SHEET, REMOVE_DIALOG, REMOVE_DIALOG, SAVED_SHEET]
    )

    with pytest.raises(DriverError) as excinfo:
        driver(shell).remove_saved_card(timeout=0)

    assert "still on the sheet" in str(excinfo.value)
    assert STORED in str(excinfo.value)


def test_remove_saved_card_does_not_read_the_dialogs_own_window_as_success():
    shell = FakeShell(
        trees=[
            SAVED_SHEET,
            SAVED_SHEET,
            REMOVE_DIALOG,
            REMOVE_DIALOG,
            REMOVE_DIALOG,
            SAVED_SHEET,
        ]
    )

    with pytest.raises(DriverError) as excinfo:
        driver(shell).remove_saved_card(timeout=0)

    assert "still on the sheet" in str(excinfo.value)


def test_remove_saved_card_waits_out_the_dialog_before_it_answers():
    shell = FakeShell(
        trees=[
            SAVED_SHEET,
            SAVED_SHEET,
            REMOVE_DIALOG,
            REMOVE_DIALOG,
            REMOVE_DIALOG,
            SAVED_GONE,
        ]
    )

    driver(shell).remove_saved_card()


def test_remove_saved_card_says_so_when_there_is_nothing_to_remove():
    ordinary = (FIXTURES / "android-rearmed.uix").read_text()

    with pytest.raises(DriverError) as excinfo:
        driver(FakeShell(tree=ordinary)).remove_saved_card(timeout=0)

    assert "no stored-card row" in str(excinfo.value)


def test_wait_saved_card_finds_the_list_the_sdk_only_composes_when_there_is_one():
    assert android.SAVED_CARDS == "paycross.savedCards"

    assert driver(FakeShell(tree=SAVED_SHEET)).wait_saved_card() is True


def test_wait_saved_card_answers_false_rather_than_raising_when_none_is_offered():
    ordinary = (FIXTURES / "android-rearmed.uix").read_text()

    assert driver(FakeShell(tree=ordinary)).wait_saved_card(timeout=0) is False


def test_wait_saved_card_still_raises_when_the_device_will_not_dump():
    with pytest.raises(DriverError):
        driver(FakeShell(tree="")).wait_saved_card(timeout=0)


SAVE_FORM = (FIXTURES / "android-save-card-form.uix").read_text()
SAVE_FORM_TICKED = SAVE_FORM.replace(
    'resource-id="paycross.saveCard" class="android.view.View" '
    'package="com.paycross.flutterdemo" content-desc="" checkable="true" '
    'checked="false"',
    'resource-id="paycross.saveCard" class="android.view.View" '
    'package="com.paycross.flutterdemo" content-desc="" checkable="true" '
    'checked="true"',
)
assert SAVE_FORM_TICKED != SAVE_FORM, "the fixture's save-card row changed shape"


def test_save_card_taps_the_row_the_identifier_is_on():
    shell = FakeShell(trees=[SAVE_FORM, SAVE_FORM_TICKED])

    driver(shell).save_card()

    taps = [a for a in shell.argv_text() if a.startswith("shell input tap")]
    assert taps == ["shell input tap 540 1124"]


def test_save_card_refuses_a_tag_that_is_not_on_a_two_state_control():
    loose = SAVE_FORM.replace(
        'resource-id="paycross.saveCard" class="android.view.View" '
        'package="com.paycross.flutterdemo" content-desc="" checkable="true"',
        'resource-id="paycross.saveCard" class="android.view.View" '
        'package="com.paycross.flutterdemo" content-desc="" checkable="false"',
    )
    assert loose != SAVE_FORM

    with pytest.raises(DriverError) as excinfo:
        driver(FakeShell(tree=loose)).save_card(timeout=0)

    assert "not a two-state control" in str(excinfo.value)


def test_save_card_verifies_the_tick_took():
    shell = FakeShell(tree=SAVE_FORM)

    with pytest.raises(DriverError) as excinfo:
        driver(shell).save_card(timeout=0)

    assert "did not tick" in str(excinfo.value)


def test_save_card_leaves_an_already_ticked_box_alone():
    shell = FakeShell(tree=SAVE_FORM_TICKED)

    driver(shell).save_card()

    assert not [a for a in shell.argv_text() if a.startswith("shell input tap")]


def test_save_card_says_so_when_the_session_never_rendered_a_box():
    shell = FakeShell(tree=SAVED_SHEET)

    with pytest.raises(DriverError) as excinfo:
        driver(shell).save_card(timeout=0)

    assert "save_card_config" in str(excinfo.value)
    assert android.SAVE_CARD in str(excinfo.value)


def test_type_cvv_fills_the_cvv_field_and_touches_nothing_else():
    form = (FIXTURES / "android-rearmed.uix").read_text()
    shell = FakeShell(tree=form)
    naps = []

    driver(shell, naps).type_cvv("123")

    text = " | ".join(shell.argv_text())
    assert "shell input text 123" in text
    assert android.CVV == "paycross.cvv"
    assert text.count("input text") == 1
    assert "input keyevent 67" not in text


def test_type_cvv_drops_the_ime_so_the_pay_button_is_reachable():
    form = (FIXTURES / "android-rearmed.uix").read_text()
    shell = FakeShell(tree=form)

    driver(shell).type_cvv("123")

    argv = shell.argv_text()
    typed = argv.index("shell input text 123")
    assert f"shell input keyevent {android._KEYCODE_BACK}" in argv[typed:]


def test_paste_token_refuses_an_empty_token_file(tmp_path):
    path = tmp_path / "token"
    path.write_text("   \n")
    shell = FakeShell()

    with pytest.raises(DriverError) as excinfo:
        driver(shell).paste_token(path)

    assert "empty" in str(excinfo.value)
    assert shell.calls == []


def test_paste_token_refuses_something_that_is_not_shaped_like_a_token(tmp_path):
    path = tmp_path / "token"
    path.write_text("not a token; rm -rf /sdcard")
    shell = FakeShell()

    with pytest.raises(DriverError) as excinfo:
        driver(shell).paste_token(path)

    message = str(excinfo.value)
    assert "JWT" in message
    assert "Refusing to type it" in message
    assert "rm -rf" not in message
    assert shell.calls == []


def test_paste_token_sends_the_token_on_stdin_never_in_an_argv(tmp_path):
    path = tmp_path / "token"
    path.write_text(TOKEN)
    shell = FakeShell(tree=screen(TOKEN))

    driver(shell).paste_token(path)

    assert not any(TOKEN in " ".join(argv) for argv in shell.calls)
    carried = [
        (argv, s) for argv, s in zip(shell.calls, shell.stdins, strict=True) if s
    ]
    assert len(carried) == 1
    assert carried[0] == (["shell"], f"input text {TOKEN}\n")


def test_paste_token_chunks_a_long_token_and_loses_nothing(tmp_path):
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
    shell = FakeShell(trees=[screen(TOKEN[:10]), screen(TOKEN[:10]), screen(TOKEN)])

    driver(shell).paste_token(path)


def test_paste_token_reports_a_paste_that_never_agreed(tmp_path, monkeypatch):
    monkeypatch.setattr(android, "TOKEN_READBACK_SECONDS", 0)
    path = tmp_path / "token"
    path.write_text(TOKEN)
    shell = FakeShell(tree=screen(TOKEN[:10]))

    with pytest.raises(DriverError) as excinfo:
        driver(shell).paste_token(path)

    message = str(excinfo.value)
    assert "10" in message and str(len(TOKEN)) in message
    assert TOKEN not in message


def test_a_find_with_no_needle_does_not_say_it_was_looking_for_nothing():
    d = driver(FakeShell(tree="<hierarchy></hierarchy>"))

    with pytest.raises(DriverError) as excinfo:
        d._find(lambda nodes, _: [], "", "the token field", timeout=0)

    assert str(excinfo.value) == "the token field never appeared within 0s"


def test_logs_since_takes_its_cutoff_from_the_device_not_the_host():
    shell = FakeShell("08-28 18:24:27.000\n", "08-28 18:24:28.000 I x: y\n")
    when = datetime.now(timezone.utc) - timedelta(seconds=60)

    driver(shell).logs_since(when)

    asked, fetched = shell.argv_text()
    assert asked.startswith("shell date -d @$(( $(date +%s) - 6")
    assert "'+%m-%d %H:%M:%S.000'" in asked
    assert fetched == "logcat -d -v time -t 08-28 18:24:27.000"


def test_logs_since_refuses_a_cutoff_the_device_could_not_produce():
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
    xml = (FIXTURES / "android-rearmed.uix").read_text()
    shell = FakeShell("", xml)

    driver(shell).dump_tree()

    dumped, fetched = shell.argv_text()
    assert dumped == "shell rm -f /sdcard/ui.xml; uiautomator dump /sdcard/ui.xml"
    assert fetched == "shell cat /sdcard/ui.xml"


def test_dump_tree_retries_a_read_that_came_back_unparsable():
    good = (FIXTURES / "android-rearmed.uix").read_text()
    shell = FakeShell("", "<hierarchy><node ", "", good)

    assert driver(shell).dump_tree(interval=0) == good.encode("utf-8")


def test_dump_tree_gives_up_as_a_driver_error_carrying_what_it_saw():
    shell = FakeShell(*(["ERROR: could not get idle state.\n", "no such file"] * 3))

    with pytest.raises(DriverError) as excinfo:
        driver(shell).dump_tree(attempts=3, interval=0)

    message = str(excinfo.value)
    assert "could not get idle state" in message
    assert "no such file" in message


def test_wait_rearmed_polls_until_the_banner_appears():
    empty = "<hierarchy></hierarchy>"
    rearmed = (FIXTURES / "android-rearmed.uix").read_text()
    shell = FakeShell("", empty, "", rearmed)

    assert driver(shell).wait_rearmed("€10.00", timeout=30, interval=0) is True


def test_wait_rearmed_gives_up_and_says_so():
    shell = FakeShell(*(["", "<hierarchy></hierarchy>"] * 3))

    assert driver(shell).wait_rearmed("€10.00", timeout=0, interval=0) is False


def test_wait_rearmed_blames_the_rig_for_an_amount_it_cannot_spell():
    rearmed = (FIXTURES / "android-rearmed.uix").read_text()
    french = rearmed.replace('text="€10.00"', 'text="10,00 €"', 1)
    assert french != rearmed

    with pytest.raises(DriverError) as excinfo:
        driver(FakeShell(tree=french)).wait_rearmed("€10.00", timeout=0, interval=0)

    message = str(excinfo.value)
    assert "10,00" in message
    assert "the rig, not the SDK" in message
    assert "the device is not drawing" in message
    assert android.AndroidDriver.device_noun == "device"


def test_wait_rearmed_still_answers_false_for_a_sheet_that_did_not_re_arm():
    rearmed = (FIXTURES / "android-rearmed.uix").read_text()
    no_banner = rearmed.replace('resource-id="paycross.errorBanner"', 'resource-id="x"')
    assert no_banner != rearmed

    assert (
        driver(FakeShell(tree=no_banner)).wait_rearmed("€10.00", timeout=0, interval=0)
        is False
    )


def test_wait_label_returns_the_contract_label():
    tree_xml = (FIXTURES / "android-result.uix").read_text()
    shell = FakeShell("", tree_xml)

    label = driver(shell).wait_label(
        timeout=10, interval=0, prefixes=("Paid ", "result:")
    )

    assert label.startswith("Paid 1000 EUR")


def test_a_wait_rides_out_a_device_that_will_not_dump():
    refused = ["", ""] * 3
    tree_xml = (FIXTURES / "android-result.uix").read_text()
    shell = FakeShell(*refused, "", tree_xml)

    label = driver(shell).wait_label(
        timeout=10, interval=0, prefixes=("Paid ", "result:")
    )

    assert label.startswith("Paid 1000 EUR")


def test_a_wait_past_its_deadline_blames_the_dump_not_the_missing_node():
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
    shell = FakeShell(tree=(FIXTURES / "android-rearmed.uix").read_text())
    d = driver(shell)

    for call in (lambda: d._tap_text(""), lambda: d._tap_desc("")):
        with pytest.raises(DriverError):
            call()

    assert shell.calls == []


def test_close_is_a_no_op_for_a_driver_with_nothing_to_release():
    shell = FakeShell()

    assert driver(shell).close() is None
    assert shell.calls == []


def test_a_wait_that_times_out_on_a_legacy_label_names_the_missing_define():
    shell = FakeShell(tree=(FIXTURES / "android-result.uix").read_text())

    with pytest.raises(DriverError) as excinfo:
        driver(shell).wait_label(timeout=0, interval=0)

    assert "PAYCROSS_E2E" in str(excinfo.value)


def test_a_wait_that_times_out_on_nothing_at_all_does_not_blame_the_build():
    shell = FakeShell(tree="<hierarchy></hierarchy>")

    with pytest.raises(DriverError) as excinfo:
        driver(shell).wait_label(timeout=0, interval=0)

    assert "PAYCROSS_E2E" not in str(excinfo.value)


def test_the_rig_paths_are_overridable_from_the_environment(monkeypatch):
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
    assert android.ADB == "adb.exe"
    assert android.STAGING_DIR == "/mnt/c/dev/tmp"
    assert android.WINDOWS_STAGING == r"C:\dev\tmp"


def test_a_driver_that_skips_super_init_has_no_package_at_all():
    class Forgetful(base.Driver):
        _parse_dump = staticmethod(lambda dump: [])

        def __init__(self):
            pass

        install = launch = paste_token = type_card = tap_pay = lambda *a, **k: None
        wait_label = acs = cancel_challenge = cancel_form = lambda *a, **k: None
        wait_rearmed = dump_tree = screenshot = logs_since = lambda *a, **k: None

    with pytest.raises(AttributeError, match="package"):
        assert Forgetful().package


def test_the_android_driver_exposes_what_it_was_constructed_with():
    slept = []
    made = android.AndroidDriver(shell=FakeShell(), sleep=slept.append)

    assert made.package == android.PACKAGE
    made._sleep(1.5)
    assert slept == [1.5]


def test_wait_no_label_hands_back_the_label_that_appeared():
    resolved = (
        "<hierarchy>"
        '<node class="android.view.View" text=""'
        ' content-desc="result:success:txn-1" bounds="[0,0][100,50]"/>'
        "</hierarchy>"
    )
    shell = FakeShell(tree=resolved)

    assert driver(shell).wait_no_label(0) == "result:success:txn-1"


def test_wait_no_label_answers_none_when_the_app_said_nothing():
    shell = FakeShell(tree=screen())

    assert driver(shell).wait_no_label(0) is None


def test_relaunch_on_android_is_exactly_launch():
    one = ["1\n", "0\n", "0\n", "0\n", "0\n", "", ""]
    shell = FakeShell(*one, *one)
    made = driver(shell)

    made.launch()
    launched = list(shell.calls)
    shell.calls.clear()
    made.relaunch()

    assert shell.calls == launched


def sheet(*rows: tuple[str, str, str]) -> str:
    return (
        "<hierarchy>"
        + "".join(
            f'<node class="android.view.View" text="{text}" content-desc="{desc}"'
            f' bounds="{bounds}"/>'
            for text, desc, bounds in rows
        )
        + "</hierarchy>"
    )


def tagged(*rows: tuple[str, str, str]) -> str:
    return (
        "<hierarchy>"
        + "".join(
            f'<node class="android.view.View" resource-id="{identifier}"'
            f' text="{text}" content-desc="" bounds="{bounds}"/>'
            for identifier, text, bounds in rows
        )
        + "</hierarchy>"
    )


def taps(shell):
    return [c for c in shell.argv_text() if c.startswith("shell input tap")]


def test_tap_pay_taps_the_sheets_own_pay_button_and_not_the_examples():
    shell = FakeShell(
        tree=(
            "<hierarchy>"
            '<node class="android.view.View" resource-id="paycross.amount"'
            ' text="€10.00" content-desc="" bounds="[0,0][100,40]"/>'
            '<node class="android.view.View" resource-id="paycross.payButton"'
            ' text="" content-desc="" bounds="[0,60][100,100]"/>'
            '<node class="android.view.View" resource-id="" text="Pay €10.00"'
            ' content-desc="" bounds="[0,70][100,90]"/>'
            '<node class="android.view.View" resource-id="" text=""'
            ' content-desc="Pay" bounds="[0,120][100,160]"/>'
            "</hierarchy>"
        )
    )

    driver(shell).tap_pay("€10.00")

    assert taps(shell) == ["shell input tap 50 80"]


def test_tap_pay_does_not_need_the_amount_it_is_given():
    shell = FakeShell(tree=tagged(("paycross.payButton", "", "[0,60][100,100]")))

    driver(shell).tap_pay("nonsense")

    assert taps(shell) == ["shell input tap 50 80"]


def test_acs_waits_for_the_sandbox_page_before_it_taps_an_outcome():
    shell = FakeShell(
        tree=sheet(
            (android.ACS_MARKERS[0], "", "[0,0][100,40]"),
            ("approve", "", "[0,200][100,240]"),
            ("authentication_failed", "", "[0,260][100,300]"),
        )
    )

    driver(shell).acs("authentication_failed")

    assert taps(shell) == ["shell input tap 50 280"]


CANCEL_WINDOW = tagged(
    ("paycross.cancelDialog", "", "[0,300][100,500]"),
    ("paycross.cancelDismiss", "", "[0,400][50,440]"),
    ("paycross.cancelConfirm", "", "[60,400][100,440]"),
)


def test_cancel_challenge_backs_out_of_the_acs_page_then_confirms():
    shell = FakeShell(
        trees=[
            sheet((android.ACS_MARKERS[0], "", "[0,0][100,40]")),
            CANCEL_WINDOW,
            CANCEL_WINDOW,
        ]
    )

    driver(shell).cancel_challenge()

    assert "shell input keyevent 4" in shell.argv_text()
    assert taps(shell) == ["shell input tap 80 420"]


def test_cancel_form_confirms_without_waiting_for_the_acs_page():
    shell = FakeShell(tree=CANCEL_WINDOW)

    driver(shell).cancel_form()

    assert "shell input keyevent 4" in shell.argv_text()
    assert taps(shell) == ["shell input tap 80 420"]
    assert not any(android.ACS_MARKERS[0] in c for c in shell.argv_text())


def test_dismiss_cancel_presses_the_other_button_and_waits_for_the_form():
    form = tagged(("paycross.payButton", "", "[0,60][100,100]"))
    shell = FakeShell(trees=[CANCEL_WINDOW, CANCEL_WINDOW, form])

    driver(shell).dismiss_cancel()

    assert "shell input keyevent 4" in shell.argv_text()
    assert taps(shell) == ["shell input tap 25 420"]


def test_dismiss_cancel_raises_when_the_sheet_does_not_come_back():
    shell = FakeShell(
        trees=[CANCEL_WINDOW, CANCEL_WINDOW, "<hierarchy></hierarchy>"] * 2
    )

    with pytest.raises(DriverError) as excinfo:
        driver(shell).dismiss_cancel(timeout=0)

    assert "did not come back" in str(excinfo.value)


def token_screen_without_the_form(token: str) -> str:
    return (
        "<hierarchy>"
        f'<node class="android.widget.EditText" text="{token}" content-desc=""'
        ' bounds="[0,0][100,50]"/>'
        '<node class="android.view.View" text="" content-desc="Pay"'
        ' bounds="[0,60][100,100]"/>'
        "</hierarchy>"
    )


def test_present_token_does_not_wait_for_a_card_form_that_will_never_come(tmp_path):
    path = tmp_path / "token"
    path.write_text(TOKEN)
    shell = FakeShell(tree=token_screen_without_the_form(TOKEN))

    driver(shell).present_token(path)

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
    missing = str(tmp_path / "absent.token")
    shell = FakeShell(tree=screen())

    driver(shell).enter_token(missing)

    assert f"shell input text {missing}" in shell.argv_text()


def test_enter_token_takes_a_literal_that_paste_token_would_refuse(tmp_path):
    path = tmp_path / "token"
    path.write_text("short")
    shell = FakeShell(tree=screen())

    with pytest.raises(DriverError, match="JWT"):
        driver(shell).paste_token(path)

    driver(FakeShell(tree=screen())).enter_token("short")


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


def test_airplane_quotes_what_the_toggle_itself_said():
    shell = FakeShell("cmd: Can't find service: connectivity\n", "0\n")

    with pytest.raises(DriverError) as excinfo:
        driver(shell).airplane(True)

    assert "Can't find service: connectivity" in str(excinfo.value)


def test_airplane_bounds_the_device_text_it_quotes():
    shell = FakeShell("x" * 4000, "y" * 4000)

    with pytest.raises(DriverError) as excinfo:
        driver(shell).airplane(True)

    message = str(excinfo.value)
    assert "x" * android.QUOTED_DEVICE_TEXT_CHARS in message
    assert "x" * (android.QUOTED_DEVICE_TEXT_CHARS + 1) not in message
    assert "y" * (android.QUOTED_DEVICE_TEXT_CHARS + 1) not in message


def test_airplane_refuses_a_cut_that_did_not_take():
    shell = FakeShell("", "0\n")

    with pytest.raises(DriverError) as excinfo:
        driver(shell).airplane(True)

    assert "meaningless" in str(excinfo.value)


def test_launch_refuses_a_device_a_previous_cell_left_in_airplane_mode():
    shell = FakeShell("1\n", "1\n")

    with pytest.raises(DriverError) as excinfo:
        driver(shell).launch()

    message = str(excinfo.value)
    assert "airplane mode" in message
    assert "airplane-mode disable" in message
    assert not any("monkey" in c for c in shell.argv_text())


def test_wait_acs_waits_for_the_page_without_answering_it():
    shell = FakeShell(
        tree=sheet(
            (android.ACS_MARKERS[0], "", "[0,0][100,40]"),
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


GOOGLE_PAY_BOUNDS = "[42,179][1038,305]"


def offered_sheet() -> str:
    return sheet(
        ("Pay \u20ac10.00", "", "[0,60][100,100]"),
        ("", android.GOOGLE_PAY_DESC, GOOGLE_PAY_BOUNDS),
    )


def sheet_without_wallet() -> str:
    return sheet(("Pay \u20ac10.00", "", "[0,60][100,100]"))


def test_wait_google_pay_finds_the_button_play_services_draws():
    shell = FakeShell(tree=offered_sheet())

    assert driver(shell).wait_google_pay(timeout=5) is True


def test_wait_google_pay_polls_rather_than_looking_once():
    shell = FakeShell(
        trees=[sheet_without_wallet(), sheet_without_wallet(), offered_sheet()]
    )
    naps = []

    assert driver(shell, naps).wait_google_pay(timeout=30) is True
    assert naps == [2, 2]


def test_wait_google_pay_answers_false_rather_than_raising():
    shell = FakeShell(tree=sheet_without_wallet())

    assert driver(shell).wait_google_pay(timeout=0) is False


def test_wait_no_google_pay_is_disproved_by_a_button_that_is_merely_late():
    shell = FakeShell(
        trees=[sheet_without_wallet(), sheet_without_wallet(), offered_sheet()]
    )
    naps = []

    assert driver(shell, naps).wait_no_google_pay(timeout=20) is False
    assert naps == [2, 2]


def test_wait_no_google_pay_answers_true_when_the_window_passes_empty():
    shell = FakeShell(tree=sheet_without_wallet())

    assert driver(shell).wait_no_google_pay(timeout=0) is True


def test_wait_no_google_pay_rides_out_a_device_that_will_not_dump():
    refused = ["", ""] * 3
    shell = FakeShell(*refused, "", offered_sheet())

    assert driver(shell).wait_no_google_pay(timeout=20) is False


def test_tap_google_pay_taps_the_wrapper_because_the_node_is_not_clickable():
    shell = FakeShell(tree=offered_sheet())

    driver(shell).tap_google_pay()

    assert taps(shell) == ["shell input tap 540 242"]


def test_tap_google_pay_says_which_button_never_appeared():
    shell = FakeShell(tree=sheet_without_wallet())

    with pytest.raises(DriverError) as excinfo:
        driver(shell).tap_google_pay(timeout=0)

    assert "the Google Pay button" in str(excinfo.value)


def test_the_google_pay_description_is_the_one_the_evidence_shows():
    assert android.GOOGLE_PAY_DESC == "Pay with GPay"


def focused(package, activity="com.paycross.MainActivity"):
    return f"  mCurrentFocus=Window{{c4b8ac1 u0 {package}/{activity}}}\n"


LAUNCHER = focused("com.google.android.apps.nexuslauncher", "NexusLauncherActivity")
OURS = focused("com.paycross.flutterdemo")


def test_the_foreground_package_is_asked_of_the_window_manager():
    shell = FakeShell(OURS)

    assert driver(shell)._foreground_package() == "com.paycross.flutterdemo"
    assert shell.argv_text() == [
        "shell dumpsys window | grep -E 'mCurrentFocus|mFocusedApp'"
    ]


def test_nothing_focused_reads_as_no_package():
    assert driver(FakeShell("  mCurrentFocus=null\n"))._foreground_package() == ""


def test_wait_foreground_gives_up_naming_what_it_saw():
    shell = FakeShell(LAUNCHER)

    with pytest.raises(DriverError) as excinfo:
        driver(shell)._wait_foreground("com.paycross.flutterdemo", timeout=0)

    message = str(excinfo.value)
    assert "com.paycross.flutterdemo is not in the foreground" in message
    assert "nexuslauncher" in message


def test_wait_foreground_keeps_looking_until_the_app_is_back():
    shell = FakeShell(LAUNCHER, LAUNCHER, OURS)
    naps = []

    driver(shell, naps)._wait_foreground("com.paycross.flutterdemo", interval=1)

    assert len(shell.calls) == 3
    assert naps == [1, 1]


def test_background_goes_home_waits_and_resumes_the_existing_task():
    shell = FakeShell("", LAUNCHER, "", OURS)
    naps = []

    driver(shell, naps).background(60)

    assert shell.argv_text() == [
        "shell input keyevent 3",
        "shell dumpsys window | grep -E 'mCurrentFocus|mFocusedApp'",
        "shell monkey -p com.paycross.flutterdemo "
        "-c android.intent.category.LAUNCHER 1",
        "shell dumpsys window | grep -E 'mCurrentFocus|mFocusedApp'",
    ]
    assert naps == [
        android.BACKGROUND_SETTLE_SECONDS,
        60,
        android.BACKGROUND_SETTLE_SECONDS,
    ]
    assert not any("force-stop" in t for t in shell.argv_text())


def test_background_refuses_a_home_that_did_not_take():
    shell = FakeShell("", OURS)

    with pytest.raises(DriverError) as excinfo:
        driver(shell).background(60)

    assert "still in the foreground after HOME" in str(excinfo.value)
    assert not any("monkey" in t for t in shell.argv_text())


def test_rotate_turns_the_accelerometer_off_first():
    shell = FakeShell("", "0\n")
    naps = []

    driver(shell, naps).rotate()

    assert shell.argv_text() == [
        "shell settings put system accelerometer_rotation 0",
        "shell settings get system user_rotation",
        "shell settings put system user_rotation 1",
    ]
    assert naps == [android.ROTATE_SETTLE_SECONDS]


def test_rotate_toggles_from_whatever_it_read():
    shell = FakeShell("", "1\n")

    driver(shell).rotate()

    assert "shell settings put system user_rotation 0" in shell.argv_text()


def test_kill_activity_force_stops_rather_than_killing():
    shell = FakeShell()
    naps = []

    driver(shell, naps).kill_activity()

    assert shell.argv_text() == ["shell am force-stop com.paycross.flutterdemo"]
    assert naps == [android.SETTLE_SECONDS]


def test_dont_keep_activities_writes_and_reads_back():
    shell = FakeShell("", "1\n")
    naps = []

    driver(shell, naps).dont_keep_activities(True)

    assert shell.argv_text() == [
        "shell settings put global always_finish_activities 1",
        "shell settings get global always_finish_activities",
    ]
    assert naps == [android.SETTLE_SECONDS]


def test_dont_keep_activities_off_asks_for_zero():
    shell = FakeShell("", "0\n")

    driver(shell).dont_keep_activities(False)

    assert "shell settings put global always_finish_activities 0" in shell.argv_text()


def test_dont_keep_activities_refuses_a_setting_that_did_not_take():
    shell = FakeShell("", "0\n")

    with pytest.raises(DriverError) as excinfo:
        driver(shell).dont_keep_activities(True)

    assert "always_finish_activities reads '0'" in str(excinfo.value)


SET_FR = "shell cmd locale set-app-locales com.paycross.flutterdemo --locales 'fr'"
GET = "shell cmd locale get-app-locales com.paycross.flutterdemo"


def said(*tags: str) -> str:
    return f"Locales for com.paycross.flutterdemo for user 0 are [{','.join(tags)}]\n"


def test_the_read_back_parses_the_list_the_device_names():
    assert android.parse_app_locales(said("fr-FR")) == ["fr-FR"]
    assert android.parse_app_locales(said("fr", "en-US")) == ["fr", "en-US"]


def test_an_empty_list_is_an_answer_and_not_a_failure():
    assert android.parse_app_locales(said()) == []


def test_the_read_back_refuses_anything_that_is_not_a_list():
    with pytest.raises(DriverError) as excinfo:
        android.parse_app_locales(
            "Unknown package com.paycross.flutterdemo for userId 0\n"
        )

    assert "cmd locale get-app-locales" in str(excinfo.value)
    assert "Unknown package" in str(excinfo.value)


def test_device_language_writes_the_tag_and_reads_it_back():
    shell = FakeShell("", said("fr"))
    naps = []

    driver(shell, naps).device_language("fr")

    assert shell.argv_text() == [SET_FR, GET]
    assert naps == [android.SETTLE_SECONDS]


def test_device_language_default_clears_the_list():
    shell = FakeShell("", said())

    driver(shell).device_language("default")

    assert shell.argv_text() == [
        "shell cmd locale set-app-locales com.paycross.flutterdemo --locales ''",
        GET,
    ]


def test_device_language_refuses_a_write_that_did_not_take():
    shell = FakeShell("", said())

    with pytest.raises(DriverError) as excinfo:
        driver(shell).device_language("fr")

    message = str(excinfo.value)
    assert "read [] after asking for ['fr']" in message
    assert "cmd locale set-app-locales com.paycross.flutterdemo" in message


def test_device_language_accepts_the_regions_case_as_the_device_spells_it():
    shell = FakeShell("", said("FR-fr"))

    driver(shell).device_language("fr-FR")


def test_device_language_refuses_a_device_that_will_not_say():
    shell = FakeShell("", "error: device offline\n")

    with pytest.raises(DriverError):
        driver(shell).device_language("fr")


def pay_button(caption: str) -> str:
    return (
        "<hierarchy>"
        '<node class="android.view.View" resource-id="paycross.payButton"'
        ' text="" content-desc="" bounds="[0,600][400,700]"/>'
        f'<node class="android.widget.TextView" text="{caption}"'
        ' content-desc="" bounds="[20,620][380,680]"/>'
        "</hierarchy>"
    )


def test_the_sheet_is_french_when_the_pay_button_says_payer():
    shell = FakeShell(tree=pay_button("Payer 10,00 €"))

    assert driver(shell).wait_french_sheet(timeout=0) is True


def test_the_sheet_is_french_even_when_the_amount_is_not():
    shell = FakeShell(tree=pay_button("Payer € 10.00"))

    assert driver(shell).wait_french_sheet(timeout=0) is True


def test_the_sheet_is_not_french_when_the_pay_button_says_pay():
    shell = FakeShell(tree=pay_button("Pay €10.00"))

    assert driver(shell).wait_french_sheet(timeout=0) is False


def test_the_sheet_is_not_french_when_there_is_no_pay_button_at_all():
    shell = FakeShell(tree="<hierarchy></hierarchy>")

    assert driver(shell).wait_french_sheet(timeout=0) is False


def test_launch_refuses_a_device_left_not_keeping_activities():
    shell = FakeShell("1\n", "0\n", "1\n")

    with pytest.raises(DriverError) as excinfo:
        driver(shell).launch()

    message = str(excinfo.value)
    assert "Don't keep activities" in message
    assert "always_finish_activities 0" in message
    assert not any("monkey" in c for c in shell.argv_text())


def test_launch_refuses_a_device_a_previous_cell_left_turned():
    shell = FakeShell("1\n", "0\n", "0\n", "0\n", "1\n")

    with pytest.raises(DriverError) as excinfo:
        driver(shell).launch()

    message = str(excinfo.value)
    assert "not upright" in message
    assert "user_rotation 0" in message
    assert not any("monkey" in c for c in shell.argv_text())


def test_launch_ignores_a_stale_user_rotation_the_sensor_overrides():
    shell = FakeShell("1\n", "0\n", "0\n", "1\n", "1\n", "", "")

    driver(shell).launch()

    assert any("monkey" in c for c in shell.argv_text())


REDESIGNED_ACS = (FIXTURES / "android-acs-redesigned.uix").read_text()


def test_wait_acs_recognises_the_redesigned_sandbox_page():
    shell = FakeShell(tree=REDESIGNED_ACS)

    assert driver(shell).wait_acs(timeout=0) is True


def test_wait_acs_still_recognises_the_old_page():
    old = REDESIGNED_ACS.replace("AUTHENTICATION OUTCOMES", "Sandbox 3DS Challenge")

    assert driver(FakeShell(tree=old)).wait_acs(timeout=0) is True


def test_wait_acs_still_refuses_a_page_that_is_not_the_challenge():
    with pytest.raises(DriverError) as excinfo:
        driver(FakeShell(tree=screen())).wait_acs(timeout=0)

    assert "sandbox ACS page" in str(excinfo.value)


def test_the_acs_markers_are_page_text_rather_than_a_document_title():
    assert "Sandbox 3DS Challenge" in android.ACS_MARKERS
    assert "AUTHENTICATION OUTCOMES" in android.ACS_MARKERS
