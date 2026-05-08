"""Tests for #3 retry helper, #4 body-size cap, and #6 subscription-key forwarding."""

from __future__ import annotations

import azure.functions as func
import httpx
import pytest

import function_app
from function_app import _is_retry_safe, analyze_text, list_blocklists


# ---------------------------------------------------------------------------
# #6: APIM subscription-key forwarding
# ---------------------------------------------------------------------------
@pytest.mark.asyncio
async def test_subscription_key_forwarded_when_set(apim_mock, monkeypatch) -> None:
    monkeypatch.setattr(function_app, "APIM_SUBSCRIPTION_KEY", "test-secret-key")

    route = apim_mock.post(
        "/contentsafety/text:analyze",
        params={"api-version": "2024-09-01"},
    ).mock(return_value=httpx.Response(200, json={"categoriesAnalysis": []}))

    req = func.HttpRequest(
        method="POST",
        url="/api/analyze-text",
        body=b'{"text":"x"}',
        headers={"content-type": "application/json"},
    )
    await analyze_text(req)

    assert route.called
    assert route.calls.last.request.headers.get("ocp-apim-subscription-key") == "test-secret-key"


@pytest.mark.asyncio
async def test_subscription_key_absent_when_unset(apim_mock, monkeypatch) -> None:
    monkeypatch.setattr(function_app, "APIM_SUBSCRIPTION_KEY", "")

    route = apim_mock.post(
        "/contentsafety/text:analyze",
        params={"api-version": "2024-09-01"},
    ).mock(return_value=httpx.Response(200, json={"categoriesAnalysis": []}))

    req = func.HttpRequest(
        method="POST",
        url="/api/analyze-text",
        body=b'{"text":"x"}',
        headers={"content-type": "application/json"},
    )
    await analyze_text(req)

    assert "ocp-apim-subscription-key" not in route.calls.last.request.headers


# ---------------------------------------------------------------------------
# #4: request body size cap
# ---------------------------------------------------------------------------
@pytest.mark.asyncio
async def test_payload_too_large_returns_413(apim_mock, monkeypatch) -> None:
    monkeypatch.setattr(function_app, "MAX_REQUEST_BODY_BYTES", 16)

    # respx route that should NOT be called when the body is rejected.
    route = apim_mock.post("/contentsafety/text:analyze").mock(
        return_value=httpx.Response(200)
    )

    oversized = b"x" * 32  # 32 bytes > 16-byte cap
    req = func.HttpRequest(
        method="POST",
        url="/api/analyze-text",
        body=oversized,
        headers={"content-type": "application/json"},
    )
    resp = await analyze_text(req)

    assert resp.status_code == 413
    assert b"PayloadTooLarge" in resp.get_body()
    assert not route.called  # short-circuited before any upstream call


@pytest.mark.asyncio
async def test_within_limit_passes_through(apim_mock, monkeypatch) -> None:
    monkeypatch.setattr(function_app, "MAX_REQUEST_BODY_BYTES", 64)
    route = apim_mock.post(
        "/contentsafety/text:analyze",
        params={"api-version": "2024-09-01"},
    ).mock(return_value=httpx.Response(200, json={"ok": True}))

    req = func.HttpRequest(
        method="POST",
        url="/api/analyze-text",
        body=b'{"text":"x"}',  # 12 bytes < 64
        headers={"content-type": "application/json"},
    )
    resp = await analyze_text(req)

    assert resp.status_code == 200
    assert route.called


# ---------------------------------------------------------------------------
# #3: retry helper — replay-safe vs non-idempotent
# ---------------------------------------------------------------------------
def test_is_retry_safe_idempotent_methods() -> None:
    assert _is_retry_safe("GET", {})
    assert _is_retry_safe("HEAD", {})
    assert _is_retry_safe("OPTIONS", {})
    assert _is_retry_safe("get", {})  # case-insensitive


def test_is_retry_safe_post_without_idempotency_key() -> None:
    assert not _is_retry_safe("POST", {})
    assert not _is_retry_safe("PATCH", {"content-type": "application/json"})
    assert not _is_retry_safe("DELETE", {})


def test_is_retry_safe_post_with_idempotency_key() -> None:
    assert _is_retry_safe("POST", {"Idempotency-Key": "abc"})
    assert _is_retry_safe("POST", {"idempotency-key": "abc"})  # case-insensitive
    assert _is_retry_safe("PATCH", {"IDEMPOTENCY-KEY": "abc"})


