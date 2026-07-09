---
id: 43
slug: preserve-set-operators-in-expand-trees
title: "Preserve set operators in expand trees"
kind: exec-plan
created_at: 2026-07-07T15:24:51Z
intention: intention_01kx2cmexke9mv9aggb7jf7w5t
master_plan: "docs/masterplans/7-fix-the-en-evaluation-engine.md"
---

# Preserve set operators in expand trees

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`en` (縁) offers **`expand`** (`en-core/src/En/Expand.hs`): given an object and a
permission, return a tree describing *who* can reach it and *through what*. It exists
for review and audit UIs — "show me everyone with `audit` on this space, and why".
Today that tree is a lie by omission (finding B10 of
`docs/reviews/2026-07-07-architecture-performance-review.md`): the evaluator flattens
`Union`, `Intersection`, and `Exclusion` rewrites into one concatenated child list
(`expandRewrite`, `En/Expand.hs` lines 170–179), and the node type (`ExpandNode`, lines
57–61) has no operator constructors. Expanding a permission defined as
`owner ∩ member` produces the same shape as `owner ∪ member`: a flat list of subjects.
An audit UI cannot distinguish "needs **all** of these" from "**any** of these suffices"
from "these, **except** those" — which makes access review reach wrong conclusions.
That is a correctness problem, not a cosmetic one.

After this plan, `ExpandNode` has explicit operator nodes — union, intersection, and
exclusion (with its base and subtracted branches kept apart) — alongside the existing
caveat wrapper, the evaluator preserves them, the HTTP wire DTO
(`en-servant/src/En/Servant/API.hs`) carries them, and the tests assert them. The
observable acceptance: expanding the kikan fixture permission `space#audit` (defined in
the schema as the intersection `owner ∩ member`) returns, on the wire, an
**intersection node over its two branch subtrees** instead of a flat subject list.


## Progress

- [x] M0 (2026-07-09): baseline — `cabal build all` and `cabal test all` green before any
  edit; cited symbols confirmed, line numbers and the wire encoding drifted, and a fourth
  consumer found. Drift recorded in Surprises & Discoveries.
- [x] M1 (2026-07-09): failing tests captured for both `space#audit` and
  `space#member_not_owner` — each expands to two flat children where one operator node is
  required. Red transcripts in Concrete Steps.
- [x] M2 (2026-07-09): `ExpandNode` gains `ExpandUnion` / `ExpandIntersection` /
  `ExpandExclusion`; `expandRewrite` stops flattening via `unionNode` /
  `intersectionNode` / `asBranchNode`; en-core tree helpers recurse through the new nodes;
  pagination assertion reworked onto `exclusionSpace#member`.
- [x] M2 (2026-07-09): added `branchSchema`, a fixture whose intersection has a multi-node
  conjunct — without it every assertion in this plan is vacuous (see Surprises).
- [x] M3 (2026-07-09): `ExpandNodeWire` gains the three constructors under EP-35's `kind`
  vocabulary (`"union"`, `"intersection"`, `"exclusion"`); `expandNodeToWire`, `ToJSON`,
  `FromJSON`, the rejected-variant list, and `ToSchema` (OpenAPI) all extended; golden
  byte tests plus a handler-level byte-for-byte acceptance on `audited-space#audit`.
- [x] M2/M3 evidence (2026-07-09): both operator behaviours observed to fail against a
  deliberately broken evaluator — a concatenating `intersectionNode` and an exclusion that
  puts every child on the granting side. Transcripts in Concrete Steps.
- [ ] Final: full suite green; Outcomes filled; master plan progress row updated.


## Surprises & Discoveries

**The baseline is green (M0, 2026-07-09).** `cabal build all` and `cabal test all` both pass
on `ac24e0e` before any edit. This is worth stating because it is the first child of this
master plan for which it was true: EP-39 found the workspace red. The master plan's
full-workspace-suite rule is doing its job.

**docs/plans/35 landed first, inverting this plan's stated expectation (M0, 2026-07-09).**
The Decision Log predicted "if this plan lands first (expected — it is small)". It did not.
EP-35 is Complete in `docs/masterplans/6-*.md`, and it rewrote the wire layer this plan
must extend. Four consequences, all of which make M3 *different* rather than larger:

`ExpandNodeWire` is no longer a `Generic`-derived tagged sum emitting
`{"tag":"ExpandUsersetWire",…}`. It is a hand-written `ToJSON`/`FromJSON` pair using a
`kind` string discriminator with lowercase values (`"subject"`, `"userset"`, `"caveated"`),
at `en-servant/src/En/Servant/API.hs` lines 756–794. The file's own header comment states
the intent: every instance is hand-written "so that the wire shape is a reviewed artifact
rather than a side effect of generic derivation — which, for sum types, would leak Haskell
constructor names". The `Wire`-suffix leak this plan's Decision Log said EP-35 would
eliminate is already gone.

