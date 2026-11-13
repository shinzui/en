---
id: 73
slug: serve-tenants-selected-by-api-key-each-from-its-own-isolated-stack
title: "Serve tenants selected by API key, each from its own isolated stack"
kind: exec-plan
created_at: 2026-11-12T23:20:49Z
intention: "intention_01m7910hcdejsv2zfwyrxptjkb"
master_plan: "docs/masterplans/12-serve-several-isolated-tenants-from-one-en-server.md"
provenance:
  created_by:
    model: "claude-fable-5-2"
    harness: "claude-code"
    at: 2026-11-12T23:20:49Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-13T02:19:34Z
      mode: "update"
      note: "Gate G1 reduced to EP-2 M1 and EP-5 with 3 rounds; smoke benchmark elsewhere; list-bin target fixed"
---

# Serve tenants selected by API key, each from its own isolated stack

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

Today one `en-server` process serves one authorization model. After this plan an operator can
start one process that serves several **tenants**. A tenant is an independent authorization
owner: a name, a schema file, a PostgreSQL database, and its own API keys. A request belongs to
the tenant of the API key that authenticated it. Nothing else in a request can select a tenant.

To see it working: start one `en-server` with `EN_TENANTS=alpha,beta`, two databases and two
schemas that define different object types. With one of alpha's keys, write and check a
relationship of a type only alpha defines; it succeeds. With the same key, write a relationship
of a type only beta defines; it is refused as a schema violation. With beta's key, look for
alpha's relationship; it is not there. Present a consistency token minted under alpha to beta; it
is rejected as an invalid token. Stop beta's PostgreSQL entirely; every alpha route still
answers. And a server started the old way, without `EN_TENANTS`, behaves exactly as before and
is measurably no slower.

This plan delivers acceptance criteria AC-1, AC-2 and AC-3 of
[IR-2](../improvement-requests/serve-several-isolated-tenants-from-one-en-server.md), and the
part of AC-6 that says a read-only key stays read-only within its tenant.


## Progress

- [ ] Milestone 1: the per-datastore runtime is extracted into a `TenantStack`; a server without
      `EN_TENANTS` builds exactly one and behaves as before. Existing suites pass, the upgrade
      test passes against the baseline binary, and the A/B benchmark reports `RESULT: PASS`
      (gate G1).
- [ ] Milestone 2: `EN_TENANTS` and the per-tenant variables are parsed and validated;
      `cabal test en-server-config-tests` covers every acceptance and rejection rule.
- [ ] Milestone 3: requests are routed by key to per-tenant stacks;
      `cabal test en-server-tenant-tests` passes its isolation cases, including the case that
      exercises every alpha route while beta's PostgreSQL is stopped; `just loadbench-smoke`
      passes; the ADR is written.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Each tenant gets a complete copy of the single-datastore runtime (pool, datastore
  id, active schema, caches, rate-limit buckets, metrics registry, maintenance thread, `Env`,
  WAI application); the engine and `en-servant` are not made tenant-aware.
  Rationale: Tokens, cursors and cache keys already bind a datastore id and schema hash. Copying
  the stack reuses those guards, keeps every SQL statement unchanged, and gives isolation by
  construction: a handler holds one `Env` and that `Env` holds one pool.
  Date: 2026-11-12

- Decision: Routing is done by the authentication middleware, which pairs each key with its
  tenant's application. No tenant identifier is placed in a header for a later stage to look up.
  Rationale: The key lookup already happens; pairing the application with the key adds no second
  lookup and leaves nothing a client-supplied header could influence.
  Date: 2026-11-12

- Decision: Without `EN_TENANTS` the server builds one stack and wraps it with the existing
  `authMiddleware`, unchanged.
  Rationale: Guarantees AC-1 and makes "no overhead for existing deployments" structural.
  Date: 2026-11-12

- Decision: A secret may appear in only one tenant, and two tenants may not use the same
  database (same URL text, or same resolved datastore id). Both are startup failures.
  Rationale: "A key belongs to exactly one tenant" must be enforced, not assumed; and two tenants
  on one database would share tuples, tokens and garbage collection.
  Date: 2026-11-12

