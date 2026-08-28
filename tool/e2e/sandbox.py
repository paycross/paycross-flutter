"""Minting and reading TEST payment sessions through the merchant API.

Contains no credentials of its own. The caller passes the path of an env file
at runtime and `read_env_file` parses exactly the five keys it needs out of it
-- it does not source the file, so nothing else in it can reach a subprocess
by accident -- and the values it read stay inside one `Sandbox` instance.

The minted `session_token` is a live credential. This module hands it back to
the caller and does nothing else with it: it is never logged, never put on a
command line, and every error message raised here goes through `_safe_to_echo`
first, which drops `session_token` at any depth and masks anything JWT-shaped.
Redacting what a caller then writes into the evidence tree is not this
module's job -- that belongs to `evidence.redact()`.

Do not run this module's tests with `pytest --showlocals`. The locals of
`_bearer` and `mint` hold the client secret and a live session token, and that
flag would print both into the run log.
"""

from __future__ import annotations

import base64
import json
import re
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from typing import Any, Callable

#: Cloudflare in front of the TEST API refuses urllib's default User-Agent
#: outright. Every seed script sends a browser UA; so does this.
USER_AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/140.0 Safari/537.36"
)

REQUIRED_KEYS = (
    "CLIENT_PAYX_SANDBOX_ID",
    "CLIENT_PAYX_SANDBOX_SECRET",
    "TOKEN_URL",
    "PAYMENT_API_URL",
    "PAYCROSS_VERSION",
)

REQUEST_TIMEOUT_SECONDS = 60

#: One retry, not a storm: a matrix run would rather fail a cell in seconds
#: than mask a broken TEST environment behind minutes of backoff.
MAX_ATTEMPTS = 2
RETRY_BACKOFF_SECONDS = 2.0

DEFAULT_TOKEN_LIFETIME_SECONDS = 3600.0

#: The M2M token lives 3600 s, behind an API-Gateway cache that holds for
#: 3300 s. Refreshing 300 s early both avoids expiring mid-run and lands past
#: that cache TTL, which is what makes the replacement actually fresh.
TOKEN_REFRESH_MARGIN_SECONDS = 300.0

#: Any JWT in a body: the session token is one, and so is the M2M token.
_JWT = re.compile(r"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+")

_ECHO_LIMIT = 400

Transport = Callable[[str, str, dict, bytes | None], tuple[int, bytes]]


class SandboxError(RuntimeError):
    """The merchant API did not do what was asked. Never carries a token."""


def read_env_file(path: Path | str) -> dict[str, str]:
    """Parses the shell-style env file the campaign's credentials live in.

    Deliberately not `set -a; . file`: this reads only the five keys it needs
    and returns them, so nothing else in that file can end up in a subprocess
    environment by accident.

    The parsing is shallow, which is enough for the campaign's file and worth
    knowing before pointing it at another one. `export ` is stripped, one
    layer of surrounding quotes is removed, and everything after the first `=`
    is the value. There is no unescaping, no variable expansion and no
    inline-comment handling, so a value containing ` #` keeps it and a value
    that genuinely ends in a quote loses that character.
    """
    values: dict[str, str] = {}
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        line = line.removeprefix("export ").strip()
        key, sep, value = line.partition("=")
        if not sep:
            continue
        key = key.strip()
        if key in REQUIRED_KEYS:
            values[key] = value.strip().strip("'\"")

    missing = [k for k in REQUIRED_KEYS if k not in values]
    if missing:
        # Names the keys, never anything it managed to read.
        raise SandboxError(f"{path}: missing {', '.join(missing)}")
    return values


def _urllib_transport(
    method: str, url: str, headers: dict, body: bytes | None
) -> tuple[int, bytes]:
    request = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_SECONDS) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        # urlopen raises on any 4xx/5xx and the API's explanation is in the
        # body, so the status is handed back instead of the exception: the
        # caller turns it into a SandboxError naming the status and the reason
        # rather than a raw traceback.
        return error.code, error.read()


