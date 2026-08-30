"""The D4 cells are data, and data has typos too.

D4 is the wallet dimension: whether the SDK offers Google Pay when the session
allows it, and -- the harder half -- whether it withholds the button when the
session does not. Everything true of every dimension lives in `cell_rules.py`.
What stays here is what is true of D4 and of nothing else.

The rule that matters most is the last one. `google_pay_absent_on_aft` asserts
an absence, and an absence asserted against the wrong session is not an
assertion at all: without the account-funding block the wallet stays eligible,
the button renders, and the cell fails while reporting something that is not
about the SDK. So the block is checked here rather than trusted.
"""

from pathlib import Path

import pytest

# A sibling module, imported the way pytest resolves one -- see the note in
# `test_d0_cells.py`.
from cell_rules import check_cell_dir

from tool.e2e import cells

CELLS = Path(__file__).resolve().parents[1] / "cells"
D4 = CELLS / "d4"

#: Both wallet cells. The iOS SDK has no wallet at all and Apple Pay is an
#: explicit campaign non-goal, so `IosDriver` refuses the whole D4 vocabulary
#: and these two are `platforms: [android]`.
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
    # Spelled out: a cell that quietly drops a platform still satisfies every
    # rule above and would shrink a matrix run without failing anything.
    assert len(loaded) == count


def test_no_ios_cell_reaches_for_a_wallet():
    for cell in cells.load_cells(D4, "ios"):
        assert not {"tap_google_pay"} & {a.verb for a in cell.actions}, cell.id
        assert not {"google_pay", "no_google_pay"} & {
            a.arg for a in cell.actions if a.verb == "expect"
        }, cell.id


def test_the_wallet_cells_leave_by_cancelling_rather_than_paying():
    # A wallet payment is its own cell and this dimension's two presence cells
    # must not spend one: they prove what the sheet offers, then abandon.
    # Without this, a cell that grew a `tap_pay` would still satisfy every
    # shared rule while quietly charging the card it was only meant to look at.
    for cell in cells.load_cells(D4, "android"):
        if cell.id == "control":
            continue
        verbs = [a.verb for a in cell.actions]
        assert "cancel_form" in verbs, cell.id
        assert "tap_pay" not in verbs, cell.id
        assert cell.expected_for("android").label == "result:cancelled", cell.id


def test_the_absence_cell_mints_the_session_that_makes_the_absence_mean_something():
    # The suppression is `data.account_funding`, computed by core's
    # SessionDataService and read by GooglePayRequests.isSessionEligible with
    # strict `!= true` semantics. Mint without the block and the session is
    # ordinary, the button renders, and the cell reports a failure that is not
    # about the SDK. Measured on TEST 2026-08-31: the checkout snapshot reads
    # `data.account_funding: true` with this block and `false` without it.
    absent = next(c for c in cells.load_cells(D4, "android") if "absent" in c.id)
    funding = absent.session.options.get("account_funding")
    verbs = [a.verb for a in absent.actions]

    assert isinstance(funding, dict), f"{absent.id}: no account_funding block"
    assert funding.get("sender_is_recipient") is True, absent.id
    # The session and the expectation are one assertion, not two: an AFT
    # session asked for `google_pay` measures nothing, and the pair is what
    # this dimension is. Pinned by position, as D0 pins its re-arm cell --
    # without it the two cells' expectations can be swapped and all of these
    # tests stay green while both cells fail on the device.
    assert ("expect", "no_google_pay") == (verbs[-3], absent.actions[-3].arg)


def test_the_presence_cell_mints_an_ordinary_session():
    # The other half of the pair, and the reason the two are worth running
    # together: the only difference between them must be the session, or a
    # difference in the button proves nothing about what suppressed it.
    offered = next(
        c for c in cells.load_cells(D4, "android") if c.id.endswith("offered")
    )
    verbs = [a.verb for a in offered.actions]

    assert offered.session.options == {}, offered.id
    assert ("expect", "google_pay") == (verbs[-3], offered.actions[-3].arg)
