---
id: 40
slug: adopt-zanzibar-cycle-and-exclusion-semantics-in-check
title: "Adopt Zanzibar cycle and exclusion semantics in check"
kind: exec-plan
created_at: 2026-07-07T15:24:51Z
intention: intention_01kx2cmexke9mv9aggb7jf7w5t
master_plan: "docs/masterplans/7-fix-the-en-evaluation-engine.md"
---

# Adopt Zanzibar cycle and exclusion semantics in check

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`en` (縁) answers authorization questions over a graph of relationship tuples. Its
forward evaluator, `check` in `en-core/src/En/Check.hs`, currently gets three pieces of
*semantics* wrong on legal data (findings B3, B4, B5 of
`docs/reviews/2026-07-07-architecture-performance-review.md`):

- **B3 — data cycles poison unrelated branches.** Two groups that contain each other are
  perfectly legal data. But when the evaluator revisits a subproblem it has already
  entered, it returns the error `ResolutionLimitExceeded`, and because a union combines
  its branches with `sequence` (fail on first error), one cyclic branch converts the
  entire check into an error — even when another branch already proved `Allowed`.
  Zanzibar's semantics is that a revisited subproblem simply contributes **no members**
  (an empty result). Unions also never short-circuit: a check keeps evaluating branches
  after one has already answered `Allowed`.
- **B4 — exclusion over a conditional base never evaluates the subtrahend.** For a
  permission `member - banned` ("member but not banned"), if `member` evaluates to
  `Conditional` (a caveat needs more context) the evaluator returns `Conditional`
  immediately. If the subject is unconditionally `banned`, the true answer is `Denied` —
  the current answer tells a provably-banned subject "supply more context and you may
  pass", a false conditional.
- **B5 — `checkMany` erases errors.** The batch entry point maps every per-pair error
  (unknown relation, store failure, depth exceeded) to `Denied`. Fail-closed is the right
  default for a decision, but callers cannot distinguish "denied" from "the evaluation
  broke", and the signature silently dropped the `Error EnError` capability that single
  `check` has.

After this plan: a subject with access through *any* union branch gets `Allowed` even if
another branch's data is cyclic; a purely cyclic path yields `Denied` (not an error); a
union stops work at its first unconditional `Allowed`; exclusion evaluates the subtrahend
whenever the base is not `Denied`, so a banned subject is `Denied` even when the base was
conditional; `checkMany` returns a per-pair `Either EnError CheckDecision` so transports
can distinguish outages from denials while still failing closed on the wire; and
`EnError` distinguishes a detected graph cycle from an exhausted depth budget. Each of
these is demonstrated by a conformance-style test that fails on today's tree.


## Progress

- [x] M0 (2026-07-08): baseline — `cabal build all && cabal test all` green across seven
  suites; EP-39 has landed, so only the memoized evaluator family exists. Cited symbols
  re-located (line numbers shifted); see Surprises & Discoveries.
- [x] M1 (2026-07-08): failing tests — mutual-group cycle answered via an unrelated union
  branch; cycle-only path returns Denied; exclusion-over-conditional returns Denied; red
  output captured (commit `d056afa`).
- [x] M2 (2026-07-08): cycle-as-empty — revisited subproblems contribute `Denied`; new
  `CycleDetected` constructor on `En.Error.EnError`; `En.Expand` revisit reports
  `CycleDetected`. Landed in commit `8e31363`.
- [x] M2a (new milestone, discovered during M2): cut-taint propagation. Not memoizing the
  revisited subproblem is insufficient — its *ancestors* poison the memo and the
  cross-request cache. See Surprises & Discoveries.
- [x] M3 (2026-07-08): union short-circuit on the first unconditional `Allowed`, and the
  free `Denied` short-circuit for intersections, via one `evalBranchesMemo` helper.
  Landed in commit `8e31363`.
- [x] M4 (2026-07-08): sound exclusion — `Decision.exclusionDecisions` two-argument
  combinator; `Exclusion` evaluation uses it; subtrahend evaluated for `Conditional`
  bases. Landed in commit `8e31363`.
- [x] M5 (2026-07-08): `checkMany` returns per-pair `Either EnError CheckDecision`;
  en-servant batch handler and tests updated, wire behavior unchanged and fail-closed
  (commit `acad9ff`). The `Error EnError` constraint was *not* restored — it is redundant;
  see the Decision Log.
- [x] Final (2026-07-08): full suite green (seven suites); benchmarks run; Outcomes
  filled; master plan Progress rows and Registry updated.


## Surprises & Discoveries

**M2 — "do not memoize the revisited result" is not enough, and the gap is a correctness
bug that reaches the cross-request cache.** This plan's M2 step 2 says: change the revisit
branch to `pure (Right Denied, memo)` and "do **not** insert the revisited result into the
memo", calling it "the classic fixpoint-vs-memo trap". The diagnosis is right and the
prescription is incomplete. The revisit branch never inserted anything into the memo in the
first place — it returns before reaching the insert. The values that get poisoned are the
**ancestors** of the cut, whose results were computed *using* the cut's `Denied`.

A minimal witness, now the fixture `taintSchema` in `en-core/test/Main.hs`:

```haskell
node#direct = this                       -- carol is granted directly
node#x      = union [computed y, computed direct]
node#y      = computed x
```

Evaluate `(carol, x, node:n)`. Entering `x` pushes it onto `visited`; branch one descends
into `y`, which computes `x` again, hits the revisit guard, and cuts to `Denied`. So `y`
evaluates to `Denied` — true only while `x` is on the stack. Branch two then grants, and
`x` is `Allowed`. But `y = Denied` has been written to the memo. Now the second pair of the
same `checkMany` batch asks `(carol, y, node:n)`: the memo answers `Denied`, and the true
answer is `Allowed` (via `x`). The batch returns `[Allowed, Denied]`.

Worse, `checkCached` runs `insertExternalDecision` on the same path, so the stack-local
`Denied` is written into the process-wide decision cache keyed by
`(datastore, schema hash, revision, subject, relation, object, context)` and served to
*later requests*. A legal cycle in customer data would silently deny a subject who has
access, until the cache expired.

