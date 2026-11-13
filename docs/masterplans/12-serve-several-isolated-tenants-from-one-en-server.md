---
id: 12
slug: serve-several-isolated-tenants-from-one-en-server
title: "Serve several isolated tenants from one En server"
kind: master-plan
created_at: 2026-11-12T23:20:49Z
intention: "intention_01m7910hcdejsv2zfwyrxptjkb"
provenance:
  created_by:
    model: "claude-fable-5-2"
    harness: "claude-code"
    at: 2026-11-12T23:20:49Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-13T00:54:04Z
      mode: "implement"
      note: "EP-1 implemented; G0 evidence recorded and awaiting the owner"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-13T02:19:34Z
      mode: "update"
      note: "Gate G1 reduced to two runs of 3 rounds with the owner's agreement"
---

# Serve several isolated tenants from one En server

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

This initiative implements the improvement request
[IR-2, "Serve several isolated tenants from one En server"](../improvement-requests/serve-several-isolated-tenants-from-one-en-server.md),
raised by `mori://shinzui/mori` on behalf of
`mori://shinzui/mori/plans/302-migrate-the-shared-registry-from-legacy-tokens-to-shomei-and-en-with-a-team-pilot`.

Today one `en-server` process serves exactly one authorization model: one schema file, one
PostgreSQL database, one list of API keys. An application that wants its own model must run a
second En. After this initiative, an operator can declare several **tenants** at startup. A
tenant is an independent authorization owner: a name, a schema file, a PostgreSQL database, and
its own read-only and read-write API keys. The tenant of a request is the tenant of the key that
authenticated it. There is no request field, header, path or wire type through which a caller
can name a tenant, so a client written against today's server works unchanged against its tenant
on a shared server.

The owner has attached two conditions to implementing this at all, and they are the acceptance
bar of the whole initiative, above the seven acceptance criteria of IR-2:

1. **Complete isolation.** A tenant's requests never read, write, validate against, cache
   alongside, rate-limit against, or invalidate another tenant's state, and a fault in one
   tenant's storage or schema never makes another tenant unavailable.
2. **No performance degradation.** A server started without tenant configuration is no slower
   than it is today, a tenant on a shared server whose neighbours are idle is no slower than the
   same workload on a dedicated server, and sharing a process costs a tenant with a busy
   neighbour no more than sharing a machine with a second `en-server` process would.

These are enforced as measured go/no-go gates (see Progress). If a gate fails and cannot be
fixed inside the design below, the initiative stops and the result is reported to the owner
rather than shipped with a caveat.

One limit must be stated plainly because no design removes it: tenants of one process share its
CPU cores, its garbage-collected heap and its network listener. Data and authorization isolation
can be made complete; performance isolation in a shared process can be made *no worse than
co-located processes* and can be bounded with the existing per-caller rate limiter, but it
cannot be absolute. Gate G3 measures exactly this, and the owner decides at gate G0 whether the
preview of that number is acceptable before any tenant code is written.

In scope: tenant configuration, key-to-tenant routing, one complete authorization stack per
tenant, per-tenant schema reload, `check-schema`, import, export, maintenance and migrations,
containment of per-tenant storage faults, tenant-aware logs, metrics, traces and readiness, a
load benchmark for `en-server`, and the operations documentation.

Out of scope, as IR-2 itself excludes: tenant administration over HTTP, creating or removing
tenants without a restart, relations or subjects that cross tenants, and quotas beyond the
existing rate limiter. Also out of scope: any change to `en-core`, `en-postgres`, `en-client`,
the wire contract, the token encoding or the database schema, and the Nagare bootstrap change
that would declare tenants for the platform En (that belongs to `mori://shinzui/nagare`).


## Decomposition Strategy

### The design every child plan shares

