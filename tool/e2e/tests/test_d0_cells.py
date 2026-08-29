"""The shipped D0 cells are data, and data has typos too.

These run without a device, so a malformed cell fails in CI in under a second
rather than twenty minutes into an emulator run. The last three tests are not
about YAML syntax at all -- they are the cell-authoring rules the design
review asked for, held here because nothing else can hold them: `cells.py`
validates that an assertion is well-formed, not that the set of assertions a
cell makes is strong enough to mean anything.
"""

from pathlib import Path

import pytest

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
def test_every_d0_cell_loads_on_both_platforms(platform):
    loaded = cells.load_cells(D0, platform)

    assert {c.id for c in loaded} == EXPECTED_IDS


def test_d0_is_exactly_the_six_cells_phase_0_promised():
    assert {p.stem for p in D0.glob("*.yaml")} == EXPECTED_IDS


@pytest.mark.parametrize("platform", ["android", "ios"])
def test_no_cell_reaches_for_an_action_phase_0_has_not_implemented(platform):
    unimplemented = {"background", "rotate", "airplane", "kill_activity"}

    for cell in cells.load_cells(D0, platform):
        assert {a.verb for a in cell.actions} & unimplemented == set()


@pytest.mark.parametrize("platform", ["android", "ios"])
def test_every_cell_ends_by_waiting_for_a_result(platform):
    for cell in cells.load_cells(D0, platform):
        assert cell.actions[-1].verb == "wait_result", cell.id


@pytest.mark.parametrize("platform", ["android", "ios"])
def test_every_non_success_cell_asserts_no_succeeded_transaction(platform):
    for cell in cells.load_cells(D0, platform):
        expected = cell.expected_for(platform)
        if expected.label.startswith("result:success"):
            continue
        assert expected.merchant.get("no_succeeded_txn") is True, cell.id


def test_the_rearm_cell_carries_a_per_platform_recovery_expectation():
    cell = cells.load_cell(D0 / "challenge_authentication_failed_rearm.yaml")

    assert cell.expected_for("android").merchant["failure_recovery"] is None
    assert cell.expected_for("ios").merchant["failure_recovery"] == "change_method"
    assert cell.expected_for("android").rearmed is True


def test_the_excluded_sandbox_card_appears_nowhere():
    # 4111111111153055 approves without 3DS on TEST (io.paycross#870).
    for path in D0.glob("*.yaml"):
        assert "4111111111153055" not in path.read_text(encoding="utf-8")


@pytest.mark.parametrize("platform", ["android", "ios"])
def test_no_succeeded_txn_is_always_pinned_to_a_session_that_exists(platform):
    # `no_succeeded_txn` passes vacuously against a degenerate resource: {} has
    # no succeeded transactions either. On its own it cannot tell "the payment
    # correctly did not go through" from "the session was never read". Pairing
    # it with a positive assertion -- a status, a count -- is what makes it
    # evidence, so the design review made the pairing a rule.
    for cell in cells.load_cells(D0, platform):
        merchant = cell.expected_for(platform).merchant
        if not merchant.get("no_succeeded_txn"):
            continue
        assert {"session_status", "txn_count"} & set(merchant), cell.id


def test_the_rearm_cell_leaves_the_sheet_the_only_way_a_shopper_could():
    # The re-arm is a non-result: the sheet stays up and Dart is told nothing.
    # So the cell has to observe the predicate and then get out by hand, and
    # `result:cancelled` is the only outcome that shape can end in. Asserting
    # the shape here keeps a later edit from dropping the `expect` -- which
    # would still load, still pass, and silently stop testing the predicate.
    cell = cells.load_cell(D0 / "challenge_authentication_failed_rearm.yaml")
    verbs = [a.verb for a in cell.actions]

    assert ("expect", "rearmed") == (verbs[-3], cell.actions[-3].arg)
    assert verbs[-2] == "cancel_form"
    assert cell.expected.label == "result:cancelled"
