from pathlib import Path

import pytest

from tool.e2e import cells, evidence, verify

FIXTURES = Path(__file__).parent / "fixtures"


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

    found, excused, driver = verify.crash_lines(logcat, "com.paycross.flutterdemo")

    assert len(found) == 2
    assert excused == []
    assert driver == []
    assert verify.crash_lines("all quiet\n", "com.paycross.x") == ([], [], [])


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
    assert verify.crash_lines(f"quiet\n{line}\nquiet\n", "com.paycross.x") == (
        [line],
        [],
        [],
    )


@pytest.mark.parametrize(
    "line",
    [
        "08-28 12:00:03.000 E ActivityManager: ANR in com.paycross.x",
        "08-28 12:00:02.000 I ActivityManager: Force finishing activity "
        "com.paycross.x/.MainActivity",
    ],
)
def test_every_scoped_fault_marker_fires_for_this_app(line):
    assert verify.crash_lines(f"quiet\n{line}\nquiet\n", "com.paycross.x") == (
        [line],
        [],
        [],
    )


def test_an_anr_in_another_package_is_not_this_apps_crash():
    log ="08-28 12:00:03.000 E ActivityManager: ANR in com.other.app\n"

    assert verify.crash_lines(log, "com.paycross.flutterdemo") == ([], [], [])


def test_a_force_finish_of_another_app_is_not_this_apps_crash():
    log = (
        "08-28 12:00:02.000 I ActivityManager: Force finishing activity "
        "com.android.settings/.Settings\n"
    )

    assert verify.crash_lines(log, "com.paycross.flutterdemo") == ([], [], [])


def test_a_fatal_exception_in_another_process_is_not_ours():
    log = (
        "08-28 12:00:02.000 E AndroidRuntime: FATAL EXCEPTION: main\n"
        "08-28 12:00:02.000 E AndroidRuntime: Process: com.other.app, PID: 9\n"
        "08-28 12:00:02.000 E AndroidRuntime: java.lang.NullPointerException\n"
    )

    assert verify.crash_lines(log, "com.paycross.flutterdemo") == ([], [], [])


def test_a_fatal_exception_in_our_process_is_ours():
    log = (
        "08-28 12:00:02.000 E AndroidRuntime: FATAL EXCEPTION: main\n"
        "08-28 12:00:02.000 E AndroidRuntime: Process: com.paycross.x, PID: 9\n"
    )

    found, excused, driver = verify.crash_lines(log, "com.paycross.x")

    assert len(found) == 1
    assert "FATAL EXCEPTION" in found[0]
    assert excused == []
    assert driver == []


def test_a_fatal_exception_with_no_process_line_is_kept():
    log ="08-28 12:00:02.000 E AndroidRuntime: FATAL EXCEPTION: main\n"

    assert verify.crash_lines(log, "com.paycross.x") == ([log.strip()], [], [])


UIAUTOMATION_CRASH = (FIXTURES / "android-uiautomation-crash.log").read_text()

UIAUTOMATION_HEADER = "09-01 13:22:50.706 E/AndroidRuntime(11111): "


def test_the_drivers_own_uiautomator_crash_is_not_the_apps():
    scan = verify.crash_lines(UIAUTOMATION_CRASH, "com.paycross.flutterdemo")

    assert scan.faults == []
    assert scan.excused == []
    assert len(scan.driver) == 1
    assert "FATAL EXCEPTION: UiAutomation" in scan.driver[0]


def test_the_drivers_crash_is_still_reported_as_a_warning():
    scan = verify.crash_lines(UIAUTOMATION_CRASH, "com.paycross.flutterdemo")

    assert scan.driver
    assert verify.DRIVER_CRASH_REASON


def test_a_uiautomation_crash_that_reaches_our_code_is_still_ours():
    log = (
        f"{UIAUTOMATION_HEADER}FATAL EXCEPTION: UiAutomation\n"
        f"{UIAUTOMATION_HEADER}PID: 11111\n"
        f"{UIAUTOMATION_HEADER}java.lang.RuntimeException: Bad file descriptor\n"
        f"{UIAUTOMATION_HEADER}\tat android.os.BinderProxy.transactNative"
        "(Native Method)\n"
        f"{UIAUTOMATION_HEADER}\tat com.paycross.sdk.internal.ui."
        "PaymentActivity.onResume(PaymentActivity.kt:88)\n"
    )

    scan = verify.crash_lines(log, "com.paycross.flutterdemo")

    assert len(scan.faults) == 1
    assert scan.driver == []


