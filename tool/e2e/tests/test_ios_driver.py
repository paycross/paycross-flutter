import base64
import importlib
import json
import shlex
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from tool.e2e import tree
from tool.e2e.cells import Card
from tool.e2e.drivers import ios
from tool.e2e.drivers.base import DriverError

FIXTURES = Path(__file__).parent / "fixtures"
SOURCE_XML = (FIXTURES / "ios-source.xml").read_text()

DEVICE_LINE = "    iPhone 17 (C311AFDC-25FA-44A2-A800-10EB5A1039E3) (Booted) \n"

TOKEN = "eyJhbGciOiJSUzI1NiJ9.eyJzZXNzaW9uX2lkIjoiMDFhMCJ9.c2lnbmF0dXJlLWJ5dGVz"

CONSOLE_MARK = 4096
CONSOLE_STARTED = f"    {CONSOLE_MARK}\n12345\n"

SCROLLED_XML = SOURCE_XML.replace(
    'name="fraud_suspected" label="fraud_suspected" value="" enabled="true" '
    'visible="false" x="16" y="1402"',
    'name="fraud_suspected" label="fraud_suspected" value="" enabled="true" '
    'visible="true" x="16" y="402"',
)
assert SCROLLED_XML != SOURCE_XML, "the fixture's fraud_suspected node changed shape"

KEYBOARD_XML = SOURCE_XML.replace(
    "</XCUIElementTypeOther>",
    '<XCUIElementTypeKeyboard type="XCUIElementTypeKeyboard" name="" label="" '
    'enabled="true" visible="true" x="0" y="564" width="402" height="310" '
    'index="11"/></XCUIElementTypeOther>',
    1,
)
assert "XCUIElementTypeKeyboard" in KEYBOARD_XML

BLIND_XML = SOURCE_XML.replace('visible="true"', 'visible="false"')
assert 'visible="true"' not in BLIND_XML


TRUNCATED = json.dumps({"value": "<XCUIElementTypeApplication"})


def payloads_for(ssh, path):
    bodies = []
    for command in ssh.calls:
        if path in command and "printf %s " in command:
            raw = command.split("printf %s ", 1)[1].split(" | curl", 1)[0]
            bodies.append(json.loads(shlex.split(raw)[0]))
    return bodies


def typed_strings(ssh):
    return ["".join(b["value"]) for b in payloads_for(ssh, "/wda/keys")]


def source_response(xml=None):
    return json.dumps({"value": SOURCE_XML if xml is None else xml})


class FakeSsh:
    def __init__(self, *outputs, xml=None):
        self.outputs = list(outputs)
        self.xml = xml
        self.calls = []
        self.stdins = []

    def __call__(self, command, *, stdin=None):
        self.calls.append(command)
        self.stdins.append(stdin)
        if self.outputs:
            return self.outputs.pop(0)
        if "/source" in command:
            return source_response(self.xml)
        if "window/size" in command:
            return json.dumps({"value": {"width": 402, "height": 874}})
        return json.dumps({"value": None})

    def joined(self):
        return " | ".join(self.calls)


class ScrollingFakeSsh(FakeSsh):
    def __init__(self):
        super().__init__()
        self.scrolled = False

    def __call__(self, command, *, stdin=None):
        if "dragfromtoforduration" in command:
            self.scrolled = True
            self.calls.append(command)
            self.stdins.append(stdin)
            return json.dumps({"value": None})
        if "/source" in command:
            self.calls.append(command)
            self.stdins.append(stdin)
            return source_response(SCROLLED_XML if self.scrolled else SOURCE_XML)
        return super().__call__(command, stdin=stdin)


class KeyboardFakeSsh(FakeSsh):
    def __init__(self, clears_on_tap=True):
        super().__init__()
        self.clears_on_tap = clears_on_tap
        self.cleared = False

    def __call__(self, command, *, stdin=None):
        if "keyboard/dismiss" in command:
            self.calls.append(command)
            self.stdins.append(stdin)
            return json.dumps(
                {
                    "value": {
                        "error": "no such element",
                        "message": "keyboard cannot be dismissed",
                        "traceback": "x" * 10842,
                    }
                }
            )
        if "/wda/tap" in command:
            self.calls.append(command)
            self.stdins.append(stdin)
            if self.clears_on_tap:
                self.cleared = True
            return json.dumps({"value": None})
        if "/source" in command:
            self.calls.append(command)
            self.stdins.append(stdin)
            return source_response(SOURCE_XML if self.cleared else KEYBOARD_XML)
        return super().__call__(command, stdin=stdin)


def token_file(tmp_path, text=TOKEN):
    path = tmp_path / "cell.token"
    path.write_text(text, encoding="utf-8")
    return path


def driver(ssh, naps=None, session_id="sess-1"):
    d = ios.IosDriver(ssh=ssh, sleep=(naps if naps is not None else []).append)
    d._session_id = session_id
    return d


def unlaunched(ssh, naps=None):
    return driver(ssh, naps, session_id=None)


def launched(ssh, naps=None):
    ssh.outputs = list(launch_outputs()) + ssh.outputs
    d = ios.IosDriver(ssh=ssh, sleep=(naps if naps is not None else []).append)
    d.launch()
    ssh.calls.clear()
    ssh.stdins.clear()
    return d


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

    monkeypatch.setattr(ios.subprocess, "run", fake_run)
    return seen


def test_ssh_runs_the_command_on_the_configured_host_under_a_timeout(monkeypatch):
    seen = _stub_subprocess(monkeypatch, stdout=b"hi\n")

    assert ios._ssh("echo hi") == "hi\n"
    assert seen["argv"] == ["ssh", ios.SSH_HOST, "echo hi"]
    assert seen["kwargs"]["timeout"] == ios.SSH_TIMEOUT_SECONDS
    assert seen["kwargs"]["capture_output"] is True


def test_ssh_turns_a_timeout_into_a_driver_error(monkeypatch):
    def explode(argv, **kwargs):
        raise ios.subprocess.TimeoutExpired(argv, ios.SSH_TIMEOUT_SECONDS)

    monkeypatch.setattr(ios.subprocess, "run", explode)

    with pytest.raises(DriverError) as excinfo:
        ios._ssh(ios.MAC_ENV + "xcrun simctl list devices")

    message = str(excinfo.value)
    assert "xcrun" in message
    assert str(ios.SSH_TIMEOUT_SECONDS) in message


def test_ssh_turns_a_missing_ssh_binary_into_a_driver_error(monkeypatch):
    def explode(argv, **kwargs):
        raise FileNotFoundError(2, "No such file or directory", "ssh")

    monkeypatch.setattr(ios.subprocess, "run", explode)

    with pytest.raises(DriverError) as excinfo:
        ios._ssh("true")

    assert "ssh" in str(excinfo.value)


def test_ssh_hands_stdin_to_the_process_rather_than_the_command_line(monkeypatch):
    seen = _stub_subprocess(monkeypatch)

    ios._ssh("xcrun simctl pbcopy UDID", stdin=b"a.b.c")

    assert seen["argv"] == ["ssh", ios.SSH_HOST, "xcrun simctl pbcopy UDID"]
    assert seen["kwargs"]["input"] == b"a.b.c"


def test_ssh_normalises_the_crlf_that_a_pty_console_produces(monkeypatch):
    _stub_subprocess(monkeypatch, stdout=b"one\r\ntwo\r\nthree")

    assert ios._ssh("cat log") == "one\ntwo\nthree"


def test_ssh_surfaces_the_stderr_of_a_failed_remote_command(monkeypatch):
    _stub_subprocess(
        monkeypatch,
        stdout=b"",
        stderr=b"ssh: connect to host mac port 22\r\n",
        returncode=255,
    )

    assert "connect to host mac" in ios._ssh("true")


def test_every_remote_command_carries_the_env_exports_and_no_sudo():
    ssh = FakeSsh("ok")

    driver(ssh)._remote("echo hi")

    command = ssh.calls[0]
    assert "DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer" in command
    assert "/opt/homebrew/bin" in command
    assert "$HOME/development/flutter/bin" in command
    assert "sudo" not in command


def test_wda_calls_go_through_curl_on_the_mac_not_from_wsl():
    ssh = FakeSsh(json.dumps({"value": {"ready": True}}))

    driver(ssh)._wda("GET", "/status")

    command = ssh.calls[0]
    assert "curl" in command
    assert "http://127.0.0.1:8100/status" in command
    assert ios.WDA_TIMEOUT_SECONDS == 30
    assert "-m 30" in command
    assert command.count("http://") == 1


def test_wda_puts_the_body_on_stdin_rather_than_the_command_line():
    ssh = FakeSsh()

    driver(ssh)._wda("POST", "/session/sess-1/wda/tap", {"x": 1.0, "y": 2.0})

    command = ssh.calls[0]
    assert "printf %s " in command and "--data-binary @-" in command
    assert payloads_for(ssh, "/wda/tap") == [{"x": 1.0, "y": 2.0}]


def test_wda_raises_on_the_error_envelope_rather_than_returning_it():
    ssh = FakeSsh(
        json.dumps(
            {
                "value": {
                    "error": "invalid session id",
                    "message": "Session does not exist",
                    "traceback": "x" * 10842,
                }
            }
        )
    )

    with pytest.raises(DriverError) as excinfo:
        driver(ssh)._wda("POST", "/session/bad/wda/tap", {"x": 1.0, "y": 1.0})

    text = str(excinfo.value)
    assert "invalid session id" in text
    assert "Session does not exist" in text
    assert len(text) < 400


def test_wda_raises_when_the_answer_is_not_json():
    ssh = FakeSsh("curl: (7) Failed to connect to 127.0.0.1 port 8100\n")

    with pytest.raises(DriverError) as excinfo:
        driver(ssh)._wda("GET", "/status")

    assert "Failed to connect" in str(excinfo.value)


def test_wda_raises_when_the_answer_is_empty():
    ssh = FakeSsh("   \n")

    with pytest.raises(DriverError) as excinfo:
        driver(ssh)._wda("GET", "/status")

    assert "/status" in str(excinfo.value)


NO_OPEN_SESSION = json.dumps({"value": {"ready": True}, "sessionId": None})


