---
id: 47
slug: fail-loudly-on-storage-decode-errors-and-tighten-write-snapshots
title: "Fail loudly on storage decode errors and tighten write snapshots"
kind: exec-plan
created_at: 2026-07-07T15:24:59Z
master_plan: "docs/masterplans/8-correct-write-path-and-storage-semantics.md"
---

# Fail loudly on storage decode errors and tighten write snapshots

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

en is a relationship-based authorization toolkit backed by PostgreSQL. An authorization
store must never *lie*: when it cannot faithfully answer, it must error, because a degraded
answer here is a wrong permission decision. Today en's PostgreSQL layer lies in four places
(findings C5, C8, and C7 of `docs/reviews/2026-07-07-architecture-performance-review.md`):
a malformed pagination cursor silently restarts the scan at the beginning (duplicating
results); a caveat payload that no longer decodes silently becomes an *empty* payload —
which can flip a Conditional decision into something else entirely; the consistency token
minted on a write claims to be a snapshot but leaves a gap of transaction ids *visible*, so
a read pinned "at exactly this token" can see different data before and after a concurrent
transaction commits; and if the write anchor's snapshot fails to parse, the caller gets a
token that quietly cannot see its own write. Separately, the whole token-validation scheme
rests on an undocumented operational invariant — the garbage-collection window must be much
longer than any request — that no deployment guide states (C7).

After this plan: malformed cursors and undecodable payloads are typed errors, not defaults;
a write token denotes an exact, repeatable snapshot (a read at it returns identical results
no matter what commits around it); a snapshot parse failure at mint time is an error, not a
lying token; and the GC-window invariant is written into the deployment guide and the spec.
You can see it working by running `cabal test en-postgres-integration-tests` from the
repository root: a new scenario holds a concurrent write transaction open across two reads
at the same token and asserts identical results, and another plants a corrupt payload row
and asserts the read errors instead of returning a decision-changing row.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Add `InvalidCursor Text` to `en-core/src/En/Error.hs`.
- [ ] Make `decodeCursor` in `en-postgres/src/En/Postgres/TupleStore.hs` total-with-error and validate cursors in the interpreter before running read sessions.
- [ ] Move caveat-payload decoding into the hasql column decoder so an undecodable payload fails the session (surfacing as `StoreError`); delete the `Map.empty` fallback in `decodeTupleCaveat`.
- [ ] Fix the `limit <= 0` cursor off-by-one in `pageFromRows` (return the caller's own cursor instead of consuming the next row's id).
- [ ] Tighten `writeVisibleSnapshot`: mark the xid gap `[snapshot.xmax .. xid-1]` in-progress; return `Either` and mint the token in the interpreter so a parse failure throws `StoreError`.
- [ ] Add integration scenarios: token repeatability under a concurrent writer (fails pre-fix), malformed-cursor error, malformed-payload error, limit-0 page behavior.
- [ ] Document the GC-window ≫ request-duration invariant in `docs/user/production-deployment-and-performance.md` and `docs/spec/0001-en-overview.md` §7.
- [ ] Run `cabal build all` and `cabal test all`; record the failing-then-passing repeatability transcript.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Add a dedicated `EnError` constructor `InvalidCursor Text` for malformed store
  cursors rather than reusing `InvalidConsistencyToken` or `StoreError`.
  Rationale: A bad cursor is a client fault distinct from both a bad token (different
  artifact, different remediation) and a storage outage (retryable). The engine-level lookup
  cursor work in docs/plans/42-stream-lookup-pages-with-validated-cursors-and-a-real-deadline.md
  (master plan 7) can reuse the same constructor; the HTTP status mapping for it belongs to
  docs/plans/35-version-the-wire-contract-and-type-the-error-model.md.
  Date: 2026-07-07
- Decision: Undecodable caveat payloads fail inside the hasql row decoder (becoming a
  `SessionError`, mapped by the existing interpreter plumbing to `StoreError`) rather than
  being detected after the fact in `rowFromColumns`.
  Rationale: `Decoders.jsonbBytes` takes a `ByteString -> Either Text a` function, so the
  decoder is the natural, unbypassable choke point — every statement that reads
  `caveat_payload` inherits the strictness without per-call-site vigilance, and the error
  carries hasql's row/column context for free.
  Date: 2026-07-07
