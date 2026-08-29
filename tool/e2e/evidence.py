"""Where a run's proof goes, and what is scrubbed out of it on the way.

The evidence root lives outside every git checkout (WSL reboots have killed
runs before, and the campaign directory survives them). One directory per run,
one subdirectory per cell, and a `progress.jsonl` written incrementally so an
interrupted run can be resumed rather than restarted.
"""

from __future__ import annotations

import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

#: A session token is a JWT: three base64url segments. Anchored on the `eyJ`
#: that every `{"` header base64-encodes to, and with a length floor so an
#: ordinary dotted identifier is not mangled.
#:
#: One trailing segment is enough, not two. iOS truncates an element's
#: accessibility value at 512 characters, so the example's token field reaches
#: a `.uix` as a header, a dot and a few hundred characters of payload, with no
#: signature at all -- and a three-segment rule let 512-character prefixes of
#: live session tokens through into every iOS cell of the first live run
#: (2026-08-29). Still a floor of sixteen characters per segment, which is what
#: keeps `eyJshort.a.b` and ordinary dotted identifiers intact.
JWT_RE = re.compile(rb"eyJ[A-Za-z0-9_-]{16,}(?:\.[A-Za-z0-9_-]{16,})+")

REDACTED = b"[REDACTED-SESSION-TOKEN]"

#: A `secrets` entry shorter than this is ignored rather than replaced.
#: Nothing that short is a credential worth protecting, and blanket-replacing
#: a three-character string would corrupt every artifact it appears in.
MIN_SECRET_CHARS = 8

#: How much of a known secret has to appear before a prefix of it is treated as
#: the secret. A device that truncated a token inside its first segment leaves
#: no dot for the shape rule to see, and the runner knows the exact string it
#: handed over. Long enough that the header every RS256 JWT shares -- and which
#: carries nothing -- is not on its own a match.
MIN_SECRET_PREFIX_CHARS = 48


def redact(data: bytes, secrets: Iterable[str | None] = ()) -> bytes:
    """Removes JWT-shaped strings, and any literal secret named, from an artifact.

    Runs over **every** artifact before it touches disk, accessibility dumps
    included: the example app's token field still holds the session token on
    the result screen, and that is exactly where full 1011-character tokens
    leaked into `.uix` files in the 2026-08-26 run.

    `secrets` is what the caller *knows* is sensitive -- the runner passes the
    session token it just minted. The shape rule alone is not enough: it wants
    sixteen characters a segment, so a shorter token slips through it, and a
    log line can wrap a token in a way no regex was written for. A caller who
    holds the exact string should say so. A long *prefix* of that string counts
    too: a device that truncated the token still leaked most of it.

    Byte-level and encoding-agnostic, so a PNG passes through untouched. That
    is deliberate rather than lucky: a screenshot cannot be redacted, so the
    runner never captures one of a screen showing the token.
    """
    for secret in secrets:
        if secret and len(secret) >= MIN_SECRET_CHARS:
            data = _replace_prefixes(data, secret.encode("utf-8"))
    return JWT_RE.sub(REDACTED, data)


def _replace_prefixes(data: bytes, secret: bytes) -> bytes:
    """Replaces `secret`, and any long prefix of it, wherever it appears.

    A whole-string replace misses a token the device truncated, and iOS
    truncates an accessibility value at 512 characters. Each match is extended
    as far as the secret keeps agreeing, so what is removed is exactly the part
    that was really there -- a shorter run is not padded out, and a longer one
    is not left with a tail.
    """
    if len(secret) < MIN_SECRET_PREFIX_CHARS:
        return data.replace(secret, REDACTED)
    head = secret[:MIN_SECRET_PREFIX_CHARS]
    out = bytearray()
    at = 0
    while (found := data.find(head, at)) >= 0:
        end = len(head)
        while end < len(secret) and data[found + end : found + end + 1] == (
            secret[end : end + 1]
        ):
            end += 1
        out += data[at:found] + REDACTED
        at = found + end
    out += data[at:]
    return bytes(out)


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")