def launch_outputs(
    session=None,
    alive="alive\n",
    status=NO_OPEN_SESSION,
    *,
    stopping=False,
    mark=CONSOLE_MARK,
    orientation=None,
):
    stale = json.loads(status).get("sessionId")
    return (
        DEVICE_LINE,
        *(["gone\n"] if stopping else []),
        status,
        *([json.dumps({"value": None})] if stale else []),
        "",
        f"    {mark}\n12345\n",
        session or json.dumps({"value": {"sessionId": "sess-9"}}),
        alive,
        orientation or json.dumps({"value": "PORTRAIT"}),
    )


def test_a_hostile_udid_cannot_break_out_of_a_command():
    ssh = FakeSsh("", "")
    hostile = "x; rm -rf ~"

    ios.IosDriver(ssh=ssh, udid=hostile, sleep=lambda _: None).install("/tmp/R.app")

    assert shlex.quote(hostile) in ssh.joined()


def test_launch_terminates_and_relaunches_the_example_bundle_then_opens_a_session():
    ssh = FakeSsh(*launch_outputs())
    d = ios.IosDriver(ssh=ssh, sleep=lambda _: None)

    d.launch()

    assert d._session_id == "sess-9"
    joined = ssh.joined()
    assert "simctl terminate" in joined
    assert "simctl launch" in joined
    assert "com.paycross.flutterdemo" in joined


def test_launch_accepts_the_older_top_level_session_id_shape():
    ssh = FakeSsh(*launch_outputs(session=json.dumps({"sessionId": "sess-8"})))
    d = ios.IosDriver(ssh=ssh, sleep=lambda _: None)

    d.launch()

    assert d._session_id == "sess-8"


def test_launch_captures_the_app_console_because_the_sdk_emits_no_os_log():
    ssh = FakeSsh(*launch_outputs())
    d = ios.IosDriver(ssh=ssh, sleep=lambda _: None)

    d.launch()

    started = next(c for c in ssh.calls if "--console-pty" in c)
    assert ios.CONSOLE_LOG in started
    assert "nohup" in started and "echo $!" in started
    assert d._console_from == CONSOLE_MARK


def test_launch_kills_the_previous_capture_before_starting_another():
    ssh = FakeSsh(*launch_outputs())
    d = ios.IosDriver(ssh=ssh, sleep=lambda _: None)
    d.launch()
    ssh.outputs = list(launch_outputs(stopping=True))
    ssh.calls.clear()

    d.launch()

    killed = next(i for i, c in enumerate(ssh.calls) if "kill 12345" in c)
    started = next(i for i, c in enumerate(ssh.calls) if "--console-pty" in c)
    terminated = next(i for i, c in enumerate(ssh.calls) if "simctl terminate" in c)
    assert killed < terminated < started


def test_launch_reports_a_previous_capture_that_will_not_die():
    ssh = FakeSsh(*launch_outputs())
    d = ios.IosDriver(ssh=ssh, sleep=lambda _: None)
    d.launch()
    ssh.outputs = [DEVICE_LINE, "en_US\n", "alive\n"]
    ssh.calls.clear()

    with pytest.raises(DriverError) as excinfo:
        d.launch()

    assert "12345" in str(excinfo.value)


def test_close_kills_the_capture_the_run_started():
    ssh = FakeSsh(*launch_outputs())
    d = ios.IosDriver(ssh=ssh, sleep=lambda _: None)
    d.launch()
    ssh.outputs = ["gone\n"]
    ssh.calls.clear()

    d.close()

    assert any("kill 12345" in c for c in ssh.calls)
    assert d._console_pid is None


def test_close_before_launch_does_nothing():
    ssh = FakeSsh()

    unlaunched(ssh).close()

    assert ssh.calls == []


def test_close_is_safe_to_call_twice():
    ssh = FakeSsh(*launch_outputs())
    d = ios.IosDriver(ssh=ssh, sleep=lambda _: None)
    d.launch()
    ssh.outputs = ["gone\n"]
    d.close()
    ssh.calls.clear()

    d.close()

    assert ssh.calls == []


def test_close_surfaces_a_capture_that_will_not_die():
    ssh = FakeSsh(*launch_outputs())
    d = ios.IosDriver(ssh=ssh, sleep=lambda _: None)
    d.launch()
    ssh.outputs = ["alive\n"]

    with pytest.raises(DriverError) as excinfo:
        d.close()

    assert "12345" in str(excinfo.value)


def test_launch_truncates_the_console_log_so_it_cannot_grow_unbounded():
    ssh = FakeSsh(*launch_outputs())

    ios.IosDriver(ssh=ssh, sleep=lambda _: None).launch()

    started = next(c for c in ssh.calls if "--console-pty" in c)
    assert f": > {ios.CONSOLE_LOG}" in started


def test_launch_does_not_let_the_session_relaunch_the_app_out_from_under_it():
    ssh = FakeSsh(*launch_outputs())

    ios.IosDriver(ssh=ssh, sleep=lambda _: None).launch()

    capabilities = payloads_for(ssh, "/session")[0]["capabilities"]["alwaysMatch"]
    assert "bundleId" not in capabilities
    assert "forceAppLaunch" not in capabilities
    assert capabilities["shouldWaitForQuiescence"] is False


def test_launch_closes_a_session_left_open_before_it_starts_the_capture():
    ssh = FakeSsh(*launch_outputs(status=json.dumps({"sessionId": "stale-1"})))

    ios.IosDriver(ssh=ssh, sleep=lambda _: None).launch()

    deleted = [c for c in ssh.calls if "DELETE" in c and "stale-1" in c]
    assert len(deleted) == 1
    started = next(i for i, c in enumerate(ssh.calls) if "--console-pty" in c)
    assert ssh.calls.index(deleted[0]) < started


@pytest.mark.parametrize(
    "status, answers",
    [
        (json.dumps({"sessionId": "stale-1"}), [json.dumps({"value": None})]),
        (NO_OPEN_SESSION, []),
    ],
    ids=["one was open", "none was open"],
)
def test_closing_the_open_session_leaves_no_id_behind(status, answers):
    ssh = FakeSsh(status, *answers)
    d = driver(ssh, session_id="sess-old")

    d._close_open_session()

    assert d._session_id is None


def test_launch_does_not_delete_a_session_when_none_is_open():
    ssh = FakeSsh(*launch_outputs())

    ios.IosDriver(ssh=ssh, sleep=lambda _: None).launch()

    assert not [c for c in ssh.calls if "DELETE" in c]


def test_close_deletes_the_session_it_opened():
    ssh = FakeSsh(*launch_outputs())
    d = ios.IosDriver(ssh=ssh, sleep=lambda _: None)
    d.launch()
    ssh.outputs = ["gone\n", json.dumps({"value": None})]
    ssh.calls.clear()

    d.close()

    assert [c for c in ssh.calls if "DELETE" in c and "sess-9" in c]


def test_close_deletes_the_session_even_when_the_capture_will_not_die():
    ssh = FakeSsh(*launch_outputs())
    d = ios.IosDriver(ssh=ssh, sleep=lambda _: None)
    d.launch()
    ssh.outputs = ["alive\n", json.dumps({"value": None})]
    ssh.calls.clear()

    with pytest.raises(DriverError):
        d.close()

    assert [c for c in ssh.calls if "DELETE" in c and "sess-9" in c]


def test_launch_checks_the_console_capture_after_the_session_not_before():
    ssh = FakeSsh(*launch_outputs(alive="dead\n"))

    with pytest.raises(DriverError) as excinfo:
        ios.IosDriver(ssh=ssh, sleep=lambda _: None).launch()

    message = str(excinfo.value)
    assert "console" in message
    assert ios.CONSOLE_LOG in message
    asked = next(i for i, c in enumerate(ssh.calls) if "kill -0" in c)
    session = next(i for i, c in enumerate(ssh.calls) if "/session" in c)
    assert asked > session


def test_launch_reports_a_console_capture_that_would_not_start():
    ssh = FakeSsh(DEVICE_LINE, NO_OPEN_SESSION, "", "sh: xcrun: command not found\n")

    with pytest.raises(DriverError) as excinfo:
        ios.IosDriver(ssh=ssh, sleep=lambda _: None).launch()

    assert "command not found" in str(excinfo.value)


def test_launch_refuses_a_simulator_that_is_not_booted():
    shutdown = DEVICE_LINE.replace("(Booted)", "(Shutdown)")
    ssh = FakeSsh(shutdown)

    with pytest.raises(DriverError) as excinfo:
        ios.IosDriver(ssh=ssh, sleep=lambda _: None).launch()

    assert "Shutdown" in str(excinfo.value)


def test_launch_says_the_udid_is_unknown_rather_than_that_it_is_not_booted():
    ssh = FakeSsh("")

    with pytest.raises(DriverError) as excinfo:
        ios.IosDriver(ssh=ssh, sleep=lambda _: None).launch()

    message = str(excinfo.value)
    assert "names no simulator" in message
    assert "C311AFDC-25FA-44A2-A800-10EB5A1039E3" in message
    assert "Booted" not in message


def test_launch_settles_before_it_asks_wda_for_a_session():
    ssh = FakeSsh(*launch_outputs())
    naps = []

    ios.IosDriver(ssh=ssh, sleep=naps.append).launch()

    assert ios.LAUNCH_SETTLE_SECONDS == 6
    assert naps == [6]


def test_install_replaces_any_existing_build():
    ssh = FakeSsh("", "")

    driver(ssh).install("/Users/mikz/work/e2e/ios/Runner.app")

    text = ssh.joined()
    assert "simctl uninstall" in text
    assert "simctl install" in text
    assert "/Users/mikz/work/e2e/ios/Runner.app" in text


def test_install_reports_what_simctl_actually_said():
    failure = "An error was encountered processing the command: Invalid device\n"
    ssh = FakeSsh("", failure)

    with pytest.raises(DriverError) as excinfo:
        driver(ssh).install("/tmp/Runner.app")

    assert "Invalid device" in str(excinfo.value)


def test_dump_tree_unwraps_the_json_envelope():
    ssh = FakeSsh(source_response())

    assert driver(ssh).dump_tree() == SOURCE_XML.encode()


def test_dump_tree_retries_a_source_that_came_back_unparsable():
    ssh = FakeSsh(TRUNCATED, source_response())

    assert driver(ssh).dump_tree(interval=0) == SOURCE_XML.encode()


