import base64
import http.client
import json
import urllib.error
import urllib.request

import pytest

from tool.e2e import sandbox

ENV = {
    "CLIENT_PAYX_SANDBOX_ID": "id-123",
    "CLIENT_PAYX_SANDBOX_SECRET": "secret-456",
    "TOKEN_URL": "https://auth.test-pay-cross.com/oauth/token",
    "PAYMENT_API_URL": "https://api.test-pay-cross.com/payment-sessions",
    "PAYCROSS_VERSION": "2026-01-01",
}

TOKEN = "eyJhbGciOiJSUzI1NiJ9.eyJzZXNzaW9uIjoiYWJjIn0.c2lnbmF0dXJl"

MINTED = json.dumps({"id": "01a0-sess", "session_token": TOKEN}).encode()


class FakeTransport:
    """Records every request and replays canned responses in order.

    A canned response is a `(status, body)` pair, a bare body (taken as 200)
    or an exception to raise, so a test can spell out only what it cares about.
    """

    def __init__(self, *responses):
        self.responses = [_canned(response) for response in responses]
        self.calls = []

    def __call__(self, method, url, headers, body):
        self.calls.append((method, url, dict(headers), body))
        outcome = self.responses.pop(0)
        if isinstance(outcome, BaseException):
            raise outcome
        return outcome


def _canned(response):
    if isinstance(response, (BaseException, tuple)):
        return response
    return (200, response)


class FakeClock:
    """A monotonic clock the test moves by hand; sleeping moves it.

    `time` is the wall clock the JWT `exp` claim is measured against. It
    advances with `now`, so a test moves both by assigning `now`.
    """

    #: Arbitrary, and far from zero so an `exp` is a plausible epoch stamp.
    WALL_EPOCH = 1_700_000_000.0

    def __init__(self):
        self.now = 0.0
        self.slept = []

    def monotonic(self):
        return self.now

    def time(self):
        return self.WALL_EPOCH + self.now

    def sleep(self, seconds):
        self.slept.append(seconds)
        self.now += seconds


def jwt_with(payload):
    """A syntactically real JWT carrying `payload`; the signature is a stub."""
    def segment(raw):
        return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()

    header = segment(json.dumps({"alg": "RS256"}).encode())
    body = segment(json.dumps(payload).encode())
    return header + "." + body + ".c2lnbmF0dXJl"


def access_token_response(expires_in=None, token="bearer-789"):
    payload = {"access_token": token}
    if expires_in is not None:
        payload["expires_in"] = expires_in
    return json.dumps(payload).encode()


def client_with(*responses, clock=None):
    clock = clock or FakeClock()
    transport = FakeTransport(*responses)
    return (
        sandbox.Sandbox(
            ENV,
            transport=transport,
            sleep=clock.sleep,
            monotonic=clock.monotonic,
            now=clock.time,
        ),
        transport,
        clock,
    )


def test_reads_an_env_file_without_leaking_it(tmp_path):
    path = tmp_path / ".env.staging"
    path.write_text(
        "# a comment\n"
        "\n"
        "export CLIENT_PAYX_SANDBOX_ID=id-123\n"
        "CLIENT_PAYX_SANDBOX_SECRET='secret-456'\n"
        'TOKEN_URL="https://auth.test-pay-cross.com/oauth/token"\n'
        "PAYMENT_API_URL=https://api.test-pay-cross.com/payment-sessions\n"
        "PAYCROSS_VERSION=2026-01-01\n"
        "UNRELATED=ignored\n",
        encoding="utf-8",
    )

    env = sandbox.read_env_file(path)

    assert env == ENV


def test_an_env_file_path_may_be_a_plain_string(tmp_path):
    path = tmp_path / ".env"
    path.write_text(
        "".join(f"{key}=v\n" for key in sandbox.REQUIRED_KEYS), encoding="utf-8"
    )

    assert sandbox.read_env_file(str(path))["TOKEN_URL"] == "v"


def test_env_file_missing_a_key_is_a_clear_error(tmp_path):
    path = tmp_path / ".env"
    path.write_text("TOKEN_URL=https://x\n", encoding="utf-8")

    with pytest.raises(sandbox.SandboxError) as excinfo:
        sandbox.read_env_file(path)

    assert "CLIENT_PAYX_SANDBOX_ID" in str(excinfo.value)
    # The error must name the key, never the value of anything it did read.
    assert "https://x" not in str(excinfo.value)


