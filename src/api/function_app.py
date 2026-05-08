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
import json
import logging
import os
from urllib.parse import parse_qsl, quote, urlsplit

import azure.functions as func
import httpx

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

# Retry transient APIM-side failures. We retry only when the upstream call is
# safe to repeat: idempotent HTTP methods, OR any method that carries an
# Idempotency-Key (the APIM policy contract guarantees replay-safety).
_RETRY_STATUS = frozenset({502, 503, 504})
_IDEMPOTENT_METHODS = frozenset({"GET", "HEAD", "OPTIONS"})
_RETRY_MAX_ATTEMPTS = 3
_RETRY_BACKOFF_BASE_SECONDS = 0.25

_FORWARD_REQUEST_HEADERS = frozenset(
    {
        "content-type",
        "accept",
        "accept-encoding",
        "accept-language",
        "idempotency-key",
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
        "x-idempotent-replay",
        "retry-after",
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


def _is_retry_safe(method: str, headers) -> bool:
    """Retry only when the upstream call is replay-safe.

    True for idempotent HTTP methods, OR any method that carries an
    Idempotency-Key (the APIM policy contract guarantees replay-safety).
    """
    if method.upper() in _IDEMPOTENT_METHODS:
        return True
    return any(k.lower() == "idempotency-key" for k in headers)


async def _request_with_retry(method, url, params, content, headers, retry_safe):
    """Execute the upstream call with bounded exponential backoff on transient failures."""
    last_exc: BaseException | None = None
    last_resp: httpx.Response | None = None

    attempts = _RETRY_MAX_ATTEMPTS if retry_safe else 1
    for attempt in range(attempts):
        try:
            resp = await _HTTP_CLIENT.request(
                method=method,
                url=url,
                params=params,
                content=content,
                headers=headers,
            )
        except (httpx.ConnectError, httpx.ReadTimeout, httpx.WriteTimeout) as ex:
            last_exc = ex
            if attempt + 1 == attempts:
                raise
        else:
            last_resp = resp
            if resp.status_code not in _RETRY_STATUS or attempt + 1 == attempts:
                return resp
            logging.info(
                "Upstream %s on attempt %d/%d; retrying", resp.status_code, attempt + 1, attempts
            )

        # Exponential backoff: 0.25, 0.5 (max attempt index = 1 when attempts=3)
        await asyncio.sleep(_RETRY_BACKOFF_BASE_SECONDS * (2**attempt))

    # Defensive: loop exits via return or raise; last_resp is the most recent
    # response when retries exhausted on retryable status.
    if last_resp is not None:
        return last_resp
    if last_exc is not None:  # pragma: no cover - belt-and-suspenders
        raise last_exc
    raise RuntimeError("retry loop exited without a response")  # pragma: no cover


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
    # Merge inbound query string so server-side paging (top/skiptoken/...) reaches APIM.
    # `api-version` is sourced from server config and cannot be overridden by the caller.
    inbound = urlsplit(req.url).query
    if inbound:
        for k, v in parse_qsl(inbound, keep_blank_values=True):
            if k.lower() != "api-version":
                params[k] = v

    fwd_headers = _filter_headers(dict(req.headers), _FORWARD_REQUEST_HEADERS)
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
        upstream = await _request_with_retry(
            method=method,
            url=url,
            params=params,
            content=body,
            headers=fwd_headers,
            retry_safe=_is_retry_safe(method, req.headers),
        )
    except httpx.HTTPError as ex:
        logging.exception("APIM upstream call failed")
        err_headers = _trace_headers(req)
        return func.HttpResponse(
            body=json.dumps({"code": "UpstreamFailure", "message": str(ex)}).encode("utf-8"),
            status_code=502,
            mimetype="application/json",
            headers=err_headers,
        )

    resp_headers = _filter_headers(upstream.headers, _FORWARD_RESPONSE_HEADERS)
    return func.HttpResponse(
        body=upstream.content,
        status_code=upstream.status_code,
        headers=resp_headers,
        mimetype=resp_headers.get("content-type", "application/json"),
    )


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
