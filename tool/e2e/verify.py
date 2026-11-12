"""Pass criteria 1-3 as pure functions over what a run collected."""

from __future__ import annotations

import re
from collections.abc import Iterable
from typing import Any, NamedTuple

# WHY: cells owns TXN_PLACEHOLDER because load_cell refuses a template with two;
# importing the other way round would be a cycle.
from .cells import (
    ANY_LABEL,
    LABEL_RE,
    NO_LABEL,
    TOLERABLE_CRASH_MARKERS,
    TXN_PLACEHOLDER,
)

# WHY: these log for every app on the device, so they fail a cell only when
# they name the app under test.
_SCOPED_FAULTS = ("ANR in", "Force finishing activity")

# WHY: the header names no package, so _attribute_fatal scopes it through the
# Process: line.
# A bare AndroidRuntime line is no fault: uiautomator and monkey log those on
# healthy runs.
_FATAL = "FATAL EXCEPTION"
_PROCESS = "Process:"

# WHY: two lines, not one, so a logcat that interleaves another buffer's line
# still finds Process:.
_PROCESS_LOOKAHEAD = 2

# WHY: logcat writes this tag as `E/AndroidRuntime(19931):` on a device and
# `E AndroidRuntime:` in other captures.
_CRASH_TAG = "AndroidRuntime"
_TAG_RE = re.compile(rf"\b{_CRASH_TAG}(?:\(\s*\d+\))?\s*:\s*")

# WHY: bounded, so a capture truncated mid-crash does not read the rest of the
# log as one stack.
_STACK_LOOKAHEAD = 80

_APP_FRAMES = ("com.paycross", "io.flutter")

_DRIVER_FRAMES = ("android.view.accessibility.", "android.accessibilityservice.")

_FRAMEWORK_PREFIX = "android."

_DRIVER_THREAD = "UiAutomation"

_APP = "app"
_DRIVER = "driver"
_FOREIGN = "foreign"

DRIVER_CRASH_REASON = (
    "attributed to the test driver, not the app: no Process: line, thread "
    f"{_DRIVER_THREAD}, and every frame is framework accessibility or binder "
    "machinery with none from the app. This is `uiautomator dump` losing its "
    "binder mid-cell, not a crash of the app under test"
)

_IOS_FAULTS = ("Fatal error:", "*** Terminating app due to uncaught exception")

# WHY: Dart faults read the same on Android (E/flutter) and iOS, so they are
# not per-platform.
_DART_FAULTS = ("Unhandled Exception:",)

_FAULTS = _IOS_FAULTS + _DART_FAULTS


# Statuses that mean money moved: an `auth` stops at authorized and an
# `auth_capture` at captured.
MONEY_MOVED = frozenset({"succeeded", "authorized", "captured"})


# WHY: kept equal to cells.MERCHANT_KEYS by a test; a declared key nothing
# checks here would pass vacuously.
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
    """Compares a label against a cell's expectation; returns (matched, captured txn id)."""
    # WHY: `<any>` captures too, so verify_label_transaction can catch a phantom id.
    if template == NO_LABEL:
        return actual is None, None
    if actual is None:
        return False, None
    if template == ANY_LABEL:
        found = LABEL_RE.fullmatch(actual)
        return bool(found), found.group("txn") if found else None
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
    # WHY: "failure" can be an explicit null on a succeeded transaction, not
    # only absent.
    return (latest or {}).get("failure") or {}


def _threeds_problems(
    latest: dict[str, Any] | None, expected: dict[str, Any]
) -> list[str]:
    """One problem per mismatched 3DS field, or one for a missing block."""
    actual = (latest or {}).get("threeds_result")
    if not actual:
        return ["threeds: no threeds_result on the latest transaction"]
    return [
        f"threeds.{key}: expected {want!r}, got {actual.get(key)!r}"
        for key, want in expected.items()
        if actual.get(key) != want
    ]


