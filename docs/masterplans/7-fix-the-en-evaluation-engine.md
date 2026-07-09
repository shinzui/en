---
id: 7
slug: fix-the-en-evaluation-engine
title: "Fix the en evaluation engine"
kind: master-plan
created_at: 2026-07-07T15:24:21Z
intention: intention_01kx2cmexke9mv9aggb7jf7w5t
---

# Fix the en evaluation engine

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

en's evaluation engine (`check`, `lookup`, `expand` in `en-core`) currently fails or
degrades badly on realistic data shapes: a check on any relation wider than one page
(1000 tuples) errors out instead of answering; direct-membership checks scan every row
of a relation instead of probing for the one tuple that matters; legal data cycles (two
groups that contain each other) poison whole checks including union branches that
already proved access; exclusion over a conditional base reports "maybe" for subjects
who provably have no access; the decision cache is useless for caveated schemas because
caveat context (including `current_time`) is part of the cache key; lookup recomputes
its entire traversal for every page and its deadline only relabels results instead of
bounding work; lookup cursors carry a client-forgeable revision that bypasses token
validation; and expand erases union/intersection/exclusion structure, so an audit UI
cannot say whether children mean "all of", "any of", or "except".

After this initiative, check answers correctly with bounded store work on relations of
any width; cycles contribute nothing (Zanzibar semantics) instead of failing; the
exclusion algebra is sound; cached decisions are shared across requests regardless of
caveat context; lookup does incremental work per page under a real deadline with
tamper-proof cursors; expand preserves operators; and evaluation budgets (depth, page
size, result cap) are engine configuration instead of constants duplicated across three
modules. Findings addressed: Theme B (B1–B12) of
`docs/reviews/2026-07-07-architecture-performance-review.md`.

Out of scope: concurrent subproblem dispatch (deferred — the sequential engine must
first be correct), the new lookup-subjects algorithm
(docs/plans/52-add-a-lookup-subjects-api.md under
`docs/masterplans/9-complete-the-en-api-surface.md`), and any HTTP-layer changes.


## Decomposition Strategy

The decomposition follows the review's observation that the engine's problems cluster
into independent behavioral fixes, each testable with the existing in-memory conformance
store (`en-core/src/En/Conformance/Kikan.hs`). EP-39 (membership probe) introduces the
one new store primitive — a point-membership probe on the `TupleStore` effect — that
changes check's evaluation shape; it fixes both the page-limit failure (B1) and the
full-scan pattern (B2) because they share one root cause: check reads whole relations to
answer point questions. EP-40 fixes evaluation semantics (cycles as empty results, union
short-circuit, sound exclusion algebra, error taxonomy, `checkMany` error surface — B3,
B4, B5) and is kept separate from EP-39 because semantics changes need conformance-level
scrutiny independent of performance changes, even though both edit
`en-core/src/En/Check.hs`. EP-41 (context-free caching, B6) is isolated because it
changes cache key structure and caveat re-application — a correctness-sensitive change
that should not be reviewed alongside unrelated edits. EP-42 owns lookup's paging model,
cursor validation, and deadline enforcement (B7, B8, B9) as one coherent rework of
`en-core/src/En/Lookup.hs`. EP-43 (operator-preserving expand, B10) is independent and
small. EP-44 sweeps the remaining structural debt (configurable budgets, dead
`EntryPoint` machinery, hot-path allocations, cache contention — B11, B12) and
deliberately runs last so it tunes the engine's final shape rather than code about to be
rewritten.

A single "rewrite check" mega-plan was rejected: the semantic fixes (EP-40) must be
verifiable in isolation against conformance cases, and the probe (EP-39) touches every
store implementation, which is risky enough to deserve its own validation cycle.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-39 | Add a point-membership probe and probe-first check evaluation | docs/plans/39-add-a-point-membership-probe-and-probe-first-check-evaluation.md | None | None | Complete |
| EP-40 | Adopt Zanzibar cycle and exclusion semantics in check | docs/plans/40-adopt-zanzibar-cycle-and-exclusion-semantics-in-check.md | None | EP-39 | Complete |
| EP-41 | Cache context-free check subproblems | docs/plans/41-cache-context-free-check-subproblems.md | None | EP-39, EP-40 | Complete |
| EP-42 | Stream lookup pages with validated cursors and a real deadline | docs/plans/42-stream-lookup-pages-with-validated-cursors-and-a-real-deadline.md | None | EP-39 | Complete |
| EP-43 | Preserve set operators in expand trees | docs/plans/43-preserve-set-operators-in-expand-trees.md | None | None | Complete |
| EP-44 | Make evaluation budgets configurable and trim hot-path overhead | docs/plans/44-make-evaluation-budgets-configurable-and-trim-hot-path-overhead.md | None | EP-39, EP-40, EP-42 | Complete |


## Dependency Graph

No plan has a hard dependency: each is implementable against the current tree. The soft
dependencies express merge-order preference, not necessity. EP-39 and EP-40 both rewrite
the evaluation core of `en-core/src/En/Check.hs`; implementing them concurrently in
separate branches would produce a painful merge, so whichever lands second rebases on
the first. The registry orders EP-39 first because the probe changes the shape of
`evalThisMemo`, which EP-40's cycle handling then threads state through. EP-41's cache
keys wrap whatever subproblem representation exists after EP-39 and EP-40, so it should
land after both to avoid re-keying twice. EP-42 is mostly confined to `En/Lookup.hs`, but it cannot treat `check` as a fully
black box after all: fixing B7 (one snapshot per lookup) requires a revision-pinned
internal entry point (`checkAtRevision`) added to `En/Check.hs`, so EP-42 shares a merge
seam with EP-39/EP-40/EP-41 on that file — keep the addition surgical and rebase like
the others. There is also an EP-41/EP-42 seam the rebase rule does not cover: EP-41
changes what `checkCached` stores while EP-42 changes how lookup confirmation calls it;
whichever lands second re-verifies the cached-lookup confirmation-hit tests (both plans
carry this note). EP-43 (expand) is fully parallel with
everything. EP-44 runs last by design: it tunes and deduplicates code the other plans
finish shaping, and it deletes or relocates the unused reachability `EntryPoint`
machinery only after confirming no other child plan adopted it.


## Integration Points

The `TupleStore` effect (`en-core/src/En/Effect/TupleStore.hs`) gains a point-membership
probe operation in EP-39. EP-39 defines it and updates all interpreters: the PostgreSQL
store (`en-postgres/src/En/Postgres/TupleStore.hs`), the cached interposer
(`en-core/src/En/Effect/CachedTupleStore.hs`), and the in-memory conformance store
(`en-core/src/En/Conformance/Kikan.hs`). **Settled by EP-41 (2026-07-08):** the cached
interposer caches probes under a dedicated `ProbeReadKey !Revision !ObjectRef
!RelationName ![Subject]` in `En.Cache.TupleReadKey`, storing the row list as an
`Exhausted` `TuplePage`. Page reuse across read shapes was rejected. The subject list is
part of the key and must stay there: omitting it returns one subject's rows to another.
Cross-master-plan: the same effect gains write preconditions in
docs/plans/46-add-write-preconditions-and-atomic-mixed-writes.md (master plan 8); the
read-side and write-side extensions are disjoint operations on the same GADT, so
coordinate constructor naming but nothing else.

