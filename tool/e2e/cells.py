"""Cell files: the declarative unit the matrix runner executes.

A cell is one payment attempt and everything that has to be true about it.
Keeping the vocabulary small and validated is what stops a typo in a YAML file
from being read as an SDK finding six phases from now.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
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

#: Verbs that require one argument, written `verb:arg` or `verb arg`.
ARG_ACTIONS = frozenset({"acs", "background", "airplane", "wait_result", "expect"})

#: Merchant assertions `verify.py` knows how to check. A key that is absent is
#: not asserted; a key present with a null value asserts the field is absent.
MERCHANT_KEYS = frozenset(
    {
        "session_status",
        "txn_count",
        "txn_status",
        "no_succeeded_txn",
        "failure_recovery",
        "threeds",
    }
)

_PAN = re.compile(r"^\d{12,19}$")
_EXPIRY = re.compile(r"^(0[1-9]|1[0-2])/\d{2}$")
_CVV = re.compile(r"^\d{3,4}$")
_CURRENCY = re.compile(r"^[A-Z]{3}$")


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
    expected: Expected
    overrides: dict[str, dict[str, Any]]

    def expected_for(self, platform: str) -> Expected:
        """The base expectation with this platform's overrides merged in.

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
            rearmed=bool(override.get("rearmed", self.expected.rearmed)),
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
        return Action(verb, arg)
    raise CellError(f"{where}: unknown action {text!r}")


def _require(mapping: Any, key: str, where: str) -> Any:
    if not isinstance(mapping, dict) or key not in mapping:
        raise CellError(f"{where}: missing {key!r}")
    return mapping[key]


def _expected(raw: Any, where: str) -> Expected:
    label = _require(raw, "label", where)
    if not isinstance(label, str) or not label:
        raise CellError(f"{where}: label must be a non-empty string")
    merchant = raw.get("merchant", {})
    if not isinstance(merchant, dict):
        raise CellError(f"{where}: merchant must be a mapping")
    unknown = sorted(set(merchant) - MERCHANT_KEYS)
    if unknown:
        raise CellError(f"{where}: unknown merchant key(s) {unknown}")
    return Expected(label=label, rearmed=bool(raw.get("rearmed", False)), merchant=merchant)


def load_cell(path: Path) -> Cell:
    path = Path(path)
    where = path.name
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

    overrides = {}
    for platform in PLATFORMS:
        override = raw.get(f"expected.{platform}")
        if override is not None:
            if not isinstance(override, dict):
                raise CellError(f"{where}: expected.{platform} must be a mapping")
            unknown = sorted(set(override.get("merchant", {})) - MERCHANT_KEYS)
            if unknown:
                raise CellError(f"{where}: unknown merchant key(s) {unknown}")
            overrides[platform] = override

    return Cell(
        id=cell_id,
        path=path,
        platforms=platforms,
        card=card,
        session=Session(amount=amount, currency=currency, options=options),
        actions=tuple(parse_action(a, where) for a in raw_actions),
        expected=_expected(_require(raw, "expected", where), where),
        overrides=overrides,
    )


def load_cells(directory: Path, platform: str) -> list[Cell]:
    """Every cell in `directory` that runs on `platform`, in filename order."""
    if platform not in PLATFORMS:
        raise CellError(f"unknown platform {platform!r}")
    loaded = [load_cell(p) for p in sorted(Path(directory).glob("*.yaml"))]
    return [c for c in loaded if platform in c.platforms]
