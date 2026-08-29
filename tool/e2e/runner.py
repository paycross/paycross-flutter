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

One evidence root per dimension, and `--build-id` for the build. A resume
trusts what earlier runs in the root recorded, and `passed_cells` keys on the
cell id -- so two dimensions sharing a root would let D0's `control` pass
satisfy D2's. The build half is carried rather than disciplined: every
progress record names the build under test and a resume only trusts a pass
whose name matches, so pointing a release APK at a debug run's root reruns
rather than reporting yesterday's result as today's. `--app` still implies
`--all`, which is the same answer without having to name a build.

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
from collections.abc import Sequence
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from . import evidence, tree, verify
from .cells import ARG_ACTIONS, BARE_ACTIONS, Action, Card, Cell, CellError, load_cells
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

#: How often `wait_expired` asks the merchant API.
SESSION_POLL_SECONDS = 30

#: What `expect no_result` gives a result that must never arrive. Long enough
#: that a slow one would still be caught, short enough that a cell asserting an
#: absence does not dominate a matrix run.
NO_RESULT_TIMEOUT_SECONDS = 60

#: The sandbox ACS page's own load. The same 120 s `acs()` already allows it.
ACS_PAGE_TIMEOUT_SECONDS = 120

#: The wallet button appears only after the session loads and after an
#: asynchronous isReadyToPay, so it is genuinely late rather than instant.
WALLET_TIMEOUT_SECONDS = 30

#: And its absence is waited OUT rather than waited for -- this is how long a
#: late button gets to turn up and disprove the expectation.
WALLET_ABSENT_TIMEOUT_SECONDS = 20

#: A stored card is in the session snapshot before the sheet renders, so this
#: only covers the sheet coming up at all.
SAVED_CARD_TIMEOUT_SECONDS = 30

#: How long each `expect` predicate is given, in one place so the failure
#: message can name the number the wait actually used.
#:
#: The drivers keep their own literal defaults for these -- `runner` imports
#: `drivers`, so a driver cannot import back -- and `_observe` always passes
#: `timeout=` explicitly, which makes this table the value that is really used
#: and the driver defaults only a courtesy to a direct caller. Keep the pairs
#: equal; a test asserts it, over the predicates that carry a literal default
#: on the CONCRETE drivers. `Driver`'s declarations deliberately have none --
#: they raise before a timeout could matter -- and `wait_rearmed` and
#: `wait_no_label` take the deadline without a default by design, so a sweep
#: over all six would read `Parameter.empty` and fail on three of them.
#:
#: `no_google_pay` is the odd one and deliberately short: it waits an absence
#: OUT rather than waiting for something, so its number is how long a late
#: button gets to appear, not how long anything gets to arrive.
EXPECT_TIMEOUT_SECONDS = {
    "rearmed": REARM_TIMEOUT_SECONDS,
    "no_result": NO_RESULT_TIMEOUT_SECONDS,
    "acs": ACS_PAGE_TIMEOUT_SECONDS,
    "google_pay": WALLET_TIMEOUT_SECONDS,
    "no_google_pay": WALLET_ABSENT_TIMEOUT_SECONDS,
    "saved_card": SAVED_CARD_TIMEOUT_SECONDS,
}

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
    # The same entry and the same read-back, minus the wait for a sheet that
    # is never going to open -- but the example's own screen still has to come
    # up first, which is where most of the 180 goes.
    "present_token": 180,
    "enter_token": 60,
    "tap_example_pay": 30,
    "type_card": PAN_DIGITS * DIGIT_PACING_SECONDS + CARD_FIELDS_SECONDS,
    "type_cvv": 60,
    "tap_pay": 60,
    "tap_google_pay": 60,
    "select_saved_card": 60,
    "save_card": 60,
    "acs": 240,
    "cancel_challenge": 180,
    "cancel_form": 90,
    "expect": 90,
    # A cold start plus the settle, which is `launch` again from inside a cell.
    "relaunch": 90,
    "rotate": 60,
    "airplane": 60,
    "dont_keep_activities": 60,
    "kill_activity": 60,
}
DEFAULT_VERB_SECONDS = 120

