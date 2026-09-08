from dataclasses import replace
from pathlib import Path

import pytest

from tool.e2e import tree

FIXTURES = Path(__file__).parent / "fixtures"


def android(name):
    return tree.parse_uiautomator((FIXTURES / name).read_bytes())


def ios():
    return tree.parse_wda((FIXTURES / "ios-source.xml").read_bytes())


def test_parses_an_android_dump_into_uniform_nodes():
    nodes = android("android-rearmed.uix")

    # resource-id, which is where a Compose testTag lands once
    # testTagsAsResourceId is set. The tagged node is the EditText itself; the
    # `Card number input` description is on a non-clickable View inside it,
    # which is why the driver stopped matching on the description.
    pan_field = tree.find_identifier(nodes, "paycross.cardNumber")[0]
    assert pan_field.type == "android.widget.EditText"
    assert pan_field.bounds == (42, 431, 1038, 599)
    assert pan_field.centre == (540, 515)
    assert pan_field.visible is True


def test_parses_a_wda_dump_into_uniform_nodes():
    nodes = ios()

    # `paycross.sheet` and not `paycross.payButton`, because that is what the
    # simulator really answers with: SDK 0.7.0 puts the sheet's identifier on
    # the group wrapping the form, and SwiftUI's outer name overrides the one
    # set on the pinned footer. `IosDriver._pay_button` is what copes.
    pay = [
        n for n in tree.find_identifier(nodes, "paycross.sheet") if n.type == "Button"
    ]
    assert len(pay) == 1
    # label fills both text and content_desc, so matchers need no branch.
    assert pay[0].text == "Pay €10.00"
    assert pay[0].content_desc == "Pay €10.00"
    assert pay[0].bounds == (20, 790, 382, 840)
    assert pay[0].centre == (201, 815)

    banner = tree.find_identifier(nodes, "paycross.errorBanner")[0]
    # In the tree while scrolled off-screen. The predicate must not need
    # visibility -- CardFormView puts the banner below the pinned footer.
    assert banner.visible is False


def test_a_checkable_node_reports_its_state_and_an_ordinary_one_says_nothing():
    """`checked` is how a two-state control is read, normalised across two dumps.

    The SDK's save-card control is a `Row` carrying `Modifier.toggleable` and
    the `paycross.saveCard` tag, with a `Checkbox` inside it whose own
    `onCheckedChange` is null. So in a real dump the tagged Row is the
    checkable node and the CheckBox is not one at all -- the reverse of what
    this fixture held before Train 4, when the tag did not exist and the box
    was the only handle. `save_card` reads the state back off the Row, and the
    state is the sole evidence that a tap landed.

    `None` rather than `False` for a node that is not checkable, because
    uiautomator writes `checked="false"` on every node in the tree -- the frame
    layouts, the labels, all of them. Reading that as "an unticked control"
    would make every dump full of them.
    """
    nodes = android("android-save-card-form.uix")

    row = tree.find_identifier(nodes, "paycross.saveCard")
    assert len(row) == 1
    assert row[0].checked is False

    # The Compose Checkbox inside it takes no click of its own, so it is not a
    # two-state control as far as a dump is concerned.
    inner = [n for n in nodes if n.type.endswith("CheckBox")]
    assert len(inner) == 1
    assert inner[0].checked is None

    assert all(n.checked is None for n in nodes if n.type.endswith("TextView"))


def test_a_wda_switch_reports_its_state_the_same_way():
    # The iOS half of the same idea: `Toggle("Save this card")` is an
    # XCUIElementTypeSwitch whose `value` is "0" or "1". Normalised here so a
    # driver asks `node.checked` on either platform rather than one of them
    # asking about a string.
    xml = (
        '<XCUIElementTypeApplication type="XCUIElementTypeApplication">'
        '<XCUIElementTypeSwitch type="XCUIElementTypeSwitch" name="Save this card"'
        ' label="Save this card" value="1" visible="true" x="20" y="600"'
        ' width="362" height="31"/>'
        '<XCUIElementTypeSwitch type="XCUIElementTypeSwitch" name="off one"'
        ' label="off one" value="0" visible="true" x="20" y="640"'
        ' width="362" height="31"/>'
        '<XCUIElementTypeStaticText type="XCUIElementTypeStaticText" name="Total"'
        ' label="Total" value="10.00 EUR" visible="true" x="20" y="100"'
        ' width="100" height="20"/>'
        "</XCUIElementTypeApplication>"
    )
    nodes = tree.parse_wda(xml.encode())
    by_name = {n.identifier: n for n in nodes}

    assert by_name["Save this card"].checked is True
    assert by_name["off one"].checked is False
    # A value that is not a switch state says nothing, rather than being
    # coerced -- "10.00 EUR" is not an unticked control.
    assert by_name["Total"].checked is None


