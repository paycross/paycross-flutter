import base64
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


def no_content():
    """Apple's answer to a successful DELETE: 204, and nothing to parse."""
    return 204, b""


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


def paths(transport):
    """`(method, path)` for every recorded call, query string dropped."""
    return [
        (method, url[len(asc_setup.API) :].split("?")[0])
        for method, url, _, _ in transport.calls
    ]


def _main_with(transport, argv):
    """Runs `main` against a fake transport, so no key and no network.

    `_client_from_args` is the seam: it is the only place `main` builds a
    client, and replacing it keeps the rest of the command path -- argument
    parsing, dispatch, printing, the write -- exactly as it ships.
    """
    original = asc_setup._client_from_args
    asc_setup._client_from_args = lambda args: client(transport)
    try:
        return asc_setup.main(argv)
    finally:
        asc_setup._client_from_args = original


def test_deleting_a_profile_issues_a_delete_to_that_profile_s_url():
    # The method is the assertion. A fake that answers 204 to anything would
    # pass just as happily for a GET, which deletes nothing.
    transport = FakeTransport(no_content())

    client(transport).delete("/v1/profiles/PGM4YHQ9L9")

    method, url, _, body = transport.calls[0]
    assert method == "DELETE"
    assert url == "https://api.appstoreconnect.apple.com/v1/profiles/PGM4YHQ9L9"
    assert body is None


def test_a_delete_accepts_the_empty_204_apple_actually_answers():
    # `_call` parses the body on the way out and rejects anything that is not
    # a JSON object. A successful delete is both: no body, and not an object.
    #
    # The absence of a raise is the whole assertion. `delete` is annotated
    # `-> None` and discards what `_call` hands back, so an `is None` check
    # here would hold whatever the transport answered and prove nothing.
    transport = FakeTransport(no_content())

    client(transport).delete("/v1/profiles/PGM4YHQ9L9")


def test_a_refused_delete_carries_apple_s_own_detail_truncated():
    detail = "profile is referenced by a build " + "x" * 500
    transport = FakeTransport(
        (409, json.dumps({"errors": [{"detail": detail}]}).encode())
    )

    with pytest.raises(asc_setup.AscError) as raised:
        client(transport).delete("/v1/profiles/PGM4YHQ9L9")

    message = str(raised.value)
    assert "409" in message
    assert "profile is referenced by a build" in message
    # `_safe_detail` caps Apple's text at 400 characters, so the whole 533
    # never reaches stdout or a progress file.
    assert detail not in message


def test_finding_a_profile_filters_on_the_exact_name_and_returns_its_id():
    transport = FakeTransport(
        ok(
            {
                "data": [
                    {
                        "id": "PGM4YHQ9L9",
                        "attributes": {"name": "PayCross Demo App Store"},
                    }
                ]
            }
        )
    )

    found = asc_setup.find_profile(client(transport), name="PayCross Demo App Store")

    assert found == "PGM4YHQ9L9"
    method, url, _, _ = transport.calls[0]
    assert method == "GET"
    assert "filter%5Bname%5D=PayCross+Demo+App+Store" in url


def test_finding_no_profile_answers_none_rather_than_raising():
    # "There is nothing to delete" is the normal state of a re-run, not an
    # error, so `recreate_profile` can ask without guarding the call.
    transport = FakeTransport(ok({"data": []}))

    assert (
        asc_setup.find_profile(client(transport), name="PayCross Demo App Store")
        is None
    )


def test_creating_a_profile_posts_the_app_store_document():
    transport = FakeTransport(
        created(
            {
                "data": {
                    "id": "NEW1",
                    "attributes": {"uuid": "UUID-1", "profileContent": "YmFzZTY0"},
                }
            }
        )
    )

    result = asc_setup.create_profile(
        client(transport),
        name="PayCross Demo App Store",
        bundle_id_asc_id="TZND5PLR24",
        certificate_id="Z59HWB27F8",
    )

    assert result == {"id": "NEW1", "uuid": "UUID-1", "content": "YmFzZTY0"}
    method, url, _, body = transport.calls[0]
    assert method == "POST"
    assert url.endswith("/v1/profiles")
    document = json.loads(body)["data"]
    assert document["type"] == "profiles"
    assert document["attributes"]["name"] == "PayCross Demo App Store"
    assert document["attributes"]["profileType"] == "IOS_APP_STORE"
    assert document["relationships"]["bundleId"]["data"] == {
        "type": "bundleIds",
        "id": "TZND5PLR24",
    }
    assert document["relationships"]["certificates"]["data"] == [
        {"type": "certificates", "id": "Z59HWB27F8"}
    ]


