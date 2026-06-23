---
id: 16
slug: make-lookup-streaming-with-resumable-cursors-and-a-deadline-budget
title: "Make lookup streaming with resumable cursors and a deadline budget"
kind: exec-plan
created_at: 2026-06-23T16:37:01Z
intention: "intention_01kvv5mecvechb6c6jv3p3zv4a"
master_plan: "docs/masterplans/3-harden-en-correctness-fixes-lookup-streaming-and-performance-benchmarks.md"
---

# Make lookup streaming with resumable cursors and a deadline budget

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`en` (縁) is a relationship-based access-control toolkit written in Haskell. Its job is to
answer authorization questions over a graph of relationships ("who is related to what, and
how"). One of its three query verbs is **`lookup`**: given a subject (a user, an org, an
agent), a permission (like `view`), and an object *type* (like `space`), it returns the list
of objects of that type on which the subject has that permission. This is the "reverse
expansion" query — it walks the relationship graph *backwards*, from the subject toward the
resources, instead of forwards from a single resource. It is the engine's **read-filter
primitive**: a consuming service (for example kawa, which stores a stream of activities)
calls `lookup` to learn the small set of spaces or visibility-classes a subject can reach,
then filters its own large table with `… WHERE space IN (:reachable)`. The `lookup` result
set is supposed to stay small (tens of labels), but the *intermediate* traversal can touch
many relationship rows.

Today `lookup` has a sharp correctness bug hiding behind a performance limitation. It is
**eager-then-capped**, not streaming. Concretely:

- `runLookup` (`en-core/src/En/Lookup.hs`, around lines 107–109) computes the **entire**
  candidate set in memory first, then `pageLookup` (around lines 566–577) slices that
  in-memory list with an integer offset and applies a hard `resultCap = 1000` *after* the
  whole computation already ran.
- Every intermediate read of the relationship store goes through `readRowsForSubjects`
  (around lines 391–412), which calls `ensureExhausted` (around lines 414–419). That helper
  **errors with `ResolutionLimitExceeded`** the moment any single storage read reports
  `HasMore` or `Truncated` — i.e. if the intermediate result does not fit in one page of
  1000 rows. So a `lookup` whose reverse walk legitimately passes through more than one
  page of relationship rows **fails outright** instead of paging through them.

This means the design the spec calls for in `docs/spec/0001-en-overview.md` §5.4 —
"bounded, possibly-truncated **by design**", driven by a **deadline plus a max-results cap**,
streamed through resumable cursors — does not exist. The "cursor" the API hands back is just
an integer offset that forces the whole expensive computation to re-run on the next page.

After this change:

- A `lookup` whose intermediate reverse reads span **multiple storage pages** returns the
  **complete, correctly ordered, de-duplicated** result set across cursor continuations,
  instead of raising `ResolutionLimitExceeded`. This is the headline behavior; there is a
  test that fails before this plan and passes after.
- The cursor handed back in the response is a **real resumable token**: it encodes enough
  traversal state (and the snapshot/revision the lookup is reading at) to *continue* the
  paginated walk without recomputing from scratch.
- A **deadline budget** (a wall-clock time limit, default in the low single-digit seconds,
  configurable) means a `lookup` that cannot finish in time returns a *truncated* page plus a
  continuation cursor, rather than running unbounded. Truncation is surfaced on the existing
  HTTP wire (`LookupStateWire` in `en-servant/src/En/Servant/API.hs`).

The reverse-expansion **algorithm itself is correct and is preserved**. We change *how it is
driven* (streaming, resumable, deadline-bounded), not *what it computes*.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M0 (orientation, no code): re-read `En.Lookup`, `En.Check`, `En.Effect.TupleStore`,
  `En.Postgres.TupleStore`, `En.Servant.API`; confirm the symbols and line ranges this plan
  cites still match the tree; record any drift in Surprises & Discoveries. Completed 2026-06-23.
- [x] M1: add a failing acceptance test in `en-core/test/Main.hs` — a subject that reaches
  more than one storage page of candidates — and confirm it fails today with
  `Left ResolutionLimitExceeded`. Completed 2026-06-23 with a 1,200-folder regression test.
- [x] M2: introduce the resumable cursor codec and the `Deadline` clock seam in `En.Lookup`;
  keep behavior identical (still eager) so all existing tests stay green. Completed 2026-06-23.
- [x] M3: replace `ensureExhausted` with a paging reader that drains storage pages; remove
  the multi-page hard-fail; M1's acceptance test now passes for the no-cursor (single-call)
  case. Completed 2026-06-23.
- [x] M4: make the cursor resumable with the pinned revision and last emitted object key; prove
  page-by-page continuation returns the same complete set as a single call. Completed 2026-06-23.
- [x] M5: add the deadline budget; prove a tiny deadline yields `LookupTruncated` with a
  usable continuation cursor and that resuming past it eventually completes. Completed 2026-06-23.
- [x] M6: thread the deadline default/config and the resumable cursor through
  `en-servant` (`lookupHandler`, `LookupStateWire`); add an `en-postgres` integration test
  that exercises real multi-page storage paging. Completed 2026-06-23.
- [x] M7: decide Expand's scope — apply the same paging treatment to `En.Expand`; reconcile
  the `En.Decision` soft dependency on EP-15. Completed 2026-06-23.
- [x] Final: update Outcomes & Retrospective; run `cabal build all` and `cabal test all`
  green; note cross-plan inconsistencies. Completed 2026-06-23.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The `LookupCursor`, `StoreCursor`, `ExpandCursor`, and `LookupStateWire`/`ExpandStateWire`
  types already carry an **opaque `Text`** payload (see `LookupCursor { cursorEncoding ::
  Text }` at `En.Lookup` ~lines 40–43, and `LookupHasMoreWire !Text` at `En.Servant.API`
  ~lines 219–224). So making the cursor resumable is a change to *what we encode into that
  Text*, **not** a change to any type's shape or the HTTP contract. This is a happy
  accident and significantly de-risks the wire changes. _(2026-06-23)_

