---
id: 53
slug: add-a-watch-changelog-api
title: "Add a watch changelog API"
kind: exec-plan
created_at: 2026-07-07T15:25:10Z
master_plan: "docs/masterplans/9-complete-the-en-api-surface.md"
---

# Add a watch changelog API

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Systems built around an authorization service need to *react* to permission changes:
a downstream cache must invalidate entries when a grant is revoked, a search index
must re-sync its ACL filters when membership changes, and a Biscuit decision-token
deployment (see `en-biscuit`) needs a revocation feed — "tell me every grant deletion
so I can revoke the tokens minted from it". en has no way to deliver any of this
today: there is no changelog endpoint, so consumers must poll full reads or read the
database directly. Yet the changelog already *exists* in the tables — en's
soft-delete design records the creating and deleting transaction (`created_xid`,
`deleted_xid`) on every tuple row, and `en_transaction` anchors every write with its
snapshot. This is gap E5 of
`docs/reviews/2026-07-07-architecture-performance-review.md`, coordinated by
`docs/masterplans/9-complete-the-en-api-surface.md`, whose Decision Log already
commits to building watch on the existing tables rather than a new outbox table.

After this change, `POST /watch` is a cursored polling feed: a client presents a
cursor (or asks to start "from now", or presents an ordinary write token to start
from a known write), and receives the batch of tuple change events — touch (a tuple
became live) or delete (a tuple stopped being live) — that became visible between the
cursor's snapshot and the current head, plus a resumption cursor. Cursors older than
the garbage-collection horizon are rejected with the same typed stale-cursor error
that stale consistency tokens get, because pruned history cannot be replayed.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: Define `ChangeKind`, `TupleChange`, `ChangePage` and the `ReadChanges` operation in `en-core/src/En/Effect/TupleStore.hs`; stub it in the in-memory interpreter (`en-core/src/En/Conformance/Kikan.hs`).
- [ ] M1: Implement the window query in `en-postgres/src/En/Postgres/TupleStore.hs` (two `UNION ALL` arms with xmin bounds; id-keyset pagination within the window).
- [ ] M1: Integration tests in `en-postgres/integration-test/Main.hs`: write→window shows touch; delete→window shows delete; create+delete inside one window is skipped; within-window pagination is complete and duplicate-free; `EXPLAIN` confirms the `created_xid`/`deleted_xid` indexes serve the arms.
- [ ] M2: Watch cursor codec and validation in `en-postgres/src/En/Postgres/Watch.hs` (new module), including accepting an `en1.` consistency token as a start position and the GC-horizon expiry check; unit tests in `en-postgres/test/Main.hs`.
- [ ] M2: The `watch` orchestration function (window selection, draining state machine, resumption cursor, `checkedAt` token) in `En.Postgres.Watch`, integration-tested.
- [ ] M3: `POST /watch` route, wire DTOs, `Env.watchOperation`, server wiring, `EnClient.watch`; servant tests including the cursor-expired error path.
- [ ] M3: If `docs/plans/50`'s `RelationshipFilter` has landed, add the optional `filter` field to the watch request and apply it as residual predicates; otherwise record the deferral.
- [ ] M4: Run the end-to-end transcript (start from now → write → poll shows touch → delete → poll shows delete) against a live server and paste the output into Validation and Acceptance.
- [x] Record the index-retention coordination entry with `docs/plans/49` in both Decision Logs — done 2026-07-09 when EP-49 landed: `relation_tuple_created_xid_idx` is KEPT and reserved for this plan.
- [ ] Record the pruning coordination entry in the Decision Log of `docs/plans/37` when that plan lands (see Decision Log here).


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Build the feed as a *pull* API — a simple cursored polling endpoint (`POST /watch`) — first; NDJSON/SSE streaming is an explicitly deferred later milestone, not part of this plan.
  Rationale: Polling composes with the existing one-request-one-response Servant handlers, needs no connection lifecycle management on the single-connection server (review A2), and every streaming design still needs the cursor semantics this plan builds. Wire streaming for large results is separately tracked as review gap E13. Long-poll (holding the request open until events exist) is likewise deferred; clients poll on their own interval.
  Date: 2026-07-07
