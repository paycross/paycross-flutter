from pathlib import Path

import pytest
from cell_rules import check_cell_dir

from tool.e2e import cells

D0 = Path(__file__).resolve().parents[1] / "cells" / "d0"

EXPECTED_IDS = {
    "control",
    "frictionless",
    "challenge_approve",
    "challenge_fraud_suspected",
    "challenge_authentication_failed_rearm",
    "cancel_mid_challenge",
}


@pytest.mark.parametrize("platform", ["android", "ios"])
def test_the_d0_cells_satisfy_the_shared_authoring_rules(platform):
    loaded = check_cell_dir(D0, platform)

    assert {c.id for c in loaded} == EXPECTED_IDS


def test_d0_is_exactly_the_six_cells_phase_0_promised():
    assert {p.stem for p in D0.glob("*.yaml")} == EXPECTED_IDS


@pytest.mark.parametrize("platform", ["android", "ios"])
def test_no_d0_cell_reaches_for_an_action_a_later_phase_owns(platform):
    later = {
        "background",
        "rotate",
        "airplane",
        "kill_activity",
        "dont_keep_activities",
        "relaunch",
        "tap_google_pay",
        "select_saved_card",
        "save_card",
        "enter_token",
        "present_token",
    }

    for cell in cells.load_cells(D0, platform):
        assert {a.verb for a in cell.actions} & later == set()


@pytest.mark.parametrize("platform", ["android", "ios"])
def test_every_non_success_d0_cell_asserts_no_money_moved(platform):
    for cell in cells.load_cells(D0, platform):
        expected = cell.expected_for(platform)
        if expected.label.startswith("result:success"):
            continue
        assert expected.merchant.get("no_succeeded_txn") is True, cell.id


def test_the_rearm_cell_expects_one_recovery_on_both_platforms():
    cell = cells.load_cell(D0 / "challenge_authentication_failed_rearm.yaml")

    assert cell.expected_for("android").merchant["failure_recovery"] == "change_method"
    assert cell.expected_for("ios").merchant["failure_recovery"] == "change_method"
    assert cell.expected_for("android").rearmed is True


def test_the_rearm_cell_leaves_the_sheet_the_only_way_a_shopper_could():
    cell = cells.load_cell(D0 / "challenge_authentication_failed_rearm.yaml")
    verbs = [a.verb for a in cell.actions]

    assert ("expect", "rearmed") == (verbs[-3], cell.actions[-3].arg)
    assert verbs[-2] == "cancel_form"
    assert cell.expected.label == "result:cancelled"
