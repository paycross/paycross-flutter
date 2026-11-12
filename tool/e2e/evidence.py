"""Redact secrets from run artifacts and write the per-run evidence tree."""

from __future__ import annotations

import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

# WHY: one trailing segment is enough, because iOS truncates token values at
# 512 characters.
JWT_RE = re.compile(rb"eyJ[A-Za-z0-9_-]{16,}(?:\.[A-Za-z0-9_-]{16,})+")

REDACTED = b"[REDACTED-SESSION-TOKEN]"

MIN_SECRET_CHARS = 8

# WHY: long enough that the header every RS256 JWT shares is not a match on its own.
MIN_SECRET_PREFIX_CHARS = 48

# WHY: wider than sandbox._scrub on purpose; a token re-minted on a read is
# never named in advance.
TOKEN_KEYS = frozenset({"session_token", "saved_token", "used_token"})

# WHY: the checkout URL carries the token as a query parameter too.
_URL_TOKEN_RE = re.compile(r"(?<=[?&]session=)[^&#\s]+")


def redact(data: bytes, secrets: Iterable[str | None] = ()) -> bytes:
    """Remove JWT-shaped strings and the named secrets from an artifact."""
    # WHY: the shape rule runs first; the prefix rule would hide a token's tail from it.
    data = JWT_RE.sub(REDACTED, data)
    for secret in secrets:
        if secret and len(secret) >= MIN_SECRET_CHARS:
            data = _replace_prefixes(data, secret.encode("utf-8"))
    return data


def _replace_prefixes(data: bytes, secret: bytes) -> bytes:
    """Replace `secret`, and any long prefix of it, wherever it appears."""
    if len(secret) < MIN_SECRET_PREFIX_CHARS:
        return data.replace(secret, REDACTED)
    head = secret[:MIN_SECRET_PREFIX_CHARS]
    out = bytearray()
    at = 0
    while (found := data.find(head, at)) >= 0:
        end = len(head)
        while (
            end < len(secret)
            and data[found + end : found + end + 1] == (secret[end : end + 1])
        ):
            end += 1
        out += data[at:found] + REDACTED
        at = found + end
    out += data[at:]
    return bytes(out)


def scrub_resource(value: Any) -> tuple[Any, list[str]]:
    """Return a copy of the resource with its tokens replaced, and the tokens it held."""
    # WHY: a scrubbed token is replaced, not removed, so saved_card_saved and
    # saved_card_used still read presence.
    found: list[str] = []

    def walk(node: Any) -> Any:
        if isinstance(node, dict):
            out = {}
            for key, item in node.items():
                if key in TOKEN_KEYS and isinstance(item, str) and item:
                    found.append(item)
                    out[key] = REDACTED.decode()
                elif key.endswith("_url") and isinstance(item, str):

                    def take(match: "re.Match[str]") -> str:
                        found.append(match.group(0))
                        return REDACTED.decode()

                    out[key] = _URL_TOKEN_RE.sub(take, item)
                else:
                    out[key] = walk(item)
            return out
        if isinstance(node, list):
            return [walk(item) for item in node]
        return node

    return walk(value), found


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")


# WHY: refused rather than sanitised, because a cell file named `...yaml` has stem `..`.
UNSAFE_IN_PATH = ("/", "\\", "..")


def check_cell_id(cell_id: str) -> None:
    """Raise ValueError unless this id is safe to make a path out of."""
    if not cell_id or any(bad in cell_id for bad in UNSAFE_IN_PATH):
        raise ValueError(f"unsafe cell id: {cell_id!r}")


class Run:
    """One invocation of the runner and the directory tree it fills."""

    def __init__(self, root: Path, platform: str, run_id: str | None = None):
        # WHY: the platform is in the id so two platforms started in the same
        # second do not share a directory.
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
        """Write one redacted artifact and return where it landed."""
        path = self.cell_dir(cell_id) / name
        path.write_bytes(redact(data, secrets))
        return path

    def write_report(self, record: dict[str, Any]) -> Path:
        """Write the run's summary to report.json."""
        path = self.dir / "report.json"
        path.write_bytes(redact(json.dumps(record, indent=2).encode()))
        return path

    def append_progress(
        self, record: dict[str, Any], *, secrets: Iterable[str | None] = ()
    ) -> None:
        """Append one line to progress.jsonl and fsync it."""
        # WHY: platform is written last, so a record cannot file its results
        # under another platform's ledger.
        line = json.dumps({**record, "at": _now(), "platform": self.platform})
        with self.progress_path.open("ab") as handle:
            handle.write(redact(line.encode(), secrets) + b"\n")
            handle.flush()
            os.fsync(handle.fileno())


def passed_cells(root: Path, platform: str, build_id: str | None = None) -> set[str]:
    """Return the cell ids that passed on this platform, in any previous run."""
    # WHY: the build is named, not hashed; the iOS .app is a directory.
    passed: set[str] = set()
    for path in sorted(Path(root).glob("*/progress.jsonl")):
        for line in path.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                # WHY: a run killed mid-append leaves a partial last line; skip it
                # rather than strand the resume.
                continue
            if (
                record.get("platform") == platform
                and record.get("status") == "pass"
                and record.get("cell")
                # WHY: .get, so a legacy record with no build key reads as None.
                and record.get("build") == build_id
                # WHY: an interleaved control check is not the control cell's own
                # run, so it is no pass.
                and not record.get("control_check")
            ):
                passed.add(record["cell"])
    return passed
