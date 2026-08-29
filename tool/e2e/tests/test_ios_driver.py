"""The iOS driver, exercised against a fake ssh transport.

Nothing here touches the Mac. `FakeSsh` records the remote command line and
replays canned stdout with `ios._ssh`'s exact signature, so what a test asserts
on is the command line and the JSON body that would really go on the wire.
Every wait is recorded rather than taken, and the rig's real durations stay
pinned by asserting on what was recorded.
"""

import base64
import importlib
import json
import shlex
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from tool.e2e.cells import Card
from tool.e2e.drivers import ios
from tool.e2e.drivers.base import DriverError

FIXTURES = Path(__file__).parent / "fixtures"
SOURCE_XML = (FIXTURES / "ios-source.xml").read_text()

#: What `xcrun simctl list devices | grep <udid>` answers on the rig, trailing
#: space included.
DEVICE_LINE = "    iPhone 17 (C311AFDC-25FA-44A2-A800-10EB5A1039E3) (Booted) \n"

#: Shaped like the real thing -- base64url segments joined by dots -- because
#: the driver refuses anything that is not.
TOKEN = "eyJhbGciOiJSUzI1NiJ9.eyJzZXNzaW9uX2lkIjoiMDFhMCJ9.c2lnbmF0dXJlLWJ5dGVz"

#: `wc -c` then the backgrounded pid, which is what `_start_console` parses.
#: Non-zero on purpose: a log that already holds a previous cell's output is
#: the only shape in which reading from the mark differs from reading the file.
CONSOLE_MARK = 4096
CONSOLE_STARTED = f"    {CONSOLE_MARK}\n12345\n"

#: The same page after one swipe: fraud_suspected has come up into the window.
SCROLLED_XML = SOURCE_XML.replace(
    'name="fraud_suspected" label="fraud_suspected" value="" enabled="true" '
    'visible="false" x="16" y="1402"',
    'name="fraud_suspected" label="fraud_suspected" value="" enabled="true" '
    'visible="true" x="16" y="402"',
)
assert SCROLLED_XML != SOURCE_XML, "the fixture's fraud_suspected node changed shape"

#: The same page with the CVV field's numeric pad still up, covering the bottom
#: ~35% -- which is where the ISSUER DECLINES buttons and scroll_to's drag
#: origin both live.
KEYBOARD_XML = SOURCE_XML.replace(
    "</XCUIElementTypeOther>",
    '<XCUIElementTypeKeyboard type="XCUIElementTypeKeyboard" name="" label="" '
    'enabled="true" visible="true" x="0" y="564" width="402" height="310" '
    'index="11"/></XCUIElementTypeOther>',
    1,
)
assert "XCUIElementTypeKeyboard" in KEYBOARD_XML

#: A source in which WebDriverAgent reports nothing as visible at all. The
#: on-screen preference is inert against it, which is a rig fault rather than
#: a licence to tap off-screen coordinates.
BLIND_XML = SOURCE_XML.replace('visible="true"', 'visible="false"')
assert 'visible="true"' not in BLIND_XML


TRUNCATED = json.dumps({"value": "<XCUIElementTypeApplication"})


def payloads_for(ssh, path):
    """The JSON bodies actually put on the wire for `path`."""
    bodies = []
    for command in ssh.calls:
        if path in command and "printf %s " in command:
            raw = command.split("printf %s ", 1)[1].split(" | curl", 1)[0]
            bodies.append(json.loads(shlex.split(raw)[0]))
    return bodies


def typed_strings(ssh):
    """`_keys` sends {"value": [...]} one character at a time, as wda.py does."""
    return ["".join(b["value"]) for b in payloads_for(ssh, "/wda/keys")]


def source_response(xml=None):
    return json.dumps({"value": SOURCE_XML if xml is None else xml})


class FakeSsh:
    """Records the remote command line and replays canned stdout.

    Mirrors `ios._ssh`'s signature exactly, so nothing here can pass while the
    real transport is called differently. Explicit outputs are consumed in
    order; after they run out it answers any `/source` request with the
    fixture, a window-size request with the simulator's 402x874, and everything
    else with an empty WDA envelope. That fallback is what lets a multi-step
    action be exercised without hand-counting how many round trips it makes.
    """

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
    """Serves the unscrolled ACS page until a drag arrives, then the scrolled one."""

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
    """The CVV pad, which WDA cannot dismiss because it has no Done key.

    `clears_on_tap` is the difference between a pad that goes away when a
    neutral node is tapped and one that does not.
    """

    def __init__(self, clears_on_tap=True):
        super().__init__()
        self.clears_on_tap = clears_on_tap
        self.cleared = False

    def __call__(self, command, *, stdin=None):
        if "keyboard/dismiss" in command:
            self.calls.append(command)
            self.stdins.append(stdin)
            # The real envelope shape: HTTP 4xx with JSON in the body.
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
    """The driver under test, with every wait recorded instead of taken."""
    d = ios.IosDriver(ssh=ssh, sleep=(naps if naps is not None else []).append)
    d._session_id = session_id
    return d


def unlaunched(ssh, naps=None):
    """The same driver before `launch()`, so it has no session yet."""
    return driver(ssh, naps, session_id=None)


def launched(ssh, naps=None):
    """A driver that has really been through `launch()`.

    The console mark only exists on the far side of one, so anything reading
    the console log has to go through it rather than have it set by hand. The
    launch's own traffic is dropped so a test can index from its first call.
    """
    ssh.outputs = list(launch_outputs()) + ssh.outputs
    d = ios.IosDriver(ssh=ssh, sleep=(naps if naps is not None else []).append)
    d.launch()
    ssh.calls.clear()
    ssh.stdins.clear()
    return d


# -- _ssh, the one place the transport is real --------------------------------


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
    # Every call is bounded: a hung ssh would otherwise hold the whole matrix.
    assert seen["kwargs"]["timeout"] == ios.SSH_TIMEOUT_SECONDS
    assert seen["kwargs"]["capture_output"] is True


