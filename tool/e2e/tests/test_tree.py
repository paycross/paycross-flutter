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

    pan_field = tree.find_identifier(nodes, "paycross.cardNumber")[0]
    assert pan_field.type == "android.widget.EditText"
    assert pan_field.bounds == (42, 431, 1038, 599)
    assert pan_field.centre == (540, 515)
    assert pan_field.visible is True


def test_parses_a_wda_dump_into_uniform_nodes():
    nodes = ios()

    pay = [
        n for n in tree.find_identifier(nodes, "paycross.sheet") if n.type == "Button"
    ]
    assert len(pay) == 1
    assert pay[0].text == "Pay €10.00"
    assert pay[0].content_desc == "Pay €10.00"
    assert pay[0].bounds == (20, 790, 382, 840)
    assert pay[0].centre == (201, 815)

    banner = tree.find_identifier(nodes, "paycross.errorBanner")[0]
    assert banner.visible is False


def test_a_checkable_node_reports_its_state_and_an_ordinary_one_says_nothing():
    nodes = android("android-save-card-form.uix")

    row = tree.find_identifier(nodes, "paycross.saveCard")
    assert len(row) == 1
    assert row[0].checked is False

    inner = [n for n in nodes if n.type.endswith("CheckBox")]
    assert len(inner) == 1
    assert inner[0].checked is None

    assert all(n.checked is None for n in nodes if n.type.endswith("TextView"))


def test_a_wda_switch_reports_its_state_the_same_way():
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
    assert by_name["Total"].checked is None


def test_find_text_exact_does_not_match_the_neighbouring_nodes():
    nodes = android("android-rearmed.uix")

    assert len(tree.find_text_exact(nodes, "Pay €10.00")) == 1
    assert len(tree.find_text_exact(nodes, "€10.00")) == 1
    assert tree.find_text_exact(nodes, "Pay with GPay") == []
    assert len(tree.find_content_desc(nodes, "Pay with GPay")) == 1


def test_label_from_tree_reads_content_desc_on_android():
    nodes = android("android-result.uix")

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


BANNER, AMOUNT = "paycross.errorBanner", "paycross.amount"


def without(nodes, identifier):
    return [n for n in nodes if n.identifier != identifier]


def showing(nodes, label):
    return [replace(n, text=label) if n.identifier == AMOUNT else n for n in nodes]


@pytest.mark.parametrize("dump", ["android-rearmed.uix", None])
def test_sheet_rearmed_needs_both_halves_on_either_platform(dump):
    nodes = android(dump) if dump else ios()
    amount = tree.format_amount_en_us(1000, "EUR")

    assert tree.sheet_rearmed(nodes, amount) is True
    assert tree.sheet_rearmed(without(nodes, BANNER), amount) is False
    assert tree.sheet_rearmed(without(nodes, AMOUNT), amount) is False
    assert tree.sheet_rearmed(nodes, "€12.50") is False


def test_sheet_rearmed_is_false_on_the_example_apps_own_screen():
    result_screen = android("android-result.uix")

    assert (
        tree.sheet_rearmed(result_screen, tree.format_amount_en_us(1000, "EUR"))
        is False
    )


def test_sheet_rearmed_reads_the_amount_off_the_header_not_the_pay_button():
    nodes = android("android-rearmed.uix")
    button = tree.find_identifier(nodes, "paycross.payButton")[0]

    assert button.text == ""
    assert tree.find_identifier(nodes, AMOUNT)[0].text == "€10.00"


def test_sheet_rearmed_tolerates_the_regions_decimal_separator():
    nodes = showing(ios(), "Total, €10,00")

    assert tree.sheet_rearmed(nodes, "€10.00") is True
    assert tree.sheet_rearmed(nodes, "€12.50") is False


def test_sheet_rearmed_reads_an_amount_inside_a_caption():
    assert tree.sheet_rearmed(showing(ios(), "Total, €10.00"), "€10.00") is True
    assert tree.sheet_rearmed(showing(ios(), "€10.00"), "€10.00") is True


