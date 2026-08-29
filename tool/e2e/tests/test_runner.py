import json
import os
import subprocess
import textwrap
from pathlib import Path

import pytest

from tool.e2e import cells, evidence, runner, tree
from tool.e2e.cells import CellError
from tool.e2e.drivers import android
from tool.e2e.drivers.base import Driver, DriverError
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


#: Long enough to reach the prefix rule's 48-character floor, which the short
#: TOKEN above deliberately does not.
MINTED_LIKE_THE_REAL_ONE = (
    "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9"
    ".eyJzZXNzaW9uIjoiMDFhMDQ3OWQtMDMwYS03MDhhIiwibWVyY2hhbnQiOiIwMTlkNzc3YyJ9"
    ".SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5cAAAAAAAAAAAA"
)


class FakeSandbox:
    def __init__(self, sessions=None, token=TOKEN):
        self.minted = []
        self.sessions = sessions or {}
        self.token = token
        # The real Sandbox carries these; the runner drains them into the
        # run report rather than into its problems.
        self.warnings = []

    def mint(self, amount, currency, options):
        session_id = f"sess-{len(self.minted)}"
        self.minted.append(session_id)
        return {"id": session_id, "token": self.token}

    def read(self, session_id):
        return self.sessions.get(
            session_id,
            {
                "id": session_id,
                "status": "completed",
                "transactions": [{"id": "txn-1", "status": "succeeded"}],
            },
        )


class FakeDriver(Driver):
    """A device that does whatever the test says, on the real interface.

    A `Driver` subclass rather than a bare stand-in, so every verb and
    predicate a later dimension owns raises NotImplementedError here exactly
    as it would on a real driver. That distinction is the whole of the
    authoring-fault classification: an AttributeError would be read as a
    broken device and spend an interleaved control check.
    """

    _parse_dump = staticmethod(tree.parse_uiautomator)

    def __init__(self, labels=None, rearmed=True, acs_page=True, stray_label=None):
        super().__init__(package="com.paycross.example", sleep=lambda seconds: None)
        self.labels = list(labels or [])
        self.rearmed = rearmed
        self.acs_page = acs_page
        self.stray_label = stray_label
        self.actions = []
        self.token_paths = []

    def install(self, app_path):
        self.actions.append(("install", app_path))

    def launch(self):
        self.actions.append(("launch", None))

    def _took_the_token(self, token_path):
        self.token_paths.append(Path(token_path))
        # The runner must have written a real token, readable only by us.
        assert Path(token_path).read_text().startswith("eyJ")
        assert oct(Path(token_path).stat().st_mode)[-3:] == "600"
        assert oct(Path(token_path).parent.stat().st_mode)[-3:] == "700"

    def paste_token(self, token_path):
        self.actions.append(("paste_token", None))
        self._took_the_token(token_path)

    def present_token(self, token_path):
        self.actions.append(("present_token", None))
        self._took_the_token(token_path)

    def tap_example_pay(self):
        self.actions.append(("tap_example_pay", None))

    def enter_token(self, literal):
        self.actions.append(("enter_token", literal))

    def type_card(self, card):
        self.actions.append(("type_card", card.pan))

    def tap_pay(self, amount_text):
        self.actions.append(("tap_pay", amount_text))

    def airplane(self, on):
        self.actions.append(("airplane", on))

    def acs(self, outcome):
        self.actions.append(("acs", outcome))

    def wait_acs(self, timeout):
        self.actions.append(("wait_acs", timeout))
        return self.acs_page

    def wait_no_label(self, timeout):
        self.actions.append(("wait_no_label", timeout))
        return self.stray_label

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


def step_for(driver, **over):
    """One `Step`, so a `_perform` test names only the field it is about."""
    fields = {
        "driver": driver,
        "sandbox": FakeSandbox(),
        "card": None,
        "token_path": None,
        "amount_text": "\u20ac10.00",
        "session_id": "sess-0",
        "secrets": [],
    }
    fields.update(over)
    return runner.Step(**fields)


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


def test_the_token_file_is_destroyed_even_when_the_cell_blows_up(cell_dir, tmp_path):
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
        {
            "sess-0": {
                "id": "sess-0",
                "status": "open",
                "transactions": [{"id": "txn-1"}],
            }
        }
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
    # Every cell directory carries a control cell; `only` is what keeps this
    # test to the one cell it is about.
    (directory / "control.yaml").write_text(
        textwrap.dedent(CELL.format(id="control")), encoding="utf-8"
    )
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
        only=["rearm"],
    )
    assert passing.results[0].passed

    not_rearmed = runner.run_cells(
        platform="android",
        cell_dir=directory,
        evidence_root=tmp_path / "e2",
        driver=FakeDriver(labels=["result:cancelled"], rearmed=False),
        sandbox=sandbox,
        run_all=True,
        only=["rearm"],
    )
    assert not not_rearmed.results[0].passed
    assert any("rearm" in p for p in not_rearmed.results[0].problems)


def test_a_rearm_that_never_came_names_the_deadline_the_wait_really_used():
    # Replaces `_rearm_problem`, whose two cases are both gone: a falsy answer
    # is reported by the generic `expect` handler with the expectation's name
    # and its own timeout, and "expects a re-arm and never looks for one" is
    # refused at load by `load_cell`'s cross-field rule. A branch that can no
    # longer be reached is worse than no branch.
    assert not hasattr(runner, "_rearm_problem")
    assert runner.EXPECT_TIMEOUT_SECONDS["rearmed"] == runner.REARM_TIMEOUT_SECONDS


# -- skepticism -------------------------------------------------------------


def test_a_failure_interleaves_a_control_cell_before_it_is_recorded(cell_dir, tmp_path):
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


def test_the_control_check_runs_even_when_only_names_one_other_cell(cell_dir, tmp_path):
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


def test_evidence_holds_a_tree_per_action_and_the_merchant_response(cell_dir, tmp_path):
    run(cell_dir, tmp_path, FakeDriver(), only=["control"])

    cell_files = names(tmp_path)
    assert "merchant.json" in cell_files
    assert "result.json" in cell_files
    assert "logs.txt" in cell_files
    assert any(
        n.startswith("01-paste_token") and n.endswith(".uix") for n in cell_files
    )
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


def test_the_progress_record_is_scrubbed_with_the_token_too(cell_dir, tmp_path):
    # The label is read off the device, so it can carry anything that is on
    # screen -- and progress.jsonl is the one artifact whose text does not
    # come from the already-redacted problems list.
    driver = FakeDriver(labels=[f"result:success:{TOKEN}"])

    run(cell_dir, tmp_path, driver, only=["control"])

    progress = next((tmp_path / "evidence").glob("*/progress.jsonl"))
    assert TOKEN.encode() not in progress.read_bytes()


def test_the_result_file_records_the_verdict_and_what_was_expected(cell_dir, tmp_path):
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


def test_a_hung_device_fails_the_cell_instead_of_killing_the_matrix(cell_dir, tmp_path):
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
    (directory / "control.yaml").write_text(
        textwrap.dedent(CELL.format(id="control")), encoding="utf-8"
    )
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

    report = run(directory, tmp_path, driver, only=["rearm"])

    problems = report.results[0].problems
    assert any("driver: no parsable" in p for p in problems)
    assert not any(p.startswith("rearm:") for p in problems)


def test_a_screenshot_failure_is_recorded_and_the_cell_carries_on(cell_dir, tmp_path):
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


def test_a_merchant_read_failure_is_reported_as_the_cell_s_problem(cell_dir, tmp_path):
    sandbox = FakeSandbox()
    sandbox.read = raises(SandboxError("GET /sessions/sess-0 -> HTTP 500"))

    report = run(cell_dir, tmp_path, FakeDriver(), sandbox=sandbox, only=["control"])

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


def test_a_driver_error_quoting_the_session_token_is_redacted_too(cell_dir, tmp_path):
    driver = FakeDriver()
    driver.tap_pay = raises(DriverError(f"the field reads {TOKEN}"))

    report = run(cell_dir, tmp_path, driver, only=["control"])

    assert not any(TOKEN in p for p in report.results[0].problems)