def test_ssh_turns_a_timeout_into_a_driver_error(monkeypatch):
    # A Mac that has gone to sleep raises TimeoutExpired out of subprocess,
    # which is not a DriverError -- so it escapes every polling loop and takes
    # the whole matrix down instead of failing one cell.
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
    # `simctl launch --console-pty` copies the app's output through a pty,
    # which turns every LF into CRLF on the way to the log.
    _stub_subprocess(monkeypatch, stdout=b"one\r\ntwo\r\nthree")

    assert ios._ssh("cat log") == "one\ntwo\nthree"


def test_ssh_surfaces_the_stderr_of_a_failed_remote_command(monkeypatch):
    # Discarding it is how "no route to host" reads as an empty log, and an
    # empty log is how criterion 3 passes on nothing.
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


# -- _wda ---------------------------------------------------------------------


def test_wda_calls_go_through_curl_on_the_mac_not_from_wsl():
    ssh = FakeSsh(json.dumps({"value": {"ready": True}}))

    driver(ssh)._wda("GET", "/status")

    command = ssh.calls[0]
    assert "curl" in command
    assert "http://127.0.0.1:8100/status" in command
    # A /source that has not answered in 30 s is not going to. The ceiling
    # matters because a look's own transport time is spent on top of the
    # poll's deadline, not inside it.
    assert ios.WDA_TIMEOUT_SECONDS == 30
    assert "-m 30" in command
    # WDA is bound to the Mac's loopback; there is nothing to reach from WSL.
    assert command.count("http://") == 1


def test_wda_puts_the_body_on_stdin_rather_than_the_command_line():
    ssh = FakeSsh()

    driver(ssh)._wda("POST", "/session/sess-1/wda/tap", {"x": 1.0, "y": 2.0})

    command = ssh.calls[0]
    assert "printf %s " in command and "--data-binary @-" in command
    assert payloads_for(ssh, "/wda/tap") == [{"x": 1.0, "y": 2.0}]


def test_wda_raises_on_the_error_envelope_rather_than_returning_it():
    # WDA reports a failure as HTTP 4xx with a JSON body, which curl -s prints
    # and json.loads accepts -- so an unchecked call is completely silent and
    # the damage surfaces one caller later as a KeyError or an AttributeError.
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
    # The ~10 KB traceback must not reach problems or result.json.
    assert len(text) < 400


def test_wda_raises_when_the_answer_is_not_json():
    # curl's own failures arrive as a sentence, which json.loads answers with a
    # JSONDecodeError -- not a DriverError, so it escapes every polling loop.
    ssh = FakeSsh("curl: (7) Failed to connect to 127.0.0.1 port 8100\n")

    with pytest.raises(DriverError) as excinfo:
        driver(ssh)._wda("GET", "/status")

    assert "Failed to connect" in str(excinfo.value)


def test_wda_raises_when_the_answer_is_empty():
    ssh = FakeSsh("   \n")

    with pytest.raises(DriverError) as excinfo:
        driver(ssh)._wda("GET", "/status")

    assert "/status" in str(excinfo.value)


# -- launch -------------------------------------------------------------------


#: WebDriverAgent reports whatever session is currently open at the top level
#: of /status, and null when there is none.
NO_OPEN_SESSION = json.dumps({"value": {"ready": True}, "sessionId": None})


def launch_outputs(
    session=None,
    alive="alive\n",
    status=NO_OPEN_SESSION,
    *,
    stopping=False,
    mark=CONSOLE_MARK,
    locale="en_US@rg=lvzzzz\n",
):
    """One launch's worth of remote answers, in the order launch() asks.

    `stopping` is for a second launch on the same driver: the first one left a
    capture behind, so `_stop_console` has a round trip of its own. `mark` is
    what `wc -c` reports -- a relaunch measures a log that has grown. `locale`
    is what `defaults read -g AppleLocale` answers; the default is what this
    rig's simulator really says.
    """
    stale = json.loads(status).get("sessionId")
    return (
        DEVICE_LINE,
        locale,
        *(["gone\n"] if stopping else []),
        status,
        # Only asked for when /status named one.
        *([json.dumps({"value": None})] if stale else []),
        "",
        f"    {mark}\n12345\n",
        session or json.dumps({"value": {"sessionId": "sess-9"}}),
        alive,
    )


def test_a_hostile_udid_cannot_break_out_of_a_command():
    # Constructor arguments, not constants, once the runner takes --udid.
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
    assert "com.paycross.paycrossFlutterExample" in joined


def test_launch_accepts_the_older_top_level_session_id_shape():
    ssh = FakeSsh(*launch_outputs(session=json.dumps({"sessionId": "sess-8"})))
    d = ios.IosDriver(ssh=ssh, sleep=lambda _: None)

    d.launch()

    assert d._session_id == "sess-8"


def test_launch_captures_the_app_console_because_the_sdk_emits_no_os_log():
    # criterion 3's iOS markers -- Swift's `Fatal error:`, ObjC's `***
    # Terminating app`, Dart's `Unhandled Exception:` -- reach stdout and
    # stderr, not the unified log. Without this capture `log show` alone
    # answers with nothing and "nothing crashed" passes on an empty window.
    ssh = FakeSsh(*launch_outputs())
    d = ios.IosDriver(ssh=ssh, sleep=lambda _: None)

    d.launch()

    started = next(c for c in ssh.calls if "--console-pty" in c)
    assert ios.CONSOLE_LOG in started
    # Backgrounded: --console-pty blocks for the app's whole lifetime.
    assert "nohup" in started and "echo $!" in started
    # And the byte offset the log had beforehand is what logs_since reads from.
    assert d._console_from == CONSOLE_MARK


def test_launch_kills_the_previous_capture_before_starting_another():
    # Two of them interleave into one log, and the older one still owns the app
    # it launched. Killed before the terminate, so the app it holds goes too.
    ssh = FakeSsh(*launch_outputs())
    d = ios.IosDriver(ssh=ssh, sleep=lambda _: None)
    d.launch()
    # The device and locale checks come first, then the kill, then the
    # terminate.
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
    # launch() clears the *previous* cell's capture, so without this the last
    # one of a run outlives the run: a simctl still holding the app, and a log
    # still being written to.
    ssh = FakeSsh(*launch_outputs())
    d = ios.IosDriver(ssh=ssh, sleep=lambda _: None)
    d.launch()
    ssh.outputs = ["gone\n"]
    ssh.calls.clear()

    d.close()

    assert any("kill 12345" in c for c in ssh.calls)
    assert d._console_pid is None


