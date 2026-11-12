import json
import os
import zlib
from pathlib import Path

import pytest

from tool.e2e import evidence

FIXTURES = Path(__file__).parent / "fixtures"

JWT = (
    "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9"
    ".eyJzZXNzaW9uX2lkIjoiMDFhMDQ3OWQtMDMwYS03MDhhIn0"
    ".SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
)


def png_bytes():
    header = b"\x89PNG\r\n\x1a\n"
    ihdr = b"\x00\x00\x00\x01" * 2 + b"\x08\x02\x00\x00\x00"
    idat = zlib.compress(b"\x00\xff\xff\xff")

    def chunk(kind, payload):
        return (
            len(payload).to_bytes(4, "big")
            + kind
            + payload
            + zlib.crc32(kind + payload).to_bytes(4, "big")
        )

    return header + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b"")


def test_redacts_a_jwt_out_of_an_accessibility_dump():
    uix = (
        '<?xml version="1.0"?><hierarchy><node class="android.widget.EditText" '
        f'text="{JWT}" bounds="[53,347][1028,746]" /></hierarchy>'
    ).encode()

    out = evidence.redact(uix)

    assert b"eyJ" not in out
    assert b"[REDACTED-SESSION-TOKEN]" in out
    assert b'bounds="[53,347][1028,746]"' in out


def test_redacts_every_occurrence_and_leaves_short_lookalikes_alone():
    text = f"{JWT} and again {JWT} but not eyJshort.a.b".encode()

    out = evidence.redact(text)

    assert out.count(b"[REDACTED-SESSION-TOKEN]") == 2
    assert b"eyJshort.a.b" in out


SHORT_TOKEN = "eyJhbGciOiJSUzI1NiJ9.eyJhIjoxfQ.sig"


def test_redacts_a_literal_secret_the_shape_rule_misses():
    dump = f'<node text="{SHORT_TOKEN}"/>'.encode()
    assert evidence.redact(dump) == dump

    out = evidence.redact(dump, secrets=[SHORT_TOKEN])

    assert SHORT_TOKEN.encode() not in out
    assert b"[REDACTED-SESSION-TOKEN]" in out


TRUNCATED_JWT = JWT[: JWT.index(".", JWT.index(".") + 1)][:512]


def test_redacts_a_token_the_device_truncated_before_its_signature():
    assert TRUNCATED_JWT.count(".") == 1
    dump = f'<node value="{TRUNCATED_JWT}"/>'.encode()

    out = evidence.redact(dump)

    assert TRUNCATED_JWT.encode() not in out
    assert b"[REDACTED-SESSION-TOKEN]" in out


def test_redacts_a_prefix_of_a_secret_it_was_handed():
    prefix = JWT[: JWT.index(".", JWT.index(".") + 1) - 6]
    assert prefix != JWT and len(prefix) > 40
    dump = f'<node value="{prefix}"/>'.encode()

    out = evidence.redact(dump, secrets=[JWT])

    assert prefix.encode() not in out
    assert b"[REDACTED-SESSION-TOKEN]" in out


def test_a_short_head_shared_with_a_secret_is_not_a_leak():
    text = b'<node value="eyJhbGci"/>'

    assert evidence.redact(text, secrets=[JWT]) == text


def test_redact_takes_the_shape_rule_before_the_prefix_rule():
    minted = (
        "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzZXNzaW9uIjoiMDFhMCJ9.AAA" + "a" * 40
    )
    reminted = minted[:-20] + "b" * 20
    assert reminted != minted and reminted.startswith(minted[:60])

    out = evidence.redact(f"<v>{reminted}</v>".encode(), secrets=[minted])

    assert reminted[-20:].encode() not in out
    assert b"eyJ" not in out
    assert b"[REDACTED-SESSION-TOKEN]" in out


def test_scrub_resource_drops_a_token_by_key_at_any_depth():
    resource = {
        "id": "sess-1",
        "session_token": JWT,
        "transactions": [{"id": "txn-1", "saved_token": JWT}],
        "nested": {"deeper": {"used_token": JWT}},
        "status": "open",
    }

    safe, found = evidence.scrub_resource(resource)

    assert JWT not in json.dumps(safe)
    assert safe["status"] == "open" and safe["id"] == "sess-1"
    assert safe["transactions"][0]["id"] == "txn-1"
    assert found == [JWT, JWT, JWT]