- Decision: In tenant mode every tenant needs an explicit schema path and at least one key.
  `EN_AUTH_DISABLED` and the built-in demo schema are not available.
  Rationale: Without a key there is nothing to select a tenant with, and a demo schema served by
  accident under a tenant's name would be a silent misconfiguration.
  Date: 2026-11-12

- Decision: Biscuit grant minting (`POST /v1/grants`) is configured per tenant; there is no
  shared issuer key in tenant mode.
  Rationale: A shared signing key would let one tenant's grant verify against a verifier that
  trusts another tenant's issuer.
  Date: 2026-11-12


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

`en` is a relationship-based authorization toolkit in Haskell (GHC 9.12.4, `cabal`; enter the
development shell with `nix develop` or `direnv allow`). `en-server` is its standalone HTTP
service. This plan changes only the `en-server` package, plus at most one small export in
`en-servant`.

How a request flows today, all in `en-server/app/Main.hs` unless stated:

- `main` parses the command. With no arguments it calls `loadServerConfig`
  (`en-server/app/Config.hs`), which reads a fixed list of environment variables
  (`knownVariables`) and returns a `ServerConfig`, or an error that `configFailure` prints
  before exiting 1.
- `withStore` reads and validates the schema file named by `EN_SCHEMA_PATH` (or a built-in demo
  schema), opens a `hasql-pool` connection pool on `EN_DATABASE_URL`, checks the database is
  reachable, validates `EN_GC_WINDOW`, and resolves the **datastore id**: a random identifier
  stored in the singleton table `en_datastore_metadata`, minted on first start
  (`resolveDatastoreId`). It builds a `ConsistencyConfig` (datastore id, schema hash, GC window).
- `runServeApplication` builds everything a request needs: an `IORef ActiveSchema` holding the
  compiled schema (swapped on `SIGHUP` by `reloadSchema`); three caches (optimized-revision,
  tuple-read, decision); `runAppIO`, which runs an engine action against the pool under one
  schema snapshot; an `Env` record (`en-servant/src/En/Servant/Seam.hs`) holding those
  operations; liveness and readiness probes (`mkProbes` in
  `en-servant/src/En/Servant/Probes.hs`); and the WAI application
  `appWithOpenApiProbes serverEnv livenessProbe readinessProbe`
  (`en-servant/src/En/Servant/OpenApi.hs`). It then starts the background maintenance loop
  (`runMaintenanceLoop` in `en-server/app/Maintenance.hs`) and serves.
- The application is wrapped in middleware, outermost first: OpenTelemetry, Servant route
  telemetry, `authMiddleware`, `rateLimitMiddleware`, `requestIdMiddleware`, the request logger,
  `metricsMiddleware`, `metricsRoute`. A **middleware** is a function that wraps a WAI
  `Application` (a function from request to response).
- `en-server/app/Middleware.hs` holds authentication. `ApiKey` has a name, a secret and a
  `KeyRole` (`ReadOnly` or `ReadWrite`). `authenticate` takes the bearer secret from the
  `Authorization` header and finds the matching key with a constant-time comparison over the
  list. `authMiddleware` answers 401 for no match, 403 when a read-only key calls a write route
  (`isWriteRequest`), lets `/health/live` and `/health/ready` through without a key
  (`isExemptPath`), and otherwise passes the request inward with the header `X-En-Caller` set to
  the key name. `rateLimitMiddleware` keeps one token bucket per caller name in a map.

Why this is already nearly tenant-safe. A **consistency token** is the opaque string a write
returns and a later read can present to say "at least as fresh as this". It embeds the datastore
id and schema hash, and `validateTokenMetadata` in `en-postgres/src/En/Postgres/Revision.hs`
rejects a token whose datastore id or schema hash differs from the serving configuration with
`InvalidConsistencyToken`. Watch cursors embed the datastore id the same way
(`validateWatchCursor` in `en-postgres/src/En/Postgres/Watch.hs`). Decision-cache keys include
both (`SubproblemKey` in `en-core/src/En/Cache.hs`). So two copies of the runtime, each with its
own pool and datastore id, cannot accept each other's tokens or read each other's rows.

