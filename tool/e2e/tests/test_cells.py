import textwrap

import pytest

from tool.e2e import cells

CONTROL = """\
id: control
platforms: [android, ios]
card:
  pan: "4111111111170000"
  expiry: "12/28"
  cvv: "123"
session:
  amount: 1000
  currency: EUR
actions:
  - paste_token
  - type_card
  - tap_pay
  - wait_result 120
expected:
  label: "result:success:<txn>"
  merchant:
    session_status: completed
    txn_count: 1
    txn_status: succeeded
    no_succeeded_txn: false
"""


def write(tmp_path, name, body):
    path = tmp_path / name
    path.write_text(textwrap.dedent(body), encoding="utf-8")
    return path


def test_loads_a_whole_cell(tmp_path):
    cell = cells.load_cell(write(tmp_path, "control.yaml", CONTROL))

    assert cell.id == "control"
    assert cell.platforms == ("android", "ios")
    assert cell.card.pan == "4111111111170000"
    assert cell.card.expiry_digits == "1228"
    assert cell.card.holder == "John Doe"
    assert cell.session.amount == 1000
    assert cell.session.currency == "EUR"
    assert cell.session.options == {}
    assert [a.verb for a in cell.actions] == [
        "paste_token",
        "type_card",
        "tap_pay",
        "wait_result",
    ]
    assert cell.actions[-1].arg == "120"
    assert cell.expected_for("android").label == "result:success:<txn>"
    assert cell.expected_for("android").rearmed is False
    assert cell.expected_for("android").merchant["txn_count"] == 1


def test_parses_the_colon_and_space_action_forms(tmp_path):
    body = CONTROL.replace(
        "  - wait_result 120",
        "  - acs:authentication_failed\n"
        "  - expect rearmed\n"
        "  - background 5\n"
        "  - airplane on\n"
        "  - wait_result 120",
        # `expect rearmed` is only well-formed alongside the expectation it
        # looks for; load_cell refuses the two apart.
    ).replace("expected:\n", "expected:\n  rearmed: true\n")
    cell = cells.load_cell(write(tmp_path, "control.yaml", body))
    verbs = [(a.verb, a.arg) for a in cell.actions]

    assert ("acs", "authentication_failed") in verbs
    assert ("expect", "rearmed") in verbs
    assert ("background", "5") in verbs
    assert ("airplane", "on") in verbs


def test_platform_override_merges_over_the_base(tmp_path):
    body = CONTROL + textwrap.dedent(
        """\
        expected.ios:
          merchant:
            failure_recovery: change_method
        expected.android:
          merchant:
            failure_recovery: null
        """
    )
    cell = cells.load_cell(write(tmp_path, "control.yaml", body))

    ios = cell.expected_for("ios")
    android = cell.expected_for("android")

    # The override replaces only the key it names.
    assert ios.merchant["failure_recovery"] == "change_method"
    assert ios.merchant["session_status"] == "completed"
    assert android.merchant["failure_recovery"] is None
    # An asserted null and an unasserted key are different things.
    assert "failure_recovery" in android.merchant


def test_load_cells_filters_by_platform_and_sorts(tmp_path):
    write(tmp_path, "control.yaml", CONTROL)
    write(
        tmp_path,
        "android_only.yaml",
        CONTROL.replace("id: control", "id: android_only").replace(
            "platforms: [android, ios]", "platforms: [android]"
        ),
    )

    assert [c.id for c in cells.load_cells(tmp_path, "android")] == [
        "android_only",
        "control",
    ]
    assert [c.id for c in cells.load_cells(tmp_path, "ios")] == ["control"]


