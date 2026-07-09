---
id: 42
slug: stream-lookup-pages-with-validated-cursors-and-a-real-deadline
title: "Stream lookup pages with validated cursors and a real deadline"
kind: exec-plan
created_at: 2026-07-07T15:24:51Z
master_plan: "docs/masterplans/7-fix-the-en-evaluation-engine.md"
---

# Stream lookup pages with validated cursors and a real deadline

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`en` (縁) answers "which objects of this type can this subject reach with this
permission?" through **`lookup`** (`en-core/src/En/Lookup.hs`) — the reverse walk that a
consuming service uses as a read filter. Lookup already pages: it hands back an opaque
cursor and the caller loops. But three findings of
`docs/reviews/2026-07-07-architecture-performance-review.md` show the paging is partly
an illusion and partly a security hole:

- **B9 — the cursor is client-forgeable.** The cursor embeds the raw revision text of
  the snapshot the first page read at, and a continuation call takes that revision
  straight from the client (`lookupWithDeadlineWithChecker`, `En/Lookup.hs` lines
  162–176) with none of the checks a consistency token gets — no datastore identity, no
  schema hash, no garbage-collection-window check. A forged or expired cursor reads at
  an arbitrary revision, including past the GC horizon where soft-deleted rows have been
  physically reaped, silently producing wrong answers.
- **B7 — one lookup can span several snapshots and confirms candidates one by one.**
  Intersection/exclusion candidates are confirmed by calling `check` per candidate with
  the *original* `Consistency` request; `check` re-resolves it every time
  (`En/Check.hs` lines 66–68), so under `MinimizeLatency` or `FullyConsistent` each
  confirmation may read a *different* snapshot than the traversal that produced the
  candidate — and each confirmation rebuilds its memo from scratch.
- **B8 — every page recomputes the whole traversal, and the deadline bounds nothing.**
  `runLookup` materializes the complete candidate set, then `pageLookup` slices it
  (lines 178–190, 587–608); page N+1 re-runs the entire walk. The deadline is polled
  once, *after* traversal — it relabels `HasMore` as `Truncated` but never interrupts
  work, contradicting the module's own claim of being "streamed" (lines 105–108).

After this plan: a lookup cursor is a **validated token** — tampered, foreign, or
GC-expired cursors are rejected with the typed client error `InvalidConsistencyToken`
instead of being obeyed; a single lookup request resolves consistency **once** and pins
every candidate-confirmation check to that same revision through a new internal check
entry point (with one shared memo); continuation pages **resume** from cursor state
instead of recomputing from zero for the traversal stages where that is sound (with the
recompute fallback stated honestly); and the deadline is polled **inside** the traversal
loop, so an expiring budget halts expansion mid-work and returns a truncated page plus a
resumable cursor. The module documentation is corrected to describe exactly what is
guaranteed.

You can see it working: a test feeds a forged cursor and gets a typed error; a counting
consistency store proves one resolution per request including confirmations; a
counting tuple store proves page two does less work than page one; and a budget that
expires after N store reads yields `LookupTruncated` with a cursor that resumes to
completion.


## Progress

- [x] M0 (2026-07-08): baseline `cabal build all && cabal test all` green (7 suites);
  EP-39, EP-40, and EP-41 all confirmed landed; cited symbols verified and drift recorded
  below, including the one that changes this plan's M2.
- [x] M1 (2026-07-08): `MintToken` on `ConsistencyStore` + all four interpreters (permissive
  in-memory, new strict in-memory, PostgreSQL, en-example); cursor codec v2 carrying a
  token and a reserved frontier; `resolveCursor` validates via `decodeToken`/`validateToken`;
  forged v1, malformed v2, foreign-datastore, and unmintable-token cursors all rejected.
  Red evidence captured. `En.Lookup` now imports `Revision` without its constructor, so it
  *cannot* build a revision from client text.
- [x] M2 (2026-07-08): `En.Check.checkAtRevision` / `checkCachedAtRevision` added with
  exported `CheckMemo` and `emptyCheckMemo`; `CheckForCandidate` pinned to a revision and
  threading a memo; `consistency` deleted from every internal evaluator, which now carry
  only `TupleStore :> es`. Resolution count 3 → 1 (red evidence captured); confirmations
  share a memo, 19 reads → 17 on a shared-subtree fixture.
- [x] M3 (2026-07-08), **partly as planned**: confirmation is now watermark-filtered and
  bounded to the page (`EmitWindow`), so page N+1 never re-confirms pages 1..N. Per-page
  store reads on the shared-memo fixture at `LookupLimit 1`: 15 / 12 / 7, against a flat
  17 for every page before. Negative control observed failing.
- [x] M3-retreat (2026-07-08): per-branch `StoreCursor` resumption of the direct-read stage
  is **not implemented** — it is unsound against a store that returns rows in row-id order,
  which both stores do. Evidence and the counterexample are in Surprises & Discoveries; the
  Decision Log records the retreat, which the plan's Idempotence section authorized. The
  cursor's `frontier` field is encoded, round-trip tested, and always empty.
- [ ] M4: deadline inside the traversal loop — polls between store pages and between
  branch steps; mid-work truncation returns partial page + resumable cursor; existing
  deadline tests still pass.
- [ ] M5: documentation and wire pass — fix the `En.Lookup` haddock (lines 105–108),
  en-servant handler unchanged (cursor stays opaque `Text`), en-postgres integration
  test for cursor validation against a real store.
- [ ] Final: full suite green; Outcomes filled; master plan progress rows updated.


## Surprises & Discoveries

**M0: baseline green, and all three sibling plans have landed (2026-07-08).**
`cabal build all && cabal test all` passes across seven suites. EP-39 (probe), EP-40
(cycle/exclusion semantics), and EP-41 (context-free caching) are all Complete, so this
plan is the last to touch `En/Check.hs` before EP-44. The rebase the master plan's
Dependency Graph warned about is therefore not a rebase at all: this plan writes
`checkAtRevision` against the *final* shape of that module.

