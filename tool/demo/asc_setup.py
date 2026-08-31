"""App Store Connect setup for PayCross Demo.

Two invocations either side of a gate the API cannot cross. Apple's own
documentation says the `apps` resource does not allow CREATE -- the app
record is made in the web UI -- so this script registers the bundle id
*before* that step and creates the TestFlight group *after* it.

The signing key never reaches this module. `--key-path` names a file that
`sign_token` reads and immediately hands to pyjwt; nothing else opens it,
nothing prints it, and every error raised here goes through `_safe_detail`,
which quotes Apple's message and nothing of ours.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable, Optional

API = "https://api.appstoreconnect.apple.com"

#: Apple refuses a token that claims more than 20 minutes of life.
TOKEN_LIFETIME_SECONDS = 1200

REQUEST_TIMEOUT_SECONDS = 60

# `Optional[bytes]` rather than `bytes | None`: this alias is evaluated at import
# time, and the Mac that runs the live commands has only Python 3.9, where PEP 604
# unions in a runtime expression raise TypeError. The annotations below are strings
# (`from __future__ import annotations`) and can keep the modern spelling.
Transport = Callable[[str, str, dict, Optional[bytes]], tuple[int, bytes]]


class AscError(RuntimeError):
    """App Store Connect refused, or answered something unusable."""


def token_claims(issuer_id: str, *, now: int | None = None) -> dict[str, Any]:
    issued = int(time.time()) if now is None else now
    return {
        "iss": issuer_id,
        "iat": issued,
        "exp": issued + TOKEN_LIFETIME_SECONDS,
        "aud": "appstoreconnect-v1",
    }


def token_headers(key_id: str) -> dict[str, str]:
    return {"alg": "ES256", "kid": key_id, "typ": "JWT"}


def sign_token(key_id: str, issuer_id: str, key_path: Path) -> str:
    """ES256-signs a request token with the team key at `key_path`.

    pyjwt is imported here rather than at module scope so the pure functions
    above -- and every unit test -- work on a machine that has no crypto
    stack. Only the Mac ever calls this.
    """
    import jwt  # noqa: PLC0415 -- see the docstring.

    return jwt.encode(
        token_claims(issuer_id),
        Path(key_path).read_text(encoding="utf-8"),
        algorithm="ES256",
        headers=token_headers(key_id),
    )


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
        # Apple puts the reason in the body, so hand the status back rather
        # than the exception: the caller turns it into an AscError naming
        # both, instead of a traceback naming neither.
        return error.code, error.read()


def _safe_detail(payload: bytes) -> str:
    """Apple's own explanation, and nothing of ours."""
    try:
        decoded = json.loads(payload)
    except ValueError:
        return payload.decode("utf-8", errors="replace")[:400]
    errors = decoded.get("errors") if isinstance(decoded, dict) else None
    if isinstance(errors, list):
        details = [str(e.get("detail") or e.get("title")) for e in errors]
        return "; ".join(d for d in details if d)[:400]
    return json.dumps(decoded)[:400]


class AppStoreConnect:
    """The three verbs this script needs, and no more."""

    def __init__(
        self,
        *,
        key_id: str,
        issuer_id: str,
        token: Callable[[], str],
        transport: Transport | None = None,
    ):
        self._key_id = key_id
        # No `self._issuer_id`: the issuer only ever reaches Apple through the
        # `token` callable, which closes over it. A second copy on the client
        # is one more thing a future repr or log line could reach for.
        self._token = token
        self._transport = transport or _urllib_transport

    def __repr__(self) -> str:
        # The default repr would print the token callable's closure.
        return f"<AppStoreConnect key={self._key_id}>"

    def get(self, path: str, **query: str) -> dict[str, Any]:
        url = f"{API}{path}"
        if query:
            url = f"{url}?{urllib.parse.urlencode(query)}"
        return self._call("GET", url, None)

    def post(self, path: str, payload: dict[str, Any]) -> dict[str, Any]:
        return self._call("POST", f"{API}{path}", json.dumps(payload).encode())

    def _call(self, method: str, url: str, body: bytes | None) -> dict[str, Any]:
        headers = {
            "Authorization": f"Bearer {self._token()}",
            "Content-Type": "application/json",
        }
        try:
            status, payload = self._transport(method, url, headers, body)
        except urllib.error.URLError as error:
            # DNS failures, TLS failures and timeouts arrive as URLError, which
            # carries no status and is not what `main` catches. Unconverted it
            # prints a traceback whose last line never names Apple or the call.
            raise AscError(
                f"{method} {url} did not complete: {error.reason}"
            ) from error
        if not 200 <= status < 300:
            # The URL and Apple's detail, never the headers: the bearer is in
            # there and an exception message reaches stdout and progress files.
            raise AscError(f"{method} {url} -> HTTP {status}: {_safe_detail(payload)}")
        try:
            decoded = json.loads(payload)
        except ValueError as error:
            raise AscError(
                f"{method} {url} -> HTTP {status}, body is not JSON: "
                f"{_safe_detail(payload)}"
            ) from error
        if not isinstance(decoded, dict):
            raise AscError(f"{method} {url} did not return an object")
        return decoded