#: A cell id becomes a directory name directly, so anything that could climb
#: out of the run directory is refused rather than sanitised. Cell ids come
#: from filenames, and a cell file named `...yaml` has stem `..`; quietly
#: rewriting that would file a cell's evidence where nobody looks for it.
UNSAFE_IN_PATH = ("/", "\\", "..")


def check_cell_id(cell_id: str) -> None:
    """Raises ValueError unless this id is safe to make a path out of.

    Public because the runner builds one other path out of a cell id -- the
    token file -- and one guard is one place to be wrong.
    """
    if not cell_id or any(bad in cell_id for bad in UNSAFE_IN_PATH):
        raise ValueError(f"unsafe cell id: {cell_id!r}")


class Run:
    """One invocation of the runner, and the directory tree it fills."""

    def __init__(self, root: Path, platform: str, run_id: str | None = None):
        # The generated id carries the platform because the two platforms are
        # driven from two shells: on a bare timestamp, an Android and an iOS
        # run started in the same second share a directory and overwrite each
        # other's artifacts cell for cell.
        self.platform = platform
        self.run_id = run_id or f"{_stamp()}-{platform}"
        self.dir = Path(root) / self.run_id
        self.dir.mkdir(parents=True, exist_ok=True)

    @property
    def progress_path(self) -> Path:
        return self.dir / "progress.jsonl"

    def cell_dir(self, cell_id: str) -> Path:
        check_cell_id(cell_id)
        path = self.dir / cell_id
        path.mkdir(parents=True, exist_ok=True)
        return path

    def write(
        self,
        cell_id: str,
        name: str,
        data: bytes,
        *,
        secrets: Iterable[str | None] = (),
    ) -> Path:
        """Writes one artifact, redacted. Returns where it landed."""
        path = self.cell_dir(cell_id) / name
        path.write_bytes(redact(data, secrets))
        return path

    def append_progress(
        self, record: dict[str, Any], *, secrets: Iterable[str | None] = ()
    ) -> None:
        """Appends one line and fsyncs it, so a killed run leaves real progress.

        One fsync per cell against a cell that takes tens of seconds is free,
        and a WSL reboot has killed a run before: progress still sitting in a
        buffer is progress the next run cannot resume from.

        The run's own stamps are written last so a record cannot shadow them.
        `platform` is the key resume filters on: a record carrying one of its
        own would file this run's results under the other platform's ledger,
        and resume would then skip a cell that never ran there.
        """
        line = json.dumps({**record, "at": _now(), "platform": self.platform})
        with self.progress_path.open("ab") as handle:
            handle.write(redact(line.encode(), secrets) + b"\n")
            handle.flush()
            os.fsync(handle.fileno())


def passed_cells(root: Path, platform: str) -> set[str]:
    """Cell ids that have passed on this platform in *any* previous run.

    Scanning the runs themselves rather than keeping a separate ledger: a
    second source of truth about what passed is a second thing that can be
    wrong, and these files are small.
    """
    passed: set[str] = set()
    for path in sorted(Path(root).glob("*/progress.jsonl")):
        for line in path.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                # A run killed mid-append leaves a partial last line. Skipping
                # it costs one cell a re-run; raising would strand the whole
                # resume, which is the failure this file exists to prevent.
                continue
            if (
                record.get("platform") == platform
                and record.get("status") == "pass"
                # A pass with no cell id is a runner bug. Same direction as
                # above: drop the record rather than crash the next run.
                and record.get("cell")
                # An interleaved control check is a rig probe, not the control
                # cell's own run. Counting it would let a resumed run skip
                # `control` -- and then the next failure's skepticism check
                # re-runs a cell the resume logic already considers done.
                and not record.get("control_check")
            ):
                passed.add(record["cell"])
    return passed