@pytest.mark.parametrize(
    "mutation, message",
    [
        (lambda b: b.replace("id: control", "id: wrong"), "filename"),
        (lambda b: b.replace("[android, ios]", "[android, windows]"), "platform"),
        (lambda b: b.replace('"4111111111170000"', '"41x1"'), "pan"),
        (lambda b: b.replace('"12/28"', '"1228"'), "expiry"),
        (lambda b: b.replace('"123"', '"12"'), "cvv"),
        (lambda b: b.replace("amount: 1000", "amount: 0"), "amount"),
        (lambda b: b.replace("currency: EUR", "currency: eur"), "currency"),
        (lambda b: b.replace("  - tap_pay", "  - tap_the_pay_button"), "action"),
        (lambda b: b.replace("  - tap_pay", "  - acs"), "argument"),
        (lambda b: b.replace("  - tap_pay", "  - rotate 90"), "argument"),
        # Indentation matters: these literals must match CONTROL exactly or
        # str.replace is a no-op and the test passes by not testing anything.
        (lambda b: b.replace("    txn_count: 1", "    txns: 1"), "merchant key"),
        (lambda b: b.replace("  label:", "  lable:"), "label"),
    ],
)
def test_validation_rejects(tmp_path, mutation, message):
    path = write(tmp_path, "control.yaml", mutation(CONTROL))

    with pytest.raises(cells.CellError) as excinfo:
        cells.load_cell(path)

    # Every message is `<path>: <detail>`. Matching on the detail keeps a
    # tmp_path that happens to contain the word from passing the case for us.
    assert str(excinfo.value).startswith(f"{path}: ")
    assert message in str(excinfo.value).removeprefix(f"{path}: ")


# --- Helpers for the follow-up review items -------------------------------


def with_action(body, action):
    """CONTROL with one extra action spliced in after `tap_pay`."""
    return body.replace("  - tap_pay", f"  - tap_pay\n  - {action}")


def with_merchant(body, block):
    """CONTROL with its whole merchant block replaced."""
    head, marker, _ = body.partition("  merchant:\n")
    assert marker, "the merchant block moved; fix this helper"
    return head + marker + block


def with_label(body, label):
    return body.replace('  label: "result:success:<txn>"', f'  label: "{label}"')


def expect_rejected(tmp_path, body, name="control.yaml"):
    with pytest.raises(cells.CellError) as excinfo:
        cells.load_cell(write(tmp_path, name, body))
    return str(excinfo.value)


# --- C1: argument grammar -------------------------------------------------


@pytest.mark.parametrize(
    "action",
    [
        "acs:authentication_failed",
        "acs:approve",
        "airplane on",
        "airplane off",
        "background 5",
        # Not `expect rearmed`: that one is only well-formed alongside
        # `rearmed: true`, which this body does not carry. Its own pairing has
        # tests of its own under "cross-field rules".
        "expect google_pay",
        "wait_result 1.5",
    ],
)
def test_accepts_valid_action_arguments(tmp_path, action):
    cell = cells.load_cell(
        write(tmp_path, "control.yaml", with_action(CONTROL, action))
    )

    verb, _, _ = action.partition(":") if ":" in action else action.partition(" ")
    assert verb in [a.verb for a in cell.actions]


@pytest.mark.parametrize(
    "action",
    [
        "acs:Authentication_Failed",
        "acs:auth-failed",
        "acs:123",
        "airplane maybe",
        "background 0",
        "background -1",
        "expect success",
        "wait_result 0",
        "wait_result -5",
        "wait_result soon",
        "wait_result inf",
    ],
)
def test_rejects_invalid_action_arguments(tmp_path, action):
    message = expect_rejected(tmp_path, with_action(CONTROL, action))

    assert action in message


def test_arg_actions_still_reads_as_a_set_of_verbs():
    # Task 9 does `verb in ARG_ACTIONS`; carrying validators must not break it.
    assert "wait_result" in cells.ARG_ACTIONS
    assert "tap_pay" not in cells.ARG_ACTIONS
    assert set(cells.ARG_ACTIONS) == {
        "acs",
        "airplane",
        "background",
        "dont_keep_activities",
        "enter_token",
        "expect",
        "wait_expired",
        "wait_result",
    }


# --- I1: `expected` is the unmerged base ----------------------------------


