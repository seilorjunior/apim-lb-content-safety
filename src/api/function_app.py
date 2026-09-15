"""Azure Function App: thin proxy to APIM gateway.

Routes (all require a function key — `?code=<key>` or `x-functions-key`):
  GET  /api/health
  POST /api/analyze-text
  POST /api/analyze-image
  POST /api/detect-groundedness
  POST /api/detect-protected-material
  POST /api/shield-prompt
  GET  /api/blocklists
  PATCH/api/blocklists/{name}
  GET  /api/blocklists/{name}
  DEL  /api/blocklists/{name}
  POST /api/blocklists/{name}/items:add
  POST /api/blocklists/{name}/items:remove
  GET  /api/blocklists/{name}/items
  GET  /api/blocklists/{name}/items/{itemId}
"""

import asyncio
import hashlib
import json
import logging
import os
import re
from functools import lru_cache
from urllib.parse import parse_qsl, quote, urlsplit

import azure.functions as func
import httpx
from azure.identity import ManagedIdentityCredential
from azure.storage.blob import ContainerClient

from idempotency import BlobStore, Envelope, FingerprintConflict, InProgress, digest

# httpx logs every request URL (including query string) at INFO. Our caller-facing
# routes accept `?code=<function-key>` for FUNCTION auth, so leaving httpx at INFO
# would leak that key into App Insights traces. Drop httpx to WARNING; our own
# proxy log line (logs the path only, never the query string) still runs at INFO.
logging.getLogger("httpx").setLevel(logging.WARNING)

# ----------------------------------------------------------------------------
# Config
# ----------------------------------------------------------------------------

APIM_GATEWAY_URL = os.environ.get("APIM_GATEWAY_URL", "").rstrip("/")
APIM_SUBSCRIPTION_KEY = os.environ.get("APIM_SUBSCRIPTION_KEY", "")
API_VERSION = os.environ.get("CONTENT_SAFETY_API_VERSION", "2024-09-01")
PREVIEW_API_VERSION = os.environ.get(
    "CONTENT_SAFETY_PREVIEW_API_VERSION", "2024-09-15-preview"
)

# 10 MiB default; rejects oversized payloads early (also the documented
# Content Safety image hard limit). Override via env when domain rules differ.
MAX_REQUEST_BODY_BYTES = int(os.environ.get("MAX_REQUEST_BODY_BYTES", str(10 * 1024 * 1024)))

# APIM owns the entire retry budget. The Function always sends exactly once.
_READ_METHODS = frozenset({"GET", "HEAD", "OPTIONS"})
_PAGING_PARAMS = frozenset({"top", "maxpagesize", "skiptoken"})
_UPSTREAM_TOTAL_TIMEOUT_SECONDS = 60

_FORWARD_REQUEST_HEADERS = frozenset(
    {
        "content-type",
        "accept",
        "accept-encoding",
        "accept-language",
        "x-correlation-id",
        "traceparent",
        "tracestate",
    }
)
_FORWARD_RESPONSE_HEADERS = frozenset(
    {
        "content-type",
        "location",
        "x-correlation-id",
        "retry-after",
        "etag",
        "last-modified",
        "x-ms-request-id",
        "apim-request-id",
        "traceparent",
        "tracestate",
    }
)

# Module-level HTTP client - reused across invocations on the same worker.
# Bandit B113 misses the keyword-form timeout below; explicit suppression.
_HTTP_CLIENT = httpx.AsyncClient(  # nosec B113
    timeout=httpx.Timeout(60.0, connect=10.0),
    limits=httpx.Limits(max_keepalive_connections=20, max_connections=100),
)

app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)


# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------


def _filter_headers(headers, allowed):
    """Lowercase, filter, and dedupe headers to the allowed set."""
    out = {}
    for k, v in headers.items():
        lk = k.lower()
        if lk in allowed:
            out[lk] = v
    return out


def _build_url(path, preview=False):
    """Compose upstream URL + base query params (caller may merge inbound query)."""
    version = PREVIEW_API_VERSION if preview else API_VERSION
    return f"{APIM_GATEWAY_URL}/contentsafety{path}", {"api-version": version}


def _trace_headers(req):
    """Pick correlation/tracing headers from the inbound request for echo on errors."""
    out = {}
    for h in ("x-correlation-id", "traceparent", "tracestate"):
        v = req.headers.get(h)
        if v:
            out[h] = v
    return out