def test_a_uiautomation_crash_carrying_our_process_line_is_still_ours():
    log = (
        f"{UIAUTOMATION_HEADER}FATAL EXCEPTION: UiAutomation\n"
        f"{UIAUTOMATION_HEADER}Process: com.paycross.flutterdemo, PID: 11111\n"
        f"{UIAUTOMATION_HEADER}java.lang.RuntimeException: Bad file descriptor\n"
        f"{UIAUTOMATION_HEADER}\tat android.os.BinderProxy.transactNative"
        "(Native Method)\n"
        f"{UIAUTOMATION_HEADER}\tat android.view.accessibility."
        "AccessibilityCache.onAccessibilityEvent(AccessibilityCache.java:296)\n"
    )

    scan = verify.crash_lines(log, "com.paycross.flutterdemo")

    assert len(scan.faults) == 1
    assert scan.driver == []


def test_an_ordinary_app_fatal_still_fails_the_cell():
    log = (
        "09-01 13:22:50.706 E/AndroidRuntime(11111): FATAL EXCEPTION: main\n"
        "09-01 13:22:50.706 E/AndroidRuntime(11111): Process: "
        "com.paycross.flutterdemo, PID: 11111\n"
        "09-01 13:22:50.706 E/AndroidRuntime(11111): "
        "java.lang.NullPointerException\n"
        "09-01 13:22:50.706 E/AndroidRuntime(11111): \tat com.paycross.sdk."
        "internal.Foo.bar(Foo.kt:10)\n"
    )

    scan = verify.crash_lines(log, "com.paycross.flutterdemo")

    assert len(scan.faults) == 1
    assert "FATAL EXCEPTION: main" in scan.faults[0]
    assert scan.driver == []


def test_a_framework_only_crash_on_another_thread_is_not_the_drivers():
    log = (
        "09-01 13:22:50.706 E/AndroidRuntime(11111): FATAL EXCEPTION: main\n"
        "09-01 13:22:50.706 E/AndroidRuntime(11111): PID: 11111\n"
        "09-01 13:22:50.706 E/AndroidRuntime(11111): "
        "java.lang.RuntimeException: Bad file descriptor\n"
        "09-01 13:22:50.706 E/AndroidRuntime(11111): \tat android.view."
        "accessibility.AccessibilityCache.onAccessibilityEvent"
        "(AccessibilityCache.java:296)\n"
    )

    scan = verify.crash_lines(log, "com.paycross.flutterdemo")

    assert len(scan.faults) == 1
    assert scan.driver == []


def test_a_uiautomation_crash_with_no_accessibility_frame_is_kept():
    log = (
        f"{UIAUTOMATION_HEADER}FATAL EXCEPTION: UiAutomation\n"
        f"{UIAUTOMATION_HEADER}PID: 11111\n"
        f"{UIAUTOMATION_HEADER}java.lang.IllegalStateException: boom\n"
        f"{UIAUTOMATION_HEADER}\tat android.os.Looper.loop(Looper.java:317)\n"
    )

    scan = verify.crash_lines(log, "com.paycross.flutterdemo")

    assert len(scan.faults) == 1
    assert scan.driver == []


def test_no_succeeded_txn_false_fails_a_session_where_no_money_moved():
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
    problems = verify.verify_merchant(
        session(status="open", txns=[txn(status=status)]),
        {"no_succeeded_txn": True},
    )

    assert len(problems) == 1
    assert "moved money" in problems[0]


def test_failure_code_and_network_decline_code_read_the_failure_block():
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


def test_a_real_scrub_leaves_the_saved_card_assertions_something_to_read():
    live = session(
        txns=[
            txn(
                stored_credentials={
                    "saved_token": "eyJhbGciOiJSUzI1NiJ9.eyJjYXJkIjoiMSJ9.c2ln",
                    "used_token": None,
                    "save_operation": "created",
                }
            )
        ]
    )

    scrubbed, found = evidence.scrub_resource(live)
    stored = scrubbed["transactions"][0]["stored_credentials"]

    assert found == ["eyJhbGciOiJSUzI1NiJ9.eyJjYXJkIjoiMSJ9.c2ln"]
    assert stored["saved_token"] == evidence.REDACTED.decode()
    assert "saved_token" in stored
    assert stored["used_token"] is None
    assert stored["save_operation"] == "created"

    assert verify.verify_merchant(scrubbed, {"saved_card_saved": True}) == []
    assert verify.verify_merchant(scrubbed, {"saved_card_used": False}) == []


