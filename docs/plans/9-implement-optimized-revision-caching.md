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

- [ ] Add an optimized revision cache type and constructor in `en-postgres`.
- [ ] Wire `postgresTupleStore` so `optimizedRevision` can use the cached reader while `headRevision` always calls `headRevisionSession`.
- [ ] Add tests proving cached reuse, expiry, and disabled-cache behavior.
- [ ] Run `cabal test en-postgres-revision-tests` and `cabal build all`.


## Surprises & Discoveries

None yet.


## Decision Log

- Decision: Implement optimized revision caching in `en-postgres`, not `en-core`.
  Rationale: `en-core` only knows that `TupleStore.optimizedRevision` returns a `Revision`; the PostgreSQL package owns how to obtain and reuse `pg_snapshot` values.
  Date: 2026-06-23
- Decision: Keep `FullyConsistent` uncached.
  Rationale: `FullyConsistent` is the explicit request for the current head revision. Caching it would make the mode misleading and reduce safety.
  Date: 2026-06-23


## Outcomes & Retrospective

To be filled during and after implementation.


## Context and Orientation

The relevant core type is `TupleStore` in `en-core/src/En/Effect/TupleStore.hs`. Its fields include `headRevision :: m Revision` and `optimizedRevision :: m Revision`. `headRevision` is for freshest reads. `optimizedRevision` is for lower-latency reads that may use a recent snapshot.

The PostgreSQL implementation is in `en-postgres/src/En/Postgres/TupleStore.hs`. Today `postgresTupleStore` sets both fields to `run headRevisionSession`, so the optimized path does not cache anything. `headRevisionSession` runs:

```sql
SELECT pg_current_snapshot()::text
```

Consistency resolution lives in `en-postgres/src/En/Postgres/Revision.hs`. `resolveConsistencyRequest` selects `optimized` for `MinimizeLatency`, selects `headRevision` for `FullyConsistent`, and for `AtLeastAsFresh token` compares the optimized revision with the token revision. That means an optimized revision may be cached as long as it remains a valid snapshot and the comparison logic still chooses the token revision when read-your-writes requires it.

The current tests for revision resolution are in `en-postgres/test/Main.hs`. Integration tests using a real PostgreSQL instance are in `en-postgres/integration-test/Main.hs`.


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

Milestone 2 wires the cache into the PostgreSQL tuple store. Keep the existing `postgresTupleStore :: PostgresSessionRunner m -> ConsistencyConfig -> TupleStore m` for effect-polymorphic callers. Add an IO-specific constructor such as:

```haskell
postgresTupleStoreIOWithOptimizedRevision ::
    Connection ->
    ConsistencyConfig ->
    OptimizedRevisionConfig ->
    IO (TupleStore IO)
```

This constructor builds the normal store and replaces only `optimizedRevision` with the cached reader. Leave `headRevision` as `run headRevisionSession`. Keep `postgresTupleStoreIO` as the current uncached convenience function or make it call the new constructor with caching disabled only if doing so does not force unsafe top-level IO.

Milestone 3 tests the behavior. Add pure or IO tests to `en-postgres/test/Main.hs` using a fake underlying revision reader that increments an `IORef` counter and returns deterministic revisions. Verify these cases:

- Disabled config calls the underlying reader on every `optimizedRevision`.
- Enabled config returns the same revision and increments the counter once inside the TTL.
- Enabled config refreshes after the TTL.
- `headRevision` remains uncached in the tuple store constructor that supports caching.

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

Edit the `en-postgres` source and package metadata. If adding a new module, expose it in `en-postgres/en-postgres.cabal`.

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

The changes are additive. Re-running the tests is safe. If the cached constructor causes API churn, keep the existing `postgresTupleStoreIO` behavior and add the new constructor alongside it rather than replacing callers. If concurrency concerns arise, choose correctness over perfect single-flight behavior; duplicate refreshes are acceptable, stale reuse beyond TTL is not.


## Interfaces and Dependencies

This plan uses only existing dependencies: `base`, `time`, `en-core`, `hasql`, and the current `en-postgres` modules. It must not add a third-party cache dependency.

At completion, the repository should expose an optimized revision cache configuration and an IO constructor for a PostgreSQL `TupleStore` whose `optimizedRevision` uses that cache. The exact module name can be `En.Postgres.Revision` if the implementation is small, or `En.Postgres.OptimizedRevision` if the code is clearer as a separate module. If a new module is created, add it to `en-postgres/en-postgres.cabal`.