The check evaluation state (memo table, visited set, depth budget in
`en-core/src/En/Check.hs`) is reshaped by EP-39 (probe-first paths), EP-40
(cycle-as-empty, short-circuit union), EP-41 (what gets memoized), and EP-44 (configurable
budgets replace the `maxDepth`/`pageLimit` constants). Later plans in that order own
reconciling with earlier ones. **Settled by EP-41 (2026-07-08):** what gets memoized is a
`ResidualDecision` — a *tree* of named caveat gates joined by union/intersection/exclusion,
not a flat list of obligations, because a flat list cannot say whether two residual caveats
are joined by AND or by OR and rejoining them wrongly grants access. The memo, the
cross-request cache, and every internal evaluator now hold that one context-free type;
`CaveatContext` appears only in the three public entry points.

`EnError` (`en-core/src/En/Error.hs`) is extended by EP-40 (distinct "cycle detected" vs
"depth exceeded" — both currently collapse into `ResolutionLimitExceeded`). EP-42
decided to reuse the existing `InvalidConsistencyToken` error for cursor-validation
failures, since its cursors literally carry a consistency token (see EP-42's Decision
Log) — no new constructor there. **Confirmed by EP-42 (2026-07-08):** that choice cost
nothing to wire, because `enErrorToFault` already maps the constructor to a 400
`invalid_consistency_token`. The wire mapping of the new EP-40 constructors belongs
to docs/plans/35-version-the-wire-contract-and-type-the-error-model.md (master plan 6);
whichever lands second wires the new constructors into the error envelope.

The lookup cursor codec (`en-core/src/En/Lookup.hs`, currently raw revision text) is
redefined by EP-42 to carry a validated token. The service layer
(`en-servant/src/En/Servant/API.hs`) passes cursors opaquely, so no wire change is
expected, but docs/plans/52-add-a-lookup-subjects-api.md (master plan 9) should reuse
EP-42's cursor discipline for its own paging. **Settled by EP-42 (2026-07-08):** format
`lookup-v2` is `token | lastObjectType | lastObjectId | branchCount ( … )*`; `v1` cursors are
rejected, not migrated. `ConsistencyStore` gained
`MintToken :: Revision -> ConsistencyStore m ConsistencyToken` with smart constructor
`mintToken`, implemented by all four interpreters — the two in-memory ones (a new *strict*
variant, `runConsistencyStoreInMemoryStrict`, exists because the permissive one cannot fail a
token and so cannot test a rejection), the PostgreSQL one, and both in `en-example`.
docs/plans/51-return-checked-at-consistency-tokens-from-read-responses.md (master plan 9)
reuses `MintToken` as-is. No wire change was needed: `enErrorToFault` already maps
`InvalidConsistencyToken` to a 400, so docs/plans/35's contribution here was already in place.

The expand node type (`En.Expand.ExpandNode`) and its wire mirror
(`En.Servant.API.ExpandNodeWire`) are owned by EP-43. **Settled by EP-43 (2026-07-09):**
`ExpandNode` gained `ExpandUnion ![ExpandNode]`, `ExpandIntersection ![ExpandNode]`, and
`ExpandExclusion ![ExpandNode] ![ExpandNode]` (granted children, subtracted children). The
handshake with docs/plans/35-version-the-wire-contract-and-type-the-error-model.md
(master plan 6) is resolved in 35's favour, because 35 landed first: the wire tags are
`kind: "union" | "intersection" | "exclusion"`, lowercase, following EP-35's `kind`
discriminator vocabulary, and no `Wire`-suffixed constructor name reaches a client. The
exclusion node's two sides are distinct JSON keys (`granted`, `subtracted`) so no encoder
can merge them. EP-44 must leave `unionNode`/`intersectionNode`/`asBranchNode` in
`En/Expand.hs` alone — the single-branch collapses are semantics, not optimizations.

`ExpandNodeWire` has a consumer the compiler does not check: `instance ToSchema
ExpandNodeWire` in `en-servant/src/En/Servant/OpenApi.hs` hand-enumerates the node kinds
into the published OpenAPI 3.1 document. Any later plan adding a node kind must update it
by hand or ship a specification that contradicts the server.

