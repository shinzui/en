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
| EP-33 | Add caller authentication and rate limiting to en-server | docs/plans/33-add-caller-authentication-and-rate-limiting-to-en-server.md | None | None | In Progress |
| EP-34 | Pool database connections in en-server | docs/plans/34-pool-database-connections-in-en-server.md | None | None | Not Started |
| EP-35 | Version the wire contract and type the error model | docs/plans/35-version-the-wire-contract-and-type-the-error-model.md | None | None | Not Started |
| EP-36 | Add health endpoints, graceful shutdown, and observability | docs/plans/36-add-health-endpoints-graceful-shutdown-and-observability.md | None | EP-34, EP-35 | Not Started |
| EP-37 | Schedule background maintenance for reaping and transaction pruning | docs/plans/37-schedule-background-maintenance-for-reaping-and-transaction-pruning.md | None | EP-34 | Not Started |
| EP-38 | Validate configuration and persist datastore identity | docs/plans/38-validate-configuration-and-persist-datastore-identity.md | None | None | Not Started |


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

codd migrations under `en-migrations/db/migrations/` are added by EP-37 (index on
`en_transaction (created_at, xid)`) and EP-38 (new datastore-metadata table). Timestamped
filenames prevent collisions; each plan owns its own migration file and must not edit
the other's.

Cross-master-plan: EP-35's versioned wire contract is the surface that
`docs/masterplans/9-complete-the-en-api-surface.md` extends with new endpoints; new
endpoints added there must live under the same version prefix and error envelope. EP-37
prunes `en_transaction` behind the GC horizon; the watch API
(docs/plans/53-add-a-watch-changelog-api.md) reads history and must bound its cursor
recovery by the same horizon.


## Progress

- [ ] EP-33: authentication required on every endpoint; unauthenticated requests get 401
- [ ] EP-33: write endpoints separately authorizable; rate limiting active
- [ ] EP-34: en-server serves concurrent requests through hasql-pool and survives a PostgreSQL restart
- [ ] EP-35: versioned path prefix and stable field names on all endpoints; constructor tags gone
- [ ] EP-35: typed error envelope with machine-readable codes; 4xx/5xx split correct; OpenAPI document served
- [ ] EP-36: /healthz and /readyz respond correctly; SIGTERM drains in-flight requests
- [ ] EP-36: structured request logs and a metrics endpoint (including cache stats) exposed
- [ ] EP-37: reaper and en_transaction pruning run on a schedule with batched deletes
- [ ] EP-37: en_transaction horizon query served by an index
- [ ] EP-38: datastore identity minted once, persisted, and used in tokens
- [ ] EP-38: all config validated at startup with clear failures; deadlines and batch limits configurable


## Surprises & Discoveries

(None yet.)


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


## Outcomes & Retrospective

(To be filled during and after implementation.)
