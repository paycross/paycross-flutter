"""One node shape for two very different accessibility dumps.

Android's `uiautomator dump` and iOS's WebDriverAgent `GET /source` describe
the same idea in different vocabularies. Normalising here means every matcher
above this layer is written once, and the platform differences are visible in
exactly one table instead of being spread through the drivers.
"""

from __future__ import annotations

import re
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from decimal import Decimal

#: The label vocabulary the example app renders under --dart-define=PAYCROSS_E2E.
LABEL_PREFIXES = ("result:", "error:")

#: Also matched, so a dump taken from a build *without* the define is diagnosed
#: as "wrong build" rather than as "no result" after a 120-second wait.
LEGACY_LABEL_PREFIXES = (
    "Paid ",
    "Declined",
    "Cancelled",
    "Outcome unknown",
    "Integration error",
)

#: `PaymentViewModel.kt:244,269,393`. Identical after any non-cancel submit
#: failure, so on its own it does not mean "retryable decline" -- pass criterion
#: 2's merchant check is what separates those.
ANDROID_REARM_BANNER = "Payment failed. Please try again."

_BOUNDS = re.compile(r"\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]")
_CURRENCY_SYMBOLS = {"EUR": "€", "USD": "$", "GBP": "£"}


@dataclass(frozen=True)
class Node:
    type: str
    text: str
    content_desc: str
    identifier: str
    value: str
    bounds: tuple[int, int, int, int]
    # Android: derived from the bounds area -- "has a box", not "on screen".
    # iOS: WDA's own attribute, so an absent one reads False.
    visible: bool

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
                # uiautomator has no `visible` attribute; a degenerate box is
                # the only thing it can mean here.
                visible=x2 > x1 and y2 > y1,
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
                # `name` is the accessibilityIdentifier when one is set and
                # falls back to the label when it is not, which is exactly the
                # handle the SDK's identifiers give us.
                identifier=element.get("name", ""),
                value=element.get("value", ""),
                bounds=(x, y, x + width, y + height),
                visible=element.get("visible") == "true",
            )
        )
    return nodes


def find_text_exact(nodes: list[Node], text: str) -> list[Node]:
    """Exact match on `text`, which is what separates the Android Pay button.

    The header renders a bare `€10.00` node and the Google Pay row carries
    `content-desc="Pay with GPay"`, so a substring or all-attribute match hits
    three nodes where one is meant.
    """
    return [n for n in nodes if n.text == text]


def find_content_desc(nodes: list[Node], content_desc: str) -> list[Node]:
    return [n for n in nodes if n.content_desc == content_desc]


def find_identifier(nodes: list[Node], identifier: str) -> list[Node]:
    return [n for n in nodes if n.identifier == identifier]


def label_from_tree(
    nodes: list[Node], prefixes: tuple[str, ...] = LABEL_PREFIXES
) -> str | None:
    """The example app's outcome string, wherever this platform puts it.

    Android surfaces a Flutter `Text` as `content-desc` with an empty `text`;
    iOS surfaces it as the node's label. Reading `content_desc or text` covers
    both without a platform branch.
    """
    for node in nodes:
        candidate = node.content_desc or node.text
        if candidate.startswith(prefixes):
            return candidate
    return None


def format_amount_en_us(minor_units: int, currency: str) -> str:
    """What `NumberFormat.getCurrencyInstance` renders under `en-US`.

    Computed rather than hardcoded because the Android Pay button's text is
    the only handle the SDK offers -- it tags nothing -- so the matcher has to
    track the cell's amount. The driver pins the emulator locale to `en-US`;
    a different locale is a rig fault, not a cell failure.

    Two minor digits are assumed, which is right for EUR/USD-style currencies
    and wrong for JPY. `cells.py` constrains a cell to positive integer minor
    units and an ISO 4217 code, not to that subset.
    """
    body = f"{Decimal(minor_units) / 100:,.2f}"
    symbol = _CURRENCY_SYMBOLS.get(currency)
    return f"{symbol}{body}" if symbol else f"{currency} {body}"


def sheet_rearmed(nodes: list[Node], platform: str, amount_text: str) -> bool:
    """The sheet took a failure and offered the form again.

    The native sheet is opaque to Dart, so this is the runner's only way to
    observe a non-result. It is half of a `rearmed` verdict: the other half is
    criterion 2's merchant check (transaction `failed`, session still `open`),
    because the banner is not unique to a retryable decline.

    `amount_text` is required on both platforms. Android has nothing but the
    Pay button's text to match on; iOS matches the payButton identifier and
    then asks that its label carry the amount, because an identifier says
    nothing about which payment it belongs to -- without that half, a sheet
    re-armed at a different amount, or a form that was never this cell's,
    satisfies the predicate.
    """
    if not amount_text:
        # An empty string is in every label, so this would match any sheet.
        raise ValueError("sheet_rearmed needs the cell's amount text")
    if platform == "android":
        return bool(
            find_text_exact(nodes, ANDROID_REARM_BANNER)
            and find_text_exact(nodes, f"Pay {amount_text}")
        )
    if platform == "ios":
        # Identifiers, not copy: issue-ios-followups.md item 3 proposes
        # changing the banner's wording, which would break a text match
        # mid-campaign. Visibility is not required -- CardFormView puts the
        # banner last in the ScrollView, below the pinned footer.
        return bool(
            find_identifier(nodes, "errorBanner")
            and any(
                amount_text in node.text
                for node in find_identifier(nodes, "payButton")
            )
        )
    raise ValueError(f"unknown platform {platform!r}")
