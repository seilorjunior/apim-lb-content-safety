"""The Function never retries; APIM exclusively owns the read retry budget."""

import azure.functions as func
import httpx
import pytest

import function_app


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
    await function_app.analyze_text(req)

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
    await function_app.analyze_text(req)

    assert "ocp-apim-subscription-key" not in route.calls.last.request.headers


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
    resp = await function_app.analyze_text(req)

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
    resp = await function_app.analyze_text(req)

    assert resp.status_code == 200
    assert route.called


@pytest.mark.parametrize("method", ["GET", "HEAD", "OPTIONS", "POST", "PATCH", "DELETE"])
@pytest.mark.parametrize("key", [None, "key"])
@pytest.mark.parametrize("status", [200, 400, 408, 429, 500, 502, 503, 504])
async def test_status_is_preserved_without_retry(apim_mock, method, key, status):
    route = apim_mock.request(method, "/contentsafety/text/blocklists/x").mock(
        return_value=httpx.Response(status, content=b"original", headers={"retry-after": "7"}),
    )
    req = func.HttpRequest(
        method=method, url="/api/blocklists/x", body=b"",
        headers={"idempotency-key": key} if key else {},
    )
    response = await function_app._proxy(req, method, "/text/blocklists/x")
    assert route.call_count == 1
    assert response.status_code == status
    assert response.get_body() == b"original"
    assert response.headers["retry-after"] == "7"
    assert "idempotency-key" not in route.calls.last.request.headers


@pytest.mark.parametrize("method", ["GET", "HEAD", "OPTIONS", "POST", "PATCH", "DELETE"])
@pytest.mark.parametrize("key", [None, "key"])
@pytest.mark.parametrize(
    "error",
    [httpx.ConnectError, httpx.ReadTimeout, httpx.WriteTimeout, httpx.RemoteProtocolError],
)
async def test_network_failures_are_never_retried(apim_mock, method, key, error):
    route = apim_mock.request(method, "/contentsafety/text/blocklists/x").mock(
        side_effect=[error("unknown"), httpx.Response(200)],
    )
    req = func.HttpRequest(
        method=method, url="/api/blocklists/x", body=b"",
        headers={"idempotency-key": key} if key else {},
    )
    response = await function_app._proxy(req, method, "/text/blocklists/x")
    assert route.call_count == 1
    assert response.status_code == 502


@pytest.mark.parametrize("key", ["", "server-owned-key"])
async def test_subscription_key_only_from_config(apim_mock, monkeypatch, key):
    monkeypatch.setattr(function_app, "APIM_SUBSCRIPTION_KEY", key)
    route = apim_mock.post("/contentsafety/text:analyze").mock(
        return_value=httpx.Response(200),
    )
    req = func.HttpRequest(
        method="POST", url="/api/analyze-text", body=b"{}",
        headers={"ocp-apim-subscription-key": "caller-key"},
    )
    await function_app.analyze_text(req)
    assert route.calls.last.request.headers.get("ocp-apim-subscription-key") == (key or None)


@pytest.mark.parametrize("size,status", [(15, 200), (16, 200), (17, 413)])
async def test_request_size_boundary(apim_mock, monkeypatch, size, status):
    monkeypatch.setattr(function_app, "MAX_REQUEST_BODY_BYTES", 16)
    route = apim_mock.post("/contentsafety/text:analyze").mock(
        return_value=httpx.Response(200),
    )
    req = func.HttpRequest(method="POST", url="/api/analyze-text", body=b"x" * size)
    response = await function_app.analyze_text(req)
    assert response.status_code == status
    assert route.call_count == (1 if status == 200 else 0)
