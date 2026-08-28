"""Pass criteria 1-3, as pure functions over what the run collected.

1. the Dart label matches the cell's expectation
2. the merchant API agrees
3. nothing crashed

All three return a list of human-readable problems; empty means pass. A list
rather than a bool so a failed cell's report names every mismatch at once
instead of one per rerun.
"""

from __future__ import annotations

import re
from typing import Any

#: Only ever appears last in a label, so `.*` cannot swallow a later field.
TXN_PLACEHOLDER = "<txn>"

#: `ANR in <package>` is checked against the app; a bare AndroidRuntime line is
#: not, because the uiautomator and monkey harnesses log dozens of those on a
#: perfectly healthy run.
_ANDROID_FAULTS = ("FATAL EXCEPTION", "Force finishing activity")

_IOS_FAULTS = ("Fatal error:", "*** Terminating app due to uncaught exception")


def match_label(template: str, actual: str | None) -> tuple[bool, str | None]:
    """Compares a label against a cell's expectation.

    `<txn>` is a capture, not a literal: a transaction id is minted by the
    server, so a cell can never name one. The captured value is cross-checked
    against the merchant API by `verify_label_transaction` instead.
    """
    if actual is None:
        return False, None
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


def verify_merchant(resource: dict[str, Any], expected: dict[str, Any]) -> list[str]:
    """Checks only the keys the cell actually asserts.

    A key that is absent is not asserted. A key present with a null value
    asserts the field is absent -- which is the distinction the
    authentication_failed cell needs, because the sandbox returns no recovery
    on Android and `change_method` on iOS for the same ACS outcome.
    """
    problems: list[str] = []
    latest = _latest(resource)

    if "session_status" in expected:
        actual = resource.get("status")
        if actual != expected["session_status"]:
            problems.append(
                f"session_status: expected {expected['session_status']!r}, got {actual!r}"
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

    if expected.get("no_succeeded_txn"):
        succeeded = [
            t for t in _transactions(resource) if t.get("status") == "succeeded"
        ]
        if succeeded:
            problems.append(
                "no_succeeded_txn: the session holds "
                f"{len(succeeded)} succeeded transaction(s): "
                f"{[t.get('id') for t in succeeded]}"
            )

    if "failure_recovery" in expected:
        # `or {}` on the inner get too: a succeeded transaction plausibly
        # carries an explicit "failure": null, and `.get("failure", {})` would
        # then hand back None and raise on the next call.
        actual = ((latest or {}).get("failure") or {}).get("recovery")
        if actual != expected["failure_recovery"]:
            problems.append(
                f"failure_recovery: expected {expected['failure_recovery']!r}, "
                f"got {actual!r}"
            )

    if "threeds" in expected:
        actual_threeds = (latest or {}).get("threeds_result") or {}
        for key, want in expected["threeds"].items():
            got = actual_threeds.get(key)
            if got != want:
                problems.append(f"threeds.{key}: expected {want!r}, got {got!r}")

    return problems


def verify_label_transaction(txn_id: str | None, resource: dict[str, Any]) -> list[str]:
    """A non-empty `<txn>` in the label must name a real transaction.

    An empty one is recorded, not rejected: `PayCrossFailure.transactionId` is
    genuinely null when the payment failed before a transaction existed.
    """
    if not txn_id:
        return []
    known = {t.get("id") for t in _transactions(resource)}
    if txn_id in known:
        return []
    return [f"label transaction {txn_id!r} is not among the session's {sorted(known)}"]


def crash_lines(log: str, package: str) -> list[str]:
    """Pass criterion 3, over logcat or the simulator's unified log."""
    faults = []
    for line in log.splitlines():
        if any(marker in line for marker in _ANDROID_FAULTS + _IOS_FAULTS):
            faults.append(line)
        elif "ANR in" in line and package in line:
            faults.append(line)
    return faults