- `en-core` is a **pure** library: every engine function is `(Monad m) => …`, with no
  `MonadIO`. There is no clock available inside the traversal. The deadline therefore cannot
  be read from `getCurrentTime` *inside* `En.Lookup`; it must be supplied through a small
  injected seam (a `Deadline` value carrying a "remaining budget" check the caller threads
  in). The `time` package is already a dependency of `en-core`. See Decision Log "deadline
  default" and "deadline clock seam". _(2026-06-23)_

- `En.Expand` (`en-core/src/En/Expand.hs`) has the **identical** eager-then-cap shape: its
  `ensureExhausted` (~lines 273–278) errors on `HasMore`/`Truncated`, and `pageNodes`
  (~lines 286–297) is an integer-offset slice. It shares the bug. M7 decides whether to fix
  it here. _(2026-06-23)_

- EP-15 (`docs/plans/15-generalize-the-caveat-evaluator-and-unify-the-decision-algebra.md`)
  landed before this plan ran. `En.Decision` exists, and `En.Lookup` already delegates
  decision combination through it where it computes lookup decisions. `confirmCandidates`
  still calls `En.Check.check` because reach-then-check needs the full forward evaluator,
  not only the algebra helpers. _(2026-06-23)_

- The in-memory test store's `StoreCursor` semantics were off by one for multi-page reads: it
  returned the next row index while resume used `drop cursor`, skipping that row. PostgreSQL
  already uses the last visible row id as the cursor. The test store was aligned with the
  PostgreSQL semantics while adding the 1,200-row regression. _(2026-06-23)_


## Decision Log

Record every decision made while working on the plan.

- Decision: **Cursor encoding** — encode the resumable cursor as a small, versioned,
  length-prefixed `Text` record stored in the existing `LookupCursor` payload. The record
  carries the resolved revision string and the last emitted `ObjectRef`; continuation reads
  the same snapshot and emits objects strictly greater than that key.
  Rationale: it reuses the existing opaque-`Text` cursor fields without adding `aeson` or a
  base64 dependency to `en-core`, pins the snapshot for correctness, and is enough for the
  shallow, bounded result sets `en` is designed to return. A fully incremental frontier that
  persists storage sub-cursors is left for benchmark-driven optimization if EP-17 proves it
  necessary.
  Date: 2026-06-23

- Decision: **Deadline default** — the per-request deadline defaults to **3 seconds**, and is
  configurable per request (and via a server-level default). This matches OpenFGA's
  ListObjects default (3s/1000) cited in spec §5.4 and is the documented "few-seconds range".
  Rationale: spec §5.4 says lookup is "bounded, possibly-truncated by design" with "a
  deadline + max-results cap (OpenFGA defaults 3s / 1000; SpiceDB 1000)". 3s is the
  reference default and a safe ceiling for an interactive read-filter call.
  Date: 2026-06-23