- Decision: The tightened write snapshot is
  `xmax' = max(snapshot.xmax, xid+1)`,
  `xip' = (snapshot.xip \ {xid}) ∪ {t | snapshot.xmax <= t < xmax', t /= xid}` — i.e. keep
  making the write's own xid visible, but mark every other xid in the raised gap
  in-progress.
  Rationale: This is exactly review finding C5's proposed construction. PostgreSQL's
  `pg_current_snapshot()` sets `xmax` to the latest *completed* xid + 1, so xids already
  assigned to still-running transactions can sit at or above `xmax`. Raising `xmax` to
  include our own xid must not also declare the gap's foreign xids visible — they were
  uncommitted when the token was minted, and a snapshot's meaning must not change when they
  later commit. Listing them in `xip` preserves the standard `xmin:xmax:xip` encoding (no
  token-format change) and the existing comparator semantics.
  Date: 2026-07-07
- Decision: Token minting moves out of the write `Session` and into the interpreter: the
  session returns the `Anchor` (xid + snapshot text) and `interpretTupleStorePostgres` calls
  `tokenFromAnchor`, which now returns `Either Text ConsistencyToken`; a `Left` throws
  `StoreError`.
  Rationale: hasql `Session` has no ergonomic custom-failure channel for pure post-processing,
  and the parse failure is not a database error — lifting the fallible step to the
  interpreter keeps the session simple and makes the failure a first-class `EnError` instead
  of the current silent `_ -> anchor.snapshot` fallback that mints a token unable to see its
  own write.
  Date: 2026-07-07
- Decision: `pageFromRows` with `limit <= 0` returns `HasMore` carrying the *caller's own
  cursor* (or `Exhausted` when the store returned no rows), instead of a cursor pointing at
  the first unreturned row.
  Rationale: The current code hands back the next row's id as the cursor while returning
  zero rows, so the row whose id became the cursor is skipped forever (`id > cursor` in the
  read statements). A zero-limit page must make no progress. This requires threading the
  incoming cursor value into `pageFromRows` — a small signature change confined to
  `en-postgres/src/En/Postgres/TupleStore.hs`.
  Date: 2026-07-07
- Decision: This plan does not add or modify migrations and does not change the token text
  format.
  Rationale: The snapshot tightening happens at mint time inside the existing
  `xmin:xmax:xip` encoding; nothing on disk changes. This keeps the plan independent of the
  migration-sequencing coordination between docs/plans/45 and docs/plans/49 noted in the
  master plan.
  Date: 2026-07-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This plan is a child of `docs/masterplans/8-correct-write-path-and-storage-semantics.md` and
fixes findings C5, C8, and C7 of
`docs/reviews/2026-07-07-architecture-performance-review.md`. It has no hard dependencies
and may land before or after its sibling plans; the only textual overlap is
`en-postgres/src/En/Postgres/TupleStore.hs`, which docs/plans/45/46/48 also edit — rebase
mechanically, the seams are disjoint (they own write *statements*; this plan owns decoding
and token minting).

en is a Haskell project at `/Users/shinzui/Keikaku/bokuno/en`. Orientation for the files
touched:

- `en-postgres/src/En/Postgres/TupleStore.hs` — the hasql (typed PostgreSQL client)
  implementation of the `TupleStore` storage effect from
  `en-core/src/En/Effect/TupleStore.hs`. The four defect sites, with current line numbers
  (they will drift as sibling plans land; locate by name):
  - `decodeCursor` (line 667): parses a `StoreCursor` — the opaque keyset-pagination
    position, in practice the last-seen `relation_tuple.id` rendered as text — with
    `reads`, and maps *any* parse failure to `0`, silently restarting pagination from the
    beginning. A caller that mangles a cursor gets duplicated results instead of an error.
  - `decodeTupleCaveat` (line 574): a tuple's caveat payload (the write-time arguments to a
    named condition, e.g. an expiry timestamp) is stored as `jsonb` in
    `relation_tuple.caveat_payload`. This function maps an undecodable payload to
    `Map.empty` — an *empty* payload. Downstream, the caveat evaluator treats missing
    parameters as "ask the caller for more context" or evaluates differently than the true
    payload would; either way the authorization answer changes. The row decoder
    (`tupleRowDecoder`, line 526) currently reads the column as raw bytes via
    `Decoders.jsonbBytes Right` and defers all interpretation to `decodeTupleCaveat`.
  - `writeVisibleSnapshot` (line 233): a write runs inside a transaction whose *anchor*
    statement records the transaction's xid and its `pg_snapshot` (the MVCC state string
    `xmin:xmax:xip` — `xmin`/`xmax` bound the in-doubt region, `xip` lists the in-progress
    xids inside it; a committed xid `t` is visible iff `t < xmax` and `t ∉ xip`). The token
    returned to the caller is minted from that snapshot, adjusted so the write's own xid is
    visible: `xmax := max(xmax, xid+1)`, `xip := xip \ {xid}`. The flaw (C5): PostgreSQL's
    `xmax` is "latest *completed* xid + 1", so other transactions' xids that were assigned
    but uncommitted at anchor time can lie in `[snapshot.xmax, xid)`; raising `xmax` past
    them without adding them to `xip` declares them **visible**. They contribute no rows
    while uncommitted, but become visible the moment they commit — so two reads "at exactly"
    the same token straddling a concurrent commit disagree. That is precisely what a
    snapshot token must prevent (a revocation racing a write is the new-enemy-adjacent
    case). Additionally the function's fallback arm (`_ -> anchor.snapshot`) silently
    returns the *raw* anchor snapshot when parsing fails — a token that cannot see its own
    write (the empirical finding recorded in the Surprises & Discoveries of
    `docs/plans/14-harden-consistency-faithful-snapshot-visibility-gc-window-and-token-reconciliation.md`).
  - `pageFromRows` (line 203): converts the `limit+1` fetched rows into a page. With
    `limit = 0`, `visibleRows` is empty and the `HasMore` cursor is taken from `nextRow` —
    the first *unreturned* row — so resuming skips it (the read statements filter
    `id > cursor`). Unreachable at the engine's normal limits, but the path exists and the
    fix is mechanical.
