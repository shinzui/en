---
id: 33
slug: add-caller-authentication-and-rate-limiting-to-en-server
title: "Add caller authentication and rate limiting to en-server"
kind: exec-plan
created_at: 2026-07-07T15:24:43Z
master_plan: "docs/masterplans/6-production-harden-the-en-service.md"
intention: intention_01kx21nk4kemtt6pjnb5tr76nk
---

# Add caller authentication and rate limiting to en-server

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today the standalone authorization service `en-server` answers every HTTP request from
anyone who can reach its port. There is no authentication of any kind: finding A1
(CRITICAL) of `docs/reviews/2026-07-07-architecture-performance-review.md` observes that
anyone with network reach can `POST /tuples` to grant themselves any permission, or
`DELETE /tuples` to erase the relationship graph. There is also no rate limiting — and an
authorization service is a denial-of-service amplifier, because each `check` request fans
out into multiple database reads — and no stated TLS story, so API keys would cross the
network in cleartext unless an operator happens to guess the right deployment shape.

After this change, `en-server` requires every request to present a valid API key in an
`Authorization: Bearer …` header. Keys are configured from the environment in two tiers:
read-write keys may call every endpoint, read-only keys may call only the query endpoints
(`/check`, `/batch-check`, `/lookup`, `/expand`). A request with no key or an unknown key
receives HTTP 401 with a JSON body; a read-only key calling a write endpoint (`POST
/tuples` or `DELETE /tuples`) receives HTTP 403 with a JSON body; a caller exceeding its
per-key request budget receives HTTP 429 with a JSON body and a `Retry-After` header. The
server refuses to start with no keys configured unless the operator explicitly opts out
for local development. The TLS posture is documented: terminate TLS at a reverse proxy in
front of `en-server`, or serve TLS directly through the optional `warp-tls` path this
plan adds. You can see all of it working with `curl` transcripts in Validation and
Acceptance below.

This plan implements finding A1 of the review and is child EP-33 of the master plan
`docs/masterplans/6-production-harden-the-en-service.md`.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: `AuthConfig` parsing (`EN_API_KEYS_READ_WRITE`, `EN_API_KEYS_READ_ONLY`,
  `EN_AUTH_DISABLED`) and the bearer-token authentication middleware in
  `en-server/app/Middleware.hs`; every endpoint returns 401 without a valid key.
- [x] M1: `en-server/en-server.cabal` gains `other-modules: Middleware` and the new
  `wai`, `http-types`, `bytestring`, `aeson`, and `ram` dependencies.
- [x] M1: Justfile `start-and-test` / `test-server` updated to configure and send a
  dev API key.
- [ ] M2: write/read authorization split; read-only keys get 403 on `POST /tuples` and
  `DELETE /tuples`, 200 on query endpoints.
- [ ] M3: per-caller token-bucket rate limiting middleware with
  `EN_RATE_LIMIT_RPS` / `EN_RATE_LIMIT_BURST`; over-budget requests get 429 with
  `Retry-After`.
- [ ] M4: optional direct TLS via `warp-tls` (`EN_TLS_CERT_FILE` / `EN_TLS_KEY_FILE`)
  and the documented reverse-proxy TLS posture in
  `docs/user/service-and-operations.md`.
- [ ] Final validation: full curl transcript (401 / 403 / 429 / 200) reproduced against
  a locally running server; `just start-and-test` passes.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The `memory` package named throughout the original plan is deprecated. Implementation
  switched to `ram`, its maintained fork, which exposes the same `Data.ByteArray`
  module and `constEq`. No import changed; only `build-depends`. Verified building
  against `ram-0.22.0` on GHC 9.12.4. Recorded in the Decision Log; the plan's prose was
  updated in place.