- Decision: **Deadline clock seam** — because `en-core` is pure (`Monad m`, no `MonadIO`),
  the deadline is passed into `lookup` as a `Deadline m` value: an injected effect the
  traversal can poll between storage pages to ask "is there budget left?". The PostgreSQL/IO
  caller (`en-servant`) constructs it from a monotonic clock and the configured budget; the
  in-memory test store constructs either an "infinite budget" deadline (default) or a
  "already expired / expires after N polls" deadline to drive truncation tests
  deterministically.
  Rationale: keeps `en-core` free of `IO`/clock dependencies (preserving the package
  boundary documented in `en-core.cabal`: "depends on no Servant, WAI, PostgreSQL, or HTTP
  library"), while letting the real service enforce wall-clock time and letting tests be
  deterministic.
  Date: 2026-06-23

- Decision: **Expand scope** — *(provisional; finalized in M7)* apply the **paging fix**
  (drain multi-page storage reads instead of erroring) to `En.Expand` as well, because it is
  a near-mechanical mirror of the `En.Lookup` `ensureExhausted` change and leaving it broken
  would mean `expand` still hard-fails on multi-page objects. The **resumable-cursor** and
  **deadline** parts are scoped to `lookup` only for this plan; `expand` keeps its existing
  integer-offset cursor over the now-complete node list. If M7 finds the Expand paging change
  is more than mechanical, defer it entirely with a follow-up note here.
  Rationale: the masterplan's Integration Point 3 names `En.Lookup` and the lookup wire as
  EP-16's surface; `expand` shares only the paging bug. Fixing the shared paging bug is cheap
  and correctness-relevant; reworking `expand`'s cursor is not in this plan's headline.
  Date: 2026-06-23

- Decision: **En.Decision dependency** — because EP-15 landed first, EP-16 keeps the existing
  `En.Decision` usage in `En.Lookup`. `confirmCandidates` continues to call `En.Check.check`
  directly.
  Rationale: confirmation is not just decision algebra; it asks the forward evaluator to
  decide each candidate against the full rewrite.
  Date: 2026-06-23


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

EP-16 completed on 2026-06-23. `En.Lookup` now drains multi-page `readStartingWithUser`
results instead of treating `HasMore` as `ResolutionLimitExceeded`; the in-memory regression
uses 1,200 folders and proves cursor continuation returns the complete ordered result set.
Lookup cursors are versioned, revision-pinned, and based on the last emitted object key; stale
integer cursors are rejected as invalid lookup cursors.

The deadline seam is `Deadline m`, with `lookupWithDeadline` for callers that can supply a
budget and the existing `lookup` preserved as the no-deadline wrapper. `en-servant` accepts an
optional `deadlineMillis` field and builds a monotonic-clock deadline with a 3-second default.
`En.Expand` now drains multi-page object reads before applying its existing 1,000-node result
cap. `en-postgres` integration writes 1,500 real rows and proves lookup drains them across
cursor pages.


## Context and Orientation

You are working in the `en` repository (working directory `/Users/shinzui/Keikaku/bokuno/en`
on disk; all paths below are repository-relative). `en` is a Haskell **Cabal multi-package**
project. The packages relevant here are:

- **`en-core`** — the pure engine. No database, no HTTP. Defines the query algorithms
  (`En.Check`, `En.Lookup`, `En.Expand`), the storage interface as a record of functions
  (`En.Effect.TupleStore`), the consistency-resolution interface
  (`En.Effect.ConsistencyStore`), the error type (`En.Error`), and the data model
  (`En.Tuple`, `En.Schema`, `En.Reachability`, `En.Revision`). Its cabal file declares it
  "depends on no Servant, WAI, PostgreSQL, or HTTP library" — keep it that way.
- **`en-postgres`** — the PostgreSQL implementation of the storage interface
  (`En.Postgres.TupleStore`) and the revision/consistency-token machinery
  (`En.Postgres.Revision`).
- **`en-servant`** — the HTTP API (`En.Servant.API`), built with the Servant library. It
  translates JSON request/response shapes ("wire" types, suffixed `Wire`) to and from the
  engine's types and calls the engine.

Define the terms this plan uses, in plain language:

- **Tuple / relationship tuple**: one stored fact of the form *object#relation@subject*, e.g.
  `space:project-x # member @ user:alice`. It says "alice is a member of space project-x".
  Modeled by `En.Tuple.Tuple`. A subject can itself be a *userset* (`SubjectSet object
  relation`, e.g. "every member of org:acme"), which is how groups-of-groups work.
- **Permission / relation**: a named edge type on an object. Some relations are stored
  directly; others are computed from a **rewrite** (a small expression combining other
  relations with union/intersection/exclusion/caveat). `En.Schema.Rewrite` is that
  expression type; its constructors are `This`, `ComputedUserset`, `TupleToUserset`, `Union`,
  `Intersection`, `Exclusion`, `Caveated`.
- **Reachability graph** (`En.Reachability.ReachabilityGraph`): the schema compiled into a
  form the traversal can walk. `graph.relations` maps a `RelationRef{objectType, relation}`
  to its `Relation` (which carries the `rewrite` and the set of `allowedSubjects`).
- **`readStartingWithUser`** (`En.Effect.TupleStore`, the record field at ~line 72): the one
  reverse storage primitive — "give me the tuples of type *T* on relation *R* whose subject
  is one of these subjects." It takes a `UsersetQuery` (with a `queryLimit` and an optional
  `queryCursor :: Maybe StoreCursor`) and returns a `TuplePage { rows, state }`. The `state`
  is a `PageState`: `Exhausted` (no more rows), `HasMore StoreCursor` (more rows; resume with
  this cursor), or `Truncated StoreCursor` (storage gave up early; resume with this cursor).
