---
id: 36
slug: add-health-endpoints-graceful-shutdown-and-observability
title: "Add health endpoints, graceful shutdown, and observability"
kind: exec-plan
created_at: 2026-07-07T15:24:43Z
master_plan: "docs/masterplans/6-production-harden-the-en-service.md"
---

# Add health endpoints, graceful shutdown, and observability

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

An orchestrator (Kubernetes, systemd, process-compose) currently has no way to ask
`en-server` "are you alive?" or "are you ready for traffic?" — there is no `/healthz` or
`/readyz`; the Justfile's own readiness loop curls `/` and accepts the resulting 404 as
"up". SIGTERM kills the process mid-request because Warp is run without a shutdown
handler, so every deploy drops in-flight authorization checks. The only log output is a
handful of startup `putStrLn` lines: no request logging, no request ids to correlate a
client error report with server behavior, and no metrics — the engine already counts
cache hits/misses/evictions in-process (`cacheStats` in `en-core/src/En/Cache.hs`) but
exports them nowhere. This is finding A4 (HIGH) of
`docs/reviews/2026-07-07-architecture-performance-review.md` (feature gap E7).

After this change: `GET /healthz` returns 200 whenever the process serves HTTP;
`GET /readyz` returns 200 only when a `SELECT 1` succeeds against PostgreSQL through the
`Database` effect, and 503 otherwise; SIGTERM stops accepting new connections, lets
in-flight requests finish (bounded by a timeout), releases resources, and exits 0; every
request produces one structured JSON log line carrying a request id (also returned to
the client as an `X-Request-Id` header) and the authenticated caller when EP-33 is
active; and `GET /metrics` serves Prometheus-format request counts, latency aggregates,
and the engine cache statistics. The dev environment gets the same treatment:
`en-server` becomes a process-compose process with a real HTTP readiness probe. This
plan is child EP-36 of `docs/masterplans/6-production-harden-the-en-service.md`.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: `/healthz` and `/readyz` served from a WAI layer in
  `en-server/app/Health.hs`; readiness pings PostgreSQL through the `Database` effect;
  Justfile readiness loop switched to `/healthz`.
- [ ] M2: graceful shutdown via `setGracefulShutdownTimeout` +
  `setInstallShutdownHandler` + a SIGTERM handler; clean-exit transcript captured.
- [ ] M3: request-id middleware and JSON request logging (wai-extra) wired in the
  master-plan middleware order.
- [ ] M4: `/metrics` endpoint with request counters, latency sum/count, and cache
  stats; `en-server/app/Metrics.hs`.
- [ ] M5: `en-server` process added to `process-compose.yaml` with an `http_get`
  readiness probe on `/readyz`; docs updated.
- [ ] Final validation transcript recorded in Outcomes.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Serve `/healthz`, `/readyz`, and `/metrics` from a small WAI layer in
  `en-server` rather than adding them to the Servant `EnAPI` type.
  Rationale: They are operational endpoints of the *process*, not part of the versioned
  wire contract EP-35 owns (`docs/plans/35-version-the-wire-contract-and-type-the-error-model.md`
  deliberately excludes them from `/v1` and from the OpenAPI document). Keeping them in
  `en-server/app/` also avoids giving `en-servant` a dependency on the Database effect
  runner wiring. EP-33's auth middleware already exempts exactly `/healthz` and
  `/readyz` (its Decision Log), so probes work unauthenticated; `/metrics` is NOT
  exempt — Prometheus scrapes with a bearer token.
  Date: 2026-07-07
- Decision: Liveness (`/healthz`) is unconditional 200; readiness (`/readyz`) is the
  database ping. Readiness does not check schema state or cache health.
  Rationale: Liveness must only mean "restart me if this stops answering" — tying it to
  the database would make an orchestrator restart en-server during a PostgreSQL outage,
  which helps nothing. Readiness gates traffic, and the only hard runtime dependency is
  PostgreSQL. The ping goes through the `Database` effect (per the master plan's
  Integration Points: consume whatever runner EP-34 defines — the pool if
  `docs/plans/34-pool-database-connections-in-en-server.md` has landed, the single
  connection otherwise; the code is identical either way because it calls
  `En.Postgres.Database.runSession`).
  Date: 2026-07-07
