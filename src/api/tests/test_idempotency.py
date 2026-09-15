"""Offline durable coordination tests, including concurrent independent workers."""

import asyncio
import json
import threading
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import Mock

import azure.functions as func
import httpx
import pytest
from azure.core.exceptions import ResourceModifiedError
from azure.core.pipeline.transport import HttpResponse
from azure.storage.blob import ContainerClient

import function_app
from idempotency import BlobStore, Claim, Envelope, FingerprintConflict, InProgress


def request(body=b"{}", key="same-key", headers=None):
    return func.HttpRequest(
        method="PATCH", url="/api/blocklists/a", body=body,
        headers={"idempotency-key": key, "content-type": "application/json", **(headers or {})},
        route_params={"name": "a"},
    )


@pytest.mark.parametrize("status,body", [(201, b'{ "created":true }'), (204, b""),
                                       (400, b"bad"), (429, b"limited"), (503, b"\x00\xff")])
async def test_response_envelope_replayed_exactly(
    apim_mock, durable_store, monkeypatch, status, body,
):
    headers = {
        "content-type": "application/octet-stream", "location": "/resources/a",
        "retry-after": "9", "etag": '"v1"', "last-modified": "Wed, 01 Jan 2025 00:00:00 GMT",
        "x-correlation-id": "original", "set-cookie": "not-replayed",
        "x-ms-request-id": "request-id", "apim-request-id": "apim-id",
        "traceparent": "original-trace", "tracestate": "original-state",
    }
    route = apim_mock.patch("/contentsafety/text/blocklists/a").mock(
        return_value=httpx.Response(status, content=body, headers=headers),
    )
    first = await function_app.blocklist_by_name(request())
    # A new worker uses the same durable container, not any local replay cache.
    monkeypatch.setattr(
        function_app, "_idempotency_store",
        lambda: BlobStore(durable_store.container, ttl=60),
    )
    replay = await function_app.blocklist_by_name(request(headers={"x-correlation-id": "new"}))
    assert route.call_count == 1
    assert first.status_code == replay.status_code == status
    assert first.get_body() == replay.get_body() == body
    assert dict(replay.headers) == {**dict(first.headers), "x-idempotent-replay": "true"}
    assert "set-cookie" not in replay.headers
    assert replay.headers["x-correlation-id"] == "original"
    assert len(durable_store.container.records) == 1
    serialized = json.loads(next(iter(durable_store.container.records.values()))[0])
    assert serialized["response"]["status"] == status
    assert "same-key" not in next(iter(durable_store.container.records))


async def test_concurrent_requests_only_one_upstream_call(apim_mock):
    entered, finish = asyncio.Event(), asyncio.Event()

    async def delayed(_):
        entered.set()
        await asyncio.wait_for(finish.wait(), timeout=5)
        return httpx.Response(201, content=b"created")

    route = apim_mock.patch("/contentsafety/text/blocklists/a").mock(side_effect=delayed)
    winner = asyncio.create_task(function_app.blocklist_by_name(request()))
    try:
        await asyncio.wait_for(entered.wait(), timeout=5)
        responses = await asyncio.wait_for(
            asyncio.gather(*[function_app.blocklist_by_name(request()) for _ in range(12)]),
            timeout=5,
        )
        assert all(response.status_code == 409 for response in responses)
        assert all(response.headers["retry-after"] == "5" for response in responses)
        assert all(
            json.loads(response.get_body())["code"] == "IdempotencyInFlight"
            for response in responses
        )
        conflict = await function_app.blocklist_by_name(request(body=b'{"different":true}'))
        assert conflict.status_code == 422
    finally:
        finish.set()
        result = await asyncio.wait_for(winner, timeout=5)
    assert result.status_code == 201
    assert route.call_count == 1


@pytest.mark.parametrize("headers,body", [
    ({}, b"changed"), ({"content-type": "text/plain"}, b"{}"),
    ({"accept": "text/plain"}, b"{}"), ({"accept-language": "fr"}, b"{}"),
])
async def test_conflicting_fingerprints_return_422(apim_mock, headers, body):
    route = apim_mock.patch("/contentsafety/text/blocklists/a").mock(
        return_value=httpx.Response(200),
    )
    await function_app.blocklist_by_name(request())
    response = await function_app.blocklist_by_name(request(body=body, headers=headers))
    assert response.status_code == 422
    assert json.loads(response.get_body())["code"] == "IdempotencyKeyConflict"
    assert route.call_count == 1


