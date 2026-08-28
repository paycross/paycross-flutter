"""Cell files: the declarative unit the matrix runner executes.

A cell is one payment attempt and everything that has to be true about it.
Keeping the vocabulary small and validated is what stops a typo in a YAML file
from being read as an SDK finding six phases from now. Everything a cell can
say is checked at load time -- verbs, their arguments, the result label, and
every merchant value -- so a malformed cell fails before a device is touched
rather than halfway through a matrix run.

Read expectations through `Cell.expected_for(platform)`, never through
`Cell.expected`: the latter is the unmerged base and is wrong for any cell that
carries an `expected.android` / `expected.ios` override.
"""

from __future__ import annotations

import math
import re
from dataclasses import dataclass
from pathlib import Path
from types import MappingProxyType
from typing import Any

import yaml

PLATFORMS = ("android", "ios")

#: Verbs that take no argument.
BARE_ACTIONS = frozenset(
    {
        "paste_token",
        "type_card",
        "tap_pay",
        "cancel_challenge",
        "cancel_form",
        "rotate",
        "kill_activity",
    }
)


def _is_acs_outcome(arg: str) -> bool:
    """The sandbox ACS buttons are all lower-case snake tokens."""
    return bool(re.fullmatch(r"[a-z_]+", arg))


def _is_positive_seconds(arg: str) -> bool:
    try:
        seconds = float(arg)
    except ValueError:
        return False
    # `inf` parses as a float and would hang the run rather than time it out.
    return math.isfinite(seconds) and seconds > 0


def _is_on_off(arg: str) -> bool:
    return arg in ("on", "off")


def _is_rearmed(arg: str) -> bool:
    return arg == "rearmed"


#: Verbs that require one argument, written `verb:arg` or `verb arg`, each
#: mapped to the check its argument must pass and how to describe a failure.
#: A mapping rather than a set so the argument grammar lives next to the verb;
#: `verb in ARG_ACTIONS` still reads as membership.
ARG_ACTIONS = MappingProxyType(
    {
        "acs": (_is_acs_outcome, "a lower-case ACS outcome token"),
        "airplane": (_is_on_off, "'on' or 'off'"),
        "background": (_is_positive_seconds, "a positive number of seconds"),
        "expect": (_is_rearmed, "'rearmed'"),
        "wait_result": (_is_positive_seconds, "a positive number of seconds"),
    }
)


def _is_non_empty_str(value: Any) -> bool:
    return isinstance(value, str) and bool(value)


def _is_count(value: Any) -> bool:
    # bool is a subclass of int; `txn_count: true` is a typo, not a count.
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
    "threeds": (_is_mapping, "a mapping"),
}

MERCHANT_KEYS = frozenset(_MERCHANT_VALUES)

#: The keys an `expected` or `expected.<platform>` block may carry.
EXPECTED_KEYS = frozenset({"label", "rearmed", "merchant"})

_PAN = re.compile(r"^\d{12,19}$")
_EXPIRY = re.compile(r"^(0[1-9]|1[0-2])/\d{2}$")
_CVV = re.compile(r"^\d{3,4}$")
_CURRENCY = re.compile(r"^[A-Z]{3}$")

#: The label vocabulary the example app froze in Task 1. Labels are matched
#: whole and never split on ':' -- an `unrecognized(<raw>)` token may itself
#: contain colons. An empty `<txn>` is allowed; the app emits one when the
#: session never reached a transaction.
_LABEL = re.compile(
    r"^(result:success:[^\s]*"
    r"|result:failure:"
    r"(retry|change_method|restart|do_not_retry|contact_support|unrecognized\(.*\))"
    r":[^\s]*"
    r"|result:cancelled"
    r"|error:[A-Za-z]+)$"
)


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
    #: The *unmerged* base expectation. Do not read this to decide whether a
    #: run passed -- it ignores `expected.android` / `expected.ios`, so on any
    #: cell carrying an override it is the wrong answer for at least one
    #: platform. Call `expected_for(platform)` instead.
    expected: Expected
    overrides: dict[str, dict[str, Any]]

    def expected_for(self, platform: str) -> Expected:
        """The base expectation with this platform's overrides merged in.

        This is the only correct way to read a cell's expectations.

        Merged one key deep rather than replaced wholesale: the platforms
        differ in one merchant field at a time (the sandbox returns a
        different `failure.recovery` for the same ACS outcome), and restating
        the other five in every override is how they drift apart.
        """
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
    verb, _, arg = text.partition(":") if ":" in text else text.partition(" ")
    verb, arg = verb.strip(), arg.strip()

    if verb in BARE_ACTIONS:
        if arg:
            raise CellError(f"{where}: action {verb!r} takes no argument")
        return Action(verb)
    if verb in ARG_ACTIONS:
        if not arg:
            raise CellError(f"{where}: action {verb!r} needs an argument")
        accepts, description = ARG_ACTIONS[verb]
        if not accepts(arg):
            raise CellError(
                f"{where}: action {text!r} argument must be {description}"
            )
        return Action(verb, arg)
    raise CellError(f"{where}: unknown action {text!r}")


def _require(mapping: Any, key: str, where: str) -> Any:
    if not isinstance(mapping, dict) or key not in mapping:
        raise CellError(f"{where}: missing {key!r}")
    return mapping[key]


def _check_label(label: Any, where: str) -> None:
    if not isinstance(label, str) or not label:
        raise CellError(f"{where}: label must be a non-empty string")
    if not _LABEL.fullmatch(label):
        raise CellError(f"{where}: label {label!r} is not in the frozen vocabulary")


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
    return raw


def _check_expectation(raw: Any, where: str, what: str) -> dict[str, Any]:
    """Validate one `expected` or `expected.<platform>` block.

    Shared by the base and the overrides so the two cannot drift into
    accepting different things.
    """
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
    # `label` is required, and its absence is reported before the unknown-key
    # sweep so that a misspelled `lable:` names the key the cell actually needs.
    label = _require(raw, "label", where)
    _check_expectation(raw, where, "expected")
    return Expected(
        label=label,
        rearmed=raw.get("rearmed", False),
        merchant=raw.get("merchant", {}),
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

    platforms = tuple(_require(raw, "platforms", where))
    bad = [p for p in platforms if p not in PLATFORMS]
    if bad or not platforms:
        raise CellError(f"{where}: unknown platform(s) {bad or '<empty>'}")

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

    overrides = {}
    for platform in PLATFORMS:
        override = raw.get(f"expected.{platform}")
        if override is not None:
            overrides[platform] = _check_expectation(
                override, where, f"expected.{platform}"
            )

    return Cell(
        id=cell_id,
        path=path,
        platforms=platforms,
        card=card,
        session=Session(amount=amount, currency=currency, options=options),
        actions=tuple(parse_action(a, where) for a in raw_actions),
        expected=expected,
        overrides=overrides,
    )


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