- Decision: Hand-roll the `/metrics` exporter in Prometheus text exposition format
  instead of depending on `prometheus-client`.
  Rationale: The needed surface is tiny — monotonically increasing counters and a
  latency sum/count per (path-group, status-class), plus the four cache counters
  `En.Cache.cacheStats` already maintains — and the text format is a few lines of
  rendering. `prometheus-client` (with `wai-middleware-prometheus`) is the named
  upgrade path if histograms/quantiles are ever needed, but it is unverified on
  GHC 9.12.4 and would duplicate the cache counters' storage. Recorded alternative:
  `prometheus-client` + `wai-middleware-prometheus`.
  Date: 2026-07-07
- Decision: Structured request logs are JSON lines to stdout via wai-extra's
  `RequestLogger` with `formatAsJSON`, enriched with `X-Request-Id` and the
  `X-En-Caller` header EP-33 attaches.
  Rationale: `wai-extra` is already in the build closure and its JSON formatter emits
  one machine-parseable object per request (method, path, status, duration, headers).
  Restated master-plan ordering constraint: authentication runs before logging so the
  logger can record a verified caller identity, and rate limiting runs after
  authentication. The resulting composition, outermost first, is: auth → rate limit →
  request-id → logger → health/metrics layer → Servant app. Request-id sits inside rate
  limiting so throttled requests are cheap (no UUID allocation), and the logger sits
  inside request-id so every logged line has one. 401/403/429 short-circuits from the
  outer middlewares are not request-logged — acceptable, they are countable at the
  proxy and in `/metrics` once EP-33's responses pass through the metrics layer
  (they do not; noted as a known limitation in the ops doc).
  Date: 2026-07-07
- Decision: Graceful shutdown drains for at most 30 seconds
  (`setGracefulShutdownTimeout (Just 30)`), and the SIGTERM handler is installed through
  Warp's `setInstallShutdownHandler`.
  Rationale: 30 s comfortably exceeds the lookup deadline default (3 s, clamped by
  EP-38) and typical orchestrator grace periods default to 30 s. Warp's mechanism —
  handler receives `closeSocket`, calls it on SIGTERM, `runSettings` returns after
  in-flight requests complete — is the supported drain path; `System.Posix.Signals`
  (package `unix`) provides the handler installation. After `runSettings` returns, the
  `finally`-attached resource release from EP-34 (pool release) runs, which is exactly
  why EP-34 installed it.
  Date: 2026-07-07
- Decision: In process-compose, run `en-server` via `just start-server` with
  `availability.restart: on_failure` and an `http_get` readiness probe on `/readyz`.
  Rationale: `just start-server` already chains `run-migrations` and inherits the dev
  shell environment, so the process definition stays one line of command; the probe
  makes `process-compose up` block meaningfully on real readiness instead of the
  current curl-accepts-404 loop in `Justfile:start-and-test` (which this plan also
  fixes to hit `/healthz` and require 200).
  Date: 2026-07-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

en is a Haskell workspace at `/Users/shinzui/Keikaku/bokuno/en` (cabal, GHC 9.12.4).
The standalone service is `en-server/app/Main.hs`: it parses environment variables,
loads a schema, connects to PostgreSQL, builds `runAppIO :: Eff AppEffects a -> IO
(Either EnError a)` (the natural transformation that runs the effect stack — the
`AppEffects` list in `en-servant/src/En/Servant/Seam.hs` includes the `Database` effect
from `en-postgres/src/En/Postgres/Database.hs`), assembles the Servant `Env`, prints a
few startup lines with `Text.putStrLn`, and ends in a `serve` call.

