import json
import subprocess
import textwrap
from pathlib import Path

import pytest

from tool.e2e import cells, evidence, runner
from tool.e2e.cells import CellError
from tool.e2e.drivers.base import DriverError
from tool.e2e.sandbox import SandboxError

CELL = """\
id: {id}
platforms: [android, ios]
card:
  pan: "4111111111170000"
  expiry: "12/28"
  cvv: "123"
session:
  amount: 1000
  currency: EUR
actions:
  - paste_token
  - type_card
  - tap_pay
  - wait_result 60
expected:
  label: "result:success:<txn>"
  merchant:
    session_status: completed
    txn_count: 1
"""

#: What FakeSandbox mints. Deliberately *not* JWT_RE-shaped -- its middle
#: segment is ten characters and the shape rule wants sixteen -- so a test that
#: watches for it on disk is watching the literal-secret scrub, not redact().
TOKEN = "eyJhbGciOiJSUzI1NiJ9.eyJhIjoxfQ.sig"

#: And one that is, for the other half.
JWT = (
    "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9"
    ".eyJzZXNzaW9uX2lkIjoiMDFhMDQ3OWQtMDMwYS03MDhhIn0"
    ".SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
)


@pytest.fixture
def cell_dir(tmp_path):
    directory = tmp_path / "d0"
    directory.mkdir()
    for name in ("control", "frictionless"):
        (directory / f"{name}.yaml").write_text(
            textwrap.dedent(CELL.format(id=name)), encoding="utf-8"
        )
    return directory


class FakeSandbox:
    def __init__(self, sessions=None):
        self.minted = []
        self.sessions = sessions or {}

    def mint(self, amount, currency, options):
        session_id = f"sess-{len(self.minted)}"
        self.minted.append(session_id)
        return {"id": session_id, "token": TOKEN}

    def read(self, session_id):
        return self.sessions.get(
            session_id,
            {
                "id": session_id,
                "status": "completed",
                "transactions": [{"id": "txn-1", "status": "succeeded"}],
            },
        )


class FakeDriver:
    package = "com.paycross.example"

    def __init__(self, labels=None, rearmed=True):
        self.labels = list(labels or [])
        self.rearmed = rearmed
        self.actions = []
        self.token_paths = []

    def install(self, app_path):
        self.actions.append(("install", app_path))

    def launch(self):
        self.actions.append(("launch", None))

    def paste_token(self, token_path):
        self.actions.append(("paste_token", None))
        self.token_paths.append(Path(token_path))
        # The runner must have written a real token, readable only by us.
        assert Path(token_path).read_text().startswith("eyJ")
        assert oct(Path(token_path).stat().st_mode)[-3:] == "600"
        assert oct(Path(token_path).parent.stat().st_mode)[-3:] == "700"

    def type_card(self, card):
        self.actions.append(("type_card", card.pan))

    def tap_pay(self, amount_text):
        self.actions.append(("tap_pay", amount_text))

    def acs(self, outcome):
        self.actions.append(("acs", outcome))

    def cancel_challenge(self):
        self.actions.append(("cancel_challenge", None))

    def cancel_form(self):
        self.actions.append(("cancel_form", None))

    def wait_rearmed(self, amount_text, timeout):
        self.actions.append(("wait_rearmed", amount_text))
        return self.rearmed

    def wait_label(self, timeout):
        self.actions.append(("wait_label", timeout))
        return self.labels.pop(0) if self.labels else "result:success:txn-1"

    def dump_tree(self):
        return b"<hierarchy/>"

    def screenshot(self):
        return b"\x89PNG"

    def logs_since(self, since):
        self.actions.append(("logs_since", None))
        return "all quiet\n"

    def close(self):
        self.actions.append(("close", None))


def run(cell_dir, tmp_path, driver, sandbox=None, only=None, run_all=True):
    return runner.run_cells(
        platform="android",
        cell_dir=cell_dir,
        evidence_root=tmp_path / "evidence",
        driver=driver,
        sandbox=sandbox or FakeSandbox(),
        run_all=run_all,
        only=only,
    )


def verbs(driver):
    return [verb for verb, _ in driver.actions]


def names(tmp_path, cell="control"):
    return sorted(p.name for p in (tmp_path / "evidence").glob(f"*/{cell}/*"))


