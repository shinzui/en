---
id: 70
slug: characterize-and-bound-grant-generation-overhead
title: "Characterize and bound grant-generation overhead"
kind: exec-plan
created_at: 2026-09-14T20:58:43Z
intention: "intention_01m2gvcrbze3pv829ecz022bmz"
provenance:
  created_by:
    model: "gpt-5.6-sol"
    harness: "codex-cli"
    at: 2026-09-14T20:58:43Z
---

# Characterize and bound grant-generation overhead

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

En now returns a grant generation with each PostgreSQL-backed authorization check so a consumer
such as Koyomi can distinguish permission changes from unrelated database activity. That safety
feature is complete, but it added three sequential database sessions after every single check, a
historical lookup whose cost may grow with the number of newer grant writes, one history row per
write, and a singleton row lock that serializes grant commits. None of those costs has a dedicated
performance measurement.

After this plan, an operator can run one repository-owned command and see fresh and historical
generation-read latency, concurrent grant-write throughput and tail latency, and generation-pruning
cost at representative history sizes. The avoidable fixed read overhead is reduced without weakening
exact-snapshot or retention safety. Automated tests prevent its database-session count and failure
classification from regressing, while the measured write-serialization capacity and remaining
storage/maintenance costs are documented honestly. The observable demonstration is
`cabal run en-grant-generation-spike`: it prints a bounded result table and exits nonzero when a
correctness assertion or declared performance envelope fails.


## Progress

- [ ] Milestone 1: add deterministic database-session and error-surface tests, then capture the
      current three-session post-check baseline.
- [ ] Milestone 2: add the isolated PostgreSQL generation-performance spike and record unoptimized
      fresh-read, historical-read, concurrent-write, storage, and pruning measurements.
- [ ] Milestone 3: remove avoidable check-path sessions and bound historical lookup work while
      preserving exact-snapshot, commit-order, rollback, and retention behavior.
- [ ] Milestone 4: repeat the full measurement matrix, document the supported operating envelope,
      update durable architecture context, and pass owner and Koyomi acceptance.


## Surprises & Discoveries

(None yet. The pre-existing costs and error-classification issue that motivated the work are
described in Context and Orientation; record implementation-time findings here with evidence.)


## Decision Log

- Decision: Use a new follow-up ExecPlan instead of reopening completed Plan 69.
  Rationale: Plan 69 delivered and accepted the user-visible generation contract. Performance
  characterization, hot-path optimization, regression gates, and operating limits are independently
  verifiable work with a different completion condition.
  Date: 2026-09-14

- Decision: Reuse the repository's manual PostgreSQL-spike pattern for database measurements and
  retain `tasty-bench` only for the existing pure microbenchmarks.
  Rationale: Database startup, multi-connection contention, large fixture seeding, and maintenance
  batches need explicit lifecycle control. `en-postgres/lookup-spike/Main.hs` already supplies the
  local convention. A committed absolute `tasty-bench` baseline from an ephemeral PostgreSQL process
  would mostly measure shared CI-runner and database-startup noise. Deterministic call-count,
  correctness, and plan-shape checks belong in integration tests; sampled latency belongs in the
  reproducible spike and its recorded result note.
  Date: 2026-09-14

- Decision: Preserve the final post-read retention validation and target no more than two database
  sessions in the generation-metadata stage.
  Rationale: The validation after the generation read is the fail-closed defense against concurrent
  collection. The earlier validation duplicates work already performed by the check. Decode the
  internally returned token to recover its revision, read the generation, then validate retention
  once afterward. This removes one horizon query while preserving the safety ordering of “read,
  then validate.” Running the decision and metadata actions inside one `engine` invocation also
  removes duplicate effect-stack setup without changing their schema snapshot.
  Date: 2026-09-14

- Decision: Treat commit serialization as a capacity boundary unless measurement exposes work
  outside the minimal deferred-trigger critical section.
  Rationale: ADR 8 deliberately exchanges concurrent grant-commit freedom for a generation order
  that agrees with successful commit order. The plan may reduce avoidable trigger statements or
  indexing/WAL amplification, but changing the global ordering mechanism requires an updated proof
  and an ADR revision, not a benchmark-driven shortcut.
  Date: 2026-09-14

