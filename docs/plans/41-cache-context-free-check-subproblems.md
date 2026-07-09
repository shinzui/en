---
id: 41
slug: cache-context-free-check-subproblems
title: "Cache context-free check subproblems"
kind: exec-plan
created_at: 2026-07-07T15:24:51Z
master_plan: "docs/masterplans/7-fix-the-en-evaluation-engine.md"
---

# Cache context-free check subproblems

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`en` (縁) caches authorization decisions so repeated checks do not re-read the database.
Today that cache is useless for exactly the schemas it matters most for. The cache key
(`SubproblemKey` in `en-core/src/En/Cache.hs`, lines 92–107) includes the request's full
**caveat context** — the map of request-supplied values (like `current_time`) that
caveated grants are evaluated against. The canonical caveat pattern is a time-bounded
grant, so virtually every request carries a fresh `current_time`, every request's key is
unique, and the cross-request hit rate is ~0% (finding B6 of
`docs/reviews/2026-07-07-architecture-performance-review.md`). SpiceDB solved this by
caching the *context-free* part of the answer and re-applying caveats per request; en
should too.

After this plan, the decision cache stores, per (datastore, schema, revision, subject,
relation, object) — **no context** — a *residual decision*: the fully-traversed answer
with the caveats left symbolic (the caveat names and payloads that still gate the
answer, combined with the same union/intersection/exclusion structure the traversal
found). On a cache hit, en skips the entire graph traversal and all store reads, and only
re-evaluates the residual caveats against the *current* request's context. Two requests
that differ only in `current_time` now share one cache entry — and each still gets its
own correct answer, because the caveats are re-run against each request's own context. A
caveated decision can never be served with stale context, by construction: context never
enters the cache at all.

You can see it working: a test checks the same caveated grant twice with two different
`current_time` values; the second check performs zero tuple-store reads (counting store)
and the cache reports a hit, yet an expired context still gets `Denied` and a missing
context still gets `Conditional` from that same cached entry.


## Progress

- [x] M0 (2026-07-08): baseline `cabal build all && cabal test all` green; EP-39 and EP-40
  confirmed landed; cited symbols confirmed with line drift recorded below.
- [x] M1 (2026-07-08): `ResidualDecision` + `rUnion`/`rIntersection`/`rExclusion` in
  `En.Decision`; `applyResidual` in `En.Caveat`; pure `testResidualDecision` proves
  agreement with `unionDecisions`/`intersectionDecisions`/`exclusionDecisions` over every
  pair of sample residuals under four contexts, plus the AND-vs-OR distinction and every
  smart-constructor collapse. Both negative controls observed failing.
- [x] M2 (2026-07-08): `En.Check` evaluates symbolically end to end; `context` is gone from
  every internal evaluator and applied once at the top of
  `check`/`checkCached`/`checkMany`. Full workspace suite green with zero assertion
  changes. Two new assertions pin a deliberate narrowing (unknown caveat beside a
  *caveated* grant now errors; beside an *uncaveated* grant still short-circuits).
- [x] M2b (2026-07-08): cache *value* type moved here from M3 out of necessity — a hit must
  hand a `ResidualDecision` back into the traversal. `CheckCacheEnv.cacheDecisions ::
  Cache SubproblemKey ResidualDecision`; construction sites updated in
  `en-core/test/Main.hs`, `en-servant/test/Main.hs`, `en-server/app/Main.hs`.
- [x] M3 (2026-07-08): `SubproblemKey` loses `context`; `decisionCacheOps` no longer takes
  one. Cross-context tests observed red (4 reads vs 2) on the M2 tree, green after. The
  never-stale assertions were observed failing against a cache that stores the
  context-applied answer — the one bug this milestone could plausibly have introduced.
  `laterRequestContext` added to `En.Conformance.Kikan`.
- [ ] M4: cached tuple-page interposer handles `ProbeTuples` (integration point owned
  here per the master plan): `TupleReadKey` gains a probe variant; probe results cached
  by revision.
- [ ] M5: stats and staleness proofs — hits across contexts asserted via `cacheStats`;
  never-stale property tests; existing "context separates cache" test inverted
  deliberately with a Decision Log entry.
- [ ] Final: full suite green; Outcomes filled; master plan progress row updated.


## Surprises & Discoveries

**M0 baseline is green, unlike EP-39's (2026-07-08).** `cabal build all && cabal test all`
passes across every package, so any red test from here on is this plan's doing. EP-39's
repair of the stale `en-example` assertion has held.

**M0 line drift (2026-07-08).** EP-39 and EP-40 both landed and grew `En/Check.hs`, so the
line numbers this plan cites have moved. The symbols are all present and unchanged in
meaning: `applyRewriteCaveat` is at `en-core/src/En/Check.hs:656-659` (plan said 574–577),
`evaluateNamedCaveat` at `:668-672` (plan said 586–590), `DecisionCacheOps` at `:215-243`
(plan said 229–257). `SubproblemKey` is exactly where the plan says it is,
`en-core/src/En/Cache.hs:92-107`. The decision-cache test block is `testDecisionCache` at
`en-core/test/Main.hs:846-892` (plan said ~794–840) and `testCachedTupleStore` at
`:790-840` (plan said ~738–788). The "different caveat context misses decision cache"
assertion this plan inverts is at `en-core/test/Main.hs:872`.

