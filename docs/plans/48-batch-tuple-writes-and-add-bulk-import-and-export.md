---
id: 48
slug: batch-tuple-writes-and-add-bulk-import-and-export
title: "Batch tuple writes and add bulk import and export"
kind: exec-plan
created_at: 2026-07-07T15:25:00Z
master_plan: "docs/masterplans/8-correct-write-path-and-storage-semantics.md"
---

# Batch tuple writes and add bulk import and export

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

en is a relationship-based authorization toolkit backed by PostgreSQL. Today a write of N
tuples costs N+3 network round trips to the database — `BEGIN`, an anchor statement, one
statement per tuple, `COMMIT` (finding C6 of
`docs/reviews/2026-07-07-architecture-performance-review.md`; after
docs/plans/45-adopt-touch-semantics-for-tuple-writes.md it is 2N+3, since touch semantics
run two statements per tuple). And there is no way in or out of en in bulk (gap E9): migrating
an existing permission system into en, or extracting the graph for a rebuild or another
datastore, means hand-writing a driver against the per-request API.

After this plan, writing N tuples costs a *constant* number of round trips (the tuple lists
travel as PostgreSQL arrays unpacked server-side with `unnest`, implementing exactly the touch
semantics of docs/plans/45), and the `en-server` binary gains two subcommands: `en-server
import` streams newline-delimited-JSON tuples from a file into the store in anchored batches
(each batch one transaction, one consistency token — the same token semantics as any write),
and `en-server export` streams every live tuple at one revision to stdout in the same format,
so `import` of an `export` reproduces the graph. You can see it working by importing 100,000
synthetic tuples on a laptop in seconds and reading back the count, and by counting statements
in the PostgreSQL log for a 100-tuple write: about 103 lines before, 6 after.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Verify the hard dependency on docs/plans/45 (touch statements and re-keyed unique index present) and check docs/plans/46's status to pick the write entry point (`ApplyTupleWrites` vs `WriteTuples`/`DeleteTuples`).
- [ ] Add `batchTouchReplaceStatement`, `batchInsertTupleStatement`, `batchDeleteTupleStatement`, and the batched verify statement to `en-postgres/src/En/Postgres/TupleStore.hs`; rewrite the write session over them.
- [ ] Prove batched-vs-sequential equivalence in `en-postgres/integration-test/Main.hs` (touch scenarios from docs/plans/45 rerun through the batched path, plus a duplicate-key-in-one-batch case).
- [ ] Add the `ReadAllTuples` effect operation to `en-core/src/En/Effect/TupleStore.hs`, implement it in the PostgreSQL and in-memory interpreters, and confirm the cached interposer passes it through.
- [ ] Add subcommand dispatch to `en-server/app/Main.hs` and implement `import` (NDJSON in, anchored batches, final token printed) and `export` (NDJSON out at a single revision).
- [ ] Round-trip test: export a seeded dev database, import into a fresh database, compare sorted NDJSON.
- [ ] Measure: statement-log counts for a 100-tuple write before/after; 100k-tuple import wall-clock and rate; record both in Outcomes & Retrospective.
- [ ] Update `docs/user/service-and-operations.md` with the two subcommands.
- [ ] Run `cabal build all`, `cabal test all`, `just start-and-test`; record transcripts.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Bulk import and export are `en-server` CLI subcommands (`en-server import`,
  `en-server export`), not admin HTTP endpoints.
  Rationale: The review's finding A1 says the HTTP API is currently unauthenticated; adding a
  bulk-write endpoint would widen that exposure, and master plan 9 owns new endpoint work.
  A CLI subcommand runs with database credentials the operator already holds, needs no new
  wire contract, and composes with shell tooling (`gzip`, `pv`, redirects). If an HTTP bulk
  surface is ever needed, master plan 9 can wrap these same sessions.
  Date: 2026-07-07
- Decision: The interchange format is newline-delimited JSON (NDJSON), one `TupleWire`
  object per line, reusing the wire codec from `en-servant/src/En/Servant/API.hs`.
  Rationale: `TupleWire` already has a stable JSON codec with tests and exactly captures a
  tuple including its caveat; NDJSON streams line-by-line with constant memory and is
  trivially inspectable/greppable. Inventing a second serialization would create a second
  compatibility surface. This adds an `en-servant` dependency to the `en-server` executable —
  which it already has.
  Date: 2026-07-07