def test_find_text_exact_does_not_match_the_neighbouring_nodes():
    nodes = android("android-rearmed.uix")

    assert len(tree.find_text_exact(nodes, "Pay €10.00")) == 1
    # The amount header renders a bare "€10.00" in the same tree...
    assert len(tree.find_text_exact(nodes, "€10.00")) == 1
    # ...and the Google Pay row is a content-desc, not a text.
    assert tree.find_text_exact(nodes, "Pay with GPay") == []
    assert len(tree.find_content_desc(nodes, "Pay with GPay")) == 1


def test_label_from_tree_reads_content_desc_on_android():
    nodes = android("android-result.uix")

    # A Flutter Text surfaces as content-desc with text="" on Android. This
    # fixture predates the contract, so it is read with the legacy prefixes --
    # which is also what tells a runner it is looking at a build made without
    # --dart-define=PAYCROSS_E2E.
    assert (
        tree.label_from_tree(nodes, prefixes=tree.LEGACY_LABEL_PREFIXES)
        == "Paid 1000 EUR — 99e6bc23-4c5c-4b29-9c2c-66d338d71e1a"
    )
    assert tree.label_from_tree(nodes) is None


def test_label_from_tree_reads_the_label_on_ios():
    assert (
        tree.label_from_tree(ios())
        == "result:success:7d8e12aa-98c9-4032-9e03-6567d8db7bea"
    )


def test_label_from_tree_ignores_everything_outside_the_vocabulary():
    nodes = ios()

    assert tree.label_from_tree(nodes, prefixes=("nothing:",)) is None


@pytest.mark.parametrize(
    "minor, currency, expected",
    [
        (1000, "EUR", "€10.00"),
        (1250, "EUR", "€12.50"),
        (123456, "EUR", "€1,234.56"),
        (1000, "USD", "$10.00"),
        (1000, "GBP", "£10.00"),
        (1000, "SEK", "SEK 10.00"),
    ],
)
def test_format_amount_en_us(minor, currency, expected):
    assert tree.format_amount_en_us(minor, currency) == expected


#: The two the predicate reads, spelled out here so a rename in `tree` that
#: the tests happened to follow still fails something.
BANNER, AMOUNT = "paycross.errorBanner", "paycross.amount"


def without(nodes, identifier):
    return [n for n in nodes if n.identifier != identifier]


def showing(nodes, label):
    """The same tree with the amount header reading `label`."""
    return [replace(n, text=label) if n.identifier == AMOUNT else n for n in nodes]


@pytest.mark.parametrize("dump", ["android-rearmed.uix", None])
def test_sheet_rearmed_needs_both_halves_on_either_platform(dump):
    # One rule for both platforms now: the SDKs publish the same identifiers,
    # so the predicate stopped having a platform branch.
    nodes = android(dump) if dump else ios()
    amount = tree.format_amount_en_us(1000, "EUR")

    assert tree.sheet_rearmed(nodes, amount) is True
    assert tree.sheet_rearmed(without(nodes, BANNER), amount) is False
    assert tree.sheet_rearmed(without(nodes, AMOUNT), amount) is False
    # A sheet re-armed at some other amount is not this cell's sheet.
    assert tree.sheet_rearmed(nodes, "€12.50") is False


def test_sheet_rearmed_is_false_on_the_example_apps_own_screen():
    # The negative that matters: the result screen is what a cell is looking
    # at when the sheet is gone, and it carries none of the three.
    result_screen = android("android-result.uix")

    assert (
        tree.sheet_rearmed(result_screen, tree.format_amount_en_us(1000, "EUR"))
        is False
    )


def test_sheet_rearmed_reads_the_amount_off_the_header_not_the_pay_button():
    # Measured on the emulator 2026-09-07: Android's `paycross.payButton` is a
    # View whose own text is empty -- `Pay €10.00` is on a child TextView. So
    # the button could not answer for the amount even if the predicate asked
    # it, and the header, which carries the amount as its own text, is what
    # both platforms read.
    nodes = android("android-rearmed.uix")
    button = tree.find_identifier(nodes, "paycross.payButton")[0]

    assert button.text == ""
    assert tree.find_identifier(nodes, AMOUNT)[0].text == "€10.00"


