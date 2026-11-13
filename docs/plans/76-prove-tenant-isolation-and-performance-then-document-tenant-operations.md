---
id: 76
slug: prove-tenant-isolation-and-performance-then-document-tenant-operations
title: "Prove tenant isolation and performance, then document tenant operations"
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
      note: "G0 option 2: G3 reported not gating; added gate G5 (single declared tenant, tenants single)"
---

# Prove tenant isolation and performance, then document tenant operations

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

`en-server` can now serve several tenants from one process (independent authorization owners,
each with its own schema file, PostgreSQL database and API keys, selected by the caller's key).
En's owner accepted this feature on two conditions: tenants are completely isolated, and
single-tenant use pays no performance tax. The owner runs both a performance-sensitive
single-tenant deployment and an intranet multi-tenant deployment without the same requirements,
so the cost a busy neighbour imposes is measured and documented but does not gate the feature.
This plan is where both conditions are finally measured, and where the feature becomes usable by
someone who was not involved in building it.

After this plan: the full isolation test suite passes in one command; three single-tenant
performance gates have passing verdicts (an existing deployment without tenant configuration is
no slower; a server declaring exactly one tenant is no slower; a tenant with idle neighbours is
no slower than a dedicated server); the busy-neighbour cost is measured beside the cost of a
second process on the same machine and stated in the guide; the operations guide
explains how to configure, migrate, reload, back up, restore and observe tenants and states the
limits of the isolation honestly; the guide's own example is executed by a test; and the
decisions are distilled into ADRs.

If a gate fails and cannot be fixed, this plan stops and reports to the owner instead of
documenting the feature. This delivers acceptance criterion AC-7 of
[IR-2](../improvement-requests/serve-several-isolated-tenants-from-one-en-server.md) and confirms
AC-1 to AC-6.


## Progress

- [ ] Milestone 1: the complete `en-server-tenant-tests` suite passes (gate G4) and the final
      single-tenant A/B reports `RESULT: PASS` (gate G1).
- [ ] Milestone 2: `en-server-loadbench tenants` exists; the single-declared-tenant comparison
      (gate G5) and the idle-neighbour comparison (gate G2) report `RESULT: PASS`; the
      busy-neighbour measurement (G3, reported, not gating) is recorded; their tables and the
      memory and connection figures are recorded here.
- [ ] Milestone 3: `docs/user/service-and-operations.md` documents tenants; its example files
      under `docs/user/examples/two-tenant/` start a server that passes the documented-example
      test; the capability catalog, the deployment guide and the README are updated;
      `just openapi` reports no drift.
- [ ] Milestone 4: ADRs are distilled, IR-2 is marked completed with evidence, friction entries
      are triaged, and the parent MasterPlan's gates and retrospective are filled in.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: The busy-neighbour gate compares two tenants in one process against two separate
  baseline processes on the same host, not against an idle machine.
  Rationale: Tenants of one process share its CPU cores and garbage-collected heap by
  construction, and IR-2 itself lists that as a limit to document. The claim that can be tested
  and kept is that sharing a process costs no more than sharing a machine.
  Date: 2026-11-12

- Decision: The busy-neighbour comparison (G3) is measured and reported, not go/no-go, and a
  single-declared-tenant gate (G5) is added. This supersedes the gate status of the entry above;
  the comparison against two processes is kept as the reported figure.
  Rationale: At the parent MasterPlan's gate G0 the owner chose option 2: the multi-tenant
  deployment is an intranet without the single-tenant deployment's performance requirements,
  and multi-tenancy is acceptable only if single-tenant use pays no tax. G5 gates the
  tenant-mode request path when it serves one tenant alone.
  Date: 2026-11-13

- Decision: The documentation's example lives in checked-in files that the documentation quotes
  and a test executes.
  Rationale: AC-7 requires the documented configuration to work "when followed literally". An
  example that only exists as prose in a guide drifts; one that a test loads cannot.
  Date: 2026-11-12

- Decision: The operations guide is written once, here, rather than incrementally by the plans
  that built each behaviour.
  Rationale: The guide's statements of guarantee and limit depend on the measured results of
  this plan, and a single pass keeps the tenant section coherent.
  Date: 2026-11-12


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

`en` is a relationship-based authorization toolkit in Haskell (GHC 9.12.4, `cabal`; enter the
development shell with `nix develop` or `direnv allow`). `en-server` is its standalone HTTP
service.

This is the last child of `docs/masterplans/12-serve-several-isolated-tenants-from-one-en-server.md`.
All four earlier children must be Complete. In order, and what each left behind:

`docs/plans/72-build-an-en-server-load-benchmark-and-record-the-single-tenant-baseline.md`
created the executable `en-server-loadbench` (sources in `en-server/loadbench/`, workloads in
`Workload.hs`) and the harness `en-server/test-support/ServerHarness.hs`. Its `run` subcommand
measures seven workloads (`check-direct`, `check-nested`, `check-cached`, `lookup`,
`check-last-key`, `schema-read`, `write`) against one server; `schema-read` is
`GET /v1/schema`, answered from memory, and isolates the request path. `ab --baseline B
--candidate C` alternates two binaries over several rounds, swapping their two databases each
round, and applies the **verdict rule**: per workload, compare medians of throughput; the
tolerance is the larger of the measured round-to-round noise and a floor of 3%; a candidate
whose throughput is worse than the baseline's by more than the tolerance is a `REGRESSION`; the
command ends with `RESULT: PASS` only if every workload passes. p50 and p99 are printed as
`info`: at saturation p50 restates throughput (Little's law), so it does not gate.
`interference` measures a "victim" caller alone and beside a saturating "aggressor" caller, in
one process and in two processes. The **baseline binary**, `.dev/loadbench/en-server-baseline`,
is `en-server` built before any tenant code existed (commit `09a7d6b`); rebuild it with
`en-server/loadbench/build-baseline.sh <commit>` using the commit recorded in that plan. Its
recorded baseline results are in `en-server/loadbench/results/`.

`docs/plans/73-serve-tenants-selected-by-api-key-each-from-its-own-isolated-stack.md` added
tenant mode: `EN_TENANTS=alpha,beta` plus `EN_TENANT_<NAME>_DATABASE_URL`, `_SCHEMA_PATH`,
`_API_KEYS_READ_WRITE`, `_API_KEYS_READ_ONLY`, and optional `_POOL_SIZE`, `_GC_WINDOW`,
`_BISCUIT_ISSUER_SECRET_KEY` (`<NAME>` is the tenant name upper-cased, `-` replaced by `_`). Each
tenant has its own connection pool, datastore id, schema, caches, rate-limit buckets and metrics
registry; the authentication middleware routes a request to the tenant of its key. A server
without `EN_TENANTS` is in **legacy mode** and behaves as before. It also created the suite
`en-server-tenant-tests` and wrote the ADR on tenancy.

`docs/plans/74-give-each-tenant-an-independent-lifecycle-and-contain-its-storage-faults.md` made
`SIGHUP` reload each tenant whose schema file changed, added `--tenant NAME` to `import`,
`export` and `check-schema`, added `EN_TENANT_<NAME>_SCHEMA_RELOAD_FORCE` and
`EN_TENANT_<NAME>_EXPECTED_DATASTORE_ID` (a pin that verifies and never assigns), made a tenant
with faulty storage unavailable alone (503 `store_error`) with automatic recovery, and made
`/health/ready` fail only when no tenant can serve.

`docs/plans/75-carry-the-tenant-through-logs-metrics-traces-and-readiness.md` added `tenant` and
`caller` to tenant-mode request log lines, a `tenant` label on metrics, tenant-scoped
`GET /metrics`, the scrape-only operator keys in `EN_METRICS_KEYS`, the gauge
`en_tenant_available`, the span attribute `en.tenant`, and the ADR on readiness.

Documentation this plan edits:

- `docs/user/service-and-operations.md`, the operations guide. Its existing sections include
  "Standalone server", "Datastore identity", "Operational warning: backup, restore, and
  datastore identity", "Migrations", "Bulk import and export", "Changing the schema",
  "Reloading the schema without a restart", "Connection pooling", "Health and readiness probes",
  "Request logging", "Metrics", "Background maintenance" and "Authentication, rate limiting, and
  TLS". Read them before writing: the tenant section refers to them rather than repeating them.
- `docs/user/production-deployment-and-performance.md`, whose "Deployment Shapes" section
  describes the embedded library and the dedicated service.
- `docs/capabilities/`, a catalog governed by an OKF profile (`docs/capabilities/profile.dhall`).
  An **OKF bundle** is a directory of Markdown documents with validated front matter. Existing
  entries such as `docs/capabilities/standalone-authorization-server.md` (CAP-20) show the shape.
  Every content change bumps the document's `generated.at` and appends an entry to the bundle's
  `log.md` with `okf log add`. The bundle already fails `--strict` validation for a reason that
  predates this work (entries lack the recommended `reviews` field), so validate without
  `--strict` and confirm no new diagnostic appears.
- `docs/improvement-requests/`, another OKF bundle, holding IR-2. Its profile allows the statuses
  `proposed`, `accepted`, `in-progress`, `completed`, `rejected`, `withdrawn` and `superseded`;
  `completed` requires `completedAt` and recommends `resolution`; `targetPlan` names the
  implementing plan.
- `docs/api/openapi.json` is generated by `just openapi`, which fails if the checked-in file
  differs from the route types. No route changed in this initiative, so it must report no drift.

Relevant ADRs: [ADR 1](../adr/0001-en-s-schema-is-an-append-only-pg-migrate-component.md)
(migrations are applied by `en-migrate`, once per database, never by the server), and the two
ADRs written by plans 73 and 75. `docs/adr/` is a plain directory, one `NNNN-slug.md` per
decision with front matter `title`, `status`, `date`, `authors`, `related`.


## Plan of Work

### Milestone 1: the isolation gate and the final single-tenant gate

Run the whole `en-server-tenant-tests` suite and the other `en-server` suites. Read the suite
against the seven acceptance criteria of IR-2 and add a case for anything not yet proven; in
particular confirm there are cases for: every route of one tenant succeeding while the other
tenant's PostgreSQL is stopped; tokens and cursors rejected across tenants; reload of one tenant
leaving the other's tokens valid; `check-schema --tenant`; the read-only key; and the upgrade
case run with `EN_BASELINE_BIN` set. Then run the single-tenant A/B of the baseline binary
against the current binary in legacy mode. This is the last run of gate G1.

### Milestone 2: the tenant performance gates

Add a `tenants` subcommand to `en-server-loadbench`, reusing the workloads and the verdict rule.

`tenants single` (gate G5) is an A/B in which the baseline side is the baseline binary in legacy
mode serving one database, and the candidate side is the current binary started with
`EN_TENANTS` naming exactly one tenant whose database URL, schema, keys and settings are those of
the baseline side (the legacy variables translated to their `EN_TENANT_<NAME>_…` forms, nothing
else changed). All seven workloads run through that tenant's keys. A `PASS` means an operator who
adopts tenant configuration for one tenant pays nothing for it. If it regresses where G1 does
not, the cause is in the tenant-mode request path: key-to-stack routing, the availability check
added by `docs/plans/74-give-each-tenant-an-independent-lifecycle-and-contain-its-storage-faults.md`,
or the tenant log and metric identity added by
`docs/plans/75-carry-the-tenant-through-logs-metrics-traces-and-readiness.md`.

`tenants idle-neighbour` (gate G2) is an A/B in which the baseline side is the baseline binary
serving one database alone, and the candidate side is the current binary in tenant mode serving
two tenants on two identically seeded databases, with all load sent through the first tenant's
key and the second tenant idle. Per-tenant settings equal the baseline's (same pool size, same
cache sizes). All seven workloads run. A `PASS` means a tenant with idle neighbours is
indistinguishable from a dedicated server.

`tenants busy-neighbour` (G3, reported, not gating) measures a victim running `check-direct` with 8 client
threads while an aggressor runs `check-nested` and `lookup` with 64 client threads. The
baseline side is two baseline processes on the same machine, one database each, victim on one
and aggressor on the other. The candidate side is one current process in tenant mode with the
victim on one tenant and the aggressor on the other. Apply the verdict rule to the victim's
throughput, p50 and p99 under load and print its table, but treat the verdict as information:
EP-1's interference preview showed the shared process keeps only a few percent of the victim's
throughput where two processes keep about 60%, and the owner accepted that cost for the intranet
multi-tenant deployment. Also print, for the documentation, the victim's slowdown relative to
running alone in each topology. Investigate only if the shared-process figure is clearly worse
than the preview's (`en-server/loadbench/results/interference.json`), which would point to a
per-tenant resource accidentally shared.

Record two capacity figures for the guide, measured rather than estimated: the resident memory
of an idle server with 1, 2 and 8 tenants (read with `ps -o rss=`), and the number of PostgreSQL
connections opened, which is the number of tenants multiplied by the pool size.

Paste the four tables (G1, G5, G2, G3), the machine description and the capacity figures
into this plan and check the JSON results in under `en-server/loadbench/results/`. If G5 or G2
reports a regression, investigate before anything else: likely causes are per-tenant resources
accidentally shared (one pool, one cache, one rate-limit map, the request-log lock under
contention) or garbage-collection pressure from the extra heap. If the cause cannot be removed
within the design, stop, record the evidence in the parent MasterPlan's Surprises & Discoveries,
and report to the owner; do not proceed to Milestone 3.

### Milestone 3: documentation with an executed example

Create `docs/user/examples/two-tenant/` with `alpha.en`, `beta.en` and `tenants.env`. The schemas
define different object types (for example `document` only in alpha and `repo` only in beta, and
a `team` type in both). `tenants.env` holds the complete tenant-mode environment with
placeholder database URLs and example keys.

Add a case `documented-example` to `en-server-tenant-tests` that loads `tenants.env` and the two
schema files from that directory, replaces only the two database URLs with those of its
ephemeral databases, starts the server, and runs the AC-2 checks: each tenant writes and checks
its own type; each is refused the other's type; neither sees the other's relationships, changes
or schema text.

Add a section "Serving several tenants" to `docs/user/service-and-operations.md`, quoting the
example files verbatim. It covers, in this order: what a tenant is and when to use tenants
instead of a second En; the variable reference (every `EN_TENANT_…` variable, `EN_TENANTS`,
`EN_METRICS_KEYS`, which process-wide variables apply per tenant, and which legacy variables are
mutually exclusive with `EN_TENANTS`); key assignment (a secret belongs to exactly one tenant;
names are unique per tenant; adding, rotating or removing keys and tenants requires a restart);
a walk-through from two empty databases to a running server, including
`DATABASE_URL=<tenant url> en-migrate up` once per tenant; schema reload and `check-schema` per
tenant; import and export per tenant; per-tenant backup and restore, restating that the
datastore-identity runbook in "Operational warning: backup, restore, and datastore identity"
applies to each tenant database separately and how the expected-datastore-id pin interacts with
it; what happens when one tenant's storage fails and how it recovers; logs, metrics, the scrape
key and the availability gauge; and readiness.

End the section with "Isolation guarantees and their limits". Guarantees, each tied to the test
that proves it: separate data, tokens, cursors, caches, rate limits, schema lifecycle, garbage
collection, grant generations and fault domains. Limits, stated plainly: tenants share the
process's CPU cores, garbage-collected heap, listener and TLS configuration; a busy tenant slows
its neighbours by the measured amount (G3), with the rate limiter as the control and a
dedicated En as the alternative for a deployment that needs performance isolation; a server
serving one tenant, with or without `EN_TENANTS`, pays nothing for tenancy (G1, G5); the process-wide settings (evaluation budget, deadlines, batch size, cache
sizes, rate limit, maintenance schedule) are common to all tenants; total database connections
and memory grow with the number of tenants (give the measured figures); one tenant's storage
fault does not fail readiness, so alert on `en_tenant_available`; anyone who can set the process
environment or read its memory can reach every tenant. Include the gate results as a short
table with the machine they were measured on.

Add a "Shared service with tenants" entry to "Deployment Shapes" in
`docs/user/production-deployment-and-performance.md`, pointing to the new section. Add a
capability document for multi-tenant serving to `docs/capabilities/` following the bundle's
conventions (allocate its id with the bundle's tooling, list the tenant test suite and the
modules as evidence) and update CAP-20's description; log both changes with `okf log add`.
Mention tenants in `README.md` where the standalone server is described. Run `just openapi`.

### Milestone 4: close out

Review the Decision Logs, Surprises & Discoveries and retrospectives of this plan, the four
earlier child plans and the parent MasterPlan. Update the two ADRs already written if
implementation changed their decisions, and write new ADRs for any durable decision not yet
recorded; one is expected: the performance gates and the verdict rule as the standing method for
judging changes to the `en-server` request path.

Before marking IR-2, check the state of
`docs/plans/78-refuse-writes-of-tuples-the-active-schema-cannot-interpret.md`, which the owner
chose (2026-11-13) over narrowing AC-2: En accepted written tuples of undeclared types in every
mode, so AC-2's "refused as unknown" verification did not hold. If plan 78 is complete, AC-2
holds as written and the tenant suite asserts `schema_violation`; cite plan 78 in AC-2's
evidence. If it is not, IR-2's resolution records the narrower guarantee the isolation suite
proves and names plan 78 as the open follow-up.

Mark IR-2 `completed` in
`docs/improvement-requests/serve-several-isolated-tenants-from-one-en-server.md`: set
`completedAt`, `targetPlan` (the parent MasterPlan) and a `resolution` that lists the evidence
per acceptance criterion and states the one deliberate difference from its text (readiness names
an unavailable tenant only when it answers 503; partial outages are named by
`en_tenant_available` and the log). Bump `generated.at`, add a log entry with `okf log add`, and
validate the bundle.

Triage friction entries recorded under the five child plans as
`agents/skills/exec-plan/FRICTION.md` describes. In the parent MasterPlan, check off gates G1 to
G5 with pointers to the evidence, mark this plan Complete in the registry, and write its
Outcomes & Retrospective.


## Concrete Steps

All commands run from the repository root inside the development shell.

Milestone 1:

```bash
cabal build all
EN_BASELINE_BIN="$PWD/.dev/loadbench/en-server-baseline" cabal test en-server-tenant-tests
cabal test en-server-config-tests en-server-middleware-test
cabal run -v0 en-server-loadbench -- ab \
  --baseline .dev/loadbench/en-server-baseline \
  --candidate "$(cabal list-bin en-server:exe:en-server)" \
  --rounds 3 \
  --json en-server/loadbench/results/g1-final.json
```

Milestone 2:

```bash
cabal run -v0 en-server-loadbench -- tenants single \
  --baseline .dev/loadbench/en-server-baseline \
  --candidate "$(cabal list-bin en-server:exe:en-server)" \
  --rounds 3 \
  --json en-server/loadbench/results/g5-single-tenant.json
cabal run -v0 en-server-loadbench -- tenants idle-neighbour \
  --baseline .dev/loadbench/en-server-baseline \
  --candidate "$(cabal list-bin en-server:exe:en-server)" \
  --json en-server/loadbench/results/g2-idle-neighbour.json
cabal run -v0 en-server-loadbench -- tenants busy-neighbour \
  --baseline .dev/loadbench/en-server-baseline \
  --candidate "$(cabal list-bin en-server:exe:en-server)" \
  --json en-server/loadbench/results/g3-busy-neighbour.json
```

`tenants single` and `tenants idle-neighbour` must each end with a line of this form;
`tenants busy-neighbour` prints its table and verdict for the record only:

```text
RESULT: PASS (7 workloads)
```

Milestone 3:

```bash
cabal test en-server-tenant-tests --test-options='-p documented-example'
just openapi
okf validate docs/capabilities --profile docs/capabilities/profile.dhall --profile-enforce --log-enforce
treefmt
```

Milestone 4:

```bash
okf validate docs/improvement-requests --profile docs/improvement-requests/profile.dhall --profile-enforce --log-enforce
```

Every commit carries these trailers:

```text
MasterPlan: docs/masterplans/12-serve-several-isolated-tenants-from-one-en-server.md
ExecPlan: docs/plans/76-prove-tenant-isolation-and-performance-then-document-tenant-operations.md
Intention: intention_01m7910hcdejsv2zfwyrxptjkb
```


## Validation and Acceptance

The plan is accepted when:

- `EN_BASELINE_BIN=… cabal test en-server-tenant-tests` passes with the upgrade case executed,
  not skipped, and with a case identifiable for each of IR-2's AC-1 to AC-6 (gate G4).
- The single-tenant A/B (G1), `tenants single` (G5) and `tenants idle-neighbour` (G2) each end
  with `RESULT: PASS`, run on a quiet machine with the round length that made the instrument's
  self-comparison pass in plan 72, and their tables are recorded in this plan. The
  `tenants busy-neighbour` table (G3) is recorded and its figures appear in the guide's limits.
  To show the tenant scenarios can fail, run `tenants single` once with
  `--candidate-env EN_TENANT_<NAME>_POOL_SIZE=1` and observe `REGRESSION`.
- A reader following only the "Serving several tenants" section, with two empty PostgreSQL
  databases, reaches a running two-tenant server and can reproduce the AC-2 checks; the
  `documented-example` case passes using the same files the section quotes (AC-7).
- `just openapi` exits 0 with no diff; both `okf validate` commands report no diagnostic that
  was not present before this plan.
- IR-2 is `completed` with evidence, the ADRs exist, and the parent MasterPlan's gates are
  checked off.


## Idempotence and Recovery

Benchmarks and tests create and remove their own PostgreSQL instances and can be repeated. A
noisy run is not a result: if a verdict is `REGRESSION` with noise near or above the tolerance
floor, quiet the machine and rerun before investigating, and never loosen the verdict rule to
obtain a pass. Documentation edits are ordinary file changes. Marking IR-2 completed is the one
step to do last, after every gate has passed; if a gate fails, leave IR-2 as it is and report.


## Interfaces and Dependencies

No new library. This plan adds the `tenants` subcommand (modes `single`, `idle-neighbour` and
`busy-neighbour`) to `en-server-loadbench`, the `documented-example` case to
`en-server-tenant-tests`, and the directory `docs/user/examples/two-tenant/`. It consumes the
verdict rule and baseline binary from plan 72 and the tenant configuration from plans 73 to 75
exactly as they are; it must not change server behaviour. If writing the guide exposes behaviour
that is wrong or missing, fix it as a defect under the plan that owns that behaviour's
acceptance and note it in the parent MasterPlan's Surprises & Discoveries.
