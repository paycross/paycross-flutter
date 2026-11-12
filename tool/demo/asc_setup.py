"""App Store Connect setup for PayCross Demo."""

from __future__ import annotations

import argparse
import base64
import datetime
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable, Optional

API = "https://api.appstoreconnect.apple.com"

#: Apple rejects tokens that claim more than 20 minutes of life.
TOKEN_LIFETIME_SECONDS = 1200

REQUEST_TIMEOUT_SECONDS = 60

#: Also pinned in `example/ios/Flutter/Release.xcconfig` and `release-ios.sh`;
#: change them together.
PROFILE_NAME = "PayCross Demo App Store"

#: App Store Connect's opaque id for the bundle, not its reverse-DNS identifier.
BUNDLE_ID_ASC_ID = "TZND5PLR24"

# The release Mac runs Python 3.9, which rejects `bytes | None` in a runtime alias.
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
    """ES256-signs a request token with the team key at `key_path`."""
    # pyjwt is imported here so the unit tests run without a crypto stack.
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
        # Apple puts the reason in the body, so return the status instead of raising.
        return error.code, error.read()


def _safe_detail(payload: bytes) -> str:
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
    """Authenticated calls to the App Store Connect API."""

    def __init__(
        self,
        *,
        key_id: str,
        issuer_id: str,
        token: Callable[[], str],
        transport: Transport | None = None,
    ):
        self._key_id = key_id
        # The issuer stays inside the token callable and is not stored on the client.
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

    def delete(self, path: str) -> None:
        """Deletes a resource. Apple answers 204 with no body."""
        self._call("DELETE", f"{API}{path}", None)

    def _call(self, method: str, url: str, body: bytes | None) -> dict[str, Any] | None:
        headers = {
            "Authorization": f"Bearer {self._token()}",
            "Content-Type": "application/json",
        }
        try:
            status, payload = self._transport(method, url, headers, body)
        except urllib.error.URLError as error:
            # URLError carries no status and is not caught by main, so it is
            # converted here.
            raise AscError(
                f"{method} {url} did not complete: {error.reason}"
            ) from error
        if not 200 <= status < 300:
            # The headers are never quoted: the bearer token is in them.
            raise AscError(f"{method} {url} -> HTTP {status}: {_safe_detail(payload)}")
        if not payload:
            if method == "DELETE":
                return None
            raise AscError(f"{method} {url} -> HTTP {status} with an empty body")
        try:
            decoded = json.loads(payload)
        except ValueError as error:
            raise AscError(
                f"{method} {url} -> HTTP {status}, body is not JSON: "
                f"{_safe_detail(payload)}"
            ) from error
        if not isinstance(decoded, dict):
            raise AscError(f"{method} {url} -> HTTP {status}, body is not an object")
        return decoded


def register_bundle_id(client: AppStoreConnect, *, identifier: str, name: str) -> str:
    """Registers the App ID, or reuses the one already registered."""
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


#: Teams may hold either type, so filtering on one misses the other.
DISTRIBUTION_CERTIFICATE_TYPES = ("IOS_DISTRIBUTION", "DISTRIBUTION")


#: Apple's maximum page size; lookups read one page and never follow links.next.
PAGE_LIMIT = "200"


def _profile_record(client: AppStoreConnect, *, name: str) -> dict[str, Any] | None:
    # Two records with one name are refused, so the delete never picks one.
    found = client.get("/v1/profiles", **{"filter[name]": name, "limit": PAGE_LIMIT})
    records = [
        record
        for record in found.get("data", [])
        if record.get("attributes", {}).get("name") == name
    ]
    if len(records) > 1:
        raise AscError(
            f"{len(records)} profiles are named {name!r} "
            f"({', '.join(str(record['id']) for record in records)}). Refusing "
            "to guess which one to delete; remove the extras in the Apple "
            "portal first."
        )
    return records[0] if records else None