- `en-server`'s startup logs vanish when stdout is not a TTY. Running the binary with
  output redirected to a file produced a zero-byte log even though the server was live
  and answering (`ps` reported the process alive, `curl` got `HTTP/1.1 401`, and
  `wc -c < server.log` was `0`). The cause is GHC's default block buffering on a
  non-TTY stdout: `Main.hs` never calls `hSetBuffering`. This is not a bug introduced by
  this plan and it did not block acceptance, but it will silently swallow the WARNING
  line that `EN_AUTH_DISABLED=true` prints — precisely the line an operator must not
  miss — whenever en-server runs under a supervisor. EP-36
  (`docs/plans/36-add-health-endpoints-graceful-shutdown-and-observability.md`) owns
  structured logging and should set `hSetBuffering stdout LineBuffering` at the top of
  `main` as part of that work.

- The startup failure path renders as an uncaught `IOException` (`en-server: Uncaught
  exception … user error (No API keys configured; …)`) because it goes through `fail`.
  The message is intact and the exit code is 1 with no port bound, so acceptance
  criterion 1 holds, but the framing is noisy. This matches the pre-existing style of
  `requiredEnv` and `optionalNonNegativeIntEnv` in `Main.hs`, so it was left alone; EP-38
  (`docs/plans/38-validate-configuration-and-persist-datastore-identity.md`), which
  centralizes configuration parsing, should render config errors and exit cleanly rather
  than throwing.


## Decision Log

Record every decision made while working on the plan.

- Decision: Authenticate with a static list of bearer API keys from environment
  variables, implemented as a WAI middleware in `en-server`, rather than a Servant
  combinator, mTLS, or shomei-identity verification.
  Rationale: The en-servant.cabal description promises gating "against the caller's
  verified shomei identity (kikan C11)", but nothing in this repository provides a shomei
  verifier — shomei is a separate project, and depending on it here would invert the
  intended dependency direction. A static key list is the smallest mechanism that closes
  finding A1 today, and a WAI middleware (a function wrapping the whole application, see
  Context and Orientation) is the seam the master plan designates: any future verifier —
  mTLS client certificates or shomei identity tokens — replaces the credential-checking
  function inside the same middleware without touching handlers. shomei therefore stays
  an extension point, not a dependency.
  Date: 2026-07-07
- Decision: Two key tiers (read-write and read-only) distinguished by which environment
  variable a key appears in, with write endpoints identified by route (`/tuples` under
  `POST` or `DELETE`).
  Rationale: The review requires write endpoints to be separately authorizable. Roles per
  route are the simplest model that achieves it; per-object authorization of en's own API
  is out of scope (that is what en itself is for, and self-hosting it would need a
  bootstrap story). When EP-35 (`docs/plans/35-version-the-wire-contract-and-type-the-error-model.md`)
  moves writes to `POST /v1/relationships` and `POST /v1/relationships/delete`, the
  write-route predicate in `Middleware.hs` must be updated in that plan.
  Date: 2026-07-07
- Decision: Fail closed at startup — refuse to boot with no keys configured — with an
  explicit `EN_AUTH_DISABLED=true` escape hatch for local development.
  Rationale: An authorization service that silently starts unauthenticated recreates
  finding A1 on any deployment that forgets a variable. The escape hatch keeps
  `cabal run en-server` demos and the conformance workflow usable, and is loud (a WARNING
  log line) so it cannot be mistaken for production posture.
  Date: 2026-07-07
