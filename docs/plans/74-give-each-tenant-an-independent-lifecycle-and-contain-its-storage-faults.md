---
id: 74
slug: give-each-tenant-an-independent-lifecycle-and-contain-its-storage-faults
title: "Give each tenant an independent lifecycle and contain its storage faults"
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
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-13T14:29:04Z
      mode: "update"
      note: "Owner passed G0 with option 2: added G5 guidance for the tenant-mode request path"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-13T19:30:56Z
      mode: "implement"
      note: "Milestone 1: independent reload, GC and generations proven; per-tenant reload force"
---

# Give each tenant an independent lifecycle and contain its storage faults

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

Once `en-server` can serve several tenants (independent authorization owners, each with its own
schema file, PostgreSQL database and API keys, selected by the caller's key), the things that
happen *outside* a request must be independent too. After this plan:

- Editing one tenant's schema file and sending `SIGHUP` swaps only that tenant's schema and
  invalidates only that tenant's consistency tokens. Another tenant's tokens keep validating.
- `en-server check-schema --tenant alpha candidate.en` reports only alpha's stored
  relationships, and `import` and `export` take the same option.
- One tenant's writes, garbage collection and grant generations never move another tenant's.
- If one tenant's database is unreachable, unmigrated, or is not the database the operator
  pinned, only that tenant is unavailable: its routes answer 503, every other tenant keeps
  answering, the process stays in rotation, and the broken tenant comes back by itself when its
  database is fixed, without a restart.

This plan delivers acceptance criteria AC-4 and AC-5 of
[IR-2](../improvement-requests/serve-several-isolated-tenants-from-one-en-server.md), except
their documentation, which the last child plan of the parent MasterPlan writes.


## Progress

- [x] Milestone 1 (2026-11-13): independent reload, maintenance, garbage collection and grant
      generations are proven by new cases in `en-server-tenant-tests` (group "independent
      lifecycles": reload swaps one tenant and invalidates only its tokens; a failed reload of
      one tenant does not stop the other's; one tenant's writes never move another's grant
      generation; garbage collection runs per tenant under each tenant's window);
      `EN_TENANT_<NAME>_SCHEMA_RELOAD_FORCE` exists (config tests: 38 pass). Maintenance and
      reload lines carry the `[tenant NAME] ` prefix; legacy lines are unchanged.
- [x] Milestone 2 (2026-11-13): `import`, `export` and `check-schema` accept `--tenant NAME`
      and operate on that tenant's database only (tenant suite group "tenant-aware
      subcommands": alpha's `check-schema` reports `3 orphan(s) across 3 live tuple(s)` with
      none of beta's; `export --tenant beta` prints beta's two relationships; an import under
      alpha is invisible to beta; missing, unknown and unexpected `--tenant` each exit 2).
      Config tests: 41 pass. Diagnostics carry the `[tenant NAME] ` prefix on stderr.
- [x] Milestone 3 (2026-11-13): a tenant whose storage is faulty at startup or later is
      unavailable alone and recovers alone; an expected datastore id can be pinned per tenant;
      readiness fails only when no tenant can serve. Tenant suite group "storage faults are
      contained" passes all seven cases (outage while running, unreachable at startup,
      unmigrated, mismatched pin, matching pin, total outage, legacy unchanged); the whole
      suite passes 17 of 17; config tests 41 of 41; the Hurl suite passes 6/6 in legacy mode;
      the upgrade case passes; `just loadbench-smoke` exits 0.


## Surprises & Discoveries