Engine configuration (EP-44's budget record) is constructed in `en-server/app/Main.hs`
and the `en-servant` seam defaults; it must slot into the server configuration record
established by docs/plans/38-validate-configuration-and-persist-datastore-identity.md
(master plan 6) if that has landed. **Settled by EP-44 (2026-07-09):** 38 had landed, so
the budget went into `ServerConfig`, read from `EN_MAX_DEPTH`, `EN_PAGE_LIMIT`, and
`EN_RESULT_CAP` through 38's `withDefault … positive` helper. EP-44's own M3 text said to
hardcode `defaultEvaluationBudget` and leave env parsing to 38; that text predated 38
landing, and following it would have left the budget a source constant with no remaining
plan owning the lift. `En.Budget.EvaluationBudget { maxDepth, pageLimit, resultCap }` is
the shared vocabulary; the `…WithBudget` entry points (`checkWithBudget`,
`checkAtRevisionWithBudget`, `lookupWithDeadlineAndBudget`, `expandWithBudget`, and cached
variants) are the real ones, and every pre-existing name is a thin
`defaultEvaluationBudget` wrapper, so no call site changed. `En.Servant.Seam.Env` gained a
strict `budget` field.

`En.Reachability.ReachabilityGraph` no longer carries `entries`. **Settled by EP-44
(2026-07-09):** entry-point compilation moved behind
`entryPoints :: ValidSchema -> Map RelationRef [EntryPoint]`, and
`En.Schema.Render.renderReachabilityMermaid` now takes a `ValidSchema` rather than a
graph. Any later plan that wants reverse-edge metadata — the explain/trace feature the
review files as E12 is the obvious one — calls `entryPoints`, and pays for it only there.


## Progress

- [x] EP-39 (2026-07-08): point-membership probe on TupleStore with all three interpreters
- [x] EP-39 (2026-07-08): check answers direct membership without full-relation scans; wide-relation checks no longer error
- [x] EP-40 (2026-07-08): data cycles yield empty results, not failures; union short-circuits on Allowed
- [x] EP-40 (2026-07-08): exclusion over a Conditional base evaluates the subtrahend; checkMany surfaces per-pair errors
- [x] EP-41 (2026-07-08): decision cache keyed without caveat context; caveats re-applied on hit; cross-request hit rate demonstrated
- [x] EP-41 (2026-07-08): check evaluates symbolically; probe results cached in the tuple-read interposer
- [x] EP-42 (2026-07-08): lookup confirmation resumes from the cursor watermark and is bounded to the page; the traversal itself still recomputes (see below)
- [x] EP-42 (2026-07-08): cursors validated like consistency tokens; deadline interrupts expansion; one snapshot per lookup
- [x] EP-43 (2026-07-09): expand tree preserves union/intersection/exclusion operators end-to-end to the wire
- [x] EP-43 (2026-07-09): exclusion keeps granted and subtracted children apart; operator nodes are atomic under paging
- [x] EP-44 (2026-07-09): depth/page/result budgets configurable per engine (`En.Budget`, read from `EN_MAX_DEPTH`/`EN_PAGE_LIMIT`/`EN_RESULT_CAP`); nine constants deduplicated to one record
- [x] EP-44 (2026-07-09): EntryPoint machinery relocated to `entryPoints`; hot-path fixes landed; benchmarked, and the benchmarks' limits recorded


## Surprises & Discoveries

**The workspace baseline was red before this initiative began (found in EP-39's M0,
2026-07-08).** `cabal test all` failed in `en-example`, which still asserted that an engine
error yields HTTP 500. Commit `059fbd4` — a completed child of
`docs/masterplans/6-*` — had deliberately remapped `StoreError` to a 503 with
`retryable=true` and did not update the sibling package's assertion. EP-39 fixed the stale
assertion in its own commit (`54b58aa`) so that its before/after evidence for findings
B1/B2 is not confounded.

The lesson is a coordination one, and it applies to every child plan here: a plan whose
acceptance runs only its own focused suites can leave another package broken without
anyone noticing. Every child plan of this master plan must run the full workspace suite
(`cabal build all && cabal test all`) at its Final milestone, not just the suites for the
modules it edited. EP-39's Final milestone already specifies this; EP-40 through EP-44
should be read as carrying the same requirement.

**EP-39 changed the shape `En/Check.hs` presents to EP-40 and EP-41 (2026-07-08).** Three
things the later plans assume about that file are no longer true, and each of them makes
those plans *smaller*, not larger.

The non-memoized evaluator family is gone. `check`, `checkCached`, and `checkMany` now all
drive `evalRelationMemo`/`evalRewriteMemo`, so a semantics change written once takes
effect everywhere. EP-40 was written against a tree where `evalRewrite` and
`evalRewriteMemo` both existed and had to be edited in lockstep; it should now edit one.

`ensureExhausted` is gone, and with it the collapse of "this relation is wider than a page"
into `ResolutionLimitExceeded`. EP-40's error-taxonomy work (B3: distinguishing "cycle
detected" from "depth exceeded") therefore has one fewer unrelated meaning to disentangle
from that constructor: the only remaining producers of `ResolutionLimitExceeded` in
`En/Check.hs` are the depth guard and the visited-set guard, which is exactly the pair
EP-40 exists to split apart.

The `This` case now short-circuits on an unconditional `Allowed` from the probe. This is a
local union short-circuit, and EP-40 owns the general one across rewrite branches. One
consequence needs EP-40's explicit blessing: a relation containing both an unconditional
grant and a row whose caveat name is undefined in the schema now returns `Right Allowed`,
where the old evaluator returned `Left (UnknownRelation "unknown caveat: …")` because
`sequence` fails on the first `Left` anywhere in the decision list. No test exercises this
today. EP-40 should decide whether "provably allowed by a path involving no caveat" beats
"some other row of this relation is malformed", and record it.

**A soundness rule EP-41 and EP-44 must not optimize away (2026-07-08).** EP-39's batched
nested-group accelerator (`provenByDirectGroupMembership` in `En/Check.hs`) concludes
`Allowed` from a stored membership tuple only when the group's relation reaches a bare
`This` through unions — guarded by `relationUnionsThis`. A relation defined as
`Intersection [This, active]` or `Exclusion This banned` is not satisfied by a stored
tuple alone. EP-40 rewrites exclusion semantics and EP-44 tunes hot paths; both touch code
adjacent to this guard, and removing it silently grants access. The same function also
declines to accelerate any subproblem already on the `visited` stack or at the depth
limit, precisely so that EP-40 — not EP-39 — decides what cycles and depth exhaustion
mean.

**A hard precondition EP-41 inherits from EP-40 (2026-07-08): never cache a decision that
consumed a cycle cut.** EP-40 made a revisited subproblem contribute `Denied` instead of an
error, which is Zanzibar's semantics. But that `Denied` is true only while the revisited
node sits on the recursion stack; evaluated on its own the same subproblem may be `Allowed`.
Any decision computed *using* such a cut is therefore stack-local, and EP-40 found that
`En/Check.hs` would happily write those into both the within-call memo and — through
`checkCached`'s `insertExternalDecision` — the process-wide decision cache served to later
requests. A legal cycle in customer data would have silently denied a subject with access
until the cache expired.

`En/Check.hs` now threads a `CutTaint` value beside the decision and refuses to memoize or
cache a `Tainted` one. EP-41 rewrites exactly that path: it changes what `checkCached`
stores (a context-free decision plus residual caveat obligations) and re-keys the cache. It
must carry the `Untainted` precondition across to both writes. A context-free decision
derived under a cut is no safer to cache than a context-bearing one, and the failure is
silent — the test that catches it (`taintSchema` in `en-core/test/Main.hs`) had to be
written twice, because the obvious version passes against a broken evaluator.

**EP-40 narrowed `ResolutionLimitExceeded` and added `CycleDetected` (2026-07-08).** The
constructor now means only "a configured budget was exhausted". `check` and `lookup` never
raise `CycleDetected`; `expand` does, since it renders a tree for a human to audit. The
master plan's Integration Points anticipated that
docs/plans/35-version-the-wire-contract-and-type-the-error-model.md (master plan 6) would
wire new constructors into the error envelope, "whichever lands second". That is now moot:
`enErrorToFault` in `en-servant/src/En/Servant/Seam.hs` is a *total* match (EP-35 made it
so), which means adding a constructor is a compile error, not a silent fall-through. EP-40
therefore supplied the mapping itself — 422, `cycle_detected`, `retryable = false`. EP-43
should note that if operator-preserving expand wants a dedicated cycle node in the tree
instead of an error, that is a change to EP-40's deliberate choice and needs its own
decision.

**`checkMany` changed shape, and EP-44's benchmark work will see it (2026-07-08).** It now
returns `[Either EnError CheckDecision]`. The HTTP batch response is byte-identical — an
unevaluable pair is still a denial on the wire — but the engine no longer destroys the
error. It also does *not* take an `Error EnError` constraint, contrary to its own plan's
Decision Log: it raises nothing, and `-Wredundant-constraints` rejects the addition.

**EP-41 made the check evaluator symbolic, which is a bigger change than "re-key the cache"
(2026-07-08).** `En/Check.hs` no longer sees the caveat context anywhere below its three
public entry points. Every internal evaluator returns `ResidualDecision` — the traversed
answer with its caveats left as named gates joined by the union/intersection/exclusion
structure the traversal found — and `En.Caveat.applyResidual` folds the request's context
through it once, at the top. The within-call memo and the cross-request cache both store
that context-free value. EP-42 and EP-44 will read a `En/Check.hs` whose evaluators have no
`CaveatContext` parameter at all; do not add one back.

Three consequences fall out of the traversal losing the ability to ask "does this caveat
pass?", and EP-44's hot-path work will encounter all three. A caveated probe hit no longer
short-circuits a union (`unionSettled` tests for `RAllowed`, an *unconditional* allow, and a
caveated allow is an `RCaveat`, which settles nothing). The nested-group accelerator now
requires *uncaveated* edges — this **tightens** the `relationUnionsThis` soundness guard
this master plan flagged, and EP-44 must not "restore" the old context-sensitive test as an
optimization: it would cache a satisfied caveat as an unconditional allow. And `Exclusion`
evaluates its subtrahend whenever the base is not *symbolically* `RDenied`, which costs
reads the old evaluator skipped but cannot change an answer.

**EP-40's cut-taint precondition survived EP-41 intact (2026-07-08).** `evalRelationMemo`
still threads `CutTaint` and still refuses to memoize or cache a `Tainted` residual.
Making a decision context-free did not make one derived under a cycle cut any safer to
cache, exactly as the Decision Log anticipated. EP-44 inherits the same precondition.

**Lookup barely uses the decision cache, and EP-42 should know why before it changes the
seam (2026-07-08).** `En.Lookup.evalRewrite` calls `confirmCandidates` — and therefore
`checkCached` — only for `Intersection` and `Exclusion` rewrites. Union, `This`,
`ComputedUserset`, and arrows resolve candidates straight from the reverse index and never
confirm. EP-41's first attempt at a cached-lookup cross-context test used
`intention#view` (a `ComputedUserset` over `This`), asserted decision-cache hits, and
failed, because that lookup performs zero cached checks. The test now uses `room#enter`, an
exclusion over a time-bounded grant. This is the EP-41/EP-42 seam the Dependency Graph
predicted: EP-42 changes how lookup confirmation calls `checkCached`, so it must re-verify
`cached lookup hits the decision cache across caveat contexts` in `en-core/test/Main.hs` —
and if it widens confirmation to more rewrite kinds, the decision cache suddenly matters far
more to lookup than it does today.

EP-42 should also note that a repeated cached lookup does **not** perform zero store reads,
because lookup re-runs its whole candidate traversal every call. That is finding B7, EP-42's
own subject. EP-41's test therefore asserts only that a *differing caveat context* costs no
extra reads over repeating the identical request. Once EP-42 lands incremental paging, that
assertion can be strengthened.

**A testing rule this initiative should adopt beyond the decision cache (2026-07-08).** The
master plan's existing rule — a memo or caching test is not accepted until it has been seen
to fail against a deliberately broken implementation — caught two would-be-vacuous tests in
EP-41, and both failures were instructive rather than pedantic.

A cross-context cache test that asserts only the *hit* passes against a cache that stores
the answer computed under the inserting request's context, which is the precise bug B6's fix
could introduce, and which serves expired grants as `Allowed`. Every pre-existing assertion
in the suite passed against that sabotage. Only an assertion that the answer still tracks
the context caught it.

A probe read-cache test that asserts only the *read count* passes against a `ProbeReadKey`
whose `Ord` instance omits the subject list — which returns one subject's rows to another,
a privilege escalation, and which makes the read count look *better*. Only asserting the
returned rows caught it.

The rule should be read as covering read caches and pure algebra, not just the decision
cache it was written for. The generalization: when a test's subject is "X was reused", the
assertion must be about the *value* reuse produced, never about reuse having occurred.

**EP-41 owns `ProbeReadKey`; EP-44 should leave it alone (2026-07-08).** The integration
point the master plan assigned to EP-41 is settled: `TupleReadKey` gained
`ProbeReadKey !Revision !ObjectRef !RelationName ![Subject]`, and `cachedTupleStore` stores
probe rows as an `Exhausted` `TuplePage` so probes share the one cache and its bound. Page
reuse across shapes was rejected — reconstructing probe answers from cached
`ReadObjectRelation` pages would couple the interposer to paging semantics and only pay off
when a full page for the same `object#relation` at the same revision is already cached,
which is rare precisely in the wide-relation case probes exist for.

**`En.Cache.DecisionKey` is dead, and EP-44 now has the evidence to delete it
(2026-07-08).** EP-41's staleness sweep found exactly two caches in the workspace,
`Cache TupleReadKey TuplePage` and `Cache SubproblemKey ResidualDecision`. `DecisionKey`'s
only consumer is `en-core/test/Main.hs`, which caches `Text` under it. It still carries a
`context` field, which is harmless (a context-bearing key is safe, merely useless) but is
now the last place in en where a cache key mentions caveat context.

**EP-44's `EntryPoint` question has a partial answer already (2026-07-08).** EP-39 needed
"does this relation union in its directly-stored tuples?" and answered it by walking the
`Rewrite` tree (`relationUnionsThis`), not by consulting the reachability graph's unused
`EntryPoint` machinery. That is one more consumer that could have adopted `EntryPoint` and
did not, which is evidence for relocating or deleting it rather than wiring it up. EP-44
should weigh that when it makes the call.


**EP-42 found the limit of what the engine can fix alone: store scans are ordered by row id
(2026-07-08).** Both of en's tuple stores return `readStartingWithUser` rows `ORDER BY id ASC`
with a keyset cursor on `id`. Row id is insertion order and bears no relation to
`(object_type, object_id)`, which is the key lookup sorts and paginates by. Two consequences,
and they are the same fact seen twice.

Per-branch cursor resumption — the mechanism EP-42's plan named for making page N+1 cheaper —
is unsound. A branch yielding objects `[z, a, b, c]` in store order, paged at `limit 2`, emits
`[a, b]`; resuming past those four rows loses `c` and `z`, consumed but never emitted because
they fell beyond the page limit. No prefix of a branch scan is safe to skip. And an interrupted
traversal cannot emit what it has found, for the same reason: those objects are an arbitrary
subset, not the smallest members, so advancing the watermark past them would drop everything
smaller that remains undiscovered.

EP-42 therefore fixed the half that is fixable in the engine — confirmation, which is the
expensive stage — and left the traversal recomputing per page. The unlock is a storage change:
order `readStartingWithUser` by `(object_type, object_id, id)` with a matching keyset cursor and
supporting index, in `en-postgres` and in the in-memory store. That would let the traversal
resume *and* let an interrupted lookup emit a true prefix; both of EP-42's retreats dissolve at
once. It is a coherent plan of its own and this master plan does not contain it. The lookup
cursor reserves a `frontier` field for it, encoded and round-trip tested, currently always empty.

**EP-42 fixed two findings structurally rather than behaviorally, and EP-44 must not undo it
(2026-07-08).** B9 (forgeable cursors) is closed by importing `Revision` *without its
constructor* into `en-core/src/En/Lookup.hs`: the module cannot build a revision from client
text, so an edit that resurrects `Revision cursorText` does not compile. B7 (one lookup, many
snapshots) is closed by deleting `consistency` from the internal evaluators, which also deleted
`ConsistencyStore :> es` from their constraint sets: the traversal cannot resolve consistency,
because the effect is not available to it.

Both are compiler-maintained invariants. EP-44 tunes hot paths in exactly these functions. If a
signature there grows `ConsistencyStore :> es` back, or `En.Lookup` starts importing
`Revision (..)`, a fixed finding has been silently reopened.

**`En.Check` gained two engine-internal entry points (2026-07-08).** `checkAtRevision` and
`checkCachedAtRevision` take an already-resolved revision and a caller-owned `CheckMemo`,
returning the updated memo. `CheckMemo` and `emptyCheckMemo` are exported. They exist so lookup
can pin every confirmation to the snapshot its traversal read and share subproblems across a
candidate list. Callers must not carry a memo across a revision boundary; the functions cannot
check that, which is why they are documented engine-internal. EP-44's benchmark work will see
them.

**EP-41's context-free memo made EP-42's shared memo sound for a stronger reason than expected
(2026-07-08).** The plan justified sharing one memo across a lookup's confirmations with "one
lookup has one context". After EP-41 the memo holds `ResidualDecision`s, which mention no caveat
context at all; the context is applied per candidate at the `checkAtRevision` boundary. And
EP-40's cut-taint rule already guarantees a residual computed under a cycle cut is never
memoized, so the shared memo cannot inherit a stack-local answer. Two earlier plans paid for a
property this one needed.

**A third test encoding a bug, and a pattern worth naming (2026-07-08).** EP-41 inverted a test
asserting that a different caveat context must *miss* the decision cache. EP-42 inverted two
more: one asserted a lookup with a budget of *zero polls* still returned a full 500-object page
(the deadline could only relabel work it had already done in full), and the cursor round-trip
test pinned the v1 format whose raw-revision field is the forgery.

Three tests, three plans, one shape: a test written to pin current behavior pins current bugs,
and reads as coverage. The only way to notice is to ask what the assertion *would* say if the
bug were fixed. EP-43 and EP-44 should expect to find more of these — EP-43 in particular, since
expand's current tree shape is what B10 says is wrong, and any test asserting that shape is
asserting the finding.

**EP-42 measured what it fixed (2026-07-08).** Consistency resolutions per lookup: 3 → 1.
Confirmation store reads across three pages of an exclusion fixture: a flat 17 per page → 15,
12, 7. Store pages read by a lookup with no deadline budget: 2 → 1. Shared-memo confirmation on
a shared-subtree fixture: 19 → 17 reads. The last number is small on purpose, and EP-44 should
know why before it benchmarks: EP-39's probe already made an individual confirmation cheap, so
memo sharing saves one bounded read per candidate rather than a whole relation drain.


**"The compiler will force it" is false in this workspace, and EP-44 should stop relying on
it (EP-43, 2026-07-09).** `-Wall` is on; `-Werror` is not. EP-43 extended `ExpandNode` and
`cabal build all` exited 0, emitting only a `-Wincomplete-patterns` warning for
`expandNodeToWire` — a function EP-43's plan twice called "the total mapping the compiler
will force you to extend". Shipping that state means a `Non-exhaustive patterns` crash on
the first intersection any client expands, and every test suite stays green, because no test
expanded one.

There is a second, worse instance in the same file's neighbourhood. `instance ToSchema
ExpandNodeWire` in `en-servant/src/En/Servant/OpenApi.hs` hand-enumerates the wire node kinds
into the published OpenAPI document. It is a list, not a pattern match, so it produces no
warning at all. EP-43's own survey of `ExpandNode` consumers missed it, having searched for
the engine type rather than the wire type.

The consequence for this initiative is procedural. EP-44 deletes or relocates the
`EntryPoint` machinery, deduplicates budget constants across three modules, and tunes hot
paths — all changes whose safety argument is "the compiler finds the call sites". It will
not, for hand-written schema instances, JSON decoders, or any `case` over `Text`. Grep for
the *wire* type as well as the engine type, and remember that a green build here means less
than it looks.

**A fixture whose branches all have arity one cannot observe branching (EP-43,
2026-07-09).** This is the master plan's testing rule meeting a new failure mode, and it is
the first time the vacuous test was one a plan *specified in advance* rather than one it
inherited.

Every conjunct in the kikan schema is a `ComputedUserset`, and a `ComputedUserset` expands to
exactly one node. So on `audited-space#audit`, an `intersectionNode` that emits one child per
conjunct and a broken one that concatenates all branches produce the *same tree*: two
children either way. `treeHasIntersection` passes against both. So does counting conjuncts.
EP-43's plan specified exactly those assertions, and they would have covered `asBranchNode`
— the function the plan calls "the difference between n conjuncts and one blurry pile" —
not at all.

The fix was a fixture, not an assertion: `branchSchema` in `en-core/test/Main.hs`, an
intersection over a two-row `This`. Under sabotage it fails `Just 2` / `Just 3` while every
kikan-based assertion stays green. The generalization, which EP-44's benchmark work should
carry: before trusting a test, ask what *arity* the code under test distinguishes, then check
the fixture exhibits more than one of it. A test over a one-element case is a test of the
element, not of the structure.

**EP-43 met the predicted inherited bug-pinning test too (2026-07-09).** `expand paginates
top-level children` (`en-core/test/Main.hs`) expanded `audited-space#audit` at `ExpandLimit
1` and asserted `ExpandHasMore`. It passed only because the intersection was flattened into
two pageable children — the erasure B10 names. It now expands a flat two-row relation, and a
sibling assertion pins that an operator node is atomic under paging: `audit` at limit 1 is
`ExpandExhausted` with one child, because handing a client half a conjunction is worse than
the flattening this plan removed. That is four bug-pinning tests across four plans.


**The in-memory conformance store skipped rows, and every wide-relation claim this
initiative made was measured against it (EP-44, 2026-07-09).** `pageTuples` in
`en-core/src/En/Conformance/Kikan.hs` resumed a cursor with
`drop start (zip [start + 1 ..] tuples)` — dropping from the *zipped* list. Each page's
outgoing cursor was `2 * start` instead of `start + limit`, so a relation spanning three or
more pages silently lost rows and then reported `Exhausted` as though it had read them all.

Every engine drains through that function. It is a fixture bug, so no production path was
affected, but it means EP-39's `check-wide` evidence — a 2,048-row relation, which is where
the skipping *begins* — was gathered from a store that read 2,000 of those rows. The bug
had been invisible for the same reason throughout: the widest fixture in the suite spanned
two pages, and two pages is exactly where it starts.

What found it was an *assertion on a benchmark*. EP-44's `checkMany/wide-overlapping`
fixture pins its answer before `defaultMain` times it, and it denied on a 5,064-row folder
while allowing on 64-row folders carrying identical group attachments. Without that
assertion the benchmark would have reported a plausible time for the wrong computation, and
gotten *faster* for it. The generalization, which is the master plan's testing rule reaching
somewhere nobody thought to apply it: **a benchmark is a test whose assertion was left
out.** A benchmark reports a time whatever the engine returns, so a mistyped fixture reads
as a fast benchmark and a wrongly-denied check reads as an expensive one.

In the same file, `lookup/wide-fanout` first reported **2.29 ns** — three orders of
magnitude below the cheapest honest bench — because `\() -> action` is a constant
expression and GHC's full-laziness pass floats it out of the lambda, so every iteration
after the first read a memoized result. EP-39's benchmarks were written in that shape too.

**Microbenchmarks at millisecond scale are not evidence on this hardware, and a bisect will
happily explain the noise (EP-44, 2026-07-09).** The two fixtures EP-44 built to see B12's
quadratic accumulation are bimodal at a ratio of 1.35: the same binary, the same command,
lands near 4.7 ms or near 6.3 ms. Within one shell session the mode is *stable* — five
alternating before/after rounds gave spreads of 1.01×–1.05× — so a single session reads as
clean evidence. Across sessions the mode flips, and it flips per configuration. Two
sessions, identical commits and method, gave `checkMany/wide-overlapping` at **+34%** and at
**−26%**.

Bisecting the second attributed the entire swing, reproducibly, to a commit that deletes an
unused record field from `En.Reachability` — a module `checkMany` never calls at runtime.
A field no engine reads cannot slow an engine by a third; what moved was code and data
layout. `-fproc-alignment=64` is already set and a 64 MB nursery changed nothing.

Two consequences for anything that follows this initiative. The deferred concurrency work
will want to show speedups on exactly these fixtures, and must not trust a single session's
numbers: alternate configurations within one session, take minima, and check whether an
unrelated commit moves the same number. And `en-core/bench/baseline.csv` — which CI gates
at `--fail-if-slower 25` — must never contain them. It currently contains four benchmarks
recorded on CI hardware and knows nothing of the seven added since EP-39; that gap is
better than a gate that flakes at ±35% until people learn to ignore it.

**`cabal build all` does not build test suites (EP-44, 2026-07-09).** It reported zero
errors while `en-core/test/Main.hs` had an out-of-scope identifier. Only `cabal test all`
compiles test components. The Decision Log's full-workspace rule already requires both;
this is why the second half is not optional, and it is one more instance of the pattern
EP-43 named — the build is greener than it looks.

## Decision Log

- Decision: Split performance (EP-39) from semantics (EP-40) even though both rewrite `En/Check.hs`.
  Rationale: Cycle/exclusion semantics need conformance-level review in isolation; bundling them with the probe rework would hide behavior changes inside a performance diff. A soft dependency plus rebase discipline handles the shared file.
  Date: 2026-07-07
- Decision: Defer concurrent subproblem dispatch entirely.
  Rationale: The review flags sequential evaluation as a gap, but correctness fixes must land first; concurrency multiplies whatever semantics exist. Revisit after this master plan completes.
  Date: 2026-07-07
- Decision: Keep lookup-subjects out of this master plan.
  Rationale: It is a new feature with its own API surface, not a fix to existing behavior; it lives in docs/masterplans/9-complete-the-en-api-surface.md and benefits from EP-42's cursor discipline.
  Date: 2026-07-07
- Decision: Every child plan runs the full workspace suite (`cabal build all && cabal test all`) at its Final milestone, not only the focused suites for the modules it edits.
  Rationale: EP-39's baseline check found the workspace already red, in `en-example`, from a completed child of master plan 6 whose acceptance ran only its own suites. Focused-suite acceptance cannot catch a change that breaks a sibling package. Cost is a few minutes per plan.
  Date: 2026-07-08
- Decision: EP-39 fixed the unrelated `en-example` failure itself, in a separate commit, rather than reporting it back to master plan 6.
  Rationale: A red baseline makes "these tests failed before and pass after" unverifiable, which is the entire acceptance argument of EP-39. The fix is a one-line stale assertion. Landing it separately keeps EP-39's diff honest and leaves it independently revertible.
  Date: 2026-07-08
- Decision: Cycle-as-empty ships with cut-taint propagation; decisions derived from a cycle cut are returned but never memoized or cached. Every later plan touching the memo or the decision cache inherits this precondition.
  Rationale: EP-40 discovered that cycle-as-empty without taint tracking is worse than the erroring behavior it replaces: it silently writes stack-local `Denied` answers into the cross-request decision cache. This is a whole-initiative invariant, not an EP-40 implementation detail, because EP-41 rewrites the cache and EP-44 tunes the evaluator around it.
  Date: 2026-07-08
- Decision: A test for a memoization or caching bug is not accepted until it has been observed to fail against a deliberately broken implementation.
  Rationale: EP-40's first cut-taint regression test passed against an evaluator with the guard removed — its two batch pairs used different subjects, and memo keys include the subject, so no entry was ever shared. It looked correct and proved nothing. Cheap to check, and the failure mode it guards against is silent.
  Date: 2026-07-08
- Decision: The rule above extends to read caches and pure algebra, and it is sharpened: when a test's subject is "X was reused", the assertion must be about the *value* the reuse produced, never about reuse having occurred.
  Rationale: EP-41 found two plausible implementations that pass reuse-shaped assertions while being badly wrong. A cross-context decision cache that stores the answer computed under the inserting request's context passes every "did it hit?" assertion in the suite and serves expired grants as `Allowed`. A `ProbeReadKey` whose `Ord` omits the subject list passes every "did reads drop?" assertion, makes the read count look better, and returns one subject's rows to another. Both were caught only by assertions about returned values.
  Date: 2026-07-08
- Decision: EP-42's fixes for B7 and B9 are enforced by the compiler, and no later plan may weaken them: `en-core/src/En/Lookup.hs` imports `Revision` without its constructor, and the internal lookup evaluators carry `TupleStore :> es` alone, without `ConsistencyStore`.
  Rationale: a forged cursor was obeyed because nothing validated it, and a lookup spanned several snapshots because the traversal could re-resolve consistency. Removing the *capability* rather than the *call site* means a regression is a compile error. EP-44 tunes exactly these functions; if a signature there regains `ConsistencyStore :> es`, or the module starts importing `Revision (..)`, a fixed finding has been reopened silently.
  Date: 2026-07-08
- Decision: Lookup's traversal keeps recomputing per page. Per-branch cursor resumption is abandoned, not deferred, and an interrupted lookup emits no objects.
  Rationale: both tuple stores scan `ORDER BY id ASC` with a keyset cursor on `id`, and row id bears no relation to object key. No prefix of a branch scan is safe to skip, and the objects found before an interruption are an arbitrary subset rather than the smallest members — emitting either would drop results silently. EP-42 fixed the half that is fixable in the engine (confirmation, the expensive stage) and left the rest to a storage plan that orders scans by `(object_type, object_id, id)`. Both retreats dissolve together if that lands.
  Date: 2026-07-08
- Decision: The check evaluator is symbolic throughout; `CaveatContext` does not appear below `check`/`checkCached`/`checkMany`, and the nested-group accelerator requires uncaveated edges.
  Rationale: caching a context-free decision requires that the traversal never consult the context, or only leaves could be cached. The accelerator's conclusion is an unconditional allow and cannot carry a gate, so a caveated edge must fall back to recursion. This tightens the `relationUnionsThis` guard rather than weakening it. EP-44 must not reintroduce a context-sensitive accelerator test as an optimization: it would cache a satisfied caveat as an unconditional allow, which is the same class of bug as B6's inverse.
  Date: 2026-07-08
- Decision: A plan may not justify completeness with "the compiler will force it" without checking the workspace's warning flags. `-Werror` is off; a non-exhaustive `\case` warns and builds. Hand-written `ToSchema` instances, JSON decoders, and any `case` over `Text` produce no warning whatsoever.
  Rationale: EP-43 extended `ExpandNode` and got a green `cabal build all` with a runtime crash latent in `expandNodeToWire`, and separately missed `instance ToSchema ExpandNodeWire` entirely, which would have shipped an OpenAPI document contradicting the server. Both were caught by reading warnings and by grepping the wire type, not by the build. EP-44's `EntryPoint` removal and constant deduplication rest on exactly this assumption.
  Date: 2026-07-09
- Decision: The testing rule extends again: when a test's subject is a *structure*, the fixture must exhibit more than one element of that structure. A test over a one-element case tests the element, not the structure.
  Rationale: every kikan intersection conjunct expands to exactly one node, so EP-43's specified assertions — `treeHasIntersection` and a conjunct count over `audited-space#audit` — pass identically against a correct evaluator and against one that concatenates every branch. `asBranchNode`, the function that carries the whole meaning of B10, was covered by nothing until `branchSchema` added an intersection over a two-row `This`. This is the first vacuous test in this initiative that a plan specified in advance rather than inherited, which is why the rule needs stating separately from "invert the test against a broken implementation": inverting these assertions would have shown them green.
  Date: 2026-07-09
- Decision: Operator nodes in the expand tree are atomic under paging; `pageNodes` never splits one across pages, and a single-branch `Union`/`Intersection` collapses to its branch.
  Rationale: slicing inside an intersection hands a client half a conjunction, which is a worse lie than the flattening EP-43 removes. The collapse is semantic — a one-branch operator carries no information — and EP-44 must not treat either as an optimization to tune away.
  Date: 2026-07-09
- Decision: The testing rule extends to benchmarks: a benchmark asserts the value its call returns before it is timed, and applies its call to an argument rather than closing over one.
  Rationale: a benchmark reports a time whatever the engine returns, so it is a test with the assertion left out. EP-44's assertion caught the conformance store dropping rows on any relation wider than two pages — a bug every engine drains through, which had been invisible since EP-39 measured its wide-relation evidence against it. And `\() -> action` is a constant expression GHC floats out of the lambda: `lookup/wide-fanout` first reported 2.29 ns, timing a memoized result. Both failures produce a plausible number, which is worse than an error, and both make the benchmark look *better*.
  Date: 2026-07-09
- Decision: This initiative does not claim performance improvements from its millisecond-scale microbenchmarks, and they never enter `en-core/bench/baseline.csv`.
  Rationale: they are bimodal at 1.35×, stable within a shell session and flipping across sessions, so any one session reads as clean evidence. Two sessions of five alternating rounds, same commits and command, gave `checkMany/wide-overlapping` at +34% and at −26%; bisecting the second blamed a commit that deletes an unused record field from a module the benchmark never calls. That is code layout. CI gates at `--fail-if-slower 25`, and a ±35% benchmark behind that gate teaches operators to ignore it. The deferred concurrency work will want to demonstrate speedups on exactly these fixtures and must not trust one session: alternate within a session, take minima, and check whether an unrelated commit moves the number.
  Date: 2026-07-09
- Decision: An undefined caveat name beside a *satisfied caveated* grant now fails the check instead of returning `Allowed`; beside an *unconditional* grant it is still absorbed by the short-circuit.
  Rationale: symbolic evaluation cannot know the good row's caveat passes, and deferring name validation to re-application does not recover the old answer (the fold is a `traverse` and fails on the first `Left` in the union). Failing closed on data referencing a caveat the schema no longer declares is the defensible reading, and eager validation guarantees a cached residual names only definable caveats. This refines, and does not contradict, the case EP-39 introduced and EP-40 blessed.
  Date: 2026-07-08


## Outcomes & Retrospective

All six child plans are complete, and every finding in Theme B (B1–B12) of
`docs/reviews/2026-07-07-architecture-performance-review.md` is closed or explicitly
retreated from with its reason recorded.

Check answers direct membership with one bounded probe instead of draining the relation,
so a check on a relation of any width no longer errors (B1, B2). Data cycles contribute
nothing rather than poisoning the whole check, and a decision derived from a cycle cut
never enters the memo or the cross-request cache (B3, B4). Exclusion over a conditional
base evaluates its subtrahend, and `checkMany` surfaces per-pair errors instead of
destroying them (B5). The decision cache is keyed without caveat context and stores a
`ResidualDecision`, so requests differing only in `current_time` share one entry and each
still gets its own answer (B6). A lookup reads one snapshot for its whole life, its cursors
are validated like consistency tokens, and its deadline interrupts the walk rather than
relabelling a finished one (B7 partial, B8, B9). Expand preserves union, intersection, and
exclusion, so an auditor can tell "all of" from "any of" from "except" (B10). The three
evaluation budgets are one record read from the environment, and the hot-path and cache
mechanics of B11/B12 are worked through (B11, B12).

Two retreats are deliberate and documented. Lookup's traversal still recomputes per page,
because both tuple stores scan `ORDER BY id ASC` and row id bears no relation to object
key, so no prefix of a branch scan is safe to skip; the fix is a storage plan this master
plan does not contain, and the lookup cursor reserves a `frontier` field for it. And
concurrent subproblem dispatch stays deferred, as decided at the outset.

**What this initiative learned about its own evidence is worth more than any single fix.**
Six plans produced a chain of discoveries about tests that read as coverage and prove
nothing, and each one sharpened the rule that caught the next.

It began as "invert a caching test against a broken implementation" (EP-40). EP-41 widened
it: when a test's subject is "X was reused", assert the *value* the reuse produced, never
that reuse occurred — two plausible implementations passed every reuse-shaped assertion in
the suite while serving expired grants as `Allowed` and one subject's rows to another.
EP-43 widened it again: when a test's subject is a *structure*, the fixture must exhibit
more than one element of it — every kikan intersection conjunct expands to exactly one
node, so the assertions EP-43's own plan specified in advance could not distinguish a
conjunction from a pile. EP-44 widened it once more, to a place nobody had thought to look:
a benchmark is a test whose assertion was left out, and adding one exposed a paging bug in
the conformance store that every engine drains through and that had silently truncated
EP-39's wide-relation evidence.

Five tests across the initiative turned out to encode the bugs they covered. EP-43 predicted
it would meet more, and it did.

The counterpart lesson is about trusting the compiler. "The compiler will force it" is false
here — `-Werror` is off, so EP-43 shipped a green build with a latent crash, and a
hand-written `ToSchema` instance produced no warning at all. EP-44 found the boundary of
that lesson: a *strict record field* genuinely is compiler-enforced (`Env.budget` errored at
every construction site), while the configuration plumbing beside it is not — omit a name
from `Config.knownVariables` and an operator's environment variable is silently ignored. And
`cabal build all` never compiles test suites, so a green build says less than it appears to.

Finally, EP-44 could not measure most of what it fixed. Its two millisecond benchmarks are
bimodal at 1.35×, stable within a session and flipping across them, and a bisect attributed
a 34% swing to deleting an unused record field from a module the benchmark never calls. One
change — `Map.lookupMin` eviction — is a reproducible 51% win; four are reproducible
regressions of 8–13% on sub-microsecond in-memory fixtures, the price of a cycle guard that
no longer degrades as `EN_MAX_DEPTH` rises. The rest is asymptotics the hardware cannot see.
The concurrency work this master plan deferred will want to demonstrate speedups on exactly
these fixtures, and should read that section before it starts.


---

Revision note (2026-07-08, third): EP-41 is complete. Registry, Progress, Integration
Points, Surprises & Discoveries, and Decision Log updated. Finding B6 is fixed: a caveated
grant checked under four contexts now reads the tuple store once, where the second context
previously re-traversed the graph.

The mechanism turned out to be larger than the plan's title suggests, and later plans must
know it. `En/Check.hs` is now a *symbolic* evaluator: no internal function takes a
`CaveatContext`, every subproblem yields a `ResidualDecision`, and the request's context is
folded in once at the top. EP-42 and EP-44 will read that file; they must not thread a
context back down. Two Integration Points are now settled rather than pending: what gets
memoized (a residual *tree*, not a flat obligation list) and how the interposer caches
probes (`ProbeReadKey`, subject list included — omitting it is a privilege escalation).
EP-40's cut-taint precondition survived unchanged; a context-free decision derived under a
cycle cut is no safer to cache than a context-bearing one, exactly as predicted.

Three findings change what other children should expect. EP-44 must not "optimize" the
nested-group accelerator back to a context-sensitive test — EP-41 tightened it to require
uncaveated edges, and loosening it would cache a satisfied caveat as an unconditional
allow. EP-42 should know that `En.Lookup` reaches the decision cache only through
`Intersection` and `Exclusion` rewrites, which made EP-41's first cached-lookup test
vacuous, and that a repeated cached lookup still performs store reads because lookup
recomputes its traversal — B7, EP-42's own subject. And EP-44 now has the evidence it wanted
about `En.Cache.DecisionKey`: it is dead in production and is the last cache key in en that
mentions caveat context.

The master plan's testing rule gained a sharper form, promoted to the Decision Log because
it is an initiative-level invariant rather than an EP-41 detail: when a test's subject is
"X was reused", the assertion must be about the *value* the reuse produced, never about
reuse having occurred. EP-41 found two plausible implementations that pass every
reuse-shaped assertion in the suite while serving expired grants as `Allowed` and one
subject's rows to another. No decomposition change: EP-42 through EP-44 keep their scopes,
dependencies, and ordering.

Revision note (2026-07-08, second): EP-40 is complete. Registry, Progress, Surprises &
Discoveries, and Decision Log updated. The initiative-level consequence is a new invariant,
recorded in the Decision Log and in Surprises & Discoveries: cycle-as-empty is only safe
alongside cut-taint propagation, and no decision derived from a cycle cut may enter the memo
or the cross-request decision cache. EP-41 rewrites exactly that path and must carry the
precondition forward. Two smaller consequences: `EnError` gained `CycleDetected` and got its
wire mapping here rather than in master plan 6's docs/plans/35, because `enErrorToFault` is
a total match and the compiler would not allow the deferral the Integration Points section
assumed; and `checkMany` now returns `[Either EnError CheckDecision]` without an
`Error EnError` constraint, which EP-44's benchmark work will encounter. No decomposition
change: EP-41 through EP-44 keep their scopes, dependencies, and ordering.

Revision note (2026-07-08): EP-39 is complete. The Exec-Plan Registry, Progress checklist,
Surprises & Discoveries, and Decision Log are updated. Three of EP-39's discoveries change
what later child plans should expect, and are recorded in Surprises & Discoveries rather
than left in EP-39's own file: `En/Check.hs` now has a single evaluator (EP-40 and EP-41
edit one code path, not two); `ensureExhausted` is gone, so `ResolutionLimitExceeded` is
now produced only by the depth and cycle guards that EP-40 exists to separate; and EP-39's
probe short-circuit changes one observable error outcome that EP-40 must bless or revert.
A soundness guard in EP-39's batched accelerator (`relationUnionsThis`) is called out
explicitly so EP-40 and EP-44 do not remove it while working nearby. No decomposition
change: EP-40 through EP-44 keep their scopes, dependencies, and ordering. Two new Decision
Log entries record the full-workspace-suite requirement and why EP-39 repaired an unrelated
red test rather than routing it back to master plan 6.

