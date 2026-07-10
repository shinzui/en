---
id: 52
slug: add-a-lookup-subjects-api
title: "Add a lookup-subjects API"
kind: exec-plan
created_at: 2026-07-07T15:25:10Z
master_plan: "docs/masterplans/9-complete-the-en-api-surface.md"
---

# Add a lookup-subjects API

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

"Who has access to this object?" is the question behind sharing dialogs, access-review
screens, and notification fan-out. en cannot answer it today. `POST /expand` returns an
explanatory *tree* of the permission's structure, and — as the review found (B10 in
`docs/reviews/2026-07-07-architecture-performance-review.md`) — that tree erases the
set operators, so a client cannot even in principle flatten it into the correct set of
subjects. `POST /lookup` answers the mirror-image question (which objects can this
subject reach). The flat, correct, paginated "list the subjects" query — Zanzibar's
and SpiceDB's LookupSubjects — is missing. This is gap E4, coordinated by
`docs/masterplans/9-complete-the-en-api-surface.md`.

After this change, a new core algorithm `En.LookupSubjects.lookupSubjects` and an
endpoint `POST /lookup-subjects` answer: given an object, a permission, and a subject
type filter, return the flat cursored set of subjects of that type that hold the
permission, each tagged with a `CheckDecision` — `Allowed` for unconditional access or
`Conditional` with the caveat obligations that remain, exactly as lookup already does
per object. Wildcard grants (`user:*`) surface as a distinct wildcard entry, never
silently expanded into or hidden among concrete subjects. Results are pageable with
the engine's standard page vocabulary (exhausted / has-more / truncated) and bounded
by a deadline budget. A sharing dialog can render the response directly.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1 (2026-07-09): Create `en-core/src/En/LookupSubjects.hs` with the request/result/cursor types and the traversal skeleton over `This`, `ComputedUserset`, and `Union`.
- [x] M1 (2026-07-09): Implement `TupleToUserset` traversal and tuple/rewrite caveat gating.
- [x] M1 (2026-07-09): Implement intersection/exclusion candidate confirmation via forward check, and wildcard surfacing rules.
- [x] M1 (2026-07-09): Implement paging (`Exhausted`/`HasMore`/`Truncated`), the cursor codec, and the deadline hook; add the module to `en-core/en-core.cabal` exposed-modules.
- [x] M1 (2026-07-09): Conformance tests over the kikan fixtures: group nesting through `org#member`, caveated delegate (Allowed and Conditional), exclusion (`member_not_owner`), intersection (`audit`), pagination determinism; plus a local wildcard-schema test, a malformed-cursor test, and a foreign-token cursor test under the strict consistency store.
- [x] M2 (2026-07-09): Wire DTOs, `POST /v1/lookup-subjects` route, handler, and `Env.lookupSubjectsWithDeadlineOperation` in `en-servant/src/En/Servant/API.hs` and `en-servant/src/En/Servant/Seam.hs`; hand-written `ToSchema` instances in `en-servant/src/En/Servant/OpenApi.hs`; cached/uncached variants wired in `en-server/app/Main.hs`; uncached in `en-example/src/En/Example/Host.hs`; golden and handler tests in `en-servant/test/Main.hs`.
- [x] M2 (2026-07-09): Add the `lookupSubjects` field to `EnClient` in `en-client/src/En/Client.hs`.
- [ ] M3: Run the end-to-end curl transcript against a live server and paste the observed output into Validation and Acceptance.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-07-09 (M1): the external sequencing this plan only *preferred* has already
  happened. Master plans 6, 7, and 8 are all Complete, so `docs/plans/35` (versioned wire
  contract), `docs/plans/40` and `42` (cycle semantics, validated cursors, real deadline),
  and `docs/plans/49` (index trim) all landed before this plan started. Consequences: the
  route is `POST /v1/lookup-subjects`, not `POST /lookup-subjects`; every JSON transcript
  written into this plan on 2026-07-07 showing `{"tag": …}` sum encodings is stale — the
  `v1` contract encodes sums with a string discriminator (`kind` for subjects, `result`
  for decisions, `mode` for consistency, `status` for page states); and the "inheriting
  engine defects through the confirmation step" risk in Idempotence and Recovery is moot,
  because `check` no longer errors on a data cycle.

