"""Stateless analyze endpoints — verify path translation + body forwarding."""

from __future__ import annotations

import azure.functions as func
import httpx
import pytest

from function_app import (
    analyze_image,
    analyze_text,
    detect_groundedness,
    detect_protected_material,
    shield_prompt,
)


@pytest.mark.asyncio
async def test_analyze_text_proxies_body(apim_mock) -> None:
    route = apim_mock.post(
        "/contentsafety/text:analyze",
        params={"api-version": "2024-09-01"},
    ).mock(
        return_value=httpx.Response(
            200,
            json={
                "categoriesAnalysis": [
                    {"category": "Hate", "severity": 0},
                ]
            },
        )
    )

    req = func.HttpRequest(
        method="POST",
        url="/api/analyze-text",
        body=b'{"text":"hello"}',
        headers={"content-type": "application/json"},
    )
    resp = await analyze_text(req)

    assert route.called
    assert route.calls.last.request.content == b'{"text":"hello"}'
    assert resp.status_code == 200
    assert b"categoriesAnalysis" in resp.get_body()


@pytest.mark.asyncio
async def test_analyze_image_uses_image_path(apim_mock) -> None:
    route = apim_mock.post(
        "/contentsafety/image:analyze",
        params={"api-version": "2024-09-01"},
    ).mock(return_value=httpx.Response(200, json={"categoriesAnalysis": []}))

    req = func.HttpRequest(
        method="POST",
        url="/api/analyze-image",
        body=b'{"image":{"content":"BASE64"}}',
        headers={"content-type": "application/json"},
    )
    resp = await analyze_image(req)

    assert route.called
    assert resp.status_code == 200


@pytest.mark.asyncio
async def test_groundedness_uses_preview_version(apim_mock) -> None:
    route = apim_mock.post(
        "/contentsafety/text:detectGroundedness",
        params={"api-version": "2024-09-15-preview"},
    ).mock(return_value=httpx.Response(200, json={"ungroundedDetected": False}))

    req = func.HttpRequest(
        method="POST",
        url="/api/detect-groundedness",
        body=b"{}",
        headers={"content-type": "application/json"},
    )
    resp = await detect_groundedness(req)

    assert route.called
    assert resp.status_code == 200


@pytest.mark.asyncio
async def test_protected_material_passthrough(apim_mock) -> None:
    route = apim_mock.post(
        "/contentsafety/text:detectProtectedMaterial",
        params={"api-version": "2024-09-01"},
    ).mock(return_value=httpx.Response(200, json={"protectedMaterialAnalysis": {}}))

    req = func.HttpRequest(
        method="POST",
        url="/api/detect-protected-material",
        body=b'{"text":"hello"}',
        headers={"content-type": "application/json"},
    )
    resp = await detect_protected_material(req)

    assert route.called
    assert resp.status_code == 200


@pytest.mark.asyncio
async def test_shield_prompt_forwards_idempotency_key(apim_mock) -> None:
    route = apim_mock.post(
        "/contentsafety/text:shieldPrompt",
        params={"api-version": "2024-09-01"},
    ).mock(return_value=httpx.Response(200, json={"userPromptAnalysis": {}}))

    req = func.HttpRequest(
        method="POST",
        url="/api/shield-prompt",
        body=b'{"userPrompt":"hi"}',
        headers={
            "content-type": "application/json",
            "idempotency-key": "abc123",
        },
    )
    resp = await shield_prompt(req)

    assert route.called
    sent = route.calls.last.request
    assert sent.headers.get("idempotency-key") == "abc123"
    assert resp.status_code == 200


@pytest.mark.asyncio
async def test_proxy_returns_500_when_apim_url_missing(monkeypatch) -> None:
    # Simulate missing config without poisoning the module cache permanently.
    import function_app

    monkeypatch.setattr(function_app, "APIM_GATEWAY_URL", "")

    req = func.HttpRequest(
        method="POST",
        url="/api/analyze-text",
        body=b"{}",
        headers={"content-type": "application/json"},
    )
    resp = await analyze_text(req)
    assert resp.status_code == 500
    assert b"ConfigurationError" in resp.get_body()