**The import graph permits the placement M1 proposes, confirmed (2026-07-08).**
`En.Error` imports no en-core module at all; `En.Caveat.Value` imports only `containers`,
`text`, `time`, and `template-haskell`. So `En.Decision` may import `En.Caveat.Value` for
`CaveatPayload` without a cycle, and `En.Caveat` (which already imports `En.Decision`,
`En.Caveat.Value`, and `En.Schema`) may import `En.Error` to host `applyResidual`. No
`.cabal` change is needed.

**M1's algebra tests were verified against two deliberately broken implementations
(2026-07-08),** per the master plan's rule that a test for this class of bug is not
accepted until it has been seen to fail. The rule was written for memo/cache tests; it
earns its keep here too.

The first sabotage made `rIntersection` build an `RUnion` node — the exact AND/OR
conflation the tree exists to prevent. The *structural* assertion caught it, which proves
little, since a structural assertion cannot distinguish a wrong answer from a differently
spelled right one:

```text
user error (rIntersection keeps two caveats symbolic
expected: RIntersection [RCaveat (CaveatName "never") …,RCaveat (CaveatName "always") …]
actual:   RUnion [RCaveat (CaveatName "never") …,RCaveat (CaveatName "always") …])
```

The second sabotage is the one that matters. It left the tree alone and made
`applyResidual` fold an `RIntersection` with `Decision.union` — precisely the bug a flat
list of outstanding caveats would have, and precisely the bug that grants access:

```text
user error (gated allow folds like intersectionDecisions: expired
expected: Right Denied
actual:   Right Allowed)
```

An *expired* time-bounded grant returned `Allowed`. The semantic assertions catch the
soundness failure, not just the shape change; the agreement-with-the-decision-algebra
sweep over every pair of sample residuals is what makes M2's "symbolic detour is
invisible" claim checkable rather than asserted.

**M2 could not defer the cache *value* type to M3 (2026-07-08).** The plan assigned
`CheckCacheEnv.cacheDecisions :: Cache SubproblemKey ResidualDecision` to M3, but M2 does
not compile without it. On an external cache hit, `evalRelationMemo` must return the cached
value *into* a symbolic traversal, and a stored `CheckDecision` cannot be turned back into a
`ResidualDecision`: `Conditional [CaveatObligation]` has already discarded the caveat
payloads and the union/intersection structure. There is no total function
`CheckDecision -> ResidualDecision`. The value type therefore moved into M2 and only the
*key* change (dropping `context`) remains for M3. This keeps M2 behavior-preserving — the
key still separates by context, so hit rates are unchanged — and leaves M3 as a one-field
deletion plus the test inversion, which is a cleaner review boundary than the plan's split.

**Symbolic evaluation forces three behavior changes M2 had to make deliberately
(2026-07-08).** All three are consequences of one fact: the traversal can no longer ask
"does this caveat pass?", because it no longer has the request context. Each was checked
against the suite; none changed a decision.

The nested-group accelerator (`provenByDirectGroupMembership`) previously accepted an
attachment or membership edge whose caveat *evaluated to* `Allowed` under the request
context. It now requires the edge to carry no caveat at all (`isNothing tuple.caveat`).
This strictly tightens the master plan's soundness guard rather than loosening it: the
accelerator concludes `RAllowed` and cannot represent a gate. A caveated group edge simply
falls back to recursion, which composes the gates into the residual correctly. Cost: a few
more store reads on caveated group paths. Answer: identical, and
`caveats on both edges of a nested-group path compose into both obligations` still passes.

A caveated *probe* hit no longer short-circuits `evalThisMemo`. Under the old evaluator a
satisfied caveat looked exactly like an unconditional grant and absorbed the union. That is
precisely the value that must not be cached and replayed against a request whose context
fails the same caveat, so `unionSettled` now tests for `RAllowed` only. An uncaveated probe
hit still short-circuits, so EP-39's wide-relation bound (one probe read) is intact for the
uncaveated case that motivated it.

`Exclusion` now evaluates its subtrahend whenever the base is not *symbolically* `RDenied`,
which includes a base whose caveats would have denied under this request's context. This
cannot change the answer — `rExclusion` keeps the pair symbolic and `exclusionDecisions`
ignores the subtrahend once the base folds to `Denied` — but it does perform store reads the
old evaluator skipped, and it makes an error in the subtrahend observable where it was not.

**The one observable answer change, and why it is the right one (2026-07-08).** A relation
holding both a *satisfied caveated* grant and a row naming a caveat the schema does not
define used to return `Right Allowed`: the satisfied row short-circuited the probe before
`sequence` ever looked at the malformed row. It now returns
`Left (UnknownRelation "unknown caveat: ghost")`.

