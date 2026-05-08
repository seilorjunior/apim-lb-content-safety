"""Cross-cutting proxy behavior tests:

* Inbound query string is forwarded (paging support).
* `api-version` cannot be overridden by caller.
* Path segments containing reserved chars are URL-encoded.
* Correlation/trace headers are echoed back on upstream-failure 502.
"""

from __future__ import annotations

import azure.functions as func
import httpx
import pytest
import respx

from function_app import (
    analyze_text,
    blocklist_by_name,
    list_blocklist_items,
)


@pytest.mark.asyncio
async def test_inbound_query_string_is_forwarded(apim_mock) -> None:
    """top= and skiptoken= must reach APIM for paging to work."""
    route = apim_mock.get(
        "/contentsafety/text/blocklists/profanity/blocklistItems",
        params={"api-version": "2024-09-01", "top": "10", "skiptoken": "abc"},
    ).mock(return_value=httpx.Response(200, json={"value": []}))

    req = func.HttpRequest(
        method="GET",
        url="/api/blocklists/profanity/items?top=10&skiptoken=abc",
        body=b"",
        headers={},
        route_params={"name": "profanity"},
    )
    resp = await list_blocklist_items(req)

    assert route.called
    assert resp.status_code == 200


@pytest.mark.asyncio
async def test_caller_cannot_override_api_version(apim_mock) -> None:
    """If the caller passes ?api-version=evil, server-configured version still wins."""
    route = apim_mock.post(
        "/contentsafety/text:analyze",
        params={"api-version": "2024-09-01"},
    ).mock(return_value=httpx.Response(200, json={"categoriesAnalysis": []}))

    req = func.HttpRequest(
        method="POST",
        url="/api/analyze-text?api-version=evil",
        body=b'{"text":"hi"}',
        headers={"content-type": "application/json"},
    )
    resp = await analyze_text(req)

    assert route.called
    sent = route.calls.last.request
    # Exactly one api-version, and it's the server-configured value.
    qs = sent.url.params
    assert qs.get_list("api-version") == ["2024-09-01"]
    assert resp.status_code == 200


@pytest.mark.asyncio
async def test_path_segment_with_reserved_chars_is_encoded(apim_mock) -> None:
    """A name containing a slash or '?' must NOT inject extra path/query segments upstream.

    Use a regex matcher so respx accepts whatever percent-encoded form the proxy emits;
    then assert on the recorded request URL that the literal '/' is gone from the segment.
    """
    import re

    route = apim_mock.get(
        url__regex=re.compile(
            r"^https://apim-test\.azure-api\.net/contentsafety/text/blocklists/[^/?]+(\?.*)?$"
        ),
    ).mock(return_value=httpx.Response(200, json={"blocklistName": "../evil"}))

    req = func.HttpRequest(
        method="GET",
        url="/api/blocklists/..%2Fevil",
        body=b"",
        headers={},
        route_params={"name": "../evil"},
    )
    resp = await blocklist_by_name(req)

    assert route.called, "URL-encoding of path segment broken — request did not match"
    sent_path = route.calls.last.request.url.raw_path.decode("ascii")
    # '..%2Fevil' (encoded) — NOT '../evil' which would inject path traversal.
    assert "/blocklists/..%2Fevil" in sent_path
    assert "/blocklists/../evil" not in sent_path
    assert resp.status_code == 200


@pytest.mark.asyncio
async def test_correlation_id_echoed_on_upstream_failure() -> None:
    """When httpx raises, the 502 response must echo back trace headers from the inbound request."""
    with respx.mock(
        base_url="https://apim-test.azure-api.net",
        assert_all_called=False,
    ) as mock:
        mock.post("/contentsafety/text:analyze").mock(
            side_effect=httpx.ConnectError("simulated network failure"),
        )

        req = func.HttpRequest(
            method="POST",
            url="/api/analyze-text",
            body=b'{"text":"hi"}',
            headers={
                "content-type": "application/json",
                "x-correlation-id": "corr-123",
                "traceparent": "00-aaaaaaaa-bbbbbbbb-01",
            },
        )
        resp = await analyze_text(req)

    assert resp.status_code == 502
    assert resp.headers.get("x-correlation-id") == "corr-123"
    assert resp.headers.get("traceparent") == "00-aaaaaaaa-bbbbbbbb-01"