- Decision: Hand-roll the token-bucket rate limiter (~60 lines over an `IORef` map)
  instead of adopting `wai-rate-limit` or `wai-middleware-throttle` from Hackage.
  Rationale: `wai-rate-limit`'s useful backends assume Redis; `wai-middleware-throttle`
  is unmaintained and its `token-bucket` dependency is unverified on GHC 9.12.4 (this
  project's compiler). The algorithm is tiny, needs only `base` and `containers`, and a
  per-process in-memory limiter is correct for the stated scope (single process, one org,
  no horizontal dispatch per `docs/spec/0001-en-overview.md`). Both packages are named
  here so a later operator can revisit if distributed limiting is ever needed.
  Date: 2026-07-07
- Decision: Compare API keys in constant time using `Data.ByteArray.constEq` from the
  `ram` package.
  Rationale: A plain `==` on `ByteString` short-circuits at the first differing byte,
  which leaks key prefixes through response timing. `constEq` is the documented
  constant-time equality.
  Date: 2026-07-07
- Decision: Depend on `ram`, not `memory`, for `Data.ByteArray.constEq` (revision to the
  decision above, made during implementation).
  Rationale: `memory` (vincenthz/hs-memory) is deprecated and unmaintained; `ram`
  (jappeace/ram) is the maintained fork with an identical module and API surface, so the
  import (`import Data.ByteArray (constEq)`) is unchanged. Verified: `en-server` builds
  against `ram-0.22.0` under GHC 9.12.4 with no `Data.ByteArray` module clash, because
  `en-server` does not depend on the biscuit/crypton chain that would also supply the
  module.
  Date: 2026-07-08
- Decision: Error bodies use the minimal envelope `{"error": <message>, "code": <code>}`
  until EP-35 lands.
  Rationale: The master plan's Integration Points section assigns ownership of the typed
  error envelope (`{code, message, retryable}`) to EP-35
  (`docs/plans/35-version-the-wire-contract-and-type-the-error-model.md`) and instructs
  EP-33 to emit a minimal `{"error": …, "code": …}` object that EP-35 later reconciles.
  This plan follows that instruction so the two plans stay landable in either order.
  Date: 2026-07-07
- Decision: When API keys are configured *and* `EN_AUTH_DISABLED=true` is set, keep
  authentication enabled and print a warning that the flag was ignored.
  Rationale: The plan specified `EN_AUTH_DISABLED` only for the no-keys case, leaving the
  overlap undefined. Honouring the flag would let a stray environment variable silently
  disable authentication on a deployment that correctly configured keys — a fail-open
  path, and a re-run of finding A1. Keys therefore win, and the ignored flag is announced
  rather than tolerated in silence.
  Date: 2026-07-08
- Decision: The authentication middleware exempts the exact paths `/healthz` and
  `/readyz` (and nothing else).
  Rationale: EP-36 (`docs/plans/36-add-health-endpoints-graceful-shutdown-and-observability.md`)
  adds liveness/readiness probes at those paths, and orchestrator probes cannot carry
  credentials conveniently. Exempting them now (they 404 harmlessly until EP-36 lands)
  avoids a cross-plan edit later. The future `/metrics` endpoint is deliberately NOT
  exempted — Prometheus supports bearer-token scraping.
  Date: 2026-07-07
- Decision: Recommend reverse-proxy TLS termination as the primary posture and add
  optional direct TLS via `warp-tls` behind `EN_TLS_CERT_FILE`/`EN_TLS_KEY_FILE`.
  Rationale: Bearer keys are only as secret as the transport. A reverse proxy (nginx,
  caddy, an ingress) is how single-org services are typically deployed and keeps
  certificate rotation out of en's code; `warp-tls` is a one-function addition
  (`Network.Wai.Handler.WarpTLS.runTLS`) for deployments with nothing in front.
  Date: 2026-07-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

en is a relationship-based authorization toolkit, organized as several Haskell packages
under the repository root `/Users/shinzui/Keikaku/bokuno/en` and built with `cabal`
(project file `cabal.project`, compiler GHC 9.12.4). The standalone HTTP service is the
executable in `en-server/app/Main.hs`: it reads environment variables, connects to
PostgreSQL, loads and compiles a schema, assembles an `Env` record of engine operations,
and finally runs the Servant application with `Warp.run port (app serverEnv)` (currently
at the bottom of `main`, inside an inert `bracket`).

The HTTP surface is defined in `en-servant/src/En/Servant/API.hs` as the Servant type
`EnAPI` with six endpoints: `POST /tuples` (write relationship tuples), `DELETE /tuples`
(delete tuples; carries a JSON request body), `POST /check`, `POST /batch-check`,
`POST /lookup`, and `POST /expand`. `app` in that module is
`serve apiProxy . server` — a plain WAI `Application` with nothing wrapped around it.
`en-servant/src/En/Servant/Seam.hs` holds the `Env` record and the `jsonError` helper
that renders a Servant `ServerError` with a JSON body `{"error": <text>}` (the
`ErrorWire` type). `en-servant/src/En/Servant/Authorize.hs` is unrelated to this plan's
concern: it is a helper for *host applications embedding en* to gate their own routes; it
does not protect en-server's API.

Two terms of art used throughout this plan:

- A **WAI middleware** is a function of type `Network.Wai.Middleware`, which is
  `Application -> Application` — it receives the inner application and returns a new one
  that can inspect the request, short-circuit with its own response, or pass through.
  Middlewares compose by nesting; the outermost one sees the request first. WAI types
  come from the `wai` package (already in the build closure; `en-server` must now declare
  it directly).
- A **token bucket** is the standard rate-limiting algorithm: each caller has a bucket
  holding up to `burst` tokens; tokens refill continuously at `rps` tokens per second;
  each request spends one token; a request arriving at an empty bucket is rejected. It
  permits short bursts while bounding sustained throughput.

The master plan (`docs/masterplans/6-production-harden-the-en-service.md`, Integration
Points) fixes three constraints this plan must respect and which are restated here so the
plan stands alone. First, `en-server/app/Main.hs` is edited by several sibling plans, so
land this plan's `Main.hs` edits as one small block (the middleware composition around
`app serverEnv`). Second, the middleware order is: **authentication runs first, rate
limiting runs after authentication** (so limits are per-caller), and any request logging
added later by EP-36 must be able to see the caller identity that authentication
attached. This plan propagates the verified caller name to inner middleware and handlers
by replacing the request's `X-En-Caller` header (stripping any client-supplied value
first, so it cannot be forged). Third, error bodies use the minimal
`{"error": …, "code": …}` envelope until EP-35 defines the typed one.

