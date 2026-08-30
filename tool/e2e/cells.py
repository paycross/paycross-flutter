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
        # Enters the minted token and taps the example's Pay WITHOUT waiting
        # for a sheet. For the cells where no sheet is the expected answer:
        # on iOS a malformed or expired token is refused at
        # PaymentSheet.swift:42-51, before `present` on line 65, so waiting
        # for one costs a 60 s timeout and reports the wrong failure.
        "present_token",
        "tap_example_pay",
        "relaunch",
        "type_card",
        "type_cvv",
        "tap_pay",
        "tap_google_pay",
        "select_saved_card",
        "save_card",
        "cancel_challenge",
        "cancel_form",
        "rotate",
        "kill_activity",
    }
)

#: What `expect` can be asked to observe. Every one of these is a
#: *non-result*: something true of the screen or of the merchant state that
#: Dart is never told about.
EXPECTATIONS = frozenset(
    {
        "rearmed",
        "no_result",
        # Waits for the sandbox ACS page without tapping an outcome, which is
        # what `acs:<outcome>` would do. The cell that cuts the network during
        # a challenge has to observe the page and then leave it alone.
        "acs",
        "google_pay",
        "no_google_pay",
        "saved_card",
    }
)

#: A literal a cell may type into the token field. Two constraints, each for
#: its own reason.
#:
#: The 200-character cap is far below the ~1011 of a real session token, so
#: a live credential cannot be committed in a cell file even by accident.
#:
#: The character class is base64url plus a dot -- the alphabet a token would
#: have been made of anyway -- because `AndroidDriver._input_text` hands this
#: string to `input text` on a device shell that re-splits and expands
#: whatever it is given. A `$`, a backtick, a quote or a pipe would be
#: mangled rather than typed, and the cell would then be measuring a string
#: it never sent. Narrowing the grammar beats quoting at the call site: the
#: grammar is what a cell author reads, and a rejected literal is a better
#: answer than a silently rewritten one.
_LITERAL_TOKEN = re.compile(r"[A-Za-z0-9._~-]{1,200}")