The database schema (`en-migrations/migrations/0001-en-bootstrap.sql`,
`0002-grant-generations.sql`) has singleton tables `en_datastore_metadata`, `en_gc_horizon` and
`en_grant_generation_head`, and `relation_tuple` has no owner column. This plan does not change
it: each tenant gets its own database carrying these tables unchanged.

Conventions to follow. Record fields are accessed with generic-lens labels
(`config ^. #store . #pool`), per [ADR 7](../adr/0007-generic-lens-labels-are-en-s-record-access-idiom.md).
Modules import `En.Prelude`. `treefmt` formats Haskell (fourmolu) and cabal files. Look up
dependency sources with `mori registry show <project> --full`; never search `/nix/store`.

Relevant ADRs. [ADR 1](../adr/0001-en-s-schema-is-an-append-only-pg-migrate-component.md): the
SQL schema is applied by `en-migrate`, never at service startup, so each tenant database is
migrated separately by the operator and this plan adds no migration.
[ADR 4](../adr/0004-en-s-health-probe-surface-is-owned-by-servant-health.md): the probe routes
and their wire type belong to the `servant-health` library; this plan keeps using its
combinators. [ADR 8](../adr/0008-grant-generations-follow-committed-owner-writes.md): the
grant-generation counter is a per-database singleton, so separate databases give separate
counters with no further work. No ADR covers tenancy; this plan writes one.

Prerequisites from the parent,
`docs/masterplans/12-serve-several-isolated-tenants-from-one-en-server.md`: the child plan
`docs/plans/72-build-an-en-server-load-benchmark-and-record-the-single-tenant-baseline.md` must be
Complete and the owner must have approved gate G0. That plan provides three things used here:
the harness module `en-server/test-support/ServerHarness.hs` (start ephemeral PostgreSQL, create
a migrated database, spawn an `en-server` binary and wait for readiness, capture its output);
the executable `en-server-loadbench` with its `ab` subcommand, which compares two binaries and
prints `RESULT: PASS` or names regressions; and the baseline binary
`.dev/loadbench/en-server-baseline`, rebuilt with `en-server/loadbench/build-baseline.sh` from
the commit in `.dev/loadbench/baseline.sha` (also recorded in plan 72).

A separate, unstarted plan,
`docs/plans/71-accept-the-api-key-in-a-header-the-kubernetes-api-server-forwards.md`, also edits
`authenticate`. If it has landed, its alternate header must resolve to the same key, and so the
same tenant, as the bearer header. If it has not, nothing here depends on it.


## Plan of Work

### Milestone 1: extract the tenant stack, change nothing observable

Create `en-server/app/Tenant.hs` and move the per-datastore part of `withStore` and
`runServeApplication` into it. The module defines a `TenantStack`: everything that today exists
once per process and must exist once per tenant. It holds the pool, the `ConsistencyConfig`, the
`IORef ActiveSchema`, the three caches, the "run against the current schema" function used by
maintenance and readiness, the schema path and reload-force flag, and the **inner application**,
meaning the servant application wrapped in everything that sits inside authentication (rate
limiter, request id, request logger, metrics recorder, metrics route). A function, here called
`buildStack`, takes the settings shared by the whole process and the settings of one datastore
and returns a stack; a companion releases its pool.

`Main.hs` keeps the process-wide concerns: configuration, telemetry, the `SIGHUP` handler, the
shutdown handling in `serve`, and the outer middleware (OpenTelemetry, Servant telemetry,
authentication). In this milestone it builds exactly one stack from the existing variables and
wraps its inner application with the existing `authMiddleware`. Startup lines, their order, the
log format, the routes, the probes and the exit codes must not change. `reloadSchema` and
`runMaintenanceLoop` are called with the one stack's fields.

Add `Tenant` to `other-modules` of the `en-server` executable.

Before changing code, move IR-2 from `proposed` to `in-progress` in
`docs/improvement-requests/serve-several-isolated-tenants-from-one-en-server.md`, with
`targetPlan` naming the parent MasterPlan. That directory is an OKF bundle (Markdown documents
with validated front matter): bump the document's `generated.at`, append a log entry with
`okf log add docs/improvement-requests --kind Update -m "..."`, and validate with
`okf validate docs/improvement-requests --profile docs/improvement-requests/profile.dhall --profile-enforce --log-enforce`.