- Decision: Never edit migration `0002-grant-generations.sql`.
  Rationale: ADR 1 makes applied migration bytes immutable. If the selected lookup or storage
  optimization needs a function, index, or column, create the next migration through
  `just make-migration`; prefer a Haskell/SQL-statement-only change when it meets the same bound.
  Date: 2026-09-14


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This repository contains En, a relationship-based authorization system. A relationship write
changes facts such as “user Alice is a viewer of calendar C.” A single authorization check returns
both a decision and `checkedAt`, an En consistency token containing a PostgreSQL snapshot. A
PostgreSQL snapshot identifies which transactions a read can see; it changes for unrelated database
transactions and therefore cannot by itself serve as a stable permission-policy generation.

[Plan 69](69-expose-stable-grant-generations-at-authorization-snapshots.md) added a separate grant
generation. Migration `en-migrations/migrations/0002-grant-generations.sql` owns two tables. The
singleton `en_grant_generation_head` holds the next counter value. `en_grant_generation` records one
counter value and the owner-write transaction ID that created it. A deferred constraint trigger on
`en_transaction` locks and increments the singleton immediately before commit. Because a later
writer cannot obtain that row lock until the earlier writer finishes, generation order follows
successful commit order even if PostgreSQL assigned transaction IDs in another order.

`en-postgres/src/En/Postgres/GrantGeneration.hs` is the production database module. Its
`grantGenerationAtSession :: Revision -> Session (Maybe GrantGeneration)` query scans generations in
descending order and applies `pg_visible_in_snapshot` until it finds the newest generation visible
to the supplied revision. “Fresh” below means a snapshot taken at or close to the current database
head. “Historical distance” means how many committed grant generations are newer than the supplied
snapshot. The current query should find a fresh value near the first index entry, but an old value
may filter many newer entries before succeeding.

The same module's `grantGenerationForToken` performs the public metadata operation. It resolves the
token through `ConsistencyStore`, executes the generation query, resolves the token again, and
renders `gg1_<nonnegative decimal>`. `en-servant/src/En/Check/Api.hs` invokes the ordinary check and
then invokes `grantGenerationOperation` through a second `engine` call.
`en-server/app/Main.hs` binds that operation to the PostgreSQL implementation. Embedded hosts, such
as `en-example/src/En/Example/Host.hs`, return `Nothing` and should remain free to do so.

`en-postgres/src/En/Postgres/Revision.hs` validates a consistency token against the active datastore,
schema, optional wall-clock expiry, and the durable garbage-collection horizon. An
`AtExactSnapshot` resolution reads that horizon once. `en-postgres/src/En/Postgres/TupleStore.hs`
maps each horizon read to a Hasql database session. `en-postgres/src/En/Postgres/Database.hs` maps
each session to `Pool.use`, so it may acquire a different pooled connection. The integration suite
already has `runConsistencyFetchCountScenario` in `en-postgres/integration-test/Main.hs`, which
interposes the tuple-store effect to enforce per-mode fetch counts. Extend that pattern to count
`Database.RunSession` operations around grant-generation metadata.

The metadata stage also has a distinct failure surface. If its first or final horizon validation
sees that retention advanced after a check completed, it raises `ConsistencyTokenExpired`.
`en-servant/src/En/Servant/Seam.hs` normally maps that error to the HTTP 400 client-error response,
which is correct when a caller supplied an invalid request token but wrong when a
`FullyConsistent` check minted the token moments earlier. A failure that occurs only while attaching
post-check generation metadata is a server-side race and must use En's retryable HTTP 503
unavailable response.

`en-server/app/Maintenance.hs` advances the durable horizon, reaps deleted tuples, prunes old
`en_transaction` anchors, and then calls `pruneGrantGenerationsBatchSession`. Generation pruning
keeps the newest row below the horizon as a floor visible to every still-valid snapshot and retains
all rows at or above the horizon. It deletes older rows in bounded `SKIP LOCKED` batches. The row
limit bounds mutations and locks per statement, not necessarily buffers scanned or wall-clock time.

The repository has two performance mechanisms. `en-postgres/bench/Main.hs` and
`.github/workflows/bench.yml` use `tasty-bench` for deterministic pure functions with committed CSV
baselines. `en-postgres/lookup-spike/Main.hs` uses `ephemeral-pg`, Hasql, a monotonic clock, one
discarded warm-up, repeated samples, and p50/p95 reporting for database work. Add a sibling
`en-postgres/grant-generation-spike/Main.hs`; do not make database latency a committed
machine-independent CSV gate.