- Decision: Events are delivered in per-revision-window batches with *no ordering guarantee inside a batch*. A batch is the set difference of the live tuple set between two snapshots; ordering holds only between batches (everything in batch N became visible at or before batch N+1's window start).
  Rationale: Honest to the storage model. xid8 assignment order is not commit order — a transaction that acquired a lower xid can commit after one with a higher xid — so sorting events by `created_xid` would fabricate an order that PostgreSQL never promised. What *is* well-defined is snapshot-to-snapshot visibility (`pg_visible_in_snapshot`), which is exactly what reads use, so the feed uses the same oracle. Consumers needing total order per tuple key must serialize on the tuple, which the batch model supports (a tuple appears at most once per batch, see next entry).
  Date: 2026-07-07
- Decision: A row whose creation *and* deletion both became visible within the same window is skipped entirely; a row whose deletion became visible emits `Delete`; otherwise a newly visible row emits `Touch`. Each row therefore contributes at most one event per batch.
  Rationale: The batch contract is "the delta of the live set between two snapshots". A grant that appeared and vanished inside one window is a net no-op for every stated consumer (cache invalidation, ACL sync, revocation of tokens minted from it — no token could have been minted at a snapshot where it was live and still be unexpired against a feed consumer that never saw it). Emitting phantom touch/delete pairs would force consumers to handle intra-batch ordering, contradicting the previous decision.
  Date: 2026-07-07
- Decision: The watch cursor is its own codec (`enwatch1.` prefix, percent-escaped fields like the `en1.` token codec) carrying the datastore id, the window-boundary snapshot(s), and — mid-window only — the last row id. Validation checks the datastore id and the GC horizon exactly as `validateTokenMetadata` does, but deliberately does NOT check the schema hash.
  Rationale: The cursor must carry more than a token (a mid-drain position), so it cannot literally be an `en1.` token. Datastore-id and GC checks are the same fail-closed guards tokens get (`validateTokenMetadata` in `en-postgres/src/En/Postgres/Revision.hs`). The schema-hash check is dropped because tuple change events are schema-independent data; expiring every watch consumer on a schema reload (see `docs/plans/54-manage-the-schema-lifecycle-at-runtime.md`) would sever revocation feeds at exactly the moment operators change models. This divergence from token validation is intentional and documented.
  Date: 2026-07-07
- Decision: A plain `en1.` consistency token is accepted as a *start position* (its revision becomes the window start after full `validateTokenMetadata` validation, schema hash included, since it is a real token).
  Rationale: "Give me everything since my write" and "start the revocation feed from the token embedded in this Biscuit grant" become one-call idioms; `docs/plans/57-mint-biscuit-grants-over-http.md`'s revocation story leans on this.
  Date: 2026-07-07
- Decision: Expired cursors are rejected with `InvalidConsistencyToken "watch cursor is older than the garbage-collection window"` — the existing `EnError` constructor, not a new one.
  Rationale: It is the same failure class as a stale token, and the closed `EnError` type is pattern-matched across the codebase; `docs/plans/35-version-the-wire-contract-and-type-the-error-model.md` (master plan 6) owns giving it a machine-readable wire code and should map this message distinctly if consumers need to distinguish it.
  Date: 2026-07-07
- Decision: The window query stays index-served by bounding each arm with the window-start snapshot's xmin: `created_xid >= $start_xmin::xid8` (any xid below the start snapshot's xmin was already visible at the start, so it cannot be newly visible). This makes `relation_tuple_created_xid_idx` and `relation_tuple_deleted_xid_idx` load-bearing. Coordination: `docs/plans/49-trim-dead-indexes-and-resolve-consistency-lazily.md` (master plan 8) proposes dropping `relation_tuple_created_xid_idx` as dead — this plan is the consumer that keeps it. Whichever plan lands first must record the reconciliation in BOTH Decision Logs (this entry is EP-53's half; add the mirror entry to EP-49's log at landing time).
  Rationale: Without the xmin bound both arms are sequential scans on every poll; with it, each arm is a range scan over exactly the recent portion of the table. The master plan's Integration Points call out this index conflict explicitly.
  Date: 2026-07-07