The fix, added as milestone M2a: evaluation reports whether its subtree consumed a cut. The
type is a two-valued `CutTaint` monoid in `en-core/src/En/Check.hs`; every `eval*Memo`
function returns it alongside the decision and memo, branch folds accumulate it, and
`evalRelationMemo` writes to the memo and the external cache only when the result is
`Untainted`. A cut itself returns `Tainted`; a memo or cache *hit* returns `Untainted`,
because anything already stored is context-independent by construction. This is
conservative — it declines to memoize some results that would have been fine — and
correctness beats a cache hit rate on cyclic data.

The test earns its keep by mutation. The obvious test to write here (mutual groups `a`/`b`
with `carol` granted directly on the document) **passes even with the guard removed**,
because memo keys include the subject and the two batch pairs used different subjects. That
version was written, observed to pass against a deliberately broken evaluator, and thrown
away. The `taintSchema` fixture above was built specifically so both pairs share a subject
and differ only in relation. Verified both ways:

```text
with the guard:     Right [Right Allowed, Right Allowed]
guard removed:      Right [Right Allowed, Right Denied]
```

Handed forward: docs/plans/41-cache-context-free-check-subproblems.md reshapes exactly this
memoize-and-cache path. It must preserve the `Untainted` precondition on both writes. A
context-free decision derived under a cut is no safer to cache than a context-bearing one.

**M0 — EP-39 has landed, so this plan edits one evaluator, not two.** The plan is written
to work either way ("make each semantic edit in both evaluator families" if EP-39 had not
landed). It has: `runCheck`, `evalRelation`, `evalRewrite`, `evalThis`, and
`evalTupleToUserset` are gone, and `check`/`checkCached`/`checkMany` all drive
`evalRelationMemo`. Every semantic edit below is made once. Current locations, since line
numbers moved:

- Cycle-as-error: `evalRelationMemo`'s revisit guard, `en-core/src/En/Check.hs:231`; the
  depth guard is `:229`, and `evalThisMemo` carries a second depth guard at `:377`.
- Union via `sequence`: the `Union` case of `evalRewriteMemo`, built eagerly by
  `evalRewriteListMemo`.
- Exclusion early return: the `Exclusion` case of `evalRewriteMemo`.
- `checkMany` error erasure: `either (const Denied) id result` in `evaluateDistinct`.
- `En.Expand` revisit guard: `en-core/src/En/Expand.hs:137` (depth guard at `:135`).
- The one `check`-side test asserting the old cycle semantics is
  "recursive graph respects depth limit" (`en-core/test/Main.hs:429`), exactly as the plan
  predicted.

**M0 — `EnError` is consumed by an exhaustive match, so `CycleDetected` is not a free
addition.** This plan's Context section says `CycleDetected` "surfaces via the existing
(untyped) 500 mapping in `en-servant/src/En/Servant/Seam.hs`, which is acceptable in the
interim". That is no longer true: `enErrorToFault` (`en-servant/src/En/Servant/Seam.hs`)
is a total `\case` over every constructor, added by master plan 6's EP-35 ("give every
error a stable code and an honest status"). Adding a constructor is therefore a compile
error in `en-servant`, not a silent fall-through, and this plan must supply a mapping. It
does — see the Decision Log entry dated 2026-07-08. The compiler catching this is the
system working as intended; the plan's prose was simply written against an older tree.

**M5 — the `Error EnError` constraint this plan wanted to restore is redundant, and GHC
says so.** The Decision Log dated 2026-07-07 says `checkMany` "regains the
`Error EnError :> es` constraint for failures *before* per-pair evaluation begins
(consistency resolution)". Adding it produces:

```text
src/En/Check.hs:107:5: warning: [GHC-30606] [-Wredundant-constraints]
    Redundant constraint: Error EnError :> es
```

The reasoning behind the constraint was wrong. `checkMany` does not raise anything:
`resolveConsistency` is a `ConsistencyStore` operation returning a plain
`ResolvedConsistency`, and it is the *interpreter* (for instance
`runConsistencyStorePostgres`) that throws on an invalid token. The batch aborts because
the interpreter throws, not because `checkMany` has the capability to. `en-core` compiles
with `-Wredundant-constraints`, so the constraint would be permanent noise. Omitting it is
also the better contract: a function whose job is to report per-pair errors *as values*
should not demand an error capability from its caller. The constraint was dropped and the
haddock says why.

**M2/M3/M4 landed as one commit rather than three.** The plan's Idempotence section asks for
separate commits in order, noting that "M2 before M3 matters: short-circuiting is only
provably safe once cycles stop erroring". That ordering argument is sound and was honored
in the *reasoning* — union short-circuiting is justified in the code comment by cycles no
longer producing `Left`. But the three edits turned out to occupy the same lines: threading
`CutTaint` (M2a) rewrote every branch of `evalRewriteMemo`, which is precisely where the
union fold (M3) and the exclusion case (M4) live. Splitting them would have meant writing
the taint threading twice and landing an intermediate tree whose only distinction was
cosmetic. They are one commit, `8e31363`, with a message that separates the three concerns.
M1 and M5 are their own commits, as planned.

**M0 — EP-39 left one semantic question on this plan's desk.** EP-39's probe-first `This`
evaluation returns early on an unconditional `Allowed`, which means a relation containing
both an unconditional grant and a row whose caveat name is undefined in the schema now
answers `Right Allowed` where the pre-EP-39 evaluator answered
`Left (UnknownRelation "unknown caveat: …")` — `sequence` used to fail on the first `Left`
anywhere in the decision list. EP-39 recorded this and deferred the call to this plan,
which owns error taxonomy. Resolved in the Decision Log (2026-07-08): the early return is
correct and this plan generalizes rather than reverts it.


## Decision Log

- Decision: Keep the existing `ResolutionLimitExceeded` constructor with its existing
  name and arity, narrowed in meaning to "a configured evaluation budget (depth, breadth)
  was exhausted", and add a **new** constructor `CycleDetected Text` to
  `En.Error.EnError` for "the traversal re-entered a subproblem it is already inside".
  In `check`, a revisited subproblem no longer errors at all (it contributes an empty
  result), so `CycleDetected` is raised only where reporting a cycle is the honest
  answer: `En.Expand`'s revisit guard. A reason-field redesign of
  `ResolutionLimitExceeded` was rejected.
  Rationale: changing the constructor's arity would touch every pattern match and test
  assertion for zero behavioral gain, and the reason field would be dead in `check` once
  cycles stop erroring. Two constructors give the review's requested distinguishability
  ("EnError cannot distinguish 'depth exceeded' from 'cycle detected'") with minimal
  churn. The wire mapping of `CycleDetected` belongs to
  docs/plans/35-version-the-wire-contract-and-type-the-error-model.md per the master
  plan's integration points — this plan only adds the constructor.
  Date: 2026-07-07