def _scrub(value: Any) -> Any:
    """Drops every `session_token` from a decoded body, at any depth."""
    if isinstance(value, dict):
        return {k: _scrub(v) for k, v in value.items() if k != "session_token"}
    if isinstance(value, list):
        return [_scrub(item) for item in value]
    return value


def _safe_to_echo(payload: Any) -> str:
    """Renders a response for an error message with every token stripped.

    Whole session resources reach here, not just refusals -- a GET on a
    session returns its live `session_token` -- and so do Cloudflare's HTML
    pages, which are not JSON at all. The key is dropped at every depth and
    anything else JWT-shaped is masked before the text is truncated.
    """
    if isinstance(payload, (bytes, bytearray)):
        try:
            payload = json.loads(payload)
        except ValueError:
            text = bytes(payload).decode("utf-8", errors="replace")
            return _JWT.sub("<redacted>", text)[:_ECHO_LIMIT]
    return _JWT.sub("<redacted>", json.dumps(_scrub(payload)))[:_ECHO_LIMIT]


def _refresh_after(raw: dict[str, Any]) -> float:
    """How long a freshly issued access token may be reused for."""
    try:
        lifetime = float(raw.get("expires_in", DEFAULT_TOKEN_LIFETIME_SECONDS))
    except (TypeError, ValueError):
        lifetime = DEFAULT_TOKEN_LIFETIME_SECONDS
    return max(lifetime - TOKEN_REFRESH_MARGIN_SECONDS, 0.0)


def _session_body(amount: int, currency: str, reference: str | None) -> dict[str, Any]:
    """The create-session request every D0 cell mints against."""
    stamp = int(time.time())
    return {
        "amount": amount,
        "currency": currency,
        "transaction_type": "sale",
        # A whole-second stamp alone collides when a matrix run mints several
        # cells inside one second.
        "merchant_reference": reference or f"ORDER-{stamp}-{uuid.uuid4().hex[:8]}",
        "return_url": "https://merchant.example.com/payment/return",
        "success_url": "https://merchant.example.com/payment/success",
        "customer": {
            "email": "john.doe@example.com",
            "first_name": "John",
            "last_name": "Doe",
            "phone": "+12025551234",
            # Left colliding on purpose: a stable customer reference is what a
            # saved-card cell will need, and pinning it is D5's call, not this
            # module's.
            "merchant_reference": f"CUST-{stamp}",
            "address": {
                "billing": {
                    "line1": "123 Main Street",
                    "line2": "Apt 4B",
                    "city": "New York",
                    "state": "NY",
                    "postal_code": "10001",
                    "country": "US",
                }
            },
        },
    }


