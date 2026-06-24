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

- [x] Reconcile EP-11 with current `effectful` APIs and already-landed `checkMany` memoization before implementation. Completed 2026-06-24T00:12:00Z.
- [x] Add an explicit cached check API without breaking the existing `check` function. Completed 2026-06-24T00:21:55Z.
- [x] Cache top-level and useful recursive subproblem decisions by schema identity and resolved revision. Completed 2026-06-24T00:21:55Z.
- [x] Route lookup confirmation checks through the cached path when a cache is provided. Completed 2026-06-24T00:21:55Z.
- [x] Add tests for allowed, denied, conditional, context separation, schema separation, and revision separation. Completed 2026-06-24T00:21:55Z.
- [x] Run `nix develop -c cabal test en-core-interface-tests` and `nix develop -c cabal build all`. Completed 2026-06-24T00:21:55Z.


## Surprises & Discoveries

- A later ExecPlan (`docs/plans/25-adopt-effectful-for-the-en-effect-stack.md`) migrated `check`, `lookup`, and store access to `effectful`. The cached API should therefore be effect-polymorphic with `ConsistencyStore :> es`, `TupleStore :> es`, `IOE :> es`, and `Error EnError :> es` constraints rather than the obsolete `ConsistencyStore IO -> TupleStore IO -> IO (Either ...)` shape. _(2026-06-24)_
- MasterPlan 3 EP-19 already added `checkMany` with a within-call `Map` memo keyed by `Revision` text and `(subject, object, relation)`. EP-11 can reuse that private memoization boundary as the cross-request cache boundary by adding a cache environment to the memo evaluator rather than inventing a parallel traversal. _(2026-06-24)_
- The cached lookup path can avoid changing the uncached lookup API by passing an internal confirmation-check function through lookup traversal. `lookupWithDeadline` keeps using `check`, while `lookupCached` and `lookupWithDeadlineCached` use `checkCached`; the shared traversal only knows about the supplied function. _(2026-06-24)_


## Decision Log

- Decision: Preserve the existing uncached `check` API.
  Rationale: Existing embedded users and Servant handlers should continue to compile. Cached behavior should be opt-in until service wiring decides defaults.
  Date: 2026-06-23
- Decision: Include `CaveatContext` in decision cache keys.
  Rationale: Caveats can turn the same graph path into `Allowed`, `Denied`, or `Conditional` depending on request-time facts.
  Date: 2026-06-23
- Decision: Cache the `CheckDecision` from `En.Check`'s monadic `runCheck` subproblem evaluation, treating MasterPlan 3 EP-15's `En.Decision` as the type seam (not the cache target), and keep the cache key batch-friendly for MasterPlan 3 EP-19.
  Rationale: MasterPlan 3 is implemented in full before this MasterPlan (see `docs/masterplans/2-add-caching-support-to-en.md` Decision Log), so `En.Decision` already exists and `CheckDecision` is re-exported through `En.Check`. The expensive, cacheable work is the tuple-reading subproblem evaluation, not the pure `En.Decision` combinators. Keeping the key a plain per-pair tuple under one resolved revision (no per-call state) lets MasterPlan 3 EP-19's `BatchCheck` reuse entries across requests with no EP-19-specific code.
  Date: 2026-06-23
- Decision: Reuse `checkMany`'s subproblem memo evaluator as the cached traversal.
  Rationale: `checkMany` already proves that a memoized evaluator can share subproblem work without changing decisions. Extending that evaluator with optional `En.Cache` lookup/insert keeps the public uncached `check` path intact, keeps batch behavior compatible, and gives EP-11 cross-request reuse for the same per-pair subproblem key.
  Date: 2026-06-24


## Outcomes & Retrospective

Implemented EP-11 on 2026-06-24. `en-core/src/En/Check.hs` now exposes `CheckCacheEnv` and `checkCached`. The existing `check` API remains unchanged. The cached path resolves consistency once, uses the already-existing memo evaluator, checks `En.Cache` before evaluating subproblems, and inserts successful `CheckDecision` results under a `SubproblemKey` containing datastore id, `ReachabilityGraph.hash`, resolved revision, subject, relation, object, and caveat context.

`en-core/src/En/Lookup.hs` now exposes `lookupCached` and `lookupWithDeadlineCached`. The uncached lookup path still calls `check`; the cached path supplies `checkCached` to the same confirmation traversal used for intersection and exclusion candidates.

Validation passed with:

```text
nix develop -c cabal test en-core-interface-tests
Test suite en-core-interface-tests: PASS

nix develop -c cabal build all
Build completed successfully.
```