def raises(error):
    """A stand-in device method that fails however the test wants it to."""

    def fail(*args, **kwargs):
        raise error

    return fail


# -- the happy path ---------------------------------------------------------


def test_a_passing_run_reports_every_cell_and_exits_clean(cell_dir, tmp_path):
    report = run(cell_dir, tmp_path, FakeDriver())

    assert [r.cell_id for r in report.results] == ["control", "frictionless"]
    assert all(r.passed for r in report.results)
    assert report.exit_code == 0


def test_each_cell_gets_a_fresh_launch_and_its_own_session(cell_dir, tmp_path):
    driver, sandbox = FakeDriver(), FakeSandbox()

    run(cell_dir, tmp_path, driver, sandbox)

    assert verbs(driver).count("launch") == 2
    assert sandbox.minted == ["sess-0", "sess-1"]


def test_the_run_directory_names_the_platform(cell_dir, tmp_path):
    # Two platforms are driven from two shells; on a bare timestamp a run
    # started in the same second would file its cells over the other's.
    run(cell_dir, tmp_path, FakeDriver(), only=["control"])

    run_dir = next(p for p in (tmp_path / "evidence").iterdir() if p.is_dir())

    assert run_dir.name.endswith("-android")


# -- the token --------------------------------------------------------------


def test_the_token_file_is_destroyed_after_every_cell(cell_dir, tmp_path):
    driver = FakeDriver()

    run(cell_dir, tmp_path, driver)

    assert driver.token_paths
    assert not any(p.exists() for p in driver.token_paths)
    assert not any(p.parent.exists() for p in driver.token_paths)


def test_the_token_file_is_destroyed_even_when_the_cell_blows_up(
    cell_dir, tmp_path
):
    driver = FakeDriver()
    driver.type_card = raises(DriverError("the form never appeared"))

    run(cell_dir, tmp_path, driver, only=["control"])

    assert driver.token_paths
    assert not any(p.exists() for p in driver.token_paths)


def test_no_token_reaches_the_evidence_tree(cell_dir, tmp_path):
    run(cell_dir, tmp_path, FakeDriver())

    for path in (tmp_path / "evidence").rglob("*"):
        if path.is_file():
            assert TOKEN.encode() not in path.read_bytes()


def test_the_literal_token_is_scrubbed_even_when_it_is_not_jwt_shaped(
    cell_dir, tmp_path
):
    # The shape rule needs sixteen characters a segment, so it does not match
    # every token an environment can mint. The runner knows the exact string
    # and hands it to the evidence layer, which is what covers the gap.
    assert evidence.redact(TOKEN.encode()) == TOKEN.encode()
    driver = FakeDriver()
    driver.dump_tree = lambda: (
        f'<hierarchy><node text="{TOKEN}"/></hierarchy>'.encode()
    )

    run(cell_dir, tmp_path, driver, only=["control"])

    for path in (tmp_path / "evidence").rglob("*"):
        if path.is_file():
            assert TOKEN.encode() not in path.read_bytes()


# -- the verdicts -----------------------------------------------------------


def test_a_wrong_label_fails_the_cell_and_says_what_it_wanted(cell_dir, tmp_path):
    report = run(cell_dir, tmp_path, FakeDriver(labels=["result:cancelled"] * 4))

    assert report.exit_code != 0
    assert any("result:success:<txn>" in p for p in report.results[0].problems)


def test_a_merchant_mismatch_fails_the_cell(cell_dir, tmp_path):
    sandbox = FakeSandbox(
        {"sess-0": {"id": "sess-0", "status": "open", "transactions": [{"id": "txn-1"}]}}
    )

    report = run(cell_dir, tmp_path, FakeDriver(), sandbox)

    assert not report.results[0].passed
    assert any("session_status" in p for p in report.results[0].problems)


def test_a_label_naming_an_unknown_transaction_fails_the_cell(cell_dir, tmp_path):
    # verify_label_transaction takes the resource first; called the other way
    # round it would read the id as the session and pass on anything.
    driver = FakeDriver(labels=["result:success:txn-9"])

    report = run(cell_dir, tmp_path, driver, only=["control"])

    assert not report.results[0].passed
    assert any("label_transaction" in p for p in report.results[0].problems)


