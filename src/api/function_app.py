"""Azure Function App: thin proxy to APIM gateway.

Routes (anonymous):
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

import json
import logging
import os

import azure.functions as func
import httpx

# ----------------------------------------------------------------------------
# Config
# ----------------------------------------------------------------------------

APIM_GATEWAY_URL = os.environ.get("APIM_GATEWAY_URL", "").rstrip("/")
API_VERSION = os.environ.get("CONTENT_SAFETY_API_VERSION", "2024-09-01")
PREVIEW_API_VERSION = os.environ.get(
    "CONTENT_SAFETY_PREVIEW_API_VERSION", "2024-09-15-preview"
)

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
_HTTP_CLIENT = httpx.Client(
    timeout=httpx.Timeout(60.0, connect=10.0),
    limits=httpx.Limits(max_keepalive_connections=20, max_connections=100),
)

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)


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
    version = PREVIEW_API_VERSION if preview else API_VERSION
    return f"{APIM_GATEWAY_URL}/contentsafety{path}?api-version={version}"


def _proxy(req, method, path, preview=False):
    """Forward `req` to APIM and translate the response back."""
    if not APIM_GATEWAY_URL:
        return func.HttpResponse(
            body=b'{"code":"ConfigurationError","message":"APIM_GATEWAY_URL is not set"}',
            status_code=500,
            mimetype="application/json",
        )

    url = _build_url(path, preview=preview)
    body = req.get_body() or None
    fwd_headers = _filter_headers(dict(req.headers), _FORWARD_REQUEST_HEADERS)

    logging.info("Proxying %s %s -> %s (body=%d bytes)", method, req.url, url, len(body) if body else 0)

    try:
        upstream = _HTTP_CLIENT.request(
            method=method,
            url=url,
            content=body,
            headers=fwd_headers,
        )
    except httpx.HTTPError as ex:
        logging.exception("APIM upstream call failed")
        return func.HttpResponse(
            body=json.dumps({"code": "UpstreamFailure", "message": str(ex)}).encode("utf-8"),
            status_code=502,
            mimetype="application/json",
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
def health(req: func.HttpRequest) -> func.HttpResponse:
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
def analyze_text(req: func.HttpRequest) -> func.HttpResponse:
    return _proxy(req, "POST", "/text:analyze")


@app.route(route="analyze-image", methods=["POST"])
def analyze_image(req: func.HttpRequest) -> func.HttpResponse:
    return _proxy(req, "POST", "/image:analyze")


@app.route(route="detect-groundedness", methods=["POST"])
def detect_groundedness(req: func.HttpRequest) -> func.HttpResponse:
    return _proxy(req, "POST", "/text:detectGroundedness", preview=True)


@app.route(route="detect-protected-material", methods=["POST"])
def detect_protected_material(req: func.HttpRequest) -> func.HttpResponse:
    return _proxy(req, "POST", "/text:detectProtectedMaterial")


@app.route(route="shield-prompt", methods=["POST"])
def shield_prompt(req: func.HttpRequest) -> func.HttpResponse:
    return _proxy(req, "POST", "/text:shieldPrompt")


# ----------------------------------------------------------------------------
# Blocklist endpoints
# ----------------------------------------------------------------------------


@app.route(route="blocklists", methods=["GET"])
def list_blocklists(req: func.HttpRequest) -> func.HttpResponse:
    return _proxy(req, "GET", "/text/blocklists")


@app.route(route="blocklists/{name}", methods=["PATCH", "GET", "DELETE"])
def blocklist_by_name(req: func.HttpRequest) -> func.HttpResponse:
    name = req.route_params.get("name", "")
    return _proxy(req, req.method, f"/text/blocklists/{name}")


@app.route(route="blocklists/{name}/items:add", methods=["POST"])
def add_blocklist_items(req: func.HttpRequest) -> func.HttpResponse:
    name = req.route_params.get("name", "")
    return _proxy(req, "POST", f"/text/blocklists/{name}:addOrUpdateBlocklistItems")


@app.route(route="blocklists/{name}/items:remove", methods=["POST"])
def remove_blocklist_items(req: func.HttpRequest) -> func.HttpResponse:
    name = req.route_params.get("name", "")
    return _proxy(req, "POST", f"/text/blocklists/{name}:removeBlocklistItems")


@app.route(route="blocklists/{name}/items", methods=["GET"])
def list_blocklist_items(req: func.HttpRequest) -> func.HttpResponse:
    name = req.route_params.get("name", "")
    return _proxy(req, "GET", f"/text/blocklists/{name}/blocklistItems")


@app.route(route="blocklists/{name}/items/{itemId}", methods=["GET"])
def get_blocklist_item(req: func.HttpRequest) -> func.HttpResponse:
    name = req.route_params.get("name", "")
    item_id = req.route_params.get("itemId", "")
    return _proxy(req, "GET", f"/text/blocklists/{name}/blocklistItems/{item_id}")