def test_the_merchant_read_s_own_token_never_reaches_disk(cell_dir, tmp_path):
    # The API re-mints a session token on every read of an OPEN session and
    # hands it back in the resource, plus a second copy in checkout_url's
    # `session=` parameter. The runner cannot pass it to `secrets=`: it has
    # never seen it, and it is not the token it minted. It reached
    # merchant.json in the first live iOS run.
    # It shares a long head with the minted one, as the real pair does: same
    # header and same session, merchant, customer and amount claims, differing
    # only in iat, exp, jti and the signature. That is what made the shape rule
    # useless -- the prefix scrub ate the `eyJ` the regex anchors on and left
    # the tail behind.
    minted = MINTED_LIKE_THE_REAL_ONE
    reminted = minted[:-24] + "B" * 24
    sandbox = FakeSandbox(
        sessions={
            "sess-0": {
                "id": "sess-0",
                "status": "open",
                "session_token": reminted,
                "checkout_url": (
                    f"https://checkout.test-pay-cross.com/?session={reminted}"
                ),
                "transactions": [{"id": "txn-1", "status": "succeeded"}],
            }
        },
        token=minted,
    )

    run(cell_dir, tmp_path, FakeDriver(), only=["control"], sandbox=sandbox)

    written = [p for p in tmp_path.rglob("*") if p.is_file()]
    assert written, "the run filed nothing to check"
    for path in written:
        text = path.read_text(errors="replace")
        assert reminted not in text, path
        # And no headless remnant of it either.
        assert reminted[-24:] not in text, path


def test_the_merchant_read_s_own_token_is_a_secret_for_the_rest_of_the_cell(
    cell_dir, tmp_path
):
    # Once the resource has been read the runner knows the string, so anything
    # filed after it -- the logs among them -- can be scrubbed of it by
    # literal rather than left to the shape rule.
    reminted = MINTED_LIKE_THE_REAL_ONE[:-24] + "B" * 24
    sandbox = FakeSandbox(
        sessions={
            "sess-0": {
                "id": "sess-0",
                "status": "open",
                "session_token": reminted,
                "transactions": [{"id": "txn-1", "status": "succeeded"}],
            }
        },
        token=MINTED_LIKE_THE_REAL_ONE,
    )
    driver = FakeDriver()
    driver.logs_since = lambda since: f"a log line quoting {reminted} verbatim"

    run(cell_dir, tmp_path, driver, only=["control"], sandbox=sandbox)

    logs = next(tmp_path.rglob("logs.txt")).read_text()
    assert reminted not in logs
    # And not the headless tail either: that is the shape the leak really took
    # on disk, not the whole token. `reminted[-24:]` rather than
    # MINTED_LIKE_THE_REAL_ONE[-24:] -- the minted token's own last 24
    # characters are the slice `reminted` replaced, so they never appear in
    # this log at all and asserting their absence would prove nothing.
    assert reminted[-24:] not in logs
    assert "REDACTED-SESSION-TOKEN" in logs


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
    # Seconds to one decimal: a budget is a real number, and "0s" reads as
    # a missing value rather than as the number that was actually spent.
    assert any("0.0s" in p for p in report.results[0].problems)
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
    for name in ("control", "frictionless"):
        (directory / f"{name}.yaml").write_text(
            textwrap.dedent(CELL.format(id=name)), encoding="utf-8"
        )
    (directory / "ios_only.yaml").write_text(
        textwrap.dedent(CELL.format(id="ios_only")).replace(
            "platforms: [android, ios]", "platforms: [ios]"
        ),
        encoding="utf-8",
    )

    report = run(directory, tmp_path, FakeDriver())

    assert [r.cell_id for r in report.results] == ["control", "frictionless"]


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


# -- what a consumer of the report is allowed to see --------------------------