Prove nothing changed in three ways. Run the existing suites. Run the Hurl black-box suite
(`just start-and-test`). Create the test suite `en-server-tenant-tests`
(`en-server/test/TenantSpec.hs`, with `test-support` in its `hs-source-dirs` and
`build-tool-depends: en-server:en-server`) holding, for now, only the upgrade test described
under Validation, which starts the
baseline binary against a database, obtains a consistency token, stops it, starts the new binary
against the same database, and shows the datastore id, schema hash and token all carry over
(AC-1). Then run gate G1: the A/B benchmark of the baseline binary against the new binary, with
`--rounds 3`, must print `RESULT: PASS`. If it reports a regression, find and remove the cause before continuing;
if it cannot be removed, stop and report to the owner as the parent MasterPlan requires.

### Milestone 2: tenant configuration

Extend `en-server/app/Config.hs`. `loadServerConfig` currently looks up a fixed list of names;
tenant variables are not known in advance, so it must also snapshot every environment variable
that starts with `EN_TENANT` (use `System.Environment.getEnvironment`) and pass them to the pure
parser, which stays testable without a process.

The variables:

```text
EN_TENANTS                                   comma-separated tenant names; presence selects tenant mode
EN_TENANT_<NAME>_DATABASE_URL                required
EN_TENANT_<NAME>_SCHEMA_PATH                 required
EN_TENANT_<NAME>_API_KEYS_READ_WRITE         name:secret entries, as EN_API_KEYS_READ_WRITE
EN_TENANT_<NAME>_API_KEYS_READ_ONLY          name:secret entries, as EN_API_KEYS_READ_ONLY
EN_TENANT_<NAME>_POOL_SIZE                   optional; defaults to EN_POOL_SIZE
EN_TENANT_<NAME>_GC_WINDOW                   optional; defaults to EN_GC_WINDOW
EN_TENANT_<NAME>_BISCUIT_ISSUER_SECRET_KEY   optional; enables POST /v1/grants for this tenant
```

A tenant name matches `[a-z][a-z0-9-]{0,30}`. `<NAME>` is the name upper-cased with `-` replaced
by `_`; because `_` is not allowed in a name, two names never share a segment.

Everything else stays process-wide and applies to each tenant separately where it is a
per-stack resource: `EN_PORT`, the TLS variables, `EN_TELEMETRY_ENABLED`, the evaluation budget
(`EN_MAX_DEPTH`, `EN_PAGE_LIMIT`, `EN_RESULT_CAP`), the lookup deadlines, `EN_MAX_BATCH_SIZE`,
the rate limit (one bucket per caller per tenant), the maintenance interval and batch size (one
loop per tenant), the three cache settings (each tenant gets caches of that size), the remaining
pool settings, `EN_SCHEMA_RELOAD_FORCE`, and the Biscuit TTL bounds.

Rejections, each a startup failure whose message names the variable and the tenant: an empty
`EN_TENANTS` or an empty or malformed or duplicated name; `EN_TENANTS` together with any of
`EN_DATABASE_URL`, `EN_SCHEMA_PATH`, `EN_API_KEYS_READ_WRITE`, `EN_API_KEYS_READ_ONLY`,
`EN_AUTH_DISABLED` or `EN_BISCUIT_ISSUER_SECRET_KEY`; a tenant missing its database URL or schema
path; a tenant with no key; a duplicate key name within a tenant; the same secret in two tenants
(or twice in one); two tenants with the same database URL; and any `EN_TENANT_…` variable that
does not belong to a declared tenant or is not one of the suffixes above, so a typo cannot be
silently ignored. A `EN_TENANT_…` variable set without `EN_TENANTS` is also rejected. Key names
need only be unique within a tenant: a caller's identity is the pair of tenant and key name.