- **Caveat**: a named, bounded condition attached to a tuple or rewrite (e.g. "valid until
  time T", "only at autonomy level ≤ act"). Evaluating one against request context
  (`CaveatContext`) yields a three-valued `CheckDecision`: `Allowed`, `Denied`, or
  `Conditional [obligations]` (the path exists but needs more context before the caller may
  treat it as allowed).
- **Reach-then-check**: the strategy for intersection/exclusion. The reverse walk cheaply
  *over-generates* candidates from the "easy" (union-shaped) branch, then a forward
  `En.Check.check` *confirms* each candidate against the full rewrite (including the
  intersected/excluded branches). `confirmCandidates` (`En.Lookup` ~lines 368–389) does this.
- **Revision / consistency**: every read happens at a `Revision` (a PostgreSQL `pg_snapshot`
  — a point-in-time view of the database). The `Consistency` argument (e.g. `MinimizeLatency`,
  `FullyConsistent`, `AtLeastAsFresh token`) selects which revision; `ConsistencyStore`
  resolves it to a concrete `Revision`. A resumable cursor must pin the revision so each page
  reads the same snapshot.

How the current `lookup` is structured (read `en-core/src/En/Lookup.hs` end to end first):

1. `lookup` (~lines 83–96) resolves the consistency to a concrete `Revision`, then calls
   `runLookup`.
2. `runLookup` (~lines 98–109) calls `evalRelation` to compute **all** candidates eagerly
   into a `[LookupObject]`, then calls `pageLookup` to slice that list.
3. `evalRelation` → `evalRewrite` (~lines 143–219) dispatches on the rewrite:
   - `This` → `evalThis` (~lines 221–264): reads direct rows via `readRowsForSubjects`, and
     for userset-typed allowed subjects recurses and reads their rows. This is driven by
     `readStartingWithUser`.
   - `ComputedUserset` → recurse on another relation.
   - `TupleToUserset` → `evalTupleToUserset` (~lines 266–353): the reverse walk over an
     arrow, including the recursive-relation fixpoint `expandRecursive` (~lines 328–339).
   - `Union` → evaluate every branch and merge.
   - `Intersection` / `Exclusion` → evaluate the union-shaped base, then
     `confirmCandidates` runs a forward `check` per candidate.
   - `Caveated` → evaluate inner and apply the caveat gate.
4. Every storage read funnels through `readRowsForSubjects` (~lines 391–412) →
   `ensureExhausted` (~lines 414–419), which is the hard-fail: it `Right rows` only when the
   page is `Exhausted`, otherwise `Left ResolutionLimitExceeded`.
5. `pageLookup` (~lines 566–577) slices with `decodeCursor` (an integer) and applies
   `resultCap = 1000`.

**The algorithm in steps 3 is correct and must be preserved.** This plan changes steps 2, 4,
and 5: drain multi-page reads instead of erroring (step 4), produce results incrementally and
stop at a budget/limit (step 2), and hand back a resumable cursor instead of an integer offset
(step 5).

The HTTP surface (`en-servant/src/En/Servant/API.hs`): `lookupHandler` (~lines 324–346)
builds a `Lookup.LookupRequest` from the JSON `LookupRequestWire` (which has `limit :: Int`
and `cursor :: Maybe Text`, ~lines 200–210) and converts the engine's `LookupPage` back with
`lookupPageToWire`/`lookupStateToWire` (~lines 488–504). The wire state type `LookupStateWire`
(~lines 219–224) is `LookupExhaustedWire | LookupHasMoreWire !Text | LookupTruncatedWire
!Text`. We reuse all of these; only the *content* of the cursor `Text` changes, plus a new
optional deadline field on the request.

Related plans (referenced by path only, per the spec):

- Master plan: `docs/masterplans/3-harden-en-correctness-fixes-lookup-streaming-and-performance-benchmarks.md`
  (this is EP-16; see its Integration Point 3 and the EP-15 soft dependency).
- `docs/plans/15-generalize-the-caveat-evaluator-and-unify-the-decision-algebra.md` (extracts
  `En.Decision`; soft dependency — see Decision Log).
- `docs/plans/17-strengthen-the-lookup-spike-and-add-performance-regression-benchmarks.md`
  (benchmarks this path; must use EP-16's final cursor contract).
- `docs/plans/18-conformance-a-guarded-route-example-and-the-kikan-agency-proof.md` (consumes
  streaming lookup for read-filter conformance).


## Plan of Work

The work is broken into milestones M0–M7 plus a Final wrap-up. Each is independently
verifiable. The guiding principle is **additive, test-green-at-each-step** change: introduce
the new machinery alongside the old, prove it, then remove the old. The existing test suite
(`en-core/test/Main.hs`) has many `lookup` assertions (lines ~117–124); none of them may
regress.


### M0 — Orientation and drift check (no code)

Scope: confirm the citations in this plan against the current tree before editing anything.
Read `en-core/src/En/Lookup.hs`, `en-core/src/En/Check.hs`, `en-core/src/En/Effect/TupleStore.hs`,
`en-postgres/src/En/Postgres/TupleStore.hs`, and `en-servant/src/En/Servant/API.hs`. If any
symbol named in this plan has moved or changed shape, record the drift in Surprises &
Discoveries and adjust the steps below in place (this is a living document).

What exists after: nothing new in code; a confirmation note in Surprises & Discoveries.

Commands: from the repository root,

```bash
cabal build all
cabal test all
```

Acceptance: the project builds and all existing tests pass *before* you change anything (so
you have a clean baseline). Record the test count you observe.


### M1 — Add the failing acceptance test (red)

Scope: write the headline acceptance test in `en-core/test/Main.hs` *first*, and watch it
fail with the current code. The test models a single subject who legitimately reaches **more
than one storage page** of candidate objects on a single relation.

The existing in-memory store (`inMemoryTupleStore`, ~lines 544–582 of `en-core/test/Main.hs`)
already pages correctly: `pageTuples` returns `HasMore (StoreCursor "<nextIndex>")` when more
rows remain than `queryLimit`. So to force multi-page intermediate reads you need *two*
ingredients: (a) enough tuples that the engine's per-read page size is exceeded, and (b) a
relation whose evaluation reads those tuples directly.

The simplest construction: add a new object type/relation to the test schema — call it a
`folder` with a direct `viewer` relation — and a fixture of, say, **1,200** tuples
`folder:f1..f1200 # viewer @ user:paginator`. With the engine's internal page size (today the
constant `pageLimit = 1000` in `En.Lookup`, ~line 138) this read spans two pages.

Add to the test fixtures (near `fixtureTuples`) a helper that generates these tuples, extend
`kikanSchema` (or add a sibling schema used only by this assertion) with the `folder#viewer`
relation, and add an assertion:

```haskell
-- The subject `paginator` reaches 1200 folders via a direct relation, which
-- spans more than one internal storage page. A streaming lookup must return all
-- 1200 across cursor continuations without raising ResolutionLimitExceeded.
allFolders <- collectAllPages
    consistencyStore tupleStore graph
    (lookupRequest (SubjectId paginator) (RelationName "viewer") (ObjectType "folder")
        requestContext (LookupLimit 500) Nothing)
assertEqual "streaming lookup returns every reachable folder across pages"
    1200 (length allFolders)
```

`collectAllPages` is a new test helper: it calls `Lookup.lookup`, and while the returned
`state` is `LookupHasMore cursor`, it calls again with that cursor, accumulating `objects`,
stopping at `LookupExhausted` (and failing the test if it sees `LookupTruncated`, since this
case has an effectively-infinite deadline). Write it in the test file.

What exists after: a new test that **fails** today. With the current code it fails not by
returning fewer rows but by returning `Left ResolutionLimitExceeded` from the very first
call (because `ensureExhausted` rejects the `HasMore` page). Capture that failure output in
the Concrete Steps section as evidence.

Commands:

```bash
cabal test en-core:en-core-interface-tests
```

Acceptance: the new assertion fails, and the failure is the `ResolutionLimitExceeded` error
(or a `length` mismatch), demonstrating the bug. **All other existing assertions still pass.**


### M2 — Resumable cursor codec and the Deadline seam (still eager; green)

Scope: introduce the new types and the cursor encode/decode without changing behavior yet, so
the suite stays green. This isolates the "new machinery compiles and round-trips" risk from
the "traversal rewrite" risk.

In `en-core/src/En/Lookup.hs`:

1. Define an internal `LookupCursorState` record and a codec:

   ```haskell
   data LookupCursorState = LookupCursorState
       { version  :: !Int          -- cursor format version, start at 1
       , revision :: !Revision     -- the pinned snapshot to resume reading at
       , frontier :: ![FrontierStep]  -- ordered remaining work (see M4)
       }

   encodeLookupCursor :: LookupCursorState -> LookupCursor
   decodeLookupCursor :: LookupCursor -> Either EnError LookupCursorState
   ```

   Encode as base64url-wrapped JSON (use `aeson` for the JSON and `base64-bytestring` or
   `Data.ByteString.Base64.URL` for the wrapping; add the dependency to `en-core.cabal` if
   not present — check first, `bytestring` is already there). A malformed cursor decodes to
   `Left (InvalidConsistencyToken "lookup cursor")` (reuse that existing `EnError`
   constructor, or add a dedicated one if you prefer — record the choice in the Decision Log).
   For M2, `frontier` can be a placeholder `[]`; M4 fills it with real content.

2. Define the deadline seam:

   ```haskell
   newtype Deadline m = Deadline { remainingBudget :: m Bool }
   -- remainingBudget returns True while there is time left, False once exhausted.

   noDeadline :: Applicative m => Deadline m
   noDeadline = Deadline (pure True)
   ```

   Add a `deadline :: !(Deadline m)` knob to `LookupRequest`? No — `LookupRequest` derives
   `Eq`/`Show` and is pure data; a function field breaks that. Instead pass `Deadline m` as
   a **separate argument** to `lookup`/`runLookup` (after the `TupleStore m`). Update the one
   caller (`en-servant` `lookupHandler`) in M6; for now default the test call sites through a
   wrapper `lookup` that supplies `noDeadline` so existing tests are untouched, or thread
   `noDeadline` explicitly. Decide and record which; the cleaner option is to make `lookup`
   take the `Deadline m` and update every call site (there are few: `en-servant` and the
   tests).

What exists after: `LookupCursorState`, the codec, and `Deadline m` exist and are exported as
needed for tests. Behavior is unchanged (the old `pageLookup` still runs). M1's test still
fails (we have not fixed the traversal yet).

Commands:

```bash
cabal build all
cabal test en-core:en-core-interface-tests
```

Add a tiny round-trip property/assertion in the test: `decodeLookupCursor (encodeLookupCursor
s) == Right s` for a sample state. Acceptance: build is green; the round-trip assertion
passes; all *previously passing* tests still pass; M1's acceptance test still fails.


### M3 — Drain multi-page reads (remove the hard-fail; M1 single-call passes)

Scope: replace `ensureExhausted` (and the single-page `readRowsForSubjects`) with a reader
that **pages through storage** until the relevant rows are drained, so the algorithm sees the
complete intermediate row set. This is the smallest change that makes a *non-cursored*
`lookup` correct across multiple pages.

In `en-core/src/En/Lookup.hs`, replace `readRowsForSubjects`/`ensureExhausted` with a draining
reader:

```haskell
-- Page through readStartingWithUser, following HasMore cursors, accumulating all
-- rows for the given subjects at the given revision. Stops on Exhausted. On
-- Truncated, surfaces it (M5 wires the deadline; for now treat Truncated like
-- HasMore and keep draining, OR thread a budget — see below).
drainRowsForSubjects ::
    (Monad m) =>
    TupleStore m -> Revision -> ObjectType -> RelationName -> [Subject] ->
    m (Either EnError [TupleRow])
```

It loops: call `readStartingWithUser` with `queryCursor = Nothing` first, then with the
returned `StoreCursor` while the page state is `HasMore`. Concatenate `rows`. Keep `pageLimit
= 1000` as the per-read page size (it is now a *batch* size, not a hard ceiling). Because the
existing tests' stores return `Exhausted` quickly, they are unaffected; the new 1,200-tuple
fixture now drains two pages and returns all rows.

Leave `pageLookup` as-is for this milestone (it will still slice the now-complete list with an
integer offset). The point of M3 is only to stop the hard-fail and return the *complete* set
on a single call.

What exists after: a `lookup` with no incoming cursor and a generous limit returns the full,
complete candidate set even when intermediate reads spanned multiple storage pages.

Commands:

```bash
cabal test en-core:en-core-interface-tests
```

Acceptance: M1's `collectAllPages` test now returns **1200** folders and passes (the first
call already returns everything because the eager traversal drains all pages, and `pageLookup`
hands out 500 at a time over the complete in-memory list via the old integer cursor — that is
fine for M3). No existing assertion regresses. This proves the **headline acceptance**:
multi-page intermediate reads no longer raise `ResolutionLimitExceeded`.