def test_sheet_rearmed_does_not_confuse_grouping_with_value():
    assert tree.sheet_rearmed(showing(ios(), "Total, €1,000.00"), "€10.00") is False
    assert tree.sheet_rearmed(showing(ios(), "Total, €1,000.00"), "€1,000.00") is True

    assert tree.sheet_rearmed(showing(ios(), "€10,000.00"), "€10.00") is False
    assert tree.sheet_rearmed(showing(ios(), "€10.000,00"), "€10.00") is False
    assert tree.sheet_rearmed(showing(ios(), "€10,000.00"), "€10,000.00") is True
    assert tree.sheet_rearmed(showing(ios(), "€10.000,00"), "€10.000,00") is True


def test_sheet_rearmed_still_matches_an_amount_that_is_not_last():
    assert tree.sheet_rearmed(showing(ios(), "Total, €10.00 due"), "€10.00") is True


@pytest.mark.parametrize("predicate", [tree.sheet_rearmed, tree.rearm_amount_mismatch])
def test_the_rearm_predicates_refuse_an_empty_amount(predicate):
    with pytest.raises(ValueError):
        predicate(ios(), "")


def test_rearm_amount_mismatch_names_a_french_sheet_rather_than_denying_it():
    french = showing(ios(), "Total, 10,00 €")

    assert tree.sheet_rearmed(french, "€10.00") is False
    assert tree.rearm_amount_mismatch(french, "€10.00") == "Total, 10,00 €"


def test_rearm_amount_mismatch_leaves_a_different_amount_to_the_cell():
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
    assert tree.rearm_amount_mismatch(nodes_of(), "€10.00") is None, why


def box(**kw):
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
    button = box(text="Payer 10,00 €", bounds=(20, 790, 382, 840))

    assert tree.caption([button], button) == "Payer 10,00 €"


def test_a_caption_written_on_a_child_is_read():
    button = box(identifier="paycross.payButton", bounds=(0, 600, 400, 700))
    label = box(text="Payer 10,00 €", bounds=(20, 620, 380, 680))

    assert tree.caption([button, label], button) == "Payer 10,00 €"


def test_text_outside_the_control_is_not_its_caption():
    button = box(identifier="paycross.payButton", bounds=(0, 600, 400, 700))
    elsewhere = box(text="Annuler", bounds=(0, 100, 400, 160))

    assert tree.caption([elsewhere, button], button) == ""


def test_a_control_that_is_not_in_this_tree_has_no_caption():
    button = box(identifier="paycross.payButton", bounds=(0, 600, 400, 700))
    label = box(text="Payer 10,00 €", bounds=(20, 620, 380, 680))

    assert tree.caption([label], button) == ""


def test_a_child_with_no_box_does_not_end_the_walk():
    button = box(identifier="paycross.payButton", bounds=(0, 600, 400, 700))
    boxless = box(text="", bounds=(0, 0, 0, 0))
    label = box(text="Payer 10,00 €", bounds=(20, 620, 380, 680))

    assert tree.caption([button, boxless, label], button) == "Payer 10,00 €"


def test_a_label_scrolled_under_the_button_is_not_its_caption():
    label = box(text="Email address", bounds=(20, 477, 107, 494))
    button = box(
        identifier="paycross.payButton",
        text="Payer 10,00 €",
        bounds=(20, 448, 382, 498),
    )

    assert tree.caption([label, button], button) == "Payer 10,00 €"


def test_the_walk_stops_where_the_control_ends():
    button = box(identifier="paycross.payButton", bounds=(0, 600, 400, 700))
    after = box(text="Annuler", bounds=(0, 720, 400, 780))

    assert tree.caption([button, after], button) == ""


def test_a_flutter_widget_answers_through_its_description():
    button = box(bounds=(0, 600, 400, 700))
    label = box(content_desc="Payer", bounds=(20, 620, 380, 680))

    assert tree.caption([button, label], button) == "Payer"
