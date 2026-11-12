from pathlib import Path

from tool.e2e import cells

# WHY: these PANs approve on TEST, so a cell that uses one would measure an approval, not a decline.
APPROVING_PANS = ("4111111111153055", "4111111111150069", "4111111111150127")

TERMINAL_VERBS = ("wait_result", "expect")

TEARDOWN = cells.TEARDOWN


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
        actions = [(a.verb, a.arg) for a in cell.actions]
        verbs = {a.verb for a in cell.actions}

        tail = list(actions)
        while tail and tail[-1] in TEARDOWN:
            tail.pop()
        assert tail and tail[-1][0] in TERMINAL_VERBS, cell.id
        for verb, restore in sorted(TEARDOWN):
            if any(v == verb and a != restore for v, a in actions):
                assert (verb, restore) in actions, (
                    f"{cell.id}: changes {verb} and never puts it back with "
                    f"`{verb} {restore}`"
                )
        for index, (verb, arg) in enumerate(actions):
            if verb != "device_language" or arg == cells.DEVICE_LANGUAGE_DEFAULT:
                continue
            following = actions[index + 1] if index + 1 < len(actions) else None
            assert following == ("relaunch", None), (
                f"{cell.id}: sets the device language to {arg!r} and does not "
                "relaunch next, so the app never sees it"
            )
        turns = sum(1 for verb, _ in actions if verb == "rotate")
        assert turns % 2 == 0, (
            f"{cell.id}: rotates {turns} time(s), so it leaves the device "
            "turned for every cell after it; rotate back before the cell ends"
        )
        if any(v == "wait" for v, _ in actions):
            assert "expired" in cell.id or "jwt" in cell.id, (
                f"{cell.id}: a bare `wait` is only for the two expiry recipes"
            )
        for pan in APPROVING_PANS:
            assert pan not in text, f"{cell.id} uses {pan}, which approves on TEST"
        if "no_succeeded_txn" in expected.merchant:
            assert {"session_status", "txn_count"} & set(expected.merchant), (
                f"{cell.id}: no_succeeded_txn passes vacuously against a "
                "degenerate resource; pin it to a session that exists"
            )
        if expected.label in cells.LABEL_SENTINELS:
            assert {"session_status", "txn_count"} & set(expected.merchant), (
                f"{cell.id}: a discovery cell must still pin the session state"
            )
        elif not expected.label.startswith("result:success"):
            assert "no_succeeded_txn" in expected.merchant, cell.id
        assert "airplane" not in verbs or platform == "android", (
            f"{cell.id}: airplane mode does not exist on the iOS simulator"
        )
        if any(
            verb == "device_language" and arg != cells.DEVICE_LANGUAGE_DEFAULT
            for verb, arg in actions
        ):
            assert not verbs & {"tap_google_pay"}, (
                f"{cell.id}: sets a device language and taps the wallet, whose "
                "button is drawn and translated by Play services"
            )
            assert not {a for v, a in actions if v == "expect"} & {
                "google_pay",
                "no_google_pay",
            }, (
                f"{cell.id}: sets a device language and expects the wallet, "
                "whose button is drawn and translated by Play services"
            )
    return loaded