Configuration parsing today is ad hoc in `Main.hs` (`requiredEnv`,
`optionalNonNegativeIntEnv`). EP-38
(`docs/plans/38-validate-configuration-and-persist-datastore-identity.md`) later
centralizes all environment parsing in a `ServerConfig` record; until then this plan adds
its own small parsers in the same style, and EP-38 absorbs them.

The development database comes from `process-compose` driven by `just` (read `Justfile`
and `process-compose.yaml`): `just process-up` starts PostgreSQL (unix-socket only;
`PG_CONNECTION_STRING` and `EN_DATABASE_URL` are exported by the nix dev shell /
`.envrc`), `just run-migrations` applies the SQL migrations with guarded `psql` calls,
`just start-server` runs `cabal run en-server`, and `just test-server` is the HTTP smoke
test (curl + jq) that this plan must keep passing by teaching it to send a key.


## Plan of Work

The work is four milestones. M1 is the critical one — after it, nothing answers without a
key. M2 splits write from read authority. M3 adds throttling. M4 settles transport
security. Each milestone leaves `cabal build all` green and the smoke test passing.


### Milestone 1: Bearer-key authentication middleware

Scope: a new module `en-server/app/Middleware.hs` (registered under `other-modules` in
the `executable en-server` stanza of `en-server/en-server.cabal`, with `wai`,
`http-types`, `bytestring`, `aeson`, and `ram` added to `build-depends`), plus wiring
in `en-server/app/Main.hs`. At the end of this milestone every endpoint requires a valid
key and the server fails closed at startup when no keys are configured.

Define the configuration types and parser in `Middleware.hs`:

```haskell
-- en-server/app/Middleware.hs
data KeyRole = ReadOnly | ReadWrite
    deriving stock (Eq, Show)

data ApiKey = ApiKey
    { keyName :: !Text          -- caller identity, e.g. "ci-deployer"
    , keySecret :: !ByteString  -- the bearer secret
    , keyRole :: !KeyRole
    }

data AuthConfig
    = AuthDisabled
    | AuthKeys ![ApiKey]

loadAuthConfig :: IO AuthConfig
```

`loadAuthConfig` reads `EN_API_KEYS_READ_WRITE` and `EN_API_KEYS_READ_ONLY`, each an
optional comma-separated list of `name:secret` entries (names must be nonempty and
unique across both lists; secrets must be at least 16 bytes — reject shorter ones with a
clear message so weak dev keys do not leak into production). If both variables are unset
or empty: when `EN_AUTH_DISABLED=true`, return `AuthDisabled` and print a prominent
`WARNING: authentication is DISABLED …` line; otherwise `fail` with a message naming all
three variables and an example value, so startup aborts before the port is bound.
Malformed entries (no `:`, empty name or secret, duplicate name) are startup failures,
not skipped entries — authentication config must never partially parse.

