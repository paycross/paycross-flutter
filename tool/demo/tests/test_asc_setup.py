import json
import urllib.error

import pytest

from tool.demo import asc_setup


class FakeTransport:
    """Records every call and answers from a scripted list."""

    def __init__(self, *responses):
        self.responses = list(responses)
        self.calls = []

    def __call__(self, method, url, headers, body):
        self.calls.append((method, url, headers, body))
        if not self.responses:
            raise AssertionError(f"unscripted call: {method} {url}")
        return self.responses.pop(0)


def ok(payload):
    return 200, json.dumps(payload).encode()


def created(payload):
    return 201, json.dumps(payload).encode()


def client(transport):
    return asc_setup.AppStoreConnect(
        key_id="Q8Y9M5TLY8",
        issuer_id="92422d0e-885b-467d-b9f2-3f604eb503ba",
        # Injected so no test needs a private key or the pyjwt dependency.
        token=lambda: "a.fake.jwt",
        transport=transport,
    )


def test_the_token_claims_are_what_apple_requires():
    claims = asc_setup.token_claims("issuer-1", now=1_000_000)

    assert claims["iss"] == "issuer-1"
    assert claims["aud"] == "appstoreconnect-v1"
    assert claims["iat"] == 1_000_000
    # Apple refuses anything longer than 20 minutes.
    assert 0 < claims["exp"] - claims["iat"] <= 1200


def test_the_token_header_names_the_key_and_the_algorithm():
    assert asc_setup.token_headers("Q8Y9M5TLY8") == {
        "alg": "ES256",
        "kid": "Q8Y9M5TLY8",
        "typ": "JWT",
    }


def test_every_request_carries_the_bearer_and_asks_for_json():
    transport = FakeTransport(ok({"data": []}))

    client(transport).get("/v1/bundleIds")

    method, url, headers, body = transport.calls[0]
    assert method == "GET"
    assert url == "https://api.appstoreconnect.apple.com/v1/bundleIds"
    assert headers["Authorization"] == "Bearer a.fake.jwt"
    assert headers["Content-Type"] == "application/json"
    assert body is None


def test_registering_a_new_bundle_id_posts_the_documented_shape():
    transport = FakeTransport(
        ok({"data": []}),
        created({"data": {"id": "BID1", "attributes": {"identifier": "com.x"}}}),
    )

    result = asc_setup.register_bundle_id(
        client(transport), identifier="com.paycross.flutterdemo", name="PayCross Demo"
    )

    assert result == "BID1"
    method, url, _, body = transport.calls[1]
    assert method == "POST"
    assert url.endswith("/v1/bundleIds")
    assert json.loads(body) == {
        "data": {
            "type": "bundleIds",
            "attributes": {
                "identifier": "com.paycross.flutterdemo",
                "name": "PayCross Demo",
                "platform": "IOS",
            },
        }
    }


def test_registering_one_that_exists_is_a_no_op_that_returns_its_id():
    # Re-running the command must not fail: the owner may already have made
    # the record, and a second POST answers 409 with a message that reads
    # like a real problem.
    transport = FakeTransport(
        ok(
            {
                "data": [
                    {
                        "id": "BID1",
                        "attributes": {"identifier": "com.paycross.flutterdemo"},
                    }
                ]
            }
        )
    )

    result = asc_setup.register_bundle_id(
        client(transport), identifier="com.paycross.flutterdemo", name="PayCross Demo"
    )

    assert result == "BID1"
    assert len(transport.calls) == 1


def test_an_api_error_names_the_status_and_apple_s_own_detail():
    transport = FakeTransport(
        (409, json.dumps({"errors": [{"detail": "identifier is taken"}]}).encode())
    )

    with pytest.raises(asc_setup.AscError, match=r"409.*identifier is taken"):
        client(transport).get("/v1/bundleIds")


def test_an_error_never_echoes_the_authorization_header():
    transport = FakeTransport((500, b"upstream exploded"))

    with pytest.raises(asc_setup.AscError) as raised:
        client(transport).get("/v1/bundleIds")

    assert "a.fake.jwt" not in str(raised.value)
    assert "Bearer" not in str(raised.value)