Revision note (2026-07-07): Two corrections found while authoring the child plans.
First, EP-42 reuses `InvalidConsistencyToken` for cursor-validation failures instead of
adding a new `EnError` constructor (its cursors carry a real consistency token), so the
Integration Points entry for `EnError` now attributes new constructors to EP-40 only.
Second, EP-42 does touch `En/Check.hs` (a revision-pinned `checkAtRevision` entry point
is required to fix B7), so the Dependency Graph no longer claims it can treat check as a
black box and now records the EP-41/EP-42 `checkCached` seam. Both child plans carry the
matching notes.


---

Revision note (2026-07-09, sixth): EP-44 is complete, and with it this master plan.
Registry, Progress, Integration Points, Surprises & Discoveries, Decision Log, and
Outcomes & Retrospective updated. B11 and B12 are closed: the three evaluation budgets are
one `En.Budget.EvaluationBudget` read from `EN_MAX_DEPTH` / `EN_PAGE_LIMIT` /
`EN_RESULT_CAP`, the nine constant definitions are gone, the `EntryPoint` machinery is off
the structure every engine carries, and B12's hot-path list is worked through one commit at
a time.

Two Integration Points are now settled rather than pending. The budget slotted into
docs/plans/38's `ServerConfig` because 38 had landed — EP-44's own M3 text said to defer
env parsing to 38, advice written while 38 was still pending, which would have left the
budget a source constant with no remaining plan owning the lift. And `ReachabilityGraph`
lost `entries`; reverse-edge metadata now comes from
`entryPoints :: ValidSchema -> Map RelationRef [EntryPoint]`, which is where a future
explain/trace feature should look.