def test_a_crash_in_the_log_fails_an_otherwise_clean_cell(cell_dir, tmp_path):
    driver = FakeDriver()
    driver.logs_since = lambda since: "E AndroidRuntime: FATAL EXCEPTION: main\n"

    report = run(cell_dir, tmp_path, driver)

    assert not report.results[0].passed
    assert any("FATAL EXCEPTION" in p for p in report.results[0].problems)


def test_a_rearm_cell_needs_both_the_predicate_and_the_merchant_state(tmp_path):
    directory = tmp_path / "d0"
    directory.mkdir()
    (directory / "rearm.yaml").write_text(
        textwrap.dedent(
            """\
            id: rearm
            platforms: [android]
            card: {pan: "4111111111153220", expiry: "12/28", cvv: "123"}
            session: {amount: 1000, currency: EUR}
            actions:
              - paste_token
              - type_card
              - tap_pay
              - acs:authentication_failed
              - expect rearmed
              - cancel_form
              - wait_result 60
            expected:
              label: "result:cancelled"
              rearmed: true
              merchant:
                session_status: open
                no_succeeded_txn: true
            """
        ),
        encoding="utf-8",
    )
    sandbox = FakeSandbox(
        {
            "sess-0": {
                "id": "sess-0",
                "status": "open",
                "transactions": [{"id": "txn-1", "status": "failed"}],
            }
        }
    )

    passing = runner.run_cells(
        platform="android",
        cell_dir=directory,
        evidence_root=tmp_path / "e1",
        driver=FakeDriver(labels=["result:cancelled"], rearmed=True),
        sandbox=sandbox,
        run_all=True,
    )
    assert passing.results[0].passed

    not_rearmed = runner.run_cells(
        platform="android",
        cell_dir=directory,
        evidence_root=tmp_path / "e2",
        driver=FakeDriver(labels=["result:cancelled"], rearmed=False),
        sandbox=sandbox,
        run_all=True,
    )
    assert not not_rearmed.results[0].passed
    assert any("rearm" in p for p in not_rearmed.results[0].problems)


def test_a_cell_expecting_a_rearm_it_never_asks_for_says_so(tmp_path):
    # `rearmed: true` with no `expect rearmed` action is a cell-authoring
    # mistake. Reporting it as "the sheet never re-armed" would send whoever
    # is triaging after an SDK bug that is not there.
    directory = tmp_path / "d0"
    directory.mkdir()
    (directory / "control.yaml").write_text(
        textwrap.dedent(CELL.format(id="control")).replace(
            "expected:\n", "expected:\n  rearmed: true\n"
        ),
        encoding="utf-8",
    )

    report = run(directory, tmp_path, FakeDriver())

    assert any(
        "no 'expect rearmed' action" in p for p in report.results[0].problems
    )


# -- skepticism -------------------------------------------------------------


def test_a_failure_interleaves_a_control_cell_before_it_is_recorded(
    cell_dir, tmp_path
):
    # control passes, frictionless fails, control is re-run to check the rig.
    driver = FakeDriver(
        labels=["result:success:txn-1", "result:cancelled", "result:success:txn-1"]
    )

    report = run(cell_dir, tmp_path, driver)

    assert [r.cell_id for r in report.results] == [
        "control",
        "frictionless",
        "control",
    ]
    assert [r.is_control_check for r in report.results] == [False, False, True]
    assert report.results[-1].passed


def test_a_control_check_keeps_its_evidence_out_of_the_control_cell_s(
    cell_dir, tmp_path
):
    # Both would otherwise be filed as `control/`, and the check -- which may
    # have failed -- would overwrite the cell's own passing proof.
    driver = FakeDriver(
        labels=["result:success:txn-1", "result:cancelled", "result:success:txn-1"]
    )

    report = run(cell_dir, tmp_path, driver)

    assert names(tmp_path, "control")
    assert names(tmp_path, "control-check-01")
    assert report.results[-1].artifact_id == "control-check-01"


def test_the_control_check_runs_even_when_only_names_one_other_cell(
    cell_dir, tmp_path
):
    # --only is about what to run, not about whether to believe the result.
    driver = FakeDriver(labels=["result:cancelled", "result:success:txn-1"])

    report = run(cell_dir, tmp_path, driver, only=["frictionless"])

    assert [r.cell_id for r in report.results] == ["frictionless", "control"]
    assert report.results[-1].is_control_check


