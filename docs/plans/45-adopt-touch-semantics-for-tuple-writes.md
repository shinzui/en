---
id: 45
slug: adopt-touch-semantics-for-tuple-writes
title: "Adopt touch semantics for tuple writes"
kind: exec-plan
created_at: 2026-07-07T15:24:59Z
master_plan: "docs/masterplans/8-correct-write-path-and-storage-semantics.md"
---

# Adopt touch semantics for tuple writes

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

en is a relationship-based authorization toolkit: applications write *tuples* ("alice is a
viewer of space:project-x", optionally guarded by a *caveat* such as "only until July 1st")
into PostgreSQL, and the engine answers permission checks against them. Today the write path
has an authorization-correctness trap, finding C1 of
`docs/reviews/2026-07-07-architecture-performance-review.md`: rewriting a live tuple with a
different caveat *payload* (same caveat name) is silently dropped by `ON CONFLICT DO NOTHING`
while the caller receives a success token — the new expiry date never takes effect. Worse,
writing the same (object, relation, subject) with a different caveat *name* — for example,
adding a caveat to tighten a previously unconditional grant — creates a *second* live row while
the unconditional grant stays in force, so the tightening silently does nothing.

After this plan, en adopts SpiceDB-style **touch semantics**: the identity of a live tuple is
(object, relation, subject) alone — the caveat is an *attribute* of the grant, not part of its
identity. A write that collides with a live row whose caveat name or payload differs
atomically soft-deletes the old row and inserts the new one in the same transaction; the
caller's token sees exactly the new grant. Writing a byte-for-byte identical tuple remains an
idempotent no-op. You can see it working by running
`cabal test en-postgres-integration-tests` from the repository root: new scenarios prove that
a payload update takes effect at the write's token, that caveat-tightening replaces the
unconditional grant instead of duplicating it, and that reads at *older* tokens still see the
old grant (point-in-time history is preserved by the soft delete).


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Create the new migration file with `just make-migration touch-semantics-live-unique` and write the duplicate-resolution UPDATE plus the `relation_tuple_live_unique` redefinition into it.
- [ ] Add the new migration's guard stanza to the `run-migrations` recipe in `Justfile`.
- [ ] Mirror the new unique-index definition into the inline `schemaSql` of `en-postgres/integration-test/Main.hs`.
- [ ] Add `touchReplaceStatement` and the rows-affected variant of `insertTupleStatement` to `en-postgres/src/En/Postgres/TupleStore.hs`; rewrite `writeTuplesSession` around the touch loop.
- [ ] Drop the caveat-name predicate from `deleteTupleStatement` and remove `caveatName` from `TupleDeleteParams`.
- [ ] Make `runTupleStoreInMemory` in `en-core/src/En/Conformance/Kikan.hs` stateful and implement the same touch semantics with pure helpers.
- [ ] Add the payload-update, caveat-tightening, idempotent-rewrite, and old-token-history integration scenarios to `en-postgres/integration-test/Main.hs`.
- [ ] Add the pre-migration duplicate-resolution scenario (old schema, seeded duplicates, migration SQL applied, newest-created_xid winner asserted).
- [ ] Update `docs/spec/0001-en-overview.md` §7 wording from "Upsert inserts a new row" to describe touch semantics.
- [ ] Run `cabal build all`, `cabal test all`, and `just start-and-test`; record transcripts.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Tuple identity for uniqueness is (object_type, object_id, relation, subject_type,
  subject_id, coalesce(subject_relation, '')) — the caveat name is removed from the key.
  Rationale: This is finding C1's root cause and SpiceDB's model: one live grant per
  object/relation/subject; the caveat is an attribute of that grant. Keeping the caveat in the
  key is what allows an unconditional grant and a caveated grant to coexist, defeating
  caveat-tightening.
  Date: 2026-07-07
- Decision: Implement touch as two prepared statements per tuple (soft-delete a differing live
  row, then insert with `ON CONFLICT DO NOTHING`) inside the existing hand-rolled
  BEGIN/COMMIT session, with a bounded verify-and-retry step for cross-transaction races,
  rather than one data-modifying CTE.
  Rationale: A single CTE that both soft-deletes and inserts depends on subtle intra-statement
  ordering of data-modifying CTEs against a partial unique index; two statements in the same
  transaction are equally atomic to observers (nothing is visible until COMMIT), match the
  existing per-tuple session shape, and are straightforward to port to `unnest` batches in
  docs/plans/48-batch-tuple-writes-and-add-bulk-import-and-export.md.
  Date: 2026-07-07
- Decision: The migration resolves pre-existing duplicate live rows by keeping, per identity
  key, the row with the highest `created_xid` (ties broken by highest `id`) and soft-deleting
  the rest with the migration transaction's own xid.
  Rationale: "Newest write wins" is the only rule consistent with the touch semantics being
  introduced — had touch semantics existed all along, the latest write would have replaced the
  earlier ones. `created_xid` is monotone per write transaction; `id` (a `bigserial`) breaks
  the tie for rows written by the same transaction, preferring the later insert.
  Date: 2026-07-07
- Decision: The migration does not insert an `en_transaction` anchor row for its own xid.
  Rationale: Anchor rows exist to mint consistency tokens for writers; the migration mints no
  token. Read visibility (`pg_visible_in_snapshot(deleted_xid, R)`) and the reaper
  (`deleted_xid < horizon`) work on any committed xid whether or not it is anchored.
  Date: 2026-07-07
- Decision: `deleteTupleStatement` stops matching on `caveat_name`; a delete targets the
  (object, relation, subject) identity and removes the live grant whatever its caveat is.
  `TupleDeleteParams` loses its `caveatName` field.
  Rationale: With one live row per identity, requiring the caller to know the current caveat
  name to delete it reintroduces the silent-no-op trap this plan removes (a delete supplying
  yesterday's caveat name would match nothing). This matches SpiceDB's delete-by-key behavior.
  The `DELETE /tuples` wire shape is unchanged; a request's `caveat` field is now ignored for
  deletes.
  Date: 2026-07-07
- Decision: The `TupleStore` effect signature is unchanged in this plan — `WriteTuples ::
  [Tuple] -> TupleStore m ConsistencyToken` stays as is; no created-vs-replaced result is
  added.
  Rationale: The master plan (`docs/masterplans/8-correct-write-path-and-storage-semantics.md`,
  Integration Points) assigns the final write signature to
  docs/plans/46-add-write-preconditions-and-atomic-mixed-writes.md. Changing the signature
  twice in consecutive plans would churn every interpreter and consumer for no behavioral
  gain; touch semantics are observable through reads without a distinct result type.
  Date: 2026-07-07
- Decision: The in-memory conformance store (`runTupleStoreInMemory`) becomes stateful using
  `Effectful.State.Static.Local` so writes and deletes actually mutate the tuple set with the
  same touch semantics, while keeping the existing `[Tuple] -> Eff (TupleStore : es) a -> Eff
  es a` signature and remaining runnable under `runPureEff`.
  Rationale: The current interpreter ignores writes entirely, so it cannot mirror any write
  semantics; a pure `State` effect keeps every existing caller (including
  `en-core/conformance/Main.hs`, which uses `runPureEff`) compiling and behaviorally identical
  for read-only fixtures.
  Date: 2026-07-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This plan is a child of `docs/masterplans/8-correct-write-path-and-storage-semantics.md` and
fixes finding C1 of `docs/reviews/2026-07-07-architecture-performance-review.md`. It is the
root of that master plan's dependency graph: docs/plans/46 (preconditions) and docs/plans/48
(batched writes) both hard-depend on the semantics defined here. The original write-path
design intent is recorded in
`docs/plans/2-implement-postgresql-tuple-store-and-consistency-tokens.md`: EP-2 established
soft-deleted, MVCC-versioned tuple rows and treated the tuple *including its caveat name* as
the unit of identity, with `ON CONFLICT DO NOTHING` making re-writes idempotent. That was
correct for exact re-writes but wrong for caveat *changes* — this plan changes what a
conflicting write means, which is why it must land before any plan that builds statements on
top of the conflict behavior.

en is a Haskell project at `/Users/shinzui/Keikaku/bokuno/en`, split into Cabal packages. The
ones this plan touches:

- `en-core` — the engine and abstract interfaces, no database dependency. The storage
  interface is the `TupleStore` *effect* (an interface expressed with the `effectful` library)
  in `en-core/src/En/Effect/TupleStore.hs`: `WriteTuples :: [Tuple] -> TupleStore m
  ConsistencyToken` and `DeleteTuples :: [Tuple] -> TupleStore m ConsistencyToken` are the
  write operations. A `Tuple` (`en-core/src/En/Tuple.hs`) is `{object :: ObjectRef, relation
  :: RelationName, subject :: Subject, caveat :: Maybe TupleCaveat}`; a `TupleCaveat` is a
  caveat *name* plus a *payload* (a map of typed values supplied at write time, e.g. an expiry
  timestamp). `en-core/src/En/Conformance/Kikan.hs` hosts `runTupleStoreInMemory`, the
  in-memory interpreter used by the conformance and en-servant test suites — today its
  `WriteTuples`/`DeleteTuples` cases ignore their arguments and return constant tokens.
  `en-core/src/En/Effect/CachedTupleStore.hs` is a read-cache interposer that passes writes
  through untouched.
- `en-migrations` — the PostgreSQL schema as timestamped SQL files under
  `en-migrations/db/migrations/`, managed by codd (a migration tool that applies the files in
  filename order; locally the `run-migrations` recipe in `Justfile` applies them with `psql`
  behind idempotence guards). The relevant file is
  `en-migrations/db/migrations/20260623044157_create-relation-tuples.sql`. It defines
  `relation_tuple` with `created_xid xid8 NOT NULL` and `deleted_xid xid8 NULL` — a row is
  *live* when `deleted_xid IS NULL`; deletion stamps `deleted_xid` instead of removing the row
  (a *soft delete*), which is what makes point-in-time reads possible. Its lines 23–33 define
  the index this plan replaces:

  ```sql
  CREATE UNIQUE INDEX relation_tuple_live_unique
    ON relation_tuple
      ( object_type
      , object_id
      , relation
      , subject_type
      , subject_id
      , coalesce(subject_relation, '')
      , coalesce(caveat_name, '')
      )
    WHERE deleted_xid IS NULL;
  ```

  The `coalesce(caveat_name, '')` component is the bug: it lets an uncaveated and a caveated
  row for the same (object, relation, subject) be simultaneously live.
- `en-postgres` — the hasql implementation. `en-postgres/src/En/Postgres/TupleStore.hs` holds
  everything this plan rewires: `writeTuplesSession` (line 157) runs `BEGIN`, inserts an
  anchor row into `en_transaction` (recording the write transaction's xid and snapshot for
  token minting), loops one `insertTupleStatement` per tuple, then `COMMIT`;
  `insertTupleStatement` (line 344) is the `INSERT ... ON CONFLICT DO NOTHING`;
  `deleteTupleStatement` (line 391) is an `UPDATE ... SET deleted_xid = $1::xid8` that today
  also matches `coalesce(caveat_name, '') = coalesce($8, '')`. Note the two silent-failure
  consequences: a same-name different-payload write hits the unique index and is dropped by
  `DO NOTHING`; a different-name write misses the index and inserts a duplicate live grant.
- `en-postgres/integration-test/Main.hs` — the `en-postgres-integration-tests` suite. It uses
  the `ephemeral-pg` library to start a throwaway PostgreSQL (no external service needed; it
  requires PostgreSQL binaries such as `initdb` on `PATH`, which the project's dev shell
  provides), creates the schema from an inline `schemaSql` string (lines 438–493) that mirrors
  the migration files, and runs end-to-end scenarios with plain `assertEqual` helpers. Every
  migration change must be mirrored into `schemaSql` or the tests drift from production.

Term: **touch semantics** (from SpiceDB's `TOUCH` write operation). A write of tuple T either
(a) inserts T when no live row shares its identity, (b) does nothing when a live row is
byte-identical to T (same caveat name and payload), or (c) atomically retires the differing
live row (soft delete, stamped with the write transaction's xid) and inserts T. In all cases
the caller's consistency token reflects a state where exactly the written grant is live.

Term: **consistency token**. The opaque string returned by a write; presenting it on a read
("at least as fresh as" / "at exactly this snapshot") makes the read see that write. Token
minting (`tokenFromAnchor`, `writeVisibleSnapshot` in
`en-postgres/src/En/Postgres/TupleStore.hs`) is *not* touched by this plan.

Integration points restated from the master plan
(`docs/masterplans/8-correct-write-path-and-storage-semantics.md`):

- **This plan (EP-45) owns the redefinition of `relation_tuple_live_unique`** — one live row
  per object/relation/subject. docs/plans/46 and docs/plans/48 build their statements against
  this shape.
- **The final `TupleStore` write signature is owned by docs/plans/46** (preconditions and the
  combined write-and-delete operation); this plan must not change the effect constructors.
- **The write-token snapshot definition (`writeVisibleSnapshot`) is owned by docs/plans/47**;
  this plan must not adjust it.
- **The `created_xid` index and the other secondary indexes are owned by docs/plans/49**
  (which coordinates with docs/plans/53-add-a-watch-changelog-api.md); this plan changes only
  the unique index.


## Plan of Work

The work is three milestones: the migration (schema truth first), the PostgreSQL write path,
and the in-memory store — each independently verifiable, with the integration scenarios
landing alongside the code they prove.


### Milestone 1 — Migration: new identity key, deterministic duplicate resolution

Scope: a new codd migration file that (1) resolves any pre-existing duplicate live rows under
the new identity and (2) replaces `relation_tuple_live_unique` with the caveat-free key. At
the end, a database migrated from the old schema has at most one live row per
(object, relation, subject) and rejects a second one.

Create the file with the repository's recipe (it timestamps the filename so codd applies it
after the existing migrations):

```bash
cd /Users/shinzui/Keikaku/bokuno/en
just make-migration touch-semantics-live-unique
```

Write this content into the created
`en-migrations/db/migrations/<timestamp>_touch-semantics-live-unique.sql` (codd runs each
migration in a single transaction, so the dedupe and the index swap are atomic together; the
dedupe MUST come first or `CREATE UNIQUE INDEX` fails on the duplicates it exists to prevent):

```sql
-- Touch semantics (docs/plans/45): a live tuple's identity is
-- (object, relation, subject); the caveat is an attribute, not identity.
--
-- 1. Resolve pre-existing duplicate live rows deterministically: per identity
--    key, the row with the highest created_xid wins (the newest write - the row
--    that touch semantics would have kept); ties on created_xid (same write
--    transaction) are broken by highest id (the later insert). Losers are
--    soft-deleted with this migration transaction's xid so point-in-time reads
--    at pre-migration revisions still see them.
WITH ranked AS (
  SELECT id,
         row_number() OVER (
           PARTITION BY object_type, object_id, relation,
                        subject_type, subject_id, coalesce(subject_relation, '')
           ORDER BY created_xid DESC, id DESC
         ) AS keep_rank
  FROM relation_tuple
  WHERE deleted_xid IS NULL
)
UPDATE relation_tuple
SET deleted_xid = pg_current_xact_id()
WHERE id IN (SELECT id FROM ranked WHERE keep_rank > 1);

-- 2. Re-key live uniqueness without the caveat name.
DROP INDEX relation_tuple_live_unique;

CREATE UNIQUE INDEX relation_tuple_live_unique
  ON relation_tuple
    ( object_type
    , object_id
    , relation
    , subject_type
    , subject_id
    , coalesce(subject_relation, '')
    )
  WHERE deleted_xid IS NULL;
```

Do NOT edit `20260623044157_create-relation-tuples.sql` — it has been applied to real
databases and codd keys applied migrations by file; already-applied migrations are immutable.

Then wire the local apply path and the test schema:

- In `Justfile`, the `run-migrations` recipe applies each migration behind a guard. Add a
  stanza after the existing two, guarded on the new index shape (the index *name* is unchanged,
  so guard on its definition):

  ```just
    @if psql "$PG_CONNECTION_STRING" -tAc "SELECT indexdef FROM pg_indexes WHERE indexname = 'relation_tuple_live_unique'" | grep -q caveat_name; then \
        psql "$PG_CONNECTION_STRING" -v ON_ERROR_STOP=1 -f en-migrations/db/migrations/<timestamp>_touch-semantics-live-unique.sql; \
      else \
        echo "touch-semantics unique index already applied"; \
      fi
  ```

  (Replace `<timestamp>` with the generated filename. Note the polarity: the migration runs
  when the *old* definition, which mentions `caveat_name`, is still present.)
- In `en-postgres/integration-test/Main.hs`, edit the inline `schemaSql` so its
  `relation_tuple_live_unique` matches the new definition (drop `coalesce(caveat_name, '')`
  from the column list). The test database is created fresh each run, so it gets the final
  shape directly; the migration's *dedupe* step is tested separately in Milestone 3.

Acceptance: from `/Users/shinzui/Keikaku/bokuno/en`, `just process-up` then
`just run-migrations` completes; running `just run-migrations` a second time prints the
"already applied" lines (idempotent); and

```bash
psql "$PG_CONNECTION_STRING" -tAc "SELECT indexdef FROM pg_indexes WHERE indexname = 'relation_tuple_live_unique'"
```

prints a definition without `caveat_name`.


### Milestone 2 — PostgreSQL touch write path

Scope: replace the bare `ON CONFLICT DO NOTHING` write with the touch protocol in
`en-postgres/src/En/Postgres/TupleStore.hs`, and re-key the delete. At the end, the two C1
scenarios behave correctly against a real PostgreSQL.

The per-tuple protocol, run inside the existing `BEGIN` … `COMMIT` of `writeTuplesSession`
(after the anchor statement, which supplies the write xid as text):

1. **Touch-delete**: soft-delete a live row with the same identity whose caveat *differs*.
   Add `touchReplaceStatement :: Statement TupleInsertParams Int64` (reuse
   `TupleInsertParams`; decode rows affected with `Decoders.rowsAffected`):

   ```sql
   UPDATE relation_tuple
   SET deleted_xid = $1::xid8
   WHERE object_type = $2
     AND object_id = $3
     AND relation = $4
     AND subject_type = $5
     AND subject_id = $6
     AND coalesce(subject_relation, '') = coalesce($7, '')
     AND deleted_xid IS NULL
     AND (caveat_name IS DISTINCT FROM $8
          OR caveat_payload IS DISTINCT FROM $9::jsonb)
   ```

   `IS DISTINCT FROM` is NULL-safe (so uncaveated-vs-caveated compares as different), and
   `jsonb` equality is structural (key order and whitespace insensitive), so re-encoding the
   same payload does not count as a change. An identical live row matches nothing here and is
   left untouched — that is what keeps identical rewrites idempotent *and* keeps their
   original `created_xid` (history is not churned).
2. **Insert**: run `insertTupleStatement` with its result decoder changed from
   `Decoders.noResult` to `Decoders.rowsAffected` (SQL unchanged — `ON CONFLICT DO NOTHING`
   is now correct because the only possible conflict after step 1 is an identical live row).
   1 row affected means inserted; 0 means the identical row already existed (idempotent
   no-op).
3. **Verify-and-retry (cross-transaction races)**: if step 2 affected 0 rows *and* step 1
   also affected 0 rows, the no-op is legitimate only if an identical live row exists. It
   almost always does — but a concurrent transaction that committed a *different* caveat for
   the same identity between our statements would also produce (0, 0)-then-conflict, silently
   dropping our write (the very bug this plan fixes, in racing form). Guard it: when step 2
   returns 0, run steps 1–2 once more (each statement in a transaction takes a fresh
   READ COMMITTED snapshot, so the retry sees the racer's committed row and retires it). If
   the second insert still affects 0 rows and the second touch-delete also affected 0 rows,
   the row is now identical — done. Bound the loop at 2 iterations; hitting the bound is
   unreachable in practice and would indicate livelock-level contention, so let a subsequent
   plan revisit if it ever surfaces. Two same-key writers with *different* caveats where
   neither sees a pre-existing live row can still race the insert itself; the new unique index
   makes the loser fail with a unique-violation, surfacing as `StoreError` (fail loud, not
   silent) — docs/plans/46's preconditions are the typed tool for callers who need to
   arbitrate such races.

Implement this as a helper `touchTupleSteps :: Text -> Tuple -> Session ()` (taking the
anchor xid) called from `writeTuplesSession` via `traverse_`, replacing the current bare
`insertTupleStatement` loop. `deleteTuplesSession` keeps its shape but `deleteTupleStatement`
loses the `AND coalesce(caveat_name, '') = coalesce($8, '')` predicate and
`TupleDeleteParams` loses `caveatName` (adjust `tupleDeleteParams` and the encoder — it drops
from eight parameters to seven).

A same-key tuple appearing twice in one `writeTuples` call (e.g. `[t{caveat=A}, t{caveat=B}]`)
resolves last-wins: the second tuple's touch-delete stamps the first's row with the shared
write xid (`deleted_xid = created_xid`, visible at no revision). Assert this in the
integration scenario so the behavior is pinned, and note it in the Haddock on
`writeTuplesSession`.

`en-core/src/En/Effect/CachedTupleStore.hs` needs no change: it forwards writes via
`passthrough`, and cached read pages are keyed by resolved revision, which any write advances.

Acceptance: `cabal build all` succeeds; the Milestone 3 integration scenarios (written
together with this milestone) pass.


### Milestone 3 — In-memory store parity and the proving scenarios

Scope: the conformance store mirrors touch semantics, and the integration suite proves the
review's two scenarios plus the migration's dedupe rule. At the end,
`cabal test en-postgres-integration-tests` and `cabal test all` pass with the new assertions.

In `en-core/src/En/Conformance/Kikan.hs`, change `runTupleStoreInMemory` from
`interpret_` over a fixed list to `reinterpret` (from `Effectful.Dispatch.Dynamic`) into
`Effectful.State.Static.Local.evalState tuples`, so the handler reads the current tuple list
with `get` and updates it with `modify`. Semantics, as pure helpers next to the interpreter
(exported for direct unit testing from the `en-core-conformance` suite):

```haskell
-- | The touch identity of a tuple: everything except the caveat.
tupleKey :: Tuple -> (ObjectRef, RelationName, Subject)

-- | Apply one write with touch semantics: drop any tuple sharing the key
-- (whatever its caveat), then append the new tuple. Identical rewrites are
-- no-ops that preserve position.
touchTuple :: Tuple -> [Tuple] -> [Tuple]

-- | Apply a delete by key: remove any tuple sharing the key, ignoring the
-- request's caveat (mirrors the PostgreSQL delete re-keying).
deleteTupleByKey :: Tuple -> [Tuple] -> [Tuple]
```

`WriteTuples tuples` folds `touchTuple`; `DeleteTuples tuples` folds `deleteTupleByKey`; both
keep returning their existing constant tokens (`in-memory-write` / `in-memory-delete`) — the
in-memory store has no revisions, so reads always see the current state, which is exactly the
"reads at the write token" behavior the conformance suites need. The signature
`runTupleStoreInMemory :: [Tuple] -> Eff (TupleStore : es) a -> Eff es a` is unchanged and the
interpreter stays pure (`Effectful.State.Static.Local` works under `runPureEff`, which
`en-core/conformance/Main.hs` requires). Existing callers (`en-core/test/Main.hs`,
`en-core/bench/Main.hs`, `en-servant/test/Main.hs`, `en-example`) compile unchanged and behave
identically for read-only flows.

Integration scenarios, added to `runTupleStoreScenario` (or a sibling function called from
`main`) in `en-postgres/integration-test/Main.hs`, using the existing `runPgOrFail` /
`assertEqual` helpers and a fresh object id per scenario to avoid cross-talk:

1. **Payload update takes effect** (review scenario 1): write tuple T with caveat
   `within_autonomy` payload `until = 2026-07-01`; capture token1; write T again with payload
   `until = 2026-12-31`; capture token2. Read `readStartingWithUser` at token2's revision:
   exactly 1 row, payload shows `2026-12-31`. Read at token1's revision: exactly 1 row,
   payload shows `2026-07-01` (old token still sees the old grant — soft delete preserved
   history). On pre-plan code the token2 read shows `2026-07-01` (the silent drop), so this
   scenario fails before and passes after.
2. **Caveat tightening replaces, not duplicates** (review scenario 2): write T uncaveated;
   write T with caveat `within_autonomy`. Read at the second token: exactly 1 row and its
   `caveat` is `Just …` — the unconditional grant is gone. On pre-plan code this read returns
   2 rows (fails before, passes after).
3. **Idempotent rewrite**: write T (caveated) twice with identical payload; read at the second
   token: exactly 1 row, and its `rowId` equals the `rowId` from a read at the first token
   (the row was not churned).
4. **Same key twice in one call**: `writeTuples [t{caveat=A}, t{caveat=B}]`; read at the
   token: exactly 1 row with caveat B.
5. **Migration dedupe rule**: in a separate scenario against a *second* schema reset, create
   the *old* index shape (with `coalesce(caveat_name,'')`), insert three live rows for one
   identity with distinct caveat names and ascending `created_xid` values via raw SQL, run the
   dedupe-and-reindex SQL (inline in the test, with a comment naming the migration file it
   must stay in sync with — the same convention `schemaSql` already uses), and assert exactly
   one live row remains and it is the one with the highest `created_xid`.

Also update the prose in `docs/spec/0001-en-overview.md` §7: replace "Upsert inserts a new
row; delete stamps `deleted_xid`" with wording that a write conflicting with a differing live
grant soft-deletes it and inserts the replacement in the same transaction (touch), identical
rewrites are no-ops, and uniqueness is keyed on object/relation/subject. Grep
`docs/user/queries-and-writes.md` for write-semantics wording and align it if it describes the
old behavior.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/en`.

1. Bring up the dev PostgreSQL (needed for `just run-migrations` and the final smoke test;
   the integration suite itself starts its own throwaway PostgreSQL via `ephemeral-pg` and
   only needs PostgreSQL binaries on `PATH`, which the dev shell provides):

   ```bash
   just process-up
   ```

2. Create and fill the migration, wire the Justfile guard, mirror `schemaSql`:

   ```bash
   just make-migration touch-semantics-live-unique
   just run-migrations
   ```

   Expected transcript (second run):

   ```text
   base migration already applied
   historical-read indexes already applied
   touch-semantics unique index already applied
   ```

3. Implement Milestone 2 in `en-postgres/src/En/Postgres/TupleStore.hs`, then Milestone 3 in
   `en-core/src/En/Conformance/Kikan.hs` and `en-postgres/integration-test/Main.hs`. Build and
   test:

   ```bash
   cabal build all
   cabal test en-postgres-integration-tests
   cabal test all
   ```

   Expected: every suite reports `1 of 1 test suites (1 of 1 test cases) passed` (the
   integration suite fails fast with a labeled `assertEqual` diff on any regression — e.g.
   `caveat tightening leaves one live row\nexpected: 1\nactual: 2` is what the pre-fix code
   produces for scenario 2).

4. End-to-end smoke against the real server and dev database:

   ```bash
   just start-and-test
   ```

   Expected final line: `server smoke test passed: AllowedWire`.

5. Commit per milestone with conventional-commit messages carrying the plan trailer, e.g.:

   ```text
   feat(en-migrations): re-key live-tuple uniqueness on object/relation/subject

   ExecPlan: docs/plans/45-adopt-touch-semantics-for-tuple-writes.md
   ```


## Validation and Acceptance

Acceptance is behavioral, not structural:

- With only Milestone 3's scenarios added (code fix reverted), `cabal test
  en-postgres-integration-tests` FAILS on scenario 1 (payload read at token2 shows the old
  `until`) and scenario 2 (2 live rows). With the fix applied, the full suite PASSES. Capture
  the failing-then-passing transcript in Surprises & Discoveries.
- `psql "$PG_CONNECTION_STRING" -tAc "SELECT indexdef FROM pg_indexes WHERE indexname =
  'relation_tuple_live_unique'"` shows no `caveat_name`.
- `cabal test all` passes — proving the in-memory store change did not disturb the
  conformance, en-core, or en-servant suites.
- `just start-and-test` passes — proving the served write path still round-trips
  write→token→check.
- `docs/spec/0001-en-overview.md` §7 describes touch semantics (grep for "touch").


## Idempotence and Recovery

Every step is re-runnable. The migration is applied at most once per database: codd tracks it
by filename, and the Justfile guard checks the index definition. The migration itself is safe
against a crash mid-transaction because codd (and the guarded `psql -v ON_ERROR_STOP=1`
fallback) run it in one transaction — either the dedupe and the new index both exist or
neither does. The dedupe UPDATE is destructive only in the soft-delete sense: losing rows get
`deleted_xid` stamped and remain readable at pre-migration revisions, so no data is lost; if
the chosen winner ever proves wrong for a specific deployment, the losers can be un-stamped by
hand (`UPDATE relation_tuple SET deleted_xid = NULL WHERE id = …`) before the reaper's GC
window passes. `cabal build`/`cabal test` are idempotent. Commit per milestone so a bad
milestone is a single `git revert`.


## Interfaces and Dependencies

- `hasql` (`Hasql.Statement`, `Hasql.Session`, `Hasql.Decoders.rowsAffected`) — already the
  storage client; the new statements follow the `Statement.preparable` pattern used throughout
  `en-postgres/src/En/Postgres/TupleStore.hs`.
- `effectful` / `effectful-core` (`Effectful.Dispatch.Dynamic.reinterpret`,
  `Effectful.State.Static.Local`) — already dependencies of `en-core`; used to make the
  conformance store stateful while staying pure.
- `ephemeral-pg` — already the integration-test harness; scenario 5 uses a second schema reset
  on the same throwaway database.

Signatures that must exist at the end (full module paths):

- `En.Postgres.TupleStore.touchReplaceStatement :: Statement TupleInsertParams Int64`
  (internal), `En.Postgres.TupleStore.insertTupleStatement :: Statement TupleInsertParams
  Int64` (result decoder changed), `En.Postgres.TupleStore.deleteTupleStatement :: Statement
  TupleDeleteParams ()` with `TupleDeleteParams` lacking `caveatName`.
- `En.Effect.TupleStore.TupleStore` — UNCHANGED constructors (verify with `git diff
  en-core/src/En/Effect/TupleStore.hs` showing only comment/Haddock edits, if any).
- `En.Conformance.Kikan.runTupleStoreInMemory :: [Tuple] -> Eff (TupleStore : es) a -> Eff es
  a` (unchanged signature, stateful semantics), plus exported pure helpers
  `En.Conformance.Kikan.tupleKey`, `En.Conformance.Kikan.touchTuple`,
  `En.Conformance.Kikan.deleteTupleByKey`.

Cross-plan boundary (restated): this plan owns `relation_tuple_live_unique`; it must not add
preconditions or new effect constructors (docs/plans/46), must not modify
`writeVisibleSnapshot`/`tokenFromAnchor` (docs/plans/47), must not batch statements with
`unnest` (docs/plans/48), and must not touch `relation_tuple_object_live_idx`,
`relation_tuple_subject_live_idx`, or `relation_tuple_created_xid_idx` (docs/plans/49, in
coordination with docs/plans/53-add-a-watch-changelog-api.md).
