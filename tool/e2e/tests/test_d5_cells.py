"""The D5 cells are data, and this dimension's data has an order in it.

D5 is card-on-file: store a card, then pay with the stored one. Everything
that is true of every dimension lives in `cell_rules.py`. What stays here is
what is true of D5 and of nothing else -- and almost all of it is about the
one property no other dimension has: **these cells are not independent**. The
saved-card list is snapshotted into a session at creation and never rebuilt
(SessionDataService.php:37-38), so a pay cell's session has to be minted after
its store cell's save has settled. The runner's only ordering is the filename,
so the ordering is asserted here rather than trusted.
"""

import re
from pathlib import Path

import pytest

# A sibling module, imported the way pytest resolves one -- see the note in
# `test_d0_cells.py`.
from cell_rules import check_cell_dir

from tool.e2e import cells

CELLS = Path(__file__).resolve().parents[1] / "cells"
D5 = CELLS / "d5"

#: The store cell and the pay cell that re-uses what it stored, in the order
#: they must run. Named as pairs rather than as a flat set because every rule
#: below is about the relationship between the two halves.
PAIRS = (
    ("saved_card_1_save", "saved_card_2_pay"),
    ("saved_card_3_challenge_save", "saved_card_4_challenge_pay"),
)

EXPECTED_IDS = {"control"} | {cell_id for pair in PAIRS for cell_id in pair}


def text_of(cell_id):
    return (D5 / f"{cell_id}.yaml").read_text(encoding="utf-8")


def test_d5_is_exactly_the_cells_the_plan_promised():
    assert {p.stem for p in D5.glob("*.yaml")} == EXPECTED_IDS


@pytest.mark.parametrize("platform", ["android", "ios"])
def test_the_d5_cells_satisfy_the_shared_authoring_rules(platform):
    loaded = check_cell_dir(D5, platform)

    assert {c.id for c in loaded} == EXPECTED_IDS
    # Both platforms run all five. Saved cards are the one exploratory
    # dimension with no platform asymmetry designed into it -- unlike D2's
    # network cuts or D4's Android-only wallet -- so a cell that quietly
    # dropped a platform would shrink the run without failing anything.
    assert len(loaded) == 5


def test_the_control_cell_is_the_same_payment_in_every_dimension():
    # The same rule D0 and D2 assert, restated because it is checked per
    # dimension directory and a new directory is exactly where it would be
    # forgotten. "The control passed" has to mean one thing everywhere.
    d0 = (CELLS / "d0" / "control.yaml").read_bytes()
    assert (D5 / "control.yaml").read_bytes() == d0


@pytest.mark.parametrize("platform", ["android", "ios"])
@pytest.mark.parametrize("store, pay", PAIRS)
def test_each_pair_stores_before_it_pays(store, pay, platform):
    """The whole dimension rests on this, and it is one `sorted()` away.

    `load_cells` sorts by path, so the filename is the execution order. Assert
    it over the LOADED cells rather than over the filenames: it is the loader's
    ordering the runner uses, and a rule that checks the strings instead would
    survive a change to how cells are enumerated.
    """
    order = [c.id for c in cells.load_cells(D5, platform)]
    assert order.index(store) < order.index(pay), (
        f"{pay} would run before {store}, so its session would be minted "
        "before the card it re-uses exists"
    )


@pytest.mark.parametrize("store, pay", PAIRS)
def test_each_pair_shares_one_pinned_customer(store, pay):
    """Same reference in both halves, and a literal in both.

    Two failures this catches, and they present identically on a device --
    "no stored card was offered" -- while having nothing to do with each
    other. A mismatched pair looks up a customer that has no cards; a
    templated reference (`CUST-{{timestamp}}`, or the runner's own default)
    mints a fresh customer per session, which is the same thing by a different
    route. `PaymentSessionsController.php:89-109` mints a random UUID when the
    field is absent, so leaving it out is a third.
    """
    references = {}
    for cell_id in (store, pay):
        cell = cells.load_cell(D5 / f"{cell_id}.yaml")
        customer = cell.session.options.get("customer") or {}
        reference = customer.get("merchant_reference")
        assert isinstance(reference, str) and reference, (
            f"{cell_id}: no customer.merchant_reference, so the backend mints a "
            "random customer and the stored card can never be found again"
        )
        assert "{{" not in reference, (
            f"{cell_id}: customer reference {reference!r} is templated; a "
            "per-run customer has no cards from a previous run"
        )
        references[cell_id] = reference
    assert references[store] == references[pay], (
        f"{store} stores against {references[store]!r} but {pay} looks up "
        f"{references[pay]!r}"
    )