#: Verbs whose argument already says how long they may take. D2 waits 16 and
#: 30 minutes for a session to pass its own expiry, and on the default budget
#: such a cell would breach mid-wait and report a hang -- which is a false
#: finding, and the expensive direction to be wrong in.
TIMED_VERBS = ("wait", "wait_result", "wait_expired", "background")

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
    #: Things the run noticed and carried on through -- today, a bearer
    #: refresh that fell back to the field the gateway restates. Deliberately
    #: not `problems`: these do not change the exit code, because a warning
    #: that turns a green matrix red is a warning the next person learns to
    #: silence.
    warnings: list[str] = field(default_factory=list)
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
        # Either the driver saying the cell asked for an action it does not
        # implement, or `_perform` saying the grammar accepts the verb but no
        # branch executes it yet. Both mean the cell reached for a dimension
        # that has not landed: the cell file is wrong, not the rig.
        return "authoring"
    return type(error).__name__


def _shows_the_example_screen(
    dump: bytes, platform: str, secrets: Sequence[str | None]
) -> bool:
    """Whether this dump is of the example app rather than of the sheet.

    Three tells, any of which is enough: a credential this cell is known to
    hold, anything else JWT-shaped, or a result label -- the example renders
    one only once the sheet has closed. An unreadable dump counts as a yes,
    because a leaked frame cannot be un-leaked and a missing one costs
    nothing.

    Every known credential rather than the one the cell minted, because
    `wait_expired` re-mints on every poll: by a later step the string in the
    example's token field is one the runner learned about afterwards, and the
    original's prefix is not on screen at all. That would leave only the shape
    rule -- which `evidence.scrub_resource` refuses to rely on for exactly
    this, having twice been shown to miss a token.
    """
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
    """Whether a frame of this step can be filed without leaking the token.

    Both conditions are required. The verb has to be one that runs with the
    sheet or the ACS page foreground, and the dump taken a moment earlier has
    to agree -- if the payment resolved during that dump the sheet has gone,
    and the frame would be the example's screen, token field and all. A
    `grep eyJ` over the evidence tree cannot see into a compressed PNG, so
    that leak would be invisible to the check meant to catch it.
    """
    return verb in SHOT_VERBS and not _shows_the_example_screen(dump, platform, secrets)


@dataclass
class Step:
    """Everything one action may need, so `_perform` takes two arguments.

    `wait_expired` reaches the merchant API and rewrites the cell's token
    file, so an action now needs more than a driver. Threading five more
    keyword arguments would put the same five at every call site in the
    runner's tests; one object does not.
    """

    driver: Any
    sandbox: Any
    card: Card
    token_path: Path
    amount_text: str
    session_id: str | None
    #: The cell's growing list of known credentials. `wait_expired` appends to
    #: it: every read of an open session re-mints a token the runner never
    #: minted, and everything filed afterwards is scrubbed of it by literal.
    secrets: list[str | None]


def _wait_expired(step: Step, seconds: float, *, sleep=None) -> None:
    """Waits for the backend to mark the session `expired`, refreshing the token.

    Two jobs on one poll, because they are the same read. A session's
    `expires_at` is mint + 1200 s (session_ttl + session_grace_period, both
    env-overridable) while the token minted with it dies at mint + 900 s, so
    re-presenting the original token after the flip would measure the JWT
    expiry all over again rather than the server's verdict. A GET on an open
    session re-mints a token (`PaymentSessionResource.php`, gated on
    `effective_status === OPEN`), so every poll leaves a fresher one on the
    cell's 0600 file and the last read before the flip hands it one good for
    another ~900 s.

    `payments:expire-sessions` runs every minute over sessions that are OPEN
    and past `expires_at` (`ExpirePaymentSessions.php:29-31`) -- it does not
    look at transactions at all, so a session holding a failed one expires
    exactly like an empty one.
    """
    # Resolved here rather than as a default, so patching `time.sleep` reaches
    # this from a whole-cell test as well as from a direct one.
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
            # Read by key from the unscrubbed resource rather than taken from
            # what the scrub returned: the checkout_url carries the same string
            # and the order those two are found in is the resource's key order,
            # not something to depend on.
            step.token_path.write_text(token, encoding="utf-8")
        if time.monotonic() >= deadline:
            raise BudgetExceeded(
                f"the session was still {status!r} after {seconds:.0f}s, expected "
                "'expired'"
            )
        sleep(SESSION_POLL_SECONDS)


