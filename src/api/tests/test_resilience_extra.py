"""Additional resiliency tests covering production failure modes.

Single-attempt status/network behavior is parameterized in test_resilience.py.
These original configuration, header, body, and logging regressions remain intact.
"""

from __future__ import annotations

import asyncio
import json
import logging

import azure.functions as func
import httpx
import pytest

import function_app
from function_app import analyze_text, list_blocklists


# ---------------------------------------------------------------------------
# Retry-eligibility boundaries
# ---------------------------------------------------------------------------
@pytest.mark.asyncio
async def test_500_is_not_retried(apim_mock) -> None:
    """500 Internal Server Error is returned on the single Function attempt."""
    route = apim_mock.get(
        "/contentsafety/text/blocklists",
        params={"api-version": "2024-09-01"},
    ).mock(return_value=httpx.Response(500, json={"err": "boom"}))

    req = func.HttpRequest(method="GET", url="/api/blocklists", body=b"", headers={})
    resp = await list_blocklists(req)

    assert route.call_count == 1
    assert resp.status_code == 500


@pytest.mark.asyncio
async def test_429_with_idempotency_key_is_not_retried(apim_mock) -> None:
    """429 is NOT retryable — caller must respect Retry-After itself."""
    route = apim_mock.post(
        "/contentsafety/text:analyze",
        params={"api-version": "2024-09-01"},
    ).mock(
        return_value=httpx.Response(
            429,
            json={"err": "rate limited"},
            headers={"retry-after": "30"},
        )
    )

    req = func.HttpRequest(
        method="POST",
        url="/api/analyze-text",
        body=b'{"text":"x"}',
        headers={
            "content-type": "application/json",
            "idempotency-key": "abc",
        },
    )
    resp = await analyze_text(req)

    assert route.call_count == 1
    assert resp.status_code == 429


@pytest.mark.asyncio
async def test_retry_after_preserved_on_final_response(apim_mock) -> None:
    """`Retry-After` on a final 503 response must reach the caller."""
    apim_mock.get(
        "/contentsafety/text/blocklists",
        params={"api-version": "2024-09-01"},
    ).mock(
        return_value=httpx.Response(
            503,
            json={"err": "overloaded"},
            headers={"retry-after": "5"},
        )
    )

    req = func.HttpRequest(method="GET", url="/api/blocklists", body=b"", headers={})
    resp = await list_blocklists(req)

    assert resp.status_code == 503
    assert resp.headers.get("retry-after") == "5"


# ---------------------------------------------------------------------------
# Config & boundary edges
# ---------------------------------------------------------------------------
@pytest.mark.asyncio
async def test_missing_gateway_url_returns_500(apim_mock, monkeypatch) -> None:
    """APIM_GATEWAY_URL empty → 500 ConfigurationError, no upstream call."""
    monkeypatch.setattr(function_app, "APIM_GATEWAY_URL", "")

    route = apim_mock.post(
        "/contentsafety/text:analyze",
        params={"api-version": "2024-09-01"},
    ).mock(return_value=httpx.Response(200))

    req = func.HttpRequest(
        method="POST",
        url="/api/analyze-text",
        body=b'{"text":"x"}',
        headers={"content-type": "application/json"},
    )
    resp = await analyze_text(req)

    assert resp.status_code == 500
    assert not route.called
    body = json.loads(resp.get_body())
    assert body["code"] == "ConfigurationError"


@pytest.mark.asyncio
async def test_body_exactly_at_limit_passes_through(apim_mock, monkeypatch) -> None:
    """Boundary: len(body) == MAX_REQUEST_BODY_BYTES is allowed (strict `>`)."""
    monkeypatch.setattr(function_app, "MAX_REQUEST_BODY_BYTES", 32)
    route = apim_mock.post(
        "/contentsafety/text:analyze",
        params={"api-version": "2024-09-01"},
    ).mock(return_value=httpx.Response(200, json={"ok": True}))

    body = b"x" * 32  # exactly at the limit
    req = func.HttpRequest(
        method="POST",
        url="/api/analyze-text",
        body=body,
        headers={"content-type": "application/json"},
    )
    resp = await analyze_text(req)

    assert resp.status_code == 200
    assert route.called