**M0: EP-41 changed what `checkAtRevision` has to do, and the plan half-anticipated it
(2026-07-08).** `En.Check` is now a symbolic evaluator. `runCheckMemoWithCache` returns
`Either EnError ResidualDecision`, not `Either EnError CheckDecision`, and
`CheckMemo = Map MemoKey ResidualDecision` (`en-core/src/En/Check.hs:182`). M2 step 1 says
"if EP-41 has landed, the internal result is a residual — apply the context at this
boundary exactly as `checkCached` does; the signature above stays." That is exactly right
and is what this plan will do.

Two consequences the plan did not foresee, both favourable. The memo is now *context-free*,
so threading one memo across a lookup's confirmations is sound for a stronger reason than
"one lookup has one context" — the entries do not mention context at all. And EP-41 already
established that a residual computed under a cycle cut is never memoized, so the shared memo
this plan introduces cannot inherit a stack-local answer.

**M0 line drift (2026-07-08).** `En/Lookup.hs` is untouched by the sibling plans and every
citation in this document is exact: `lookupWithDeadlineWithChecker` at 154–176 (the B9 hole
at 170–176), `runLookup` at 178–190, `CheckForCandidate` at 150–152, `confirmCandidates` at
462–481, `readRowsForSubjects` at 483–509, `mergeLookupObjects` at 538–552, `pageLookup` at
587–608, `decodeLookupCursor` at 628–641, the `encodeField`/`parseFields` codec at 643–663,
and the over-promising haddock at 105–108.

`En/Check.hs` moved: `check` is at :64 (plan said 57–68), `checkCached` at :89 (plan said
73–86), `runCheckMemoWithCache` at :224 (plan said 215–227).

The test-file citations are the ones that drifted badly, so record them properly:
`countingConsistencyStore` is at `en-core/test/Main.hs:1620` (plan said ~345),
`budgetedDeadline` at `:1302` (plan said ~969–978), `collectAllLookupPages` at `:1270`, the
cursor round-trip assertion at `:389-390` (plan said ~384–385), the deterministic-pagination
cursor at `:481`, and the deadline truncate-and-resume tests at `:406-408`. In `en-servant`,
`lookupHandler` is at `en-servant/src/En/Servant/API.hs:960` (plan said 373–395) and
`lookupDeadline` at `:991` (plan said 397–405). `runConsistencyStoreInMemory` is at
`en-core/src/En/Conformance/Kikan.hs:220` (plan said 211–223).

**B9, measured (2026-07-08).** A hand-written v1 cursor naming a revision the client chose,
fed to a lookup running under a *strict* validator that rejects foreign tokens. The engine
obeyed it and returned a full page:

```text
user error (a forged lookup cursor is rejected, not obeyed
expected: Left (InvalidConsistencyToken "lookup cursor")
actual:   Right (LookupPage {objects = [LookupObject {object = ObjectRef {objectType =
          ObjectType "space", objectId = "child-space"}, decision = Allowed},
          LookupObject {object = ObjectRef {objectType = ObjectType "space", objectId =
          "project-x"}, decision = Allowed}], state = LookupExhausted}))
```

Note what the strict validator bought: nothing. The old cursor path never called
`decodeToken` or `validateToken` at all, so no validator, however strict, could refuse it.
That is the finding: not "validation was too weak" but "validation was absent".

**The interpreters had to grow before the fix could be tested (2026-07-08).** `MintToken` is
a new operation on a GADT-based effect, so *every* interpreter must implement it or the
compiler warns. There were four, not two: the permissive in-memory store and the PostgreSQL
one the plan names, plus `runConsistencyStoreInMemory` and `runConsistencyStoreFailing` in
`en-example/src/En/Example/Host.hs`. GHC's `-Wincomplete-patterns` found the last two.

The new `runConsistencyStoreInMemoryStrict` exists because the permissive interpreter
*cannot* fail a token, and a test asserting that a forged cursor is rejected proves nothing
if the validator it runs against accepts everything. Its in-memory token format is
`in-memory:<datastore>:<revision>` — deliberately trivial, but it carries the two things a
cursor test must vary: who minted it and what revision it pins.

**PostgreSQL's `MintToken` sets `expiresAt = Nothing`, matching write tokens (2026-07-08).**
That looks wrong for something the plan describes as "expiring with the GC window", so it is
worth stating why it is right. `En.Postgres.TupleStore.tokenFromAnchor` mints write tokens
with no expiry, and `validateTokenMetadata` enforces the GC window not from a wall-clock
stamp but by comparing the token's snapshot `xmax` against `oldestRetainedXid`. A cursor
therefore expires exactly when the rows it could still read are reaped — which is the
property that matters — rather than at an arbitrary timestamp chosen at mint time.

**B9's acceptance is now a compile-time property, not a grep (2026-07-08).** The plan's
Validation section proposes verifying "no code path reads at a revision taken from client
text" by grepping `En.Lookup` for `Revision`. Better: the module now imports the type
*without its constructor* (`import En.Revision (Consistency, ConsistencyToken (..),
Revision)`). Every `Revision` in `En/Lookup.hs` is a type in a signature; the module has no
way to build one. A future edit that tries to resurrect `Revision cursorText` does not pass
review — it does not compile.

**B7, measured (2026-07-08).** A lookup on kikan's `audit` permission (an intersection, so
its candidates are confirmed by a forward check) under a consistency store that counts
`ResolveConsistency` calls:

```text
user error (a lookup resolves consistency exactly once, confirmations included
expected: 1
actual:   3)
```

One resolution for the traversal, plus one per confirmed candidate. Under `MinimizeLatency`
those three resolutions may select three different snapshots, so a candidate discovered in
one snapshot could be confirmed against another.

**M2's acceptance became structural too (2026-07-08).** Deleting the `consistency` parameter
from `evalRelation`/`evalRewrite`/`evalThis`/`evalTupleToUserset` did more than tidy a
signature: those functions no longer need `ConsistencyStore :> es` at all, and neither does
`runLookup`. They now carry `(TupleStore :> es)` alone. The traversal *cannot* resolve
consistency, because the effect is not available to it. `ConsistencyStore` survives only in
the four public entry points, `lookupWithDeadlineWithChecker`, and `resolveCursor`, and
`resolveConsistency` is called on exactly one line. As with the `Revision` import in M1,
this is a property the compiler maintains rather than one a reviewer must re-check.

