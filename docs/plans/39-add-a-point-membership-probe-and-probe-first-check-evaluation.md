---
id: 39
slug: add-a-point-membership-probe-and-probe-first-check-evaluation
title: "Add a point-membership probe and probe-first check evaluation"
kind: exec-plan
created_at: 2026-07-07T15:24:51Z
intention: intention_01kx2cmexke9mv9aggb7jf7w5t
master_plan: "docs/masterplans/7-fix-the-en-evaluation-engine.md"
---

# Add a point-membership probe and probe-first check evaluation

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`en` (縁) is a relationship-based authorization toolkit written in Haskell. Its most-called
query is **`check`**: "does this subject have this permission on this object?" — the
question a service asks before serving every request. Today `check` answers that point
question by reading the *entire* relation off storage: to decide whether `user:alice` is a
`viewer` of `document:report`, it fetches every `viewer` row of `document:report` (up to a
hard one-page limit of 1,000 rows) and compares each row's subject to `alice` in a Haskell
loop. Two failures follow directly (findings B1 and B2 of
`docs/reviews/2026-07-07-architecture-performance-review.md`):

- **B1**: if the relation has more than 1,000 rows, the single-page read reports "there is
  more", and `check` converts that into the error `ResolutionLimitExceeded`. A document
  with 1,001 direct viewers makes **every** check on it fail — not slowly, but with an
  error — even when the answer is a trivial "yes, alice is row 3".
- **B2**: even under 1,000 rows, the cost of a direct-membership check is proportional to
  the width of the relation (a 900-member group costs 900 rows per check), when the store
  could answer "is this exact tuple live?" with one indexed row fetch.

After this plan, the `TupleStore` storage interface has a **point-membership probe** — an
operation that, given an object, a relation, and a small set of candidate subjects, returns
just the live tuples matching them (including any caveat name and payload attached to those
tuples). `check` probes first: a direct member is confirmed with a single bounded store
read, no matter how wide the relation is. When `check` genuinely has to enumerate rows
(to recurse into nested groups, or to walk an arrow like `parent->view`), it **drains
pages** instead of erroring, and it discovers direct membership in candidate groups with
one batched reverse query instead of one recursive walk per group.

You can see it working: a new regression test creates a relation with well over 1,000
direct members in the in-memory test store and asserts that `check` answers `Allowed` for
a member and `Denied` for a non-member — a test that fails with `Left
ResolutionLimitExceeded` on today's tree — and a new benchmark in
`en-core/bench/Main.hs` shows a wide-relation membership check costing a constant, small
number of store reads.


## Progress

- [x] M0 (2026-07-08): baseline — build and test the current tree; confirmed the file/line
  citations in this plan still match; found and fixed one pre-existing red test
  (`en-example`, commit `54b58aa`) recorded in Surprises & Discoveries.
- [x] M1 (2026-07-08): added the failing wide-relation regression test in
  `en-core/test/Main.hs` (commit `a6b7482`); captured the `Left ResolutionLimitExceeded`
  failure. The fixture shape this plan originally proposed did not reproduce B1; see
  Surprises & Discoveries for the corrected fixture.
- [x] M4a (new, discovered in M1; done 2026-07-08 as part of M2): repaired
  `erroringTupleStore` in `en-core/test/Main.hs` before deleting `ensureExhausted` — it
  injected errors by returning `HasMore` unconditionally, which would have turned M4's
  drain loop into an infinite loop. See Surprises & Discoveries.
- [x] M2 (2026-07-08): added the `ProbeTuples` operation to the `TupleStore` effect
  (`en-core/src/En/Effect/TupleStore.hs`) and implemented it in the in-memory conformance
  store (`en-core/src/En/Conformance/Kikan.hs`); cached interposer left an explicit
  passthrough with a comment pointing at docs/plans/41. Unit assertions in
  `en-core/test/Main.hs` cover a present subject, an absent subject, and caveat carriage.
- [x] M2a (2026-07-08): repaired `erroringTupleStore` (the M4a item, pulled forward because
  M2 had to add a `ProbeTuples` case to the same interpreter anyway).
- [x] M3 (2026-07-08): implemented the probe in the PostgreSQL store
  (`en-postgres/src/En/Postgres/TupleStore.hs`) as a prepared statement; verified index use
  with EXPLAIN; added the `runProbeScenario` integration test in
  `en-postgres/integration-test/Main.hs`. M2+M3 landed as one commit (`b0323d3`) because
  the GADT constructor breaks the exhaustive PostgreSQL interpreter until handled.
- [x] M4 (2026-07-08): unified `check` onto the memoized evaluator (commit `dfd6e37`);
  made `evalThisMemo` probe-first and replaced `ensureExhausted` with
  `drainObjectRelation` (commit `d3aecf5`). M1's two assertions are green and the full
  workspace suite passes.
- [ ] M5: batch direct-membership discovery for the subject-set recursion frontier with
  `readStartingWithUser`, mirroring `En.Lookup`.
- [ ] M6: regression test green; add wide-relation benchmarks to `en-core/bench/Main.hs`
  and record numbers.
- [ ] Final: full suite green (`cabal build all && cabal test all`); Outcomes filled in;
  master plan progress row updated.


## Surprises & Discoveries

**M0 — the baseline was not green.** This plan's M0 assumes `cabal test all` passes before
any change. It did not: `en-example`'s test suite failed with

```text
user error (engine error route returns 500
expected: Just 500
actual:   Just 503)
```

