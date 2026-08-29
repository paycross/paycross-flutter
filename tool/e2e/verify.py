"""Pass criteria 1-3, as pure functions over what the run collected.

1. the Dart label matches the cell's expectation -- `match_label`, which
   answers whether it matched and hands back the transaction id it captured;
   `verify_label_transaction` then turns that id into problems
2. the merchant API agrees -- `verify_merchant`
3. nothing crashed -- `crash_lines`, which returns the offending log lines
   verbatim rather than a description of them

The two verifiers return a list of human-readable problems; empty means pass.
A list rather than a bool so a failed cell's report names every mismatch at
once instead of one per rerun. Every problem line leads with the key it is
about, so a report can be scanned down its first column.
"""

from __future__ import annotations

import re
from typing import Any

#: `<txn>` only ever appears last in a label, so `.*` cannot swallow a later
#: field. Owned by `cells` because `load_cell` is what refuses a template
#: carrying two of them; imported here, and still readable as
#: `verify.TXN_PLACEHOLDER`, because this is where the label rules live.
#: Importing the other way round would be a cycle.
from .cells import ANY_LABEL, LABEL_RE, NO_LABEL, TXN_PLACEHOLDER

#: Faults whose own log line names the component it is about, and which are
#: therefore matched only when that component is the app under test. `ANR in
#: <package>` comes from system_server and `Force finishing activity
#: <package>/<activity>` from the activity manager, and the emulator does
#: plenty of both on its own housekeeping. Unscoped, one of those fails a cell,
#: then fails the interleaved control for the same reason, and aborts the whole
#: run as a rig fault.
_SCOPED_FAULTS = ("ANR in", "Force finishing activity")

#: The Android crash header. Its own line carries no package -- the `Process:`
#: line below it does -- so `_fatal_is_ours` scopes it instead. A bare
#: AndroidRuntime line is not a fault at all: the uiautomator and monkey
#: harnesses log dozens of those on a perfectly healthy run.
_FATAL = "FATAL EXCEPTION"
_PROCESS = "Process:"

#: How far below the header that line is looked for. It is the very next one;
#: two leaves room for a logcat that interleaves another buffer's line.
_PROCESS_LOOKAHEAD = 2

_IOS_FAULTS = ("Fatal error:", "*** Terminating app due to uncaught exception")

#: Dart faults surface identically on both platforms -- `E/flutter` on Android,
#: the same text through the unified log on iOS -- so they are not per-platform.
#: This is the fault a plugin bug is most likely to produce, and it appears
#: nowhere in the 15,647-line healthy reference log at android/smoke.
_DART_FAULTS = ("Unhandled Exception:",)

#: Built once rather than per log line: `crash_lines` scans a whole device log.
#: These name no component, so they are faults wherever they appear.
_FAULTS = _IOS_FAULTS + _DART_FAULTS


#: Transaction statuses that mean money moved. `succeeded` is the ordinary
#: `sale` terminal, but an `auth` session stops at `authorized` and an
#: `auth_capture` at `captured` -- and a cancel/decline cell that only looked
#: for `succeeded` would pass on either of those.
MONEY_MOVED = frozenset({"succeeded", "authorized", "captured"})


#: The merchant assertions `verify_merchant` implements. Kept equal to
#: `cells.MERCHANT_KEYS` by a test rather than imported from it: a key a cell
#: can declare but nothing here checks would pass vacuously, which is the one
#: failure mode a green suite cannot otherwise show.
MERCHANT_CHECKS = frozenset(
    {
        "session_status",
        "txn_count",
        "txn_status",
        "no_succeeded_txn",
        "failure_recovery",
        "failure_code",
        "network_decline_code",
        "saved_card_saved",
        "saved_card_used",
        "threeds",
    }
)


def match_label(template: str, actual: str | None) -> tuple[bool, str | None]:
    """Compares a label against a cell's expectation.

    Three shapes. `<none>` passes only when nothing was rendered. `<any>`
    passes on any well-formed contract label and captures nothing -- it is a
    discovery cell's expectation, and the label it measured is recorded in
    result.json rather than compared. Anything else is a literal, in which
    `<txn>` is a capture: a transaction id is minted by the server, so a cell
    can never name one, and `verify_label_transaction` cross-checks the
    captured value against the merchant API instead.

    `LABEL_RE` is imported rather than restated -- unlike `MERCHANT_CHECKS`,
    which is deliberately kept equal to `cells.MERCHANT_KEYS` by a test. Two
    independent key lists whose equality is the thing under test is not the
    same as one vocabulary with one meaning.
    """
    if template == NO_LABEL:
        return actual is None, None
    if actual is None:
        return False, None
    if template == ANY_LABEL:
        return bool(LABEL_RE.fullmatch(actual)), None
    if TXN_PLACEHOLDER not in template:
        return template == actual, None
    head, _, tail = template.partition(TXN_PLACEHOLDER)
    pattern = re.compile(f"^{re.escape(head)}(?P<txn>.*){re.escape(tail)}$", re.DOTALL)
    found = pattern.match(actual)
    return (True, found.group("txn")) if found else (False, None)


def _transactions(resource: dict[str, Any]) -> list[dict[str, Any]]:
    return resource.get("transactions") or []


def _latest(resource: dict[str, Any]) -> dict[str, Any] | None:
    txns = _transactions(resource)
    return txns[-1] if txns else None


def _failure(latest: dict[str, Any] | None) -> dict[str, Any]:
    # `or {}` on the inner get too: a succeeded transaction plausibly carries
    # an explicit "failure": null.
    return (latest or {}).get("failure") or {}


