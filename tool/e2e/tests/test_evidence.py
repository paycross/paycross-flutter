import json
import zlib

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
