"""Minting and reading TEST payment sessions through the merchant API.

Contains no credentials. The caller passes the path of an env file at runtime
and this module sources it in-process; nothing it reads is ever logged, put on
a command line, or written into the evidence tree.
"""

from __future__ import annotations

import base64
import json
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

Transport = Callable[[str, str, dict, bytes | None], bytes]


class SandboxError(RuntimeError):
    """The merchant API did not do what was asked. Never carries a token."""


def read_env_file(path: Path) -> dict[str, str]:
    """Parses the shell-style env file the campaign's credentials live in.

    Deliberately not `set -a; . file`: this reads only the five keys it needs
    and returns them, so nothing else in that file can end up in a subprocess
    environment by accident.
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


def _urllib_transport(method: str, url: str, headers: dict, body: bytes | None) -> bytes:
    request = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        # urlopen raises on any 4xx/5xx, and the API's explanation is in the
        # body. Without this, mint's "safe to echo: a refusal carries no token"
        # branch is unreachable against the live API and a malformed cell
        # surfaces as a raw traceback instead of the reason.
        return error.read()


def _safe_to_echo(raw: Any) -> str:
    """A mint response rendered for an error message, minus any session_token.

    A refusal carries no token, but the same branch fires if the API ever
    answers with a token and no id, so the token is dropped rather than
    assumed absent.
    """
    if isinstance(raw, dict):
        raw = {k: v for k, v in raw.items() if k != "session_token"}
    return json.dumps(raw)[:400]


class Sandbox:
    """A thin merchant-API client: one M2M token, mint, read."""

    def __init__(self, env: dict[str, str], transport: Transport | None = None):
        self._env = dict(env)
        self._transport = transport or _urllib_transport
        self._access_token: str | None = None

    def __repr__(self) -> str:
        # The default dataclass-ish repr would print the client secret.
        return f"<Sandbox {self._env['PAYMENT_API_URL']}>"

    @classmethod
    def from_env_file(cls, path: Path, transport: Transport | None = None) -> "Sandbox":
        return cls(read_env_file(path), transport=transport)

    def mint(self, amount: int, currency: str, options: dict[str, Any]) -> dict[str, str]:
        """Creates one session and returns `{"id": …, "token": …}`.

        `options` is merged over the default body rather than replacing it, so
        a cell can add `save_card_config` or a `data.wallets` gate without
        restating the customer block every time.
        """
        stamp = int(time.time())
        body: dict[str, Any] = {
            "amount": amount,
            "currency": currency,
            "transaction_type": "sale",
            "merchant_reference": f"ORDER-{stamp}",
            "return_url": "https://merchant.example.com/payment/return",
            "success_url": "https://merchant.example.com/payment/success",
            "customer": {
                "email": "john.doe@example.com",
                "first_name": "John",
                "last_name": "Doe",
                "phone": "+12025551234",
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
        body.update(options)

        raw = self._call(
            "POST",
            self._env["PAYMENT_API_URL"],
            body=json.dumps(body).encode(),
            headers={
                "Content-Type": "application/json",
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
        return self._call("GET", f"{self._env['PAYMENT_API_URL']}/{session_id}")

    def _call(
        self,
        method: str,
        url: str,
        body: bytes | None = None,
        headers: dict[str, str] | None = None,
    ) -> dict[str, Any]:
        merged = {
            "User-Agent": USER_AGENT,
            "Authorization": f"Bearer {self._bearer()}",
            "PayCross-Version": self._env["PAYCROSS_VERSION"],
        }
        merged.update(headers or {})
        return json.loads(self._transport(method, url, merged, body))

    def _bearer(self) -> str:
        if self._access_token is None:
            basic = base64.b64encode(
                f"{self._env['CLIENT_PAYX_SANDBOX_ID']}:"
                f"{self._env['CLIENT_PAYX_SANDBOX_SECRET']}".encode()
            ).decode()
            raw = json.loads(
                self._transport(
                    "POST",
                    self._env["TOKEN_URL"],
                    {
                        "User-Agent": USER_AGENT,
                        "Authorization": f"Basic {basic}",
                        "Content-Type": "application/x-www-form-urlencoded",
                    },
                    b"grant_type=client_credentials",
                )
            )
            if "access_token" not in raw:
                raise SandboxError("the token endpoint returned no access_token")
            self._access_token = raw["access_token"]
        return self._access_token