def find_profile(client: AppStoreConnect, *, name: str) -> str | None:
    """The profile with this exact name, or None."""
    # The name filter must stay exact, so delete-then-create cannot reach
    # another profile.
    record = _profile_record(client, name=name)
    return str(record["id"]) if record is not None else None


def _expired(record: dict[str, Any], now: datetime.datetime) -> bool:
    # Unparseable dates count as unexpired, so a date-format change cannot hide
    # the certificate.
    raw = record.get("attributes", {}).get("expirationDate")
    if not raw:
        return False
    try:
        expires = datetime.datetime.fromisoformat(str(raw))
    except ValueError:
        return False
    if expires.tzinfo is None:
        expires = expires.replace(tzinfo=datetime.timezone.utc)
    return expires <= now


def distribution_certificate_id(client: AppStoreConnect) -> str:
    """Returns the id of the one unexpired App Store distribution certificate."""
    # Two live certificates are refused: a profile issued to the outgoing one
    # expires with it.
    found = client.get(
        "/v1/certificates",
        **{
            "filter[certificateType]": ",".join(DISTRIBUTION_CERTIFICATE_TYPES),
            "limit": PAGE_LIMIT,
        },
    )
    matching = [
        record
        for record in found.get("data", [])
        if record.get("attributes", {}).get("certificateType")
        in DISTRIBUTION_CERTIFICATE_TYPES
    ]
    now = datetime.datetime.now(datetime.timezone.utc)
    live = [record for record in matching if not _expired(record, now)]
    if len(live) > 1:
        raise AscError(
            f"{len(live)} unexpired distribution certificates on this team "
            f"({', '.join(str(record['id']) for record in live)}). Refusing to "
            "guess which one the profile should be issued to; retire the one "
            "being replaced, or issue the profile by hand."
        )
    if not live:
        expired_note = f" {len(matching)} matched but had expired." if matching else ""
        raise AscError(
            "no distribution certificate on this team. Looked for a certificate of "
            f"type {' or '.join(DISTRIBUTION_CERTIFICATE_TYPES)}; an App Store "
            f"profile cannot be created without one.{expired_note}"
        )
    return str(live[0]["id"])


def create_profile(
    client: AppStoreConnect,
    *,
    name: str,
    bundle_id_asc_id: str,
    certificate_id: str,
) -> dict[str, str]:
    """Creates an IOS_APP_STORE profile and returns its id, uuid and content."""
    created = client.post(
        "/v1/profiles",
        {
            "data": {
                "type": "profiles",
                "attributes": {"name": name, "profileType": "IOS_APP_STORE"},
                "relationships": {
                    "bundleId": {"data": {"type": "bundleIds", "id": bundle_id_asc_id}},
                    "certificates": {
                        "data": [{"type": "certificates", "id": certificate_id}]
                    },
                },
            }
        },
    )
    record = created["data"]
    attributes = record.get("attributes", {})
    profile_id = record.get("id")
    missing = [
        field
        for field, value in (
            ("id", profile_id),
            ("uuid", attributes.get("uuid")),
            ("profileContent", attributes.get("profileContent")),
        )
        if not value
    ]
    if missing:
        # str(None) is the string "None", which base64 decodes without error.
        # The profile already exists here; re-running the command would delete it first.
        created_as = (
            f"profile {profile_id} was created"
            if profile_id
            else "a profile was created"
        )
        raise AscError(
            f"{created_as}, but Apple's response carries no "
            f"{', no '.join(missing)}. Read the profile from the Apple "
            "portal rather than re-running this command."
        )
    return {
        "id": str(profile_id),
        "uuid": str(attributes["uuid"]),
        "content": str(attributes["profileContent"]),
    }