def test_mint_posts_the_session_and_returns_id_and_token():
    minted = json.dumps(
        {"id": "01a0-sess", "session_token": TOKEN, "merchant_reference": "ORDER-1"}
    ).encode()
    client, transport, _ = client_with(access_token_response(), minted)

    session = client.mint(amount=1000, currency="EUR", options={})

    assert session["id"] == "01a0-sess"
    assert session["token"] == TOKEN

    auth_call, mint_call = transport.calls
    assert auth_call[0] == "POST" and auth_call[1] == ENV["TOKEN_URL"]
    assert auth_call[3] == b"grant_type=client_credentials"
    assert auth_call[2]["Authorization"].startswith("Basic ")
    assert "Chrome" in auth_call[2]["User-Agent"]

    assert mint_call[1] == ENV["PAYMENT_API_URL"]
    assert mint_call[2]["Authorization"] == "Bearer bearer-789"
    assert mint_call[2]["PayCross-Version"] == "2026-01-01"
    assert mint_call[2]["Idempotency-Key"]
    body = json.loads(mint_call[3])
    assert body["amount"] == 1000
    assert body["currency"] == "EUR"
    assert body["transaction_type"] == "sale"
    assert body["customer"]["email"] == "john.doe@example.com"


def test_mint_sends_the_browser_user_agent_and_a_json_content_type():
    # Cloudflare refuses urllib's own UA, so losing it breaks every live run.
    client, transport, _ = client_with(access_token_response(), MINTED)

    client.mint(amount=1000, currency="EUR", options={})

    headers = transport.calls[1][2]
    assert headers["User-Agent"] == sandbox.USER_AGENT
    assert headers["Content-Type"] == "application/json"


def test_read_sends_exactly_the_three_shared_headers():
    client, transport, _ = client_with(
        access_token_response(), json.dumps({"id": "s"}).encode()
    )

    client.read("s")

    assert transport.calls[1][2] == {
        "User-Agent": sandbox.USER_AGENT,
        "Authorization": "Bearer bearer-789",
        "PayCross-Version": "2026-01-01",
    }
    assert transport.calls[1][3] is None


def test_mint_merges_cell_options_over_the_default_body():
    client, transport, _ = client_with(access_token_response(), MINTED)

    client.mint(
        amount=2500,
        currency="EUR",
        options={"data": {"wallets": {"google_pay": False}}},
    )

    body = json.loads(transport.calls[1][3])
    assert body["data"] == {"wallets": {"google_pay": False}}
    assert body["amount"] == 2500


def test_mint_takes_a_caller_supplied_reference():
    client, transport, _ = client_with(access_token_response(), MINTED)

    client.mint(amount=1000, currency="EUR", options={}, reference="D0-CONTROL-1")

    assert json.loads(transport.calls[1][3])["merchant_reference"] == "D0-CONTROL-1"


def test_two_mints_in_the_same_second_get_different_references():
    # A whole-second timestamp alone collides across a fast matrix run.
    client, transport, _ = client_with(access_token_response(), MINTED, MINTED)

    client.mint(amount=1000, currency="EUR", options={})
    client.mint(amount=1000, currency="EUR", options={})

    references = [json.loads(call[3])["merchant_reference"] for call in transport.calls[1:]]
    assert references[0] != references[1]
    assert all(reference.startswith("ORDER-") for reference in references)


def test_mint_reuses_one_access_token_across_calls():
    client, transport, _ = client_with(access_token_response(), MINTED, MINTED)

    client.mint(amount=1000, currency="EUR", options={})
    client.mint(amount=1000, currency="EUR", options={})

    assert [c[1] for c in transport.calls].count(ENV["TOKEN_URL"]) == 1


def test_the_access_token_is_refreshed_before_it_expires():
    clock = FakeClock()
    client, transport, _ = client_with(
        access_token_response(expires_in=3600),
        MINTED,
        MINTED,
        access_token_response(expires_in=3600),
        MINTED,
        clock=clock,
    )

    client.mint(amount=1000, currency="EUR", options={})
    clock.now = 3600 - sandbox.TOKEN_REFRESH_MARGIN_SECONDS - 1
    client.mint(amount=1000, currency="EUR", options={})
    assert [c[1] for c in transport.calls].count(ENV["TOKEN_URL"]) == 1

    # The API-Gateway cache in front of the token endpoint holds for 3300 s, so
    # refreshing at 3300 is what makes the replacement token actually fresh.
    clock.now = 3600 - sandbox.TOKEN_REFRESH_MARGIN_SECONDS
    client.mint(amount=1000, currency="EUR", options={})
    assert [c[1] for c in transport.calls].count(ENV["TOKEN_URL"]) == 2


