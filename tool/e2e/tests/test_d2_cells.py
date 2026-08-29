"""The D2 cells are data, and data has typos too.

D2 is the failure matrix: every way a payment can end that is not an approval
-- issuer declines, ACS declines, a provider that never answers, a shopper who
walks away, four integration errors and three network cuts. It is the first
dimension with cells that *discover* rather than assert, and the first with
cells that run on one platform only, so both of those get a rule here.

Everything that is true of every dimension lives in `cell_rules.py`. What
stays here is what is true of D2 and of nothing else.
"""

import re
from pathlib import Path

import pytest

# A sibling module, imported the way pytest resolves one -- see the note in
# `test_d0_cells.py`.
from cell_rules import check_cell_dir

from tool.e2e import cells

CELLS = Path(__file__).resolve().parents[1] / "cells"
D2 = CELLS / "d2"

#: The cells that cut the network, and so the cells that cannot run on the iOS
#: simulator: it shares the host's network and every route to cutting that
#: needs sudo or the GUI, so `IosDriver.airplane` refuses rather than
#: pretending. `cell_rules` enforces the platform list; this names the three so
#: the per-platform counts below are readable rather than arithmetic.
ANDROID_ONLY = {
    "airplane_before_submit",
    "airplane_during_challenge",
    "airplane_during_polling",
}

EXPECTED_IDS = {
    "control",
    "acs_authentication_rejected",
    "acs_card_expired",
    "acs_do_not_honor",
    "acs_invalid_cvv",
    "cancel_on_form",
    "completed_session_represented",
    "decline_do_not_honor",
    "decline_fraud_suspected",
    "decline_insufficient_funds",
    "error_blank_token",
    "error_malformed_token",
    "session_expired_jwt",
    "session_expired_server",
    "timeout_provider_never_answers",
} | ANDROID_ONLY


def test_d2_is_exactly_the_cells_the_plan_promised():
    assert {p.stem for p in D2.glob("*.yaml")} == EXPECTED_IDS


@pytest.mark.parametrize(
    "platform, count",
    [("android", 18), ("ios", 15)],
)
def test_the_d2_cells_satisfy_the_shared_authoring_rules(platform, count):
    loaded = check_cell_dir(D2, platform)

    assert {c.id for c in loaded} == (
        EXPECTED_IDS if platform == "android" else EXPECTED_IDS - ANDROID_ONLY
    )
    # The numbers the plan predicted, spelled out: a cell that quietly drops a
    # platform still satisfies every rule above and would shrink a matrix run
    # without failing anything.
    assert len(loaded) == count


def test_the_control_cell_is_the_same_payment_in_every_dimension():
    # Every dimension directory needs its own control (the runner refuses one
    # without it) and every copy must stay identical, or "the control passed"
    # means a different thing in each dimension.
    d0 = (CELLS / "d0" / "control.yaml").read_bytes()
    for path in sorted(CELLS.glob("d*/control.yaml")):
        assert path.read_bytes() == d0, f"{path} has drifted from d0's control"


def test_every_pan_is_quoted_and_is_one_the_sandbox_still_recognises():
    # Two assertions on one line of YAML, and the order matters. A quoted-only
    # regex would simply not FIND an unquoted PAN, so the scenario check would
    # go green on exactly the file it was meant to catch -- and an unquoted PAN
    # with a leading zero is YAML octal. So: find every `pan:` line first, then
    # insist it is quoted, then check it.
    live = {"0000", "0002", "9995", "0119", "3220", "3063", "0051"}  # scenarios.go
    for path in sorted(D2.glob("*.yaml")):
        for line in path.read_text(encoding="utf-8").splitlines():
            found = re.match(r"\s*pan:\s*(\S+)\s*$", line)
            if not found:
                continue
            raw = found.group(1)
            assert raw[0] == raw[-1] == '"', f"{path.name}: PAN {raw} is not quoted"
            pan = raw.strip('"')
            assert pan.isdigit(), f"{path.name}: {raw} is not digits"
            assert pan[-4:] in live, f"{path.name}: {pan} no longer has a scenario"


def test_the_discovery_cells_say_so():
    # `<any>` is a licence to record rather than assert, and every cell that
    # holds one must explain in its own comment what is being discovered --
    # otherwise a pinned expectation quietly becomes an unpinned one.
    for path in sorted(D2.glob("*.yaml")):
        text = path.read_text(encoding="utf-8")
        if '"<any>"' in text:
            assert "DISCOVER" in text.upper() or "record" in text, path.name


def test_no_ios_cell_asks_for_airplane_mode():
    for cell in cells.load_cells(D2, "ios"):
        assert "airplane" not in {a.verb for a in cell.actions}, cell.id
