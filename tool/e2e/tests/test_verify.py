import pytest

from tool.e2e import cells, verify


def session(status="completed", txns=None):
    return {"id": "01a0-sess", "status": status, "transactions": txns or []}


def txn(status="succeeded", **extra):
    return {"id": "txn-1", "type": "payment", "status": status, **extra}


@pytest.mark.parametrize(
    "template, actual, ok, captured",
    [
        ("result:success:<txn>", "result:success:abc", True, "abc"),
        ("result:success:<txn>", "result:success:", True, ""),
        ("result:success:<txn>", "result:failure:retry:abc", False, None),
        (
            "result:failure:do_not_retry:<txn>",
            "result:failure:do_not_retry:abc",
            True,
            "abc",
        ),
        (
            "result:failure:do_not_retry:<txn>",
            "result:failure:retry:abc",
            False,
            None,
        ),
        ("result:cancelled", "result:cancelled", True, None),
        ("result:cancelled", "result:cancelled:x", False, None),
        ("error:invalidToken", "error:invalidToken", True, None),
        ("error:invalidToken", "error:unknown", False, None),
        # A transaction id containing a colon would still be captured whole:
        # <txn> is always last, so the capture is unambiguous.
        ("result:success:<txn>", "result:success:a:b", True, "a:b"),
    ],
)
def test_match_label(template, actual, ok, captured):
    matched, txn_id = verify.match_label(template, actual)

    assert matched is ok
    if ok:
        assert txn_id == captured


def test_match_label_on_a_missing_label():
    assert verify.match_label("result:cancelled", None) == (False, None)


def test_every_merchant_key_a_cell_can_declare_is_checked_here():
    # A key added to cells.py without a check here would pass vacuously --
    # the cell would assert it and verify_merchant would ignore it in silence.
    assert cells.MERCHANT_KEYS == verify.MERCHANT_CHECKS


def test_verify_merchant_passes_a_clean_control_cell():
    assert (
        verify.verify_merchant(
            session(txns=[txn()]),
            {
                "session_status": "completed",
                "txn_count": 1,
                "txn_status": "succeeded",
                "no_succeeded_txn": False,
            },
        )
        == []
    )


def test_verify_merchant_only_checks_the_keys_that_are_asserted():
    # No txn_status key, so a failed transaction is not a mismatch here.
    assert (
        verify.verify_merchant(
            session(status="open", txns=[txn(status="failed")]),
            {"session_status": "open"},
        )
        == []
    )


def test_verify_merchant_reports_every_mismatch_not_just_the_first():
    problems = verify.verify_merchant(
        session(status="open", txns=[txn(status="failed")]),
        {"session_status": "completed", "txn_count": 2, "txn_status": "succeeded"},
    )

    assert len(problems) == 3
    assert any("session_status" in p for p in problems)
    assert any("txn_count" in p for p in problems)
    assert any("txn_status" in p for p in problems)


def test_a_resource_with_no_status_key_is_named_as_a_shape_fault():
    # sandbox.read raises on any non-2xx or non-JSON response, so a resource
    # that reaches this check without a `status` key is an unexpected shape,
    # not a session that reported a null status.
    problems = verify.verify_merchant({"id": "01a0-sess"}, {"session_status": "open"})

    assert len(problems) == 1
    assert "status" in problems[0]
    assert "None" not in problems[0]


def test_no_succeeded_txn_is_the_assertion_every_cancel_and_decline_cell_needs():
    declined = session(status="open", txns=[txn(status="failed")])
    leaked = session(
        status="open", txns=[txn(status="failed"), txn(status="succeeded")]
    )

    assert verify.verify_merchant(declined, {"no_succeeded_txn": True}) == []
    problems = verify.verify_merchant(leaked, {"no_succeeded_txn": True})
    assert len(problems) == 1
    assert "succeeded" in problems[0]