def test_the_label_is_scrubbed_before_it_reaches_stdout(
    cell_dir, tmp_path, capsys, monkeypatch
):
    # The label is read off the device and main prints it. Scrubbing it in
    # run_cell rather than at the print keeps every consumer -- stdout, the
    # progress ledger, result.json -- looking at the same redacted value.
    class StubSandbox:
        @staticmethod
        def from_env_file(path):
            return FakeSandbox()

    monkeypatch.setattr(runner, "Sandbox", StubSandbox)
    monkeypatch.setattr(
        runner,
        "_build_driver",
        lambda platform: FakeDriver(labels=[f"result:success:{TOKEN}"] * 4),
    )

    runner.main(
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

    assert TOKEN not in capsys.readouterr().out


def test_the_scrubbed_label_is_what_the_result_carries(cell_dir, tmp_path):
    driver = FakeDriver(labels=[f"result:success:{TOKEN}"])

    report = run(cell_dir, tmp_path, driver, only=["control"])

    assert TOKEN not in report.results[0].label
    assert "REDACTED-SESSION-TOKEN" in report.results[0].label


# -- findings a cut-short cell is not allowed to invent ------------------------


def test_a_failure_does_not_invent_a_merchant_finding(cell_dir, tmp_path):
    # The cell never got to the payment, so "the session is still open" is
    # what the first failure implies, not a second finding.
    sandbox = FakeSandbox(
        {"sess-0": {"id": "sess-0", "status": "open", "transactions": []}}
    )
    driver = FakeDriver()
    driver.tap_pay = raises(DriverError("no node with text 'Pay'"))

    report = run(cell_dir, tmp_path, driver, sandbox=sandbox, only=["control"])

    problems = report.results[0].problems
    assert any("driver: " in p for p in problems)
    assert not any(p.startswith("session_status:") for p in problems)
    assert not any(p.startswith("txn_count:") for p in problems)
    # Still filed: it is how you tell a driver that lost the device from a
    # payment that never happened.
    assert "merchant.json" in names(tmp_path)


def test_a_crash_is_reported_even_when_the_cell_was_cut_short(cell_dir, tmp_path):
    # A crash is not a consequence of the first failure -- it is very often
    # the cause of it.
    driver = FakeDriver()
    driver.tap_pay = raises(DriverError("no node with text 'Pay'"))
    driver.logs_since = lambda since: "E AndroidRuntime: FATAL EXCEPTION: main\n"

    report = run(cell_dir, tmp_path, driver, only=["control"])

    assert any("FATAL EXCEPTION" in p for p in report.results[0].problems)


# -- the rig checks cannot be silently off ------------------------------------


def test_a_cell_directory_with_no_control_cell_is_refused(tmp_path):
    # Without one there is no interleaved check and no abort rule, and a run
    # that cannot tell an SDK finding from a broken rig should not start.
    directory = tmp_path / "d0"
    directory.mkdir()
    (directory / "frictionless.yaml").write_text(
        textwrap.dedent(CELL.format(id="frictionless")), encoding="utf-8"
    )

    with pytest.raises(CellError) as error:
        run(directory, tmp_path, FakeDriver())

    assert "control" in str(error.value)


def test_a_cell_id_that_could_escape_the_run_directory_is_refused(tmp_path):
    # The same guard the evidence tree uses, applied before a cell id is made
    # into a token filename or a directory name.
    directory = tmp_path / "d0"
    directory.mkdir()
    (directory / "control.yaml").write_text(
        textwrap.dedent(CELL.format(id="control")), encoding="utf-8"
    )
    (directory / "...yaml").write_text(
        textwrap.dedent(CELL.format(id="..")), encoding="utf-8"
    )

    with pytest.raises(CellError) as error:
        run(directory, tmp_path, FakeDriver())

    assert "unsafe" in str(error.value).lower()


def test_a_d3_action_is_an_authoring_problem_and_skips_the_control_check(tmp_path):
    # NotImplementedError is the driver saying the cell asked for something
    # Phase 0 does not have. Nothing about the rig is in doubt, so spending a
    # control cell on it would only add a session and a minute.
    directory = tmp_path / "d0"
    directory.mkdir()
    (directory / "control.yaml").write_text(
        textwrap.dedent(CELL.format(id="control")), encoding="utf-8"
    )
    (directory / "lifecycle.yaml").write_text(
        textwrap.dedent(CELL.format(id="lifecycle")).replace(
            "  - tap_pay\n", "  - tap_pay\n  - rotate\n"
        ),
        encoding="utf-8",
    )
    driver = FakeDriver()
    driver.rotate = raises(NotImplementedError("rotate is a D3 action"))

    report = run(directory, tmp_path, driver, only=["lifecycle"])

    assert any("authoring: " in p for p in report.results[0].problems)
    assert [r.cell_id for r in report.results] == ["lifecycle"]


# -- hygiene the run owns -----------------------------------------------------


def test_a_token_file_that_will_not_go_is_a_run_problem(
    cell_dir, tmp_path, monkeypatch
):
    # A live credential still on disk is not a verdict about the payment, and
    # it must not be swallowed by ignore_errors either.
    def refuse(path):
        raise OSError("device or resource busy")

    monkeypatch.setattr(runner.shutil, "rmtree", refuse)

    report = run(cell_dir, tmp_path, FakeDriver(), only=["control"])

    assert report.results[0].passed
    assert any("token" in p for p in report.problems)
    # Which cell's, because a matrix run leaves one temp directory per cell
    # and "a token file" names none of them.
    assert any("control" in p for p in report.problems)
    assert report.exit_code != 0


def test_the_card_form_is_shot_while_the_sheet_is_foreground(cell_dir, tmp_path):
    # type_card runs with the sheet up, so the guard covers it -- and the dump
    # beside the frame is the caret evidence the seed script used to produce.
    run(cell_dir, tmp_path, FakeDriver(), only=["control"])

    assert "02-type_card.png" in names(tmp_path)
    assert "02-type_card.uix" in names(tmp_path)


# -- budgets ------------------------------------------------------------------


def test_the_type_card_budget_is_derived_from_the_drivers_own_pacing():
    # Restated rather than referenced, it drifts the first time the pacing
    # changes -- and the pacing is what the 0.3.2 caret fix was proven under.
    assert runner.VERB_BUDGET_SECONDS["type_card"] == pytest.approx(
        16 * android.DIGIT_PACING_SECONDS + runner.CARD_FIELDS_SECONDS
    )


def test_the_paste_token_budget_covers_the_ios_worst_case():
    # 60 s for the example's own screen, 60 s for the sheet, a 10 s read-back
    # and the paste itself.
    assert runner.VERB_BUDGET_SECONDS["paste_token"] >= 160


# -- exit codes ---------------------------------------------------------------


def test_an_aborted_run_exits_three_so_the_nightly_can_tell_it_apart(tmp_path):
    directory = tmp_path / "d0"
    directory.mkdir()
    for name in ("a_cell", "b_cell", "control"):
        (directory / f"{name}.yaml").write_text(
            textwrap.dedent(CELL.format(id=name)), encoding="utf-8"
        )

    report = run(directory, tmp_path, FakeDriver(labels=["result:cancelled"] * 20))

    assert report.aborted
    assert report.exit_code == 3


def test_a_cell_failure_exits_one_and_a_clean_run_exits_zero(cell_dir, tmp_path):
    assert run(cell_dir, tmp_path, FakeDriver()).exit_code == 0

    failed = run(
        cell_dir, tmp_path, FakeDriver(labels=["result:cancelled"]), only=["control"]
    )

    assert failed.exit_code == 1


# -- the command line ---------------------------------------------------------


def test_installing_a_build_reruns_every_cell(cell_dir, tmp_path, capsys, monkeypatch):
    # An APK is a different build, and passed_cells has no idea which build a
    # pass came from: resuming onto a new one would report yesterday's result.
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

    code = runner.main(argv + ["--app", "/tmp/app-debug.apk"])

    out = capsys.readouterr().out
    assert code == 0
    assert "SKIP" not in out
    assert "PASS control" in out


def test_an_abort_is_printed_before_the_findings_it_disbelieves(
    tmp_path, capsys, monkeypatch
):
    directory = tmp_path / "d0"
    directory.mkdir()
    for name in ("a_cell", "b_cell", "control"):
        (directory / f"{name}.yaml").write_text(
            textwrap.dedent(CELL.format(id=name)), encoding="utf-8"
        )

    class StubSandbox:
        @staticmethod
        def from_env_file(path):
            return FakeSandbox()

    monkeypatch.setattr(runner, "Sandbox", StubSandbox)
    monkeypatch.setattr(
        runner,
        "_build_driver",
        lambda platform: FakeDriver(labels=["result:cancelled"] * 20),
    )

    code = runner.main(
        [
            "--platform",
            "android",
            "--cells",
            str(directory),
            "--evidence-root",
            str(tmp_path / "evidence"),
            "--env-file",
            str(tmp_path / "never-opened.env"),
        ]
    )

    out = capsys.readouterr().out.splitlines()
    assert code == 3
    assert out[0].startswith("ABORT")
    findings = [line for line in out if line.startswith("FAIL")]
    assert findings and all("(unverified)" in line for line in findings)


def test_the_summary_line_counts_the_cells_and_the_control_checks(
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
        lambda platform: FakeDriver(
            labels=["result:success:txn-1", "result:cancelled", "result:success:txn-1"]
        ),
    )

    runner.main(
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

    summary = capsys.readouterr().out.splitlines()[-1]
    assert summary == (
        "2 cells, 1 passed, 1 failed, 0 skipped, 1 control check, aborted: no"
    )


def test_perform_names_the_argument_it_cannot_perform():
    # cells.py rejects this at load time; the message is for whoever adds a
    # verb argument here and forgets the branch that performs it.
    with pytest.raises(DriverError) as error:
        runner._perform(step_for(FakeDriver()), cells.Action("expect", "settled"))

    assert "settled" in str(error.value)


# -- what main checks before it opens the credentials -------------------------


def cli(cells_dir, tmp_path, *extra):
    """main's argv, with an env file that does not exist.

    Reading it would raise before any authoring mistake could be reported, so
    the checks that come first are exactly what these tests are about.
    """
    return [
        "--platform",
        "android",
        "--cells",
        str(cells_dir),
        "--evidence-root",
        str(tmp_path / "evidence"),
        "--env-file",
        str(tmp_path / "absent.env"),
        *extra,
    ]


def test_main_refuses_a_control_less_directory_before_the_env_file(tmp_path, capsys):
    directory = tmp_path / "d0"
    directory.mkdir()
    (directory / "frictionless.yaml").write_text(
        textwrap.dedent(CELL.format(id="frictionless")), encoding="utf-8"
    )

    code = runner.main(cli(directory, tmp_path))

    error = capsys.readouterr().err
    assert code == runner.EXIT_SETUP
    assert "control" in error
    assert "absent.env" not in error


def test_main_refuses_an_unsafe_cell_id_before_the_env_file(tmp_path, capsys):
    directory = tmp_path / "d0"
    directory.mkdir()
    (directory / "control.yaml").write_text(
        textwrap.dedent(CELL.format(id="control")), encoding="utf-8"
    )
    (directory / "...yaml").write_text(
        textwrap.dedent(CELL.format(id="..")), encoding="utf-8"
    )

    code = runner.main(cli(directory, tmp_path))

    error = capsys.readouterr().err
    assert code == runner.EXIT_SETUP
    assert "unsafe" in error.lower()
    assert "absent.env" not in error


def test_the_summary_counts_what_a_resume_skipped(
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

    runner.main(argv)

    summary = capsys.readouterr().out.splitlines()[-1]
    assert summary == (
        "0 cells, 0 passed, 0 failed, 2 skipped, 0 control checks, aborted: no"
    )


# --- Plan B: the build fingerprint reaches the ledger ---------------------


def test_the_build_id_is_written_into_every_progress_record(cell_dir, tmp_path):
    runner.run_cells(
        platform="android",
        cell_dir=cell_dir,
        evidence_root=tmp_path / "evidence",
        driver=FakeDriver(),
        sandbox=FakeSandbox(),
        run_all=True,
        build_id="android-0.3.3-release-r8",
    )

    records = [
        json.loads(line)
        for path in (tmp_path / "evidence").glob("*/progress.jsonl")
        for line in path.read_text().splitlines()
    ]
    assert records
    assert all(r["build"] == "android-0.3.3-release-r8" for r in records if "cell" in r)


def test_a_pass_on_a_debug_build_does_not_skip_the_cell_on_a_release_one(
    cell_dir, tmp_path
):
    common = dict(
        platform="android",
        cell_dir=cell_dir,
        evidence_root=tmp_path / "evidence",
        sandbox=FakeSandbox(),
    )
    runner.run_cells(driver=FakeDriver(), build_id="debug", **common)

    second = runner.run_cells(driver=FakeDriver(), build_id="release", **common)

    assert second.skipped == []
    assert [r.cell_id for r in second.results]


def test_the_build_id_is_recorded_in_result_json(cell_dir, tmp_path):
    runner.run_cells(
        platform="android",
        cell_dir=cell_dir,
        evidence_root=tmp_path / "evidence",
        driver=FakeDriver(),
        sandbox=FakeSandbox(),
        run_all=True,
        build_id="android-0.3.3-release-r8",
    )

    written = next((tmp_path / "evidence").glob("*/control/result.json"))
    assert json.loads(written.read_text())["build"] == "android-0.3.3-release-r8"


# --- Plan B: the run-level report ----------------------------------------


@pytest.fixture
def distinct_run_ids(monkeypatch):
    """One evidence directory per run, even for two runs in the same second.

    `Run`'s generated id is second-resolution, so without this two runs in one
    test share a directory -- and a test about what a run leaves *on its own*
    then reads the other one's files and passes for the wrong reason.
    """
    stamps = iter(f"20260829-1200{n:02d}" for n in range(20))
    monkeypatch.setattr(evidence, "_stamp", lambda: next(stamps))


def report_json(tmp_path):
    """The newest report.json under the evidence root.

    Newest, because a fully-skipped run leaves a directory holding nothing
    else, so a root accumulates them.
    """
    written = sorted((tmp_path / "evidence").glob("*/report.json"))
    return json.loads(written[-1].read_text())


def test_a_finished_run_is_readable_without_parsing_stdout(cell_dir, tmp_path):
    # The exit code was printed and nowhere else, so nothing downstream --
    # the nightly, the campaign report -- could read a finished run.
    report = run(cell_dir, tmp_path, FakeDriver())

    written = report_json(tmp_path)
    assert written["exit_code"] == report.exit_code == 0
    assert written["platform"] == "android"
    assert written["cells_dir"] == str(cell_dir)
    assert [c["cell"] for c in written["cells"]] == ["control", "frictionless"]
    assert all(c["passed"] for c in written["cells"])
    assert written["started"] <= written["finished"]


def test_a_report_is_written_when_the_run_aborts(cell_dir, tmp_path):
    # Every label wrong, so the control fails and so does its check: two in a
    # row, which is the rig-fault rule.
    driver = FakeDriver(labels=["result:cancelled"] * 20)

    report = run(cell_dir, tmp_path, driver)

    written = report_json(tmp_path)
    assert written["aborted"] is True
    assert written["abort_reason"] == report.abort_reason
    assert written["exit_code"] == report.exit_code == runner.EXIT_ABORTED


def test_a_report_is_written_even_when_every_cell_was_skipped(
    cell_dir, tmp_path, distinct_run_ids
):
    # A fully-resumed run is exactly what Task 10 reads while assembling its
    # tables, and it used to return before the Run was ever constructed.
    run(cell_dir, tmp_path, FakeDriver())

    second = run(cell_dir, tmp_path, FakeDriver(), run_all=False)

    assert second.results == []
    assert second.skipped == ["control", "frictionless"]
    # Its own directory, holding nothing but the report -- which is what the
    # resume test below turns on.
    latest = sorted((tmp_path / "evidence").iterdir())[-1]
    assert [p.name for p in latest.iterdir()] == ["report.json"]
    written = report_json(tmp_path)
    assert written["cells"] == []
    assert written["skipped"] == ["control", "frictionless"]
    assert written["exit_code"] == second.exit_code == 0


def test_a_skipped_runs_directory_cannot_satisfy_a_later_resume(
    cell_dir, tmp_path, distinct_run_ids
):
    run(cell_dir, tmp_path, FakeDriver(), only=["control"])
    run(cell_dir, tmp_path, FakeDriver(), only=["control"], run_all=False)

    # Two directories, and the second really is the bare one: without distinct
    # ids both runs share a directory and this passes for the wrong reason.
    written = sorted((tmp_path / "evidence").iterdir())
    assert len(written) == 2
    assert not (written[-1] / "progress.jsonl").exists()
    # And passed_cells globs `*/progress.jsonl`, so the bare one contributes
    # nothing rather than being counted as a run that passed no cells.
    assert evidence.passed_cells(tmp_path / "evidence", "android") == {"control"}


def test_a_fully_skipped_run_touches_no_device(cell_dir, tmp_path, distinct_run_ids):
    run(cell_dir, tmp_path, FakeDriver())
    driver = FakeDriver()

    run(cell_dir, tmp_path, driver, run_all=False)

    assert driver.actions == []


def test_a_token_spliced_into_a_problem_does_not_survive_into_the_report(
    cell_dir, tmp_path
):
    driver = FakeDriver()
    driver.type_card = raises(DriverError(f"the form said {JWT}"))

    run(cell_dir, tmp_path, driver, sandbox=FakeSandbox(token=JWT), only=["control"])

    raw = next((tmp_path / "evidence").glob("*/report.json")).read_bytes()
    assert b"eyJ" not in raw
    assert b"[REDACTED-SESSION-TOKEN]" in raw


def test_a_sandbox_warning_is_recorded_beside_the_verdicts_not_among_them(
    cell_dir, tmp_path
):
    # A warning must not turn a green matrix red, or the next person to see
    # one learns to silence it.
    sandbox = FakeSandbox()
    sandbox.warnings.append("the access token is a JWT but its 'exp' is a str")

    report = run(cell_dir, tmp_path, FakeDriver(), sandbox=sandbox)

    assert report.exit_code == 0
    assert report.problems == []
    assert report.warnings == sandbox.warnings
    assert report_json(tmp_path)["warnings"] == sandbox.warnings


def test_a_warning_is_printed_but_does_not_change_the_exit_code(
    cell_dir, tmp_path, capsys, monkeypatch
):
    sandbox = FakeSandbox()
    sandbox.warnings.append("the access token's exp is 5400s in the past")
    monkeypatch.setattr(runner, "_build_driver", lambda platform: FakeDriver())
    monkeypatch.setattr(
        runner.Sandbox,
        "from_env_file",
        classmethod(lambda cls, path, transport=None: sandbox),
    )
    env = tmp_path / ".env"
    env.write_text("x=1\n", encoding="utf-8")

    code = runner.main(
        [
            "--platform",
            "android",
            "--cells",
            str(cell_dir),
            "--evidence-root",
            str(tmp_path / "evidence"),
            "--env-file",
            str(env),
            "--all",
        ]
    )

    assert code == 0
    assert "WARN the access token's exp is 5400s in the past" in capsys.readouterr().out


# --- Plan B: the guard's refusals are evidence too ------------------------


def test_the_frames_the_screenshot_guard_refused_are_named(cell_dir, tmp_path):
    # "0 screenshots on iOS" was invisible in the evidence rather than
    # explained by it.
    driver = FakeDriver()
    driver.dump_tree = lambda: f'<hierarchy><node text="{TOKEN}"/></hierarchy>'.encode()

    run(cell_dir, tmp_path, driver, only=["control"])

    written = json.loads(
        next((tmp_path / "evidence").glob("*/control/result.json")).read_text()
    )
    assert written["screenshots_skipped"] == ["02-type_card", "03-tap_pay"]
    assert not list((tmp_path / "evidence").glob("*/control/*.png"))


def test_a_run_that_took_every_frame_it_could_names_none(cell_dir, tmp_path):
    run(cell_dir, tmp_path, FakeDriver(), only=["control"])

    written = json.loads(
        next((tmp_path / "evidence").glob("*/control/result.json")).read_text()
    )
    assert written["screenshots_skipped"] == []


#: A token the merchant API re-minted mid-cell. Deliberately not JWT_RE-shaped
#: -- its segments are under sixteen characters -- and with a different first
#: 24 characters from TOKEN, so a test using it separates the literal tell from
#: the shape rule.
RE_MINTED = "eyJraWQiOiJ0d28ifQ.eyJiIjoyfQ.gis"


def test_a_frame_is_refused_while_a_re_minted_token_is_on_screen():
    # `wait_expired` re-mints on every poll, so by a later step the string in
    # the example's token field is not the one the cell started with. Told
    # only the original, the literal tell goes stale and the guard is left
    # with the shape rule -- which `scrub_resource` refuses to rely on for
    # exactly this, having already been shown to miss a token twice.
    assert evidence.JWT_RE.search(RE_MINTED.encode()) is None
    assert RE_MINTED[:24] != TOKEN[:24]
    dump = f'<hierarchy><node text="{RE_MINTED}"/></hierarchy>'.encode()

    assert runner._may_screenshot("expect", dump, "android", [TOKEN]) is True
    assert (
        runner._may_screenshot("expect", dump, "android", [TOKEN, RE_MINTED]) is False
    )


class ReMintingSandbox(FakeSandbox):
    """A merchant API that re-mints once and has expired by the next read.

    Both halves of what `wait_expired` is for: the first read of an open
    session hands back a token the runner never minted, and the read after it
    is the flip the verb is waiting for.
    """

    def __init__(self):
        super().__init__()
        self.reads = 0

    def read(self, session_id):
        self.reads += 1
        if self.reads == 1:
            return {"id": session_id, "status": "open", "session_token": RE_MINTED}
        return {"id": session_id, "status": "expired"}


def re_minting_cell_dir(tmp_path):
    """A control cell that re-mints before the step whose frame is at stake."""
    directory = tmp_path / "d2"
    directory.mkdir()
    (directory / "control.yaml").write_text(
        textwrap.dedent(CELL.format(id="control")).replace(
            "  - tap_pay\n", "  - wait_expired 1\n  - tap_pay\n"
        ),
        encoding="utf-8",
    )
    return directory


def test_a_cell_that_re_minted_files_no_frame_of_the_new_token(tmp_path, monkeypatch):
    # The wiring half: `run_cell` has to hand the guard the list it keeps
    # extending, not the one credential it started with. Reverting that call
    # site leaves the unit test above green.
    monkeypatch.setattr(runner.time, "sleep", lambda seconds: None)
    driver = FakeDriver()
    driver.dump_tree = (
        lambda: f'<hierarchy><node text="{RE_MINTED}"/></hierarchy>'.encode()
    )

    run(
        re_minting_cell_dir(tmp_path),
        tmp_path,
        driver,
        sandbox=ReMintingSandbox(),
    )

    # tap_pay is a SHOT_VERB, and its dump is showing the re-minted token.
    assert not list((tmp_path / "evidence").glob("*/control/*tap_pay*.png"))
    assert list((tmp_path / "evidence").glob("*/control/*tap_pay*.uix"))


def test_a_cell_that_died_after_re_minting_files_no_frame_either(tmp_path, monkeypatch):
    # The failure path takes its own frame, from a second `_may_screenshot`
    # call site -- the `-failed.png` beside the dump of the moment the cell
    # died. The test above cannot reach it, because a cell that reaches its
    # last action never fails, so reverting THAT call site to the minted token
    # alone left the whole suite green and photographed the example's screen,
    # token field and all.
    monkeypatch.setattr(runner.time, "sleep", lambda seconds: None)
    driver = FakeDriver()
    driver.dump_tree = (
        lambda: f'<hierarchy><node text="{RE_MINTED}"/></hierarchy>'.encode()
    )

    def never_appeared(amount_text):
        raise DriverError("the Pay button never appeared")

    driver.tap_pay = never_appeared

    run(
        re_minting_cell_dir(tmp_path),
        tmp_path,
        driver,
        sandbox=ReMintingSandbox(),
    )

    # The failure path really ran -- there is a dump of the step that died --
    # and it filed no frame beside it. Scoped to the `-failed` pair: the
    # frames before `wait_expired` are taken while the re-minted token does
    # not yet exist, and this fake serves the same dump at every step.
    assert list((tmp_path / "evidence").glob("*/control/*tap_pay-failed.uix"))
    assert not list((tmp_path / "evidence").glob("*/control/*-failed.png"))


def test_a_re_minted_token_in_a_label_never_reaches_stdout(
    tmp_path, monkeypatch, capsys
):
    # A label comes off the device and `main` prints it, so the scrub happens
    # where it is read. Told only the token the cell minted, that scrub goes
    # stale the moment `wait_expired` re-mints -- and a re-minted token whose
    # segments are shorter than the shape rule wants is caught by nothing
    # else, so it would have reached the terminal intact.
    monkeypatch.setattr(runner.time, "sleep", lambda seconds: None)
    driver = FakeDriver(labels=[f"result:success:{RE_MINTED}"])
    sandbox = ReMintingSandbox()
    monkeypatch.setattr(runner, "_build_driver", lambda platform: driver)
    monkeypatch.setattr(
        runner.Sandbox,
        "from_env_file",
        classmethod(lambda cls, path, transport=None: sandbox),
    )
    env = tmp_path / ".env"
    env.write_text("x=1\n", encoding="utf-8")

    runner.main(
        [
            "--platform",
            "android",
            "--cells",
            str(re_minting_cell_dir(tmp_path)),
            "--evidence-root",
            str(tmp_path / "evidence"),
            "--env-file",
            str(env),
            "--all",
        ]
    )

    printed = capsys.readouterr().out
    assert RE_MINTED not in printed
    assert "result:success:[REDACTED-SESSION-TOKEN]" in printed


def test_a_dump_that_cannot_be_parsed_is_not_a_licence_to_photograph():
    # A leaked frame cannot be un-leaked and a missing one costs nothing, so
    # an unreadable dump counts as "the example's screen is showing".
    assert runner._shows_the_example_screen(b"<not xml", "android", []) is True
    assert runner._shows_the_example_screen(b"<not xml", "ios", []) is True
    assert not runner._may_screenshot("tap_pay", b"<not xml", "android", [])


def test_a_cell_whose_dumps_are_unreadable_files_no_frame(cell_dir, tmp_path):
    driver = FakeDriver()
    driver.dump_tree = lambda: b"<not xml"

    run(cell_dir, tmp_path, driver, only=["control"])

    assert not list((tmp_path / "evidence").glob("*/control/*.png"))


def test_a_wait_expired_cell_is_budgeted_from_its_own_argument(tmp_path):
    # D2's session_expired cells wait 16 and 30 minutes. On the default 120 s
    # a cell would breach its budget mid-wait and report a hang, which is the
    # false finding this whole file is arranged to avoid.
    directory = tmp_path / "d2"
    directory.mkdir()
    (directory / "control.yaml").write_text(
        textwrap.dedent(CELL.format(id="control")).replace(
            "  - wait_result 60\n", "  - wait_expired 960\n  - wait_result 60\n"
        ),
        encoding="utf-8",
    )
    cell = cells.load_cell(directory / "control.yaml")

    assert runner.budget_for(cell) > 960


# --- review: a verb with no branch is an authoring fault ------------------


@pytest.mark.parametrize(
    "verb, arg",
    [
        ("tap_google_pay", None),
        ("select_saved_card", None),
        ("save_card", None),
        ("type_cvv", None),
        ("dont_keep_activities", "on"),
    ],
)
def test_a_verb_a_later_dimension_owns_is_an_authoring_fault(verb, arg):
    # The cell file is wrong, not the rig, so no control check is spent
    # proving a rig that was never in doubt. `cells.py` accepts these verbs
    # today and `_perform` dispatches every one of them; what refuses is the
    # `Driver` declaration behind it, which is the layer that knows whether
    # the dimension has landed.
    # And the refusal names the verb, because `run_cell` files the exception's
    # own message as the cell's problem: without the name the reader is told a
    # dimension has not landed but not which action asked for it.
    with pytest.raises(NotImplementedError, match=verb):
        runner._perform(
            step_for(FakeDriver(), card=cells.Card("4111111111111111", "12/28", "123")),
            cells.Action(verb, arg),
        )


@pytest.mark.parametrize("arg", ["google_pay", "no_google_pay", "saved_card"])
def test_an_expectation_a_later_dimension_owns_is_an_authoring_fault_too(arg):
    with pytest.raises(NotImplementedError, match=f"wait_{arg}"):
        runner._perform(step_for(FakeDriver()), cells.Action("expect", arg))


@pytest.mark.parametrize("verb", ["airplane", "dont_keep_activities"])
@pytest.mark.parametrize("arg", ["ON", "true", "", None])
def test_an_on_off_verb_refuses_an_argument_that_is_neither(verb, arg):
    # These branches match on the verb alone, so `arg == "on"` quietly
    # performed everything else as `off` -- and a cell built by hand asking
    # for "ON" would have measured the opposite of what it asked for.
    with pytest.raises(DriverError, match="'on' or 'off'"):
        runner._perform(step_for(FakeDriver()), cells.Action(verb, arg))


def test_a_verb_the_grammar_does_not_know_is_still_a_driver_error():
    # Not reachable from a cell file -- load_cell refuses it -- but run_cell
    # takes an Action, so this is the honest answer for one built by hand.
    with pytest.raises(DriverError, match="invented"):
        runner._perform(step_for(FakeDriver()), cells.Action("invented", "x"))


def test_a_verb_added_to_the_grammar_with_no_branch_is_an_authoring_fault(monkeypatch):
    # Every verb the grammar holds today has a branch, so this guard is about
    # the next one somebody adds. NotImplementedError rather than a silent
    # no-op or an AttributeError: the cell reached for a dimension that has
    # not landed, which is a cell-file mistake and costs no control check.
    monkeypatch.setattr(runner, "BARE_ACTIONS", runner.BARE_ACTIONS | {"teleport"})

    with pytest.raises(NotImplementedError, match="no branch"):
        runner._perform(step_for(FakeDriver()), cells.Action("teleport"))


def test_an_authoring_fault_spends_no_control_check(cell_dir, tmp_path):
    # The whole point of the classification: a driver refusing a verb says
    # nothing about the rig, and a control cell costs a session and a minute.
    directory = tmp_path / "d3"
    directory.mkdir()
    (directory / "control.yaml").write_text(
        textwrap.dedent(CELL.format(id="control")), encoding="utf-8"
    )
    (directory / "wallet.yaml").write_text(
        textwrap.dedent(CELL.format(id="wallet")).replace(
            "  - tap_pay\n", "  - tap_pay\n  - tap_google_pay\n"
        ),
        encoding="utf-8",
    )

    report = run(directory, tmp_path, FakeDriver())

    wallet = next(r for r in report.results if r.cell_id == "wallet")
    assert wallet.authoring is True
    assert not wallet.passed
    assert any("tap_google_pay" in p for p in wallet.problems)
    # No interleaved control check was run for it.
    assert [r.artifact_id for r in report.results if r.is_control_check] == []


# --- D2: the generic observer ----------------------------------------------


@pytest.mark.parametrize("what", sorted(cells.EXPECTATIONS))
def test_every_expectation_has_a_deadline_and_a_predicate(what):
    # The drift this exists to stop: `run_cell`'s obvious shape -- an `elif`
    # per argument -- silently discards the answer of every expectation it has
    # no branch for, and the ones that arrive later are exactly the ones whose
    # only job is to look. So a new expectation is one line in `_observe` and
    # one in the table, and this fails the suite if it is neither.
    assert what in runner.EXPECT_TIMEOUT_SECONDS

    # First against a driver that stubs nothing, so the predicate this
    # expectation names has to exist -- as a real method or as the `Driver`
    # declaration that raises. A missing one is an AttributeError, which
    # `run_cell` reads as a broken device rather than as the cell-file mistake
    # it is, and two of those abort the run.
    try:
        runner._observe(step_for(FakeDriver()), what)
    except NotImplementedError:
        pass

    driver = FakeDriver()
    # Whichever predicate this expectation reaches, it answers "no".
    driver.wait_rearmed = lambda amount_text, timeout: False
    driver.wait_no_label = lambda timeout: "result:success:txn-9"
    driver.wait_acs = lambda timeout: False
    driver.wait_google_pay = lambda timeout: False
    driver.wait_no_google_pay = lambda timeout: False
    driver.wait_saved_card = lambda timeout: False

    observed, _ = runner._observe(step_for(driver), what)

    assert observed is False


def test_a_falsy_predicate_is_a_cell_failure_that_names_it(tmp_path, cell_dir):
    # `expect google_pay` answering False would otherwise leave
    # `google_pay_offered` passing on a sheet with no wallet button at all.
    driver = FakeDriver()
    driver.wait_google_pay = lambda timeout: False
    directory = tmp_path / "d4"
    directory.mkdir()
    (directory / "control.yaml").write_text(
        textwrap.dedent(CELL.format(id="control")), encoding="utf-8"
    )
    (directory / "wallet.yaml").write_text(
        textwrap.dedent(CELL.format(id="wallet")).replace(
            "  - wait_result 60\n", "  - expect google_pay\n  - wait_result 60\n"
        ),
        encoding="utf-8",
    )

    report = run(directory, tmp_path, driver, only=["wallet"])

    problem = next(p for p in report.results[0].problems if p.startswith("expect:"))
    assert "'google_pay'" in problem
    # And the number the wait actually used, not a constant restated here.
    assert f"{runner.WALLET_TIMEOUT_SECONDS}s" in problem


def test_expect_no_result_reports_the_label_that_should_not_exist(tmp_path):
    # Inverted, and converted inside `_observe` rather than leaving every
    # caller to know which way round it reads.
    driver = FakeDriver(stray_label="result:success:txn-9")

    observed, detail = runner._observe(step_for(driver), "no_result")

    assert observed is False
    assert detail == "result:success:txn-9"
    assert runner._observe(step_for(FakeDriver()), "no_result") == (True, None)


def test_a_result_that_should_not_exist_is_named_and_scrubbed(tmp_path):
    # `expect no_result` is the Android process-kill cell's whole assertion:
    # the pending Dart call dies with the isolate and nothing is delivered BY
    # DESIGN. When something is, the failure has to say what -- through the
    # same scrub as every other problem, because a label carries the
    # transaction id and a driver message can carry more.
    # TOKEN is deliberately not JWT_RE-shaped, so what keeps it out of the
    # problem line is the literal-secret scrub rather than `redact()`'s shape
    # rule -- the one that has already been shown to miss a token twice.
    driver = FakeDriver(stray_label=f"result:success:{TOKEN}")
    directory = tmp_path / "d3"
    directory.mkdir()
    (directory / "control.yaml").write_text(
        textwrap.dedent(CELL.format(id="control")), encoding="utf-8"
    )
    (directory / "killed.yaml").write_text(
        textwrap.dedent(CELL.format(id="killed"))
        .replace('  label: "result:success:<txn>"', '  label: "<none>"')
        .replace("  - wait_result 60\n", "  - expect no_result\n"),
        encoding="utf-8",
    )

    report = run(directory, tmp_path, driver, only=["killed"])

    problem = next(p for p in report.results[0].problems if p.startswith("expect:"))
    assert "'no_result'" in problem
    assert f"{runner.NO_RESULT_TIMEOUT_SECONDS}s" in problem
    assert "saw" in problem
    # The label named the token, and the token does not reach a problem line.
    assert TOKEN not in problem
    assert "REDACTED" in problem


def test_an_expectation_with_no_deadline_is_not_a_key_error():
    # A direct lookup would raise KeyError, and KeyError is exactly the
    # miscategorised error this design is about: `run_cell` reads DriverError
    # and NotImplementedError as things it knows how to report, and anything
    # else as a device problem worth an interleaved control check.
    with pytest.raises(DriverError, match="no deadline"):
        runner._observe(step_for(FakeDriver()), "settled")


def test_an_expectation_with_a_deadline_and_no_predicate_says_so(monkeypatch):
    # Not the same drift as the guard above: falling off the end instead would
    # return None, which `run_cell` unpacks as a tuple.
    monkeypatch.setitem(runner.EXPECT_TIMEOUT_SECONDS, "settled", 30)

    with pytest.raises(DriverError, match="no predicate"):
        runner._observe(step_for(FakeDriver()), "settled")


def test_expect_acs_observes_the_page_and_taps_nothing(tmp_path):
    driver = FakeDriver()

    assert runner._observe(step_for(driver), "acs") == (True, None)
    assert driver.actions == [("wait_acs", runner.ACS_PAGE_TIMEOUT_SECONDS)]


def test_the_expect_table_agrees_with_the_drivers_own_defaults():
    # `runner` imports `drivers`, so a driver cannot import back: each keeps
    # its own literal default and `_observe` always passes `timeout=`
    # explicitly. That makes this table the value really used and the driver
    # defaults a courtesy to a direct caller -- but the pair must stay equal
    # or a message would name a number no wait ever spent.
    import inspect

    from tool.e2e.drivers.android import AndroidDriver
    from tool.e2e.drivers.ios import IosDriver

    for driver_class in (AndroidDriver, IosDriver):
        default = inspect.signature(driver_class.wait_acs).parameters["timeout"].default
        assert default == runner.EXPECT_TIMEOUT_SECONDS["acs"], driver_class


# --- D2: the new action branches --------------------------------------------


def test_present_token_hands_the_driver_the_cells_token_file(tmp_path, cell_dir):
    driver = FakeDriver()
    directory = tmp_path / "d2"
    directory.mkdir()
    (directory / "control.yaml").write_text(
        textwrap.dedent(CELL.format(id="control")).replace(
            "  - paste_token\n  - type_card\n  - tap_pay\n", "  - present_token\n"
        ),
        encoding="utf-8",
    )

    run(directory, tmp_path, driver)

    assert ("present_token", None) in driver.actions
    assert driver.token_paths and driver.token_paths[0].name == "control.token"


def test_enter_token_passes_the_literal_through_untouched(tmp_path):
    driver = FakeDriver()

    runner._perform(step_for(driver), cells.Action("enter_token", "not.a.token"))

    assert driver.actions == [("enter_token", "not.a.token")]


def test_tap_example_pay_and_relaunch_reach_the_driver(tmp_path):
    driver = FakeDriver()

    runner._perform(step_for(driver), cells.Action("tap_example_pay"))
    runner._perform(step_for(driver), cells.Action("relaunch"))

    # relaunch's default on `Driver` is `launch()`, which is the whole answer
    # on Android; iOS overrides it to keep its console capture.
    assert driver.actions == [("tap_example_pay", None), ("launch", None)]


def test_airplane_translates_on_and_off_into_a_bool(tmp_path):
    driver = FakeDriver()

    runner._perform(step_for(driver), cells.Action("airplane", "on"))
    runner._perform(step_for(driver), cells.Action("airplane", "off"))

    assert driver.actions == [("airplane", True), ("airplane", False)]


def test_wait_spends_exactly_the_seconds_the_cell_asked_for(monkeypatch):
    naps = []
    monkeypatch.setattr(runner.time, "sleep", naps.append)

    runner._perform(step_for(FakeDriver()), cells.Action("wait", "300"))

    assert naps == [300.0]


def test_a_cell_that_waits_reaches_its_result_afterwards(tmp_path, monkeypatch):
    # End to end, because `wait` is the one verb whose whole job is to do
    # nothing: a branch that silently fell through would look identical here
    # until the expiry cell measured a token that was still valid.
    naps = []
    monkeypatch.setattr(runner.time, "sleep", naps.append)
    directory = tmp_path / "d2"
    directory.mkdir()
    (directory / "control.yaml").write_text(
        textwrap.dedent(CELL.format(id="control")).replace(
            "  - wait_result 60\n", "  - wait 300\n  - wait_result 60\n"
        ),
        encoding="utf-8",
    )

    report = run(directory, tmp_path, FakeDriver())

    assert naps == [300.0]
    assert report.results[0].passed


def test_every_verb_in_the_grammar_reaches_a_branch_or_a_declaration(monkeypatch):
    # The two lists cannot drift: a verb `cells.py` accepts with no `_perform`
    # branch would be reported as "the runner has no branch for it yet", and
    # one whose driver method is simply missing would raise AttributeError --
    # which `run_cell` reads as a broken device rather than a cell-file
    # mistake, and two of those abort the whole matrix.
    monkeypatch.setattr(runner.time, "sleep", lambda seconds: None)
    legal = {
        "acs": "approve",
        "airplane": "on",
        "background": "5",
        "dont_keep_activities": "on",
        "enter_token": "abc",
        "expect": "rearmed",
        "wait": "1",
        # Not "1": `_wait_expired` checks a real monotonic deadline, so a
        # whole second of this sweep would be spent busy-waiting for it.
        "wait_expired": "0.001",
        "wait_result": "1",
    }
    card = cells.Card("4111111111111111", "12/28", "123")

    for verb in sorted(cells.BARE_ACTIONS | set(cells.ARG_ACTIONS)):
        driver = FakeDriver()
        step = step_for(driver, card=card, token_path=Path("/dev/null"))
        try:
            runner._perform(step, cells.Action(verb, legal.get(verb)))
        except NotImplementedError as error:
            assert "no branch" not in str(error), verb
        except AttributeError as error:  # pragma: no cover - the failure mode
            pytest.fail(f"{verb}: {error}")
        except Exception:  # noqa: BLE001 - a fake device refusing is fine
            pass


# --- D2: waiting a session out ----------------------------------------------


class ExpiringSandbox(FakeSandbox):
    """A session that answers `open` a few times and then `expired`.

    Every read of an open one re-mints a token, exactly as
    `PaymentSessionResource.php` does.
    """

    def __init__(self, opens=2):
        super().__init__()
        self.opens = opens
        self.reads = 0

    def read(self, session_id):
        self.reads += 1
        if self.reads <= self.opens:
            return {
                "id": session_id,
                "status": "open",
                "session_token": f"{JWT}-{self.reads}",
            }
        return {"id": session_id, "status": "expired"}


def test_wait_expired_returns_once_the_backend_has_flipped_the_session(tmp_path):
    sandbox = ExpiringSandbox()
    token_path = tmp_path / "cell.token"
    token_path.write_text(TOKEN, encoding="utf-8")
    secrets = [TOKEN]
    naps = []
    step = step_for(
        FakeDriver(), sandbox=sandbox, token_path=token_path, secrets=secrets
    )

    runner._wait_expired(step, 3600, sleep=naps.append)

    assert sandbox.reads == 3
    assert naps == [runner.SESSION_POLL_SECONDS] * 2


def test_wait_expired_leaves_the_freshest_token_on_the_cells_file(tmp_path):
    # The session outlives the token minted with it -- expires_at is
    # mint + 1200 s while the JWT dies at mint + 900 s -- so re-presenting the
    # original would measure the JWT expiry all over again rather than the
    # server's verdict.
    sandbox = ExpiringSandbox()
    token_path = tmp_path / "cell.token"
    token_path.write_text(TOKEN, encoding="utf-8")
    os.chmod(token_path, 0o600)
    step = step_for(
        FakeDriver(), sandbox=sandbox, token_path=token_path, secrets=[TOKEN]
    )

    runner._wait_expired(step, 3600, sleep=lambda seconds: None)

    assert token_path.read_text(encoding="utf-8") == f"{JWT}-2"
    # Still only ours. `write_text` truncates in place and leaves the mode
    # alone; an unlink-and-rewrite would silently hand the next credential
    # back at the process umask, and `run_cell`'s own chmod happens once,
    # before the cell starts.
    assert oct(token_path.stat().st_mode)[-3:] == "600"


def test_wait_expired_adds_every_re_minted_token_to_the_cells_secrets(tmp_path):
    # A GET on an open session hands back a credential the runner never
    # minted. Everything filed afterwards is scrubbed of it by literal.
    sandbox = ExpiringSandbox()
    token_path = tmp_path / "cell.token"
    token_path.write_text(TOKEN, encoding="utf-8")
    secrets = [TOKEN]
    step = step_for(
        FakeDriver(), sandbox=sandbox, token_path=token_path, secrets=secrets
    )

    runner._wait_expired(step, 3600, sleep=lambda seconds: None)

    assert f"{JWT}-1" in secrets and f"{JWT}-2" in secrets


def test_wait_expired_gives_up_with_the_status_it_last_saw(tmp_path):
    sandbox = ExpiringSandbox(opens=99)
    token_path = tmp_path / "cell.token"
    token_path.write_text(TOKEN, encoding="utf-8")
    step = step_for(
        FakeDriver(), sandbox=sandbox, token_path=token_path, secrets=[TOKEN]
    )

    with pytest.raises(runner.BudgetExceeded) as error:
        runner._wait_expired(step, 0, sleep=lambda seconds: None)

    assert "'open'" in str(error.value)


# --- D2: budgets -------------------------------------------------------------


def test_a_bare_wait_is_budgeted_from_its_own_argument(tmp_path):
    # Without this a 20-minute cell trips its budget at step three and reports
    # a hang, which is the false finding this whole file is arranged to avoid.
    assert "wait" in runner.TIMED_VERBS
    directory = tmp_path / "d2"
    directory.mkdir()
    (directory / "expired.yaml").write_text(
        textwrap.dedent(CELL.format(id="expired")).replace(
            "  - wait_result 60\n", "  - wait 900\n  - wait_result 60\n"
        ),
        encoding="utf-8",
    )

    assert runner.budget_for(cells.load_cell(directory / "expired.yaml")) > 900


@pytest.mark.parametrize(
    "verb, seconds",
    [
        ("present_token", 180),
        ("enter_token", 60),
        ("tap_example_pay", 30),
        ("relaunch", 90),
    ],
)
def test_the_new_verbs_carry_their_own_budget(verb, seconds):
    # Rather than being left on DEFAULT_VERB_SECONDS, which is a hang backstop
    # for a verb nobody has measured.
    assert runner.VERB_BUDGET_SECONDS[verb] == seconds


# --- review: a cell that dies mid-cut puts the device back ----------------


#: The action list `CELL` carries, so a test can swap in its own.
DEFAULT_ACTIONS = "  - paste_token\n  - type_card\n  - tap_pay\n  - wait_result 60\n"


def cell_dir_with(tmp_path, actions, cell_id="control"):
    """A cell whose action list is exactly `actions`, everything else CELL's."""
    body = textwrap.dedent(CELL.format(id=cell_id))
    assert DEFAULT_ACTIONS in body, "CELL's action block moved; fix DEFAULT_ACTIONS"
    directory = tmp_path / "cells"
    directory.mkdir()
    (directory / f"{cell_id}.yaml").write_text(
        body.replace(DEFAULT_ACTIONS, "".join(f"  - {a}\n" for a in actions)),
        encoding="utf-8",
    )
    return directory


def dying_at_the_label(driver, error=None):
    """Makes `wait_result` raise, which is how a cell dies after a rig toggle.

    `wait_label` really does raise on a timeout (`no_label_error`) rather than
    answering falsy, so this is the shape of the failure the replay exists for
    and not a contrivance.
    """

    def raise_it(timeout):
        raise error or DriverError("the label never appeared")

    driver.wait_label = raise_it
    return driver


def result_json(tmp_path, cell_id="control"):
    return json.loads(
        next((tmp_path / "evidence").glob(f"*/{cell_id}/result.json")).read_text()
    )


def test_a_cell_that_dies_after_cutting_the_network_puts_it_back(tmp_path):
    # Airplane mode outlives the cell, the run and the process. Left on, it
    # fails every cell after this one and then the interleaved control, and the
    # run aborts as a rig fault -- forty minutes to be told that the tail of
    # the matrix never ran. The cell's own `airplane off` is exactly the action
    # that does not happen, because the loop it sits in has already unwound.
    driver = dying_at_the_label(FakeDriver())
    directory = cell_dir_with(
        tmp_path,
        ["paste_token", "airplane on", "tap_pay", "wait_result 60", "airplane off"],
    )

    report = run(directory, tmp_path, driver)

    assert [a for a in driver.actions if a[0] == "airplane"] == [
        ("airplane", True),
        ("airplane", False),
    ]
    problems = report.results[0].problems
    # Recorded, and beside the failure that caused it rather than instead of
    # it: a cell that put the device back is still a cell that failed.
    assert any("the label never appeared" in p for p in problems), problems
    assert any("airplane off" in p for p in problems), problems
    assert not report.results[0].passed
    assert result_json(tmp_path)["teardown_replayed"] == ["airplane off"]


def test_a_teardown_replay_that_fails_says_so_and_keeps_the_first_failure(tmp_path):
    # Best effort, and audibly so. A device that will not come out of airplane
    # mode is the next cell's problem whatever this one does, and the reader
    # needs both halves: what the cell was doing when it died, and that the
    # rig was left dirty.
    class Stubborn(FakeDriver):
        def airplane(self, on):
            self.actions.append(("airplane", on))
            if not on:
                raise DriverError("the radios stayed down")

    driver = dying_at_the_label(Stubborn())
    directory = cell_dir_with(
        tmp_path,
        ["paste_token", "airplane on", "tap_pay", "wait_result 60", "airplane off"],
    )

    report = run(directory, tmp_path, driver)

    problems = report.results[0].problems
    assert any("the label never appeared" in p for p in problems), problems
    assert any("the radios stayed down" in p for p in problems), problems
    # Attempted, so it is not silently absent; it did not take, so it is not
    # claimed as done.
    assert result_json(tmp_path)["teardown_replayed"] == []


def test_a_cell_that_declared_no_teardown_replays_nothing(cell_dir, tmp_path):
    # The replay reads the cell's own action list. A cell that never touched
    # the device's settings has nothing to put back, and inventing an
    # `airplane off` for it would be the runner changing a device no cell
    # asked it to change.
    driver = dying_at_the_label(FakeDriver())

    report = run(cell_dir, tmp_path, driver, only=["control"])

    assert not [a for a in driver.actions if a[0] == "airplane"]
    assert not any("teardown" in p for p in report.results[0].problems)
    assert result_json(tmp_path)["teardown_replayed"] == []


def test_the_replay_covers_every_declared_teardown_pair(tmp_path):
    # Driven by the table, not by a special case for airplane mode:
    # `dont_keep_activities` is the other half of `cells.TEARDOWN` and D3 will
    # be its first user.
    driver = dying_at_the_label(FakeDriver())
    driver.dont_keep_activities = lambda on: driver.actions.append(
        ("dont_keep_activities", on)
    )
    directory = cell_dir_with(
        tmp_path,
        [
            "paste_token",
            "dont_keep_activities on",
            "tap_pay",
            "wait_result 60",
            "dont_keep_activities off",
        ],
    )

    run(directory, tmp_path, driver)

    assert [a for a in driver.actions if a[0] == "dont_keep_activities"] == [
        ("dont_keep_activities", True),
        ("dont_keep_activities", False),
    ]
    assert result_json(tmp_path)["teardown_replayed"] == ["dont_keep_activities off"]