[ADR 8](../adr/0008-grant-generations-follow-committed-owner-writes.md) requires commit-ordered
generations, exact-snapshot lookup, failure rather than fabricated history, and floor-preserving
retention. All optimizations in this plan must preserve those invariants. Update ADR 8 if measured
capacity or a changed lookup algorithm is durable architectural context.
[ADR 1](../adr/0001-en-s-schema-is-an-append-only-pg-migrate-component.md) forbids editing an applied
migration and requires any schema correction to be an appended pg-migrate migration. No other local
ADR governs the performance envelope of grant generations.

Koyomi is the first consumer. Its plan
`mori://shinzui/koyomi/plans/5-expose-authorized-calendar-http-apis-and-typed-clients` performs one
fully-consistent check followed by bounded exact-snapshot checks and requires all responses to carry
the same snapshot and generation. The normal consumer sequence therefore needs the fresh and
small-historical-distance cases to be cheap. Arbitrary retained En tokens still make the oldest
valid historical case part of the owner API's denial-of-service boundary. The current Mori registry
resolves `mori://shinzui/koyomi` to its checkout but does not yet index Koyomi plan artifacts, so
`mori path` cannot currently resolve that more specific URI. The file exists at
`docs/plans/5-expose-authorized-calendar-http-apis-and-typed-clients.md` within the Mori-resolved
Koyomi project; retain the intended canonical plan URI in durable references.


## Plan of Work

### Milestone 1 — Make fixed overhead and failure semantics executable contracts

Extend `en-postgres/integration-test/Main.hs` with a transparent interposer around the exported
`Database` effect. Count each `RunSession` operation while running `grantGenerationForToken` against
the real migrations and PostgreSQL interpreter. First capture the current value—three sessions—and
record it in Surprises & Discoveries before changing production code. Add cases for a current token,
a retained historical token, and missing history; the number must not depend on whether the decision
cache would have supplied the preceding authorization result.

Extend `en-servant/test/Main.hs` so a metadata operation that raises `ConsistencyTokenExpired` or
`InvalidConsistencyToken` after a completed check produces `EnUnavailable`, not `EnClientError`.
The test must include `FullyConsistent`, where the request carries no client token, making it
unambiguous that a post-check expiration is a server-side metadata race. Preserve ordinary 400
behavior when the initial check itself rejects a malformed, mismatched, or expired client token.
Make the smallest typed orchestration change needed for these new tests to pass in this milestone;
do not leave an intentionally failing test suite for the later read-path optimization.

Before changing production code, observe and record that the session-count test reports three and
that the post-check retention test fails with the current client-error classification. This
milestone is accepted when the committed session-count test accurately locks in the three-session
baseline, the post-check classification test passes with HTTP 503 while initial client-token errors
remain HTTP 400, and all older integration and wire tests are green.

### Milestone 2 — Build and run the PostgreSQL characterization spike

Add executable `en-grant-generation-spike` to `en-postgres/en-postgres.cabal` and implement it in
`en-postgres/grant-generation-spike/Main.hs`. Reuse the lifecycle, timing, percentile, rendering,
and error-handling style from `en-postgres/lookup-spike/Main.hs`. Use `ephemeral-pg` and apply
`En.Migrations.enMigrationPlan`, so the spike measures the released schema. Keep correctness tests
in the integration suite; the spike may use synthetic `xid8` values and snapshots solely to create
large, repeatable visibility profiles without executing a million individual transactions. Clearly
label synthetic fixtures in its output and cross-check a small fixture against generations created
by real committed transactions.

Measure generation lookup at retained-history sizes 1,000, 10,000, 100,000, and 1,000,000. At each
size sample a head-visible generation, a snapshot with 32 newer generations (the bounded Koyomi-like
sequence case), a midpoint, and the oldest retained floor. Run `ANALYZE`, discard one warm-up, take
at least 50 measured samples, and report p50, p95, rows removed by the filter, shared buffers, and the
operator name from `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)`. A measurement is invalid if the lookup
returns a generation other than the fixture's expected value.

Measure write overhead with real transactions at concurrency widths 1, 8, and 32 against both 1,000
and 1,000,000 retained generations. Report completed writes per second and commit p50/p95 with the
production trigger enabled. In the disposable database only, repeat the same workload with
`en_transaction_grant_generation` disabled to isolate trigger overhead; never present the disabled
result as a valid En configuration. Verify afterward that the enabled run produced one monotonically
increasing generation per committed transaction and none for rollbacks. Also report table and index
bytes from `pg_total_relation_size` after 1,000, 10,000, 100,000, and 1,000,000 generation rows.