Represent the result so that legacy mode is not a special case of tenant mode in the types: the
parsed configuration is either the existing single-store configuration or a non-empty list of
tenant configurations plus the shared settings. `loadStoreConfig`, used by the `import`,
`export` and `check-schema` subcommands, is not changed here; when `EN_TENANTS` is set those
subcommands exit 2 with a message saying a tenant must be selected, and the child plan
`docs/plans/74-give-each-tenant-an-independent-lifecycle-and-contain-its-storage-faults.md` adds
the `--tenant` option.

Add a test suite `en-server-config-tests` (`en-server/test/ConfigSpec.hs`, compiling
`app/Config.hs` the way `en-server-middleware-test` compiles `app/Middleware.hs`) with one case
per rule above, plus a case showing that an environment without `EN_TENANTS` parses to the same
single-store configuration as before.

### Milestone 3: route by key and prove isolation

In `en-server/app/Middleware.hs`, add the tenant-mode entry point beside the unchanged
`authMiddleware`. It takes the application that serves the probe paths and a list pairing every
configured key with the inner application of its tenant. For a probe path it calls the probe
application. Otherwise it authenticates exactly as today (same header parsing, same
constant-time comparison, same 401), applies the same read-only rule (same 403), sets
`X-En-Caller` to the key name after stripping any client-supplied value, and calls the inner
application paired with the matched key. It must not read any other header, the path, or the
body to choose an application.

In `Main.hs`, tenant mode builds one stack per tenant with `buildStack`. Each stack gets its own
rate limiter (`rateLimitMiddleware` allocates its bucket map, so calling it once per stack
separates the buckets) and its own metrics registry (`newMetrics`), so `GET /metrics` under a
tenant's key reports only that tenant's requests and caches. The request logger is created once
and shared, because its lock serializes writes to the one stdout. Probes are process-level:
liveness is unchanged, and readiness runs one check per tenant, named `postgres:<tenant>`,
through `sequenceChecks`; the child plan
`docs/plans/75-carry-the-tenant-through-logs-metrics-traces-and-readiness.md` later refines what
readiness reports. Serve the probe paths from a probes-only application; if `en-servant` does
not expose one, add a small exported function next to `appWithOpenApiProbes` in
`en-servant/src/En/Servant/OpenApi.hs` that serves only the `servant-health` routes. The route
type and `docs/api/openapi.json` do not change; confirm with `just openapi`.

Startup in tenant mode initializes tenants in the order of `EN_TENANTS`. Each prints the same
lines as today, prefixed with `[tenant <name>] `. Any failure (unreadable or invalid schema,
unreachable database, missing migrations, invalid GC window) exits 1 naming the tenant, as the
single-tenant server does today. After all datastore ids are resolved, two tenants reporting the
same id is a startup failure: they are the same database reached by different URLs. The
`SIGHUP` handler reloads every stack in turn under the existing single guard; a stack whose
schema file is unchanged is skipped by the existing hash comparison. One maintenance loop runs
per stack, and all pools are released on shutdown.

Extend the test suite `en-server-tenant-tests` created in Milestone 1 with a two-tenant
fixture. The fixture starts two ephemeral PostgreSQL instances (two instances, not two databases in one, so a
later case can stop one), creates a migrated database in each, writes two schema files, and
starts one server:

```text
alpha schema: object user {}   object team { relation member: user }   object document { relation viewer: user  permission view = viewer }
beta  schema: object user {}   object team { relation member: user }   object repo     { relation reader: user  permission read = reader }
```

`document` exists only in alpha, `repo` only in beta, and `team` in both, so the suite can test
both "unknown type" and "same type, separate data". Use the typed client in
`en-client/src/En/Client.hs` for requests, which also shows that an unmodified client works
against a tenant. The cases are listed under Validation.

Finish by running `just loadbench-smoke` (a functional check; gate G1 is not re-run until
`docs/plans/76-prove-tenant-isolation-and-performance-then-document-tenant-operations.md`), and by writing the ADR
`docs/adr/NNNN-tenancy-is-a-property-of-the-standalone-host.md`, where `NNNN` is the next unused
number in `docs/adr/` (0009 unless another plan has taken it), in the format of the existing
ADRs (front matter with `title`, `status`, `date`, `authors`, `related`; sections Status,
Context, Decision, Consequences). It records: one single-datastore stack per tenant; one
PostgreSQL database per tenant and why a tenant column was rejected; routing by key only; the
engine, store and servant layers stay tenant-unaware; legacy mode is one implicit stack.


