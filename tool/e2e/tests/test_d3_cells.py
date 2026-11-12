from pathlib import Path

import pytest

from cell_rules import check_cell_dir

from tool.e2e import cells

CELLS = Path(__file__).resolve().parents[1] / "cells"
D3 = CELLS / "d3"

ANDROID_ONLY = {
    "rotate_after_submit",
}

NO_CELL_FOR = {"dont_keep_activities"}

EXPECTED_IDS = {
    "control",
    "background_during_challenge",
    "background_during_polling",
    "kill_process_during_challenge",
} | ANDROID_ONLY


def test_d3_is_exactly_the_cells_the_probes_reproduced():
    assert {p.stem for p in D3.glob("*.yaml")} == EXPECTED_IDS


@pytest.mark.parametrize("platform, count", [("android", 5), ("ios", 4)])
def test_the_d3_cells_satisfy_the_shared_authoring_rules(platform, count):
    loaded = check_cell_dir(D3, platform)

    assert {c.id for c in loaded} == (
        EXPECTED_IDS if platform == "android" else EXPECTED_IDS - ANDROID_ONLY
    )
    assert len(loaded) == count


def test_the_control_cell_is_the_same_payment_in_every_dimension():
    d0 = (CELLS / "d0" / "control.yaml").read_bytes()
    for path in sorted(CELLS.glob("d*/control.yaml")):
        assert path.read_bytes() == d0, f"{path} has drifted from d0's control"


def test_no_d3_cell_is_excused_a_crash_line():
    for cell in cells.load_cells(D3, "android"):
        assert cell.tolerated_crash_markers == (), cell.id


def test_the_cell_that_turns_the_device_puts_it_back():
    by_id = {c.id: c for c in cells.load_cells(D3, "android")}

    turns = [a.verb for a in by_id["rotate_after_submit"].actions if a.verb == "rotate"]
    assert len(turns) == 2


def test_no_cell_asks_for_the_verb_this_rig_cannot_deliver():
    for platform in ("android", "ios"):
        for cell in cells.load_cells(D3, platform):
            assert NO_CELL_FOR.isdisjoint({a.verb for a in cell.actions}), cell.id


@pytest.mark.parametrize("platform", ["android", "ios"])
def test_the_discovery_cells_say_so(platform):
    for cell in cells.load_cells(D3, platform):
        if cell.expected_for(platform).label in cells.LABEL_SENTINELS:
            text = cell.path.read_text(encoding="utf-8")
            assert "DISCOVER" in text.upper() or "record" in text, cell.id


def test_every_cell_uses_the_challenge_card_and_the_control_does_not():
    for cell in cells.load_cells(D3, "android"):
        if cell.id == "control":
            continue
        assert cell.card.pan == "4111111111153220", cell.id