def test_a_token_response_without_expires_in_still_caches():
    clock = FakeClock()
    client, transport, _ = client_with(
        access_token_response(), MINTED, MINTED, clock=clock
    )

    client.mint(amount=1000, currency="EUR", options={})
    clock.now = sandbox.DEFAULT_TOKEN_LIFETIME_SECONDS - sandbox.TOKEN_REFRESH_MARGIN_SECONDS - 1
    client.mint(amount=1000, currency="EUR", options={})

    assert [c[1] for c in transport.calls].count(ENV["TOKEN_URL"]) == 1


def test_an_unusable_expires_in_falls_back_to_the_default_lifetime():
    clock = FakeClock()
    client, transport, _ = client_with(
        access_token_response(expires_in="not-a-number"), MINTED, MINTED, clock=clock
    )

    client.mint(amount=1000, currency="EUR", options={})
    clock.now = sandbox.DEFAULT_TOKEN_LIFETIME_SECONDS - sandbox.TOKEN_REFRESH_MARGIN_SECONDS - 1
    client.mint(amount=1000, currency="EUR", options={})

    assert [c[1] for c in transport.calls].count(ENV["TOKEN_URL"]) == 1


def test_mint_failure_names_no_token():
    refused = json.dumps({"message": "amount is required"}).encode()
    client, _, _ = client_with(access_token_response(), refused)

    with pytest.raises(sandbox.SandboxError) as excinfo:
        client.mint(amount=1000, currency="EUR", options={})

    assert "session_token" in str(excinfo.value)
    assert "amount is required" in str(excinfo.value)


def test_mint_never_echoes_a_token_it_could_not_use():
    # The "no session_token" branch fires on a token without an id too, and
    # that message reaches the run log.
    orphaned = json.dumps({"session_token": TOKEN}).encode()
    client, _, _ = client_with(access_token_response(), orphaned)

    with pytest.raises(sandbox.SandboxError) as excinfo:
        client.mint(amount=1000, currency="EUR", options={})

    assert TOKEN not in str(excinfo.value)


def test_mint_reports_a_response_that_is_not_an_object():
    client, _, _ = client_with(access_token_response(), b"null")

    with pytest.raises(sandbox.SandboxError):
        client.mint(amount=1000, currency="EUR", options={})


def test_read_gets_the_session_resource():
    session = json.dumps({"id": "01a0-sess", "status": "completed"}).encode()
    client, transport, _ = client_with(access_token_response(), session)

    assert client.read("01a0-sess")["status"] == "completed"
    assert transport.calls[1][0] == "GET"
    assert transport.calls[1][1] == ENV["PAYMENT_API_URL"] + "/01a0-sess"


def test_read_rejects_a_body_that_is_not_a_session_object():
    client, _, _ = client_with(access_token_response(), b"[]")

    with pytest.raises(sandbox.SandboxError) as excinfo:
        client.read("01a0-sess")

    assert "01a0-sess" in str(excinfo.value)


def test_a_refusal_is_reported_with_its_status_and_reason():
    refused = json.dumps({"message": "amount is required"}).encode()
    client, _, _ = client_with(access_token_response(), (422, refused))

    with pytest.raises(sandbox.SandboxError) as excinfo:
        client.mint(amount=1000, currency="EUR", options={})

    message = str(excinfo.value)
    assert "422" in message
    assert ENV["PAYMENT_API_URL"] in message
    assert "amount is required" in message


def test_an_error_body_never_echoes_a_session_token():
    # A GET on a session returns the whole resource, session_token included,
    # and a non-2xx body is exactly the thing that gets logged.
    leaky = json.dumps(
        {"id": "s", "session_token": TOKEN, "message": "gone"}
    ).encode()
    client, _, _ = client_with(access_token_response(), (410, leaky))

    with pytest.raises(sandbox.SandboxError) as excinfo:
        client.read("s")

    assert TOKEN not in str(excinfo.value)
    assert "gone" in str(excinfo.value)