- 2026-07-09 (M1): `En.Check.evalTupleToUsersetMemo` follows a tupleset row's *own*
  subject relation, not the arrow's `computedRelation`, when the row's subject is a
  userset. That is, for `TupleToUserset parent view` over a row
  `space:child#parent@space:p#editor`, check evaluates `space:p#editor`, not
  `space:p#view`. `En.Expand.expandTupleToUserset` does the same. This module copies that
  behavior rather than the arrow's nominal reading, because the confirmation step calls
  `check`: had the traversal followed `computedRelation` there, a candidate the walk found
  would be denied by the check confirming it, and intersections would silently return
  fewer subjects than the union of their branches contains.

- 2026-07-09 (M1): the six conformance scenarios passed on their first run. That is worth
  recording rather than celebrating — it is what "reach-then-check delegating to the one
  evaluator" buys. The exclusion and intersection cases are not vacuous: without the
  confirmation step, `exclusionSpace#member_not_owner` returns `member-owner` (the base
  branch grants it) and `auditedSpace#audit` returns every member *or* owner rather than
  the one subject holding both. Both assertions name the exact singleton set.

  ```text
  Test suite en-core-conformance: PASS
  1 of 1 test suites (1 of 1 test cases) passed.
  ```

- 2026-07-09 (M2): adding `LookupSubjectsRequestWire` broke an *existing* test that had
  nothing to do with this plan. `en-servant/test/Main.hs` built its deadline-clamp request
  with `lookupRequest{deadlineMillis = Just 86400000, limit = 1}`, and that pair of fields
  named a unique record until this type arrived carrying both. GHC narrows a record update
  by its field set and then by the field types; when several parents survive it falls back
  to the type expected of the update, warns `-Wambiguous-fields`, and says the mechanism is
  going away.

  ```text
  test/Main.hs:301:25: error: [GHC-99339]
      • Ambiguous record update with fields ‘deadlineMillis’ and ‘limit’
        These fields appear in both datatypes
          ‘LookupRequestWire’ and ‘LookupSubjectsRequestWire’
  ```

  The clamp request is now a full literal. Three older updates in that file
  (`lookupRequest{cursor = …}` twice, and one on `TupleFilterWire`) already ride the
  deprecated mechanism and now have company; the whole file wants one sweep when GHC drops
  it, not a piecemeal rewrite here.

- 2026-07-09 (M2): the OpenAPI document is compile-and-test-enforced twice over. Adding a
  route to `EnAPI` without a hand-written `ToSchema` instance fails to build, and
  `en-servant/test/Main.hs` separately asserts the served path list, so the new operation
  had to be added to `servedPaths` before the suite would pass. Both guards fired, which is
  what they are for.


## Decision Log

Record every decision made while working on the plan.

- Decision: The subject-type filter is mandatory in the request (one `ObjectType`, e.g. `user`).
  Rationale: Matches SpiceDB's LookupSubjects (which requires `subject_object_type`) and keeps the traversal bounded and the result homogeneous; "all subjects of every type" is an audit query better served by expand plus the relationship filter of `docs/plans/50-expose-relationship-read-and-delete-by-filter-endpoints.md`. An optional subject-relation filter (for userset subjects like `org#member` as results) is deliberately out of scope for this plan.
  Date: 2026-07-07
- Decision: Use reach-then-check, in the forward direction: the traversal walks the rewrite AST from `object#permission` collecting candidate subjects; intersection and exclusion nodes collect candidates from their branches and then confirm each candidate with a full forward `En.Check.check` of that subject against the node's enclosing relation, mirroring `confirmCandidates` in `en-core/src/En/Lookup.hs`.
  Rationale: This is the same shape lookup already uses for its conditional entrypoints, reuses the one evaluator that implements the full decision algebra, and cannot silently disagree with `check`. Evaluating operator semantics inside the traversal would duplicate the algebra and rot independently.
  Date: 2026-07-07
- Decision: A revisited subproblem during traversal contributes an empty subject set (mirroring `En.Lookup.evalRelation`, which returns `Right []` on revisit), not an error.
  Rationale: Lookup already adopted the Zanzibar cycle posture for reverse traversal; a brand-new API must not inherit check's harsher revisit-is-error behavior (review B3). Note the asymmetry: the *confirmation* step delegates to `check`, which today still errors on data cycles — see the soft-ordering entry below.
  Date: 2026-07-07
