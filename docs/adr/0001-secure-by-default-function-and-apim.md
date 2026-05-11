# ADR 0001: Secure-by-default Function App and APIM gateway

- **Status:** Accepted
- **Date:** 2025-01
- **Decision Drivers:** code review of the deployed surface flagged production
  red-flag defects: the Function App accepted anonymous requests, browser CORS
  was wide open (`allowedOrigins: ['*']`), the APIM API did not require a
  subscription key, and the function had no upper bound on request body size or
  upstream retry policy.

## Context

Initial deployments of the APIM-fronted Content Safety load balancer prioritised
"works end-to-end with `azd up`" and deferred hardening to a later iteration.
The README documented the gaps but the configuration itself was not safe to
expose to untrusted callers:

1. `func.AuthLevel.ANONYMOUS` on every Function route — anyone with the
   hostname could invoke Content Safety analysis.
2. `cors.allowedOrigins: ['*']` on the Function App — any browser origin could
   call the proxy with credentials.
3. `subscriptionRequired: false` on the APIM API — the policy chain (rate
   limit, blocklist, idempotency) was the only gate.
4. No body-size cap on the Function — a single 100 MiB POST could pin a worker
   for the full 60-second upstream timeout.
5. No retry policy on transient APIM 5xx responses — a single backend hiccup
   surfaced as a 502 to the caller even when retry would have been safe.

## Decision

Adopt a **server-to-server-only** posture by default, opt-in to browser usage
via explicit configuration, and bound all upstream interactions:

| Concern                      | Decision                                                                                                                                                                       |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Function authentication      | `func.AuthLevel.FUNCTION` on every route. Callers must present `x-functions-key` (header) or `?code=` (query). The default host key is rotated by Azure and stored encrypted.  |
| APIM authentication          | `subscriptionRequired: true` on the `content-safety` API. A single per-API subscription resource named `function-app` is provisioned by Bicep and bound to the API scope.      |
| Function → APIM credential   | The function reads the subscription primary key at deploy time via `apimSubscription.listSecrets().primaryKey` and forwards it as `Ocp-Apim-Subscription-Key` on every call.   |
| Browser CORS                 | `corsAllowedOrigins` defaults to `[]` (no browser origins). Operators add specific origins via `AZURE_CORS_ALLOWED_ORIGINS`. Wildcard is no longer the default.                |
| Body-size cap                | `MAX_REQUEST_BODY_BYTES` (default 10 MiB, matches Content Safety's image hard limit). Bodies above the cap are rejected with `413 PayloadTooLarge` before any upstream call.   |
| Upstream retry policy        | Bounded exponential backoff (≤3 attempts, 0.25 s → 0.5 s) on 502/503/504 and on `httpx.ConnectError`/`ReadTimeout`/`WriteTimeout`. Only invoked when the call is replay-safe.  |
| Replay-safety classification | Idempotent methods (GET/HEAD/OPTIONS) **or** any method carrying an `Idempotency-Key` header. POST/PATCH/DELETE without the header are sent at-most-once.                      |

## Consequences

### Positive

- The deployed Function App is no longer reachable without a credential, even
  if its hostname is leaked.
- APIM enforces the subscription requirement independently — if the function's
  forwarded key is wrong (e.g. mid-rotation), APIM rejects the call before it
  hits the Content Safety pool.
- Browsers cannot call the proxy by default. SPAs must be added to an explicit
  allow-list and use a server-side BFF pattern for the function key anyway.
- Hostile or buggy callers cannot tie up a worker with a multi-megabyte
  payload past the upstream cap.
- Transient 5xx/connection failures self-heal for read-only and idempotent
  workloads, reducing alert noise without changing semantics for mutations.

### Negative / Trade-offs

- The smoke-test scripts (`test-deployment.ps1`, `load-test.ps1`) now need
  `az functionapp keys list` to fetch the host key. The deployment outputs
  expose `FUNCTION_APP_NAME` + `AZURE_RESOURCE_GROUP` so the scripts can do
  this automatically.
- The APIM subscription primary key is read by Bicep via `listSecrets()` and
  ends up in App Service `appSettings`. App Service encrypts settings at rest,
  but the value is visible to anyone with `Microsoft.Web/sites/config/list`
  permission. This is acceptable for the current threat model; a future ADR
  may move the key to a Key Vault reference.
- Single FUNCTION auth level means `/api/health` also requires a key. This is
  intentional — liveness probes from inside the VNet or from CI already need
  credentials, and removing the key on health risks accidentally re-opening
  the rest of the surface during incident response.
- POST/PATCH/DELETE without an `Idempotency-Key` are not retried. Callers that
  want resilience for blocklist mutations must opt-in by sending the header
  (the existing APIM idempotency policy already validates and replays it).

## Alternatives considered

- **Keep ANONYMOUS, rely on APIM only** — rejected. APIM is in front of the
  pool, but the function App is reachable directly via its
  `*.azurewebsites.net` hostname. Two layers of gating with independent
  credentials is materially safer.
- **Easy-Auth (App Service Authentication) instead of host keys** — viable
  for SPA scenarios but requires an Entra ID app registration per environment
  and a token-acquisition flow in CI. Host keys are sufficient for the current
  S2S use case; revisit if a browser SPA is ever a first-class consumer.
- **Per-route authentication levels** (e.g. ADMIN on mutations,
  ANONYMOUS on health) — rejected as YAGNI; the current 14 routes form a
  single trust boundary.
- **Tenacity / urllib3 Retry adapter** — rejected to keep the supply-chain
  surface flat. The native `httpx.AsyncClient` + ~30 lines of helper is
  sufficient and easier to audit.

## Follow-ups

- ADR 0002 (proposed): move `APIM_SUBSCRIPTION_KEY` to a Key Vault reference
  on the Function App, eliminating the plaintext value in deployment history.
- ADR 0003 (proposed): introduce a per-tenant APIM subscription scheme for
  multi-tenant deployments, replacing the single shared `function-app`
  subscription.

## 2026-05 follow-up (Tier 1 hardening pass)

A second-pass review after the private-endpoint migration surfaced four
defense-in-depth gaps. All were fixed in a single PR; the rationale is captured
here so future maintainers know which knobs are tunable.

### Key Vault reference for the APIM subscription key

ADR 0002 (proposed above) is now **implemented**. The Bicep flow is:

1. `apim.bicep` reads the per-API subscription primary key via
   `apimSubscription.listSecrets().primaryKey` (server-side at deploy time).
2. The value is written to Key Vault as secret
   `apim-subscription-function-app-key`. `listSecrets()` is NOT recorded in
   deployment history; only the secret URI is surfaced as a module output.
3. `function.bicep` sets `APIM_SUBSCRIPTION_KEY` to
   `@Microsoft.KeyVault(SecretUri=${apimSubscriptionKeySecretUri})`. App Service
   resolves it at runtime using the function's system-assigned MI + the
   `Key Vault Secrets User` role.

**Consequence:** the cleartext key never appears in `appSettings` or in any
deployment history snapshot. Rotation no longer requires a function redeploy —
update the secret value and the function picks it up on the next config refresh
(or on demand via `az functionapp restart`).

### Rate-limit + quota at the APIM layer

`api-base.xml` now applies two throttles on the inbound path, keyed by APIM
subscription id (or gateway IP for unauthenticated callers):

| Policy             | Limit               | Renewal | Tunable via            |
| ------------------ | ------------------- | ------- | ---------------------- |
| `rate-limit-by-key`| 60 calls            | 60 s    | edit `api-base.xml`    |
| `quota-by-key`     | 10 000 calls        | 86 400 s| edit `api-base.xml`    |

**How to tune:** the numbers are tuned for "thin proxy in front of Content
Safety". Increase them when adding a second high-volume API consumer. Both
limits are per APIM subscription, so adding a new subscription gets its own
fresh bucket — no need to bump the global limit for a single new tenant.
Note that these caps apply to traffic *through APIM*; the Function App is
upstream of APIM and is NOT rate-limited by these policies (see the open
question below).

### Body-size rejection at APIM (`<choose>` + `<return-response>`)

`api-base.xml` rejects any inbound request whose `Content-Length` exceeds the
`max-request-body-bytes` named value (sourced from the `maxRequestBodyBytes`
Bicep parameter; default 10 MiB). 413 fires before rate-limit/quota counters
tick and before the call reaches the Content Safety pool. The check uses
`int.Parse(Content-Length)` + literal-int compare — no Razor cost, no body
materialisation.

**Why not `<validate-content>`:** APIM's built-in `validate-content` policy
caps `max-size` at 4 MB, but our default is 10 MiB (matches the Content Safety
image hard limit). The `<choose>` pattern is the supported workaround for
larger caps. The Function App still enforces `MAX_REQUEST_BODY_BYTES`
independently — APIM is defense-in-depth for any future caller that bypasses
the function.

### Log retention bumped from 30 to 90 days

`monitoring.bicep` now exposes a `logRetentionInDays` parameter (default 90,
range 30–730). Both APIM (`GatewayLogs` + `WebSocketConnectionLogs`) and the
Function App (`FunctionAppLogs`) are wired to the shared Log Analytics workspace
via `diagnosticSettings`.

**FC1 gotcha:** Flex Consumption Function Apps reject the `AppServiceHTTPLogs`,
`AppServiceConsoleLogs`, and `AppServiceAppLogs` categories at ARM validation —
those are Web App–only. The diagnostic settings here ship `FunctionAppLogs`
(structured worker traces) and `AllMetrics` only. Structured request/response
data lives in App Insights via `APPLICATIONINSIGHTS_CONNECTION_STRING`.

### CORS wildcard guard

`main-resources.bicep` filters `'*'` out of `corsAllowedOrigins` before passing
the array to `function.bicep`. The original list is checked for wildcard
presence and a `corsWildcardSilentlyStripped` output is set to `true` when it
was — operators see the silent rewrite in azd's post-deploy summary instead of
discovering a wide-open browser surface in prod.

This is intentionally a silent strip rather than a hard failure: misconfiguring
`AZURE_CORS_ALLOWED_ORIGINS=*` is a common foot-gun, and 413-ing the deploy
felt worse than logging the rewrite and continuing with a safe-by-default
configuration. The output flag makes the misconfiguration visible without
breaking the deploy loop.

### Open question — Function App ingress hardening

The Function is `publicNetworkAccess: 'Enabled'` and reachable by anyone with
the function key. The original proposal was to allow-list APIM's outbound IP
on the function, but that inverts the data flow (clients reach the **Function**
first, which then forwards to APIM). Locking the function to APIM's IP would
black-hole all legitimate callers. Alternatives under consideration:

1. **Front Door + WAF** in front of the function (rate-limit at the edge,
   WAF on common attack patterns). ~$35/mo base + traffic.
2. **Private Endpoint on the function** + a known public ingress (App Gateway
   or Front Door Premium).
3. **Move the smart-proxy logic into APIM** (idempotency, body-size, retry are
   all APIM-feasible) and retire the function entirely. Bigger refactor.
4. **Accept the current posture** (function key + rate-limit-on-APIM caps
   the downstream blast radius). Rate-limit-on-APIM does *not* prevent the
   function from being scaled out by an authenticated abuser, but the
   function-key requirement makes anonymous abuse impossible.

No decision yet; tracking as ADR 0004 (proposed).