def recreate_profile(
    client: AppStoreConnect, *, name: str, bundle_id_asc_id: str
) -> dict[str, str]:
    """Deletes the profile with this name if there is one, then creates it."""
    # Apple refuses a duplicate name, so the old profile must go before the new
    # one is created.
    # The certificate is resolved before the delete, so a missing one leaves the
    # old profile in place.
    existing = find_profile(client, name=name)
    certificate_id = distribution_certificate_id(client)
    if existing is not None:
        client.delete(f"/v1/profiles/{existing}")
    return create_profile(
        client,
        name=name,
        bundle_id_asc_id=bundle_id_asc_id,
        certificate_id=certificate_id,
    )


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
    """Creates the internal TestFlight group, or finds the one already there."""
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
                    "hasAccessToAllBuilds": True,
                },
                "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
            }
        },
    )
    return str(created["data"]["id"])


def list_builds(client: AppStoreConnect, *, bundle_id: str) -> list[tuple[str, str]]:
    """`(build number, processing state)` for the app, newest first."""
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


def _writable_destination(path: str) -> Path:
    # Fails before any Apple call, because recreate-profile deletes before it creates.
    # A missing directory is refused rather than created, so a mistyped path fails.
    destination = Path(path).expanduser()
    if not destination.parent.is_dir():
        raise AscError(
            f"no directory at {destination.parent} to write the profile into. "
            "Nothing has been changed in App Store Connect."
        )
    return destination


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

    find = commands.add_parser("find-profile")
    find.add_argument("--name", default=PROFILE_NAME)

    recreate = commands.add_parser("recreate-profile")
    recreate.add_argument("--name", default=PROFILE_NAME)
    recreate.add_argument("--bundle-id-asc-id", default=BUNDLE_ID_ASC_ID)
    recreate.add_argument(
        "--dry-run",
        action="store_true",
        help=(
            "Report the profile that would be deleted and the certificate the "
            "replacement would be issued to, then stop without changing anything."
        ),
    )
    recreate.add_argument(
        "--out",
        required=True,
        help=(
            "Where to write the new profile. Required because the signed "
            "profile comes back once and is never printed."
        ),
    )

    args = parser.parse_args(argv)
    args.key_path = str(Path(args.key_path).expanduser())

    try:
        # Runs before the client is built, so an unwritable path cannot cost a profile.
        destination = (
            _writable_destination(args.out)
            if args.command == "recreate-profile"
            else None
        )
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
        elif args.command == "find-profile":
            record = _profile_record(client, name=args.name)
            if record is None:
                print(f"no profile named {args.name!r}")
            else:
                attributes = record.get("attributes", {})
                print(
                    f"profile {args.name!r} is {record['id']}, "
                    f"uuid {attributes.get('uuid')}, "
                    f"state {attributes.get('profileState')}, "
                    f"expires {attributes.get('expirationDate')}"
                )
        elif args.command == "recreate-profile" and args.dry_run:
            record = _profile_record(client, name=args.name)
            certificate_id = distribution_certificate_id(client)
            if record is None:
                print(f"no profile named {args.name!r} to delete")
            else:
                print(f"would delete profile {record['id']} named {args.name!r}")
            print(f"would issue the replacement to certificate {certificate_id}")
            print(f"would write it to {destination}")
            print("--dry-run: nothing in App Store Connect has been changed.")
        elif args.command == "recreate-profile":
            profile = recreate_profile(
                client, name=args.name, bundle_id_asc_id=args.bundle_id_asc_id
            )
            # Print the id and uuid only: the content is the signed profile and goes
            # to the file.
            try:
                destination.write_bytes(base64.b64decode(profile["content"]))
            except OSError as error:
                # The profile exists by now, so the error must say so rather than
                # invite a re-run.
                raise AscError(
                    f"profile {profile['id']} was created but could not be "
                    f"written to {destination}: {error}. It exists in App "
                    "Store Connect; download it there rather than re-running "
                    "this command."
                ) from error
            print(f"profile {args.name!r} is now {profile['id']}")
            print(f"uuid {profile['uuid']}")
            print(f"written to {destination}")
    except AscError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
