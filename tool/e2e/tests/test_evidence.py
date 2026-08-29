import json
import os
import zlib

import pytest

from tool.e2e import evidence

JWT = (
    "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9"
    ".eyJzZXNzaW9uX2lkIjoiMDFhMDQ3OWQtMDMwYS03MDhhIn0"
    ".SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
)


def png_bytes():
    """A minimal but real PNG, so the passthrough test is not testing a stub."""
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
    # Everything that is not the token survives verbatim.
    assert b'bounds="[53,347][1028,746]"' in out


def test_redacts_every_occurrence_and_leaves_short_lookalikes_alone():
    text = f"{JWT} and again {JWT} but not eyJshort.a.b".encode()

    out = evidence.redact(text)

    assert out.count(b"[REDACTED-SESSION-TOKEN]") == 2
    assert b"eyJshort.a.b" in out


#: A token the shape rule cannot see: its middle segment is ten characters
#: and JWT_RE wants sixteen. Not every environment mints a 1011-character JWT,
#: and the runner knows the exact string it handed to the device.
SHORT_TOKEN = "eyJhbGciOiJSUzI1NiJ9.eyJhIjoxfQ.sig"


def test_redacts_a_literal_secret_the_shape_rule_misses():
    dump = f'<node text="{SHORT_TOKEN}"/>'.encode()
    assert evidence.redact(dump) == dump

    out = evidence.redact(dump, secrets=[SHORT_TOKEN])

    assert SHORT_TOKEN.encode() not in out
    assert b"[REDACTED-SESSION-TOKEN]" in out


def test_a_secret_too_short_to_be_a_token_is_left_alone():
    # Blanket-replacing a three-character string would corrupt every artifact
    # it appears in, and nothing that short is a credential worth protecting.
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
    # A control check is a rig probe, not the control cell's own run. Counting
    # it would let a resumed run skip `control`, after which the next failure's
    # skepticism check re-runs a cell resume considers done.
    run = evidence.Run(tmp_path, platform="android", run_id="r1")
    run.append_progress({"cell": "frictionless", "status": "fail"})
    run.append_progress({"cell": "control", "status": "pass", "control_check": True})

    assert evidence.passed_cells(tmp_path, "android") == set()


def test_passed_cells_on_an_empty_root_is_empty(tmp_path):
    assert evidence.passed_cells(tmp_path, "android") == set()


def test_passed_cells_survives_a_run_killed_mid_append(tmp_path):
    run = evidence.Run(tmp_path, platform="android", run_id="r1")
    run.append_progress({"cell": "control", "status": "pass"})
    # What a WSL reboot leaves behind: the last record never finished.
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
    # Android and iOS are run from two shells. Without the platform in the id
    # they would share a run directory and overwrite each other's artifacts.
    monkeypatch.setattr(evidence, "_stamp", lambda: "20260828-120000")

    android = evidence.Run(tmp_path, platform="android")
    ios = evidence.Run(tmp_path, platform="ios")

    assert android.dir == tmp_path / "20260828-120000-android"
    assert ios.dir == tmp_path / "20260828-120000-ios"


def test_progress_reaches_the_disk_before_the_next_cell_starts(tmp_path, monkeypatch):
    # The docstring promises a killed run leaves usable progress, and a WSL
    # reboot has killed a run before. A buffer the kernel never wrote does not
    # keep that promise.
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
    # A cell file named `...yaml` has stem `..`.
    run = evidence.Run(tmp_path, platform="android", run_id="r1")

    with pytest.raises(ValueError):
        run.cell_dir(cell_id)


def test_write_refuses_it_too_before_anything_touches_disk(tmp_path):
    run = evidence.Run(tmp_path, platform="android", run_id="r1")

    with pytest.raises(ValueError):
        run.write("../escape", "form.uix", b"x")

    assert not (tmp_path / "escape").exists()