#: Every button the sandbox's challenge page renders, which is what
#: `acs:<outcome>` taps. Three groups, not two: `internal/challenge/render.go`
#: builds `authOutcomes`, `issuerOutcomes` AND `technicalOutcomes`, and
#: `assets/challenge.html.tmpl:142-153` renders each of them as
#: `<button data-outcome="{{.}}">{{.}}</button>` -- so the visible text a
#: driver taps is the token verbatim, and every token here is reachable.
#: Values from `internal/sandboxcore/outcome.go` on payment-sandbox
#: `origin/main` (read 2026-08-31; the local working tree runs behind).
#:
#: A membership check rather than the shape check this used to be. `[a-z_]+`
#: accepts `card_expird`, which authors cleanly, reaches a device, and then
#: spends the full 120-second ACS page wait before failing on text that
#: nothing renders -- a live cell burned on a typo. Membership costs nothing
#: and answers at load time.
#:
#: Kept as a literal rather than fetched: the runner has no access to the Go
#: repo, and a list that could not be read would fail closed on a legal cell.
#: A sandbox that adds a button is a one-line change here, and one that
#: REMOVES one shows up as a live cell failing rather than as a false pass.
ACS_OUTCOMES = frozenset(
    {
        # authOutcomes
        "approve",
        "authentication_failed",
        "authentication_rejected",
        "authentication_abandoned",
        "authentication_timeout",
        "authentication_required",
        # issuerOutcomes
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
        # technicalOutcomes
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
    """One of the buttons the sandbox's challenge page actually renders."""
    return arg in ACS_OUTCOMES


def _is_positive_seconds(arg: str) -> bool:
    try:
        seconds = float(arg)
    except ValueError:
        return False
    # `inf` parses as a float and would hang the run rather than time it out.
    return math.isfinite(seconds) and seconds > 0


def _is_on_off(arg: str) -> bool:
    return arg in ("on", "off")


def _is_expectation(arg: str) -> bool:
    return arg in EXPECTATIONS


def _is_literal_token(arg: str) -> bool:
    return bool(_LITERAL_TOKEN.fullmatch(arg))


#: Verbs that require one argument, written `verb:arg` or `verb arg`, each
#: mapped to the check its argument must pass and how to describe a failure.
#: A mapping rather than a set so the argument grammar lives next to the verb;
#: `verb in ARG_ACTIONS` still reads as membership.
ARG_ACTIONS = MappingProxyType(
    {
        # The whole list, not a description of it: this message is read by
        # whoever mistyped an outcome, and the answer they need is which
        # token to write instead.
        "acs": (_is_acs_outcome, f"one of {sorted(ACS_OUTCOMES)}"),
        "airplane": (_is_on_off, "'on' or 'off'"),
        "background": (_is_positive_seconds, "a positive number of seconds"),
        "dont_keep_activities": (_is_on_off, "'on' or 'off'"),
        "enter_token": (
            _is_literal_token,
            "at most 200 characters of A-Z a-z 0-9 . _ ~ -",
        ),
        "expect": (_is_expectation, f"one of {sorted(EXPECTATIONS)}"),
        # Spends time and nothing else. There is exactly one reason a cell
        # needs this and it is not slowness: a session token's JWT `exp` is
        # mint + 900 s while its session's `expires_at` is mint + 1200 s
        # (session_ttl + session_grace_period, both env-overridable), so the
        # only way to present a token that is expired while its session is
        # still open is to wait out the difference. `cell_rules` refuses it
        # anywhere else.
        "wait": (_is_positive_seconds, "a positive number of seconds"),
        "wait_expired": (_is_positive_seconds, "a positive number of seconds"),
        "wait_result": (_is_positive_seconds, "a positive number of seconds"),
    }
)


#: Rig settings a cell may change, each paired with the action that puts it
#: back. Neither is undone by the end of a cell, by a failure or by an
#: exception: they change the DEVICE rather than the app, and left on they
#: fail every cell that follows -- including the interleaved control, so the
#: run aborts as a rig fault two cells later.
#:
#: Read by two places that have to agree. `tests/cell_rules` refuses a cell
#: that turns one on without declaring the off, and lets only these follow the
#: action that reads the outcome; `runner` replays the off when a cell dies
#: before reaching it. Here rather than beside the authoring rules because the
#: runner cannot import from the test tree, and because which settings outlive
#: a cell is a fact about the grammar rather than about how cells are written.
TEARDOWN = frozenset({("airplane", "off"), ("dont_keep_activities", "off")})


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
    "failure_code": (_is_recovery, "a non-empty string or null"),
    "network_decline_code": (_is_recovery, "a non-empty string or null"),
    "saved_card_saved": (_is_bool, "true or false"),
    "saved_card_used": (_is_bool, "true or false"),
    "threeds": (_is_mapping, "a mapping"),
}

MERCHANT_KEYS = frozenset(_MERCHANT_VALUES)

#: The 3-D Secure fields a cell may assert. `eci` and `version` are
#: deliberately absent: they are sandbox implementation detail, and a sandbox
#: upgrade must not present as a finding.
_THREEDS_VALUES = {
    "outcome": (_is_non_empty_str, "a non-empty string"),
    "flow": (_is_non_empty_str, "a non-empty string"),
    "liability_shifted": (_is_bool, "true or false"),
}

THREEDS_KEYS = frozenset(_THREEDS_VALUES)

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
LABEL_RE = re.compile(
    r"^(result:success:[^\s]*"
    r"|result:failure:"
    r"(retry|change_method|restart|do_not_retry|contact_support|unrecognized\(.*\))"
    r":[^\s]*"
    r"|result:cancelled"
    r"|error:[A-Za-z]+)$"
)

#: Expectations that are not a literal label.
#:
#: `<any>` is a discovery cell's expectation: any well-formed contract label,
#: whatever it turns out to be. It asserts the three things the spec asks of
#: D2's (b)-(d) -- a terminal outcome, exactly once, no crash -- and nothing
#: about which one. Phase 3 replaces it with the label the run measured, so
#: the final matrix asserts rather than records.
#:
#: `<none>` is the opposite: no label may appear. It exists for the Android
#: process-kill cell, where the pending Dart call dies with the isolate and
#: no result is delivered BY DESIGN, so "the app said nothing" is the pass.
ANY_LABEL = "<any>"
NO_LABEL = "<none>"
LABEL_SENTINELS = frozenset({ANY_LABEL, NO_LABEL})

#: Only ever appears last in a label, so `.*` cannot swallow a later field.
#: Lives here rather than in `verify` because `load_cell` refuses a template
#: carrying two of them -- an ambiguous capture -- and `verify` already
#: imports this module for `LABEL_RE`.
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
    #: The *unmerged* base expectation. Do not read this to decide whether a
    #: run passed -- it ignores `expected.android` / `expected.ios`, so on any
    #: cell carrying an override it is the wrong answer for at least one
    #: platform. Call `expected_for(platform)` instead.
    expected: Expected
    overrides: dict[str, dict[str, Any]]

    def expected_for(self, platform: str) -> Expected:
        """The base expectation with this platform's overrides merged in.

        This is the only correct way to read a cell's expectations.

        Merged one key deep rather than replaced wholesale: where the
        platforms diverge they diverge in one merchant field at a time, and
        restating the other five in every override is how they drift apart.

        No shipped cell has an override, D2 included. The mechanism was
        added for a divergence in `failure.recovery` that the live runs
        disproved -- both platforms answer `change_method` for
        authentication_failed -- so this path has unit coverage and no live
        coverage. D2 was expected to be its first real user and is not: where
        the platforms may diverge it records the label per platform (`<any>`)
        rather than asserting two different ones, which is what a dimension
        does before anything has measured it. An override lands in Phase 3 if
        a live run shows one is needed.
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
    # Whichever delimiter comes first, so `verb arg` and `verb:arg` are one
    # grammar rather than two with a precedence rule between them. The old
    # colon-first split misparsed `wait_result 1:20` as the verb
    # `wait_result 1` and reported an unknown action -- a diagnosis that
    # sends the reader after the wrong half of the line.
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
    # Here rather than beside the constructed `Expected`, so an override's
    # label is held to it as well: `match_label`'s capture is exactly as
    # ambiguous either way.
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


def _check_cross_fields(cell: Cell, where: str) -> None:
    """Rules that relate an expectation to the actions, per platform.

    Over every platform the cell declares, never the unmerged base. A cell
    whose base says `rearmed: false` and whose `expected.android` says true
    would otherwise load cleanly and fail on a device twenty minutes later --
    and D2 is the dimension that would find out, being the first with cells
    whose two platforms are expected to answer differently.

    The two directions are deliberately asymmetric, because **one action list
    is shared by every platform the cell runs on**. Any platform expecting a
    re-armed sheet needs the action. The action being present needs *every*
    platform to expect one -- it runs unconditionally, so on a platform where
    the sheet resolves terminally instead it answers falsy and fails the
    cell.

    That forecloses one shape on purpose: "Android re-arms, iOS resolves
    terminally" cannot be one cell and must be split into two single-platform
    ones. Such a pair differs in more than the expectation anyway -- the
    terminal variant has no `cancel_form` to reach a label with -- and it is
    exactly the shape sub-project #2 will produce as it fixes one platform
    before the other.

    `no_result` used to be checked as that same pair and is not, because the
    two directions turned out to be asking about different things. What the
    label expectation describes is the LAST `wait_result`; `expect no_result`
    is a separate assertion about a moment that may come after it. Requiring
    every platform to expect `<none>` merely because the cell looks for an
    absence somewhere forbade the two-phase shape `session_expired_server`
    needs -- cancel, capture `result:cancelled`, then re-present a dead
    session and prove nothing resolves.

    What replaces it is the rule that was really wanted, stated over
    `wait_result` instead of over the action that looks:

    * `wait_result` is the only action that sets a label, so any expectation
      that is not `<none>` needs one, or the cell reaches its verdict with
      `label` still None and fails on a device.
    * `wait_result` RAISES when no label arrives, so a cell expecting
      `<none>` must not hold one -- with it the cell cannot pass either way,
      failing in the driver if the label is absent and on the expectation if
      it is not.

    Together those still catch the divergence the old pair was aimed at: a
    cell where one platform expects `<none>` and another expects a literal
    demands both the presence and the absence of a `wait_result`, so one of
    the two rules fires. And nothing passes silently, because `expect
    no_result` carries its own verdict at run time whatever the label says.
    """
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
    # Gated on the absence check being present, which keeps this exactly as
    # wide as the rule it replaces. The invariant is true of every cell --
    # only `wait_result` sets a label -- but stated unconditionally it also
    # rejects a cell built to fail before the verdict is ever reached, and
    # several tests use one of those as a double. Widening it is a separate
    # change with its own fixtures to fix.
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
            # A bare string iterates into characters, and every one of them is
            # an unknown platform -- a message about 'a', 'n', 'd'.
        )
    platforms = tuple(raw_platforms)
    bad = [p for p in platforms if p not in PLATFORMS]
    if bad or not platforms:
        raise CellError(f"{where}: unknown platform(s) {bad or '<empty>'}")
    repeated = sorted({p for p in platforms if platforms.count(p) > 1})
    if repeated:
        # The cell still runs once, but every per-platform loop counts it
        # twice -- including the cross-field rules, which would then name the
        # same platform twice in one message.
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

    overrides = {}
    for platform in PLATFORMS:
        override = raw.get(f"expected.{platform}")
        if override is None:
            continue
        if platform not in platforms:
            # Silently dead otherwise: `expected_for` is only ever asked about
            # a platform the cell declares, so this block would never be read
            # and the cell would run asserting the base it was written to
            # override.
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
    )
    # After construction rather than inline above: these rules read
    # `expected_for(platform)`, which needs the whole cell.
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
