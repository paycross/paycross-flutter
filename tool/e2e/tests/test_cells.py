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
    )
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

    assert message in str(excinfo.value)
