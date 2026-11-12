from pathlib import Path

import pytest

from cell_rules import check_cell_dir

from tool.e2e import cells

CELLS = Path(__file__).resolve().parents[1] / "cells"
D4 = CELLS / "d4"

ANDROID_ONLY = {"google_pay_offered", "google_pay_absent_on_aft"}

EXPECTED_IDS = {"control"} | ANDROID_ONLY


def test_d4_is_exactly_the_cells_the_plan_promised():
    assert {p.stem for p in D4.glob("*.yaml")} == EXPECTED_IDS


@pytest.mark.parametrize("platform, count", [("android", 3), ("ios", 1)])
def test_the_d4_cells_satisfy_the_shared_authoring_rules(platform, count):
    loaded = check_cell_dir(D4, platform)

    assert {c.id for c in loaded} == (
        EXPECTED_IDS if platform == "android" else EXPECTED_IDS - ANDROID_ONLY
    )
    assert len(loaded) == count


def test_no_ios_cell_reaches_for_a_wallet():
    for cell in cells.load_cells(D4, "ios"):
        assert not {"tap_google_pay"} & {a.verb for a in cell.actions}, cell.id
        assert not {"google_pay", "no_google_pay"} & {
            a.arg for a in cell.actions if a.verb == "expect"
        }, cell.id


def test_the_wallet_cells_leave_by_cancelling_rather_than_paying():
    for cell in cells.load_cells(D4, "android"):
        if cell.id == "control":
            continue
        verbs = [a.verb for a in cell.actions]
        assert "cancel_form" in verbs, cell.id
        assert "tap_pay" not in verbs, cell.id
        assert cell.expected_for("android").label == "result:cancelled", cell.id


def test_the_absence_cell_mints_the_session_that_makes_the_absence_mean_something():
    absent = next(c for c in cells.load_cells(D4, "android") if "absent" in c.id)
    funding = absent.session.options.get("account_funding")
    verbs = [a.verb for a in absent.actions]

    assert isinstance(funding, dict), f"{absent.id}: no account_funding block"
    assert funding.get("sender_is_recipient") is True, absent.id
    assert ("expect", "no_google_pay") == (verbs[-3], absent.actions[-3].arg)


def test_the_presence_cell_mints_an_ordinary_session():
    offered = next(
        c for c in cells.load_cells(D4, "android") if c.id.endswith("offered")
    )
    verbs = [a.verb for a in offered.actions]

    assert offered.session.options == {}, offered.id
    assert ("expect", "google_pay") == (verbs[-3], offered.actions[-3].arg)