def test_sheet_rearmed_tolerates_the_regions_decimal_separator():
    # Measured on the rig 2026-08-29: the simulator is en_US@rg=lvzzzz -- US
    # English, Latvian region -- so the SDK renders "€10,00" while the runner
    # computes "€10.00" and the re-arm cell failed as "the sheet never
    # re-armed" on a sheet that plainly had. The value is what the check is
    # about, and a region is free to punctuate it however it likes.
    nodes = showing(ios(), "Total, €10,00")

    assert tree.sheet_rearmed(nodes, "€10.00") is True
    # Still this cell's amount, and still not another one's.
    assert tree.sheet_rearmed(nodes, "€12.50") is False


def test_sheet_rearmed_reads_an_amount_inside_a_caption():
    # iOS labels the header `Total, €10.00`; Android's is the bare amount. A
    # substring search is what reads both without a platform branch.
    assert tree.sheet_rearmed(showing(ios(), "Total, €10.00"), "€10.00") is True
    assert tree.sheet_rearmed(showing(ios(), "€10.00"), "€10.00") is True


def test_sheet_rearmed_does_not_confuse_grouping_with_value():
    # Separator-blind, not digit-blind: neither the amount as written nor the
    # separator-swapped variant may match the head of a longer number. A sheet
    # re-armed at a thousand times the amount is exactly what the amount half
    # of this predicate exists to catch.
    #
    # "€1,000.00" alone does not prove it -- neither "€10.00" nor "€10,00"
    # appears in it, so it passed before there was anything stopping them. The
    # two that do reach the hole are below, one per separator convention.
    assert tree.sheet_rearmed(showing(ios(), "Total, €1,000.00"), "€10.00") is False
    assert tree.sheet_rearmed(showing(ios(), "Total, €1,000.00"), "€1,000.00") is True

    # "€10,00", the swapped variant, is the head of "€10,000.00".
    assert tree.sheet_rearmed(showing(ios(), "€10,000.00"), "€10.00") is False
    # And "€10.00" as written is the head of "€10.000,00".
    assert tree.sheet_rearmed(showing(ios(), "€10.000,00"), "€10.00") is False
    # Each is still its own amount.
    assert tree.sheet_rearmed(showing(ios(), "€10,000.00"), "€10,000.00") is True
    assert tree.sheet_rearmed(showing(ios(), "€10.000,00"), "€10.000,00") is True


def test_sheet_rearmed_still_matches_an_amount_that_is_not_last():
    # The guard looks at the character after the amount, so anything that is
    # not part of a longer number has to keep matching.
    assert tree.sheet_rearmed(showing(ios(), "Total, €10.00 due"), "€10.00") is True


@pytest.mark.parametrize("predicate", [tree.sheet_rearmed, tree.rearm_amount_mismatch])
def test_the_rearm_predicates_refuse_an_empty_amount(predicate):
    # "" is in every label, so an empty amount would match any sheet at all.
    with pytest.raises(ValueError):
        predicate(ios(), "")


def test_rearm_amount_mismatch_names_a_french_sheet_rather_than_denying_it():
    """The half of the removed locale guard that still had work to do.

    `format_amount_en_us` renders `€10.00` where a French sheet draws
    `10,00 €`, and swapping the separator does not move the symbol. Without
    this the cell would report "the sheet never re-armed" about a sheet that
    plainly had -- a rig fault wearing an SDK finding's clothes.
    """
    french = showing(ios(), "Total, 10,00 €")

    assert tree.sheet_rearmed(french, "€10.00") is False
    assert tree.rearm_amount_mismatch(french, "€10.00") == "Total, 10,00 €"


def test_rearm_amount_mismatch_leaves_a_different_amount_to_the_cell():
    # The digits are what separate a spelling from a value. A sheet re-armed at
    # €12.50 when the cell is a €10.00 one is the finding the amount half
    # exists to make, and calling it a rig fault would hide it.
    other = showing(ios(), "Total, €12.50")

    assert tree.sheet_rearmed(other, "€10.00") is False
    assert tree.rearm_amount_mismatch(other, "€10.00") is None


