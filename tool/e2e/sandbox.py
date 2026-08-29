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
import http.client
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

#: What the TEST deployment does today: cognito-m2m issues a 3600 s token and
#: the API-Gateway cache in front of it holds for 3300 s. Named because the
#: margin below is only correct relative to these two numbers -- if the infra
#: changes, this is the pair to re-measure.
OBSERVED_TOKEN_LIFETIME_SECONDS = 3600.0
OBSERVED_TOKEN_CACHE_TTL_SECONDS = 3300.0

#: How early to replace a token, and the one constant here with a hard upper
#: bound rather than a preference.
#:
#: A token minted at the origin at T0 expires at T0 + lifetime, but the cache
#: keeps serving it until T0 + cacheTTL. The refresh fires at T0 + lifetime -
#: margin, so it reaches the origin only when
#:
#:     margin < lifetime - cacheTTL        (3600 - 3300 = 300 s today)
#:
#: The failure mode of getting this wrong is not a stale token, it is a busy
#: loop: a margin of 300 or more schedules the refresh inside the cache
#: window, the gateway returns the very same token, its `exp` has not moved,
#: so the client decides it needs refreshing again -- immediately, and every
#: time. Smaller is safe; larger is not. 240 leaves a minute of headroom past
#: the boundary and still replaces the token four minutes before it dies.
TOKEN_REFRESH_MARGIN_SECONDS = 240.0

#: How far in the past an `exp` has to be before it is treated as a clock
#: problem rather than a dead token. A token really is dead the moment it
#: passes, but nothing hands out one older than its own lifetime -- so an
#: `exp` further back than that is this machine's clock, not the issuer's.
#: (WSL suspends; the monotonic clock not advancing across one is a failure
#: mode this campaign has already reasoned about.)
IMPLAUSIBLE_EXP_AGE_SECONDS = OBSERVED_TOKEN_LIFETIME_SECONDS

#: Failures worth one more try. HTTPException covers the short reads and bad
#: status lines that surface out of `response.read()`, after the status line
#: has already arrived: those are not URLErrors and would otherwise escape
#: this module as a raw http.client exception.
TRANSIENT = (urllib.error.URLError, TimeoutError, http.client.HTTPException)

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
        with urllib.request.urlopen(
            request, timeout=REQUEST_TIMEOUT_SECONDS
        ) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        # urlopen raises on any 4xx/5xx and the API's explanation is in the
        # body, so the status is handed back instead of the exception: the
        # caller turns it into a SandboxError naming the status and the reason
        # rather than a raw traceback.
        return error.code, error.read()


def _scrub(value: Any) -> Any:
    """Drops every `session_token` from a decoded body, at any depth.

    Deliberately narrower than `evidence.TOKEN_KEYS`, which this does not
    share. This one guards an error message: the body is an API response, so
    a token in it is whole and three-segmented, and the `_JWT` mask below
    catches anything this key list misses. Evidence has neither guarantee --
    it holds device dumps and console logs, where a token arrives truncated,
    wrapped or decapitated -- so its list is longer and is paired with the
    layering described in `evidence`'s module docstring.
    """
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


