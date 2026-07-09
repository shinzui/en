---
id: 6
slug: production-harden-the-en-service
title: "Production-harden the en service"
kind: master-plan
created_at: 2026-07-07T15:24:21Z
intention: intention_01kx21nk4kemtt6pjnb5tr76nk
---

# Production-harden the en service

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

en's standalone server (`en-server`) is currently a prototype shell around a strong
engine: its HTTP API is completely unauthenticated, all database work funnels through a
single hasql connection, every engine error becomes an opaque HTTP 500, there are no
health endpoints or metrics, background garbage collection is never scheduled, and its
datastore identity is a hardcoded string. This initiative makes `en-server` deployable
as a real authorization microservice. After it is complete, an operator can run
`en-server` behind a load balancer with confidence: callers must authenticate before
touching any endpoint and write endpoints can be restricted separately; the server
survives PostgreSQL restarts and serves concurrent traffic through a connection pool;
clients receive stable, versioned wire responses with machine-readable error codes that
distinguish client faults from server faults; orchestrators can probe liveness and
readiness and get clean graceful shutdown on SIGTERM; soft-deleted tuples and the
`en_transaction` table are pruned automatically on a schedule; and two en deployments
can never mint interchangeable consistency tokens because datastore identity is minted
once and persisted in the database.

The findings driving this initiative are Theme A (A1–A9) plus the operational storage
items C2 and C4 of `docs/reviews/2026-07-07-architecture-performance-review.md`. Out of
scope: engine evaluation fixes (master plan
`docs/masterplans/7-fix-the-en-evaluation-engine.md`), write-path semantics
(`docs/masterplans/8-correct-write-path-and-storage-semantics.md`), new API features
such as read-relationships or watch
(`docs/masterplans/9-complete-the-en-api-surface.md`), and Biscuit hardening
(`docs/masterplans/10-harden-the-biscuit-decision-token-layer.md`). Horizontal scaling,
distributed caching, and gRPC remain explicit non-goals per `docs/spec/0001-en-overview.md`.


## Decomposition Strategy

The work splits along independently deployable operational concerns, each verifiable on
its own against a running server. Authentication (EP-33) is the critical finding (A1)
and is isolated so it can ship first without waiting on any other stream. Connection
pooling (EP-34) is a self-contained swap of the `Database` effect's runner from a single
`Connection` to `hasql-pool` and is a soft prerequisite for everything that adds load or
background work. The wire contract (EP-35) groups error typing (A3), versioning and
constructor-name leaks (A5), and OpenAPI generation (E11) because they are all breaking
changes to the same JSON surface and should break clients exactly once. Operability
(EP-36) groups health probes, graceful shutdown, structured request logging, and a
metrics endpoint because they share Warp middleware and settings plumbing. Background
maintenance (EP-37) pairs the never-scheduled tuple reaper (C4) with `en_transaction`
indexing and pruning (C2) because both run in the same scheduled job and share the GC
horizon. Configuration hardening (EP-38) collects persisted datastore identity (A6),
config validation, and deadline/batch-limit configurability (A7) because they all touch
`en-server/app/Main.hs` startup.

An alternative decomposition by finding severity (one plan per CRITICAL/HIGH finding,
one sweep plan for MED/LOW) was rejected: it would scatter edits to the same modules
(`Main.hs`, `Seam.hs`) across many plans and make later plans depend on earlier ones
merely because they touch the same lines, not because of real artifact dependencies.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-33 | Add caller authentication and rate limiting to en-server | docs/plans/33-add-caller-authentication-and-rate-limiting-to-en-server.md | None | None | Complete |
| EP-34 | Pool database connections in en-server | docs/plans/34-pool-database-connections-in-en-server.md | None | None | Complete |
| EP-35 | Version the wire contract and type the error model | docs/plans/35-version-the-wire-contract-and-type-the-error-model.md | None | None | Complete |
| EP-36 | Add health endpoints, graceful shutdown, and observability | docs/plans/36-add-health-endpoints-graceful-shutdown-and-observability.md | None | EP-34, EP-35 | Complete |
| EP-37 | Schedule background maintenance for reaping and transaction pruning | docs/plans/37-schedule-background-maintenance-for-reaping-and-transaction-pruning.md | None | EP-34 | Complete |
| EP-38 | Validate configuration and persist datastore identity | docs/plans/38-validate-configuration-and-persist-datastore-identity.md | None | None | In Progress |