async def test_scope_includes_method_resource_operation_and_version(apim_mock, monkeypatch):
    route = apim_mock.route().mock(return_value=httpx.Response(200))
    req = request()
    for method, path in [
        ("PATCH", "/text/blocklists/a"), ("DELETE", "/text/blocklists/a"),
        ("PATCH", "/text/blocklists/b"),
        ("POST", "/text/blocklists/a:addOrUpdateBlocklistItems"),
        ("POST", "/text/blocklists/a:removeBlocklistItems"),
    ]:
        assert (await function_app._proxy(req, method, path)).status_code == 200
    monkeypatch.setattr(function_app, "API_VERSION", "future-version")
    assert (await function_app._proxy(req, "PATCH", "/text/blocklists/a")).status_code == 200
    assert route.call_count == 6


async def test_untrusted_identity_headers_cannot_bypass_shared_boundary(apim_mock):
    route = apim_mock.patch("/contentsafety/text/blocklists/a").mock(
        return_value=httpx.Response(200),
    )
    await function_app.blocklist_by_name(request(headers={
        "x-ms-client-principal-id": "caller-a", "x-functions-key": "credential-a",
    }))
    replay = await function_app.blocklist_by_name(request(headers={
        "x-ms-client-principal-id": "caller-b", "x-functions-key": "credential-b",
    }))
    assert replay.headers["x-idempotent-replay"] == "true"
    assert route.call_count == 1


async def test_completed_expiry_allows_new_request_via_cas(apim_mock, durable_store):
    clock = [100.0]
    durable_store.clock = lambda: clock[0]
    route = apim_mock.patch("/contentsafety/text/blocklists/a").mock(
        return_value=httpx.Response(201),
    )
    await function_app.blocklist_by_name(request())
    clock[0] = 159
    replay = await function_app.blocklist_by_name(request())
    assert replay.headers["x-idempotent-replay"] == "true"
    clock[0] = 160
    response = await function_app.blocklist_by_name(request(body=b"new"))
    assert response.status_code == 201
    assert "x-idempotent-replay" not in response.headers
    assert route.call_count == 2


def test_expired_reclaim_race_is_atomic(durable_store):
    store = durable_store
    store.clock = lambda: 100
    old_claim = store.claim("scope", "key", "old")
    store.complete(old_claim, Envelope(200, b"old", {}))
    workers = 8
    barrier = threading.Barrier(workers, timeout=5)
    store.container.before_replace = barrier.wait
    store.clock = lambda: 160

    def reclaim(_):
        independent = BlobStore(store.container, ttl=60, clock=store.clock)
        try:
            return independent.claim("scope", "key", "new")
        except InProgress:
            return None

    with ThreadPoolExecutor(max_workers=workers) as pool:
        claims = list(pool.map(reclaim, range(workers)))
    assert sum(isinstance(claim, Claim) for claim in claims) == 1
    store.container.before_replace = None
    with pytest.raises(ResourceModifiedError):
        store.complete(old_claim, Envelope(200, b"stale", {}))


@pytest.mark.parametrize("status", [202, 408, 500, 502, 503, 504])
async def test_ambiguous_http_results_never_expire(apim_mock, durable_store, status):
    clock = [100.0]
    durable_store.clock = lambda: clock[0]
    route = apim_mock.patch("/contentsafety/text/blocklists/a").mock(
        return_value=httpx.Response(status, content=b"original failure"),
    )
    first = await function_app.blocklist_by_name(request())
    clock[0] += 10_000_000
    replay = await function_app.blocklist_by_name(request())
    assert replay.status_code == first.status_code == status
    assert replay.get_body() == b"original failure"
    assert route.call_count == 1
    assert "expires_at" not in json.loads(next(iter(durable_store.container.records.values()))[0])


async def test_transport_unknown_never_expires(apim_mock, durable_store):
    clock = [100.0]
    durable_store.clock = lambda: clock[0]
    route = apim_mock.patch("/contentsafety/text/blocklists/a").mock(
        side_effect=httpx.ReadTimeout("mutation may have committed"),
    )
    first = await function_app.blocklist_by_name(request())
    clock[0] += 10_000_000
    replay = await function_app.blocklist_by_name(request())
    assert replay.status_code == first.status_code == 502
    assert replay.get_body() == first.get_body()
    assert route.call_count == 1