The cause is not in the evaluation engine at all. Commit `059fbd4`
("feat(en-servant): give every error a stable code and an honest status", part of
`docs/masterplans/6-*`'s EP-35) deliberately stopped mapping every `EnError` to HTTP 500
and gave `StoreError` a 503 with `retryable=true`, on the reasoning that a store outage is
not the caller's fault. The `en-example` assertion was never updated to match, so master
carried a red suite. The fix is a one-line assertion update (`en-example/test/Main.hs`,
now asserting `Just 503` and renamed to "store error route returns 503") landed as its own
commit `54b58aa` before any EP-39 work, so that this plan's before/after test evidence is
not confounded by an unrelated failure.

Cross-plan implication, mirrored into the master plan's Surprises section: a completed
child plan of another master plan left a sibling package red. Neither master plan's
acceptance ran `cabal test all` across the whole workspace after landing. Later plans in
this master plan should run the *full* workspace suite at their Final milestone, not only
the focused suites they touch.

**M4 — the probe-first path needed one rule the plan did not state: skip rows the probe
already matched.** The plan's M4 step 3 says to keep "only the `SubjectSet` rows" during
enumeration. That is very nearly right, but not quite: a stored row can name the checked
subject *as a subject-set* — for example the tuple
`space:userset-member#member@org:acme#member` when the checked subject is literally
`org:acme#member`. The old code's first guard, `tuple.subject == subject`, short-circuited
such a row to `applyTupleCaveat … Allowed` and never recursed into it. The probe also
matches it, since it is in the candidate set. So "keep all subject-set rows" would evaluate
that row twice — once as a probe decision and once as a recursion — and, when the row is
caveated, contribute two `Conditional` decisions where the old evaluator contributed one.

The fix is to define the enumeration filter as the exact complement of the probe's
candidate set: recurse into a row only when its subject is a `SubjectSet` *and* that
subject is not among the probe candidates. That preserves the old semantics precisely,
because the old first guard (`tuple.subject == subject || wildcardMatches tuple.subject
subject`) is, by construction, membership in `subjectsWithWildcard subject`.

**M4 — union's identity is what makes it safe to drop rows.** `Decision.union` (see
`unionDecisions` in `en-core/src/En/Decision.hs`) returns `Allowed` if any input is
`Allowed`, and `Denied` for the empty list. Two consequences the rework leans on, recorded
so a later plan does not "optimize" them away: an unconditional `Allowed` from the probe
can return immediately (nothing downstream can beat `Allowed`), and concrete/wildcard rows
that the probe did not match can be dropped from enumeration entirely (they could only
have contributed `Denied`, the identity). Both are behavior-preserving under today's
union. If EP-40 changes union's algebra, it must revisit both.

There is one deliberate, visible consequence of the early return: if a relation contains
both a row that grants unconditional access *and* a row whose caveat name is undefined in
the schema, the old evaluator returned `Left (UnknownRelation "unknown caveat: …")` because
`sequence` fails on the first `Left` anywhere in the list; the new one returns
`Right Allowed`. This is the union short-circuit the Decision Log explicitly sanctions, and
it is arguably the better answer — the subject provably has access by a path that involves
no caveat at all. Recorded here because it is the one place M4 changes an observable
outcome for an input no current test exercises. EP-40 owns the error taxonomy and should
confirm this is the semantics it wants.

**M3 — the planner picks the subject-side index, exactly as the Decision Log predicted.**
The plan's "no new index" decision rested on a claim that had never been measured: that
`relation_tuple_subject_hist_idx` can serve the probe with equality on the subject triple
plus `(object_type, relation)`, leaving `object_id` as a cheap filter. It does. Against
1,504 rows on `folder:probe-wide#viewer` (after `ANALYZE relation_tuple`), the plan is:

```text
Nested Loop
  ->  HashAggregate
        Group Key: unnest.unnest, unnest.unnest_1, unnest.unnest_2
        ->  Function Scan on unnest
  ->  Index Scan using relation_tuple_subject_hist_idx on relation_tuple
        Index Cond: ((subject_type = unnest.unnest) AND (subject_id = unnest.unnest_1) AND (COALESCE(subject_relation, ''::text) = unnest.unnest_2) AND (object_type = 'folder'::text) AND (relation = 'viewer'::text))
        Filter: (object_id = 'probe-wide'::text)
```

No sequential scan, so the deferred-index follow-up in the Decision Log stays deferred and
no migration is needed. The integration test asserts this property rather than merely
printing it: `runProbeScenario` fails if the plan contains neither `Index Scan` nor
`Bitmap Index Scan`. That guards against a future schema or statistics change silently
turning the probe back into the full-relation scan it exists to eliminate.

One implementation detail worth recording: `probeTuplesSession` short-circuits on an empty
candidate list rather than sending an empty `unnest`, since a probe with no candidates
cannot match anything and the round trip would be wasted.

**M1 — this plan's proposed wide fixture would not have reproduced B1.** The M1 milestone
text suggests a fixture "of at least 1,500 tuples `folder:fN#viewer@user:memberN`", and
suggests reusing `streamingTuples`. Both are wrong, for the same reason: they spread the
tuples across 1,200–1,500 *distinct* folder objects, one viewer each. `check` reads
`readObjectRelation revision object relation …`, which filters by object, so every one of
those relations has width one and the single-page read never reports `HasMore`. The bug
needs *one object* whose relation is wider than a page.

The fixture actually added is `wideFolder` (`folder:wide`) with 1,501 `viewer` rows, and
`wideMember` (`user:wide-member`) placed at position 1,200 — deliberately *past* the
1,000-row first page. Position matters: had the member sat inside page one, a naive "just
stop erroring and use the rows we got" fix would pass the test while still being wrong.
The schema is reused from `streamingSchema` unchanged (`folder#viewer` is a plain `this`
relation over `user` subjects), so no new schema fixture was needed.

Evidence — the red M1 run (`cabal test en-core:en-core-interface-tests`):

```text
user error (wide relation: direct member checks Allowed
expected: Right Allowed
actual:   Left ResolutionLimitExceeded)
```

**M1 — `erroringTupleStore` will infinite-loop the moment `ensureExhausted` is deleted.**
This is a trap M4 walks straight into, so it is recorded now. The test helper
`erroringTupleStore` (`en-core/test/Main.hs`, in `interpretFixtureTupleStore`) simulates a
failing store read like this:

```haskell
if Just object == errorObject
    then pure TuplePage{rows = [], state = HasMore (StoreCursor "injected-error")}
```

It returns `HasMore` *unconditionally* — the same page state for every cursor, forever. It
"errors" only because today's `ensureExhausted` converts `HasMore` into
`Left ResolutionLimitExceeded`. M4 replaces `ensureExhausted` with `drainObjectRelation`,
which follows the `HasMore` cursor until `Exhausted`; against this store that loop never
terminates, so the test suite would hang rather than fail.