def test_two_consecutive_control_failures_abort_the_run(tmp_path):
    directory = tmp_path / "d0"
    directory.mkdir()
    # Loaded in filename order, so: a_cell, b_cell, c_cell, control.
    for name in ("a_cell", "b_cell", "c_cell", "control"):
        (directory / f"{name}.yaml").write_text(
            textwrap.dedent(CELL.format(id=name)), encoding="utf-8"
        )
    # Everything fails, the interleaved controls included.
    driver = FakeDriver(labels=["result:cancelled"] * 20)

    report = run(directory, tmp_path, driver)

    assert report.aborted
    assert "rig" in report.abort_reason.lower()
    # a_cell fails and its control check fails; b_cell fails and so does its
    # control check -- that is two in a row, so c_cell is never reached. A
    # broken rig must not produce a page of findings that are all one finding.
    assert [r.cell_id for r in report.results] == [
        "a_cell",
        "control",
        "b_cell",
        "control",
    ]
    assert "c_cell" not in [r.cell_id for r in report.results]
    assert report.exit_code != 0


def test_an_abort_is_recorded_in_the_progress_file(tmp_path):
    directory = tmp_path / "d0"
    directory.mkdir()
    for name in ("a_cell", "b_cell", "control"):
        (directory / f"{name}.yaml").write_text(
            textwrap.dedent(CELL.format(id=name)), encoding="utf-8"
        )

    run(directory, tmp_path, FakeDriver(labels=["result:cancelled"] * 20))

    progress = next((tmp_path / "evidence").glob("*/progress.jsonl"))
    last = json.loads(progress.read_text().splitlines()[-1])
    assert last["status"] == "abort"
    assert "rig" in last["problems"][0].lower()


# -- resume -----------------------------------------------------------------


def test_resume_skips_cells_that_passed_in_an_earlier_run(cell_dir, tmp_path):
    run(cell_dir, tmp_path, FakeDriver())
    driver = FakeDriver()

    report = runner.run_cells(
        platform="android",
        cell_dir=cell_dir,
        evidence_root=tmp_path / "evidence",
        driver=driver,
        sandbox=FakeSandbox(),
        run_all=False,
    )

    assert [r.cell_id for r in report.results] == []
    assert report.skipped == ["control", "frictionless"]
    assert driver.actions == []


def test_all_reruns_everything(cell_dir, tmp_path):
    run(cell_dir, tmp_path, FakeDriver())

    report = run(cell_dir, tmp_path, FakeDriver(), run_all=True)

    assert [r.cell_id for r in report.results] == ["control", "frictionless"]


# -- evidence ---------------------------------------------------------------


def test_evidence_holds_a_tree_per_action_and_the_merchant_response(
    cell_dir, tmp_path
):
    run(cell_dir, tmp_path, FakeDriver(), only=["control"])

    cell_files = names(tmp_path)
    assert "merchant.json" in cell_files
    assert "result.json" in cell_files
    assert "logs.txt" in cell_files
    assert any(n.startswith("01-paste_token") and n.endswith(".uix") for n in cell_files)
    # The sheet is still up in this dump, so the sheet-foreground step is shot.
    assert "03-tap_pay.png" in cell_files


def test_no_screenshot_once_the_dump_already_shows_a_label(cell_dir, tmp_path):
    # If the payment resolves during the dump the sheet has gone and the frame
    # would be the example app's screen, token field and all. redact() cannot
    # scrub a PNG and `grep eyJ` cannot see into one, so the leak would be
    # invisible to the check meant to catch it.
    driver = FakeDriver()
    driver.dump_tree = lambda: (
        b'<hierarchy><node content-desc="result:success:txn-1" '
        b'bounds="[0,0][10,10]"/></hierarchy>'
    )

    run(cell_dir, tmp_path, driver, only=["control"])

    assert "03-tap_pay.uix" in names(tmp_path)
    assert not any(n.endswith(".png") for n in names(tmp_path))


def test_no_screenshot_while_the_token_itself_is_on_screen(cell_dir, tmp_path):
    # The same leak without a label to give it away: the example's screen is
    # up, its TextField still holds the token, and the sheet never opened.
    driver = FakeDriver()
    driver.dump_tree = lambda: (
        f'<hierarchy><node class="android.widget.EditText" '
        f'text="{TOKEN}" bounds="[0,0][10,10]"/></hierarchy>'
    ).encode()

    run(cell_dir, tmp_path, driver, only=["control"])

    assert not any(n.endswith(".png") for n in names(tmp_path))