- Decision: In `check`, a revisited subproblem evaluates to `Denied` (the empty
  contribution) — not to `Conditional`, and not skipped-with-a-marker.
  Rationale: Zanzibar semantics: the fixpoint of a membership recursion assigns a cycle
  no members; `Denied` is `Decision.union`'s identity, so a cyclic branch simply drops
  out of unions, and in intersections it correctly forces `Denied` (a cycle proves no
  membership evidence). `En.Lookup` already does exactly this (`en-core/src/En/Lookup.hs`
  line ~239 returns `Right []` on revisit), so check and lookup finally agree.
  Date: 2026-07-07
- Decision: Union branches evaluate left-to-right and stop at the first **unconditional**
  `Allowed`; a `Left` (real error) from a branch evaluated *before* any `Allowed` still
  fails the whole check.
  Rationale: `Decision.unionDecisions` (`en-core/src/En/Decision.hs` lines 37–49) makes
  `Allowed` absorbing — `union [Conditional o, Allowed] = Allowed` and
  `union [Conditional o, Denied] = Conditional o` — so stopping early on `Allowed`
  cannot change any answer, only skip work. Continuing past a genuine error (store
  failure, unknown relation) in the hope a later branch allows would turn outages into
  data-dependent answers; fail-fast keeps errors loud. With cycles no longer erroring
  (M2), the only remaining branch errors are genuine.
  Date: 2026-07-07
- Decision: Exclusion gets a real two-argument combinator in `en-core/src/En/Decision.hs`
  — `exclusionDecisions base subtrahend` — with this table: base `Denied` → `Denied`
  (subtrahend not evaluated; short-circuit retained); base `Allowed` with subtrahend
  `Allowed`/`Denied`/`Conditional o` → `Denied`/`Allowed`/`Conditional o`; base
  `Conditional o` with subtrahend `Allowed` → `Denied`, subtrahend `Denied` →
  `Conditional o`, subtrahend `Conditional o'` → `Conditional (o <> o')`, deduplicated.
  Subtract-side obligations are passed through **without a negation marker**.
  Rationale: the missing case is exactly B4 — a conditional base must not suppress an
  unconditional subtraction. The obligation model (`CaveatObligation` = caveat name +
  missing context names) has no way to express "this caveat must evaluate *false*";
  `Conditional` means "supply the missing context and re-evaluate", which remains true
  and safe (the re-evaluation with full context takes this new code path and lands on
  `Denied`/`Allowed` correctly). Adding a negation marker is a wire-visible model change,
  out of scope; recorded here so docs/plans/35 and API consumers know the limitation.
  The one-argument `exclusionDecision`/`exclusion` stays exported (it is the
  base-`Allowed` column) to avoid breaking callers, with a haddock pointing to the new
  combinator.
  Date: 2026-07-07
- Decision: `checkMany` returns `[Either EnError CheckDecision]` (input order preserved,
  one entry per input pair) and regains the `Error EnError :> es` constraint for
  failures *before* per-pair evaluation begins (consistency resolution). The en-servant
  batch handler maps `Left _` to `DeniedWire` for now, preserving today's fail-closed
  wire behavior byte-for-byte.
  Rationale: the engine must not destroy information the transport might want;
  the wire error channel for batches (per-pair error codes) is
  docs/plans/35's decision to make, and whichever of these plans lands second wires the
  new constructors/channel into the envelope. A dedicated result record was rejected as
  premature — `Either` is sufficient and standard.
  Date: 2026-07-07
- Decision (2026-07-08, during M2): A decision computed with the help of a cycle cut is
  returned but never memoized and never written to the cross-request decision cache.
  Evaluation threads a `CutTaint` monoid to track this.
  Rationale: the plan's "do not memoize the revisited result" addresses the wrong node. The
  cut's own frame never reaches the memo insert; its *ancestors* do, carrying a `Denied`
  that is true only while the cut node sits on the `visited` stack. Left unguarded, a
  legal data cycle poisons later pairs of the same `checkMany` batch and — through
  `checkCached`'s `insertExternalDecision` — later *requests*. Conservative by design: some
  cacheable results go uncached on cyclic data. See Surprises & Discoveries for the witness
  and the mutation test that pins it.
  Date: 2026-07-08
- Decision (2026-07-08, during M5): `checkMany` does **not** regain the
  `Error EnError :> es` constraint, contrary to the 2026-07-07 entry below.
  Rationale: it raises nothing. Consistency-resolution failures escape through the
  `ConsistencyStore` interpreter's own error effect, not through `checkMany`, so the
  constraint is redundant — `-Wredundant-constraints` rejects it — and demanding an error
  capability from callers contradicts the point of returning per-pair errors as values.
  Date: 2026-07-08
