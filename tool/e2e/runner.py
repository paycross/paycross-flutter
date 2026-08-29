"""Loads cells, drives one, judges it, writes the proof. Repeat.

    python -m tool.e2e.runner --platform android \\
        --cells tool/e2e/cells/d0 \\
        --evidence-root ~/e2e-evidence/d0-debug \\
        --env-file ~/.paycross/.env.staging \\
        [--all] [--app PATH] [--only control]

Two rules here are worth their code. A failed cell triggers an interleaved
control before the failure is believed, and two consecutive control failures
abort the run -- a broken rig otherwise produces a page of findings that are
all the same finding. And the session token lives in a 0600 file in a 0700
directory outside the evidence root and is removed in a finally, so a driver
failure does not leave a live credential on disk.

Exit codes, which a nightly reads rather than the output:

    0  every cell passed, or every cell was skipped as already passed
    1  a cell failed, or the run itself had a problem
    2  a setup or cell-authoring mistake; nothing ran
    3  the run aborted: either two consecutive control failures, or an
       `--app` that would not install. The rig or the backend is broken,
       and no finding above it should be believed

One evidence root per build. A resume trusts what earlier runs recorded, and
`passed_cells` has no idea which build a pass came from, so pointing a new APK
or .app at an old root would report yesterday's result as today's. `--app`
therefore implies `--all`.

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
from .drivers.android import DIGIT_PACING_SECONDS
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
#:
#: `type_card` is one of them: the sheet's own card form is what is on screen
#: throughout it. On Android that frame is black (FLAG_SECURE) and the
#: `NN-type_card.uix` dump written beside it is the real evidence -- it is the
#: post-PAN tree the seed script dumped by hand, and the artifact a caret bug
#: shows up in.
SHOT_VERBS = ("type_card", "tap_pay", "acs", "expect")

#: Exit codes. Part of this module's interface: the nightly branches on them.
EXIT_OK = 0
EXIT_FAILED = 1
EXIT_SETUP = 2
EXIT_ABORTED = 3

#: How much of the token has to appear in a dump for the runner to conclude
#: that the example's own screen is showing. Short enough to survive a viewer
#: that truncates long attribute values, and a false positive here costs a
#: screenshot while a false negative costs a leak that cannot be undone.
_TOKEN_PREFIX_CHARS = 24

#: A PAN is typed one key event at a time, at the Android driver's own pacing.
#: Referenced rather than restated so a change there moves the budget with it:
#: that pacing is what the 0.3.2 caret fix was proven under.
PAN_DIGITS = 16

#: On top of the typing: four field round trips, the PAN read-back, and the
#: IME drop that makes the Pay button reachable again.
CARD_FIELDS_SECONDS = 150

#: Wall-clock ceilings per verb, before slack, for a step that is making
#: progress -- not expected durations. `acs` gives the sandbox page 120 s, and
#: `type_card` spends ~7 s on key events before anything else happens.
VERB_BUDGET_SECONDS = {
    # iOS is the worst case here: 60 s for the example's own screen to come
    # up, 60 s for the sheet after it, a 10 s read-back, and the paste itself.
    "paste_token": 180,
    "type_card": PAN_DIGITS * DIGIT_PACING_SECONDS + CARD_FIELDS_SECONDS,
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
    #: True when the cell asked for something Phase 0 does not implement. A
    #: cell-authoring mistake, not a device fault, so no control check is
    #: spent proving a rig that was never in doubt.
    authoring: bool = False
    #: Problems this cell found that belong to the run rather than to the
    #: verdict -- a token file that would not go. Drained into Report.
    run_problems: list[str] = field(default_factory=list)
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
        """See the table in the module docstring.

        An abort is its own code because it is its own thing: the findings
        under it are not findings. A run-level problem counts as a failure --
        a green exit has to mean the whole run worked, or the next reader has
        no reason to read the output.
        """
        if self.aborted:
            return EXIT_ABORTED
        if self.problems or not all(r.passed for r in self.results):
            return EXIT_FAILED
        return EXIT_OK


def budget_for(cell: Cell) -> float:
    """The wall clock a cell is allowed before the runner gives up on it.

    Deliberately generous -- a false budget failure would be a false finding
    -- but bounded, because a driver's own transport timeouts (300 s for adb,
    900 s for ssh) are spent on top of a poll's deadline rather than inside
    it, and one wedged cell would otherwise take a 40-minute matrix with it.

    What this is and is not. It is checked between steps, so it never
    interrupts a driver call in progress and never fires after the last
    action; a cell's true ceiling is this budget plus one transport timeout.
    It is a backstop against a hang, not a bound on how long the matrix
    takes, and it is not a performance assertion: a cell that finishes inside
    it has proved nothing about how quickly it did so.
    """
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
        # The driver saying the cell asked for a D2/D3 action. The cell file
        # is wrong, not the rig.
        return "authoring"
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
    else:
        # Reached only for an argument this function has no branch for --
        # cells.py rejects those at load time -- so it is the argument that
        # gets named, not the verb, which is supported and is not the problem.
        raise DriverError(f"the runner cannot perform {verb} with {arg!r}")
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
    run_problems: list[str] = []
    label: str | None = None
    rearmed: bool | None = None
    session: dict[str, str] = {}
    reached_the_end = False
    authoring = False

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
    #: Every credential this cell is known to hold. It grows: the merchant read
    #: hands back a token the runner never minted, and everything filed after
    #: that read is scrubbed of it by literal rather than left to the shape
    #: rule.
    secrets: list[str | None] = [token]

    def write(name: str, data: bytes) -> None:
        # The literal tokens as well as the shape rule: a token whose segments
        # are shorter than JWT_RE wants is not matched by shape, and a log can
        # wrap one in a way no regex was written for.
        run.write(artifact_id, name, data, secrets=tuple(secrets))

    if session:
        # 0700 directory, 0600 file, outside the evidence root, gone in the
        # finally even when the driver dies mid-cell.
        token_dir = Path(tempfile.mkdtemp(prefix="paycross-e2e-"))
        step, verb = "00-launch", "launch"
        try:
            os.chmod(token_dir, 0o700)
            # The same guard the evidence tree puts on a directory name: this
            # is the other path a cell id is made into.
            evidence.check_cell_id(cell.id)
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
                        f"the cell used its {budget:.1f}s budget before {step}"
                    )

                answer = _perform(
                    driver,
                    action,
                    card=cell.card,
                    token_path=token_path,
                    amount_text=amount_text,
                )
                if action.verb == "wait_result":
                    # Scrubbed where it is read: the label comes off the
                    # device, and main prints it. Doing it here means the
                    # match, the ledger, result.json and stdout all see the
                    # same value.
                    label = _redacted(answer, token)
                elif action.verb == "expect":
                    rearmed = answer

                # Unguarded, unlike the screenshot below and the log
                # fetch at the end. Those are collected beside a verdict; the
                # tree is how a verdict is reached at all, since every polling
                # wait reads it. A device that will not produce one has
                # nothing left to observe, so the cell ends here rather than
                # carrying on blind.
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
            authoring = isinstance(error, NotImplementedError)
            problems.append(f"{_kind(error)}: {error}")
            # The tree at the moment of failure is usually the whole
            # diagnosis, and the write above never ran for this step. Best
            # effort: a device that has gone away must not replace the real
            # error with a second one.
            try:
                # Best effort by now: a dump that fails here is the second
                # failure in a row and costs only a diagnosis.
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
            try:
                shutil.rmtree(token_dir)
            except OSError as error:
                # Not ignore_errors: a live credential still on disk is not
                # this cell's verdict, but it is nobody's if it is swallowed.
                run_problems.append(
                    _redacted(
                        f"token: {cell.id}'s token file was left behind at "
                        f"{token_dir}: {error}"
                    )
                )

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
            # A GET on an open session re-mints a session_token and hands
            # it back, and puts a second copy in checkout_url -- a live
            # credential the runner never minted and cannot have named as a
            # secret. Dropped by key here, and added to `secrets` so the
            # artifacts filed after this one are scrubbed of it too.
            resource, minted_by_the_read = evidence.scrub_resource(resource)
            secrets.extend(minted_by_the_read)
            # Filed either way: the merchant's view of a cell that died
            # mid-flight is how you tell a driver that lost the device from a
            # payment that never happened.
            write("merchant.json", json.dumps(resource, indent=2).encode())
            if reached_the_end:
                # Gated for the same reason the label check is: a cell cut
                # short never reached the state it describes, so a mismatch
                # here is the first failure's consequence, not a finding.
                problems += verify.verify_merchant(resource, expected.merchant)
                problems += verify.verify_label_transaction(
                    resource, transaction_id
                )

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
            # Never gated on reaching the end: a crash is not a consequence of
            # the first failure, it is very often the cause of it.
            problems += [
                f"crash: {line.strip()}"
                for line in verify.crash_lines(log, driver.package)
            ]

    problems = [_redacted(problem, *secrets) for problem in problems]
    result = CellResult(
        cell_id=cell.id,
        passed=not problems,
        problems=problems,
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
    # Last: this line is the ledger a resume reads, so it is appended only
    # once the evidence it points at is on disk. Every field here has already
    # been through _redacted, so the scrub is belt and braces -- but it takes
    # the cell's whole secrets list rather than the minted token alone,
    # because the merchant read adds one the runner never minted and a
    # narrower list here would be the one place it is not covered.
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
        secrets=tuple(secrets),
    )
    return result


def check_cells(cell_dir: Path, platform: str) -> list[Cell]:
    """Loads a cell directory and refuses everything wrong with it up front.

    Everything here is knowable before a credential is read or a device is
    touched, and `main` calls it ahead of the env file for exactly that
    reason: an authoring mistake reported after the credentials have been
    opened has already cost more than it should.
    """
    everything = load_cells(Path(cell_dir), platform)
    if not everything:
        # Running nothing and exiting 0 reads as "everything passed".
        raise CellError(f"{cell_dir}: no cell in it runs on {platform}")
    for cell in everything:
        # The evidence tree's own guard: a cell id becomes a directory name
        # and a token filename, and neither may climb out of where it belongs.
        try:
            evidence.check_cell_id(cell.id)
        except ValueError as error:
            raise CellError(f"{cell.path}: {error}") from error
    if not any(c.id == CONTROL_CELL_ID for c in everything):
        # The interleaved check and the abort rule are what tell an SDK
        # finding from a broken rig. A run that cannot do that should not
        # start rather than quietly report findings nothing vouches for.
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
) -> Report:
    # Checked again rather than taken on trust: run_cells is callable on its
    # own, and this is the last point before a session is minted.
    everything = check_cells(cell_dir, platform)
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
            report.problems += result.run_problems

            if cell.id == CONTROL_CELL_ID:
                consecutive_control_failures = (
                    0 if result.passed else consecutive_control_failures + 1
                )
            elif not result.passed and not result.authoring:
                # Skepticism: prove the rig before believing the finding. Not
                # for an authoring fault, though -- the driver refusing a D3
                # verb says nothing about the rig, and a control cell costs a
                # session and a minute.
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
            "build: a resume trusts what earlier runs in it recorded, and a "
            "pass carries no build fingerprint"
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
        "--only", action="append", help="run just this cell; repeatable"
    )
    args = parser.parse_args(argv)

    try:
        # Before the credentials are read or a device is touched: a cell
        # directory that cannot be run deserves one line, not a traceback
        # halfway through a matrix -- or after the env file has been opened.
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
        )
    except (CellError, SandboxError, OSError) as error:
        # An unusable selection or an evidence root that cannot be written is
        # a mistake to explain, not a stack to read. Whatever a run did manage
        # is already on disk: progress is appended and fsynced per cell.
        print(f"error: {error}", file=sys.stderr)
        return EXIT_SETUP

    if report.aborted:
        # First, so that what follows is read as what it is. The findings
        # under a rig fault are not findings.
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
        # The control checks are the evidence for the abort, so they stand;
        # the cell failures beside them are what nothing vouches for.
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
    for problem in report.problems:
        print(f"RUN-PROBLEM {problem}")
    print(_summary(report))
    return report.exit_code


if __name__ == "__main__":
    sys.exit(main())