**Memo sharing pays less than the plan implies, and the reason is EP-39 (2026-07-08).** The
plan asks for a test showing confirmations "cost fewer reads than independent checks".
Kikan's `audit` cannot show it: its two candidates are different objects with no shared
subproblem, so there is nothing to share. The fixture that does show it is
`sharedMemoSchema` — two children inheriting from one root through
`inherited = owner | parent->inherited`, gated by `enter = inherited - banned` so that
lookup must confirm.

With the memo threaded across the candidate list: **17** store reads. Resetting it per
candidate (the sabotage): **19**. The saving is one read per candidate that shares a
subproblem with an earlier one, so it grows with the candidate set rather than being a fixed
discount — but it is two reads, not twenty, because EP-39's probe already made each
individual confirmation cheap. Before the probe, re-deriving `memo-root#inherited` meant
draining a whole relation; now it is one bounded probe. The memo still matters, and matters
more as candidate sets and inheritance depth grow, but this plan should not claim a dramatic
number it does not have.

The memo is shared across the candidate list of one `confirmCandidates` call, not across the
whole traversal. A permission with nested intersections makes several such calls, and
threading one memo through every evaluator would mean changing each to return it. The
dominant case is one call with many candidates. Recorded rather than silently narrowed.

Sharing the memo is sound for a stronger reason than "one lookup has one context": after
EP-41, memo entries are `ResidualDecision`s and mention no caveat context at all. The context
is applied per candidate, at the `checkAtRevision` boundary.

**M3's central mechanism is unsound, and the store proves it (2026-07-08).** The plan asks
for a per-branch `StoreCursor` in the cursor's frontier so a continuation "continues the
underlying store scans instead of restarting them". That is not sound against either store en
has, and no amount of care in `En.Lookup` can make it so.

The reverse-query statement in `en-postgres/src/En/Postgres/TupleStore.hs` reads:

```sql
FROM relation_tuple
WHERE object_type = $2 AND relation = $3 AND id > $8
  ...
ORDER BY id ASC
LIMIT $7
```

Rows come back in **row-id order**, and the `StoreCursor` is that `id`. The in-memory store
agrees — `pageTuples` pages by list index. Row id is insertion order; it has no relationship
to `(object_type, object_id)`, which is the key the watermark and `mergeLookupObjects` sort
by.

The counterexample is short. A branch holds four rows whose objects, in store order, are
`[z, a, b, c]`. Page 1 has `limit = 2`: the traversal drains the branch, merges and sorts to
`[a, b, c, z]`, emits `[a, b]`, and sets the watermark to `b`. If page 2 resumes that branch
from a `StoreCursor` past all four rows — which is where page 1 left it — the branch yields
nothing, and `c` and `z` are lost forever. They were consumed but never emitted, because they
fell beyond the page limit.

Advancing the branch cursor only past rows whose objects are at or below the watermark does
not rescue it either: those rows are interleaved arbitrarily with rows the page did not emit,
so there is no prefix of the scan that is safe to skip. The property M3 needs is that the
store returns rows in object order, and it does not.

Making it so is a storage change, not an engine change: `ORDER BY object_type, object_id, id`
with a matching keyset cursor on that triple, an index to support it, and the same treatment
in the in-memory store. That is a coherent piece of work with its own correctness burden, and
it belongs in its own plan rather than smuggled into this one. This plan takes the retreat its
own Idempotence section authorizes: "fall back to watermark-only resumption (M3 step 3
alone)".

**What M3 does deliver, measured (2026-07-08).** Step 3 — "confirmations run only for
candidates that survive the watermark filter" — is sound, and it is where B8's real cost sits.
Confirmation is the expensive half of reach-then-check: the reverse walk over-generates, and
each candidate costs a forward check against storage. Before this milestone every page
confirmed every candidate and then threw away the ones it had already emitted.

`EmitWindow` carries two things into the outermost confirmation: the watermark, which drops
already-emitted candidates without checking them, and a budget of `limit + 1` allowed
candidates, which is exactly enough to fill a page of `limit` and still know more remain.
Candidates arrive sorted, so the ones confirmed are the ones the page wants.

On the `sharedMemoSchema` fixture at `LookupLimit 1`, store reads per page:

```text
page 1: 15    page 2: 12    page 3: 7
```

Against the old behavior — 17 reads on *every* page, since each re-confirmed all three
candidates. The negative control (restoring `wanted = candidates` and a no-op budget) fails
the assertion exactly as it should:

```text
user error (page 2 confirms less than page 1 (17 < 17)
expected True
actual:   False)
```

**Where the emit window may and may not travel (2026-07-08).** Both the watermark filter and
the budget are sound only where a confirmation's output goes straight into the page. Three
places would silently corrupt results if the window reached them, and each is worth naming
because the code deliberately passes `Nothing` there.

A *nested* confirmation is filtered again upstream. Truncating it at `limit + 1` allowed could
drop candidates the outer stage would have kept once its own filter denied the earlier ones.

An *arrow* (`TupleToUserset`) uses the objects it finds as the **subjects** of a further read.
On a recursive parent chain (`view = owner | parent->view`), dropping a low-keyed parent
because it sits below the watermark would hide every high-keyed child reachable only through
it. This is the subtlest of the three: the objects being filtered are of the request's own
type, so a naive "same type, safe to filter" rule gets it wrong.

The *candidate sources* of an intersection or exclusion must over-generate by construction, so
they receive `Nothing` while the confirmation that consumes them receives the window.

`Union` and `Caveated` do carry it: a union branch contributing its own smallest `limit + 1`
candidates is enough for the merged page, and a rewrite-level caveat gates every object
identically.

**The reserved `frontier` field ships empty (2026-07-08).** It is encoded, parsed, and
round-trip tested (including a two-entry frontier), and always `[]` in practice. It reserves
format space so that a future object-ordered-scan plan need not bump the cursor version. A
reader should not mistake its presence for a claim that branch resumption works.


## Decision Log