def test_close_before_launch_does_nothing():
    # Task 9 calls it in a finally, which runs whether or not launch() got far
    # enough to start anything -- so with no capture and no session there is
    # nothing to say to the Mac at all.
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
    # Documented on the ABC, because a caller running close() in a finally has
    # to decide whether to let this stand in for the failure it was reporting.
    ssh = FakeSsh(*launch_outputs())
    d = ios.IosDriver(ssh=ssh, sleep=lambda _: None)
    d.launch()
    ssh.outputs = ["alive\n"]

    with pytest.raises(DriverError) as excinfo:
        d.close()

    assert "12345" in str(excinfo.value)


def test_launch_truncates_the_console_log_so_it_cannot_grow_unbounded():
    # The runner reads a cell's logs before the next launch, so the previous
    # cell's console has already been collected by the time this happens.
    ssh = FakeSsh(*launch_outputs())

    ios.IosDriver(ssh=ssh, sleep=lambda _: None).launch()

    started = next(c for c in ssh.calls if "--console-pty" in c)
    assert f": > {ios.CONSOLE_LOG}" in started


def test_launch_does_not_let_the_session_relaunch_the_app_out_from_under_it():
    # POST /session with a bundleId launches -- which for XCUIApplication means
    # terminate-then-launch -- and that kills the console capture started one
    # step earlier. `forceAppLaunch: false` was meant to activate the running
    # instance instead; it is a literal in the 16.2.2 binary but it does not
    # stop the relaunch, measured on the rig 2026-08-29 where it failed every
    # cell in _check_console. So the session names no bundle at all: it then
    # launches nothing and attaches to whatever is foreground. Everything asked
    # of a session here is coordinate- or device-level (tap, drag, keys,
    # keyboard/dismiss, window/size) and /source is unscoped, so nothing needs
    # the binding.
    ssh = FakeSsh(*launch_outputs())

    ios.IosDriver(ssh=ssh, sleep=lambda _: None).launch()

    capabilities = payloads_for(ssh, "/session")[0]["capabilities"]["alwaysMatch"]
    assert "bundleId" not in capabilities
    assert "forceAppLaunch" not in capabilities
    # The Flutter engine never quiesces, so waiting for it times the request out.
    assert capabilities["shouldWaitForQuiescence"] is False


def test_launch_closes_a_session_left_open_before_it_starts_the_capture():
    # Measured on the rig 2026-08-29, and the second failure of the live run:
    # an existing session bound to a bundleId terminates its app under test
    # when a new session displaces it. The app it terminates is the instance
    # this driver just launched, so the --console-pty capture goes with it and
    # _check_console fails the cell. Closing the stale session first spends
    # that termination on an app nobody is capturing yet.
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
    # No session is open once this returns, whichever branch it took, so an id
    # kept from the previous cell would name one that no longer exists.
    ssh = FakeSsh(status, *answers)
    d = driver(ssh, session_id="sess-old")

    d._close_open_session()

    assert d._session_id is None


def test_launch_does_not_delete_a_session_when_none_is_open():
    ssh = FakeSsh(*launch_outputs())

    ios.IosDriver(ssh=ssh, sleep=lambda _: None).launch()

    assert not [c for c in ssh.calls if "DELETE" in c]


def test_close_deletes_the_session_it_opened():
    # Otherwise the run leaves one open, and the next run's launch pays for it.
    ssh = FakeSsh(*launch_outputs())
    d = ios.IosDriver(ssh=ssh, sleep=lambda _: None)
    d.launch()
    ssh.outputs = ["gone\n", json.dumps({"value": None})]
    ssh.calls.clear()

    d.close()

    assert [c for c in ssh.calls if "DELETE" in c and "sess-9" in c]


def test_close_deletes_the_session_even_when_the_capture_will_not_die():
    # close() runs in the runner's finally; a capture that will not die must
    # not also strand the session.
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
    # The log is named, never quoted: the app's own output is redacted on its
    # way into evidence, and a DriverError is not on that path.
    assert ios.CONSOLE_LOG in message
    # The liveness question is asked once the session has had its chance to
    # relaunch the app, which is the only thing that could kill the capture.
    asked = next(i for i, c in enumerate(ssh.calls) if "kill -0" in c)
    session = next(i for i, c in enumerate(ssh.calls) if "/session" in c)
    assert asked > session


def test_launch_reports_a_console_capture_that_would_not_start():
    ssh = FakeSsh(
        DEVICE_LINE, "en_US\n", NO_OPEN_SESSION, "", "sh: xcrun: command not found\n"
    )

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
    # grep finds nothing and exits 1, so the "answer" is empty. Reading that as
    # a state would report a simulator part-way through booting when the truth
    # is that there is no such simulator -- the emulator lesson, transposed.
    ssh = FakeSsh("")

    with pytest.raises(DriverError) as excinfo:
        ios.IosDriver(ssh=ssh, sleep=lambda _: None).launch()

    message = str(excinfo.value)
    assert "names no simulator" in message
    assert "C311AFDC-25FA-44A2-A800-10EB5A1039E3" in message
    # And not dressed up as a state simctl never reported.
    assert "Booted" not in message


def test_launch_settles_before_it_asks_wda_for_a_session():
    ssh = FakeSsh(*launch_outputs())
    naps = []

    ios.IosDriver(ssh=ssh, sleep=naps.append).launch()

    assert ios.LAUNCH_SETTLE_SECONDS == 6
    assert naps == [6]


# -- install ------------------------------------------------------------------


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


# -- dump_tree ----------------------------------------------------------------


def test_dump_tree_unwraps_the_json_envelope():
    ssh = FakeSsh(source_response())

    assert driver(ssh).dump_tree() == SOURCE_XML.encode()


