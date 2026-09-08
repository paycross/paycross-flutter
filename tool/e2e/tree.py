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

#: The two identifiers `sheet_rearmed` reads. Both SDKs publish these exact
#: strings -- Android as a resource id, iOS as an accessibility identifier --
#: which is what lets the predicate be one rule rather than one per platform.
#:
#: The banner used to be matched on Android by the two sentences
#: `PaymentViewModel` renders after a failed submit. That was English, and the
#: sheet now draws French, so the identifier is the only handle that survives a
#: locale. It is also broader: the same banner carries the card-removal failure.
#: That costs nothing here, because a re-arm verdict was never the banner alone
#: -- pass criterion 2's merchant check is the other half, and no cell both
#: removes a card and expects a re-arm.
#: `paycross.payButton` is deliberately NOT read here. It would say "the form
#: is being offered again", which the amount header already says -- both are
#: drawn by the form and both are gone while the spinner is up or the challenge
#: is showing. And it is the one identifier iOS 0.7.0 does not publish: the
#: button there answers to `paycross.sheet` (see `drivers/ios.SHEET`), so
#: asking for it would make this predicate answer False on every iOS cell.
ERROR_BANNER = "paycross.errorBanner"
AMOUNT = "paycross.amount"

#: The word the SDKs' French Pay button is built from. `paycross_pay_amount`
#: is `Payer %1$s` in the Android SDK's `values-fr/strings.xml` at v0.8.1 and
#: the same sentence on iOS, so the verb is the language and the rest of the
#: caption is the amount.
FRENCH_PAY_VERB = "Payer"

_BOUNDS = re.compile(r"\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]")
_CURRENCY_SYMBOLS = {"EUR": "€", "USD": "$", "GBP": "£"}

#: What an XCUIElementTypeSwitch puts in `value`. A mapping rather than
#: `value == "1"` so anything else answers None instead of False.
_SWITCH_STATE = {"0": False, "1": True}


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
    #: A two-state control's state, or None where this node is not one.
    #:
    #: Three-valued on purpose. uiautomator writes `checked="false"` on every
    #: node in the tree -- frame layouts, labels, all of them -- so reading it
    #: unconditionally would fill a dump with unticked controls that do not
    #: exist; `checkable` is what says the attribute means anything. WDA has no
    #: such flag and puts a switch's state in `value`, which also holds
    #: ordinary text, so only the two literals a switch uses are read.
    #:
    #: Defaulted so every existing construction -- both parsers' siblings, and
    #: the hand-built nodes in the tests -- keeps working unchanged.
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
                # uiautomator has no `visible` attribute; a degenerate box is
                # the only thing it can mean here.
                visible=x2 > x1 and y2 > y1,
                # Gated on `checkable`, which is what makes `checked` mean
                # anything: uiautomator writes both on every node.
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
                # `name` is the accessibilityIdentifier when one is set and
                # falls back to the label when it is not, which is exactly the
                # handle the SDK's identifiers give us.
                identifier=element.get("name", ""),
                value=element.get("value", ""),
                bounds=(x, y, x + width, y + height),
                visible=element.get("visible") == "true",
                # Only the two literals a switch uses. `value` also carries
                # ordinary text -- an amount, a field's contents -- and "10.00
                # EUR" is not an unticked control.
                checked=_SWITCH_STATE.get(element.get("value")),
            )
        )
    return nodes


def find_text_exact(nodes: list[Node], text: str) -> list[Node]:
    """Exact match on `text`, for the things that publish no identifier.

    What is left on this matcher is the sandbox challenge page's outcome
    buttons and the example app's own widgets -- neither is drawn by an SDK, so
    neither has a `paycross.*` name to reach instead. The sheet's Pay button
    was the reason this was exact, and is matched by identifier now.

    Still exact rather than a substring, and the challenge page is why: it
    renders a button per outcome, and `timeout` is inside
    `authentication_timeout`. A substring match asked for the first would find
    both and tap whichever came first in the tree, which is a cell measuring an
    outcome it did not ask for.
    """
    return [n for n in nodes if n.text == text]


def find_content_desc(nodes: list[Node], content_desc: str) -> list[Node]:
    return [n for n in nodes if n.content_desc == content_desc]


def find_identifier(nodes: list[Node], identifier: str) -> list[Node]:
    return [n for n in nodes if n.identifier == identifier]