- `en-core/src/En/Error.hs` — `EnError`, the closed engine error type; gains
  `InvalidCursor`.
- `en-postgres/integration-test/Main.hs` — the `en-postgres-integration-tests` suite: starts
  a throwaway PostgreSQL via the `ephemeral-pg` library (no external service needed;
  PostgreSQL binaries must be on `PATH`, which the project dev shell provides), creates the
  schema from an inline `schemaSql`, and asserts scenarios with `assertEqual`. It already
  acquires a connection with a local `acquire` helper; the repeatability scenario below
  needs a *second* connection from the same throwaway database.
- `docs/user/production-deployment-and-performance.md` and `docs/spec/0001-en-overview.md`
  §7 — where the C7 invariant gets documented. C7 (the *GC TOCTOU*, "time of check to time
  of use"): token validation reads the garbage-collection horizon (the oldest transaction id
  whose history is still retained), and the tuple read runs afterwards; if the reaper
  physically deletes soft-deleted rows in between, the read silently returns an incomplete
  answer instead of `InvalidConsistencyToken`. This is acceptable *iff* the configured GC
  window (`EN_GC_WINDOW`, default `24 hours`; see `docs/user/service-and-operations.md`)
  exceeds any request duration by orders of magnitude — an invariant currently stated
  nowhere.

Integration points restated from the master plan
(`docs/masterplans/8-correct-write-path-and-storage-semantics.md`):

- **This plan (EP-47) owns the write-token snapshot definition**
  (`writeVisibleSnapshot`/`tokenFromAnchor` and the anchor seam). docs/plans/46 and
  docs/plans/48 must not adjust it; their sessions mint tokens by calling it as-is, and
  their tests exercise it.
- **The `relation_tuple_live_unique` index is owned by docs/plans/45**; the final write
  signature by docs/plans/46; the secondary/`created_xid` indexes by docs/plans/49 in
  coordination with docs/plans/53-add-a-watch-changelog-api.md. This plan touches none of
  those — no schema changes, and no effect-signature changes beyond the new error
  constructor.


## Plan of Work

Two code milestones (decode strictness; snapshot tightening) and one documentation
milestone, each independently verifiable.


### Milestone 1 — Decode failures become errors; the limit-0 page makes no progress

Scope: `decodeCursor`, the payload decoder, `pageFromRows`, and the `InvalidCursor`
constructor, with integration scenarios proving each. At the end, feeding the store garbage
produces typed errors and a zero-limit page is harmless.

Edits, all in `en-postgres/src/En/Postgres/TupleStore.hs` unless noted:

1. `en-core/src/En/Error.hs`: add, in the file's Haddock style,

   ```haskell
     | -- | A pagination cursor was malformed or does not belong to this store.
       InvalidCursor Text
   ```

