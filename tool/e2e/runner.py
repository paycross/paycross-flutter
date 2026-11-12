"""Loads cells, drives each one, judges it and writes its proof."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import tempfile
import time
from collections.abc import Sequence
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from . import evidence, tree, verify
from .cells import (
    ARG_ACTIONS,
    BARE_ACTIONS,
    LABEL_SENTINELS,
    TEARDOWN,
    Action,
    Card,
    Cell,
    CellError,
    load_cells,
)
from .drivers.android import DIGIT_PACING_SECONDS
from .drivers.base import DriverError
from .sandbox import Sandbox, SandboxError

CONTROL_CELL_ID = "control"

MAX_CONSECUTIVE_CONTROL_FAILURES = 2

REARM_TIMEOUT_SECONDS = 30

SESSION_POLL_SECONDS = 30

NO_RESULT_TIMEOUT_SECONDS = 60

ACS_PAGE_TIMEOUT_SECONDS = 120

WALLET_TIMEOUT_SECONDS = 30

WALLET_ABSENT_TIMEOUT_SECONDS = 20

SAVED_CARD_TIMEOUT_SECONDS = 30

FRENCH_SHEET_TIMEOUT_SECONDS = 30

# WHY: the drivers keep their own literal defaults, because runner imports
# drivers and not the reverse.
EXPECT_TIMEOUT_SECONDS = {
    "rearmed": REARM_TIMEOUT_SECONDS,
    "no_result": NO_RESULT_TIMEOUT_SECONDS,
    "acs": ACS_PAGE_TIMEOUT_SECONDS,
    "google_pay": WALLET_TIMEOUT_SECONDS,
    "no_google_pay": WALLET_ABSENT_TIMEOUT_SECONDS,
    "saved_card": SAVED_CARD_TIMEOUT_SECONDS,
    "french_sheet": FRENCH_SHEET_TIMEOUT_SECONDS,
}

# WHY: redact() is byte-level and cannot scrub a PNG, so only verbs with the
# sheet or ACS page in front may take a frame.
SHOT_VERBS = ("type_card", "tap_pay", "acs", "expect")


def _grammar_accepts(verb: str, arg: str | None) -> bool:
    """Whether `load_cell` would have accepted this action.

    The same two rules `cells.parse_action` applies, asked of an `Action` that
    already exists. It is what separates the two ways `_perform` can fail to
    execute one: a legal action whose dimension has not landed, and a
    malformed one that no cell file could have carried in the first place.
    """
    if verb in BARE_ACTIONS:
        return not arg
    accepts = ARG_ACTIONS.get(verb)
    return accepts is not None and bool(arg) and accepts[0](arg)


EXIT_OK = 0
EXIT_FAILED = 1
EXIT_SETUP = 2
EXIT_ABORTED = 3

# WHY: the monotonic clock does not advance across a host suspend, so
# timeouts never fire during one.
SUSPEND_SECONDS = 60


def host_suspended_seconds(*, wall: float, monotonic: float) -> float:
    """How long the host was asleep during a cell, or 0.0."""
    slept = wall - monotonic
    return slept if slept >= SUSPEND_SECONDS else 0.0


_TOKEN_PREFIX_CHARS = 24

PAN_DIGITS = 16

CARD_FIELDS_SECONDS = 150

VERB_BUDGET_SECONDS = {
    "paste_token": 180,
    "present_token": 180,
    "enter_token": 60,
    "tap_example_pay": 30,
    "type_card": PAN_DIGITS * DIGIT_PACING_SECONDS + CARD_FIELDS_SECONDS,
    "type_cvv": 60,
    "tap_pay": 60,
    "tap_google_pay": 60,
    "select_saved_card": 60,
    "remove_saved_card": 180,
    "dismiss_cancel": 150,
    "save_card": 60,
    "acs": 240,
    "cancel_challenge": 180,
    "cancel_form": 90,
    "expect": 90,
    "relaunch": 90,
    "rotate": 60,
    "airplane": 60,
    "dont_keep_activities": 60,
    "device_language": 60,
    "kill_activity": 60,
}
DEFAULT_VERB_SECONDS = 120

# WHY: a session's own expiry wait is longer than the default budget, so
# these verbs use their argument.
TIMED_VERBS = ("wait", "wait_result", "wait_expired", "background")

WAIT_SLACK_SECONDS = 60

STEP_EVIDENCE_SECONDS = 30

LAUNCH_BUDGET_SECONDS = 90


class BudgetExceeded(RuntimeError):
    """A cell spent its wall clock without finishing."""


@dataclass
class CellResult:
    cell_id: str
    passed: bool
    problems: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    session_id: str | None = None
    label: str | None = None
    transaction_id: str | None = None
    is_control_check: bool = False
    authoring: bool = False
    run_problems: list[str] = field(default_factory=list)
    artifact_id: str = ""


@dataclass
class Report:
    results: list[CellResult] = field(default_factory=list)
    skipped: list[str] = field(default_factory=list)
    problems: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    aborted: bool = False
    abort_reason: str = ""

    @property
    def exit_code(self) -> int:
        """The process exit code for this run: an abort, a failure or a pass."""
        if self.aborted:
            return EXIT_ABORTED
        if self.problems or not all(r.passed for r in self.results):
            return EXIT_FAILED
        return EXIT_OK


def budget_for(cell: Cell) -> float:
    """The wall clock a cell is allowed before the runner gives up on it."""
    total = float(LAUNCH_BUDGET_SECONDS)
    for action in cell.actions:
        if action.verb in TIMED_VERBS:
            total += float(action.arg) + WAIT_SLACK_SECONDS
        else:
            total += VERB_BUDGET_SECONDS.get(action.verb, DEFAULT_VERB_SECONDS)
        total += STEP_EVIDENCE_SECONDS
    return total


def _redacted(text: str, *secrets: str | None) -> str:
    """What the runner is allowed to print or file.

    Driver and sandbox messages quote what they saw on a device, and nothing
    below runs them through `redact()` -- these strings reach stdout as well
    as the evidence tree, so they are scrubbed where they are made.

    Several secrets rather than one: a cell holds the token it minted, and
    after the merchant read it also holds the one the API re-minted and handed
    back.
    """
    return evidence.redact(text.encode("utf-8"), secrets).decode(
        "utf-8", errors="replace"
    )


def _kind(error: BaseException) -> str:
    if isinstance(error, DriverError):
        return "driver"
    if isinstance(error, BudgetExceeded):
        return "budget"
    if isinstance(error, NotImplementedError):
        return "authoring"
    return type(error).__name__


def _shows_the_example_screen(
    dump: bytes, platform: str, secrets: Sequence[str | None]
) -> bool:
    """Whether this dump is of the example app rather than of the sheet."""
    for secret in secrets:
        if secret and secret[:_TOKEN_PREFIX_CHARS].encode("utf-8") in dump:
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


def _may_screenshot(
    verb: str, dump: bytes, platform: str, secrets: Sequence[str | None]
) -> bool:
    """Whether a frame of this step can be filed without leaking the token."""
    return verb in SHOT_VERBS and not _shows_the_example_screen(dump, platform, secrets)


@dataclass
class Step:
    """Everything one action may need, so `_perform` takes two arguments."""

    driver: Any
    sandbox: Any
    card: Card
    token_path: Path
    amount_text: str
    session_id: str | None
    secrets: list[str | None]


def _wait_expired(step: Step, seconds: float, *, sleep=None) -> None:
    """Waits for the backend to mark the session `expired`, refreshing the token."""
    sleep = sleep or time.sleep
    deadline = time.monotonic() + seconds
    while True:
        resource = step.sandbox.read(step.session_id)
        _, minted = evidence.scrub_resource(resource)
        step.secrets.extend(minted)
        status = resource.get("status")
        if status == "expired":
            return
        token = resource.get("session_token")
        if isinstance(token, str) and token:
            step.token_path.write_text(token, encoding="utf-8")
        if time.monotonic() >= deadline:
            raise BudgetExceeded(
                f"the session was still {status!r} after {seconds:.0f}s, expected "
                "'expired'"
            )
        sleep(SESSION_POLL_SECONDS)


def _observe(step: Step, what: str) -> tuple[bool, str | None]:
    """Runs one `expect` predicate and answers (observed, what was seen).

    A falsy answer is a cell failure. `no_result` is the inverted case: it
    returns the label that must not exist, so it is converted here.
    """
    driver = step.driver
    timeout = EXPECT_TIMEOUT_SECONDS.get(what)
    if timeout is None:
        # WHY: a KeyError here would be read as a device problem, not an
        # authoring fault.
        raise DriverError(f"the runner cannot observe {what!r}: no deadline")
    if what == "rearmed":
        return driver.wait_rearmed(step.amount_text, timeout=timeout), None
    if what == "no_result":
        label = driver.wait_no_label(timeout=timeout)
        return label is None, label
    if what == "acs":
        return driver.wait_acs(timeout=timeout), None
    if what == "google_pay":
        return driver.wait_google_pay(timeout=timeout), None
    if what == "no_google_pay":
        return driver.wait_no_google_pay(timeout=timeout), None
    if what == "saved_card":
        return driver.wait_saved_card(timeout=timeout), None
    if what == "french_sheet":
        return driver.wait_french_sheet(timeout=timeout), None
    # WHY: falling off the end would return None, which the caller unpacks as a tuple.
    raise DriverError(f"the runner cannot observe {what!r}: no predicate")


def _teardown_left_undone(actions: Sequence[Action], reached: int) -> list[Action]:
    """The rig settings this cell turned on and did not live to turn off."""
    ran = [(a.verb, a.arg) for a in actions[:reached]]
    un_run = {(a.verb, a.arg) for a in actions[reached:]}
    return [
        Action(verb, restore)
        for verb, restore in sorted(TEARDOWN)
        if any(v == verb and a != restore for v, a in ran) and (verb, restore) in un_run
    ]


def _replay_teardown(
    step: Step, actions: Sequence[Action], reached: int
) -> tuple[list[str], list[str]]:
    """Puts back what a cell turned on and did not live to turn off, best effort."""
    replayed: list[str] = []
    problems: list[str] = []
    for undone in _teardown_left_undone(actions, reached):
        spelled = f"{undone.verb} {undone.arg}"
        try:
            _perform(step, undone)
        except Exception as error:  # noqa: BLE001
            problems.append(
                f"teardown: could not replay {spelled!r} ({error}); "
                "the device is left for the next cell to refuse"
            )
        else:
            replayed.append(spelled)
            problems.append(
                f"teardown: the cell died before {spelled!r}, so the runner replayed it"
            )
    return replayed, problems


def _on_or_off(verb: str, arg: str | None) -> bool:
    """Reads an `on` or `off` argument, and refuses anything else."""
    if arg == "on":
        return True
    if arg == "off":
        return False
    raise DriverError(f"{verb} takes 'on' or 'off', not {arg!r}")


def _perform(step: Step, action: Action):
    """Executes one action and returns its answer, or None for verbs with none."""
    driver, verb, arg = step.driver, action.verb, action.arg
    if verb == "paste_token":
        driver.paste_token(step.token_path)
    elif verb == "present_token":
        driver.present_token(step.token_path)
    elif verb == "tap_example_pay":
        driver.tap_example_pay()
    elif verb == "enter_token":
        driver.enter_token(arg)
    elif verb == "type_card":
        driver.type_card(step.card)
    elif verb == "type_cvv":
        driver.type_cvv(step.card.cvv)
    elif verb == "tap_pay":
        driver.tap_pay(step.amount_text)
    elif verb == "tap_google_pay":
        driver.tap_google_pay()
    elif verb == "select_saved_card":
        driver.select_saved_card()
    elif verb == "remove_saved_card":
        driver.remove_saved_card()
    elif verb == "save_card":
        driver.save_card()
    elif verb == "acs":
        driver.acs(arg)
    elif verb == "cancel_challenge":
        driver.cancel_challenge()
    elif verb == "cancel_form":
        driver.cancel_form()
    elif verb == "dismiss_cancel":
        driver.dismiss_cancel()
    elif verb == "expect":
        return _observe(step, arg)
    elif verb == "wait_result":
        return driver.wait_label(timeout=float(arg))
    elif verb == "wait":
        time.sleep(float(arg))
    elif verb == "wait_expired":
        _wait_expired(step, float(arg))
    elif verb == "relaunch":
        driver.relaunch()
    elif verb == "background":
        driver.background(float(arg))
    elif verb == "rotate":
        driver.rotate()
    elif verb == "airplane":
        driver.airplane(_on_or_off(verb, arg))
    elif verb == "dont_keep_activities":
        driver.dont_keep_activities(_on_or_off(verb, arg))
    elif verb == "device_language":
        driver.device_language(arg)
    elif verb == "kill_activity":
        driver.kill_activity()
    elif _grammar_accepts(verb, arg):
        # WHY: without this guard an unlanded verb would raise DriverError and be
        # read as a device problem.
        raise NotImplementedError(
            f"{verb} is in the action grammar but the runner has no branch "
            f"for it yet (arg {arg!r})"
        )
    else:
        raise DriverError(f"the runner cannot perform {verb} with {arg!r}")
    return None


def run_cell(
    cell: Cell,
    platform: str,
    driver,
    sandbox,
    run: evidence.Run,
    *,
    artifact_id: str | None = None,
    is_control_check: bool = False,
    build_id: str | None = None,
) -> CellResult:
    """One cell, end to end: mint, drive, judge, file the proof."""
    artifact_id = artifact_id or cell.id
    expected = cell.expected_for(platform)
    amount_text = tree.format_amount_en_us(cell.session.amount, cell.session.currency)
    budget = budget_for(cell)
    started = datetime.now(timezone.utc)
    started_monotonic = time.monotonic()

    problems: list[str] = []
    warnings: list[str] = []
    run_problems: list[str] = []
    label: str | None = None
    rearmed: bool | None = None
    session: dict[str, str] = {}
    screenshots_skipped: list[str] = []
    teardown_replayed: list[str] = []
    tolerated_crash_lines: list[str] = []
    label_transaction_notes: list[str] = []
    reached_the_end = False
    authoring = False

    try:
        session = sandbox.mint(
            cell.session.amount, cell.session.currency, cell.session.options
        )
    except Exception as error:  # noqa: BLE001
        problems.append(f"sandbox: {error}")

    token = session.get("token")
    secrets: list[str | None] = [token]

    def write(name: str, data: bytes) -> None:
        run.write(artifact_id, name, data, secrets=tuple(secrets))

    if session:
        token_dir = Path(tempfile.mkdtemp(prefix="paycross-e2e-"))
        stem, verb = "00-launch", "launch"
        index = 0
        step = None
        try:
            os.chmod(token_dir, 0o700)
            evidence.check_cell_id(cell.id)
            token_path = token_dir / f"{cell.id}.token"
            token_path.write_text(token, encoding="utf-8")
            os.chmod(token_path, 0o600)

            clock = time.monotonic()
            driver.launch()
            step = Step(
                driver=driver,
                sandbox=sandbox,
                card=cell.card,
                token_path=token_path,
                amount_text=amount_text,
                session_id=session.get("id"),
                secrets=secrets,
            )
            for index, action in enumerate(cell.actions, start=1):
                stem, verb = f"{index:02d}-{action.verb}", action.verb
                if time.monotonic() - clock >= budget:
                    raise BudgetExceeded(
                        f"the cell used its {budget:.1f}s budget before {stem}"
                    )

                answer = _perform(step, action)
                if action.verb == "wait_result":
                    label = _redacted(answer, *secrets)
                elif action.verb == "expect":
                    observed, detail = answer
                    if action.arg == "rearmed":
                        rearmed = observed
                    if not observed:
                        seen = (
                            f", saw {_redacted(str(detail), *secrets)!r}"
                            if detail
                            else ""
                        )
                        problems.append(
                            f"expect: never observed {action.arg!r} within "
                            f"{EXPECT_TIMEOUT_SECONDS[action.arg]:.0f}s{seen}"
                        )

                # WHY: every polling wait reads the tree, so a dump that fails ends
                # the cell.
                dump = driver.dump_tree()
                write(f"{stem}.uix", dump)
                if _may_screenshot(verb, dump, platform, secrets):
                    try:
                        write(f"{stem}.png", driver.screenshot())
                    except Exception as error:  # noqa: BLE001
                        problems.append(f"screenshot: {error}")
                elif verb in SHOT_VERBS:
                    screenshots_skipped.append(stem)
            reached_the_end = True
        except Exception as error:  # noqa: BLE001
            # WHY: a hung emulator raises TimeoutExpired and a dead WebDriverAgent
            # raises JSONDecodeError, not only DriverError.
            authoring = isinstance(error, NotImplementedError)
            problems.append(f"{_kind(error)}: {error}")
            try:
                dump = driver.dump_tree()
                write(f"{stem}-failed.uix", dump)
            except Exception as secondary:  # noqa: BLE001
                problems.append(f"driver: no dump after the failure ({secondary})")
            else:
                if _may_screenshot(verb, dump, platform, secrets):
                    try:
                        write(f"{stem}-failed.png", driver.screenshot())
                    except Exception as secondary:  # noqa: BLE001
                        problems.append(
                            f"screenshot: none after the failure ({secondary})"
                        )
                elif verb in SHOT_VERBS:
                    screenshots_skipped.append(f"{stem}-failed")
            # WHY: airplane mode outlives the process, so the teardown replay runs
            # even after the budget is spent.
            if step is not None:
                replayed, said = _replay_teardown(step, cell.actions, index)
                teardown_replayed.extend(replayed)
                problems.extend(said)
        finally:
            try:
                shutil.rmtree(token_dir)
            except OSError as error:
                # WHY: a live credential left on disk must be reported, so this error
                # is not swallowed.
                run_problems.append(
                    _redacted(
                        f"token: {cell.id}'s token file was left behind at "
                        f"{token_dir}: {error}"
                    )
                )

    matched, transaction_id = verify.match_label(expected.label, label)
    if reached_the_end:
        if not matched:
            problems.append(f"label: expected {expected.label!r}, got {label!r}")

    if session:
        try:
            resource = sandbox.read(session["id"])
        except Exception as error:  # noqa: BLE001
            problems.append(
                f"merchant: could not read session {session['id']}: {error}"
            )
        else:
            # WHY: a GET on an open session mints a session_token the runner did not
            # name, so it is dropped here.
            resource, minted_by_the_read = evidence.scrub_resource(resource)
            secrets.extend(minted_by_the_read)
            write("merchant.json", json.dumps(resource, indent=2).encode())
            if reached_the_end:
                problems += verify.verify_merchant(resource, expected.merchant)
                # WHY: a `<any>` label records the transaction id rather than
                # asserting it, so this check runs for it too.
                said = verify.verify_label_transaction(resource, transaction_id)
                if expected.label in LABEL_SENTINELS:
                    label_transaction_notes += said
                else:
                    problems += said

        try:
            # WHY: the log is read before the next launch(), which truncates the iOS
            # console capture.
            log = driver.logs_since(started)
        except Exception as error:  # noqa: BLE001
            problems.append(f"logs: {error}")
        else:
            write("logs.txt", log.encode())
            # WHY: a crash is often the cause of the first failure, so it is checked
            # even when the cell did not reach its end.
            faults, tolerated_crash_lines, driver_crashes = verify.crash_lines(
                log, driver.package, cell.tolerated_crash_markers
            )
            problems += [f"crash: {line.strip()}" for line in faults]
            # WHY: uiautomator's FATAL on a closed binder has no `Process:` line, so
            # it is a warning, not an app crash.
            warnings += [
                f"driver_crash: {line.strip()} -- {verify.DRIVER_CRASH_REASON}"
                for line in driver_crashes
            ]
            # WHY: a setting can read back as applied yet be ignored until reboot
            # (always_finish_activities on API 35), so the marker's absence is a
            # finding.
            if cell.tolerated_crash_markers and not tolerated_crash_lines:
                problems.append(
                    "tolerated_crash_markers: the cell declared "
                    f"{list(cell.tolerated_crash_markers)} and none of it ever "
                    "appeared in the log, so the behaviour the cell was written "
                    "to observe did not happen and whatever it measured was "
                    "something else"
                )

    # WHY: a session minted before a host suspend expires during it, so the
    # cell's failure is a misdiagnosis, not evidence.
    elapsed = (datetime.now(timezone.utc) - started).total_seconds()
    suspended = host_suspended_seconds(
        wall=elapsed, monotonic=time.monotonic() - started_monotonic
    )
    if suspended:
        problems.append(
            f"host: the machine was suspended for about {suspended / 3600:.1f}h "
            "during this cell, so its session expired mid-flight and nothing it "
            "measured is evidence of anything. Rerun it; do not triage the "
            "failure above"
        )

    problems = [_redacted(problem, *secrets) for problem in problems]
    warnings = [_redacted(warning, *secrets) for warning in warnings]
    result = CellResult(
        cell_id=cell.id,
        passed=not problems,
        problems=problems,
        warnings=warnings,
        session_id=session.get("id"),
        label=label,
        transaction_id=transaction_id,
        is_control_check=is_control_check,
        authoring=authoring,
        run_problems=run_problems,
        artifact_id=artifact_id,
    )
    write(
        "result.json",
        json.dumps(
            {
                "cell": cell.id,
                "platform": platform,
                "build": build_id,
                "passed": result.passed,
                "control_check": is_control_check,
                "session_id": result.session_id,
                "label": result.label,
                "transaction_id": result.transaction_id,
                "rearmed": rearmed,
                "expected_label": expected.label,
                "problems": problems,
                "warnings": warnings,
                "screenshots_skipped": screenshots_skipped,
                "teardown_replayed": teardown_replayed,
                "label_transaction_notes": label_transaction_notes,
                "tolerated_crash_markers": list(cell.tolerated_crash_markers),
                "tolerated_crash_lines": [
                    _redacted(line.strip(), *secrets) for line in tolerated_crash_lines
                ],
                "budget_seconds": budget,
                "host_suspended_seconds": suspended,
                "seconds": elapsed,
            },
            indent=2,
        ).encode(),
    )
    # WHY: the progress line is appended last, so a resume never reads a cell
    # whose evidence is not on disk.
    run.append_progress(
        {
            "cell": cell.id,
            "status": "pass" if result.passed else "fail",
            "build": build_id,
            "session_id": result.session_id,
            "label": result.label,
            "problems": problems,
            "warnings": warnings,
            "control_check": is_control_check,
            "evidence": artifact_id,
        },
        secrets=tuple(secrets),
    )
    return result


def check_cells(cell_dir: Path, platform: str) -> list[Cell]:
    """Loads a cell directory and refuses anything wrong before a device is touched."""
    everything = load_cells(Path(cell_dir), platform)
    if not everything:
        raise CellError(f"{cell_dir}: no cell in it runs on {platform}")
    for cell in everything:
        try:
            evidence.check_cell_id(cell.id)
        except ValueError as error:
            raise CellError(f"{cell.path}: {error}") from error
    if not any(c.id == CONTROL_CELL_ID for c in everything):
        # WHY: the control cell is what tells an SDK finding from a broken rig, so
        # a run without one does not start.
        raise CellError(
            f"{cell_dir}: no {CONTROL_CELL_ID!r} cell runs on {platform}, so "
            "no failure here could be checked against a known-good payment"
        )
    return everything


def run_cells(
    platform: str,
    cell_dir: Path,
    evidence_root: Path,
    driver,
    sandbox,
    run_all: bool = False,
    only: list[str] | None = None,
    app_path: str | None = None,
    build_id: str | None = None,
) -> Report:
    started = datetime.now(timezone.utc)
    everything = check_cells(cell_dir, platform)
    chosen = everything
    if only:
        unknown = sorted(set(only) - {c.id for c in everything})
        if unknown:
            raise CellError(
                f"{cell_dir}: --only names no cell that runs on {platform}: "
                f"{', '.join(unknown)}"
            )
        chosen = [c for c in everything if c.id in only]

    report = Report()
    passed = (
        set()
        if run_all
        else evidence.passed_cells(Path(evidence_root), platform, build_id)
    )
    todo = [c for c in chosen if c.id not in passed]
    report.skipped = [c.id for c in chosen if c.id in passed]

    run = evidence.Run(Path(evidence_root), platform=platform)

    def write_run_report() -> None:
        report.warnings = list(sandbox.warnings)
        run.write_report(
            {
                "run_id": run.run_id,
                "platform": platform,
                "build": build_id,
                "cells_dir": str(cell_dir),
                "started": started.isoformat(),
                "finished": datetime.now(timezone.utc).isoformat(),
                "exit_code": report.exit_code,
                "summary": _summary(report),
                "aborted": report.aborted,
                "abort_reason": report.abort_reason,
                "problems": report.problems,
                "warnings": report.warnings,
                "skipped": report.skipped,
                "cells": [
                    {
                        "cell": r.cell_id,
                        "passed": r.passed,
                        "control_check": r.is_control_check,
                        "session_id": r.session_id,
                        "label": r.label,
                        "transaction_id": r.transaction_id,
                        "problems": r.problems,
                        "warnings": r.warnings,
                        "evidence": r.artifact_id,
                    }
                    for r in report.results
                ],
            }
        )

    if not todo:
        write_run_report()
        return report

    # WHY: the control cell comes from every cell, so --only cannot drop the
    # check that vouches for the run.
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
            # WHY: adb and ssh raise errors that are not DriverError, and a failed
            # install makes every later result stale.
            except Exception as error:  # noqa: BLE001
                stop(f"could not install {app_path}: {_redacted(str(error))}")
                return report

        for cell in todo:
            # WHY: only run_cell holds the session token the progress record is
            # scrubbed against.
            result = run_cell(cell, platform, driver, sandbox, run, build_id=build_id)
            report.results.append(result)
            report.problems += result.run_problems

            if cell.id == CONTROL_CELL_ID:
                consecutive_control_failures = (
                    0 if result.passed else consecutive_control_failures + 1
                )
            elif not result.passed and not result.authoring:
                # WHY: a control re-checks the rig after a finding, but not after an
                # authoring fault, which says nothing about the rig.
                checks += 1
                check = run_cell(
                    control,
                    platform,
                    driver,
                    sandbox,
                    run,
                    artifact_id=f"{CONTROL_CELL_ID}-check-{checks:02d}",
                    is_control_check=True,
                    build_id=build_id,
                )
                report.results.append(check)
                report.problems += check.run_problems
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
            driver.close()
        except Exception as error:  # noqa: BLE001
            # WHY: the cells have already reached their verdicts, so a failing close
            # is recorded, not raised.
            problem = f"close: {_redacted(str(error))}"
            report.problems.append(problem)
            run.append_progress(
                {"cell": "-", "status": "run-problem", "problems": [problem]}
            )
        write_run_report()

    return report


def _plural(count: int, thing: str) -> str:
    return f"{count} {thing}" if count == 1 else f"{count} {thing}s"


def _summary(report: Report) -> str:
    """One line a person can read off the bottom of a 40-minute run."""
    cells = [r for r in report.results if not r.is_control_check]
    passed = sum(1 for r in cells if r.passed)
    checks = sum(1 for r in report.results if r.is_control_check)
    return (
        f"{_plural(len(cells), 'cell')}, {passed} passed, "
        f"{len(cells) - passed} failed, {len(report.skipped)} skipped, "
        f"{_plural(checks, 'control check')}, "
        f"aborted: {'yes' if report.aborted else 'no'}"
    )


def _build_driver(platform: str):
    if platform == "android":
        from .drivers.android import AndroidDriver

        return AndroidDriver()
    from .drivers.ios import IosDriver

    return IosDriver()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="tool.e2e.runner",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "exit codes:\n"
            "  0  every cell passed, or was skipped as already passed\n"
            "  1  a cell failed, or the run itself had a problem\n"
            "  2  a setup or cell-authoring mistake; nothing ran\n"
            "  3  aborted, on consecutive control failures or an --app that\n"
            "     would not install -- the rig or the backend is broken, and\n"
            "     no finding above it is believable\n"
        ),
    )
    parser.add_argument("--platform", required=True, choices=("android", "ios"))
    parser.add_argument("--cells", required=True, type=Path)
    parser.add_argument(
        "--evidence-root",
        required=True,
        type=Path,
        help=(
            "outside any git checkout; survives a WSL reboot. One root per "
            "dimension: a resume trusts what earlier runs in it recorded and "
            "keys on the cell id alone, and every dimension has a 'control'. "
            "Use --build-id for the build"
        ),
    )
    parser.add_argument("--env-file", required=True, type=Path)
    parser.add_argument(
        "--all", action="store_true", help="rerun cells that already passed"
    )
    parser.add_argument(
        "--app",
        help=(
            "APK (Android) or .app on the Mac (iOS) to install first; implies "
            "--all, because a pass recorded against another build is not this "
            "build's"
        ),
    )
    parser.add_argument(
        "--build-id",
        help=(
            "names the build under test, e.g. 'android-0.3.3-release-r8'. "
            "Written into every progress record, and a resume only trusts a "
            "pass whose build-id matches. Omit it and the behaviour is exactly "
            "as before"
        ),
    )
    parser.add_argument(
        "--only", action="append", help="run just this cell; repeatable"
    )
    args = parser.parse_args(argv)

    try:
        check_cells(args.cells, args.platform)
        sandbox = Sandbox.from_env_file(args.env_file)
        report = run_cells(
            platform=args.platform,
            cell_dir=args.cells,
            evidence_root=args.evidence_root,
            driver=_build_driver(args.platform),
            sandbox=sandbox,
            run_all=args.all or bool(args.app),
            only=args.only,
            app_path=args.app,
            build_id=args.build_id,
        )
    except (CellError, SandboxError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return EXIT_SETUP

    if report.aborted:
        # WHY: under a rig fault the findings below are not findings, so the abort
        # line comes first.
        print(f"ABORT {report.abort_reason}")
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
        unverified = (
            " (unverified)"
            if report.aborted and not result.passed and not result.is_control_check
            else ""
        )
        print(
            f"{tag} {result.cell_id} session={result.session_id} "
            f"label={result.label!r}{where}{unverified}"
        )
        for problem in result.problems:
            print(f"     - {problem}")
        for warning in result.warnings:
            print(f"     ! {warning}")
    for problem in report.problems:
        print(f"RUN-PROBLEM {problem}")
    for warning in report.warnings:
        print(f"WARN {warning}")
    print(_summary(report))
    return report.exit_code


if __name__ == "__main__":
    sys.exit(main())