The focused tests prove allowed, denied, and conditional decisions are reused on repeated cached checks without extra tuple reads; different caveat context, revision, and schema hash miss the cache; and repeated cached lookup confirmations produce cache hits while returning the same lookup page.


## Context and Orientation

The forward authorization algorithm is in `en-core/src/En/Check.hs`. The current public function is effect-polymorphic:

```haskell
check ::
    (ConsistencyStore :> es, TupleStore :> es, Error EnError :> es) =>
    ReachabilityGraph ->
    Consistency ->
    CaveatContext ->
    Subject ->
    RelationName ->
    ObjectRef ->
    Eff es CheckDecision
```

It resolves consistency and calls a private `runCheck`, which recursively evaluates relations and rewrites. `checkMany` resolves consistency once and calls `runCheckMemo`, a private memoized evaluator. The recursion identifies subproblems by subject, object, and relation. Those subproblems are natural cache entries.

`en-core/src/En/Lookup.hs` imports `check` and uses it inside `confirmCandidates` for conditional entrypoints. Caching should help those confirmation checks too. The existing uncached lookup API should stay available; add a cached variant only if needed for service wiring.

The prerequisite plan `docs/plans/10-add-core-cache-interfaces-and-configuration.md` adds `DecisionKey` or `SubproblemKey` and a bounded `Cache`.

**Cross-MasterPlan prerequisite (MasterPlan 3 EP-15, already complete).** This plan's MasterPlan (`docs/masterplans/2-add-caching-support-to-en.md`) sequences MasterPlan 3 (en hardening) in full *before* this MasterPlan, so MasterPlan 3 EP-15 (`docs/plans/15-generalize-the-caveat-evaluator-and-unify-the-decision-algebra.md`) is a **completed prerequisite**. EP-15 extracts the three-valued algebra into a shared module `En.Decision` (exporting `CheckDecision (..)`, `CaveatObligation (..)`, and the union/intersection/exclusion/gate combinators) and rewires `En.Check`/`En.Lookup` to import it; `En.Check` re-exports `CheckDecision`/`CaveatObligation` so its public interface is unchanged. EP-15 also makes caveat evaluation schema-driven (`En.Caveat.evaluateCaveat`) and adds a `caveats` map to `ReachabilityGraph`. **What this means for you:** the thing you cache is the `CheckDecision` returned by `En.Check`'s monadic `runCheck` subproblem evaluation (the part that reads tuples) — `En.Decision` is only the *type seam* that fixes the `CheckDecision` shape your key maps to; the pure combinators in `En.Decision` are cheap and are not worth caching. Import `CheckDecision` via `En.Check` (or `En.Decision`); both compile. Do not change EP-15's three-valued results — caching must be observationally identical to the uncached engine. Your `CaveatContext` cache-key field must reflect EP-15's schema-driven caveat semantics (the same context that drives `evaluateCaveat`).

**Cross-MasterPlan consumer (MasterPlan 3 EP-19, BatchCheck).** MasterPlan 3 EP-19 (`docs/plans/19-add-batchcheck-for-graphql-field-capability-and-candidate-filtering.md`) evaluates many `(subject, permission, object)` pairs under one resolved revision for the kikan GraphQL gateway, and composes on top of this plan's cache: EP-19 owns the per-request batch surface and a within-call subproblem memo, while *this* plan's per-revision decision cache is what makes pairs overlapping *across* requests cheap. Because MasterPlan 3 lands first, EP-19 has already shipped as a correct `check` fold *without* this cache; landing this plan upgrades its cross-request efficiency. For that to be drop-in, keep the cache key a plain per-pair tuple under one resolved revision with **no per-call state** (exactly the key listed in Milestone 2), so a batch fold over `checkCached` reuses entries with no EP-19-specific cache code.


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
    (ConsistencyStore :> es, TupleStore :> es, IOE :> es, Error EnError :> es) =>
    CheckCacheEnv ->
    ReachabilityGraph ->
    Consistency ->
    CaveatContext ->
    Subject ->
    RelationName ->
    ObjectRef ->
    Eff es CheckDecision
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
    (ConsistencyStore :> es, TupleStore :> es, IOE :> es, Error EnError :> es) =>
    CheckCacheEnv ->
    ReachabilityGraph ->
    Consistency ->
    LookupRequest ->
    Eff es LookupPage
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


---

**Revision note (2026-06-24).** Reconciled EP-11 with the current effectful engine and completed the implementation. The plan now documents the effect-polymorphic cached APIs, the reuse of `checkMany`'s memo evaluator, the lookup confirmation injection approach, and the passing Nix-shell validation commands.