def test_progress_is_written_per_cell_not_at_the_end(cell_dir, tmp_path):
    run(cell_dir, tmp_path, FakeDriver(), only=["control"])

    progress = next((tmp_path / "evidence").glob("*/progress.jsonl"))
    record = json.loads(progress.read_text().splitlines()[0])
    assert record["cell"] == "control"
    assert record["status"] == "pass"
    assert record["session_id"] == "sess-0"


def test_the_result_file_records_the_verdict_and_what_was_expected(
    cell_dir, tmp_path
):
    run(cell_dir, tmp_path, FakeDriver(), only=["control"])

    result = json.loads(
        next((tmp_path / "evidence").glob("*/control/result.json")).read_text()
    )

    assert result["cell"] == "control"
    assert result["platform"] == "android"
    assert result["passed"] is True
    assert result["label"] == "result:success:txn-1"
    assert result["transaction_id"] == "txn-1"
    assert result["expected_label"] == "result:success:<txn>"


# -- a device that misbehaves ------------------------------------------------


def test_a_hung_device_fails_the_cell_instead_of_killing_the_matrix(
    cell_dir, tmp_path
):
    # adb times out at 300 s and ssh at 900 s; a dead WebDriverAgent gives a
    # JSONDecodeError. None of those is a DriverError, and a 40-minute matrix
    # must not die on one of them.
    driver = FakeDriver()
    driver.tap_pay = raises(
        subprocess.TimeoutExpired(cmd="adb shell input tap", timeout=300)
    )

    report = run(cell_dir, tmp_path, driver, only=["control"])

    assert not report.results[0].passed
    assert any("TimeoutExpired" in p for p in report.results[0].problems)
    assert "03-tap_pay-failed.uix" in names(tmp_path)


def test_a_failing_action_still_leaves_a_dump(cell_dir, tmp_path):
    # The tree at the moment of failure is the whole diagnosis, and the
    # happy-path write never runs for the step that raised.
    driver = FakeDriver()
    driver.tap_pay = raises(DriverError("no node with text 'Pay €10.00'"))

    report = run(cell_dir, tmp_path, driver, only=["control"])

    assert not report.results[0].passed
    assert "03-tap_pay-failed.uix" in names(tmp_path)
    assert any("driver: no node with text" in p for p in report.results[0].problems)


def test_a_device_that_will_not_dump_after_a_failure_says_both_things(
    cell_dir, tmp_path
):
    driver = FakeDriver()
    driver.tap_pay = raises(DriverError("no node with text 'Pay'"))
    # The two steps before the failure dump fine; the device goes away with it.
    dumps = iter([b"<hierarchy/>", b"<hierarchy/>"])

    def dump_until_it_cannot():
        try:
            return next(dumps)
        except StopIteration:
            raise DriverError("no parsable uiautomator dump") from None

    driver.dump_tree = dump_until_it_cannot

    report = run(cell_dir, tmp_path, driver, only=["control"])

    problems = report.results[0].problems
    assert any("no node with text" in p for p in problems)
    assert any("no dump after the failure" in p for p in problems)


def test_a_failure_does_not_invent_a_label_finding(cell_dir, tmp_path):
    # The cell never reached wait_result, so "expected result:success, got
    # None" is a consequence of the real fault, not a second finding.
    driver = FakeDriver()
    driver.tap_pay = raises(DriverError("no node with text 'Pay'"))

    report = run(cell_dir, tmp_path, driver, only=["control"])

    assert not any(p.startswith("label:") for p in report.results[0].problems)


def test_a_failure_during_expect_does_not_also_claim_no_rearm(tmp_path):
    directory = tmp_path / "d0"
    directory.mkdir()
    (directory / "rearm.yaml").write_text(
        textwrap.dedent(
            """\
            id: rearm
            platforms: [android]
            card: {pan: "4111111111153220", expiry: "12/28", cvv: "123"}
            session: {amount: 1000, currency: EUR}
            actions:
              - paste_token
              - type_card
              - tap_pay
              - expect rearmed
            expected:
              label: "result:cancelled"
              rearmed: true
            """
        ),
        encoding="utf-8",
    )
    driver = FakeDriver()
    # wait_rearmed raises rather than answering False when the device will not
    # dump: a dead uiautomator is a rig fault, not a verdict about the sheet.
    driver.wait_rearmed = raises(DriverError("no parsable uiautomator dump"))

    report = run(directory, tmp_path, driver)

    problems = report.results[0].problems
    assert any("driver: no parsable" in p for p in problems)
    assert not any(p.startswith("rearm:") for p in problems)