- Decision: Wildcards surface as a distinct result entry (`SubjectWildcard` with its own decision) and are never expanded into concrete subjects. Inside intersection/exclusion, a wildcard candidate is confirmed by checking the wildcard subject itself, which means a wildcard survives an intersection only if every branch grants the wildcard, and is subtracted only if the subtrahend grants the wildcard.
  Rationale: Expanding `user:*` is unbounded and wrong (the set of users is not en's data). The conservative confirmation rule fails closed: it can under-report a wildcard's interaction with concrete-subject branches (a concrete subject granted by one branch and covered by a wildcard in another is still reported concretely via its own candidacy), and it never fabricates access. Distributing wildcard-versus-concrete semantics across operators is Zanzibar-paper territory explicitly deferred; the conformance tests pin the conservative behavior so a later refinement is a visible change.
  Date: 2026-07-07
- Decision: Mirror lookup's current paging mechanics — materialize the merged candidate set at one revision, sort by subject, slice by cursor and limit, and consult the deadline to choose `HasMore` versus `Truncated` — including its known weakness that each page re-runs the traversal (review B8).
  Rationale: Consistency with the existing engine beats a private streaming design in one endpoint. `docs/plans/42-stream-lookup-pages-with-validated-cursors-and-a-real-deadline.md` (master plan 7) owns fixing the mechanics for lookup; this module copies the page-state vocabulary (`Exhausted`/`HasMore`/`Truncated`) and cursor conventions so EP-42's fix transfers mechanically.
  Date: 2026-07-07
- Decision: Soft ordering restated from `docs/masterplans/9-complete-the-en-api-surface.md`: this plan benefits from `docs/plans/40-adopt-zanzibar-cycle-and-exclusion-semantics-in-check.md` (cycle-as-empty-set and exclusion/Conditional fixes in check) and `docs/plans/42-stream-lookup-pages-with-validated-cursors-and-a-real-deadline.md` (validated cursors, real deadline) landing first; implementing before them means this API inherits check's current defects (B3, B4) through the confirmation step and lookup's cursor forgeability (B9) through the copied cursor scheme.
  Rationale: Recorded so the implementer sequences deliberately; the plan is still implementable against the current tree.
  Date: 2026-07-07
- Decision: The response includes a `checkedAt` consistency token from day one, following the convention of `docs/plans/51-return-checked-at-consistency-tokens-from-read-responses.md`.
  Rationale: Master plan 9's Integration Points require every new read DTO to carry the token. If EP-51 has landed, mint via its `mintToken` effect operation; if not, add the field per the review's E3 description (minted exactly like write tokens through the consistency boundary) and let EP-51 reconcile — record whichever happened here.
  Date: 2026-07-07
- Decision: EP-51 had landed, so `checkedAt` follows its established convention exactly, and a cursored resume does **not** re-resolve the request's `consistency`.
  Rationale: `LookupSubjectsPage.checkedAt :: ConsistencyToken` is minted by the `MintToken` operation of the `ConsistencyStore` effect (a pure encode in every interpreter, so it costs no round trip) from the revision the read *resolved to*. On the wire it is `checkedAt :: !Text`, last in the response object. On a cursor resume the token comes from the cursor's *validated* token and `resolveConsistency` is never called — EP-51's Surprises record a lookup page-two request asking for `minimizeLatency` and correctly receiving page one's snapshot, and a cursored read that re-resolves silently spans two snapshots and pages with gaps.
  Date: 2026-07-09
- Decision: Do not port `En.Lookup`'s `EmitWindow` (the watermark-and-confirm-budget optimization that bounds confirmation to the current page). Confirm every candidate.
  Rationale: The window is sound only where a confirmation's output goes straight into the page, so it threads a `Maybe EmitWindow` through every rewrite node with per-constructor rules about when to pass it on. Copying that into a brand-new evaluator buys a constant factor on the confirmation of intersection and exclusion nodes and risks a page with gaps if one rule is copied wrong. `docs/plans/42` owns lookup's paging mechanics; when a future plan generalizes them, this module adopts the result. The page vocabulary, cursor discipline, and traversal shape are already identical, which is what makes that transfer mechanical.
  Date: 2026-07-09
- Decision: `LookupSubjectsRequest.limit` is a bare `Int`, not a `LookupSubjectsLimit` newtype mirroring `En.Lookup.LookupLimit`.
  Rationale: The plan's own sketch spelled it `Int`, and the handler already carries an unrelated `Int` (`deadlineMillis`) that a newtype here would not distinguish from anything. One fewer type for a novice to thread.
  Date: 2026-07-09
- Decision: The traversal's invariant arguments (graph, context, revision, subject type, deadline, confirming checker) travel in one `Traversal` record rather than as positional parameters.
  Rationale: `En.Lookup`'s evaluators take nine positional arguments, three of which are `RelationName`s and two `ObjectType`s, so a call site can transpose two of them without a type error. The record is internal, so it costs nothing on the public surface.
  Date: 2026-07-09
- Decision: A tupleset row whose subject is a userset is followed through that userset's own relation, not the arrow's `computedRelation`.
  Rationale: This is what `En.Check` does, and the confirmation step calls `check`. See Surprises & Discoveries.
  Date: 2026-07-09


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

The repository root is `/Users/shinzui/Keikaku/bokuno/en` (Haskell, GHC 9.12.4,
`cabal`). This plan adds a module to `en-core` (the storage-agnostic engine), an
endpoint to `en-servant`/`en-server`, and a client field to `en-client`. It fixes gap
E4 of `docs/reviews/2026-07-07-architecture-performance-review.md` under
`docs/masterplans/9-complete-the-en-api-surface.md`.

Vocabulary. A **tuple** is a stored grant `object#relation@subject`
(`En.Tuple.Tuple`). A **subject** is a concrete object (`SubjectId user:alice`), a
userset (`SubjectSet org:acme#member` — "all members of acme"), or a wildcard
(`SubjectWildcard user` — "every user"). A **permission** is a relation whose
**rewrite** (`En.Schema.Rewrite`) is an expression over the Zanzibar algebra: `This`
(directly written tuples), `ComputedUserset` (alias to a sibling relation),
`TupleToUserset` (follow a relation to a parent object, then a relation there — the
"arrow"), `Union`, `Intersection`, `Exclusion`, and `Caveated` (gated by a named
condition evaluated against request context and tuple payload). A **CheckDecision**
(`En.Decision`, re-exported by `En.Check`) is `Allowed`, `Denied`, or
`Conditional [CaveatObligation]` — the last meaning "allowed if the caller supplies
the named missing context". The compiled schema is a `ReachabilityGraph`
(`En.Reachability`), whose `relations` map is how evaluators find a relation's rewrite.

The three existing read algorithms, and what this plan mirrors from each:

- `En.Check.check` (`en-core/src/En/Check.hs`) — forward yes/no evaluation. This
  plan's confirmation step calls it (through the same `CheckForCandidate`-style
  indirection lookup uses, so the decision-cached variant `checkCached` can be swapped
  in by the server).