- Decision: Import batches use large `unnest` multi-row statements inside one anchored
  transaction per batch (default 5000 tuples, `--batch-size` flag), not `COPY`.
  Rationale: `COPY` bypasses the touch semantics (no `ON CONFLICT`, no differing-row
  soft-delete) and the anchor/token discipline; reproducing touch around a `COPY` staging
  table would be a second implementation of the write semantics. The `unnest` batch *is* the
  production write path, so import exercises and inherits its correctness, and one anchor
  per batch preserves token semantics exactly (each batch is an ordinary write). If profiling
  ever shows `unnest` bind-parameter overhead dominating, a `COPY`-to-staging prototype can
  be a follow-up.
  Date: 2026-07-07
- Decision: Export reads at a single revision captured once at startup (head revision), via a
  new `ReadAllTuples :: Revision -> Int -> Maybe StoreCursor -> TupleStore m TuplePage`
  effect operation that keyset-paginates the whole live set ordered by `id`.
  Rationale: No existing read primitive scans all tuples (`readObjectRelation` needs an
  object, `readStartingWithUser` needs subjects). Anchoring every page to one revision makes
  the export a consistent snapshot even while writers proceed. This extends the `TupleStore`
  effect *without altering* docs/plans/46's write constructors, which is exactly the
  extension budget the master plan grants this plan.
  Date: 2026-07-07
- Decision: Round trips are counted with PostgreSQL's own statement log
  (`log_statement = 'all'` on the dev database) rather than instrumenting hasql.
  Rationale: The server's log is ground truth for what crossed the wire; instrumenting the
  client would count what we *think* we sent. The dev process-compose PostgreSQL already
  writes a log file (`$PGLOG`), so the measurement is one `ALTER SYSTEM` and one `grep -c`.
  Date: 2026-07-07
- Decision: Subcommand parsing uses plain `System.Environment.getArgs` pattern matching, not
  a CLI-parsing library.
  Rationale: Two subcommands with one optional flag do not justify a new dependency in
  `en-server`; the master plan scopes this plan to storage throughput, not CLI ergonomics.
  Revisit if the operator surface grows.
  Date: 2026-07-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Record here: the before/after statement
counts for the 100-tuple write, and the 100k-import wall-clock time and tuples/second rate.

(To be filled during and after implementation.)


## Context and Orientation

This plan is a child of `docs/masterplans/8-correct-write-path-and-storage-semantics.md` and
fixes findings C6 and E9 of `docs/reviews/2026-07-07-architecture-performance-review.md`.

**Hard dependency — verify before starting.** This plan hard-depends on
`docs/plans/45-adopt-touch-semantics-for-tuple-writes.md`: the batched statements must
reproduce *touch semantics* (live-tuple identity is object/relation/subject without the
caveat name; a conflicting write soft-deletes the differing live row and inserts the
replacement atomically; identical rewrites are idempotent no-ops), and writing the batch
statements against the older `ON CONFLICT DO NOTHING` behavior would be wasted work that
plan invalidates. Concretely verify: docs/plans/45's Progress checklist is complete;
`grep -n touchReplaceStatement en-postgres/src/En/Postgres/TupleStore.hs` finds the per-tuple
touch statement; and the migration re-keying `relation_tuple_live_unique` (no
`caveat_name` in the key) exists under `en-migrations/db/migrations/`. **Soft dependency**:
`docs/plans/46-add-write-preconditions-and-atomic-mixed-writes.md`. If it has landed (its
Progress complete), the write entry point is `ApplyTupleWrites`/`applyTupleWritesSession`
and the batch rewrite happens inside that session, preserving precondition checks unchanged
before the batched deletes/writes; if it has not, batch `writeTuplesSession` and
`deleteTuplesSession` directly and EP-46 will inherit the batched statements. Record which
case applied in this Decision Log.

en is a Haskell project at `/Users/shinzui/Keikaku/bokuno/en`. Orientation:

- `en-postgres/src/En/Postgres/TupleStore.hs` — the hasql (typed PostgreSQL client)
  implementation of the `TupleStore` effect. The write session runs `BEGIN`; an *anchor*
  statement inserting the transaction's xid and snapshot into `en_transaction` (the token is
  minted from it — the minting seam is owned by docs/plans/47 and must not be changed here);
  per-tuple statements; `COMMIT`. Each `Session.statement` is a network round trip. The
  *read* path already shows the batching idiom this plan applies to writes:
  `readStartingWithUserStatement` sends three parallel `text[]` arrays and joins
  `unnest($4::text[], $5::text[], $6::text[])` server-side.
- `en-core/src/En/Effect/TupleStore.hs` — the storage effect. `TuplePage`/`StoreCursor` are
  the existing keyset-pagination vocabulary (a cursor is the last-seen `relation_tuple.id`);
  `ReadAllTuples` (added here) reuses them.
- `en-core/src/En/Conformance/Kikan.hs` — the in-memory interpreter (stateful with touch
  semantics after docs/plans/45); gains a trivial `ReadAllTuples` (page over the whole state
  with the existing `pageTuples` helper). `en-core/src/En/Effect/CachedTupleStore.hs` is a
  read-cache interposer whose catch-all `passthrough` forwards unknown operations —
  `ReadAllTuples` is deliberately *not* cached (export pages are read once; caching them
  would evict hot check-path entries), so the passthrough is the desired behavior; confirm
  by reading its case list.
- `en-server/app/Main.hs` — the standalone service binary. Today `main` reads env vars
  (`EN_DATABASE_URL` required, `EN_SCHEMA_PATH` optional) and starts Warp; there is no
  argument parsing. The import/export subcommands reuse its connection setup and
  `ConsistencyConfig` construction, then run store sessions instead of serving HTTP.
- `en-servant/src/En/Servant/API.hs` — `TupleWire` and `tupleToWire`/`tupleFromWire`, the
  JSON codec the NDJSON format reuses.
- Databases for testing: `cabal test en-postgres-integration-tests` starts its own throwaway
  PostgreSQL via `ephemeral-pg` (needs only PostgreSQL binaries on `PATH`, which the dev
  shell provides). The *dev* database — needed for the statement-count and throughput
  measurements and for running the subcommands for real — comes from process-compose:
  `just process-up` starts it (readiness-looped on `pg_ctl status`), `just run-migrations`
  applies the schema, and `$PG_CONNECTION_STRING` is its connection string; its server log
  path is `$PGLOG`.

Term: **`unnest` batching**. Instead of one `INSERT`/`UPDATE` per tuple, the session sends
each column of the whole batch as a PostgreSQL array parameter and the statement expands them
server-side with `unnest(a, b, c, …)` into a rowset — one round trip for any batch size.

Term: **anchored batch / token semantics**. Every write transaction inserts one
`en_transaction` row (the anchor) from which its consistency token is minted; a reader
presenting that token sees the whole batch or none of it. Import keeps this per batch: N/5000
transactions, each atomic, each yielding a token; the final token is printed so a follow-up
read can see the entire import.

Integration points restated from the master plan
(`docs/masterplans/8-correct-write-path-and-storage-semantics.md`):

- **The uniqueness index (`relation_tuple_live_unique`) is owned by docs/plans/45** — the
  batched insert's `ON CONFLICT DO NOTHING` leans on its re-keyed form; do not alter it.
- **The write signature is finalized by docs/plans/46** — this plan extends the effect with
  `ReadAllTuples` but must not alter `ApplyTupleWrites` (or, pre-EP-46, the
  `WriteTuples`/`DeleteTuples` constructors); batching is an interpreter-internal change.
- **The write-token snapshot definition is owned by docs/plans/47** — the batched session
  mints tokens through the same `tokenFromAnchor`/`writeVisibleSnapshot` seam, unmodified.
- **Index changes are owned by docs/plans/49** (with the
  docs/plans/53-add-a-watch-changelog-api.md coordination on `created_xid`); this plan adds
  no indexes — `ReadAllTuples` orders by `id`, the primary key.


## Plan of Work

Three milestones: batch the write path (C6), add the export primitive, and build the two
subcommands with the throughput measurements (E9).


### Milestone 1 — `unnest`-batched writes with touch semantics