- Observation: the first request on a pooled connection that PostgreSQL has terminated is
  answered `500 internal_error`, not `503 store_error`. The server logs `en: internal error:
  Unexpected number of rows`: hasql reports a row-count decoding failure on that session,
  and `sessionErrorToEnError` in `en-postgres/src/En/Postgres/TupleStore.hs` classifies
  statement errors other than server errors as `InternalError`. The request still fails
  closed, and the following requests open fresh connections, are refused, and answer 503.
  This is independent of tenancy (a single-tenant server sees it after any session
  termination: a failover, an administrator's `pg_terminate_backend`, an idle-session kill),
  and fixing it is a change to `en-postgres`, which the parent MasterPlan excludes. The
  outage case asserts that alpha fails closed throughout and settles on `503 store_error`.
  Reported to the owner as a follow-up.

- Observation: `ephemeral-pg` cannot stop a server and keep its data for a later start
  (`stop` removes the data directory; `restart` has no gap). Outages are simulated per
  database instead: `ALTER DATABASE … WITH ALLOW_CONNECTIONS false` plus terminating the
  database's sessions (`setDatabaseAccepting` in `en-server/test-support/ServerHarness.hs`).
  That is the closer model of a tenant's outage anyway, since only one database goes away.

- Observation: with 17 cases the suite exhausted macOS's 32 System V shared-memory segments
  (two PostgreSQL instances per case, a case per core); `initdb` failed with "could not
  create shared memory segment". `TenantSpec`'s main now sets `TASTY_NUM_THREADS=3` unless
  the caller sets it. Friction entry FRIC-3.

- Observation: the garbage-collection case proves more than the plan asked by giving the two
  tenants different windows (alpha `1 second`, beta `1 hour`): alpha's deleted row is reaped
  while beta's stays, so the case shows both that alpha's maintenance never touches beta's
  database and that the per-tenant GC window is honoured. Grant generations are read straight
  from `en_grant_generation_head` rather than from a check's `grantGeneration` field, which is
  optional in the response. The harness gained `signalServer` and `queryDatabaseText` for these
  cases (`en-server/test-support/ServerHarness.hs`).


## Decision Log

- Decision: Schema reload stays a process-wide `SIGHUP` that visits every tenant; there is no
  per-tenant signal or HTTP endpoint.
  Rationale: Reload already skips a schema whose hash is unchanged, so only tenants whose file
  was edited are swapped. IR-2 excludes tenant administration over HTTP.
  Date: 2026-11-12

- Decision: In tenant mode a storage fault at startup makes the tenant unavailable instead of
  stopping the process; a schema file that cannot be read, parsed or validated still stops the
  process.
  Rationale: AC-5 requires that an unreachable, unmigrated or wrongly identified database
  affects only its tenant, and a pod restarted during one tenant's database outage must still
  serve the others. A bad schema file is local deployment input, and failing the start is what
  lets a rollout stop before replacing healthy pods. A server without `EN_TENANTS` keeps today's
  behaviour exactly: any startup fault exits 1.
  Date: 2026-11-12

- Decision: `/health/ready` reports unready only when no tenant can serve.
  Rationale: Readiness removes the whole pod from traffic. Failing it for one tenant's outage
  would take every healthy tenant down with it, which is the opposite of containment.
  Date: 2026-11-12

- Decision: `--tenant` may appear anywhere after the subcommand, and an unusable tenant
  selection (missing in tenant mode, undeclared, or given without `EN_TENANTS`) exits 2 with
  the reason, the code `usage` and an unreadable `check-schema` candidate already use. A
  configuration error in the selected tenant's store variables (for example a missing
  `EN_TENANT_<NAME>_DATABASE_URL`) also exits 2, since the subcommand reports it before
  touching any store.
  Rationale: exit 1 is reserved by `check-schema` for "the candidate strands grants"; a
  pipeline must be able to tell a wrong command line from a dangerous schema.
  Date: 2026-11-13