def test_failure_recovery_distinguishes_absent_from_a_value():
    android = session(status="open", txns=[txn(status="failed")])
    ios = session(
        status="open",
        txns=[txn(status="failed", failure={"recovery": "change_method"})],
    )

    assert verify.verify_merchant(android, {"failure_recovery": None}) == []
    assert verify.verify_merchant(ios, {"failure_recovery": "change_method"}) == []
    absent_but_present = verify.verify_merchant(ios, {"failure_recovery": None})
    assert len(absent_but_present) == 1
    assert absent_but_present[0].startswith("failure_recovery:")

    present_but_absent = verify.verify_merchant(
        android, {"failure_recovery": "change_method"}
    )
    assert len(present_but_absent) == 1
    assert present_but_absent[0].startswith("failure_recovery:")


def test_an_explicit_null_failure_object_does_not_crash():
    # A succeeded transaction plausibly carries "failure": null rather than
    # omitting the key, and the re-arm cell asserts failure_recovery on both
    # platforms -- so this shape reaches the check on every run.
    explicit_null = session(txns=[txn(failure=None)])

    assert verify.verify_merchant(explicit_null, {"failure_recovery": None}) == []
    problems = verify.verify_merchant(explicit_null, {"failure_recovery": "retry"})
    assert len(problems) == 1
    assert problems[0].startswith("failure_recovery:")


def test_threeds_is_a_subset_match_on_the_latest_transaction():
    completed = session(
        txns=[
            txn(
                threeds_result={
                    "outcome": "authenticated",
                    "flow": "challenge",
                    "liability_shifted": True,
                    "eci": "05",
                    "version": "2.2.0",
                }
            )
        ]
    )

    # Asserting three of five fields must not fail on the two not named.
    assert (
        verify.verify_merchant(
            completed,
            {
                "threeds": {
                    "outcome": "authenticated",
                    "flow": "challenge",
                    "liability_shifted": True,
                }
            },
        )
        == []
    )
    assert verify.verify_merchant(completed, {"threeds": {"flow": "frictionless"}}) == [
        "threeds.flow: expected 'frictionless', got 'challenge'"
    ]


def test_threeds_asserted_on_a_session_with_no_threeds_result():
    # One line, not one per asserted key: the ...153055 no-3DS case would
    # otherwise report the same absence once for every field the cell names.
    problems = verify.verify_merchant(
        session(txns=[txn()]),
        {"threeds": {"flow": "frictionless", "outcome": "authenticated"}},
    )

    assert problems == ["threeds: no threeds_result on the latest transaction"]


def test_label_transaction_must_exist_server_side_when_it_is_not_empty():
    resource = session(txns=[txn()])

    assert verify.verify_label_transaction(resource, "txn-1") == []
    assert verify.verify_label_transaction(resource, "") == []
    assert verify.verify_label_transaction(resource, None) == []
    problems = verify.verify_label_transaction(resource, "txn-ghost")
    assert len(problems) == 1
    assert problems[0].startswith("label_transaction:")
    assert "txn-ghost" in problems[0]


def test_a_transaction_without_an_id_does_not_break_the_mismatch_message():
    # sorted() over a set holding both None and a string raises TypeError, so
    # an id-less transaction would turn a verification failure into a crash.
    resource = session(txns=[txn(), {"type": "payment", "status": "failed"}])

    problems = verify.verify_label_transaction(resource, "txn-ghost")

    assert len(problems) == 1
    assert "txn-1" in problems[0]


def test_crash_lines_finds_only_real_faults():
    logcat = (
        "08-28 12:00:00.000 I ActivityManager: Start proc\n"
        "08-28 12:00:01.000 W AndroidRuntime: uiautomator noise\n"
        "08-28 12:00:02.000 E AndroidRuntime: FATAL EXCEPTION: main\n"
        "08-28 12:00:03.000 E ActivityManager: ANR in "
        "com.paycross.flutterdemo\n"
    )

    found = verify.crash_lines(logcat, "com.paycross.flutterdemo")

    assert len(found) == 2
    assert verify.crash_lines("all quiet\n", "com.paycross.x") == []


