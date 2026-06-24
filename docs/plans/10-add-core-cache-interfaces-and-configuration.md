---
id: 10
slug: add-core-cache-interfaces-and-configuration
title: "Add core cache interfaces and configuration"
kind: exec-plan
created_at: 2026-06-23T15:06:50Z
intention: "intention_01kvtg84azehbsj9zgsfd71y90"
master_plan: "docs/masterplans/2-add-caching-support-to-en.md"
---

# Add core cache interfaces and configuration

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan adds the shared cache vocabulary that later tuple-read and decision caches will use. After this change, `en-core` has a bounded in-memory cache abstraction, cache configuration, cache statistics, and typed key material that makes it hard to accidentally reuse cached authorization data across a different datastore, schema, revision, or request shape. A user can see it working through focused tests that insert values, observe hits and misses, and prove eviction when the configured maximum size is exceeded.


## Progress

- [x] Reconcile EP-10 with current `Revision` ordering semantics before implementation. Completed 2026-06-23T23:59:54Z.
- [x] Add `En.Cache` with bounded cache operations, configuration, and stats. Completed 2026-06-24T00:05:35Z.
- [x] Add cache key types for tuple reads and authorization decisions. Completed 2026-06-24T00:05:35Z.
- [x] Expose the module from `en-core/en-core.cabal`. Completed 2026-06-24T00:05:35Z.
- [x] Add `en-core` tests for hits, misses, eviction, and key separation. Completed 2026-06-24T00:05:35Z.
- [x] Run `nix develop -c cabal test en-core-interface-tests` and `nix develop -c cabal build all`. Completed 2026-06-24T00:05:35Z.


## Surprises & Discoveries

- `Revision` deliberately has no global `Ord` instance in `en-core/src/En/Revision.hs` because datastore revisions form a partial order. Cache key types still need deterministic `Map` ordering, so EP-10 should avoid adding `Ord Revision` and instead implement local `Ord` instances for cache keys that compare `revisionEncoding` only as opaque identity bytes. This preserves the semantic invariant while allowing in-process maps. _(2026-06-23)_
- Exporting cache key record fields as normal selectors collided with the existing `En.Schema.schemaHash` function in the interface tests. `En.Cache` now uses `NoFieldSelectors`, so callers can construct and update keys without exporting selector functions that pollute importing modules. _(2026-06-24)_


## Decision Log

- Decision: Put shared cache interfaces in `en-core`.
  Rationale: Tuple-read caching and decision caching both need the same correctness vocabulary, and `en-core` is already the transport- and database-agnostic package.
  Date: 2026-06-23
- Decision: Use a bounded in-process cache first.
  Rationale: The current production target is one organization on PostgreSQL. Revision-keyed in-process caches are easier to prove correct than distributed invalidation.
  Date: 2026-06-23
- Decision: Do not add a global `Ord` instance to `Revision`.
  Rationale: `Revision` represents datastore snapshots with a partial freshness order, and `En.Revision` intentionally withholds `Ord` to prevent accidental semantic ordering. The cache only needs a deterministic map key, so `En.Cache` key types will compare `revisionEncoding` locally as an opaque identity component.
  Date: 2026-06-23


## Outcomes & Retrospective

Implemented EP-10 on 2026-06-24. `en-core/src/En/Cache.hs` now exposes a bounded in-process cache, `CacheConfig`, `CacheStats`, and shared `TupleReadKey`, `DecisionKey`, and `SubproblemKey` types. The cache records misses even when disabled, records hits/inserts/evictions when enabled, and evicts the oldest inserted entries when `maxEntries` is exceeded. `en-core/en-core.cabal` exposes the module.

Validation passed with:

```text
nix develop -c cabal test en-core-interface-tests
Test suite en-core-interface-tests: PASS

nix develop -c cabal build all
Build completed successfully.
```

The implementation preserves the absence of a global `Ord Revision` instance; the cache key `Ord` instances compare `revisionEncoding` locally only as an opaque map-key component.


## Context and Orientation

`en-core` currently has no cache module. It defines authorization data in `en-core/src/En/Tuple.hs`, schema identity in `en-core/src/En/Schema.hs`, revisions and consistency tokens in `en-core/src/En/Revision.hs`, and store reads in `en-core/src/En/Effect/TupleStore.hs`.

The types already derive enough ordering for deterministic `Map` keys: `ObjectRef`, `Subject`, `Tuple`, `TupleCaveat`, `CaveatContext`, `DatastoreId`, and `SchemaHash` derive `Ord`. `Revision` intentionally derives only `Eq` and `Show`, because revisions have a partial semantic order. Do not add a global `Ord Revision` instance. Instead, write explicit `Ord` instances for `TupleReadKey`, `DecisionKey`, and `SubproblemKey` that compare `revisionEncoding` locally as an opaque identity component.