def test_the_two_pairs_use_different_customers():
    """One row per selector, so "the first stored card" cannot be ambiguous.

    `select_saved_card` picks the first stored card it is offered. With both
    pairs on one customer that customer accumulates two cards -- one
    frictionless, one challenge -- and each pay cell would then have a 50%
    chance of re-using the other pair's card, passing its `saved_card_used`
    assertion while measuring the wrong PAN entirely.
    """
    used = {}
    for store, _ in PAIRS:
        cell = cells.load_cell(D5 / f"{store}.yaml")
        used[store] = cell.session.options["customer"]["merchant_reference"]
    assert len(set(used.values())) == len(PAIRS), (
        f"the pairs share a customer reference: {used}"
    )


@pytest.mark.parametrize("store, _pay", PAIRS)
def test_every_store_cell_renders_the_box_and_ticks_it(store, _pay):
    """`save_card_config` and the `save_card` action are both required (R5).

    Neither implies the other and each without the other is a cell that
    reports something it did not measure. Without the config the checkbox is
    not rendered at all (`CardFormScreen.kt:82`, `canSaveCard`), so the action
    fails looking for it; without the action the box renders unticked, the
    submit carries `card.save: false`, and the cell is an ordinary payment
    asserting a save that never happened.
    """
    cell = cells.load_cell(D5 / f"{store}.yaml")
    assert "save_card_config" in cell.session.options, store
    assert cell.session.options["save_card_config"].get("usage") == "card_on_file"
    assert "save_card" in {a.verb for a in cell.actions}, store
    assert cell.expected.merchant.get("saved_card_saved") is True, store


@pytest.mark.parametrize("_store, pay", PAIRS)
def test_every_pay_cell_asks_for_the_snapshot_and_selects_from_it(_store, pay):
    """`saved_cards: {show: all}` (R4), then look, then choose, then the CVV.

    The order is the assertion. `expect saved_card` before `select_saved_card`
    is what turns "no card was offered" into its own verdict instead of a
    selector that times out; `type_cvv` after the selection is what makes it
    reach the saved-card CVV field rather than the fresh form's.
    """
    cell = cells.load_cell(D5 / f"{pay}.yaml")
    assert cell.session.options.get("saved_cards") == {"show": "all"}, pay
    verbs = [(a.verb, a.arg) for a in cell.actions]
    order = [
        verbs.index(("expect", "saved_card")),
        verbs.index(("select_saved_card", None)),
        verbs.index(("type_cvv", None)),
    ]
    assert order == sorted(order), f"{pay}: {verbs}"
    assert cell.expected.merchant.get("saved_card_used") is True, pay


@pytest.mark.parametrize("_store, pay", PAIRS)
def test_no_pay_cell_types_a_card(_store, pay):
    """A `type_card` here would fill the fresh form and pay with a new PAN.

    It would then still approve, still render `result:success:<txn>`, and
    still leave a completed session -- and `saved_card_used` is the only
    assertion in the cell that would notice. Catching it at authoring time
    costs nothing; catching it live costs a full matrix run to diagnose.
    """
    cell = cells.load_cell(D5 / f"{pay}.yaml")
    assert "type_card" not in {a.verb for a in cell.actions}, pay


def test_every_pan_is_quoted_and_is_one_the_sandbox_still_recognises():
    # The same rule D2 states, for the same two reasons: an unquoted PAN with
    # a leading zero is YAML octal, and a PAN whose scenario was removed from
    # payment-sandbox approves instead of doing what the cell says. `0000` is
    # the instant approve, `3220` the challenge card.
    live = {"0000", "3220"}  # scenarios.go, the two D5 uses
    for path in sorted(D5.glob("*.yaml")):
        for line in path.read_text(encoding="utf-8").splitlines():
            found = re.match(r"\s*pan:\s*(\S+)\s*$", line)
            if not found:
                continue
            raw = found.group(1)
            assert raw[0] == raw[-1] == '"', f"{path.name}: PAN {raw} is not quoted"
            pan = raw.strip('"')
            assert pan.isdigit(), f"{path.name}: {raw} is not digits"
            assert pan[-4:] in live, f"{path.name}: {pan} no longer has a scenario"


@pytest.mark.parametrize("_store, pay", PAIRS)
def test_every_saved_card_cvv_is_three_digits(_store, pay):
    """Not style: four digits cannot be entered on a saved card at all.

    Both SDKs validate a saved card's CVV at 3 digits regardless of the stored
    card's brand -- Android passes `CardType.UNKNOWN` on the saved path
    (`CardFormScreen.kt:314` and `:382`), and iOS mirrors it deliberately
    (`CardFormState.swift:64-66`, whose comment says so). A 4-digit `cvv`
    here would be truncated by the field and then fail validation, and the
    cell would report a Pay button that never enabled.
    """
    cell = cells.load_cell(D5 / f"{pay}.yaml")
    assert len(cell.card.cvv) == 3, f"{pay}: {cell.card.cvv!r}"
