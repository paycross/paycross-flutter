import re
from pathlib import Path

import pytest

from cell_rules import check_cell_dir

from tool.e2e import cells

CELLS = Path(__file__).resolve().parents[1] / "cells"
D2 = CELLS / "d2"

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
    "cancel_dismissed_then_paid",
    "cancel_on_form",
    "completed_session_represented",
    "decline_do_not_honor",
    "decline_fraud_suspected",
    "decline_insufficient_funds",
    "error_blank_token",
    "error_malformed_token",
    "session_expired_jwt",
    "session_expired_server",
    "session_expired_server_submit",
    "timeout_provider_never_answers",
} | ANDROID_ONLY


def test_d2_is_exactly_the_cells_the_plan_promised():
    assert {p.stem for p in D2.glob("*.yaml")} == EXPECTED_IDS


@pytest.mark.parametrize(
    "platform, count",
    [("android", 20), ("ios", 17)],
)
def test_the_d2_cells_satisfy_the_shared_authoring_rules(platform, count):
    loaded = check_cell_dir(D2, platform)

    assert {c.id for c in loaded} == (
        EXPECTED_IDS if platform == "android" else EXPECTED_IDS - ANDROID_ONLY
    )
    assert len(loaded) == count


def test_the_control_cell_is_the_same_payment_in_every_dimension():
    d0 = (CELLS / "d0" / "control.yaml").read_bytes()
    for path in sorted(CELLS.glob("d*/control.yaml")):
        assert path.read_bytes() == d0, f"{path} has drifted from d0's control"


def test_every_pan_is_quoted_and_is_one_the_sandbox_still_recognises():
    live = {"0000", "0002", "9995", "0119", "3220", "3063", "0051"}
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


@pytest.mark.parametrize("platform", ["android", "ios"])
def test_the_discovery_cells_say_so(platform):
    for cell in cells.load_cells(D2, platform):
        if cell.expected_for(platform).label == cells.ANY_LABEL:
            text = cell.path.read_text(encoding="utf-8")
            assert "DISCOVER" in text.upper() or "record" in text, cell.id


def test_no_ios_cell_asks_for_airplane_mode():
    for cell in cells.load_cells(D2, "ios"):
        assert "airplane" not in {a.verb for a in cell.actions}, cell.id