def _jwt_exp(token: Any) -> tuple[float | None, str | None]:
    """The `exp` claim out of a JWT, and why there was not one to read.

    Two answers rather than one, because only this function can tell "that is
    not a JWT at all" -- a legitimate `expires_in` case, worth no warning --
    from "that is a JWT whose `exp` is unusable", which is the trap the
    fallback was written to avoid falling into silently. The second value is
    non-None only in the second case, and describes the claim's shape without
    quoting it: this text reaches a report.

    Deliberately does not verify the signature: this is scheduling, not
    authentication. A forged `exp` costs an unnecessary refresh, and the API
    is what decides whether a token is honoured.
    """
    if not isinstance(token, str):
        return None, None
    parts = token.split(".")
    if len(parts) != 3:
        return None, None
    padded = parts[1] + "=" * (-len(parts[1]) % 4)
    try:
        # binascii.Error subclasses ValueError, so a payload that is not
        # base64 at all lands here with the rest.
        claims = json.loads(base64.urlsafe_b64decode(padded))
    except (ValueError, TypeError):
        return None, None
    if not isinstance(claims, dict):
        # Three segments that decode to something that is not a claim set.
        # Not a JWT, whatever it is shaped like.
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
    """How long a freshly issued access token may be reused for, and any doubts.

    The JWT's own `exp` is preferred over `expires_in` because only one of
    them describes *this* token. The M2M endpoint sits behind an API-Gateway
    cache, and a cached hit arrives with a full `expires_in` restated as
    though the token had just been minted -- so a client starting partway
    through a token's life is told it has the whole thing. `exp` is inside the
    signed payload and is not rewritten by the cache (cognito-m2m#1).

    `expires_in` remains the fallback for a token that is not a JWT, or whose
    payload carries no usable `exp`. Falling back to the distrusted field is
    worth saying out loud, so the warnings come back alongside the delay --
    the same shape `verify_merchant` and `scrub_resource` already use. Pure,
    and a caller decides what to do with them.
    """
    exp, unusable = _jwt_exp(raw.get("access_token"))
    warnings = []
    if unusable:
        warnings.append(
            f"the access token is a JWT but its 'exp' is {unusable}; falling "
            "back to expires_in, which the API-Gateway cache is known to "
            "restate -- cognito-m2m#1"
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
    """`over` wins, one key at a time, all the way down.

    A shallow merge is enough until a cell needs to change one field of a
    nested block: D5 pins `customer.merchant_reference` so two sessions
    resolve to one customer, and a shallow merge would drop the rest of the
    customer with it -- and the create schema requires those fields.

    Neither side is mutated: a cell's `options` mapping is loaded once and
    reused across a resume.
    """
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
        now: Callable[[], float] = time.time,
    ):
        self._env = dict(env)
        self._transport = transport or _urllib_transport
        self._sleep = sleep
        self._monotonic = monotonic
        # Wall clock, because a JWT `exp` is an epoch stamp. The expiry itself
        # is still tracked on the monotonic clock, which a clock adjustment
        # mid-run cannot move.
        self._now = now
        self._access_token: str | None = None
        self._token_expires_at = 0.0
        #: Things that went quietly right-ish and are worth saying out loud.
        #: The runner drains these into report.json and prints them; they are
        #: never problems, because a warning that turns a green matrix red is
        #: a warning the next person learns to silence.
        self.warnings: list[str] = []

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
        restating the customer block every time. The merge is deep: a cell
        that sets one field of `customer` keeps the rest of it, and a scalar
        still replaces a scalar. There is no way to *remove* a default field,
        and nothing needs one.
        """
        body = _deep_merge(_session_body(amount, currency, reference), options)

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
        if status == 401:
            # The backstop for every expiry the clock cannot predict. The
            # scheduled refresh reads the token's own `exp`, which covers the
            # ordinary case, but it is silent when there is no claim to read
            # (a token that is not a JWT, or one whose payload carries no
            # usable `exp`, both of which fall back to the `expires_in` the
            # gateway may have restated), and it cannot see a clock that
            # disagrees with the issuer's or a token revoked before its time.
            #
            # In all of those the API is the only thing that knows, and a 401
            # is how it says so: drop the token and replay once.
            #
            # The refetch reaches the origin rather than the cache because a
            # token old enough to be refused has outlived a cache entry
            # shorter than its own lifetime.
            #
            # Once, never in a loop. A replay refused again means the
            # credentials or the environment are wrong, and `_decode` says so.
            self._access_token = None
            self._token_expires_at = 0.0
            merged["Authorization"] = f"Bearer {self._bearer()}"
            status, payload = self._request(method, url, merged, body)
        return _decode(method, url, status, payload)

    def _request(
        self, method: str, url: str, headers: dict[str, str], body: bytes | None
    ) -> tuple[int, bytes]:
        """One request, retried once for a transport failure or a 5xx.

        A 4xx is the API's considered answer and is never retried: repeating a
        refusal only spends run time. Retrying a mint is safe because its
        Idempotency-Key is generated before the call and replayed unchanged
        with it -- regenerating it here would bill a second live session.
        """
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
        # Once each, however many times a long run refreshes: the same
        # degradation restated forty times in a report reads as forty
        # findings. A list rather than a set, because the order they were
        # first noticed in is the order worth reading them in -- and the
        # clock warning carries its own measurement, so two genuinely
        # different ones stay two.
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
