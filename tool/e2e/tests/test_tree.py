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

    pan_field = tree.find_content_desc(nodes, "Card number input")[0]
    assert pan_field.type == "android.view.View"
    assert pan_field.bounds == (42, 431, 1038, 599)
    assert pan_field.centre == (540, 515)
    assert pan_field.visible is True


def test_parses_a_wda_dump_into_uniform_nodes():
    nodes = ios()

    pay = tree.find_identifier(nodes, "payButton")[0]
    assert pay.type == "Button"
    # label fills both text and content_desc, so matchers need no branch.
    assert pay.text == "Pay €10.00"
    assert pay.content_desc == "Pay €10.00"
    assert pay.bounds == (16, 790, 386, 840)
    assert pay.centre == (201, 815)

    banner = tree.find_identifier(nodes, "errorBanner")[0]
    # In the tree while scrolled off-screen. The predicate must not need
    # visibility -- CardFormView puts the banner below the pinned footer.
    assert banner.visible is False


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


def test_sheet_rearmed_on_android_needs_the_banner_and_the_pay_button():
    rearmed = android("android-rearmed.uix")
    result_screen = android("android-result.uix")
    amount = tree.format_amount_en_us(1000, "EUR")

    assert tree.sheet_rearmed(rearmed, "android", amount) is True
    assert tree.sheet_rearmed(result_screen, "android", amount) is False
    # A different amount means a different Pay button, so no false positive.
    assert tree.sheet_rearmed(rearmed, "android", "€12.50") is False
    # The result screen happens to carry neither half, so it cannot show that
    # the banner is required. Drop only the banner from a tree that has both.
    without_banner = [n for n in rearmed if n.text != tree.ANDROID_REARM_BANNER]
    assert tree.sheet_rearmed(without_banner, "android", amount) is False


def test_sheet_rearmed_on_ios_matches_identifiers_not_copy():
    nodes = ios()

    assert tree.sheet_rearmed(nodes, "ios", "€10.00") is True

    without_banner = [n for n in nodes if n.identifier != "errorBanner"]
    assert tree.sheet_rearmed(without_banner, "ios", "€10.00") is False

    without_pay = [n for n in nodes if n.identifier != "payButton"]
    assert tree.sheet_rearmed(without_pay, "ios", "€10.00") is False


def test_sheet_rearmed_on_ios_needs_the_pay_button_to_carry_this_amount():
    # payButton is an identifier, so without this a sheet re-armed at some
    # other amount -- or a form that was never this cell's -- satisfies it.
    nodes = ios()

    assert tree.sheet_rearmed(nodes, "ios", "€10.00") is True
    assert tree.sheet_rearmed(nodes, "ios", "€12.50") is False


def test_sheet_rearmed_on_ios_tolerates_the_regions_decimal_separator():
    # Measured on the rig 2026-08-29: the simulator is en_US@rg=lvzzzz -- US
    # English, Latvian region -- so the SDK renders "Pay €10,00" while the
    # runner computes "€10.00" and the re-arm cell failed as "the sheet never
    # re-armed" on a sheet that plainly had. The value is what the check is
    # about, and a region is free to punctuate it however it likes.
    nodes = [
        replace(n, text=n.text.replace(".", ","))
        if n.identifier == "payButton"
        else n
        for n in ios()
    ]
    assert any("€10,00" in n.text for n in nodes if n.identifier == "payButton")

    assert tree.sheet_rearmed(nodes, "ios", "€10.00") is True
    # Still this cell's amount, and still not another one's.
    assert tree.sheet_rearmed(nodes, "ios", "€12.50") is False


def pay_button(label):
    return [
        replace(n, text=label) if n.identifier == "payButton" else n for n in ios()
    ]


def test_sheet_rearmed_on_ios_does_not_confuse_grouping_with_value():
    # Separator-blind, not digit-blind: neither the amount as written nor the
    # separator-swapped variant may match the head of a longer number. A sheet
    # re-armed at a thousand times the amount is exactly what the amount half
    # of this predicate exists to catch.
    #
    # "Pay €1,000.00" alone does not prove it -- neither "€10.00" nor "€10,00"
    # appears in it, so it passed before there was anything stopping them. The
    # two that do reach the hole are below, one per separator convention.
    assert tree.sheet_rearmed(pay_button("Pay €1,000.00"), "ios", "€10.00") is False
    assert tree.sheet_rearmed(pay_button("Pay €1,000.00"), "ios", "€1,000.00") is True

    # "€10,00", the swapped variant, is the head of "€10,000.00".
    assert tree.sheet_rearmed(pay_button("Pay €10,000.00"), "ios", "€10.00") is False
    # And "€10.00" as written is the head of "€10.000,00".
    assert tree.sheet_rearmed(pay_button("Pay €10.000,00"), "ios", "€10.00") is False
    # Each is still its own amount.
    assert tree.sheet_rearmed(pay_button("Pay €10,000.00"), "ios", "€10,000.00") is True
    assert tree.sheet_rearmed(pay_button("Pay €10.000,00"), "ios", "€10.000,00") is True


def test_sheet_rearmed_on_ios_still_matches_an_amount_that_is_not_last():
    # The guard looks at the character after the amount, so anything that is
    # not part of a longer number has to keep matching.
    assert tree.sheet_rearmed(pay_button("Pay €10.00 now"), "ios", "€10.00") is True
    assert tree.sheet_rearmed(pay_button("Pay €10.00"), "ios", "€10.00") is True


@pytest.mark.parametrize("platform", ["android", "ios"])
def test_sheet_rearmed_refuses_an_empty_amount(platform):
    # "" is in every label, so an empty amount would match any sheet at all.
    with pytest.raises(ValueError):
        tree.sheet_rearmed(ios(), platform, "")


def test_sheet_rearmed_rejects_an_unknown_platform():
    with pytest.raises(ValueError):
        tree.sheet_rearmed([], "windows", "€10.00")