@pytest.mark.asyncio
async def test_retry_on_502_for_get(apim_mock, monkeypatch) -> None:
    """GET is retry-safe; 502→502→200 should succeed after 3 attempts."""
    monkeypatch.setattr(function_app, "_RETRY_BACKOFF_BASE_SECONDS", 0)

    route = apim_mock.get(
        "/contentsafety/text/blocklists",
        params={"api-version": "2024-09-01"},
    ).mock(
        side_effect=[
            httpx.Response(502, json={"err": "1"}),
            httpx.Response(502, json={"err": "2"}),
            httpx.Response(200, json={"value": []}),
        ]
    )

    req = func.HttpRequest(
        method="GET",
        url="/api/blocklists",
        body=b"",
        headers={},
    )
    resp = await list_blocklists(req)

    assert route.call_count == 3
    assert resp.status_code == 200


@pytest.mark.asyncio
async def test_no_retry_on_post_without_idempotency_key(apim_mock, monkeypatch) -> None:
    """POST without Idempotency-Key MUST NOT be retried (preserve at-most-once)."""
    monkeypatch.setattr(function_app, "_RETRY_BACKOFF_BASE_SECONDS", 0)

    route = apim_mock.post(
        "/contentsafety/text:analyze",
        params={"api-version": "2024-09-01"},
    ).mock(return_value=httpx.Response(502, json={"err": "transient"}))

    req = func.HttpRequest(
        method="POST",
        url="/api/analyze-text",
        body=b'{"text":"x"}',
        headers={"content-type": "application/json"},
    )
    resp = await analyze_text(req)

    assert route.call_count == 1
    assert resp.status_code == 502


@pytest.mark.asyncio
async def test_retry_on_post_with_idempotency_key(apim_mock, monkeypatch) -> None:
    """POST + Idempotency-Key IS retry-safe per the APIM policy contract."""
    monkeypatch.setattr(function_app, "_RETRY_BACKOFF_BASE_SECONDS", 0)

    route = apim_mock.post(
        "/contentsafety/text:analyze",
        params={"api-version": "2024-09-01"},
    ).mock(
        side_effect=[
            httpx.Response(503, json={"err": "transient"}),
            httpx.Response(200, json={"ok": True}),
        ]
    )

    req = func.HttpRequest(
        method="POST",
        url="/api/analyze-text",
        body=b'{"text":"x"}',
        headers={"content-type": "application/json", "Idempotency-Key": "abc-123"},
    )
    resp = await analyze_text(req)

    assert route.call_count == 2
    assert resp.status_code == 200


@pytest.mark.asyncio
async def test_retry_exhausted_returns_last_status(apim_mock, monkeypatch) -> None:
    """Retries exhausted → return the LAST upstream response (502)."""
    monkeypatch.setattr(function_app, "_RETRY_BACKOFF_BASE_SECONDS", 0)

    route = apim_mock.get(
        "/contentsafety/text/blocklists",
        params={"api-version": "2024-09-01"},
    ).mock(return_value=httpx.Response(502, json={"err": "perma"}))

    req = func.HttpRequest(
        method="GET",
        url="/api/blocklists",
        body=b"",
        headers={},
    )
    resp = await list_blocklists(req)

    assert route.call_count == 3  # _RETRY_MAX_ATTEMPTS
    assert resp.status_code == 502


@pytest.mark.asyncio
async def test_retry_on_connect_error_then_success(apim_mock, monkeypatch) -> None:
    """Transient ConnectError on retry-safe method → retry → 200."""
    monkeypatch.setattr(function_app, "_RETRY_BACKOFF_BASE_SECONDS", 0)

    route = apim_mock.get(
        "/contentsafety/text/blocklists",
        params={"api-version": "2024-09-01"},
    ).mock(
        side_effect=[
            httpx.ConnectError("temporary"),
            httpx.Response(200, json={"value": []}),
        ]
    )

    req = func.HttpRequest(
        method="GET",
        url="/api/blocklists",
        body=b"",
        headers={},
    )
    resp = await list_blocklists(req)

    assert route.call_count == 2
    assert resp.status_code == 200


@pytest.mark.asyncio
async def test_connect_error_not_retried_for_non_idempotent(apim_mock, monkeypatch) -> None:
    """Non-retry-safe method + ConnectError → raised immediately, surfaces as 502."""
    monkeypatch.setattr(function_app, "_RETRY_BACKOFF_BASE_SECONDS", 0)

    route = apim_mock.post(
        "/contentsafety/text:analyze",
        params={"api-version": "2024-09-01"},
    ).mock(side_effect=httpx.ConnectError("temporary"))

    req = func.HttpRequest(
        method="POST",
        url="/api/analyze-text",
        body=b'{"text":"x"}',
        headers={"content-type": "application/json"},
    )
    resp = await analyze_text(req)

    assert route.call_count == 1
    assert resp.status_code == 502
