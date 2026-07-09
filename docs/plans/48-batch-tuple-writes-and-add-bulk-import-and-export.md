---
id: 48
slug: batch-tuple-writes-and-add-bulk-import-and-export
title: "Batch tuple writes and add bulk import and export"
kind: exec-plan
created_at: 2026-07-07T15:25:00Z
master_plan: "docs/masterplans/8-correct-write-path-and-storage-semantics.md"
intention: intention_01kx48hvkeemk9j4r828132s2h
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

- [x] Verify the hard dependency on docs/plans/45 (touch statements and re-keyed unique index present) and check docs/plans/46's status to pick the write entry point (`ApplyTupleWrites` vs `WriteTuples`/`DeleteTuples`). — 2026-07-09. Both complete; the entry point is `applyTupleWritesSession`.
- [x] Add `batchTouchReplaceStatement`, `batchInsertTupleStatement`, `batchDeleteTupleStatement`, and the batched verify statement (`batchUnconvergedStatement`) to `en-postgres/src/En/Postgres/TupleStore.hs`; rewrite the write session over them. — 2026-07-09
- [x] Prove batched-vs-sequential equivalence in `en-postgres/integration-test/Main.hs` (docs/plans/45's five touch scenarios rerun unchanged through the batched path, plus `runBatchWriteScenario` and `runBatchTouchRaceScenario`). — 2026-07-09
- [x] Each new scenario run once against the bug it claims to catch (see Surprises & Discoveries). — 2026-07-09
- [x] Add the `ReadAllTuples` effect operation to `en-core/src/En/Effect/TupleStore.hs`, implement it in the PostgreSQL and in-memory interpreters, and confirm the cached interposer passes it through. — 2026-07-09. `runReadAllTuplesScenario` proves the drain is complete and snapshot-isolated; the write constructors are byte-identical to their pre-plan state (`git diff bf9cd88 -- en-core/src/En/Effect/TupleStore.hs`).
- [x] Add subcommand dispatch to `en-server/app/Main.hs` and implement `import` (NDJSON in, anchored batches, final token printed) and `export` (NDJSON out at a single revision). — 2026-07-09
- [x] Split `StoreConfig` out of `ServerConfig` in `en-server/app/Config.hs` so the subcommands need no API keys, rate limit, or TLS material. — 2026-07-09. Not in the plan; see Surprises.
- [x] Fix the planner regression the batched statements introduced: all three drive from the unnested batch through a `LATERAL` probe of `relation_tuple_live_unique`. — 2026-07-09. See Surprises; this is the plan's most consequential finding.
- [x] Round-trip test: export a seeded dev database, import into a fresh database, compare sorted NDJSON. — 2026-07-09. Also round-tripped caveats, usersets, and wildcards, and confirmed export is a fixed point.
- [x] Measure: statement-log counts for a 100-tuple write before/after; 100k-tuple import wall-clock and rate; record both in Outcomes & Retrospective. — 2026-07-09
- [x] Update `docs/user/service-and-operations.md` with the two subcommands. — 2026-07-09
- [x] Run `cabal build all`, `cabal test all`, `just start-and-test`; record transcripts. — 2026-07-09. All seven suites pass; `just start-and-test` prints `server smoke test passed: allowed`.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

**The retry ladder repairs duplicate keys, until it doesn't — and then it raises.** The
plan justified client-side deduplication with "PostgreSQL raises `21000
cardinality_violation` if one `UPDATE … FROM unnest` matches the same target row twice".
It does not: `UPDATE … FROM` silently picks one arbitrary source row per target (only
`MERGE` and `ON CONFLICT DO UPDATE` raise 21000), and `ON CONFLICT DO NOTHING` tolerates
intra-command duplicates. Deduplication is still required, but for two other reasons.

The first is determinism. `INSERT … SELECT … ON CONFLICT DO NOTHING` keeps whichever
conflicting row the executor reaches first, so a batch carrying one identity twice
resolves *arbitrary*-wins on the insert. The retry ladder then hides this: each attempt
inserts the earliest surviving copy and drops the rest, so the unconverged set walks the
batch down toward its last copy, and two or three copies land on last-wins by accident.

The second is that the accident stops at four. With four copies, the convergence check
hands the fallback two entries of one identity, and the fallback's insert omits
`ON CONFLICT` by design — so PostgreSQL raises `unique_violation` and a legitimate
last-wins request becomes a `503 store_error`. Verified by deleting the `dedupeWrites`
call and running the suite:

```text
code: 23505
message: duplicate key value violates unique constraint "relation_tuple_live_unique"
detail: Key (object_type, object_id, relation, subject_type, subject_id,
  COALESCE(subject_relation, ''::text))=(space, batch-quadruple, viewer, user, batch-alice, )
  already exists.
```

The first duplicate-key scenario written for this plan used *two* copies and passed
against the un-deduplicated code, certifying nothing. `runBatchWriteScenario`'s fourth
sub-scenario uses four.

**Within one transaction the batch always converges on the first attempt, so a
single-connection suite leaves the retry ladder entirely untested.** After
`batchTouchReplaceStatement`, the only live row that can still conflict with an entry is
byte-identical to it — which satisfies the entry. So `batchUnconvergedStatement` returns
`[]`, and the second attempt, the fallback, and the ordinal bookkeeping that maps an
unsatisfied entry back to its tuple are unreachable. Injecting an off-by-one into
`selectOrdinals` (`zip [0 ..]` for `zip [1 ..]`) left the whole suite green.

`runBatchTouchRaceScenario` forces the overlap: a racer holds an uncommitted live row for
the contended identity, the writer's retire statement cannot see it, the writer's insert
blocks on it (asserted, not slept for), and only then does the racer commit. The same
off-by-one now fails loudly, and in the exact shape finding C1 describes — the writer's
caveat is silently dropped and a success token is returned:

```text
user error (the writer's caveat replaces the racer's rather than being silently dropped
expected: [Just (TupleCaveat {name = CaveatName "within_autonomy", payload = ... 2026-12-31 ...})]
actual:   [Just (TupleCaveat {name = CaveatName "within_autonomy", payload = ... 2026-01-01 ...})])
```

The contended entry is deliberately the batch's *second*, so the retry acts on ordinal 2
and a zero-based mapping selects nothing at all.

**An unreferenced bind parameter has no inferable type.** `batchUnconvergedStatement`
reads rather than writes, so it never mentions the write xid. Sending it anyway as an
unused `$9` fails at parse time with "could not determine data type of parameter". Hence
three encoders over one `BatchParams` — `batchColumnsEncoder` (`$1`–`$8`),
`batchWriteEncoder` (plus the xid at `$9`), and `batchDeleteEncoder` (the six identity
arrays plus the xid at `$7`) — rather than one shared encoder as the per-row statements
had.

**Batching a statement changes its plan, and `unnest` has no statistics. This was the
plan's real hazard, and it is not in finding C6.** Replacing N indexed single-row
statements with one N-row join hands the planner a `Function Scan` it cannot estimate.
Below roughly a thousand entries it nested-loops over `relation_tuple_live_unique`, which
is what the per-row statements did. Above that it switches to a merge join over whatever
index it can scan in order — `relation_tuple_subject_hist_idx`, whose columns are the
subject plus the object *type*, and **not** the object id. So `object_id`, the only
discriminating column in a bulk import, is demoted from the merge condition to a join
filter, and the merge produces the cross product:

```text
Update on relation_tuple t (actual rows=0 loops=1)
->  Merge Join (actual rows=0 loops=1)
      Merge Cond: ((t.subject_type = w.subject_type) AND (t.subject_id = w.subject_id) AND ...
                   AND (t.object_type = w.object_type) AND (t.relation = w.relation))
      Join Filter: ((w.object_id = t.object_id) AND ((t.caveat_name IS DISTINCT FROM ...)))
      Rows Removed by Join Filter: 500000000
      ->  Index Scan using relation_tuple_subject_hist_idx on relation_tuple t (actual rows=100000)
      ->  Sort (actual rows=499900001 loops=1)
Execution Time: 55791.728 ms
```

One 5,000-tuple retire statement against a 100,000-row table: **55.8 seconds**, 500
million discarded pairs. Measured crossover, same table:

| batch | plan | execution |
| --- | --- | --- |
| 1 | Nested Loop over `relation_tuple_live_unique` | 0.4 ms |
| 1,000 | Nested Loop | 3.6 ms |
| 2,000 | Merge Join | 22,322 ms |
| 5,000 | Merge Join | 55,792 ms |

`EN_MAX_BATCH_SIZE` defaults to **1,000**. An operator raising it to 2,000 would have
turned an ordinary HTTP write into a 22-second table scan, with no code change and no
warning. The default import batch size of 5,000 sat well past the cliff.

It surfaced as a 100,000-tuple re-import taking **272 seconds** where the first import of
the same file took **3.12 seconds** — and then, damningly, the *first* import of a fresh
database timed at 54 seconds on a later run. Same file, same code: autoanalyze had fired
partway through, the planner learned the table's true size, and flipped to the merge join
mid-import. A performance property that depends on when autovacuum last ran is not a
property.

The fix removes the choice rather than tuning it. Every batch statement now drives from
the unnested batch through a `CROSS JOIN LATERAL` (or `LEFT JOIN LATERAL`, for the
convergence check) that probes `relation_tuple_live_unique` once per entry. `LIMIT 1`
inside the lateral is exact — the unique index admits one live row per identity — and it
is also what stops the planner flattening the subquery back into the join. The batch is
always the outer relation:

```text
Update on relation_tuple t
->  Nested Loop
      ->  Function Scan on w (actual rows=5000 loops=1)
      ->  Limit (actual rows=0 loops=5000)
            ->  Index Scan using relation_tuple_live_unique on relation_tuple r
Execution Time: 14.355 ms
```

55,792 ms → 14.4 ms, and the plan no longer depends on the batch size, the table size, or
`work_mem`. The convergence check went from a hash anti join that hashed every live row
in the table (38.6 ms at 100k rows, and unbounded above that) to 10.3 ms of index probes.
End to end, the 100k re-import went from 272 s to **3.57 s**.

**A stale binary reports the old numbers.** `cabal build en-postgres` does not relink the
`en-server` executable. The first "post-fix" measurement showed no improvement because
`cabal list-bin en-server` still pointed at a binary linking the pre-fix library. Build
the executable, not the library, before measuring it.

**`loadServerConfig` refuses to start without API keys — correctly, and it was refusing
the subcommands too.** `en-server import` bound no port and served no request, yet
demanded `EN_API_KEYS_READ_WRITE`. `StoreConfig` is now split out of `ServerConfig` and
read by `loadStoreConfig`, which reads only `EN_DATABASE_URL`, `EN_SCHEMA_PATH`,
`EN_GC_WINDOW`, and `EN_POOL_*`. `parseServerConfig` builds on `parseStoreConfig` rather
than duplicating it, so the two cannot drift.

**Hand-written NDJSON is a bad oracle, and the importer said so.** Three attempts at a
caveated test line were rejected in turn — `payload` needs a `values` wrapper, and each
value is a tagged `{"type": …, "value": …}` object. The importer named the file, the line,
and the JSON path each time (`caveated.ndjson:1: Error in $.caveat.payload.values.ok:
parsing CaveatValueWire failed, expected Object, but encountered Boolean`), which is
exactly the behavior the plan asked for, arrived at by being on the receiving end of it.


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
- Decision: The soft dependency resolved in the affirmative — docs/plans/46 has landed, so
  batching rewrote `applyTupleWritesSession`, which stays `Session (Either Text Anchor)`.
  Rationale: Its Progress checklist is complete and `ApplyTupleWrites` is the effect's only
  write constructor. Preconditions are checked unchanged, before the batched delete and the
  batched touch; the interpreter still mints the token from the returned `Anchor`, per
  docs/plans/47's seam. Batching is entirely interpreter-internal: the effect's constructors
  are byte-identical to their pre-plan state.
  Date: 2026-07-09
- Decision: The batch's convergence check asks one set-oriented question — "which entries
  have no byte-identical live row?" — returning ordinals via `unnest … WITH ORDINALITY`,
  rather than reproducing the per-row pair of "did the insert affect a row?" and "is there an
  identical row?".
  Rationale: An entry whose insert succeeded has a byte-identical live row, and so does an
  entry that was already present, so one question subsumes both. Ordinals map an unsatisfied
  entry back to its tuple without shipping the tuple's columns home again, which keeps the
  retry restricted to the unconverged subset — a retry that re-inserted a satisfied entry
  would raise the very `unique_violation` that signals failure.
  Date: 2026-07-09
- Decision: The retry acts only on the unconverged subset, and the final fallback insert
  omits `ON CONFLICT`, exactly as the per-row protocol did.
  Rationale: This preserves docs/plans/45's contract that a write which cannot converge fails
  loudly rather than being dropped. It also forces `dedupeWrites`: without it a four-way
  duplicate reaches the fallback with two same-identity rows and the strict insert raises.
  Date: 2026-07-09
- Decision: Every batch statement reaches `relation_tuple` through a `LATERAL` probe driven
  by the unnested batch, never as a bare join, and never via `NOT EXISTS`.
  Rationale: A `Function Scan` has no statistics. Left to choose, the planner abandons the
  nested loop over `relation_tuple_live_unique` somewhere between 1,000 and 2,000 entries and
  picks a merge join on an index without `object_id`, producing the cross product — 55.8
  seconds and 500M discarded pairs for one 5,000-tuple statement. `EN_MAX_BATCH_SIZE` defaults
  to 1,000, one step from the cliff, and autoanalyze can move the cliff under a running
  import. The `LATERAL` is not an optimization; it is what makes the plan a property of the
  statement rather than of the planner's current beliefs. Verified with EXPLAIN ANALYZE at
  batch sizes 1 through 5,000. This constraint binds any future batched statement over
  `relation_tuple`, including docs/plans/49's index work.
  Date: 2026-07-09
- Decision: `StoreConfig` is split out of `ServerConfig`, and the subcommands read only it.
  Rationale: `loadServerConfig` fails closed without API keys — right for a server, absurd for
  a bulk load that binds no port. `parseServerConfig` is defined in terms of `parseStoreConfig`
  so the store variables cannot diverge between the two loaders.
  Date: 2026-07-09
- Decision: `--batch-size 5000` stays the import default despite the planner finding.
  Rationale: With the `LATERAL` probes the plan is index-driven at every batch size, so the
  cliff no longer exists and the batch size trades only transaction size against round trips.
  Measured at 100k tuples in 3.6 seconds either way.
  Date: 2026-07-09
- Decision: A malformed line aborts the import with earlier batches committed, rather than
  validating the whole file first.
  Rationale: Validating first means holding every tuple in memory, forfeiting the streaming
  that lets a file larger than memory import at all. Touch semantics make the committed prefix
  a no-op on re-run, so the failure costs nothing but the operator's second invocation. The
  error names the file, the line, and the JSON path.
  Date: 2026-07-09


## Outcomes & Retrospective

Both of the plan's promises hold, and the work turned up a defect graver than the finding
it was chartered to fix.

**Round trips (finding C6).** Measured with PostgreSQL's own statement log
(`log_statement = 'all'`), counting the lines a single 100-tuple `POST /v1/relationships`
produced between two marker statements, against `bf9cd88` (pre-plan) and `HEAD`:

| | statements | shape |
| --- | --- | --- |
| before | **203** | `BEGIN`, anchor, then `UPDATE` + `INSERT` per tuple, `COMMIT` — 2N+3 |
| after | **6** | `BEGIN`, anchor, retire, insert, converge, `COMMIT` — constant in N |

The predicted 2N+3 and 6 exactly. A delete costs 4. The contended retry costs 8, and no
scenario outside the deliberate race provoked one.

**Bulk import and export (gap E9).** 100,000 synthetic relationships (a 15.8 MB NDJSON
file), dev PostgreSQL on an Apple-silicon laptop, `--batch-size 5000`:

| | wall clock | rate |
| --- | --- | --- |
| import into an empty database | 3.17 s | ~31,500 tuples/s |
| re-import the same file (all rows present) | 2.13 s | ~47,000 tuples/s |
| export 100,000 rows | 1.10 s | ~91,000 tuples/s |

(Timings vary a few tenths of a second run to run; a separate run of the same three
commands read 3.75 s / 3.57 s / —. The figures above are one consistent set.)

`psql -tAc "SELECT count(*) …"` returns `100000` after the first import and `100000` after
the second, with no retired rows: touch semantics make re-import a true no-op, so a crashed
import is resumed by re-running it. `export | wc -l` equals the live count. Sorted
`export → import → export` is byte-identical (`100K-ROUND-TRIP-OK`), including caveated
tuples, usersets, and wildcards, and export is a fixed point of import.

Against the pre-plan per-tuple path the sanity floor was "an order of magnitude". The
round-trip ratio is 203/6 ≈ 34×, and the measured import rate is ~31k tuples/s where the
per-tuple path would issue 200,000 statements to do the same work.

**The gap the plan did not anticipate.** Finding C6 is about round trips, and this plan
delivered on it in Milestone 1. But collapsing N indexed single-row statements into one
N-row join is not a neutral transformation: it replaces a plan the planner cannot get
wrong with one it estimates, and `unnest` gives it nothing to estimate from. Past ~1,000
entries it chose a merge join on an index lacking `object_id` and computed the cross
product — 55.8 seconds for one statement, 500 million discarded pairs. `EN_MAX_BATCH_SIZE`
defaults to 1,000, one doubling from that cliff. The bug was invisible in the integration
suite (whose tables are small), invisible in the 100-tuple statement-count measurement,
and invisible in the *first* 100k import — it only appeared on the second, after
autoanalyze had taught the planner the table's size. Pinning all three statements to
`LATERAL` probes of `relation_tuple_live_unique` made the plan a property of the statement:
55,792 ms → 14.4 ms, and the 100k re-import 272 s → 3.57 s.

The lesson generalizes past this plan: **a batched statement's cost must be argued from its
plan, not from its round-trip count.** Any future batched statement over `relation_tuple`
— docs/plans/49's index work included — should be EXPLAINed at a batch size well above
`EN_MAX_BATCH_SIZE` against a table large enough to have statistics.

**Test-quality lessons, both learned the hard way.** The first duplicate-key scenario used
two copies of an identity and passed against the un-deduplicated code, because the retry
ladder walks a two-copy batch down to last-wins by accident; four copies are needed to
reach the failure. And within one transaction the batch always converges on its first
attempt, so `batchUnconvergedStatement`, the second attempt, the fallback, and the ordinal
mapping were *entirely unreachable* from a single-connection suite — an injected off-by-one
in `selectOrdinals` left the whole suite green. `runBatchTouchRaceScenario` forces the
overlap and now catches it, in exactly the silent-drop shape finding C1 describes. Both
scenarios were run once against the bug they claim to catch, as the master plan requires.

**Scope taken on beyond the plan.** `StoreConfig` was split out of `ServerConfig` because
`en-server import` was refusing to run without API keys for a server it does not start. The
`LATERAL` rewrite was not planned. Neither changed the `TupleStore` effect's write
constructors, which are byte-identical to their pre-plan state
(`git diff bf9cd88 -- en-core/src/En/Effect/TupleStore.hs` shows only the `ReadAllTuples`
addition), so the master plan's extension budget for this plan was respected.


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