Since EP-34 and EP-35 landed, that tail is
`serve tlsConfig port wrappedApp \`finally\` Pool.release pool`, where
`wrappedApp = authMiddleware authConfig (rateLimit (appWithOpenApi serverEnv))`. Note
`appWithOpenApi` (from `en-servant/src/En/Servant/OpenApi.hs`), **not** the bare `app`
from `En.Servant.API`: it serves the six operations plus `GET /v1/openapi.json`, and it
installs the `ErrorFormatters` that make body-parse and 404 errors emit the
`{code, message, retryable}` envelope. Wrapping `app` instead would silently drop both.

Definitions for this plan. A **WAI middleware** is a function
`Application -> Application` wrapping the whole HTTP app; the outermost middleware sees
requests first. **Liveness** (`/healthz`) answers "is the process able to serve HTTP at
all"; **readiness** (`/readyz`) answers "should a load balancer send this instance
traffic right now". **Graceful shutdown** means: on SIGTERM stop accepting connections,
finish requests already in flight (up to a timeout), then exit cleanly. The
**Prometheus text exposition format** is the plain-text metrics format scraped by
Prometheus: lines like `en_http_requests_total{path="check",status="2xx"} 42`, with
`# HELP`/`# TYPE` comment headers. A **request id** is a per-request UUID minted at the
edge, echoed in the response `X-Request-Id` header and in every log line, so one request
can be traced across systems.

What exists to build on:

- `En.Cache` (`en-core/src/En/Cache.hs`) exposes
  `cacheStats :: Cache key value -> IO CacheStats` with fields `hits`, `misses`,
  `inserts`, `evictions`. `Main.hs` already holds the two caches it creates
  (`tupleReadCache :: Cache TupleReadKey TuplePage`,
  `decisionCache :: Cache SubproblemKey CheckDecision`) — the metrics endpoint reads
  them directly.
- `En.Postgres.Database.runSession :: (Database :> es) => Session a -> Eff es (Either
  SessionError a)` — the readiness ping is `runAppIO (runSession (Session.script
  "SELECT 1"))`, whose result is `Either EnError (Either SessionError ())`; both `Left`
  layers mean "not ready".
- Warp (`warp-3.4`) provides `runSettings`, `setPort`, `setGracefulShutdownTimeout ::
  Maybe Int -> Settings -> Settings` (seconds), and `setInstallShutdownHandler :: (IO ()
  -> IO ()) -> Settings -> Settings`.
- `wai-extra` (already in the dependency closure) provides
  `Network.Wai.Middleware.RequestLogger` (`mkRequestLogger`, `outputFormat =
  CustomOutputFormatWithDetails formatAsJSON` with `formatAsJSON` from
  `Network.Wai.Middleware.RequestLogger.JSON`).
- The `uuid` package (in the closure) provides `Data.UUID.V4.nextRandom`.
- `process-compose.yaml` currently defines only `postgres` (with an `exec` readiness
  probe) plus two helper processes; `Justfile` recipes `process-up`, `start-server`,
  `start-and-test` (whose wait loop curls `/` and accepts any response), and
  `test-server` drive it.

Sibling-plan integration, restated from
`docs/masterplans/6-production-harden-the-en-service.md`: this plan has soft
dependencies on EP-34 (readiness should exercise the pool — automatic, since the ping
goes through the `Database` effect and uses whatever runner `Main.hs` wires) and EP-35
(error bodies of `/readyz` should use the typed envelope once it exists; until then the
minimal `{"error": …, "code": …}` object). EP-33 owns the auth/rate-limit middlewares
and their order ahead of this plan's logger; the composed order is spelled out in the
Decision Log above. Four sibling plans edit `en-server/app/Main.hs` — keep this plan's
`Main.hs` diff a compact block (settings + middleware composition) and land milestones
whole.


