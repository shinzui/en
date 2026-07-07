---
id: 43
slug: preserve-set-operators-in-expand-trees
title: "Preserve set operators in expand trees"
kind: exec-plan
created_at: 2026-07-07T15:24:51Z
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

- [ ] M0: baseline — build/test; confirm cited symbols/lines in `En.Expand`,
  `En.Servant.API`, and both test suites; record drift.
- [ ] M1: failing test — expanding `space#audit` on the kikan fixtures must contain an
  intersection node; captured red output (today: flat children).
- [ ] M2: `ExpandNode` gains `ExpandUnion` / `ExpandIntersection` / `ExpandExclusion`;
  `expandRewrite` stops flattening; en-core tree helpers updated; en-core tests green
  including the reworked pagination assertion.
- [ ] M3: wire DTO — `ExpandNodeWire` gains the three operator constructors;
  `expandNodeToWire` extended; en-servant tests assert the intersection tag on the
  wire; coordination note with docs/plans/35 recorded in code.
- [ ] Final: full suite green; Outcomes filled; master plan progress row updated.


## Surprises & Discoveries

(None yet.)


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

Expected M1 red (with the pre-M2 structural check):

```text
expand preserves the audit intersection operator
expected: True
actual:   False
```

After M2, spot-check by eye in GHCi if useful:

```bash
cabal repl en-core
-- ghci> import En.Expand, run expand over the kikan fixtures and Show the tree
```

Update this section with real transcripts (red M1, green M2/M3, the encoded JSON
snippet from the wire test) as evidence while working.


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