@lru_cache(maxsize=1)
def _idempotency_store():
    endpoint = os.environ["IDEMPOTENCY_BLOB_ENDPOINT"]
    container = os.environ["IDEMPOTENCY_CONTAINER"]
    if not endpoint.startswith("https://"):
        raise ValueError("Idempotency storage requires HTTPS")
    return BlobStore(
        ContainerClient(
            account_url=endpoint, container_name=container,
            credential=ManagedIdentityCredential(),
            retry_total=0, connection_timeout=10, read_timeout=30,
        ),
        ttl=int(os.environ.get("IDEMPOTENCY_TTL_SECONDS", "3600")),
    )


def _error(req, status, code, message, retry_after=False):
    headers = _trace_headers(req)
    if retry_after:
        headers["retry-after"] = "5"
    return func.HttpResponse(
        body=json.dumps({"code": code, "message": message}).encode(),
        status_code=status, mimetype="application/json", headers=headers,
    )


def _response(envelope, replay=False):
    headers = dict(envelope.headers)
    if replay:
        headers["x-idempotent-replay"] = "true"
    return func.HttpResponse(
        body=envelope.body, status_code=envelope.status, headers=headers,
        mimetype=headers.get("content-type", "application/json"),
    )


async def _proxy(req, method, path, preview=False):
    """Forward `req` to APIM and translate the response back."""
    if not APIM_GATEWAY_URL:
        return func.HttpResponse(
            body=b'{"code":"ConfigurationError","message":"APIM_GATEWAY_URL is not set"}',
            status_code=500,
            mimetype="application/json",
            headers=_trace_headers(req),
        )

    body = req.get_body() or None
    if body and len(body) > MAX_REQUEST_BODY_BYTES:
        return func.HttpResponse(
            body=json.dumps(
                {
                    "code": "PayloadTooLarge",
                    "message": (
                        f"Request body of {len(body)} bytes exceeds limit of "
                        f"{MAX_REQUEST_BODY_BYTES} bytes"
                    ),
                }
            ).encode("utf-8"),
            status_code=413,
            mimetype="application/json",
            headers=_trace_headers(req),
        )

    url, params = _build_url(path, preview=preview)
    # Only list operations support paging. Credentials and arbitrary query
    # parameters must never be copied into the upstream URL or fingerprint.
    if method == "GET" and (
        path == "/text/blocklists" or path.endswith("/blocklistItems")
    ):
        for k, v in parse_qsl(urlsplit(req.url).query, keep_blank_values=True):
            if k in _PAGING_PARAMS:
                params[k] = v

    fwd_headers = _filter_headers(dict(req.headers), _FORWARD_REQUEST_HEADERS)
    claim = None
    store = None
    key = req.headers.get("idempotency-key")
    if method not in _READ_METHODS and key is not None:
        if not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", key):
            return _error(req, 400, "InvalidIdempotencyKey",
                          "Idempotency-Key must match ^[A-Za-z0-9._-]{1,128}$")
        # FUNCTION auth exposes no verified individual principal. The boundary
        # is all holders of this Function's credentials, not caller-supplied
        # identity headers. Deploy separate Functions/storage for tenant isolation.
        scope = ["function-credentials", APIM_GATEWAY_URL, method, path, params["api-version"]]
        fingerprint = digest([
            params, hashlib.sha256(body or b"").hexdigest(),
            {k: v for k, v in fwd_headers.items() if k in {
                "content-type", "accept", "accept-encoding", "accept-language",
            }},
        ])
        try:
            store = _idempotency_store()
            claim = await asyncio.to_thread(store.claim, scope, key, fingerprint)
        except InProgress:
            return _error(req, 409, "IdempotencyInFlight",
                          "Operation is in progress or requires reconciliation", retry_after=True)
        except FingerprintConflict:
            return _error(req, 422, "IdempotencyKeyConflict",
                          "Idempotency-Key was already used with a different request")
        except Exception:
            logging.error("Idempotency claim unavailable; no upstream request sent")
            return _error(req, 503, "IdempotencyUnavailable",
                          "Durable coordination unavailable", retry_after=True)
        if isinstance(claim, Envelope):
            return _response(claim, replay=True)

    if APIM_SUBSCRIPTION_KEY:
        fwd_headers["ocp-apim-subscription-key"] = APIM_SUBSCRIPTION_KEY

    # Log path only (no query string) to avoid leaking caller-supplied secrets.
    logging.info(
        "Proxying %s %s -> %s (body=%d bytes)",
        method,
        urlsplit(req.url).path,
        url,
        len(body) if body else 0,
    )

    try:
        async with asyncio.timeout(_UPSTREAM_TOTAL_TIMEOUT_SECONDS):
            upstream = await _HTTP_CLIENT.request(
                method=method,
                url=url,
                params=params,
                content=body,
                headers=fwd_headers,
            )
    except (httpx.HTTPError, TimeoutError):
        logging.error("APIM upstream call failed; outcome may be unknown")
        failure = _error(req, 502, "UpstreamFailure", "Upstream outcome is unknown")
        envelope = Envelope(502, failure.get_body(), dict(failure.headers))
        definitive = False
    else:
        envelope = Envelope(
            upstream.status_code, upstream.content,
            _filter_headers(upstream.headers, _FORWARD_RESPONSE_HEADERS),
        )
        # Accepted async work, gateway/server failures and request timeouts do
        # not establish a final mutation outcome. Replay them without expiry.
        definitive = upstream.status_code < 500 and upstream.status_code not in {202, 408}

    if claim is not None:
        try:
            await asyncio.to_thread(store.complete, claim, envelope, definitive)
        except Exception:
            logging.error("Idempotency completion unavailable; claim retained for reconciliation")
            return _error(req, 503, "IdempotencyUnavailable",
                          "Outcome could not be durably recorded; do not use a new key",
                          retry_after=True)
    return _response(envelope)