## Plan of Work

Five milestones: probes, shutdown, logging, metrics, orchestration. Each is
independently observable with curl or `kill`.


### Milestone 1: /healthz and /readyz

Scope: a new module `en-server/app/Health.hs` (add to `other-modules` in
`en-server/en-server.cabal`; add `wai`, `http-types`, `aeson`, and `bytestring` to
`build-depends` if EP-33 has not already) providing a WAI layer:

```haskell
-- en-server/app/Health.hs
healthRoutes :: IO Bool -> Middleware
healthRoutes checkReady inner request respond =
    case (requestMethod request, pathInfo request) of
        ("GET", ["healthz"]) ->
            respond (jsonResponse status200 [("status", "ok")])
        ("GET", ["readyz"]) -> do
            ready <- checkReady
            respond $ if ready
                then jsonResponse status200 [("status", "ok")]
                else jsonResponse status503 [("status", "unavailable"), ("reason", "database unreachable")]
        _ -> inner request respond
```

(`jsonResponse` builds a `responseLBS` with `Content-Type: application/json` from an
aeson object.) In `Main.hs`, define the readiness action next to `runAppIO`:

```haskell
let checkReady :: IO Bool
    checkReady = do
        result <- runAppIO (runSession (Session.script "SELECT 1"))
        pure (case result of Right (Right ()) -> True; _ -> False)
```

and wrap the app: `healthRoutes checkReady (appWithOpenApi serverEnv)` (placed *inside*
the EP-33 middlewares if present — auth already exempts these two paths — and *outside*
the Servant app). Use `appWithOpenApi`, not `app`; see Context and Orientation. Update
the `Justfile` `start-and-test` wait loop to
`curl -fsS "$url/healthz"` (the `-f` makes a 404 fail, so the loop now proves real
readiness of this feature too).

Acceptance: `curl -s localhost:8080/healthz` returns
`{"status":"ok"}` with 200; `curl -s -o /dev/null -w "%{http_code}" localhost:8080/readyz`
prints `200` with PostgreSQL up and `503` within a few seconds of
`pg_ctl stop -D "$PGDATA"` — and `200` again after `pg_ctl start` (with EP-34's pool
this recovery needs no server restart; with the pre-EP-34 single connection the 503
correctly persists, which is finding A2's problem, not this plan's).


### Milestone 2: Graceful shutdown on SIGTERM

Scope: `Main.hs` switches from `Warp.run` to `Warp.runSettings` with shutdown plumbing.
At the end, SIGTERM produces a clean drain-and-exit.

```haskell
import System.Posix.Signals (Handler (Catch), installHandler, sigTERM, sigINT)

let settings =
        Warp.setPort port
            . Warp.setGracefulShutdownTimeout (Just 30)
            . Warp.setInstallShutdownHandler
                (\closeSocket -> do
                    _ <- installHandler sigTERM (Catch closeSocket) Nothing
                    _ <- installHandler sigINT (Catch closeSocket) Nothing
                    pure ())
            $ Warp.defaultSettings
Warp.runSettings settings wrappedApp
Text.putStrLn "en-server: drained in-flight requests; shutting down"
```