@pytest.mark.parametrize(
    "line",
    [
        "08-28 12:00:02.000 E AndroidRuntime: FATAL EXCEPTION: main",
        "Fatal error: Unexpectedly found nil while unwrapping an Optional",
        "*** Terminating app due to uncaught exception 'NSInvalidArgument'",
        "E/flutter ( 8123): [ERROR:flutter/runtime/dart_vm_initializer.cc(41)] "
        "Unhandled Exception: Bad state: no element",
    ],
)
def test_every_unscoped_fault_marker_fires(line):
    # The package is deliberately absent from each line: these markers carry no
    # component of their own, so a marker is a fault on its own.
    assert verify.crash_lines(f"quiet\n{line}\nquiet\n", "com.paycross.x") == [line]


@pytest.mark.parametrize(
    "line",
    [
        "08-28 12:00:03.000 E ActivityManager: ANR in com.paycross.x",
        "08-28 12:00:02.000 I ActivityManager: Force finishing activity "
        "com.paycross.x/.MainActivity",
    ],
)
def test_every_scoped_fault_marker_fires_for_this_app(line):
    assert verify.crash_lines(f"quiet\n{line}\nquiet\n", "com.paycross.x") == [line]


def test_an_anr_in_another_package_is_not_this_apps_crash():
    # Without the package filter this reads as our crash. The emulator ANRs on
    # its own housekeeping often enough that the difference matters.
    log = "08-28 12:00:03.000 E ActivityManager: ANR in com.other.app\n"

    assert verify.crash_lines(log, "com.paycross.flutterdemo") == []


def test_a_force_finish_of_another_app_is_not_this_apps_crash():
    # The activity manager names the component it is finishing, and it finishes
    # other apps' activities all day. Unscoped, one of those fails a cell, then
    # fails the interleaved control for the same reason, and aborts the run.
    log = (
        "08-28 12:00:02.000 I ActivityManager: Force finishing activity "
        "com.android.settings/.Settings\n"
    )

    assert verify.crash_lines(log, "com.paycross.flutterdemo") == []


def test_a_fatal_exception_in_another_process_is_not_ours():
    # The header line names no package; the Process: line under it does.
    log = (
        "08-28 12:00:02.000 E AndroidRuntime: FATAL EXCEPTION: main\n"
        "08-28 12:00:02.000 E AndroidRuntime: Process: com.other.app, PID: 9\n"
        "08-28 12:00:02.000 E AndroidRuntime: java.lang.NullPointerException\n"
    )

    assert verify.crash_lines(log, "com.paycross.flutterdemo") == []


def test_a_fatal_exception_in_our_process_is_ours():
    log = (
        "08-28 12:00:02.000 E AndroidRuntime: FATAL EXCEPTION: main\n"
        "08-28 12:00:02.000 E AndroidRuntime: Process: com.paycross.x, PID: 9\n"
    )

    found = verify.crash_lines(log, "com.paycross.x")

    assert len(found) == 1
    assert "FATAL EXCEPTION" in found[0]


def test_a_fatal_exception_with_no_process_line_is_kept():
    # A window that starts mid-crash has the header and not the line under it.
    # A missed crash is the expensive direction to be wrong in.
    log = "08-28 12:00:02.000 E AndroidRuntime: FATAL EXCEPTION: main\n"

    assert verify.crash_lines(log, "com.paycross.x") == [log.strip()]


# --- Plan B: no_succeeded_txn: false is an assertion ----------------------


def test_no_succeeded_txn_false_fails_a_session_where_no_money_moved():
    # It used to be a no-op that read like an assertion.
    problems = verify.verify_merchant(
        session(status="open", txns=[txn(status="failed")]),
        {"no_succeeded_txn": False},
    )

    assert len(problems) == 1
    assert "expected a transaction that moved money" in problems[0]


def test_no_succeeded_txn_false_passes_a_session_where_money_moved():
    assert (
        verify.verify_merchant(session(txns=[txn()]), {"no_succeeded_txn": False}) == []
    )


