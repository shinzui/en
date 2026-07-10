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

- [x] Enumerate every `Statement` in `en-postgres/src/En/Postgres/TupleStore.hs` as of the working tree (sibling plans may have reshaped the write path) and prepare the EXPLAIN harness for each.
- [x] Seed the dev database and capture `EXPLAIN (ANALYZE, BUFFERS)` for every statement; record which indexes each uses.
- [x] Confirm `relation_tuple_object_live_idx` and `relation_tuple_subject_live_idx` appear in no plan; check `pg_stat_user_indexes.idx_scan` stays zero across a driven workload. — **object_live_idx confirmed dead (0 scans). subject_live_idx is NOT dead: it serves EP-46's subject-scoped precondition filter. Resolved by counterfactual — see Surprises & Discoveries and the 2026-07-09 Decision Log entry.**
- [x] Check docs/plans/53-add-a-watch-changelog-api.md status; decide keep-vs-drop for `relation_tuple_created_xid_idx`; record the outcome in BOTH Decision Logs. — **KEEP; mirrored in both logs.**
- [x] Create the drop migration with `just make-migration drop-dead-live-indexes`; add its Justfile guard; mirror the removal in the integration test's `schemaSql`. — `20260709232320_drop-dead-live-indexes.sql`; drops **both** `*_live_idx`; guard is the fifth stanza; idempotence confirmed ("dead live indexes already dropped").
- [x] Re-run the EXPLAIN sweep post-drop to confirm no plan regressed to a sequential scan. — no regressions; the reaper's plan flip was proven (by counterfactual re-creation of the indexes) to be an autovacuum statistics effect, not a consequence of the drop.
- [x] Refactor `ResolveConsistency` in `en-postgres/src/En/Postgres/Revision.hs` to fetch per mode; generalize the TTL cache. — done. **The horizon is deliberately NOT put behind the cache**: this plan's TTL-cache Decision Log entry had the safety direction inverted. See Surprises & Discoveries and the 2026-07-09 Decision Log entry.
- [x] Add the operation-counting integration assertion (per-mode fetch counts) and record before/after counts. — `runConsistencyFetchCountScenario`; before/after recorded in Outcomes.
- [x] Run `cabal build all`, `cabal test all`, `just start-and-test`; record transcripts.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

**`relation_tuple_subject_live_idx` is used, and dropping it still makes every plan
faster.** This plan predicted both `*_live_idx` indexes would appear in no plan, and
installed a gate: "if a plan *does* use a supposedly dead index, stop … keep that index."
The gate fired. EP-46 (docs/plans/46) added `matchingLiveTupleExistsStatement` and
`lockMatchingLiveTupleStatement`, whose `TupleFilter` makes `objectId` optional while
`objectType` is mandatory. A subject-scoped precondition — `{objectType: "space",
subjectType: "user", subjectId: "bob"}`, reachable straight over
`POST /v1/relationships` — filters `deleted_xid IS NULL` with a subject-leading key, and
the planner picks `relation_tuple_subject_live_idx` for it. A driven workload through the
real server recorded `idx_scan = 1` on it (and `0` on `relation_tuple_object_live_idx`,
which stayed dead even under an object-scoped precondition).

But "used" is not "needed". Dropping the index inside a rolled-back transaction and
re-EXPLAINing the same statement shows `relation_tuple_subject_hist_idx` — the non-partial
twin — taking over with the **identical index condition**, fewer buffers, and lower
latency:

```text
-- baseline (subject_live_idx present)
->  Index Only Scan using relation_tuple_subject_live_idx on relation_tuple (actual rows=0 loops=1)
      Index Cond: ((subject_type = 'user') AND (subject_id = 'nobody-here') AND (object_type = 'space'))
      Heap Fetches: 0
      Buffers: shared hit=3
    Execution Time: 0.059 ms

-- counterfactual (subject_live_idx dropped)
->  Index Scan using relation_tuple_subject_hist_idx on relation_tuple (actual rows=0 loops=1)
      Index Cond: ((subject_type = 'user') AND (subject_id = 'nobody-here') AND (object_type = 'space'))
      Buffers: shared hit=3
    Execution Time: 0.018 ms
```

