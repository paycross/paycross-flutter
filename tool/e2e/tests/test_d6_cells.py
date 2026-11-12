from pathlib import Path

import pytest

from cell_rules import check_cell_dir

from tool.e2e import cells

CELLS = Path(__file__).resolve().parents[1] / "cells"
D6 = CELLS / "d6"

EXPECTED_IDS = {"control", "french_device", "french_session"}


@pytest.mark.parametrize("platform", ["android", "ios"])
def test_the_d6_cells_satisfy_the_shared_authoring_rules(platform):
    loaded = check_cell_dir(D6, platform)

    assert {c.id for c in loaded} == EXPECTED_IDS


def test_d6_is_exactly_the_cells_the_train_promised():
    assert {p.stem for p in D6.glob("*.yaml")} == EXPECTED_IDS


def test_the_control_cell_is_the_same_payment_in_every_dimension():
    assert (D6 / "control.yaml").read_bytes() == (
        CELLS / "d0" / "control.yaml"
    ).read_bytes()


@pytest.mark.parametrize("platform", ["android", "ios"])
def test_a_localized_cell_never_expects_a_rearm(platform):
    for cell in cells.load_cells(D6, platform):
        if cell.id == "control":
            continue
        assert cell.expected_for(platform).rearmed is not True, cell.id
        assert ("expect", "rearmed") not in [(a.verb, a.arg) for a in cell.actions], (
            cell.id
        )


@pytest.mark.parametrize("platform", ["android", "ios"])
def test_the_french_cell_differs_from_the_control_only_in_its_locale(platform):
    loaded = {c.id: c for c in cells.load_cells(D6, platform)}
    control, french = loaded["control"], loaded["french_session"]

    assert french.session.options == {"locale": "fr"}
    assert control.session.options == {}
    assert french.session.amount == control.session.amount
    assert french.session.currency == control.session.currency
    assert _driving(french) == _driving(control)
    assert ("expect", "french_sheet") in [(a.verb, a.arg) for a in french.actions]
    assert (
        french.expected_for(platform).merchant
        == control.expected_for(platform).merchant
    )


@pytest.mark.parametrize("platform", ["android", "ios"])
def test_the_device_cell_asks_for_a_language_nothing_else_can_supply(platform):
    device = {c.id: c for c in cells.load_cells(D6, platform)}["french_device"]
    actions = [(a.verb, a.arg) for a in device.actions]

    assert device.session.options == {"locale": "zz"}
    assert ("device_language", "fr") in actions
    assert ("expect", "french_sheet") in actions
    assert actions[-1] == ("device_language", cells.DEVICE_LANGUAGE_DEFAULT)


def _driving(cell) -> list[tuple[str, str | None]]:
    return [(a.verb, a.arg) for a in cell.actions if a.verb != "expect"]