def test_a_nested_session_token_is_dropped_by_key_not_by_shape():
    # Deliberately not JWT-shaped: the regex mask must not be what saves this,
    # or _scrub could stop recursing and no test would notice.
    opaque = "opaque-session-token-value"
    leaky = json.dumps({"errors": [{"session": {"session_token": opaque}}]}).encode()
    client, _, _ = client_with(access_token_response(), (422, leaky))

    with pytest.raises(sandbox.SandboxError) as excinfo:
        client.read("s")

    assert opaque not in str(excinfo.value)


def test_a_non_json_body_is_reported_with_any_token_masked():
    # Cloudflare answers with an HTML page, not JSON, when the UA is wrong.
    page = b"<html>Attention Required! trace: " + TOKEN.encode() + b"</html>"
    client, _, _ = client_with(access_token_response(), page)

    with pytest.raises(sandbox.SandboxError) as excinfo:
        client.read("s")

    assert TOKEN not in str(excinfo.value)
    assert "not JSON" in str(excinfo.value)


def test_a_token_endpoint_refusal_is_reported_with_its_status():
    client, _, _ = client_with((401, b'{"error": "invalid_client"}'))

    with pytest.raises(sandbox.SandboxError) as excinfo:
        client.mint(amount=1000, currency="EUR", options={})

    assert "401" in str(excinfo.value)
    assert "invalid_client" in str(excinfo.value)


def test_a_transport_failure_is_retried_once_and_then_reported():
    refused = urllib.error.URLError("connection refused")
    client, transport, clock = client_with(refused, refused)

    with pytest.raises(sandbox.SandboxError) as excinfo:
        client.mint(amount=1000, currency="EUR", options={})

    assert len(transport.calls) == sandbox.MAX_ATTEMPTS
    assert clock.slept == [sandbox.RETRY_BACKOFF_SECONDS]
    assert "URLError" in str(excinfo.value)


def test_a_timeout_is_retried_like_a_connection_failure():
    client, transport, clock = client_with(
        TimeoutError("timed out"), access_token_response(), MINTED
    )

    assert client.mint(amount=1000, currency="EUR", options={})["id"] == "01a0-sess"
    assert len(transport.calls) == 3
    assert clock.slept == [sandbox.RETRY_BACKOFF_SECONDS]


def test_a_5xx_is_retried_once_and_then_reported():
    client, transport, clock = client_with(
        access_token_response(), (503, b"upstream"), (503, b"upstream")
    )

    with pytest.raises(sandbox.SandboxError) as excinfo:
        client.mint(amount=1000, currency="EUR", options={})

    assert len(transport.calls) == 3
    assert clock.slept == [sandbox.RETRY_BACKOFF_SECONDS]
    assert "503" in str(excinfo.value)

    # The invariant that makes retrying a mint safe at all: replay the key,
    # never regenerate it, or the retry bills a second live session.
    first, second = transport.calls[1][2], transport.calls[2][2]
    assert first["Idempotency-Key"] == second["Idempotency-Key"]


def test_a_truncated_response_is_retried_like_a_connection_failure():
    # A short read raises out of response.read(), after the status line, so it
    # is not a URLError and would otherwise escape as a raw HTTPException.
    client, transport, clock = client_with(
        http.client.IncompleteRead(b"partial"), access_token_response(), MINTED
    )

    assert client.mint(amount=1000, currency="EUR", options={})["id"] == "01a0-sess"
    assert len(transport.calls) == 3
    assert clock.slept == [sandbox.RETRY_BACKOFF_SECONDS]


def test_a_truncated_response_that_persists_is_reported():
    failure = http.client.IncompleteRead(b"partial")
    client, transport, _ = client_with(failure, failure)

    with pytest.raises(sandbox.SandboxError) as excinfo:
        client.mint(amount=1000, currency="EUR", options={})

    assert "IncompleteRead" in str(excinfo.value)
    assert len(transport.calls) == sandbox.MAX_ATTEMPTS


def test_a_4xx_is_never_retried():
    # A refusal is the API's considered answer; repeating it wastes a run.
    client, transport, clock = client_with(access_token_response(), (422, b"{}"))

    with pytest.raises(sandbox.SandboxError):
        client.mint(amount=1000, currency="EUR", options={})

    assert len(transport.calls) == 2
    assert clock.slept == []