def test_dump_tree_retries_a_source_that_came_back_unparsable():
    # A truncated body raises ParseError out of _nodes, which is not a
    # DriverError, so it escapes every polling loop and aborts the cell for one
    # transient read.
    ssh = FakeSsh(TRUNCATED, source_response())

    assert driver(ssh).dump_tree(interval=0) == SOURCE_XML.encode()


def test_dump_tree_gives_up_as_a_driver_error_carrying_what_it_saw():
    ssh = FakeSsh(*([TRUNCATED] * 3))

    with pytest.raises(DriverError) as excinfo:
        driver(ssh).dump_tree(attempts=3, interval=0)

    message = str(excinfo.value)
    assert "XCUIElementTypeApplication" in message
    # An excerpt, not the tree: a real dump holds the example's token field.
    assert len(message) < 600


def test_dump_tree_refuses_an_envelope_whose_value_is_not_the_source():
    ssh = FakeSsh(*([json.dumps({"value": {"ready": True}})] * 3))

    with pytest.raises(DriverError) as excinfo:
        driver(ssh).dump_tree(attempts=3, interval=0)

    assert "dict" in str(excinfo.value)


# -- the polling waits --------------------------------------------------------


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
    # WDA answers mid-transition with a body that stops halfway. Three of those
    # must not end a cell that still has 10 s of its own deadline left.
    refused = [TRUNCATED] * ios._DUMP_ATTEMPTS
    ssh = FakeSsh(*refused, source_response())

    label = driver(ssh).wait_label(timeout=10, interval=0)

    assert label.startswith("result:success:")


def test_a_wait_past_its_deadline_blames_the_dump_not_the_missing_node():
    # Once the deadline is gone the tolerance goes with it, so the error names
    # the source rather than reporting a label that was never looked for.
    ssh = FakeSsh(*([TRUNCATED] * 3))

    with pytest.raises(DriverError) as excinfo:
        driver(ssh).wait_label(timeout=0, interval=0)

    assert "source" in str(excinfo.value)


def test_wait_rearmed_is_true_when_the_banner_is_in_the_tree_but_offscreen():
    ssh = FakeSsh(source_response())

    # The fixture's payButton is labelled "Pay €10.00", and sheet_rearmed now
    # asks that the amount be this cell's rather than any sheet's at all.
    assert driver(ssh).wait_rearmed("€10.00", timeout=10, interval=0) is True


def test_wait_rearmed_is_false_when_the_sheet_re_armed_at_another_amount():
    ssh = FakeSsh(source_response())

    assert driver(ssh).wait_rearmed("€12.50", timeout=0, interval=0) is False


def test_wait_rearmed_gives_up_and_says_so():
    ssh = FakeSsh(*([json.dumps({"value": "<XCUIElementTypeApplication/>"})] * 3))

    assert driver(ssh).wait_rearmed("€10.00", timeout=0, interval=0) is False


# -- finding and tapping ------------------------------------------------------


def test_tap_identifier_uses_the_node_centre():
    ssh = FakeSsh()

    driver(ssh).tap_identifier("payButton")

    assert payloads_for(ssh, "/wda/tap") == [{"x": 201.0, "y": 815.0}]


def test_tap_identifier_that_is_not_there_says_what_it_looked_for():
    ssh = FakeSsh()

    with pytest.raises(DriverError) as excinfo:
        driver(ssh).tap_identifier("noSuchThing", timeout=0, interval=0)

    assert "noSuchThing" in str(excinfo.value)


def test_tap_pay_uses_the_sheets_own_identifier_not_the_amount():
    # Unlike Android, where the button's text is the only handle there is.
    ssh = FakeSsh()

    driver(ssh).tap_pay("EUR 10.00")

    assert payloads_for(ssh, "/wda/tap") == [{"x": 201.0, "y": 815.0}]


def test_find_prefers_a_node_that_is_actually_on_screen():
    ssh = FakeSsh()
    d = driver(ssh)

    # In the tree at y=1402 on an 874pt sheet: addressable, not tappable.
    assert d._find("fraud_suspected", timeout=0).bounds[1] == 1402
    with pytest.raises(DriverError):
        d._find("fraud_suspected", timeout=0, require_on_screen=True)


def test_find_calls_a_source_that_reports_no_visibility_at_all_a_rig_fault():
    # Falling back to an off-screen node is only defensible while WDA is
    # reporting visibility. If nothing in the whole source carries it, the
    # on-screen preference is inert and every tap lands at raw coordinates.
    ssh = FakeSsh(xml=BLIND_XML)

    with pytest.raises(DriverError) as excinfo:
        driver(ssh)._find("payButton", timeout=0)

    assert "visible" in str(excinfo.value)


def test_find_identifier_only_does_not_match_a_label():
    ssh = FakeSsh()
    d = driver(ssh)

    # threeDSCancel is *labelled* "Cancel"; the sheet's toolbar item is named
    # it. Both are on screen, so which one a tap reaches is decided purely by
    # whether the label half of the matcher is on.
    assert d._find("threeDSCancel").identifier == "threeDSCancel"
    assert [n.identifier for n in d._matches("Cancel")] == ["Cancel", "threeDSCancel"]
    only = d._matches("Cancel", identifier_only=True)
    assert [n.identifier for n in only] == ["Cancel"]


def test_find_refuses_an_empty_name_rather_than_matching_the_whole_tree():
    # Every untagged element carries name="" and label="", which is most of a
    # real source, so the tap would land on an arbitrary one.
    ssh = FakeSsh()

    with pytest.raises(DriverError):
        driver(ssh)._find("", timeout=0)

    assert ssh.calls == []


def test_a_call_before_launch_says_there_is_no_session():
    ssh = FakeSsh()

    with pytest.raises(DriverError) as excinfo:
        unlaunched(ssh).tap_identifier("payButton")

    assert "launch()" in str(excinfo.value)


# -- scrolling and the ACS page -----------------------------------------------