- Decision: The cursor carries a real `ConsistencyToken` minted by the datastore (new
  effect operation `MintToken :: Revision -> ConsistencyStore m ConsistencyToken`)
  rather than a hand-rolled "token-equivalent" tuple of datastore id + schema hash +
  revision + expiry assembled inside `En.Lookup`.
  Rationale: the validation path must *mirror `validateToken`* exactly — datastore
  identity, schema hash, GC horizon — and the only component that can mint something
  `decodeToken`/`validateToken` accept is the datastore itself (`En.Postgres.Revision`
  owns the encoding). Duplicating that encoding in en-core would fork the format.
  `MintToken` also directly serves
  docs/plans/51-return-checked-at-consistency-tokens-from-read-responses.md (master plan
  9), which needs to mint tokens from read revisions; coordinate the operation name with
  that plan — this plan defines it first.
  Date: 2026-07-07
- Decision: Cursor format v2 is the existing length-prefixed field encoding with a new
  `"lookup-v2"` prefix and fields (token, last-object-type, last-object-id, frontier
  state); v1 cursors (`"lookup-v1"`) are **rejected** with
  `InvalidConsistencyToken "lookup cursor"`, not migrated.
  Rationale: v1's revision field is exactly the forgeable value this plan removes;
  honoring it would preserve the hole for old cursors. Cursors are short-lived
  pagination state — clients restart from no cursor, the same recovery path as any
  invalid cursor. Reusing the existing `encodeField`/`parseFields` codec
  (`En/Lookup.hs` lines 643–663) avoids new dependencies in en-core.
  Date: 2026-07-07
- Decision: Reuse the existing `EnError.InvalidConsistencyToken Text` for cursor
  rejection (message `"lookup cursor"` plus the specific reason) instead of adding a new
  constructor.
  Rationale: a cursor now *is* a token plus resume state, and every rejection reason
  (forged, foreign datastore, schema drift, GC-expired) is literally a token-validation
  failure. The wire mapping of this error to a 4xx is owned by
  docs/plans/35-version-the-wire-contract-and-type-the-error-model.md per the master
  plan's integration points; this plan keeps the constructor set stable so that plan has
  one fewer moving target.
  Date: 2026-07-07
- Decision (2026-07-08, supersedes the staged-honesty decision below for the direct-read
  half): per-branch `StoreCursor` resumption is **abandoned**, not deferred for effort
  reasons — it is unsound against a store whose scans are ordered by row id, which both en
  stores are (`ORDER BY id ASC`, keyset cursor on `id`). A branch's rows are interleaved
  arbitrarily with respect to object key, so no prefix of a branch scan is safe to skip: rows
  consumed but not emitted (they fell beyond the page limit) would be lost on resume. See
  Surprises & Discoveries for the four-row counterexample. M3 keeps step 3 alone — the
  watermark filter — extended with a page-sized confirmation budget, which is where B8's
  cost actually lives. This is the retreat the Idempotence section pre-authorized.
  Enabling the original design means making `readStartingWithUser` return rows ordered by
  `(object_type, object_id, id)` with a keyset cursor on that triple, plus a supporting
  index and the same change in the in-memory store. That is a storage plan, not this one.
  Date: 2026-07-08
- Decision: The emit window (watermark + confirmation budget) reaches only confirmations
  whose output goes straight into the page: it propagates through `Union` and `Caveated`,
  is consumed by `Intersection`/`Exclusion`, and is withheld from their candidate sources,
  from `ComputedUserset`, and from arrows.
  Rationale: an arrow uses the objects it finds as the *subjects* of a further read, so on a
  recursive parent chain dropping a low-keyed parent below the watermark would hide every
  high-keyed child reachable only through it — even though those parents are of the request's
  own object type. A nested confirmation is filtered again upstream, so truncating it at
  `limit + 1` could drop candidates the outer stage would have kept.
  Date: 2026-07-08