class Sandbox:
    """A thin merchant-API client: one M2M token, mint, read."""

    def __init__(
        self,
        env: dict[str, str],
        transport: Transport | None = None,
        *,
        sleep: Callable[[float], None] = time.sleep,
        monotonic: Callable[[], float] = time.monotonic,
    ):
        self._env = dict(env)
        self._transport = transport or _urllib_transport
        self._sleep = sleep
        self._monotonic = monotonic
        self._access_token: str | None = None
        self._token_expires_at = 0.0

    def __repr__(self) -> str:
        # The default repr would print the client secret, and a repr that
        # raises KeyError inside a traceback hides the error being reported.
        return f"<Sandbox {self._env.get('PAYMENT_API_URL', '?')}>"

    @classmethod
    def from_env_file(
        cls, path: Path | str, transport: Transport | None = None
    ) -> "Sandbox":
        return cls(read_env_file(path), transport=transport)

    def mint(
        self,
        amount: int,
        currency: str,
        options: dict[str, Any],
        *,
        reference: str | None = None,
    ) -> dict[str, str]:
        """Creates one session and returns `{"id": …, "token": …}`.

        `options` is merged over the default body rather than replacing it, so
        a cell can add `save_card_config` or a `data.wallets` gate without
        restating the customer block every time. The merge is one level deep:
        a cell that sets `customer` replaces the whole block.
        """
        body = _session_body(amount, currency, reference)
        body.update(options)

        raw = self._call(
            "POST",
            self._env["PAYMENT_API_URL"],
            body=json.dumps(body).encode(),
            headers={
                "Content-Type": "application/json",
                # Generated before the call, so the retry in _request replays
                # the same key rather than minting a second session.
                "Idempotency-Key": str(uuid.uuid4()),
            },
        )
        if not isinstance(raw, dict) or "session_token" not in raw or "id" not in raw:
            # A body that is not an object at all reaches here too; without the
            # isinstance guard it is a raw TypeError instead of the reason.
            raise SandboxError(f"mint returned no session_token: {_safe_to_echo(raw)}")
        return {"id": raw["id"], "token": raw["session_token"]}

    def read(self, session_id: str) -> dict[str, Any]:
        """The merchant-side source of truth for one session."""
        url = f"{self._env['PAYMENT_API_URL']}/{session_id}"
        session = self._call("GET", url)
        if not isinstance(session, dict):
            raise SandboxError(
                f"GET {url} did not return a session object: {_safe_to_echo(session)}"
            )
        return session

    def _call(
        self,
        method: str,
        url: str,
        body: bytes | None = None,
        headers: dict[str, str] | None = None,
    ) -> Any:
        merged = {
            "User-Agent": USER_AGENT,
            "Authorization": f"Bearer {self._bearer()}",
            "PayCross-Version": self._env["PAYCROSS_VERSION"],
        }
        merged.update(headers or {})
        status, payload = self._request(method, url, merged, body)
        return _decode(method, url, status, payload)

    def _request(
        self, method: str, url: str, headers: dict[str, str], body: bytes | None
    ) -> tuple[int, bytes]:
        """One request, retried once for a transport failure or a 5xx.

        A 4xx is the API's considered answer and is never retried: repeating a
        refusal only spends run time. Retrying a mint is safe because its
        Idempotency-Key is generated before the call and replayed with it.
        """
        attempt = 0
        while True:
            attempt += 1
            final = attempt >= MAX_ATTEMPTS
            try:
                status, payload = self._transport(method, url, headers, body)
            except (urllib.error.URLError, TimeoutError) as error:
                if final:
                    raise SandboxError(
                        f"{method} {url} failed after {attempt} attempts: "
                        f"{type(error).__name__}: {error}"
                    ) from error
            else:
                if status < 500 or final:
                    return status, payload
            self._sleep(RETRY_BACKOFF_SECONDS)

    def _bearer(self) -> str:
        if self._access_token is not None and self._monotonic() < self._token_expires_at:
            return self._access_token

        basic = base64.b64encode(
            f"{self._env['CLIENT_PAYX_SANDBOX_ID']}:"
            f"{self._env['CLIENT_PAYX_SANDBOX_SECRET']}".encode()
        ).decode()
        url = self._env["TOKEN_URL"]
        status, payload = self._request(
            "POST",
            url,
            {
                "User-Agent": USER_AGENT,
                "Authorization": f"Basic {basic}",
                "Content-Type": "application/x-www-form-urlencoded",
            },
            b"grant_type=client_credentials",
        )
        raw = _decode("POST", url, status, payload)
        if not isinstance(raw, dict) or "access_token" not in raw:
            raise SandboxError("the token endpoint returned no access_token")
        self._access_token = raw["access_token"]
        self._token_expires_at = self._monotonic() + _refresh_after(raw)
        return self._access_token


def _decode(method: str, url: str, status: int, payload: bytes) -> Any:
    """Turns one response into JSON, or into an error that says why not."""
    if not 200 <= status < 300:
        raise SandboxError(f"{method} {url} -> HTTP {status}: {_safe_to_echo(payload)}")
    try:
        return json.loads(payload)
    except ValueError as error:
        raise SandboxError(
            f"{method} {url} -> HTTP {status}, body is not JSON: {_safe_to_echo(payload)}"
        ) from error
