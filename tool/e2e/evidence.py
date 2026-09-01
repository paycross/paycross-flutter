"""Where a run's proof goes, and what is scrubbed out of it on the way.

The evidence root lives outside every git checkout (WSL reboots have killed
runs before, and the campaign directory survives them). One directory per run,
one subdirectory per cell, and a `progress.jsonl` written incrementally so an
interrupted run can be resumed rather than restarted.

Redaction is three rules, and the order of the first two is load-bearing:

1. **Shape** -- `JWT_RE`, an `eyJ` head and one or more further base64url
   segments of at least sixteen characters. Catches a token nobody named,
   including one the device truncated before its signature.
2. **Literal, and any long prefix, of a named secret** -- what the caller
   knows it handed over. Never before the shape rule: it replaces a *head*,
   and the shape rule is anchored on the `eyJ` that head begins with, so
   running it first decapitates a token and hides the tail from rule 1.
3. **Key** -- `scrub_resource` drops `TOKEN_KEYS` at any depth and the
   `session=` parameter of any `*_url`, by name rather than by shape, and
   hands back what it found.

The runner stacks them per cell: it starts with the token it minted, and after
the merchant read it adds whatever rule 3 returned -- a GET on an open session
re-mints a token the runner never saw -- so everything filed after that read is
covered by rule 2 as well.

`sandbox._safe_to_echo` is a separate and narrower rule for error messages:
it drops `session_token` and masks JWT-shaped text before truncating, so a
refusal quoted into an exception carries no credential. It is not this
pipeline and does not need to be, because nothing it produces is an artifact.
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

#: Keys whose value is a credential wherever they appear in a merchant
#: resource. Wider than `sandbox._scrub`'s single key on purpose -- see there.
#: A GET on an *open* session re-mints a `session_token` and hands it back, so
#: the runner is given a live token it never minted and cannot name as
#: a secret in advance -- which is how full tokens reached merchant.json in the
#: first live iOS run. Dropped by key, so this holds however the value is
#: shaped and whatever the shape rule can or cannot see.
TOKEN_KEYS = frozenset({"session_token", "saved_token", "used_token"})

#: The same credential again, as a query parameter: the checkout URL carries
#: `?session=<token>`, so dropping the field alone leaves the whole thing on
#: disk one key over.
_URL_TOKEN_RE = re.compile(r"(?<=[?&]session=)[^&#\s]+")


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
    # The shape rule goes first, while a token still looks like one. The
    # prefix rule below replaces a *head*, and JWT_RE is anchored on the `eyJ`
    # that head begins with -- so running it second means a token that shares a
    # long prefix with a known secret is decapitated and its tail is then
    # invisible to the regex. That is not hypothetical: the merchant API
    # re-mints a session token on every read of an open session, and the new
    # one shares a 617-character head with the old.
    data = JWT_RE.sub(REDACTED, data)
    for secret in secrets:
        if secret and len(secret) >= MIN_SECRET_CHARS:
            data = _replace_prefixes(data, secret.encode("utf-8"))
    return data


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
    """A merchant resource with its tokens removed, and the tokens it held.

    Two jobs, because they are the same walk. What comes back first is safe to
    file; what comes back second is what the caller now knows is sensitive and
    should hand to `redact()` as `secrets=` for everything it files afterwards.

    Removal is by key (`TOKEN_KEYS`) and by the checkout URL's `session=`
    parameter -- never by shape. The value here is a live credential whatever
    it looks like, and the shape rule has already been shown to miss one.

    The runner hands the scrubbed copy on to `verify` as well as to disk, and
    that is safe for a reason worth stating exactly, because it is narrower
    than it used to be. `verify` mostly wants `status`, `transactions` and the
    failure block, none of which are touched here. But D5's `saved_card_saved`
    and `saved_card_used` read `stored_credentials.saved_token` and
    `used_token`, which ARE in `TOKEN_KEYS` -- and they work only because a
    scrubbed token is **replaced rather than removed**: the key survives
    carrying `REDACTED`, so a stored card is truthy and an absent one is still
    the original `null`. That is why those two assertions are documented as
    testing presence and never a value, and why removing the key instead --
    which reads like the safer choice -- would silently turn every
    `saved_card_saved: true` into a failure.

    Only a non-empty string is replaced, so a `"saved_token": null` on an
    ordinary payment passes through untouched as null.

    The caller's own object is left alone regardless: this builds a new one
    rather than deleting in place.
    """
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

    def write_report(self, record: dict[str, Any]) -> Path:
        """The run's own summary, so a finished run is readable off disk.

        The exit code reaches stdout and nowhere else, and nothing downstream
        -- the nightly, the campaign report -- can parse a 40-minute run's
        output. Written through `redact()` like every other artifact: every
        field the runner puts in here has already been through `_redacted`, so
        this is belt and braces rather than the only guard.
        """
        path = self.dir / "report.json"
        path.write_bytes(redact(json.dumps(record, indent=2).encode()))
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


def passed_cells(root: Path, platform: str, build_id: str | None = None) -> set[str]:
    """Cell ids that have passed on this platform in *any* previous run.

    Scanning the runs themselves rather than keeping a separate ledger: a
    second source of truth about what passed is a second thing that can be
    wrong, and these files are small.

    A pass only counts when it was recorded against the same build. Hashing is
    not an option -- the iOS `.app` is a directory on the Mac -- so the build
    is *named*, not measured, and a run that names none matches records that
    carry none. Every record written before this existed has no `build` key at
    all, so an existing evidence root keeps resuming exactly as it did.
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
                # Named, not measured -- see the docstring. `.get` rather than
                # `record["build"]` so a legacy record reads as None and a run
                # with no --build-id still resumes from it.
                and record.get("build") == build_id
                # An interleaved control check is a rig probe, not the control
                # cell's own run. Counting it would let a resumed run skip
                # `control` -- and then the next failure's skepticism check
                # re-runs a cell the resume logic already considers done.
                and not record.get("control_check")
            ):
                passed.add(record["cell"])
    return passed