def test_dump_tree_gives_up_as_a_driver_error_carrying_what_it_saw():
    ssh = FakeSsh(*([TRUNCATED] * 3))

    with pytest.raises(DriverError) as excinfo:
        driver(ssh).dump_tree(attempts=3, interval=0)

    message = str(excinfo.value)
    assert "XCUIElementTypeApplication" in message
    assert len(message) < 600


def test_dump_tree_refuses_an_envelope_whose_value_is_not_the_source():
    ssh = FakeSsh(*([json.dumps({"value": {"ready": True}})] * 3))

    with pytest.raises(DriverError) as excinfo:
        driver(ssh).dump_tree(attempts=3, interval=0)

    assert "dict" in str(excinfo.value)


def test_wait_label_reads_the_contract_label_off_the_source():
    ssh = FakeSsh(source_response())

    label = driver(ssh).wait_label(timeout=10, interval=0)

    assert label == "result:success:7d8e12aa-98c9-4032-9e03-6567d8db7bea"


def test_wait_label_timing_out_raises():
    ssh = FakeSsh(*([json.dumps({"value": "<XCUIElementTypeApplication/>"})] * 3))

    with pytest.raises(DriverError) as excinfo:
        driver(ssh).wait_label(timeout=0, interval=0)

    assert "label" in str(excinfo.value)


def test_a_wait_rides_out_a_source_that_will_not_parse():
    refused = [TRUNCATED] * ios._DUMP_ATTEMPTS
    ssh = FakeSsh(*refused, source_response())

    label = driver(ssh).wait_label(timeout=10, interval=0)

    assert label.startswith("result:success:")


def test_a_wait_past_its_deadline_blames_the_dump_not_the_missing_node():
    ssh = FakeSsh(*([TRUNCATED] * 3))

    with pytest.raises(DriverError) as excinfo:
        driver(ssh).wait_label(timeout=0, interval=0)

    assert "source" in str(excinfo.value)


def test_wait_rearmed_is_true_when_the_banner_is_in_the_tree_but_offscreen():
    ssh = FakeSsh(source_response())

    assert driver(ssh).wait_rearmed("€10.00", timeout=10, interval=0) is True


def test_wait_rearmed_is_false_when_the_sheet_re_armed_at_another_amount():
    ssh = FakeSsh(source_response())

    assert driver(ssh).wait_rearmed("€12.50", timeout=0, interval=0) is False


def test_wait_rearmed_gives_up_and_says_so():
    ssh = FakeSsh(*([json.dumps({"value": "<XCUIElementTypeApplication/>"})] * 3))

    assert driver(ssh).wait_rearmed("€10.00", timeout=0, interval=0) is False


def test_tap_identifier_uses_the_node_centre():
    ssh = FakeSsh()

    driver(ssh).tap_identifier("paycross.amount")

    assert payloads_for(ssh, "/wda/tap") == [{"x": 79.0, "y": 212.0}]


def test_tap_identifier_that_is_not_there_says_what_it_looked_for():
    ssh = FakeSsh()

    with pytest.raises(DriverError) as excinfo:
        driver(ssh).tap_identifier("noSuchThing", timeout=0, interval=0)

    assert "noSuchThing" in str(excinfo.value)


def test_tap_pay_ignores_the_amount_it_is_given():
    ssh = FakeSsh()

    driver(ssh).tap_pay("EUR 10.00")

    assert payloads_for(ssh, "/wda/tap") == [{"x": 201.0, "y": 815.0}]


def test_tap_pay_falls_back_to_the_button_wearing_the_sheets_name():
    ssh = FakeSsh()

    assert driver(ssh)._pay_button().identifier == "paycross.sheet"
    assert driver(ssh)._pay_button().type == "Button"


def test_the_pay_button_fallback_is_the_branch_being_taken():
    taken = driver(FakeSsh())._pay_button()

    assert taken.identifier == ios.SHEET, (
        "the Pay button now publishes its own identifier: payment-ios-sdk#47 "
        "is fixed, so delete IosDriver._is_pay_button and this test"
    )


def test_tap_pay_prefers_the_contract_the_moment_the_sdk_honours_it():
    fixed = SOURCE_XML.replace(
        'name="paycross.sheet" label="Pay €10.00"',
        'name="paycross.payButton" label="Pay €10.00"',
    )
    assert fixed != SOURCE_XML
    ssh = FakeSsh(xml=fixed)

    assert driver(ssh)._pay_button().identifier == "paycross.payButton"


def test_find_prefers_a_node_that_is_actually_on_screen():
    ssh = FakeSsh()
    d = driver(ssh)

    assert d._find("fraud_suspected", timeout=0).bounds[1] == 1402
    with pytest.raises(DriverError):
        d._find("fraud_suspected", timeout=0, require_on_screen=True)


def test_find_calls_a_source_that_reports_no_visibility_at_all_a_rig_fault():
    ssh = FakeSsh(xml=BLIND_XML)

    with pytest.raises(DriverError) as excinfo:
        driver(ssh)._find("paycross.amount", timeout=0)

    assert "visible" in str(excinfo.value)


def test_find_identifier_only_does_not_match_a_label():
    ssh = FakeSsh()
    d = driver(ssh)

    assert d._find("paycross.threeDSCancel").identifier == "paycross.threeDSCancel"
    assert [n.identifier for n in d._matches("Cancel")] == [
        "paycross.cancel",
        "paycross.threeDSCancel",
    ]
    assert d._matches("Cancel", identifier_only=True) == []


def test_find_refuses_an_empty_name_rather_than_matching_the_whole_tree():
    ssh = FakeSsh()

    with pytest.raises(DriverError):
        driver(ssh)._find("", timeout=0)

    assert ssh.calls == []


def test_a_call_before_launch_says_there_is_no_session():
    ssh = FakeSsh()

    with pytest.raises(DriverError) as excinfo:
        unlaunched(ssh).tap_identifier("paycross.amount")

    assert "launch()" in str(excinfo.value)


def test_scroll_to_does_not_swipe_when_the_target_is_already_on_screen():
    ssh = ScrollingFakeSsh()

    node = driver(ssh).scroll_to("approve", settle=0)

    assert node.identifier == "approve"
    assert not any("dragfromtoforduration" in c for c in ssh.calls)


def test_acs_scrolls_until_the_outcome_is_on_screen_then_taps():
    ssh = ScrollingFakeSsh()

    driver(ssh).acs("fraud_suspected", timeout=0, settle=0)

    assert any("dragfromtoforduration" in c for c in ssh.calls)
    tap = payloads_for(ssh, "/wda/tap")[-1]
    assert tap["y"] == 424.0
    assert 0 <= tap["y"] <= 874


def test_acs_gives_up_with_a_named_error_if_scrolling_never_reveals_it():
    ssh = FakeSsh()

    with pytest.raises(DriverError) as excinfo:
        driver(ssh).acs("fraud_suspected", timeout=0, max_swipes=2, settle=0)

    assert "fraud_suspected" in str(excinfo.value)
    assert len([c for c in ssh.calls if "dragfromtoforduration" in c]) == 2


def test_acs_puts_the_keyboard_away_before_it_tries_to_scroll():
    ssh = KeyboardFakeSsh(clears_on_tap=True)

    with pytest.raises(DriverError):
        driver(ssh).acs("fraud_suspected", timeout=0, max_swipes=1, settle=0)

    dismissed = next(i for i, c in enumerate(ssh.calls) if "keyboard/dismiss" in c)
    dragged = next(i for i, c in enumerate(ssh.calls) if "dragfromtoforduration" in c)
    assert dismissed < dragged


def test_scroll_to_calls_a_blind_source_a_rig_fault_rather_than_swiping():
    ssh = FakeSsh(xml=BLIND_XML)

    with pytest.raises(DriverError) as excinfo:
        driver(ssh).scroll_to("fraud_suspected", max_swipes=2, settle=0)

    assert "visible" in str(excinfo.value)
    assert not any("dragfromtoforduration" in c for c in ssh.calls)


def test_scroll_to_drags_within_the_window_it_asked_wda_for():
    ssh = ScrollingFakeSsh()

    driver(ssh).scroll_to("fraud_suspected", settle=0)

    drag = payloads_for(ssh, "/wda/dragfromtoforduration")[0]
    assert drag["fromX"] == 201.0 and drag["toX"] == 201.0
    assert drag["fromY"] > drag["toY"]
    assert 0 <= drag["toY"] <= 874 and 0 <= drag["fromY"] <= 874


def test_dismiss_keyboard_taps_a_neutral_node_when_the_pad_will_not_go():
    ssh = KeyboardFakeSsh(clears_on_tap=True)

    driver(ssh).dismiss_keyboard(settle=0)

    assert any("keyboard/dismiss" in c for c in ssh.calls)
    assert payloads_for(ssh, "/wda/tap") == [{"x": 79.0, "y": 212.0}]


def test_dismiss_keyboard_raises_if_the_pad_survives_even_that():
    ssh = KeyboardFakeSsh(clears_on_tap=False)

    with pytest.raises(DriverError) as excinfo:
        driver(ssh).dismiss_keyboard(settle=0)

    assert "keyboard is still up" in str(excinfo.value)


def test_dismiss_keyboard_reports_rather_than_raises_when_it_is_not_required():
    ssh = KeyboardFakeSsh(clears_on_tap=False)

    assert driver(ssh).dismiss_keyboard(settle=0, required=False) is False


def test_dismiss_keyboard_says_so_when_the_pad_did_go():
    ssh = KeyboardFakeSsh(clears_on_tap=True)

    assert driver(ssh).dismiss_keyboard(settle=0) is True


def test_type_card_does_not_fail_a_cell_over_a_pad_that_will_not_go():
    ssh = KeyboardFakeSsh(clears_on_tap=False)
    d = driver(ssh)
    d._focus_field = lambda name: None
    d._fill = lambda name, value: None

    d.type_card(Card(pan="4111111111170000", expiry="12/28", cvv="123"))

    assert any("keyboard/dismiss" in c for c in ssh.calls)


def test_dismiss_keyboard_does_nothing_at_all_when_no_pad_is_up():
    ssh = FakeSsh()

    driver(ssh).dismiss_keyboard(settle=0)

    assert payloads_for(ssh, "/wda/tap") == []
    assert not any("keyboard/dismiss" in c for c in ssh.calls)