- Decision: Tenant mode wraps each tenant in a slot (`TenantSlot` in `en-server/app/Tenant.hs`)
  whose state is `Available stack` or `Unavailable reason since`; the slot's application reads
  that state once per request. One worker per slot runs maintenance while available, or
  retries opening the store (5 s, doubling to 60 s) and then runs maintenance. Store opening
  is split into `loadStoreSchema` (exits on a bad schema) and `connectStore` (returns a
  `StoreFault`: `StoreUnavailable` retries, `StoreMisconfigured` exits at startup).
  Rationale: legacy mode keeps calling `openStore`, which still exits on any fault with
  today's messages, and never touches a slot, so its request path is unchanged.
  Date: 2026-11-13

- Decision: A tenant that recovers is served under the schema read at startup; `SIGHUP`
  skips unavailable tenants, so an edit made during the outage is applied by the next
  `SIGHUP` after recovery. An unavailable tenant's 503 is answered before its stack, so it
  does not reach that tenant's request log or metrics.
  Rationale: re-reading the file in the worker would make recovery fail on a schema edit
  that `SIGHUP` would have refused, and the stack's middleware does not exist yet while the
  store is unavailable. Plan 75 decides how an unavailable tenant is observed.
  Date: 2026-11-13

- Decision: `EN_TENANT_<NAME>_EXPECTED_DATASTORE_ID` verifies the database's identity and never
  assigns it.
  Rationale: `docs/user/service-and-operations.md` explains why there is deliberately no
  variable that sets a datastore id. A pin that only compares cannot recreate that collision,
  and it catches the worst tenant misconfiguration: a database URL pointing at another tenant's
  or an unrelated database.
  Date: 2026-11-12


## Outcomes & Retrospective

Complete (2026-11-13; `a1e713e`, `d2d620c` and the Milestone 3 commit). Each tenant now has an
independent lifecycle, proven in `en-server-tenant-tests`: a `SIGHUP` swaps only the tenants
whose files changed and invalidates only their tokens, a broken file for one tenant does not
stop another's reload, writes, grant generations and garbage collection stay within a
tenant's database, and `import`, `export` and `check-schema` act on the tenant named by
`--tenant`. Storage faults are contained: a tenant that is unreachable, unmigrated or not the
pinned database is unavailable alone, answers 503, keeps authentication, and recovers without
a restart; readiness fails only when no tenant can serve. Legacy mode's behaviour, request
path and messages are unchanged (Hurl 6/6, upgrade case, legacy startup-failure case).
This delivers IR-2 AC-4 and AC-5, except their documentation (plan 76).

Gaps: a terminated pooled connection answers 500 once before 503 (`en-server` cannot fix it;
see Surprises & Discoveries). Partial outages are visible in the log and to
`tenantAvailability`, which plan 75 turns into metrics and readiness detail.

Friction: FRIC-3 (macOS shared-memory limit with parallel ephemeral PostgreSQL), accepted with
the `TASTY_NUM_THREADS` default as its workaround.


## Context and Orientation

`en` is a relationship-based authorization toolkit in Haskell (GHC 9.12.4, `cabal`; enter the
development shell with `nix develop` or `direnv allow`). `en-server` is its standalone HTTP
service. This plan changes only the `en-server` package.

State of the code this plan starts from, produced by the earlier child plan
`docs/plans/73-serve-tenants-selected-by-api-key-each-from-its-own-isolated-stack.md` of the
parent `docs/masterplans/12-serve-several-isolated-tenants-from-one-en-server.md`. That plan
must be Complete before this one begins.

- Tenants are declared with `EN_TENANTS=alpha,beta` and per-tenant variables
  `EN_TENANT_<NAME>_DATABASE_URL`, `_SCHEMA_PATH`, `_API_KEYS_READ_WRITE`, `_API_KEYS_READ_ONLY`,
  and the optional `_POOL_SIZE`, `_GC_WINDOW`, `_BISCUIT_ISSUER_SECRET_KEY`, where `<NAME>` is
  the tenant name upper-cased with `-` replaced by `_`. Parsing is in `en-server/app/Config.hs`,
  which rejects any unrecognized `EN_TENANT_…` variable. A server without `EN_TENANTS` is in
  **legacy mode** and behaves as it always has.
