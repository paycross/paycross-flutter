"""The D3 cells are data, and data has typos too.

D3 is app lifecycle: what happens to a payment in flight when the shopper
backgrounds the app, turns the phone, or the process dies under it. It is the
first dimension whose cells change the DEVICE in ways that outlive the cell,
and the first with a cell that is allowed to be excused a criterion-3 line, so
both of those get a rule here.

Everything that is true of every dimension lives in `cell_rules.py`. What
stays here is what is true of D3 and of nothing else.
"""

from pathlib import Path

import pytest

# A sibling module, imported the way pytest resolves one -- see the note in
# `test_d0_cells.py`.
from cell_rules import check_cell_dir

from tool.e2e import cells

CELLS = Path(__file__).resolve().parents[1] / "cells"
D3 = CELLS / "d3"

#: The cells that cannot run on the iOS simulator, and why each one cannot.
#: Both were measured rather than assumed, which is why they are named here
#: rather than left to `platforms:` alone: a future reader deserves the reason
#: without going to the git log.
#:
#: `dont_keep_activities` is an Android developer option and iOS has no
#: equivalent -- there is no activity to not keep, and `IosDriver` refuses the
#: verb outright.
#:
#: `rotate_after_submit` is excluded by a MEASURED iOS defect, not by a
#: platform difference: rotating with the sheet up leaves the CVV keypad
#: undismissable on the 3-D Secure challenge page, so the cell dies in the
#: driver before it can assert anything at all. payment-ios-sdk#17, with the
#: unrotated control that passes minutes apart. It goes back to both platforms
#: when that is fixed.
ANDROID_ONLY = {
    "dont_keep_activities",
    "rotate_after_submit",
}

EXPECTED_IDS = {
    "control",
    "background_during_challenge",
    "background_during_polling",
    "kill_process_during_challenge",
} | ANDROID_ONLY


def test_d3_is_exactly_the_cells_the_probes_reproduced():
    assert {p.stem for p in D3.glob("*.yaml")} == EXPECTED_IDS


@pytest.mark.parametrize("platform, count", [("android", 6), ("ios", 4)])
def test_the_d3_cells_satisfy_the_shared_authoring_rules(platform, count):
    loaded = check_cell_dir(D3, platform)

    assert {c.id for c in loaded} == (
        EXPECTED_IDS if platform == "android" else EXPECTED_IDS - ANDROID_ONLY
    )
    # The numbers spelled out: a cell that quietly drops a platform still
    # satisfies every rule above and would shrink a matrix run without failing
    # anything.
    assert len(loaded) == count


def test_the_control_cell_is_the_same_payment_in_every_dimension():
    # Every dimension directory needs its own control (the runner refuses one
    # without it) and every copy must stay identical, or "the control passed"
    # means a different thing in each dimension.
    d0 = (CELLS / "d0" / "control.yaml").read_bytes()
    for path in sorted(CELLS.glob("d*/control.yaml")):
        assert path.read_bytes() == d0, f"{path} has drifted from d0's control"


def test_only_the_developer_option_cell_is_excused_a_crash_line():
    # The allow-list is closed and validated at load, so nothing here can
    # declare something dangerous. What this catches is a cell picking up a
    # declaration it does not need -- an excuse that is not being used is an
    # excuse waiting to hide something.
    for cell in cells.load_cells(D3, "android"):
        if cell.id == "dont_keep_activities":
            assert cell.tolerated_crash_markers == ("Force finishing activity",)
        else:
            assert cell.tolerated_crash_markers == (), cell.id


def test_the_cells_that_change_the_device_put_it_back():
    # `cell_rules` already refuses an unpaired `on` and an odd number of turns.
    # This says the same thing from the cell list's side, so that a cell which
    # stops touching the device -- and therefore stops needing the teardown --
    # is noticed rather than silently keeping a stale action.
    by_id = {c.id: c for c in cells.load_cells(D3, "android")}

    keeping = [(a.verb, a.arg) for a in by_id["dont_keep_activities"].actions]
    assert ("dont_keep_activities", "on") in keeping
    assert keeping[-1] == ("dont_keep_activities", "off")

    turns = [a.verb for a in by_id["rotate_after_submit"].actions if a.verb == "rotate"]
    assert len(turns) == 2


def test_no_ios_cell_asks_for_the_verb_that_platform_refuses():
    for cell in cells.load_cells(D3, "ios"):
        assert "dont_keep_activities" not in {a.verb for a in cell.actions}, cell.id


@pytest.mark.parametrize("platform", ["android", "ios"])
def test_the_discovery_cells_say_so(platform):
    # `<any>` and `<none>` are a licence to record rather than assert, and a
    # cell holding one has to explain in its own comment what is being
    # discovered -- otherwise a pinned expectation quietly becomes an unpinned
    # one. Asked of the PARSED expectation, so an override cannot slip past.
    for cell in cells.load_cells(D3, platform):
        if cell.expected_for(platform).label in cells.LABEL_SENTINELS:
            text = cell.path.read_text(encoding="utf-8")
            assert "DISCOVER" in text.upper() or "record" in text, cell.id


def test_every_cell_uses_the_challenge_card_and_the_control_does_not():
    # D3 measures what a lifecycle event does to a payment IN FLIGHT, and the
    # only way to hold one in flight long enough is a 3-D Secure challenge.
    # A cell that quietly moved to a frictionless PAN would still pass every
    # rule above while measuring nothing this dimension is about.
    for cell in cells.load_cells(D3, "android"):
        if cell.id == "control":
            continue
        assert cell.card.pan == "4111111111153220", cell.id