def test_dismiss_keyboard_refuses_a_fallback_target_behind_the_pad():
    covered = KEYBOARD_XML.replace(
        'name="paycross.amount" label="Total, \u20ac10.00" '
        'value="Total, \u20ac10.00" enabled="true" visible="true" x="20" y="192"',
        'name="paycross.amount" label="Total, \u20ac10.00" '
        'value="Total, \u20ac10.00" enabled="true" visible="true" x="20" y="600"',
    )
    assert 'y="600"' in covered

    class Covered(KeyboardFakeSsh):
        def __call__(self, command, *, stdin=None):
            if "/source" in command:
                self.calls.append(command)
                self.stdins.append(stdin)
                return source_response(covered)
            return super().__call__(command, stdin=stdin)

    ssh = Covered(clears_on_tap=True)

    with pytest.raises(DriverError) as excinfo:
        driver(ssh).dismiss_keyboard(settle=0)

    assert "behind the keyboard" in str(excinfo.value)
    assert payloads_for(ssh, "/wda/tap") == []


def test_type_card_fills_the_fields_by_identifier_in_form_order():
    ssh = FakeSsh()
    d = driver(ssh)
    tapped = []
    d._focus_field = lambda name: tapped.append(name)
    d._value_of = lambda name: None if len(tapped) % 2 else "changed"

    d.type_card(Card(pan="4111111111170000", expiry="12/28", cvv="123"))

    assert tapped == [
        "paycross.cardholderName",
        "paycross.cardNumber",
        "paycross.expiry",
        "paycross.cvv",
    ]
    assert typed_strings(ssh) == list("John Doe41111111111700001228123")


def test_type_card_dismisses_the_keyboard_the_cvv_field_raised():
    ssh = KeyboardFakeSsh(clears_on_tap=True)
    d = driver(ssh)
    d._focus_field = lambda name: None
    d._fill = lambda name, value: d._paced_keys(value)

    d.type_card(Card(pan="4111111111170000", expiry="12/28", cvv="123"))

    keys_at = max(i for i, c in enumerate(ssh.calls) if "/wda/keys" in c)
    dismiss_at = next(i for i, c in enumerate(ssh.calls) if "keyboard/dismiss" in c)
    assert dismiss_at > keys_at


def test_type_card_paces_the_keystrokes_rather_than_sending_them_at_once():
    ssh = FakeSsh()
    naps = []
    d = driver(ssh, naps)
    d._focus_field = lambda name: None
    d._value_of = lambda name: None

    with pytest.raises(DriverError):
        d.type_card(Card(pan="4111111111170000", expiry="12/28", cvv="123"))

    assert ios.KEY_PACING_SECONDS == 0.15
    assert naps[:3] == [0.15, 0.15, 0.15]


SAVE_FORM_IOS = (FIXTURES / "ios-save-card-form.xml").read_text()

SAVE_FORM_IOS_ONSCREEN = SAVE_FORM_IOS.replace(
    'visible="false" accessible="true" x="20" y="929"',
    'visible="true" accessible="true" x="20" y="440"',
).replace(
    'visible="false" accessible="false" x="321" y="929"',
    'visible="true" accessible="false" x="321" y="440"',
)
assert SAVE_FORM_IOS_ONSCREEN.count('y="440"') == 2, "both switches must move"

SAVE_FORM_IOS_TICKED = SAVE_FORM_IOS_ONSCREEN.replace(
    'value="0" name="paycross.saveCard"', 'value="1" name="paycross.saveCard"'
)
assert SAVE_FORM_IOS_TICKED != SAVE_FORM_IOS_ONSCREEN

SAVE_FORM_IOS_SCROLLED = SAVE_FORM_IOS_TICKED.replace(
    'name="paycross.amount" label="Total, \u20ac10.00" enabled="true" '
    'visible="true" accessible="true" x="20" y="171"',
    'name="paycross.amount" label="Total, \u20ac10.00" enabled="true" '
    'visible="true" accessible="true" x="20" y="37"',
)
assert SAVE_FORM_IOS_SCROLLED != SAVE_FORM_IOS_TICKED, "amount did not move"


class SaveCardFakeSsh(FakeSsh):
    def __init__(self, ticks=True):
        super().__init__()
        self.scrolled = False
        self.restored = False
        self.tapped = False
        self.ticks = ticks

    def __call__(self, command, *, stdin=None):
        if "dragfromtoforduration" in command:
            raw = command.split("printf %s ", 1)[1].split(" | curl", 1)[0]
            body = json.loads(shlex.split(raw)[0])
            if body["fromY"] > body["toY"]:
                self.scrolled = True
            else:
                self.restored = True
        if "/wda/tap" in command:
            self.tapped = True
        if "/source" in command:
            self.calls.append(command)
            self.stdins.append(stdin)
            if self.tapped and self.ticks:
                if self.restored:
                    return source_response(SAVE_FORM_IOS_TICKED)
                return source_response(SAVE_FORM_IOS_SCROLLED)
            return source_response(
                SAVE_FORM_IOS_ONSCREEN if self.scrolled else SAVE_FORM_IOS
            )
        return super().__call__(command, stdin=stdin)


def test_save_card_scrolls_to_the_toggle_before_tapping_it():
    ssh = SaveCardFakeSsh()

    driver(ssh).save_card()

    assert ssh.scrolled, "the toggle is below the fold; a bare tap would miss"
    assert ssh.tapped


def test_save_card_taps_the_control_and_not_the_labelled_row():
    ssh = SaveCardFakeSsh()

    driver(ssh).save_card()

    assert payloads_for(ssh, "/wda/tap") == [{"x": 352.0, "y": 454.0}]


def test_save_card_verifies_the_toggle_took():
    ssh = SaveCardFakeSsh(ticks=False)

    with pytest.raises(DriverError) as excinfo:
        driver(ssh).save_card(timeout=0)

    assert "did not turn on" in str(excinfo.value)


def test_save_card_leaves_an_already_on_toggle_alone():
    class AlreadyOn(FakeSsh):
        def __call__(self, command, *, stdin=None):
            if "/source" in command:
                self.calls.append(command)
                self.stdins.append(stdin)
                return source_response(SAVE_FORM_IOS_TICKED)
            return super().__call__(command, stdin=stdin)

    ssh = AlreadyOn()

    driver(ssh).save_card()

    assert payloads_for(ssh, "/wda/tap") == []


def test_save_card_says_so_when_the_session_never_rendered_a_toggle():
    ssh = FakeSsh()

    with pytest.raises(DriverError) as excinfo:
        driver(ssh).save_card()

    assert ios.SAVE_CARD in str(excinfo.value)
    assert "save_card_config" in str(excinfo.value)


SAVED_SHEET_IOS = (FIXTURES / "ios-saved-card-sheet.xml").read_text()

SAVED_SHEET_IOS_CHOSEN = SAVED_SHEET_IOS.replace(
    'name="paycross.cardNumber"', 'name="gone"'
)
assert SAVED_SHEET_IOS_CHOSEN != SAVED_SHEET_IOS

SAVED_SHEET_IOS_REMOVED = SAVED_SHEET_IOS.replace(
    'name="paycross.savedCards" label="Visa •••• 3063, 12/28"', 'name="gone"'
).replace(
    'name="paycross.savedCards" label="Remove card, Visa •••• 3063"', 'name="gone"'
)
assert SAVED_SHEET_IOS_REMOVED.count("gone") == 2


class SelectFakeSsh(FakeSsh):
    def __init__(self, switches=True):
        super().__init__()
        self.tapped = False
        self.switches = switches

    def __call__(self, command, *, stdin=None):
        if "/wda/tap" in command:
            self.tapped = True
        if "/source" in command:
            self.calls.append(command)
            self.stdins.append(stdin)
            chosen = self.tapped and self.switches
            sheet = SAVED_SHEET_IOS_CHOSEN if chosen else SAVED_SHEET_IOS
            return source_response(sheet)
        return super().__call__(command, stdin=stdin)


def test_select_saved_card_taps_the_stored_row_and_not_the_new_card_row():
    ssh = SelectFakeSsh()

    driver(ssh).select_saved_card()

    assert payloads_for(ssh, "/wda/tap") == [{"x": 179.0, "y": 358.0}]


def test_the_picker_fallback_tells_a_row_from_its_bin_and_from_the_new_card_row():
    d = driver(FakeSsh(xml=SAVED_SHEET_IOS))
    nodes = tree.parse_wda(SAVED_SHEET_IOS)

    rows = d._saved_card_rows(nodes)
    assert [n.bounds for n in rows] == [(20, 336, 338, 381)]

    bin_button = d._remove_button_for(rows[0], nodes)
    assert bin_button is not None
    assert bin_button.bounds == (338, 336, 382, 380)


def test_the_picker_fallback_is_the_branch_being_taken():
    nodes = tree.parse_wda(SAVED_SHEET_IOS)

    assert not [n for n in nodes if n.identifier.startswith(ios.SAVED_CARD_PREFIX)], (
        "the picker now publishes its rows' own identifiers: "
        "payment-ios-sdk#47 is fixed, so delete IosDriver._picker_rows, "
        "_remove_button_for's geometry branch and this test"
    )
    assert [n.identifier for n in driver(FakeSsh())._picker_rows(nodes)] == [
        ios.SAVED_CARDS,
        ios.SAVED_CARDS,
    ]


def test_the_picker_fallback_gives_way_the_moment_the_sdk_names_a_row():
    named = SAVED_SHEET_IOS.replace(
        'name="paycross.savedCards" label="Visa •••• 3063, 12/28"',
        'name="paycross.savedCard.abc-123" label="Visa •••• 3063, 12/28"',
    )
    assert named != SAVED_SHEET_IOS
    d = driver(FakeSsh(xml=named))

    rows = d._saved_card_rows(tree.parse_wda(named))

    assert [n.identifier for n in rows] == ["paycross.savedCard.abc-123"]


def test_select_saved_card_raises_rather_than_paying_with_a_fresh_card():
    ssh = SelectFakeSsh(switches=False)

    with pytest.raises(DriverError) as excinfo:
        driver(ssh).select_saved_card(timeout=0)

    assert "still showing the new-card form" in str(excinfo.value)


