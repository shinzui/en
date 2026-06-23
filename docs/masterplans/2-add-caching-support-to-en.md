---
id: 2
slug: add-caching-support-to-en
title: "Add Caching Support to en"
kind: master-plan
created_at: 2026-06-23T15:06:38Z
intention: "intention_01kvtg84azehbsj9zgsfd71y90"
---

# Add Caching Support to en

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

This initiative adds production-grade in-process caching support to `en` so protected request paths can reuse resolved revisions, tuple reads, and authorization subproblems without changing the semantics of `check`, `lookup`, `expand`, or consistency tokens. After completion, a user running the embedded library or standalone service can enable bounded caches, observe cache hit and miss counters in tests or service logs, and verify that repeated authorization queries at the same resolved revision avoid repeated PostgreSQL reads or repeated graph traversal.

The work is deliberately local and conservative. It includes an optimized revision cache for `MinimizeLatency`, core cache interfaces and statistics, a tuple-read cache wrapper around `TupleStore`, a decision/subproblem cache for repeated `check` work and lookup confirmations, service wiring through environment variables, documentation, and validation tests. It explicitly excludes a distributed cache, cross-process invalidation, a Watch API, a materialized reverse index, and any behavior that reuses a decision across a different datastore id, schema hash, resolved revision, subject, object, permission, or caveat context.

The implementation must preserve the current safety rule: protected operations fail closed unless the engine returns `Allowed`. Cache misses must behave exactly like the uncached engine. Cache hits must only return results that would have been valid at the same resolved revision and schema hash.


## Decomposition Strategy

The initiative is decomposed by cache layer, ordered from the lowest-risk freshness primitive to higher-level cached decisions. Optimized revision caching comes first because it makes `MinimizeLatency` actually share a snapshot; without that, result caches have poor hit rates. Core cache interfaces and configuration come next because tuple-read and decision caches need a shared vocabulary for bounded maps, keys, statistics, and disabled-by-default configuration.

Tuple-read caching and authorization decision caching are separate work streams. Tuple-read caching wraps the storage boundary and can be proven with counting stores before changing the algorithms. Decision caching touches `En.Check` and the lookup confirmation path, so it depends on stable cache interfaces and benefits from tuple-read cache tests but should remain independently verifiable. Final service wiring and validation come last because it consumes all cache layers and turns them into operational behavior.

An alternative single large plan was rejected because it would couple revision semantics, cache data structures, graph traversal changes, and service configuration in one difficult review. A distributed cache plan was rejected because `en` currently targets one organization on PostgreSQL and should first get correct in-process cache semantics, matching the local-process cache pattern documented in OpenFGA and the server-side cache pattern used by SpiceDB.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-9 | Implement optimized revision caching | docs/plans/9-implement-optimized-revision-caching.md | None | None | Not Started |
| EP-10 | Add core cache interfaces and configuration | docs/plans/10-add-core-cache-interfaces-and-configuration.md | None | EP-9 | Not Started |
| EP-12 | Implement tuple read caching | docs/plans/12-implement-tuple-read-caching.md | EP-10 | EP-9 | Not Started |
| EP-11 | Implement authorization decision caching | docs/plans/11-implement-authorization-decision-caching.md | EP-10 | EP-12 | Not Started |
| EP-13 | Wire caching into service operations and validation | docs/plans/13-wire-caching-into-service-operations-and-validation.md | EP-9, EP-10, EP-11, EP-12 | None | Not Started |


## Dependency Graph

EP-9 can start immediately. It changes `en-postgres/src/En/Postgres/TupleStore.hs` and `en-postgres/src/En/Postgres/Revision.hs` so `optimizedRevision` can return a bounded-age cached snapshot instead of always calling `headRevisionSession`. This does not require the higher-level cache abstractions, but later caches benefit from it because many `MinimizeLatency` reads will resolve to the same `Revision`.

EP-10 can also start immediately, though it has a soft dependency on EP-9 for naming consistency around freshness windows. EP-10 owns the shared cache types in `en-core`, including bounded in-memory map behavior, cache statistics, and cache key data types that include datastore id, schema hash, and revision. EP-12 and EP-11 both depend hard on EP-10 because they must use the same cache implementation and stats model.

EP-12 depends hard on EP-10 because tuple-read caching requires the shared bounded cache and statistics types. It has a soft dependency on EP-9 because optimized revisions improve hit rates, but the tuple-read wrapper can be implemented and tested with a fixed test revision before EP-9 is complete.