## Dependency Graph

There are no hard dependencies inside this master plan; every child compiles and is
verifiable on the current codebase. EP-33, EP-34, EP-35, and EP-38 can proceed fully in
parallel provided the integration points below are respected. EP-36 has soft
dependencies on EP-34 (its readiness probe should exercise the connection pool rather
than a single connection, but can stub against the current single connection and be
revisited) and on EP-35 (health/error responses should use the typed error envelope once
it exists). EP-37 has a soft dependency on EP-34 because a background maintenance loop
sharing one un-pooled connection with request traffic would serialize against it; if
implemented first, EP-37 should acquire its own dedicated connection and switch to the
pool later.

Because four of six plans edit `en-server/app/Main.hs`, implementers should land plans
one at a time (any order among the parallel-safe ones) rather than in long-lived
branches, to keep rebases trivial.


## Integration Points

`en-server/app/Main.hs` (startup and Warp wiring) is touched by EP-33 (auth middleware),
EP-34 (pool acquisition), EP-36 (Warp settings, middleware stack, health routes), EP-37
(background thread forking), and EP-38 (config parsing). EP-38 defines the shared
`ServerConfig`-style record that centralizes environment parsing; the other plans should
read their knobs (auth mode, pool size, timeouts, maintenance interval) through that
record when it exists, or add individually-parsed env vars that EP-38 later absorbs.
Whichever plan lands first establishes the middleware composition order; auth must run
before request logging records a caller identity, and rate limiting must run after auth
(so limits can be per-caller).

The `Database` effect and its runner (`en-postgres/src/En/Postgres/Database.hs`,
currently `runDatabaseConnection :: Connection -> …`) is redefined by EP-34 to run
against a `hasql-pool` `Pool`. EP-36 (readiness probe) and EP-37 (maintenance session)
consume whatever runner EP-34 defines; both plans must call through the effect rather
than holding a raw `Connection`.

The typed error envelope (new wire type in `en-servant/src/En/Servant/API.hs` plus the
mapping in `en-servant/src/En/Servant/Seam.hs`) is defined by EP-35. EP-33 must emit its
401/403/429 responses in the same envelope shape (if EP-35 has not landed yet, EP-33
uses a minimal `{"error": …, "code": …}` object and EP-35 reconciles).

EP-35 also makes each operation a Servant `MultiVerb` whose response alternatives
enumerate its statuses (200/400/422/503), so handler errors are part of the API type
and appear in the generated OpenAPI document. Two consequences for siblings. First,
`en-client`'s operations return `ClientM (EnResult X)`; any plan calling the Haskell
client pattern-matches `EnResult` rather than catching a `ClientError` for engine
faults. Second, MultiVerb reaches only errors a *handler* produces: EP-33's
middleware-level 401/403/429 and Servant's routing-level 404/405/415/malformed-body are
outside it, and stay normalized into the same envelope by `ErrorFormatters` and by
EP-33's own response builders. Any new endpoint added by
`docs/masterplans/9-complete-the-en-api-surface.md` should be a `MultiVerb` endpoint
over EP-35's shared `EnResponses` list.