Why the helper was written that way: `checkMany`'s per-pair fail-closed behavior needs the
evaluator to yield `Left EnError` *as a value*, not to throw through the `Error EnError`
effect (a thrown error escapes `checkMany` and fails the whole batch, since
`evaluateDistinct` only maps `either (const Denied) id` over the returned `Either`).
Today, `ensureExhausted` is the only way a *store* can produce an in-band `Left`. Deleting
it removes the sole error-injection route, which is why this is a plan change and not a
one-line edit.

The replacement (milestone M4a, added to Progress) keeps the in-band `Left` without
depending on paging: the erroring store returns, for the bad object, a single row whose
subject is a `SubjectSet` naming a relation absent from the schema. `evalRelationMemo`
looks that relation up in `graph.relations`, misses, and returns
`Left (UnknownRelation …)` — an in-band `Left` that flows through `sequence` exactly as
the paging error did, so "batch fails closed per pair" keeps asserting what it always
asserted. Note this row must be a `SubjectSet`, because M4's `evalThisMemo` skips
`SubjectId`/`SubjectWildcard` rows during enumeration (the probe has already answered for
those) and only recurses into subject-set rows.

**M0 — plan citations verified accurate.** Every line range this plan cites still matches
the tree: `check`/`runCheck` at `en-core/src/En/Check.hs:57-68` and `127-137`, the
duplicated non-memo evaluator family at `169-201` and `454-558`, `evalThisMemo` at
`383-417` (single `readObjectRelation … pageLimit Nothing` + `ensureExhausted`),
`evalTupleToUsersetMemo` at `419-452`, `ensureExhausted` at `567-572`, `maxDepth = 25` and
`pageLimit = 1000` at `163-167`. `readRowsForSubjects` (`en-core/src/En/Lookup.hs:483-509`)
and `subjectsWithWildcard` (`441-447`) have the drain-loop and candidate-set shapes the
plan says they do. The PostgreSQL interpreter matches exhaustively at
`en-postgres/src/En/Postgres/TupleStore.hs:115-132`, confirming this plan's warning that
M2 and M3 must land as one buildable unit.


## Decision Log

- Decision: The probe is a batched, list-returning operation — `ProbeTuples :: Revision ->
  ObjectRef -> RelationName -> [Subject] -> TupleStore m [TupleRow]` — rather than a
  single-subject `Maybe TupleRow` lookup.
  Rationale: a direct-membership check must consult two subjects at once (the concrete
  subject and the type-wildcard `SubjectWildcard`), and the same (object, relation,
  subject) can legally have several live rows differing only in caveat name (the unique
  index `relation_tuple_live_unique` includes `coalesce(caveat_name,'')`; see the
  migration `en-migrations/db/migrations/20260623044157_create-relation-tuples.sql`).
  A list of candidate subjects in, a list of matching live rows out covers both facts in
  one round trip and mirrors the existing batched `UsersetQuery` shape.
  Date: 2026-07-07
- Decision: No new database index or migration in this plan. The probe statement relies on
  the existing historical indexes from
  `en-migrations/db/migrations/20260623160000_historical-read-indexes.sql`, verified with
  EXPLAIN in the integration milestone; a dedicated `(object_type, object_id, relation,
  subject_type, subject_id)` index is deferred until EXPLAIN evidence demands it.
  Rationale: `relation_tuple_object_hist_idx (object_type, object_id, relation, id)`
  already gives an equality prefix on the probe's object side, and
  `relation_tuple_subject_hist_idx` gives one on the subject side; the planner can pick
  the more selective. The partial "live" indexes cannot serve the probe at all because en
  reads visibility through `pg_visible_in_snapshot`, never through the bare
  `deleted_xid IS NULL` predicate those indexes require (review finding C9). Adding an
  index is a one-line follow-up if needed; adding it speculatively is write amplification.
  Date: 2026-07-07
- Decision: Delete the duplicated non-memoized evaluator path in `en-core/src/En/Check.hs`
  (`evalRelation`/`evalRewrite`/`evalThis`/`evalTupleToUserset`, roughly lines 169–201 and
  454–558) and route plain `check` through `runCheckMemoWithCache Nothing`.
  Rationale: the module currently maintains two parallel evaluators (memo and non-memo)
  that must be edited in lockstep; this plan reworks the evaluation shape, and doing it
  twice doubles the risk. The memoized path with an empty memo is behaviorally identical
  for a single check. This also simplifies the rebases docs/plans/40 and docs/plans/41
  must perform on this file (see Integration notes in Context and Orientation).
  Date: 2026-07-07
- Decision: Inside `This`-evaluation, an unconditional `Allowed` from the probe
  short-circuits the rest of that relation's evaluation (no page enumeration, no
  recursion). General union short-circuiting across rewrite branches is *not* changed
  here; it belongs to docs/plans/40.
  Rationale: `Decision.union` (`en-core/src/En/Decision.hs`, `unionDecisions`) returns
  `Allowed` whenever any input is `Allowed`, so returning early on a proven unconditional
  direct membership cannot change the decision — it only removes work. Reordering or
  short-circuiting *across* union branches interacts with cycle/error semantics (review
  finding B3), which docs/plans/40 owns.
  Date: 2026-07-07
- Decision: The cached tuple-store interposer
  (`en-core/src/En/Effect/CachedTupleStore.hs`) forwards probe operations to the upstream
  store unchanged in this plan (the existing catch-all `passthrough` arm already does
  this); how probe results are cached is decided by docs/plans/41, which owns that
  integration point per the master plan.
  Date: 2026-07-07
- Decision: Discovering *which* subject-set rows exist on a wide relation still drains
  full pages of `readObjectRelation` (O(relation width) in the worst case). A store-side
  "userset rows only" filter that would make nested-group discovery cheaper is deferred.
  Rationale: the probe plus the batched membership query remove the common-case cost; a
  new filtered read is a second storage-interface change with its own SQL and index
  questions, and nothing in the current findings shows it is needed yet. Recorded so a
  future plan can pick it up if wide relations with many nested groups appear.
  Date: 2026-07-07


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

You are in the `en` repository (working tree `/Users/shinzui/Keikaku/bokuno/en`; every
path below is repository-relative). `en` is a Haskell Cabal multi-package project built
with GHC 9.12.4 (`cabal.project` pins `with-compiler: ghc-9.12.4`). This plan is EP-39 of
the master plan `docs/masterplans/7-fix-the-en-evaluation-engine.md` and fixes findings
B1 and B2 of `docs/reviews/2026-07-07-architecture-performance-review.md`.