This is unavoidable, not a choice about where to validate. Deferring name validation to
`applyResidual` does not help: that fold is a `traverse` and fails on the first `Left`
anywhere in the union. The only way to keep the old answer would be to know, during the
traversal, that the good row's caveat passes — which is the one thing symbolic evaluation
gives up. Failing closed on data that references a caveat the schema no longer declares is
the defensible reading, and eager validation buys an invariant worth having: a residual
that reaches the decision cache names only caveats the schema defines, so a cache hit can
always be re-applied.

EP-39's blessed case is untouched, and both are now pinned by tests
(`an unknown caveat beside a satisfied caveated grant fails the check` /
`an unconditional grant still short-circuits past an unknown caveat`): an *unconditional*
grant beside a malformed row still returns `Right Allowed`, because `RAllowed` is present in
the probe residuals and settles the union before the `Left` is inspected.

**B6, measured (2026-07-08).** The red run on the M2 tree, before `context` left the key.
Two checks of the same caveated grant differing only in `current_time`; the second one
re-traversed the graph from scratch:

```text
user error (different caveat context hits the decision cache
expected: 2
actual:   4)
```

After the key change the second, third, and fourth contexts each perform *zero* store reads
and the cache reports hits — while `expiredContext` still gets `Denied` and
`missingAutonomyContext` still gets its `Conditional` obligation, from that one entry.

**The never-stale test earns its place; nothing else in the suite does (2026-07-08).** Per
the master plan's rule, the M3 assertions were run against a deliberately broken cache. The
first sabotage — `residualGate` dropping its caveat entirely — was caught, but by the
*pre-existing* `cached conditional check returns Conditional first`, because it corrupts
even the single-context answer. That proves nothing about cross-context safety.

The second sabotage is the one that matters, and it is the exact bug a careless fix for B6
would ship: keep the context-free *key*, but store the decision **as computed under the
inserting request's context** (collapse `RAllowed`/`RDenied` through `applyResidual` before
`insertCache`). Every pre-existing assertion still passed. So did
`a different caveat context reuses the cached entry`. Only the new assertion fired:

```text
user error (an expired context gets Denied from the shared entry
expected: Right Denied
actual:   Right Allowed)
```

An expired time-bounded grant, served as `Allowed` to a later request. Asserting the *hit*
is not enough; a cross-context cache test must also assert that the answer still tracks the
context, or it certifies the very bug it was written to prevent.


## Decision Log

- Decision: Cache a **residual decision expression tree** (`ResidualDecision`), not a
  flat list of caveat obligations.
  Rationale: the flat `Conditional [CaveatObligation]` model cannot express whether two
  residual caveats are joined by AND (intersection) or OR (union), and a cached wrong
  join would produce wrong *decisions* on re-application (e.g. an intersection of two
  caveats must deny when either fails; a flat list re-joined as a union would allow).
  The live evaluator avoids this today only because it resolves caveats inline with the
  request context before combining. Once evaluation is context-free, the combination
  structure must be preserved. A small tree with smart constructors that collapse
  constants keeps entries tiny in practice (uncaveated subproblems collapse to a bare
  `RAllowed`/`RDenied`).
  Date: 2026-07-07
- Decision: The evaluator becomes symbolic *throughout* (every subproblem yields a
  `ResidualDecision`), and the request context is applied exactly once, at the top of
  `check`/`checkCached`/`checkMany` — not per subproblem.
  Rationale: applying context per subproblem would mean the value flowing through the
  traversal is context-dependent again, and only the leaves could be cached. With a
  fully symbolic evaluator, the within-call memo (`CheckMemo`) and the cross-call cache
  store the same context-free type, hits compose at any depth, and the context-dependent
  step is a single cheap pure fold. Union short-circuiting survives: `RAllowed` (an
  *unconditional* allow) is still absorbing; a caveated allow is `RCaveat …`, which is
  not, exactly as correctness requires.
  Date: 2026-07-07
- Decision: The residual for a caveat is the pair (caveat **name**, tuple caveat
  **payload**); the caveat *definition* is not stored in the cache entry — it is looked
  up in `graph.caveats` at re-application time.
  Rationale: the cache key already includes the schema hash, so the definition the name
  resolves to is pinned; storing payloads (small maps of typed values already in memory
  as `En.Tuple.CaveatPayload`) keeps entries self-contained without duplicating schema
  data. Rewrite-level caveats (`Caveated` nodes) use the empty payload, exactly like
  today's `applyRewriteCaveat` (`en-core/src/En/Check.hs` lines 574–577).
  Date: 2026-07-07
- Decision: `SubproblemKey` drops its `context` field; `revision` stays in the key.
  `DecisionKey` (also in `en-core/src/En/Cache.hs`, currently exercised only by tests)
  is left untouched.
  Rationale: cross-revision reuse is a different, riskier optimization — en already
  quantizes revisions via the optimized-revision cache, which gives natural key sharing
  under `MinimizeLatency`; removing `revision` would require invalidation machinery this
  plan does not need. `DecisionKey` is not on the hot path; deleting it is cleanup for
  docs/plans/44 to consider.
  Date: 2026-07-07