Scope: the write session issues a constant number of statements regardless of tuple count.
At the end, the docs/plans/45 touch scenarios pass unchanged through the batched path and the
statement log shows the constant count.

In `en-postgres/src/En/Postgres/TupleStore.hs`, add a `BatchParams` record holding the anchor
xid plus one list per tuple column (`objectTypes :: [Text]`, `objectIds`, `relations`,
`subjectTypes`, `subjectIds`, `subjectRelations :: [Maybe Text]`,
`caveatNames :: [Maybe Text]`, `caveatPayloads :: [Maybe LazyByteString.ByteString]`), built
by transposing the tuple list with the existing `flattenSubject`/`flattenCaveat` helpers.
Encode nullable array elements with `Encoders.foldableArray (Encoders.nullable …)` (the
existing `textArrayEncoder` is the non-nullable template). Three statements replace the
per-tuple loops — each the set-form of its docs/plans/45 counterpart, and each decoding
`Decoders.rowsAffected` or a key list so the session can implement the same
verify-and-retry:

1. `batchTouchReplaceStatement` — soft-delete live rows whose identity matches a batch entry
   but whose caveat differs:

   ```sql
   UPDATE relation_tuple AS t
   SET deleted_xid = $1::xid8
   FROM unnest($2::text[], $3::text[], $4::text[], $5::text[], $6::text[],
               $7::text[], $8::text[], $9::jsonb[])
        AS w(object_type, object_id, relation, subject_type, subject_id,
             subject_relation, caveat_name, caveat_payload)
   WHERE t.object_type = w.object_type
     AND t.object_id = w.object_id
     AND t.relation = w.relation
     AND t.subject_type = w.subject_type
     AND t.subject_id = w.subject_id
     AND coalesce(t.subject_relation, '') = coalesce(w.subject_relation, '')
     AND t.deleted_xid IS NULL
     AND (t.caveat_name IS DISTINCT FROM w.caveat_name
          OR t.caveat_payload IS DISTINCT FROM w.caveat_payload)
   ```

2. `batchInsertTupleStatement` — insert the whole batch, conflicts (now only identical live
   rows or intra-batch duplicates) dropped:

   ```sql
   INSERT INTO relation_tuple
     (object_type, object_id, relation, subject_type, subject_id,
      subject_relation, caveat_name, caveat_payload, created_xid)
   SELECT w.object_type, w.object_id, w.relation, w.subject_type, w.subject_id,
          w.subject_relation, w.caveat_name, w.caveat_payload, $1::xid8
   FROM unnest($2::text[], $3::text[], $4::text[], $5::text[], $6::text[],
               $7::text[], $8::text[], $9::jsonb[])
        AS w(object_type, object_id, relation, subject_type, subject_id,
             subject_relation, caveat_name, caveat_payload)
   ON CONFLICT DO NOTHING
   ```

3. `batchDeleteTupleStatement` — the set form of the (caveat-ignoring, per docs/plans/45)
   delete: `UPDATE … SET deleted_xid = $1::xid8 FROM unnest(six identity arrays) AS w WHERE
   … AND t.deleted_xid IS NULL`.

Session shape: `BEGIN`; anchor; batch-touch-delete; batch-insert; **batched verify** — the
docs/plans/45 per-tuple verify-and-retry, in set form: select the batch keys whose live row's
caveat still differs from the intended write (a `SELECT … FROM unnest(…) JOIN relation_tuple
… WHERE caveat differs AND deleted_xid IS NULL`); if non-empty (a concurrent racer), rerun
statements 1–2 once for the whole batch; `COMMIT`. Intra-batch duplicate keys: PostgreSQL
raises `21000 cardinality_violation` if one `UPDATE … FROM unnest` matches the same target
row twice with different payloads, and `ON CONFLICT DO NOTHING` drops the second identical
insert — so *pre-dedupe the batch client-side by identity key, last occurrence wins* (a
`Data.Map.Strict.fromList` over `(tupleKey, tuple)` pairs preserves last-wins), which also
preserves docs/plans/45's pinned "same key twice in one call resolves last-wins" behavior.
State this in a comment on the session.

Statement count per write: `BEGIN` + anchor + touch-delete + insert + verify + `COMMIT` =
6, independent of N (7–8 on the rare retry). Deletes: 4.