def test_expected_is_the_unmerged_base_and_expected_for_merges(tmp_path):
    body = CONTROL + textwrap.dedent(
        """\
        expected.ios:
          merchant:
            failure_recovery: change_method
        """
    )
    cell = cells.load_cell(write(tmp_path, "control.yaml", body))

    # `.expected` is the base and is wrong for iOS; consumers go through
    # `.expected_for(platform)`.
    assert "failure_recovery" not in cell.expected.merchant
    assert cell.expected_for("ios") != cell.expected
    assert cell.expected_for("ios").merchant["failure_recovery"] == "change_method"
    assert cell.expected_for("android") == cell.expected


# --- I2: load_cells directory errors --------------------------------------


def test_load_cells_rejects_a_missing_directory(tmp_path):
    missing = tmp_path / "nope"

    with pytest.raises(cells.CellError) as excinfo:
        cells.load_cells(missing, "android")

    assert str(missing) in str(excinfo.value)


def test_load_cells_rejects_a_directory_with_no_cells(tmp_path):
    with pytest.raises(cells.CellError) as excinfo:
        cells.load_cells(tmp_path, "android")

    message = str(excinfo.value)
    assert str(tmp_path) in message
    # The glob is not recursive, so it must point at the likely mistake.
    assert "d0" in message


# --- I3: unknown keys in an expectation block -----------------------------


@pytest.mark.parametrize("block", ["expected", "expected.ios"])
def test_rejects_unknown_keys_in_an_expectation_block(tmp_path, block):
    if block == "expected":
        body = CONTROL.replace("expected:\n", "expected:\n  bogus: 1\n")
    else:
        body = CONTROL + "expected.ios:\n  bogus: 1\n"

    message = expect_rejected(tmp_path, body)

    assert "bogus" in message
    assert block in message


# --- I4: merchant value types ---------------------------------------------


@pytest.mark.parametrize(
    "block, key",
    [
        ("    session_status: 1\n", "session_status"),
        ("    session_status: ''\n", "session_status"),
        ("    txn_count: -1\n", "txn_count"),
        ("    txn_count: true\n", "txn_count"),
        ("    txn_count: '1'\n", "txn_count"),
        ("    txn_status: null\n", "txn_status"),
        ("    no_succeeded_txn: 'false'\n", "no_succeeded_txn"),
        ("    failure_recovery: 7\n", "failure_recovery"),
        ("    threeds: 3\n", "threeds"),
    ],
)
def test_rejects_bad_merchant_values(tmp_path, block, key):
    message = expect_rejected(tmp_path, with_merchant(CONTROL, block))

    assert key in message


def test_accepts_a_full_merchant_block(tmp_path):
    body = with_merchant(
        CONTROL,
        "    session_status: completed\n"
        "    txn_count: 0\n"
        "    txn_status: failed\n"
        "    no_succeeded_txn: true\n"
        "    failure_recovery: null\n"
        "    threeds:\n"
        "      flow: challenge\n",
    )
    merchant = (
        cells.load_cell(write(tmp_path, "control.yaml", body))
        .expected_for("android")
        .merchant
    )

    assert merchant["txn_count"] == 0
    assert merchant["failure_recovery"] is None
    assert merchant["threeds"] == {"flow": "challenge"}


def test_rejects_bad_merchant_values_in_an_override(tmp_path):
    body = CONTROL + "expected.ios:\n  merchant:\n    txn_count: -1\n"

    assert "txn_count" in expect_rejected(tmp_path, body)


# --- I5: the frozen label vocabulary --------------------------------------


@pytest.mark.parametrize(
    "label",
    [
        "result:success:txn_123",
        "result:success:",
        "result:failure:retry:txn_1",
        "result:failure:change_method:txn_1",
        "result:failure:restart:txn_1",
        "result:failure:do_not_retry:txn_1",
        "result:failure:contact_support:txn_1",
        "result:failure:unrecognized(weird:raw):txn_1",
        "result:cancelled",
        "error:sessionExpired",
    ],
)
def test_accepts_every_frozen_label_form(tmp_path, label):
    cell = cells.load_cell(write(tmp_path, "control.yaml", with_label(CONTROL, label)))

    assert cell.expected_for("android").label == label