2. Change `decodeCursor :: StoreCursor -> Int64` to
   `decodeCursor :: StoreCursor -> Either EnError Int64`, returning
   `Left (InvalidCursor cursorText)` where it currently returns `0`. Validate in the
   *interpreter* (`interpretTupleStorePostgres`), before any session runs: the
   `ReadObjectRelation` and `ReadStartingWithUser` cases resolve
   `traverse decodeCursor maybeCursor` with `either throwError pure` and pass the
   already-decoded `Int64` (defaulting to `0` only for `Nothing` — an absent cursor
   legitimately means "from the start") into
   `readObjectRelationSession`/`readStartingWithUserSession`, whose signatures change to
   take `Int64` instead of `Maybe StoreCursor`. This keeps sessions infallible and the
   error typed. The near-identical `decodeTestCursor` in
   `en-core/src/En/Conformance/Kikan.hs` backs the in-memory store, whose cursors are
   engine-internal test artifacts; leave it as is (client-supplied *lookup* cursors are
   docs/plans/42's scope, per the Decision Log).
3. Make the payload column decoder strict. In `tupleRowDecoder`, replace the raw
   `Decoders.column (Decoders.nullable (Decoders.jsonbBytes Right))` with a decoder that
   parses all the way to the typed payload:

   ```haskell
   Decoders.column
       ( Decoders.nullable
           ( Decoders.jsonbBytes
               ( \bytes ->
                   case Aeson.decodeStrict bytes >>= decodeCaveatPayload of
                       Just decoded -> Right decoded
                       Nothing -> Left "undecodable caveat_payload"
               )
           )
       )
   ```

   so the column yields `Maybe (Map.Map Text CaveatValue)` and a bad payload fails the whole
   statement as a hasql `SessionError` — which the interpreter's existing `orThrow` already
   maps to `StoreError`. `rowFromColumns` and `decodeTupleCaveat` then take the decoded map;
   delete the `Map.empty` fallback. One semantic wrinkle to preserve: a row with a
   `caveat_name` but a SQL `NULL` payload today decodes to an empty payload — that case is a
   legitimately empty payload (a caveat with no write-time arguments), distinct from an
   *undecodable* one, and must keep working (the `Nothing` from `Decoders.nullable` maps to
   `Map.empty` as before).
4. Fix `pageFromRows`. Thread the request's cursor in
   (`pageFromRows :: Int64 -> Int -> [TupleRow] -> TuplePage`, first argument the incoming
   cursor position) and change the `HasMore` arm: when `visibleRows` is empty (only possible
   at `limit <= 0`), the cursor is the *incoming* position rendered the same way
   (`StoreCursor (Text.pack (show cursorId))`), not `nextRow`'s id. Both read sessions pass
   their `cursorId` through.

Integration scenarios (in `en-postgres/integration-test/Main.hs`, new assertions in the
existing flow or a sibling scenario function called from `main`):

- **Malformed cursor**: `readObjectRelation` with `Just (StoreCursor "not-a-number")`
  returns `Left (InvalidCursor "not-a-number")` (use the suite's `runPg`, which surfaces
  `Either EnError`). Pre-fix this silently returned page one.
- **Malformed payload**: insert, via a raw `Session.statement`, a live row whose
  `caveat_payload` is valid `jsonb` but not a valid payload — e.g.
  `'{"level":{"type":"integer","value":"not-a-number"}}'::jsonb` (the column type forces
  valid JSON, so corruption means valid-JSON-wrong-shape) — then `readStartingWithUser`
  over it and assert the result matches `Left (StoreError _)` (pattern match the
  constructor, not the text). Pre-fix this returned a row with an empty payload.
- **Limit-0 page**: write two tuples; `readObjectRelation` with `limit = 0` and no cursor
  must return zero rows and a `HasMore` cursor; reading again *with that cursor* and
  `limit = 10` must return **both** tuples. Pre-fix the second read returns one (the first
  was skipped).


### Milestone 2 — Exact write snapshots and loud mint failures

Scope: `writeVisibleSnapshot` and the token-minting seam. At the end, a token names a
snapshot whose meaning never changes, proven by a repeatability test that fails on the
pre-fix code.

Edits in `en-postgres/src/En/Postgres/TupleStore.hs`:

1. Rewrite `writeVisibleSnapshot`:

   ```haskell
   writeVisibleSnapshot :: Anchor -> Either Text Text
   writeVisibleSnapshot anchor =
       case (parsePgSnapshot anchor.snapshot, parseWord64 anchor.xid) of
           (Right snapshot, Just xid) ->
               let xmax' = max snapshot.xmax (succBounded xid)
                   -- xids assigned but uncommitted when the anchor snapshot was
                   -- taken sit at/above its xmax; raising xmax to show our own
                   -- xid must mark the rest of that gap in-progress, or their
                   -- later commits would change what this token can see.
                   gap = [txid | txid <- [snapshot.xmax .. xmax' - 1], txid /= xid]
                in Right
                       ( renderPgSnapshot
                           snapshot
                               { xmax = xmax'
                               , xip = filter (/= xid) snapshot.xip <> gap
                               }
                       )
           (Left err, _) -> Left ("write anchor snapshot did not parse: " <> err)
           (_, Nothing) -> Left ("write anchor xid did not parse: " <> anchor.xid)
   ```

   (`renderPgSnapshot` already sorts and dedupes `xip`; when `xid < snapshot.xmax` the gap
   is empty and the result is today's, correct, behavior. Note `xmin` is deliberately left
   alone: raising it would falsely mark old xids visible; the comparator only needs
   `xmax`/`xip` to be truthful.)
2. `tokenFromAnchor :: ConsistencyConfig -> Anchor -> Either Text ConsistencyToken`
   propagates the `Either`. The write session(s) — `writeTuplesSession` and
   `deleteTuplesSession`, or `applyTupleWritesSession` if docs/plans/46 has landed — return
   the `Anchor` instead of the token, and the interpreter mints:
   `either (throwError . StoreError . ("could not mint write token: " <>)) pure
   (tokenFromAnchor config anchor)`. No caller-visible type changes: the `writeTuples`
   helper still yields `ConsistencyToken`.

Integration scenario — **token repeatability under a concurrent writer** (the headline;
write it first and watch it fail pre-fix):

1. Acquire a second connection (`connection2`) from the same `ephemeral-pg` database (reuse
   the suite's `acquire` helper).
2. On `connection2`, open a transaction, force an xid assignment, and make it write
   something the test query will match — then leave it **uncommitted**: run
   `Connection.use connection2` with a session doing `Session.script "BEGIN"`, a
   `SELECT pg_current_xact_id()::text`, and an `INSERT` of a tuple row (reuse the insert
   statement shape with that xid as `created_xid`). hasql runs every `Connection.use` on the
   same underlying libpq connection, so the open transaction persists across calls on
   `connection2`.
3. On the primary connection, `writeTuples [tupleA]` (same object/relation/subject *type*
   as the query, different id from step 2's tuple only in subject or object id) and keep the
   returned token; decode its revision with `tokenMetadataFromPayload` as the suite already
   does.
4. Read `readStartingWithUser` at the token's revision → result R1 (expected: exactly
   `tupleA`).
5. Commit `connection2`'s transaction (`Connection.use connection2 (Session.script
   "COMMIT")`).
6. Read again at the *same* revision → result R2. Assert `R1 == R2` and both contain only
   `tupleA`.

Pre-fix, step 2's xid lies in the write token's raised gap without being in `xip`, so R2
additionally contains the concurrent tuple — the assertion fails with a 1-vs-2 row diff.
(For the gap to exist, step 2's xid must be assigned *before* step 3's write and no other
transaction may commit in between — the sequence above guarantees both on the quiet
throwaway database.) Post-fix, the gap xid is in `xip`, the concurrent tuple is invisible at
that token forever, and the assertion passes. In the same scenario also assert the token
still sees its own write (the read-your-writes property the raised `xmax` exists for), and
confirm the suite's existing `write token is not fresher than immediate head revision`
assertion still passes.


### Milestone 3 — Document the GC-window invariant (C7)

Scope: prose only. In `docs/user/production-deployment-and-performance.md`, add a section
near the consistency-token guidance titled "The GC window bounds token lifetime — keep it
much longer than any request", stating: token validation checks the garbage-collection
horizon once, before the read; the reaper may physically delete soft-deleted rows between
that check and the read; therefore correctness relies on `EN_GC_WINDOW` (default
`24 hours`) exceeding the longest possible request or pagination session by orders of
magnitude. Give the operational rules — never set the window below minutes; when paginating
with `AtExactSnapshot` across user think-time, the window must cover the whole pagination
session — and name the failure mode if violated (a silently incomplete read rather than
`InvalidConsistencyToken`). In `docs/spec/0001-en-overview.md` §7, add one normative
sentence stating the same invariant. In `docs/user/service-and-operations.md`, extend the
`EN_GC_WINDOW` table entry with a pointer to the new section.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/en`. The integration suite needs no
external database — `ephemeral-pg` launches a throwaway PostgreSQL, requiring only the
PostgreSQL binaries the dev shell puts on `PATH`. (The dev process-compose database from
`just process-up` is *not* required for this plan.)

1. Milestone 1 edits, then:

   ```bash
   cabal build all
   cabal test en-postgres-integration-tests
   ```

   Expected: `1 of 1 test suites (1 of 1 test cases) passed`, including the three new
   labeled assertions (`malformed cursor is rejected`, `malformed caveat payload is a
   StoreError`, `limit-0 page makes no progress`).
2. Milestone 2: add the repeatability scenario *first* and run it against unmodified code:

   ```bash
   cabal test en-postgres-integration-tests
   ```

   Expected pre-fix failure transcript fragment:

   ```text
   reads at one write token are repeatable across a concurrent commit
   expected: 1
   actual:   2
   ```

   Apply the `writeVisibleSnapshot`/`tokenFromAnchor` changes, rerun, expect a pass. Paste
   both transcripts into Surprises & Discoveries.
3. Milestone 3 doc edits, then verify:

   ```bash
   grep -n "GC window" docs/user/production-deployment-and-performance.md docs/spec/0001-en-overview.md docs/user/service-and-operations.md
   ```

   Expected: at least one hit in each file.
4. Full sweep:

   ```bash
   cabal test all
   ```

5. Commit per milestone with the plan trailer, e.g.:

   ```text
   fix(en-postgres): error on malformed cursors and undecodable caveat payloads

   ExecPlan: docs/plans/47-fail-loudly-on-storage-decode-errors-and-tighten-write-snapshots.md
   ```


## Validation and Acceptance

Acceptance is observable behavior, each item runnable via
`cabal test en-postgres-integration-tests`:

- A read with cursor text `"not-a-number"` returns `Left (InvalidCursor "not-a-number")` —
  not a silently restarted page one.
- A live row whose `caveat_payload` cannot decode makes the read return
  `Left (StoreError …)` — not a row whose empty payload could change a decision.
- Two reads at one write token, straddling a concurrent transaction's commit, return
  identical results — the scenario fails before the fix with a 1-vs-2 diff and passes after;
  the recorded transcripts are the proof of effectiveness beyond compilation.
- A `limit = 0` read loses no rows across resumption.
- The deployment guide, the spec, and the operations guide state the GC-window invariant
  (grep transcript in Concrete Steps step 3).
- `cabal test all` passes, showing no consumer regressed (the token format is unchanged, so
  no en-servant or en-biscuit suite should notice anything).


## Idempotence and Recovery

All steps are re-runnable; there are no migrations and no destructive operations. The
repeatability scenario must commit-or-rollback its held transaction and release the second
connection even on assertion failure (wrap in a finalizer such as `Control.Exception.finally`)
so a failing run cannot wedge later scenarios on the shared throwaway database. Each
milestone is an independent commit; reverting one does not disturb the others — Milestones 1
and 2 touch disjoint functions in the same file.


## Interfaces and Dependencies

- `hasql` (`Hasql.Decoders.jsonbBytes` with a fallible decode function) — the strict payload
  decoder; no new package dependencies anywhere in this plan.
- `aeson` — already used for payload JSON; the fallible decoder reuses the existing
  `decodeCaveatPayload`.
- `ephemeral-pg` — the repeatability scenario acquires two connections from one throwaway
  database.

Signatures that must exist at the end (full module paths):

- `En.Error.EnError` with `InvalidCursor Text`.
- `En.Postgres.TupleStore.decodeCursor :: StoreCursor -> Either EnError Int64`.
- `En.Postgres.TupleStore.writeVisibleSnapshot :: Anchor -> Either Text Text` and
  `En.Postgres.TupleStore.tokenFromAnchor :: ConsistencyConfig -> Anchor -> Either Text
  ConsistencyToken` (both internal), with the write sessions returning `Anchor` and the
  interpreter minting the token.
- `En.Postgres.TupleStore.pageFromRows :: Int64 -> Int -> [TupleRow] -> TuplePage` (incoming
  cursor threaded).

Cross-plan boundary (restated): this plan owns the snapshot definition
(`writeVisibleSnapshot`) — docs/plans/46 and docs/plans/48 must call it unmodified; the
uniqueness index belongs to docs/plans/45; the final write signature to docs/plans/46; index
trimming and the `created_xid`/watch coordination to docs/plans/49 with
docs/plans/53-add-a-watch-changelog-api.md. The HTTP mapping for `InvalidCursor` belongs to
docs/plans/35-version-the-wire-contract-and-type-the-error-model.md.