# ----------------------------------------------------------------------------
# Health
# ----------------------------------------------------------------------------


@app.route(route="health", methods=["GET"])
async def health(req: func.HttpRequest) -> func.HttpResponse:
    payload = {
        "status": "ok",
        "apim_configured": bool(APIM_GATEWAY_URL),
        "api_version": API_VERSION,
        "preview_api_version": PREVIEW_API_VERSION,
    }
    return func.HttpResponse(
        body=json.dumps(payload).encode("utf-8"),
        status_code=200,
        mimetype="application/json",
    )


# ----------------------------------------------------------------------------
# Stateless analyze endpoints
# ----------------------------------------------------------------------------


@app.route(route="analyze-text", methods=["POST"])
async def analyze_text(req: func.HttpRequest) -> func.HttpResponse:
    return await _proxy(req, "POST", "/text:analyze")


@app.route(route="analyze-image", methods=["POST"])
async def analyze_image(req: func.HttpRequest) -> func.HttpResponse:
    return await _proxy(req, "POST", "/image:analyze")


@app.route(route="detect-groundedness", methods=["POST"])
async def detect_groundedness(req: func.HttpRequest) -> func.HttpResponse:
    return await _proxy(req, "POST", "/text:detectGroundedness", preview=True)


@app.route(route="detect-protected-material", methods=["POST"])
async def detect_protected_material(req: func.HttpRequest) -> func.HttpResponse:
    return await _proxy(req, "POST", "/text:detectProtectedMaterial")


@app.route(route="shield-prompt", methods=["POST"])
async def shield_prompt(req: func.HttpRequest) -> func.HttpResponse:
    return await _proxy(req, "POST", "/text:shieldPrompt")


# ----------------------------------------------------------------------------
# Blocklist endpoints
# ----------------------------------------------------------------------------


@app.route(route="blocklists", methods=["GET"])
async def list_blocklists(req: func.HttpRequest) -> func.HttpResponse:
    return await _proxy(req, "GET", "/text/blocklists")


@app.route(route="blocklists/{name}", methods=["PATCH", "GET", "DELETE"])
async def blocklist_by_name(req: func.HttpRequest) -> func.HttpResponse:
    name = quote(req.route_params.get("name", ""), safe="")
    return await _proxy(req, req.method, f"/text/blocklists/{name}")


@app.route(route="blocklists/{name}/items:add", methods=["POST"])
async def add_blocklist_items(req: func.HttpRequest) -> func.HttpResponse:
    name = quote(req.route_params.get("name", ""), safe="")
    return await _proxy(req, "POST", f"/text/blocklists/{name}:addOrUpdateBlocklistItems")


@app.route(route="blocklists/{name}/items:remove", methods=["POST"])
async def remove_blocklist_items(req: func.HttpRequest) -> func.HttpResponse:
    name = quote(req.route_params.get("name", ""), safe="")
    return await _proxy(req, "POST", f"/text/blocklists/{name}:removeBlocklistItems")


@app.route(route="blocklists/{name}/items", methods=["GET"])
async def list_blocklist_items(req: func.HttpRequest) -> func.HttpResponse:
    name = quote(req.route_params.get("name", ""), safe="")
    return await _proxy(req, "GET", f"/text/blocklists/{name}/blocklistItems")


@app.route(route="blocklists/{name}/items/{itemId}", methods=["GET"])
async def get_blocklist_item(req: func.HttpRequest) -> func.HttpResponse:
    name = quote(req.route_params.get("name", ""), safe="")
    item_id = quote(req.route_params.get("itemId", ""), safe="")
    return await _proxy(req, "GET", f"/text/blocklists/{name}/blocklistItems/{item_id}")