- Decision: Probe results (`ProbeTuples`, added by docs/plans/39) are cached in the
  existing tuple-read cache by adding a `ProbeReadKey` variant to `TupleReadKey`, storing
  the row list wrapped as a `TuplePage` with state `Exhausted` — no second cache, no page
  reuse across shapes.
  Rationale: the master plan assigns this decision to EP-41 ("EP-41 decides how the
  cached interposer caches probe results (single-tuple entries vs page reuse)").
  Reconstructing probe answers from cached `ReadObjectRelation` pages would couple the
  interposer to paging semantics and only pay off when a full page for the same
  object#relation at the same revision is already cached — rare precisely in the wide
  -relation cases probes exist for. A dedicated key with the same revision-pinned
  correctness argument is simple and obviously safe; reusing the `TuplePage` value type
  avoids widening the cache's value parameter.
  Date: 2026-07-07
- Decision: The cache *value* type (`Cache SubproblemKey ResidualDecision`) changes in M2,
  not M3 as planned; M3 keeps only the key change.
  Rationale: no total `CheckDecision -> ResidualDecision` exists, so a symbolic evaluator
  cannot consume a cache that stores `CheckDecision`. M2 does not compile without it. The
  split still holds the property it was designed for — M2 changes no observable behavior,
  because the key still carries `context` and hit rates are unchanged.
  Date: 2026-07-08
- Decision: The nested-group accelerator requires *uncaveated* edges, where it previously
  accepted edges whose caveat evaluated to `Allowed` under the request context.
  Rationale: the accelerator's conclusion is `RAllowed`, which cannot carry a gate, and the
  traversal can no longer evaluate the gate. Falling back to recursion composes the gates
  correctly. This tightens the `relationUnionsThis` soundness guard the master plan flagged
  rather than weakening it, at the cost of extra store reads on caveated group paths.
  Date: 2026-07-08
- Decision: A relation holding a satisfied caveated grant beside a row naming an undefined
  caveat now fails the check (`UnknownRelation`) instead of returning `Allowed`.
  Rationale: symbolic evaluation cannot know the good row's caveat passes, and deferring
  name validation to `applyResidual` does not recover the old answer (its `traverse` fails
  on the first `Left` in the union). Failing closed on data referencing a caveat the schema
  does not declare is the defensible reading, and eager validation guarantees that a cached
  residual names only definable caveats — so a cache hit can always be re-applied. EP-39's
  blessed case (an *unconditional* grant beside the same malformed row) still returns
  `Allowed`; both are now pinned by tests.
  Date: 2026-07-08
- Decision: The existing test "different caveat context misses decision cache"
  (`en-core/test/Main.hs`, around lines 818–820) is deliberately inverted: after this
  plan a different context must **hit**.
  Rationale: that assertion encodes finding B6 — the bug this plan removes. The
  replacement assertions (M5) are strictly stronger: hit across contexts *plus* proof the
  answer still tracks the context.
  Date: 2026-07-07


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

You are in the `en` repository (working tree `/Users/shinzui/Keikaku/bokuno/en`; paths
repository-relative), a Haskell Cabal multi-package project on GHC 9.12.4. This plan is
EP-41 of `docs/masterplans/7-fix-the-en-evaluation-engine.md`, fixing finding B6 of
`docs/reviews/2026-07-07-architecture-performance-review.md`. All edits are in
**`en-core`**.

Plain-language definitions:

- **Caveat**: a named, schema-declared condition. A grant tuple may carry a
  `TupleCaveat { name :: CaveatName, payload :: CaveatPayload }` — the payload is data
  fixed at write time (e.g. `until = 2026-07-01`). At check time the caller supplies a
  `CaveatContext` (e.g. `current_time = now`). Evaluation
  (`En.Caveat.evaluateCaveat :: CaveatDefinition -> CaveatPayload -> CaveatContext ->
  CheckDecision`, `en-core/src/En/Caveat.hs`) resolves each parameter from payload or
  context per the definition's predicate and returns `Allowed`, `Denied`, or
  `Conditional [CaveatObligation]` when required *context* keys are absent (missing
  *payload* keys deny — see `resolveOperand`, lines 67–81: `FromPayload` misses are
  `OperandDenied`, `FromContext` misses are obligations). **This function is the exact
  re-application step this plan runs on cache hits** — read it before M1.
- **`CheckDecision` / decision algebra** (`en-core/src/En/Decision.hs`):
  `unionDecisions` (Allowed-absorbing), `intersectionDecisions` (Denied-absorbing),
  `exclusionDecisions` (two-argument, added by docs/plans/40 — base minus subtrahend
  with the Conditional interactions specified there), `applyGate` (intersection of a
  caveat gate with a decision).
- **Caveat definitions in the graph**: `ReachabilityGraph.caveats :: Map CaveatName
  CaveatDefinition` (`en-core/src/En/Reachability.hs` line 43); `check` resolves names
  through it (`evaluateNamedCaveat`, `en-core/src/En/Check.hs` lines 586–590), erroring
  with `UnknownRelation "unknown caveat: …"` on a miss.
- **The two memo/cache layers in `check`**: (1) a *within-call* memo
  `CheckMemo = Map MemoKey CheckDecision` keyed by revision + subproblem — already
  context-free, safe because one call has one context; (2) the *cross-call* cache,
  reached through `DecisionCacheOps` (lines 229–257): `checkCached` builds
  `SubproblemKey`s including `context` and stores plain `CheckDecision`s in a
  `Cache SubproblemKey CheckDecision` owned by `CheckCacheEnv` (lines 49–52). The cache
  itself (`En.Cache`, `newCache`/`lookupCache`/`insertCache`/`cacheStats`) is a bounded
  `IORef` map with hit/miss/insert/evict counters.
- **Tuple-read cache / interposer**: `En.Effect.CachedTupleStore.cachedTupleStore`
  interposes on the `TupleStore` effect and caches `ReadObjectRelation` /
  `ReadStartingWithUser` pages in a `Cache TupleReadKey TuplePage`, keyed by resolved
  revision plus read parameters (`TupleReadKey`, `en-core/src/En/Cache.hs` lines 56–73).
  docs/plans/39 added a third read, `ProbeTuples`, which currently passes through
  uncached; this plan owns its caching policy.

Consumers of `checkCached`/`CheckCacheEnv` you will touch or re-verify:
`En.Lookup.lookupCached`/`lookupWithDeadlineCached` (`en-core/src/En/Lookup.hs` lines
129–148) route candidate confirmation through `checkCached`; `en-servant` builds cache
envs in its `Env` seam and its tests assert hit counting
(`en-servant/test/Main.hs`); `en-core/test/Main.hs` has the decision-cache test block
(`testDecisionCache`, lines ~794–840).

Integration points restated from the master plan so this plan stands alone:

- **Rebase order on `en-core/src/En/Check.hs` is EP-39 → EP-40 → EP-41 (this plan).**
  This plan assumes docs/plans/39 (probe-first unified evaluator) and docs/plans/40
  (cycle-as-empty, union short-circuit, `exclusionDecisions`) have landed. If they have
  not, stop and implement against whatever is present only after recording the deviation
  here — the residual algebra must mirror the *final* decision semantics, especially
  EP-40's exclusion table.
- **The probe operation is defined by docs/plans/39 and must not be redefined here**;
  this plan only decides how `En.Effect.CachedTupleStore` caches it.
- Engine budget constants and cache eviction/stat mechanics are
  docs/plans/44-make-evaluation-budgets-configurable-and-trim-hot-path-overhead.md's
  scope; do not optimize them here even where tempting.


## Plan of Work


### M0 — Baseline and drift check (no code)

Build and test; re-read `en-core/src/En/Check.hs` (post-EP-39/40 shape),
`en-core/src/En/Decision.hs`, `en-core/src/En/Caveat.hs`, `en-core/src/En/Cache.hs`,
`en-core/src/En/Effect/CachedTupleStore.hs`. Record the evaluator's current shape and
the exact `SubproblemKey` construction site (`decisionCacheOps.cacheKey`).

```bash
cabal build all
cabal test all
```


### M1 — The residual decision algebra (pure, additive)

Scope: the new type and its evaluator, fully unit-tested before touching `check`. In
`en-core/src/En/Decision.hs` add:

```haskell
-- | A decision with caveats left symbolic: what a check answer looks like
-- before any request context is applied. RCaveat names a caveat and carries
-- the tuple payload it was written with; applyResidual resolves it against a
-- concrete request context.
data ResidualDecision
    = RAllowed
    | RDenied
    | RCaveat !CaveatName !CaveatPayload
    | RUnion ![ResidualDecision]
    | RIntersection ![ResidualDecision]
    | RExclusion !ResidualDecision !ResidualDecision
    deriving stock (Eq, Show)
```

(`CaveatPayload` comes from `En.Caveat.Value` / re-exported via `En.Tuple`; check the
import graph — `En.Decision` currently imports only `En.Schema` for `CaveatName`, and
`En.Caveat.Value` is dependency-free, so no cycle arises.)

Add **smart constructors** that collapse constants so uncaveated schemas cache single
leaves: `rUnion` drops `RDenied` members, returns `RAllowed` if any member is `RAllowed`,
unwraps singletons, and returns `RDenied` for the empty list; `rIntersection` dually
(drops `RAllowed`, absorbs `RDenied`, empty list is `RAllowed`); `rExclusion` folds the
constant cases of `exclusionDecisions` (`rExclusion RDenied _ = RDenied`,
`rExclusion base RDenied = base`, `rExclusion _ RAllowed = RDenied`).

Add the re-application fold:

```haskell
-- | Resolve a residual decision against a request's caveat context. The
-- caveat definitions come from the compiled schema (the cache key pins the
-- schema hash, so names resolve identically to when the residual was built).
applyResidual ::
    Map CaveatName CaveatDefinition ->
    CaveatContext ->
    ResidualDecision ->
    Either EnError CheckDecision
```

`RCaveat name payload` looks the definition up (missing name ⇒
`Left (UnknownRelation ("unknown caveat: " <> name))`, matching
`En.Check.evaluateNamedCaveat`) and returns `evaluateCaveat definition payload context`;
`RUnion` maps and combines with `unionDecisions`; `RIntersection` with
`intersectionDecisions`; `RExclusion` with `exclusionDecisions`. This makes the caveat
re-application step *precisely* `En.Caveat.evaluateCaveat` on the stored payload with
the fresh context — nothing more.

Note the import direction: `applyResidual` needs `evaluateCaveat`, and `En.Caveat`
imports `En.Decision`. To avoid a module cycle, put `ResidualDecision` + smart
constructors in `En.Decision` and `applyResidual` in `En.Caveat` (which already imports
both). Record the final placement in this plan.

Unit tests in `en-core/test/Main.hs` (pure, no store): for a caveat definition with a
context parameter, assert `applyResidual` over `RIntersection [RCaveat c p, RAllowed]`
equals `intersectionDecisions [evaluateCaveat …, Allowed]` for satisfied, failed, and
missing contexts; assert the AND-vs-OR distinction concretely — an `RIntersection` of a
failing and a passing caveat is `Denied` while the `RUnion` of the same two is `Allowed`
(this is the case a flat obligation list gets wrong); assert every smart-constructor
collapse.

```bash
cabal test en-core:en-core-interface-tests
```

Acceptance: new pure assertions pass; nothing else touched.


### M2 — Symbolic evaluation inside check (behavior-preserving)

Scope: the evaluator produces `ResidualDecision`; context applies once at the top. All
observable behavior is unchanged, so the whole suite must stay green — this milestone is
the risk concentrator, keep it a single reviewable commit.

In `en-core/src/En/Check.hs`:

1. Change the internal result type of the memoized evaluator family from
   `Either EnError CheckDecision` to `Either EnError ResidualDecision`, and the memo to
   `Map MemoKey ResidualDecision`. The `context` parameter disappears from the internal
   evaluators entirely (grep it out; the compiler drives this).
2. Leaf translation: where today `applyTupleCaveat graph context tuple.caveat Allowed`
   produces a decision, now produce `RAllowed` gated by the tuple caveat:
   `maybe RAllowed (\TupleCaveat{name, payload} -> rIntersection [RCaveat name payload, RAllowed]) tuple.caveat`
   — i.e. a small helper `residualGate :: Maybe TupleCaveat -> ResidualDecision ->
   ResidualDecision`. Caveat-name *existence* should still be validated eagerly (look up
   in `graph.caveats` and return `Left (UnknownRelation …)` if absent) so unknown-caveat
   errors keep failing at evaluation time, not at re-application.
3. Combination sites: union branches fold with the EP-40 short-circuit, but the
   absorbing element is now `RAllowed` **only** (a caveated allow is `RCaveat`, not
   absorbing — this is what makes probe-first short-circuiting remain sound
   symbolically); intersections use `rIntersection`; exclusion uses `rExclusion` but
   must still evaluate the subtrahend whenever the base is not `RDenied` (EP-40's rule,
   now at the residual level); `Caveated name inner` wraps as
   `rIntersection [RCaveat name (CaveatPayload Map.empty), inner]`.
4. Top level: `check` and `checkMany` compute the residual, then
   `either throwError pure . (>>= applyResidual graph.caveats context)` (respectively
   keep per-pair `Either`). `checkCached` likewise (M3 changes what it caches).
   Cycle-as-empty (EP-40) becomes `Right RDenied` on revisit; depth exhaustion still
   `Left ResolutionLimitExceeded`.

Behavioral equivalence argument to keep as a module comment: for a fixed context,
`applyResidual` distributes over the constructors exactly as the old inline evaluation
did, and smart-constructor collapses only fold constants the old code would have folded
through `unionDecisions`/`intersectionDecisions` anyway.

```bash
cabal test en-core:en-core-interface-tests
cabal test en-core:en-core-conformance
cabal test en-servant:en-servant-tests
```

Acceptance: entire suite green with zero assertion changes. Every caveat test
(`Allowed`/`Denied`/`Conditional` with obligations, expired, missing-context,
generic-integer `min_level`) passes unchanged — these are the proof the symbolic detour
is invisible.


### M3 — Context-free cache keys and residual values (the headline)

Scope: the cross-call cache. In `en-core/src/En/Cache.hs`: remove the `context` field
from `SubproblemKey` and its `Ord` instance. In `en-core/src/En/Check.hs`:
`CheckCacheEnv.cacheDecisions` becomes `Cache SubproblemKey ResidualDecision`;
`DecisionCacheOps` looks up / inserts `ResidualDecision`; `decisionCacheOps` no longer
takes or embeds `context`. On external-cache hit inside `evalRelationMemo`, the residual
is returned into the symbolic evaluation as-is (no context application mid-tree); the
single top-level `applyResidual` from M2 finishes the job. Update `CheckCacheEnv`
construction sites (`newCheckCacheEnv` in `en-core/test/Main.hs` and the analogous env in
`en-servant/test/Main.hs`) — the type parameter change makes the compiler list them.

Write the headline tests first and watch the relevant ones fail on the M2 tree:

```haskell
-- Two contexts that differ only in current_time share one entry.
crossContextEnv <- newCheckCacheEnv
crossReads <- newIORef 0
assertEqual "caveated check (context A) evaluates" (Right Allowed)
    =<< checkCachedEngine consistencyStore (countingTupleStore crossReads tupleStore)
            crossContextEnv graph MinimizeLatency requestContext
            (SubjectId user) (RelationName "view") intention
readsAfterFirst <- readIORef crossReads
assertEqual "caveated check (context B) still evaluates correctly" (Right Allowed)
    =<< checkCachedEngine consistencyStore (countingTupleStore crossReads tupleStore)
            crossContextEnv graph MinimizeLatency laterRequestContext   -- same values, later current_time
            (SubjectId user) (RelationName "view") intention
assertEqual "second context performs no store reads" readsAfterFirst =<< readIORef crossReads

-- The same cached entry yields context-appropriate answers: never stale.
assertEqual "expired context gets Denied from the shared entry" (Right Denied)
    =<< checkCachedEngine … expiredContext …
assertEqual "missing context gets Conditional from the shared entry"
    (Right (Conditional [CaveatObligation (CaveatName "within_autonomy") ["requested_autonomy"]]))
    =<< checkCachedEngine … missingAutonomyContext …
```

(`laterRequestContext` is a new fixture: `requestContext` with `current_time` bumped a
minute, still before the fixture's `until` expiry; `expiredContext` and
`missingAutonomyContext` already exist in `En.Conformance.Kikan`.) Invert the old
"different caveat context misses decision cache" assertion per the Decision Log — it now
asserts a *hit* (no additional reads) — and keep the revision- and schema-hash-separation
assertions exactly as they are (those keys still separate).

```bash
cabal test en-core:en-core-interface-tests
```

Acceptance: cross-context tests green; the counting store proves zero tuple reads on the
second context; expired/missing contexts get their distinct correct answers from the
same entry.


### M4 — Probe caching in the tuple-read interposer

Scope: the integration point this plan owns. In `en-core/src/En/Cache.hs`, extend

```haskell
data TupleReadKey
    = ObjectRelationReadKey !Revision !ObjectRef !RelationName !Int !(Maybe StoreCursor)
    | StartingWithUserReadKey !Revision !UsersetQuery
    | ProbeReadKey !Revision !ObjectRef !RelationName ![Subject]
```

and extend the hand-written `Ord` instance (it compares through `revisionEncoding`; give
the new variant a stable position after the existing two). In
`en-core/src/En/Effect/CachedTupleStore.hs`, add the arm:

```haskell
ProbeTuples revision object relation subjects ->
    (.rows) <$>
        cachedRead
            cache
            (ProbeReadKey revision object relation subjects)
            (TuplePage <$> send (ProbeTuples revision object relation subjects) <*> pure Exhausted)
```

(i.e. wrap the row list as an `Exhausted` `TuplePage` for storage and unwrap on return —
adjust to the record syntax the file uses). Correctness argument, stated in a comment:
the key pins the resolved revision, identical to the two existing read shapes, so an
entry can never serve rows from a different snapshot; `Exhausted` is truthful because
probes are unpaginated by construction.

Tests in `en-core/test/Main.hs`, alongside `testCachedTupleStore` (lines ~738–788):
two identical `probeTuples` calls through `cachedTupleStore` hit the underlying store
once (counting interpreter); a probe at a different revision or with a different subject
list misses; a disabled cache still returns correct rows and does not suppress reads.

```bash
cabal test en-core:en-core-interface-tests
```


### M5 — Stats, staleness sweep, and consumer verification

Scope: observable evidence and downstream consumers.

1. Stats: extend the M3 block with `cacheStats crossContextEnv.cacheDecisions` and assert
   `hits` increased between the first and second context (the en-servant test file
   already demonstrates this pattern with `cacheStats`). This is the "cache stats show
   hits across contexts" acceptance.
2. Lookup-path verification: the existing cached-lookup assertions
   ("cached lookup reuses decision cache for confirmations", `en-core/test/Main.hs`
   lines ~833–840, and the analogous en-servant handler test) must pass unchanged —
   confirmations flow through `checkCached` and thus now share entries across request
   contexts too. Add one assertion: two cached lookups with different `current_time`
   contexts, second one shows decision-cache hits and no new store reads.
3. Staleness sweep: grep en-core for any remaining place a `CheckDecision` computed
   under one context could be stored and replayed under another (the memo inside one
   `checkMany` call is fine — single context per call; document that reasoning in the
   `checkMany` haddock).

```bash
cabal build all
cabal test all
```


### Final — wrap-up

Fill Outcomes & Retrospective, tick the EP-41 rows in
`docs/masterplans/7-fix-the-en-evaluation-engine.md`, add a Revision Note here.


## Concrete Steps

All commands from `/Users/shinzui/Keikaku/bokuno/en`:

```bash
cabal build all
cabal test all                                  # M0 baseline and Final
cabal test en-core:en-core-interface-tests      # M1–M5 inner loop
cabal test en-core:en-core-conformance
cabal test en-servant:en-servant-tests          # M3/M5 consumer guard
```

Expected shape of the M3 red run (before the re-keying, on the M2 tree the second
context misses and re-reads):

```text
second context performs no store reads
expected: 3
actual:   6
```

(Exact read counts depend on the post-EP-39 evaluator; record the real numbers.) Update
this section with true transcripts as evidence while working.


## Validation and Acceptance

1. **Cross-context sharing (B6)**: with the decision cache enabled, checking a caveated
   grant under context A and then under context B (same values, different
   `current_time`) performs zero tuple-store reads on the second call and increments
   cache `hits` — asserted with `countingTupleStore` and `cacheStats` in
   `en-core/test/Main.hs`. Before this plan the second call misses and re-reads.
2. **Never stale**: from the *same* cache entry, `expiredContext` yields `Right Denied`,
   `missingAutonomyContext` yields `Right (Conditional [within_autonomy needs
   requested_autonomy])`, and a satisfied context yields `Right Allowed`. There is no
   configuration in which a decision computed under one context is returned under
   another, because context is structurally absent from keys and values (a reviewer can
   verify by reading the `SubproblemKey` and `ResidualDecision` definitions).
3. **Algebraic soundness**: pure tests prove `applyResidual` agrees with
   `unionDecisions`/`intersectionDecisions`/`exclusionDecisions` on every constructor,
   and that AND/OR of caveats are distinguished (the flat-list failure case).
4. **Probe caching**: repeated probes at one revision hit; different revision/subjects
   miss; disabled cache is transparent.
5. **No regressions**: `cabal test all` green, including the kikan conformance suite,
   the inverted context test (with its Decision Log entry), and the en-servant cached
   check/lookup handler tests.


## Idempotence and Recovery

All steps are additive code changes plus test updates; every command is re-runnable and
there are no migrations. M1 is purely additive (safe to land alone). M2 is the
behavior-preserving pivot — land it as one commit with the whole suite green so `git
revert` of that single commit restores the inline evaluator if something subtle
surfaces later. M3's key change invalidates nothing persistent (the cache is in-process
and empty at boot). If M2 uncovers a semantic mismatch (a test that changes answers),
stop: that is a real bug in either the residual algebra or the pre-existing evaluator —
record it in Surprises & Discoveries with the failing case before choosing a side.


