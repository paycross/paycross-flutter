"""The D6 cells are data, and data has typos too.

D6 is localization: the same payment the control makes, with the sheet drawn
in another language. It is the dimension the identifier switch bought. Every
matcher on the SDK's sheet used to be a rendered English string, and the
Android driver refused to launch against a device that was not `en-US`
because of it, so a cell like `french_session` could not have been written
and would not have run.

Everything that is true of every dimension lives in `cell_rules.py`. What
stays here is what is true of D6 and of nothing else -- the one thing a
localized cell may not ask for.
"""

from pathlib import Path

import pytest

# A sibling module, imported the way pytest resolves one -- see the note in
# `test_d0_cells.py`.
from cell_rules import check_cell_dir

from tool.e2e import cells

CELLS = Path(__file__).resolve().parents[1] / "cells"
D6 = CELLS / "d6"

EXPECTED_IDS = {"control", "french_session"}


@pytest.mark.parametrize("platform", ["android", "ios"])
def test_the_d6_cells_satisfy_the_shared_authoring_rules(platform):
    loaded = check_cell_dir(D6, platform)

    assert {c.id for c in loaded} == EXPECTED_IDS


def test_d6_is_exactly_the_cells_the_train_promised():
    assert {p.stem for p in D6.glob("*.yaml")} == EXPECTED_IDS


def test_the_control_cell_is_the_same_payment_in_every_dimension():
    # The same rule D0, D2 and D5 assert. "The control passed" has to mean one
    # thing everywhere, and a new directory is exactly where it gets forgotten.
    assert (D6 / "control.yaml").read_bytes() == (
        CELLS / "d0" / "control.yaml"
    ).read_bytes()


@pytest.mark.parametrize("platform", ["android", "ios"])
def test_a_localized_cell_never_expects_a_rearm(platform):
    """The one thing the drivers still cannot do in another language.

    `expect rearmed` reaches `tree.sheet_rearmed`, which asks that the sheet's
    amount be the cell's. The expectation is computed by
    `tree.format_amount_en_us` and nothing translates it: it renders `€10.00`
    where a French sheet draws `10,00 €`, and `_carries_amount` swaps the
    decimal separator but does not move the currency symbol.

    So a French cell that expected a re-arm would fail on the amount while the
    sheet had plainly re-armed. `wait_rearmed` now says so out loud rather than
    answering False -- it names the amount the sheet was showing and blames the
    rig -- but a cell that cannot pass should not be written in the first
    place. Whoever wants one teaches `_separator_variants` about a trailing
    symbol first, and deletes this test in the same commit.
    """
    for cell in cells.load_cells(D6, platform):
        if cell.id == "control":
            continue
        assert cell.expected_for(platform).rearmed is not True, cell.id
        assert ("expect", "rearmed") not in [(a.verb, a.arg) for a in cell.actions], (
            cell.id
        )


@pytest.mark.parametrize("platform", ["android", "ios"])
def test_the_french_cell_differs_from_the_control_only_in_its_locale(platform):
    # The claim of the dimension: the language changes what is read and
    # nothing else. Asserted over the loaded cells rather than the files, so
    # it survives the comments the two carry being entirely different.
    loaded = {c.id: c for c in cells.load_cells(D6, platform)}
    control, french = loaded["control"], loaded["french_session"]

    assert french.session.options == {"locale": "fr"}
    assert control.session.options == {}
    assert french.session.amount == control.session.amount
    assert french.session.currency == control.session.currency
    assert [(a.verb, a.arg) for a in french.actions] == [
        (a.verb, a.arg) for a in control.actions
    ]
    assert (
        french.expected_for(platform).merchant
        == control.expected_for(platform).merchant
    )