- `en-server/app/Tenant.hs` defines `TenantStack`, everything that exists once per tenant at run
  time: a connection pool, the datastore identity, the active schema held in an
  `IORef ActiveSchema`, three caches, a rate limiter, a metrics registry, and the tenant's
  **inner application** (the HTTP application with all middleware that sits inside
  authentication). `buildStack` creates one. Legacy mode builds exactly one stack with no tenant
  name.
- `en-server/app/Middleware.hs` authenticates the bearer key and, in tenant mode, hands the
  request to the inner application paired with that key.
- `en-server/app/Main.hs` builds the stacks at startup, printing each tenant's startup lines
  with a `[tenant <name>] ` prefix; any tenant failing to initialize exits the process. It
  installs one `SIGHUP` handler that calls `reloadSchema` for each stack, and runs one
  maintenance loop per stack. In tenant mode the `import`, `export` and `check-schema`
  subcommands exit 2 asking for a tenant; this plan adds the option.
- The test suite `en-server-tenant-tests` (`en-server/test/TenantSpec.hs`) starts two ephemeral
  PostgreSQL instances and one server serving tenants alpha and beta, using the harness
  `en-server/test-support/ServerHarness.hs`. The harness can stop and restart a PostgreSQL
  instance, create a migrated or an empty database, spawn the server with a chosen environment,
  with or without waiting for readiness, and return the lines the server has printed.
- `en-server-loadbench ab --baseline B --candidate C` compares two server binaries and ends with
  `RESULT: PASS` or names regressions. The baseline binary is
  `.dev/loadbench/en-server-baseline`, rebuilt by `en-server/loadbench/build-baseline.sh` from
  the commit recorded in
  `docs/plans/72-build-an-en-server-load-benchmark-and-record-the-single-tenant-baseline.md`.

Mechanisms this plan relies on, unchanged since before tenants existed:

- **Schema reload.** `reloadSchema` in `en-server/app/Main.hs` re-reads the schema file, skips
  the swap if the compiled hash is unchanged, scans stored relationships for ones the candidate
  would strand ("orphans"), refuses an orphaning schema unless forcing is enabled
  (`EN_SCHEMA_RELOAD_FORCE`), and otherwise swaps the `IORef`. A consistency token embeds the
  schema hash, so a swap invalidates tokens minted under the old schema.
- **Maintenance.** `runMaintenanceLoop` in `en-server/app/Maintenance.hs` periodically advances
  the garbage-collection horizon (the singleton row in table `en_gc_horizon`), then deletes
  soft-deleted relationships, old transaction rows and old grant generations behind it.
- **Grant generations.** Each committed write increments a counter in the singleton table
  `en_grant_generation_head`; a check response reports the generation at its snapshot in its
  `grantGeneration` field. See
  [ADR 8](../adr/0008-grant-generations-follow-committed-owner-writes.md).
- **Datastore identity.** `resolveDatastoreId` in `Main.hs` mints a random id into the singleton
  table `en_datastore_metadata` on first start and reads it back afterwards; a missing table
  means migrations were not applied. Migrations are applied by the operator with `en-migrate up`
  (`DATABASE_URL=<url> cabal run en-migrate -- up`), never by the server, per
  [ADR 1](../adr/0001-en-s-schema-is-an-append-only-pg-migrate-component.md).
- **Store failures.** When a request cannot reach PostgreSQL the engine returns `StoreError`,
  which `enErrorToFault` in `en-servant/src/En/Servant/Seam.hs` maps to HTTP 503 with problem
  code `store_error` ("the tuple store failed; retry later", retryable). The pool reconnects by
  itself when PostgreSQL returns.
