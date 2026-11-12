"""Mints and reads TEST payment sessions through the merchant API."""

from __future__ import annotations

import base64
import http.client
import json
import re
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from typing import Any, Callable

# WHY: the TEST API's Cloudflare refuses urllib's default User-Agent outright.
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

MAX_ATTEMPTS = 2
RETRY_BACKOFF_SECONDS = 2.0

DEFAULT_TOKEN_LIFETIME_SECONDS = 3600.0

# WHY: the TEST gateway caches a 3600 s token for 3300 s; the refresh margin depends on both.
OBSERVED_TOKEN_LIFETIME_SECONDS = 3600.0
OBSERVED_TOKEN_CACHE_TTL_SECONDS = 3300.0

# WHY: a margin of 300 s or more refreshes inside the gateway cache window and busy-loops on one token.
TOKEN_REFRESH_MARGIN_SECONDS = 240.0

# WHY: an exp older than one lifetime is this machine's clock (WSL suspend), not a dead token.
IMPLAUSIBLE_EXP_AGE_SECONDS = OBSERVED_TOKEN_LIFETIME_SECONDS

# WHY: HTTPException covers short reads after the status line; those are not URLErrors.
TRANSIENT = (urllib.error.URLError, TimeoutError, http.client.HTTPException)

_JWT = re.compile(r"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+")

_ECHO_LIMIT = 400

Transport = Callable[[str, str, dict, bytes | None], tuple[int, bytes]]


class SandboxError(RuntimeError):
    """The merchant API did not do what was asked. Never carries a token."""


def read_env_file(path: Path | str) -> dict[str, str]:
    """Parses the five keys the campaign needs out of a shell-style env file."""
    # WHY: not `set -a; . file`, so nothing else in the file reaches a subprocess environment.
    # WHY: the parsing is shallow: no unescaping, no variable expansion, no inline comments.
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
        # WHY: names the keys only, never a value.
        raise SandboxError(f"{path}: missing {', '.join(missing)}")
    return values


def _urllib_transport(
    method: str, url: str, headers: dict, body: bytes | None
) -> tuple[int, bytes]:
    request = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(
            request, timeout=REQUEST_TIMEOUT_SECONDS
        ) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        # WHY: urlopen raises on any 4xx/5xx; the status and body are returned so the API's reason is reported.
        return error.code, error.read()


def _scrub(value: Any) -> Any:
    """Drops every `session_token` from a decoded body, at any depth."""
    if isinstance(value, dict):
        return {k: _scrub(v) for k, v in value.items() if k != "session_token"}
    if isinstance(value, list):
        return [_scrub(item) for item in value]
    return value


def _safe_to_echo(payload: Any) -> str:
    """Renders a response for an error message with every token stripped."""
    if isinstance(payload, (bytes, bytearray)):
        try:
            payload = json.loads(payload)
        except ValueError:
            text = bytes(payload).decode("utf-8", errors="replace")
            return _JWT.sub("<redacted>", text)[:_ECHO_LIMIT]
    return _JWT.sub("<redacted>", json.dumps(_scrub(payload)))[:_ECHO_LIMIT]


def _jwt_exp(token: Any) -> tuple[float | None, str | None]:
    """The `exp` claim of a JWT, and why there is none to read."""
    # WHY: the signature is not verified: this is scheduling, not authentication.
    if not isinstance(token, str):
        return None, None
    parts = token.split(".")
    if len(parts) != 3:
        return None, None
    padded = parts[1] + "=" * (-len(parts[1]) % 4)
    try:
        # WHY: binascii.Error is a ValueError, so a payload that is not base64 lands here too.
        claims = json.loads(base64.urlsafe_b64decode(padded))
    except (ValueError, TypeError):
        return None, None
    if not isinstance(claims, dict):
        return None, None
    if "exp" not in claims:
        return None, "absent"
    exp = claims["exp"]
    # bool is an int; `exp: true` is not a deadline.
    if isinstance(exp, bool):
        return None, "a boolean"
    if not isinstance(exp, (int, float)):
        return None, f"a {type(exp).__name__}"
    return float(exp), None


