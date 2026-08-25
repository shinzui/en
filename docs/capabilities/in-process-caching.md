---
title: "In-process decision and tuple-read caching"
type: Capability
description: "Bounded in-process caches for authorization decisions, evaluation subproblems, and tuple reads, wired in as a store decorator, with hit/miss statistics exposed for metrics."
generated:
  by: anthropic/claude-opus-5
  at: "2026-08-24T14:35:00Z"
capabilityId: CAP-15
provider: mori://shinzui/en
status: shipped
stability: experimental
since: unreleased
packages:
  - en-core
interface:
  - En.Cache
  - En.Effect.CachedTupleStore
requires:
  - CAP-11
evidence:
  - kind: test
    resource: en-core/test/Main.hs
    proves: testCacheOperations and testCachedTupleStore cover insert/lookup/eviction and the decorated store's behavior; testDecisionCache exercises the decision cache against a compiled graph.
  - kind: guide
    resource: docs/user/production-deployment-and-performance.md
    proves: "The Caching section: what is safe to cache, for how long, and how consistency modes interact with it."
---

# In-process caching

`En.Cache` provides bounded caches keyed by `DecisionKey`, `SubproblemKey`, and `TupleReadKey`.
`cachedTupleStore` decorates any `TupleStore` with the read cache, so caching is opt-in
composition rather than a mode inside the engine.

`cacheStats` returns hits, misses, and size; [the standalone server](standalone-authorization-server.md)
publishes these on its Prometheus endpoint.

## Usage

```haskell
cache <- newCache cacheConfig
runStore & cachedTupleStore cache
```

## Limits

- Caches are per-process and unshared. Two server replicas cache independently.
- Entries are keyed by snapshot-bearing keys, so a cache cannot serve a
  [token-pinned read](consistency-tokens-and-snapshot-reads.md) an answer from a different
  revision — but it also means a `MinimizeLatency` hit can be older than head by the cache TTL.
- Bounded means evicting. A working set larger than the configured size will thrash.