- Decision (2026-07-08): `CycleDetected` maps to HTTP 422 with code `cycle_detected` and
  `retryable = false` in `en-servant/src/En/Servant/Seam.hs`, alongside
  `ResolutionLimitExceeded`'s 422.
  Rationale: this plan's prose assumed an untyped 500 fallback existed to absorb a new
  constructor. It does not — `enErrorToFault` is a total match (master plan 6's EP-35),
  so the compiler demands a mapping and the choice cannot be deferred to
  docs/plans/35-version-the-wire-contract-and-type-the-error-model.md. 422 is the honest
  status for both members of the pair: the request is well-formed, the caller is not at
  fault, retrying changes nothing, and the operation could not produce a result over this
  data. Retryability is `False` for the same reason it is for `ResolutionLimitExceeded`.
  Only `expand` can raise it, and only on genuinely cyclic data. docs/plans/35 may refine
  the code or envelope; it does not need to invent the mapping from nothing.
  Date: 2026-07-08
- Decision (2026-07-08): Keep EP-39's early return on an unconditional `Allowed` from the
  `This` probe, and extend the same principle to union branches (M3) rather than reverting
  it. A row with an undefined caveat name in a relation that also grants unconditionally
  therefore yields `Right Allowed`, not `Left (UnknownRelation …)`.
  Rationale: EP-39 deferred this to this plan because this plan owns error taxonomy. Two
  arguments settle it. First, consistency: M3 makes union stop at the first unconditional
  `Allowed`, so a malformed branch *after* a proven `Allowed` is already unobserved by
  design; it would be incoherent for a malformed *row* of one relation to behave
  differently from a malformed *branch* of one union. Second, meaning: the subject
  provably has access by a path that involves no caveat at all. Reporting a schema defect
  in an unrelated row of the same relation as the *answer* to an authorization question
  conflates "your data has a problem" with "you may not enter". The defect remains
  discoverable — the same check for a subject who depends on that row still errors, and
  schema validation catches undefined caveat names before any tuple can reference them.
  Noted for docs/plans/35: `check` is therefore not a total detector of schema defects,
  and never was.
  Date: 2026-07-08
- Decision: `En.Expand`'s revisit guard keeps *erroring* (now with `CycleDetected`)
  rather than adopting cycle-as-empty.
  Rationale: expand is an audit rendering — silently omitting a cyclic branch would hide
  data from a review UI, whereas check/lookup compute set membership where a cycle
  genuinely contributes nothing. Revisit docs/plans/43 if operator-preserving expand
  wants a dedicated cycle node instead.
  Date: 2026-07-07


## Outcomes & Retrospective

Landed 2026-07-08 in three commits (`d056afa`, `8e31363`, `acad9ff`) on `master`, with the
full workspace suite green and benchmarks running. Findings B3, B4, and B5 of
`docs/reviews/2026-07-07-architecture-performance-review.md` are closed.

The engine's semantics changed in four ways a user can observe. A subject with access
through any union branch is now `Allowed` even when another branch's data is cyclic; before,
one cycle turned the entire check into `ResolutionLimitExceeded`. A path that exists only
through a cycle is `Denied` rather than an error. `enter = allowed - banned` now denies a
provably banned subject even when the base needed more context, instead of replying
"supply more context and you may pass" — a false conditional that a caller acting on it
would have turned into wrongly-granted access. And `checkMany` tells its caller which pair
broke, rather than reporting every failure as a denial.

Two things landed that the plan did not ask for, and one thing the plan asked for did not
land.

The unrequested ones. First, cut-taint propagation (`CutTaint` in `en-core/src/En/Check.hs`)
— without it, cycle-as-empty is not merely incomplete but actively unsafe, poisoning the
within-batch memo and the cross-request decision cache with stack-local answers. This was
the single most valuable discovery of the plan and is written up at length in Surprises &
Discoveries. Second, a wire mapping for `CycleDetected` (422, `cycle_detected`, not
retryable), because `enErrorToFault` is a total match and the compiler would not let the
question be deferred to docs/plans/35 as the plan's prose assumed.

The thing that did not land: `checkMany` was not given back its `Error EnError` constraint.
It raises nothing, and `-Wredundant-constraints` says as much. The plan's rationale
confused "the batch aborts when consistency resolution fails" (true, via the interpreter)
with "checkMany throws" (false).

Method note, worth carrying into every later plan here. The first cut-taint regression test
passed against a deliberately broken evaluator. It looked right — mutual groups, a batch,
two pairs — but the memo key includes the subject, and its two pairs used different
subjects, so no memo entry was ever shared. It was only caught by removing the guard and
checking that the test went red. A test for a caching or memoization bug is worth nothing
until you have watched it fail. Both directions are recorded in Surprises & Discoveries.

Handed forward. docs/plans/41-cache-context-free-check-subproblems.md rewrites the exact
memoize-and-cache path this plan guarded; it must keep the `Untainted` precondition on both
writes, since a context-free decision derived under a cut is no safer to cache than a
context-bearing one. docs/plans/44-make-evaluation-budgets-configurable-and-trim-hot-path-overhead.md
inherits `evalBranchesMemo` (still `reverse`-ing an accumulator and threading a triple) and
`maxDepth`, which remains a module constant here. docs/plans/35-version-the-wire-contract-and-type-the-error-model.md
inherits a `CycleDetected` mapping it may refine, and the per-pair error channel that
`checkMany` now has the information to feed.

One limitation is recorded rather than fixed, as the Decision Log intended: subtract-side
obligations pass through un-negated, because `CaveatObligation` cannot express "this caveat
must evaluate false". `Conditional` keeps its plain meaning — supply the missing context and
re-evaluate — which stays true and safe, since the re-evaluation runs the same combinator
with a settled subtrahend. Expressing negated obligations is a wire-visible model change and
belongs to whoever wants it.


## Context and Orientation

You are in the `en` repository (working tree `/Users/shinzui/Keikaku/bokuno/en`; all
paths repository-relative), a Haskell Cabal multi-package project on GHC 9.12.4. This
plan is EP-40 of `docs/masterplans/7-fix-the-en-evaluation-engine.md` and fixes findings
B3, B4, B5 of `docs/reviews/2026-07-07-architecture-performance-review.md`. Everything
here lives in **`en-core`** (the pure engine package) except one small handler update in
**`en-servant`** (the HTTP layer).

Terms, defined plainly:

- **Tuple**: a stored fact `object#relation@subject` (`En.Tuple.Tuple`). A subject may be
  a **userset** `SubjectSet object relation` ("everyone with *relation* on *object*"),
  which is how a group can contain another group — and how legal cycles arise: tuple
  `group:a#member@group:b#member` plus tuple `group:b#member@group:a#member`.
- **Rewrite**: the expression defining a relation (`En.Schema.Rewrite`): `This` (stored
  tuples), `ComputedUserset`, `TupleToUserset` (arrow), `Union`, `Intersection`,
  `Exclusion base subtract`, `Caveated`.
- **`CheckDecision`** (`en-core/src/En/Decision.hs`): `Allowed`, `Denied`, or
  `Conditional [CaveatObligation]`. A `CaveatObligation` names a caveat and the context
  keys it still needs. The algebra: `unionDecisions` is `Allowed`-absorbing and merges
  obligations otherwise; `intersectionDecisions` is `Denied`-absorbing;
  `exclusionDecision` (one argument!) maps the *subtrahend's* decision to the result
  assuming the base was `Allowed`; `applyGate`/`applyDecisionGate` intersects a caveat
  gate with a decision.
- **Subproblem / visited set**: `check` recursion carries
  `EvalState { depth :: Int, visited :: [Subproblem] }` where
  `Subproblem = (subject, object, relation)` (`en-core/src/En/Check.hs` lines 139–149).
  Re-entering a subproblem already in `visited` is the cycle guard.
- **Memo**: independent of `visited`, evaluation results are memoized per
  `(revision, subproblem)` in a within-call `Map` (`MemoKey`, `CheckMemo`, lines
  152–157), shared across the pairs of one `checkMany` call.

Where the offending code is, on the current tree (if
docs/plans/39-add-a-point-membership-probe-and-probe-first-check-evaluation.md has
landed, the non-memoized twin functions named below are gone and only the `…Memo` family
remains — the edits are the same, made once):

- Cycle-as-error: `evalRelation` lines 179–183 and `evalRelationMemo` lines 271–275 both
  have `| subproblem `elem` state.visited = pure (Left ResolutionLimitExceeded, …)`. The
  depth guard (`state.depth >= maxDepth`, `maxDepth = 25` at line 163–164) shares the
  same error constructor — that conflation is the taxonomy gap.
- Union via `sequence`: `evalRewriteMemo` lines 342–345 (`Decision.union <$> sequence
  decisions`) and `evalRewrite` lines 473–475; the branch list is built eagerly by
  `evalRewriteListMemo` (lines 363–381), which evaluates *every* branch.
- Exclusion early-return: `evalRewriteMemo` lines 350–358 and `evalRewrite` lines
  479–487: `Right (Conditional obligations) -> pure (Right (Conditional obligations))` —
  the subtrahend is only evaluated for `Right Allowed`.
- `checkMany` error erasure: lines 96–117 — `either (const Denied) id result` — and its
  signature `(ConsistencyStore :> es, TupleStore :> es) => … -> Eff es [CheckDecision]`
  with no `Error EnError`.
- `En.Error.EnError` (`en-core/src/En/Error.hs`): six constructors today;
  `ResolutionLimitExceeded` is nullary.
- `En.Expand` revisit guard: `en-core/src/En/Expand.hs` lines 133–137
  (`Left ResolutionLimitExceeded` on revisit).
- Consumers of `checkMany`: the HTTP batch handler `batchCheckHandler` in
  `en-servant/src/En/Servant/API.hs` (lines 344–361, maps decisions with
  `decisionToWire`), the benchmark `en-core/bench/Main.hs` (`checkMany` group), and
  tests in `en-core/test/Main.hs` (assertions around lines 338–374, including
  "batch fails closed per pair").

Test conventions: `en-core/test/Main.hs` is a plain `IO` main with `assertEqual`-style
helpers and in-memory interpreters from `en-core/src/En/Conformance/Kikan.hs`
(`runTupleStoreInMemory tuples`, `runConsistencyStoreInMemory`, the `kikanSchema`
fixture built with `En.Schema.Builder`). Small purpose-built schemas are defined inline
in the test file (see `minLevelSchema`, `publicSchema`, `streamingSchema` there) — the
new conformance cases follow that pattern.

Integration points restated from the master plan so this plan stands alone:

- **Shared-file rebase order** on `en-core/src/En/Check.hs` is EP-39 → this plan (EP-40)
  → EP-41 (docs/plans/41-cache-context-free-check-subproblems.md). If EP-39 landed, this
  plan edits the unified memoized evaluator only; if not, make each semantic edit in both
  evaluator families and note it in Surprises & Discoveries. EP-41 will re-shape *what*
  is memoized/cached; this plan must not change memo keys or cache plumbing.
- **`EnError` extension** (`CycleDetected`) is this plan's; its HTTP mapping belongs to
  docs/plans/35-version-the-wire-contract-and-type-the-error-model.md — whichever lands
  second wires the constructor into the typed error envelope. Until then it surfaces via
  the existing (untyped) 500 mapping in `en-servant/src/En/Servant/Seam.hs`, which is
  acceptable in the interim.
- **`checkMany`'s richer result** is engine-internal for now; the batch wire response
  stays `[CheckDecisionWire]` with fail-closed `Denied` until docs/plans/35 adds a
  per-pair error channel.


## Plan of Work


### M0 — Baseline and drift check (no code)

Build and test the tree; read `en-core/src/En/Check.hs`, `en-core/src/En/Decision.hs`,
`en-core/src/En/Error.hs`, `en-core/src/En/Expand.hs`, and the `checkMany` call sites
listed above. Record in Surprises & Discoveries whether the EP-39 evaluator unification
is present (one evaluator family or two).

```bash
cabal build all
cabal test all
```

Acceptance: green baseline recorded.


### M1 — Failing conformance cases (red)

Scope: encode B3 and B4 as tests first. In `en-core/test/Main.hs`, add a small inline
schema and fixtures (kikan style, using `En.Schema.Builder`):

```haskell
cyclicSchema :: Schema
cyclicSchema =
    testSchemaOrError $ do
        userObject <- Schema.object "user" []
        group <-
            Schema.object
                "group"
                [ Schema.relation "member" [Schema.subject "user", Schema.userset "group" "member"] Schema.this ]
        doc <-
            Schema.object
                "doc"
                [ Schema.relation "viewer" [Schema.subject "user"] Schema.this
                , Schema.relation "team" [Schema.userset "group" "member"] Schema.this
                , Schema.permission "view" (Schema.anyOf (Schema.computed "team") [Schema.computed "viewer"])
                ]
        Schema.build [userObject, group, doc]
```

Fixtures: `group:a#member@group:b#member`, `group:b#member@group:a#member` (the mutual
cycle), `doc:d#team@group:a#member` (the cyclic branch is attached to the doc), and
`doc:d#viewer@user:carol` (the unrelated direct branch). Note the union order puts the
cyclic `team` branch **first**, so short-circuiting alone cannot mask a broken cycle
rule. Assertions:

```haskell
-- B3: an unrelated union branch must still answer, despite the cycle.
assertEqual "cycle does not poison an unrelated union branch"
    (Right Allowed)
    =<< check consistencyStore cyclicStore cyclicGraph MinimizeLatency requestContext
            (SubjectId carol) (RelationName "view") docD

-- B3: a path that only exists through the cycle is a denial, not an error.
assertEqual "cycle-only path returns Denied, not an error"
    (Right Denied)
    =<< check consistencyStore cyclicStore cyclicGraph MinimizeLatency requestContext
            (SubjectId dave) (RelationName "view") docD
```

(`dave` has no tuples at all; his only route is through the cyclic groups.) For B4, add
an exclusion schema: `permission enter = allowed - banned`, where `allowed` is a plain
relation whose grant tuple carries a caveat (reuse the kikan `within_autonomy` caveat and
`autonomyCaveat` payload from `En.Conformance.Kikan`), and `banned` is uncaveated.
Fixtures: `room:r#allowed@user:erin` (caveated), `room:r#banned@user:erin`. Assertion,
using `missingAutonomyContext` (which makes the base `Conditional`):

```haskell
-- B4: an unconditional ban must beat a conditional base.
assertEqual "exclusion over conditional base evaluates the subtrahend"
    (Right Denied)
    =<< check consistencyStore roomStore roomGraph MinimizeLatency missingAutonomyContext
            (SubjectId erin) (RelationName "enter") roomR
```

Run and capture the red output:

```bash
cabal test en-core:en-core-interface-tests
```

Acceptance: the two cycle assertions fail with `Left ResolutionLimitExceeded`, the
exclusion assertion fails with `Right (Conditional […])`; everything pre-existing passes.
Paste the failures into Concrete Steps.


### M2 — Cycle contributes an empty result; error taxonomy

Scope: the revisit branch and the new constructor.

1. `en-core/src/En/Error.hs`: add, with haddocks matching the file's style:

   ```haskell
   | -- | The traversal re-entered a subproblem it is already evaluating
     -- (a relationship cycle). check treats cycles as empty results and
     -- never raises this; expand reports it because omitting a cyclic
     -- branch would silently hide data from an audit view.
     CycleDetected Text
   ```

   Keep `ResolutionLimitExceeded` and update its haddock to say "depth/breadth budget
   exhausted" explicitly.

2. `en-core/src/En/Check.hs`: in `evalRelationMemo` (and `evalRelation` if the non-memo
   family still exists), change the revisit branch from
   `pure (Left ResolutionLimitExceeded, memo)` to `pure (Right Denied, memo)`. Do **not**
   insert the revisited result into the memo — `Denied`-on-revisit is true only *inside*
   the current recursion stack; memoizing it would let a stack-local answer leak into
   sibling branches where the subproblem is genuinely evaluable. (This is the classic
   fixpoint-vs-memo trap; write this as a comment at the branch.) The depth branch is
   unchanged.

3. `en-core/src/En/Expand.hs` line ~136: change the revisit branch to
   `pure (Left (CycleDetected (renderSubproblem subproblem)))` with a tiny local
   `renderSubproblem` producing e.g. `"space:recursive-space#view"`. The depth branch
   keeps `ResolutionLimitExceeded`.

4. Tests: the M1 cycle assertions go green. Check the existing assertion
   `"recursive graph respects depth limit"` (`en-core/test/Main.hs` line ~407): it uses a
   `recursiveTupleStore` where a space is its own parent. Trace it: the arrow
   `parent->view` re-enters `(user, recursive-space, view)` — with cycle-as-empty this
   now returns `Right Denied` instead of `Left ResolutionLimitExceeded`. **That is the
   intended new semantics**: update the assertion to expect `Right Denied` and rename its
   label to "self-parent cycle yields Denied via cycle-as-empty". To keep a live guard on
   the depth budget, add a non-cyclic deep-chain fixture (26 distinct spaces each the
   parent of the next — deeper than `maxDepth = 25`) and assert that checking the deepest
   one yields `Left ResolutionLimitExceeded`. Also update the expand-side expectation if
   any test asserted expand's revisit error (search the test file for
   `ResolutionLimitExceeded`).