- Decision: **(mirror entry, added by docs/plans/49 at its landing time)** EP-49 kept `relation_tuple_created_xid_idx`, reserved for this plan. Its EXPLAIN sweep of the whole statement set confirmed the index serves nothing today (`idx_scan = 0` across a driven workload against a 250k-row table), so this plan is its sole justification. If this plan's design ends up not needing it — for example if the window query drops the `created_xid >= $start_xmin::xid8` bound, or watch is built on a different substrate — **this plan must arrange the drop**, since EP-49 will have closed by then. EP-49 also dropped `relation_tuple_object_live_idx` and `relation_tuple_subject_live_idx`; neither is referenced by the window query above, so nothing in this plan is affected. Note for M1's `EXPLAIN` step: `relation_tuple_deleted_xid_idx` survives (it serves the reaper) and is confirmed to serve `deleted_xid` range scans.
  Rationale: Recorded per the coordination obligation in this plan's `created_xid` Decision Log entry and in `docs/masterplans/8-correct-write-path-and-storage-semantics.md`'s Integration Points. Dropping and re-adding an index on a large table is avoidable churn, and this plan affirmatively claims the index.
  Date: 2026-07-09
- Decision: Recovery is bounded by the GC horizon maintained by `docs/plans/37-schedule-background-maintenance-for-reaping-and-transaction-pruning.md` (master plan 6): once the reaper prunes soft-deleted rows and `en_transaction` rows behind the horizon, windows starting before it are unreconstructible, so cursor validation *must* reject them (previous entries). A consumer that falls behind for longer than `EN_GC_WINDOW` must full-resync (e.g. via `docs/plans/50`'s relationship query) and restart the feed from now. Record the mirror entry in EP-37's Decision Log when it lands: the pruning cadence defines the watch recovery window, so shortening `EN_GC_WINDOW` shortens permissible consumer downtime.
  Rationale: Stated dependency from the master plan's Integration Points; making the operational trade-off explicit here keeps both plans honest.
  Date: 2026-07-07
- Decision: The datastore-specific parts (cursor codec, validation, window orchestration) live in a new module `en-postgres/src/En/Postgres/Watch.hs`; en-core gets only the event/page types and the `ReadChanges` storage operation. The Servant handler reaches the orchestration through a new `Env.watchOperation` field.
  Rationale: Snapshot parsing and token codecs are PostgreSQL-specific (they live in `En.Postgres.Revision` today), and `en-servant` already depends on `en-postgres` (`En.Servant.Seam` imports `En.Postgres.Database`). Forcing a datastore-neutral watch abstraction through en-core would invent effects with exactly one real interpreter.
  Date: 2026-07-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

The repository root is `/Users/shinzui/Keikaku/bokuno/en` (Haskell, GHC 9.12.4,
`cabal`). Packages touched: `en-core` (event types, storage operation), `en-postgres`
(the real implementation), `en-servant`/`en-server` (endpoint), `en-client` (client
field). This plan fixes gap E5 of
`docs/reviews/2026-07-07-architecture-performance-review.md` under
`docs/masterplans/9-complete-the-en-api-surface.md`.

How en stores history — read this section against
`en-migrations/db/migrations/20260623044157_create-relation-tuples.sql` and
`en-postgres/src/En/Postgres/TupleStore.hs`. Every grant is a row in
`relation_tuple`. Rows are never updated in place except once: `created_xid` (an
`xid8`, PostgreSQL's 64-bit transaction id) is set at insert, and a delete sets
`deleted_xid` (soft delete). Every writing transaction also inserts an anchor row into
`en_transaction (xid, snapshot, schema_hash, created_at)` recording its own xid and
the `pg_snapshot` at write time; the write's consistency token is minted from that
anchor. A **snapshot** (`xmin:xmax:xip`) defines visibility: transaction `t` is
visible in snapshot `S` iff `t < S.xmin`, or `t < S.xmax` and `t ∉ S.xip`
(PostgreSQL's `pg_visible_in_snapshot`; mirrored in Haskell as `transactionVisible`
in `en-postgres/src/En/Postgres/Revision.hs`). Reads at revision `R` see rows where
the creation is visible in `R` and the deletion (if any) is not. A **Revision** in
en-core is the opaque rendered snapshot; a **ConsistencyToken** wraps it with
datastore id, schema hash, and optional expiry (`encodeToken`/`decodeToken`,
validation in `validateTokenMetadata` — including the GC check: a token whose
snapshot `xmax` is at or below `oldestRetainedXid` is "older than the
garbage-collection window").

The changelog insight (review E5): "which tuples changed between snapshot A and
snapshot B" is answerable from these tables alone. A row's creation *became visible*
in the window (A, B] iff `pg_visible_in_snapshot(created_xid, B) AND NOT
pg_visible_in_snapshot(created_xid, A)`; deletions likewise via `deleted_xid`. The
`oldestRetainedXid` operation (already on the `TupleStore` effect,
`oldestRetainedXidStatement` in `en-postgres/src/En/Postgres/TupleStore.hs`) gives
the GC horizon: `docs/plans/37-schedule-background-maintenance-for-reaping-and-transaction-pruning.md`
will prune `en_transaction` and reap soft-deleted rows behind it, which is why
windows must not start before it.

What a window can and cannot promise: xid8 values are assigned at transaction start,
but visibility flips at commit, and commit order need not match xid order. So "events
between A and B" is a well-defined *set*, but there is no faithful total order of
events inside it. This plan's contract (see Decision Log) is per-window batches,
unordered within a batch.

Indexes: `relation_tuple_created_xid_idx (created_xid)` and the partial
`relation_tuple_deleted_xid_idx (deleted_xid) WHERE deleted_xid IS NOT NULL` exist
from the base migration and are currently used by *nothing* (review C9 calls them
dead weight) — this plan is the consumer that justifies them; see the Decision Log
entry coordinating with `docs/plans/49`.

The HTTP layer conventions (routes and DTOs in `en-servant/src/En/Servant/API.hs`,
the `Env` seam in `en-servant/src/En/Servant/Seam.hs`, operation fields wired in
`en-server/app/Main.hs`, client record in `en-client/src/En/Client.hs`) are the same
as every other endpoint; see those files.

Use cases this feed serves, restated from the review: downstream cache invalidation
(evict authorization-derived cache entries whose tuples changed), search-index ACL
sync (recompute per-document visibility when grants change), and the Biscuit
revocation feed (when a grant tuple underlying a minted decision token is deleted,
publish its revocation id — `en-biscuit` consumers subscribe to deletes).

External sequencing restated from the master plan: prefer landing
`docs/plans/35-version-the-wire-contract-and-type-the-error-model.md` first so this
endpoint is born inside the versioned contract and the cursor-expired error gets a
typed code. `docs/plans/50`'s `RelationshipFilter` is a soft dependency for scoping
the feed. `docs/plans/51`'s `checkedAt` convention applies to this response DTO from
day one.


## Plan of Work

Four milestones: the storage window query (M1), cursor codec and orchestration (M2),
the HTTP surface (M3), and the live demonstration (M4).


### Milestone 1: the window query as a storage operation

Scope: after this milestone the store can answer "what changed in (A, B], paged", and
integration tests prove correctness of the visibility algebra.

In `en-core/src/En/Effect/TupleStore.hs`, add and export:

```haskell
data ChangeKind = ChangeTouch | ChangeDelete
    deriving stock (Eq, Ord, Show)

data TupleChange = TupleChange
    { kind :: !ChangeKind
    , tuple :: !Tuple
    , rowId :: !TupleRowId
    }
    deriving stock (Eq, Show)

data ChangePage = ChangePage
    { changes :: ![TupleChange]
    , state :: !PageState
    }
    deriving stock (Eq, Show)

    -- new GADT constructor:
    ReadChanges :: Revision -> Revision -> Int -> Maybe StoreCursor -> TupleStore m ChangePage
```

with smart constructor `readChanges start end limit cursor`. Semantics: all rows whose
live-set membership changed between snapshot `start` and snapshot `end`, classified
per the Decision Log (delete-visible-in-window ⇒ `ChangeDelete`; else
newly-created-and-still-live ⇒ `ChangeTouch`; created-and-deleted-in-window ⇒
skipped), ordered by row id (a stable within-window pagination key, *not* an event
order), keyset-paged like every other read.

Extend `runTupleStoreInMemory` in `en-core/src/En/Conformance/Kikan.hs` with a stub:
the fixture store is a static tuple list with one test revision, so `ReadChanges`
returns every fixture tuple as `ChangeTouch` in one exhausted page — enough for
handler-level tests; real semantics are integration-tested.

In `en-postgres/src/En/Postgres/TupleStore.hs`, implement the session. Parse both
revisions to snapshots (reject unparseable ones as `InvalidConsistencyToken` via the
existing error mapping); pass the start snapshot's `xmin` separately for the sargable
bound. The statement (two arms, each index-served):

```sql
SELECT id, object_type, object_id, relation, subject_type, subject_id, subject_relation,
       caveat_name, caveat_payload, created_xid::text, deleted_xid::text,
       (deleted_xid IS NOT NULL
        AND pg_visible_in_snapshot(deleted_xid, $2::pg_snapshot)
        AND NOT pg_visible_in_snapshot(deleted_xid, $1::pg_snapshot)) AS is_delete
FROM relation_tuple
WHERE id > $5
  AND (
        ( created_xid >= $3::xid8
          AND pg_visible_in_snapshot(created_xid, $2::pg_snapshot)
          AND NOT pg_visible_in_snapshot(created_xid, $1::pg_snapshot) )
     OR ( deleted_xid IS NOT NULL
          AND deleted_xid >= $3::xid8
          AND pg_visible_in_snapshot(deleted_xid, $2::pg_snapshot)
          AND NOT pg_visible_in_snapshot(deleted_xid, $1::pg_snapshot) )
      )
ORDER BY id ASC
LIMIT $4
```

then classify rows in Haskell: `is_delete` ⇒ `ChangeDelete`, unless the row's
creation *also* became newly visible in the window (both flags) — skip; else
`ChangeTouch`. (Computing "creation newly visible" needs the same two
`pg_visible_in_snapshot` calls on `created_xid`; select it as a second boolean column
rather than recomputing client-side.) Note `$3` (the start snapshot's xmin) is the
performance bound; if `EXPLAIN` shows the planner cannot use the indexes through the
`OR`, split into two statements combined with `UNION ALL` — record the outcome in
Surprises & Discoveries. Reuse `tupleRowDecoder`'s column conventions and
`pageFromRows`-style limit+1 paging.

Integration tests in `en-postgres/integration-test/Main.hs` (ephemeral PostgreSQL, no
dev database needed): capture snapshot A (`headRevision`); write tuples; capture B;
assert `readChanges A B` returns exactly the touches; delete one tuple; capture C;
assert `readChanges B C` returns exactly one `ChangeDelete`; assert `readChanges A C`
for a tuple written *and* deleted between A and C returns nothing for it (net no-op
rule); assert within-window pagination with `limit = 1` visits every change exactly
once; run `EXPLAIN` for the statement and record whether the xid indexes serve it.

Acceptance: `cabal build all && cabal test en-postgres-integration-tests` passes.


### Milestone 2: cursor codec, validation, and orchestration

Scope: after this milestone `En.Postgres.Watch.watch` implements the full feed step —
decode/validate cursor, choose the window, drain a page, hand back the resumption
cursor — with unit and integration tests.

Create `en-postgres/src/En/Postgres/Watch.hs` (add to `exposed-modules` in
`en-postgres/en-postgres.cabal`):

```haskell
data WatchCursorState
    = WatchAt !Revision                        -- between windows: next window starts here
    | WatchDraining !Revision !Revision !TupleRowId  -- mid-window: (start, end, last row id)

encodeWatchCursor :: DatastoreId -> WatchCursorState -> Text
decodeWatchCursor :: Text -> Either EnError (DatastoreId, WatchCursorState)

data WatchStart
    = StartFromNow
    | StartFromCursor !Text        -- an enwatch1. cursor
    | StartFromToken !Text         -- an en1. consistency token (validated fully)

data WatchBatch = WatchBatch
    { changes :: ![TupleChange]
    , cursor :: !Text              -- resumption cursor, always present
    , checkedAt :: !ConsistencyToken  -- token of the window-end revision (EP-51 convention)
    }

watch ::
    (TupleStore :> es, ConsistencyStore :> es, IOE :> es, Error EnError :> es) =>
    ConsistencyConfig -> WatchStart -> Int -> Eff es WatchBatch
```

Codec: `enwatch1.` prefix, percent-escaped fields (reuse `escapeText`/`unescapeText`
from `En.Postgres.Revision` — export them if internal) carrying datastore id, a tag
for at/draining, the snapshot(s), and the row id. Validation on decode, mirroring
`validateTokenMetadata`'s shape: datastore id must equal
`config.datastoreId`; the (start) snapshot must parse; and the GC check — if
`snapshot.xmax <= oldestRetainedXid` then
`Left (InvalidConsistencyToken "watch cursor is older than the garbage-collection
window")`. No schema-hash check (Decision Log). `StartFromToken` decodes with
`tokenMetadataFromPayload` and validates with the *full* token validation, then
behaves as `WatchAt` that token's revision.

Orchestration in `watch`: for `StartFromNow`, return an empty batch whose cursor is
`WatchAt head` (one `headRevision` call, no events — "subscribe from now"). For
`WatchAt start`: take `end = headRevision`; if `end` equals `start`, return an empty
batch with the same cursor; else drain one page of `readChanges start end limit
Nothing`; if the page has more, the cursor is `WatchDraining start end lastRowId`,
else `WatchAt end`. For `WatchDraining start end lastId`: continue paging the *fixed*
window (the end snapshot must not advance mid-drain, or the batch loses its
set-difference meaning). `checkedAt` is minted from the window-end revision — via
`mintToken` if `docs/plans/51` has landed, else via `encodeToken` directly with the
config (record which in this Decision Log).

Unit tests in `en-postgres/test/Main.hs` (pure codec round-trips, wrong-datastore and
expired-cursor rejections with the exact error text). Integration tests extend M1's
scenario through `watch` itself: from-now subscribe → write → poll yields the touch
and an advancing cursor → delete → poll yields the delete; a cursor forged with
`xmax = 1` is rejected as expired.

Acceptance: `cabal test en-postgres-revision-tests` (or wherever the suite lives —
check `en-postgres/en-postgres.cabal` stanza names) and
`cabal test en-postgres-integration-tests` pass.


### Milestone 3: endpoint, seam, server, client

Scope: after this milestone `POST /watch` serves the feed over HTTP.

In `en-servant/src/En/Servant/Seam.hs`, add
`watchOperation :: !(WatchStart -> Int -> Eff es WatchBatch)` to `Env` (importing
from `En.Postgres.Watch`; the seam already depends on en-postgres). Wire it in
`en-server/app/Main.hs` as `watch config` partially applied. In
`en-servant/src/En/Servant/API.hs`, add:

```haskell
        :<|> "watch" :> ReqBody '[JSON] WatchRequestWire :> Post '[JSON] WatchResponseWire
```

with DTOs: `WatchRequestWire { cursor :: Maybe Text, startToken :: Maybe Text,
limit :: Int }` (both `cursor` and `startToken` absent ⇒ start from now; both present
⇒ 400), `TupleChangeWire { kind :: ChangeKindWire, tuple :: TupleWire }`,
`ChangeKindWire = TouchWire | DeleteWire`, and `WatchResponseWire { changes ::
[TupleChangeWire], cursor :: Text, checkedAt :: Text }`. Clamp `limit` to the server's
page bounds (follow `maxBatchSize`'s precedent). If `docs/plans/50` has landed, add
`filter :: Maybe RelationshipFilterWire` applied as residual predicates inside the
window query (the filter is EP-50's type, reused unchanged per the master plan's
Integration Points); otherwise record the deferral in the Decision Log.

Add `watch` to `EnClient` in `en-client/src/En/Client.hs`. Extend
`en-servant/test/Main.hs` with a handler round trip over the in-memory stub and a 400
for cursor+startToken together.

Acceptance: `cabal build all && cabal test en-servant` passes.


### Milestone 4: live demonstration

Scope: run the subscribe → write → poll → delete → poll story against a real server
and record the transcript in Validation and Acceptance.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/en` in the dev shell.

Build and database-free tests:

```bash
cabal build all
cabal test en-core
cabal test en-servant
```

Storage tests (ephemeral PostgreSQL via ephemeral-pg; dev shell only):

```bash
cabal test en-postgres-integration-tests
```

Dev PostgreSQL and server (Justfile: `process-up` starts PostgreSQL under
process-compose and waits for readiness; `start-server` applies migrations from
`en-migrations/db/migrations/` with `psql` then runs `cabal run en-server`; stop
everything with `process-down`):

```bash
just process-up
just start-server
```


## Validation and Acceptance

Live transcript, demo schema (`space#viewer`, served when `EN_SCHEMA_PATH` is unset).

Step 1 — subscribe from now (no cursor):

```bash
curl -sS -X POST localhost:8080/watch -H 'content-type: application/json' \
  -d '{"cursor": null, "startToken": null, "limit": 100}'
```

```json
{"changes": [], "cursor": "enwatch1.…", "checkedAt": "en1.…"}
```

Step 2 — write a grant, then poll with the cursor from step 1:

```bash
curl -sS -X POST localhost:8080/tuples -H 'content-type: application/json' -d '{
  "tuples": [{"object": {"objectType": "space", "objectId": "project-x"}, "relation": "viewer",
              "subject": {"tag": "SubjectIdWire", "contents": {"objectType": "user", "objectId": "alice"}},
              "caveat": null}]}' > /dev/null

curl -sS -X POST localhost:8080/watch -H 'content-type: application/json' \
  -d '{"cursor": "<cursor from step 1>", "startToken": null, "limit": 100}'
```

```json
{
  "changes": [
    {"kind": {"tag": "TouchWire"},
     "tuple": {"object": {"objectType": "space", "objectId": "project-x"},
               "relation": "viewer",
               "subject": {"tag": "SubjectIdWire", "contents": {"objectType": "user", "objectId": "alice"}},
               "caveat": null}}
  ],
  "cursor": "enwatch1.…",
  "checkedAt": "en1.…"
}
```

Step 3 — delete the grant, poll with the newest cursor: the response contains the
same tuple with `"kind": {"tag": "DeleteWire"}` and a further-advanced cursor. A
fourth poll returns `"changes": []` (feed is caught up; the cursor may stay equal).

Error path: a cursor whose start snapshot lies behind the GC horizon returns the
stale-cursor error (`{"error": "InvalidConsistencyToken \"watch cursor is older than
the garbage-collection window\""}`-shaped under today's collapsed error model, review
A3; a typed code once `docs/plans/35` lands). This path is asserted in the M2 tests
with a forged low-xmax cursor rather than by waiting out a real GC window.

Test-level validation: M1's visibility-algebra assertions (touch, delete,
net-no-op skip, pagination completeness), M2's codec/validation/orchestration tests,
and M3's handler tests — under the commands in Concrete Steps. The recorded `EXPLAIN`
must show index usage on the xid arms (or the Surprises entry explains the fallback
taken).


## Idempotence and Recovery

Watching is read-only: polling with the same cursor repeatedly returns the same batch
(for a fixed head; the mid-window `WatchDraining` cursor pins both window edges, so
even drains are repeatable). Consumers get at-least-once delivery by persisting the
cursor only after processing a batch; the batch model makes redelivery idempotent for
set-oriented consumers. If a consumer's cursor expires (offline longer than
`EN_GC_WINDOW`), recovery is: full resync of the derived state (e.g. via the
relationship query of `docs/plans/50`, or full re-check), then subscribe from now —
document this in the operator docs when touching them. Nothing in this plan writes to
the database or migrates schema; every milestone is safely re-runnable. The window
query's cost is bounded by the xmin bound plus the page limit; if a pathological
window (huge backlog) is slow, the drain cursor spreads it across polls.


## Interfaces and Dependencies

End-state interfaces, by full module path:

- `En.Effect.TupleStore` (`en-core/src/En/Effect/TupleStore.hs`): `ChangeKind`,
  `TupleChange`, `ChangePage`, constructor `ReadChanges :: Revision -> Revision ->
  Int -> Maybe StoreCursor -> TupleStore m ChangePage`, smart constructor
  `readChanges`.
- `En.Conformance.Kikan` (`en-core/src/En/Conformance/Kikan.hs`): in-memory stub for
  `ReadChanges`.
- `En.Postgres.TupleStore` (`en-postgres/src/En/Postgres/TupleStore.hs`): the window
  session/statement of M1. No schema migration; the existing
  `relation_tuple_created_xid_idx` and `relation_tuple_deleted_xid_idx` become
  load-bearing (coordinate with `docs/plans/49` — see Decision Log).
- `En.Postgres.Watch` (`en-postgres/src/En/Postgres/Watch.hs`, new): `WatchCursorState`,
  `WatchStart`, `WatchBatch`, `encodeWatchCursor`, `decodeWatchCursor`,
  `watch :: (TupleStore :> es, ConsistencyStore :> es, IOE :> es, Error EnError :> es)
  => ConsistencyConfig -> WatchStart -> Int -> Eff es WatchBatch`. May require
  exporting `escapeText`/`unescapeText` from `En.Postgres.Revision`.
- `En.Servant.Seam` / `En.Servant.API` / `en-server/app/Main.hs` / `En.Client`:
  `Env.watchOperation`, route `POST /watch`, wire types `WatchRequestWire`,
  `TupleChangeWire`, `ChangeKindWire`, `WatchResponseWire`, client field `watch`.

Dependencies and coordination, restated so this plan stands alone: no hard plan
dependencies. Prefer landing after `docs/plans/35-version-the-wire-contract-and-type-the-error-model.md`
(versioned contract; typed cursor-expired code). Soft dependency on
`docs/plans/50-expose-relationship-read-and-delete-by-filter-endpoints.md` for the
optional subscription filter (EP-50 owns `RelationshipFilter`). The response carries
`checkedAt` per `docs/plans/51-return-checked-at-consistency-tokens-from-read-responses.md`.
Mutual-coordination obligations recorded in the Decision Log: with
`docs/plans/49-trim-dead-indexes-and-resolve-consistency-lazily.md` (the
`created_xid` index must survive) and with
`docs/plans/37-schedule-background-maintenance-for-reaping-and-transaction-pruning.md`
(the pruning horizon defines the feed's recovery window; pruning must not outpace the
documented `EN_GC_WINDOW` contract). No new package dependencies are required.