Implement the middleware:

```haskell
authMiddleware :: AuthConfig -> Middleware
```

For `AuthDisabled` it is `id`. Otherwise, for each request: if `pathInfo` is exactly
`["healthz"]` or `["readyz"]`, pass through untouched (probe exemption; see Decision
Log). Otherwise read the `Authorization` header, require the form `Bearer <secret>`
(case-insensitive scheme per RFC 7235), and compare `<secret>` against each configured
key's secret with `Data.ByteArray.constEq` (from the `ram` package; both sides as
`ByteString`). On failure — missing header, wrong scheme, unknown secret — respond
immediately with 401, headers `Content-Type: application/json` and
`WWW-Authenticate: Bearer`, and body:

```json
{"error":"missing or invalid API key","code":"unauthenticated"}
```

On success, pass the request to the inner application with its headers rewritten: remove
any inbound `X-En-Caller` header and insert `X-En-Caller: <keyName>`. That header is how
rate limiting (M3) and EP-36's request logging identify the caller without re-verifying
the secret. Build the JSON body with `aeson`'s `encode` over a small record (do not
hand-concatenate JSON), and respond with `responseLBS status401 …`.

In `Main.hs`, call `authConfig <- loadAuthConfig` alongside the other environment reads,
and change the final line to wrap the application:

```haskell
Warp.run port (authMiddleware authConfig (app serverEnv))
```

Update the Justfile so the smoke test authenticates. In `start-and-test`, export a dev
key for the server process (`EN_API_KEYS_READ_WRITE="dev:dev-secret-0123456789"`); in
`test-server`, add `-H "Authorization: Bearer ${EN_API_KEY:-dev-secret-0123456789}"` to
every curl invocation. Also update `start-server` to pass through whatever
`EN_API_KEYS_*`/`EN_AUTH_DISABLED` the caller set (it already inherits the environment,
so only the recipe comment needs to mention the variables).

Acceptance: `cabal build en-server` succeeds; starting with no key variables fails with
the clear message; starting with `EN_AUTH_DISABLED=true` warns and serves; with a key
configured, a request without a header gets 401 with the JSON body above and a request
with the key gets the normal response. `just start-and-test` passes.


### Milestone 2: Separate write authorization

Scope: read-only keys can query but not mutate. At the end of this milestone the
authentication middleware distinguishes write routes and enforces `KeyRole`.

In `Middleware.hs`, add the route predicate:

```haskell
isWriteRequest :: Request -> Bool
isWriteRequest request =
    pathInfo request == ["tuples"]
        && requestMethod request `elem` [methodPost, methodDelete]
```

(`pathInfo` and `requestMethod` from `Network.Wai`; method constants from
`Network.HTTP.Types.Method`.) After a key authenticates, if `isWriteRequest` holds and
the key's role is `ReadOnly`, respond 403 with body:

```json
{"error":"this API key is read-only","code":"permission_denied"}
```

Note for the future: EP-35 renames the write routes to `POST /v1/relationships` and
`POST /v1/relationships/delete`; whichever plan lands second updates this predicate (a
one-line change) and its test transcript.

Acceptance: with `EN_API_KEYS_READ_ONLY="reader:reader-secret-0123456789"` also set, a
`POST /check` with the reader key returns a decision, while `POST /tuples` with the
reader key returns 403 with the body above; the read-write key still writes successfully.


### Milestone 3: Per-caller token-bucket rate limiting

Scope: a second middleware, applied *inside* authentication (so it sees `X-En-Caller`),
that throttles each caller independently. At the end of this milestone a caller
exceeding its budget receives 429 until tokens refill.

In `Middleware.hs`:

```haskell
data RateLimitConfig = RateLimitConfig
    { ratePerSecond :: !Double  -- refill rate; 0 disables limiting
    , burst :: !Double          -- bucket capacity
    }

loadRateLimitConfig :: IO RateLimitConfig
rateLimitMiddleware :: RateLimitConfig -> IO Middleware
```