Per that Decision Log's own handshake ("**if docs/plans/35 lands first**, add the operator
nodes to its `/v1` vocabulary following its naming scheme"), the new JSON tags are
`"union"`, `"intersection"`, and `"exclusion"` — not `ExpandUnionWire` and friends. The
Haskell constructors keep the `…Wire` suffix to match their siblings; only the wire
spelling follows EP-35. The plan's proposed acceptance — "assert the encoded bytes contain
`ExpandIntersectionWire`" — is therefore both wrong and unnecessary: EP-35 supplies a
`golden` helper (`en-servant/test/Main.hs` line 530) that asserts *exact bytes* and the
decode round-trip in one call, which is strictly stronger than a substring check.

There is a `FromJSON` instance now, so the wire change is not write-only. Its fallthrough
calls `unknownVariant "expand node kind" other ["subject", "userset", "caveated"]`, and
`en-servant/test/Main.hs` line 477 pins that an unknown `kind` is *rejected*. Adding
constructors means extending the decoder and that legal-values list; the compiler does not
force either, because a `FromJSON` written as a `case` over `Text` has no exhaustive match
to fail.

**A fourth `ExpandNodeWire` consumer exists, and the compiler will not point at it
(M0, 2026-07-09).** This plan's Context and Orientation says "No other renderer consumes
`ExpandNode` — verified by search", listing `En.Expand`, the two test suites, and
`expandNodeToWire`. That search was for `ExpandNode`. The *wire* type has one more:
`instance ToSchema ExpandNodeWire` in `en-servant/src/En/Servant/OpenApi.hs` lines 379–397,
which hand-enumerates the three variants into the published OpenAPI 3.1 document (EP-35's
M4). It is a hand-written list, not a pattern match, so omitting the operator variants
compiles clean and silently ships an OpenAPI document that contradicts the server.

This is exactly the failure mode this plan's own Idempotence and Recovery section warns
about ("do not add wildcard matches to silence them — that is how the next constructor gets
silently dropped"), arriving through a door the section did not anticipate: not a wildcard,
but a type whose totality was never compiler-checked to begin with. M3 must update
`OpenApi.hs`, and the plan's claim that `expandNodeToWire` is "the total mapping the
compiler will force you to extend" is true only of that one function.

**`asBranchNode []` is reachable, contrary to the Decision Log (M0, 2026-07-09).** The
third Decision Log entry says "empty branch lists cannot occur (schema validation rejects
empty `Union`/`Intersection`)". That is true of *rewrite* branch lists and irrelevant to
the branch rule, which operates on *expanded node* lists: a conjunct like
`ComputedUserset "member"` over an object with no `member` rows expands to `[]` legitimately.
`asBranchNode []` must therefore be defined. It yields `ExpandUnion []` — an empty union
grants nobody, so the conjunct is unsatisfiable, which is the faithful reading and exactly
what an auditor needs to see. Collapsing it away would erase the reason the intersection
denies.

**Cited line numbers have drifted; symbols have not (M0, 2026-07-09).** Every symbol the
plan names still exists. Current locations: `expandRewrite`'s flattening at
`en-core/src/En/Expand.hs` 155–185 (plan said 170–179); `ExpandNode` at 57–61 ✓;
`pageNodes` at 281–292 (plan said 278–289); the `maxDepth`/`pageLimit`/`resultCap` constants
at 116–123 ✓. In `en-servant/src/En/Servant/API.hs`, `ExpandNodeWire` at 756–794 (plan said
272–277) and `expandNodeToWire` at 1172–1179 (plan said 576–583). In `en-core/test/Main.hs`,
the expand assertions are at 587–595 (plan said ~417–425) and the tree helpers at 1448–1478
(plan said ~1002–1036); the tree-level helper is named `treeHasUserset`, and `nodeHasUserset`
is its per-node companion — the plan's Interfaces section names only the latter.

EP-40's `CycleDetected` revisit guard is present at `En/Expand.hs` line 140 with its
explanatory comment, as this plan's Context and Orientation anticipated. Keep it intact.

**Nothing compiler-forces the wire mapping; it only warns (M2, 2026-07-09).** This plan
asserts twice that `expandNodeToWire` is "the total mapping the compiler will force you to
extend", and its Idempotence section rests on the same belief. It is false. The workspace
builds with `-Wall` but not `-Werror`, so after extending `ExpandNode` the engine compiled
clean:

```text
src/En/Servant/API.hs:1174:5: warning: [GHC-62161] [-Wincomplete-patterns]
    Pattern match(es) are non-exhaustive
    In a \case alternative:
        Patterns of type ‘Expand.ExpandNode’ not matched:
            Expand.ExpandUnion _
            Expand.ExpandIntersection _
```

`cabal build all` exits 0 on that. An implementer who ran only the engine's tests would
have shipped a server that throws `Non-exhaustive patterns` on every expansion of an
intersection — a crash, not a compile error. Together with the un-checked `ToSchema`
hand-list, *both* of the wire's consumers are unenforced; the compiler's contribution is a
warning one has to be reading for.