def test_a_screenshot_failure_is_recorded_and_the_cell_carries_on(
    cell_dir, tmp_path
):
    driver = FakeDriver()
    driver.screenshot = raises(DriverError("adb exec-out exited 1"))

    report = run(cell_dir, tmp_path, driver, only=["control"])

    assert any("screenshot: " in p for p in report.results[0].problems)
    # The cell ran to the end: the label was still read and judged.
    assert report.results[0].label == "result:success:txn-1"
    assert "04-wait_result.uix" in names(tmp_path)


def test_a_log_failure_never_replaces_the_verdict(cell_dir, tmp_path):
    driver = FakeDriver()
    driver.logs_since = raises(DriverError("the console log has not grown"))

    report = run(cell_dir, tmp_path, driver, only=["control"])

    assert report.results[0].label == "result:success:txn-1"
    assert any("logs: " in p for p in report.results[0].problems)


def test_the_driver_is_closed_when_the_run_ends(cell_dir, tmp_path):
    driver = FakeDriver()

    run(cell_dir, tmp_path, driver)

    assert verbs(driver).count("close") == 1
    assert verbs(driver)[-1] == "close"


def test_the_driver_is_closed_even_when_a_cell_blows_up(cell_dir, tmp_path):
    driver = FakeDriver()
    driver.launch = raises(DriverError("the emulator has not finished booting"))

    run(cell_dir, tmp_path, driver, only=["control"])

    assert "close" in verbs(driver)


def test_a_close_failure_is_a_run_problem_not_a_cell_verdict(cell_dir, tmp_path):
    driver = FakeDriver()
    driver.close = raises(DriverError("the console capture will not die"))

    report = run(cell_dir, tmp_path, driver, only=["control"])

    assert report.results[0].passed
    assert any("close: " in p for p in report.problems)
    assert report.exit_code != 0


def test_a_close_that_fails_some_other_way_is_still_only_a_run_problem(
    cell_dir, tmp_path
):
    driver = FakeDriver()
    driver.close = raises(OSError("ssh: connection reset"))

    report = run(cell_dir, tmp_path, driver, only=["control"])

    assert report.results[0].passed
    assert any("close: " in p for p in report.problems)


def test_a_cell_s_logs_are_collected_before_the_next_launch(cell_dir, tmp_path):
    # The iOS console log is truncated by every launch(), so a cell whose logs
    # are read after the next one starts has no logs at all.
    driver = FakeDriver()

    run(cell_dir, tmp_path, driver)

    ordered = [v for v in verbs(driver) if v in ("launch", "logs_since")]
    assert ordered == ["launch", "logs_since", "launch", "logs_since"]


# -- the merchant API --------------------------------------------------------


def test_a_mint_failure_fails_the_cell_rather_than_the_run(cell_dir, tmp_path):
    sandbox = FakeSandbox()
    sandbox.mint = raises(SandboxError("POST /sessions -> HTTP 502"))

    report = run(cell_dir, tmp_path, FakeDriver(), sandbox=sandbox)

    # Both cells are attempted and the abort rule -- not an exception -- is
    # what decides that a backend which cannot mint is a rig fault.
    assert report.aborted
    assert any("sandbox: " in p for p in report.results[0].problems)


def test_a_mint_failure_never_touches_the_device(cell_dir, tmp_path):
    sandbox = FakeSandbox()
    sandbox.mint = raises(SandboxError("POST /sessions -> HTTP 502"))
    driver = FakeDriver()

    run(cell_dir, tmp_path, driver, sandbox=sandbox, only=["control"])

    assert "launch" not in verbs(driver)


def test_a_merchant_read_failure_is_reported_as_the_cell_s_problem(
    cell_dir, tmp_path
):
    sandbox = FakeSandbox()
    sandbox.read = raises(SandboxError("GET /sessions/sess-0 -> HTTP 500"))

    report = run(
        cell_dir, tmp_path, FakeDriver(), sandbox=sandbox, only=["control"]
    )

    assert not report.results[0].passed
    assert any("merchant: " in p for p in report.results[0].problems)
    # The label was still read and recorded.
    assert report.results[0].label == "result:success:txn-1"