- `En.Lookup.lookup` (`en-core/src/En/Lookup.hs`) — reverse traversal
  (subject → objects) with reach-then-check for intersection/exclusion
  (`confirmCandidates`), per-result `CheckDecision` (`LookupObject`), a deadline hook
  (`Deadline`, a monadic "budget remaining?" probe), the page vocabulary
  `LookupExhausted`/`LookupHasMore`/`LookupTruncated`, and a length-prefixed cursor
  codec (`encodeLookupCursor`) that embeds the traversal's revision so later pages
  stay on the first page's snapshot. This plan is the *forward* twin: object →
  subjects, same result shape and machinery.
- `En.Expand.expand` (`en-core/src/En/Expand.hs`) — forward traversal producing an
  explanatory tree. Its traversal over `This`/`TupleToUserset` rows (draining pages
  with `readObjectRelation`) is structurally what M1's collector does, but expand's
  output cannot serve this feature, for the reasons below.

Why client-side flattening of the expand tree is incorrect — this motivates the whole
feature, so it is spelled out. First, operators: `ExpandNode` has constructors only
for subjects, usersets, and caveats; `Intersection`, `Exclusion`, and `Union` all
flatten to concatenated children (`expandRewrite` in `en-core/src/En/Expand.hs`,
review B10). A client that flattens the tree therefore unions everything: a user who
satisfies only one branch of an "all of" permission appears as having access, and the
users listed under an exclusion's *subtracted* branch — precisely the people who do
NOT have access — appear as if granted. Second, caveats: `ExpandCaveated` marks a
subtree conditional, but whether a particular subject is `Allowed`, `Conditional`, or
`Denied` requires evaluating the caveat against context and payload and combining
decisions across branches with the decision algebra (`En.Decision.union`
/`intersection`/`exclusion`) — logic that lives in the engine, not in a tree consumer.
Third, wildcards: `user:*` appears as a leaf subject; a naive flattener either treats
the literal `*` as a user id or drops it, and it cannot know how a wildcard interacts
with exclusions or type restrictions. The correct flat answer requires the evaluator;
that is what `lookupSubjects` is.