def test_scroll_to_does_not_swipe_when_the_target_is_already_on_screen():
    ssh = ScrollingFakeSsh()

    node = driver(ssh).scroll_to("approve", settle=0)

    assert node.identifier == "approve"
    assert not any("dragfromtoforduration" in c for c in ssh.calls)


def test_acs_scrolls_until_the_outcome_is_on_screen_then_taps():
    # fraud_suspected lives in ISSUER DECLINES, below the fold on a 402x874
    # sheet. Without a scroll the tap lands on whatever is at y=1402.
    ssh = ScrollingFakeSsh()

    driver(ssh).acs("fraud_suspected", timeout=0, settle=0)

    assert any("dragfromtoforduration" in c for c in ssh.calls)
    tap = payloads_for(ssh, "/wda/tap")[-1]
    assert tap["y"] == 424.0  # 402 + 44/2, i.e. on screen
    assert 0 <= tap["y"] <= 874


def test_acs_gives_up_with_a_named_error_if_scrolling_never_reveals_it():
    ssh = FakeSsh()  # always the unscrolled page

    with pytest.raises(DriverError) as excinfo:
        driver(ssh).acs("fraud_suspected", timeout=0, max_swipes=2, settle=0)

    assert "fraud_suspected" in str(excinfo.value)
    # N swipes means N drags, with a look before the first and after the last.
    assert len([c for c in ssh.calls if "dragfromtoforduration" in c]) == 2


def test_acs_puts_the_keyboard_away_before_it_tries_to_scroll():
    # scroll_to drags from height * 0.75 = y~655, which is inside a keyboard
    # whose top is y~564: a pad left up swallows every swipe AND hides the
    # decline outcomes, so the cell burns all twelve and fails anyway.
    ssh = KeyboardFakeSsh(clears_on_tap=True)

    with pytest.raises(DriverError):
        driver(ssh).acs("fraud_suspected", timeout=0, max_swipes=1, settle=0)

    dismissed = next(i for i, c in enumerate(ssh.calls) if "keyboard/dismiss" in c)
    dragged = next(i for i, c in enumerate(ssh.calls) if "dragfromtoforduration" in c)
    assert dismissed < dragged


def test_scroll_to_calls_a_blind_source_a_rig_fault_rather_than_swiping():
    # require_on_screen can never be satisfied by a source that marks nothing
    # visible, so without the check the cell burns every swipe and then reports
    # a button that "never came on screen" -- a plausible wrong diagnosis.
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


# -- the keyboard -------------------------------------------------------------


def test_dismiss_keyboard_taps_a_neutral_node_when_the_pad_will_not_go():
    # The CVV pad is numeric: no Done, no Return, so dismissKeyboard has
    # nothing to press and answers with an error envelope. `amount` is
    # SDK-tagged and never interactive.
    ssh = KeyboardFakeSsh(clears_on_tap=True)

    driver(ssh).dismiss_keyboard(settle=0)

    assert any("keyboard/dismiss" in c for c in ssh.calls)
    assert payloads_for(ssh, "/wda/tap") == [{"x": 201.0, "y": 214.0}]


def test_dismiss_keyboard_raises_if_the_pad_survives_even_that():
    # Failing here beats burning every swipe: scroll_to drags from y=655,
    # which is inside a keyboard whose top is around y=564.
    ssh = KeyboardFakeSsh(clears_on_tap=False)

    with pytest.raises(DriverError) as excinfo:
        driver(ssh).dismiss_keyboard(settle=0)

    assert "keyboard is still up" in str(excinfo.value)


def test_dismiss_keyboard_reports_rather_than_raises_when_it_is_not_required():
    # type_card's call is a tidy-up: on the card form the pad covers nothing
    # that matters, because payButton sits above it. Only acs() needs it gone.
    ssh = KeyboardFakeSsh(clears_on_tap=False)

    assert driver(ssh).dismiss_keyboard(settle=0, required=False) is False


def test_dismiss_keyboard_says_so_when_the_pad_did_go():
    ssh = KeyboardFakeSsh(clears_on_tap=True)

    assert driver(ssh).dismiss_keyboard(settle=0) is True


def test_type_card_does_not_fail_a_cell_over_a_pad_that_will_not_go():
    # Measured on the rig 2026-08-29: nothing dismisses this pad. It is
    # numeric, so it has no Done or Return key; XCUIApplication.dismissKeyboard
    # answers "invalid element state"; and taps on 'amount', on TOTAL, on the
    # navigation bar and a drag down the form all leave it up -- the SwiftUI
    # form offers no affordance at all. Every cell failed here, including
    # control, which never sees an ACS page.
    ssh = KeyboardFakeSsh(clears_on_tap=False)
    d = driver(ssh)
    d.tap_identifier = lambda name, **kw: None

    d.type_card(Card(pan="4111111111170000", expiry="12/28", cvv="123"))

    assert any("keyboard/dismiss" in c for c in ssh.calls)


def test_dismiss_keyboard_does_nothing_at_all_when_no_pad_is_up():
    # acs() calls this on a page that has no keyboard, where dismissKeyboard
    # would answer with an error envelope and cost two round trips to learn
    # nothing.
    ssh = FakeSsh()

    driver(ssh).dismiss_keyboard(settle=0)

    assert payloads_for(ssh, "/wda/tap") == []
    assert not any("keyboard/dismiss" in c for c in ssh.calls)