def _refresh_after(raw: dict[str, Any], now: float) -> tuple[float, list[str]]:
    """Seconds a fresh token may be reused: the JWT `exp` beats the cached `expires_in`."""
    exp, unusable = _jwt_exp(raw.get("access_token"))
    warnings = []
    if unusable:
        warnings.append(
            f"the access token is a JWT but its 'exp' is {unusable}; falling "
            "back to expires_in, which the API-Gateway cache is known to "
            "restate -- tracked internally"
        )
    elif exp is not None and exp < now - IMPLAUSIBLE_EXP_AGE_SECONDS:
        warnings.append(
            f"the access token's exp is {now - exp:.0f}s in the past, further "
            "back than a whole token lifetime; treating that as this machine's "
            "clock rather than the issuer's, and falling back to expires_in"
        )
        exp = None

    if exp is not None:
        return max(exp - now - TOKEN_REFRESH_MARGIN_SECONDS, 0.0), warnings
    try:
        lifetime = float(raw.get("expires_in", DEFAULT_TOKEN_LIFETIME_SECONDS))
    except (TypeError, ValueError):
        lifetime = DEFAULT_TOKEN_LIFETIME_SECONDS
    return max(lifetime - TOKEN_REFRESH_MARGIN_SECONDS, 0.0), warnings


def _deep_merge(base: dict[str, Any], over: dict[str, Any]) -> dict[str, Any]:
    out = dict(base)
    for key, value in over.items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = _deep_merge(out[key], value)
        else:
            out[key] = value
    return out


def _session_body(amount: int, currency: str, reference: str | None) -> dict[str, Any]:
    """The create-session request every D0 cell mints against."""
    stamp = int(time.time())
    return {
        "amount": amount,
        "currency": currency,
        "transaction_type": "sale",
        "merchant_reference": reference or f"ORDER-{stamp}-{uuid.uuid4().hex[:8]}",
        "return_url": "https://merchant.example.com/payment/return",
        "success_url": "https://merchant.example.com/payment/success",
        "customer": {
            "email": "john.doe@example.com",
            "first_name": "John",
            "last_name": "Doe",
            "phone": "+12025551234",
            # Per-second stamp on purpose: saved-card cells need one customer reference.
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
        now: Callable[[], float] = time.time,
    ):
        self._env = dict(env)
        self._transport = transport or _urllib_transport
        self._sleep = sleep
        self._monotonic = monotonic
        # Wall clock: a JWT `exp` is an epoch stamp.
        self._now = now
        self._access_token: str | None = None
        self._token_expires_at = 0.0
        #: Non-fatal findings the runner reports; they never fail a run.
        self.warnings: list[str] = []

    def __repr__(self) -> str:
        # The default repr would print the client secret.
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
        """Creates one session; `options` is deep-merged over the default body."""
        body = _deep_merge(_session_body(amount, currency, reference), options)

        raw = self._call(
            "POST",
            self._env["PAYMENT_API_URL"],
            body=json.dumps(body).encode(),
            headers={
                "Content-Type": "application/json",
                # Generated once, so a retry in _request replays the same key.
                "Idempotency-Key": str(uuid.uuid4()),
            },
        )
        if not isinstance(raw, dict) or "session_token" not in raw or "id" not in raw:
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
        if status == 401:
            # A 401 can mean an expiry the clock cannot predict: refetch and replay once.
            # A replay refused again means the credentials or environment are wrong.
            self._access_token = None
            self._token_expires_at = 0.0
            merged["Authorization"] = f"Bearer {self._bearer()}"
            status, payload = self._request(method, url, merged, body)
        return _decode(method, url, status, payload)

    def _request(
        self, method: str, url: str, headers: dict[str, str], body: bytes | None
    ) -> tuple[int, bytes]:
        """One request, retried for a transport failure or a 5xx, never for a 4xx."""
        attempt = 0
        while True:
            attempt += 1
            final = attempt >= MAX_ATTEMPTS
            try:
                status, payload = self._transport(method, url, headers, body)
            except TRANSIENT as error:
                if final:
                    raise SandboxError(
                        f"{method} {url} failed after {attempt} attempts: "
                        f"{type(error).__name__}: {error}"
                    ) from error
            else:
                if status < 500 or final:
                    return status, payload
            self._sleep(RETRY_BACKOFF_SECONDS)

    # WHY: the locals of _bearer and mint hold the client secret and a token; --showlocals would log them.
    def _bearer(self) -> str:
        if (
            self._access_token is not None
            and self._monotonic() < self._token_expires_at
        ):
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
        delay, warnings = _refresh_after(raw, self._now())
        # Each warning once, however many refreshes restate it.
        self.warnings += [w for w in warnings if w not in self.warnings]
        self._token_expires_at = self._monotonic() + delay
        return self._access_token


def _decode(method: str, url: str, status: int, payload: bytes) -> Any:
    """Turns one response into JSON, or into an error that says why not."""
    if not 200 <= status < 300:
        raise SandboxError(f"{method} {url} -> HTTP {status}: {_safe_to_echo(payload)}")
    try:
        return json.loads(payload)
    except ValueError as error:
        raise SandboxError(
            f"{method} {url} -> HTTP {status}, body is not JSON: "
            f"{_safe_to_echo(payload)}"
        ) from error