REMOVE_DIALOG_NODES = (
    '<XCUIElementTypeOther type="XCUIElementTypeOther" '
    'name="paycross.removeDialog" label="Remove this card?" enabled="true" '
    'visible="true" x="40" y="300" width="322" height="200" index="90"/>'
    '<XCUIElementTypeButton type="XCUIElementTypeButton" '
    'name="paycross.removeConfirm" label="Remove" enabled="true" '
    'visible="true" x="220" y="440" width="120" height="44" index="91"/>'
    '<XCUIElementTypeButton type="XCUIElementTypeButton" '
    'name="paycross.removeDismiss" label="Cancel" enabled="true" '
    'visible="true" x="60" y="440" width="120" height="44" index="92"/>'
)


def with_remove_dialog(source):
    added = source.replace(
        "</XCUIElementTypeOther>", REMOVE_DIALOG_NODES + "</XCUIElementTypeOther>", 1
    )
    assert added != source
    return added


def _hide(source, *labels):
    for label in labels:
        source = source.replace(
            f'label="{label}" enabled="true" visible="true"',
            f'label="{label}" enabled="true" visible="false"',
        )
    return source


HIDDEN_PICKER = _hide(
    SAVED_SHEET_IOS,
    "Visa •••• 3063, 12/28",
    "Remove card, Visa •••• 3063",
    "Use a new card",
)
assert HIDDEN_PICKER != SAVED_SHEET_IOS


class RemoveFakeSsh(FakeSsh):
    def __init__(self, removes=True, obscured=False):
        super().__init__()
        self.removes = removes
        self.obscured = obscured
        self.taps = []

    def __call__(self, command, *, stdin=None):
        if "/wda/tap" in command:
            self.taps.append(command)
        if "/source" in command:
            self.calls.append(command)
            self.stdins.append(stdin)
            if not self.taps:
                return source_response(SAVED_SHEET_IOS)
            if len(self.taps) == 1:
                return source_response(with_remove_dialog(SAVED_SHEET_IOS))
            if self.obscured and len(self.taps) == 2:
                self.taps.append("settled")
                return source_response(with_remove_dialog(HIDDEN_PICKER))
            return source_response(
                SAVED_SHEET_IOS_REMOVED if self.removes else SAVED_SHEET_IOS
            )
        return super().__call__(command, stdin=stdin)


def test_remove_saved_card_taps_the_bin_beside_the_row_then_confirms():
    ssh = RemoveFakeSsh()

    driver(ssh).remove_saved_card()

    assert payloads_for(ssh, "/wda/tap")[0] == {"x": 360.0, "y": 358.0}
    assert len(payloads_for(ssh, "/wda/tap")) == 2


def test_remove_saved_card_raises_when_the_row_survives_the_confirmation():
    ssh = RemoveFakeSsh(removes=False)

    with pytest.raises(DriverError) as excinfo:
        driver(ssh).remove_saved_card(timeout=0)

    assert "still on the sheet" in str(excinfo.value)


def test_remove_saved_card_counts_the_picker_before_it_taps_anything():
    ssh = RemoveFakeSsh()

    driver(ssh).remove_saved_card()

    assert "/source" in ssh.calls[0]


def test_remove_saved_card_does_not_read_an_obscured_picker_as_a_removal():
    ssh = RemoveFakeSsh(removes=False, obscured=True)

    with pytest.raises(DriverError) as excinfo:
        driver(ssh).remove_saved_card(timeout=0)

    assert "still on the sheet" in str(excinfo.value)
    assert HIDDEN_PICKER != SAVED_SHEET_IOS


def test_remove_saved_card_says_so_when_there_is_nothing_to_remove():
    ssh = FakeSsh()

    with pytest.raises(DriverError) as excinfo:
        driver(ssh).remove_saved_card(timeout=0)

    assert "no stored-card row" in str(excinfo.value)


def test_select_saved_card_says_so_when_no_stored_card_is_offered():
    ssh = FakeSsh()

    with pytest.raises(DriverError) as excinfo:
        driver(ssh).select_saved_card(timeout=0)

    assert "no stored-card row" in str(excinfo.value)


def test_save_card_puts_the_scroll_back_where_it_found_it():
    ssh = SaveCardFakeSsh()

    driver(ssh).save_card()

    drags = payloads_for(ssh, "/wda/dragfromtoforduration")
    assert drags, "it has to scroll down to reach the toggle"
    assert drags[-1]["fromY"] < drags[-1]["toY"], drags[-1]
    assert drags[0]["fromY"] > drags[0]["toY"], drags[0]


def test_wait_saved_card_answers_false_rather_than_raising_when_none_is_offered():
    assert driver(FakeSsh()).wait_saved_card(timeout=0) is False


def test_type_cvv_fills_the_cvv_field_and_touches_nothing_else():
    ssh = FakeSsh()
    d = driver(ssh)
    tapped = []
    d._focus_field = lambda name: tapped.append(name)

    d.type_cvv("123")

    assert tapped == ["paycross.cvv"]
    assert typed_strings(ssh) == ["1", "2", "3"]


def test_type_cvv_tries_the_keyboard_away_without_failing_the_cell_over_it():
    ssh = KeyboardFakeSsh(clears_on_tap=False)
    d = driver(ssh)
    d._focus_field = lambda name: None

    d.type_cvv("123")

    keys_at = max(i for i, c in enumerate(ssh.calls) if "/wda/keys" in c)
    dismiss_at = next(i for i, c in enumerate(ssh.calls) if "keyboard/dismiss" in c)
    assert dismiss_at > keys_at


def test_type_cvv_does_not_read_the_digits_back():
    ssh = FakeSsh()
    d = driver(ssh)
    d._focus_field = lambda name: None

    d.type_cvv("123")

    assert not any("/wda/element" in c for c in ssh.calls)


def test_type_card_leaves_the_cvv_out_of_the_read_back():
    ssh = FakeSsh()
    d = driver(ssh)
    filled = []
    d._focus_field = lambda name: None
    d._fill = lambda name, value: filled.append(name)

    d.type_card(Card(pan="4111111111170000", expiry="12/28", cvv="123"))

    assert filled == [
        "paycross.cardholderName",
        "paycross.cardNumber",
        "paycross.expiry",
    ]


def test_paste_token_refuses_an_empty_token_file(tmp_path):
    ssh = FakeSsh()

    with pytest.raises(DriverError) as excinfo:
        driver(ssh).paste_token(token_file(tmp_path, "   \n"))

    assert "empty" in str(excinfo.value)
    assert ssh.calls == []


def test_paste_token_refuses_something_that_is_not_shaped_like_a_token(tmp_path):
    ssh = FakeSsh()

    with pytest.raises(DriverError) as excinfo:
        driver(ssh).paste_token(token_file(tmp_path, '{"error": "unauthorized"}'))

    message = str(excinfo.value)
    assert "JWT" in message
    assert "Refusing to paste it" in message
    assert "unauthorized" not in message
    assert ssh.calls == []


def test_paste_token_never_puts_the_token_on_a_command_line(tmp_path):
    ssh = FakeSsh()
    d = driver(ssh)
    d.tap_identifier = lambda name, **kw: None

    d.paste_token(token_file(tmp_path))

    assert TOKEN not in ssh.joined()
    assert "eyJhbGciOiJSUzI1NiJ9" not in ssh.joined()
    carried = [
        (c, sent)
        for c, sent in zip(ssh.calls, ssh.stdins, strict=True)
        if sent is not None
    ]
    assert len(carried) == 2
    assert "pbcopy" in carried[0][0]
    assert carried[0][1] == TOKEN.encode()
    assert "pbcopy" in carried[1][0]
    assert TOKEN.encode() not in carried[1][1]


def test_paste_token_clears_the_pasteboard_even_when_the_paste_fails(tmp_path):
    ssh = FakeSsh()
    d = driver(ssh)

    def explode(name, **kw):
        raise DriverError("no Paste menu item")

    d.tap_identifier = explode

    with pytest.raises(DriverError):
        d.paste_token(token_file(tmp_path))

    sent = [s for s in ssh.stdins if s is not None]
    assert sent[0] == TOKEN.encode()
    assert TOKEN.encode() not in sent[-1]


def test_paste_token_reports_a_field_that_never_took_the_paste(tmp_path, monkeypatch):
    monkeypatch.setattr(ios, "TOKEN_READBACK_SECONDS", 0)
    blank = SOURCE_XML.replace('value="[REDACTED-SESSION-TOKEN]"', 'value=""')
    assert "[REDACTED-SESSION-TOKEN]" not in blank
    ssh = FakeSsh(xml=blank)
    d = driver(ssh)
    d.tap_identifier = lambda name, **kw: None

    with pytest.raises(DriverError) as excinfo:
        d.paste_token(token_file(tmp_path))

    message = str(excinfo.value)
    assert "Session token" in message
    assert TOKEN not in message


MOVED_XML = SOURCE_XML.replace(
    'name="Session token" label="Session token" value="[REDACTED-SESSION-TOKEN]" '
    'enabled="true" visible="true" x="20" y="190"',
    'name="Session token" label="Session token" value="[REDACTED-SESSION-TOKEN]" '
    'enabled="true" visible="true" x="20" y="90"',
)
assert MOVED_XML != SOURCE_XML, "the fixture's token field changed shape"


class MovingFieldFakeSsh(FakeSsh):
    def __init__(self):
        super().__init__()
        self.tapped = False

    def __call__(self, command, *, stdin=None):
        if "/wda/tap" in command:
            self.tapped = True
            self.calls.append(command)
            self.stdins.append(stdin)
            return json.dumps({"value": None})
        if "/source" in command:
            self.calls.append(command)
            self.stdins.append(stdin)
            return source_response(MOVED_XML if self.tapped else SOURCE_XML)
        return super().__call__(command, stdin=stdin)


def test_paste_token_long_presses_where_the_field_is_now(tmp_path):
    ssh = MovingFieldFakeSsh()
    d = driver(ssh)
    d.tap_identifier = lambda name, **kw: None

    d.paste_token(token_file(tmp_path))

    assert payloads_for(ssh, "/wda/tap") == [{"x": 201.0, "y": 266.0}]
    assert payloads_for(ssh, "/wda/touchAndHold") == [
        {"x": 201.0, "y": 166.0, "duration": 1.2}
    ]