### M4 — Make the cursor genuinely resumable (continue, don't recompute)

Scope: replace the integer-offset `pageLookup`/`decodeCursor` with the resumable cursor from
M2, so a continuation **resumes** the walk at the pinned revision rather than recomputing the
whole candidate set and re-slicing it.

For `en`'s shallow schemas the practical, correct design is a **two-level cursor**:

1. **Outer / storage frontier.** The dominant cost and the only genuinely unbounded source is
   the direct-read fan-out in `evalThis`/`evalTupleToUserset` over `readStartingWithUser`. The
   `FrontierStep` records the *remaining* storage sub-cursor(s) for the in-progress stage plus
   the still-unprocessed subproblems. On a continuation, `decodeLookupCursor` rebuilds the
   `EvalState`/frontier and the traversal resumes from the saved `StoreCursor` instead of from
   the beginning.

2. **Inner / result ordering.** Results are emitted in a **stable total order** so pages do
   not overlap or skip. The engine already sorts by object (`mergeLookupObjects` uses `sortOn
   (.object)`, ~lines 447–461, and `ObjectRef`/`Subject` derive `Ord`). The cursor records the
   last emitted object key; the next page emits objects strictly greater than it. This keeps
   the across-pages union complete and duplicate-free even if the underlying storage order and
   the result order differ.

