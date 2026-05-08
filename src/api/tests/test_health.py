"""Health endpoint tests."""

from __future__ import annotations

import json

import azure.functions as func
import pytest

from function_app import health


@pytest.mark.asyncio
async def test_health_returns_200() -> None:
    req = func.HttpRequest(method="GET", url="/api/health", body=b"", headers={})
    resp = await health(req)
    assert resp.status_code == 200
    payload = json.loads(resp.get_body())
    assert payload["status"] == "ok"


@pytest.mark.asyncio
async def test_health_reports_apim_configured() -> None:
    req = func.HttpRequest(method="GET", url="/api/health", body=b"", headers={})
    resp = await health(req)
    payload = json.loads(resp.get_body())
    assert payload["apim_configured"] is True
