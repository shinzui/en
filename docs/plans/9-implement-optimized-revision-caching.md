---
id: 9
slug: implement-optimized-revision-caching
title: "Implement optimized revision caching"
kind: exec-plan
created_at: 2026-06-23T15:06:50Z
intention: "intention_01kvtg84azehbsj9zgsfd71y90"
master_plan: "docs/masterplans/2-add-caching-support-to-en.md"
---

# Implement optimized revision caching

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`MinimizeLatency` is documented as using an optimized cached revision, but the current PostgreSQL store returns `headRevisionSession` for both `headRevision` and `optimizedRevision`. After this change, a PostgreSQL-backed `TupleStore` can reuse a recent `pg_current_snapshot()` for `MinimizeLatency` requests for a short configured window, while `FullyConsistent` continues to resolve against the current head. A user can see the behavior with a unit test that calls `optimizedRevision` repeatedly and observes one underlying snapshot read until the cache window expires.


## Progress

- [x] Confirm MasterPlan 3 is complete and adjust this plan to the current `effectful` interpreter architecture. Completed 2026-06-23T23:59:00Z.
- [x] Add an optimized revision cache type and constructor in `en-postgres`. Completed 2026-06-23T23:59:54Z.
- [x] Wire the PostgreSQL `TupleStore` interpreter so `OptimizedRevision` can use the cached reader while `HeadRevision` always calls `headRevisionSession`. Completed 2026-06-23T23:59:54Z.
- [x] Add tests proving cached reuse, expiry, disabled-cache behavior, and `FullyConsistent` head revision selection. Completed 2026-06-23T23:59:54Z.
- [x] Run `nix develop -c cabal test en-postgres-revision-tests` and `nix develop -c cabal build all`. Completed 2026-06-23T23:59:54Z.


## Surprises & Discoveries

- MasterPlan 3 is already implemented in the current tree: `docs/masterplans/3-harden-en-correctness-fixes-lookup-streaming-and-performance-benchmarks.md` marks EP-14 through EP-19 Complete, and source inspection found the expected artifacts, including `En.Decision`, `checkMany`, and the faithful `comparePgSnapshot` implementation. This satisfies the cross-MasterPlan prerequisites for this plan before implementation begins. _(2026-06-23)_
- A later ExecPlan (`docs/plans/25-adopt-effectful-for-the-en-effect-stack.md`) migrated the engine and PostgreSQL store from record-of-functions constructors to `effectful` interpreters. The implementation target is now `runTupleStorePostgres` in `en-postgres/src/En/Postgres/TupleStore.hs`; the cached path should be an additional interpreter/configuration path rather than the obsolete `postgresTupleStoreIOWithOptimizedRevision` constructor. _(2026-06-23)_
- The existing `runTupleStorePostgres` interpreter can stay uncached and keep its no-`IOE` type. The new `runTupleStorePostgresWithOptimizedRevisionCache` allocates an `OptimizedRevisionCache` once around the interpreted action and only changes the `OptimizedRevision` operation, so current callers and `HeadRevision` behavior remain unchanged. _(2026-06-23)_


## Decision Log

- Decision: Implement optimized revision caching in `en-postgres`, not `en-core`.
  Rationale: `en-core` only knows that `TupleStore.optimizedRevision` returns a `Revision`; the PostgreSQL package owns how to obtain and reuse `pg_snapshot` values.
  Date: 2026-06-23
- Decision: Keep `FullyConsistent` uncached.
  Rationale: `FullyConsistent` is the explicit request for the current head revision. Caching it would make the mode misleading and reduce safety.
  Date: 2026-06-23
- Decision: Build on MasterPlan 3 EP-14's corrected snapshot comparator rather than the pre-hardening `snapshotIncludes`.
  Rationale: MasterPlan 3 is implemented in full before this MasterPlan (see `docs/masterplans/2-add-caching-support-to-en.md` Decision Log), so EP-14's faithful `comparePgSnapshot`/`snapshotIncludes` and stabilized token codec are already in `en-postgres/src/En/Postgres/Revision.hs`. Sharing a snapshot across `MinimizeLatency` requests is only safe atop a correct partial order, so this plan must not reintroduce the old probe approximation and must preserve EP-14's `AtLeastAsFresh = max(optimized, token)` semantics.
  Date: 2026-06-23
- Decision: Preserve the existing uncached `runTupleStorePostgres` interpreter and add a cached variant.
  Rationale: `runTupleStorePostgres` intentionally has no `IOE` constraint after the effectful migration. Optimized revision caching needs an `IORef` and clock reads, so the least disruptive API is a new `runTupleStorePostgresWithOptimizedRevisionCache` interpreter that EP-13 can opt into from service wiring while existing callers remain unchanged.
  Date: 2026-06-23


