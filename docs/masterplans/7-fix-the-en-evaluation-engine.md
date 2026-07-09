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
| EP-41 | Cache context-free check subproblems | docs/plans/41-cache-context-free-check-subproblems.md | None | EP-39, EP-40 | In Progress |
| EP-42 | Stream lookup pages with validated cursors and a real deadline | docs/plans/42-stream-lookup-pages-with-validated-cursors-and-a-real-deadline.md | None | EP-39 | Not Started |
| EP-43 | Preserve set operators in expand trees | docs/plans/43-preserve-set-operators-in-expand-trees.md | None | None | Not Started |
| EP-44 | Make evaluation budgets configurable and trim hot-path overhead | docs/plans/44-make-evaluation-budgets-configurable-and-trim-hot-path-overhead.md | None | EP-39, EP-40, EP-42 | Not Started |


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
(`en-core/src/En/Conformance/Kikan.hs`). EP-41 decides how the cached interposer caches
probe results (single-tuple entries vs page reuse); it consumes EP-39's definition and
must not redefine it. Cross-master-plan: the same effect gains write preconditions in
docs/plans/46-add-write-preconditions-and-atomic-mixed-writes.md (master plan 8); the
read-side and write-side extensions are disjoint operations on the same GADT, so
coordinate constructor naming but nothing else.

The check evaluation state (memo table, visited set, depth budget in
`en-core/src/En/Check.hs`) is reshaped by EP-39 (probe-first paths), EP-40
(cycle-as-empty, short-circuit union), EP-41 (what gets memoized: a context-free
decision plus residual caveat obligations), and EP-44 (configurable budgets replace the
`maxDepth`/`pageLimit` constants). Later plans in that order own reconciling with
earlier ones.

`EnError` (`en-core/src/En/Error.hs`) is extended by EP-40 (distinct "cycle detected" vs
"depth exceeded" — both currently collapse into `ResolutionLimitExceeded`). EP-42
decided to reuse the existing `InvalidConsistencyToken` error for cursor-validation
failures, since its cursors literally carry a consistency token (see EP-42's Decision
Log) — no new constructor there. The wire mapping of the new EP-40 constructors belongs
to docs/plans/35-version-the-wire-contract-and-type-the-error-model.md (master plan 6);
whichever lands second wires the new constructors into the error envelope.

The lookup cursor codec (`en-core/src/En/Lookup.hs`, currently raw revision text) is
redefined by EP-42 to carry a validated token. The service layer
(`en-servant/src/En/Servant/API.hs`) passes cursors opaquely, so no wire change is
expected, but docs/plans/52-add-a-lookup-subjects-api.md (master plan 9) should reuse
EP-42's cursor discipline for its own paging.

Engine configuration (EP-44's budget record) is constructed in `en-server/app/Main.hs`
and the `en-servant` seam defaults; it must slot into the server configuration record
established by docs/plans/38-validate-configuration-and-persist-datastore-identity.md
(master plan 6) if that has landed.


## Progress

- [x] EP-39 (2026-07-08): point-membership probe on TupleStore with all three interpreters
- [x] EP-39 (2026-07-08): check answers direct membership without full-relation scans; wide-relation checks no longer error
- [x] EP-40 (2026-07-08): data cycles yield empty results, not failures; union short-circuits on Allowed
- [x] EP-40 (2026-07-08): exclusion over a Conditional base evaluates the subtrahend; checkMany surfaces per-pair errors
- [ ] EP-41: decision cache keyed without caveat context; caveats re-applied on hit; cross-request hit rate demonstrated
- [ ] EP-42: lookup pages resume incrementally from cursors instead of recomputing the traversal
- [ ] EP-42: cursors validated like consistency tokens; deadline interrupts expansion
- [ ] EP-43: expand tree preserves union/intersection/exclusion operators end-to-end to the wire
- [ ] EP-44: depth/page/result budgets configurable per engine; constants deduplicated
- [ ] EP-44: EntryPoint machinery wired to a consumer or relocated; hot-path allocation fixes benchmarked


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

**EP-44's `EntryPoint` question has a partial answer already (2026-07-08).** EP-39 needed
"does this relation union in its directly-stored tuples?" and answered it by walking the
`Rewrite` tree (`relationUnionsThis`), not by consulting the reachability graph's unused
`EntryPoint` machinery. That is one more consumer that could have adopted `EntryPoint` and
did not, which is evidence for relocating or deleting it rather than wiring it up. EP-44
should weigh that when it makes the call.


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


## Outcomes & Retrospective

(To be filled during and after implementation.)


---

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