async def test_worker_cancellation_leaves_permanent_claim(apim_mock, durable_store):
    entered = asyncio.Event()
    attempts = []

    async def crash(_):
        attempts.append(1)
        entered.set()
        await asyncio.wait_for(asyncio.Event().wait(), timeout=5)

    apim_mock.patch("/contentsafety/text/blocklists/a").mock(side_effect=crash)
    task = asyncio.create_task(function_app.blocklist_by_name(request()))
    try:
        await asyncio.wait_for(entered.wait(), timeout=5)
    finally:
        task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await asyncio.wait_for(task, timeout=5)
    durable_store.clock = lambda: 10**12
    response = await function_app.blocklist_by_name(request())
    assert response.status_code == 409
    assert len(attempts) == 1


async def test_storage_failure_before_claim_fails_closed(apim_mock, durable_store):
    durable_store.container.fail_write = True
    response = await function_app.blocklist_by_name(request())
    assert response.status_code == 503
    assert not apim_mock.calls


async def test_completion_failure_retains_claim(apim_mock, durable_store):
    def committed(_):
        durable_store.container.fail_write = True
        return httpx.Response(201)

    route = apim_mock.patch("/contentsafety/text/blocklists/a").mock(side_effect=committed)
    response = await function_app.blocklist_by_name(request())
    assert response.status_code == 503
    durable_store.container.fail_write = False
    durable_store.clock = lambda: 10**12
    assert (await function_app.blocklist_by_name(request())).status_code == 409
    assert route.call_count == 1


async def test_lost_completion_ack_can_replay_saved_result(apim_mock, durable_store, monkeypatch):
    original = durable_store.complete

    def lost_response(*args):
        original(*args)
        raise OSError("completion saved but acknowledgement lost")

    monkeypatch.setattr(durable_store, "complete", lost_response)
    route = apim_mock.patch("/contentsafety/text/blocklists/a").mock(
        return_value=httpx.Response(201, content=b"created"),
    )
    assert (await function_app.blocklist_by_name(request())).status_code == 503
    replay = await function_app.blocklist_by_name(request())
    assert replay.status_code == 201
    assert replay.get_body() == b"created"
    assert replay.headers["x-idempotent-replay"] == "true"
    assert route.call_count == 1


async def test_ambiguous_claim_write_never_sends_upstream(apim_mock, durable_store, monkeypatch):
    original = durable_store.claim

    def lost_response(*args):
        original(*args)
        raise OSError("claim succeeded but acknowledgement lost")

    monkeypatch.setattr(durable_store, "claim", lost_response)
    assert (await function_app.blocklist_by_name(request())).status_code == 503
    monkeypatch.setattr(durable_store, "claim", original)
    assert (await function_app.blocklist_by_name(request())).status_code == 409
    assert not apim_mock.calls


@pytest.mark.parametrize("key", [
    "", " ", "with space", "é", "a" * 129, "a" * 257, "a/b", "key!", "a\n",
])
async def test_invalid_keys_rejected_before_upstream(apim_mock, key):
    response = await function_app.blocklist_by_name(request(key=key))
    assert response.status_code == 400
    assert json.loads(response.get_body())["code"] == "InvalidIdempotencyKey"
    assert not apim_mock.calls


@pytest.mark.parametrize("key", ["a", "A9._-", "a" * 128])
async def test_valid_key_contract_boundaries(apim_mock, key):
    route = apim_mock.patch("/contentsafety/text/blocklists/a").mock(
        return_value=httpx.Response(200),
    )
    assert (await function_app.blocklist_by_name(request(key=key))).status_code == 200
    assert route.call_count == 1


async def test_total_upstream_deadline_is_durable_unknown(apim_mock, durable_store, monkeypatch):
    attempts = []
    monkeypatch.setattr(function_app, "_UPSTREAM_TOTAL_TIMEOUT_SECONDS", 0.01)

    async def slow_stream(_):
        attempts.append(1)
        await asyncio.wait_for(asyncio.Event().wait(), timeout=10)

    apim_mock.patch("/contentsafety/text/blocklists/a").mock(side_effect=slow_stream)
    first = await asyncio.wait_for(function_app.blocklist_by_name(request()), timeout=5)
    assert first.status_code == 502
    durable_store.clock = lambda: 10**12
    replay = await function_app.blocklist_by_name(request())
    assert replay.status_code == 502
    assert replay.headers["x-idempotent-replay"] == "true"
    assert replay.get_body() == first.get_body()
    assert len(attempts) == 1