Test fixtures: `en-core/src/En/Conformance/Kikan.hs` provides `kikanSchema` /
`kikanGraph`, `fixtureTuples`, and in-memory interpreters (`runTupleStoreInMemory`,
`runConsistencyStoreInMemory`). Ready-made scenarios: `usersetMemberSpace` has
`member` granted to the userset `org:acme#member` and `agencyUser` is a member of
`org:acme` (group nesting); `intention` has a `delegate` grant to `user:alice` carrying
the `within_autonomy` caveat (caveated member; `requestContext` satisfies it,
`missingAutonomyContext` leaves an obligation); `exclusionSpace` has permission
`member_not_owner = member but not owner` with `memberOnly` (member only) and
`memberOwner` (member and owner); `auditedSpace` has `audit = owner & member` with
`memberOwner` holding both. The kikan schema has no wildcard relation, so the wildcard
test defines a minimal local schema in the test (via `En.Schema.Builder`, e.g.
`relation reader: user, user:*`). The conformance suite is
`en-core/conformance/Main.hs` (`en-core-conformance` in `en-core/en-core.cabal`).

External sequencing restated from the master plan: prefer landing
`docs/plans/35-version-the-wire-contract-and-type-the-error-model.md` (master plan 6)
first so the new endpoint is born inside the versioned wire contract; and see the
Decision Log for the soft ordering after `docs/plans/40` and `docs/plans/42`.


## Plan of Work

Three milestones: the core algorithm with conformance tests (M1), the HTTP surface
(M2), and the live demonstration (M3).


### Milestone 1: the core algorithm

Scope: after this milestone, `En.LookupSubjects.lookupSubjects` works against the
in-memory store with correct operator, caveat, and wildcard handling, proven by
conformance tests.

Create `en-core/src/En/LookupSubjects.hs` (add to `exposed-modules` in
`en-core/en-core.cabal`; dependencies are all already in scope). Public shape,
mirroring `En.Lookup`'s vocabulary:

```haskell
module En.LookupSubjects (
    LookupSubjectsRequest (..),
    LookupSubject (..),
    LookupSubjectsState (..),
    LookupSubjectsPage (..),
    LookupSubjectsCursor (..),
    lookupSubjects,
    lookupSubjectsWithDeadline,
    lookupSubjectsWithDeadlineCached,
) where

data LookupSubjectsRequest = LookupSubjectsRequest
    { object :: !ObjectRef
    , permission :: !RelationName
    , subjectType :: !ObjectType
    , context :: !CaveatContext
    , limit :: !Int
    , cursor :: !(Maybe LookupSubjectsCursor)
    }

data LookupSubject = LookupSubject
    { subject :: !Subject      -- SubjectId or SubjectWildcard of subjectType
    , decision :: !CheckDecision
    }

data LookupSubjectsState
    = SubjectsExhausted
    | SubjectsHasMore !LookupSubjectsCursor
    | SubjectsTruncated !LookupSubjectsCursor

data LookupSubjectsPage = LookupSubjectsPage
    { subjects :: ![LookupSubject]
    , state :: !LookupSubjectsState
    }
```

(If `docs/plans/51` has landed, `LookupSubjectsPage` also carries
`checkedAt :: ConsistencyToken` — see Decision Log.) The entry points take the same
constraint set as lookup (`ConsistencyStore :> es, TupleStore :> es, Error EnError :>
es`, plus `IOE` for the cached variant), a `ReachabilityGraph`, a `Consistency`, a
`Lookup.Deadline (Eff es)` (reuse the type from `En.Lookup` — export it there if not
already), and the request.