@pytest.mark.parametrize(
    "nodes_of, why",
    [
        (lambda: ios(), "the amount agrees, so there is nothing to explain"),
        (lambda: without(ios(), BANNER), "no failure banner: this is not a re-arm"),
        (lambda: without(ios(), AMOUNT), "no amount header to have misread"),
    ],
)
def test_rearm_amount_mismatch_stays_quiet_when_it_has_nothing_to_say(nodes_of, why):
    # It must not turn every failed re-arm into a rig fault: a cell that
    # measures "the sheet did not re-arm" has a verdict to report.
    assert tree.rearm_amount_mismatch(nodes_of(), "€10.00") is None, why


# --- the caption a control draws, on a tree with no children -----------------


def box(**kw):
    """A node with only the fields `caption` reads."""
    base = dict(
        type="",
        text="",
        content_desc="",
        identifier="",
        value="",
        bounds=(0, 0, 0, 0),
        visible=True,
    )
    return tree.Node(**{**base, **kw})


def test_a_caption_written_on_the_control_itself_is_read():
    # iOS. The whole string is the button's own label, and a node is inside
    # its own box.
    button = box(text="Payer 10,00 €", bounds=(20, 790, 382, 840))

    assert tree.caption([button], button) == "Payer 10,00 €"


def test_a_caption_written_on_a_child_is_read():
    # Android. `paycross.payButton` is an `android.view.View` whose own text
    # is empty; the caption is on a `TextView` inside it, and both parsers
    # flatten, so geometry is the only relationship left.
    button = box(identifier="paycross.payButton", bounds=(0, 600, 400, 700))
    label = box(text="Payer 10,00 €", bounds=(20, 620, 380, 680))

    assert tree.caption([button, label], button) == "Payer 10,00 €"


def test_text_outside_the_control_is_not_its_caption():
    button = box(identifier="paycross.payButton", bounds=(0, 600, 400, 700))
    elsewhere = box(text="Annuler", bounds=(0, 100, 400, 160))

    assert tree.caption([elsewhere, button], button) == ""


def test_a_control_that_is_not_in_this_tree_has_no_caption():
    # A stale node, read from a dump the tree has moved past. Answering with
    # whatever happens to sit at index 0 would be worse than answering nothing.
    button = box(identifier="paycross.payButton", bounds=(0, 600, 400, 700))
    label = box(text="Payer 10,00 €", bounds=(20, 620, 380, 680))

    assert tree.caption([label], button) == ""


def test_a_child_with_no_box_does_not_end_the_walk():
    # A boxless node is inside nothing, so treating it as the end of the
    # control's run would stop at the first invisible child and answer with no
    # caption at all.
    button = box(identifier="paycross.payButton", bounds=(0, 600, 400, 700))
    boxless = box(text="", bounds=(0, 0, 0, 0))
    label = box(text="Payer 10,00 €", bounds=(20, 620, 380, 680))

    assert tree.caption([button, boxless, label], button) == "Payer 10,00 €"


def test_a_label_scrolled_under_the_button_is_not_its_caption():
    # Measured on the simulator 2026-09-08. Both sheets pin the Pay button
    # under a scrolling form, and the contact field caption `Email address`
    # sat INSIDE the button's bounds while belonging to the form. It comes
    # earlier in the document, so walking forward from the button skips it --
    # where "anything inside the box" would have answered with it.
    label = box(text="Email address", bounds=(20, 477, 107, 494))
    button = box(
        identifier="paycross.payButton",
        text="Payer 10,00 €",
        bounds=(20, 448, 382, 498),
    )

    assert tree.caption([label, button], button) == "Payer 10,00 €"


def test_the_walk_stops_where_the_control_ends():
    # The node after a control's own run is the next sibling, not a child, and
    # it is told apart by falling outside the box.
    button = box(identifier="paycross.payButton", bounds=(0, 600, 400, 700))
    after = box(text="Annuler", bounds=(0, 720, 400, 780))

    assert tree.caption([button, after], button) == ""


def test_a_flutter_widget_answers_through_its_description():
    # Android surfaces a Flutter `Text` as `content-desc` with an empty
    # `text`, which is the same rule `label_from_tree` follows.
    button = box(bounds=(0, 600, 400, 700))
    label = box(content_desc="Payer", bounds=(20, 620, 380, 680))

    assert tree.caption([button, label], button) == "Payer"