The partial index wins an index-only scan but loses on wall clock and ties on buffers; the
hist twin's key is a superset prefix for this predicate. So the gate's *purpose* (do not
regress a plan) is satisfied by dropping it, even though the gate's *text* (an index that
appears in a plan is load-bearing) says keep. Measured write amplification for the pair, on
a 20,000-row insert into the 250k-row seeded table, median of three trials:

```text
all indexes ....................... 0.573 s
both *_live_idx dropped ........... 0.378 s   (-34%)
object_live_idx dropped only ...... 0.586 s   (within noise of baseline)
```

The write win requires dropping *both* — removing `object_live_idx` alone is unmeasurable.
Discovered 2026-07-09; the keep-vs-drop call was escalated and resolved as "drop both".

**`relation_tuple_live_unique` subsumes `relation_tuple_object_live_idx` outright.** The
dead index's key is `(object_type, object_id, relation, id)` partial on
`deleted_xid IS NULL`; the unique index's key begins `(object_type, object_id, relation,
subject_type, …)` under the same predicate. Every object-scoped precondition the API admits
binds a prefix of those three columns, so the unique index answers it — as an *Index Only
Scan* when the filter is a prefix. That is why `object_live_idx` records zero scans even
when the workload contains exactly the query it was built for. Its only unique capability,
ordering by `id` within an object key, has no consumer: the read path filters visibility
through `pg_visible_in_snapshot(...)`, never `deleted_xid IS NULL`, so it cannot use a
partial index predicated on the latter — the original C9 reasoning, confirmed.

**The precondition statements are fast only because PostgreSQL re-plans them per
execution.** `lockMatchingLiveTupleStatement` and `matchingLiveTupleExistsStatement` are
`Statement.preparable`, and their `($n::text IS NULL OR col = $n)` idiom is sargable only
after the planner folds a known-NULL parameter away — which a *custom* plan does and a
*generic* plan cannot. Forcing `plan_cache_mode = force_generic_plan` collapses both to a
sequential scan of the whole table:

```text
->  Parallel Seq Scan on relation_tuple (actual rows=0 loops=2)
      Filter: ((deleted_xid IS NULL) AND (($2 IS NULL) OR (object_id = $2)) AND …)
      Rows Removed by Filter: 250019
      Buffers: shared hit=3035
    Execution Time: 19.284 ms      -- vs 0.059 ms on the custom plan