The traversal. Resolve consistency exactly as lookup does (fresh `resolveConsistency`
on the first page; on cursor resume, the revision decoded from the cursor). Then walk
the rewrite of `object#permission` (found via `graph.relations` keyed by
`RelationRef{objectType = object.objectType, relation = permission}`) carrying an
`EvalState` of depth (`maxDepth = 25`, matching the other evaluators), a visited list
of `(object, relation)` subproblems (revisit ⇒ empty set, per the Decision Log), and
producing `[LookupSubject]`:

- `This`: drain `readObjectRelation revision object relation` pages (copy
  `readObjectRows` from `En.Expand`). For each row: a `SubjectId` whose type equals
  the requested `subjectType` becomes a candidate with decision `Allowed` gated by the
  row's tuple caveat (reuse the `includeDecision`/`applyTupleCaveat` pattern — a
  caveat evaluated against the request context yields `Allowed`, `Denied` (drop the
  row), or `Conditional` obligations); a `SubjectWildcard` of the requested type
  becomes a wildcard candidate, likewise caveat-gated; a `SubjectSet inner rel`
  recurses into `inner#rel` and gates the recursive results with the row's caveat;
  subjects of other types are skipped.
- `ComputedUserset rel`: recurse on the same object with `rel`.
- `TupleToUserset tupleset computed`: drain the tupleset rows; for each row's subject
  object (`SubjectId` or the object of a `SubjectSet`), recurse into
  `target#computed`, gating results with the row's caveat; wildcard tupleset rows
  contribute nothing (matching check's behavior in `evalTupleToUserset`).
- `Union rewrites`: evaluate all branches and merge by subject, combining decisions
  with `Decision.union` per subject (copy `mergeLookupObjects` from `En.Lookup`,
  keyed by `Subject` — `Subject` has `Ord`).
- `Intersection rewrites` and `Exclusion base subtract`: collect candidates from the
  union of branches (for exclusion, from `base` only), then confirm each candidate by
  running the injected checker (`check` or `checkCached`) for
  `(candidate subject, permission-of-this-node's-relation, object)` at the request's
  `Consistency`, keeping `Allowed`/`Conditional` results with the checker's decision
  and dropping `Denied` — a direct port of `confirmCandidates` in
  `en-core/src/En/Lookup.hs`. Wildcard candidates are confirmed as the wildcard
  subject itself (see Decision Log).
- `Caveated name inner`: evaluate `inner`, then gate every result's decision with the
  named caveat evaluated at empty payload (port `applyRewriteCaveat`).

Paging: sort the merged results by subject, drop everything at or before the cursor's
`lastSubject`, take `min limit resultCap` (`resultCap = 1000`, matching lookup),
consult the deadline to choose `SubjectsHasMore` (budget remains) versus
`SubjectsTruncated` (budget exhausted) when more results exist, else
`SubjectsExhausted` — a direct port of `pageLookup`. The cursor codec ports
`encodeLookupCursor`/`decodeLookupCursor` with prefix `lookupsubjects-v1` and fields:
revision, subject type, subject id (empty string plus a wildcard marker field for
wildcard subjects). Malformed cursors are
`Left (InvalidConsistencyToken "lookup-subjects cursor")`.

Conformance tests in `en-core/conformance/Main.hs` (follow the suite's existing
style), all against `kikanGraph`, `fixtureTuples`, and the in-memory interpreters:

- Direct + group nesting: `lookupSubjects` on `usersetMemberSpace#view`,
  `subjectType = user` returns `agency-alice` (reached only through
  `org:acme#member`) — flat, not as a userset node.
- Caveated member: `intention#view` with `requestContext` returns alice `Allowed`;
  with `missingAutonomyContext` returns alice `Conditional` with the
  `within_autonomy` obligation naming the missing key.
- Exclusion: `exclusionSpace#member_not_owner` returns `member-only` and not
  `member-owner`.
- Intersection: `auditedSpace#audit` returns `member-owner` only.
- Wildcard: a local builder schema with `reader: user, user:*` and a wildcard tuple —
  the result contains one `SubjectWildcard user` entry and any concrete grants as
  separate entries.
- Pagination: with `limit = 1`, walking cursors visits each subject exactly once, in a
  deterministic order, ending `SubjectsExhausted`.

Acceptance: `cabal build en-core && cabal test en-core` passes (both the interface and
conformance suites).


### Milestone 2: endpoint, seam, server, client

Scope: after this milestone `POST /lookup-subjects` works end to end and the typed
client can call it.

In `en-servant/src/En/Servant/Seam.hs`, add to `Env`:

```haskell
    , lookupSubjectsOperation :: !(LookupSubjects.Deadline' -> ReachabilityGraph -> Consistency -> LookupSubjects.LookupSubjectsRequest -> Eff es LookupSubjects.LookupSubjectsPage)
```

(concretely, the same `Lookup.Deadline (Eff es)` type the lookup field uses). In
`en-server/app/Main.hs`, wire it beside `lookupWithDeadlineOperation`: the cached
variant (`lookupSubjectsWithDeadlineCached checkCacheEnv`) when the decision cache is
enabled, else `lookupSubjectsWithDeadline`.

In `en-servant/src/En/Servant/API.hs`, add the route

```haskell
        :<|> "lookup-subjects" :> ReqBody '[JSON] LookupSubjectsRequestWire :> Post '[JSON] LookupSubjectsPageWire
```

and the DTOs (generic Aeson like their neighbors): `LookupSubjectsRequestWire`
(`consistency`, `object`, `permission`, `subjectType`, `context`, `limit`, `cursor`,
`deadlineMillis` — the deadline handled exactly as `lookupHandler`'s `lookupDeadline`
helper does, defaulting to 3000 ms), `LookupSubjectWire` (`subject :: SubjectWire`,
`decision :: CheckDecisionWire` — wildcards ride the existing `SubjectWildcardWire`
constructor, so they are distinct on the wire for free), `LookupSubjectsStateWire`
(`Exhausted`/`HasMore cursor`/`Truncated cursor`), and `LookupSubjectsPageWire`
(`subjects`, `state`, plus `checkedAt` per the Decision Log). The handler validates
inputs with the existing `either400` helpers and dispatches through
`env.lookupSubjectsOperation`.

Add the `lookupSubjects` field to `EnClient` in `en-client/src/En/Client.hs`,
extending the `:<|>` pattern in API order. Extend `en-servant/test/Main.hs` with a
handler-level round trip against the in-memory interpreters (group-nesting fixture)
and a 400 for an empty `subjectType`.

Acceptance: `cabal build all && cabal test en-servant` passes.


### Milestone 3: live demonstration

Scope: run the sharing-dialog query against a real server and record the transcript in
Validation and Acceptance.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/en` in the dev shell.

Build and test without a database:

```bash
cabal build all
cabal test en-core
cabal test en-servant
```

Start the dev PostgreSQL and the server (Justfile: `process-up` starts PostgreSQL via
process-compose and waits for readiness; `start-server` applies the migrations under
`en-migrations/db/migrations/` with `psql`, then runs `cabal run en-server`):

```bash
just process-up
just start-server
```

Afterwards: `just process-down`.

For the live demo, use the built-in demo schema (`user`; `space` with relation
`viewer` and permission `view = viewer`; served when `EN_SCHEMA_PATH` is unset). Seed
two viewers:

```bash
curl -sS -X POST localhost:8080/tuples -H 'content-type: application/json' -d '{
  "tuples": [
    {"object": {"objectType": "space", "objectId": "project-x"}, "relation": "viewer",
     "subject": {"tag": "SubjectIdWire", "contents": {"objectType": "user", "objectId": "alice"}}, "caveat": null},
    {"object": {"objectType": "space", "objectId": "project-x"}, "relation": "viewer",
     "subject": {"tag": "SubjectIdWire", "contents": {"objectType": "user", "objectId": "bob"}}, "caveat": null}
  ]
}'
```


## Validation and Acceptance

Live acceptance — "who can view space project-x?":

```bash
curl -sS -X POST localhost:8080/lookup-subjects -H 'content-type: application/json' -d '{
  "consistency": {"tag": "FullyConsistentWire"},
  "object": {"objectType": "space", "objectId": "project-x"},
  "permission": "view",
  "subjectType": "user",
  "context": {"values": {}},
  "limit": 10,
  "cursor": null,
  "deadlineMillis": null
}'
```

Expected response shape (subject order is deterministic; `checkedAt` present if the
EP-51 convention is in — see Decision Log):

```json
{
  "subjects": [
    {"subject": {"tag": "SubjectIdWire", "contents": {"objectType": "user", "objectId": "alice"}},
     "decision": {"tag": "AllowedWire"}},
    {"subject": {"tag": "SubjectIdWire", "contents": {"objectType": "user", "objectId": "bob"}},
     "decision": {"tag": "AllowedWire"}}
  ],
  "state": {"tag": "SubjectsExhaustedWire"}
}
```

With `"limit": 1` the same request returns one subject and
`{"tag": "SubjectsHasMoreWire", "contents": "<cursor>"}`; re-issuing with that cursor
returns the second subject and then exhaustion — no duplicates, no gaps.

The operator/caveat/wildcard correctness — the substance of this plan — is validated
by the M1 conformance tests (`cabal test en-core`), which encode: group nesting
resolves to flat concrete members; a caveated grant is `Conditional` with the right
obligation when context is missing and `Allowed` when supplied; an excluded subject is
absent even though the base branch grants it; an intersection returns only subjects
satisfying all branches; a wildcard grant appears as a distinct wildcard entry. These
tests fail against a naive flatten-the-expand-tree implementation, which is the point.

If `docs/plans/35`'s versioned contract has landed, adjust the route prefix, tag
names, and error envelope accordingly and note it in the Decision Log.


## Idempotence and Recovery

The algorithm is a pure function of the store at a fixed revision; requests are safe
to repeat and pages are deterministic for a fixed snapshot (the cursor pins the
revision, exactly like lookup). No migrations, no writes, no state. The main schedule
risk is inheriting engine defects through the confirmation step (check's
cycle-as-error B3 and exclusion/Conditional B4): if a conformance scenario hits them,
do not fork check's semantics inside this module — record the failing case in
Surprises & Discoveries, mark the test pending with a reference to `docs/plans/40`,
and proceed; the scenario becomes the cross-check when EP-40 lands.


## Interfaces and Dependencies

End-state interfaces, by full module path:

- `En.LookupSubjects` (`en-core/src/En/LookupSubjects.hs`, new; listed in
  `en-core/en-core.cabal`): `LookupSubjectsRequest`, `LookupSubject`,
  `LookupSubjectsState`, `LookupSubjectsPage`, `LookupSubjectsCursor`, and
  `lookupSubjects :: (ConsistencyStore :> es, TupleStore :> es, Error EnError :> es)
  => ReachabilityGraph -> Consistency -> LookupSubjectsRequest -> Eff es
  LookupSubjectsPage`, plus `lookupSubjectsWithDeadline` (adds the
  `Lookup.Deadline (Eff es)` parameter) and `lookupSubjectsWithDeadlineCached` (adds
  `CheckCacheEnv` and `IOE :> es`). Uses only existing effects — no storage changes.
- `En.Servant.Seam` (`en-servant/src/En/Servant/Seam.hs`): `Env` gains
  `lookupSubjectsOperation`.
- `En.Servant.API` (`en-servant/src/En/Servant/API.hs`): route
  `POST /lookup-subjects`; wire types `LookupSubjectsRequestWire`,
  `LookupSubjectWire`, `LookupSubjectsStateWire`, `LookupSubjectsPageWire`.
- `en-server/app/Main.hs`: wires the cached/uncached operation into `Env`.
- `En.Client` (`en-client/src/En/Client.hs`): `EnClient` gains `lookupSubjects`.

Dependencies and coordination, restated so this plan stands alone: no hard
dependencies. Prefer landing after
`docs/plans/35-version-the-wire-contract-and-type-the-error-model.md` (versioned wire
contract). Soft ordering after `docs/plans/40-adopt-zanzibar-cycle-and-exclusion-semantics-in-check.md`
and `docs/plans/42-stream-lookup-pages-with-validated-cursors-and-a-real-deadline.md`
(see Decision Log). The response DTO carries `checkedAt` per
`docs/plans/51-return-checked-at-consistency-tokens-from-read-responses.md`, which
owns that convention. The master plan
(`docs/masterplans/9-complete-the-en-api-surface.md`) records why this plan lives in
the API master plan rather than the engine one: it is a new capability, not a fix. No
new package dependencies are required.
