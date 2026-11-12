"""Cell files: the declarative unit the matrix runner executes."""

from __future__ import annotations

import math
import re
from dataclasses import dataclass
from pathlib import Path
from types import MappingProxyType
from typing import Any

import yaml

PLATFORMS = ("android", "ios")

BARE_ACTIONS = frozenset(
    {
        "paste_token",
        # WHY: on iOS a malformed or expired token is refused before the sheet
        # appears, so waiting for a sheet would time out instead.
        "present_token",
        "tap_example_pay",
        "relaunch",
        "type_card",
        "type_cvv",
        "tap_pay",
        "tap_google_pay",
        "select_saved_card",
        # WHY: a confirmed removal can leave the row in place behind an error
        # banner, so the verb checks the row is gone.
        "remove_saved_card",
        "save_card",
        "cancel_challenge",
        "cancel_form",
        "dismiss_cancel",
        "rotate",
        "kill_activity",
    }
)

EXPECTATIONS = frozenset(
    {
        "rearmed",
        "no_result",
        "acs",
        "google_pay",
        "no_google_pay",
        "saved_card",
        # WHY: only the Pay button's verb is matched; the amount beside it is
        # formatted by a different rule and is not translated.
        "french_sheet",
    }
)

# WHY: the 200-character cap is far below a real session token, so a live
# credential cannot be committed in a cell file. The character class is
# limited because the device shell re-splits and expands what `input text`
# is given: any other character would be typed mangled.
_LITERAL_TOKEN = re.compile(r"[A-Za-z0-9._~-]{1,200}")


# WHY: kept as a literal because the runner cannot read the sandbox's outcome
# constants. A typo is rejected at load time by membership, not a shape check.
ACS_OUTCOMES = frozenset(
    {
        "approve",
        "authentication_failed",
        "authentication_rejected",
        "authentication_abandoned",
        "authentication_timeout",
        "authentication_required",
        "do_not_honor",
        "insufficient_funds",
        "card_expired",
        "invalid_card_number",
        "invalid_cvv",
        "card_lost_stolen",
        "card_restricted",
        "fraud_suspected",
        "transaction_not_allowed",
        "account_closed",
        "limit_exceeded",
        "duplicate_transaction",
        "customer_abandoned",
        "gateway_error",
        "issuer_unavailable",
        "timeout",
        "invalid_request",
        "session_expired",
        "merchant_configuration",
        "method_not_supported",
        "unknown_error",
    }
)


def _is_acs_outcome(arg: str) -> bool:
    return arg in ACS_OUTCOMES


def _is_positive_seconds(arg: str) -> bool:
    try:
        seconds = float(arg)
    except ValueError:
        return False
    # WHY: `inf` parses as a float and would hang the run rather than time it out.
    return math.isfinite(seconds) and seconds > 0


def _is_on_off(arg: str) -> bool:
    return arg in ("on", "off")


DEVICE_LANGUAGE_DEFAULT = "default"

# WHY: the Android SDK applies this shape rule before it formats an amount with a
# language tag, so a shape check is used rather than a list of languages.
_DEVICE_LANGUAGE = re.compile(r"[A-Za-z]{2,3}(-[A-Za-z0-9]+)*")


def _is_device_language(arg: str) -> bool:
    return arg == DEVICE_LANGUAGE_DEFAULT or bool(_DEVICE_LANGUAGE.fullmatch(arg))


def _is_expectation(arg: str) -> bool:
    return arg in EXPECTATIONS


def _is_literal_token(arg: str) -> bool:
    return bool(_LITERAL_TOKEN.fullmatch(arg))


