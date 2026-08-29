"""Loads cells, drives one, judges it, writes the proof. Repeat.

    python -m tool.e2e.runner --platform android \\
        --cells tool/e2e/cells/d0 \\
        --evidence-root ~/projects/payments/.e2e-3ds/campaign/evidence \\
        --env-file ~/projects/payments/payment_testing_go/.env.staging \\
        [--all] [--app PATH] [--only control]

Two rules here are worth their code. A failed cell triggers an interleaved
control before the failure is believed, and two consecutive control failures
abort the run -- a broken rig otherwise produces a page of findings that are
all the same finding. And the session token lives in a 0600 file in a 0700
directory outside the evidence root and is removed in a finally, so a driver
failure does not leave a live credential on disk.

Contains no credentials and no internal hostnames beyond the TEST API the env
file names.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import tempfile
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

from . import evidence, tree, verify
from .cells import Action, Card, Cell, CellError, load_cells
from .drivers.base import DriverError
from .sandbox import Sandbox, SandboxError

CONTROL_CELL_ID = "control"

#: Two in a row means the rig or the backend is broken, not the SDK. Stopping
#: is the honest answer: everything after it would be noise.
MAX_CONSECUTIVE_CONTROL_FAILURES = 2

#: What `expect rearmed` gives the sheet. The driver raises rather than
#: answering False when the device will not dump, so this bounds a live
#: device's slowness and nothing else.
REARM_TIMEOUT_SECONDS = 30

#: The only verbs that run with the native sheet or the ACS page foreground,
#: and therefore the only steps a frame may ever be taken of. `redact()` is
#: byte-level and cannot scrub a PNG, and the example app's own screen holds
#: the session token in a TextField.
SHOT_VERBS = ("tap_pay", "acs", "expect")

#: How much of the token has to appear in a dump for the runner to conclude
#: that the example's own screen is showing. Short enough to survive a viewer
#: that truncates long attribute values, and a false positive here costs a
#: screenshot while a false negative costs a leak that cannot be undone.
_TOKEN_PREFIX_CHARS = 24

#: Wall-clock ceilings per verb, before slack, for a step that is making
#: progress -- not expected durations. `type_card` spends ~17 s on key events
#: alone (0.4 s x 16 digits) and `acs` gives the sandbox page 120 s.
VERB_BUDGET_SECONDS = {
    "paste_token": 120,
    "type_card": 150,
    "tap_pay": 60,
    "acs": 240,
    "cancel_challenge": 180,
    "cancel_form": 90,
    "expect": 90,
    "rotate": 60,
    "airplane": 60,
    "kill_activity": 60,
}
DEFAULT_VERB_SECONDS = 120

#: Verbs whose argument already says how long they may take.
TIMED_VERBS = ("wait_result", "background")

#: On top of such a verb's own deadline, because that deadline bounds when the
#: next look starts, not how long one takes: a dump's transport timeout is
#: spent above it (30 s on iOS, three attempts).
WAIT_SLACK_SECONDS = 60

#: A dump after every step, and sometimes a screenshot.
STEP_EVIDENCE_SECONDS = 30

#: force-stop, monkey and the settle on Android; terminate, the console
#: capture and the WebDriverAgent session on iOS.
LAUNCH_BUDGET_SECONDS = 90


class BudgetExceeded(RuntimeError):
    """A cell spent its wall clock without finishing."""


@dataclass
class CellResult:
    cell_id: str
    passed: bool
    problems: list[str] = field(default_factory=list)
    session_id: str | None = None
    label: str | None = None
    transaction_id: str | None = None
    is_control_check: bool = False
    #: The directory its artifacts went to. Equal to `cell_id` except for an
    #: interleaved control check, which would otherwise overwrite the control
    #: cell's own proof with the probe's.
    artifact_id: str = ""


@dataclass
class Report:
    results: list[CellResult] = field(default_factory=list)
    skipped: list[str] = field(default_factory=list)
    #: Problems belonging to the run rather than to any cell -- a driver that
    #: would not close, an app that would not install. Recorded beside the
    #: verdicts, never in place of them.
    problems: list[str] = field(default_factory=list)
    aborted: bool = False
    abort_reason: str = ""

    @property
    def exit_code(self) -> int:
        """0 only when every cell passed and nothing else went wrong.

        A run-level problem counts. A green exit has to mean the whole run
        worked, or the next reader has no reason to read the output.
        """
        if self.aborted or self.problems:
            return 1
        return 0 if all(r.passed for r in self.results) else 1


def budget_for(cell: Cell) -> float:
    """The wall clock a cell is allowed before the runner gives up on it.

    Deliberately generous -- a false budget failure would be a false finding
    -- but bounded, because a driver's own transport timeouts (300 s for adb,
    900 s for ssh) are spent on top of a poll's deadline rather than inside
    it, and one wedged cell would otherwise take a 40-minute matrix with it.
    """
    total = float(LAUNCH_BUDGET_SECONDS)
    for action in cell.actions:
        if action.verb in TIMED_VERBS:
            total += float(action.arg) + WAIT_SLACK_SECONDS
        else:
            total += VERB_BUDGET_SECONDS.get(action.verb, DEFAULT_VERB_SECONDS)
        total += STEP_EVIDENCE_SECONDS
    return total


def _redacted(text: str, token: str | None = None) -> str:
    """What the runner is allowed to print or file.

    Driver and sandbox messages quote what they saw on a device, and nothing
    below runs them through `redact()` -- these strings reach stdout as well
    as the evidence tree, so they are scrubbed where they are made.
    """
    return evidence.redact(text.encode("utf-8"), (token,)).decode(
        "utf-8", errors="replace"
    )


def _kind(error: BaseException) -> str:
    if isinstance(error, DriverError):
        return "driver"
    if isinstance(error, BudgetExceeded):
        return "budget"
    return type(error).__name__


def _shows_the_example_screen(dump: bytes, platform: str, token: str | None) -> bool:
    """Whether this dump is of the example app rather than of the sheet.

    Three tells, any of which is enough: the token itself, anything else
    JWT-shaped, or a result label -- the example renders one only once the
    sheet has closed. An unreadable dump counts as a yes, because a leaked
    frame cannot be un-leaked and a missing one costs nothing.
    """
    if token and token[:_TOKEN_PREFIX_CHARS].encode("utf-8") in dump:
        return True
    if evidence.JWT_RE.search(dump):
        return True
    try:
        nodes = (
            tree.parse_uiautomator(dump)
            if platform == "android"
            else tree.parse_wda(dump)
        )
    except Exception:  # noqa: BLE001 - a dump we cannot read is not a licence
        return True
    return tree.label_from_tree(nodes) is not None


def _may_screenshot(verb: str, dump: bytes, platform: str, token: str | None) -> bool:
    """Whether a frame of this step can be filed without leaking the token.

    Both conditions are required. The verb has to be one that runs with the
    sheet or the ACS page foreground, and the dump taken a moment earlier has
    to agree -- if the payment resolved during that dump the sheet has gone,
    and the frame would be the example's screen, token field and all. A
    `grep eyJ` over the evidence tree cannot see into a compressed PNG, so
    that leak would be invisible to the check meant to catch it.
    """
    return verb in SHOT_VERBS and not _shows_the_example_screen(dump, platform, token)


def _perform(
    driver, action: Action, *, card: Card, token_path: Path, amount_text: str
):
    """Executes one action and returns whatever it answers with.

    `wait_result` answers with a label and `expect rearmed` with a bool.
    Everything else answers with None.
    """
    verb, arg = action.verb, action.arg
    if verb == "paste_token":
        driver.paste_token(token_path)
    elif verb == "type_card":
        driver.type_card(card)
    elif verb == "tap_pay":
        driver.tap_pay(amount_text)
    elif verb == "acs":
        driver.acs(arg)
    elif verb == "cancel_challenge":
        driver.cancel_challenge()
    elif verb == "cancel_form":
        driver.cancel_form()
    elif verb == "expect" and arg == "rearmed":
        return driver.wait_rearmed(amount_text, timeout=REARM_TIMEOUT_SECONDS)
    elif verb == "wait_result":
        return driver.wait_label(timeout=float(arg))
    elif verb == "background":
        driver.background(float(arg))
    elif verb == "rotate":
        driver.rotate()
    elif verb == "airplane":
        driver.airplane(arg == "on")
    elif verb == "kill_activity":
        driver.kill_activity()
    else:  # pragma: no cover - cells.py rejects these at load time
        raise DriverError(f"the runner cannot perform {verb!r}")
    return None


def _rearm_problem(rearmed: bool | None) -> str:
    if rearmed is None:
        # A cell that asserts `rearmed: true` without an `expect rearmed`
        # action never looked. Saying "the sheet never re-armed" would send
        # whoever is triaging after an SDK bug that is not there.
        return (
            "rearm: the cell expects a re-armed sheet but has no "
            "'expect rearmed' action to look for one"
        )
    return f"rearm: the sheet never re-armed within {REARM_TIMEOUT_SECONDS}s"


def run_cell(
    cell: Cell,
    platform: str,
    driver,
    sandbox,
    run: evidence.Run,
    *,
    artifact_id: str | None = None,
    is_control_check: bool = False,
) -> CellResult:
    """One cell, end to end: mint, drive, judge, file the proof."""
    artifact_id = artifact_id or cell.id
    expected = cell.expected_for(platform)
    amount_text = tree.format_amount_en_us(cell.session.amount, cell.session.currency)
    budget = budget_for(cell)
    started = datetime.now(timezone.utc)

    problems: list[str] = []
    label: str | None = None
    rearmed: bool | None = None
    session: dict[str, str] = {}
    reached_the_end = False

    try:
        session = sandbox.mint(
            cell.session.amount, cell.session.currency, cell.session.options
        )
    except Exception as error:  # noqa: BLE001
        # Not re-raised: a backend that will not mint fails every cell, and
        # the interleaved control plus the abort rule are what turn that into
        # "the rig is broken" rather than a page of SDK findings.
        problems.append(f"sandbox: {error}")

    token = session.get("token")

    def write(name: str, data: bytes) -> None:
        # The literal token as well as the shape rule: a token whose segments
        # are shorter than JWT_RE wants is not matched by shape, and a log can
        # wrap one in a way no regex was written for.
        run.write(artifact_id, name, data, secrets=(token,))

    if session:
        # 0700 directory, 0600 file, outside the evidence root, gone in the
        # finally even when the driver dies mid-cell.
        token_dir = Path(tempfile.mkdtemp(prefix="paycross-e2e-"))
        step, verb = "00-launch", "launch"
        try:
            os.chmod(token_dir, 0o700)
            token_path = token_dir / f"{cell.id}.token"
            token_path.write_text(token, encoding="utf-8")
            os.chmod(token_path, 0o600)

            # From here rather than from the mint: budget_for sums a launch
            # and the actions, and the merchant API bounds its own calls.
            clock = time.monotonic()
            driver.launch()
            for index, action in enumerate(cell.actions, start=1):
                step, verb = f"{index:02d}-{action.verb}", action.verb
                if time.monotonic() - clock >= budget:
                    raise BudgetExceeded(
                        f"the cell used its {budget:.0f}s budget before {step}"
                    )

                answer = _perform(
                    driver,
                    action,
                    card=cell.card,
                    token_path=token_path,
                    amount_text=amount_text,
                )
                if action.verb == "wait_result":
                    label = answer
                elif action.verb == "expect":
                    rearmed = answer

                dump = driver.dump_tree()
                write(f"{step}.uix", dump)
                if _may_screenshot(verb, dump, platform, token):
                    try:
                        write(f"{step}.png", driver.screenshot())
                    except Exception as error:  # noqa: BLE001
                        # A frame is the least of what a cell collects, and
                        # the cell still has a verdict to reach.
                        problems.append(f"screenshot: {error}")
            reached_the_end = True
        except Exception as error:  # noqa: BLE001
            # DriverError is the expected shape, but subprocess.TimeoutExpired
            # (adb at 300 s, ssh at 900 s) and json.JSONDecodeError are both
            # reachable from a hung emulator or a dead WebDriverAgent. One bad
            # cell must not kill a 40-minute matrix: the interleaved control
            # and the abort rule exist to judge exactly that.
            problems.append(f"{_kind(error)}: {error}")
            # The tree at the moment of failure is usually the whole
            # diagnosis, and the write above never ran for this step. Best
            # effort: a device that has gone away must not replace the real
            # error with a second one.
            try:
                dump = driver.dump_tree()
                write(f"{step}-failed.uix", dump)
            except Exception as secondary:  # noqa: BLE001
                problems.append(f"driver: no dump after the failure ({secondary})")
            else:
                if _may_screenshot(verb, dump, platform, token):
                    try:
                        write(f"{step}-failed.png", driver.screenshot())
                    except Exception as secondary:  # noqa: BLE001
                        problems.append(
                            f"screenshot: none after the failure ({secondary})"
                        )
        finally:
            shutil.rmtree(token_dir, ignore_errors=True)

    matched, transaction_id = verify.match_label(expected.label, label)
    if reached_the_end:
        # Only judged when the cell got that far. A run cut short never asked
        # for a label, and "expected result:success, got None" would be a
        # second finding invented out of the first one.
        if not matched:
            problems.append(f"label: expected {expected.label!r}, got {label!r}")
        if expected.rearmed and rearmed is not True:
            problems.append(_rearm_problem(rearmed))

    if session:
        try:
            resource = sandbox.read(session["id"])
        except Exception as error:  # noqa: BLE001
            problems.append(
                f"merchant: could not read session {session['id']}: {error}"
            )
        else:
            write("merchant.json", json.dumps(resource, indent=2).encode())
            problems += verify.verify_merchant(resource, expected.merchant)
            problems += verify.verify_label_transaction(resource, transaction_id)

        try:
            # Before the next cell's launch(), which is where the iOS console
            # capture is truncated -- collected any later there is nothing to
            # collect, and criterion 3 would pass on an empty log.
            log = driver.logs_since(started)
        except Exception as error:  # noqa: BLE001
            # Beside the verdict, never in place of it.
            problems.append(f"logs: {error}")
        else:
            write("logs.txt", log.encode())
            problems += [
                f"crash: {line.strip()}"
                for line in verify.crash_lines(log, driver.package)
            ]

    problems = [_redacted(problem, token) for problem in problems]
    result = CellResult(
        cell_id=cell.id,
        passed=not problems,
        problems=problems,
        session_id=session.get("id"),
        label=label,
        transaction_id=transaction_id,
        is_control_check=is_control_check,
        artifact_id=artifact_id,
    )
    write(
        "result.json",
        json.dumps(
            {
                "cell": cell.id,
                "platform": platform,
                "passed": result.passed,
                "control_check": is_control_check,
                "session_id": result.session_id,
                "label": result.label,
                "transaction_id": result.transaction_id,
                "rearmed": rearmed,
                "expected_label": expected.label,
                "problems": problems,
                "budget_seconds": budget,
                "seconds": (datetime.now(timezone.utc) - started).total_seconds(),
            },
            indent=2,
        ).encode(),
    )
    # Last, and with the token. This line is the ledger a resume reads, so it
    # is appended only once the evidence it points at is on disk -- and its
    # `label` is read off the device, which makes it the one field here that
    # has not already been through _redacted.
    run.append_progress(
        {
            "cell": cell.id,
            "status": "pass" if result.passed else "fail",
            "session_id": result.session_id,
            "label": result.label,
            "problems": problems,
            "control_check": is_control_check,
            "evidence": artifact_id,
        },
        secrets=(token,),
    )
    return result


def run_cells(
    platform: str,
    cell_dir: Path,
    evidence_root: Path,
    driver,
    sandbox,
    run_all: bool = False,
    only: list[str] | None = None,
    app_path: str | None = None,
) -> Report:
    everything = load_cells(Path(cell_dir), platform)
    if not everything:
        # Running nothing and exiting 0 reads as "everything passed".
        raise CellError(f"{cell_dir}: no cell in it runs on {platform}")
    chosen = everything
    if only:
        unknown = sorted(set(only) - {c.id for c in everything})
        if unknown:
            # Silently running nothing would exit 0, which reads as a pass.
            raise CellError(
                f"{cell_dir}: --only names no cell that runs on {platform}: "
                f"{', '.join(unknown)}"
            )
        chosen = [c for c in everything if c.id in only]

    report = Report()
    passed = set() if run_all else evidence.passed_cells(Path(evidence_root), platform)
    todo = [c for c in chosen if c.id not in passed]
    report.skipped = [c.id for c in chosen if c.id in passed]
    if not todo:
        return report

    run = evidence.Run(Path(evidence_root), platform=platform)
    # From every cell rather than from the chosen ones: --only says what to
    # run, not whether to believe the result.
    control = next((c for c in everything if c.id == CONTROL_CELL_ID), None)
    consecutive_control_failures = 0
    checks = 0

    def stop(reason: str) -> None:
        report.aborted = True
        report.abort_reason = reason
        run.append_progress({"cell": "-", "status": "abort", "problems": [reason]})

    try:
        if app_path:
            try:
                driver.install(app_path)
            except Exception as error:  # noqa: BLE001
                stop(f"could not install {app_path}: {_redacted(str(error))}")
                return report

        for cell in todo:
            # run_cell appends its own progress line: it is the only scope
            # holding the session token the record has to be scrubbed against.
            result = run_cell(cell, platform, driver, sandbox, run)
            report.results.append(result)

            if cell.id == CONTROL_CELL_ID:
                consecutive_control_failures = (
                    0 if result.passed else consecutive_control_failures + 1
                )
            elif not result.passed and control is not None:
                # Skepticism: prove the rig before believing the finding.
                checks += 1
                check = run_cell(
                    control,
                    platform,
                    driver,
                    sandbox,
                    run,
                    artifact_id=f"{CONTROL_CELL_ID}-check-{checks:02d}",
                    is_control_check=True,
                )
                report.results.append(check)
                consecutive_control_failures = (
                    0 if check.passed else consecutive_control_failures + 1
                )

            if consecutive_control_failures >= MAX_CONSECUTIVE_CONTROL_FAILURES:
                stop(
                    f"{consecutive_control_failures} consecutive control failures: "
                    "treating this as a rig or backend problem rather than an "
                    "SDK finding"
                )
                break
    finally:
        try:
            # iOS holds a console capture on the Mac that outlives the app;
            # Android holds nothing. Either way the last one of a run is this
            # runner's to release.
            driver.close()
        except Exception as error:  # noqa: BLE001
            # Whatever it raises: the cells have already reached their
            # verdicts and a wedged host must not throw them away.
            problem = f"close: {_redacted(str(error))}"
            report.problems.append(problem)
            run.append_progress(
                {"cell": "-", "status": "run-problem", "problems": [problem]}
            )

    return report


def _build_driver(platform: str):
    if platform == "android":
        from .drivers.android import AndroidDriver

        return AndroidDriver()
    from .drivers.ios import IosDriver

    return IosDriver()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="tool.e2e.runner")
    parser.add_argument("--platform", required=True, choices=("android", "ios"))
    parser.add_argument("--cells", required=True, type=Path)
    parser.add_argument(
        "--evidence-root",
        required=True,
        type=Path,
        help="outside any git checkout; survives a WSL reboot",
    )
    parser.add_argument("--env-file", required=True, type=Path)
    parser.add_argument(
        "--all", action="store_true", help="rerun cells that already passed"
    )
    parser.add_argument(
        "--app", help="APK (Android) or .app on the Mac (iOS) to install first"
    )
    parser.add_argument(
        "--only", action="append", help="run just this cell; repeatable"
    )
    args = parser.parse_args(argv)

    try:
        # Loaded here as well as inside run_cells, and before the credentials
        # are read or a device is touched: a typo in a cell file deserves one
        # line rather than a traceback halfway through a matrix.
        load_cells(args.cells, args.platform)
        sandbox = Sandbox.from_env_file(args.env_file)
        report = run_cells(
            platform=args.platform,
            cell_dir=args.cells,
            evidence_root=args.evidence_root,
            driver=_build_driver(args.platform),
            sandbox=sandbox,
            run_all=args.all,
            only=args.only,
            app_path=args.app,
        )
    except (CellError, SandboxError, OSError) as error:
        # An unusable selection or an evidence root that cannot be written is
        # a mistake to explain, not a stack to read. Whatever a run did manage
        # is already on disk: progress is appended and fsynced per cell.
        print(f"error: {error}", file=sys.stderr)
        return 2

    for cell_id in report.skipped:
        print(f"SKIP {cell_id} (passed in an earlier run; --all to rerun)")
    for result in report.results:
        verdict = "PASS" if result.passed else "FAIL"
        tag = f"CTRL-{verdict}" if result.is_control_check else verdict
        where = (
            f" evidence={result.artifact_id}"
            if result.artifact_id != result.cell_id
            else ""
        )
        print(
            f"{tag} {result.cell_id} session={result.session_id} "
            f"label={result.label!r}{where}"
        )
        for problem in result.problems:
            print(f"     - {problem}")
    for problem in report.problems:
        print(f"RUN-PROBLEM {problem}")
    if report.aborted:
        print(f"ABORT {report.abort_reason}")
    return report.exit_code


if __name__ == "__main__":
    sys.exit(main())