Measure pruning with backlogs 10,000, 100,000, and 1,000,000 at the production default batch size
1,000. Report first, median, p95, and final-empty batch latency, total statements, buffers, deleted
rows, and surviving floor. Each individual statement must delete at most the requested batch and the
retained floor must resolve correctly after the backlog drains.

Append compact baseline tables and the exact host/PostgreSQL/GHC context to this plan's Surprises &
Discoveries. The milestone is accepted when `cabal run en-grant-generation-spike` completes the
default matrix, renders every required field, proves its correctness assertions, and exits zero.
Support a smaller `--smoke` matrix for routine development and a `--json FILE` result artifact for
comparison; reject unknown arguments instead of silently changing the workload.

### Milestone 3 — Remove avoidable reads and bound historical lookup work

In `en-postgres/src/En/Postgres/GrantGeneration.hs`, separate token decoding from retained-history
validation. The metadata path receives the `checkedAt` token minted by the just-completed check, so
decode it to obtain the exact `Revision`, read that generation, then perform one validation after
the read. Do not remove the final validation. Missing history, database failure, owner mismatch, or
expiration discovered in this post-check metadata stage must become the retryable unavailable
surface required by Plan 69; initial request-token validation in `En.Check.check` retains its
existing client-error behavior.

In `en-servant/src/En/Check/Api.hs`, execute `checkOperation` and
`grantGenerationOperation` inside one `engine env active` action. Both operations must continue to
use the one request-time `ActiveSchema`; a concurrent schema reload may not split the decision from
its metadata. Update `en-servant/src/En/Servant/Seam.hs` only if a small typed wrapper is needed to
distinguish post-check metadata failure from ordinary client-token failure. Avoid adding an
unstructured catch-all that would turn programming or schema errors into retryable faults.

For historical lookup, first use the spike and `EXPLAIN` evidence to prove whether the current
descending scan grows linearly with historical distance. If it does, replace it with a lookup whose
work is bounded logarithmically in generation-history size. Commit order makes visibility monotone
by generation: for a fixed snapshot, visible generations form a prefix, because generation N+1
cannot acquire the singleton lock until generation N's transaction finishes. Prototype an inline
recursive-CTE or equivalent primary-key binary search over generation numbers and verify this prefix
property with actual concurrent transactions, out-of-order XID allocation, rollback, and snapshots
whose `xip` list contains an older still-running transaction. Adopt the new statement only when it
returns exactly the same answer as the original visibility query throughout the fixture matrix and
its `EXPLAIN` evidence shows logarithmic point lookups rather than a scan through every newer row.

If the bounded implementation needs a PostgreSQL function or index, create a new migration with
`just make-migration`; do not edit `0002-grant-generations.sql`. Include migration upgrade tests and
verify an already-migrated database advances cleanly. If an inline statement meets the same
correctness and plan-shape gates, prefer it because it requires no new persistent schema.

After optimization, the generation metadata stage must issue at most two `Database.RunSession`
operations: one generation read and one post-read horizon validation. At one million retained rows,
the fresh and 32-newer-generation cases must have p95 below 5 ms on the reference host, and the
oldest-floor and midpoint cases must have p95 below 25 ms. More importantly than the machine-local
milliseconds, doubling history size must add at most a constant number of lookup steps; the JSON
EXPLAIN record must show work proportional to the logarithm of row count. If the prototype disproves
the monotone-prefix argument, stop before changing production SQL, record the counterexample, and
revise this plan and ADR 8 with a different bounded design.

### Milestone 4 — Establish the supported envelope and close integration

Run the full spike again after the read-path changes and render before/after deltas for every matrix
cell. A regression is actionable when the same-host post-change p95 is more than 25 percent slower
than its pre-change counterpart outside the intentionally improved cells; investigate rather than
re-recording the slower number. Concurrent-write results are capacity evidence, not permission to
weaken commit order. Confirm that commit latency is independent of accumulated history size and that
the singleton lock is held only during the deferred trigger/commit tail. If avoidable work extends
that critical section, remove it and repeat the matrix. Otherwise record the measured throughput and
p95 at widths 1, 8, and 32 as the supported reference envelope.