@pytest.mark.parametrize("status", sorted(verify.MONEY_MOVED))
def test_no_succeeded_txn_true_fails_on_every_status_that_means_money_moved(status):
    # An `auth` session stops at `authorized` and an `auth_capture` at
    # `captured`; a cancel cell that only looked for `succeeded` passed on
    # either of those.
    problems = verify.verify_merchant(
        session(status="open", txns=[txn(status=status)]),
        {"no_succeeded_txn": True},
    )

    assert len(problems) == 1
    assert "moved money" in problems[0]


# --- Plan B: the four assertions D2, D4 and D5 need -----------------------


def test_failure_code_and_network_decline_code_read_the_failure_block():
    # The shape is the one the 2026-08-29 Android run recorded for
    # challenge_fraud_suspected.
    declined = session(
        status="open",
        txns=[
            txn(
                status="failed",
                failure={
                    "code": "fraud_suspected",
                    "recovery": "do_not_retry",
                    "network_decline_code": "59",
                },
            )
        ],
    )

    assert (
        verify.verify_merchant(
            declined,
            {
                "failure_code": "fraud_suspected",
                "failure_recovery": "do_not_retry",
                "network_decline_code": "59",
            },
        )
        == []
    )
    problems = verify.verify_merchant(declined, {"failure_code": "card_expired"})
    assert len(problems) == 1
    assert "failure_code" in problems[0]


def test_a_failure_key_asserted_null_is_a_real_assertion():
    approved = session(txns=[txn(failure=None)])

    assert verify.verify_merchant(approved, {"network_decline_code": None}) == []
    assert len(verify.verify_merchant(approved, {"failure_code": "declined"})) == 1


def test_the_saved_card_assertions_read_presence_not_the_value():
    # `evidence.scrub_resource` drops both keys by name before this ever sees
    # them, so what is left is the redaction marker for a card that was stored
    # and null for one that was not.
    saved = session(
        txns=[txn(stored_credentials={"saved_token": "[REDACTED-SESSION-TOKEN]"})]
    )
    not_saved = session(txns=[txn(stored_credentials=None)])

    assert verify.verify_merchant(saved, {"saved_card_saved": True}) == []
    assert verify.verify_merchant(not_saved, {"saved_card_saved": False}) == []
    problems = verify.verify_merchant(not_saved, {"saved_card_saved": True})
    assert len(problems) == 1
    assert "stored_credentials.saved_token" in problems[0]


def test_saved_card_used_is_separate_from_saved_card_saved():
    reused = session(
        txns=[txn(stored_credentials={"used_token": "[REDACTED-SESSION-TOKEN]"})]
    )

    assert (
        verify.verify_merchant(
            reused, {"saved_card_used": True, "saved_card_saved": False}
        )
        == []
    )


# --- Plan B: match_label and the two sentinels ----------------------------


@pytest.mark.parametrize(
    "template, actual, ok",
    [
        ("<none>", None, True),
        ("<none>", "result:cancelled", False),
        ("<any>", "result:cancelled", True),
        ("<any>", "result:failure:retry:txn-1", True),
        ("<any>", "not a label", False),
        ("<any>", None, False),
    ],
)
def test_a_sentinel_decides_whether_a_label_had_to_appear(template, actual, ok):
    matched, captured = verify.match_label(template, actual)

    assert matched is ok
    # Neither sentinel captures: `<any>` records the label it measured in
    # result.json rather than cross-checking an id it never named.
    assert captured is None


def test_a_stored_credentials_of_the_wrong_shape_is_a_problem_not_a_crash():
    # `verify_merchant`'s whole contract is to return problems; raising
    # AttributeError out of it turns a malformed resource into a traceback.
    odd = session(txns=[txn(stored_credentials=["saved_token"])])

    problems = verify.verify_merchant(odd, {"saved_card_saved": True})

    assert len(problems) == 1
    assert "stored_credentials is a list" in problems[0]
