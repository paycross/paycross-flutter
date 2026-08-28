import json

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


class FakeTransport:
    """Records every request and replays canned responses in order."""

    def __init__(self, *responses):
        self.responses = list(responses)
        self.calls = []

    def __call__(self, method, url, headers, body):
        self.calls.append((method, url, dict(headers), body))
        return self.responses.pop(0)


def access_token_response():
    return json.dumps({"access_token": "bearer-789"}).encode()


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
    transport = FakeTransport(access_token_response(), minted)
    client = sandbox.Sandbox(ENV, transport=transport)

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


def test_mint_merges_cell_options_over_the_default_body():
    minted = json.dumps({"id": "s", "session_token": TOKEN}).encode()
    transport = FakeTransport(access_token_response(), minted)
    client = sandbox.Sandbox(ENV, transport=transport)

    client.mint(
        amount=2500,
        currency="EUR",
        options={"data": {"wallets": {"google_pay": False}}},
    )

    body = json.loads(transport.calls[1][3])
    assert body["data"] == {"wallets": {"google_pay": False}}
    assert body["amount"] == 2500


def test_mint_reuses_one_access_token_across_calls():
    minted = json.dumps({"id": "s", "session_token": TOKEN}).encode()
    transport = FakeTransport(access_token_response(), minted, minted)
    client = sandbox.Sandbox(ENV, transport=transport)

    client.mint(amount=1000, currency="EUR", options={})
    client.mint(amount=1000, currency="EUR", options={})

    assert [c[1] for c in transport.calls].count(ENV["TOKEN_URL"]) == 1


def test_mint_failure_names_no_token():
    refused = json.dumps({"message": "amount is required"}).encode()
    transport = FakeTransport(access_token_response(), refused)
    client = sandbox.Sandbox(ENV, transport=transport)

    with pytest.raises(sandbox.SandboxError) as excinfo:
        client.mint(amount=1000, currency="EUR", options={})

    assert "session_token" in str(excinfo.value)
    assert "amount is required" in str(excinfo.value)


def test_read_gets_the_session_resource():
    session = json.dumps({"id": "01a0-sess", "status": "completed"}).encode()
    transport = FakeTransport(access_token_response(), session)
    client = sandbox.Sandbox(ENV, transport=transport)

    assert client.read("01a0-sess")["status"] == "completed"
    assert transport.calls[1][0] == "GET"
    assert transport.calls[1][1] == ENV["PAYMENT_API_URL"] + "/01a0-sess"


def test_transport_returns_the_body_of_an_error_response(monkeypatch):
    # urlopen raises on 4xx/5xx, so without this mint's SandboxError branch is
    # unreachable against the live API and a bad cell is a raw traceback.
    import io
    import urllib.error
    import urllib.request

    def refuse(request, timeout=None):
        raise urllib.error.HTTPError(
            request.full_url,
            422,
            "Unprocessable Entity",
            {},
            io.BytesIO(b'{"message": "amount is required"}'),
        )

    monkeypatch.setattr(urllib.request, "urlopen", refuse)

    body = sandbox._urllib_transport("POST", "https://api.example/x", {}, b"{}")

    assert json.loads(body)["message"] == "amount is required"


def test_repr_never_shows_credentials():
    client = sandbox.Sandbox(ENV, transport=FakeTransport())

    text = repr(client)

    assert "secret-456" not in text
    assert "id-123" not in text


def test_mint_never_echoes_a_token_it_could_not_use():
    # The "no session_token" branch fires on a token without an id too, and
    # that message reaches the run log.
    orphaned = json.dumps({"session_token": TOKEN}).encode()
    transport = FakeTransport(access_token_response(), orphaned)
    client = sandbox.Sandbox(ENV, transport=transport)

    with pytest.raises(sandbox.SandboxError) as excinfo:
        client.mint(amount=1000, currency="EUR", options={})

    assert TOKEN not in str(excinfo.value)


def test_mint_reports_a_response_that_is_not_an_object():
    transport = FakeTransport(access_token_response(), b"null")
    client = sandbox.Sandbox(ENV, transport=transport)

    with pytest.raises(sandbox.SandboxError):
        client.mint(amount=1000, currency="EUR", options={})