Commands and acceptance:

```bash
cabal test en-core:en-core-interface-tests
cabal test en-core:en-core-conformance
```

M1's cycle tests pass; the reworked depth test passes; nothing else regresses.


### M3 — Union short-circuits on the first unconditional Allowed

Scope: stop paying for branches that cannot change the answer. In
`en-core/src/En/Check.hs`, replace the `Union` case's use of `evalRewriteListMemo` +
`sequence` with a short-circuiting fold (and delete `evalRewriteListMemo` if
`Intersection` is its only remaining caller — `Intersection` keeps evaluating all
branches, since `Denied` there is absorbing but conditional/obligation merging needs the
rest; an analogous `Denied` short-circuit for intersections is a free, safe bonus —
implement both with one helper):

```haskell
-- Evaluate union branches left-to-right. Stop at the first unconditional
-- Allowed (union is Allowed-absorbing: union of Conditional and Allowed is
-- Allowed; union of Conditional and Denied is Conditional — see
-- Decision.unionDecisions). A Left before any Allowed fails the check:
-- with cycles contributing Denied (M2), a Left is a genuine failure.
evalUnionMemo cacheOps graph context revision subject object relation rewrites state memo =
    go [] memo rewrites
  where
    go acc currentMemo [] = pure (Right (Decision.union (reverse acc)), currentMemo)
    go acc currentMemo (rewrite : rest) = do
        (result, memo') <- evalRewriteMemo cacheOps graph context revision subject object relation rewrite state currentMemo
        case result of
            Left err -> pure (Left err, memo')
            Right Allowed -> pure (Right Allowed, memo')
            Right decision -> go (decision : acc) memo' rest
```