@pytest.mark.parametrize(
    "label",
    [
        "result:succes:txn_1",
        "result:failure:banana:txn_1",
        "result:failure:retry",
        "result:cancelled:txn_1",
        "error:session_expired",
        "result:success:txn 1",
        "cancelled",
        "",
    ],
)
def test_rejects_labels_outside_the_frozen_vocabulary(tmp_path, label):
    assert "label" in expect_rejected(tmp_path, with_label(CONTROL, label))


# --- M3: errors name the path, not the basename ---------------------------


def test_the_error_names_the_path_not_just_the_basename(tmp_path):
    d0 = tmp_path / "d0"
    d0.mkdir()
    path = d0 / "control.yaml"
    path.write_text(CONTROL.replace('"4111111111170000"', '"41x1"'), encoding="utf-8")

    with pytest.raises(cells.CellError) as excinfo:
        cells.load_cell(path)

    assert str(excinfo.value).startswith(f"{path}: ")


# --- M6: rearmed is a bool ------------------------------------------------


@pytest.mark.parametrize("value", ["'yes'", "1", "null"])
def test_rearmed_must_be_a_bool(tmp_path, value):
    body = CONTROL.replace("expected:\n", f"expected:\n  rearmed: {value}\n")

    assert "rearmed" in expect_rejected(tmp_path, body)


def test_rearmed_true_is_carried_through(tmp_path):
    body = CONTROL.replace("expected:\n", "expected:\n  rearmed: true\n").replace(
        "  - tap_pay\n", "  - tap_pay\n  - expect rearmed\n"
    )
    cell = cells.load_cell(write(tmp_path, "control.yaml", body))

    assert cell.expected_for("android").rearmed is True


# --- Plan B: one delimiter grammar ----------------------------------------


def test_an_argument_holding_a_colon_is_reported_against_the_verb_that_takes_it():
    # Not "unknown action": the verb is real and the argument is what is wrong.
    with pytest.raises(cells.CellError, match=r"wait_result 1:20.*positive number"):
        cells.parse_action("wait_result 1:20", "cell.yaml")


def test_the_space_form_and_the_colon_form_parse_the_same():
    assert cells.parse_action("acs approve", "w") == cells.parse_action(
        "acs:approve", "w"
    )


# --- Plan B: the new verbs ------------------------------------------------


@pytest.mark.parametrize(
    "verb",
    [
        "present_token",
        "tap_example_pay",
        "relaunch",
        "type_cvv",
        "tap_google_pay",
        "select_saved_card",
        "save_card",
    ],
)
def test_a_new_bare_verb_parses_and_takes_no_argument(verb):
    assert cells.parse_action(verb, "w") == cells.Action(verb)
    with pytest.raises(cells.CellError, match="takes no argument"):
        cells.parse_action(f"{verb} 5", "w")


@pytest.mark.parametrize(
    "good, bad",
    [
        ("dont_keep_activities on", "dont_keep_activities maybe"),
        ("enter_token not.a.real.token", "enter_token has spaces"),
        ("wait_expired 960", "wait_expired soon"),
    ],
)
def test_a_new_arg_verb_parses_and_rejects_a_bad_argument(good, bad):
    verb, _, arg = good.partition(" ")

    assert cells.parse_action(good, "w") == cells.Action(verb, arg)
    with pytest.raises(cells.CellError, match="argument must be"):
        cells.parse_action(bad, "w")


@pytest.mark.parametrize("expectation", sorted(cells.EXPECTATIONS))
def test_expect_takes_every_expectation_and_nothing_else(expectation):
    assert cells.parse_action(f"expect {expectation}", "w").arg == expectation
    with pytest.raises(cells.CellError, match="argument must be"):
        cells.parse_action("expect success", "w")