Concretely, restructure `runLookup` into a producer that yields a bounded batch of ordered
`LookupObject`s plus a continuation:

```haskell
runLookup ::
    (Monad m) =>
    Deadline m -> ConsistencyStore m -> TupleStore m -> ReachabilityGraph ->
    Revision -> Consistency -> LookupRequest ->
    m (Either EnError LookupPage)
```

Implementation guidance for the shallow-schema case (the pragmatic choice, see Decision Log):
keep the existing eager `evalRelation` to produce the complete *ordered* candidate list at the
pinned revision, but make the cursor encode `(revision, lastEmittedObjectKey)` instead of an
integer index, and select the next page as "the first `limit` candidates whose key >
`lastEmittedObjectKey`". This is still O(full set) per page in the worst case, **but it is
correct, resumable across truncation, and snapshot-stable** — and for the bounded result sets
`en` is designed for (spec §6: tens of labels), it is the right tradeoff. Record in the
Decision Log that a fully incremental producer (carrying the storage `StoreCursor` in the
frontier so re-reads are avoided) is the optimization EP-17 may pursue if benchmarks demand
it; do not prematurely build the goroutine-style pipeline the spec §5 explicitly says maps
poorly onto Haskell.

**Pin the revision.** The first call resolves `Consistency` to a `Revision` and stores it in
the cursor. A continuation **ignores** the incoming `Consistency`'s freshness selection and
reads at the cursor's pinned revision (decode it; if absent or malformed, error
`InvalidConsistencyToken`). This guarantees a stable page sequence even under concurrent
writes — the same property the storage `pg_visible_in_snapshot` predicate gives within one
read.

What exists after: paginating with the returned cursor walks the complete set page by page,
and the concatenation of pages equals the single-call result, with no duplicates and no gaps.

Commands:

```bash
cabal test en-core:en-core-interface-tests
```

Add an assertion that drives `collectAllPages` with a *small* limit (e.g. `LookupLimit 100`
over the 1,200-folder fixture → 12 pages) and asserts the accumulated set is exactly the
1,200 folders, in sorted order, with no duplicates. Also keep the existing deterministic
pagination assertions (test lines ~123–124) passing — note their expected cursor strings will
change from `"1"` to the new encoded form, so **update those two expected values** to the new
cursor encoding (or assert on the *decoded* state rather than the raw text). Acceptance: full
set recovered across many small pages; existing pagination assertions updated and green.


### M5 — Deadline budget and truncation

Scope: wire the `Deadline m` into the producer so a lookup that exhausts its time budget
returns `LookupTruncated cursor` (a resumable continuation), per spec §5.4.

In the traversal's paging loop (the `drainRowsForSubjects` loop and the per-stage advance in
M4), poll `deadline.remainingBudget` **between storage pages** (not per row — polling a clock
per row is wasteful). When it returns `False`, stop draining, package the work done so far
into a `LookupCursorState`, and return a `LookupPage` whose `state` is `LookupTruncated`
carrying that cursor. The objects already collected are returned (a partial but valid page).

Add deterministic test deadlines to the in-memory harness:

```haskell
-- A deadline that reports "out of budget" after N successful polls.
budgetedDeadline :: IORef Int -> Deadline IO
budgetedDeadline ref = Deadline $ do
    n <- atomicModifyIORef' ref (\k -> (k - 1, k))
    pure (n > 0)
```

(Use `IORef` from `base`; the test already runs in `IO`.)

What exists after: a lookup with a deadline that expires mid-traversal returns
`LookupTruncated` with a usable cursor, and resuming from that cursor (with a fresh budget)
eventually drains the rest.

Commands:

```bash
cabal test en-core:en-core-interface-tests
```

Add assertions: (a) with `budgetedDeadline` allowing only 1 poll over the 1,200-folder
fixture, the first page's `state` is `LookupTruncated _`; (b) a loop that resumes the
truncated cursor with a fresh small budget each time still accumulates exactly 1,200 folders
and finally reaches `LookupExhausted`. Acceptance: both assertions pass; the "infinite
budget" path from M3/M4 is unchanged.


### M6 — Thread deadline and resumable cursor through en-servant (and storage paging)

Scope: surface the new capabilities on the HTTP boundary and (if feasible against a real
database) prove storage-level paging end to end.

In `en-servant/src/En/Servant/API.hs`:

1. Add an optional deadline to `LookupRequestWire` — e.g. `deadlineMillis :: Maybe Int`
   (defaulting to the 3,000 ms default from the Decision Log when absent). Keep it optional so
   existing clients are unaffected (it is a new nullable JSON field).
2. In `lookupHandler` (~lines 324–346), construct a `Deadline IO` from a monotonic clock
   (`System.Clock` / `getMonotonicTimeNSec` from `GHC.Clock` in `base`, no new dependency) and
   the resolved budget: capture a start time, and `remainingBudget = do now <-
   getMonotonicTimeNSec; pure (now - start < budgetNs)`. Pass it into `Lookup.lookup`.