def register_bundle_id(client: AppStoreConnect, *, identifier: str, name: str) -> str:
    """Registers the App ID, or finds the one that is already there.

    Idempotent on purpose: this command exists to unblock a human step, and
    a human who has already done half of it should not be met with a 409
    that reads like a real problem.
    """
    existing = client.get("/v1/bundleIds", **{"filter[identifier]": identifier})
    for record in existing.get("data", []):
        if record.get("attributes", {}).get("identifier") == identifier:
            return str(record["id"])

    created = client.post(
        "/v1/bundleIds",
        {
            "data": {
                "type": "bundleIds",
                "attributes": {
                    "identifier": identifier,
                    "name": name,
                    "platform": "IOS",
                },
            }
        },
    )
    return str(created["data"]["id"])


def _app_id(client: AppStoreConnect, bundle_id: str) -> str:
    found = client.get("/v1/apps", **{"filter[bundleId]": bundle_id})
    for record in found.get("data", []):
        if record.get("attributes", {}).get("bundleId") == bundle_id:
            return str(record["id"])
    raise AscError(
        f"no app record for {bundle_id}. The API cannot create one -- Apple's "
        "own documentation says to create new apps on the App Store Connect "
        "website -- so this is the owner's one manual step."
    )


def create_beta_group(
    client: AppStoreConnect, *, bundle_id: str, group_name: str
) -> str:
    """Creates the internal TestFlight group, or finds the one already there.

    Whether the API will accept `isInternalGroup` on a create is the one
    thing here nobody has been able to confirm against the live service. If
    it refuses, the error carries Apple's own wording: make the group in the
    web UI (TestFlight -> Internal Testing -> +) and re-run this command,
    which will then find it and confirm.
    """
    app_id = _app_id(client, bundle_id)

    existing = client.get("/v1/betaGroups", **{"filter[app]": app_id})
    for record in existing.get("data", []):
        if record.get("attributes", {}).get("name") == group_name:
            return str(record["id"])

    created = client.post(
        "/v1/betaGroups",
        {
            "data": {
                "type": "betaGroups",
                "attributes": {
                    "name": group_name,
                    "isInternalGroup": True,
                    # Internal testers should get every build without anyone
                    # assigning them one by one; that is the whole point of
                    # an automated pipeline.
                    "hasAccessToAllBuilds": True,
                },
                "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
            }
        },
    )
    return str(created["data"]["id"])


def list_builds(client: AppStoreConnect, *, bundle_id: str) -> list[tuple[str, str]]:
    """`(build number, processing state)` for the app, newest first.

    This is what "the build is visible in App Store Connect" means as a
    check something can run, rather than as something a person looks at.
    """
    app_id = _app_id(client, bundle_id)
    found = client.get(
        "/v1/builds", **{"filter[app]": app_id, "sort": "-version", "limit": "10"}
    )
    return [
        (
            str(record.get("attributes", {}).get("version")),
            str(record.get("attributes", {}).get("processingState")),
        )
        for record in found.get("data", [])
    ]


def _client_from_args(args: argparse.Namespace) -> AppStoreConnect:
    key_path = Path(args.key_path)
    if not key_path.is_file():
        raise AscError(f"no API key at {key_path}")
    return AppStoreConnect(
        key_id=args.key_id,
        issuer_id=args.issuer_id,
        token=lambda: sign_token(args.key_id, args.issuer_id, key_path),
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--key-id", default="Q8Y9M5TLY8")
    parser.add_argument("--issuer-id", default="92422d0e-885b-467d-b9f2-3f604eb503ba")
    parser.add_argument(
        "--key-path",
        default="~/.appstoreconnect/private_keys/AuthKey_Q8Y9M5TLY8.p8",
        help="Path to the .p8. Read once, by pyjwt. Never printed.",
    )
    commands = parser.add_subparsers(dest="command", required=True)

    register = commands.add_parser("register-bundle-id")
    register.add_argument("--identifier", default="com.paycross.flutterdemo")
    register.add_argument("--name", default="PayCross Demo")

    group = commands.add_parser("create-beta-group")
    group.add_argument("--bundle-id", default="com.paycross.flutterdemo")
    group.add_argument("--name", default="PayCross Demo — Internal")

    builds = commands.add_parser("list-builds")
    builds.add_argument("--bundle-id", default="com.paycross.flutterdemo")

    args = parser.parse_args(argv)
    args.key_path = str(Path(args.key_path).expanduser())

    try:
        client = _client_from_args(args)
        if args.command == "register-bundle-id":
            bundle_id = register_bundle_id(
                client, identifier=args.identifier, name=args.name
            )
            print(f"bundle id {args.identifier} is {bundle_id}")
        elif args.command == "create-beta-group":
            group_id = create_beta_group(
                client, bundle_id=args.bundle_id, group_name=args.name
            )
            print(f"beta group {args.name!r} is {group_id}")
        elif args.command == "list-builds":
            for version, state in list_builds(client, bundle_id=args.bundle_id):
                print(f"build {version}: {state}")
    except AscError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