ARG_ACTIONS = MappingProxyType(
    {
        "acs": (_is_acs_outcome, f"one of {sorted(ACS_OUTCOMES)}"),
        "airplane": (_is_on_off, "'on' or 'off'"),
        "background": (_is_positive_seconds, "a positive number of seconds"),
        # WHY: neither the Android locale list nor the iOS launch argument takes
        # effect on a running app, so the cell relaunches before it reads the sheet.
        "device_language": (
            _is_device_language,
            f"a language tag, or {DEVICE_LANGUAGE_DEFAULT!r}",
        ),
        "dont_keep_activities": (_is_on_off, "'on' or 'off'"),
        "enter_token": (
            _is_literal_token,
            "at most 200 characters of A-Z a-z 0-9 . _ ~ -",
        ),
        "expect": (_is_expectation, f"one of {sorted(EXPECTATIONS)}"),
        # WHY: a session token's JWT `exp` falls before its session's
        # `expires_at`, so an expired token in an open session needs that gap
        # waited out.
        "wait": (_is_positive_seconds, "a positive number of seconds"),
        "wait_expired": (_is_positive_seconds, "a positive number of seconds"),
        "wait_result": (_is_positive_seconds, "a positive number of seconds"),
    }
)


# WHY: these settings change the device, not the app, and a failed cell must
# still restore them or every later cell fails.
TEARDOWN = frozenset(
    {
        ("airplane", "off"),
        ("dont_keep_activities", "off"),
        # WHY: a per-app locale outlives the cell and draws every later sheet in
        # its language.
        ("device_language", DEVICE_LANGUAGE_DEFAULT),
    }
)

# WHY: a cell that could mute a real crash marker could pass through a crash, so
# this set holds only the marker the developer option produces on purpose.
TOLERABLE_CRASH_MARKERS = frozenset({"Force finishing activity"})


def _is_non_empty_str(value: Any) -> bool:
    return isinstance(value, str) and bool(value)