The design follows from one observation: every isolation guard En needs already exists *per
datastore*. Consistency tokens and watch cursors embed and validate a datastore id
(`validateTokenMetadata` in `en-postgres/src/En/Postgres/Revision.hs`, `validateWatchCursor` in
`en-postgres/src/En/Postgres/Watch.hs`), the decision cache keys on datastore id and schema hash
(`DecisionKey` and `SubproblemKey` in `en-core/src/En/Cache.hs`), and each request is evaluated
under one schema snapshot (`runPorts` in `en-servant/src/En/Servant/Seam.hs`). So tenancy is not
threaded through the engine. Instead `en-server` builds **one complete single-datastore stack
per tenant** and picks a stack by API key:

- **Storage: one PostgreSQL database per tenant**, each migrated by `en-migrate` and carrying
  today's tables unchanged. `en_datastore_metadata`, `en_gc_horizon` and
  `en_grant_generation_head` stay singleton tables, so datastore identity, garbage collection
  and grant generations keep their existing proofs per tenant, and backup, restore and migration
  of one tenant cannot touch another. A tenant column across the existing tables was rejected:
  it would put a `WHERE tenant = $1` on every hot-path statement (a performance risk the owner
  ruled out), require re-proving GC, grant-generation ordering and the changes feed, and make
  per-tenant backup a row filter instead of a `pg_dump`.
- **Runtime: one tenant stack per tenant**, each holding its own connection pool, datastore id,
  active-schema reference, tuple-read cache, decision cache, optimized-revision cache, rate-limit
  buckets, metrics registry, maintenance thread, `Env` and WAI application. The stack is built by
  the same code that builds the single stack today.
- **Routing: by key, at the authentication middleware.** `authenticate` in
  `en-server/app/Middleware.hs` already scans the key list; each key now carries its tenant, and
  the middleware hands the request to that tenant's application. No handler, route or wire type
  changes, and `en-servant` stays tenant-unaware.
- **Legacy mode is the same code with one implicit stack.** A server started without `EN_TENANTS`
  builds exactly one stack from `EN_DATABASE_URL`, `EN_SCHEMA_PATH` and `EN_API_KEYS_*` and
  dispatches to it directly, with no table lookup on the request path. This is what makes "no
  degradation for existing deployments" a structural property rather than a hope, and gate G1
  measures it anyway.

Tenant configuration is environment variables, matching the existing rule that `en-server/app/Config.hs`
parses every setting in one place and that Kubernetes injects secrets as variables:

```text
EN_TENANTS=platform,mori
EN_TENANT_PLATFORM_DATABASE_URL=postgresql://…/en_platform
EN_TENANT_PLATFORM_SCHEMA_PATH=/etc/en/schema/app.en
EN_TENANT_PLATFORM_API_KEYS_READ_WRITE=nagare:…
EN_TENANT_PLATFORM_API_KEYS_READ_ONLY=gateway:…
EN_TENANT_MORI_DATABASE_URL=postgresql://…/en_mori
EN_TENANT_MORI_SCHEMA_PATH=/etc/en/schema/registry.en
EN_TENANT_MORI_API_KEYS_READ_WRITE=mori-api:…
```

A tenant name matches `[a-z][a-z0-9-]{0,30}`; its variable segment is the name upper-cased with
`-` replaced by `_`. `EN_TENANTS` is mutually exclusive with the legacy store and key variables.
The full variable reference is defined by
`docs/plans/73-serve-tenants-selected-by-api-key-each-from-its-own-isolated-stack.md`.

### Work streams

The work is five child plans, split by functional concern.

`docs/plans/72-build-an-en-server-load-benchmark-and-record-the-single-tenant-baseline.md` builds
the instrument the performance condition needs and does not yet exist: a load benchmark that
drives a real `en-server` process over HTTP, an A/B comparison with a measured noise band, a
preserved baseline binary, and an early preview of in-process interference. It comes first so
the baseline is recorded before any tenant code exists and so the owner can stop cheaply.