- **Readiness.** `mkProbes` in `en-servant/src/En/Servant/Probes.hs` builds the checks from the
  `servant-health` library (`boolCheck`, `safeCheck`, `sequenceChecks`, `newFailureTracker`). A
  check returns `Healthy` or `Unhealthy name since`; an unhealthy readiness check answers 503
  with the check's name. [ADR 4](../adr/0004-en-s-health-probe-surface-is-owned-by-servant-health.md)
  gives that library ownership of the probe wire format. Find its source with
  `mori registry show shinzui/servant-health --full`.

Because each tenant has its own database, most of AC-4 is already true by construction after
plan 73. Milestone 1 mostly proves it. Milestones 2 and 3 add behaviour.


## Plan of Work

### Milestone 1: prove lifecycles are independent

Add the optional variable `EN_TENANT_<NAME>_SCHEMA_RELOAD_FORCE` (defaulting to
`EN_SCHEMA_RELOAD_FORCE`) to `en-server/app/Config.hs` and to its list of recognized tenant
suffixes, and carry it on the stack so `reloadSchema` uses the tenant's own value. Make sure the
`SIGHUP` handler treats tenants independently: a tenant whose candidate cannot be read or is
refused logs its refusal, prefixed with the tenant name, and the handler continues with the next
tenant. Maintenance log lines are prefixed the same way. Legacy mode's lines stay unprefixed.

Add these cases to `en-server/test/TenantSpec.hs`. For the ones that need maintenance to run,
start the server with `EN_MAINTENANCE_INTERVAL_SECONDS=1` and a short `EN_GC_WINDOW`.

- Reload: obtain a consistency token from a write under each tenant. Append a new relation to
  alpha's schema file (a compatible edit) and send `SIGHUP`. Alpha's `GET /v1/schema` shows a new
  hash and a later `loadedAt`; beta's shows the same hash and the same `loadedAt`. Beta's old
  token still validates on a check; alpha's old token is rejected as an invalid consistency
  token, which is the existing single-tenant behaviour.
- Reload failure is contained: make alpha's file unparseable and add a relation to beta's, send
  one `SIGHUP`; alpha keeps its previous schema and beta is reloaded.
- Writes and generations: read beta's `grantGeneration` from a check, perform several writes
  under alpha, and read beta's again: it is unchanged, while alpha's has advanced. Directly in
  the databases, `SELECT generation FROM en_grant_generation_head` moved only in alpha's.
- Garbage collection: delete relationships under alpha and wait for maintenance passes.
  `SELECT horizon FROM en_gc_horizon` in beta's database changes only according to beta's own
  transactions; compare against a control read taken while alpha was idle. Alpha's log shows
  `reaped=` counts and beta's row counts in `relation_tuple` are unchanged.

### Milestone 2: tenant-aware subcommands

Extend `parseCommand` in `en-server/app/Main.hs` so `import`, `export` and `check-schema` accept
`--tenant NAME`. With the option, the subcommand reads only that tenant's store variables
(`EN_TENANT_<NAME>_DATABASE_URL`, `_SCHEMA_PATH`, `_GC_WINDOW`, `_POOL_SIZE` and the process-wide
pool defaults) through a tenant-aware variant of `loadStoreConfig` in `Config.hs`. It must not
require API keys, exactly as the legacy subcommands do not. The rules: `EN_TENANTS` set and no
`--tenant` exits 2 and lists the tenant names; an unknown name exits 2; `--tenant` without
`EN_TENANTS` exits 2. Update `usage`. Without `EN_TENANTS` the subcommands behave as today.

Add cases: write a different number of `team` relationships under alpha and beta, then run
`check-schema --tenant alpha` with a candidate that removes the `team` type. Its orphan count
and its "live tuple(s)" total are alpha's, and none of beta's relationships appear in its
output. `export --tenant beta` prints only beta's relationships, and
`import --tenant alpha --file F` followed by a check under each tenant shows the imported
relationships exist only in alpha.

### Milestone 3: contain storage faults