Update `docs/user/production-deployment-and-performance.md` with the number of extra database
sessions per check, the historical lookup bound, storage growth per retained generation, maintenance
batch behavior, and the deliberate global grant-commit serialization point. State that measurements
are reference evidence rather than universal hardware promises and show operators how to run the
spike on their deployment class. Update
`docs/adr/0008-grant-generations-follow-committed-owner-writes.md` with the final lookup algorithm,
validated performance consequences, and any retained serialization boundary. If a schema artifact
was added, also confirm its append-only treatment against ADR 1.

Run the En all-package build, focused tests, formatting, OpenAPI drift check if the error surface
changed the schema, and the full spike. Then run the consumer gate from the Mori-resolved
`mori://shinzui/koyomi` checkout. Existing cursor behavior must remain unchanged: calendar writes do
not invalidate authority; revocation, downgrade, and regrant do. The plan is complete only when the
deterministic session-count gate, exact-snapshot correctness suite, performance envelope, owner API,
and real Koyomi consumer gate all pass.


## Concrete Steps

Run all En commands from `/Users/shinzui/Keikaku/bokuno/en` inside the repository development shell.
Start with focused correctness and a quick characterization:

```bash
nix develop -c cabal test en-postgres:en-postgres-integration-tests en-servant --test-show-details=direct
nix develop -c cabal run en-grant-generation-spike -- --smoke
```

The smoke output must name the fixture as synthetic or transactional and include fields equivalent
to the following; exact numbers are machine-dependent:

```text
generation-read history=10000 distance=32 expected=9968 actual=9968 p50_ms=... p95_ms=... shared_blocks=... plan=...
generation-write concurrency=8 trigger=enabled committed=... rollbacks=... writes_per_second=... commit_p95_ms=...
generation-prune history=10000 batch=1000 removed=9999 survivors=1 batch_p95_ms=...
PASS: generation performance matrix preserved exact visibility, commit order, rollback and retained floor
```

Capture the full baseline before production optimization and write JSON outside the repository until
the results have been summarized in the plan:

```bash
nix develop -c cabal run en-grant-generation-spike -- --json .dev/grant-generation-before.json
```

After implementation, repeat the full matrix on the same host and compare it with the baseline:

```bash
nix develop -c cabal run en-grant-generation-spike -- --json .dev/grant-generation-after.json
nix develop -c cabal run en-grant-generation-spike -- --compare .dev/grant-generation-before.json --json .dev/grant-generation-after.json
```

The comparison exits zero only when correctness matches, declared latency limits pass, and
unintended same-host regressions stay within 25 percent. The executable must explain a nonzero result
with the failing scenario and measured values.

Run the full En validation:

```bash
nix develop -c cabal test en-migrations en-postgres:en-postgres-revision-tests en-postgres:en-postgres-integration-tests en-servant --test-show-details=direct
nix develop -c cabal build all
nix develop -c cabal bench en-postgres --benchmark-options='--baseline bench/baseline.csv --fail-if-slower 25'
nix develop -c just openapi
nix fmt -- --fail-on-change
```

Resolve the Koyomi project through Mori rather than assuming a sibling directory, then run its owner
gate from the returned project root:

```bash
mori registry show shinzui/koyomi --full
nix develop -c just test-en-owner
```

Record the actual commands, dates, relevant result rows, and pass/fail status in Progress,
Surprises & Discoveries, and Outcomes & Retrospective as milestones finish.


## Validation and Acceptance

The following observable statements define completion:

1. The PostgreSQL integration suite proves generation metadata uses no more than two database
   sessions after the decision, returns the generation visible at the decision's exact snapshot,
   fails unavailable when history disappears or retention advances, and never returns a value from
   a later snapshot.

2. Servant tests prove the initial malformed/expired client-token surface remains HTTP 400 while a
   failure resolving metadata for a completed `FullyConsistent` check is HTTP 503 and retryable.
   Legacy embedded hosts still omit `grantGeneration`; the live PostgreSQL host never silently does.

3. `en-grant-generation-spike --smoke` completes quickly enough for routine local use, and the full
   command measures the declared history sizes, snapshot distances, concurrency widths, storage
   sizes, and pruning backlogs. Both modes verify returned generations and retained floors rather
   than timing unchecked SQL.

4. At one million retained generations on the reference host, fresh and 32-newer-generation reads
   have p95 below 5 ms, midpoint and oldest-floor reads have p95 below 25 ms, and JSON EXPLAIN shows
   lookup steps growing logarithmically rather than linearly with history. The result note includes
   the host and PostgreSQL version so another operator can reproduce rather than misapply the
   absolute numbers.