# -- redaction of what the runner itself writes ------------------------------


def test_a_driver_error_quoting_a_jwt_is_redacted_before_it_is_reported(
    cell_dir, tmp_path
):
    # DriverError messages do not pass through redact() on their own, and the
    # runner both prints them and files them.
    driver = FakeDriver()
    driver.tap_pay = raises(DriverError(f"the field reads {JWT}"))

    report = run(cell_dir, tmp_path, driver, only=["control"])

    assert not any(JWT in p for p in report.results[0].problems)
    assert any("REDACTED-SESSION-TOKEN" in p for p in report.results[0].problems)


def test_a_driver_error_quoting_the_session_token_is_redacted_too(
    cell_dir, tmp_path
):
    driver = FakeDriver()
    driver.tap_pay = raises(DriverError(f"the field reads {TOKEN}"))

    report = run(cell_dir, tmp_path, driver, only=["control"])

    assert not any(TOKEN in p for p in report.results[0].problems)


# -- budgets ------------------------------------------------------------------


def test_the_budget_absorbs_the_cell_s_own_waits(cell_dir, tmp_path):
    cell = cells.load_cell(cell_dir / "control.yaml")

    budget = runner.budget_for(cell)

    # The cell waits 60 s for its result and types sixteen digits at 0.4 s
    # apiece before that; the budget is the sum of the steps plus slack.
    assert budget > 60 + runner.LAUNCH_BUDGET_SECONDS


def test_a_cell_that_overruns_its_budget_is_failed_with_a_dump(
    cell_dir, tmp_path, monkeypatch
):
    # A cell that is making no progress must not eat the matrix's wall clock.
    monkeypatch.setattr(runner, "budget_for", lambda cell: 0.0)

    report = run(cell_dir, tmp_path, FakeDriver(), only=["control"])

    assert not report.results[0].passed
    assert any("budget: " in p for p in report.results[0].problems)
    assert "01-paste_token-failed.uix" in names(tmp_path)


# -- selection ----------------------------------------------------------------


def test_only_refuses_a_cell_id_that_does_not_exist(cell_dir, tmp_path):
    # Otherwise a typo runs nothing at all and exits 0, which reads as a pass.
    with pytest.raises(CellError) as error:
        run(cell_dir, tmp_path, FakeDriver(), only=["contrl"])

    assert "contrl" in str(error.value)


def test_a_cell_that_does_not_run_on_this_platform_is_not_run(tmp_path):
    directory = tmp_path / "d0"
    directory.mkdir()
    (directory / "control.yaml").write_text(
        textwrap.dedent(CELL.format(id="control")).replace(
            "platforms: [android, ios]", "platforms: [ios]"
        ),
        encoding="utf-8",
    )
    (directory / "frictionless.yaml").write_text(
        textwrap.dedent(CELL.format(id="frictionless")), encoding="utf-8"
    )

    report = run(directory, tmp_path, FakeDriver())

    assert [r.cell_id for r in report.results] == ["frictionless"]


def test_a_directory_with_nothing_for_this_platform_is_refused(tmp_path):
    # Running nothing and exiting 0 reads as "everything passed".
    directory = tmp_path / "d0"
    directory.mkdir()
    (directory / "control.yaml").write_text(
        textwrap.dedent(CELL.format(id="control")).replace(
            "platforms: [android, ios]", "platforms: [ios]"
        ),
        encoding="utf-8",
    )

    with pytest.raises(CellError) as error:
        run(directory, tmp_path, FakeDriver())

    assert "android" in str(error.value)


def test_an_install_failure_aborts_the_run_before_any_cell(cell_dir, tmp_path):
    driver = FakeDriver()
    driver.install = raises(DriverError("adb install did not report Success"))

    report = runner.run_cells(
        platform="android",
        cell_dir=cell_dir,
        evidence_root=tmp_path / "evidence",
        driver=driver,
        sandbox=FakeSandbox(),
        run_all=True,
        app_path="/tmp/app-debug.apk",
    )

    assert report.aborted
    assert "install" in report.abort_reason
    assert "launch" not in verbs(driver)
    assert report.exit_code != 0


# -- the command line ---------------------------------------------------------