Introduce an availability state around the stack in `en-server/app/Tenant.hs`. A **tenant slot**
holds the tenant's name and configuration and a mutable reference that is either *available*
with a built stack, or *unavailable* with a reason and the time it became so. The application
paired with a tenant's keys becomes the slot's application: when available it calls the stack's
inner application; when unavailable it answers every request with the same 503 `store_error`
problem a store failure produces (build it with `problemResponse specStoreError` as
`en-server/app/Middleware.hs` builds its own problems). Authentication and the read-only rule
still run first, so an unavailable tenant never weakens them. Legacy mode has no slot: it calls
its one stack directly, so its request path is unchanged.

Startup in tenant mode. For each tenant, read and validate the schema file first; a failure
there exits 1 naming the tenant, as today. Then try to initialize storage. These outcomes make
the tenant unavailable rather than stopping the process, each logged as
`[tenant <name>] UNAVAILABLE: <reason>`: the database cannot be reached; `en_datastore_metadata`
is missing (include the existing migration hint); `EN_TENANT_<NAME>_EXPECTED_DATASTORE_ID` is set
and differs from the id the database reports, or the database has no id yet. When the pin is
set, read the id with a plain `SELECT datastore_id FROM en_datastore_metadata` and never mint
one, so a mis-pointed URL cannot stamp an identity into a stranger's database; write that
statement in `en-server`, since `resolveDatastoreIdSession` in `en-postgres` inserts when absent.
An invalid GC window on a reachable database is configuration and still exits 1. Two tenants
that both initialize at startup and report the same datastore id still exit 1, as plan 73
established.

Recovery. For each unavailable slot run a supervisor thread that retries initialization, first
after 5 seconds and then doubling up to 60 seconds. On success it checks the pin, checks that no
available tenant already reports the same datastore id (if one does, the slot stays unavailable
with that reason), stores the stack in the slot, starts that tenant's maintenance loop, and logs
`[tenant <name>] AVAILABLE` followed by the usual startup lines. A tenant that was available and
then loses its database needs no state change: its requests fail with 503 `store_error` through
the existing path and succeed again when the pool reconnects. `SIGHUP` skips unavailable slots
with a log line. Shutdown cancels supervisors and maintenance loops and releases every pool.

Readiness. Replace the tenant-mode readiness check with one that pings each tenant (an
unavailable slot counts as failing; an available one uses the existing double ping), tracks each
tenant's failure onset separately with `newFailureTracker`, and returns `Healthy` if at least
one tenant is healthy. When none is, it returns the first tenant's `Unhealthy` verdict, named
`postgres:<tenant>`. Legacy mode's check and its name `postgres` are unchanged. The child plan
`docs/plans/75-carry-the-tenant-through-logs-metrics-traces-and-readiness.md` adds the reporting
of partial outages; expose from `Tenant.hs` a function that returns each tenant's name and
current health for it to use.

Add the fault cases listed under Validation, then run `just loadbench-smoke` (gate G1 itself is
run only by EP-2 Milestone 1 and EP-5; see the MasterPlan).


## Concrete Steps

All commands run from the repository root inside the development shell.

```bash
cabal build all
cabal test en-server-config-tests
cabal test en-server-tenant-tests
cabal test en-server-middleware-test
```

By hand, with a two-tenant environment exported (see plan 73 for the variables):

```bash
"$(cabal list-bin en-server:exe:en-server)" check-schema --tenant alpha ./candidate.en
```

```text
checking at revision …
team:t1#member@user:ann  (orphan: object type team is not defined)
1 orphan(s) across 3 live tuple(s); candidate schema … would strand them.
```

```bash
"$(cabal list-bin en-server:exe:en-server)" export
```

```text
en-server: EN_TENANTS is set; choose a tenant with --tenant (alpha, beta)
```

Starting with alpha's database down:

```text
[tenant alpha] Loaded schema from ./alpha.en
[tenant alpha] UNAVAILABLE: could not reach PostgreSQL: …
[tenant beta] Loaded schema from ./beta.en
[tenant beta] Datastore id: 9a41…
en-server listening on :8080
…
[tenant alpha] AVAILABLE
[tenant alpha] Datastore id: 5d0c…
```

The smoke benchmark, at the end:

```bash
just loadbench-smoke
treefmt
```

Every commit carries these trailers:

```text
MasterPlan: docs/masterplans/12-serve-several-isolated-tenants-from-one-en-server.md
ExecPlan: docs/plans/74-give-each-tenant-an-independent-lifecycle-and-contain-its-storage-faults.md
Intention: intention_01m7910hcdejsv2zfwyrxptjkb
```


## Validation and Acceptance

`cabal test en-server-tenant-tests` passes the Milestone 1 and Milestone 2 cases above and these
fault cases, each against one process serving alpha and beta:

- **Outage while running (AC-5).** Stop alpha's PostgreSQL. Alpha's check and write answer 503
  with code `store_error`; beta's check and write succeed; `GET /health/ready` answers 200.
  Restart alpha's PostgreSQL; alpha's check succeeds again with no server restart.
- **Unreachable at startup.** Start the server while alpha's PostgreSQL is stopped. The process
  starts and listens, beta serves, alpha answers 503, and alpha's read-only key is still
  answered 403 on a write route. Start alpha's PostgreSQL; within the retry interval the log
  shows `[tenant alpha] AVAILABLE` and alpha serves.
- **Unmigrated.** Start with alpha pointed at an empty database. Alpha is unavailable and the
  log names the missing migrations; beta serves. Apply En's migration plan to alpha's database;
  alpha becomes available without a restart.
- **Wrong datastore id.** Start with `EN_TENANT_ALPHA_EXPECTED_DATASTORE_ID` set to a value that
  is not alpha's. Alpha stays unavailable, the log shows both ids, alpha's database has gained
  no row and no changed row in `en_datastore_metadata`, and beta serves. With the correct value,
  alpha serves.
- **Total outage.** Stop both PostgreSQL instances. `GET /health/ready` answers 503 and its body
  names a tenant check (`postgres:alpha`); `GET /health/live` still answers 200.
- **Legacy mode is unchanged.** A server without `EN_TENANTS` whose database is unreachable at
  startup exits 1 with today's message.

`cabal test en-server-config-tests` covers the two new variables and the subcommand option
rules. The A/B command ends with `RESULT: PASS`; paste the verdict table into Progress.


## Idempotence and Recovery

All tests own their PostgreSQL instances and can be re-run. The supervisor's retries are safe to
repeat: initialization only reads, except for minting a datastore id into a database that has
the metadata table and no id, which is the existing first-start behaviour and does not happen
when a pin is set. `import` remains idempotent as documented in `runImport`. Nothing here adds a
migration. If the smoke benchmark, or later gate G1, regresses, the likeliest cause is work added to the legacy request path;
legacy mode must not read a slot reference or take any new branch per request. The per-request
availability check this plan adds to tenant mode is gated later by G5 (one declared tenant against
the baseline binary, run by plan 76), so keep it to one read of a mutable reference per request.


## Interfaces and Dependencies

No new library. `en-server/app/Tenant.hs` gains the slot type, the slot application, the
supervisor, and a function returning each tenant's name with its current health, which
`docs/plans/75-carry-the-tenant-through-logs-metrics-traces-and-readiness.md` consumes for
metrics and logs. `en-server/app/Config.hs` gains `EN_TENANT_<NAME>_SCHEMA_RELOAD_FORCE`,
`EN_TENANT_<NAME>_EXPECTED_DATASTORE_ID` and a tenant-aware store-configuration loader for the
subcommands. `docs/plans/76-prove-tenant-isolation-and-performance-then-document-tenant-operations.md`
documents all of it, including per-tenant migration, backup and restore, and does not need
further code from this plan.