def _observe(step: Step, what: str) -> tuple[bool, str | None]:
    """Runs one `expect` predicate and answers (observed, what was seen).

    Uniform on purpose, and this is the whole reason it exists. The obvious
    shape -- an `elif` per argument in `run_cell` -- silently discards the
    answer of every expectation it has no branch for, and the expectations
    that arrive later are exactly the ones whose only job is to look:
    `expect google_pay` returning False would leave `google_pay_offered`
    passing on a sheet with no wallet button on it at all. So the rule is that
    a **falsy answer is a cell failure**, stated once, and a new expectation is
    one line here rather than a branch someone has to remember to wire.

    `no_result` is the one inverted case: it hands back the label that should
    not exist, so it is converted here rather than leaving every caller to know
    which way round it reads.
    """
    driver = step.driver
    timeout = EXPECT_TIMEOUT_SECONDS.get(what)
    if timeout is None:
        # `.get` and a guard rather than a direct lookup, because a direct one
        # raises KeyError -- and KeyError is exactly the miscategorised error
        # this whole design is about: `run_cell` reads DriverError and
        # NotImplementedError as things it knows how to report, and anything
        # else as a device problem worth spending an interleaved control check
        # on. An expectation added to EXPECTATIONS without a deadline would
        # take that path.
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
    # Not dead, and not the same drift as the guard above: this one catches an
    # expectation that HAS a deadline and no branch. Falling off the end
    # instead would return None, which `run_cell` unpacks as a tuple.
    raise DriverError(f"the runner cannot observe {what!r}: no predicate")