EP-11 depends hard on EP-10 because decision caching needs shared key and stats types. It has a soft dependency on EP-12 because both cache layers can be tested independently, but decision-cache performance validation is easier when tuple reads can also be counted. EP-11 must not depend hard on EP-12; a user should be able to enable decision caching without tuple-read caching.

EP-13 depends on all earlier plans. It wires cache construction into `en-server/app/Main.hs`, updates `docs/user/production-deployment-and-performance.md`, adds service-level tests or transcripts, and records validation evidence. It should not begin until the lower-level cache APIs are stable.


## Integration Points

The `Revision` selection path is shared by EP-9, EP-10, EP-12, EP-11, and EP-13. EP-9 defines how `MinimizeLatency` obtains a reusable optimized revision. Later plans must treat the resolved revision as part of every cache key and must not invent separate freshness semantics.

The core cache module is owned by EP-10. The expected artifact is a new module such as `en-core/src/En/Cache.hs`, exposed from `en-core/en-core.cabal`, with bounded cache construction, lookup/insert operations, configuration records, and statistics. EP-12 and EP-11 consume this module rather than creating independent cache maps.

The tuple-store boundary is shared by EP-12, EP-11, and EP-13. EP-12 owns a wrapper around `En.Effect.TupleStore.TupleStore` that caches `readObjectRelation` and `readStartingWithUser` results by resolved revision and read parameters. EP-11 can rely on this wrapper but must not change tuple-store semantics. EP-13 decides whether the service enables the wrapper.

The check and lookup algorithms are shared by EP-11 and EP-13. EP-11 owns changes to `en-core/src/En/Check.hs` and the lookup confirmation path in `en-core/src/En/Lookup.hs`. EP-13 only wires the resulting API into service configuration and docs.

The `.cabal` files are shared integration points. EP-10 may add `En.Cache` to `en-core/en-core.cabal`; EP-12 and EP-11 may add tests in `en-core/test/Main.hs`; EP-13 may add dependencies or environment parsing in `en-server/en-server.cabal` and `en-server/app/Main.hs`. Every plan that touches package metadata must keep `cabal build all` green.

The production docs are owned by EP-13. Earlier plans may update narrow API docs if needed, but EP-13 must reconcile the final user-facing story in `docs/user/production-deployment-and-performance.md`.


## Progress

- [ ] EP-9: Add an optimized revision cache configuration and implementation for PostgreSQL-backed stores.
- [ ] EP-9: Prove `MinimizeLatency` can reuse a cached optimized revision while `FullyConsistent` still reads the head revision.
- [ ] EP-10: Add shared bounded cache types, cache configuration, and cache statistics in `en-core`.
- [ ] EP-10: Add focused tests proving cache keys include datastore id, schema hash, revision, and request-shaping values.
- [ ] EP-12: Add a `TupleStore` cache wrapper for object-relation and reverse userset reads.
- [ ] EP-12: Prove repeated tuple reads at the same revision hit cache and reads at different revisions miss.
- [ ] EP-11: Add decision/subproblem caching for forward `check` and lookup confirmation checks.
- [ ] EP-11: Prove repeated authorization checks reuse cached subproblems without changing `Allowed`, `Denied`, or `Conditional` results.
- [ ] EP-13: Wire cache configuration into `en-server` and embedded-library examples.
- [ ] EP-13: Update production docs and run full build/test validation with cache-enabled scenarios.


## Surprises & Discoveries

None yet.


## Decision Log

- Decision: Create a dedicated caching MasterPlan instead of appending work to the completed ReBAC toolkit MasterPlan.
  Rationale: The first MasterPlan is complete and covers core ReBAC behavior. Caching is a cross-cutting production initiative with several independently verifiable layers and deserves its own progress, dependency, and retrospective tracking.
  Date: 2026-06-23
- Decision: Pass `intention_01kvtg84azehbsj9zgsfd71y90` to the MasterPlan and every child ExecPlan.
  Rationale: The user explicitly requested that this caching planning work use that intention id, so the frontmatter carries it for tracking.
  Date: 2026-06-23
- Decision: Start with in-process bounded caches and exclude distributed invalidation.
  Rationale: `en` currently targets a single organization on PostgreSQL and already resolves reads to explicit revisions. In-process revision-scoped caches can be correct and useful without introducing cross-process coherence complexity.
  Date: 2026-06-23
- Decision: Make cache keys include resolved revision and schema identity rather than trying to invalidate decisions on every write.
  Rationale: The tuple store already supports point-in-time reads. A decision at revision R is safe to reuse only for R and the same schema hash; a later write produces a later revision and naturally misses without active invalidation.
  Date: 2026-06-23


## Outcomes & Retrospective

To be filled during and after implementation.