def test_recreating_deletes_before_it_creates():
    # The order is the whole point: Apple refuses a duplicate name, so a
    # create that runs first fails and leaves the invalid profile in place.
    # Counting the calls would not catch that.
    transport = FakeTransport(
        ok(
            {
                "data": [
                    {
                        "id": "PGM4YHQ9L9",
                        "attributes": {"name": "PayCross Demo App Store"},
                    }
                ]
            }
        ),
        ok(
            {
                "data": [
                    {
                        "id": "Z59HWB27F8",
                        "attributes": {"certificateType": "IOS_DISTRIBUTION"},
                    }
                ]
            }
        ),
        no_content(),
        created(
            {
                "data": {
                    "id": "NEW1",
                    "attributes": {"uuid": "UUID-1", "profileContent": "YmFzZTY0"},
                }
            }
        ),
    )

    result = asc_setup.recreate_profile(
        client(transport),
        name="PayCross Demo App Store",
        bundle_id_asc_id="TZND5PLR24",
    )

    assert result["id"] == "NEW1"
    assert paths(transport) == [
        ("GET", "/v1/profiles"),
        ("GET", "/v1/certificates"),
        ("DELETE", "/v1/profiles/PGM4YHQ9L9"),
        ("POST", "/v1/profiles"),
    ]


def test_recreating_with_nothing_there_just_creates():
    transport = FakeTransport(
        ok({"data": []}),
        ok(
            {
                "data": [
                    {
                        "id": "Z59HWB27F8",
                        "attributes": {"certificateType": "IOS_DISTRIBUTION"},
                    }
                ]
            }
        ),
        created(
            {
                "data": {
                    "id": "NEW1",
                    "attributes": {"uuid": "UUID-1", "profileContent": "YmFzZTY0"},
                }
            }
        ),
    )

    result = asc_setup.recreate_profile(
        client(transport),
        name="PayCross Demo App Store",
        bundle_id_asc_id="TZND5PLR24",
    )

    assert result["uuid"] == "UUID-1"
    assert paths(transport) == [
        ("GET", "/v1/profiles"),
        ("GET", "/v1/certificates"),
        ("POST", "/v1/profiles"),
    ]


def test_the_distribution_certificate_is_found_or_its_absence_is_named():
    transport = FakeTransport(
        ok(
            {
                "data": [
                    {
                        "id": "Z59HWB27F8",
                        "attributes": {"certificateType": "IOS_DISTRIBUTION"},
                    }
                ]
            }
        )
    )

    assert asc_setup.distribution_certificate_id(client(transport)) == "Z59HWB27F8"

    empty = FakeTransport(ok({"data": []}))
    with pytest.raises(asc_setup.AscError, match="IOS_DISTRIBUTION"):
        asc_setup.distribution_certificate_id(client(empty))


def test_a_create_response_missing_a_field_fails_loudly_naming_the_profile():
    # `str(None)` is the four-character string "None", and `b64decode("None")`
    # succeeds -- it is valid base64 -- so a silently missing field writes
    # three bytes of garbage to the --out path and fails much later.
    for missing, attributes in (
        ("uuid", {"profileContent": "YmFzZTY0"}),
        ("profileContent", {"uuid": "UUID-1"}),
    ):
        transport = FakeTransport(
            created({"data": {"id": "NEW1", **{"attributes": attributes}}})
        )

        with pytest.raises(asc_setup.AscError) as raised:
            asc_setup.create_profile(
                client(transport),
                name="PayCross Demo App Store",
                bundle_id_asc_id="TZND5PLR24",
                certificate_id="Z59HWB27F8",
            )

        message = str(raised.value)
        assert missing in message
        # The profile exists by now, so the error has to name it: re-running
        # this command would start by deleting the one just created.
        assert "NEW1" in message
        assert "None" not in message