def test_scrub_resource_drops_the_token_out_of_a_checkout_url():
    resource = {"checkout_url": f"https://checkout.test-pay-cross.com/?session={JWT}"}

    safe, found = evidence.scrub_resource(resource)

    assert JWT not in json.dumps(safe)
    assert safe["checkout_url"].startswith(
        "https://checkout.test-pay-cross.com/?session="
    )
    assert found == [JWT]


def test_scrub_resource_leaves_a_url_without_a_session_alone():
    resource = {"return_url": "https://merchant.example.com/payment/return"}

    safe, found = evidence.scrub_resource(resource)

    assert safe == resource
    assert found == []


def test_scrub_resource_does_not_mutate_what_it_was_given():
    resource = {"session_token": JWT}

    evidence.scrub_resource(resource)

    assert resource["session_token"] == JWT


def test_a_secret_too_short_to_be_a_token_is_left_alone():
    text = b"a status of open, an id of sess-0"

    assert evidence.redact(text, secrets=["open"]) == text


def test_an_empty_or_missing_secret_is_ignored():
    text = b"<hierarchy/>"

    assert evidence.redact(text, secrets=["", None]) == text


def test_write_scrubs_the_literal_secret_it_is_given(tmp_path):
    run = evidence.Run(tmp_path, platform="android", run_id="r1")

    path = run.write(
        "control", "logs.txt", f"token={SHORT_TOKEN}".encode(), secrets=[SHORT_TOKEN]
    )

    assert SHORT_TOKEN.encode() not in path.read_bytes()


def test_append_progress_scrubs_the_literal_secret_too(tmp_path):
    run = evidence.Run(tmp_path, platform="android", run_id="r1")

    run.append_progress(
        {"cell": "control", "problems": [f"driver: the field reads {SHORT_TOKEN}"]},
        secrets=[SHORT_TOKEN],
    )

    assert SHORT_TOKEN.encode() not in (tmp_path / "r1" / "progress.jsonl").read_bytes()


def test_screenshot_bytes_pass_through_untouched():
    png = png_bytes()

    assert evidence.redact(png) == png


def test_write_redacts_before_it_touches_disk(tmp_path):
    run = evidence.Run(tmp_path, platform="android", run_id="20260828-120000")

    path = run.write("control", "form.uix", f'<node text="{JWT}"/>'.encode())

    assert b"eyJ" not in path.read_bytes()
    assert path == tmp_path / "20260828-120000" / "control" / "form.uix"


def test_progress_is_appended_one_json_object_per_line(tmp_path):
    run = evidence.Run(tmp_path, platform="android", run_id="r1")

    run.append_progress({"cell": "control", "status": "pass"})
    run.append_progress({"cell": "frictionless", "status": "fail"})

    lines = (tmp_path / "r1" / "progress.jsonl").read_text().splitlines()
    assert [json.loads(line)["cell"] for line in lines] == ["control", "frictionless"]
    assert json.loads(lines[0])["platform"] == "android"
    assert json.loads(lines[0])["at"]


def test_progress_records_are_redacted_too(tmp_path):
    run = evidence.Run(tmp_path, platform="ios", run_id="r1")

    run.append_progress({"cell": "control", "note": f"token was {JWT}"})

    assert "eyJ" not in (tmp_path / "r1" / "progress.jsonl").read_text()


def test_passed_cells_reads_every_previous_run(tmp_path):
    first = evidence.Run(tmp_path, platform="android", run_id="r1")
    first.append_progress({"cell": "control", "status": "pass"})
    first.append_progress({"cell": "frictionless", "status": "fail"})
    second = evidence.Run(tmp_path, platform="android", run_id="r2")
    second.append_progress({"cell": "frictionless", "status": "pass"})
    other = evidence.Run(tmp_path, platform="ios", run_id="r3")
    other.append_progress({"cell": "cancel_mid_challenge", "status": "pass"})

    assert evidence.passed_cells(tmp_path, "android") == {"control", "frictionless"}
    assert evidence.passed_cells(tmp_path, "ios") == {"cancel_mid_challenge"}


def test_passed_cells_ignores_interleaved_control_checks(tmp_path):
    run = evidence.Run(tmp_path, platform="android", run_id="r1")
    run.append_progress({"cell": "frictionless", "status": "fail"})
    run.append_progress({"cell": "control", "status": "pass", "control_check": True})

    assert evidence.passed_cells(tmp_path, "android") == set()


def test_passed_cells_on_an_empty_root_is_empty(tmp_path):
    assert evidence.passed_cells(tmp_path, "android") == set()