## Outcomes & Retrospective

Implemented EP-9 on 2026-06-23. `en-postgres/src/En/Postgres/Revision.hs` now exposes `OptimizedRevisionConfig`, `OptimizedRevisionCache`, and `newOptimizedRevisionReader` plus cache lookup/store helpers. `en-postgres/src/En/Postgres/TupleStore.hs` now exposes `runTupleStorePostgresWithOptimizedRevisionCache`, an opt-in interpreter that caches only `OptimizedRevision` reads. The original `runTupleStorePostgres` interpreter remains unchanged for existing callers.

Validation passed with:

```text
nix develop -c cabal test en-postgres-revision-tests
Test suite en-postgres-revision-tests: PASS

nix develop -c cabal build all
Build completed successfully.
```

The direct ambient `cabal test en-postgres-revision-tests` command was not usable because `ghc-9.12.4` is only available inside the Nix shell; the Nix-shell command is the authoritative validation for this workspace.


## Context and Orientation

The relevant core type is `TupleStore` in `en-core/src/En/Effect/TupleStore.hs`. It is an `effectful` effect with operations including `HeadRevision :: TupleStore m Revision` and `OptimizedRevision :: TupleStore m Revision`. `HeadRevision` is for freshest reads. `OptimizedRevision` is for lower-latency reads that may use a recent snapshot.

The PostgreSQL implementation is in `en-postgres/src/En/Postgres/TupleStore.hs`. The current code uses `effectful`: `runTupleStorePostgres` interprets the `TupleStore` effect by running Hasql sessions through `En.Postgres.Database.runSession`. Today the `OptimizedRevision` operation still runs `headRevisionSession`, the same Hasql session used by `HeadRevision`, so the optimized path does not cache anything. `headRevisionSession` runs:

```sql
SELECT pg_current_snapshot()::text
```

Consistency resolution lives in `en-postgres/src/En/Postgres/Revision.hs`. `resolveConsistencyRequest` selects `optimized` for `MinimizeLatency`, selects `headRevision` for `FullyConsistent`, and for `AtLeastAsFresh token` compares the optimized revision with the token revision. That means an optimized revision may be cached as long as it remains a valid snapshot and the comparison logic still chooses the token revision when read-your-writes requires it.

The current tests for revision resolution are in `en-postgres/test/Main.hs`. Integration tests using a real PostgreSQL instance are in `en-postgres/integration-test/Main.hs`.

**Cross-MasterPlan prerequisite (MasterPlan 3 EP-14, already complete).** This plan's MasterPlan (`docs/masterplans/2-add-caching-support-to-en.md`) sequences MasterPlan 3 (en hardening) in full *before* this MasterPlan, so MasterPlan 3 EP-14 (`docs/plans/14-harden-consistency-faithful-snapshot-visibility-gc-window-and-token-reconciliation.md`) is a **completed prerequisite** by the time you implement this plan. EP-14 rewrites the same file you edit (`en-postgres/src/En/Postgres/Revision.hs`): it replaces the finite-probe `snapshotIncludes` with a faithful, oracle-tested partial-order comparator, stabilizes the token codec (base64 / ISO-8601 expiry), adds a GC-window token check, and keeps `optimizedRevision` aliased to `headRevision` (it explicitly leaves quantization to *this* plan). Two consequences for your work: (1) build your quantized/cached optimized revision on EP-14's corrected `comparePgSnapshot`/`snapshotIncludes` — do not reintroduce the probe approximation — and confirm `resolveConsistencyRequest`'s `AtLeastAsFresh` path still computes `max(optimized, token)` so a cached optimized revision never silently overrides a fresher token; (2) expect EP-14's edits to `Revision.hs` already present in the tree (corrected comparator, token format, `gcWindow` field on `ConsistencyConfig`) and add the cache alongside them. Do not change EP-14's comparator or `AtLeastAsFresh` semantics.


## Plan of Work

Milestone 1 adds the reusable optimized revision cache. In `en-postgres/src/En/Postgres/Revision.hs` or a new `en-postgres/src/En/Postgres/OptimizedRevision.hs` module, define a small IO-only cache because the production PostgreSQL store is already IO-backed when used by `en-server`. The cache should store the last `Revision` and the time at which it was loaded. Use `Data.IORef` from `base` and `UTCTime` from `time`; do not add a new dependency for this plan.

The cache configuration should be explicit:

```haskell
data OptimizedRevisionConfig = OptimizedRevisionConfig
    { enabled :: !Bool
    , ttl :: !NominalDiffTime
    }
```