- Decision: Staged honesty about resumption (M3). The cursor's traversal state is
  (a) the last emitted object key — the correctness watermark that keeps pages
  duplicate- and gap-free regardless of how much is recomputed — plus (b) for the
  **direct-read frontier** (the `evalThis` reads over `readStartingWithUser`, which are
  the only unbounded-fan-out stage) a per-branch `StoreCursor` so resumed pages continue
  the underlying store scans instead of restarting them. Recursive arrow expansion
  (`expandRecursive`) and intersection/exclusion confirmation are **recomputed** on
  resume and filtered by the watermark; persisting their mid-flight state (frontier
  sets, per-candidate confirmation progress) is explicitly out of scope.
  Rationale: the direct-read stage is where page-proportional cost lives and where a
  `StoreCursor` is a stable, storage-supported resume point (row-id keyset cursors in
  `en-postgres`). The recursive fixpoint's frontier is a set of objects discovered at
  arbitrary depth — encoding it would make cursors large, schema-coupled, and fragile,
  for stages whose output is bounded by design (the spec's "tens of labels"). The
  watermark keeps everything correct even where work is recomputed; the per-branch
  cursors make the dominant stage incremental. If benchmarks later demand more,
  a follow-up can extend the frontier encoding — the v2 format reserves a field for it.
  Date: 2026-07-07
- Decision: The deadline is polled between store pages and between traversal branches —
  never per row — and an expired budget produces `LookupTruncated` with a cursor built
  from the watermark of results already merged, discarding the partially-explored
  branch's unemitted work.
  Rationale: per-row clock polls are wasteful (the deadline is an effectful action);
  page/branch boundaries bound the overshoot by one store round trip. Emitting only
  watermark-safe results keeps the no-duplicates/no-gaps invariant: anything discarded
  is re-derivable on resume because it sorts after the watermark.
  Date: 2026-07-07
- Decision: Candidate confirmation pins to the lookup's resolved revision via a new
  internal entry point `checkAtRevision` in `En.Check` (revision in, no consistency
  resolution), with a threaded shared memo, rather than by adding a
  revision-accepting variant of the public `check`.
  Rationale: the master plan lets EP-42 proceed in parallel with EP-39/40/41 by treating
  check "as a black box"; a narrow, clearly-internal entry point (exported but
  documented as engine-internal) is the smallest surface that removes the re-resolution
  (B7) without entangling this plan in the `En.Check` rebase chain. `AtExactSnapshot`
  round trips through token encode/decode and was rejected as the pinning mechanism —
  it would mint a token per candidate just to decode it again.
  Date: 2026-07-07
- Decision: The memo is shared across the candidate list of one `confirmCandidates` call,
  not across the whole lookup traversal.
  Rationale: threading a memo through `evalRelation`/`evalRewrite`/`evalThis`/
  `evalTupleToUserset` would mean changing each to return it, a restructuring M3 is already
  doing for other reasons and which would collide. Nested intersections make several
  `confirmCandidates` calls, but the dominant case is one call with many candidates. Stated
  in the code comment so no reader assumes a lookup-wide memo.
  Date: 2026-07-08
- Decision: Removing `consistency` from the internal evaluators also removes
  `ConsistencyStore :> es` and `Error EnError :> es` from their constraint sets; keep it
  that way.
  Rationale: B7 then cannot recur. A traversal without the `ConsistencyStore` effect cannot
  re-resolve consistency even by accident, which is a compiler-checked version of the
  invariant this milestone exists to establish. The same reasoning as M1's decision to
  import `Revision` without its constructor.
  Date: 2026-07-08


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

You are in the `en` repository (working tree `/Users/shinzui/Keikaku/bokuno/en`; paths
repository-relative), a Haskell Cabal multi-package project on GHC 9.12.4 using the
`effectful` effect library. This plan is EP-42 of
`docs/masterplans/7-fix-the-en-evaluation-engine.md`, fixing findings B7, B8, B9 of
`docs/reviews/2026-07-07-architecture-performance-review.md`. Packages touched:
**`en-core`** (the engine), **`en-postgres`** (the PostgreSQL interpreters), a
no-behavior-change verification in **`en-servant`**.

Plain-language definitions:

- **Lookup**: given a subject, a permission, and an object *type*, return the objects of
  that type the subject can reach (`En.Lookup.lookup`). Results are
  `LookupObject { object, decision }` where decision is `Allowed` or `Conditional`
  (caveats pending); pages are `LookupPage { objects, state }` with
  `state :: LookupState` = `LookupExhausted | LookupHasMore cursor | LookupTruncated
  cursor`. The cursor is an opaque `Text` (`LookupCursor`).
- **Consistency / revision / token**: every read happens at a `Revision` (opaque
  snapshot id; PostgreSQL: a `pg_snapshot`). The caller's `Consistency`
  (`MinimizeLatency | AtLeastAsFresh token | AtExactSnapshot token | FullyConsistent`)
  is resolved to a concrete revision by the `ConsistencyStore` effect
  (`en-core/src/En/Effect/ConsistencyStore.hs`): `ResolveConsistency` picks the
  snapshot; `DecodeToken` parses an opaque `ConsistencyToken` into
  `TokenMetadata { token, revision, datastoreId, schemaHash, expiresAt }`;
  `ValidateToken` rejects tokens from a different datastore, a different schema, or
  older than the **GC window** (the retention period after which soft-deleted tuples
  are physically reaped — reading past it silently loses deletions). The PostgreSQL
  interpreters live in `en-postgres/src/En/Postgres/Revision.hs`; the permissive
  in-memory ones in `en-core/src/En/Conformance/Kikan.hs`
  (`runConsistencyStoreInMemory`, lines 211–223).
- **Deadline**: `En.Lookup.Deadline m` is `newtype Deadline m = Deadline
  { remainingBudget :: m Bool }` — an injected poll ("is there time left?"), because
  en-core is pure and has no clock. `en-servant` builds one from a monotonic clock with
  a 3,000 ms default (`lookupDeadline`, `en-servant/src/En/Servant/API.hs` lines
  397–405); tests use `budgetedDeadline` (an `IORef` countdown,
  `en-core/test/Main.hs` lines ~969–978).
- **Reach-then-check**: for intersection/exclusion rewrites, the reverse walk
  over-generates candidates from the union-shaped base, then a forward `check` confirms
  each candidate (`confirmCandidates`, `En/Lookup.hs` lines 462–481, via the
  `CheckForCandidate` record at lines 150–152, whose field runs
  `graph -> Consistency -> context -> subject -> relation -> object -> Eff es
  CheckDecision`).

The current flow to internalize before editing (read `en-core/src/En/Lookup.hs` end to
end): `lookupWithDeadlineWithChecker` (lines 154–176) decodes any incoming cursor with
`decodeLookupCursor` (lines 628–641: prefix `"lookup-v1"`, three length-prefixed fields:
raw revision text, last object type, last object id) — **with a cursor present it uses
`Revision cursorText` directly and never calls `resolveConsistency`** (the B9 hole);
without one it resolves. `runLookup` (lines 178–190) computes **all** candidates via
`evalRelation` and then `pageLookup` (lines 587–608) filters to objects greater than the
cursor's `lastObject` watermark, takes `min resultCap limit`, and polls the deadline
once to choose `LookupHasMore` vs `LookupTruncated`. All storage reads go through
`readRowsForSubjects` (lines 483–509), which already drains `HasMore`/`Truncated` pages
of `readStartingWithUser` in a loop — that loop is where M4's polls go. Ordering: results
are merged and sorted by object key (`mergeLookupObjects`, lines 538–552), which is what
makes the watermark scheme sound.

Also read: `En.Check.check` lines 57–68 (the `resolveConsistency` call B7 duplicates),
`runCheckMemoWithCache` (lines 215–227, the revision-accepting internal machinery
`checkAtRevision` will wrap), and `checkCached` (lines 73–86). And the wire layer:
`en-servant/src/En/Servant/API.hs` `lookupHandler` (lines 373–395) passes
`request.cursor` through as opaque `Text` into `Lookup.LookupCursor` — no wire change is
expected in this plan.

Integration points restated from the master plan so this plan stands alone:

- **EP-42 may run in parallel with EP-39/40/41** (which rework `En.Check` internals) as
  long as it treats `check` as a black box; the one exception is the deliberate,
  narrow `checkAtRevision` entry point defined here — coordinate its placement when
  rebasing (it wraps `runCheckMemoWithCache`, whose shape EP-39 owns).
- **The lookup cursor codec is redefined by this plan.** The service layer passes
  cursors opaquely, so no wire change; docs/plans/52-add-a-lookup-subjects-api.md
  (master plan 9) must reuse this plan's cursor discipline for its own paging.
- **`EnError` handling**: this plan reuses `InvalidConsistencyToken` (see Decision Log);
  mapping it to a client-distinguishable HTTP status belongs to
  docs/plans/35-version-the-wire-contract-and-type-the-error-model.md — whichever lands
  second wires it into the error envelope.
- **`MintToken`** is new shared vocabulary on `ConsistencyStore`;
  docs/plans/51-return-checked-at-consistency-tokens-from-read-responses.md will reuse
  it — coordinate naming, defined here first.
- Deadline defaults/config move into the engine-config record of
  docs/plans/44-make-evaluation-budgets-configurable-and-trim-hot-path-overhead.md,
  which runs last and reconciles with this plan's loop structure.


## Plan of Work


### M0 — Baseline and drift check (no code)

Build and test; verify the line citations above; note in Surprises & Discoveries which
of EP-39/40/41 have landed (they change `En.Check` internals but not the `check`
signature this plan consumes).

```bash
cabal build all
cabal test all
```


### M1 — Validated cursors (B9)

Scope: minting, the v2 codec, and validation-on-decode.

1. `en-core/src/En/Effect/ConsistencyStore.hs`: add to the GADT and export the smart
   constructor:

   ```haskell
   -- | Mint a token pinning the given revision, stamped with this
   -- datastore's identity and schema hash, expiring with the GC window.
   MintToken :: Revision -> ConsistencyStore m ConsistencyToken
   ```

2. Interpreters: in `en-core/src/En/Conformance/Kikan.hs`,
   `runConsistencyStoreInMemory` mints `ConsistencyToken ("in-memory:" <>
   revision.revisionEncoding)` and its `DecodeToken` learns to reverse that (returning
   the existing permissive `TokenMetadata`); also add a **strict** in-memory variant
   `runConsistencyStoreInMemoryStrict` whose `DecodeToken` fails on unrecognized text
   and whose `ValidateToken` rejects mismatched datastore ids — tests need a validator
   that can actually say no. In `en-postgres/src/En/Postgres/Revision.hs`, implement
   `MintToken` with the existing `encodeToken`/`TokenPayload` machinery (datastore id
   and schema hash from `ConsistencyConfig`, `expiresAt` per the GC window convention
   used by write tokens). Note: how token errors surface is via
   `Error EnError` exactly like `ValidateToken` failures today — reuse that path.
3. `en-core/src/En/Lookup.hs`: extend `LookupCursorState` to
   `{ version :: Int, token :: ConsistencyToken, lastObject :: Maybe ObjectRef,
   frontier :: [FrontierEntry] }` (`frontier = []` until M3 — encode it as one reserved
   field now so M3 does not bump the format again). `encodeLookupCursor` emits prefix
   `"lookup-v2"`; `decodeLookupCursor` becomes pure *parsing only* and a new

   ```haskell
   resolveCursor ::
       (ConsistencyStore :> es) =>
       LookupCursor ->
       Eff es (Either EnError (Revision, LookupCursorState))
   ```

   parses, then runs `decodeToken` + `validateToken` on the embedded token and returns
   the token's revision. Any parse failure — including a `"lookup-v1"` prefix — is
   `Left (InvalidConsistencyToken "lookup cursor")`. In
   `lookupWithDeadlineWithChecker`, replace the trust-the-cursor branch: with a cursor,
   the revision comes from `resolveCursor` (validated); without one, from
   `resolveConsistency` as today, and the first page's outgoing cursor embeds
   `mintToken revision`.
4. Tests (`en-core/test/Main.hs`): the codec round-trip assertion (line ~384–385)
   updates to v2; new assertions — a forged cursor
   (`LookupCursor "lookup-v1|13:test-revision|0:|0:"` and a garbage v2 body) yields
   `Left (InvalidConsistencyToken "lookup cursor")` under the strict store; a cursor
   minted by a *different* datastore id is rejected; the happy path still pages
   (existing deterministic pagination assertions at lines ~414–416 get their expected
   cursor values regenerated). Write the forged-cursor test first and watch it fail on
   the current tree (today it happily returns a page read at the forged revision —
   capture that as the red evidence).

```bash
cabal test en-core:en-core-interface-tests
```


### M2 — One resolution per lookup; pinned, memo-sharing confirmations (B7)

Scope: the revision is resolved once and threaded everywhere.

1. `en-core/src/En/Check.hs`: add and export

   ```haskell
   -- | Engine-internal: check at an already-resolved revision. Used by
   -- lookup's reach-then-check so one lookup reads one snapshot. Threads a
   -- caller-owned memo so a batch of confirmations shares subproblems.
   checkAtRevision ::
       (TupleStore :> es) =>
       ReachabilityGraph -> CaveatContext -> Revision ->
       Subject -> RelationName -> ObjectRef -> CheckMemo ->
       Eff es (Either EnError CheckDecision, CheckMemo)
   ```

   (a thin wrapper over `runCheckMemoWithCache Nothing`), plus
   `checkCachedAtRevision` taking `CheckCacheEnv` (wrapping
   `runCheckMemoWithCache (Just …)`). Export `CheckMemo` (opaque alias is fine) and
   `emptyCheckMemo`. If EP-41 has landed, the internal result is a residual — apply the
   context at this boundary exactly as `checkCached` does; the signature above stays.
2. `en-core/src/En/Lookup.hs`: change `CheckForCandidate` to run at a pinned revision
   with a threaded memo:

   ```haskell
   newtype CheckForCandidate es = CheckForCandidate
       { runCandidateCheck ::
           ReachabilityGraph -> CaveatContext -> Revision ->
           Subject -> RelationName -> ObjectRef -> CheckMemo ->
           Eff es (Either EnError CheckDecision, CheckMemo)
       }
   ```

   `lookupWithDeadline` instantiates it with `checkAtRevision`,
   `lookupWithDeadlineCached` with `checkCachedAtRevision cacheEnv`.
   `confirmCandidates` folds the memo across the candidate list and no longer receives
   `Consistency` at all; delete the `consistency` parameter that is currently threaded
   through `evalRelation`/`evalRewrite`/`evalTupleToUserset` solely to feed
   confirmations (grep `consistency` in the module — after this change only the public
   entry points mention it).
3. Tests: the existing `countingConsistencyStore` helper (`en-core/test/Main.hs`, line
   ~345) counts `ResolveConsistency` calls. Assert a lookup on the kikan `audit`
   permission (intersection → confirmations; fixture `memberOwner` reaching
   `auditedSpace`/`exclusionSpace`) resolves consistency **exactly once**. On the
   current tree this fails (1 + one per candidate) — capture the red count. Add a
   counting-tuple-store assertion that confirming two candidates shares reads (fewer
   total reads than two independent `check` calls — mirror the existing batch-sharing
   assertion pattern at lines ~353–367).

```bash
cabal test en-core:en-core-interface-tests
cabal test en-core:en-core-conformance
```


### M3 — Incremental resumption (B8, paging half)

Scope: page N+1 stops re-reading what page N already consumed, for the direct-read
stage; everything else recomputes behind the watermark (Decision Log). Design:

1. `FrontierEntry` (encoded in the cursor field reserved in M1) identifies a direct-read
   branch and its progress: the branch is named by the *stable path* to it — the
   `(ObjectType, RelationName)` pair of the `readStartingWithUser` query it issues plus
   an ordinal for duplicate pairs (branch enumeration order is deterministic:
   `evalRewrite` walks the rewrite structurally and `Set.toAscList` orders allowed
   subjects) — and its progress is the last `StoreCursor` consumed plus whether the
   branch is exhausted. Keep the encoding compact: this is a handful of short fields
   through the existing `encodeField` codec.
2. Restructure `runLookup` from "evaluate everything, then slice" into a staged
   producer: evaluate branches in the deterministic order; branches marked exhausted in
   the cursor are skipped outright; the in-progress branch's `readRowsForSubjects`
   starts from the saved `StoreCursor` instead of `Nothing`; results merge into the
   ordered accumulator; the page is cut at `limit` past the watermark exactly as
   `pageLookup` does today, and the outgoing cursor records each branch's new state.
   Stages that recompute (recursive `expandRecursive` fixpoints, confirmation of
   intersection/exclusion candidates) run as today but their emissions are filtered by
   the watermark — correctness is the watermark's, cost reduction is best-effort, and
   the module comment must say so in exactly those terms.
3. Interaction with confirmation: confirmations run only for candidates that survive
   the watermark filter on the current page — this alone removes the worst B8 cost
   (page N+1 re-confirming page 1..N's candidates). State this as its own bullet in the
   code comment and cover it with the counting test below.
4. Tests: drive the existing 1,200-folder streaming fixture (`streamingSchema`/
   `streamingTuples`, `en-core/test/Main.hs` lines ~394–404) with `LookupLimit 100`
   through a counting tuple store, and assert (a) the concatenation of all pages equals
   the single-call result (already asserted — must stay green), and (b) the store-read
   count of the *last* page is strictly less than that of a full recompute (record the
   before/after counts in this plan as evidence). Add an intersection-paging assertion:
   paging `audit` lookups never re-runs confirmations for objects at or below the
   watermark (counting store again).

```bash
cabal test en-core:en-core-interface-tests
```


### M4 — The deadline interrupts work (B8, deadline half)

Scope: budget polls inside the loops, truncation mid-work.

1. `en-core/src/En/Lookup.hs`: `readRowsForSubjects`' drain loop polls
   `deadline.remainingBudget` between pages; the branch iterator of M3 polls between
   branches. Introduce an internal outcome type so exhaustion is not an error:

   ```haskell
   data TraversalOutcome
       = TraversalComplete ![LookupObject]
       | TraversalInterrupted ![LookupObject]  -- merged results safe to emit
   ```

   On interruption, the produced page contains the watermark-safe prefix of what was
   merged, and the outgoing state is `LookupTruncated cursor` where the cursor holds
   the token, the new watermark, and the frontier as of the last *completed* branch
   step (per the Decision Log, an interrupted branch's partial discoveries are
   discarded, not emitted). `pageLookup`'s single after-the-fact poll is removed; the
   `hasBudget` distinction between `LookupHasMore` and `LookupTruncated` now reflects
   *why* the page ended.
2. Threading: `Deadline (Eff es)` is already a parameter of the whole call chain — no
   signature changes beyond passing it into the loops.
3. Tests: the existing deadline tests (lines ~400–404: one-poll budget truncates; the
   truncated cursor resumes to the full 1,200 set) must still pass — their meaning
   strengthens from "relabeled afterwards" to "halted during". Add the mid-work
   assertion: with a budget of exactly 2 polls over the 1,200-folder fixture and
   `LookupLimit 500`, the first page returns *fewer than 500* objects (work stopped
   mid-traversal — impossible before this milestone, since truncation previously
   happened after the full traversal) and resuming with `noDeadline` still yields
   exactly the remaining folders with no duplicates or gaps.

```bash
cabal test en-core:en-core-interface-tests
```


### M5 — Documentation, wire verification, and integration proof

Scope: make the words match the behavior, prove the stack end to end.

1. `en-core/src/En/Lookup.hs` lines 105–108: rewrite the haddock. It currently promises
   "streamed and cursorable"; the truthful post-plan claim is: cursor-resumable at a
   validated pinned snapshot; direct-read stages resume incrementally, recursive and
   confirmation stages recompute behind the watermark; the deadline interrupts between
   store pages and branches. Also document the cursor lifetime: cursors expire with the
   GC window, and expired/foreign/tampered cursors fail with
   `InvalidConsistencyToken "lookup cursor"`.
2. `en-servant`: no code change expected — `lookupHandler` already passes cursor `Text`
   opaquely. Verify by running `cabal test en-servant:en-servant-tests` and add one
   handler-level test: a lookup request with a garbage cursor string surfaces the
   engine error (today via the generic 500 mapping in
   `en-servant/src/En/Servant/Seam.hs`; the 4xx mapping is
   docs/plans/35's work — leave a comment referencing it at the assertion).
3. `en-postgres/integration-test/Main.hs`: an end-to-end test against `ephemeral-pg` —
   write 1,500 tuples, lookup with a small limit, follow real cursors across pages to
   completion (extends the existing multi-page integration coverage); then corrupt one
   character of a returned cursor's token field and assert
   `Left (InvalidConsistencyToken …)` from the real validator.

```bash
cabal build all
cabal test all
cabal test en-postgres:en-postgres-integration-tests
```


### Final — wrap-up

Fill Outcomes & Retrospective, tick the EP-42 rows in
`docs/masterplans/7-fix-the-en-evaluation-engine.md`, add a Revision Note here.


## Concrete Steps

All commands from `/Users/shinzui/Keikaku/bokuno/en`:

```bash
cabal build all
cabal test all                                    # M0 baseline, Final
cabal test en-core:en-core-interface-tests        # M1–M4 inner loop
cabal test en-core:en-core-conformance
cabal test en-servant:en-servant-tests            # M5
cabal test en-postgres:en-postgres-integration-tests   # M5 (boots its own PostgreSQL via ephemeral-pg)
```

Expected red evidence to capture before each fix: M1 — the forged-cursor test on the
current tree returns `Right (LookupPage …)` (a successful read at a forged revision;
paste it); M2 — the resolution-count assertion shows `expected: 1, actual: N` where N =
1 + number of confirmed candidates; M4 — the mid-work truncation assertion shows a full
500-object first page where fewer are expected. Replace these notes with real
transcripts as you go.


## Validation and Acceptance

1. **B9**: a tampered, foreign-datastore, v1-format, or GC-expired cursor yields
   `Left (InvalidConsistencyToken "lookup cursor")` — under the strict in-memory
   validator in unit tests and under the real PostgreSQL validator in the integration
   test. No code path reads at a revision taken from client text without
   `decodeToken`+`validateToken` (verifiable by grepping `En.Lookup` for `Revision` —
   the only constructions are from resolved consistency or validated token metadata).
2. **B7**: `countingConsistencyStore` proves exactly one `ResolveConsistency` per
   lookup request including intersection/exclusion confirmations; the shared-memo
   counting assertion shows confirmations cost fewer reads than independent checks.
3. **B8 paging** (amended 2026-07-08 — see the Decision Log): for the 1,200-folder fixture
   at `LookupLimit 100`, all pages concatenate to exactly the single-call result (no
   duplicates, no gaps, sorted). For a fixture whose permission requires *confirmation*
   (`sharedMemoSchema`, an exclusion), the store-read count falls strictly page over page —
   15, 12, 7 — against a flat 17 per page before. The traversal itself is still recomputed
   per page, and for a permission that needs no confirmation (a plain union of direct reads,
   like the 1,200-folder fixture) later pages therefore cost the same as the first. Making
   *that* cheaper requires object-ordered store scans and is out of scope; the original
   acceptance criterion assumed a resumption mechanism that turned out to be unsound.
4. **B8 deadline**: a 2-poll budget yields a first page with fewer objects than the
   limit and state `LookupTruncated cursor`; resuming with a fresh budget completes the
   set. The pre-existing truncate-and-resume tests stay green.
5. **Docs match behavior**: the `En.Lookup` module haddock states the validated-cursor,
   staged-resumption, interruptible-deadline contract; no claim of full streaming
   remains.
6. **No regressions**: `cabal test all` green, including en-servant handler tests (wire
   contract unchanged: cursor remains opaque `Text` in `LookupRequestWire.cursor` /
   `LookupStateWire`).


## Idempotence and Recovery

All steps are code + tests; every command is re-runnable; `ephemeral-pg` creates and
destroys its own database per run; no migrations. Milestones are ordered so the tree
builds and tests green at each boundary (M1's GADT addition to `ConsistencyStore`
requires both interpreters in the same change — land en-core and en-postgres edits
together, exactly like any effect extension). The externally visible break is
deliberate and bounded: v1 cursors stop working. Clients recover by restarting the
lookup without a cursor — state that in the M5 haddock and in the Revision Note. If M3's
restructuring destabilizes ordering guarantees (watch the deterministic-pagination
assertions), fall back to watermark-only resumption (M3 step 3 alone), record the
retreat in the Decision Log, and keep M1/M2/M4 — they are independent.


## Interfaces and Dependencies

No new package dependencies; the cursor codec stays hand-rolled on `text` (en-core adds
no aeson/base64), tokens ride the existing `En.Postgres.Revision` encoding.

End-state interfaces (full module paths):

- `En.Effect.ConsistencyStore.ConsistencyStore` gains
  `MintToken :: Revision -> ConsistencyStore m ConsistencyToken`, with smart constructor
  `mintToken`; implemented in `En.Conformance.Kikan.runConsistencyStoreInMemory` (plus a
  new strict variant `runConsistencyStoreInMemoryStrict`) and in
  `En.Postgres.Revision`'s interpreter. Name shared with
  docs/plans/51-return-checked-at-consistency-tokens-from-read-responses.md.
- `En.Lookup.LookupCursorState { version :: Int, token :: ConsistencyToken, lastObject
  :: Maybe ObjectRef, frontier :: [FrontierEntry] }`; `encodeLookupCursor` (v2 prefix);
  pure `decodeLookupCursor`; effectful
  `resolveCursor :: (ConsistencyStore :> es) => LookupCursor -> Eff es (Either EnError
  (Revision, LookupCursorState))`.
- `En.Check.checkAtRevision` / `En.Check.checkCachedAtRevision` with threaded
  `CheckMemo` (exported, documented engine-internal); public `check`/`checkCached`
  signatures unchanged.
- `En.Lookup.CheckForCandidate` runs at `Revision` with a threaded memo; the
  `consistency` parameter disappears from the internal traversal; deadline polls live
  in `readRowsForSubjects` and the branch iterator; `TraversalOutcome` internal.
- Public `En.Lookup.lookup`/`lookupWithDeadline`/`lookupCached`/
  `lookupWithDeadlineCached` signatures unchanged; `en-servant` wire types unchanged.

Consumed from other plans: `check` as a black box (rebase point: `checkAtRevision`
wraps machinery EP-39 reshapes; if docs/plans/41 landed, apply context at the
`checkAtRevision` boundary). Consumed by: docs/plans/52 (cursor discipline),
docs/plans/51 (`MintToken`), docs/plans/35 (`InvalidConsistencyToken` → 4xx envelope),
docs/plans/44 (deadline/budget configuration and loop tuning).