`loadRateLimitConfig` reads `EN_RATE_LIMIT_RPS` and `EN_RATE_LIMIT_BURST` (both optional
non-negative numbers; default 0 = disabled; if RPS is set and burst is not, default
burst to the RPS value). `rateLimitMiddleware` is in `IO` because it allocates the shared
state: an `IORef (Map Text Bucket)` where `Bucket` holds the token count and the
last-refill timestamp taken from `GHC.Clock.getMonotonicTimeNSec` (the monotonic clock —
never wall time, which jumps). On each request: identify the caller from the
`X-En-Caller` header (requests that bypass auth — probes, or `AuthDisabled` mode — fall
back to the literal caller name `"anonymous"`, giving one shared bucket); atomically
(`atomicModifyIORef'`) refill the bucket by `elapsedSeconds * ratePerSecond` capped at
`burst`, and spend one token if available. If the bucket is empty, respond 429 with
header `Retry-After: 1` and body:

```json
{"error":"rate limit exceeded","code":"rate_limited"}
```

Exempt `["healthz"]` and `["readyz"]` exactly as the auth middleware does. In `Main.hs`,
compose in the master-plan order (auth outermost, then rate limit, then the app):

```haskell
rateLimit <- rateLimitMiddleware rateLimitConfig
Warp.run port (authMiddleware authConfig (rateLimit (app serverEnv)))
```

Acceptance: with `EN_RATE_LIMIT_RPS=1 EN_RATE_LIMIT_BURST=2`, the third rapid request
from one key returns 429 (see the transcript in Validation and Acceptance) and a request
from a different key at the same moment still succeeds — proving the bucket is
per-caller.


### Milestone 4: TLS posture — documentation plus optional warp-tls

Scope: transport security is stated, not implied. At the end of this milestone the
operator documentation prescribes the reverse-proxy posture, and `en-server` can serve
TLS directly when given a certificate.

Add `warp-tls` to `en-server`'s `build-depends`. In `Main.hs`, read the optional pair
`EN_TLS_CERT_FILE` / `EN_TLS_KEY_FILE` (setting exactly one of the two is a startup
failure). When both are set, serve with
`Network.Wai.Handler.WarpTLS.runTLS (tlsSettings certFile keyFile) (Warp.setPort port Warp.defaultSettings) wrappedApp`
and log `Serving TLS directly (EN_TLS_CERT_FILE=…)`; otherwise keep `Warp.run` and log
`Serving plaintext HTTP; terminate TLS at a reverse proxy or set EN_TLS_CERT_FILE/EN_TLS_KEY_FILE.`

Extend `docs/user/service-and-operations.md`: a new "Authentication, rate limiting, and
TLS" section documenting all six new environment variables
(`EN_API_KEYS_READ_WRITE`, `EN_API_KEYS_READ_ONLY`, `EN_AUTH_DISABLED`,
`EN_RATE_LIMIT_RPS`, `EN_RATE_LIMIT_BURST`, `EN_TLS_CERT_FILE`+`EN_TLS_KEY_FILE`), the
401/403/429 behaviors with example bodies, the recommendation to terminate TLS at a
reverse proxy (with a note that bearer keys must never traverse plaintext networks), and
the statement that the static key list is the baseline mechanism with the middleware
seam as the extension point for mTLS or shomei-identity verification later.

Acceptance: with a self-signed pair generated by
`openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/en.key -out /tmp/en.crt -days 1 -subj /CN=localhost`,
starting the server with both variables set serves HTTPS
(`curl -k https://localhost:8080/check …` works, plain `http://` does not); the docs
section exists and names every variable.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/en`, inside the
nix dev shell (direnv loads it; it exports `PGDATA`, `PG_CONNECTION_STRING`, and
`EN_DATABASE_URL`).

Confirm a clean start, then bring up the dev database:

```bash
cabal build all
just process-up
just run-migrations
```

Expected: the build completes; process-compose reports PostgreSQL healthy; migrations
print either the `psql` apply output or `… already applied`.

Start the server with keys configured (after M1; add the reader key after M2):

```bash
EN_API_KEYS_READ_WRITE='deployer:dev-secret-0123456789' \
EN_API_KEYS_READ_ONLY='reader:reader-secret-0123456789' \
EN_RATE_LIMIT_RPS=0 \
  cabal run en-server