3. The cursor `Text` already flows through unchanged (`LookupHasMoreWire !Text` /
   `LookupTruncatedWire !Text` and `LookupRequestWire.cursor :: Maybe Text`). Confirm
   `lookupStateToWire` (~lines 499–504) still maps the three states correctly. No type change
   is needed on the wire — only the *content* of the `Text` is now the encoded cursor.

Storage paging proof (`en-postgres`): the `en-postgres` `readStartingWithUser` already pages
correctly (`pageFromRows`, `en-postgres/src/En/Postgres/TupleStore.hs` ~lines 145–156, returns
`HasMore` with a real row-id `StoreCursor`). Add an integration test under
`en-postgres/integration-test/Main.hs` (there is an existing `en-postgres-integration-tests`
suite using `ephemeral-pg`) that:

- writes ~1,500 tuples `folder:fN # viewer @ user:paginator`,
- runs `lookup` with a small `LookupLimit`,
- accumulates all pages via the same `collectAllPages` strategy,
- asserts every folder is returned exactly once with no `ResolutionLimitExceeded`.

If standing up `ephemeral-pg` in this environment is impractical, scope the storage-paging
proof out **explicitly** with a Decision Log note and rely on the in-memory multi-page test
(M3/M4) plus EP-17's spike for the database-scale proof — but the in-memory store's paging
behavior is identical in shape to `en-postgres`'s, so the engine-level guarantee holds either
way.

What exists after: the HTTP `lookup` endpoint accepts an optional deadline, returns a
resumable cursor, and surfaces truncation; (ideally) a database integration test proves
multi-page paging against real PostgreSQL.

Commands:

```bash
cabal build all
cabal test all
```

Acceptance: `en-servant` builds and its existing tests pass; the (optional) `en-postgres`
integration test drains all folders across pages. The HTTP contract is backward compatible
(the new request field is optional; the response shape is unchanged).


### M7 — Expand scope and the En.Decision reconciliation

Scope: finalize the two provisional decisions.

1. **Expand paging.** Apply the `drainRowsForSubjects`-style fix to `En.Expand`'s
   `readObjectRows`/`ensureExhausted` (`en-core/src/En/Expand.hs` ~lines 262–278) so `expand`
   no longer hard-fails on multi-page objects. Keep `expand`'s existing integer-offset
   `pageNodes` cursor (resumable cursors for `expand` are out of scope — see Decision Log). If
   the change turns out to be more than the mechanical mirror of M3, **defer it** and record
   the deferral here with the reason. Add a small `en-core` test: an object with >1000 direct
   subjects expands without `ResolutionLimitExceeded`.

2. **En.Decision.** Confirm `confirmCandidates` still calls `En.Check.check`. Leave a clearly
   labeled comment at that call site: `-- TODO(EP-15): re-point at En.Decision once the shared
   decision algebra is extracted (docs/plans/15-...).` No behavioral change.

What exists after: `expand` shares the multi-page fix (or a recorded deferral); the
`En.Decision` follow-up is documented in code and in the Decision Log.

Commands:

```bash
cabal build all
cabal test all
```

Acceptance: full suite green; the Expand multi-page test (if included) passes.


### Final — wrap-up

