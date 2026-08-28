import pytest

from tool.e2e import verify


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
    assert verify.verify_merchant(
        session(status="open", txns=[txn(status="failed")]),
        {"session_status": "open"},
    ) == []


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
    leaked = session(status="open", txns=[txn(status="failed"), txn(status="succeeded")])

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
    assert verify.verify_merchant(ios, {"failure_recovery": None}) != []
    assert verify.verify_merchant(android, {"failure_recovery": "change_method"}) != []


def test_an_explicit_null_failure_object_does_not_crash():
    # A succeeded transaction plausibly carries "failure": null rather than
    # omitting the key, and the re-arm cell asserts failure_recovery on both
    # platforms -- so this shape reaches the check on every run.
    explicit_null = session(txns=[txn(failure=None)])

    assert verify.verify_merchant(explicit_null, {"failure_recovery": None}) == []
    assert verify.verify_merchant(explicit_null, {"failure_recovery": "retry"}) != []


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
    assert verify.verify_merchant(
        completed,
        {"threeds": {"outcome": "authenticated", "flow": "challenge", "liability_shifted": True}},
    ) == []
    assert verify.verify_merchant(completed, {"threeds": {"flow": "frictionless"}}) != []


def test_threeds_asserted_on_a_session_with_no_threeds_result():
    assert verify.verify_merchant(
        session(txns=[txn()]), {"threeds": {"flow": "frictionless"}}
    ) != []


def test_label_transaction_must_exist_server_side_when_it_is_not_empty():
    resource = session(txns=[txn()])

    assert verify.verify_label_transaction("txn-1", resource) == []
    assert verify.verify_label_transaction("", resource) == []
    assert verify.verify_label_transaction(None, resource) == []
    problems = verify.verify_label_transaction("txn-ghost", resource)
    assert len(problems) == 1
    assert "txn-ghost" in problems[0]


def test_a_transaction_without_an_id_does_not_break_the_mismatch_message():
    # sorted() over a set holding both None and a string raises TypeError, so
    # an id-less transaction would turn a verification failure into a crash.
    resource = session(txns=[txn(), {"type": "payment", "status": "failed"}])

    problems = verify.verify_label_transaction("txn-ghost", resource)

    assert len(problems) == 1
    assert "txn-1" in problems[0]


def test_crash_lines_finds_only_real_faults():
    logcat = (
        "08-28 12:00:00.000 I ActivityManager: Start proc\n"
        "08-28 12:00:01.000 W AndroidRuntime: uiautomator noise\n"
        "08-28 12:00:02.000 E AndroidRuntime: FATAL EXCEPTION: main\n"
        "08-28 12:00:03.000 E ActivityManager: ANR in com.paycross.paycross_flutter_example\n"
    )

    found = verify.crash_lines(logcat, "com.paycross.paycross_flutter_example")

    assert len(found) == 2
    assert verify.crash_lines("all quiet\n", "com.paycross.x") == []