`docs/plans/73-serve-tenants-selected-by-api-key-each-from-its-own-isolated-stack.md` is the core:
configuration, the tenant stack, routing by key, and the proof that two tenants with different
schemas cannot see each other (IR-2 AC-1, AC-2, AC-3 and the key-role half of AC-6).

`docs/plans/74-give-each-tenant-an-independent-lifecycle-and-contain-its-storage-faults.md` makes
the things that happen outside a request per-tenant: schema reload, `check-schema`, import,
export, maintenance, startup against a broken tenant database, and recovery (AC-4, AC-5).

`docs/plans/75-carry-the-tenant-through-logs-metrics-traces-and-readiness.md` makes the tenant
visible to operators without making one tenant visible to another (the remainder of AC-6).

`docs/plans/76-prove-tenant-isolation-and-performance-then-document-tenant-operations.md` runs the
final gates, writes the operations guide and verifies its example literally (AC-7), and distils
the ADRs.

Alternatives considered: a single ExecPlan was rejected because the benchmark, the routing core
and the lifecycle work have separate acceptance and a mandatory stop point between them. Folding
observability into the lifecycle plan was rejected because metrics scoping has its own isolation
question (what a tenant's key may scrape) that deserves its own acceptance. Splitting a pure
"extract the stack" refactor into its own plan was rejected as an artificial split; it is
Milestone 1 of plan 73, where gate G1 is first run.

### ADR context

Relevant local ADRs, read for this decomposition:

- [ADR 1](../adr/0001-en-s-schema-is-an-append-only-pg-migrate-component.md): En's SQL is an
  append-only `pg-migrate` component applied by `en-migrate`, never by service startup. Per-tenant
  databases are therefore each migrated by the same `en-migrate up`, and no new migration is
  needed by this initiative.
- [ADR 4](../adr/0004-en-s-health-probe-surface-is-owned-by-servant-health.md): the probe wire
  type and the 200/503 mapping belong to `mori://shinzui/servant-health`. Its `ProbeVerdict` is
  `Healthy | Unhealthy name since`, so a passing probe cannot name a degraded tenant today. Plan
  75 works within that.
- [ADR 5](../adr/0005-telemetry-configuration-and-provider-lifetimes-belong-to-the-standalone-host.md):
  telemetry providers are process-wide and owned by `en-server`. Tenants share them; the tenant
  becomes a span attribute, not a separate provider.
- [ADR 8](../adr/0008-grant-generations-follow-committed-owner-writes.md): the grant-generation
  counter is a locked singleton row per database. One database per tenant means one counter per
  tenant, so a tenant's commits never serialize behind another's.
- [ADR 3](../adr/0003-the-in-memory-store-is-for-tests-and-demos-only.md): tests of tenant
  isolation must use real PostgreSQL; the in-memory store cannot stand in for it.

No ADR covers tenancy. Two decisions made here deserve records, written by the plans that
implement them: "tenancy is a property of the standalone host: one single-datastore stack per
tenant, selected by API key" (plan 73) and "a partially available process stays ready, and
per-tenant availability is reported, not gated" (plan 75). Plan 76 performs the final distillation.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-1 | Build an en-server load benchmark and record the single-tenant baseline | docs/plans/72-build-an-en-server-load-benchmark-and-record-the-single-tenant-baseline.md | None | None | Complete |
| EP-2 | Serve tenants selected by API key, each from its own isolated stack | docs/plans/73-serve-tenants-selected-by-api-key-each-from-its-own-isolated-stack.md | EP-1, gate G0 | None | Not Started |
| EP-3 | Give each tenant an independent lifecycle and contain its storage faults | docs/plans/74-give-each-tenant-an-independent-lifecycle-and-contain-its-storage-faults.md | EP-2 | None | Not Started |
| EP-4 | Carry the tenant through logs, metrics, traces and readiness | docs/plans/75-carry-the-tenant-through-logs-metrics-traces-and-readiness.md | EP-2, EP-3 | None | Not Started |
| EP-5 | Prove tenant isolation and performance, then document tenant operations | docs/plans/76-prove-tenant-isolation-and-performance-then-document-tenant-operations.md | EP-2, EP-3, EP-4 | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.


## Dependency Graph

The order is a simple chain: EP-1, then gate G0, then EP-2, EP-3, EP-4, EP-5.

EP-2 hard-depends on EP-1 because EP-2's first milestone must be measured against the baseline
binary and benchmark that EP-1 produces, and on gate G0 because the owner made implementation
conditional on the performance outcome. EP-3 hard-depends on EP-2 because it changes the
lifecycle of the tenant stack type EP-2 defines. EP-4 hard-depends on EP-2 for the per-tenant
middleware chain and on EP-3 for the tenant availability state its readiness and metrics report.
EP-5 hard-depends on all three because it measures and documents the finished behaviour.

Nothing runs in parallel. EP-3 and EP-4 both edit `en-server/app/Main.hs` and the tenant modules,
and the gain from interleaving them is smaller than the cost of reconciling them.

There is one soft relationship outside this initiative.
`docs/plans/71-accept-the-api-key-in-a-header-the-kubernetes-api-server-forwards.md` is not started
and also edits `authenticate` in `en-server/app/Middleware.hs` and the en-server test stanza.
Neither blocks the other. Whichever lands second re-reads the other's change: plan 71's alternate
credential header must resolve to the same `(tenant, key)` pair as the bearer header.


## Integration Points

**The server test harness** (`en-server/test-support/ServerHarness.hs`). Involved: EP-1, EP-2,
EP-3, EP-4, EP-5. Owner: EP-1. It starts ephemeral PostgreSQL instances, applies En's migration
plan, spawns a given `en-server` binary with a given environment on a free port, waits for
readiness, captures its stdout and stderr, and stops it. EP-2 adds a two-tenant fixture on top;
EP-3 uses its ability to stop and restart one PostgreSQL instance; EP-4 reads captured log lines;
EP-5 reuses the two-tenant fixture for the load scenarios. Later plans extend the module and do
not fork it.

**The load benchmark** (`en-server/loadbench/`, executable `en-server-loadbench`). Owner: EP-1,
which defines the scenario interface, the result JSON and the A/B verdict rule. EP-2 runs it
for gate G1; EP-3 and EP-4 run only its smoke mode (`just loadbench-smoke`). EP-5 runs gate G1
for the last time and adds the two tenant scenarios (gates G2 and G3).

**The baseline binary** (`.dev/loadbench/en-server-baseline`, built from the commit recorded in
EP-1). Owner: EP-1. It is the fixed reference for every A/B run and for EP-2's upgrade test of
IR-2 AC-1. It is a build product, not a checked-in file; EP-1 provides the script that rebuilds it
from the recorded commit.

**The tenant stack and tenant table** (`en-server/app/Tenant.hs`). Owner: EP-2, which defines
`TenantName`, `TenantConfig`, `TenantStack` and the function that builds a stack. EP-3 adds the
availability state around a stack and the per-tenant reload and maintenance entry points. EP-4
adds the metrics registry and log identity to the stack's middleware chain. No plan gives a
handler in `en-servant` access to a tenant name.

**Tenant configuration** (`en-server/app/Config.hs`). Owner: EP-2 for `EN_TENANTS` and the
required per-tenant variables. EP-3 adds `EN_TENANT_<NAME>_EXPECTED_DATASTORE_ID` and the
per-tenant overrides it needs; EP-4 adds `EN_METRICS_KEYS`. Every plan that adds a variable also
adds it to the unknown-variable check EP-2 introduces, so a typo in a tenant variable fails
startup.

**The authentication middleware** (`en-server/app/Middleware.hs`). Owner: EP-2. EP-4 extends the
identity it attaches to a request (tenant and caller for the request log) but does not change how
a key is resolved. See also plan 71 under Dependency Graph.

**The isolation test suite** (`en-server/test/TenantSpec.hs`, test suite
`en-server-tenant-tests`). Owner: EP-2. EP-3 and EP-4 add their cases to the same suite so the
full isolation proof is one command by the time EP-5 runs.

**The operations guide** (`docs/user/service-and-operations.md`). Owner: EP-5. Earlier plans do
not edit it, so the guide is written once against the finished behaviour and its example is
verified literally.

Uncertain shared behaviour, checked early: whether dispatching by key adds measurable cost. The
representative check is gate G1, run by EP-2 at the end of its Milestone 1, before any tenant
configuration exists.


## Progress

EP-1 is complete (2026-11-13): the benchmark, the baseline binary (commit `5361988`), the
single-tenant baseline and the interference preview are recorded in
`docs/plans/72-build-an-en-server-load-benchmark-and-record-the-single-tenant-baseline.md` and
`en-server/loadbench/results/`, and were reported to the owner. Gate G0 is open: EP-2 does not
start until the owner decides, and the preview (Surprises & Discoveries) suggests G3 cannot pass
with the design as written. IR-2 stays `proposed` until the owner
approves gate G0; EP-2 then moves it to `in-progress` and EP-5 marks it `completed`. If G0 is
declined, IR-2 is marked `rejected` with the benchmark evidence as its resolution. The
initiative has five gates that are not
owned by a single child plan. Each is checked off only with benchmark or test evidence recorded
in the named child plan.

- [ ] **G0, owner go/no-go (after EP-1).** EP-1 reports the single-tenant baseline and the
      in-process interference preview. The owner confirms that the preview and the stated
      shared-process limit are acceptable. If not, EP-2 to EP-5 are cancelled.
      Status 2026-11-13: evidence reported, **decision deferred by the owner**. The brief below
      is what the decision rests on.
- [ ] **G1, no single-tenant regression.** A server started without `EN_TENANTS` shows no
      regression against the baseline binary under EP-1's A/B verdict rule (`--rounds 3`), on
      every workload, at two points: the end of EP-2 Milestone 1, where the legacy request path
      changes, and EP-5, against the finished behaviour. EP-2 Milestone 3, EP-3 and EP-4 run
      `just loadbench-smoke` instead, as a functional check rather than a gate.
- [ ] **G2, no regression with idle neighbours.** One tenant of a two-tenant server, with the
      other tenant idle, shows no regression against the baseline binary serving the same
      workload alone (EP-5).
- [ ] **G3, sharing a process costs no more than sharing a machine.** With the neighbour tenant
      saturated, the measured tenant is no worse than the same two workloads served by two
      separate baseline `en-server` processes on the same host (EP-5).
- [ ] **G4, isolation.** `en-server-tenant-tests` passes with every case from EP-2, EP-3 and
      EP-4, including the case that runs every route under one tenant's keys while the other
      tenant's PostgreSQL is stopped (EP-5 confirms the whole suite).

If G1, G2, G3 or G4 fails and cannot be fixed within the design above, stop, record the evidence
in Surprises & Discoveries, and report to the owner. Work is committed to `master` (the
repository does not use feature branches by default), so every child plan keeps legacy mode
passing the smoke benchmark and the existing suites at its tip; if the initiative is abandoned, the commits carrying this MasterPlan's
trailer are reverted.


### Gate G0 decision brief (2026-11-13)

Recorded so the owner can decide later without the session that produced it. Full evidence:
`docs/plans/72-build-an-en-server-load-benchmark-and-record-the-single-tenant-baseline.md`
(Outcomes & Retrospective) and `en-server/loadbench/results/`.

**Single-tenant baseline** (commit `5361988`; Apple M5 Ultra, 36 cores, macOS 27.2, PostgreSQL
18.6, GHC 9.12.4; 32 client threads, 30 s windows, server saturated):

```text
workload              req/s    p50_ms    p95_ms    p99_ms
check-direct          11183     2.783     4.051     5.249
check-nested           4526     7.056     8.170     9.676
check-cached          17303     1.565     3.027     4.012
lookup                 3095     9.695    17.447    21.997
check-last-key        10192     3.019     4.253     5.638
write                  8840     3.025     7.833    11.231
```

**Instrument resolution.** The baseline compared with itself passes, with medians within
±5.6% (p99 within ±11.3%), but round-to-round throughput noise is 9.4–16.5% on this working
desktop. Gates run here detect regressions of roughly 10–17% or more; a quiet machine is needed
for a tighter "no degradation" claim. A one-connection-pool candidate is flagged on every
workload, so the rule does fail when it should.

**Interference preview** (victim: 8 threads of `check-direct`; aggressor: 32 threads each of
`check-nested` and `lookup`). Share of the victim's throughput kept while the aggressor runs:

```text
pool          shared process          two separate processes
10 (default)  2.9%   (p99 x32)        61%  (p99 x1.9)
64            5.6%   (p99 x9.2)       67%  (p99 x2.0)
```

**What it means for the design.** Per-tenant pools, caches and rate-limit buckets (the design
above) remove little of the gap: one process divides its capacity per in-flight request, so
the tenant with more concurrent requests takes most of it, while the operating system divides
CPU between two processes roughly per process. Shared stop-the-world garbage collection and the
single request-log lock add to it. As designed, **G3 is very likely to fail.**

**Options.**

1. *Go, with a design change*: add a per-tenant admission bound (a cap on each tenant's
   in-flight requests, possibly with a queue) to EP-2, keep G3 as written, and measure the
   bound with `interference`-style runs early in EP-2, stopping again if it does not approach
   the separate-process figure. Unproven; it would need its own Decision Log entry and changes
   to `docs/plans/73-serve-tenants-selected-by-api-key-each-from-its-own-isolated-stack.md`.
2. *Go, with a weaker G3*: accept that a busy neighbour degrades a tenant, bounded only by the
   existing per-caller rate limiter. This relaxes the owner's second condition.
3. *No-go*: serve each tenant from its own `en-server` process; mark IR-2 `rejected` with this
   brief as its resolution and cancel EP-2 to EP-5.

Recommendation recorded at the time: option 1 only if the owner accepts a second stop after an
early measurement of the bound; otherwise option 3.


## Surprises & Discoveries

- Observation (EP-1, decisive for G0): a busy caller inside the same `en-server` process
  costs an idle caller twenty to thirty times more than a busy second process on the same
  machine, and a larger connection pool closes only a little of the gap. Victim throughput kept
  under load: 2.9% shared-process vs 61% separate-processes with the default pool; 5.6% vs 67%
  with `EN_POOL_SIZE=64`. p99 grew ×32 vs ×1.9, and ×9.2 vs ×2.0.
  Implication: the design gives each tenant its own pool, caches and rate-limit buckets but not
  its own share of the CPU. One process hands out capacity per in-flight request, so a tenant
  with many concurrent requests takes most of it, where the operating system splits CPU between
  two processes per process. Shared stop-the-world garbage collection and the single request-log
  lock add to this. G3 ("no worse than two co-located processes") is therefore unlikely to pass
  unless the design adds a per-tenant admission bound, such as a cap on each tenant's in-flight
  requests. That is a design change for the owner to decide at G0, not something EP-2 can fold
  in silently.
  Evidence: `docs/plans/72-build-an-en-server-load-benchmark-and-record-the-single-tenant-baseline.md`
  (Outcomes), `en-server/loadbench/results/interference.json`, `interference-pool64.json`.

- Observation (EP-1): on the development machine the A/B has a resolution of about ±10–17% in
  throughput and more in p99 (self-comparison noise 9.4–16.5%). G1 and G2 can rule out large
  regressions there, not small ones; a quiet machine is needed for a tighter claim.
  Evidence: `en-server/loadbench/results/self-comparison.json`.

- Observation (EP-1, outside this initiative): `POST /v1/lookup` does not follow a
  self-recursive userset (`group#member` inside `group.member`) past its first level, while
  `POST /v1/check` does, so lookup omits objects check allows. The cause is the `visited` guard in
  `evalRelation` (`en-core/src/En/Lookup.hs`). This initiative does not change `en-core`; it
  is planned as its own fix in
  `docs/plans/77-make-lookup-follow-recursive-usersets-the-way-check-does.md`, independent of
  this initiative. The benchmark fixture avoids it.
  Update (2026-11-13): fixed by that plan; lookup now follows nested and mutually nested
  usersets and agrees with check. The loadbench smoke run passes with the space grants moved
  to the outer groups, but the fixture was not changed, so the recorded baseline's workload is
  unchanged. Moving the grants is this initiative's call.


## Decision Log

- Decision: One PostgreSQL database per tenant; no tenant column.
  Rationale: Keeps every hot-path statement, the singleton tables and their correctness proofs
  unchanged, makes per-tenant backup and migration ordinary database operations, and avoids a
  per-statement filter that could regress performance.
  Date: 2026-11-12

- Decision: Tenancy lives only in `en-server`; `en-core`, `en-postgres`, `en-servant` and
  `en-client` are not changed, apart from at most a probes-only application export in `en-servant`.
  Rationale: The per-datastore guards already exist; duplicating the stack reuses them without a
  new trust boundary, and embedded hosts are unaffected.
  Date: 2026-11-12

- Decision: Legacy mode is one implicit stack with direct dispatch, not a one-entry tenant table.
  Rationale: Makes the absence of request-path overhead for existing deployments structural.
  Date: 2026-11-12

- Decision: Tenants are declared in environment variables, not a configuration file.
  Rationale: Matches `Config.hs`'s single validated parse and Kubernetes secret injection; no new
  file format or dependency.
  Date: 2026-11-12

- Decision: Performance is gated by A/B measurement against a preserved baseline binary, with the
  owner deciding at G0 before tenant code is written.
  Rationale: The owner will only implement if there is no degradation; a recorded instrument and
  an early stop point make that condition testable and cheap to act on.
  Date: 2026-11-12

- Decision: "No degradation with a busy neighbour" is defined relative to two co-located
  processes (G3), not relative to an idle machine.
  Rationale: Tenants of one process share CPU and heap by construction, which IR-2 lists as a
  documented limit. The honest, falsifiable claim is that the shared process adds no cost beyond
  what sharing the host already imposes.
  Date: 2026-11-12

- Decision: Gate G1 runs twice (end of EP-2 Milestone 1, and EP-5) with 3 rounds, not at the
  tip of every child plan with 5; the other tips run the smoke benchmark. EP-1 drops its
  second A/B (baseline against a fresh build of the same commit).
  Rationale: on the development machine the A/B has a resolution of about ±10–17% in
  throughput (EP-1's self-comparison), and one full run takes about 45 minutes; four runs bought
  little beyond the two points where the legacy request path can change. The fresh-build A/B
  compared two binaries built from identical sources and so only repeated the self-comparison.
  Decided with the owner, who asked whether the test was over-engineered.
  Date: 2026-11-13

- Decision: Per-tenant schema reload is `SIGHUP` reloading every tenant whose file changed; there
  is no HTTP or per-tenant signal.
  Rationale: Reload already skips a schema whose hash is unchanged, so only edited tenants are
  swapped and only their tokens are invalidated (AC-4), with no new administrative surface, which
  IR-2 excludes.
  Date: 2026-11-12

- Decision: When some but not all tenants are unavailable, `/health/ready` stays 200.
  Rationale: A 503 would make Kubernetes withdraw the pod and take the healthy tenants down with
  the broken one, contradicting AC-5. This is in tension with AC-6's wording that readiness names
  an unavailable tenant, because `servant-health` cannot name a check in a passing response;
  EP-4 resolves it and the owner is asked to confirm.
  Date: 2026-11-12


## Outcomes & Retrospective

(To be filled during and after implementation.)