def test_pending_never_expires_and_conflicts_stay_conflicts(durable_store):
    durable_store.claim("scope", "key", "first")
    durable_store.clock = lambda: 10**12
    with pytest.raises(InProgress):
        durable_store.claim("scope", "key", "first")
    with pytest.raises(FingerprintConflict):
        durable_store.claim("scope", "key", "other")


def test_corrupt_record_fails_closed(durable_store):
    claim = durable_store.claim("scope", "key", "fp")
    durable_store.container.records[claim.name] = (b"invalid", claim.etag)
    with pytest.raises(ValueError):
        durable_store.claim("scope", "key", "fp")


@pytest.mark.parametrize("record", [
    {"version": 2}, {"version": 1, "state": "invalid", "fingerprint": "fp"},
])
def test_unknown_schema_or_state_fails_closed(durable_store, record):
    claim = durable_store.claim("scope", "key", "fp")
    durable_store.container.records[claim.name] = (json.dumps(record).encode(), claim.etag)
    with pytest.raises(ValueError):
        durable_store.claim("scope", "key", "fp")


@pytest.mark.parametrize("ttl", [59, 604801])
def test_unsafe_ttl_configuration_rejected(durable_store, ttl):
    with pytest.raises(ValueError):
        BlobStore(durable_store.container, ttl)


def test_missing_etag_cannot_grant_ownership():
    with pytest.raises(ValueError):
        Claim("name", "", "fp")


def test_managed_identity_storage_configuration(monkeypatch):
    # Retrieve the production factory despite the offline fixture override.
    from functools import lru_cache

    factory = lru_cache(maxsize=1)(_production_factory)
    monkeypatch.setenv("IDEMPOTENCY_BLOB_ENDPOINT", "https://storage.blob.core.windows.net")
    monkeypatch.setenv("IDEMPOTENCY_CONTAINER", "idempotency")
    monkeypatch.setenv("IDEMPOTENCY_TTL_SECONDS", "120")
    credential = Mock()
    client = Mock()
    monkeypatch.setattr(function_app, "ManagedIdentityCredential", credential)
    monkeypatch.setattr(function_app, "ContainerClient", client)
    store = factory()
    assert store.ttl == 120
    assert client.call_args.kwargs["credential"] is credential.return_value
    assert client.call_args.kwargs["retry_total"] == 0
    assert client.call_args.kwargs["container_name"] == "idempotency"
    assert factory() is store


_production_factory = function_app._idempotency_store.__wrapped__


def test_non_https_storage_configuration_rejected(monkeypatch):
    monkeypatch.setenv("IDEMPOTENCY_BLOB_ENDPOINT", "http://storage.blob.core.windows.net")
    monkeypatch.setenv("IDEMPOTENCY_CONTAINER", "idempotency")
    with pytest.raises(ValueError):
        _production_factory()


def test_sdk_emits_conditional_create_and_compare_and_swap():
    """Verify SDK wire conditions, not only the in-memory store's interpretation."""
    captured = []

    class Response(HttpResponse):
        def body(self):
            return b""

    def send(req, **kwargs):
        captured.append(req)
        response = Response(req, None)
        response.status_code = 201
        response.headers = httpx.Headers({
            "etag": f'"v{len(captured)}"',
            "last-modified": "Wed, 01 Jan 2025 00:00:00 GMT",
            "x-ms-request-id": "test",
        })
        return response

    transport = Mock()
    transport.send.side_effect = send
    container = ContainerClient(
        "https://storage.blob.core.windows.net", "idempotency",
        credential=None, transport=transport, retry_total=0,
    )
    store = BlobStore(container, 60)
    claim = store.claim("scope", "key", "fp")
    store.complete(claim, Envelope(201, b"body", {"location": "/new"}))
    assert len(captured) == 2
    assert captured[0].headers["If-None-Match"] == "*"
    assert captured[1].headers["If-Match"] == '"v1"'
    assert "If-None-Match" not in captured[1].headers
    assert json.loads(captured[1].body)["response"]["status"] == 201
