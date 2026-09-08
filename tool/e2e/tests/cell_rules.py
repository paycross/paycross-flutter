"""The authoring rules every dimension's cell directory must satisfy.

`cells.py` validates that an assertion is *well-formed*; nothing there can
say whether the set of assertions a cell makes is strong enough to mean
anything. These are that second thing, and they live here rather than in one
dimension's test file because D0 through D6 all need them and a rule copied
seven times is a rule that will differ seven ways.
"""

from pathlib import Path

from tool.e2e import cells

#: 4111111111153055 approves without 3DS on TEST (a sandbox routing gap), and
#: 4111111111150069 / 4111111111150127 lost their magic entries in
#: the sandbox's 66db130 and now approve too. A cell that used one would
#: quietly measure an approval and call it a decline.
APPROVING_PANS = ("4111111111153055", "4111111111150069", "4111111111150127")

#: A cell ends by looking for an outcome, one way or the other.
TERMINAL_VERBS = ("wait_result", "expect")

#: A cell that changes one of these must put it back. None of them is undone
#: by a failure, and each poisons every cell that follows -- two of them as a
#: rig fault the drivers' launch guards report, correctly but expensively, and
#: the third as a sheet quietly drawn in the wrong language.
#:
#: Defined in `cells` rather than here: `run_cell` replays these when a cell
#: dies before reaching its own teardown, and the runner cannot import from
#: the test tree. Two copies would be two rules.
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

        # Only teardown may follow the action that reads the outcome.
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
        # A language set after the app started is a language the app has not
        # been told about. Android recreates what it can and iOS reads its
        # argument domain once, at start-up, so on neither platform does the
        # sheet redraw on its own -- and a cell that skipped the relaunch would
        # measure the language it was trying to change away from, and pass or
        # fail on it. Not required of the teardown: the cell is over.
        for index, (verb, arg) in enumerate(actions):
            if verb != "device_language" or arg == cells.DEVICE_LANGUAGE_DEFAULT:
                continue
            following = actions[index + 1] if index + 1 < len(actions) else None
            assert following == ("relaunch", None), (
                f"{cell.id}: sets the device language to {arg!r} and does not "
                "relaunch next, so the app never sees it"
            )
        # Orientation outlives the cell on both platforms -- `user_rotation` is
        # a global setting on Android and the simulator keeps its pose -- and
        # unlike airplane mode it is not an on/off pair, so the runner's
        # teardown replay has no shape to put it back with. An odd number of
        # turns therefore leaves the device turned, and the next cell fails
        # looking for a button that is off-screen. Measured: the D3 iOS probe
        # rotated once, and the interleaved control after it failed with "no
        # element named 'payButton' within 60s" -- a rig fault wearing an SDK
        # finding's clothes.
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
        # No `rearmed` <-> `expect rearmed` assertion here: `load_cell` now
        # refuses that pairing outright, so a cell breaking it never reaches
        # this loop and the assertion would be dead code.
        if expected.label in cells.LABEL_SENTINELS:
            # A discovery cell asserts nothing about the label, so it has to
            # assert something about the session -- otherwise it passes on a
            # device that did nothing at all.
            assert {"session_status", "txn_count"} & set(expected.merchant), (
                f"{cell.id}: a discovery cell must still pin the session state"
            )
        elif not expected.label.startswith("result:success"):
            assert "no_succeeded_txn" in expected.merchant, cell.id
        assert "airplane" not in verbs or platform == "android", (
            f"{cell.id}: airplane mode does not exist on the iOS simulator"
        )
        # The wallet is the one thing on the sheet the SDK does not draw, so
        # it is the one thing a language change takes with it. Google Play
        # services renders that button and translates it: with the app's
        # locale set to `fr` the row reads `Payer avec GPay`, measured
        # 2026-09-08. `GOOGLE_PAY_DESC` is the only matcher there is for it --
        # `paycross.walletButton` does not reach a dump -- so such a cell
        # would fail looking for a button that was on screen the whole time,
        # and read as an SDK finding.
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