This has a consequence the plan did not foresee. M2 and M3 cannot be separate green
commits: an engine that emits operator nodes has no working wire until M3 lands. And the
plan's stated recovery — "the immediate mitigation is reverting M3 … revert means the whole
M3 commit" — was never achievable, because reverting M3 while keeping M2 restores exactly
the crash above. Reverting this work means reverting both milestones together, which is
what a single commit gives.

**The kikan fixtures cannot tell a preserved conjunction from a concatenated one
(M2, 2026-07-09).** This is the third instance of the pattern the master plan named for
EP-43, arriving in the tests this plan *adds* rather than the ones it inherits.

`audit` is `allOf owner [member]`, and both conjuncts are `ComputedUserset`s. A
`ComputedUserset` expands to exactly one `ExpandUserset` node. So a correct
`intersectionNode`, which emits one child per conjunct, and a broken one that concatenates
every branch's nodes produce the *same tree* on `audited-space`: two children either way.
`treeHasIntersection` passes against both. So does "one child per conjunct" measured on
that fixture — the count is 2 for the right reason and 2 for the wrong one.

`asBranchNode`, the function the plan calls "the difference between n conjuncts and one
blurry pile", was therefore untested by every assertion the plan specifies. The fix is a
fixture, not an assertion: `branchSchema` in `en-core/test/Main.hs` defines
`doc#reviewer = allOf this [computed approver]` over a `doc` with two stored reviewers and
one approver. The `This` conjunct expands to two nodes, so concatenation yields three
children where the conjunction has two, and the sabotage transcript in Concrete Steps shows
the new assertion failing `Just 2` / `Just 3` while every kikan-based assertion still
passes.

The generalization for EP-44, which will benchmark this code: a fixture where each branch
happens to expand to one node cannot observe *branching* at all. Ask what arity the code
under test distinguishes, then check the fixture actually exhibits more than one.

**The existing pagination test is a test encoding a bug, as the master plan predicted
(M0, 2026-07-09).** `en-core/test/Main.hs` line 595 asserts
`expand paginates top-level children` by expanding `auditedSpace#audit` at `ExpandLimit 1`
and expecting `ExpandHasMore (ExpandCursor "1")`. It passes today only because `audit`'s
intersection is flattened into two children — the very erasure B10 names. The assertion is
therefore a pin on the finding, and the master plan's Surprises & Discoveries called this
shot for EP-43 specifically. This plan's fifth Decision Log entry already schedules the
rewrite; M0 confirms it is needed for the predicted reason rather than an incidental one.


## Decision Log