Wire `Union rewrites -> evalUnionMemo …` in `evalRewriteMemo` (and the non-memo twin if
present). Semantics note to keep in the code comment, grounded in
`en-core/src/En/Decision.hs`: `unionDecisions` returns `Allowed` if any input is
`Allowed`; otherwise `Conditional` with merged, deduplicated obligations if any input is
conditional; otherwise `Denied`. The fold above reproduces exactly that on the prefix it
evaluates, and the skipped suffix can only have produced values that `Allowed` absorbs.

Tests: add a counting-store assertion (helper `countingTupleStore` exists in
`en-core/test/Main.hs`): for the kikan permission `view` (a five-branch union whose first
branch is `owner`), checking the owner (`user` on `space`) after M3 must issue strictly
fewer reads than the M0-recorded count for the same check, and still return `Allowed`.
Also assert order-independence of answers: `carol`'s M1 check stays `Allowed` when the
cyclic branch is first (it contributes `Denied` from M2, then the direct branch
short-circuits — proving the two mechanisms compose).

```bash
cabal test en-core:en-core-interface-tests
```


### M4 — Sound exclusion algebra

Scope: the decision combinator and the evaluator case.

1. `en-core/src/En/Decision.hs`: add and export

   ```haskell
   -- | Combine a base decision with its subtrahend ("base minus subtract").
   -- The subtrahend matters whenever the base is not Denied: an
   -- unconditionally Allowed subtrahend forces Denied even over a
   -- Conditional base. Subtract-side obligations pass through un-negated:
   -- Conditional still means "supply the missing context and re-evaluate".
   exclusionDecisions :: CheckDecision -> CheckDecision -> CheckDecision
   exclusionDecisions base subtrahend =
       case (base, subtrahend) of
           (Denied, _) -> Denied
           (_, Allowed) -> Denied
           (Allowed, Denied) -> Allowed
           (Allowed, Conditional obligations) -> Conditional obligations
           (Conditional obligations, Denied) -> Conditional obligations
           (Conditional base', Conditional subtract') ->
               Conditional (dedupeObligations (base' <> subtract'))
   ```

   Keep `exclusionDecision`/`exclusion` (one-argument) exported with a haddock note that
   it assumes an `Allowed` base and that evaluators should use `exclusionDecisions`.

