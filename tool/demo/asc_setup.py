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

#: Apple refuses a token that claims more than 20 minutes of life.
TOKEN_LIFETIME_SECONDS = 1200

REQUEST_TIMEOUT_SECONDS = 60

#: The name the release pipeline pins, in `example/ios/Flutter/Release.xcconfig`
#: and again in `tool/demo/release-ios.sh`. A recreated profile has to carry it
#: exactly, because neither of those two files is generated from this one.
PROFILE_NAME = "PayCross Demo App Store"

#: App Store Connect's own opaque id for the `com.paycross.flutterdemo` bundle
#: id, which is what the profile create relationship wants rather than the
#: reverse-DNS identifier a human would reach for.
BUNDLE_ID_ASC_ID = "TZND5PLR24"

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
    """The four verbs this script needs, and no more."""

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
        if not payload:
            if method == "DELETE":
                # A successful DELETE is a 204 with nothing in it. The parse
                # below raises on an empty body and the shape check after it
                # rejects everything that is not an object, so both have to be
                # skipped together: returning early after parsing would still
                # raise.
                return None
            # Every other verb's callers read `data` straight off the result.
            # Handing them None turns a truncated or proxied response into an
            # AttributeError whose last line names neither Apple nor the call,
            # which is the failure the URLError branch above exists to prevent.
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


#: The certificate types an App Store profile may be issued to. Apple issued the
#: older "iOS Distribution" certificates as `IOS_DISTRIBUTION` and the current
#: "Apple Distribution" ones as `DISTRIBUTION`; a team can hold either, and
#: filtering on only one silently finds nothing on a team that holds the other.
DISTRIBUTION_CERTIFICATE_TYPES = ("IOS_DISTRIBUTION", "DISTRIBUTION")


#: Apple's maximum page size. Both lookups below ask for it rather than taking
#: the default page and never following `links.next`: "on page two" would read
#: here as "no such profile", or as "the only certificate you have".
PAGE_LIMIT = "200"


def _profile_record(client: AppStoreConnect, *, name: str) -> dict[str, Any] | None:
    """The raw `profiles` record with this exact name, or None.

    Separate from `find_profile` only so the `find-profile` command can print
    the uuid and the state alongside the id without a second round trip.

    Two records carrying the one name are refused rather than resolved. What
    this returns is what gets deleted, and Apple's list order is not a reason
    to prefer one profile over another.
    """
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
    """The profile with this exact name, or None.

    Apple's filter is exact rather than a prefix, which is what makes
    delete-then-create safe: a near-miss name is a different profile and this
    returns None rather than deleting somebody else's.
    """
    record = _profile_record(client, name=name)
    return str(record["id"]) if record is not None else None


def _expired(record: dict[str, Any], now: datetime.datetime) -> bool:
    """Whether this certificate's expiry has already passed.

    A record with no `expirationDate`, or with one `fromisoformat` cannot
    read, counts as unexpired. This function only ever drops candidates, and
    dropping one it cannot prove is expired would turn a date-format change
    into "no distribution certificate on this team".
    """
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
    """The App Store distribution certificate a profile has to be issued to.

    An App Store profile needs a certificate and needs no devices, which is
    why this team can ship with no registered device at all.

    Expired certificates are skipped, and two live ones are refused rather
    than resolved. Renewing is precisely the moment a team holds two, and a
    profile issued to the outgoing certificate looks ACTIVE the day it is
    made and stops working the day that certificate expires.
    """
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
        # Stringifying a missing field would hide it rather than report it:
        # `str(None)` is "None", and `base64.b64decode("None")` succeeds
        # because it is valid base64, so the profile written out would be
        # three bytes of nonsense that only fails at signing time.
        #
        # The profile exists in App Store Connect by this point, so the error
        # names it. Re-running this command would begin by deleting it.
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
    """Deletes the profile with this name if there is one, then creates it.

    Delete then create, not regenerate: Apple refuses a duplicate name, and
    the release pipeline pins this profile by name in two places
    (`example/ios/Flutter/Release.xcconfig` and `tool/demo/release-ios.sh`),
    so the replacement has to carry the same one.

    The certificate is looked up before the delete rather than after it. Both
    orders satisfy Apple, but only this one leaves the existing profile in
    place when the team turns out to have no distribution certificate.
    """
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


def _writable_destination(path: str) -> Path:
    """The `--out` path, resolved and checked before any Apple call.

    `recreate-profile` deletes before it creates, so an unwritable path has to
    fail here rather than at the write. By then the old profile is gone, the
    new one exists only in a response that is deliberately never printed, and
    the operator's only way back is the portal.

    A missing directory is refused rather than created: the realistic cause is
    a mistyped path, and silently making `/Usrs/mikz` helps nobody.
    """
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
        # Before the client, and so before the delete this command opens with:
        # a destination that cannot be written must not cost a profile.
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
            # The same two lookups `recreate_profile` opens with, in its own
            # order, and then nothing. Both of them refuse an ambiguous answer,
            # so this reports the choice and proves there is one to make.
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
            # The id and the uuid name the profile and are safe to print. The
            # content is the signed profile itself and goes to the file only.
            try:
                destination.write_bytes(base64.b64decode(profile["content"]))
            except OSError as error:
                # The checks above make this unlikely rather than impossible --
                # a full disk, a revoked permission. Say the profile exists, or
                # the operator re-runs a command that starts with a delete.
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