Provide a constructor shaped like:

```haskell
newOptimizedRevisionReader ::
    OptimizedRevisionConfig ->
    IO UTCTime ->
    IO Revision ->
    IO (IO Revision)
```

When disabled or when `ttl <= 0`, the returned reader should call the underlying `IO Revision` every time. When enabled, it should return the cached revision if `now - loadedAt <= ttl`; otherwise it should read a fresh revision and replace the cache. Use `atomicModifyIORef'` or a simple `IORef` read/write with the understanding that occasional duplicate refreshes under concurrency are acceptable for this first version. The correctness property is that every returned value is a real PostgreSQL snapshot.

Milestone 2 wires the cache into the PostgreSQL tuple-store interpreter. Keep the existing `runTupleStorePostgres` behavior unchanged for callers that want the current uncached interpreter. Add a cached interpreter such as:

```haskell
runTupleStorePostgresWithOptimizedRevisionCache ::
    (Database :> es, IOE :> es, Error EnError :> es) =>
    ConsistencyConfig ->
    OptimizedRevisionConfig ->
    Eff (TupleStore : es) a ->
    Eff es a
```

This interpreter should allocate the cache once, before interpreting the supplied action, and replace only the `OptimizedRevision` operation with the cached reader. Leave `HeadRevision` as a direct `headRevisionSession` read. Keeping the uncached interpreter unchanged also preserves the no-`IOE` shape introduced by the effectful migration.

Milestone 3 tests the behavior. Add pure or IO tests to `en-postgres/test/Main.hs` using a fake underlying revision reader that increments an `IORef` counter and returns deterministic revisions. Verify these cases:

- Disabled config calls the underlying reader on every `optimizedRevision`.
- Enabled config returns the same revision and increments the counter once inside the TTL.
- Enabled config refreshes after the TTL.
- `headRevision` remains uncached in the tuple-store interpreter that supports caching.

If the test needs controllable time, use an `IORef UTCTime` as the clock supplied to `newOptimizedRevisionReader`.


## Concrete Steps

From the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/en
```

Inspect the current revision and tuple-store code:

```bash
sed -n '1,260p' en-postgres/src/En/Postgres/Revision.hs
sed -n '1,140p' en-postgres/src/En/Postgres/TupleStore.hs
```

Edit the `en-postgres` source. If adding a new module, expose it in `en-postgres/en-postgres.cabal`; otherwise export the cache types/functions from `En.Postgres.Revision` and the cached interpreter from `En.Postgres.TupleStore`.

Run the focused tests:

```bash
cabal test en-postgres-revision-tests
```

Expected successful output includes a final test-suite success line similar to:

```text
Test suite en-postgres-revision-tests: PASS
```

Then run the full build:

```bash
cabal build all
```


## Validation and Acceptance

Acceptance requires tests that demonstrate the cache changes observable behavior. A repeated `optimizedRevision` call with an enabled TTL must return the first fake revision and leave the fake underlying reader count at one. A call after advancing the fake clock beyond the TTL must return the next fake revision and increase the count. A `FullyConsistent` resolution path must still use `headRevision`; this can be proven either by existing `resolveConsistencyRequest` tests or by a new test around a `ConsistencyStore` built from different optimized and head readers.

`cabal test en-postgres-revision-tests` and `cabal build all` must pass.


## Idempotence and Recovery

The changes are additive. Re-running the tests is safe. If the cached interpreter causes API churn, keep the existing `runTupleStorePostgres` behavior and add the new interpreter alongside it rather than replacing callers. If concurrency concerns arise, choose correctness over perfect single-flight behavior; duplicate refreshes are acceptable, stale reuse beyond TTL is not.


## Interfaces and Dependencies

This plan uses only existing dependencies: `base`, `time`, `en-core`, `hasql`, and the current `en-postgres` modules. It must not add a third-party cache dependency.

At completion, the repository should expose an optimized revision cache configuration and a PostgreSQL `TupleStore` interpreter whose `OptimizedRevision` operation uses that cache. The exact module name can be `En.Postgres.Revision` if the implementation is small, or `En.Postgres.OptimizedRevision` if the code is clearer as a separate module. If a new module is created, add it to `en-postgres/en-postgres.cabal`.


---

**Revision note (2026-06-23).** Reconciled this plan with the already-complete MasterPlan 3 and the post-planning effectful migration before implementation. The plan now targets `runTupleStorePostgresWithOptimizedRevisionCache` rather than obsolete record-of-functions tuple-store constructors, and records that the existing uncached `runTupleStorePostgres` interpreter should remain API-compatible.