# ---------------------------------------------------------------------------
# Security — header allowlists & log hygiene
# ---------------------------------------------------------------------------
@pytest.mark.asyncio
async def test_authorization_and_cookie_request_headers_not_forwarded(apim_mock) -> None:
    """Inbound Authorization / Cookie / X-Forwarded-For never reach APIM."""
    route = apim_mock.post(
        "/contentsafety/text:analyze",
        params={"api-version": "2024-09-01"},
    ).mock(return_value=httpx.Response(200, json={"ok": True}))

    req = func.HttpRequest(
        method="POST",
        url="/api/analyze-text",
        body=b'{"text":"x"}',
        headers={
            "content-type": "application/json",
            "authorization": "******",
            "cookie": "session=do-not-leak",
            "x-forwarded-for": "1.2.3.4",
            "x-functions-key": "function-key-do-not-leak",
        },
    )
    await analyze_text(req)

    sent = route.calls.last.request.headers
    # Lowercased lookup since httpx headers are case-insensitive but we
    # explicitly want to confirm none of these are forwarded.
    assert "authorization" not in sent
    assert "cookie" not in sent
    assert "x-forwarded-for" not in sent
    assert "x-functions-key" not in sent


@pytest.mark.asyncio
async def test_set_cookie_and_server_response_headers_not_echoed(apim_mock) -> None:
    """Upstream Set-Cookie / Server / WWW-Authenticate stripped before reply."""
    apim_mock.post(
        "/contentsafety/text:analyze",
        params={"api-version": "2024-09-01"},
    ).mock(
        return_value=httpx.Response(
            200,
            json={"ok": True},
            headers={
                "set-cookie": "sessionid=abc; Path=/",
                "server": "kestrel",
                "www-authenticate": "******",
                "x-powered-by": "ASP.NET",
            },
        )
    )

    req = func.HttpRequest(
        method="POST",
        url="/api/analyze-text",
        body=b'{"text":"x"}',
        headers={"content-type": "application/json"},
    )
    resp = await analyze_text(req)

    assert resp.status_code == 200
    out_headers = {k.lower() for k in dict(resp.headers).keys()}
    assert "set-cookie" not in out_headers
    assert "server" not in out_headers
    assert "www-authenticate" not in out_headers
    assert "x-powered-by" not in out_headers


@pytest.mark.asyncio
async def test_query_string_not_logged(apim_mock, caplog) -> None:
    """Caller-supplied query (e.g. `?code=<function-key>`) must NOT appear
    in ANY log record. function_app.py logs the path only, and httpx is
    silenced to WARNING at module import — so an INFO-level capture should
    contain zero records that include the secret.
    """
    apim_mock.get(
        "/contentsafety/text/blocklists",
        params={"api-version": "2024-09-01"},
    ).mock(return_value=httpx.Response(200, json={"value": []}))

    req = func.HttpRequest(
        method="GET",
        url="/api/blocklists?code=SUPER-SECRET-KEY&top=10",
        body=b"",
        headers={},
    )

    with caplog.at_level(logging.INFO):
        resp = await list_blocklists(req)

    assert resp.status_code == 200
    full_log = " ".join(record.getMessage() for record in caplog.records)
    assert "SUPER-SECRET-KEY" not in full_log
    assert "code=" not in full_log


async def test_query_string_and_network_error_not_logged(apim_mock, caplog):
    apim_mock.get("/contentsafety/text/blocklists").mock(
        side_effect=httpx.ConnectError("https://secret.example/?code=SUPER-SECRET-KEY"),
    )
    req = func.HttpRequest(
        method="GET", url="/api/blocklists?code=SUPER-SECRET-KEY&top=10", body=b"",
    )
    with caplog.at_level(logging.INFO):
        response = await function_app.list_blocklists(req)
    assert response.status_code == 502
    assert "SUPER-SECRET-KEY" not in caplog.text
    assert b"SUPER-SECRET-KEY" not in response.get_body()


# ---------------------------------------------------------------------------
# Concurrency
# ---------------------------------------------------------------------------
@pytest.mark.asyncio
async def test_concurrent_requests_share_singleton_client(apim_mock) -> None:
    """asyncio.gather two requests through the shared _HTTP_CLIENT — both succeed."""
    apim_mock.post(
        "/contentsafety/text:analyze",
        params={"api-version": "2024-09-01"},
    ).mock(return_value=httpx.Response(200, json={"ok": True}))
    apim_mock.get(
        "/contentsafety/text/blocklists",
        params={"api-version": "2024-09-01"},
    ).mock(return_value=httpx.Response(200, json={"value": []}))

    req_a = func.HttpRequest(
        method="POST",
        url="/api/analyze-text",
        body=b'{"text":"a"}',
        headers={"content-type": "application/json"},
    )
    req_b = func.HttpRequest(method="GET", url="/api/blocklists", body=b"", headers={})

    resp_a, resp_b = await asyncio.gather(analyze_text(req_a), list_blocklists(req_b))

    assert resp_a.status_code == 200
    assert resp_b.status_code == 200
