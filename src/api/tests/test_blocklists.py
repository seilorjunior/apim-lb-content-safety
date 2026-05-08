"""Blocklist endpoint tests — verify path translation for the various
slug-style operations (`{name}:addOrUpdateBlocklistItems`, etc.) and that
PATCH/DELETE/GET on the same `{name}` route hit the right upstream path."""

from __future__ import annotations

import azure.functions as func
import httpx
import pytest

from function_app import (
    add_blocklist_items,
    blocklist_by_name,
    get_blocklist_item,
    list_blocklist_items,
    list_blocklists,
    remove_blocklist_items,
)


@pytest.mark.asyncio
async def test_list_blocklists(apim_mock) -> None:
    route = apim_mock.get(
        "/contentsafety/text/blocklists",
        params={"api-version": "2024-09-01"},
    ).mock(return_value=httpx.Response(200, json={"value": []}))

    req = func.HttpRequest(method="GET", url="/api/blocklists", body=b"", headers={})
    resp = await list_blocklists(req)

    assert route.called
    assert resp.status_code == 200


@pytest.mark.asyncio
async def test_upsert_blocklist_uses_patch(apim_mock) -> None:
    route = apim_mock.patch(
        "/contentsafety/text/blocklists/profanity",
        params={"api-version": "2024-09-01"},
    ).mock(return_value=httpx.Response(201, json={"blocklistName": "profanity"}))

    req = func.HttpRequest(
        method="PATCH",
        url="/api/blocklists/profanity",
        body=b'{"description":"bad words"}',
        headers={"content-type": "application/json"},
        route_params={"name": "profanity"},
    )
    resp = await blocklist_by_name(req)

    assert route.called
    assert resp.status_code == 201


@pytest.mark.asyncio
async def test_get_blocklist(apim_mock) -> None:
    route = apim_mock.get(
        "/contentsafety/text/blocklists/profanity",
        params={"api-version": "2024-09-01"},
    ).mock(return_value=httpx.Response(200, json={"blocklistName": "profanity"}))

    req = func.HttpRequest(
        method="GET",
        url="/api/blocklists/profanity",
        body=b"",
        headers={},
        route_params={"name": "profanity"},
    )
    resp = await blocklist_by_name(req)

    assert route.called
    assert resp.status_code == 200


@pytest.mark.asyncio
async def test_delete_blocklist(apim_mock) -> None:
    route = apim_mock.delete(
        "/contentsafety/text/blocklists/profanity",
        params={"api-version": "2024-09-01"},
    ).mock(return_value=httpx.Response(204))

    req = func.HttpRequest(
        method="DELETE",
        url="/api/blocklists/profanity",
        body=b"",
        headers={},
        route_params={"name": "profanity"},
    )
    resp = await blocklist_by_name(req)

    assert route.called
    assert resp.status_code == 204


@pytest.mark.asyncio
async def test_add_items_uses_slug_path(apim_mock) -> None:
    route = apim_mock.post(
        "/contentsafety/text/blocklists/profanity:addOrUpdateBlocklistItems",
        params={"api-version": "2024-09-01"},
    ).mock(return_value=httpx.Response(200, json={"blocklistItems": []}))

    req = func.HttpRequest(
        method="POST",
        url="/api/blocklists/profanity/items:add",
        body=b'{"blocklistItems":[{"text":"foo"}]}',
        headers={"content-type": "application/json"},
        route_params={"name": "profanity"},
    )
    resp = await add_blocklist_items(req)

    assert route.called
    assert resp.status_code == 200


@pytest.mark.asyncio
async def test_remove_items_uses_slug_path(apim_mock) -> None:
    route = apim_mock.post(
        "/contentsafety/text/blocklists/profanity:removeBlocklistItems",
        params={"api-version": "2024-09-01"},
    ).mock(return_value=httpx.Response(204))

    req = func.HttpRequest(
        method="POST",
        url="/api/blocklists/profanity/items:remove",
        body=b'{"blocklistItemIds":["abc"]}',
        headers={"content-type": "application/json"},
        route_params={"name": "profanity"},
    )
    resp = await remove_blocklist_items(req)

    assert route.called
    assert resp.status_code == 204


@pytest.mark.asyncio
async def test_list_blocklist_items(apim_mock) -> None:
    route = apim_mock.get(
        "/contentsafety/text/blocklists/profanity/blocklistItems",
        params={"api-version": "2024-09-01"},
    ).mock(return_value=httpx.Response(200, json={"value": []}))

    req = func.HttpRequest(
        method="GET",
        url="/api/blocklists/profanity/items",
        body=b"",
        headers={},
        route_params={"name": "profanity"},
    )
    resp = await list_blocklist_items(req)

    assert route.called
    assert resp.status_code == 200


@pytest.mark.asyncio
async def test_get_blocklist_item(apim_mock) -> None:
    route = apim_mock.get(
        "/contentsafety/text/blocklists/profanity/blocklistItems/item-1",
        params={"api-version": "2024-09-01"},
    ).mock(return_value=httpx.Response(200, json={"blocklistItemId": "item-1"}))

    req = func.HttpRequest(
        method="GET",
        url="/api/blocklists/profanity/items/item-1",
        body=b"",
        headers={},
        route_params={"name": "profanity", "itemId": "item-1"},
    )
    resp = await get_blocklist_item(req)

    assert route.called
    assert resp.status_code == 200


@pytest.mark.asyncio
async def test_idempotency_replay_passthrough(apim_mock) -> None:
    """Ensure X-Idempotent-Replay is forwarded back to the client."""
    apim_mock.patch(
        "/contentsafety/text/blocklists/p",
        params={"api-version": "2024-09-01"},
    ).mock(
        return_value=httpx.Response(
            201,
            json={"blocklistName": "p"},
            headers={
                "X-Idempotent-Replay": "true",
                "Location": "https://cs-pri/.../blocklists/p",
            },
        )
    )

    req = func.HttpRequest(
        method="PATCH",
        url="/api/blocklists/p",
        body=b"{}",
        headers={
            "content-type": "application/json",
            "idempotency-key": "k1",
        },
        route_params={"name": "p"},
    )
    resp = await blocklist_by_name(req)

    assert resp.status_code == 201
    assert resp.headers.get("x-idempotent-replay") == "true"
    assert resp.headers.get("location") == "https://cs-pri/.../blocklists/p"
