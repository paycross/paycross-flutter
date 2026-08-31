"""The shared authoring rules, exercised against cells written to break them.

`cell_rules` is what every dimension's cell directory is held to, and until D2
nothing tested the rules themselves -- only that D0 satisfied them, which a
rule that never fires also does.
"""

import textwrap
from pathlib import Path

import pytest
from cell_rules import check_cell_dir

CONTROL = """\
id: control
platforms: [android]
card: {pan: "4111111111170000", expiry: "12/28", cvv: "123"}
session: {amount: 1000, currency: EUR}
actions:
  - paste_token
  - type_card
  - tap_pay
  - wait_result 60
expected:
  label: "result:success:<txn>"
  merchant:
    session_status: completed
    txn_count: 1
"""

#: A decline cell with `{actions}` left open, so each test writes only the
#: action list it is about.
CELL = """\
id: {id}
platforms: [android]
card: {{pan: "4111111111153220", expiry: "12/28", cvv: "123"}}
session: {{amount: 1000, currency: EUR}}
actions:
{actions}
expected:
  label: "result:failure:retry:<txn>"
  merchant:
    session_status: open
    no_succeeded_txn: true
"""


def directory(tmp_path, cell_id, actions):
    where = tmp_path / "cells"
    where.mkdir(exist_ok=True)
    (where / "control.yaml").write_text(textwrap.dedent(CONTROL), encoding="utf-8")
    body = "".join(f"  - {a}\n" for a in actions)
    (where / f"{cell_id}.yaml").write_text(
        CELL.format(id=cell_id, actions=body), encoding="utf-8"
    )
    return where


CUT_AND_RESTORE = [
    "paste_token",
    "type_card",
    "airplane on",
    "tap_pay",
    "wait_result 60",
    "airplane off",
]


def test_teardown_is_allowed_after_the_action_that_reads_the_outcome(tmp_path):
    where = directory(tmp_path, "network_cut", CUT_AND_RESTORE)

    assert {c.id for c in check_cell_dir(where, "android")} == {
        "control",
        "network_cut",
    }


@pytest.mark.parametrize("verb", ["airplane", "dont_keep_activities"])
def test_a_cell_that_turns_a_rig_setting_on_must_turn_it_off(tmp_path, verb):
    # Neither is undone by a failure, and both poison every cell that follows
    # -- which the drivers' launch guards then report as a rig fault,
    # correctly but expensively.
    where = directory(
        tmp_path,
        "network_cut",
        ["paste_token", "type_card", f"{verb} on", "tap_pay", "wait_result 60"],
    )

    with pytest.raises(AssertionError, match="never off"):
        check_cell_dir(where, "android")


def test_only_teardown_may_follow_the_action_that_reads_the_outcome(tmp_path):
    # A cell whose last real action is not terminal never asks for an outcome,
    # so there is nothing for the expectation to be about.
    where = directory(
        tmp_path,
        "network_cut",
        ["paste_token", "type_card", "airplane on", "tap_pay", "airplane off"],
    )

    with pytest.raises(AssertionError):
        check_cell_dir(where, "android")


def test_a_bare_wait_belongs_only_to_the_expiry_recipes(tmp_path):
    # `wait` exists to spend the 300 s between a token's JWT `exp` and its
    # session's `expires_at`. Anywhere else it is a cell papering over a race.
    where = directory(
        tmp_path,
        "slow_sheet",
        ["paste_token", "wait 30", "type_card", "tap_pay", "wait_result 60"],
    )

    with pytest.raises(AssertionError, match="expiry recipes"):
        check_cell_dir(where, "android")


@pytest.mark.parametrize("cell_id", ["session_expired", "expired_jwt"])
def test_the_expiry_cells_may_wait(tmp_path, cell_id):
    where = directory(
        tmp_path,
        cell_id,
        ["wait 300", "present_token", "wait_result 60"],
    )

    assert {c.id for c in check_cell_dir(where, "android")} == {"control", cell_id}


def test_the_ios_refusal_of_airplane_mode_still_stands(tmp_path):
    # R6: the simulator shares the host's network, so every network-cut cell
    # is `platforms: [android]`.
    where = tmp_path / "cells"
    where.mkdir()
    (where / "control.yaml").write_text(
        textwrap.dedent(CONTROL).replace("[android]", "[android, ios]"),
        encoding="utf-8",
    )
    body = "".join(f"  - {a}\n" for a in CUT_AND_RESTORE)
    (where / "network_cut.yaml").write_text(
        CELL.format(id="network_cut", actions=body).replace(
            "platforms: [android]", "platforms: [android, ios]"
        ),
        encoding="utf-8",
    )

    with pytest.raises(AssertionError, match="iOS simulator"):
        check_cell_dir(Path(where), "ios")