```

Expected startup log lines include `en-server listening on :8080` (plus the existing
schema and cache lines). Startup with *no* key variables must instead print an error
naming `EN_API_KEYS_READ_WRITE`, `EN_API_KEYS_READ_ONLY`, and `EN_AUTH_DISABLED`, and
exit non-zero without binding the port.

Exercise authentication from another terminal (the request bodies follow the current
wire shapes — the same ones used in `Justfile`'s `test-server` recipe):

```bash
# no key -> 401
curl -si localhost:8080/check -H 'content-type: application/json' -d '{}' | head -3

# read-only key writing -> 403
curl -si -X POST localhost:8080/tuples \
  -H 'Authorization: Bearer reader-secret-0123456789' \
  -H 'content-type: application/json' \
  -d '{"tuples":[{"object":{"objectType":"space","objectId":"project-x"},"relation":"viewer","subject":{"tag":"SubjectIdWire","contents":{"objectType":"user","objectId":"alice"}},"caveat":null}]}' | head -3

# read-write key writing -> 200 with a token
curl -s -X POST localhost:8080/tuples \
  -H 'Authorization: Bearer dev-secret-0123456789' \
  -H 'content-type: application/json' \
  -d '{"tuples":[{"object":{"objectType":"space","objectId":"project-x"},"relation":"viewer","subject":{"tag":"SubjectIdWire","contents":{"objectType":"user","objectId":"alice"}},"caveat":null}]}'
```

Expected transcript (abridged):

```text
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer
{"code":"unauthenticated","error":"missing or invalid API key"}

HTTP/1.1 403 Forbidden
{"code":"permission_denied","error":"this API key is read-only"}

{"token":"en1.…"}
```

Exercise rate limiting (after M3; restart the server with
`EN_RATE_LIMIT_RPS=1 EN_RATE_LIMIT_BURST=2`):

```bash
for i in 1 2 3; do
  curl -s -o /dev/null -w "%{http_code}\n" localhost:8080/check \
    -H 'Authorization: Bearer dev-secret-0123456789' \
    -H 'content-type: application/json' \
    -d '{"consistency":{"tag":"MinimizeLatencyWire"},"context":{"values":{}},"subject":{"tag":"SubjectIdWire","contents":{"objectType":"user","objectId":"alice"}},"permission":"view","object":{"objectType":"space","objectId":"project-x"}}'
done
```

Expected:

```text
200
200
429
```

Run the maintained smoke test end to end:

```bash
just start-and-test
```

Expected final line: `server smoke test passed: AllowedWire`.


## Validation and Acceptance

Acceptance is behavioral, verified against a running server:

1. Startup fail-closed: `cabal run en-server` with `EN_DATABASE_URL` set but no
   `EN_API_KEYS_*` variables exits non-zero, printing a message that names
   `EN_API_KEYS_READ_WRITE`, `EN_API_KEYS_READ_ONLY`, and `EN_AUTH_DISABLED`, and no
   process listens on the port afterwards. With `EN_AUTH_DISABLED=true` the server
   starts and prints a WARNING line containing the word `DISABLED`.
2. 401 on every endpoint: for each of `/tuples` (POST and DELETE), `/check`,
   `/batch-check`, `/lookup`, `/expand`, a request without an `Authorization` header —
   and a request with `Authorization: Bearer wrong` — returns status 401,
   `Content-Type: application/json`, a `WWW-Authenticate: Bearer` header, and body
   `{"code":"unauthenticated","error":"missing or invalid API key"}` (field order may
   differ; it is JSON).
3. Role split: the read-only key succeeds on `/check` and receives status 403 with code
   `permission_denied` on `POST /tuples` and `DELETE /tuples`; the read-write key
   succeeds on all endpoints.
4. Rate limiting: with `EN_RATE_LIMIT_RPS=1 EN_RATE_LIMIT_BURST=2`, three back-to-back
   requests with one key yield 200, 200, 429 (the 429 carries `Retry-After: 1` and code
   `rate_limited`); an immediate request with the *other* key yields 200; after sleeping
   2 seconds the first key succeeds again. With `EN_RATE_LIMIT_RPS=0` (or unset) no 429
   is ever produced.
5. Probe exemption: `curl -si localhost:8080/healthz` without a key does NOT return 401
   (until EP-36 lands it returns Servant's 404; after EP-36 it returns 200).
6. TLS: with `EN_TLS_CERT_FILE`/`EN_TLS_KEY_FILE` set to the self-signed pair from
   Concrete Steps, `curl -sk https://localhost:8080/healthz` connects over TLS; setting
   only one of the two variables aborts startup with a message naming both.