2. `en-core/src/En/Check.hs`, the `Exclusion base subtractRewrite` case of
   `evalRewriteMemo` (and twin): keep the base-`Denied` early return (short-circuit is
   still sound — `exclusionDecisions Denied _ = Denied`), but for **both** `Allowed` and
   `Conditional` bases evaluate the subtrahend and combine with
   `Decision.exclusionDecisions baseDecision <$> subtractDecision`. Errors from the
   subtrahend propagate as today.

3. Check the other evaluators for the same hole: `En.Lookup`'s exclusion path
   (`en-core/src/En/Lookup.hs` `Exclusion` case, line ~288) confirms candidates by
   calling `check` per candidate, so it inherits the fix automatically — note that in
   Surprises & Discoveries after verifying with the M4 test below run through lookup.

Tests: the M1 exclusion assertion goes green. Add the complementary cases: base
`Conditional` + subtrahend `Denied` stays `Conditional` (same fixtures, subject not
banned); base `Conditional` + subtrahend `Conditional` merges both obligations (ban tuple
also caveated); and the pre-existing kikan cases
"exclusion allows member who is not owner" / "exclusion rejects owner"
(`en-core/test/Main.hs` lines ~336–337) still pass. Add a lookup-level assertion that
`member_not_owner` lookup for a conditionally-membered, unconditionally-owned subject
omits the object.

```bash
cabal test en-core:en-core-interface-tests
```


### M5 — checkMany surfaces per-pair errors

Scope: the batch entry point and its consumers.

1. `en-core/src/En/Check.hs`: change the signature to

   ```haskell
   checkMany ::
       (ConsistencyStore :> es, TupleStore :> es, Error EnError :> es) =>
       ReachabilityGraph ->
       Consistency ->
       CaveatContext ->
       [BatchPair] ->
       Eff es [Either EnError CheckDecision]
   ```

   Internally, drop the `either (const Denied) id` collapse: store each pair's
   `Either EnError CheckDecision` and return them in input order (duplicate pairs share
   one evaluation through the memo exactly as today; the default for a pair missing from
   the map — impossible by construction — stays `Right Denied` fail-closed). Update the
   haddock: consistency resolution failures abort the whole batch via `Error EnError`
   (they are request-level, not pair-level); per-pair evaluation failures are `Left`
   entries.

2. `en-servant/src/En/Servant/API.hs`, `batchCheckHandler`: map results with
   `either (const DeniedWire) decisionToWire`, with a comment: fail-closed on the wire
   until docs/plans/35-version-the-wire-contract-and-type-the-error-model.md adds a
   per-pair error channel; the engine now preserves the information for it.

3. `en-core/bench/Main.hs` (`checkMany` group) and `en-core/test/Main.hs` batch
   assertions: adjust expected values from `Right [Allowed, …]` to
   `Right [Right Allowed, …]`. Rework the existing test
   "batch fails closed per pair" (line ~374, using `erroringTupleStore`): it now asserts
   the *engine* result is `[Right Allowed, Left (StoreError …), Right Denied]` — the
   erroring pair is a visible `Left`, the healthy pairs unaffected — and add an
   en-servant test (in `en-servant/test/Main.hs`, which already drives
   `batchCheckHandler` directly) asserting the wire response for that shape is still
   `[AllowedWire, DeniedWire, DeniedWire]`.

```bash
cabal build all
cabal test en-core:en-core-interface-tests
cabal test en-servant:en-servant-tests
```

Acceptance: engine batch results carry `Left` for the broken pair; wire behavior is
byte-identical to before.


### Final — wrap-up

Full suite, Outcomes & Retrospective, tick the EP-40 rows in
`docs/masterplans/7-fix-the-en-evaluation-engine.md`, Revision Note at the bottom here.

```bash
cabal build all
cabal test all
```


## Concrete Steps

All commands from the repository root `/Users/shinzui/Keikaku/bokuno/en`.

```bash
cabal build all
cabal test all                                  # M0 baseline
cabal test en-core:en-core-interface-tests      # M1..M5 inner loop
cabal test en-core:en-core-conformance          # semantics guard
cabal test en-servant:en-servant-tests          # M5 wire guard
```