def verify_merchant(resource: dict[str, Any], expected: dict[str, Any]) -> list[str]:
    """Checks only the keys the cell asserts; a key set to None asserts it is absent."""
    problems: list[str] = []
    latest = _latest(resource)

    if "session_status" in expected:
        # WHY: a resource without a status key is malformed, not a session with
        # no status.
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
        moved = [t for t in _transactions(resource) if t.get("status") in MONEY_MOVED]
        if expected["no_succeeded_txn"] and moved:
            problems.append(
                "no_succeeded_txn: the session holds "
                f"{len(moved)} transaction(s) that moved money: "
                f"{[t.get('id') for t in moved]}"
            )
        elif not expected["no_succeeded_txn"] and not moved:
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
                problems.append(f"{key}: expected {expected[key]!r}, got {actual!r}")

    for key, field in (
        ("saved_card_saved", "saved_token"),
        ("saved_card_used", "used_token"),
    ):
        if key in expected:
            # WHY: presence only; scrub_resource leaves a redaction marker or null,
            # never the token.
            stored = (latest or {}).get("stored_credentials") or {}
            if not isinstance(stored, dict):
                # WHY: without this guard .get raises AttributeError instead of
                # returning a problem.
                problems.append(
                    f"{key}: stored_credentials is a "
                    f"{type(stored).__name__}, not an object"
                )
                continue
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
    """A non-empty `<txn>` in the label must name a real transaction."""
    if not txn_id:
        return []
    # WHY: a None id is dropped, because sorting a set holding None and a string raises.
    known = {t.get("id") for t in _transactions(resource) if t.get("id") is not None}
    if txn_id in known:
        return []
    return [f"label_transaction: {txn_id!r} is not among the session's {sorted(known)}"]


class CrashScan(NamedTuple):
    """Crash lines sorted into the app's faults, excused lines and driver crashes."""

    faults: list[str]
    excused: list[str]
    driver: list[str]


def _tag_body(line: str) -> str:
    """A crash line's own text, with the logcat tag in front of it removed."""
    return _TAG_RE.split(line, maxsplit=1)[-1].strip()


def _fatal_thread(line: str) -> str:
    """The thread named on a `FATAL EXCEPTION: <thread>` header."""
    _, _, thread = _tag_body(line).partition(_FATAL)
    return thread.lstrip(":").strip()


def _crash_block(lines: list[str], index: int) -> list[str]:
    """The lines of the crash the header at `index` opened, tags stripped."""
    # WHY: the block ends at the first crash-tagged line outside it. The
    # runtime's follow-on "Error reporting crash" block runs through
    # RuntimeInit and would look like a framework crash.
    # WHY: lines from other buffers interleave, so they are skipped, not treated
    # as the end.
    block: list[str] = []
    throwable_seen = False
    for line in lines[index + 1 : index + 1 + _STACK_LOOKAHEAD]:
        if _CRASH_TAG not in line:
            continue
        body = _tag_body(line)
        if _FATAL in body:
            break
        if body.startswith(("PID:", _PROCESS, "at ", "Caused by:", "... ")):
            block.append(body)
            continue
        if throwable_seen:
            break
        throwable_seen = True
        block.append(body)
    return block


def _attribute_fatal(lines: list[str], index: int, package: str) -> str:
    """Whose crash the header at `index` is: the app, the driver or a foreign package."""
    # WHY: the Process: line names the package, and it decides whenever it is present.
    # WHY: the driver is reclassified only on the narrow signature below; a
    # missed crash costs more.
    for line in lines[index + 1 : index + 1 + _PROCESS_LOOKAHEAD]:
        if _PROCESS in line:
            return _APP if package in line else _FOREIGN

    frames = [
        body.removeprefix("at ")
        for body in _crash_block(lines, index)
        if body.startswith("at ")
    ]
    if any(frame.startswith((*_APP_FRAMES, package)) for frame in frames):
        return _APP
    if (
        _fatal_thread(lines[index]) == _DRIVER_THREAD
        and frames
        and any(frame.startswith(_DRIVER_FRAMES) for frame in frames)
        and all(frame.startswith(_FRAMEWORK_PREFIX) for frame in frames)
    ):
        return _DRIVER
    return _APP


def crash_lines(log: str, package: str, tolerated: Iterable[str] = ()) -> CrashScan:
    """Pass criterion 3: sorts a log's crash lines into faults, excused lines and driver crashes."""
    # WHY: only the closed allow-list is honoured, so a caller cannot mute a
    # FATAL EXCEPTION.
    allowed = set(tolerated) & TOLERABLE_CRASH_MARKERS
    lines = log.splitlines()
    faults: list[str] = []
    excused: list[str] = []
    driver: list[str] = []
    for index, line in enumerate(lines):
        if _FATAL in line:
            whose = _attribute_fatal(lines, index, package)
            if whose == _APP:
                faults.append(line)
            elif whose == _DRIVER:
                driver.append(line)
        elif any(marker in line for marker in _SCOPED_FAULTS):
            if package in line:
                if any(marker in line for marker in allowed):
                    excused.append(line)
                else:
                    faults.append(line)
        elif any(marker in line for marker in _FAULTS):
            faults.append(line)
    return CrashScan(faults, excused, driver)