## Concrete Steps

All commands run from the repository root inside the development shell.

After Milestone 1:

```bash
cabal build all
cabal test en-core en-servant en-server
just start-and-test && just process-down
EN_BASELINE_BIN=.dev/loadbench/en-server-baseline cabal test en-server-tenant-tests --test-options='-p upgrade'
cabal run -v0 en-server-loadbench -- ab \
  --baseline .dev/loadbench/en-server-baseline \
  --candidate "$(cabal list-bin en-server:exe:en-server)" \
  --rounds 3 \
  --json .dev/loadbench/g1-m1.json
```

The last command must end with:

```text
RESULT: PASS (6 workloads, 3 rounds)
```

If `.dev/loadbench/en-server-baseline` is missing, rebuild it with the commit recorded in
`docs/plans/72-build-an-en-server-load-benchmark-and-record-the-single-tenant-baseline.md`:

```bash
en-server/loadbench/build-baseline.sh <baseline-commit>
```

After Milestone 2:

```bash
cabal test en-server-config-tests
```

After Milestone 3:

```bash
cabal test en-server-tenant-tests
just openapi
just loadbench-smoke
treefmt
```

To try it by hand, with two databases already migrated by `en-migrate up`:

```bash
EN_TENANTS=alpha,beta \
EN_TENANT_ALPHA_DATABASE_URL='postgresql://localhost/en_alpha' \
EN_TENANT_ALPHA_SCHEMA_PATH=./alpha.en \
EN_TENANT_ALPHA_API_KEYS_READ_WRITE='alpha-writer:alpha-secret-0123456789' \
EN_TENANT_BETA_DATABASE_URL='postgresql://localhost/en_beta' \
EN_TENANT_BETA_SCHEMA_PATH=./beta.en \
EN_TENANT_BETA_API_KEYS_READ_WRITE='beta-writer:beta-secret-0123456789' \
  "$(cabal list-bin en-server:exe:en-server)"
```

```text
[tenant alpha] Loaded schema from ./alpha.en
[tenant alpha] Schema hash: …
[tenant alpha] Datastore id: 5d0c…
[tenant beta] Loaded schema from ./beta.en
[tenant beta] Schema hash: …
[tenant beta] Datastore id: 9a41…
en-server listening on :8080
```

Every commit carries these trailers:

```text
MasterPlan: docs/masterplans/12-serve-several-isolated-tenants-from-one-en-server.md
ExecPlan: docs/plans/73-serve-tenants-selected-by-api-key-each-from-its-own-isolated-stack.md
Intention: intention_01m7910hcdejsv2zfwyrxptjkb
```


## Validation and Acceptance

**Unchanged single-tenant behaviour (AC-1).** `cabal test en-core en-servant en-server` and
`just start-and-test` pass with no edits to existing test expectations. The upgrade case
(`-p upgrade`) starts the baseline binary named by `EN_BASELINE_BIN` against a fresh migrated
database, records the `Datastore id:` and `Schema hash:` startup lines and the `hash` from
`GET /v1/schema`, writes one relationship and keeps the returned consistency token, stops the
server, starts the newly built binary against the same database, and asserts the same datastore
id, the same hash, and that a check presenting the old token at `atLeastAsFresh` succeeds. When
`EN_BASELINE_BIN` is unset the case prints that it was skipped; acceptance requires it to run.

**Gate G1.** The A/B command prints `RESULT: PASS` after Milestone 1; `just loadbench-smoke`
exits 0 after Milestone 3.
Paste the verdict table into Progress as evidence.

**Configuration.** `cabal test en-server-config-tests` passes; each rejection rule in Milestone 2
has a case asserting the message names the offending variable.

**Isolation (AC-2, AC-3, AC-6 key roles).** `cabal test en-server-tenant-tests` passes these
cases against one process serving alpha and beta:

- With alpha's read-write key, writing `document:d1#viewer@user:ann` succeeds and checking
  `view` for `user:ann` is allowed. The mirror holds for beta with `repo:r1#reader@user:bob`.