Expected M1 red output (shape produced by the test file's assert helpers):

```text
cycle does not poison an unrelated union branch
expected: Right Allowed
actual:   Left ResolutionLimitExceeded

exclusion over conditional base evaluates the subtrahend
expected: Right Denied
actual:   Right (Conditional [CaveatObligation {caveat = CaveatName "within_autonomy", missingContext = ["requested_autonomy"]}])
```

The real transcripts, recorded while working.

M1, red (`cabal test en-core:en-core-interface-tests`). The suite stops at the first
failure, so the cycle assertion is what it printed; the exclusion assertions were red
underneath it and turned green with the same commit:

```text
user error (cycle does not poison an unrelated union branch
expected: Right Allowed
actual:   Left ResolutionLimitExceeded)
```

The cut-taint mutation test (M2a). With the `Untainted` guard on the memo write removed,
the batch regresses; with it, the batch is correct. This is the evidence that the guard is
load-bearing rather than decorative:

```text
guard removed:  user error (a cycle-tainted decision is not memoized across batch pairs
                expected: Right [Right Allowed,Right Allowed]
                actual:   Right [Right Allowed,Right Denied])

guard restored: PASS
```

M3's counting-store number. The kikan permission `space#view` is a five-branch union whose
first branch is `owner`; checking the owner now issues exactly one store read (EP-39's
probe on `owner`), because the union stops there:

```text
union stops at the first branch that proves Allowed: 1 store read
```

Everything green at the end (`cabal test all`):

```text
Test suite en-biscuit-tests: PASS
Test suite en-core-conformance: PASS
Test suite en-core-interface-tests: PASS
Test suite en-example-tests: PASS
Test suite en-postgres-integration-tests: PASS
Test suite en-postgres-revision-tests: PASS
Test suite en-servant-tests: PASS
```

The benchmarks still run, unchanged in shape by this plan
(`cabal bench en-core:en-core-bench`, `check-wide` group):

```text
direct-member:  25.2 μs ± 2.2 μs
non-member:      343 μs ±  33 μs
```


## Validation and Acceptance

1. **B3 cycles**: with mutual groups `a`/`b` and the cyclic branch listed *first* in the
   union, `check carol view doc:d` returns `Right Allowed` and
   `check dave view doc:d` returns `Right Denied`. Both are `Left
   ResolutionLimitExceeded` before this plan. A 26-deep acyclic chain still returns
   `Left ResolutionLimitExceeded` (depth budget intact), and `En.Expand` on a cyclic
   object reports `Left (CycleDetected …)` — the two failure modes are now distinct
   constructors in `En.Error.EnError`.
2. **Union short-circuit**: the counting-store assertion shows strictly fewer store
   reads for an owner's `view` check than the recorded pre-plan count, with the same
   `Allowed` answer. Documented interaction holds by construction:
   `union [Conditional o, Allowed] = Allowed`,
   `union [Conditional o, Denied] = Conditional o` (asserted directly against
   `Decision.unionDecisions` in a pure test).
3. **B4 exclusion**: `enter = allowed − banned` with a caveated `allowed` grant, missing
   context, and an unconditional ban returns `Right Denied` (was `Conditional`); without
   the ban it stays `Conditional`; with a caveated ban it is `Conditional` with both
   obligations, deduplicated.
4. **B5 checkMany**: for a batch where one pair's reads fail, the engine returns
   `[Right Allowed, Left (StoreError …), Right Denied]` in input order; the HTTP batch
   response is unchanged (`DeniedWire` for the failed pair); `checkMany` compiles with
   `Error EnError :> es` like `check`.
5. **No regressions**: `cabal test all` green, including the kikan conformance suite and
   the en-servant handler tests.


## Idempotence and Recovery

All commands are re-runnable; there are no migrations or destructive steps. Land the
milestones as separate commits in order (M2 before M3 matters: short-circuiting is only
provably safe once cycles stop erroring). The riskiest edit is M2's revisit change — if
an unexpected test regresses, first check whether it *encoded the old broken semantics*
(like the self-parent depth test) before assuming the edit is wrong; update the test only
with a Decision Log entry. `checkMany`'s signature change (M5) is compile-guarded: the
compiler lists every call site; do not suppress with wildcards.


## Interfaces and Dependencies

No new package dependencies anywhere.

End-state interfaces (full module paths):

- `En.Error.EnError` gains `CycleDetected Text`; `ResolutionLimitExceeded` remains,
  meaning budget exhaustion only. (Wire mapping deferred to docs/plans/35.)
- `En.Decision.exclusionDecisions :: CheckDecision -> CheckDecision -> CheckDecision`
  exported; existing `exclusionDecision`/`exclusion` retained with a clarifying haddock.
- `En.Check.checkMany :: (ConsistencyStore :> es, TupleStore :> es, Error EnError :> es)
  => ReachabilityGraph -> Consistency -> CaveatContext -> [BatchPair] -> Eff es [Either
  EnError CheckDecision]`.
- `En.Check` internals: revisit ⇒ `Right Denied` (never memoized); union evaluation via a
  short-circuiting fold; exclusion via `exclusionDecisions` with the subtrahend evaluated
  for non-`Denied` bases. Public signatures of `check`/`checkCached` unchanged.
- `En.Expand` revisit ⇒ `Left (CycleDetected …)`.
- `En.Servant.API.batchCheckHandler` maps per-pair `Left` to `DeniedWire` (interim,
  fail-closed) — the seam docs/plans/35 replaces.

Consumed from other plans: the unified evaluator and probe-first `evalThisMemo` from
docs/plans/39 (rebase target). Consumed by:
docs/plans/41-cache-context-free-check-subproblems.md (its residual-decision algebra must
reproduce `exclusionDecisions` exactly) and
docs/plans/44-make-evaluation-budgets-configurable-and-trim-hot-path-overhead.md (which
makes `maxDepth` configurable and optimizes the folds introduced here).

Two additions to the end state that this plan discovered rather than planned:

- `En.Check` threads a `CutTaint` value alongside the decision and memo. A decision whose
  subtree consumed a cycle cut is `Tainted` and is never written to the within-call memo or
  to the cross-request cache via `insertExternalDecision`.
  docs/plans/41-cache-context-free-check-subproblems.md rewrites both writes and must
  preserve that precondition.
- `En.Servant.Seam.enErrorToFault` maps `CycleDetected` to 422 / `cycle_detected` /
  `retryable = false`. It is a total match, so this could not be deferred.


---

Revision note (2026-07-08, written while implementing): Three corrections, all recorded in
Surprises & Discoveries and the Decision Log.

The important one: M2's instruction to avoid memoizing the revisited subproblem does not
prevent the bug it names. The revisit frame never reaches the memo insert; the *ancestors*
that consumed its `Denied` do, and they write a stack-local answer into the within-call
memo and — through `checkCached` — into the process-wide decision cache served to later
requests. Cycle-as-empty without taint propagation is worse than the erroring behavior it
replaces, because it fails silently. A new milestone (M2a) adds a `CutTaint` monoid and
withholds tainted decisions from both writes. The regression test for it was written twice:
the first version passed against a deliberately broken evaluator, because memo keys include
the subject and its two batch pairs used different subjects.

Second, `checkMany` does not regain the `Error EnError` constraint. It raises nothing;
consistency failures escape through the interpreter. GHC's `-Wredundant-constraints`
settles it.

Third, `CycleDetected` needed a wire mapping in this plan rather than in docs/plans/35: the
plan's Context section describes an untyped 500 fallback in `en-servant` that no longer
exists, since master plan 6's EP-35 made `enErrorToFault` total.

Also resolved here, on EP-39's referral: the probe's early return on an unconditional
`Allowed` stands, and M3 generalizes it to union branches. A relation holding both an
unconditional grant and a row with an undefined caveat name answers `Right Allowed`. The
alternative — letting a malformed row of an unrelated grant deny a subject who provably has
access — conflates "your data has a problem" with "you may not enter".