```

This is not a live defect: PostgreSQL only adopts a generic plan when its estimated cost is
no worse than the custom average, and here the generic plan is ~500× dearer, so the custom
plan is chosen forever. The driven-workload counters confirm it — the real server, going
through hasql's prepared statements, took the index. It is recorded because the safety
margin is the planner's cost comparison rather than anything in the SQL, and because a
future edit that makes the generic plan look cheap would silently put a full-table lock scan
inside a write transaction. Discovered 2026-07-09.

**A TTL-cached garbage-collection horizon is permissive, not conservative — this plan's
Decision Log had the direction inverted.** The 2026-07-07 entry justified putting the horizon
behind the optimized-revision TTL cache on the grounds that "a stale-by-TTL horizon is
strictly conservative for token validation … it can only *under*-state how much history is
retained, never accept a too-old token". Both halves are backwards.

`oldestRetainedXidStatement` is `min(xid) FROM en_transaction WHERE created_at >= now() -
gcWindow`. Wall-clock only advances, so transactions age out of the window from below and the
horizon **rises monotonically**. `validateTokenMetadata` rejects a token when
`snapshot.xmax <= oldestRetainedXid` — a *larger* horizon rejects *more* tokens. Therefore a
cached horizon, being older and hence **smaller**, rejects **fewer** tokens: it honours tokens
whose history the reaper has already destroyed, for up to one TTL. A smaller horizon
*over*-states retention (it claims history reaches further back than it does), and it accepts
precisely the too-old tokens the check exists to catch.

The consequence is not merely theoretical. It would widen the GC TOCTOU race EP-47 documented
as finding C7 — currently bounded by request duration — to `TTL + request duration`, and it
would do so through a knob (`EN_OPTIMIZED_REVISION_CACHE_TTL_MS`) whose documented meaning is
"how stale may a revision be". An operator raising it to cut read latency would silently also
extend how long an expired consistency token keeps working. One knob, two meanings, one of
them safety-relevant.

The horizon cache was therefore **not built**. It is also not needed for this plan's own
acceptance criteria: the fetch-count table asserts `AtLeastAsFresh = 2` fetches, meaning the
horizon is fetched, and lazy resolution alone hits all four targets (1/1/1/2) by removing the
horizon fetch from the token-less modes entirely — which are the hot check path. `TtlCache a`
is still generalized as the plan asked, so a horizon cache can be added later behind its own
knob and its own honest safety argument. Discovered 2026-07-09.

**The maintenance batch statements hash-joined a full table scan to delete 1,000 rows.
Fixed here with a `ctid` join.** The post-drop sweep showed `reapDeletedTuplesBatchStatement`
planning as a `Hash Join` whose outer side is a `Seq Scan on relation_tuple` (250,023 rows,
3,035 buffers) to reap a `LIMIT 1000` victim set — 27 ms.

It looked at first like a regression this plan had caused. It is not: recreating both dropped
indexes inside a rolled-back transaction and re-EXPLAINing yields a *byte-identical* plan,
same cost (`202.11..6684.93`), same `Seq Scan`. The flip between the pre- and post-drop sweeps
was autovacuum moving the `deleted_xid` statistics, not an index disappearing. **A before/after
EXPLAIN across a schema change is not a controlled experiment unless statistics are held still
or the counterfactual is run in the same session.**

The defect itself is real and predates this plan. PostgreSQL's estimates are nearly tied
(`6684.93` hash join versus `6903.11` nested loop) and it picks the slower one, because it
prices 1,000 cached primary-key probes as random I/O. The scan side grows linearly with the
table while the nested loop does not, and — the part that makes it serious —
`reapDeletedTuplesBatchSession` is *drained in a loop* by `en-server/app/Maintenance.hs`, so a
backlog of `B` rows costs `B / batchSize` full table scans. The cost is
`table_pages × batches`: quadratic, and the reaper is precisely the thing that runs when the
table is large.

The fix joins back on `ctid`, the physical tuple address, instead of on the primary key:

```text
-- id join (planner's choice)
->  Hash Join  (cost=202.11..6684.93 rows=1000)
      ->  Seq Scan on relation_tuple t  (actual rows=250024)
    Buffers: shared hit=5096      Execution Time: 27.025 ms

-- ctid join (shipped)
->  Nested Loop  (actual rows=1000)
      ->  Index Scan using relation_tuple_deleted_xid_idx  (actual rows=1000)
      ->  Tid Scan on relation_tuple t  (actual rows=1 loops=1000)
    Buffers: shared hit=3061      Execution Time: 2.216 ms
```

Draining the full 50,015-row backlog on the 250,024-row table: **1.330 s → 0.194 s** (51
batches either way). `MATERIALIZED` on the victims CTE and `id IN (subquery)` were both tried
and both still seq-scan — the estimate was never wrong, only the costing of the probes.

`pruneTransactionsBatchStatement` carries the identical shape over `en_transaction`, which
accrues one row per write transaction. Seeded to 250,038 rows it plans the same `Hash Join`
over a full `Seq Scan` (21.4 ms) and takes the same `ctid` fix (1.9 ms). Both were fixed.

Safety of `ctid`: a tuple address is only stable if the tuple cannot move. Both writers that
set `deleted_xid` (`batchTouchReplaceStatement`, `batchDeleteTupleStatement`) restrict their
`UPDATE` to `deleted_xid IS NULL`, so a soft-deleted row is never updated again; `en_transaction`
rows are never updated at all. `VACUUM` cannot recycle a line pointer for a tuple the current
statement's snapshot can still see, and the victim CTE and the `DELETE` run inside one statement
under one snapshot. A racing second reaper deletes the row first and this statement's `Tid Scan`
finds nothing, exactly as the `id` join behaved.

The `ctid` form is self-correcting, not immune: on a small table the planner still hash-joins on
`ctid` (verified on a 6-row table), which is harmless because the scan is cheap, but it does mean
the integration fixture cannot assert the plan shape — the guard is the `EXPLAIN` above against a
populated database, plus the existing correctness assertions in `runMaintenanceBatchScenario`,
which were run once against an injected bug (dropping the horizon predicate) and failed with
`expected: 25 / actual: 26`. Discovered and fixed 2026-07-09.

**`readStartingWithUserStatement` at large fan-in does not sort all matches (the review's
side-note, resolved).** Milestone 1 asked whether the global `ORDER BY id LIMIT` sorts every
match before applying the limit at high subject-key fan-in. At 1,000 subject keys it does
not: the plan is a bounded `top-N heapsort` (36 kB) over a nested loop that probes
`relation_tuple_subject_hist_idx` once per key.

```text
Limit (actual rows=51 loops=1)
  ->  Sort (actual rows=51 loops=1)
        Sort Method: top-N heapsort  Memory: 36kB
        ->  Nested Loop (actual rows=800 loops=1)
              ->  HashAggregate (actual rows=1000 loops=1)
                    ->  Function Scan on unnest (actual rows=1000 loops=1)
              ->  Index Scan using relation_tuple_subject_hist_idx (loops=1000)
    Execution Time: 8.554 ms
```

The heapsort is bounded by the limit, so memory does not grow with the match count. The
nested loop below it *does* materialize every match (800 rows here) before the limit bites,
so the work is linear in total matches rather than in the page size — for a subject set
whose members each hold many grants, that is real but not pathological, and no sort spills.
No fix is warranted; recorded so a future plan need not re-measure. Discovered 2026-07-09.

**The plan's seed script cannot produce the table it describes.** As scripted it sets
`subject_id = 'user-' || (g % 20000)` and `object_id = 'obj-' || (g % 4000)`; since
`4000 | 20000`, the whole identity key is a function of `g % 20000`, so each of the 20,000
identities repeats ~12 times and `ON CONFLICT DO NOTHING` collapses them to one live row.
The result is ~16k live rows, not the 200k the EXPLAIN work needs to make index scans win.
Using `subject_id = 'user-' || g` gives 250,019 rows / 200,006 live / 4,006 objects.
A seed whose row count is an artifact of its own conflict clause would have produced an
empty-fixture EXPLAIN sweep — the exact failure mode the master plan's EP-48 entry warns
about. Discovered 2026-07-09.


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
- Decision: `relation_tuple_created_xid_idx` is KEPT, reserved for the watch/changelog feed
  of docs/plans/53-add-a-watch-changelog-api.md. The mirror entry is recorded in that plan's
  Decision Log. The EXPLAIN sweep confirms it serves no statement today (`idx_scan = 0`
  across a driven workload), so the reservation is the only thing keeping it.
  Rationale: This is the coordination the master plan
  (`docs/masterplans/8-correct-write-path-and-storage-semantics.md`, Integration Points and
  Decision Log) mandates. docs/plans/53 is entirely Not Started, but its Decision Log already
  commits to bounding each changelog arm with `created_xid >= $start_xmin::xid8` precisely so
  this index is load-bearing, and states "this plan is the consumer that keeps it". That is
  the affirmative claim the gate looks for; dropping and re-adding an index on a large table
  is avoidable churn. A `-- reserved …` comment next to the index records the reservation on
  the SQL side. If docs/plans/53 later abandons the xmin-bounded design, it owns the drop.
  Date: 2026-07-09
- Decision: `relation_tuple_subject_live_idx` is dropped despite appearing in a live query
  plan, overriding this plan's Milestone 1 gate ("keep that index").
  Rationale: The gate exists to prevent a plan regression, and encodes the assumption that an
  index the planner *chooses* is an index the planner *needs*. The counterfactual falsifies
  the assumption here: with the index dropped, `relation_tuple_subject_hist_idx` serves the
  same subject-scoped precondition with a byte-identical index condition, equal buffer count,
  and lower measured latency (0.018 ms vs 0.059 ms on a miss; 0.041 ms vs 0.125 ms on a hit).
  Nothing regresses, so the gate's purpose is met. Against that, keeping it costs a 20 MB
  index maintained on every insert and soft-delete: dropping both `*_live_idx` indexes cuts a
  20,000-row insert from 0.573 s to 0.378 s (-34%), while dropping `object_live_idx` alone is
  within measurement noise — the write win exists only if both go. Recovery is a
  `CREATE INDEX CONCURRENTLY` away and loses no data. Escalated to the user before acting.
  Date: 2026-07-09
- Decision: The garbage-collection horizon is NOT cached, reversing this plan's 2026-07-07
  "cache the horizon behind the same TTL" decision. `TtlCache a` is still generalized, and
  `OptimizedRevisionCache` remains its sole instantiation.
  Rationale: That entry's safety argument is inverted. The horizon rises monotonically as
  transactions age out of the GC window, and `validateTokenMetadata` rejects when
  `snapshot.xmax <= horizon`, so a TTL-stale (smaller) horizon rejects *fewer* tokens — it
  honours tokens whose history the reaper destroyed, for up to one TTL. That widens EP-47's
  documented C7 TOCTOU window from request-duration to TTL + request-duration, and does it
  through `EN_OPTIMIZED_REVISION_CACHE_TTL_MS`, a knob that today means only "how stale may a
  revision be". Overloading it to also mean "how long past garbage collection may an expired
  token be honored" is a footgun for any operator tuning read latency. The cache is also
  unnecessary: lazy resolution alone meets the full 1/1/1/2 acceptance table, because the
  horizon fetch vanishes from the token-less modes that dominate the check path. Escalated to
  the user before acting.
  Date: 2026-07-09
- Decision: The maintenance batch statements (`reapDeletedTuplesBatchStatement`,
  `pruneTransactionsBatchStatement`) are fixed here rather than deferred to docs/plans/37, by
  joining the victim CTE back on `ctid` instead of on the primary key.
  Rationale: The master plan's Decision Log binds every batched statement over `relation_tuple`
  to an index-probe plan, and these are batched statements over `relation_tuple`. docs/plans/37
  owns *when* maintenance runs, not the plan shape of statements that already exist. The defect
  is severe rather than cosmetic: the reap session is drained in a loop, so the full-table
  `Seq Scan` in the join-back costs `table_pages × batches` — quadratic, on the code path that
  by definition runs against large tables. Measured on a 250,024-row table with a 50,015-row
  backlog: full drain 1.330 s → 0.194 s; per batch 27.0 ms → 2.2 ms. `ctid` is safe because
  soft-deleted rows are never updated again (both writers restrict to `deleted_xid IS NULL`),
  `en_transaction` rows are never updated, and vacuum cannot recycle a line pointer visible to
  the statement's own snapshot. A mirror entry is recorded in docs/plans/37's Decision Log.
  Date: 2026-07-09
- Decision: `relation_tuple_object_live_idx` is dropped as strictly subsumed, not merely
  unused.
  Rationale: Its key `(object_type, object_id, relation, id)` under `WHERE deleted_xid IS
  NULL` shares its first three columns with `relation_tuple_live_unique` under the same
  predicate, so every object-scoped precondition binds a prefix the unique index already
  covers — often as an Index Only Scan. Its one unique capability, `id` ordering within an
  object key, has no consumer, because the read path expresses visibility as
  `pg_visible_in_snapshot(...)` and can never use a partial index predicated on
  `deleted_xid IS NULL`. `idx_scan` stayed 0 across a driven workload that deliberately
  included an object-scoped precondition.
  Date: 2026-07-09


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Record here: the EXPLAIN index-usage table,
the created_xid keep/drop outcome, and the per-mode fetch counts before/after.

### Milestone 1–2: the EXPLAIN index-usage table

Captured with `EXPLAIN (ANALYZE, BUFFERS)` against the dev database seeded to 250,019 rows
(200,006 live, 50,013 soft-deleted, 4,006 objects) and `ANALYZE`d. Batch statements were
EXPLAINed at **5,000 entries** — five times `EN_MAX_BATCH_SIZE`'s default of 1,000 — per the
master plan's binding rule that a batched statement's cost is argued at production batch and
table sizes. Every statement in `en-postgres/src/En/Postgres/TupleStore.hs` that touches
`relation_tuple` is listed; the three that touch only `en_transaction`
(`anchorTransactionStatement`, `currentSnapshotStatement`, `oldestRetainedXidStatement`) are
out of scope for an index review of `relation_tuple`.

| Statement | Index used (before drop) | Index used (after drop) | Regressed? |
|---|---|---|---|
| `readObjectRelationStatement` | `object_hist_idx` | `object_hist_idx` | no |
| `readStartingWithUserStatement` (16 keys) | `subject_hist_idx` | `subject_hist_idx` | no |
| `readStartingWithUserStatement` (1000 keys) | `subject_hist_idx` | `subject_hist_idx` | no |
| `readAllTuplesStatement` | `pkey` | `pkey` | no |
| `probeTuplesStatement` | `object_hist_idx` | `object_hist_idx` | no |
| `lockMatchingLiveTupleStatement` (full identity) | `live_unique` | `live_unique` | no |
| `matchingLiveTupleExistsStatement` (full identity) | `live_unique` | `live_unique` | no |
| `matchingLiveTupleExistsStatement` (object prefix) | `live_unique` (Index Only) | `live_unique` (Index Only) | no |
| `matchingLiveTupleExistsStatement` (subject-scoped) | **`subject_live_idx`** | `subject_hist_idx` (faster) | no |
| `batchTouchReplaceStatement` (5000) | `live_unique` + `pkey` | `live_unique` + `pkey` | no |
| `batchInsertTupleStatement` (5000) | `live_unique` (arbiter) | `live_unique` (arbiter) | no |
| `batchUnconvergedStatement` (5000) | `live_unique` | `live_unique` | no |
| `batchDeleteTupleStatement` (5000) | `live_unique` + `pkey` | `live_unique` + `pkey` | no |
| `reapDeletedTuplesStatement` | `deleted_xid_idx` | `deleted_xid_idx` | no |
| `reapDeletedTuplesBatchStatement` | `deleted_xid_idx` (+ pkey join) | `deleted_xid_idx` (+ seq-scan join) | no — see Surprises; planner flip caused by autovacuum, not by this drop |

Two `Seq Scan`s survive in the post-drop sweep and are present identically before it: the
`object_type`-only precondition filters, which are `LIMIT 1` / `EXISTS` early-exits touching
2–4 buffers when a match exists. They are not regressions. (When they *miss*, the custom plan
uses `live_unique`; see the generic-plan note in Surprises & Discoveries.)

`pg_stat_user_indexes.idx_scan` deltas across a workload driven through `en-server`
(`just start-and-test` plus a `mustExist` full-identity precondition, a `mustExist`
object-scoped precondition, a `mustNotExist` subject-scoped precondition, and a check):

| Index | idx_scan delta | Verdict |
|---|---|---|
| `relation_tuple_live_unique` | 5 | keep |
| `relation_tuple_subject_hist_idx` | 4 | keep |
| `relation_tuple_pkey` | 3 | keep |
| `relation_tuple_object_hist_idx` | 1 | keep |
| `relation_tuple_subject_live_idx` | **1** | **dropped anyway** — redundant, see Decision Log |
| `relation_tuple_created_xid_idx` | 0 | **kept** — reserved for docs/plans/53 |
| `relation_tuple_deleted_xid_idx` | 0 (26,504 lifetime) | keep — serves the reaper |
| `relation_tuple_object_live_idx` | **0** | **dropped** — dead and subsumed |

**`created_xid` outcome: KEEP.** docs/plans/53-add-a-watch-changelog-api.md is Not Started but
affirmatively claims the index (its window query bounds each arm with
`created_xid >= $start_xmin::xid8` expressly to keep it load-bearing). Mirror entries are
recorded in both plans' Decision Logs, and a `COMMENT ON INDEX` records the reservation in the
live schema.

**Write amplification removed.** 20,000-row insert into the seeded table, median of three
trials: 0.573 s with all indexes → 0.378 s with both `*_live_idx` dropped (−34%); ~36 MB of
index storage reclaimed. Dropping `object_live_idx` alone measured within noise of baseline,
so the win required dropping both — which is what made the `subject_live_idx` counterfactual
worth running rather than deferring to the plan's keep-the-index gate.

### Milestone 3: per-mode store-fetch counts

Enforced by `runConsistencyFetchCountScenario` in `en-postgres/integration-test/Main.hs`,
which interposes on `TupleStore` and tallies `HeadRevision`, `OptimizedRevision` and
`OldestRetainedXid` by name. Each maps to one database session in the interpreter, so an
operation count is a round-trip count. The "before" column is not a citation — it is the
tally the same assertion produced when the pre-refactor eager interpreter was reinstated:
`fromList [("HeadRevision",1),("OldestRetainedXid",1),("OptimizedRevision",1)]` for *every*
mode.

| Mode | Before | After | What it fetches now |
|---|---|---|---|
| `MinimizeLatency` | 3 | **1** | `OptimizedRevision` |
| `FullyConsistent` | 3 | **1** | `HeadRevision` |
| `AtExactSnapshot token` | 3 | **1** | `OldestRetainedXid` |
| `AtLeastAsFresh token` | 3 | **2** | `OldestRetainedXid`, `OptimizedRevision` |

A token-less request now performs no horizon fetch and no token validation, which is the
"token-less requests don't need the GC horizon" half of C3. The revision each mode selects is
unchanged — the suite's existing consistency scenarios (stale-token rejection,
read-your-writes at a token, snapshot repeatability) pass untouched.

Both new assertions were run once against the bug they claim to catch, per the master plan's
standing rule:

- Making `MinimizeLatency` force `getHead` fails the unit test with
  `expected: ["getOptimized"] / actual: ["getHead","getOptimized"]`.
- Restoring the eager three-fetch interpreter fails the integration assertion with
  `expected: fromList [("OptimizedRevision",1)]` against the unconditional three.

### Verification

```text
cabal build all                    exit 0
cabal test all                     exit 0   (all suites PASS)
cabal test en-postgres-revision-tests      exit 0
cabal test en-postgres-integration-tests   exit 0
just run-migrations (2nd run)      "dead live indexes already dropped"
just start-and-test                server smoke test passed: allowed
```

Exit codes were checked directly rather than grepped for `FAIL`, per the master plan's note
that a suite which fails to compile never prints one.

### Gaps

- The horizon cache the plan specified was not built; the reasoning is in Surprises &
  Discoveries and the Decision Log. `TtlCache a` is generalized and ready for it.
- The precondition statements' sargability depends on PostgreSQL preferring a custom plan to
  a generic one. True today by a ~500× cost margin, but nothing in the SQL enforces it.
- The maintenance statements' plan shape cannot be asserted by the integration fixture, whose
  table is too small for the planner to prefer the tid path. It is pinned by the recorded
  `EXPLAIN` against the populated dev database, and by the master plan's standing rule.

### Scope taken beyond the plan

`reapDeletedTuplesBatchStatement` and `pruneTransactionsBatchStatement` were rewritten to join
on `ctid`. This plan's text does not mention them, and the master plan's Vision & Scope puts
"`en_transaction` pruning and reaper scheduling" under
docs/plans/37-schedule-background-maintenance-for-reaping-and-transaction-pruning.md. The fix
was taken here anyway, on three grounds: the master plan's own Decision Log binds *every*
batched statement over `relation_tuple` to an index-probe plan and these are batched statements
over `relation_tuple`; what EP-37 owns is the *scheduling* of maintenance, not the plan shape of
statements that already exist; and the EXPLAIN harness that found the defect was already built
and warm, so verifying the fix cost one command while deferring it would have shipped a known
quadratic drain. The mirror note is recorded in EP-37's Decision Log.


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