def _threeds_problems(
    latest: dict[str, Any] | None, expected: dict[str, Any]
) -> list[str]:
    """One problem per mismatched field, or one for the whole missing block.

    A cell that names five 3DS fields against a card that never went through
    3DS -- the ...153055 case -- would otherwise report the same absence five
    times over and bury the finding.
    """
    actual = (latest or {}).get("threeds_result")
    if not actual:
        return ["threeds: no threeds_result on the latest transaction"]
    return [
        f"threeds.{key}: expected {want!r}, got {actual.get(key)!r}"
        for key, want in expected.items()
        if actual.get(key) != want
    ]


def verify_merchant(resource: dict[str, Any], expected: dict[str, Any]) -> list[str]:
    """Checks only the keys the cell actually asserts.

    A key that is absent is not asserted. A key present with a null value
    asserts the field is absent. The two are genuinely different, and the
    distinction is the reason `failure_recovery: null` is expressible at all
    -- though no shipped cell needs it today. It was written for a reading of
    authentication_failed that the live runs disproved: both platforms return
    `change_method`. Kept because "this field must not be there" is an
    assertion a decline cell will want, not because D0 makes it.
    """
    problems: list[str] = []
    latest = _latest(resource)

    if "session_status" in expected:
        # `sandbox.read` raises on any non-2xx or non-JSON response, so a
        # resource that gets this far without a `status` key is an unexpected
        # shape rather than a session that reported no status. Saying so beats
        # `got None`, which reads as a payment-state finding and sends whoever
        # is debugging after the wrong bug.
        if "status" not in resource:
            problems.append("session_status: the session resource has no 'status' key")
        elif resource["status"] != expected["session_status"]:
            problems.append(
                f"session_status: expected {expected['session_status']!r}, "
                f"got {resource['status']!r}"
            )

    if "txn_count" in expected:
        actual = len(_transactions(resource))
        if actual != expected["txn_count"]:
            problems.append(
                f"txn_count: expected {expected['txn_count']}, got {actual}"
            )

    if "txn_status" in expected:
        actual = latest.get("status") if latest else None
        if actual != expected["txn_status"]:
            problems.append(
                f"txn_status: expected {expected['txn_status']!r}, got {actual!r}"
            )

    if "no_succeeded_txn" in expected:
        moved = [
            t for t in _transactions(resource) if t.get("status") in MONEY_MOVED
        ]
        if expected["no_succeeded_txn"] and moved:
            problems.append(
                "no_succeeded_txn: the session holds "
                f"{len(moved)} transaction(s) that moved money: "
                f"{[t.get('id') for t in moved]}"
            )
        elif not expected["no_succeeded_txn"] and not moved:
            # `false` used to be a no-op that read like an assertion. It now
            # means what a reader always thought it meant.
            problems.append(
                "no_succeeded_txn: expected a transaction that moved money, "
                "the session holds none"
            )

    for key, field in (
        ("failure_recovery", "recovery"),
        ("failure_code", "code"),
        ("network_decline_code", "network_decline_code"),
    ):
        if key in expected:
            actual = _failure(latest).get(field)
            if actual != expected[key]:
                problems.append(
                    f"{key}: expected {expected[key]!r}, got {actual!r}"
                )

    for key, field in (
        ("saved_card_saved", "saved_token"),
        ("saved_card_used", "used_token"),
    ):
        if key in expected:
            # Presence, never the value: `evidence.scrub_resource` drops both
            # keys by name before this ever sees them, so what is left is the
            # redaction marker for a card that was stored and `null` for one
            # that was not -- which is exactly the distinction being asserted.
            stored = (latest or {}).get("stored_credentials") or {}
            present = bool(stored.get(field))
            if present != expected[key]:
                problems.append(
                    f"{key}: expected {expected[key]}, got {present} "
                    f"(stored_credentials.{field})"
                )

    if "threeds" in expected:
        problems.extend(_threeds_problems(latest, expected["threeds"]))

    return problems


def verify_label_transaction(resource: dict[str, Any], txn_id: str | None) -> list[str]:
    """A non-empty `<txn>` in the label must name a real transaction.

    An empty one is recorded, not rejected: `PayCrossFailure.transactionId` is
    genuinely null when the payment failed before a transaction existed.
    """
    if not txn_id:
        return []
    # A None id is dropped rather than kept: it can never equal a non-empty
    # txn_id, and sorting a set holding both None and a string raises -- which
    # would turn this verification failure into a crash.
    known = {t.get("id") for t in _transactions(resource) if t.get("id") is not None}
    if txn_id in known:
        return []
    return [f"label_transaction: {txn_id!r} is not among the session's {sorted(known)}"]


def _fatal_is_ours(lines: list[str], index: int, package: str) -> bool:
    """Whether the crash header at `index` belongs to the app under test.

    `E AndroidRuntime: FATAL EXCEPTION: main` is followed by `E AndroidRuntime:
    Process: <package>, PID: <pid>`, which is the only place the crash names
    itself. When that line is there it decides; when it is not -- a window that
    starts mid-crash, an unfamiliar format -- the fault is kept, because a
    missed crash is the expensive direction to be wrong in.
    """
    for line in lines[index + 1 : index + 1 + _PROCESS_LOOKAHEAD]:
        if _PROCESS in line:
            return package in line
    return True


def crash_lines(log: str, package: str) -> list[str]:
    """Pass criterion 3, over logcat or the simulator's unified log."""
    lines = log.splitlines()
    faults = []
    for index, line in enumerate(lines):
        if _FATAL in line:
            if _fatal_is_ours(lines, index, package):
                faults.append(line)
        elif any(marker in line for marker in _SCOPED_FAULTS):
            if package in line:
                faults.append(line)
        elif any(marker in line for marker in _FAULTS):
            faults.append(line)
    return faults