def test_the_refresh_is_scheduled_from_the_jwt_exp_not_from_expires_in():
    # The gateway replays a cached token with a full expires_in, so only the
    # signed `exp` says when this token actually dies. Here they disagree by
    # 50 minutes and `exp` must win.
    clock = FakeClock()
    short_lived = jwt_with({"exp": clock.time() + 600})
    client, transport, _ = client_with(
        access_token_response(expires_in=3600, token=short_lived),
        MINTED,
        access_token_response(expires_in=3600, token=jwt_with({"exp": clock.time() + 4000})),
        MINTED,
        clock=clock,
    )

    client.mint(amount=1000, currency="EUR", options={})
    # Past exp - 300, and far short of the 3300 s expires_in would have bought.
    clock.now = 400
    client.mint(amount=1000, currency="EUR", options={})

    assert len(_token_fetches(transport)) == 2


def test_a_token_whose_exp_has_not_come_near_is_still_reused():
    clock = FakeClock()
    client, transport, _ = client_with(
        access_token_response(expires_in=3600, token=jwt_with({"exp": clock.time() + 3600})),
        MINTED,
        MINTED,
        clock=clock,
    )

    client.mint(amount=1000, currency="EUR", options={})
    clock.now = 3600 - sandbox.TOKEN_REFRESH_MARGIN_SECONDS - 1
    client.mint(amount=1000, currency="EUR", options={})

    assert len(_token_fetches(transport)) == 1


def test_a_token_handed_over_already_expired_is_not_reused():
    # Exactly the cached-token case: the gateway replays a token with minutes
    # already spent but a full expires_in. `exp` is in the past, so the cache
    # window collapses to zero and the next call refetches rather than
    # spending the run on 401s. (The request that fetched it still goes out
    # with it; the 401 retry is what rescues that one.)
    clock = FakeClock()
    client, transport, _ = client_with(
        access_token_response(expires_in=3600, token=jwt_with({"exp": clock.time() - 1})),
        MINTED,
        access_token_response(expires_in=3600, token=jwt_with({"exp": clock.time() + 3600})),
        MINTED,
        clock=clock,
    )

    client.mint(amount=1000, currency="EUR", options={})
    client.mint(amount=1000, currency="EUR", options={})

    assert len(_token_fetches(transport)) == 2


@pytest.mark.parametrize(
    "token",
    [
        "bearer-789",
        "not.a.jwt",
        pytest.param("", id="empty"),
        "eyJhbGciOiJSUzI1NiJ9.bm90LWpzb24.c2ln",
    ],
)
def test_a_token_with_no_readable_exp_falls_back_to_expires_in(token):
    clock = FakeClock()
    client, transport, _ = client_with(
        access_token_response(expires_in=3600, token=token),
        MINTED,
        MINTED,
        clock=clock,
    )

    client.mint(amount=1000, currency="EUR", options={})
    clock.now = 3600 - sandbox.TOKEN_REFRESH_MARGIN_SECONDS - 1
    client.mint(amount=1000, currency="EUR", options={})

    assert len(_token_fetches(transport)) == 1


@pytest.mark.parametrize("exp", ["soon", None, True, [1]])
def test_an_exp_that_is_not_a_number_falls_back_to_expires_in(exp):
    clock = FakeClock()
    client, transport, _ = client_with(
        access_token_response(expires_in=3600, token=jwt_with({"exp": exp})),
        MINTED,
        MINTED,
        clock=clock,
    )

    client.mint(amount=1000, currency="EUR", options={})
    clock.now = 3600 - sandbox.TOKEN_REFRESH_MARGIN_SECONDS - 1
    client.mint(amount=1000, currency="EUR", options={})

    assert len(_token_fetches(transport)) == 1


UNAUTHORIZED = (
    401,
    json.dumps(
        {"error": {"type": "authentication_error", "message": "Invalid or expired access token"}}
    ).encode(),
)


def _mints(transport):
    return [c for c in transport.calls if c[1] == ENV["PAYMENT_API_URL"]]


def _token_fetches(transport):
    return [c for c in transport.calls if c[1] == ENV["TOKEN_URL"]]


def test_a_401_refetches_the_token_and_replays_the_request():
    # The 2026-08-29 Android run died here: a cached token reported as fresh
    # expired mid-matrix and every later mint was a 401.
    client, transport, _ = client_with(
        access_token_response(expires_in=3600),
        UNAUTHORIZED,
        access_token_response(expires_in=3600, token="bearer-fresh"),
        MINTED,
    )

    assert client.mint(amount=1000, currency="EUR", options={})["id"] == "01a0-sess"
    assert len(_token_fetches(transport)) == 2
    assert _mints(transport)[-1][2]["Authorization"] == "Bearer bearer-fresh"