Three discoveries outlive the plan. The in-memory conformance store skipped rows on any
relation wider than two pages, which means every wide-relation claim this initiative made —
including EP-39's — was measured against a store that stopped reading; it was caught by
*asserting a benchmark's answer*, and the initiative's testing rule now covers benchmarks,
which are tests with the assertion left out. The millisecond microbenchmarks are bimodal at
1.35× and a bisect will happily attribute the noise to an unrelated commit, so this
initiative claims no speedup from them and they must stay out of `baseline.csv`, which CI
gates at `--fail-if-slower 25`. And `cabal build all` does not compile test suites, so the
Decision Log's `&& cabal test all` is load-bearing.

No decomposition change. This was the last child plan; the master plan is complete.

Revision note (2026-07-09, fifth): EP-43 is complete. Registry, Progress, Integration Points,
Surprises & Discoveries, and Decision Log updated. Finding B10 is fixed: `space#audit`, an
intersection, now answers with an intersection node over two conjunct subtrees rather than a
flat subject list byte-identical to what `space#act` — a union over the same two relations —
produces. Exclusion keeps its granted and subtracted children in separate wire keys, so an
auditor can see who is carved out. Operator nodes are atomic under paging.

The docs/plans/35 handshake this master plan left open is closed, and in 35's favour: 35
landed first, so the wire tags follow its `kind` vocabulary (`"union"`, `"intersection"`,
`"exclusion"`) and no Haskell constructor name reaches a client. No version bump; the tree
semantics are EP-43's, the spelling is 35's, exactly as both plans pre-committed.

