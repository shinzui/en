---
id: 12
slug: implement-tuple-read-caching
title: "Implement tuple read caching"
kind: exec-plan
created_at: 2026-06-23T15:06:50Z
intention: "intention_01kvtg84azehbsj9zgsfd71y90"
master_plan: "docs/masterplans/2-add-caching-support-to-en.md"
---

# Implement tuple read caching

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan adds a cache wrapper around `TupleStore` reads. After implementation, repeated `readObjectRelation` and `readStartingWithUser` calls with the same resolved revision and same read parameters can return from an in-process cache instead of repeating the underlying datastore read. A user can observe this with tests that use a counting store: the first read increments the counter, the second identical read returns the same `TuplePage` without incrementing it, and a read at a different revision misses.


## Progress

- [ ] Add a tuple-store cache wrapper using `En.Cache`.
- [ ] Cache both object-relation reads and reverse `readStartingWithUser` reads.
- [ ] Preserve write/delete/head/optimized behavior without caching.
- [ ] Add counting-store tests for hits, misses, disabled cache, and revision separation.
- [ ] Run `cabal test en-core-interface-tests` and `cabal build all`.


## Surprises & Discoveries

None yet.


## Decision Log

- Decision: Cache tuple reads at the `TupleStore` boundary.
  Rationale: Both `check`, `lookup`, and `expand` already read through `TupleStore`, so a wrapper improves all algorithms without duplicating datastore-specific logic.
  Date: 2026-06-23
- Decision: Key tuple-read cache entries by resolved `Revision`.
  Rationale: The PostgreSQL store supports point-in-time reads. Reusing tuple pages is safe only for the exact same snapshot and read parameters.
  Date: 2026-06-23


## Outcomes & Retrospective

To be filled during and after implementation.


## Context and Orientation

`TupleStore` is defined in `en-core/src/En/Effect/TupleStore.hs`. It is a record of functions:

```haskell
data TupleStore m = TupleStore
    { readObjectRelation :: Revision -> ObjectRef -> RelationName -> Int -> Maybe StoreCursor -> m TuplePage
    , readStartingWithUser :: Revision -> UsersetQuery -> m TuplePage
    , writeTuples :: [Tuple] -> m ConsistencyToken
    , deleteTuples :: [Tuple] -> m ConsistencyToken
    , headRevision :: m Revision
    , optimizedRevision :: m Revision
    }
```

`check` uses `readObjectRelation` for forward evaluation in `en-core/src/En/Check.hs`. `lookup` uses `readStartingWithUser` for reverse expansion in `en-core/src/En/Lookup.hs`. `expand` uses `readObjectRelation` in `en-core/src/En/Expand.hs`.

The prerequisite plan `docs/plans/10-add-core-cache-interfaces-and-configuration.md` adds `En.Cache`, including `Cache`, `CacheConfig`, `TupleReadKey`, `lookupCache`, `insertCache`, and `cacheStats`.


## Plan of Work

Milestone 1 adds the wrapper. Create a module such as `en-core/src/En/Effect/CachedTupleStore.hs` or add the wrapper to `En.Cache` if the code stays small. Prefer a separate module because the wrapper is specifically about the `TupleStore` effect.

The exported function should be IO-specific because the first cache implementation is in-process and mutable:

```haskell
cachedTupleStore ::
    Cache TupleReadKey TuplePage ->
    TupleStore IO ->
    TupleStore IO
```

The wrapper should:

- Build `ObjectRelationReadKey revision object relation limit cursor` for `readObjectRelation`.
- Build `StartingWithUserReadKey revision query` for `readStartingWithUser`.
- Call `lookupCache` before the underlying read.
- On miss, call the underlying read, insert the returned `TuplePage`, and return it.
- Pass `writeTuples`, `deleteTuples`, `headRevision`, and `optimizedRevision` through unchanged.

Do not invalidate the cache on writes in this plan. Because every entry is keyed by resolved revision, a later write should produce or require a later revision and therefore miss. If a caller deliberately reads an old exact snapshot, the old cached tuple page is still correct for that snapshot.

Milestone 2 adds tests. Use the existing `en-core/test/Main.hs` fixture style. Build a small `TupleStore IO` whose read methods increment `IORef` counters and return deterministic `TuplePage` values. Then wrap it with `cachedTupleStore`.

Test at least:

- Two identical `readObjectRelation` calls at `Revision "r1"` hit the underlying store once.
- The same object-relation read at `Revision "r2"` misses separately.
- Two identical `readStartingWithUser` calls at `Revision "r1"` hit the underlying store once.
- A different cursor or limit misses separately.
- Disabled cache configuration does not suppress underlying reads.

Milestone 3 updates package metadata and documentation comments. Expose the wrapper module in `en-core/en-core.cabal`. Add Haddock comments explaining that this is an in-process cache and that cache entries are safe because they are keyed by resolved revision.


## Concrete Steps

From the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/en
```

Inspect the current store and algorithm callers:

```bash
sed -n '1,120p' en-core/src/En/Effect/TupleStore.hs
rg -n "readObjectRelation|readStartingWithUser" en-core/src en-core/test
```

Edit:

- `en-core/src/En/Effect/CachedTupleStore.hs`
- `en-core/en-core.cabal`
- `en-core/test/Main.hs`

Run focused tests:

```bash
cabal test en-core-interface-tests
```

Run the full build:

```bash
cabal build all
```


## Validation and Acceptance

The tuple-read cache is accepted when counting-store tests prove that repeated reads at the same revision and same parameters avoid underlying calls, and reads with a different revision, cursor, or limit miss. Existing `check`, `lookup`, and `expand` tests must still pass, proving the wrapper did not change authorization semantics.


## Idempotence and Recovery

The wrapper is additive. If tests become too large in `en-core/test/Main.hs`, split helper functions locally within that file before creating a new test suite. If a cache key lacks an `Ord` instance, add deriving to the underlying core type only if the ordering is over an opaque stable encoding or already semantically ordered values.


## Interfaces and Dependencies

This plan depends on `docs/plans/10-add-core-cache-interfaces-and-configuration.md`. It uses `En.Cache`, `En.Effect.TupleStore`, `En.Revision`, `En.Tuple`, and `En.Schema`. It should not depend on PostgreSQL or Hasql because the wrapper must work for any IO `TupleStore`.