def test_main_reports_a_bad_cell_directory_without_reading_the_env_file(
    tmp_path, capsys
):
    # The env file does not exist either. Reading it first would raise
    # FileNotFoundError over a mistake the runner can explain in one line.
    code = runner.main(
        [
            "--platform",
            "android",
            "--cells",
            str(tmp_path / "nope"),
            "--evidence-root",
            str(tmp_path / "evidence"),
            "--env-file",
            str(tmp_path / "absent.env"),
        ]
    )

    assert code != 0
    assert "no such cell directory" in capsys.readouterr().err


def test_main_reports_an_unusable_env_file_in_one_line(cell_dir, tmp_path, capsys):
    (tmp_path / "empty.env").write_text("# nothing here\n", encoding="utf-8")

    code = runner.main(
        [
            "--platform",
            "android",
            "--cells",
            str(cell_dir),
            "--evidence-root",
            str(tmp_path / "evidence"),
            "--env-file",
            str(tmp_path / "empty.env"),
        ]
    )

    error = capsys.readouterr().err
    assert code != 0
    assert "missing" in error
    assert "CLIENT_PAYX_SANDBOX_ID" in error


def test_main_prints_a_line_per_cell_and_returns_the_exit_code(
    cell_dir, tmp_path, capsys, monkeypatch
):
    class StubSandbox:
        @staticmethod
        def from_env_file(path):
            return FakeSandbox()

    monkeypatch.setattr(runner, "Sandbox", StubSandbox)
    monkeypatch.setattr(runner, "_build_driver", lambda platform: FakeDriver())

    code = runner.main(
        [
            "--platform",
            "android",
            "--cells",
            str(cell_dir),
            "--evidence-root",
            str(tmp_path / "evidence"),
            "--env-file",
            str(tmp_path / "never-opened.env"),
            "--all",
        ]
    )

    out = capsys.readouterr().out
    assert code == 0
    assert "PASS control" in out
    assert "PASS frictionless" in out


def test_main_prints_the_skips_the_failures_and_the_abort(
    cell_dir, tmp_path, capsys, monkeypatch
):
    class StubSandbox:
        @staticmethod
        def from_env_file(path):
            return FakeSandbox()

    monkeypatch.setattr(runner, "Sandbox", StubSandbox)
    monkeypatch.setattr(
        runner,
        "_build_driver",
        lambda platform: FakeDriver(labels=["result:cancelled"] * 6),
    )
    argv = [
        "--platform",
        "android",
        "--cells",
        str(cell_dir),
        "--evidence-root",
        str(tmp_path / "evidence"),
        "--env-file",
        str(tmp_path / "never-opened.env"),
    ]

    code = runner.main(argv)

    out = capsys.readouterr().out
    assert code != 0
    assert "FAIL control" in out
    assert "CTRL" in out
    assert "ABORT" in out


def test_main_skips_what_already_passed_unless_all_is_given(
    cell_dir, tmp_path, capsys, monkeypatch
):
    class StubSandbox:
        @staticmethod
        def from_env_file(path):
            return FakeSandbox()

    monkeypatch.setattr(runner, "Sandbox", StubSandbox)
    monkeypatch.setattr(runner, "_build_driver", lambda platform: FakeDriver())
    argv = [
        "--platform",
        "android",
        "--cells",
        str(cell_dir),
        "--evidence-root",
        str(tmp_path / "evidence"),
        "--env-file",
        str(tmp_path / "never-opened.env"),
    ]
    runner.main(argv + ["--all"])
    capsys.readouterr()

    code = runner.main(argv)

    out = capsys.readouterr().out
    assert code == 0
    assert "SKIP control" in out
    assert "SKIP frictionless" in out


def test_main_reports_an_unknown_only_id_in_one_line(
    cell_dir, tmp_path, capsys, monkeypatch
):
    class StubSandbox:
        @staticmethod
        def from_env_file(path):
            return FakeSandbox()

    monkeypatch.setattr(runner, "Sandbox", StubSandbox)
    monkeypatch.setattr(runner, "_build_driver", lambda platform: FakeDriver())

    code = runner.main(
        [
            "--platform",
            "android",
            "--cells",
            str(cell_dir),
            "--evidence-root",
            str(tmp_path / "evidence"),
            "--env-file",
            str(tmp_path / "never-opened.env"),
            "--only",
            "contrl",
        ]
    )

    assert code != 0
    assert "contrl" in capsys.readouterr().err