def _is_count(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def _is_bool(value: Any) -> bool:
    return isinstance(value, bool)


def _is_recovery(value: Any) -> bool:
    # An explicit null asserts the field is absent, which is a real assertion.
    return value is None or _is_non_empty_str(value)


def _is_mapping(value: Any) -> bool:
    return isinstance(value, dict)


#: Merchant assertions `verify.py` knows how to check, mapped to the check each
#: value must pass. A key that is absent is not asserted; a key present with a
#: null value asserts the field is absent.
_MERCHANT_VALUES = {
    "session_status": (_is_non_empty_str, "a non-empty string"),
    "txn_count": (_is_count, "a non-negative integer"),
    "txn_status": (_is_non_empty_str, "a non-empty string"),
    "no_succeeded_txn": (_is_bool, "true or false"),
    "failure_recovery": (_is_recovery, "a non-empty string or null"),
    "failure_code": (_is_recovery, "a non-empty string or null"),
    "network_decline_code": (_is_recovery, "a non-empty string or null"),
    "saved_card_saved": (_is_bool, "true or false"),
    "saved_card_used": (_is_bool, "true or false"),
    "threeds": (_is_mapping, "a mapping"),
}

MERCHANT_KEYS = frozenset(_MERCHANT_VALUES)

# WHY: `eci` and `version` are left out so that a sandbox upgrade cannot show
# up as a finding.
_THREEDS_VALUES = {
    "outcome": (_is_non_empty_str, "a non-empty string"),
    "flow": (_is_non_empty_str, "a non-empty string"),
    "liability_shifted": (_is_bool, "true or false"),
}

THREEDS_KEYS = frozenset(_THREEDS_VALUES)

EXPECTED_KEYS = frozenset({"label", "rearmed", "merchant"})

_PAN = re.compile(r"^\d{12,19}$")
_EXPIRY = re.compile(r"^(0[1-9]|1[0-2])/\d{2}$")
_CVV = re.compile(r"^\d{3,4}$")
_CURRENCY = re.compile(r"^[A-Z]{3}$")

# WHY: labels are matched whole and never split on ':', because an
# `unrecognized(<raw>)` token may itself contain colons.
LABEL_RE = re.compile(
    r"^(?:"
    r"(?:result:success"
    r"|result:failure:"
    r"(?:retry|change_method|restart|do_not_retry|contact_support"
    r"|unrecognized\(.*\))"
    r"|result:pending:"
    r"(?:poll_timeout|result_lost|server_verify"
    r"|unrecognized\(.*\))"
    r"):(?P<txn>[^\s]*)"
    r"|result:cancelled"
    r"|error:[A-Za-z]+"
    r")$"
)

ANY_LABEL = "<any>"
# WHY: on Android the process-kill cell delivers no result, so silence is its pass.
NO_LABEL = "<none>"
LABEL_SENTINELS = frozenset({ANY_LABEL, NO_LABEL})

# WHY: only ever last in a label, so `.*` cannot swallow a later field.
TXN_PLACEHOLDER = "<txn>"


class CellError(ValueError):
    """A cell file is malformed. Always names the file and what is wrong."""


@dataclass(frozen=True)
class Action:
    verb: str
    arg: str | None = None


@dataclass(frozen=True)
class Card:
    pan: str
    expiry: str
    cvv: str
    holder: str = "John Doe"

    @property
    def expiry_digits(self) -> str:
        """`12/28` as `1228` — how both card forms actually want it typed."""
        return self.expiry.replace("/", "")


@dataclass(frozen=True)
class Session:
    amount: int
    currency: str
    options: dict[str, Any]


@dataclass(frozen=True)
class Expected:
    label: str
    rearmed: bool
    merchant: dict[str, Any]


@dataclass(frozen=True)
class Cell:
    id: str
    path: Path
    platforms: tuple[str, ...]
    card: Card
    session: Session
    actions: tuple[Action, ...]
    # WHY: ignores the per-platform overrides; read a run's expectation through
    # expected_for.
    expected: Expected
    overrides: dict[str, dict[str, Any]]
    tolerated_crash_markers: tuple[str, ...] = ()

    def expected_for(self, platform: str) -> Expected:
        """Return the base expectation with this platform's overrides merged in."""
        override = self.overrides.get(platform)
        if not override:
            return self.expected
        merchant = dict(self.expected.merchant)
        merchant.update(override.get("merchant", {}))
        return Expected(
            label=override.get("label", self.expected.label),
            rearmed=override.get("rearmed", self.expected.rearmed),
            merchant=merchant,
        )


def parse_action(raw: Any, where: str) -> Action:
    if not isinstance(raw, str):
        raise CellError(f"{where}: action must be a string, got {raw!r}")
    text = raw.strip()
    parts = re.split(r"[:\s]", text, maxsplit=1)
    verb = parts[0].strip()
    arg = parts[1].strip() if len(parts) == 2 else ""

    if verb in BARE_ACTIONS:
        if arg:
            raise CellError(f"{where}: action {verb!r} takes no argument")
        return Action(verb)
    if verb in ARG_ACTIONS:
        if not arg:
            raise CellError(f"{where}: action {verb!r} needs an argument")
        accepts, description = ARG_ACTIONS[verb]
        if not accepts(arg):
            raise CellError(f"{where}: action {text!r} argument must be {description}")
        return Action(verb, arg)
    raise CellError(f"{where}: unknown action {text!r}")


def _require(mapping: Any, key: str, where: str) -> Any:
    if not isinstance(mapping, dict) or key not in mapping:
        raise CellError(f"{where}: missing {key!r}")
    return mapping[key]


def _check_label(label: Any, where: str) -> None:
    if not isinstance(label, str) or not label:
        raise CellError(f"{where}: label must be a non-empty string")
    if label in LABEL_SENTINELS:
        return
    if not LABEL_RE.fullmatch(label):
        raise CellError(f"{where}: label {label!r} is not in the frozen vocabulary")
    # WHY: checked here, not on the constructed Expected, so override labels are
    # held to it too.
    if label.count(TXN_PLACEHOLDER) > 1:
        raise CellError(
            f"{where}: label {label!r} has more than one '{TXN_PLACEHOLDER}'; "
            "the capture would be ambiguous"
        )


def _check_merchant(raw: Any, where: str) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raise CellError(f"{where}: merchant must be a mapping")
    unknown = sorted(set(raw) - MERCHANT_KEYS)
    if unknown:
        raise CellError(f"{where}: unknown merchant key(s) {unknown}")
    for key, value in raw.items():
        accepts, description = _MERCHANT_VALUES[key]
        if not accepts(value):
            raise CellError(
                f"{where}: merchant {key} must be {description}, got {value!r}"
            )

    threeds = raw.get("threeds")
    if isinstance(threeds, dict):
        unknown = sorted(set(threeds) - THREEDS_KEYS)
        if unknown:
            raise CellError(f"{where}: unknown threeds key(s) {unknown}")
        for key, value in threeds.items():
            accepts, description = _THREEDS_VALUES[key]
            if not accepts(value):
                raise CellError(
                    f"{where}: threeds {key} must be {description}, got {value!r}"
                )
    return raw


def _check_expectation(raw: Any, where: str, what: str) -> dict[str, Any]:
    """Validate one `expected` or `expected.<platform>` block."""
    if not isinstance(raw, dict):
        raise CellError(f"{where}: {what} must be a mapping")
    unknown = sorted(set(raw) - EXPECTED_KEYS)
    if unknown:
        raise CellError(f"{where}: unknown {what} key(s) {unknown}")
    if "label" in raw:
        _check_label(raw["label"], where)
    if "rearmed" in raw and not _is_bool(raw["rearmed"]):
        raise CellError(
            f"{where}: rearmed must be true or false, got {raw['rearmed']!r}"
        )
    if "merchant" in raw:
        _check_merchant(raw["merchant"], where)
    return raw


def _expected(raw: Any, where: str) -> Expected:
    # WHY: label is checked before the unknown-key sweep, so a misspelled
    # `lable:` is reported as missing.
    label = _require(raw, "label", where)
    _check_expectation(raw, where, "expected")
    return Expected(
        label=label,
        rearmed=raw.get("rearmed", False),
        merchant=raw.get("merchant", {}),
    )


def _check_cross_fields(cell: Cell, where: str) -> None:
    """Check each platform's merged expectation against the cell's actions."""
    # WHY: one action list serves every platform, so the presence rules need
    # each platform to agree.
    verbs = [(a.verb, a.arg) for a in cell.actions]
    seen = [(p, cell.expected_for(p)) for p in cell.platforms]

    for action, holds, describe in (
        (
            ("expect", "rearmed"),
            lambda e: e.rearmed,
            "expects a re-armed sheet",
        ),
    ):
        wanting = [p for p, e in seen if holds(e)]
        if wanting and action not in verbs:
            raise CellError(
                f"{where}: {wanting} {describe}, but the cell has no "
                f"{action[0]} {action[1]!r} action, so nothing would ever look"
            )
        missing = [p for p, e in seen if not holds(e)]
        if action in verbs and missing:
            raise CellError(
                f"{where}: the cell runs {action[0]} {action[1]!r} but "
                f"{missing} {describe.replace('expects', 'does not expect')}. "
                "The action list is shared by every platform, so it runs "
                "there too and answers falsy"
            )

    silent = [p for p, e in seen if e.label == NO_LABEL]
    looks_for_silence = ("expect", "no_result") in verbs
    if silent and not looks_for_silence:
        raise CellError(
            f"{where}: {silent} expects label {NO_LABEL!r}, but the cell has "
            "no expect 'no_result' action, so nothing would ever look"
        )

    waits = any(verb == "wait_result" for verb, _ in verbs)
    if silent and waits:
        raise CellError(
            f"{where}: {silent} expects label {NO_LABEL!r}, but the cell runs "
            "wait_result, which raises rather than answering None. Such a "
            "cell cannot pass either way"
        )
    # WHY: gated on looks_for_silence; ungated, it would reject cells several
    # tests use as doubles.
    speaking = [p for p, e in seen if e.label != NO_LABEL]
    if looks_for_silence and speaking and not waits:
        raise CellError(
            f"{where}: {speaking} expects a label, but the cell has no "
            "wait_result action, so nothing would ever capture one"
        )


def load_cell(path: Path) -> Cell:
    path = Path(path)
    where = str(path)
    raw = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise CellError(f"{where}: the file must contain a mapping")

    cell_id = _require(raw, "id", where)
    if cell_id != path.stem:
        raise CellError(f"{where}: id {cell_id!r} does not match the filename stem")

    raw_platforms = _require(raw, "platforms", where)
    if not isinstance(raw_platforms, list):
        raise CellError(
            f"{where}: platforms must be a list, got {type(raw_platforms).__name__}"
        )
    platforms = tuple(raw_platforms)
    bad = [p for p in platforms if p not in PLATFORMS]
    if bad or not platforms:
        raise CellError(f"{where}: unknown platform(s) {bad or '<empty>'}")
    repeated = sorted({p for p in platforms if platforms.count(p) > 1})
    if repeated:
        raise CellError(f"{where}: duplicate platform(s) {repeated}")

    raw_card = _require(raw, "card", where)
    card = Card(
        pan=str(_require(raw_card, "pan", where)),
        expiry=str(_require(raw_card, "expiry", where)),
        cvv=str(_require(raw_card, "cvv", where)),
        holder=str(raw_card.get("holder", "John Doe")),
    )
    if not _PAN.match(card.pan):
        raise CellError(f"{where}: pan must be 12-19 digits")
    if not _EXPIRY.match(card.expiry):
        raise CellError(f"{where}: expiry must be MM/YY")
    if not _CVV.match(card.cvv):
        raise CellError(f"{where}: cvv must be 3-4 digits")

    raw_session = _require(raw, "session", where)
    amount = _require(raw_session, "amount", where)
    currency = str(_require(raw_session, "currency", where))
    if not isinstance(amount, int) or amount <= 0:
        raise CellError(f"{where}: amount must be a positive integer of minor units")
    if not _CURRENCY.match(currency):
        raise CellError(f"{where}: currency must be an upper-case ISO 4217 code")
    options = raw_session.get("options") or {}
    if not isinstance(options, dict):
        raise CellError(f"{where}: session options must be a mapping")

    raw_actions = _require(raw, "actions", where)
    if not isinstance(raw_actions, list) or not raw_actions:
        raise CellError(f"{where}: actions must be a non-empty list")

    expected = _expected(_require(raw, "expected", where), where)

    # WHY: refused at load, before a device is touched, so no cell can be
    # excused a crash it must not pass.
    tolerated = raw.get("tolerated_crash_markers") or []
    if not isinstance(tolerated, list):
        raise CellError(f"{where}: tolerated_crash_markers must be a list")
    unknown = sorted(set(map(str, tolerated)) - TOLERABLE_CRASH_MARKERS)
    if unknown:
        raise CellError(
            f"{where}: tolerated_crash_markers {unknown} is not tolerable; only "
            f"{sorted(TOLERABLE_CRASH_MARKERS)} may be declared"
        )

    overrides = {}
    for platform in PLATFORMS:
        override = raw.get(f"expected.{platform}")
        if override is None:
            continue
        if platform not in platforms:
            # WHY: expected_for is only asked about declared platforms, so this
            # override would never be read.
            raise CellError(
                f"{where}: expected.{platform} but the cell does not run on "
                f"{platform!r}; platforms are {list(platforms)}"
            )
        overrides[platform] = _check_expectation(
            override, where, f"expected.{platform}"
        )

    cell = Cell(
        id=cell_id,
        path=path,
        platforms=platforms,
        card=card,
        session=Session(amount=amount, currency=currency, options=options),
        actions=tuple(parse_action(a, where) for a in raw_actions),
        expected=expected,
        overrides=overrides,
        tolerated_crash_markers=tuple(map(str, tolerated)),
    )
    # WHY: the cross-field rules read expected_for, which needs the whole cell.
    _check_cross_fields(cell, where)
    return cell


def load_cells(directory: Path, platform: str) -> list[Cell]:
    """Every cell in `directory` that runs on `platform`, in filename order."""
    if platform not in PLATFORMS:
        raise CellError(f"unknown platform {platform!r}")
    directory = Path(directory)
    if not directory.is_dir():
        raise CellError(f"{directory}: no such cell directory")
    paths = sorted(directory.glob("*.yaml"))
    if not paths:
        raise CellError(
            f"{directory}: contains no *.yaml cells. The glob is not recursive, "
            "so point at a dimension directory such as cells/d0, not at cells/."
        )
    return [c for c in (load_cell(p) for p in paths) if platform in c.platforms]