The packages touched here:

- **`en-core`** — the pure engine: no database, no HTTP. It defines the storage interface
  as an *effect* and the query algorithms over it.
- **`en-postgres`** — the PostgreSQL implementation of that storage effect (via the
  `hasql` library).

Plain-language definitions of the terms this plan uses:

- **Relationship tuple**: one stored fact `object#relation@subject`, for example
  `space:project-x#member@user:alice` ("alice is a member of space project-x"). Modeled by
  `En.Tuple.Tuple` (fields `object :: ObjectRef`, `relation :: RelationName`,
  `subject :: Subject`, `caveat :: Maybe TupleCaveat`). A subject can be a concrete object
  (`SubjectId`), a **userset** (`SubjectSet object relation`, meaning "everyone who has
  *relation* on *object*", which is how groups-of-groups work), or a type **wildcard**
  (`SubjectWildcard objectType`, meaning "every object of this type").
- **Caveat**: a named, bounded condition attached to a tuple (name + a payload of typed
  values, e.g. an expiry timestamp). Evaluating a caveat against request context yields a
  three-valued `CheckDecision`: `Allowed`, `Denied`, or `Conditional [obligations]`
  ("the path exists, but more context is needed"). The decision algebra lives in
  `en-core/src/En/Decision.hs`.
- **Rewrite**: the expression that defines a relation/permission
  (`En.Schema.Rewrite`): `This` (directly stored tuples), `ComputedUserset` (alias to
  another relation), `TupleToUserset` (arrow, e.g. `parent->view`), `Union`,
  `Intersection`, `Exclusion`, `Caveated`.
- **Effect / interpreter**: en uses the `effectful` library. `TupleStore`
  (`en-core/src/En/Effect/TupleStore.hs`) is a GADT of storage operations; an
  *interpreter* supplies the behavior. There are three interpreters relevant here: the
  PostgreSQL one (`en-postgres/src/En/Postgres/TupleStore.hs`,
  `interpretTupleStorePostgres`), the in-memory conformance one
  (`en-core/src/En/Conformance/Kikan.hs`, `runTupleStoreInMemory`), and a caching
  *interposer* that sits in front of another interpreter
  (`en-core/src/En/Effect/CachedTupleStore.hs`, `cachedTupleStore`).
- **Revision**: an opaque snapshot identifier (`En.Revision.Revision`); every read takes
  one so results are consistent. For PostgreSQL it wraps a `pg_snapshot`, and row
  visibility is decided by `pg_visible_in_snapshot(created_xid, snapshot)` /
  `NOT pg_visible_in_snapshot(deleted_xid, snapshot)` — soft-deleted rows stay in the
  table with a `deleted_xid`.
- **Page / `TuplePage`**: reads return `TuplePage { rows :: [TupleRow], state ::
  PageState }` where `PageState` is `Exhausted`, `HasMore cursor`, or
  `Truncated cursor`. `TupleRow` wraps a `Tuple` with its storage row id and
  created/deleted revisions.

How `check` works today (read `en-core/src/En/Check.hs` top to bottom before editing):

1. `check` (lines 57–68) resolves consistency to a `Revision` and calls `runCheck`, which
   drives the **non-memoized** evaluator `evalRelation`/`evalRewrite` (lines 169–201,
   454–558). `checkCached` and `checkMany` drive a parallel **memoized** evaluator
   (`evalRelationMemo`/`evalRewriteMemo`, lines 259–452) that threads a within-call memo
   `Map MemoKey CheckDecision` (the memo key is revision + subproblem, no caveat context).
   The two paths are line-for-line duplicates in strategy.
2. `evalThisMemo` (lines 383–417) — the `This` case — issues **one**
   `readObjectRelation revision object relation pageLimit Nothing` (`pageLimit = 1000`,
   line 166–167) and passes the page to `ensureExhausted` (lines 567–572), which returns
   `Left ResolutionLimitExceeded` for `HasMore`/`Truncated`. This is finding B1: a
   relation wider than one page cannot be checked at all.
3. For each returned row it compares `tuple.subject == subject` (or a wildcard match) and
   otherwise recurses into `SubjectSet` rows one at a time, building a per-row decision
   list with `decisions <> [d]` appends and finally `Decision.union`. This is finding B2:
   a point question is answered by a linear scan, and the store's batched reverse
   primitive is never used.
4. `evalTupleToUsersetMemo` (lines 419–452) has the same single-page + `ensureExhausted`
   shape for arrow (`TupleToUserset`) evaluation.

Contrast with `En.Lookup` (`en-core/src/En/Lookup.hs`, `readRowsForSubjects`, lines
483–509) and `En.Expand` (`en-core/src/En/Expand.hs`, `readObjectRows`, lines 256–270):
both **drain** pages in a loop, following `HasMore`/`Truncated` cursors until
`Exhausted`. Lookup additionally uses the batched reverse primitive
`ReadStartingWithUser` (`en-core/src/En/Effect/TupleStore.hs`, lines 74–88): "give me the
tuples of type T on relation R whose subject is one of these subjects", with an `unnest`
batched implementation in PostgreSQL (`readStartingWithUserStatement`,
`en-postgres/src/En/Postgres/TupleStore.hs` lines 490–520). Check never uses either
technique. This plan brings check up to par and adds the one primitive nobody has: the
point probe.

The PostgreSQL schema (read both migrations under `en-migrations/db/migrations/`):
`relation_tuple` has columns `(id bigserial, object_type, object_id, relation,
subject_type, subject_id, subject_relation NULL, caveat_name NULL, caveat_payload jsonb
NULL, created_xid xid8, deleted_xid xid8 NULL)`. Indexes that matter to the probe:

- `relation_tuple_object_hist_idx (object_type, object_id, relation, id)` — **usable**:
  equality prefix on the probe's object side; no partial predicate, so it serves
  snapshot-visibility reads.
- `relation_tuple_subject_hist_idx (subject_type, subject_id, coalesce(subject_relation,
  ''), object_type, relation, id)` — **usable**: equality on all five leading columns for
  a probe (everything except `object_id`, which becomes a filter).
- `relation_tuple_live_unique` and the two `*_live_idx` indexes are partial on
  `deleted_xid IS NULL` — **not usable** by any query in this codebase, because reads
  filter with `pg_visible_in_snapshot`, which does not imply the partial predicate
  (review finding C9). Do not try to use them for the probe.

Integration points restated from `docs/masterplans/7-fix-the-en-evaluation-engine.md` so
this plan stands alone:

- **This plan (EP-39) owns the probe's definition** on the `TupleStore` effect and its
  three interpreters. docs/plans/41-cache-context-free-check-subproblems.md decides how
  the cached interposer caches probe results and **must not redefine** the operation.
- **Shared-file rebase order**: EP-39, docs/plans/40 (cycle/exclusion semantics), and
  docs/plans/41 (context-free caching) all edit `en-core/src/En/Check.hs`. The agreed
  order is EP-39 → EP-40 → EP-41: whichever lands later rebases onto the earlier one.
  This plan therefore avoids touching union/exclusion/cycle *semantics* (EP-40's scope)
  and cache *keys* (EP-41's scope).
- **Cross-master-plan**: docs/plans/46-add-write-preconditions-and-atomic-mixed-writes.md
  (master plan 8) adds write-side operations to the same `TupleStore` GADT. The read-side
  probe and the write-side preconditions are disjoint constructors; coordinate
  constructor naming, nothing else.
- `EnError` is not extended by this plan; error-taxonomy changes belong to docs/plans/40,
  and wire mapping of any new constructors belongs to
  docs/plans/35-version-the-wire-contract-and-type-the-error-model.md (master plan 6).


## Plan of Work

The work is six milestones plus a wrap-up. The guiding principle is additive,
test-green-at-every-boundary change (except M1, whose purpose is one new failing test).


### M0 — Baseline and drift check (no code)

Re-read `en-core/src/En/Check.hs`, `en-core/src/En/Effect/TupleStore.hs`,
`en-core/src/En/Conformance/Kikan.hs`, `en-core/src/En/Effect/CachedTupleStore.hs`,
`en-postgres/src/En/Postgres/TupleStore.hs`, and both files under
`en-migrations/db/migrations/`. Confirm the symbols and line ranges cited above still
match; if anything moved, update this plan in place and note it in Surprises &
Discoveries. Then, from the repository root:

```bash
cabal build all
cabal test all
```

Acceptance: clean build, fully passing suite *before* any change. Record the observed
test output summary here as the baseline.


### M1 — The failing wide-relation regression test (red)

Scope: prove B1/B2 with a test before fixing them. In `en-core/test/Main.hs` there is an
existing "streaming" fixture pattern to copy: `streamingSchema`/`streamingTuples` define a
`folder` object type with a direct `viewer` relation and 1,200 tuples (used by the lookup
paging tests around lines 394–404). Add a check-side fixture in the same style — either
reuse `streamingTuples` or add a dedicated `wideTuples` fixture of at least 1,500 tuples
`folder:fN#viewer@user:memberN` plus one probe subject, e.g. `user:wide-member` appearing
once in the middle of the list, so the single-page read provably misses nothing.

Add two assertions using the existing `check` test helper (defined around line 892 of
`en-core/test/Main.hs`; it runs the engine with the in-memory interpreters):

```haskell
assertEqual "wide relation: direct member checks Allowed"
    (Right Allowed)
    =<< check consistencyStore wideStore wideGraph MinimizeLatency requestContext
            (SubjectId wideMember) (RelationName "viewer") wideFolder
assertEqual "wide relation: non-member checks Denied"
    (Right Denied)
    =<< check consistencyStore wideStore wideGraph MinimizeLatency requestContext
            (SubjectId bob) (RelationName "viewer") wideFolder
```

Run the focused suite and capture the failure:

```bash
cabal test en-core:en-core-interface-tests
```

Acceptance: both new assertions fail with `Left ResolutionLimitExceeded` (the in-memory
store's `pageTuples` returns `HasMore` for >1,000 rows, and `ensureExhausted` converts
that to the error). Every pre-existing assertion still passes. Paste the failure lines
into Concrete Steps as evidence.


### M2 — The probe operation, in-memory interpreter, and interposer passthrough (green)

Scope: define the effect operation and make the pure interpreters handle it; behavior of
`check` is unchanged, so the suite stays green (M1's test still red).

In `en-core/src/En/Effect/TupleStore.hs`:

1. Add a constructor to the `TupleStore` GADT (keep it adjacent to the other reads):

   ```haskell
   -- | Point-membership probe: the live tuples at @revision@ on
   -- @object#relation@ whose subject is one of the given candidates.
   -- Callers pass a small candidate set (typically the concrete subject plus
   -- its type wildcard). Several rows can match one candidate when the same
   -- grant exists under different caveat names, so the result is a list.
   ProbeTuples :: Revision -> ObjectRef -> RelationName -> [Subject] -> TupleStore m [TupleRow]
   ```

2. Add the smart constructor and export it:

   ```haskell
   probeTuples :: (TupleStore :> es) => Revision -> ObjectRef -> RelationName -> [Subject] -> Eff es [TupleRow]
   probeTuples revision object relation subjects =
       send (ProbeTuples revision object relation subjects)
   ```

In `en-core/src/En/Conformance/Kikan.hs`, extend `runTupleStoreInMemory` with the new
case (mirror the existing `ReadObjectRelation` filter, but match the subject too and
return bare rows, not a page):

```haskell
ProbeTuples _ object relation subjects ->
    pure
        [ tupleRow index tuple
        | (index, tuple) <- zip [1 ..] tuples
        , tuple.object == object
        , tuple.relation == relation
        , tuple.subject `elem` subjects
        ]
```

In `en-core/src/En/Effect/CachedTupleStore.hs`, no functional change is required — the
final arm `operation -> passthrough env operation` already forwards unknown operations —
but add a short comment above that arm naming `ProbeTuples` and stating that its caching
policy is owned by docs/plans/41-cache-context-free-check-subproblems.md, so a reader does
not mistake the passthrough for an oversight.

Note that the compiler is your safety net here: adding a GADT constructor makes every
interpreter that matches exhaustively fail to compile until handled. The PostgreSQL
interpreter (`interpretTupleStorePostgres` in `en-postgres/src/En/Postgres/TupleStore.hs`)
matches exhaustively, so M2 and M3 must land together in one buildable state — write the
M3 case at the same time or stub it temporarily with the M3 statement.

Commands and acceptance:

```bash
cabal build all
cabal test en-core:en-core-interface-tests
```

Build green across all packages; existing tests pass; add a direct unit assertion in
`en-core/test/Main.hs` that `probeTuples` against the in-memory store returns exactly the
expected row for `(space, "owner", [SubjectId user])` from the existing kikan
`fixtureTuples`, and the empty list for a non-member.


### M3 — The PostgreSQL probe statement and integration proof

Scope: the real store answers the probe with one prepared statement, and we verify the
index story. In `en-postgres/src/En/Postgres/TupleStore.hs`:

1. Add the interpreter case:

   ```haskell
   ProbeTuples revision object relation subjects ->
       orThrow =<< runSession (probeTuplesSession revision object relation subjects)
   ```

2. Add the session and statement. Reuse the existing helpers: `subjectKeys` flattens
   subjects to `(subject_type, subject_id, subject_relation-or-empty)` triples exactly as
   `readStartingWithUser` does (a `SubjectWildcard` flattens to `subject_id = "*"`, which
   is how wildcards are stored — see `flattenSubject`), and `tupleRowDecoder` decodes full
   rows including `caveat_name`/`caveat_payload`, so probe results carry the caveat data
   `check` needs. The statement is `readObjectRelationStatement` narrowed by subject and
   with no pagination:

   ```haskell
   probeTuplesStatement :: Statement ProbeParams [TupleRow]
   probeTuplesStatement =
       Statement.preparable
           """
           SELECT id, object_type, object_id, relation, subject_type, subject_id, subject_relation,
                  caveat_name, caveat_payload, created_xid::text, deleted_xid::text
           FROM relation_tuple
           WHERE object_type = $2
             AND object_id = $3
             AND relation = $4
             AND (subject_type, subject_id, coalesce(subject_relation, '')) IN (
               SELECT * FROM unnest($5::text[], $6::text[], $7::text[])
             )
             AND pg_visible_in_snapshot(created_xid, $1::pg_snapshot)
             AND (deleted_xid IS NULL OR NOT pg_visible_in_snapshot(deleted_xid, $1::pg_snapshot))
           ORDER BY id ASC
           """
           probeEncoder
           (Decoders.rowList tupleRowDecoder)
   ```

   `ProbeParams` mirrors `ReadParams` minus limit/cursor; the encoder mirrors
   `readStartingWithUserEncoder`. No `LIMIT`: the result is bounded by the candidate-set
   size times the caveat-name multiplicity, which is tiny by construction.

3. **Verify index coverage.** The migrations (read them:
   `en-migrations/db/migrations/20260623044157_create-relation-tuples.sql` and
   `20260623160000_historical-read-indexes.sql`) show the probe can be served by
   `relation_tuple_object_hist_idx` with equality on `(object_type, object_id, relation)`
   and a per-row subject filter, or by `relation_tuple_subject_hist_idx` with equality on
   the subject triple plus `(object_type, relation)` and an `object_id` filter. Both are
   full (non-partial) indexes, so the `pg_visible_in_snapshot` predicates do not disable
   them. In the integration test (or a psql session against the dev database started with
   `just process-up && just run-migrations`), run:

   ```sql
   EXPLAIN (COSTS OFF)
   SELECT id FROM relation_tuple
   WHERE object_type = 'folder' AND object_id = 'f1' AND relation = 'viewer'
     AND (subject_type, subject_id, coalesce(subject_relation, '')) IN
         (SELECT * FROM unnest(ARRAY['user'], ARRAY['wide-member'], ARRAY['']));
   ```

   Expected: an `Index Scan using relation_tuple_object_hist_idx` (or
   `relation_tuple_subject_hist_idx`) — not a `Seq Scan`. Paste the plan into Surprises &
   Discoveries. If the planner seq-scans at realistic row counts, record it and open the
   deferred-index follow-up from the Decision Log; do not add the index silently.

4. Add an integration test in `en-postgres/integration-test/Main.hs` (this suite uses the
   `ephemeral-pg` library to boot a disposable PostgreSQL, so it needs PostgreSQL binaries
   on PATH — the project's dev environment provides them; the existing tests in that file
   show the setup pattern). The test writes ~1,500 `folder:fN#viewer@user:memberN` tuples
   plus one caveated grant, then asserts: (a) `probeTuples` for a present subject returns
   exactly its row including the caveat name/payload; (b) for an absent subject returns
   `[]`; (c) a soft-deleted tuple (write then delete) is not returned at a revision after
   the delete.

Commands and acceptance:

```bash
cabal build all
cabal test en-postgres:en-postgres-integration-tests
```

The three integration assertions pass; the EXPLAIN output shows an index scan.


### M4 — Probe-first check evaluation and page draining (M1 turns green)

Scope: rework `en-core/src/En/Check.hs` so the point question is answered by the probe
and enumeration never hard-fails on page limits.

1. **Unify the evaluators** (per the Decision Log): change `check` to call
   `runCheckMemoWithCache Nothing … Map.empty` and delete `runCheck`, `evalRelation`,
   `evalRewrite`, `evalThis`, and `evalTupleToUserset` (the non-memo family). The
   memoized family becomes the only evaluator. All existing tests must still pass after
   this step alone — do it as its own commit.

2. **Replace `ensureExhausted` with a draining reader**:

   ```haskell
   drainObjectRelation ::
       (TupleStore :> es) =>
       Revision -> ObjectRef -> RelationName -> Eff es [TupleRow]
   drainObjectRelation revision object relation =
       go Nothing []
     where
       go cursor acc = do
           page <- readObjectRelation revision object relation pageLimit cursor
           let acc' = acc <> page.rows
           case page.state of
               Exhausted -> pure acc'
               HasMore next -> go (Just next) acc'
               Truncated next -> go (Just next) acc'
   ```

   This mirrors `readRowsForSubjects` in `en-core/src/En/Lookup.hs` and `readObjectRows`
   in `en-core/src/En/Expand.hs`. `pageLimit` becomes a batch size, not a ceiling. Delete
   `ensureExhausted`. (Accumulation efficiency is deliberately left as-is;
   docs/plans/44-make-evaluation-budgets-configurable-and-trim-hot-path-overhead.md owns
   hot-path allocation work.)

3. **Rework `evalThisMemo`** to this sequence:

   - Build the candidate set `subject : wildcardOf subject` where `wildcardOf (SubjectId
     ObjectRef{objectType}) = [SubjectWildcard objectType]` and `[]` otherwise (this is
     the same shape as `subjectsWithWildcard` in `En.Lookup`).
   - `rows <- probeTuples revision object relation candidates`. Map each row through the
     existing `applyTupleCaveat graph context tuple.caveat Allowed`. If any result is
     `Right Allowed` (unconditional), **return `Allowed` immediately** — this is the
     probe-first fast path and is safe per the Decision Log. Otherwise keep the resulting
     decisions (they are `Denied`/`Conditional`/errors from caveat evaluation) as the
     start of the union.
   - Only if no unconditional `Allowed` was found: `allRows <- drainObjectRelation …`,
     keep **only** the `SubjectSet` rows, and recurse into each with
     `evalRelationMemo` exactly as today, gating each by its tuple caveat. Plain
     `SubjectId` and `SubjectWildcard` rows are skipped entirely — the probe already
     answered direct and wildcard membership exactly, so those rows can only contribute
     `Denied`, which is the union's identity.
   - Union the probe decisions and the recursion decisions with `Decision.union` as
     before (`Decision.union <$> sequence decisions` — unchanged semantics; EP-40 will
     revisit the `sequence`).

4. **Rework `evalTupleToUsersetMemo`**: replace the single `readObjectRelation … Nothing`
   + `ensureExhausted` with `drainObjectRelation`; the per-row recursion logic is
   unchanged. (Arrows enumerate a tupleset like `parent`, which is normally narrow, but
   must not error when it is not.)

Commands and acceptance:

```bash
cabal test en-core:en-core-interface-tests
cabal test en-core:en-core-conformance
```

M1's two assertions now pass; every pre-existing check/lookup/expand assertion still
passes (the conformance suite `en-core/conformance/Main.hs` exercises the kikan agency
scenario end to end and must stay green). The caveat tests around lines 375–383 of
`en-core/test/Main.hs` prove the probe path preserves caveats: the `intention` fixture's
only grant is caveated, so `Allowed`/`Denied`/`Conditional` all flow through the probe's
row caveats now.


### M5 — Batched membership discovery for the recursion frontier

Scope: when M4's step 3 finds `SubjectSet` rows (nested groups), do not immediately
recurse group-by-group. First ask the store, in one batched reverse query per
(group-type, group-relation) bucket, which of those groups *directly* contain the
subject — the same `ReadStartingWithUser` primitive `En.Lookup.readRowsForSubjects` uses.

Concretely, in `evalThisMemo` after collecting the `SubjectSet` rows:

1. Bucket the rows by the subject-set's `(objectType, relation)` — e.g. all
   `org:*#member` attachments form one bucket.
2. For each bucket, issue `readStartingWithUser revision UsersetQuery{ queryType =
   bucketObjectType, queryRelation = bucketRelation, querySubjects = candidates,
   queryLimit = pageLimit, queryCursor = Nothing }` and drain its pages (reuse the
   drain-loop shape from M4; a small local helper is fine). The returned rows are
   membership facts "subject ∈ group#relation" for every group of that type — intersect
   them with the bucket's groups by object ref.
3. For each attachment row whose group was matched: the contribution is
   `applyTupleCaveat` of the *attachment* row's caveat applied to `applyTupleCaveat` of
   the *membership* row's caveat applied to `Allowed` (both edges can be caveated; both
   gates must apply — compose them with the existing `applyTupleCaveat` and
   `Decision.applyGate`). If that yields unconditional `Right Allowed`, short-circuit the
   whole relation as in M4.
4. For each attachment row whose group was **not** matched (or matched only
   conditionally): fall back to the M4 recursion (`evalRelationMemo` into
   `group#relation`), because a miss on *direct* membership proves nothing — the group's
   relation may itself have nested subject-sets or a rewrite. Correctness rule: the
   batched query is an accelerator that can only *add* `Allowed`/`Conditional` evidence
   early; it must never be used to conclude `Denied` without recursion.

Add tests in `en-core/test/Main.hs`:

- A counting-store assertion (the `countingTupleStore` helper already exists, around line
  345): checking membership through a nested group (`usersetMemberSpace` in the kikan
  fixtures: `space#member@org:acme#member`, `org:acme#member@user:agency-alice`) issues
  **fewer** store reads after M5 than the recorded M4 count, and still returns `Allowed`.
- A two-level caveat composition test: a caveated attachment row over a caveated
  membership row yields `Conditional` with both obligations when context is missing.

Commands and acceptance:

```bash
cabal test en-core:en-core-interface-tests
```

All green; the read-count assertion demonstrates the batching observably.


### M6 — Benchmark evidence

Scope: make the win measurable and guard it. In `en-core/bench/Main.hs` (a `tasty-bench`
suite; note review finding B12 calls its current 2-tuple fixture a toy — the full
benchmark overhaul belongs to docs/plans/44, so keep this addition minimal and
compatible): add a `wide` fixture of 2,048 `folder:wide#viewer@user:memberN` tuples and
two benches:

```haskell
, bgroup
    "check-wide"
    [ bench "direct-member" $ whnfAppIO (\() -> runWideEngine (check wideGraph MinimizeLatency emptyContext (SubjectId wideMember) (RelationName "viewer") wideFolder)) ()
    , bench "non-member" $ whnfAppIO (\() -> runWideEngine (check wideGraph MinimizeLatency emptyContext (SubjectId outsider) (RelationName "viewer") wideFolder)) ()
    ]
```

(`runWideEngine` mirrors `runEngine` with the wide tuple list.) Note in a comment that
before this plan these benches would not run at all — the check errored — so the first
recorded numbers are the baseline for docs/plans/44 to improve on.

Run and record:

```bash
cabal bench en-core:en-core-bench
```

Acceptance: the benchmarks run to completion (they error on the pre-plan tree) and
`direct-member` is on the order of a single store read (in-memory: microseconds, and
crucially not proportional to 2,048). Paste the two timing lines into this plan.


### Final — wrap-up

Run the full suite, fill in Outcomes & Retrospective, update the EP-39 rows in the
Progress section of `docs/masterplans/7-fix-the-en-evaluation-engine.md`, and add a
Revision Note at the bottom of this plan.

```bash
cabal build all
cabal test all
```


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/en`.

Baseline (M0):

```bash
cabal build all
cabal test all
```

Expected: green build, all suites pass. After M1, the focused suite fails like:

```text
wide relation: direct member checks Allowed
expected: Right Allowed
actual:   Left ResolutionLimitExceeded
```

(The test helpers `assertEqual`/`assertBool` in `en-core/test/Main.hs` fail the process
with expected/actual lines in this shape.)

Iterate during M2–M5 with:

```bash
cabal build all
cabal test en-core:en-core-interface-tests
cabal test en-core:en-core-conformance
```

For M3 (needs PostgreSQL binaries; `ephemeral-pg` boots its own server, so no running
database is required):

```bash
cabal test en-postgres:en-postgres-integration-tests
```

For the optional live EXPLAIN check (needs the dev database):

```bash
just process-up
just run-migrations
psql "$PG_CONNECTION_STRING" -c "EXPLAIN (COSTS OFF) SELECT id FROM relation_tuple WHERE object_type='folder' AND object_id='f1' AND relation='viewer' AND (subject_type, subject_id, coalesce(subject_relation,'')) IN (SELECT * FROM unnest(ARRAY['user'],ARRAY['wide-member'],ARRAY['']));"
just process-down
```

For M6:

```bash
cabal bench en-core:en-core-bench
```

Update this section with the real transcripts (red M1, green from M4, EXPLAIN plan,
benchmark lines) as evidence while working.


## Validation and Acceptance

Acceptance is behavior, verified by tests that fail before and pass after:

1. **Headline (B1)**: a check against a relation with 1,500 direct members returns
   `Right Allowed` for a member and `Right Denied` for a non-member. On the pre-plan tree
   both return `Left ResolutionLimitExceeded`. Verified by the M1 assertions in
   `en-core/test/Main.hs` via `cabal test en-core:en-core-interface-tests`.
2. **Probe correctness (B2 primitive)**: `probeTuples` returns exactly the live matching
   rows with caveat name and payload intact, `[]` for absent subjects, and excludes
   soft-deleted rows at post-delete revisions — in both the in-memory store (M2 unit
   assertions) and PostgreSQL (`cabal test en-postgres:en-postgres-integration-tests`).
3. **Bounded work**: the counting-store assertions show (a) a wide-relation member check
   performs a constant number of store operations (the probe, not a scan), and (b) nested
   -group membership via M5 issues fewer reads than per-group recursion did.
4. **No semantic drift**: every pre-existing assertion in
   `en-core/test/Main.hs`, `en-core/conformance/Main.hs`, `en-servant` tests
   (`cabal test en-servant:en-servant-tests`), and the postgres suites still passes —
   including all caveat decisions (`Allowed`/`Denied`/`Conditional` with obligations),
   intersection/exclusion cases, wildcard matching, and the depth-limit test
   ("recursive graph respects depth limit" must still yield
   `Left ResolutionLimitExceeded` — depth semantics are unchanged by this plan).
5. **Benchmark**: `cabal bench en-core:en-core-bench` runs the new `check-wide` group to
   completion with times recorded in this plan.


## Idempotence and Recovery

Every step is re-runnable: `cabal build all`, `cabal test …`, and `cabal bench …` are
idempotent, and `ephemeral-pg` integration tests create and destroy their own database
per run. There are no schema migrations in this plan, so there is nothing to roll back in
a database. The milestone ordering keeps the tree buildable at every boundary except
mid-M2 (adding a GADT constructor breaks the exhaustive PostgreSQL interpreter until the
M3 case exists — land M2+M3 as one buildable unit or stub the case, and do not stop
between them). If a milestone breaks an unexpected assertion, revert that milestone's
edits with git and re-derive a smaller change; M4 step 1 (evaluator unification) is
deliberately its own commit so it can be bisected independently of the probe rework.


## Interfaces and Dependencies

No new library dependencies: `en-core` stays on `base`/`containers`/`effectful`/`text`
(check `en-core/en-core.cabal` — do not add packages), and `en-postgres` already has
`hasql`. The `en-postgres` integration suite already depends on `ephemeral-pg`.

Interfaces that must exist at the end (full module paths):

- `En.Effect.TupleStore.TupleStore` gains the constructor
  `ProbeTuples :: Revision -> ObjectRef -> RelationName -> [Subject] -> TupleStore m [TupleRow]`
  and the module exports
  `probeTuples :: (TupleStore :> es) => Revision -> ObjectRef -> RelationName -> [Subject] -> Eff es [TupleRow]`.
  Constructor naming is coordinated with the write-side extensions of
  docs/plans/46-add-write-preconditions-and-atomic-mixed-writes.md (disjoint operations,
  same GADT).
- `En.Conformance.Kikan.runTupleStoreInMemory` handles `ProbeTuples` (M2).
- `En.Postgres.TupleStore` handles `ProbeTuples` via a prepared statement
  `probeTuplesStatement` using `pg_visible_in_snapshot` and the `unnest` subject-key
  pattern, served by the historical indexes (M3).
- `En.Effect.CachedTupleStore.cachedTupleStore` passes `ProbeTuples` through with a
  comment deferring caching policy to docs/plans/41 (M2).
- `En.Check.check` is implemented on the single memoized evaluator; the non-memo
  evaluator family and `ensureExhausted` are gone; internal helpers
  `drainObjectRelation` and the probe-first `evalThisMemo` exist (M4/M5). Public
  signatures of `check`, `checkCached`, and `checkMany` are unchanged by this plan.
- `en-core/bench/Main.hs` contains the `check-wide` benchmark group (M6).

Downstream contracts: docs/plans/40 rebases its `En.Check` semantic changes onto this
plan's evaluator shape; docs/plans/41 consumes `ProbeTuples` for interposer caching and
the reshaped memo for context-free keys; docs/plans/42 may treat `check` as a black box
throughout.