The new production guide at `docs/user/production-deployment-and-performance.md` already states the desired key shape: datastore id, schema hash, resolved revision, subject, permission or relation, object, and caveat context that affects the answer.


## Plan of Work

Milestone 1 creates `en-core/src/En/Cache.hs`. Keep the first cache simple and deterministic. Use `Data.IORef` and `Data.Map.Strict` from existing dependencies. The cache should be bounded by entry count. A straightforward implementation is a record with an `IORef` containing a `Map key (Entry value)` plus a monotonically increasing insertion counter. On insert, evict the oldest entries until the map size is at or below `maxEntries`. This is enough to prevent unbounded memory growth; perfect LRU is not required for the first implementation.

Provide types like:

```haskell
data CacheConfig = CacheConfig
    { enabled :: !Bool
    , maxEntries :: !Int
    }

data CacheStats = CacheStats
    { hits :: !Int
    , misses :: !Int
    , inserts :: !Int
    , evictions :: !Int
    }

data Cache key value

newCache :: Ord key => CacheConfig -> IO (Cache key value)
lookupCache :: Ord key => Cache key value -> key -> IO (Maybe value)
insertCache :: Ord key => Cache key value -> key -> value -> IO ()
cacheStats :: Cache key value -> IO CacheStats
```

When `enabled = False` or `maxEntries <= 0`, `lookupCache` should always miss and `insertCache` should do nothing. Stats should still record misses so tests and service logs can show disabled behavior.

Milestone 2 adds key types. Put them in `En.Cache` unless the module gets too large. The tuple-read key must cover both store read shapes:

```haskell
data TupleReadKey
    = ObjectRelationReadKey Revision ObjectRef RelationName Int (Maybe StoreCursor)
    | StartingWithUserReadKey Revision UsersetQuery
```

The authorization decision key should include schema identity and request context:

```haskell
data DecisionKey = DecisionKey
    { datastoreId :: !DatastoreId
    , schemaHash :: !SchemaHash
    , revision :: !Revision
    , subject :: !Subject
    , permission :: !RelationName
    , object :: !ObjectRef
    , context :: !CaveatContext
    }
```

If later implementation needs subproblem-level keys, add:

```haskell
data SubproblemKey = SubproblemKey
    { datastoreId :: !DatastoreId
    , schemaHash :: !SchemaHash
    , revision :: !Revision
    , subject :: !Subject
    , relation :: !RelationName
    , object :: !ObjectRef
    , context :: !CaveatContext
    }
```

Milestone 3 adds tests in `en-core/test/Main.hs` or a new `en-core/test/CacheTest.hs` if the test suite is split. Verify:

- A cache hit returns the inserted value.
- A miss increments miss stats.
- Disabled cache never returns inserted values.
- A bounded cache evicts old entries when `maxEntries` is exceeded.
- Two `DecisionKey` values that differ only by schema hash, revision, or context do not collide.


## Concrete Steps

From the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/en
```

Create or edit:

- `en-core/src/En/Cache.hs`
- `en-core/src/En/Revision.hs`
- `en-core/en-core.cabal`
- `en-core/test/Main.hs`

Run focused tests:

```bash
cabal test en-core-interface-tests
```

Expected successful output includes:

```text
Test suite en-core-interface-tests: PASS
```

Run the full build:

```bash
cabal build all
```


## Validation and Acceptance

The change is accepted when `en-core` exposes the cache module, tests prove hit/miss/eviction behavior, and cache keys separate at least schema hash, revision, and caveat context. `cabal test en-core-interface-tests` and `cabal build all` must pass.


## Idempotence and Recovery

The cache module is additive. If a test split creates Cabal configuration issues, keep the tests in the existing `en-core/test/Main.hs` to minimize moving parts. If the bounded eviction implementation becomes too complex, prefer oldest-insertion eviction over LRU; correctness and bounded memory matter more than recency precision.


## Interfaces and Dependencies

Use only existing dependencies already available to `en-core`: `base`, `containers`, `text`, `time`, and `unordered-containers` if needed. Prefer `Data.Map.Strict` so key ordering is explicit and deterministic.

At completion, later plans can import `En.Cache` to create bounded caches for tuple pages and authorization decisions. The module must not depend on Servant, Hasql, Warp, or PostgreSQL.


---

**Revision note (2026-06-24).** Reconciled EP-10 with the current `Revision` invariant before implementation and then completed the plan. The plan now preserves the absence of a global `Ord Revision` instance, uses local cache-key ordering by opaque `revisionEncoding`, and records the passing Nix-shell validation commands.