Two discoveries change what EP-44 should expect, and both are about trusting the wrong thing.
First: "the compiler will force it" is false here. `-Werror` is off, so extending `ExpandNode`
built green with a latent `Non-exhaustive patterns` crash in `expandNodeToWire`, and the
OpenAPI document's `ToSchema ExpandNodeWire` — a hand-written list, warning-free — was missed
by EP-43's own consumer survey. EP-44 deletes `EntryPoint` machinery and deduplicates
constants on precisely this assumption. Second: a fixture whose branches all have arity one
cannot observe branching. Every kikan conjunct expands to exactly one node, so the assertions
EP-43's plan specified in advance were vacuous with respect to the function that carries B10's
whole meaning; a new `branchSchema` fixture closes it, and under sabotage it is the only
assertion that fails. Both are now Decision Log entries.

That makes four bug-pinning tests across four plans. The predicted one landed too: `expand
paginates top-level children` passed only because `audit`'s intersection was flattened into
two pageable children. No decomposition change: EP-44 keeps its scope, dependencies, and
ordering, and is now the only child remaining.

Revision note (2026-07-08, fourth): EP-42 is complete. Registry, Progress, Integration Points,
Surprises & Discoveries, and Decision Log updated. B9 (forgeable cursors) and B7 (one lookup,
many snapshots) are closed, and closed *structurally*: `En.Lookup` imports `Revision` without
its constructor, so it cannot build one from client text, and the lookup traversal no longer
carries the `ConsistencyStore` effect, so it cannot re-resolve consistency. Both are
compiler-maintained. EP-44 tunes these exact functions and must not reintroduce either
capability.

