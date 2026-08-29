"""The shipped D0 cells are data, and data has typos too.

These run without a device, so a malformed cell fails in CI in under a second
rather than twenty minutes into an emulator run.

The rules that are not about D0 in particular live in `cell_rules.py`: every
dimension from D1 on needs the same ones, and a rule copied seven times is a
rule that will differ seven ways. What stays here is what is true of D0 and of
nothing else -- its six cells, and the shape of the one that observes a
non-result.
"""

from pathlib import Path

import pytest

# A sibling module, imported the way pytest resolves one: its default import
# mode prepends this directory to sys.path, and `tests` is not a package.
# `conftest.py` is what puts the repo root there for `tool.e2e`.
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
    # D0 is the set that is green on both platforms today. A verb Plan B adds
    # for D3 or D5 appearing here would be a cell that has quietly stopped
    # being that.
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
    # The shared rule only requires the key. D0 goes further: every one of its
    # non-success cells really does assert `true`.
    for cell in cells.load_cells(D0, platform):
        expected = cell.expected_for(platform)
        if expected.label.startswith("result:success"):
            continue
        assert expected.merchant.get("no_succeeded_txn") is True, cell.id


def test_the_rearm_cell_expects_one_recovery_on_both_platforms():
    # Observed on both: the 2026-08-29 Android run returned
    # failure.recovery = change_method, same as iOS.
    cell = cells.load_cell(D0 / "challenge_authentication_failed_rearm.yaml")

    assert cell.expected_for("android").merchant["failure_recovery"] == "change_method"
    assert cell.expected_for("ios").merchant["failure_recovery"] == "change_method"
    assert cell.expected_for("android").rearmed is True


def test_the_rearm_cell_leaves_the_sheet_the_only_way_a_shopper_could():
    # The re-arm is a non-result: the sheet stays up and Dart is told nothing.
    # So the cell has to observe the predicate and then get out by hand, and
    # `result:cancelled` is the only outcome that shape can end in. Asserting
    # the shape here keeps a later edit from dropping the `expect` -- which
    # `load_cell` would now refuse, but only because `rearmed: true` is beside
    # it; drop both and the cell still loads and stops testing the predicate.
    cell = cells.load_cell(D0 / "challenge_authentication_failed_rearm.yaml")
    verbs = [a.verb for a in cell.actions]

    assert ("expect", "rearmed") == (verbs[-3], cell.actions[-3].arg)
    assert verbs[-2] == "cancel_form"
    assert cell.expected.label == "result:cancelled"