def test_enter_token_refuses_a_token_long_enough_to_be_a_real_one():
    # ~1011 characters is what a live session token measures. The cap is far
    # below it so a credential cannot be committed in a cell file by accident.
    with pytest.raises(cells.CellError, match="argument must be"):
        cells.parse_action("enter_token " + "a" * 1011, "w")


@pytest.mark.parametrize("character", ["$", "`", '"', "'", "|", ";", "&", "<", ">"])
def test_enter_token_refuses_every_shell_metacharacter(character):
    # AndroidDriver._input_text hands this to `input text` on a device shell
    # that re-splits and expands whatever it is given, so a literal carrying
    # one of these would be mangled rather than typed -- and the cell would
    # then be measuring a string it never sent.
    with pytest.raises(cells.CellError, match="argument must be"):
        cells.parse_action(f"enter_token ab{character}cd", "w")


# --- Plan B: the label sentinels ------------------------------------------


@pytest.mark.parametrize("sentinel", ["<any>", "<none>"])
def test_a_label_sentinel_is_accepted_where_a_literal_would_be(tmp_path, sentinel):
    body = CONTROL.replace('label: "result:success:<txn>"', f'label: "{sentinel}"')
    if sentinel == "<none>":
        body = body.replace("  - wait_result 120\n", "  - expect no_result\n")
    cell = cells.load_cell(write(tmp_path, "control.yaml", body))

    assert cell.expected_for("android").label == sentinel


def test_the_sentinels_are_the_only_angle_bracket_labels(tmp_path):
    body = CONTROL.replace('label: "result:success:<txn>"', 'label: "<whatever>"')

    assert "frozen vocabulary" in expect_rejected(tmp_path, body)


# --- Plan B: cross-field rules, per platform ------------------------------


def test_expecting_a_rearmed_sheet_without_the_action_that_looks_is_refused(tmp_path):
    body = CONTROL.replace("expected:\n", "expected:\n  rearmed: true\n")

    message = expect_rejected(tmp_path, body)
    assert "expect" in message and "rearmed" in message


def test_looking_for_a_rearmed_sheet_the_cell_does_not_expect_is_refused(tmp_path):
    body = CONTROL.replace("  - wait_result 120\n", "  - expect rearmed\n")

    message = expect_rejected(tmp_path, body)
    assert "does not expect" in message


def test_a_platform_override_alone_can_require_the_rearm_action(tmp_path):
    # The case a base-only check lets through: the base says false, so nothing
    # in `expected:` asks for the action, and only android's override does.
    body = CONTROL + textwrap.dedent(
        """\
        expected.android:
          rearmed: true
        """
    )

    message = expect_rejected(tmp_path, body)
    assert "['android']" in message


def test_expecting_no_label_without_the_action_that_looks_is_refused(tmp_path):
    body = CONTROL.replace('label: "result:success:<txn>"', 'label: "<none>"')

    message = expect_rejected(tmp_path, body)
    assert "no_result" in message


def test_looking_for_no_label_the_cell_does_not_expect_is_refused(tmp_path):
    body = CONTROL.replace("  - wait_result 120\n", "  - expect no_result\n")

    message = expect_rejected(tmp_path, body)
    assert "does not expect" in message


def test_a_platform_override_alone_can_require_the_no_result_action(tmp_path):
    body = CONTROL + textwrap.dedent(
        """\
        expected.ios:
          label: "<none>"
        """
    )

    message = expect_rejected(tmp_path, body)
    assert "['ios']" in message


# --- Plan B: the threeds block's own keys ---------------------------------


def test_a_misspelled_threeds_key_is_refused_at_load(tmp_path):
    # Untreated it reads as an SDK finding twenty minutes into a run: the
    # field is simply never compared, so the assertion passes vacuously.
    body = with_merchant(
        CONTROL,
        "    session_status: completed\n    threeds:\n      outcom: authenticated\n",
    )

    message = expect_rejected(tmp_path, body)
    assert "unknown threeds key(s) ['outcom']" in message