HINTED_XML = SOURCE_XML.replace(
    'name="Session token" label="Session token" value="[REDACTED-SESSION-TOKEN]" '
    'enabled="true" visible="true" x="20" y="190"',
    'name="Session token&#10;eyJhbGciOi…" label="Session token&#10;eyJhbGciOi…" '
    'value="" enabled="true" visible="true" x="20" y="90"',
)
assert HINTED_XML != SOURCE_XML, "the fixture's token field changed shape"


class HintedFieldFakeSsh(FakeSsh):
    def __init__(self):
        super().__init__()
        self.tapped = False
        self.held = False

    def __call__(self, command, *, stdin=None):
        if "/wda/tap" in command:
            self.tapped = True
        if "touchAndHold" in command:
            self.held = True
        if "/source" in command:
            self.calls.append(command)
            self.stdins.append(stdin)
            hinted = self.tapped and not self.held
            return source_response(HINTED_XML if hinted else SOURCE_XML)
        return super().__call__(command, stdin=stdin)


def test_paste_token_re_resolves_the_field_while_its_hint_is_in_its_name(tmp_path):
    ssh = HintedFieldFakeSsh()
    d = driver(ssh)
    d.tap_identifier = lambda name, **kw: None

    d.paste_token(token_file(tmp_path))

    assert payloads_for(ssh, "/wda/touchAndHold") == [
        {"x": 201.0, "y": 166.0, "duration": 1.2}
    ]


def test_paste_token_hands_off_to_the_sheet_once_the_field_has_taken_it(tmp_path):
    ssh = FakeSsh()
    d = driver(ssh)
    tapped = []
    d.tap_identifier = lambda name, **kw: tapped.append(name)

    d.paste_token(token_file(tmp_path))

    assert tapped == [ios.PASTE_ITEM, "Pay"]


def test_paste_token_waits_for_the_sheet_that_the_example_pay_opens(
    tmp_path, monkeypatch
):
    monkeypatch.setattr(ios, "SCREEN_TIMEOUT_SECONDS", 0)
    no_sheet = SOURCE_XML.replace(
        'name="paycross.sheet" label="Pay €10.00"', 'name="notTheSheet"'
    )
    assert no_sheet != SOURCE_XML
    ssh = FakeSsh(xml=no_sheet)
    d = driver(ssh)
    d.tap_identifier = lambda name, **kw: None

    with pytest.raises(DriverError) as excinfo:
        d.paste_token(token_file(tmp_path))

    assert ios.PAY_BUTTON in str(excinfo.value)


def test_cancel_challenge_taps_the_bar_button_then_confirms():
    ssh = FakeSsh()
    d = driver(ssh)
    taps = []
    d.tap_identifier = lambda name, **kw: taps.append(name)

    d.cancel_challenge()

    assert taps == [ios.THREE_DS_CANCEL, ios.CANCEL_CONFIRM]


def test_cancel_form_taps_the_toolbar_cancel_then_confirms():
    ssh = FakeSsh()
    d = driver(ssh)
    taps = []
    d.tap_identifier = lambda name, **kw: taps.append((name, kw))

    d.cancel_form()

    assert [name for name, _ in taps] == [ios.SHEET_CANCEL, ios.CANCEL_CONFIRM]
    assert all(kw["identifier_only"] is True for _, kw in taps)


CANCEL_DIALOG_NODES = (
    '<XCUIElementTypeOther type="XCUIElementTypeOther" '
    'name="paycross.cancelDialog" label="Cancel Payment?" enabled="true" '
    'visible="true" x="40" y="300" width="322" height="200" index="80"/>'
    '<XCUIElementTypeButton type="XCUIElementTypeButton" '
    'name="paycross.cancelConfirm" label="Yes, Cancel" enabled="true" '
    'visible="true" x="220" y="440" width="120" height="44" index="81"/>'
    '<XCUIElementTypeButton type="XCUIElementTypeButton" '
    'name="paycross.cancelDismiss" label="Continue Payment" enabled="true" '
    'visible="true" x="60" y="440" width="120" height="44" index="82"/>'
)

WITH_CANCEL_DIALOG = SOURCE_XML.replace(
    "</XCUIElementTypeOther>", CANCEL_DIALOG_NODES + "</XCUIElementTypeOther>", 1
)
assert WITH_CANCEL_DIALOG != SOURCE_XML


class DismissFakeSsh(FakeSsh):
    def __init__(self, stays=False):
        super().__init__()
        self.stays = stays
        self.taps = 0

    def __call__(self, command, *, stdin=None):
        if "/wda/tap" in command:
            self.taps += 1
        if "/source" in command:
            self.calls.append(command)
            self.stdins.append(stdin)
            closed = self.taps >= 2 and not self.stays
            return source_response(SOURCE_XML if closed else WITH_CANCEL_DIALOG)
        return super().__call__(command, stdin=stdin)


def test_dismiss_cancel_presses_the_button_no_cell_ever_pressed():
    ssh = DismissFakeSsh()
    d = driver(ssh)
    tapped = []
    d.tap_identifier = lambda name, **kw: tapped.append(name) or setattr(
        ssh, "taps", ssh.taps + 1
    )

    d.dismiss_cancel()

    assert tapped == [ios.SHEET_CANCEL, ios.CANCEL_DISMISS]


def test_dismiss_cancel_waits_for_the_dialog_to_go_not_for_the_pay_button():
    ssh = DismissFakeSsh(stays=True)
    d = driver(ssh)
    d.tap_identifier = lambda name, **kw: setattr(ssh, "taps", ssh.taps + 1)

    with pytest.raises(DriverError) as excinfo:
        d.dismiss_cancel(timeout=0)

    assert "did not come back" in str(excinfo.value)
    assert any(ios._is_pay_button(n) for n in tree.parse_wda(WITH_CANCEL_DIALOG))


def test_cancel_form_reaches_the_toolbar_item_and_not_the_challenge_bar():
    ssh = FakeSsh()

    node = driver(ssh)._find(ios.SHEET_CANCEL, identifier_only=True)

    assert node.identifier == ios.SHEET_CANCEL
    assert node.bounds == (20, 76, 97, 112)


SIMCTL_NOTE = "Note: No display specified. Defaulting to display: LCD\n"


def console_response(size="9000", body="flutter: up\n"):
    return f"{size}\n{ios.CONSOLE_SIZE}\n{body}"


def shot_response(frame="", said=SIMCTL_NOTE):
    return f"{frame}\n{ios.SHOT_STDERR}\n{said}"


def test_screenshot_comes_back_base64_and_is_decoded():
    png = b"\x89PNG\r\n\x1a\n"
    ssh = FakeSsh(shot_response(base64.b64encode(png).decode()))

    assert driver(ssh).screenshot() == png


def test_screenshot_accepts_the_line_wrapping_base64_adds():
    png = b"\x89PNG\r\n\x1a\n" + b"\x00" * 300
    encoded = base64.b64encode(png).decode()
    wrapped = "\n".join(encoded[at : at + 76] for at in range(0, len(encoded), 76))
    ssh = FakeSsh(shot_response(wrapped))

    assert driver(ssh).screenshot() == png


def test_screenshot_names_what_simctl_said_when_it_took_no_frame():
    ssh = FakeSsh(shot_response(said="Invalid device: NO-SUCH-UDID\n"))

    with pytest.raises(DriverError) as excinfo:
        driver(ssh).screenshot()

    message = str(excinfo.value)
    assert "Invalid device" in message
    assert "C311AFDC-25FA-44A2-A800-10EB5A1039E3" in message


def test_screenshot_refuses_an_answer_that_never_arrived():
    ssh = FakeSsh("")

    with pytest.raises(DriverError):
        driver(ssh).screenshot()


def test_screenshot_refuses_to_hand_back_an_error_message_as_a_png():
    said = "Unable to boot device in current state: Shutdown\n"
    assert base64.b64decode("".join(said.split())), "the string stopped being a trap"

    ssh = FakeSsh(said)

    with pytest.raises(DriverError) as excinfo:
        driver(ssh).screenshot()

    assert "Unable to boot device" in str(excinfo.value)


def test_logs_since_before_launch_refuses_to_read_the_whole_console_log():
    ssh = FakeSsh()

    with pytest.raises(DriverError) as excinfo:
        driver(ssh).logs_since(datetime.now(timezone.utc))

    assert "launch()" in str(excinfo.value)
    assert ssh.calls == []


def test_a_launch_that_fails_early_drops_the_previous_cells_console_mark():
    ssh = FakeSsh()
    d = launched(ssh)
    assert d._console_from == CONSOLE_MARK
    ssh.outputs.append(DEVICE_LINE.replace("(Booted)", "(Shutdown)"))

    with pytest.raises(DriverError):
        d.launch()

    with pytest.raises(DriverError) as excinfo:
        d.logs_since(datetime.now(timezone.utc))
    assert "launch()" in str(excinfo.value)


def test_logs_since_reads_the_console_appended_since_this_launch():
    ssh = FakeSsh(console_response(body="flutter: hello\n"), "log output\n")
    d = launched(ssh)

    text = d.logs_since(datetime.now(timezone.utc) - timedelta(seconds=90))

    console = ssh.calls[0]
    assert f"tail -c +{CONSOLE_MARK + 1} {ios.CONSOLE_LOG}" in console
    assert "flutter: hello" in text


def test_logs_since_also_asks_the_unified_log_for_a_window_in_seconds():
    ssh = FakeSsh(console_response(), "log output\n")
    when = datetime.now(timezone.utc) - timedelta(seconds=90)

    text = launched(ssh).logs_since(when)

    command = ssh.calls[1]
    assert "log show" in command
    assert "--last 9" in command
    assert 'process == "Runner"' in command
    assert "log output" in text


def test_logs_since_lets_the_tools_own_complaints_into_the_evidence():
    ssh = FakeSsh(console_response(), "log output\n")

    launched(ssh).logs_since(datetime.now(timezone.utc))

    for command in ssh.calls[:2]:
        assert "2>/dev/null" not in command
        assert "2>&1" in command


def test_logs_since_refuses_a_console_that_never_grew_past_the_mark():
    ssh = FakeSsh(console_response(size=str(CONSOLE_MARK), body=""), "alive\n")

    with pytest.raises(DriverError) as excinfo:
        launched(ssh).logs_since(datetime.now(timezone.utc))

    assert "has not grown" in str(excinfo.value)