codd migrations under `en-migrations/db/migrations/` were to be added by EP-37 (index on
`en_transaction (created_at, xid)`) and EP-38 (new datastore-metadata table).
**EP-37 added none**: measurement showed the planner never chooses that index, and
pruning fixes the horizon query instead (see EP-37's Decision Log). EP-38 is therefore
the only child adding a migration, and the collision concern is moot.

Cross-master-plan: EP-35's versioned wire contract is the surface that
`docs/masterplans/9-complete-the-en-api-surface.md` extends with new endpoints; new
endpoints added there must live under the same version prefix and error envelope. EP-37
prunes `en_transaction` behind the GC horizon; the watch API
(docs/plans/53-add-a-watch-changelog-api.md) reads history and must bound its cursor
recovery by the same horizon.


## Progress

- [x] EP-33: authentication required on every endpoint; unauthenticated requests get 401
- [x] EP-33: write endpoints separately authorizable; rate limiting active
- [x] EP-34: en-server serves concurrent requests through hasql-pool and survives a PostgreSQL restart
- [x] EP-35: versioned path prefix and stable field names on all endpoints; constructor tags gone
- [x] EP-35: typed error envelope with machine-readable codes; 4xx/5xx split correct; OpenAPI document served
- [x] EP-35: handler errors are MultiVerb response alternatives, documented per operation in OpenAPI
- [x] EP-36: /healthz and /readyz respond correctly; SIGTERM drains in-flight requests
- [x] EP-36: structured request logs and a metrics endpoint (including cache stats) exposed
- [x] EP-37: reaper and en_transaction pruning run on a schedule with batched deletes
- [x] EP-37: en_transaction horizon query no longer scans lifetime writes — achieved by
  pruning, not by an index; the planned index was proven dead weight and cancelled
- [ ] EP-38: datastore identity minted once, persisted, and used in tokens
- [ ] EP-38: all config validated at startup with clear failures; deadlines and batch limits configurable


## Surprises & Discoveries

From EP-33 (2026-07-08), affecting sibling plans:

- **The `memory` package is deprecated; use `ram`.** EP-33's plan text specified `memory`
  for `Data.ByteArray.constEq`. `ram` (jappeace/ram) is the maintained fork with an
  identical module and API surface, so only `build-depends` changes. Verified against
  `ram-0.22.0` on GHC 9.12.4. Any sibling plan reaching for constant-time comparison or
  byte-array primitives — notably EP-38 when it mints a datastore identity, and the
  Biscuit hardening in `docs/masterplans/10-harden-the-biscuit-decision-token-layer.md` —
  should depend on `ram`. Watch for a `Data.ByteArray` module clash in any component that
  also pulls the crypton/biscuit chain, which may still supply `memory`.

- **`en-server` block-buffers stdout, so startup logs vanish under a supervisor.**
  Running the binary with stdout redirected to a file produced a zero-byte log while the
  server was demonstrably live and answering requests. `Main.hs` never calls
  `hSetBuffering`. This silently swallows the `WARNING: authentication is DISABLED` line
  that EP-33 prints — exactly the line an operator must not miss. **EP-36 owns the fix**
  (`hSetBuffering stdout LineBuffering` at the top of `main`) and must do it before its
  structured request logging is trustworthy, since that logging will otherwise be
  invisible in production too.

- **Configuration failures surface as uncaught `IOException`s.** Every config error in
  `Main.hs` goes through `fail`, so the operator sees
  `en-server: Uncaught exception … user error (…)` wrapped around an otherwise good
  message. Exit code is 1 and no port is bound, so behavior is correct. **EP-38 owns the
  fix** when it centralizes parsing into `ServerConfig`: render the message and exit
  cleanly rather than throwing.

- **The middleware composition order is now established**, as the master plan's
  Integration Points required: `authMiddleware` outermost, then `rateLimitMiddleware`,
  then `app serverEnv`, in `en-server/app/Main.hs`. Authentication writes the verified
  caller name to an `X-En-Caller` request header (stripping any client-supplied value
  first), and the rate limiter reads it to key its per-caller buckets. **EP-36's request
  logging should read the same header** to attribute a request to a caller, and must be
  composed inside authentication to see it.

- **`/healthz` and `/readyz` are already exempt** from both authentication and rate
  limiting; they currently return Servant's 404. EP-36 need only add the routes — no
  middleware change. `/metrics` is deliberately *not* exempt, so a scraper must present
  a bearer key.

- **EP-35 must update one predicate.** `isWriteRequest` in `en-server/app/Middleware.hs`
  matches `pathInfo == ["tuples"]` with `POST`/`DELETE`. When EP-35 moves writes to
  `POST /v1/relationships` and `POST /v1/relationships/delete`, that predicate must move
  with them, or read-only keys silently regain write access. EP-35 also reconciles the
  interim `{"error", "code"}` envelope that EP-33's 401/403/429 bodies use.

- **Rate-limit buckets are keyed by API key name and never evicted.** Safe today (the key
  set is bounded by configuration, plus one shared `"anonymous"` bucket). If any later
  plan re-keys buckets by client IP, it must add eviction or it becomes an unbounded
  memory leak.

From EP-34 (2026-07-08), affecting sibling plans:

- **The `Database` runner is now `runDatabasePool :: Pool -> Eff (Database : es) a -> Eff es a`**
  (`en-postgres/src/En/Postgres/Database.hs`), and `en-server/app/Main.hs` builds its
  `runAppIO` from it. `runDatabaseConnection` still exists for the integration test. As
  the Integration Points required, **EP-36's readiness probe and EP-37's maintenance
  session must call through the `Database` effect** and never hold a raw `Connection`.

- **Every `runSession` is a separate `Pool.use`, so a single HTTP request now spans
  several PostgreSQL connections.** This was invisible under the single-connection
  runner. It is safe — en pins reads to an explicit revision and evaluates visibility
  with `pg_visible_in_snapshot`, so nothing depended on a shared session snapshot — but
  **EP-37 must not assume its `oldestRetainedXidSession` and `reapDeletedTuplesSession`
  share a connection or a snapshot**, and no plan may express session-local state
  (advisory locks, `SET LOCAL`, temp tables) across two `runSession` calls.

- **After a PostgreSQL restart, each stale pooled connection fails two requests, not
  one.** `hasql-pool` discards a connection only on a connection-level error; the first
  session on a dead socket returns a *statement*-level error whose text is actively
  misleading (`Unexpected number of rows … expectedMin: 1, expectedMax: 1, actual: 1`),
  so the dead connection goes back into the pool and fails once more before being
  dropped. Measured `2 × (established connections)` at both 3 and 5 connections.
  **EP-35 must therefore classify `retryable` by `SessionError` constructor, never by
  message text** — that first error reads like a row-decoding bug and is in fact a
  transient connection failure. Note `Hasql.Errors.isTransient` also returns `False` for
  it, so it cannot be the sole signal either. **EP-36's readiness probe** should tolerate
  one failure before flipping to unready, or it will flap after a database restart and
  may consume the "free" first failure that a real request would otherwise absorb.

- **`just test-server` cannot prove database-recovery behavior.** Its opening
  `curl -sS -X DELETE .../tuples >/dev/null` has no `--fail` and no status check, so a
  `500` there is silently swallowed. It passed on the first attempt after a restart while
  direct `/check` probes were still returning `500`. Any plan using `just test-server` as
  a health signal should know it under-reports; EP-36, which adds real health endpoints,
  is the natural place to stop relying on it.

- **`Warp.run`/`WarpTLS.runTLS` moved out of `main` into a top-level
  `serve :: Maybe TlsConfig -> Int -> Wai.Application -> IO ()`**, and `main` now ends
  with `serve tlsConfig port wrappedApp \`finally\` Pool.release pool`. **EP-36 adds
  graceful shutdown inside `serve`**, not in `main`; the `finally` that releases the pool
  becomes load-bearing at that moment (today `Warp.run` never returns normally).

- **EP-34 confirmed EP-33's block-buffered-stdout finding.** With stdout redirected to a
  file and the process ended by SIGTERM, *no* startup line appears — including the new
  `Connection pool: size=…` line. The same run under a pty prints all of them. EP-36's
  `hSetBuffering stdout LineBuffering` remains necessary and now hides operational
  configuration, not just the auth warning.


From EP-35 (2026-07-08), affecting sibling plans:

- **The error envelope is `{"code", "message", "retryable"}`, and every response in the
  service now uses it** — engine faults, validation failures, Servant's body-parse and
  404 errors, and EP-33's `unauthenticated`/`permission_denied`/`rate_limited` middleware
  bodies, which EP-35 reconciled from their interim `{"error", "code"}` shape.
  `en-server/app/Middleware.hs` writes the envelope by hand (a WAI middleware has no
  `ServerError` to attach), so **any plan changing the envelope must change both it and
  `En.Servant.Seam.ErrorEnvelopeWire`.** `retryable` is the whole retry contract: it is
  `true` only for `store_error` and `rate_limited`.

- **EP-35 completed the write-route predicate hand-off.** `isWriteRequest` in
  `en-server/app/Middleware.hs` now prefix-matches `"v1" : "relationships" : _` with
  `POST`, covering both write routes and any future sub-route under that prefix. EP-33's
  warning is discharged.

- **Handler errors are `MultiVerb` response alternatives, so `en-client` returns
  `ClientM (EnResult X)`.** Any plan calling the Haskell client pattern-matches `EnOk` /
  `EnClientError` / `EnUnprocessable` / `EnUnavailable`; a `ClientError` now means only a
  transport failure or a pre-handler rejection (bad key, unmatched route, malformed body).
  **New endpoints — notably those in `docs/masterplans/9-complete-the-en-api-surface.md`
  — should be `MultiVerb` endpoints over `En.Servant.API.EnResponses`**, or their error
  responses will be absent from `/v1/openapi.json` and untyped in the client.

- **`en-server` now serves `En.Servant.OpenApi.appWithOpenApi`, not `En.Servant.API.app`.**
  `appWithOpenApi` serves `ServedAPI` (the six operations plus `GET /v1/openapi.json`) and
  installs the `ErrorFormatters` that make body-parse and 404 errors speak the envelope.
  **EP-36 and EP-37 must wrap that application**, not `app`, or the server loses its
  description route and its JSON 404s. `app` remains for embedded hosts.

- **`405` and `415` still return empty bodies, and `ErrorFormatters` cannot reach them.**
  Servant raises both outside the formatter hooks. EP-35 declined to add an outermost WAI
  middleware rewriting bodyless 4xx into the envelope, because **EP-36 owns the middleware
  stack** in `en-server/app/Main.hs`. If EP-36 wants uniformity, that rewrite is where it
  belongs; it is otherwise a low-value fix, since both statuses mean the caller used the
  wrong verb or content type.

- **EP-35 discharged EP-34's retryability warning.** EP-34 recorded that a PostgreSQL
  restart's first failure per stale connection is a *statement*-level error whose text
  reads like a row-decoding bug, and warned that retryability must be classified by
  constructor rather than message. `enErrorToFault` classifies on the `EnError`
  constructor, so both failures reach the client as `503 store_error` with
  `"retryable": true`. Verified by stopping PostgreSQL under load.

- **`/v1/openapi.json` requires a bearer key**; only `/healthz` and `/readyz` are exempt.
  A scraper must authenticate. EP-36 should not add the document route to the exempt set.


From EP-36 (2026-07-08), affecting sibling plans:

- **`Warp.runSettings` now returns on SIGTERM/SIGINT, and the `finally` in
  `en-server/app/Main.hs` is live.** `serve` installs a shutdown handler through
  `Warp.setInstallShutdownHandler` and caps the drain at 30 s; `main` still ends with
  ``serve tlsConfig port wrappedApp `finally` Pool.release pool``. EP-34 predicted this
  moment: the pool release actually runs now. **EP-37 must cancel its maintenance thread
  in that same `finally`**, or a drained server will sit waiting on a background loop.

- **The middleware stack is fixed and ordered, outermost first:** `authMiddleware` →
  `rateLimit` → `requestIdMiddleware` → `requestLogger` → `metricsMiddleware` →
  `healthRoutes` → `metricsRoute` → `appWithOpenApi serverEnv`. Anything EP-38 adds
  should read its knobs at startup and not insert a layer without deciding where it sits
  relative to authentication. Note the consequence EP-33 anticipated: the `401`/`403`/`429`
  that auth and rate limiting short-circuit are outside the logger and the metrics
  recorder, so they are neither logged nor counted.

- **`en-server` gained three modules and two dependencies — but not `wai-extra`.**
  `app/Health.hs`, `app/Observability.hs`, `app/Metrics.hs`; `unix` (signals) and `uuid`
  (request ids). EP-36's plan text called for `wai-extra`'s `RequestLogger`; it was
  rejected on inspection because `formatAsJSON` serializes **every request header**,
  redacting only `Cookie`, which would have written each caller's
  `Authorization: Bearer <secret>` to stdout on every request — and because the carrier
  behind `CustomOutputFormatWithDetails` buffers the entire request body and response.
  **Any sibling plan reaching for `wai-extra`'s request logger should not.** The
  hand-rolled logger in `Observability.hs` is ~30 lines.

- **`hSetBuffering stdout LineBuffering` is done**, discharging the warning EP-33 raised
  and EP-34 confirmed. Startup lines and request logs now survive redirection to a file
  and a SIGTERM. Any plan adding startup output can rely on it.

- **The stale-connection cost EP-34 documented is real, and one retry hides it.**
  `checkReady` pings PostgreSQL twice before reporting unready. Verified: after
  `pg_ctl stop` then `pg_ctl start`, the very first `/readyz` returned `200`. **EP-37's
  maintenance loop should expect the same failure on its first session after a database
  restart** and simply run again at its next interval rather than treating one failure
  as fatal.

- **Supervise a pid, not a wrapper.** `process-compose.yaml` now runs `en-server` by
  `exec`ing the binary (`… && exec "$(cabal list-bin en-server)"`). With
  `command: "just start-server"`, process-compose signalled the process group, `just` and
  `cabal run` died first, the recorded exit code was the wrapper's `143` instead of the
  server's `0`, and the drain line was truncated mid-write. **Any plan adding a
  supervised process should exec its binary.** Also: `.dev/process-compose.log` stays
  empty in detached mode — read process output with
  `process-compose … process logs <name>`.

- **`just start-and-test` no longer starts a server**; it waits on `/healthz` and drives
  the process-compose `en-server`. Adding the supervised process made the old recipe bind
  port 8080 twice. `just start-server` still runs a standalone server. **EP-38 uses
  `just start-and-test` as a regression gate** and should know its dev key is
  `dev:dev-secret-0123456789`, now set in `process-compose.yaml` rather than the recipe.

- **`En.Cache` sets `NoFieldSelectors`**, so `stats.hits` requires
  `import En.Cache (CacheStats (..))`, not `(CacheStats)`. Importing only the type gives
  a confusing `No instance for HasField "hits"`. The same trap waits in any module that
  disables field selectors.

- **`405` and `415` still return empty bodies.** EP-35 handed this to EP-36 as the owner
  of the middleware stack; EP-36 declined it deliberately. An outermost rewrite of
  bodyless 4xx would catch any future bodyless response too, and neither status is one a
  client branches on. It remains open, and cheap, for whoever wants uniformity.


From EP-37 (2026-07-08), affecting sibling plans:

- **EP-37 added no migration.** The planned index on `en_transaction (created_at, xid)` is
  never chosen by the planner: PostgreSQL rewrites `min(xid)` into a `Limit 1` over the
  `xid` primary key and prefers it even with one in-window row among 50,001. Pruning is
  what fixes the horizon query (606 buffers / 4.7 ms against a 50k backlog → 2 buffers /
  0.04 ms drained, identical with and without the index). **EP-38 now owns the only
  migration in this master plan**, so the timestamped-filename collision concern is moot.
  If `docs/plans/53-add-a-watch-changelog-api.md` later filters `en_transaction` by
  `created_at` *without* a `min`/`max` aggregate, the index is worth reconsidering on that
  query's own evidence.

- **A background loop must re-throw asynchronous exceptions.** `withAsync`'s `cancel` throws
  `AsyncCancelled`, whose `Exception` instance routes through `asyncExceptionToException`. A
  bare `try @SomeException` around a loop body — which EP-37's plan text specified — catches
  it, logs it, and keeps looping, so the server hangs on shutdown. `Maintenance.hs` filters
  on `fromException @SomeAsyncException` and re-throws. Any later plan adding a background
  thread should copy that shape.

- **EP-36's `finally` is now genuinely load-bearing.** `main` ends in
  ``withAsync (runMaintenanceLoop …) \_ -> serve … `finally` Pool.release pool``. Warp's
  `runSettings` returns on SIGTERM, `withAsync` cancels the loop, and the pool is released.
  Measured: SIGTERM with a maintenance pass mid-flight exits in 0.03 s with status 0.

- **`EN_MAINTENANCE_INTERVAL_SECONDS` and `EN_MAINTENANCE_BATCH_SIZE` are the contract**
  EP-38's `ServerConfig` absorbs. Defaults 600 and 1000; interval `0` disables. Both are
  parsed with the same fail-fast style as the pool knobs, and both currently `fail` — which
  is the uncaught-`IOException` wart EP-38 owns.

- **`en_transaction` can legitimately drain to zero** when no write occurs for a full
  `EN_GC_WINDOW`. The horizon then falls back to `pg_snapshot_xmin(pg_current_snapshot())`,
  which is exactly the value the query returned before the rows were removed — pruning
  cannot move the horizon, because the horizon is computed only from in-window rows. Any
  plan reading history from `en_transaction` (notably the watch API) must not assume the
  table is non-empty.

- **`Statement.preparable` takes `Text`, not `ByteString`.** Trivial, but it is the second
  time a plan's stated dependency signature was wrong (see EP-36 and `wai-extra`).


## Decision Log

- Decision: Group error typing, wire versioning, and OpenAPI generation into one plan (EP-35).
  Rationale: All three are breaking changes to the same JSON surface; clients should migrate once, not three times.
  Date: 2026-07-07
- Decision: Include storage findings C2 and C4 here rather than in the storage master plan.
  Rationale: Both are operational time bombs whose fix is a scheduled job inside en-server plus one migration; the storage master plan (docs/masterplans/8) owns semantic changes to writes, not service wiring.
  Date: 2026-07-07
- Decision: No hard dependencies between children; coordinate through Integration Points instead.
  Rationale: Every plan is independently compilable and verifiable; serializing them would delay the CRITICAL auth fix behind unrelated work.
  Date: 2026-07-07
- Decision: Accept that a PostgreSQL restart costs `2 × (established connections)` failed
  requests rather than adding automatic session retry in EP-34.
  Rationale: Blind re-execution of a failed session is unsafe for writes — the transaction
  may or may not have committed — and `hasql-pool` deliberately does not do it. The server
  recovers with no process restart, which is the property finding A2 demanded. The cost is
  now documented in `docs/user/service-and-operations.md` with both error strings, and
  EP-35's typed envelope will mark these errors retryable so clients retry at their layer.
  Date: 2026-07-08


- Decision: Expand EP-35 to adopt Servant `MultiVerb`, lifting handler-produced errors
  into the API type, rather than deferring it to a follow-up plan.
  Rationale: `MultiVerb` changes the Haskell types, not the JSON — the statuses and
  envelope bodies are byte-identical either way — so it is a break of `en-client`'s
  shape, not of the `/v1` wire contract. en has no API consumers today, which makes that
  break free now and expensive once anything depends on the client; that is the same
  argument that justified the one-time wire break EP-35 already carries. The payoff is a
  generated OpenAPI document that lists each operation's real error responses, and a
  typed client result instead of an opaque `ClientError`. Confirmed the toolchain
  supports it before committing: servant 0.20.3 ships `Servant.API.MultiVerb` with a
  `HasServer` instance, `servant-client-core` defines
  `Client m (MultiVerb method cs as r) = m r`, and the fork EP-35 already pins
  (`shinzui/servant-openapi-hs`) carries a MultiVerb `HasOpenApi` port. `MultiVerb` does
  not subsume EP-33's middleware errors or Servant's routing errors, so the envelope and
  `ErrorFormatters` remain load-bearing.
  Date: 2026-07-08

- Decision: Reject `wai-extra`'s `RequestLogger` for EP-36 and hand-roll the request
  logger instead, contrary to that plan's Interfaces and Dependencies section.
  Rationale: `formatAsJSON` serializes every request header and redacts only `Cookie`,
  so en — which authenticates with `Authorization: Bearer <secret>` — would have written
  a working credential to stdout on every request. It also logs full request bodies, which
  name subjects and objects. Independently, `customMiddlewareWithDetails`, the carrier a
  custom formatter runs under, slurps the request body into a list and accumulates the
  entire response into an `IORef Builder` before responding; neither is configurable, and
  both are a full copy of every request and response on the authorization hot path. The
  line en wants — time, request id, caller, method, path, status, duration — is ~30 lines
  of `Middleware`, so the dependency bought nothing and cost a credential leak.
  Date: 2026-07-08

- Decision: Supervise the `en-server` binary directly in `process-compose.yaml` rather
  than through `just start-server`, and let `just start-and-test` drive the supervised
  server rather than starting its own.
  Rationale: A process supervisor's contract is with a pid. Nesting the server under
  `just` and `cabal run` meant SIGTERM killed the wrappers first: process-compose recorded
  the wrapper's exit code `143` instead of the server's `0`, and closed the log pipe while
  the server was still writing its drain line. `exec`ing the binary makes the supervised
  pid the server. Separately, adding the process while `start-and-test` still spawned its
  own server would have bound port 8080 twice; reusing the supervised server is also what
  makes the readiness probe load-bearing rather than decorative.
  Date: 2026-07-08

- Decision: Cancel EP-37's `en_transaction (created_at, xid)` index; let pruning fix
  finding C2 on its own.
  Rationale: The index is never used. PostgreSQL rewrites `min(xid)` into a `Limit 1` over
  the `xid` primary key and prefers that plan at every selectivity measured, down to one
  in-window row among 50,001. The cost of that plan is precisely the number of rows behind
  the horizon, which is what pruning removes: 606 buffers and 4.7 ms with a 50,000-row
  backlog, 2 buffers and 0.04 ms once drained — and the drained plan is byte-identical with
  the index present or absent. Forcing the index (which requires defeating the min/max
  rewrite) would make every read scan all in-window index entries, turning an `O(1)` lookup
  into `O(window)`. Keeping it would cost one index entry per write transaction for a plan
  the optimizer never selects. Recorded alternatives: keep it as a hedge for a future
  `created_at`-filtering query (rejected — add it then, on that query's evidence); force it
  with a `FILTER` clause (rejected — slower in steady state).
  Date: 2026-07-08


## Outcomes & Retrospective

(To be filled during and after implementation.)