def test_a_non_json_body_is_reported_as_such_not_as_a_parse_error():
    transport = FakeTransport((200, b"<html>gateway</html>"))

    with pytest.raises(asc_setup.AscError, match="not JSON"):
        client(transport).get("/v1/bundleIds")


def test_a_transport_level_failure_becomes_an_asc_error_not_a_traceback():
    # DNS, TLS and timeouts arrive as URLError, which is not an HTTPError and
    # carries no status. Left alone it escapes main's `except AscError` and
    # prints a traceback whose last line says nothing about App Store Connect.
    def exploding(method, url, headers, body):
        raise urllib.error.URLError("nodename nor servname provided")

    with pytest.raises(asc_setup.AscError, match="nodename nor servname"):
        client(exploding).get("/v1/bundleIds")


def test_creating_the_group_finds_the_app_by_its_bundle_id_first():
    transport = FakeTransport(
        ok(
            {
                "data": [
                    {
                        "id": "APP1",
                        "attributes": {"bundleId": "com.paycross.flutterdemo"},
                    }
                ]
            }
        ),
        ok({"data": []}),
        created(
            {"data": {"id": "BG1", "attributes": {"name": "PayCross Demo — Internal"}}}
        ),
    )

    result = asc_setup.create_beta_group(
        client(transport),
        bundle_id="com.paycross.flutterdemo",
        group_name="PayCross Demo — Internal",
    )

    assert result == "BG1"
    assert "/v1/apps" in transport.calls[0][1]
    _, url, _, body = transport.calls[2]
    assert url.endswith("/v1/betaGroups")
    payload = json.loads(body)
    assert payload["data"]["type"] == "betaGroups"
    assert payload["data"]["attributes"]["name"] == "PayCross Demo — Internal"
    assert payload["data"]["attributes"]["isInternalGroup"] is True
    assert payload["data"]["relationships"]["app"]["data"] == {
        "type": "apps",
        "id": "APP1",
    }


def test_an_existing_group_is_reported_not_recreated():
    transport = FakeTransport(
        ok(
            {
                "data": [
                    {
                        "id": "APP1",
                        "attributes": {"bundleId": "com.paycross.flutterdemo"},
                    }
                ]
            }
        ),
        ok(
            {
                "data": [
                    {"id": "BG1", "attributes": {"name": "PayCross Demo — Internal"}}
                ]
            }
        ),
    )

    result = asc_setup.create_beta_group(
        client(transport),
        bundle_id="com.paycross.flutterdemo",
        group_name="PayCross Demo — Internal",
    )

    assert result == "BG1"
    assert len(transport.calls) == 2


def test_a_missing_app_record_says_which_manual_step_is_outstanding():
    transport = FakeTransport(ok({"data": []}))

    with pytest.raises(asc_setup.AscError, match="App Store Connect website"):
        asc_setup.create_beta_group(
            client(transport),
            bundle_id="com.paycross.flutterdemo",
            group_name="PayCross Demo — Internal",
        )


def test_a_refused_create_points_at_the_web_ui_fallback():
    transport = FakeTransport(
        ok(
            {
                "data": [
                    {
                        "id": "APP1",
                        "attributes": {"bundleId": "com.paycross.flutterdemo"},
                    }
                ]
            }
        ),
        ok({"data": []}),
        (409, json.dumps({"errors": [{"detail": "attribute not permitted"}]}).encode()),
    )

    with pytest.raises(asc_setup.AscError, match="attribute not permitted"):
        asc_setup.create_beta_group(
            client(transport),
            bundle_id="com.paycross.flutterdemo",
            group_name="PayCross Demo — Internal",
        )


def test_builds_are_listed_newest_first_for_the_release_smoke():
    transport = FakeTransport(
        ok(
            {
                "data": [
                    {
                        "id": "APP1",
                        "attributes": {"bundleId": "com.paycross.flutterdemo"},
                    }
                ]
            }
        ),
        ok(
            {
                "data": [
                    {
                        "id": "B2",
                        "attributes": {"version": "2", "processingState": "VALID"},
                    }
                ]
            }
        ),
    )

    builds = asc_setup.list_builds(
        client(transport), bundle_id="com.paycross.flutterdemo"
    )

    assert builds == [("2", "VALID")]
    assert "sort=-version" in transport.calls[1][1]