def _perform(step: Step, action: Action):
    """Executes one action and returns whatever it answers with.

    `wait_result` answers with a label and `expect` with an (observed, seen)
    pair. Everything else answers with None.
    """
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
    elif verb == "save_card":
        driver.save_card()
    elif verb == "acs":
        driver.acs(arg)
    elif verb == "cancel_challenge":
        driver.cancel_challenge()
    elif verb == "cancel_form":
        driver.cancel_form()
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
        driver.airplane(arg == "on")
    elif verb == "dont_keep_activities":
        driver.dont_keep_activities(arg == "on")
    elif verb == "kill_activity":
        driver.kill_activity()
    elif _grammar_accepts(verb, arg):
        # A cell file really could carry this, and no branch above executes it
        # -- so the cell has reached for a dimension that has not landed. That
        # is a cell-authoring fault, and NotImplementedError is what `_kind`
        # classifies as one, which is what stops a control check being spent
        # proving a rig that was never in doubt.
        #
        # Every verb the grammar holds today does have a branch, so this guard
        # is about the next one somebody adds: without it a new verb would
        # raise DriverError below and be read as a device problem. The message
        # says *branch* rather than driver method, because the two can be
        # apart -- `relaunch` was implemented on both drivers for a whole
        # phase while nothing called it.
        raise NotImplementedError(
            f"{verb} is in the action grammar but the runner has no branch "
            f"for it yet (arg {arg!r})"
        )
    else:
        # Malformed rather than unlanded: either the verb is not in the
        # grammar or its argument is not one this verb takes. `load_cell`
        # refuses both, so no cell file reaches here -- but `run_cell` takes an
        # `Action`, and this is the honest answer for one built by hand. The
        # argument is named because on a legal verb it is the half that is
        # wrong.
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

    problems: list[str] = []
    run_problems: list[str] = []
    label: str | None = None
    rearmed: bool | None = None
    session: dict[str, str] = {}
    #: Steps whose verb could have been photographed but whose dump said the
    #: sheet had already gone. Filed by name, because a cell with no frames in
    #: it is otherwise indistinguishable from a screenshot path that is
    #: quietly broken -- which is a live question for the campaign report.
    screenshots_skipped: list[str] = []
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
        stem, verb = "00-launch", "launch"
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
            # One object rather than five keyword arguments, because
            # `wait_expired` needs the merchant API and the token file as well
            # as the driver. `secrets` is the cell's own list, so what that
            # verb learns is scrubbed from everything filed afterwards.
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
                    # Scrubbed where it is read: the label comes off the
                    # device, and main prints it. Doing it here means the
                    # match, the ledger, result.json and stdout all see the
                    # same value.
                    label = _redacted(answer, token)
                elif action.verb == "expect":
                    observed, detail = answer
                    if action.arg == "rearmed":
                        # Recorded for result.json. Every expectation's
                        # verdict is reached below, by name; this one is also
                        # the field a reader looks for.
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

                # Unguarded, unlike the screenshot below and the log
                # fetch at the end. Those are collected beside a verdict; the
                # tree is how a verdict is reached at all, since every polling
                # wait reads it. A device that will not produce one has
                # nothing left to observe, so the cell ends here rather than
                # carrying on blind.
                dump = driver.dump_tree()
                write(f"{stem}.uix", dump)
                if _may_screenshot(verb, dump, platform, secrets):
                    try:
                        write(f"{stem}.png", driver.screenshot())
                    except Exception as error:  # noqa: BLE001
                        # A frame is the least of what a cell collects, and
                        # the cell still has a verdict to reach.
                        problems.append(f"screenshot: {error}")
                elif verb in SHOT_VERBS:
                    screenshots_skipped.append(stem)
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

    if session:
        try:
            resource = sandbox.read(session["id"])
        # Beside the verdict, never in place of it: a merchant API that will
        # not answer is a problem to record, and the label and the crash scan
        # are still worth reaching.
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
                "build": build_id,
                "passed": result.passed,
                "control_check": is_control_check,
                "session_id": result.session_id,
                "label": result.label,
                "transaction_id": result.transaction_id,
                "rearmed": rearmed,
                "expected_label": expected.label,
                "problems": problems,
                "screenshots_skipped": screenshots_skipped,
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
            "build": build_id,
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
    build_id: str | None = None,
) -> Report:
    # Only run_cell had one, and report.json wants the whole run's window.
    started = datetime.now(timezone.utc)
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
    passed = (
        set()
        if run_all
        else evidence.passed_cells(Path(evidence_root), platform, build_id)
    )
    todo = [c for c in chosen if c.id not in passed]
    report.skipped = [c.id for c in chosen if c.id in passed]

    # Before the fully-skipped check rather than after it: a Run only makes a
    # directory, and a run that skipped everything is exactly the one Task 10
    # reads while assembling its tables. The directory it leaves holds nothing
    # but a report.json, which cannot pollute a resume -- `passed_cells` globs
    # `*/progress.jsonl` and there is none -- but it does mean an evidence
    # root accumulates reports, so anything reading one reads the newest.
    run = evidence.Run(Path(evidence_root), platform=platform)

    def write_run_report() -> None:
        # Drained here rather than raised: a warning that turns a green matrix
        # red is a warning the next person learns to silence.
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
                        "evidence": r.artifact_id,
                    }
                    for r in report.results
                ],
            }
        )

    if not todo:
        # No device is touched, so no driver.close() either: a fully-resumed
        # run has nothing to release.
        write_run_report()
        return report

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
            # Broad on purpose: adb and ssh fail in ways that are not
            # DriverError -- a Windows mount that is not there, a Mac asleep --
            # and every one of them means the same thing here. An install that
            # did not happen makes every result below it a result for the
            # previous build, so this aborts rather than failing a cell.
            except Exception as error:  # noqa: BLE001
                stop(f"could not install {app_path}: {_redacted(str(error))}")
                return report

        for cell in todo:
            # run_cell appends its own progress line: it is the only scope
            # holding the session token the record has to be scrubbed against.
            result = run_cell(cell, platform, driver, sandbox, run, build_id=build_id)
            report.results.append(result)
            report.problems += result.run_problems

            if cell.id == CONTROL_CELL_ID:
                consecutive_control_failures = (
                    0 if result.passed else consecutive_control_failures + 1
                )
            elif not result.passed and not result.authoring:
                # Skepticism: prove the rig before believing the finding. Not
                # for an authoring fault, though -- a verb the driver does not
                # implement, or whose `_perform` branch has not landed, says
                # nothing about the rig, and a control cell costs a session
                # and a minute.
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
        # After close(), so a host that would not let go is in the report
        # rather than only in the next reader's imagination.
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
            build_id=args.build_id,
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
    for warning in report.warnings:
        print(f"WARN {warning}")
    print(_summary(report))
    return report.exit_code


if __name__ == "__main__":
    sys.exit(main())