def test_dismiss_keyboard_refuses_a_fallback_target_behind_the_pad():
    # Tapping a node the keyboard covers types into the keyboard. `amount` sits
    # above it on the card form, but a scrolled sheet -- or another screen --
    # can put it underneath.
    covered = KEYBOARD_XML.replace(
        'name="amount" label="10.00 EUR" value="10.00 EUR" enabled="true" '
        'visible="true" x="16" y="192"',
        'name="amount" label="10.00 EUR" value="10.00 EUR" enabled="true" '
        'visible="true" x="16" y="600"',
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


# -- typing -------------------------------------------------------------------


def test_type_card_fills_the_fields_by_identifier_in_form_order():
    ssh = FakeSsh()
    d = driver(ssh)
    tapped = []
    d.tap_identifier = lambda name, **kw: tapped.append(name)

    d.type_card(Card(pan="4111111111170000", expiry="12/28", cvv="123"))

    assert tapped == ["cardholderName", "cardNumber", "expiry", "cvv"]
    # The wire carries a character list, not the contiguous string -- WDA's
    # /wda/keys takes {"value": [...]}, which is what wda.py sends too.
    assert typed_strings(ssh) == ["John Doe", "4111111111170000", "1228", "123"]


def test_type_card_dismisses_the_keyboard_the_cvv_field_raised():
    # It covers the bottom ~35% of the sheet, which is where the ACS page's
    # decline outcomes land. Android drops the IME for the same reason.
    ssh = KeyboardFakeSsh(clears_on_tap=True)
    d = driver(ssh)
    d.tap_identifier = lambda name, **kw: None

    d.type_card(Card(pan="4111111111170000", expiry="12/28", cvv="123"))

    keys_at = max(i for i, c in enumerate(ssh.calls) if "/wda/keys" in c)
    dismiss_at = next(i for i, c in enumerate(ssh.calls) if "keyboard/dismiss" in c)
    assert dismiss_at > keys_at


def test_type_card_settles_between_the_taps_and_the_keystrokes():
    ssh = FakeSsh()
    naps = []
    d = driver(ssh, naps)
    d.tap_identifier = lambda name, **kw: None

    d.type_card(Card(pan="4111111111170000", expiry="12/28", cvv="123"))

    # Four and a half seconds on the rig: two per field and one after
    # dismiss_keyboard, which on this tree finds no pad and returns at once.
    # Asserted here rather than spent.
    assert ios.SETTLE_SECONDS == 0.5
    assert naps == [0.5] * 9


# -- paste_token --------------------------------------------------------------


def test_paste_token_refuses_an_empty_token_file(tmp_path):
    ssh = FakeSsh()

    with pytest.raises(DriverError) as excinfo:
        driver(ssh).paste_token(token_file(tmp_path, "   \n"))

    assert "empty" in str(excinfo.value)
    # Before any transport at all.
    assert ssh.calls == []


def test_paste_token_refuses_something_that_is_not_shaped_like_a_token(tmp_path):
    # A mint that answered with an error document would otherwise be pasted as
    # though it were a credential and come back as an instant 401.
    ssh = FakeSsh()

    with pytest.raises(DriverError) as excinfo:
        driver(ssh).paste_token(token_file(tmp_path, '{"error": "unauthorized"}'))

    message = str(excinfo.value)
    assert "JWT" in message
    # The shape check is shared with Android; the verb is this transport's own
    # word, so the message still says what was about to happen.
    assert "Refusing to paste it" in message
    # The value is never echoed, whatever it turned out to be.
    assert "unauthorized" not in message
    assert ssh.calls == []


def test_paste_token_never_puts_the_token_on_a_command_line(tmp_path):
    ssh = FakeSsh()
    d = driver(ssh)
    d.tap_identifier = lambda name, **kw: None

    d.paste_token(token_file(tmp_path))

    # A command line is world-readable for as long as the process lives, on
    # either machine, and this one never lands on the Mac's disk at all.
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
    # And the pasteboard does not keep it: left alone it outlives the cell and
    # anything on the simulator can read it.
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
    # An empty pasteboard or a long-press that missed leaves the field as it
    # was, and the run would only find out as a 401 that reads as an SDK bug.
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


#: The token field one tap later. Tapping it raises the keyboard, which on a
#: short screen scrolls the field up from under the coordinates it had.
MOVED_XML = SOURCE_XML.replace(
    'name="Session token" label="Session token" value="[REDACTED-SESSION-TOKEN]" '
    'enabled="true" visible="true" x="20" y="190"',
    'name="Session token" label="Session token" value="[REDACTED-SESSION-TOKEN]" '
    'enabled="true" visible="true" x="20" y="90"',
)
assert MOVED_XML != SOURCE_XML, "the fixture's token field changed shape"


class MovingFieldFakeSsh(FakeSsh):
    """Serves the token field where it starts, then where the tap left it."""

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
    # The tap that precedes the long press raises the keyboard, and the field
    # moves. Held at its old centre, the long press lands on whatever took its
    # place and there is no Paste menu at all.
    ssh = MovingFieldFakeSsh()
    d = driver(ssh)
    d.tap_identifier = lambda name, **kw: None

    d.paste_token(token_file(tmp_path))

    assert payloads_for(ssh, "/wda/tap") == [{"x": 201.0, "y": 266.0}]
    assert payloads_for(ssh, "/wda/touchAndHold") == [
        {"x": 201.0, "y": 166.0, "duration": 1.2}
    ]


#: The token field while it is focused and still empty -- the one state whose
#: accessible name is not "Session token". Flutter merges a focused, empty
#: field's hint into its semantics label, and the example's hint is a sample
#: JWT prefix (example/lib/main.dart:124), so the name reads
#: "Session token\neyJhbGciOi…". Measured on the rig 2026-08-29 against
#: Flutter 3.47.0 / iOS 26.5, where it failed the live run's first paste.
#: Moved as well as renamed, exactly as MOVED_XML is: the tap raises the
#: keyboard and the field scrolls, so the coordinates say which node the long
#: press was aimed from rather than merely that one was found.
HINTED_XML = SOURCE_XML.replace(
    'name="Session token" label="Session token" value="[REDACTED-SESSION-TOKEN]" '
    'enabled="true" visible="true" x="20" y="190"',
    'name="Session token&#10;eyJhbGciOi…" label="Session token&#10;eyJhbGciOi…" '
    'value="" enabled="true" visible="true" x="20" y="90"',
)
assert HINTED_XML != SOURCE_XML, "the fixture's token field changed shape"


class HintedFieldFakeSsh(FakeSsh):
    """Serves the field plain, then hinted once the tap has focused it."""

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
    # The tap focuses the field, and a focused empty field carries the hint in
    # its accessibility label. An exact match on "Session token" finds nothing
    # in exactly the state the long press has to be aimed from.
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

    # Paste out of the long-press menu, then the example's own Pay button --
    # which is untagged, so it matches on the name WDA falls back to.
    assert tapped == ["Paste", "Pay"]


def test_paste_token_waits_for_the_sheet_that_the_example_pay_opens(
    tmp_path, monkeypatch
):
    # Failing here names the sheet. Carrying on would fail at type_card instead
    # and name a card field, which reads as an SDK bug rather than a sheet that
    # never opened.
    monkeypatch.setattr(ios, "SCREEN_TIMEOUT_SECONDS", 0)
    no_sheet = SOURCE_XML.replace('name="payButton"', 'name="notTheSheet"')
    assert "payButton" not in no_sheet
    ssh = FakeSsh(xml=no_sheet)
    d = driver(ssh)
    d.tap_identifier = lambda name, **kw: None

    with pytest.raises(DriverError) as excinfo:
        d.paste_token(token_file(tmp_path))

    assert "payButton" in str(excinfo.value)


# -- cancelling ---------------------------------------------------------------


def test_cancel_challenge_taps_the_bar_button_then_confirms():
    ssh = FakeSsh()
    d = driver(ssh)
    taps = []
    d.tap_identifier = lambda name, **kw: taps.append(name)

    d.cancel_challenge()

    assert taps == ["threeDSCancel", "Yes, Cancel"]


def test_cancel_form_taps_the_toolbar_cancel_then_confirms():
    ssh = FakeSsh()
    d = driver(ssh)
    taps = []
    d.tap_identifier = lambda name, **kw: taps.append((name, kw))

    d.cancel_form()

    assert [name for name, _ in taps] == ["Cancel", "Yes, Cancel"]
    # Identifier-only, so the label half can never reach threeDSCancel -- which
    # is labelled "Cancel" too -- once D2/D3 add cells that cancel from either
    # screen.
    assert taps[0][1]["identifier_only"] is True


def test_cancel_form_reaches_the_toolbar_item_and_not_the_challenge_bar():
    # The end-to-end version of the assertion above, through the real finder.
    ssh = FakeSsh()

    node = driver(ssh)._find("Cancel", identifier_only=True)

    assert node.identifier == "Cancel"
    assert node.bounds == (16, 76, 96, 108)


# -- evidence -----------------------------------------------------------------


#: simctl says this on *stderr* even when it works, which is why the frame and
#: the complaint have to arrive separated rather than merged.
SIMCTL_NOTE = "Note: No display specified. Defaulting to display: LCD\n"


def console_response(size="9000", body="flutter: up\n"):
    """What the console round trip puts on stdout: size, marker, the window."""
    return f"{size}\n{ios.CONSOLE_SIZE}\n{body}"


def shot_response(frame="", said=SIMCTL_NOTE):
    """What the screenshot round trip puts on stdout: frame, marker, stderr."""
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
    # The failure that started this: simctl's stderr went to /dev/null, `&&`
    # skipped base64, and `rm -f` made the exit status 0 -- so the answer was
    # an empty string, b64decode("") is b"", and evidence.write() would file a
    # 0-byte PNG as though it were a frame of the sheet.
    ssh = FakeSsh(shot_response(said="Invalid device: NO-SUCH-UDID\n"))

    with pytest.raises(DriverError) as excinfo:
        driver(ssh).screenshot()

    message = str(excinfo.value)
    assert "Invalid device" in message
    assert "C311AFDC-25FA-44A2-A800-10EB5A1039E3" in message


def test_screenshot_refuses_an_answer_that_never_arrived():
    # No marker either: the round trip itself failed.
    ssh = FakeSsh("")

    with pytest.raises(DriverError):
        driver(ssh).screenshot()


def test_screenshot_refuses_to_hand_back_an_error_message_as_a_png():
    # b64decode without validation discards every character outside the
    # alphabet, so simctl's complaint decodes to a few bytes of garbage and is
    # written into evidence as though it were a frame. This particular
    # complaint really does survive that: 41 alphabet characters, which is a
    # legal length once the spaces and the colon are thrown away.
    said = "Unable to boot device in current state: Shutdown\n"
    assert base64.b64decode("".join(said.split())), "the string stopped being a trap"

    ssh = FakeSsh(said)

    with pytest.raises(DriverError) as excinfo:
        driver(ssh).screenshot()

    assert "Unable to boot device" in str(excinfo.value)


def test_logs_since_before_launch_refuses_to_read_the_whole_console_log():
    # Byte 0 is a previous cell's output, and crash_lines would count it: one
    # cell's crash would fail every later cell in the matrix.
    ssh = FakeSsh()

    with pytest.raises(DriverError) as excinfo:
        driver(ssh).logs_since(datetime.now(timezone.utc))

    assert "launch()" in str(excinfo.value)
    assert ssh.calls == []


def test_a_launch_that_fails_early_drops_the_previous_cells_console_mark():
    # The console log is truncated by _start_console and by nothing else, so a
    # launch that fails before it leaves the previous cell's window in place
    # and readable. Handing that back would fail this cell for the last one's
    # crash -- and then fail the interleaved control the same way.
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
    # From the offset the log stood at when this cell launched, so a previous
    # cell's crash cannot fail this one. `tail -c +N` counts from one.
    assert f"tail -c +{CONSOLE_MARK + 1} {ios.CONSOLE_LOG}" in console
    assert "flutter: hello" in text


def test_logs_since_also_asks_the_unified_log_for_a_window_in_seconds():
    ssh = FakeSsh(console_response(), "log output\n")
    when = datetime.now(timezone.utc) - timedelta(seconds=90)

    text = launched(ssh).logs_since(when)

    command = ssh.calls[1]
    assert "log show" in command
    assert "--last 9" in command  # 90 s plus the 5 s of slack
    assert 'process == "Runner"' in command
    assert "log output" in text


def test_logs_since_lets_the_tools_own_complaints_into_the_evidence():
    # Discarded, a `log show` that refused and a `tail` that found no file both
    # read as a quiet run.
    ssh = FakeSsh(console_response(), "log output\n")

    launched(ssh).logs_since(datetime.now(timezone.utc))

    for command in ssh.calls[:2]:
        assert "2>/dev/null" not in command
        assert "2>&1" in command


def test_logs_since_refuses_a_console_that_never_grew_past_the_mark():
    # A Flutter app prints on every launch, so an empty window means the
    # capture never attached -- and criterion 3 would pass on nothing.
    ssh = FakeSsh(console_response(size=str(CONSOLE_MARK), body=""), "alive\n")

    with pytest.raises(DriverError) as excinfo:
        launched(ssh).logs_since(datetime.now(timezone.utc))

    assert "has not grown" in str(excinfo.value)


def test_logs_since_calls_a_console_log_that_vanished_a_rig_fault():
    # `tail` reports its own failure into the section now, so an emptiness test
    # on the text alone would read "No such file or directory" as app output.
    # The size is asked for separately and is what decides.
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
    # The capture exits when the app does, and an app that died is exactly what
    # criterion 3 is looking for. Checking liveness first would report the one
    # cell that really crashed as a rig fault and lose the evidence.
    crash = "Fatal error: Unexpectedly found nil\n"
    ssh = FakeSsh(console_response(body=crash), "log output\n")

    text = launched(ssh).logs_since(datetime.now(timezone.utc))

    assert crash.strip() in text
    assert not any("kill -0" in c for c in ssh.calls)


# -- D3 -----------------------------------------------------------------------


def test_the_d3_actions_refuse():
    d = driver(FakeSsh())

    refusals = (
        lambda: d.background(5),
        d.rotate,
        lambda: d.airplane(True),
        d.kill_activity,
    )
    for call in refusals:
        with pytest.raises(NotImplementedError):
            call()


#: The example app's result screen as a build WITHOUT the define renders it:
#: the human-readable outcome, which is what `LEGACY_LABEL_PREFIXES` names.
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
    # Same failure as on Android: without --dart-define=PAYCROSS_E2E=true the
    # app shows its human-readable outcome, and "no contract label" after
    # 180 s reads as a hang rather than as the wrong build.
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
    # `mac` is one ssh config's alias and MAC_ENV hardcodes this Mac's Xcode
    # and Homebrew paths. A second rig must not need a fork of this file.
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


# --- Plan B: the Driver contract is enforced at construction --------------


def test_the_ios_driver_scopes_its_crash_markers_to_the_bundle_it_was_given():
    # `bundle`, not BUNDLE: a driver constructed against another build must
    # not match `ANR in`/`Fatal error:` lines belonging to the default one.
    made = ios.IosDriver(ssh=FakeSsh(), bundle="com.example.other")

    assert made.package == "com.example.other"
    assert ios.IosDriver(ssh=FakeSsh()).package == ios.BUNDLE


def test_the_ios_driver_waits_through_the_sleep_it_was_given():
    slept = []

    ios.IosDriver(ssh=FakeSsh(), sleep=slept.append)._sleep(0.25)

    assert slept == [0.25]


# --- Plan B: relaunching without losing the log window --------------------


def test_relaunch_does_not_truncate_the_console_log():
    # A cell that relaunches halfway through would otherwise throw away the
    # first half of its own criterion-3 evidence.
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
    # A second, larger mark: the log has grown since the launch, and honouring
    # it would start this cell's window halfway through itself.
    ssh.outputs.extend(launch_outputs(stopping=True, mark=CONSOLE_MARK + 4096))

    d.relaunch()

    assert d._console_from == was


def test_relaunch_still_replaces_the_capture_and_the_session():
    # The old --console-pty is bound to the app instance being replaced.
    ssh = FakeSsh(*launch_outputs())
    d = ios.IosDriver(ssh=ssh, sleep=lambda _: None)
    d.launch()
    ssh.calls.clear()
    ssh.outputs.extend(launch_outputs(stopping=True))

    d.relaunch()

    assert any("--console-pty" in c for c in ssh.calls)
    assert any("terminate" in c for c in ssh.calls)


# --- Plan B: the simulator's locale ---------------------------------------


@pytest.mark.parametrize(
    "locale", ["en_US\n", "en_US@rg=lvzzzz\n", "en_GB\n", "en\n", "en-US\n"]
)
def test_launch_accepts_an_english_locale(locale):
    # This rig answers `en_US@rg=lvzzzz`, and the amount predicate absorbs the
    # swapped decimal separator that comes with it.
    ssh = FakeSsh(*launch_outputs(locale=locale))

    ios.IosDriver(ssh=ssh, sleep=lambda _: None).launch()

    assert any("AppleLocale" in c for c in ssh.calls)


@pytest.mark.parametrize(
    "locale",
    [
        "fr_FR\n",
        # Three subtags, which the first shape only matched up to `zh`.
        "zh_Hans_CN\n",
        # A hyphen and a UN M.49 region, which iOS writes for Latin American
        # Spanish. Neither is a `_` followed by letters.
        "es-419\n",
        "de\n",
    ],
)
def test_launch_refuses_a_simulator_that_is_not_in_english(locale):
    # The sheet's Pay button and the re-arm banner are English strings, which
    # the amount predicate cannot absorb. A shape too narrow to recognise one
    # of these reads it as unreadable and lets the rig through.
    ssh = FakeSsh(*launch_outputs(locale=locale))

    with pytest.raises(DriverError) as excinfo:
        ios.IosDriver(ssh=ssh, sleep=lambda _: None).launch()

    message = str(excinfo.value)
    assert locale.strip() in message
    # Named as a locale, not as whatever failed next.
    assert "locale" in message


def test_an_unreadable_locale_is_not_a_reason_to_refuse_a_rig():
    # A simulator that has never had the key written answers with a complaint
    # rather than a locale, and refusing on that would break a working rig for
    # a cosmetic check.
    ssh = FakeSsh(
        *launch_outputs(
            locale="2026-08-29 defaults[1:2] \nThe domain/default pair does not exist\n"
        )
    )

    ios.IosDriver(ssh=ssh, sleep=lambda _: None).launch()