def test_passed_cells_survives_a_run_killed_mid_append(tmp_path):
    run = evidence.Run(tmp_path, platform="android", run_id="r1")
    run.append_progress({"cell": "control", "status": "pass"})
    with run.progress_path.open("ab") as handle:
        handle.write(b'{"at": "2026-08-28T12:00:00Z", "platform": "android", "cell')

    assert evidence.passed_cells(tmp_path, "android") == {"control"}


def test_passed_cells_ignores_a_pass_record_with_no_cell_id(tmp_path):
    run = evidence.Run(tmp_path, platform="android", run_id="r1")
    run.append_progress({"cell": "control", "status": "pass"})
    run.append_progress({"status": "pass"})

    assert evidence.passed_cells(tmp_path, "android") == {"control"}


def test_the_runs_own_platform_wins_over_the_record(tmp_path):
    run = evidence.Run(tmp_path, platform="android", run_id="r1")

    run.append_progress({"cell": "control", "status": "pass", "platform": "ios"})

    assert evidence.passed_cells(tmp_path, "android") == {"control"}
    assert evidence.passed_cells(tmp_path, "ios") == set()


def test_two_platforms_starting_in_the_same_second_get_their_own_run_dirs(
    tmp_path, monkeypatch
):
    monkeypatch.setattr(evidence, "_stamp", lambda: "20260828-120000")

    android = evidence.Run(tmp_path, platform="android")
    ios = evidence.Run(tmp_path, platform="ios")

    assert android.dir == tmp_path / "20260828-120000-android"
    assert ios.dir == tmp_path / "20260828-120000-ios"


def test_progress_reaches_the_disk_before_the_next_cell_starts(tmp_path, monkeypatch):
    synced = []
    real_fsync = os.fsync

    def spy(fd):
        synced.append(fd)
        real_fsync(fd)

    monkeypatch.setattr(evidence.os, "fsync", spy)
    run = evidence.Run(tmp_path, platform="android", run_id="r1")

    run.append_progress({"cell": "control", "status": "pass"})

    assert len(synced) == 1


@pytest.mark.parametrize("cell_id", ["..", "../escape", "a/b", "a\\b", ""])
def test_cell_dir_refuses_a_cell_id_that_could_leave_the_run_directory(
    tmp_path, cell_id
):
    run = evidence.Run(tmp_path, platform="android", run_id="r1")

    with pytest.raises(ValueError):
        run.cell_dir(cell_id)


def test_write_refuses_it_too_before_anything_touches_disk(tmp_path):
    run = evidence.Run(tmp_path, platform="android", run_id="r1")

    with pytest.raises(ValueError):
        run.write("../escape", "form.uix", b"x")

    assert not (tmp_path / "escape").exists()


def test_a_pass_recorded_under_one_build_does_not_satisfy_another(tmp_path):
    run = evidence.Run(tmp_path, platform="android", run_id="r1")
    run.append_progress({"cell": "control", "status": "pass", "build": "debug-1"})

    assert evidence.passed_cells(tmp_path, "android", "debug-1") == {"control"}
    assert evidence.passed_cells(tmp_path, "android", "release-2") == set()


def test_a_run_with_no_build_id_matches_records_that_carry_none(tmp_path):
    run = evidence.Run(tmp_path, platform="android", run_id="r1")
    run.append_progress({"cell": "control", "status": "pass", "build": None})

    assert evidence.passed_cells(tmp_path, "android") == {"control"}
    assert evidence.passed_cells(tmp_path, "android", "release-2") == set()


def test_a_record_written_before_build_ids_existed_still_resumes(tmp_path):
    run = evidence.Run(tmp_path, platform="android", run_id="r1")
    run.append_progress({"cell": "control", "status": "pass"})

    assert evidence.passed_cells(tmp_path, "android") == {"control"}


@pytest.mark.parametrize("path", sorted(FIXTURES.glob("*")))
def test_a_committed_fixture_is_already_clean(path):
    raw = path.read_bytes()

    assert evidence.redact(raw) == raw, f"{path.name} holds token-shaped material"


def test_a_token_sharing_a_long_head_with_a_known_secret_leaves_no_tail():
    head = "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzZXNzaW9uIjoi" + "A" * 600
    minted = head + "ORIGINAL.c2lnbmF0dXJlLWJ5dGVzLWhlcmU"
    remined = head + "SECONDONE.c2lnbmF0dXJlLXR3by1oZXJl"
    log = f"flutter: checkout_url=...?session={remined}\n".encode()

    scrubbed = evidence.redact(log, secrets=[minted])

    assert b"eyJ" not in scrubbed
    assert b"SECONDONE" not in scrubbed
    assert evidence.REDACTED in scrubbed