def test_the_replayed_mint_reuses_its_idempotency_key():
    # Regenerating it would bill a second live sandbox session for one cell.
    client, transport, _ = client_with(
        access_token_response(),
        UNAUTHORIZED,
        access_token_response(token="bearer-fresh"),
        MINTED,
    )

    client.mint(amount=1000, currency="EUR", options={})

    first, replay = _mints(transport)
    assert first[2]["Idempotency-Key"] == replay[2]["Idempotency-Key"]
    assert first[3] == replay[3]


def test_a_401_on_read_is_replayed_too():
    client, transport, _ = client_with(
        access_token_response(),
        UNAUTHORIZED,
        access_token_response(token="bearer-fresh"),
        json.dumps({"id": "01a0-sess", "status": "completed"}).encode(),
    )

    assert client.read("01a0-sess")["status"] == "completed"
    assert len(_token_fetches(transport)) == 2


def test_a_second_401_is_reported_rather_than_retried_again():
    # One retry, never a loop: if a freshly minted token is also refused the
    # credentials or the environment are wrong and the run must say so.
    client, transport, _ = client_with(
        access_token_response(),
        UNAUTHORIZED,
        access_token_response(token="bearer-fresh"),
        UNAUTHORIZED,
    )

    with pytest.raises(sandbox.SandboxError, match="HTTP 401"):
        client.mint(amount=1000, currency="EUR", options={})

    assert len(_token_fetches(transport)) == 2
    assert len(_mints(transport)) == 2


def test_a_401_never_echoes_the_token_it_was_refused_with():
    client, _, _ = client_with(
        access_token_response(),
        UNAUTHORIZED,
        access_token_response(token="bearer-fresh"),
        UNAUTHORIZED,
    )

    with pytest.raises(sandbox.SandboxError) as caught:
        client.mint(amount=1000, currency="EUR", options={})

    assert "bearer-fresh" not in str(caught.value)
    assert "secret-456" not in str(caught.value)


def test_the_real_transport_returns_the_status_and_body_of_an_error(monkeypatch):
    # urlopen raises on 4xx/5xx, so without this the caller cannot tell a
    # refusal from a success and a bad cell is a raw traceback.
    import io

    def refuse(request, timeout=None):
        raise urllib.error.HTTPError(
            request.full_url,
            422,
            "Unprocessable Entity",
            {},
            io.BytesIO(b'{"message": "amount is required"}'),
        )

    monkeypatch.setattr(urllib.request, "urlopen", refuse)

    status, body = sandbox._urllib_transport("POST", "https://api.example/x", {}, b"{}")

    assert status == 422
    assert json.loads(body)["message"] == "amount is required"


def test_the_real_transport_puts_every_header_on_the_request(monkeypatch):
    # Mutation guard: dropping `headers=headers`, the method, the body or the
    # timeout from the Request has to fail here rather than at the live API.
    seen = {}

    class Response:
        status = 200

        def read(self):
            return b"{}"

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return False

    def capture(request, timeout=None):
        seen["request"] = request
        seen["timeout"] = timeout
        return Response()

    monkeypatch.setattr(urllib.request, "urlopen", capture)

    status, _ = sandbox._urllib_transport(
        "POST",
        "https://api.example/x",
        {"User-Agent": sandbox.USER_AGENT, "PayCross-Version": "2026-01-01"},
        b"{}",
    )

    request = seen["request"]
    assert status == 200
    # urllib capitalises header names as it stores them.
    assert request.get_header("User-agent") == sandbox.USER_AGENT
    assert request.get_header("Paycross-version") == "2026-01-01"
    assert request.get_method() == "POST"
    assert request.data == b"{}"
    assert seen["timeout"] == sandbox.REQUEST_TIMEOUT_SECONDS


def test_repr_never_shows_credentials():
    client = sandbox.Sandbox(ENV, transport=FakeTransport())

    text = repr(client)

    assert "secret-456" not in text
    assert "id-123" not in text


def test_repr_survives_an_env_that_is_missing_the_api_url():
    # repr runs inside tracebacks; raising KeyError there hides the real error.
    client = sandbox.Sandbox({}, transport=FakeTransport())

    assert "?" in repr(client)