- With alpha's key, writing `repo:r1#reader@user:ann` is refused with status 400 and the
  existing schema-violation problem code; nothing is written to either database. The mirror
  holds for beta writing a `document`.
- After alpha writes `team:t1#member@user:ann`, beta's check of that membership is denied, and
  beta's lookup, lookup-subjects, relationship query and expand for `team:t1` return nothing.
  Beta's changes feed (`POST /v1/watch` from the start) contains no change written by alpha.
  The mirror holds.
- `GET /v1/schema` with alpha's key returns alpha's source text and hash and no text from
  beta's file; the two hashes differ; the two `Datastore id` startup lines differ.
- A consistency token returned by an alpha write, presented to beta's check, lookup and
  relationship query, is answered 400 with code `invalid_consistency_token`. A lookup
  continuation cursor and a watch cursor minted under alpha are rejected by beta with the
  existing invalid-token or invalid-cursor problem. The mirror holds.
- A request made with alpha's key that also carries headers such as `X-En-Tenant: beta` or
  `X-En-Caller: beta-writer`, or extra JSON fields naming beta, is served as alpha.
- Alpha's read-only key is answered 403 on `POST /v1/relationships` and can still check.
- Two callers named identically in alpha and beta do not share a rate-limit bucket: with a low
  `EN_RATE_LIMIT_RPS`, exhausting alpha's caller does not produce a 429 for beta's.
- `GET /metrics` with alpha's key reports request counts that do not move when only beta is
  called.
- **Storage separation.** Stop beta's PostgreSQL instance. Every alpha route (write, delete,
  delete by filter, relationship query, check, batch check, lookup, lookup subjects, expand,
  watch, schema) still succeeds, and beta's routes answer 503 with the existing store-error
  problem. This is the direct proof that no alpha request touches beta's storage.

A request with no key or an unknown key is answered 401 as today, and `/health/live` answers 200
without a key.


## Idempotence and Recovery

The refactor in Milestone 1 is behaviour-preserving and can be committed on its own; if gate G1
fails there, revert that commit and nothing else is affected. Tenant mode is entered only when
`EN_TENANTS` is set, so an existing deployment is not affected by Milestones 2 and 3. All tests
create and remove their own PostgreSQL instances and may be re-run freely; a run interrupted
midway can leave child processes behind, which `pgrep -fl en-server` and the `ephemeral-pg`
cleanup guide (`mori registry docs shinzui/ephemeral-pg`) help find. No migration is added and
no existing database is altered.


## Interfaces and Dependencies

No new library is required beyond what `en-server` and the harness already use; the tenant test
suite additionally depends on `en-client` and `servant-client`.

`en-server/app/Tenant.hs` owns these, which the later child plans extend rather than replace:

```haskell
newtype TenantName = TenantName Text

-- Settings of one datastore: database URL, schema path, pool, GC window, keys,
-- optional issuer key. In legacy mode there is one, built from the unprefixed variables.
data TenantConfig

-- Everything that exists once per datastore at run time, including its inner
-- WAI application (all middleware inside authentication, around the servant app).
data TenantStack

buildStack :: SharedConfig -> Maybe TenantName -> TenantConfig -> IO TenantStack
releaseStack :: TenantStack -> IO ()
```

`Maybe TenantName` is `Nothing` only for the implicit stack of legacy mode, which is how later
plans decide whether to print a tenant prefix or attach a tenant label. No function in
`en-servant` receives a `TenantName`.

`en-server/app/Middleware.hs` keeps `authMiddleware :: AuthConfig -> Middleware` unchanged and
adds the tenant-mode entry point, which pairs each `ApiKey` with a WAI `Application`.

Consumers: `docs/plans/74-give-each-tenant-an-independent-lifecycle-and-contain-its-storage-faults.md`
wraps a stack in an availability state and adds `--tenant` to the subcommands;
`docs/plans/75-carry-the-tenant-through-logs-metrics-traces-and-readiness.md` extends the inner
middleware chain; `docs/plans/76-prove-tenant-isolation-and-performance-then-document-tenant-operations.md`
documents the variables defined here. All three add cases to `en-server-tenant-tests`.