Run the whole suite, fill Outcomes & Retrospective, and update the masterplan's EP-16 status
note if appropriate (do not edit other plans' internals — reference by path only).


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/en` unless noted.

Baseline (M0):

```bash
cabal build all
cabal test all
```

Expected: a clean build and a passing test suite. Record the observed assertion count from
`en-core-interface-tests` here as you go (it prints per-assertion lines via the custom
`assertEqual`/`assertBool` helpers in `en-core/test/Main.hs`).

After M1 (the failing test), expect output resembling:

```text
streaming lookup returns every reachable folder across pages: FAILED
  expected: 1200
   but got: <error> Left ResolutionLimitExceeded
```

(The exact rendering depends on how `collectAllPages` surfaces the engine `Left`; design it
to `fail` with the `EnError` shown so the bug is unmistakable.)

Iterate per milestone with the focused suite while developing:

```bash
cabal test en-core:en-core-interface-tests
```

and the full set at milestone boundaries:

```bash
cabal build all
cabal test all
```

If you add the `en-postgres` integration test (M6), run it specifically:

```bash
cabal test en-postgres:en-postgres-integration-tests
```

Update this section with the real transcripts you observe (red in M1, green from M3 onward)
as evidence, per the spec's "capture evidence" rule.


## Validation and Acceptance

The change is internal to the engine, so acceptance is phrased as **behavior proven by tests
that fail before and pass after**, plus the HTTP contract staying compatible.

1. **Headline (multi-page completeness).** A subject reaching 1,200 folders (more than one
   internal storage page) yields, via `lookup` + cursor continuations, **exactly 1,200**
   objects, with no duplicates, in sorted order, and **without** `ResolutionLimitExceeded`.
   This assertion fails on the current tree (M1) and passes from M3/M4 onward. This is the
   single most important proof.

2. **Resumability.** Driving the same fixture with a *small* limit produces many pages whose
   concatenation equals the single-call result. The continuation cursor is the encoded
   `LookupCursorState` (not an integer offset), and it pins the revision: encode/decode
   round-trips (M2), and resuming reads the same snapshot (M4).

3. **Deadline / truncation.** With a deterministic budget that expires mid-traversal, the
   first page's `state` is `LookupTruncated cursor`; resuming with fresh budget eventually
   reaches `LookupExhausted` having returned the full set (M5).

4. **No regressions.** Every pre-existing `lookup`/`check`/`expand` assertion in
   `en-core/test/Main.hs` still passes (the two deterministic-pagination assertions at
   ~lines 123–124 have their expected cursor text updated to the new encoding, or are
   rewritten to assert on decoded state).

5. **HTTP compatibility.** `en-servant` builds; the new `deadlineMillis` request field is
   optional; the response wire shape (`LookupPageWire`, `LookupStateWire`) is unchanged
   (M6).

6. **(Optional) Storage paging.** The `en-postgres` integration test drains ~1,500 real rows
   across pages (M6), or this is explicitly deferred to EP-17 with a Decision Log note.

Run, at the end:

```bash
cabal build all
cabal test all
```

and confirm a fully green suite.


## Idempotence and Recovery

Every step is additive and re-runnable. `cabal build all` and `cabal test all` are safe to run
repeatedly. The milestone ordering is chosen so the suite is green at the end of every
milestone except M1 (whose entire purpose is one new *failing* assertion); if you must stop
mid-plan, stop at a milestone boundary so the tree builds.

The migration risk is low because no database schema changes: the `relation_tuple` reads
(`en-postgres/src/En/Postgres/TupleStore.hs`) already page via row-id `StoreCursor`s and need
no change. The only externally visible change is the *content* of the opaque cursor `Text`;
because old cursors were bare integers and new cursors are versioned base64url JSON,
`decodeLookupCursor` must reject a stale integer-format cursor cleanly (return
`Left InvalidConsistencyToken`) rather than crash — clients simply restart the lookup from no
cursor. Document that in the codec's comment.

If a milestone's change breaks an unexpected existing assertion, prefer reverting just that
milestone's edit (git) and re-deriving the smallest change that keeps the suite green; the
plan's additive structure makes this safe.


## Interfaces and Dependencies

Libraries used (all already in the dependency set or in `base`): `aeson` (cursor JSON;
confirm it is available to `en-core` — if not, the cursor JSON can be hand-rolled to avoid
adding a dep to the pure core, record the choice), `bytestring` + base64url encoding for the
opaque wrapper, `time` (already an `en-core` dep) for any timestamp needs, and `GHC.Clock`
(`getMonotonicTimeNSec`, in `base`) for the real deadline in `en-servant`. The in-memory test
deadline uses `Data.IORef` from `base`.

Types/signatures that must exist at the end of the milestones (full module paths):

- `En.Lookup.LookupCursorState` — the resumable cursor payload: `{ version :: Int, revision
  :: Revision, frontier :: [FrontierStep] }` (M2/M4).
- `En.Lookup.encodeLookupCursor :: LookupCursorState -> LookupCursor` and
  `En.Lookup.decodeLookupCursor :: LookupCursor -> Either EnError LookupCursorState` (M2).
- `En.Lookup.Deadline m` with `remainingBudget :: m Bool` and `noDeadline :: Applicative m =>
  Deadline m` (M2).
- `En.Lookup.lookup` gains a `Deadline m` parameter (placed after `TupleStore m`):

  ```haskell
  lookup ::
      (Monad m) =>
      Deadline m ->
      ConsistencyStore m ->
      TupleStore m ->
      ReachabilityGraph ->
      Consistency ->
      LookupRequest ->
      m (Either EnError LookupPage)
  ```

  (M2/M6; update the `en-servant` caller and all test call sites.)
- `En.Lookup` internal: `drainRowsForSubjects` replaces `readRowsForSubjects` +
  `ensureExhausted` (M3); `runLookup`/`pageLookup` reworked to emit ordered, budget-bounded,
  resumable pages (M4/M5).
- `En.Effect.TupleStore` — **unchanged**. The streaming change lives entirely in the engine's
  *use* of `readStartingWithUser`; the storage interface already exposes the page state and
  cursor it needs.
- `En.Servant.API.LookupRequestWire` — gains `deadlineMillis :: Maybe Int` (M6).
  `LookupStateWire` and `LookupPageWire` — **unchanged** (cursor is already `Text`).
- `En.Expand` — `readObjectRows`/`ensureExhausted` replaced by a draining reader mirroring M3
  (M7), or deferred with a note.

Soft dependency on EP-15 (`docs/plans/15-generalize-the-caveat-evaluator-and-unify-the-decision-algebra.md`):
`confirmCandidates` continues to call `En.Check.check`; when `En.Decision` exists it is a
one-call swap, flagged with a `TODO(EP-15)` at the call site (M7). This plan does **not**
create `En.Decision`.

Integration contract for downstream plans (per masterplan Integration Point 3): EP-17
(benchmarks) and EP-18 (conformance) must consume EP-16's **final** cursor contract — a
versioned, revision-pinned, base64url-JSON `LookupCursor`, surfaced unchanged through the
Servant `LookupStateWire`/`cursor` fields, with truncation reported as `LookupTruncated`.


## Revision Note

2026-06-23 — Initial flesh-out from the skeleton. Authored against `en-core/src/En/Lookup.hs`
(the eager `runLookup`/`pageLookup` and the `ensureExhausted` hard-fail), `En.Effect.TupleStore`
(the `PageState`/`StoreCursor` paging primitive that already supports continuation), the
`en-postgres` `readStartingWithUser` (which already pages by row id), and `En.Servant.API`
(whose `LookupStateWire`/cursor fields are already opaque `Text`, so the wire needs no shape
change). Decisions seeded: cursor encoding (versioned, revision-pinned, base64url JSON,
modeled on SpiceDB LR3's nested cursor); deadline default (3s, OpenFGA-aligned, injected as a
pure `Deadline m` seam because `en-core` has no `IO`); Expand scope (apply the paging fix,
defer resumable cursors/deadline); and the `En.Decision`/EP-15 dependency (stay on
`En.Check`, swap later). The reverse-expansion algorithm (`evalThis`, `evalTupleToUserset`,
`expandRecursive`, `confirmCandidates`) is preserved verbatim in semantics; only its driver
(paging, ordering, resumable cursor, deadline) changes.