def caption(nodes: list[Node], control: Node) -> str:
    """The text drawn on `control`, wherever in the tree it is written.

    Its own label first, which is the whole answer on iOS: WebDriverAgent puts
    a button's caption on the button. Android's Pay button has no text at all
    -- it is an `android.view.View` whose child `TextView` holds `Pay €10.00`
    (measured 2026-09-07, `evidence/train4/t7-probe/`) -- so the caption has to
    be looked for below it.

    Both parsers flatten: `parse_uiautomator` iterates `node` elements and
    `parse_wda` iterates the whole document, so nothing above this layer can
    ask a node for its children. But the flattening is DOCUMENT ORDER, so a
    node's children are the run that follows it, and the run ends at the first
    node that is not inside its box. That is what is walked here.

    Position rather than "anything inside the box", and that is measured too.
    Both sheets pin the Pay button under a scrolling form, and a form label
    scrolled beneath it overlaps its rect while belonging to nothing of the
    sort: on the simulator, 2026-09-08, the contact field caption
    `Email address` sat inside the Pay button's bounds. Reading the first
    contained node would have answered with that.

    A degenerate box is skipped rather than ending the walk. `[0,0][0,0]` has
    no place on screen, so it is neither a caption nor evidence that the run
    is over -- and it would otherwise stop the walk at the first invisible
    child.
    """
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
    """Where `control` sits in `nodes`, by identity and then by value.

    Identity first because `Node` is a frozen dataclass and compares by value,
    so two identical rows -- a form with the same caption twice -- would make
    `index` answer for the wrong one. By value second so a node rebuilt rather
    than taken from this list still finds its place, which is how the tests
    hand one in. `len(nodes)` for a node that is not here at all, which walks
    nothing and answers with no caption.
    """
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

    Computed rather than hardcoded because `sheet_rearmed` has to know which
    payment the sheet it is looking at belongs to, and the amount is the only
    thing on the sheet that says. Nothing taps by it any more: both Pay buttons
    are reached by identifier.

    **This is the en-US spelling and only that.** A sheet drawn in French reads
    `10,00 €`, which `_carries_amount` does not absorb -- it swaps `.` and `,`
    and does not move the currency symbol. So a French cell may not expect a
    re-arm today, and none does. Whoever writes the first one has to teach
    `_separator_variants` about a trailing symbol first.

    Two minor digits are assumed, which is right for EUR/USD-style currencies
    and wrong for JPY. `cells.py` constrains a cell to positive integer minor
    units and an ISO 4217 code, not to that subset.
    """
    body = f"{Decimal(minor_units) / 100:,.2f}"
    symbol = _CURRENCY_SYMBOLS.get(currency)
    return f"{symbol}{body}" if symbol else f"{currency} {body}"


#: What may not follow a matched amount. The match is a substring, so without
#: this "€10.00" is the head of "€10.000,00" and its swapped variant "€10,00"
#: is the head of "€10,000.00" -- and a sheet re-armed at a thousand times the
#: amount would satisfy the check that exists to catch exactly that. Only the
#: tail needs guarding: `amount_text` opens with the currency symbol, so a
#: longer number cannot run into it from the left.
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
    """`amount_text` as written, and with `.` and `,` swapped.

    The value is what the check is about; a region is free to punctuate it
    however it likes. The rig's simulator is `en_US@rg=lvzzzz` -- US English,
    Latvian region -- so the SDK renders "Pay €10,00" where the runner computes
    "€10.00", and the re-arm cell failed as "the sheet never re-armed" on a
    sheet that plainly had (measured 2026-08-29).

    A swap rather than stripping the separators out: with them gone "€10.00"
    is a substring of "€1,000.00", and a sheet re-armed at a hundred times the
    amount would satisfy the predicate that exists to catch exactly that.

    A swap and nothing more. The symbol stays where the runner put it, so this
    does not reach a French sheet's `10,00 €` -- see `format_amount_en_us`.
    """
    swapped = amount_text.translate(str.maketrans(".,", ",."))
    return (amount_text,) if swapped == amount_text else (amount_text, swapped)


def sheet_rearmed(nodes: list[Node], amount_text: str) -> bool:
    """The sheet took a failure and offered the form again.

    The native sheet is opaque to Dart, so this is the runner's only way to
    observe a non-result. It is half of a `rearmed` verdict: the other half is
    criterion 2's merchant check (transaction `failed`, session still `open`),
    because the banner is not unique to a retryable decline.

    Two things have to hold, and each answers a different question. The banner
    says the submit failed. The amount header says the form is up again AND
    that it is THIS cell's form: an identifier is the same on every session, so
    without the amount a sheet re-armed at a different one, or a form that was
    never this cell's, satisfies the predicate.

    The amount is read off `paycross.amount` and not off the Pay button, and
    that is measured rather than tidy. Android's Pay button is a `View` whose
    CHILD `TextView` holds `Pay €10.00`; the tagged node's own text is empty,
    so the button cannot answer for the amount there. The header carries it as
    its own text on Android and inside a `Total, ` caption on iOS, and a
    substring search reads both.

    No platform argument. It took one while Android had nothing but rendered
    English to match on and iOS had identifiers; now both SDKs publish the same
    three strings and the two branches were the same rule written twice.
    """
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
    """What the sheet's amount reads, when that is the only thing that failed.

    Answers None whenever there is nothing to explain: no failure banner, no
    amount node, or an amount that agrees.

    This exists because of what the drivers stopped doing. Both used to refuse
    to launch against a device that was not in English, since the Pay button
    and the re-arm banner were matched as English strings. They are identifiers
    now and the language is the device's business -- except here, where
    `format_amount_en_us` computes one region's spelling of the amount and
    nothing translates it. A sheet drawing `10,00 €` would make `sheet_rearmed`
    answer False, and the cell would report "the sheet never re-armed" about a
    sheet that plainly had: a rig fault wearing an SDK finding's clothes, which
    is the expensive direction to be wrong in.

    So a driver asks this before it answers False, and says which of the two it
    is looking at.

    It answers None for a sheet re-armed at a genuinely different AMOUNT. That
    is not a spelling problem and not the rig's fault -- it is the finding the
    amount half of `sheet_rearmed` exists to make, and turning it into a rig
    fault would hide it. The digits tell the two apart.
    """
    if not amount_text:
        raise ValueError("rearm_amount_mismatch needs the cell's amount text")
    if not find_identifier(nodes, ERROR_BANNER):
        return None
    showing = find_identifier(nodes, AMOUNT)
    if not showing or any(_carries_amount(n.text, amount_text) for n in showing):
        return None
    # The digits are what separate the two ways this predicate can fail, and
    # only one of them is the rig's fault. A sheet spelling the SAME value
    # another way -- `10,00 €` for `€10.00` -- has the same digits in the same
    # order. A sheet re-armed at a DIFFERENT amount does not, and that is a
    # cell verdict: it is the whole reason the amount is checked at all.
    wanted = _digits(amount_text)
    same_value = [n for n in showing if _digits(n.text) == wanted]
    return same_value[0].text if same_value else None