## Interfaces and Dependencies

No new package dependencies; everything uses `containers`, `effectful`, and existing
en-core modules (`en-core/en-core.cabal` unchanged except possibly exposing a new module
if `ResidualDecision` warrants one — default is extending `En.Decision`/`En.Caveat`).

End-state interfaces (full module paths):

- `En.Decision.ResidualDecision` with constructors
  `RAllowed | RDenied | RCaveat CaveatName CaveatPayload | RUnion [ResidualDecision] |
  RIntersection [ResidualDecision] | RExclusion ResidualDecision ResidualDecision`, plus
  smart constructors `rUnion`, `rIntersection`, `rExclusion`.
- `En.Caveat.applyResidual :: Map CaveatName CaveatDefinition -> CaveatContext ->
  ResidualDecision -> Either EnError CheckDecision` (placement per M1's cycle note).
- `En.Cache.SubproblemKey` without `context`; `En.Cache.TupleReadKey` with
  `ProbeReadKey !Revision !ObjectRef !RelationName ![Subject]`.
- `En.Check.CheckCacheEnv{ cacheDecisions :: Cache SubproblemKey ResidualDecision }`;
  public signatures of `check`/`checkCached`/`checkMany` unchanged from the post-EP-40
  tree.
- `En.Effect.CachedTupleStore.cachedTupleStore` caches `ProbeTuples` per M4.

Consumed from other plans: `ProbeTuples` and the unified evaluator from
docs/plans/39-add-a-point-membership-probe-and-probe-first-check-evaluation.md;
cycle/union/exclusion semantics and `exclusionDecisions` from
docs/plans/40-adopt-zanzibar-cycle-and-exclusion-semantics-in-check.md (the residual
algebra must mirror them exactly). Consumed by:
docs/plans/44-make-evaluation-budgets-configurable-and-trim-hot-path-overhead.md
(cache eviction/stat mechanics, potential `DecisionKey` deletion) and any future
explain/trace work that wants the residual tree as its evidence structure.
