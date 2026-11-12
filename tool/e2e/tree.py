"""Normalises the uiautomator and WebDriverAgent dumps into one Node shape."""

from __future__ import annotations

import re
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from decimal import Decimal

#: Labels the example app renders under --dart-define=PAYCROSS_E2E.
LABEL_PREFIXES = ("result:", "error:")

#: Labels of a build made without the define; a dump with only these is a wrong build.
LEGACY_LABEL_PREFIXES = (
    "Paid ",
    "Declined",
    "Cancelled",
    "Outcome unknown",
    "Integration error",
)

#: Identifiers both SDKs publish. paycross.payButton is left out: iOS does not
#: publish it.
ERROR_BANNER = "paycross.errorBanner"
AMOUNT = "paycross.amount"

FRENCH_PAY_VERB = "Payer"

_BOUNDS = re.compile(r"\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]")
_CURRENCY_SYMBOLS = {"EUR": "€", "USD": "$", "GBP": "£"}

#: Switch state in WDA's `value`; any other value reads None, not False.
_SWITCH_STATE = {"0": False, "1": True}


@dataclass(frozen=True)
class Node:
    type: str
    text: str
    content_desc: str
    identifier: str
    value: str
    bounds: tuple[int, int, int, int]
    # Android: a non-empty box, not on screen. iOS: WDA's own flag.
    visible: bool
    #: None where this node is not a two-state control.
    checked: bool | None = None

    @property
    def centre(self) -> tuple[int, int]:
        x1, y1, x2, y2 = self.bounds
        return ((x1 + x2) // 2, (y1 + y2) // 2)


def parse_uiautomator(xml: str | bytes) -> list[Node]:
    nodes: list[Node] = []
    for element in ET.fromstring(xml).iter("node"):
        match = _BOUNDS.match(element.get("bounds", ""))
        x1, y1, x2, y2 = map(int, match.groups()) if match else (0, 0, 0, 0)
        nodes.append(
            Node(
                type=element.get("class", ""),
                text=element.get("text", ""),
                content_desc=element.get("content-desc", ""),
                identifier=element.get("resource-id", ""),
                value="",
                bounds=(x1, y1, x2, y2),
                # uiautomator has no `visible` attribute.
                visible=x2 > x1 and y2 > y1,
                # WHY: uiautomator writes checked on every node; only checkable ones
                # have a state.
                checked=(
                    element.get("checked") == "true"
                    if element.get("checkable") == "true"
                    else None
                ),
            )
        )
    return nodes


def parse_wda(xml: str | bytes) -> list[Node]:
    nodes: list[Node] = []
    for element in ET.fromstring(xml).iter():
        x = int(float(element.get("x", 0)))
        y = int(float(element.get("y", 0)))
        width = int(float(element.get("width", 0)))
        height = int(float(element.get("height", 0)))
        label = element.get("label", "")
        nodes.append(
            Node(
                type=element.get("type", element.tag).removeprefix("XCUIElementType"),
                text=label,
                # WDA has no separate content description: the label is both.
                content_desc=label,
                # name is the accessibilityIdentifier, or the label when none is set.
                identifier=element.get("name", ""),
                value=element.get("value", ""),
                bounds=(x, y, x + width, y + height),
                visible=element.get("visible") == "true",
                # Only the two literals a switch uses: value also carries ordinary text.
                checked=_SWITCH_STATE.get(element.get("value")),
            )
        )
    return nodes


def find_text_exact(nodes: list[Node], text: str) -> list[Node]:
    """Exact match on `text`, not a substring: `timeout` is inside `authentication_timeout`."""
    return [n for n in nodes if n.text == text]


def find_content_desc(nodes: list[Node], content_desc: str) -> list[Node]:
    return [n for n in nodes if n.content_desc == content_desc]


def find_identifier(nodes: list[Node], identifier: str) -> list[Node]:
    return [n for n in nodes if n.identifier == identifier]


def caption(nodes: list[Node], control: Node) -> str:
    """The control's own label, or else the first labelled node inside its box."""
    own = control.text or control.content_desc
    if own:
        return own
    at = _position_of(nodes, control)
    x1, y1, x2, y2 = control.bounds
    for node in nodes[at + 1 :]:
        nx1, ny1, nx2, ny2 = node.bounds
        if nx2 <= nx1 or ny2 <= ny1:
            continue
        if not (nx1 >= x1 and ny1 >= y1 and nx2 <= x2 and ny2 <= y2):
            break
        text = node.text or node.content_desc
        if text:
            return text
    return ""


def _position_of(nodes: list[Node], control: Node) -> int:
    """Index of `control` in `nodes`, by identity, then by value; len(nodes) if absent."""
    for index, node in enumerate(nodes):
        if node is control:
            return index
    for index, node in enumerate(nodes):
        if node == control:
            return index
    return len(nodes)


def label_from_tree(
    nodes: list[Node], prefixes: tuple[str, ...] = LABEL_PREFIXES
) -> str | None:
    """The example app's outcome string: Android's content-desc, or iOS's label."""
    for node in nodes:
        candidate = node.content_desc or node.text
        if candidate.startswith(prefixes):
            return candidate
    return None


def format_amount_en_us(minor_units: int, currency: str) -> str:
    """en-US NumberFormat spelling with two minor digits; a French sheet does not match it."""
    body = f"{Decimal(minor_units) / 100:,.2f}"
    symbol = _CURRENCY_SYMBOLS.get(currency)
    return f"{symbol}{body}" if symbol else f"{currency} {body}"


#: What may not follow a matched amount: a longer number is not the same amount.
_AMOUNT_CONTINUES = frozenset(".,0123456789")


def _digits(text: str) -> str:
    return "".join(character for character in text if character.isdigit())


def _carries_amount(text: str, amount_text: str) -> bool:
    """`amount_text` is in `text` and is not the head of a longer number."""
    for variant in _separator_variants(amount_text):
        at = text.find(variant)
        while at >= 0:
            after = text[at + len(variant) : at + len(variant) + 1]
            if after not in _AMOUNT_CONTINUES:
                return True
            at = text.find(variant, at + 1)
    return False


def _separator_variants(amount_text: str) -> tuple[str, ...]:
    """`amount_text` and its `.`/`,` swap; stripping separators would match longer numbers."""
    swapped = amount_text.translate(str.maketrans(".,", ",."))
    return (amount_text,) if swapped == amount_text else (amount_text, swapped)


def sheet_rearmed(nodes: list[Node], amount_text: str) -> bool:
    """Whether the error banner and this cell's amount are both on the sheet."""
    if not amount_text:
        # An empty string is in every label, so this would match any sheet.
        raise ValueError("sheet_rearmed needs the cell's amount text")
    return bool(
        find_identifier(nodes, ERROR_BANNER)
        and any(
            _carries_amount(node.text, amount_text)
            for node in find_identifier(nodes, AMOUNT)
        )
    )


def rearm_amount_mismatch(nodes: list[Node], amount_text: str) -> str | None:
    """The sheet's amount text when it is the same value spelled differently, else None."""
    if not amount_text:
        raise ValueError("rearm_amount_mismatch needs the cell's amount text")
    if not find_identifier(nodes, ERROR_BANNER):
        return None
    showing = find_identifier(nodes, AMOUNT)
    if not showing or any(_carries_amount(n.text, amount_text) for n in showing):
        return None
    # Same digits, other spelling is the rig's fault; other digits is a cell verdict.
    wanted = _digits(amount_text)
    same_value = [n for n in showing if _digits(n.text) == wanted]
    return same_value[0].text if same_value else None