Acceptance: rerun the docs/plans/45 integration scenarios (payload update, caveat
tightening, idempotent rewrite, same-key-twice) — they now exercise the batched path by
construction since the session is the only write path — plus a new scenario writing 100
tuples in one call and reading all 100 back at the returned token. All via
`cabal test en-postgres-integration-tests`.


### Milestone 2 — The export primitive: `ReadAllTuples`

Scope: a store operation that streams every live tuple at one revision. At the end, embedded
callers (and Milestone 3's `export`) can drain the graph page by page.

- `en-core/src/En/Effect/TupleStore.hs`: add
  `ReadAllTuples :: Revision -> Int -> Maybe StoreCursor -> TupleStore m TuplePage` and the
  `readAllTuples` sender, documented as "every tuple live at the revision, ordered by
  internal row id, keyset-paginated".
- `en-postgres/src/En/Postgres/TupleStore.hs`: `readAllTuplesStatement` — identical in shape
  to `readObjectRelationStatement` minus the object/relation predicates:

  ```sql
  SELECT id, object_type, object_id, relation, subject_type, subject_id, subject_relation,
         caveat_name, caveat_payload, created_xid::text, deleted_xid::text
  FROM relation_tuple
  WHERE id > $3
    AND pg_visible_in_snapshot(created_xid, $1::pg_snapshot)
    AND (deleted_xid IS NULL OR NOT pg_visible_in_snapshot(deleted_xid, $1::pg_snapshot))
  ORDER BY id ASC
  LIMIT $2
  ```

  A primary-key range scan (`id > cursor ORDER BY id`) — no new index needed. Reuse
  `pageFromRows` and the cursor handling exactly as the other reads do (including
  docs/plans/47's strict cursor validation if it has landed).
- `en-core/src/En/Conformance/Kikan.hs`: `ReadAllTuples _ limit cursor` pages the whole
  current state with the existing `pageTuples`.
- `en-core/src/En/Effect/CachedTupleStore.hs`: no edit — confirm `ReadAllTuples` falls into
  the `passthrough` clause.

Acceptance: integration scenario — write 1,500 tuples (the suite already builds 1,500-row
fixtures for pagination tests), drain `readAllTuples` at the write token with `limit = 400`,
assert 1,500 distinct tuples and a final `Exhausted`.


### Milestone 3 — `en-server import` / `en-server export` and the numbers

Scope: the operator-facing subcommands plus the two measurements. At the end, a round trip
(export → import → export) reproduces the graph and the throughput figures are recorded.

In `en-server/app/Main.hs`, dispatch on `System.Environment.getArgs`: `[]` → serve as today;
`["import", "--file", path]` (plus optional `["--batch-size", n]`, default 5000) → import;
`["export"]` → export; anything else → print usage to stderr, exit 2. Both subcommands reuse
`main`'s existing setup (require `EN_DATABASE_URL`, load/validate the schema for the
`ConsistencyConfig` schema hash, connect) but skip Warp, caches, and the port.

Import: stream the file line by line (`Data.Text.Lazy.IO` or strict lines — 100k lines is
small; constant memory matters for larger files, so read lazily), decode each line as
`TupleWire` (`Data.Aeson.eitherDecodeStrict` on the encoded line), convert with
`tupleFromWire`, failing fast with the line number on any parse error; group into batches;
per batch run the write path (the effect's `writeTuples` — or `applyTupleWrites` post-EP-46 —
through the same `runEff`/`runDatabaseConnection`/`runTupleStorePostgres` stack `main`
builds); print progress (`imported 5000/100000`) to stderr and, at the end, the final
consistency token to stdout (machine-readable last line: `token: <text>`). Touch semantics
make re-running an import idempotent.

Export: resolve the head revision once (`TupleStore.headRevision`), then loop
`readAllTuples` pages (limit 5000), printing one `TupleWire` JSON line per tuple
(`Data.Aeson.encode . tupleToWire`) to stdout until `Exhausted`; stderr gets the revision and
final count. Because every page reads at the captured revision, concurrent writes during the
export are excluded — the output is one consistent snapshot.

Document both subcommands in `docs/user/service-and-operations.md` (invocation, format, token
line, idempotence).

**Measurement A — round trips for a 100-tuple write** (dev database):

```bash
cd /Users/shinzui/Keikaku/bokuno/en
just process-up && just run-migrations
psql "$PG_CONNECTION_STRING" -c "ALTER SYSTEM SET log_statement = 'all'" -c "SELECT pg_reload_conf()"
# baseline: check out the pre-batching commit (or count from statements-per-tuple math),
# run a 100-tuple write via the import subcommand with --batch-size 100, then:
grep -c "LOG:  execute" "$PGLOG"
```

Count the log lines between two markers (e.g. `psql -c "SELECT 'MARK-BEFORE'"` /
`'MARK-AFTER'` around the write). Expected: on pre-plan code roughly 103 statements
(2N+3 ≈ 203 if docs/plans/45's two-statement touch landed first); on post-plan code 6.
Record both numbers in Outcomes & Retrospective, then
`psql "$PG_CONNECTION_STRING" -c "ALTER SYSTEM RESET log_statement" -c "SELECT pg_reload_conf()"`.

**Measurement B — 100k import throughput** (dev database):

```bash
cd /Users/shinzui/Keikaku/bokuno/en
awk 'BEGIN { for (i = 1; i <= 100000; i++) printf "{\"object\":{\"objectType\":\"space\",\"objectId\":\"bulk-%d\"},\"relation\":\"viewer\",\"subject\":{\"tag\":\"SubjectIdWire\",\"contents\":{\"objectType\":\"user\",\"objectId\":\"importer\"}},\"caveat\":null}\n", i }' > /tmp/en-bulk-100k.ndjson
time EN_DATABASE_URL="$PG_CONNECTION_STRING" cabal run en-server -- import --file /tmp/en-bulk-100k.ndjson
```

Report tuples/second (100000 ÷ wall seconds) in Outcomes & Retrospective. No hard threshold
is promised (laptop-dependent), but the sanity floor is that the rate must exceed the
pre-plan per-tuple path by at least an order of magnitude — spot-check the baseline by
importing 5k with the pre-plan code if it is still reachable, or extrapolate from
measurement A's round-trip ratio.

**Round-trip fidelity check** (dev database): export, then import into a *fresh* database,
then export again and diff:

```bash
EN_DATABASE_URL="$PG_CONNECTION_STRING" cabal run en-server -- export > /tmp/en-dump-1.ndjson
createdb en_roundtrip
for f in en-migrations/db/migrations/*.sql; do psql "postgresql:///en_roundtrip?host=$PGHOST" -v ON_ERROR_STOP=1 -f "$f"; done
EN_DATABASE_URL="postgresql:///en_roundtrip?host=$PGHOST" cabal run en-server -- import --file /tmp/en-dump-1.ndjson
EN_DATABASE_URL="postgresql:///en_roundtrip?host=$PGHOST" cabal run en-server -- export > /tmp/en-dump-2.ndjson
diff <(sort /tmp/en-dump-1.ndjson) <(sort /tmp/en-dump-2.ndjson) && echo ROUND-TRIP-OK
```

(The `run-migrations` recipe targets only `$PGDATABASE`, so the loop applies the migration
files to `en_roundtrip` explicitly — filename order is application order, matching codd.)
Expected final line: `ROUND-TRIP-OK`.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/en`.

1. Verify dependencies (see Context): docs/plans/45 complete (`grep -n
   touchReplaceStatement en-postgres/src/En/Postgres/TupleStore.hs`; migration present);
   read docs/plans/46's Progress and record in the Decision Log whether batching targets
   `applyTupleWritesSession` or the pre-EP-46 sessions.
2. Milestone 1, then:

   ```bash
   cabal build all
   cabal test en-postgres-integration-tests
   ```

   Expected: `1 of 1 test suites (1 of 1 test cases) passed`, including the touch scenarios
   and the new 100-tuple batch assertion.
3. Milestone 2, then the same two commands; expected: the 1,500-tuple drain assertion
   passes.
4. Milestone 3: implement the subcommands, then run Measurements A and B and the round-trip
   fidelity check exactly as scripted in the Plan of Work (dev database via
   `just process-up`, `just run-migrations`). Expected shapes:

   ```text
   token: en1.…
   ```

   from import,

   ```text
   ROUND-TRIP-OK
   ```

   from the fidelity check, and a `time` line like `real 0m8.412s` from the 100k import —
   record the real numbers, whatever they are.
5. Full sweep and smoke:

   ```bash
   cabal test all
   just start-and-test
   ```

6. Commit per milestone with the plan trailer, e.g.:

   ```text
   perf(en-postgres): batch tuple writes with unnest touch statements

   ExecPlan: docs/plans/48-batch-tuple-writes-and-add-bulk-import-and-export.md
   ```


## Validation and Acceptance

- Behavioral equivalence: every docs/plans/45 touch scenario passes through the batched
  path (`cabal test en-postgres-integration-tests`), including payload update, caveat
  tightening, idempotent rewrite, and intra-batch duplicate keys resolving last-wins.
- Constant round trips: the statement-log count for a 100-tuple write drops from ~103 (or
  ~203 post-EP-45) to 6 — the two counts are captured in Outcomes & Retrospective with the
  grep transcript.
- Bulk import: 100k synthetic tuples import on the dev database with the wall-clock time and
  rate recorded; `psql "$PG_CONNECTION_STRING" -tAc "SELECT count(*) FROM relation_tuple
  WHERE deleted_xid IS NULL AND object_id LIKE 'bulk-%'"` prints `100000`; re-running the
  same import changes nothing (idempotence via touch) and the count stays `100000`.
- Bulk export: `export | wc -l` equals the live-tuple count; export→import→export round-trips
  byte-identically modulo line order (`ROUND-TRIP-OK`).
- `cabal test all` and `just start-and-test` pass — the serving path is untouched when no
  subcommand is given.


## Idempotence and Recovery

Import is idempotent end-to-end: touch semantics make re-importing the same file a no-op
(identical rewrites), so a crashed import is safely resumed by re-running it from the start —
batches already applied become no-ops. Each batch is one transaction: a crash mid-batch
leaves no partial batch. Export is read-only. The statement-log measurement mutates only
`log_statement`; reset it afterwards (`ALTER SYSTEM RESET log_statement` +
`pg_reload_conf()`, as scripted). The throwaway `en_roundtrip` database can be dropped with
`dropdb en_roundtrip`. All build/test commands are idempotent; commit per milestone so any
milestone reverts independently.


## Interfaces and Dependencies

- `hasql` — the batch statements; nullable array elements via
  `Encoders.foldableArray (Encoders.nullable Encoders.text)` and a `jsonb[]` parameter via
  `Encoders.foldableArray (Encoders.nullable Encoders.jsonbLazyBytes)`.
- `aeson` — NDJSON encode/decode of `TupleWire` (already an `en-servant` dependency;
  `en-server` already depends on `en-servant`).
- `en-servant` (`En.Servant.API.TupleWire`, `tupleToWire`, `tupleFromWire`) — the
  interchange codec.
- `ephemeral-pg` — integration scenarios; the dev process-compose PostgreSQL
  (`just process-up`, `$PG_CONNECTION_STRING`, `$PGLOG`) for measurements.

Signatures that must exist at the end (full module paths):

- `En.Effect.TupleStore.TupleStore` gains `ReadAllTuples :: Revision -> Int -> Maybe
  StoreCursor -> TupleStore m TuplePage` and `En.Effect.TupleStore.readAllTuples`; the write
  constructors are byte-identical to their pre-plan state (verify with `git diff` — batching
  is interpreter-internal).
- `En.Postgres.TupleStore.batchTouchReplaceStatement`, `.batchInsertTupleStatement`,
  `.batchDeleteTupleStatement`, `.readAllTuplesStatement` (internal statements).
- `en-server` binary: `en-server` (serve), `en-server import --file PATH [--batch-size N]`,
  `en-server export`.

Cross-plan boundary (restated): the uniqueness index is docs/plans/45's; the write
signature is docs/plans/46's (extended here only by `ReadAllTuples`, never altered); the
token snapshot construction is docs/plans/47's (`tokenFromAnchor` called unmodified); index
additions/removals are docs/plans/49's, coordinated with
docs/plans/53-add-a-watch-changelog-api.md — `ReadAllTuples` deliberately orders by the
primary key so it needs none of the indexes under docs/plans/49's review.