def test_logs_since_calls_a_console_log_that_vanished_a_rig_fault():
    gone = "wc: /Users/mikz/work/e2e/ios/run/console.log: No such file"
    ssh = FakeSsh(console_response(size=gone, body="tail: No such file\n"), "alive\n")

    with pytest.raises(DriverError) as excinfo:
        launched(ssh).logs_since(datetime.now(timezone.utc))

    message = str(excinfo.value)
    assert "has not grown" in message
    assert "No such file" in message


def test_logs_since_names_a_dead_capture_when_the_console_is_empty():
    ssh = FakeSsh(console_response(size=str(CONSOLE_MARK), body=""), "dead\n")

    with pytest.raises(DriverError) as excinfo:
        launched(ssh).logs_since(datetime.now(timezone.utc))

    assert "console capture is not running" in str(excinfo.value)


def test_logs_since_still_returns_a_console_that_outlived_its_capture():
    crash = "Fatal error: Unexpectedly found nil\n"
    ssh = FakeSsh(console_response(body=crash), "log output\n")

    text = launched(ssh).logs_since(datetime.now(timezone.utc))

    assert crash.strip() in text
    assert not any("kill -0" in c for c in ssh.calls)


def test_the_two_actions_this_platform_cannot_have_still_refuse():
    d = driver(FakeSsh())

    for call in (lambda: d.airplane(True), lambda: d.dont_keep_activities(True)):
        with pytest.raises(NotImplementedError):
            call()


LEGACY_XML = (
    '<XCUIElementTypeApplication type="XCUIElementTypeApplication" name="Runner" '
    'label="Runner" enabled="true" visible="true" x="0" y="0" width="402" '
    'height="874">'
    '<XCUIElementTypeStaticText type="XCUIElementTypeStaticText" '
    'name="Paid 1000 EUR - 7d8e12aa" label="Paid 1000 EUR - 7d8e12aa" value="" '
    'enabled="true" visible="true" x="16" y="200" width="370" height="24"/>'
    "</XCUIElementTypeApplication>"
)


def test_a_wait_that_times_out_on_a_legacy_label_names_the_missing_define():
    ssh = FakeSsh(xml=LEGACY_XML)

    with pytest.raises(DriverError) as excinfo:
        driver(ssh).wait_label(timeout=0, interval=0)

    assert "PAYCROSS_E2E" in str(excinfo.value)


def test_a_wait_that_times_out_on_nothing_at_all_does_not_blame_the_build():
    ssh = FakeSsh(xml="<XCUIElementTypeApplication/>")

    with pytest.raises(DriverError) as excinfo:
        driver(ssh).wait_label(timeout=0, interval=0)

    assert "PAYCROSS_E2E" not in str(excinfo.value)


def test_the_rig_host_and_remote_env_are_overridable_from_the_environment(monkeypatch):
    monkeypatch.setenv("PAYCROSS_E2E_SSH_HOST", "buildbox")
    monkeypatch.setenv("PAYCROSS_E2E_MAC_ENV", "export PATH=/usr/local/bin:$PATH; ")
    try:
        importlib.reload(ios)
        assert ios.SSH_HOST == "buildbox"
        assert ios.MAC_ENV == "export PATH=/usr/local/bin:$PATH; "
    finally:
        monkeypatch.undo()
        importlib.reload(ios)


def test_the_rig_host_and_remote_env_fall_back_to_this_workstation():
    assert ios.SSH_HOST == "mac"
    assert "DEVELOPER_DIR=/Applications/Xcode.app" in ios.MAC_ENV


def test_the_ios_driver_scopes_its_crash_markers_to_the_bundle_it_was_given():
    made = ios.IosDriver(ssh=FakeSsh(), bundle="com.example.other")

    assert made.package == "com.example.other"
    assert ios.IosDriver(ssh=FakeSsh()).package == ios.BUNDLE


def test_the_ios_driver_waits_through_the_sleep_it_was_given():
    slept = []

    ios.IosDriver(ssh=FakeSsh(), sleep=slept.append)._sleep(0.25)

    assert slept == [0.25]


def test_relaunch_does_not_truncate_the_console_log():
    ssh = FakeSsh(*launch_outputs())
    d = ios.IosDriver(ssh=ssh, sleep=lambda _: None)
    d.launch()
    ssh.calls.clear()
    ssh.outputs.extend(launch_outputs(stopping=True))

    d.relaunch()

    started = next(c for c in ssh.calls if "--console-pty" in c)
    assert f": > {ios.CONSOLE_LOG}" not in started


def test_relaunch_leaves_the_console_mark_where_the_launch_put_it():
    ssh = FakeSsh(*launch_outputs())
    d = ios.IosDriver(ssh=ssh, sleep=lambda _: None)
    d.launch()
    was = d._console_from
    ssh.outputs.extend(launch_outputs(stopping=True, mark=CONSOLE_MARK + 4096))

    d.relaunch()

    assert d._console_from == was


def test_relaunch_still_replaces_the_capture_and_the_session():
    ssh = FakeSsh(*launch_outputs())
    d = ios.IosDriver(ssh=ssh, sleep=lambda _: None)
    d.launch()
    ssh.calls.clear()
    ssh.outputs.extend(launch_outputs(stopping=True))

    d.relaunch()

    assert any("--console-pty" in c for c in ssh.calls)
    assert any("terminate" in c for c in ssh.calls)


def test_launch_no_longer_reads_or_refuses_a_locale():
    ssh = FakeSsh(*launch_outputs())

    ios.IosDriver(ssh=ssh, sleep=lambda _: None).launch()

    assert not any("AppleLocale" in call for call in ssh.calls)


def menu_item(name: str) -> tree.Node:
    return tree.parse_wda(
        f'<XCUIElementTypeMenuItem type="XCUIElementTypeMenuItem" name="{name}" '
        f'label="{name}" x="0" y="0" width="80" height="40" visible="true"/>'
    )[0]


def test_the_paste_item_is_matched_in_every_language_the_app_can_run_in():
    assert ios._is_paste_item(menu_item("Paste"))
    assert ios._is_paste_item(menu_item("Coller"))
    assert not ios._is_paste_item(menu_item("Scanner du texte"))
    assert ios.PASTE_ITEM == "Paste/Coller"


def test_the_demos_own_strings_do_not_move_with_the_device_language():
    assert ios.TOKEN_FIELD == "Session token"
    assert ios.EXAMPLE_PAY == "Pay"


def test_device_language_touches_the_simulator_at_all_before_the_next_launch():
    ssh = FakeSsh()
    d = driver(ssh)

    d.device_language("fr")

    assert ssh.calls == []


def test_the_next_launch_hands_the_app_its_language_as_argv():
    ssh = FakeSsh(*launch_outputs())
    d = ios.IosDriver(ssh=ssh, sleep=lambda _: None)
    d.device_language("fr")

    d.launch()

    started = next(c for c in ssh.calls if "--console-pty" in c)
    assert f"{ios.BUNDLE} -AppleLanguages '(fr)'" in started


def test_the_language_reaches_the_app_as_one_argument():
    ssh = FakeSsh(*launch_outputs())
    d = ios.IosDriver(ssh=ssh, sleep=lambda _: None)
    d.device_language("fr-FR")

    d.launch()

    started = next(c for c in ssh.calls if "--console-pty" in c)
    argv = shlex.split(started[started.index("xcrun") : started.index(" >>")])
    assert argv[-2:] == ["-AppleLanguages", "(fr-FR)"]


def test_device_language_default_drops_the_argument_again():
    ssh = FakeSsh(*launch_outputs())
    d = ios.IosDriver(ssh=ssh, sleep=lambda _: None)
    d.device_language("fr")
    d.device_language(ios.DEVICE_LANGUAGE_DEFAULT)

    d.launch()

    started = next(c for c in ssh.calls if "--console-pty" in c)
    assert "AppleLanguages" not in started
    assert f"{ios.BUNDLE} >>" in started


def test_a_driver_that_was_never_told_a_language_launches_as_it_always_did():
    ssh = FakeSsh(*launch_outputs())

    ios.IosDriver(ssh=ssh, sleep=lambda _: None).launch()

    started = next(c for c in ssh.calls if "--console-pty" in c)
    assert "AppleLanguages" not in started


def test_the_sheet_is_french_when_the_pay_button_says_payer():
    french = SOURCE_XML.replace("Pay \u20ac10.00", "Payer 10,00 \u20ac")
    assert french != SOURCE_XML
    ssh = FakeSsh(xml=french)

    assert driver(ssh).wait_french_sheet(timeout=0) is True


def test_the_sheet_is_not_french_on_the_english_fixture():
    ssh = FakeSsh(xml=SOURCE_XML)

    assert driver(ssh).wait_french_sheet(timeout=0) is False


def test_wait_rearmed_blames_the_rig_for_an_amount_it_cannot_spell():
    french = SOURCE_XML.replace("Total, \u20ac10.00", "Total, 10,00 \u20ac")
    assert french != SOURCE_XML
    ssh = FakeSsh(xml=french)

    with pytest.raises(DriverError) as excinfo:
        driver(ssh).wait_rearmed("\u20ac10.00", timeout=0, interval=0)

    message = str(excinfo.value)
    assert "10,00" in message
    assert "the rig, not the SDK" in message
    assert "the simulator is not drawing" in message
    assert ios.IosDriver.device_noun == "simulator"


def test_wait_rearmed_still_answers_false_for_a_sheet_that_did_not_re_arm():
    no_banner = SOURCE_XML.replace('name="paycross.errorBanner"', 'name="gone"')
    assert no_banner != SOURCE_XML

    assert (
        driver(FakeSsh(xml=no_banner)).wait_rearmed(
            "\u20ac10.00", timeout=0, interval=0
        )
        is False
    )


def test_present_token_does_not_wait_for_a_sheet_that_will_never_open(
    tmp_path, monkeypatch
):
    monkeypatch.setattr(ios, "SCREEN_TIMEOUT_SECONDS", 0)
    no_sheet = SOURCE_XML.replace(
        'name="paycross.sheet" label="Pay €10.00"', 'name="notTheSheet"'
    )
    ssh = FakeSsh(xml=no_sheet)
    d = driver(ssh)
    tapped = []
    d.tap_identifier = lambda name, **kw: tapped.append(name)

    d.present_token(token_file(tmp_path))

    assert tapped == [ios.PASTE_ITEM, "Pay"]
    other = driver(FakeSsh(xml=no_sheet))
    other.tap_identifier = lambda name, **kw: None
    with pytest.raises(DriverError, match="paycross.payButton"):
        other.paste_token(token_file(tmp_path))