def test_a_missing_out_directory_is_refused_before_any_asc_call(tmp_path, capsys):
    # `recreate-profile` deletes before it creates. A path that cannot be
    # written has to fail here, with the client not yet built and nothing sent,
    # rather than after the delete has already happened.
    exit_code = asc_setup.main(
        [
            "recreate-profile",
            "--out",
            str(tmp_path / "absent" / "PayCrossDemoAppStore.mobileprovision"),
        ]
    )

    assert exit_code == 1
    error = capsys.readouterr().err
    assert "no directory at" in error
    assert "Nothing has been changed" in error


def test_a_writable_out_directory_gets_past_the_check(tmp_path, capsys):
    # The twin of the test above: without it, a check that refused every path
    # would pass just as happily. A good directory gets as far as needing the
    # key, which is the next thing that happens and still before any network.
    exit_code = asc_setup.main(
        [
            "--key-path",
            str(tmp_path / "absent.p8"),
            "recreate-profile",
            "--out",
            str(tmp_path / "PayCrossDemoAppStore.mobileprovision"),
        ]
    )

    assert exit_code == 1
    assert "no API key at" in capsys.readouterr().err


def test_an_empty_body_on_a_get_still_raises_rather_than_returning_none():
    # The 204 early return is for `delete` alone. Widened to every verb it
    # silently hands `None` to callers that all read `data` off the result.
    transport = FakeTransport((200, b""))

    with pytest.raises(asc_setup.AscError) as raised:
        client(transport).get("/v1/bundleIds")

    message = str(raised.value)
    assert "GET" in message
    assert "/v1/bundleIds" in message
    assert "200" in message


def test_an_empty_body_reaches_a_caller_as_an_asc_error_not_an_attribute_error():
    # The twin that matters. An `AttributeError: 'NoneType' object has no
    # attribute 'get'` names neither Apple nor the URL, which is the exact
    # failure the URLError handling exists to prevent.
    transport = FakeTransport((200, b""))

    with pytest.raises(asc_setup.AscError):
        asc_setup.register_bundle_id(
            client(transport),
            identifier="com.paycross.flutterdemo",
            name="PayCross Demo",
        )


def test_a_near_miss_profile_name_is_not_a_match():
    # The guard that makes delete-then-create safe. Apple's filter is a
    # filter, not a promise: a record whose name merely starts with ours must
    # not be a candidate for deletion.
    transport = FakeTransport(
        ok(
            {
                "data": [
                    {
                        "id": "OTHER1",
                        "attributes": {"name": "PayCross Demo App Store 2"},
                    }
                ]
            }
        )
    )

    assert (
        asc_setup.find_profile(client(transport), name="PayCross Demo App Store")
        is None
    )


def test_two_profiles_with_the_one_name_are_refused_rather_than_guessed_between():
    transport = FakeTransport(
        ok(
            {
                "data": [
                    {"id": "AAA", "attributes": {"name": "PayCross Demo App Store"}},
                    {"id": "BBB", "attributes": {"name": "PayCross Demo App Store"}},
                ]
            }
        )
    )

    with pytest.raises(asc_setup.AscError) as raised:
        asc_setup.find_profile(client(transport), name="PayCross Demo App Store")

    message = str(raised.value)
    # Both ids, so the operator can go and look at them.
    assert "AAA" in message
    assert "BBB" in message


def test_a_certificate_of_the_wrong_type_is_skipped_even_when_listed_first():
    transport = FakeTransport(
        ok(
            {
                "data": [
                    {"id": "DEV1", "attributes": {"certificateType": "DEVELOPMENT"}},
                    {
                        "id": "Z59HWB27F8",
                        "attributes": {"certificateType": "IOS_DISTRIBUTION"},
                    },
                ]
            }
        )
    )

    assert asc_setup.distribution_certificate_id(client(transport)) == "Z59HWB27F8"
    # A page size, so the one we want cannot be stranded on page two.
    assert "limit=" in transport.calls[0][1]


