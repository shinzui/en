---
id: 49
slug: trim-dead-indexes-and-resolve-consistency-lazily
title: "Trim dead indexes and resolve consistency lazily"
kind: exec-plan
created_at: 2026-07-07T15:25:00Z
master_plan: "docs/masterplans/8-correct-write-path-and-storage-semantics.md"
---

# Trim dead indexes and resolve consistency lazily

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

en is a relationship-based authorization toolkit backed by PostgreSQL. Two efficiency
defects tax every write and every read (findings C9 and C3 of
`docs/reviews/2026-07-07-architecture-performance-review.md`). First, the `relation_tuple`
table carries indexes that no query can use: the read path filters visibility with
`pg_visible_in_snapshot(...)`, never with a bare `deleted_xid IS NULL`, so the two partial
"live" indexes are pure write amplification — every insert and soft-delete maintains them
for nothing. Second, resolving a request's *consistency* (which snapshot to read at) always
fetches three things — the optimized revision, the head revision, and the
garbage-collection horizon — even though no single consistency mode needs all three; with
the optimized-revision cache disabled (the default) that is three sequential database round
trips per read on what is today a single shared connection.

After this plan, the index set matches the query set (verified with `EXPLAIN (ANALYZE)`
against a seeded database before anything is dropped, and with the `created_xid` index
explicitly coordinated with the future watch/changelog feed rather than dropped blind), and
consistency resolution fetches only what the requested mode needs — one fetch for
`MinimizeLatency`, `FullyConsistent`, and `AtExactSnapshot`, two for `AtLeastAsFresh` — with
the horizon cached behind the same TTL mechanism as the optimized revision. You can see it
working in a new integration assertion that counts store operations per mode, and in
`EXPLAIN` transcripts showing every production statement served by the surviving indexes.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Enumerate every `Statement` in `en-postgres/src/En/Postgres/TupleStore.hs` as of the working tree (sibling plans may have reshaped the write path) and prepare the EXPLAIN harness for each.
- [ ] Seed the dev database and capture `EXPLAIN (ANALYZE, BUFFERS)` for every statement; record which indexes each uses.
- [ ] Confirm `relation_tuple_object_live_idx` and `relation_tuple_subject_live_idx` appear in no plan; check `pg_stat_user_indexes.idx_scan` stays zero across a driven workload.
- [ ] Check docs/plans/53-add-a-watch-changelog-api.md status; decide keep-vs-drop for `relation_tuple_created_xid_idx`; record the outcome in BOTH Decision Logs.
- [ ] Create the drop migration with `just make-migration drop-dead-live-indexes`; add its Justfile guard; mirror the removal in the integration test's `schemaSql`.
- [ ] Refactor `ResolveConsistency` in `en-postgres/src/En/Postgres/Revision.hs` to fetch per mode; generalize the TTL cache and put the horizon behind it.
- [ ] Add the operation-counting integration assertion (per-mode fetch counts) and record before/after counts.
- [ ] Re-run the EXPLAIN sweep post-drop to confirm no plan regressed to a sequential scan.
- [ ] Run `cabal build all`, `cabal test all`, `just start-and-test`; record transcripts.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Verification precedes removal — no index is dropped until `EXPLAIN (ANALYZE)`
  over every statement in `en-postgres/src/En/Postgres/TupleStore.hs`, against a seeded
  database large enough that the planner prefers indexes (≥ 200k rows), shows the index
  unused, corroborated by a zero `idx_scan` delta in `pg_stat_user_indexes` across a driven
  workload.
  Rationale: The review's C9 reasons from the SQL text; the planner is the authority.
  Notably `deleteTupleStatement` (and the docs/plans/45 touch statements) *do* filter
  `deleted_xid IS NULL` with the full identity key — the expectation is that
  `relation_tuple_live_unique` serves them, but that is exactly the kind of assumption the
  EXPLAIN sweep exists to confirm before anything is irreversible.
  Date: 2026-07-07