@pytest.mark.parametrize(
    "template, actual, ok, captured",
    [
        ("<none>", None, True, None),
        ("<none>", "result:cancelled", False, None),
        ("<any>", "result:cancelled", True, None),
        ("<any>", "result:failure:retry:txn-1", True, "txn-1"),
        ("<any>", "result:success:txn-9", True, "txn-9"),
        ("<any>", "result:success:", True, ""),
        ("<any>", "error:resultUnknown", True, None),
        ("<any>", "not a label", False, None),
        ("<any>", None, False, None),
    ],
)
def test_a_sentinel_decides_whether_a_label_had_to_appear(
    template, actual, ok, captured
):
    assert verify.match_label(template, actual) == (ok, captured)


def test_a_discovery_cell_captures_the_id_it_reports():
    _, captured = verify.match_label(
        "<any>", "result:failure:restart:3a9c6d3b-0000-0000-0000-000000000000"
    )

    assert captured == "3a9c6d3b-0000-0000-0000-000000000000"
    assert verify.verify_label_transaction(session(txns=[]), captured) != []


def test_an_unrecognized_recovery_may_hold_colons_and_the_id_still_comes_out():
    _, captured = verify.match_label(
        "<any>", "result:failure:unrecognized(weird:thing):txn-1"
    )

    assert captured == "txn-1"


def test_a_stored_credentials_of_the_wrong_shape_is_a_problem_not_a_crash():
    odd = session(txns=[txn(stored_credentials=["saved_token"])])

    problems = verify.verify_merchant(odd, {"saved_card_saved": True})

    assert len(problems) == 1
    assert "stored_credentials is a list" in problems[0]


FORCE_FINISH = (
    "08-28 12:00:02.000 I ActivityManager: Force finishing activity "
    "com.paycross.x/com.paycross.PaymentActivity"
)


def test_a_force_finish_is_a_fault_by_default():
    faults, excused, driver = verify.crash_lines(
        f"quiet\n{FORCE_FINISH}\n", "com.paycross.x"
    )

    assert faults == [FORCE_FINISH]
    assert (excused, driver) == ([], [])


def test_a_cell_may_be_excused_the_force_finish_it_asked_for():
    faults, excused, driver = verify.crash_lines(
        f"quiet\n{FORCE_FINISH}\n",
        "com.paycross.x",
        tolerated=("Force finishing activity",),
    )

    assert faults == []
    assert excused == [FORCE_FINISH]
    assert driver == []


def test_an_excuse_does_not_reach_another_apps_line():
    other = (
        "08-28 12:00:02.000 I ActivityManager: Force finishing activity "
        "com.android.settings/.Settings"
    )

    faults, excused, driver = verify.crash_lines(
        f"{other}\n", "com.paycross.x", tolerated=("Force finishing activity",)
    )

    assert (faults, excused, driver) == ([], [], [])


@pytest.mark.parametrize(
    "line",
    [
        "08-28 12:00:02.000 E AndroidRuntime: FATAL EXCEPTION: main",
        "08-28 12:00:03.000 E ActivityManager: ANR in com.paycross.x",
        "Fatal error: Unexpectedly found nil while unwrapping an Optional",
        "*** Terminating app due to uncaught exception 'NSInvalidArgument'",
        "E/flutter ( 8123): Unhandled Exception: Bad state: no element",
    ],
)
def test_no_caller_can_excuse_a_real_crash(line):
    faults, excused, driver = verify.crash_lines(
        f"quiet\n{line}\n", "com.paycross.x", tolerated=(line, "ANR in")
    )

    assert faults == [line]
    assert (excused, driver) == ([], [])


def test_the_tolerable_markers_are_exactly_one():
    assert cells.TOLERABLE_CRASH_MARKERS == frozenset({"Force finishing activity"})
