import re
from pathlib import Path

import pytest
from cell_rules import check_cell_dir

from tool.e2e import cells

CELLS = Path(__file__).resolve().parents[1] / "cells"
D5 = CELLS / "d5"

PAIRS = (
    ("saved_card_1_save", "saved_card_2_pay"),
    ("saved_card_3_challenge_save", "saved_card_4_challenge_pay"),
)

REMOVE = "saved_card_5_remove"

EXPECTED_IDS = {"control", REMOVE} | {cell_id for pair in PAIRS for cell_id in pair}


def text_of(cell_id):
    return (D5 / f"{cell_id}.yaml").read_text(encoding="utf-8")


def test_d5_is_exactly_the_cells_the_plan_promised():
    assert {p.stem for p in D5.glob("*.yaml")} == EXPECTED_IDS


@pytest.mark.parametrize("platform", ["android", "ios"])
def test_the_d5_cells_satisfy_the_shared_authoring_rules(platform):
    loaded = check_cell_dir(D5, platform)

    assert {c.id for c in loaded} == EXPECTED_IDS
    assert len(loaded) == 6


def test_the_control_cell_is_the_same_payment_in_every_dimension():
    d0 = (CELLS / "d0" / "control.yaml").read_bytes()
    assert (D5 / "control.yaml").read_bytes() == d0


@pytest.mark.parametrize("platform", ["android", "ios"])
@pytest.mark.parametrize("store, pay", PAIRS)
def test_each_pair_stores_before_it_pays(store, pay, platform):
    order = [c.id for c in cells.load_cells(D5, platform)]
    assert order.index(store) < order.index(pay), (
        f"{pay} would run before {store}, so its session would be minted "
        "before the card it re-uses exists"
    )


@pytest.mark.parametrize("platform", ["android", "ios"])
def test_the_removal_cell_runs_after_the_pair_that_seeds_it(platform):
    store, pay = PAIRS[0]
    order = [c.id for c in cells.load_cells(D5, platform)]

    assert order.index(REMOVE) > order.index(pay) > order.index(store)


def test_the_removal_cell_deletes_the_card_its_own_customer_stored():
    store, _ = PAIRS[0]
    reference = re.search(r'merchant_reference: "([^"]+)"', text_of(store)).group(1)

    assert f'merchant_reference: "{reference}"' in text_of(REMOVE)
    assert "allow_removal: true" in text_of(REMOVE)


@pytest.mark.parametrize("store, pay", PAIRS)
def test_each_pair_shares_one_pinned_customer(store, pay):
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
    used = {}
    for store, _ in PAIRS:
        cell = cells.load_cell(D5 / f"{store}.yaml")
        used[store] = cell.session.options["customer"]["merchant_reference"]
    assert len(set(used.values())) == len(PAIRS), (
        f"the pairs share a customer reference: {used}"
    )


@pytest.mark.parametrize("store, _pay", PAIRS)
def test_every_store_cell_renders_the_box_and_ticks_it(store, _pay):
    cell = cells.load_cell(D5 / f"{store}.yaml")
    assert "save_card_config" in cell.session.options, store
    assert cell.session.options["save_card_config"].get("usage") == "card_on_file"
    assert "save_card" in {a.verb for a in cell.actions}, store
    assert cell.expected.merchant.get("saved_card_saved") is True, store


@pytest.mark.parametrize("store, _pay", PAIRS)
def test_every_store_cell_ticks_the_box_before_it_types_the_card(store, _pay):
    cell = cells.load_cell(D5 / f"{store}.yaml")
    verbs = [a.verb for a in cell.actions]
    assert verbs.index("save_card") < verbs.index("type_card"), (
        f"{store}: typing first raises a keyboard that makes the iOS toggle unreachable"
    )


@pytest.mark.parametrize("_store, pay", PAIRS)
def test_every_pay_cell_asks_for_the_snapshot_and_selects_from_it(_store, pay):
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
    cell = cells.load_cell(D5 / f"{pay}.yaml")
    assert "type_card" not in {a.verb for a in cell.actions}, pay


def test_every_pan_is_quoted_and_is_one_the_sandbox_still_recognises():
    live = {"0000", "3220"}
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
    cell = cells.load_cell(D5 / f"{pay}.yaml")
    assert len(cell.card.cvv) == 3, f"{pay}: {cell.card.cvv!r}"