def test_present_token_pastes_exactly_as_paste_token_does(tmp_path):
    ssh = FakeSsh()
    d = driver(ssh)
    d.tap_identifier = lambda name, **kw: None

    d.present_token(token_file(tmp_path))

    assert not any(TOKEN in command for command in ssh.calls)
    carried = [s for s in ssh.stdins if s]
    assert carried == [TOKEN.encode("utf-8"), b" "]


def test_present_token_still_refuses_something_that_is_not_a_token(tmp_path):
    ssh = FakeSsh()

    with pytest.raises(DriverError, match="JWT"):
        driver(ssh).present_token(token_file(tmp_path, '{"error": "unauthorized"}'))

    assert ssh.calls == []


def test_tap_example_pay_matches_the_identifier_and_not_the_challenge_bar():
    ssh = FakeSsh()
    d = driver(ssh)
    seen = []
    d.tap_identifier = lambda name, **kw: seen.append((name, kw))

    d.tap_example_pay()

    assert seen == [(ios.EXAMPLE_PAY, {"identifier_only": True})]


def test_enter_token_types_the_literal_verbatim():
    ssh = FakeSsh()

    driver(ssh).enter_token("not.a.real.token")

    assert payloads_for(ssh, "/wda/keys") == [{"value": list("not.a.real.token")}]


def test_enter_token_never_reads_a_file(tmp_path):
    missing = str(tmp_path / "absent.token")
    ssh = FakeSsh()

    driver(ssh).enter_token(missing)

    assert payloads_for(ssh, "/wda/keys") == [{"value": list(missing)}]


def test_enter_token_takes_a_literal_that_paste_token_would_refuse(tmp_path):
    with pytest.raises(DriverError, match="JWT"):
        driver(FakeSsh()).paste_token(token_file(tmp_path, "short"))

    driver(FakeSsh()).enter_token("short")


def test_enter_token_taps_the_field_before_it_types():
    ssh = FakeSsh()
    naps = []

    driver(ssh, naps).enter_token("abc")

    assert payloads_for(ssh, "/wda/tap") == [{"x": 201.0, "y": 266.0}]
    assert naps == [ios.SETTLE_SECONDS, ios.SETTLE_SECONDS]


def test_airplane_refuses_and_says_why(tmp_path):
    with pytest.raises(NotImplementedError) as excinfo:
        driver(FakeSsh()).airplane(True)

    assert "simulator" in str(excinfo.value)


def test_wait_acs_waits_for_the_challenge_bar_without_answering_it():
    ssh = FakeSsh()
    d = driver(ssh)
    d.tap_identifier = lambda name, **kw: pytest.fail("wait_acs must not tap")

    assert d.wait_acs(timeout=5) is True
    assert payloads_for(ssh, "/wda/tap") == []


def test_wait_acs_says_which_page_never_came():
    no_challenge = SOURCE_XML.replace(
        'name="paycross.threeDSCancel"', 'name="notTheBar"'
    )
    ssh = FakeSsh(xml=no_challenge)

    with pytest.raises(DriverError) as excinfo:
        driver(ssh).wait_acs(timeout=0)

    assert ios.THREE_DS_CANCEL in str(excinfo.value)


@pytest.mark.parametrize(
    "name, args",
    [
        ("tap_google_pay", ()),
        ("wait_google_pay", (30,)),
        ("wait_no_google_pay", (20,)),
    ],
)
def test_the_google_pay_vocabulary_refuses_and_says_it_is_android_only(name, args):
    with pytest.raises(NotImplementedError) as excinfo:
        getattr(driver(FakeSsh()), name)(*args)

    assert "Android-only" in str(excinfo.value)


def active_app(bundle):
    return json.dumps({"value": {"name": "", "pid": 8580, "bundleId": bundle}})


SPRINGBOARD = active_app("com.apple.springboard")
OUR_APP = active_app("com.paycross.flutterdemo")


def test_the_foreground_bundle_is_asked_of_wda_directly():
    ssh = FakeSsh(OUR_APP)

    assert driver(ssh)._foreground_bundle() == "com.paycross.flutterdemo"
    assert "/wda/activeAppInfo" in ssh.joined()


def test_the_foreground_bundle_needs_no_session():
    assert unlaunched(FakeSsh(SPRINGBOARD))._foreground_bundle() == (
        "com.apple.springboard"
    )


def test_an_answer_without_a_bundle_reads_as_nothing_frontmost():
    ssh = FakeSsh(json.dumps({"value": {"pid": 1}}))

    assert driver(ssh)._foreground_bundle() == ""


def test_wait_foreground_gives_up_naming_what_it_saw():
    ssh = FakeSsh(SPRINGBOARD)

    with pytest.raises(DriverError) as excinfo:
        driver(ssh)._wait_foreground(timeout=0)

    message = str(excinfo.value)
    assert "com.paycross.flutterdemo is not frontmost" in message
    assert "com.apple.springboard" in message


def test_wait_foreground_keeps_looking_until_the_app_is_back():
    ssh = FakeSsh(SPRINGBOARD, SPRINGBOARD, OUR_APP)
    naps = []

    driver(ssh, naps)._wait_foreground(interval=1)

    assert len(ssh.calls) == 3
    assert naps == [1, 1]


def test_background_goes_home_waits_and_re_activates():
    ssh = FakeSsh(
        json.dumps({"value": None}), SPRINGBOARD, json.dumps({"value": None}), OUR_APP
    )
    naps = []

    driver(ssh, naps).background(60)

    assert "http://127.0.0.1:8100/wda/homescreen" in ssh.calls[0]
    assert "/session/" not in ssh.calls[0]
    assert "/wda/activeAppInfo" in ssh.calls[1]
    assert "/session/sess-1/wda/apps/activate" in ssh.calls[2]
    assert payloads_for(ssh, "/wda/apps/activate") == [
        {"bundleId": "com.paycross.flutterdemo"}
    ]
    assert naps == [
        ios.BACKGROUND_SETTLE_SECONDS,
        60,
        ios.BACKGROUND_SETTLE_SECONDS,
    ]
    assert "apps/launch" not in ssh.joined()
    assert "simctl terminate" not in ssh.joined()


def test_background_refuses_a_home_screen_that_did_not_take():
    ssh = FakeSsh(json.dumps({"value": None}), OUR_APP)

    with pytest.raises(DriverError) as excinfo:
        driver(ssh).background(60)

    assert "still frontmost after /wda/homescreen" in str(excinfo.value)
    assert "apps/activate" not in ssh.joined()


def test_rotate_toggles_the_orientation_it_read():
    ssh = FakeSsh(json.dumps({"value": "PORTRAIT"}))
    naps = []

    driver(ssh, naps).rotate()

    assert payloads_for(ssh, "/orientation") == [{"orientation": "LANDSCAPE"}]
    assert naps == [ios.ROTATE_SETTLE_SECONDS]


def test_rotate_turns_back_from_landscape():
    ssh = FakeSsh(json.dumps({"value": "LANDSCAPE"}))

    driver(ssh).rotate()

    assert payloads_for(ssh, "/orientation") == [{"orientation": "PORTRAIT"}]


def test_the_settle_waits_are_this_rigs_own():
    assert (ios.BACKGROUND_SETTLE_SECONDS, ios.ROTATE_SETTLE_SECONDS) == (2, 2)


def test_kill_activity_terminates_the_app():
    ssh = FakeSsh()
    naps = []

    driver(ssh, naps).kill_activity()

    assert "xcrun simctl terminate" in ssh.calls[0]
    assert "com.paycross.flutterdemo" in ssh.calls[0]
    assert naps == [ios.SETTLE_SECONDS]


def test_dont_keep_activities_refuses_and_says_why():
    with pytest.raises(NotImplementedError) as excinfo:
        driver(FakeSsh()).dont_keep_activities(True)

    message = str(excinfo.value)
    assert "Android developer option" in message
    assert "platforms: [android]" in message


def test_the_unified_log_window_is_capped():
    ssh = FakeSsh(console_response(), "log output\n")
    slept = datetime.now(timezone.utc) - timedelta(seconds=35354)

    launched(ssh).logs_since(slept)

    assert f"--last {ios.LOG_WINDOW_CAP_SECONDS}s" in ssh.calls[1]


def test_the_cap_clears_the_longest_cell_the_matrix_can_run():
    assert ios.LOG_WINDOW_CAP_SECONDS > 3026


def test_a_capped_window_says_so_in_the_evidence_header():
    ssh = FakeSsh(console_response(), "log output\n")
    slept = datetime.now(timezone.utc) - timedelta(seconds=35354)

    text = launched(ssh).logs_since(slept)

    assert f"--last {ios.LOG_WINDOW_CAP_SECONDS}s" in text
    assert "capped" in text


def test_an_ordinary_cell_is_not_capped_and_says_nothing_about_it():
    ssh = FakeSsh(console_response(), "log output\n")
    when = datetime.now(timezone.utc) - timedelta(seconds=90)

    text = launched(ssh).logs_since(when)

    assert "--last 95s" in text
    assert "capped" not in text


def test_the_console_half_is_never_capped():
    ssh = FakeSsh(console_response(), "log output\n")
    slept = datetime.now(timezone.utc) - timedelta(seconds=35354)

    launched(ssh).logs_since(slept)

    assert f"tail -c +{CONSOLE_MARK + 1}" in ssh.calls[0]


def test_launch_refuses_a_simulator_a_previous_cell_left_turned():
    ssh = FakeSsh(*launch_outputs(orientation=json.dumps({"value": "LANDSCAPE"})))
    d = ios.IosDriver(ssh=ssh, sleep=lambda _: None)

    with pytest.raises(DriverError) as excinfo:
        d.launch()

    message = str(excinfo.value)
    assert "not upright" in message
    assert "LANDSCAPE" in message


def test_launch_is_happy_with_an_upright_simulator():
    ssh = FakeSsh(*launch_outputs())

    ios.IosDriver(ssh=ssh, sleep=lambda _: None).launch()

    assert "/orientation" in ssh.joined()