- Decision: All three operators get nodes — including `Union` — with shapes
  `ExpandUnion ![ExpandNode]`, `ExpandIntersection ![ExpandNode]`, and
  `ExpandExclusion ![ExpandNode] ![ExpandNode]` (base children, subtracted children as
  two separate lists).
  Rationale: B10 says the tree "erases set operators", and a union node is as
  semantically load-bearing for an auditor as an intersection (a flat list under an
  implicit union reads identically to today's ambiguous output). Exclusion cannot be a
  single child list: "who is subtracted" versus "who is granted" is exactly the
  distinction an audit needs; two lists make it impossible to conflate. A
  `Zanzibar-style leaf/union/intersection/difference` nesting of single nodes was
  considered and rejected — en's expansion of one rewrite level naturally yields node
  *lists* per branch (subjects and usersets), and forcing singleton wrappers would add
  depth without information.
  Date: 2026-07-07
- Decision: Operator nodes are **atomic with respect to top-level paging**. `pageNodes`
  (`En/Expand.hs` lines 278–289) keeps slicing the root's direct child list; an
  operator node counts as one child and is never split across pages. The
  `resultCap = 1000` bound likewise counts top-level children only.
  Rationale: slicing *inside* an intersection would hand a client half of a
  conjunction, which is worse than the flattening this plan removes. Root-level
  operator nodes are few (a rewrite has one top shape); the cost of atomicity is that a
  single enormous operator subtree is not paginated — that is today's behavior for the
  whole tree anyway, and deep pagination of expand is out of scope here (the
  eager-then-slice shape of expand is a known sibling of lookup's B8; this plan
  deliberately does not rework expand's paging model).
  Date: 2026-07-07
- Decision: Single-branch simplification is minimal and syntactic: a `Union` or
  `Intersection` rewrite with exactly one branch produces that branch's nodes without
  an operator wrapper; empty branch lists cannot occur (schema validation rejects empty
  `Union`/`Intersection` — see the validation tests in `en-core/test/Main.hs` around
  lines 286–287). No other collapsing (no hoisting nested unions).
  Rationale: preserve what the schema author wrote; collapse only where the operator
  carries zero information. Determinism keeps the wire stable for tests.
  Date: 2026-07-07
- Decision: The wire change is additive constructors on the existing
  Generic-derived tagged sum `ExpandNodeWire` (new tags `ExpandUnionWire`,
  `ExpandIntersectionWire`, `ExpandExclusionWire`), shipped without a version bump in
  this plan, with the compatibility consequence recorded here: old clients that
  exhaustively match tags will reject trees containing the new tags.
  Rationale: the wire contract's versioning and stable tag naming is owned by
  docs/plans/35-version-the-wire-contract-and-type-the-error-model.md (master plan 6),
  which this plan must coordinate with per the master plan: **if docs/plans/35 lands
  first**, add the operator nodes to its `/v1` vocabulary following its naming scheme
  (losing the `Wire`-suffix leak it eliminates); **if this plan lands first** (expected
  — it is small), docs/plans/35 inherits three more constructors to name and version.
  Either way the *tree semantics* defined here are the contract; only spelling is
  35's. A comment at `ExpandNodeWire` records this handshake.
  Date: 2026-07-07
- Decision: The existing en-core assertion "expand paginates top-level children"
  (`en-core/test/Main.hs` line ~425), which expands `auditedSpace#audit` with
  `ExpandLimit 1` and expects `ExpandHasMore (ExpandCursor "1")`, is rewritten to use a
  flat (This-shaped) relation with two direct rows instead of `audit`.
  Rationale: after M2, `audit`'s root has exactly one child (the intersection node), so
  it no longer exercises pagination at all — the fixture choice was incidental. The
  replacement (e.g. `exclusionSpace#member`, which has two direct member tuples in
  `fixtureTuples`) tests the same paging mechanics on a shape paging still applies to.
  Date: 2026-07-07
- Decision: The docs/plans/35 handshake resolves in 35's favour, because 35 landed first.
  The three new JSON tags are `kind: "union"`, `"intersection"`, `"exclusion"` — lowercase,
  no `Wire` suffix — matching the `kind` discriminator vocabulary EP-35 established for
  `ExpandNodeWire`. The Haskell constructors are still `ExpandUnionWire` /
  `ExpandIntersectionWire` / `ExpandExclusionWire`, matching their siblings. The fourth
  Decision Log entry above (additive constructors on a `Generic`-derived tagged sum, no
  version bump, byte-check for the string `ExpandIntersectionWire`) is superseded in its
  *spelling* and stands in its *semantics*.
  Rationale: that entry pre-committed to exactly this outcome — "if docs/plans/35 lands
  first, add the operator nodes to its `/v1` vocabulary following its naming scheme (losing
  the `Wire`-suffix leak it eliminates); either way the tree semantics defined here are the
  contract; only spelling is 35's." The additive-tag compatibility consequence it recorded
  is unchanged and still true: a `/v1` client that exhaustively matches `kind` will reject
  trees containing operators. No version bump here; the tree shape is what this plan owns.
  Date: 2026-07-09
- Decision: M3 also updates `instance ToSchema ExpandNodeWire` in
  `en-servant/src/En/Servant/OpenApi.hs`, and the acceptance uses EP-35's `golden` helper
  (exact bytes plus decode round-trip) rather than the substring byte-check this plan
  proposed.
  Rationale: `ToSchema` hand-enumerates the node variants, so it is a consumer the compiler
  cannot force — omitting the operators would ship an OpenAPI document contradicting the
  server, silently. `golden` is strictly stronger than a substring assertion and is the
  house pattern for every other wire type; a substring check would pass against an encoder
  that emitted the tag under the wrong key.
  Date: 2026-07-09
- Decision: M1's red is demonstrated with assertions written in terms of the *current*
  constructors — `Right 1 == fmap (length . children) expansion` for both `audit` and
  `member_not_owner` — which fail today (`Right 2`, the flattened pair) and pass after M2.
  M2 then strengthens them to `treeHasIntersection` / `treeExclusionSides`.
  Rationale: the plan offered three techniques and asked which was used. A child-count
  assertion is the strongest statement expressible before `ExpandIntersection` exists, and
  it is a real red rather than a compile error, so it demonstrates the tests detect
  *flattening* rather than merely detecting a missing constructor.
  Date: 2026-07-09
- Decision: M1, M2, and M3 land as **one** commit, overriding the Idempotence section's
  "land M2 and M3 as separate commits".
  Rationale: that instruction protects a recovery path — "revert the M3 commit" — which
  does not exist. `expandNodeToWire` is a non-exhaustive `\case` under `-Wall` without
  `-Werror`, so an engine emitting operator nodes against a wire that lacks them *builds*
  and then crashes at runtime on the first intersection expanded. There is no commit
  boundary between M2 and M3 at which the tree is working, and reverting M3 alone
  reintroduces precisely that crash. Reverting this change means reverting both milestones,
  which one commit expresses honestly and two do not.
  Date: 2026-07-09
- Decision: `en-core/test/Main.hs` gains `branchSchema` /`reviewDoc` / `branchTuples`, a
  fixture defining `doc#reviewer = allOf this [computed approver]` with two stored
  reviewers, and the per-conjunct assertions are made against it rather than against
  `audited-space#audit`.
  Rationale: every kikan conjunct is a `ComputedUserset` and expands to exactly one node,
  so on kikan alone a concatenating `intersectionNode` is observationally identical to a
  correct one — both yield two children. The plan's specified assertions were therefore
  vacuous with respect to `asBranchNode`, the function it identifies as the whole point of
  B10. The sabotage transcript in Concrete Steps records that the new fixture fails
  (`Just 2` expected, `Just 3` actual) while the kikan assertions stay green.
  Date: 2026-07-09
- Decision: the exclusion node's wire form uses two named keys, `granted` and `subtracted`,
  rather than a two-element array or a `children` key plus a discriminator.
  Rationale: the sides are the information the node exists to carry, and named keys make
  them unmergeable by an encoder and unswappable by a careless refactor. `treeExclusionSides`
  in the en-core suite enforces the same separation one layer down, and both were observed
  to fail against an evaluator that piles every child onto the granting side.
  Date: 2026-07-09


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

You are in the `en` repository (working tree `/Users/shinzui/Keikaku/bokuno/en`; paths
repository-relative), a Haskell Cabal multi-package project on GHC 9.12.4. This plan is
EP-43 of `docs/masterplans/7-fix-the-en-evaluation-engine.md`, fixing finding B10 of
`docs/reviews/2026-07-07-architecture-performance-review.md`. Packages touched:
**`en-core`** (the engine) and **`en-servant`** (the HTTP layer and its wire DTOs).

Plain-language definitions:

- **Rewrite**: the expression defining a relation or permission
  (`En.Schema.Rewrite`): `This` (directly stored tuples), `ComputedUserset r` (alias to
  relation `r` on the same object), `TupleToUserset t c` (arrow: follow tuples of
  relation `t`, then relation `c` on their subjects), `Union [Rewrite]`,
  `Intersection [Rewrite]`, `Exclusion base subtract`, `Caveated name inner`.
- **Expand tree**: `En.Expand.expand` resolves consistency, walks the rewrite for the
  requested object#permission, and returns
  `ExpandTree { root, permission, children :: [ExpandNode], state }`. Today
  `ExpandNode` is:

  ```haskell
  data ExpandNode
      = ExpandSubject !Subject !(Maybe TupleRow)
      | ExpandUserset !ObjectRef !RelationName ![ExpandNode]
      | ExpandCaveated !CaveatName ![ExpandNode]
  ```

  `ExpandSubject` is a leaf (a concrete subject, with the tuple row that grants it);
  `ExpandUserset` is a named subtree ("everyone with relation R on object O, expanded
  below"); `ExpandCaveated` wraps children whose grant is caveat-gated — note it is
  already the "caveated wrapper" pattern this plan's operator nodes will sit beside.
- **The flattening**, verbatim from `en-core/src/En/Expand.hs` lines 170–179: `Union`
  and `Intersection` map `expandRewrite` over their branches and `concat` the results;
  `Exclusion` appends base and subtract children with `(<>)`. After that concatenation
  nothing in the tree records which operator combined them — or, for exclusion, which
  children were the *subtraction*.
- **Paging**: `runExpand` (lines 81–99) computes all children, then `pageNodes` (lines
  278–289) slices the top-level list by an integer-offset cursor with
  `resultCap = 1000`. This plan keeps that mechanism (see Decision Log) — only what
  counts as "a child" changes.

The wire layer (`en-servant/src/En/Servant/API.hs`): `ExpandNodeWire` (lines 272–277)
mirrors `ExpandNode` with `Generic`-derived JSON (tagged sum:
`{"tag":"ExpandUsersetWire","contents":[…]}`); `expandNodeToWire` (lines 576–583) is
the total mapping the compiler will force you to extend; `expandHandler` (lines
407–426) and `ExpandTreeWire` need no structural change. The en-servant test suite is
`en-servant/test/Main.hs` (`cabal test en-servant:en-servant-tests`); the en-core tree
assertions and helpers (`treeHasSubject`, `nodeHasUserset`, `treeHasCaveat`, lines
~1002–1036) are in `en-core/test/Main.hs`, and the audit fixtures are in
`en-core/src/En/Conformance/Kikan.hs` (`kikanSchema` defines
`permission audit = allOf owner [member]`, i.e. `Intersection`; `fixtureTuples` gives
`auditedSpace` an owner+member `memberOwner`; `exclusionSpace` exercises
`member_not_owner = member − owner`). No other renderer consumes `ExpandNode` — 
verified by search: `En.Schema.Render` renders schemas and reachability graphs, not
expand trees; the only `ExpandNode` consumers are `En.Expand` itself, the two test
suites, and `expandNodeToWire`. If that changes before implementation, update this
paragraph.

Integration points restated from the master plan so this plan stands alone:

- **EP-43 is fully parallel** with the other EP-39…EP-44 plans — it touches
  `En.Expand`, not `En.Check`/`En.Lookup`. One seam exists with
  docs/plans/40-adopt-zanzibar-cycle-and-exclusion-semantics-in-check.md: EP-40 changes
  expand's *revisit* error to the new `CycleDetected` constructor. That is inside
  `expandRelation`'s guard, not the node type — merge order between EP-40 and EP-43 is
  irrelevant, but if EP-40 landed first, keep its guard intact when editing the file.
- **Wire coordination is with docs/plans/35** (master plan 6), as spelled out in the
  Decision Log above: whichever plan lands second reconciles tag naming/versioning of
  the three new wire constructors.
- docs/plans/44-make-evaluation-budgets-configurable-and-trim-hot-path-overhead.md will
  replace expand's `maxDepth`/`pageLimit`/`resultCap` constants (lines 116–123) with
  the shared budget record; this plan leaves those constants untouched.


## Plan of Work


### M0 — Baseline and drift check (no code)

Build and test; re-read `en-core/src/En/Expand.hs` end to end,
`en-servant/src/En/Servant/API.hs` lines 261–300 and 567–591, and the test helpers
named above. Confirm no new `ExpandNode` consumers appeared.

```bash
cabal build all
cabal test all
```


### M1 — The failing operator assertion (red)

Scope: encode the acceptance first. In `en-core/test/Main.hs`, next to the existing
expand assertions (lines ~417–425), add a structure predicate and the headline test:

```haskell
treeHasIntersection :: Either EnError ExpandTree -> Bool
treeHasIntersection =
    either (const False) (any nodeIsIntersection . (.children))
  where
    nodeIsIntersection = \case
        ExpandIntersection _ -> True
        _ -> False
```

— which does not compile yet; for the red run, assert the *current* shape is flat:

```haskell
auditExpansion <- expandEngine consistencyStore tupleStore graph MinimizeLatency
    (expandRequest auditedSpace (RelationName "audit") requestContext (ExpandLimit 20) Nothing)
assertBool "expand preserves the audit intersection operator"
    (treeHasIntersection auditExpansion)
```

Practical red-run technique: since the constructor does not exist before M2, write the
assertion in this milestone against a temporary structural check ("children are exactly
two ExpandUserset nodes with no operator between them") and flip it to
`treeHasIntersection` in M2 — or simply commit the M1 test together with M2's type
change and demonstrate red by `git stash`-ing the evaluator edit. Record which you did.
Also add the exclusion counterpart now: expanding
`exclusionSpace#member_not_owner` must distinguish base children (the two `member`
grants) from subtracted children (the `owner` grant).

```bash
cabal test en-core:en-core-interface-tests
```

Acceptance: the new assertions fail on the flattened tree; capture output.


### M2 — Operator nodes in the engine

Scope: the type, the evaluator, and the en-core tests.

1. `en-core/src/En/Expand.hs`, extend the node type:

   ```haskell
   data ExpandNode
       = ExpandSubject !Subject !(Maybe TupleRow)
       | ExpandUserset !ObjectRef !RelationName ![ExpandNode]
       | ExpandCaveated !CaveatName ![ExpandNode]
       | ExpandUnion ![ExpandNode]
       | ExpandIntersection ![ExpandNode]
       | ExpandExclusion ![ExpandNode] ![ExpandNode]
       deriving stock (Eq, Show)
   ```

   Haddock each: union = any branch suffices; intersection = every branch required;
   exclusion = first list grants, second list subtracts. Note explicitly that
   `ExpandCaveated` is the caveat *wrapper* member of this same family (gate over its
   children) — the review's "caveated wrapper" — and stays unchanged.
2. `expandRewrite` (lines 161–182): stop flattening.

   Branch boundaries are semantic and must survive: for an intersection, "one branch
   per conjunct" is exactly the information B10 says is lost, so a branch that expands
   to several nodes (a `This` with several rows) must stay one conjunct. The rule:
   represent each branch as a single node via
   `asBranchNode [single] = single; asBranchNode nodes = ExpandUnion nodes` (a
   multi-node branch is inherently union-shaped — any of its rows grants the branch).
   Then:

   ```haskell
   Union rewrites -> do
       branches <- traverse (\current -> expandRewrite graph revision object currentRelation current state) rewrites
       pure (unionNode <$> sequence branches)
   Intersection rewrites -> do
       branches <- traverse (\current -> expandRewrite graph revision object currentRelation current state) rewrites
       pure ((\bs -> [ExpandIntersection (asBranchNode <$> bs)]) <$> sequence branches)
   Exclusion base subtractRewrite -> do
       baseChildren <- expandRewrite graph revision object currentRelation base state
       subtractChildren <- expandRewrite graph revision object currentRelation subtractRewrite state
       pure ((\b s -> [ExpandExclusion b s]) <$> baseChildren <*> subtractChildren)
   ```

   where `unionNode` applies the single-branch collapse from the Decision Log
   (`unionNode [single] = single`; otherwise
   `unionNode branches = [ExpandUnion (concat branches)]` — inside a union, branch
   boundaries carry no extra meaning, so concatenating members is faithful) and
   `ExpandExclusion` keeps the two sides' node lists whole. Write the `asBranchNode`
   rule as a code comment — it is the difference between "n conjuncts" and "one blurry
   pile", i.e. the whole point of B10.
3. Update the en-core test helpers `nodeHasSubject`/`nodeHasUserset`/`nodeHasCaveat`
   (lines ~1006–1036) with the three new recursive cases (the compiler's
   incomplete-pattern warnings under `-Wall` find them all — the test component builds
   with `-Wincomplete-uni-patterns`; treat every new warning as a task). Flip M1's
   temporary assertion to `treeHasIntersection`; add
   `treeHasExclusion` asserting base/subtract separation (the `owner` grant row appears
   only on the subtract side). Rework the pagination assertion per the Decision Log:
   expand `exclusionSpace` relation `member` (two direct rows) with `ExpandLimit 1` and
   expect `ExpandHasMore (ExpandCursor "1")`; and add its replacement-semantics sibling:
   expanding `auditedSpace#audit` with `ExpandLimit 1` is now `ExpandExhausted` with
   exactly one (intersection) child — operator nodes are atomic under paging.
4. Verify the multi-page drain assertion ("expand drains multi-page object rows before
   applying result cap", line ~405–406) still holds: it expands a flat This relation
   (`crowdedFolder#viewer`), which produces leaf nodes unchanged.

```bash
cabal test en-core:en-core-interface-tests
cabal test en-core:en-core-conformance
```

Acceptance: M1 assertions green; helper-based assertions
("expand includes direct owner subject", "expand includes parent userset",
"expand expands userset subjects", "expand includes caveat markers") green through the
new recursive cases; reworked pagination assertions green.


### M3 — The wire DTO and en-servant tests

Scope: carry the structure to HTTP clients.

1. `en-servant/src/En/Servant/API.hs`: extend

   ```haskell
   data ExpandNodeWire
       = ExpandSubjectWire !SubjectWire
       | ExpandUsersetWire !ObjectRefWire !Text ![ExpandNodeWire]
       | ExpandCaveatedWire !Text ![ExpandNodeWire]
       | ExpandUnionWire ![ExpandNodeWire]
       | ExpandIntersectionWire ![ExpandNodeWire]
       | ExpandExclusionWire ![ExpandNodeWire] ![ExpandNodeWire]
   ```

   and the three cases in `expandNodeToWire` (compiler-forced). Above the type, add the
   coordination comment: tag names are provisional pending
   docs/plans/35-version-the-wire-contract-and-type-the-error-model.md's versioned
   vocabulary; additive tags mean pre-existing clients with exhaustive tag matching
   will reject trees containing operators (see this plan's Decision Log).
2. `en-servant/test/Main.hs`: the suite drives handlers directly with the in-memory
   env (see the existing `checkHandler`/`lookupHandler` patterns and the
   `server env` destructuring at lines ~135–157, which binds `_expand`). Bind the
   expand endpoint, request `auditedSpace` / permission `"audit"` against the kikan
   fixtures, and assert the response tree's children are
   `[ExpandIntersectionWire [_, _]]` — the on-the-wire form of the headline
   acceptance. Add a JSON-level spot check (encode the response with `Data.Aeson.encode`
   and assert the bytes contain `"ExpandIntersectionWire"`) so the tag itself — what a
   real client sees — is pinned by test until docs/plans/35 renames deliberately.

```bash
cabal build all
cabal test en-servant:en-servant-tests
```

Acceptance: the wire test shows an intersection node over two children for an
intersection-defined permission; whole suite green.


### Final — wrap-up

Full suite; fill Outcomes & Retrospective; tick the EP-43 row in
`docs/masterplans/7-fix-the-en-evaluation-engine.md`; Revision Note at the bottom here.

```bash
cabal build all
cabal test all
```


## Concrete Steps

All commands from `/Users/shinzui/Keikaku/bokuno/en`:

```bash
cabal build all
cabal test all                                # M0 baseline, Final
cabal test en-core:en-core-interface-tests    # M1/M2 inner loop
cabal test en-core:en-core-conformance
cabal test en-servant:en-servant-tests        # M3
```

**M1 red, actual (2026-07-09).** Both assertions were written as child counts, since
`ExpandIntersection` did not exist yet. Each expansion returns two flat children where one
operator node belongs:

```text
user error (expand preserves the audit intersection operator
expected: Right 1
actual:   Right 2)

user error (expand separates exclusion base from subtracted children
expected: Right 1
actual:   Right 2)
```

(The second was captured by temporarily relaxing the first to `Right 2`, since the suite
aborts on the first failure.)

**M2/M3 green, actual (2026-07-09).**

```text
Test suite en-core-interface-tests: PASS
Test suite en-core-conformance: PASS
Test suite en-servant-tests: PASS
Test suite en-postgres-revision-tests: PASS
Test suite en-postgres-integration-tests: PASS
Test suite en-biscuit-tests: PASS
Test suite en-example-tests: PASS
```

**The bytes a client receives for `audited-space#audit` (2026-07-09).** Asserted exactly, in
`en-servant/test/Main.hs`, from the real handler over the kikan fixtures. Before this plan
these were two sibling `userset` nodes with no operator between them — byte-identical to
what `act` (an `anyOf` over the same two relations) produces:

```json
{"root":{"objectType":"space","objectId":"audited-space"},"permission":"audit","children":[{"kind":"intersection","children":[{"kind":"userset","object":{"objectType":"space","objectId":"audited-space"},"relation":"owner","children":[{"kind":"subject","subject":{"kind":"id","objectType":"user","objectId":"member-owner"}}]},{"kind":"userset","object":{"objectType":"space","objectId":"audited-space"},"relation":"member","children":[{"kind":"subject","subject":{"kind":"id","objectType":"user","objectId":"member-owner"}}]}]}],"state":{"status":"exhausted"}}
```

**Sabotage evidence (2026-07-09).** The master plan requires that a test for this class of
bug be observed failing against a deliberately broken implementation. Two were run.

Replacing `intersectionNode branches = [ExpandIntersection (asBranchNode <$> branches)]`
with `[ExpandIntersection (concat branches)]` — the flattening this plan removes, hidden
one level down:

```text
user error (expand renders one child per conjunct, not one per row
expected: Just 2
actual:   Just 3)
```

Only the `branchSchema` assertion caught it. Every kikan-based assertion — including
`treeHasIntersection` and the audit conjunct count — passed against the sabotage, which is
why `branchSchema` exists.

Replacing `[ExpandExclusion granted subtracted]` with
`[ExpandExclusion (granted <> subtracted) []]` — an exclusion node that exists but carves
nothing out, the flat tree wearing a hat:

```text
user error (expand carves the owner grant out on the subtract side alone
expected: Just (False,True)
actual:   Just (True,False))
```


## Validation and Acceptance

1. **Headline (B10)**: expanding `space#audit` (schema:
   `permission audit = allOf owner [member]`, an `Intersection`) on the kikan fixtures
   yields a tree whose root children are exactly one `ExpandIntersection` with two
   conjunct subtrees — asserted at the engine level
   (`cabal test en-core:en-core-interface-tests`) and on the wire as
   `ExpandIntersectionWire` (`cabal test en-servant:en-servant-tests`, including the
   JSON byte-level tag check). Before this plan the same expansion is a flat list.
2. **Exclusion separation**: expanding `space#member_not_owner`
   (`member − owner`) yields `ExpandExclusion base subtract` where the `owner` grant
   row appears only in `subtract` — an auditor can see who is carved out.
3. **Union preserved**: expanding `space#view` (a five-branch union) yields an
   `ExpandUnion` whose branches include the direct and arrow subtrees; the existing
   subject/userset/caveat presence assertions still find their nodes through it.
4. **Paging semantics**: operator nodes are atomic — `audit` at `ExpandLimit 1` is
   `ExpandExhausted` with one child; a flat two-row relation at `ExpandLimit 1` still
   pages (`ExpandHasMore (ExpandCursor "1")`); the 1,000-node `resultCap` drain
   assertion is unchanged.
5. **No regressions**: `cabal test all` green across en-core (interface + conformance),
   en-servant, and the untouched packages.


## Idempotence and Recovery

Pure code-and-tests change; every command re-runnable; no migrations, no persistent
state. The compiler drives completeness: extending `ExpandNode` and `ExpandNodeWire`
surfaces every consumer as a pattern-match error or warning — do not add wildcard
matches to silence them (that is how the next constructor gets silently dropped). The
wire addition is additive; if an unknown downstream consumer breaks on the new tags,
the immediate mitigation is reverting M3 (engine keeps structure, wire flattens is
*not* an option — there is no flatten shim; revert means the whole M3 commit) and
escalating the versioning question to docs/plans/35. Land M2 and M3 as separate commits
for that reason.


## Interfaces and Dependencies

No new package dependencies (en-servant already has `aeson` for the JSON spot check).

End-state interfaces (full module paths):

- `En.Expand.ExpandNode` gains `ExpandUnion ![ExpandNode]`,
  `ExpandIntersection ![ExpandNode]`, `ExpandExclusion ![ExpandNode] ![ExpandNode]`;
  `ExpandCaveated` unchanged as the caveat wrapper. `expandRewrite` preserves operators
  with the branch rule: multi-node branches of intersection/exclusion sides wrap in
  `ExpandUnion`; single-branch operators collapse. Public
  `expand`/`ExpandRequest`/`ExpandTree`/`ExpandState` signatures unchanged.
- `En.Servant.API.ExpandNodeWire` gains `ExpandUnionWire`, `ExpandIntersectionWire`,
  `ExpandExclusionWire`; `expandNodeToWire` total over the new constructors; tag naming
  provisional pending docs/plans/35 (comment in code, handshake recorded in this plan's
  Decision Log).
- Test helpers in `en-core/test/Main.hs` (`nodeHasSubject`, `nodeHasUserset`,
  `nodeHasCaveat`, plus new `treeHasIntersection`/`treeHasExclusion`) recurse through
  operator nodes.

Consumed by: audit/review UI work and
docs/plans/35-version-the-wire-contract-and-type-the-error-model.md (tag naming and
versioning of the three new wire constructors — whichever lands second reconciles).
Independent of docs/plans/39/40/41/42 except the trivial `En.Expand` merge seam with
EP-40's `CycleDetected` revisit guard noted in Context and Orientation.