@pytest.mark.parametrize(
    "line, key",
    [
        ("      outcome: 3\n", "outcome"),
        ("      flow: ''\n", "flow"),
        ("      liability_shifted: 'yes'\n", "liability_shifted"),
    ],
)
def test_a_threeds_value_of_the_wrong_type_is_refused(tmp_path, line, key):
    body = with_merchant(
        CONTROL, "    session_status: completed\n    threeds:\n" + line
    )

    assert f"threeds {key} must be" in expect_rejected(tmp_path, body)


def test_eci_and_version_are_not_assertable(tmp_path):
    # Sandbox implementation detail: a sandbox upgrade must not present as a
    # finding.
    body = with_merchant(
        CONTROL,
        "    session_status: completed\n    threeds:\n      eci: '05'\n",
    )

    assert "unknown threeds key(s) ['eci']" in expect_rejected(tmp_path, body)


def test_every_threeds_key_a_shipped_cell_uses_is_assertable(tmp_path):
    body = with_merchant(
        CONTROL,
        "    session_status: completed\n"
        "    threeds:\n"
        "      outcome: not_authenticated\n"
        "      flow: challenge\n"
        "      liability_shifted: false\n",
    )
    cell = cells.load_cell(write(tmp_path, "control.yaml", body))

    assert cell.expected_for("android").merchant["threeds"]["flow"] == "challenge"


# --- Plan B: shapes that used to load and mean something else -------------


def test_a_bare_string_of_platforms_is_refused_as_a_shape(tmp_path):
    # `tuple("android")` is ('a','n','d',...), and every character is then an
    # unknown platform -- a message about 'a', 'n', 'd'.
    body = CONTROL.replace("platforms: [android, ios]", "platforms: android")

    message = expect_rejected(tmp_path, body)
    assert "platforms must be a list, got str" in message


def test_a_label_with_two_transaction_placeholders_is_refused(tmp_path):
    body = with_label(CONTROL, "result:success:<txn><txn>")

    assert "more than one '<txn>'" in expect_rejected(tmp_path, body)


def test_an_override_label_with_two_placeholders_is_refused_too(tmp_path):
    body = CONTROL + textwrap.dedent(
        """\
        expected.ios:
          label: "result:success:<txn><txn>"
        """
    )

    assert "more than one '<txn>'" in expect_rejected(tmp_path, body)


def test_the_transaction_placeholder_is_one_constant_in_both_modules():
    from tool.e2e import verify

    assert verify.TXN_PLACEHOLDER is cells.TXN_PLACEHOLDER


# --- review: an override for a platform the cell does not run on ----------


def test_an_override_for_a_platform_the_cell_does_not_run_on_is_refused(tmp_path):
    # Silently dead: `expected_for` is only ever called with a platform the
    # cell declares, so this override would never be read -- and the cell
    # would run on Android asserting the base it was written to override.
    body = CONTROL.replace("platforms: [android, ios]", "platforms: [android]") + (
        textwrap.dedent(
            """\
            expected.ios:
              merchant:
                failure_recovery: retry
            """
        )
    )

    message = expect_rejected(tmp_path, body)
    assert "expected.ios" in message
    assert "does not run on" in message


def test_an_override_for_a_declared_platform_is_still_fine(tmp_path):
    body = CONTROL.replace("platforms: [android, ios]", "platforms: [ios]") + (
        textwrap.dedent(
            """\
            expected.ios:
              merchant:
                failure_recovery: retry
            """
        )
    )
    cell = cells.load_cell(write(tmp_path, "control.yaml", body))

    assert cell.expected_for("ios").merchant["failure_recovery"] == "retry"


def test_a_duplicate_platform_is_refused(tmp_path):
    # `platforms: [android, android]` runs the cell once but reads as twice,
    # and every per-platform loop then double-counts it.
    body = CONTROL.replace("platforms: [android, ios]", "platforms: [android, android]")

    assert "duplicate platform" in expect_rejected(tmp_path, body)