def test_an_expired_certificate_is_skipped():
    # The rotation hazard: a profile issued against the certificate that is
    # about to expire looks ACTIVE today and breaks releases later.
    transport = FakeTransport(
        ok(
            {
                "data": [
                    {
                        "id": "OLD1",
                        "attributes": {
                            "certificateType": "IOS_DISTRIBUTION",
                            "expirationDate": "2020-01-01T00:00:00.000+00:00",
                        },
                    },
                    {
                        "id": "NEW1",
                        "attributes": {
                            "certificateType": "IOS_DISTRIBUTION",
                            "expirationDate": "2030-01-01T00:00:00.000+00:00",
                        },
                    },
                ]
            }
        )
    )

    assert asc_setup.distribution_certificate_id(client(transport)) == "NEW1"


def test_two_unexpired_certificates_are_refused_rather_than_guessed_between():
    # This is the state a certificate rotation creates, and it is the run
    # where picking the wrong one costs the most.
    transport = FakeTransport(
        ok(
            {
                "data": [
                    {
                        "id": "AAA",
                        "attributes": {
                            "certificateType": "IOS_DISTRIBUTION",
                            "expirationDate": "2030-01-01T00:00:00.000+00:00",
                        },
                    },
                    {
                        "id": "BBB",
                        "attributes": {
                            "certificateType": "DISTRIBUTION",
                            "expirationDate": "2031-01-01T00:00:00.000+00:00",
                        },
                    },
                ]
            }
        )
    )

    with pytest.raises(asc_setup.AscError) as raised:
        asc_setup.distribution_certificate_id(client(transport))

    message = str(raised.value)
    assert "AAA" in message
    assert "BBB" in message


def test_a_dry_run_reports_what_it_would_do_and_deletes_nothing(tmp_path, capsys):
    transport = FakeTransport(
        ok(
            {
                "data": [
                    {
                        "id": "PGM4YHQ9L9",
                        "attributes": {"name": "PayCross Demo App Store"},
                    }
                ]
            }
        ),
        ok(
            {
                "data": [
                    {
                        "id": "Z59HWB27F8",
                        "attributes": {"certificateType": "IOS_DISTRIBUTION"},
                    }
                ]
            }
        ),
    )

    exit_code = _main_with(
        transport,
        [
            "recreate-profile",
            "--dry-run",
            "--out",
            str(tmp_path / "PayCrossDemoAppStore.mobileprovision"),
        ],
    )

    assert exit_code == 0
    out = capsys.readouterr().out
    assert "PGM4YHQ9L9" in out
    assert "Z59HWB27F8" in out
    # Two reads and nothing else: no DELETE, no POST.
    assert [method for method, _ in paths(transport)] == ["GET", "GET"]
    assert not (tmp_path / "PayCrossDemoAppStore.mobileprovision").exists()


def test_the_profile_content_never_reaches_stdout(tmp_path, capsys):
    # The card's own safety requirement, and until now enforced only by a
    # human reading the comment that states it.
    secret = "QSBzaWduZWQgcHJvZmlsZSB0aGF0IG11c3Qgbm90IGJlIHByaW50ZWQ="
    transport = FakeTransport(
        ok({"data": []}),
        ok(
            {
                "data": [
                    {
                        "id": "Z59HWB27F8",
                        "attributes": {"certificateType": "IOS_DISTRIBUTION"},
                    }
                ]
            }
        ),
        created(
            {
                "data": {
                    "id": "NEW1",
                    "attributes": {"uuid": "UUID-1", "profileContent": secret},
                }
            }
        ),
    )
    destination = tmp_path / "PayCrossDemoAppStore.mobileprovision"

    exit_code = _main_with(transport, ["recreate-profile", "--out", str(destination)])

    assert exit_code == 0
    captured = capsys.readouterr()
    assert "NEW1" in captured.out
    assert "UUID-1" in captured.out
    assert secret not in captured.out
    assert secret not in captured.err
    # It went to the file instead, decoded.
    assert destination.read_bytes() == base64.b64decode(secret)