Add `unix` to `en-server`'s `build-depends`. `runSettings` now *returns* after the
socket closes and in-flight requests finish, so any `finally`/cleanup after it (EP-34's
pool release; EP-37's maintenance-thread cancellation) actually runs — state this in a
comment at the call site because it is the contract sibling plans rely on. The process
then exits 0.

Acceptance: start the server, hold a slow request open (a `/v1/lookup` with a generous
`deadlineMillis` against a large fixture, or simply observe the fast path), send
`kill -TERM <pid>`; the server stops accepting new connections (subsequent curl:
connection refused), the in-flight request completes with 200, the shutdown line prints,
and `echo $?` on the foreground process shows `0`. Repeat with Ctrl-C (SIGINT) — same
behavior.


### Milestone 3: Request ids and structured request logging

Scope: two middlewares in a new `en-server/app/Observability.hs` (or extend
`Health.hs`; pick one and record it) — `requestIdMiddleware` and the configured
wai-extra logger. At the end every handled request emits one JSON log line and carries
`X-Request-Id`.

`requestIdMiddleware :: Middleware` — for each request: take the inbound `X-Request-Id`
if present (trusted deployments put a proxy in front; the ops doc says to strip it at
the edge if untrusted) else `Data.UUID.V4.nextRandom`; rewrite the request headers to
carry it; add it to the response headers via `mapResponseHeaders`.

Logger — built once in `main`:

```haskell
logger <- mkRequestLogger def
    { outputFormat = CustomOutputFormatWithDetails formatAsJSON
    , destination = Handle stdout
    }
```

`formatAsJSON` (from `Network.Wai.Middleware.RequestLogger.JSON`, `wai-extra`) includes
request headers in its output, so `X-Request-Id` (M3) and `X-En-Caller` (EP-33's
verified-caller header) appear in every line without custom formatting; verify this
against the actual output and, if headers are absent in the emitted JSON, switch to a
small custom `OutputFormatterWithDetails` that emits
`{"time":…,"requestId":…,"caller":…,"method":…,"path":…,"status":…,"durationMs":…}` —
record which branch was taken in Surprises & Discoveries. Compose per the master-plan
order (outermost first): EP-33 auth → EP-33 rate limit → `requestIdMiddleware` →
`logger` → `healthRoutes` → metrics (M4) → Servant app. Health probes hitting
`/healthz`/`/readyz` every few seconds would flood the log — exclude those two paths
from the logger (wrap it: bypass when `pathInfo` matches).

Acceptance: one `POST /check` (or `/v1/check` post-EP-35) produces exactly one stdout
JSON line containing the method, path, status 200, a duration, and the same
`X-Request-Id` value the response header carried; probe requests produce no lines.


### Milestone 4: /metrics

Scope: `en-server/app/Metrics.hs` — a counter store, a recording middleware, and the
rendering route. At the end Prometheus can scrape request and cache metrics.

The store: `newtype Metrics = Metrics (IORef (Map (Text, Text) RequestStats))` where the
key is (path-group, status-class) — path-group is the first meaningful path segment
(`check`, `batch-check`, `lookup`, `expand`, `relationships`, `healthz`, `readyz`,
`other`) so label cardinality stays bounded, status-class is `2xx`/`4xx`/`5xx` — and
`RequestStats { count :: !Int, totalDurationNs :: !Word64 }`. The middleware measures
with `GHC.Clock.getMonotonicTimeNSec` around the inner app and bumps the map with
`atomicModifyIORef'`.

The route (inside `healthRoutes`-style dispatch or its own layer): `GET /metrics`
renders, in Prometheus text format with `# TYPE` headers:

```text
# TYPE en_http_requests_total counter
en_http_requests_total{path="check",status="2xx"} 42
# TYPE en_http_request_duration_seconds_sum counter
en_http_request_duration_seconds_sum{path="check",status="2xx"} 1.234
en_http_request_duration_seconds_count{path="check",status="2xx"} 42
# TYPE en_cache_hits_total counter
en_cache_hits_total{cache="decision"} 10
en_cache_misses_total{cache="decision"} 3
en_cache_inserts_total{cache="decision"} 3
en_cache_evictions_total{cache="decision"} 0
en_cache_hits_total{cache="tuple_read"} …
```

Cache lines come from `cacheStats decisionCache` / `cacheStats tupleReadCache` at scrape
time (pass the two caches into the metrics renderer from `Main.hs`). Content type:
`text/plain; version=0.0.4`. `/metrics` is *not* auth-exempt (Decision Log) — document
scraping with a read-only EP-33 key.

Acceptance: after running `just test-server`, `curl -s localhost:8080/metrics` (with
auth header if EP-33 is active) shows nonzero `en_http_requests_total` for the exercised
paths and cache counters consistent with a second scrape after repeating a check
(decision-cache hits increase when `EN_DECISION_CACHE_MAX_ENTRIES > 0`).


### Milestone 5: process-compose and docs

Scope: dev orchestration catches up. Append to `process-compose.yaml`:

```yaml
  en-server:
    command: "just start-server"
    availability:
      restart: on_failure
    depends_on:
      postgres:
        condition: process_healthy
    readiness_probe:
      http_get:
        host: 127.0.0.1
        port: 8080
        path: /readyz
      initial_delay_seconds: 5
      period_seconds: 5
      timeout_seconds: 3
      failure_threshold: 12
```

(`just start-server` runs migrations first and inherits `EN_DATABASE_URL` from the dev
shell; the generous `failure_threshold × period` budget covers a cold `cabal run`
build. If EP-33 is landed, the recipe/environment must provide `EN_API_KEYS_*` or
`EN_AUTH_DISABLED=true` for dev.) Note that `just process-up`'s existing wait loop only
watches PostgreSQL; that remains correct.

Update `docs/user/service-and-operations.md`: document `/healthz`, `/readyz`,
`/metrics` (with the metric names above), the JSON request-log shape, `X-Request-Id`
semantics, and SIGTERM behavior (drain, 30 s cap, exit 0).

Acceptance: from a clean state, `just process-down && just process-up && process-compose
--unix-socket .dev/process-compose.sock process list` shows `en-server` `Running` and
`Ready`; `just test-server` passes against it.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/en` in the nix dev shell.

Build after each milestone:

```bash
cabal build en-server
```

Probes (M1):

```bash
just process-up && just run-migrations
EN_DATABASE_URL="$PG_CONNECTION_STRING" cabal run en-server &
sleep 20   # first build may compile
curl -s localhost:8080/healthz; echo
curl -s -o /dev/null -w "readyz=%{http_code}\n" localhost:8080/readyz
pg_ctl stop -D "$PGDATA"
curl -s -o /dev/null -w "readyz=%{http_code}\n" localhost:8080/readyz
pg_ctl start -w -l "$PGLOG" -o "--unix_socket_directories='$PGHOST'" -o "-c listen_addresses=''"
curl -s -o /dev/null -w "readyz=%{http_code}\n" localhost:8080/readyz
```

Expected:

```text
{"status":"ok"}
readyz=200
readyz=503
readyz=200
```

Graceful shutdown (M2), with the server in the foreground of terminal 1:

```bash
# terminal 2
SERVER_PID=$(pgrep -f "en-server" | head -1)
kill -TERM "$SERVER_PID"
curl -s -o /dev/null -w "%{http_code}\n" localhost:8080/healthz || echo refused
```

Expected: terminal 1 prints `en-server: drained in-flight requests; shutting down` and
exits with status 0; terminal 2 prints `refused` (or a 000/`curl: (7)` connection
failure).

Logging and metrics (M3/M4), server running again:

```bash
just test-server
curl -s localhost:8080/metrics | grep -E 'en_http_requests_total|en_cache_hits_total' | head
```

Expected: the server's stdout shows one JSON object per smoke-test request, each with an
`X-Request-Id` value matching its response header; the metrics grep shows counters like:

```text
en_http_requests_total{path="check",status="2xx"} 1
en_cache_hits_total{cache="decision"} 0
```

Orchestration (M5):

```bash
just process-down
just process-up
process-compose --unix-socket .dev/process-compose.sock process list
just test-server
```

Expected: the process list shows `postgres` and `en-server` both `Running`, `en-server`
ready; the smoke test passes.

(Adjust curl paths/bodies to EP-35's `/v1` shapes and add EP-33's auth header if those
plans have landed; `just test-server` is kept current by whichever plan lands.)


## Validation and Acceptance

Acceptance, all phrased as observable behavior:

1. `GET /healthz` → 200 `{"status":"ok"}` whenever the process accepts connections,
   including while PostgreSQL is down.
2. `GET /readyz` → 200 with PostgreSQL reachable; → 503 with body naming the database
   while it is stopped; recovers to 200 without an en-server restart (given EP-34).
3. `kill -TERM` → no new connections accepted, in-flight requests complete, log line
   `drained in-flight requests`, exit code 0. A request issued *after* SIGTERM is
   refused, not 500'd.
4. Every non-probe request yields exactly one JSON stdout line with method, path,
   status, duration, and request id equal to the `X-Request-Id` response header;
   supplying `X-Request-Id: test-123` on the request echoes `test-123` back.
5. `GET /metrics` returns `text/plain` Prometheus counters; `en_http_requests_total`
   increments across scrapes as requests are made; `en_cache_*_total{cache="decision"}`
   moves when the decision cache is enabled and a check repeats.
6. `just process-up` yields a `Ready` en-server in `process-compose process list`, and
   the Justfile wait loop fails fast (non-zero) if the server never becomes healthy
   instead of accepting a 404.
7. Regressions: `cabal build all`, `cabal test en-servant`, `just start-and-test` all
   pass.


## Idempotence and Recovery

Everything here is process-local and repeatable: probes are read-only; the metrics store
and request-id state are in-memory and reset on restart; signal handling can be
exercised repeatedly by restarting the server. `pg_ctl stop`/`start` on the dev database
is safe and reversible (if process-compose's supervisor disagrees after out-of-band
stops, `just process-down && just process-up` resets it). The process-compose edit is
additive YAML — reverting it restores the previous dev topology. No database schema or
wire-contract changes are made by this plan, so no coordination with stored state is
needed. If the wai-extra JSON formatter proves unsuitable (M3 fallback), the custom
formatter is a contained swap inside `Observability.hs`.


## Interfaces and Dependencies

New modules (all under `other-modules` of `executable en-server` in
`en-server/en-server.cabal`):

```haskell
-- en-server/app/Health.hs
healthRoutes :: IO Bool -> Network.Wai.Middleware   -- /healthz, /readyz dispatch

-- en-server/app/Observability.hs
requestIdMiddleware :: Network.Wai.Middleware
mkJsonRequestLogger :: IO Network.Wai.Middleware    -- wai-extra config, probe paths excluded

-- en-server/app/Metrics.hs
data Metrics
newMetrics :: IO Metrics
metricsMiddleware :: Metrics -> Network.Wai.Middleware          -- record count+duration
metricsRoute ::
    Metrics ->
    En.Cache.Cache En.Cache.TupleReadKey En.Effect.TupleStore.TuplePage ->
    En.Cache.Cache En.Cache.SubproblemKey En.Check.CheckDecision ->
    Network.Wai.Middleware                                       -- GET /metrics
```

`en-server/app/Main.hs` changes: `checkReady` definition, Warp `Settings` (graceful
shutdown), middleware composition in the master-plan order, passing the two caches to
`metricsRoute`.

Dependencies added to `en-server`: `wai`, `http-types`, `bytestring`, `aeson` (shared
with EP-33 — add once), `wai-extra` (request logger), `uuid` (request ids), `unix`
(signals). All are on Hackage and already present in the project's transitive closure.
Effects consumed: `En.Postgres.Database.runSession` through `runAppIO` — no new effects,
honoring the master-plan rule that the readiness probe calls through the `Database`
effect and never holds a raw connection.

Files edited: `en-server/app/Main.hs`, `en-server/en-server.cabal`,
`process-compose.yaml`, `Justfile` (wait loop), `docs/user/service-and-operations.md`.
Files added: `en-server/app/Health.hs`, `en-server/app/Observability.hs`,
`en-server/app/Metrics.hs`.