5. Concurrent-write measurements report both production-trigger and disposable trigger-disabled
   results at widths 1, 8, and 32. Production runs prove exactly one generation per commit, none per
   rollback, and commit order despite reversed XID allocation. The plan and user documentation state
   the observed throughput/p95 capacity without claiming that the required singleton serialization
   is free.

6. Generation pruning at one million rows deletes no more than its batch limit, retains exactly the
   required floor plus at/above-horizon rows, terminates with an empty batch, and has a recorded
   latency/buffer curve. Concurrent locked victims and rollback/retry behavior from Plan 69 remain
   green.

7. All En packages build, focused tests pass, formatting and generated OpenAPI are clean, and
   Koyomi's actual-owner cursor/revocation gate passes against the optimized En server.


## Idempotence and Recovery

The spike creates an `ephemeral-pg` database and destroys it when the process exits. Re-running it is
safe and does not touch an operator database. Synthetic XIDs and disabled triggers are permitted only
inside that disposable instance. Ensure cleanup is bracketed so an exception cannot leave a child
database process running.

Files under `.dev/` are local result artifacts and must not become authoritative baselines. The
compact result tables copied into this plan must state their date and environment. If a run is
interrupted, discard its JSON and rerun the entire relevant matrix; do not compare partial samples.

Integration tests also use isolated databases and may be repeated. Never run the million-row seed,
trigger-disabled counterfactual, or destructive reset SQL against `EN_DATABASE_URL` or
`PG_CONNECTION_STRING`. The spike must accept no external database URL.

If an optimization fails correctness or plan-shape acceptance, retain the current production query,
record the counterexample, and revise the plan before attempting another design. Do not weaken
exact-snapshot or floor-retention tests. If a migration is necessary, create the next migration and
test forward upgrade; never edit or delete `0002-grant-generations.sql`, and never repair the
pg-migrate ledger by hand.

The read-path code change is recoverable by reverting its ordinary Haskell commit while leaving any
already-applied additive migration in place. Therefore an added migration must be harmless to the
old query until the new code is deployed.


## Interfaces and Dependencies

Reuse the versions already selected by `cabal.project`; this plan introduces no new package or
dependency bound.

`ephemeral-pg` (`EphemeralPg`) owns the disposable PostgreSQL lifecycle for
`en-postgres/grant-generation-spike/Main.hs`. `pg-migrate` applies
`En.Migrations.enMigrationPlan`. Hasql supplies `Connection`, `Session`, prepared `Statement`s, and
JSON EXPLAIN decoding. `GHC.Clock.getMonotonicTimeNSec` supplies elapsed-time measurement. Base
concurrency primitives open coordinated connections for write contention. Follow the local
`en-postgres/lookup-spike/Main.hs` implementations of acquisition, warm-up, p50/p95, and error
rendering.

The new executable interface is:

```text
en-grant-generation-spike [--smoke] [--json FILE] [--compare BEFORE.json]
```

Default mode runs the full matrix. `--smoke` uses at most 10,000 history rows and reduced samples but
executes every scenario family. `--json FILE` writes a versioned machine-readable result while still
rendering the human table. `--compare` loads a result with the same schema version and scenario keys,
prints deltas, and exits nonzero on missing scenarios, correctness differences, declared limit
failures, or unintended regressions over 25 percent.

Keep `GrantGeneration` opaque and retain:

```haskell
grantGenerationText :: GrantGeneration -> Text
grantGenerationAtSession :: Revision -> Session (Maybe GrantGeneration)
pruneGrantGenerationsBatchSession :: Word64 -> Int -> Session Int64
```

The exact helper split may change, but the post-check operation must still present:

```haskell
grantGenerationForToken
  :: (ConsistencyStore :> es, Database :> es, Error EnError :> es)
  => ConsistencyToken
  -> Eff es (Maybe Text)
```

If a clearer type is needed to enforce “already checked, metadata failures are unavailable,” add a
small internal wrapper rather than exposing PostgreSQL details through `en-servant`. Do not change
the `gg1_` wire format, `checkedAt` token format, or the optional field behavior for embedded hosts.

The existing packages are registered locally as `mori://shinzui/en/packages/en-postgres`,
`mori://shinzui/en/packages/en-servant`, and `mori://shinzui/en/packages/en-migrations`. The consumer
acceptance dependency is the En owner contract referenced by
`mori://shinzui/koyomi/plans/5-expose-authorized-calendar-http-apis-and-typed-clients`; use Mori to
resolve its checkout before running the cross-repository gate.
