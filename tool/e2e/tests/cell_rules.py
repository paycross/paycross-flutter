"""The authoring rules every dimension's cell directory must satisfy.

`cells.py` validates that an assertion is *well-formed*; nothing there can
say whether the set of assertions a cell makes is strong enough to mean
anything. These are that second thing, and they live here rather than in one
dimension's test file because D0 through D6 all need them and a rule copied
seven times is a rule that will differ seven ways.
"""

from pathlib import Path

from tool.e2e import cells

#: 4111111111153055 approves without 3DS on TEST (io.paycross#870), and
#: 4111111111150069 / 4111111111150127 lost their magic entries in
#: payment-sandbox 66db130 and now approve too. A cell that used one would
#: quietly measure an approval and call it a decline.
APPROVING_PANS = ("4111111111153055", "4111111111150069", "4111111111150127")

#: A cell ends by looking for an outcome, one way or the other.
TERMINAL_VERBS = ("wait_result", "expect")


def check_cell_dir(directory: Path, platform: str) -> list[cells.Cell]:
    loaded = cells.load_cells(directory, platform)
    assert loaded, f"{directory}: no cell runs on {platform}"
    assert any(c.id == "control" for c in loaded), (
        f"{directory}: no 'control' cell, so no failure here could be checked "
        "against a known-good payment"
    )
    for cell in loaded:
        text = cell.path.read_text(encoding="utf-8")
        expected = cell.expected_for(platform)
        verbs = {a.verb for a in cell.actions}

        assert cell.actions[-1].verb in TERMINAL_VERBS, cell.id
        for pan in APPROVING_PANS:
            assert pan not in text, f"{cell.id} uses {pan}, which approves on TEST"
        if "no_succeeded_txn" in expected.merchant:
            assert {"session_status", "txn_count"} & set(expected.merchant), (
                f"{cell.id}: no_succeeded_txn passes vacuously against a "
                "degenerate resource; pin it to a session that exists"
            )
        # No `rearmed` <-> `expect rearmed` assertion here: `load_cell` now
        # refuses that pairing outright, so a cell breaking it never reaches
        # this loop and the assertion would be dead code.
        if not expected.label.startswith("result:success"):
            assert "no_succeeded_txn" in expected.merchant, cell.id
        assert "airplane" not in verbs or platform == "android", (
            f"{cell.id}: airplane mode does not exist on the iOS simulator"
        )
    return loaded