- Decision: `relation_tuple_created_xid_idx` is handled by coordination, not by default
  dropping: read docs/plans/53-add-a-watch-changelog-api.md at implementation time; if it
  has not landed or still plans a changelog feed ordered/filtered by `created_xid` (the
  natural design given the xid8 soft-delete schema), KEEP the index and document the
  reservation; drop it only if that plan has affirmatively decided against needing it. The
  outcome is recorded in both this Decision Log and docs/plans/53's.
  Rationale: The master plan (`docs/masterplans/8-correct-write-path-and-storage-semantics.md`,
  Decision Log and Integration Points) mandates this coordination: dropping and later
  re-adding an index on a large table is avoidable churn. At authoring time docs/plans/53 is
  an unfilled skeleton, so the expected outcome is keep-and-document.
  Date: 2026-07-07
- Decision: The lazy resolution is implemented by passing monadic getters into
  `resolveConsistencyRequest` (fields of a small `ResolveEnv` record) rather than by moving
  the case analysis into the interpreter.
  Rationale: `resolveConsistencyRequest` is pure today and unit-testable; making its inputs
  lazy-by-construction (each getter runs only when the mode's branch demands it) keeps the
  mode→requirement mapping in one auditable function instead of duplicating the `case` in
  `runConsistencyStorePostgres`, and the in-memory conformance store is unaffected.
  Date: 2026-07-07
- Decision: The GC horizon is cached behind the same TTL mechanism as the optimized
  revision — the existing cache in `en-postgres/src/En/Postgres/Revision.hs` is generalized
  from `Revision`-valued to polymorphic (`TtlCache a`), instantiated once for the optimized
  revision (unchanged behavior) and once for the horizon, both driven by the existing
  `OptimizedRevisionConfig` TTL (`EN_OPTIMIZED_REVISION_CACHE_TTL_MS`).
  Rationale: The horizon moves only as fast as the GC window (hours); re-reading it per
  request is waste in exactly the way the optimized revision was before
  docs/plans/9-implement-optimized-revision-caching.md. Reusing the one battle-tested
  TTL cell avoids a second cache implementation and a second knob; a stale-by-TTL horizon is
  strictly conservative for token validation when TTL ≪ GC window (it can only *under*-state
  how much history is retained, never accept a too-old token), which the plan documents at
  the cache site.
  Date: 2026-07-07
- Decision: A token-less `MinimizeLatency` or `FullyConsistent` request performs no horizon
  fetch and no token validation at all.
  Rationale: The horizon exists solely to reject tokens older than retained history; with no
  token there is nothing to validate. This is the "token-less requests don't need the GC
  horizon" half of finding C3.
  Date: 2026-07-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Record here: the EXPLAIN index-usage table,
the created_xid keep/drop outcome, and the per-mode fetch counts before/after.

(To be filled during and after implementation.)


## Context and Orientation

This plan is a child of `docs/masterplans/8-correct-write-path-and-storage-semantics.md` and
fixes findings C9 and C3 of `docs/reviews/2026-07-07-architecture-performance-review.md`. It
has no hard dependencies, but because docs/plans/45 also adds a migration and reshapes the
write statements, land migrations one at a time (master plan sequencing note) and always
verify against the statements as they exist in the working tree.

en is a Haskell project at `/Users/shinzui/Keikaku/bokuno/en`. Orientation:

- Schema: `en-migrations/db/migrations/20260623044157_create-relation-tuples.sql` defines
  `relation_tuple` and its indexes;
  `20260623160000_historical-read-indexes.sql` added two non-partial "hist" indexes. The
  full current index set on `relation_tuple`:
  - `relation_tuple_pkey` (id) — keyset pagination and the primary key.
  - `relation_tuple_live_unique` (identity key, partial `WHERE deleted_xid IS NULL`) —
    uniqueness; also the expected server of the delete/touch lookups. Owned by
    docs/plans/45; not touched here.
  - `relation_tuple_object_live_idx` (object key + id, partial `WHERE deleted_xid IS NULL`)
    — **suspected dead**: the read statements' visibility predicate is
    `pg_visible_in_snapshot(created_xid, $1) AND (deleted_xid IS NULL OR NOT
    pg_visible_in_snapshot(deleted_xid, $1))`, which does *not* imply
    `deleted_xid IS NULL`, so the planner cannot use a partial index predicated on it; the
    non-partial `relation_tuple_object_hist_idx` serves those reads.
  - `relation_tuple_subject_live_idx` — same story for the subject-side reads;
    `relation_tuple_subject_hist_idx` is the non-partial twin.
  - `relation_tuple_object_hist_idx`, `relation_tuple_subject_hist_idx` — the live read
    servers (added by
    docs/plans/14-harden-consistency-faithful-snapshot-visibility-gc-window-and-token-reconciliation.md);
    stay.
  - `relation_tuple_created_xid_idx` (created_xid) — used by no current statement
    (`pg_visible_in_snapshot(created_xid, …)` is a function call, not a sargable predicate);
    the one plausible future consumer is a watch/changelog feed ordered by `created_xid`
    (docs/plans/53-add-a-watch-changelog-api.md, master plan 9).
  - `relation_tuple_deleted_xid_idx` (deleted_xid, partial `WHERE deleted_xid IS NOT NULL`)
    — serves the reaper (`reapDeletedTuplesStatement`); stays.

  Every index a row's insert or update touches is write cost (*write amplification*): dead
  indexes tax every write and bloat the disk for zero read benefit.
- Statements: all SQL lives in `en-postgres/src/En/Postgres/TupleStore.hs` — at authoring
  time: `anchorTransactionStatement`, `currentSnapshotStatement`,
  `oldestRetainedXidStatement` (these three touch `en_transaction`, not `relation_tuple`),
  `insertTupleStatement`, `deleteTupleStatement`, `readObjectRelationStatement`,
  `readStartingWithUserStatement`, `reapDeletedTuplesStatement`, plus whatever
  docs/plans/45/46/48 have added (touch, precondition, batch, export statements). The sweep
  must cover the set *as found in the working tree*.
- Consistency resolution: `en-postgres/src/En/Postgres/Revision.hs`. The four consistency
  modes (`en-core/src/En/Revision.hs`): `MinimizeLatency` (read at the *optimized* revision
  — a possibly-cached recent snapshot), `FullyConsistent` (read at *head* —
  `pg_current_snapshot()` now), `AtExactSnapshot token` (read exactly at the token's
  revision, after validating the token), `AtLeastAsFresh token` (read at
  max(optimized, token)). Token validation (`validateTokenMetadata`) needs the current time
  and the *GC horizon* — the oldest transaction id still retained
  (`oldestRetainedXidStatement` over `en_transaction`) — to reject tokens whose history may
  have been reaped. The defect (C3): `ResolveConsistency` (line 315,
  `runConsistencyStorePostgres`) unconditionally performs
  `TupleStore.optimizedRevision`, `TupleStore.headRevision`, and
  `TupleStore.oldestRetainedXid` before calling the pure `resolveConsistencyRequest` —
  three store operations (three sequential round trips when the optimized-revision cache is
  disabled, its default per `en-server/app/Main.hs`'s
  `EN_OPTIMIZED_REVISION_CACHE_TTL_MS` handling) for every read, regardless of mode. The
  existing TTL cache machinery to generalize is `OptimizedRevisionCache` /
  `OptimizedRevisionConfig` / `newOptimizedRevisionCache` / `lookupOptimizedRevisionCache` /
  `storeOptimizedRevisionCache` in the same file, wired in
  `en-postgres/src/En/Postgres/TupleStore.hs` (`cachedOptimizedRevision`) and constructed in
  `en-server/app/Main.hs`.
- Tests and databases: `en-postgres/integration-test/Main.hs`
  (`en-postgres-integration-tests`) starts a throwaway PostgreSQL via `ephemeral-pg` (no
  external service; PostgreSQL binaries on `PATH` from the dev shell) and creates its schema
  from an inline `schemaSql` that mirrors the migration files — index changes must be
  mirrored there. The seeded-EXPLAIN work uses the *dev* database: `just process-up` starts
  it (process-compose, readiness-looped), `just run-migrations` applies the migration files,
  and `$PG_CONNECTION_STRING` connects `psql` to it. The `run-migrations` recipe in
  `Justfile` guards each migration file individually — a new migration needs a new guard
  stanza there.

Integration points restated from the master plan
(`docs/masterplans/8-correct-write-path-and-storage-semantics.md`):

- **This plan (EP-49) owns removing `relation_tuple_object_live_idx` and
  `relation_tuple_subject_live_idx`, and the keep-or-drop call on
  `relation_tuple_created_xid_idx` in coordination with
  docs/plans/53-add-a-watch-changelog-api.md** (record in both Decision Logs).
- **The uniqueness index `relation_tuple_live_unique` is owned by docs/plans/45** — never
  touched here, though the EXPLAIN sweep confirms it serves the delete/touch lookups.
- **The write signature is owned by docs/plans/46** and **the write-token snapshot
  definition by docs/plans/47** — this plan changes neither; its consistency-resolution
  refactor is read-side only and must produce byte-identical resolved revisions per mode,
  just with fewer fetches.


## Plan of Work

Two independent parts: the index audit-and-drop (C9) and the lazy resolution (C3). Do Part 1
first only because its EXPLAIN harness doubles as the regression check after Part 2's
refactor; they share no code.


### Milestone 1 — EXPLAIN audit of every statement against a seeded database

Scope: evidence, no changes. At the end, a table in Outcomes & Retrospective lists every
statement and the indexes its plan uses, and the two live indexes are confirmed unused.

Bring up and seed the dev database (~200k live rows, 50k soft-deleted, skewed across a few
thousand objects so index scans win over sequential scans):

```bash
cd /Users/shinzui/Keikaku/bokuno/en
just process-up
just run-migrations
psql "$PG_CONNECTION_STRING" <<'SQL'
INSERT INTO en_transaction (xid, schema_hash) VALUES (pg_current_xact_id(), 'seed')
ON CONFLICT (xid) DO NOTHING;
INSERT INTO relation_tuple
  (object_type, object_id, relation, subject_type, subject_id, subject_relation,
   caveat_name, caveat_payload, created_xid, deleted_xid)
SELECT 'space', 'obj-' || (g % 4000), 'viewer', 'user', 'user-' || (g % 20000),
       NULL, NULL, NULL, pg_current_xact_id(),
       CASE WHEN g % 5 = 0 THEN pg_current_xact_id() END
FROM generate_series(1, 250000) AS g
ON CONFLICT DO NOTHING;
ANALYZE relation_tuple;
SQL
```

(The `deleted_xid = created_xid` rows stand in for soft-deleted history; `ON CONFLICT DO
NOTHING` keeps the seed idempotent under the live-unique index.) Then, for each statement in
`en-postgres/src/En/Postgres/TupleStore.hs` *as found in the working tree*, run it through
`PREPARE`/`EXPLAIN (ANALYZE, BUFFERS) EXECUTE` with representative parameters. Example for
the object read (adapt the parameter list to each statement; take the snapshot text from
`SELECT pg_current_snapshot()::text`):

```sql
PREPARE read_obj (text, text, text, text, bigint, bigint) AS
SELECT id, object_type, object_id, relation, subject_type, subject_id, subject_relation,
       caveat_name, caveat_payload, created_xid::text, deleted_xid::text
FROM relation_tuple
WHERE object_type = $2 AND object_id = $3 AND relation = $4
  AND id > $6
  AND pg_visible_in_snapshot(created_xid, $1::pg_snapshot)
  AND (deleted_xid IS NULL OR NOT pg_visible_in_snapshot(deleted_xid, $1::pg_snapshot))
ORDER BY id ASC
LIMIT $5;
EXPLAIN (ANALYZE, BUFFERS) EXECUTE read_obj('<snapshot>', 'space', 'obj-42', 'viewer', 11, 0);
```

Expected: `Index Scan using relation_tuple_object_hist_idx …` (never
`…_object_live_idx`). Repeat for the subject read (expect `…_subject_hist_idx`), the
delete/touch statements (expect `relation_tuple_live_unique`), the reaper (expect
`relation_tuple_deleted_xid_idx`), and any batch/export statements present (export should
show the primary key). Corroborate with the usage counters: snapshot
`SELECT indexrelname, idx_scan FROM pg_stat_user_indexes WHERE relname = 'relation_tuple'`,
drive a real workload (`just start-and-test`, plus the integration-style writes above),
re-snapshot, and confirm the two live indexes' `idx_scan` deltas are zero. Also re-examine
the review's side-note on `readStartingWithUserStatement`'s global `ORDER BY id LIMIT`
across unnested subject keys at large fan-in — capture the plan at 1,000 subject keys; if it
sorts all matches before the limit, record the observation in Surprises & Discoveries for a
future plan (out of scope to fix here).

If — against expectation — a plan *does* use a supposedly dead index, stop: record the plan
in Surprises & Discoveries, keep that index, and shrink the drop migration accordingly. The
EXPLAIN table is the gate for Milestone 2.


### Milestone 2 — Coordination on `created_xid`, then the drop migration

Scope: the keep/drop decision recorded in two plans, and a migration dropping what Milestone
1 condemned. At the end, the dev database and the test schema carry the trimmed index set
and every plan still uses the surviving indexes.

First the coordination step the master plan mandates: open
`docs/plans/53-add-a-watch-changelog-api.md` and read its Progress and Decision Log. Cases:

- Not started / still planning a `created_xid`-ordered changelog (the expected case): KEEP
  `relation_tuple_created_xid_idx`. Add a Decision Log entry *here* ("kept, reserved for the
  watch feed") and a matching entry in docs/plans/53's Decision Log ("EP-49 kept
  relation_tuple_created_xid_idx reserved for this plan; if this plan's design ends up not
  needing it, it must arrange the drop"). Also add a `-- reserved for the watch/changelog
  feed (docs/plans/53); see docs/plans/49` comment next to the index in a migration comment
  or the schema documentation so the reservation is discoverable from the SQL side.
- docs/plans/53 has landed and its implementation uses the index: KEEP, record both entries.
- docs/plans/53 has affirmatively decided it does not need it: include it in the drop below,
  record both entries.

Then create the migration:

```bash
cd /Users/shinzui/Keikaku/bokuno/en
just make-migration drop-dead-live-indexes
```

with content (adjusted by Milestone 1's findings and the coordination outcome):

```sql
-- docs/plans/49: verified dead by EXPLAIN sweep on 2026-XX-XX (see plan's
-- Outcomes): the visibility predicate pg_visible_in_snapshot(...) cannot use
-- partial indexes predicated on deleted_xid IS NULL; the non-partial *_hist_idx
-- twins serve these reads. relation_tuple_created_xid_idx is retained,
-- reserved for the watch feed (docs/plans/53) -- or dropped here too, per the
-- recorded coordination outcome.
DROP INDEX IF EXISTS relation_tuple_object_live_idx;
DROP INDEX IF EXISTS relation_tuple_subject_live_idx;
```

Wire the local apply path and the test schema:

- `Justfile` `run-migrations`: add a guard stanza mirroring the existing ones —

  ```just
    @if [ "$(psql "$PG_CONNECTION_STRING" -tAc "SELECT to_regclass('public.relation_tuple_object_live_idx') IS NOT NULL")" = "t" ]; then \
        psql "$PG_CONNECTION_STRING" -v ON_ERROR_STOP=1 -f en-migrations/db/migrations/<timestamp>_drop-dead-live-indexes.sql; \
      else \
        echo "dead live indexes already dropped"; \
      fi
  ```

- `en-postgres/integration-test/Main.hs`: delete the two `CREATE INDEX …_live_idx`
  statements from the inline `schemaSql` (and, if the coordination outcome was drop, the
  `created_xid` one) so the test schema matches the migrated shape.

Re-run the Milestone 1 EXPLAIN sweep post-drop: every statement must show the same index it
showed before (nothing regresses to `Seq Scan`), which is the observable proof the dropped
indexes were dead. Re-run `just run-migrations` a second time and confirm the "already
dropped" branch prints (idempotence).


### Milestone 3 — Lazy, mode-aware consistency resolution with a cached horizon

Scope: `ResolveConsistency` fetches only what the mode needs; the horizon rides the TTL
cache. At the end, an integration assertion counts store operations per mode and matches the
target table below.

Edits in `en-postgres/src/En/Postgres/Revision.hs`:

1. Generalize the cache: rename the internals to a polymorphic
   `TtlCache a` (`newTtlCache :: OptimizedRevisionConfig -> IO UTCTime -> IO (TtlCache a)`,
   `lookupTtlCache`, `storeTtlCache`) and keep the existing exported names as `Revision`-
   specialized aliases so `en-postgres/src/En/Postgres/TupleStore.hs` and
   `en-server/app/Main.hs` keep compiling unchanged (`OptimizedRevisionCache = TtlCache
   Revision`). Add a `horizonCache :: TtlCache Word64` alongside — same
   `OptimizedRevisionConfig`, per the Decision Log. Document at the cache site why a
   TTL-stale horizon is safe: it lags reality by at most the TTL, and a lagging horizon only
   *rejects* strictly more tokens near the GC edge, never accepts a reaped one, provided
   TTL ≪ GC window (both defaults satisfy this by orders of magnitude).
2. Restructure `resolveConsistencyRequest` to take lazy getters instead of values:

   ```haskell
   data ResolveEnv m = ResolveEnv
       { getOptimized :: m Revision
       , getHead :: m Revision
       , getHorizon :: m Word64
       , getNow :: m UTCTime
       }

   resolveConsistencyRequest ::
       (Monad m) =>
       ResolveEnv m ->
       (ConsistencyToken -> Either EnError TokenMetadata) ->
       (UTCTime -> Word64 -> TokenMetadata -> Either EnError ()) ->
       Consistency ->
       m (Either EnError ResolvedConsistency)
   ```

   with the mode→requirement mapping: `MinimizeLatency` runs only `getOptimized`;
   `FullyConsistent` only `getHead`; `AtExactSnapshot` decodes the token, then runs
   `getNow` and `getHorizon` for validation, and never touches optimized or head;
   `AtLeastAsFresh` decodes, validates (`getNow`/`getHorizon`), then runs `getOptimized`
   for the comparison — never `getHead`. The revision selected per mode is unchanged from
   today; only the fetching moved. Unit-test the mapping in
   `en-postgres/test/Main.hs` with a writer-monad `ResolveEnv` that records which getters
   ran (pure, fast, no database).
3. `runConsistencyStorePostgres` builds the `ResolveEnv` from `TupleStore.optimizedRevision`
   / `TupleStore.headRevision` / a horizon getter that consults `horizonCache` before
   `TupleStore.oldestRetainedXid` / `liftIO getCurrentTime`, and applies the same
   cached-horizon getter in its `ValidateToken` case. The constructor grows an argument for
   the caches (or a small environment record); update the two construction sites
   (`en-server/app/Main.hs` and `en-postgres/integration-test/Main.hs`) — keep a
   cache-disabled construction path so tests that assert against a moving horizon (the
   existing stale-token scenario) stay deterministic.

The counting assertion, in `en-postgres/integration-test/Main.hs`: wrap the store with a
counting *interposer* — `Effectful.Dispatch.Dynamic.interpose` over `TupleStore` that
increments an `IORef (Map Text Int)` keyed by operation name for `HeadRevision`,
`OptimizedRevision`, and `OldestRetainedXid`, forwarding everything with `passthrough`
(mirror the shape of `en-core/src/En/Effect/CachedTupleStore.hs`). With the horizon cache
disabled (TTL 0) so counts are deterministic, run `resolveConsistency` once per mode against
a fresh counter and assert:

| Mode | Fetches before (today) | Fetches after |
|------|------------------------|---------------|
| `MinimizeLatency` | 3 (optimized+head+horizon) | 1 (optimized) |
| `FullyConsistent` | 3 | 1 (head) |
| `AtExactSnapshot token` | 3 | 1 (horizon) |
| `AtLeastAsFresh token` | 3 | 2 (horizon+optimized) |

The "before" column is the recorded baseline (assert it once against pre-refactor code if
convenient, or cite the unconditional three `TupleStore.*` calls at
`en-postgres/src/En/Postgres/Revision.hs:315-326`); the "after" column is the enforced
assertion. Because the interpreter maps each of these operations to one database session,
operation counts are round-trip counts.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/en`.

1. Milestone 1: `just process-up`, `just run-migrations`, seed and EXPLAIN as scripted in
   the Plan of Work. Expected fragment for the object read:

   ```text
   Limit  (cost=… rows=11 …) (actual …)
     ->  Index Scan using relation_tuple_object_hist_idx on relation_tuple …
   ```

   and a `pg_stat_user_indexes` delta table with zeros for the two `_live_idx` rows. Paste
   the per-statement index table into Outcomes & Retrospective.
2. Milestone 2: perform the docs/plans/53 coordination (edit BOTH Decision Logs), then
   `just make-migration drop-dead-live-indexes`, fill it, add the Justfile guard, mirror
   `schemaSql`, and:

   ```bash
   just run-migrations
   just run-migrations   # second run prints: dead live indexes already dropped
   cabal test en-postgres-integration-tests
   ```

   Re-run the EXPLAIN sweep; expected: identical index choices as Milestone 1, no `Seq Scan`
   regressions.
3. Milestone 3: implement the refactor, then:

   ```bash
   cabal build all
   cabal test en-postgres-revision-tests
   cabal test en-postgres-integration-tests
   ```

   Expected: the getter-recording unit test and the per-mode counting assertion pass, e.g.
   the labeled assertion `MinimizeLatency resolves with a single store fetch` comparing
   `fromList [("OptimizedRevision",1)]`.
4. Full sweep and smoke:

   ```bash
   cabal test all
   just start-and-test
   ```

   Expected final line: `server smoke test passed: AllowedWire`.
5. Commit per milestone with the plan trailer, e.g.:

   ```text
   perf(en-postgres): resolve consistency lazily per mode with cached horizon

   ExecPlan: docs/plans/49-trim-dead-indexes-and-resolve-consistency-lazily.md
   ```


## Validation and Acceptance

- The EXPLAIN sweep (before AND after the drop) shows every production statement served by
  the surviving indexes with no sequential-scan regressions, and the
  `pg_stat_user_indexes` deltas show the dropped indexes were never scanned — the recorded
  transcripts in Outcomes & Retrospective are the evidence that removal was safe, not just
  asserted.
- `\di relation_tuple*` in `psql "$PG_CONNECTION_STRING"` after `just run-migrations` no
  longer lists `relation_tuple_object_live_idx`/`relation_tuple_subject_live_idx`, and lists
  `relation_tuple_created_xid_idx` if-and-only-if the recorded coordination outcome was
  "keep"; both this plan's and docs/plans/53's Decision Logs carry the matching entries.
- The per-mode fetch-count assertion in `cabal test en-postgres-integration-tests` matches
  the "after" table (1/1/1/2), and each mode still resolves to the same revision as before
  (the suite's existing consistency scenarios — stale-token rejection, read-your-writes at
  a token — pass unchanged).
- `cabal test all` and `just start-and-test` pass.


## Idempotence and Recovery

The seed script is idempotent (`ON CONFLICT DO NOTHING`); the drop migration uses `DROP
INDEX IF EXISTS` and its Justfile guard makes re-runs no-ops. Recovery from a wrong drop is
cheap and safe: recreate the index concurrently
(`CREATE INDEX CONCURRENTLY relation_tuple_object_live_idx ON relation_tuple (object_type,
object_id, relation, id) WHERE deleted_xid IS NULL;`) — no data is lost by dropping an
index, only (potentially) plan quality, which is why the EXPLAIN gate comes first. The
resolution refactor is behavior-preserving by construction (same selected revisions) and
guarded by the existing consistency scenarios; revert is a single `git revert` of its
milestone commit. Keep dev-database experiments out of commits.


## Interfaces and Dependencies

- `psql` against the process-compose dev PostgreSQL (`just process-up`,
  `$PG_CONNECTION_STRING`) — seeding, `PREPARE`/`EXPLAIN`, `pg_stat_user_indexes`,
  `pg_indexes`.
- `effectful` (`Effectful.Dispatch.Dynamic.interpose`, `passthrough`) — the counting
  interposer in the integration test.
- `hasql`, `ephemeral-pg` — unchanged roles.

Signatures that must exist at the end (full module paths):

- `En.Postgres.Revision.TtlCache` (polymorphic), `newTtlCache`, `lookupTtlCache`,
  `storeTtlCache`, with `OptimizedRevisionCache` remaining as the `Revision` instantiation
  used by `En.Postgres.TupleStore.cachedOptimizedRevision` and `en-server/app/Main.hs`.
- `En.Postgres.Revision.ResolveEnv m` and `En.Postgres.Revision.resolveConsistencyRequest ::
  Monad m => ResolveEnv m -> (ConsistencyToken -> Either EnError TokenMetadata) -> (UTCTime
  -> Word64 -> TokenMetadata -> Either EnError ()) -> Consistency -> m (Either EnError
  ResolvedConsistency)`.
- `En.Postgres.Revision.runConsistencyStorePostgres` — same effect row, construction updated
  for the horizon cache.
- Migration `en-migrations/db/migrations/<timestamp>_drop-dead-live-indexes.sql`.

Cross-plan boundary (restated): `relation_tuple_live_unique` is docs/plans/45's (this plan
only observes it in EXPLAIN output); the write signature is docs/plans/46's and the token
snapshot definition docs/plans/47's (untouched — this plan is read-side); the
`relation_tuple_created_xid_idx` outcome is a two-plan decision recorded in both this
Decision Log and docs/plans/53-add-a-watch-changelog-api.md's, per the master plan's
Integration Points.