B8 splits. Its deadline half is fixed — polls sit inside the walk and an exhausted budget
interrupts it, reading one store page instead of two. Its paging half is fixed only for
confirmation, which is the expensive stage: 15/12/7 store reads across three pages where every
page previously cost 17. The traversal still recomputes per page, and the mechanism EP-42's plan
proposed for that (per-branch `StoreCursor` resumption) is unsound, because both stores scan
`ORDER BY id ASC` and row id bears no relation to object key. The same fact decided that an
interrupted lookup must emit nothing. Unlocking both requires object-ordered store scans — a
storage plan this master plan does not contain, and which the reserved cursor `frontier` field
awaits.

`En.Check` gained `checkAtRevision` / `checkCachedAtRevision` with an exported `CheckMemo` and
`emptyCheckMemo`; `ConsistencyStore` gained `MintToken`. Both are new shared vocabulary,
recorded in Integration Points; master plan 9's docs/plans/51 reuses `MintToken` unchanged.

Two more tests turned out to encode the bugs they covered — a zero-budget lookup asserting a
full page, and a cursor round-trip pinning the forgeable v1 format. That is now three across
three plans, and Surprises & Discoveries names the pattern for EP-43, which will meet it again:
expand's current tree shape *is* finding B10, so any test asserting that shape is asserting the
finding. No decomposition change: EP-43 and EP-44 keep their scopes, dependencies, and ordering.
