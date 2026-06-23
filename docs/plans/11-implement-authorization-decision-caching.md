---
id: 11
slug: implement-authorization-decision-caching
title: "Implement authorization decision caching"
kind: exec-plan
created_at: 2026-06-23T15:06:50Z
intention: "intention_01kvtg84azehbsj9zgsfd71y90"
master_plan: "docs/masterplans/2-add-caching-support-to-en.md"
---

# Implement authorization decision caching

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan adds decision caching for repeated authorization work. After implementation, repeated `check` calls for the same datastore id, schema hash, resolved revision, subject, permission, object, and caveat context can return a cached `CheckDecision`. Lookup confirmation checks for intersection, exclusion, and caveated candidates should use the same cached path. A user can observe this with tests that run the same check twice through a counting store and see that the second check avoids repeating tuple reads or subproblem traversal while returning the same `Allowed`, `Denied`, or `Conditional` result.


## Progress

- [ ] Add an explicit cached check API without breaking the existing `check` function.
- [ ] Cache top-level and useful recursive subproblem decisions by schema identity and resolved revision.
- [ ] Route lookup confirmation checks through the cached path when a cache is provided.
- [ ] Add tests for allowed, denied, conditional, context separation, schema separation, and revision separation.
- [ ] Run `cabal test en-core-interface-tests` and `cabal build all`.


## Surprises & Discoveries

None yet.


## Decision Log

- Decision: Preserve the existing uncached `check` API.
  Rationale: Existing embedded users and Servant handlers should continue to compile. Cached behavior should be opt-in until service wiring decides defaults.
  Date: 2026-06-23
- Decision: Include `CaveatContext` in decision cache keys.
  Rationale: Caveats can turn the same graph path into `Allowed`, `Denied`, or `Conditional` depending on request-time facts.
  Date: 2026-06-23


## Outcomes & Retrospective

To be filled during and after implementation.


## Context and Orientation

The forward authorization algorithm is in `en-core/src/En/Check.hs`. The public function:

```haskell
check ::
    Monad m =>
    ConsistencyStore m ->
    TupleStore m ->
    ReachabilityGraph ->
    Consistency ->
    CaveatContext ->
    Subject ->
    RelationName ->
    ObjectRef ->
    m (Either EnError CheckDecision)
```

resolves consistency and calls a private `runCheck`, which recursively evaluates relations and rewrites. The recursion identifies subproblems by subject, object, and relation. Those subproblems are natural cache entries.

`en-core/src/En/Lookup.hs` imports `check` and uses it inside `confirmCandidates` for conditional entrypoints. Caching should help those confirmation checks too. The existing uncached lookup API should stay available; add a cached variant only if needed for service wiring.

The prerequisite plan `docs/plans/10-add-core-cache-interfaces-and-configuration.md` adds `DecisionKey` or `SubproblemKey` and a bounded `Cache`.


## Plan of Work

Milestone 1 introduces a cached check environment. Add a type in `En.Check` or a new module `En.Check.Cached`:

```haskell
data CheckCacheEnv = CheckCacheEnv
    { datastoreId :: !DatastoreId
    , schemaHash :: !SchemaHash
    , decisionCache :: !(Cache SubproblemKey CheckDecision)
    }
```

If `ReachabilityGraph` already carries `hash`, use that schema hash rather than asking callers to supply it twice. The datastore id is not currently part of `ReachabilityGraph`, so the caller must supply it when constructing the cache environment.

Add a function:

```haskell
checkCached ::
    ConsistencyStore IO ->
    TupleStore IO ->
    CheckCacheEnv ->
    ReachabilityGraph ->
    Consistency ->
    CaveatContext ->
    Subject ->
    RelationName ->
    ObjectRef ->
    IO (Either EnError CheckDecision)
```

Keep `check` as it is. `checkCached` should resolve consistency once, then call an internal evaluator that checks the cache before evaluating a subproblem. On `Left EnError`, do not insert a cache entry. On `Right CheckDecision`, insert the decision.

Milestone 2 refactors the private evaluator just enough to avoid duplication. The current `runCheck` can call a generalized helper with `Maybe CheckCacheEnv`. The uncached public `check` passes `Nothing`; `checkCached` passes `Just env`. Make the smallest change that keeps existing tests passing.

The cache key must include:

- Datastore id.
- Schema hash.
- Resolved revision.
- Subject.
- Relation or permission.
- Object.
- Caveat context.

Milestone 3 wires lookup confirmation through the cached path. Add a cached lookup variant only if necessary:

```haskell
lookupCached ::
    ConsistencyStore IO ->
    TupleStore IO ->
    CheckCacheEnv ->
    ReachabilityGraph ->
    Consistency ->
    LookupRequest ->
    IO (Either EnError LookupPage)
```

The existing `lookup` remains uncached. Inside lookup, the only required decision-cache integration is `confirmCandidates`, which currently calls `check`. Refactor the confirmation function to accept a check function argument, or define a small local record that contains the check operation. This avoids duplicating lookup traversal.

Milestone 4 adds tests in `en-core/test/Main.hs`. Use the existing kikan-shaped fixture. Build a counting tuple store so repeated checks can prove fewer reads. Test:

- Two identical `checkCached` calls return the same `Allowed` and the second call hits the decision cache.
- `Denied` results are cached.
- `Conditional` results are cached for the exact same missing context.
- A different `CaveatContext` misses and can produce a different decision.
- A different `Revision` misses.
- A different schema hash misses, even if all other fields match.
- `lookupCached` reuses cached confirmation checks for repeated lookup of the same conditional candidates.


## Concrete Steps

From the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/en
```

Inspect current check and lookup call sites:

```bash
rg -n "check |check\\(|confirmCandidates|runCheck|evalRelation" en-core/src/En/Check.hs en-core/src/En/Lookup.hs en-servant/src
```

Edit:

- `en-core/src/En/Check.hs`
- `en-core/src/En/Lookup.hs`
- `en-core/en-core.cabal` if a new module is introduced
- `en-core/test/Main.hs`

Run:

```bash
cabal test en-core-interface-tests
cabal build all
```


## Validation and Acceptance

Acceptance requires behavior tests, not just compilation. Repeated cached checks must return the same decisions as uncached checks while reducing underlying store reads or increasing cache hit stats. The tests must show that changing caveat context, schema hash, or revision prevents an unsafe cache hit.

Existing uncached `check` and `lookup` tests must still pass unchanged.


## Idempotence and Recovery

The cached API is additive. If lookup integration becomes too invasive, implement and validate `checkCached` first, then add `lookupCached` as a second milestone. Never replace the existing public `check` behavior until the cached path is proven equivalent.


## Interfaces and Dependencies

This plan depends on `docs/plans/10-add-core-cache-interfaces-and-configuration.md` and optionally benefits from `docs/plans/12-implement-tuple-read-caching.md`. It uses `En.Cache`, `En.Check`, `En.Lookup`, `En.Reachability`, `En.Effect.ConsistencyStore`, and `En.Effect.TupleStore`. It should not depend on PostgreSQL, Servant, or Warp.