7. Regression: `just start-and-test` passes, and `cabal test en-servant` still passes
   (this plan does not touch en-servant, so its suite is a no-regression check).


## Idempotence and Recovery

Every step is safe to repeat. The middleware holds only in-memory state (the rate-limit
buckets), which resets on restart — restarting the server is always a safe recovery.
Re-running the curl transcripts is idempotent (`POST /tuples` inserts are
`ON CONFLICT DO NOTHING` at the storage layer, and the smoke test deletes before
writing). Key rotation is an environment change plus restart: because keys are read only
at startup, removing a compromised key requires a restart, and the operations doc must
say so. If a bad key configuration locks everyone out, the recovery path is to fix the
environment variables and restart — no state outlives the process. Nothing in this plan
touches the database schema.


## Interfaces and Dependencies

New module `Middleware` in `en-server/app/Middleware.hs`, listed under `other-modules`
of the `executable en-server` stanza in `en-server/en-server.cabal`, exporting:

```haskell
data KeyRole = ReadOnly | ReadWrite
data ApiKey = ApiKey { keyName :: Text, keySecret :: ByteString, keyRole :: KeyRole }
data AuthConfig = AuthDisabled | AuthKeys [ApiKey]
data RateLimitConfig = RateLimitConfig { ratePerSecond :: Double, burst :: Double }

loadAuthConfig :: IO AuthConfig
loadRateLimitConfig :: IO RateLimitConfig
authMiddleware :: AuthConfig -> Network.Wai.Middleware
rateLimitMiddleware :: RateLimitConfig -> IO Network.Wai.Middleware
```

New `build-depends` for `en-server`: `wai` (middleware types), `http-types` (statuses,
methods, header names), `bytestring`, `aeson` (error bodies), `ram`
(`Data.ByteArray.constEq`), and — in M4 — `warp-tls`
(`Network.Wai.Handler.WarpTLS.runTLS`, `tlsSettings`). All are on Hackage and already in
or adjacent to the existing build closure (`wai`, `http-types`, `bytestring`, and `aeson`
are transitive dependencies today; `ram` and `warp-tls` are new, `ram` being the
maintained fork of the deprecated `memory` and `warp-tls` the standard Warp companion).
No changes to `en-core`, `en-postgres`, or `en-servant`.

New runtime contract (environment variables): `EN_API_KEYS_READ_WRITE`,
`EN_API_KEYS_READ_ONLY` (comma-separated `name:secret` lists), `EN_AUTH_DISABLED`
(`true` to opt out), `EN_RATE_LIMIT_RPS`, `EN_RATE_LIMIT_BURST` (non-negative numbers, 0
disables), `EN_TLS_CERT_FILE`, `EN_TLS_KEY_FILE` (both or neither). EP-38
(`docs/plans/38-validate-configuration-and-persist-datastore-identity.md`) later absorbs
the parsing of these variables into its `ServerConfig` record; the names defined here are
the contract it must keep.

Files edited: `en-server/app/Main.hs` (config loading, middleware composition, TLS
branch), `en-server/en-server.cabal`, `Justfile` (`start-and-test`, `test-server`),
`docs/user/service-and-operations.md`. File added: `en-server/app/Middleware.hs`.
