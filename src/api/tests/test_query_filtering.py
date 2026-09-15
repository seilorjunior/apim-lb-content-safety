"""Only supported list pagination and server-configured API versions reach APIM."""

import azure.functions as func
import httpx
import pytest

import function_app


@pytest.mark.parametrize("path", ["/text/blocklists", "/text/blocklists/name/blocklistItems"])
async def test_only_paging_params_pass(apim_mock, path):
    route = apim_mock.get(f"/contentsafety{path}").mock(return_value=httpx.Response(200))
    req = func.HttpRequest(
        method="GET", body=b"",
        url="/api/blocklists?code=secret&Code=secret&subscription-key=evil"
            "&ocp-apim-subscription-key=evil&api-version=evil&API-VERSION=evil"
            "&top=10&maxpagesize=20&skiptoken=a%2Bb%3D%26c&unknown=value",
    )
    await function_app._proxy(req, "GET", path)
    assert dict(route.calls.last.request.url.params) == {
        "api-version": "2024-09-01", "top": "10", "maxpagesize": "20", "skiptoken": "a+b=&c",
    }


@pytest.mark.parametrize("method,path", [
    ("POST", "/text:analyze"), ("PATCH", "/text/blocklists/name"),
    ("GET", "/text/blocklists/name"), ("DELETE", "/text/blocklists/name"),
])
async def test_paging_not_forwarded_to_other_operations(apim_mock, method, path):
    route = apim_mock.request(method, f"/contentsafety{path}").mock(
        return_value=httpx.Response(200),
    )
    req = func.HttpRequest(
        method=method, body=b"", url="/api/x?top=10&skiptoken=abc&maxpagesize=20&code=secret",
    )
    await function_app._proxy(req, method, path)
    assert dict(route.calls.last.request.url.params) == {"api-version": "2024-09-01"}


async def test_credentials_and_ignored_queries_do_not_change_fingerprint(apim_mock):
    route = apim_mock.patch("/contentsafety/text/blocklists/a").mock(
        return_value=httpx.Response(200),
    )
    for query in ("code=first&top=10", "code=second&top=20&subscription-key=other"):
        req = func.HttpRequest(
            method="PATCH", body=b"{}", url=f"/api/blocklists/a?{query}",
            headers={"idempotency-key": "key"},
        )
        assert (await function_app._proxy(req, "PATCH", "/text/blocklists/a")).status_code == 200
    assert route.call_count == 1
