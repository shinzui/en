---
id: 37
slug: schedule-background-maintenance-for-reaping-and-transaction-pruning
title: "Schedule background maintenance for reaping and transaction pruning"
kind: exec-plan
created_at: 2026-07-07T15:24:43Z
master_plan: "docs/masterplans/6-production-harden-the-en-service.md"
---

# Schedule background maintenance for reaping and transaction pruning

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

en's storage design never physically deletes on the write path: deleting a relationship
tuple sets `deleted_xid` on its row (soft delete), and every write inserts one bookkeeping
row into `en_transaction`. Physical cleanup exists as a one-shot operation —
`reapDeletedTuplesSession` in `en-postgres/src/En/Postgres/TupleStore.hs` — but *nothing
ever runs it*: no code in `en-server` calls it, so soft-deleted rows accumulate forever
(finding C4 of `docs/reviews/2026-07-07-architecture-performance-review.md`). And nothing
at all prunes `en_transaction`, whose rows are scanned by `oldestRetainedXidStatement`
(a `min(xid)` over a `created_at` range with no supporting index — the primary key is on
`xid` only) on *every* consistency resolution, i.e. on every read. Read latency therefore
degrades linearly with lifetime write count (finding C2, HIGH). When the reaper *is*
invoked, it is a single unbounded `DELETE` that holds row locks and generates WAL
proportional to total garbage — an operational hazard on a large backlog.

After this change: a codd migration adds a btree index on `en_transaction (created_at,
xid)` so the per-read horizon query is served by an index-only scan; the reaper deletes
in bounded batches (default 1000 rows per statement) instead of one unbounded `DELETE`;
the same maintenance pass prunes `en_transaction` rows behind the garbage-collection
horizon; and `en-server` runs this pass on a configurable interval in a background
thread that logs what it did and shuts down cleanly with the server. An operator can
watch a soft-deleted backlog and the transaction table shrink on schedule, with row
counts as proof. This plan is child EP-37 of
`docs/masterplans/6-production-harden-the-en-service.md`.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1 **cancelled** (2026-07-08): the `(created_at, xid)` index is dead weight.
  PostgreSQL rewrites `min(xid)` into a `Limit 1` over the `xid` primary key and never
  chooses the composite index, at any selectivity. EXPLAIN evidence in Surprises &
  Discoveries; decision recorded in the Decision Log. No migration, no Justfile guard.
  **Pruning (M3) is the fix for C2**, and it is verified as such.
- [x] M2 (2026-07-08): batched sessions `reapDeletedTuplesBatchSession` and
  `pruneTransactionsBatchSession` added to `en-postgres/src/En/Postgres/TupleStore.hs`
  and exported; integration coverage extended and mutation-checked.
- [x] M3 (2026-07-08): maintenance loop in `en-server/app/Maintenance.hs`; env vars
  `EN_MAINTENANCE_INTERVAL_SECONDS` / `EN_MAINTENANCE_BATCH_SIZE`; per-pass log line;
  clean-shutdown interaction verified (0.03 s to exit with a pass mid-flight).
- [x] M4 (2026-07-08): end-to-end validation with a tiny GC window — backlog created,
  reaped, and pruned on schedule; transcript recorded in Outcomes.
- [x] Docs: maintenance section added to `docs/user/service-and-operations.md`.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **The horizon query was never a `Seq Scan`, and the planned index never fixes it.**
  M1 predicted `Seq Scan on en_transaction` before the index and an `Index Only Scan`
  after. Neither happens. PostgreSQL applies its MIN/MAX rewrite: `min(xid)` becomes a
  `Limit 1` over an ascending scan of the `xid` primary key, with `created_at` as a
  filter. Its cost is the number of rows it must *skip* — exactly the rows behind the
  horizon. Seeded with 50,000 out-of-window rows and 100 in-window (xid correlated with
  `created_at`, as real writes are):

  ```text
  Result (actual time=4.717..4.719 rows=1 loops=1)
    Buffers: shared hit=606
    InitPlan 1
      ->  Limit (actual time=4.704..4.705 rows=1 loops=1)
            ->  Index Scan using en_transaction_pkey on en_transaction
                  Filter: (created_at >= (now() - '24:00:00'::interval))
                  Rows Removed by Filter: 50000
  ```

  Creating `en_transaction_created_at_xid_idx` changed **nothing** — byte-identical plan,
  same 606 buffers. Forcing it (`SET enable_indexscan=off; SET enable_seqscan=off`) does
  produce a bitmap scan on it at 4 buffers / 0.062 ms, but the planner *estimates* that
  path at cost 487.96 against 5.80 for the primary-key path: an 84× misestimate, because
  the `Limit 1` cost model assumes matching rows are spread uniformly through `xid` order
  when in fact they are all at the far end. The planner still chose the primary key with
  only **one** in-window row among 50,001 — the worst possible selectivity. It is never
  chosen.

- **Pruning alone fixes finding C2, and does so better than the index would have.** With
  the backlog drained, every remaining row is in-window, so the `Limit 1` stops at the
  first row it reads:

  ```text
  Result (actual time=0.019..0.021 rows=1 loops=1)
    Buffers: shared hit=2
      ->  Limit  ->  Index Scan using en_transaction_pkey   (no rows removed by filter)
  ```

  2 buffers, 0.036–0.046 ms, **identical whether the composite index exists or not**.
  Better still, this is `O(1)` in the retained window, whereas forcing the composite
  index would make every read scan all in-window index entries — `O(window)`, worse at
  scale. The index would have cost one entry per write for a plan never chosen and, if
  forced, a slower steady state. It was cancelled; see the Decision Log.

- **`en_transaction` can legitimately drain to zero, and this does not move the horizon.**
  With `EN_GC_WINDOW='1 second'` and no writes in the last second, `min(xid)` over the
  window is `NULL`, `coalesce` falls back to `pg_snapshot_xmin(pg_current_snapshot())`,
  and the pruner deletes every committed row. Observed: `en_transaction` 53 → 0. This is
  safe and, importantly, *not a change in behavior*: the horizon is computed only from
  in-window rows, so removing out-of-window rows cannot alter it. The `coalesce` fallback
  yields the same value with the table full or empty. Documented for operators, who will
  otherwise find an empty table alarming.

- **Cancellation is prompt, not deferred to the end of a pass.** With a 60,000-row backlog
  and `EN_MAINTENANCE_BATCH_SIZE=1`, `SIGTERM` arrived with 38,868 rows still to go and the
  process exited **0.03 s** later with status 0 and no exception output. The 21,490 rows
  already deleted stayed deleted, and the next process's first pass removed the remaining
  38,510 in 40 batches. This is the property that makes batching worth its round trips.

- **`try @SomeException` around the pass would have swallowed cancellation.**
  `Control.Concurrent.Async.cancel` throws `AsyncCancelled`, whose `Exception` instance
  routes through `asyncExceptionToException`. Catching and logging it would leave the
  maintenance thread looping after `withAsync` believed it dead, so the server would hang
  on shutdown. `runMaintenanceLoop` re-throws anything that is a `SomeAsyncException` and
  logs only synchronous failures. **Any sibling plan adding a background loop must do the
  same.**

- **A batch size of 1 consumes one transaction id per row.** The `horizon` in consecutive
  log lines jumped from 840 to 5840 while reaping 5,000 rows with `EN_MAINTENANCE_BATCH_SIZE=1`.
  Harmless at `xid8`'s 64-bit width and irrelevant at the default batch of 1000, but it is
  a reason not to set the batch size very low on a large backlog.

- **`Statement.preparable` takes `Text`, not `ByteString`.** A small thing, but it cost a
  compile cycle and a spurious `bytestring` dependency on the integration test suite.


## Decision Log

Record every decision made while working on the plan.

- Decision: Index `en_transaction` with a plain btree on `(created_at, xid)`, not BRIN.
  Rationale: The query to serve is `SELECT coalesce(min(xid), …) FROM en_transaction
  WHERE created_at >= now() - $1::interval` (`oldestRetainedXidStatement`,
  `en-postgres/src/En/Postgres/TupleStore.hs`). A BRIN index on `created_at` looks
  attractive because insertion order correlates with `created_at`, and BRIN is tiny —
  but BRIN cannot produce index-only scans (it only narrows heap block ranges, so
  `min(xid)` still reads every retained heap row), and this very plan breaks BRIN's
  physical-correlation assumption over time: batched pruning frees space early in the
  table that PostgreSQL refills with new rows, degrading block ranges. The btree
  composite `(created_at, xid)` serves the range predicate on its leading column and
  lets the `min(xid)` aggregate complete from index tuples alone (index-only scan once
  the visibility map settles). After pruning is live the table holds roughly one GC
  window of rows, so the btree stays small; its write amplification (one index entry
  per write transaction) is the acceptable price for turning every read's helper query
  into an index scan.
  Date: 2026-07-07
  **Reversed 2026-07-08 — no index is created at all.** The reasoning above compares a
  btree against a BRIN and never questions whether the planner would use *either*. It
  does not. PostgreSQL rewrites `min(xid)` into a `Limit 1` over the `xid` primary key
  and prefers it at every selectivity tested, including one in-window row among 50,001.
  Measurements are in Surprises & Discoveries. The premise that the aggregate "can
  complete from index tuples alone" is true but irrelevant, because that plan is never
  chosen; and forcing it would make each read scan every in-window index entry —
  `O(window)` rather than the `O(1)` the primary-key path delivers once pruning keeps
  the backlog empty. Since `min(xid)`'s cost is precisely the count of rows behind the
  horizon, **pruning is the fix for C2, and the index would have added one entry per
  write for nothing.** M1 is cancelled; the migration and Justfile guard were deleted
  before landing. If a future query filters `en_transaction` by `created_at` without a
  `min`/`max` aggregate (the watch API is the candidate), reconsider the index then, on
  that query's evidence.
- Decision: Batch both deletes with a `LIMIT`-ed CTE loop (delete up to N, repeat until
  a short batch), N default 1000, statements committing between batches.
  Rationale: One unbounded `DELETE` holds locks on every doomed row for the statement's
  full duration and emits its WAL in one burst; C4 calls this out. Small transactions
  keep vacuum and replication happy and make the loop safely interruptible anywhere —
  killed mid-pass, the work already committed stays done and the next pass continues.
  `relation_tuple` batches select victims by `id` (PK); `en_transaction` batches by
  `xid` (PK).
  Date: 2026-07-07
- Decision: Prune `en_transaction` rows strictly *behind* the same horizon the reaper
  and token validation already share: delete rows with `xid < oldestRetainedXid`, where
  `oldestRetainedXid` is computed by the existing statement from `EN_GC_WINDOW`.
  Rationale: `oldestRetainedXid` is the boundary below which consistency tokens are
  already rejected (`validateTokenMetadata` in `en-postgres/src/En/Postgres/Revision.hs`
  fails tokens whose snapshot `xmax <= oldestRetainedXid`), so rows below it can never
  again influence a token decision or the `min(xid)` result (which by construction is
  `>= oldestRetainedXid`). Pruning by `xid <` rather than re-deriving from `created_at`
  guarantees the reaper, the pruner, and token validation share one horizon and can
  never disagree. The `coalesce(min(xid), pg_snapshot_xmin(pg_current_snapshot()))`
  fallback in the existing statement keeps the horizon sane even if pruning ever
  empties the table.
  Date: 2026-07-07
- Decision: Run maintenance inside `en-server` as a background thread
  (`Control.Concurrent.Async.withAsync` wrapping the Warp serve call), not as a
  separate cron binary.
  Rationale: Restated from the master plan's Decision Log: both C2 and C4 are fixed by
  one scheduled job inside en-server plus one migration; a separate binary would need
  its own config/deploy story for a loop of two statements. `withAsync` ties the
  thread's lifetime to the server: when Warp returns (EP-36's graceful shutdown) or
  throws, the maintenance thread is cancelled — and because each batch is its own
  short transaction, cancellation is safe at any point. The loop catches and logs all
  synchronous exceptions per iteration so one failed pass (e.g. PostgreSQL restarting)
  never kills the schedule.
  Date: 2026-07-07
- Decision: The maintenance loop issues its SQL through the `Database` effect
  (`En.Postgres.Database.runSession`) via the same runner the request path uses, not a
  dedicated raw `Connection`.
  Rationale: Master-plan integration point, restated: EP-34
  (`docs/plans/34-pool-database-connections-in-en-server.md`) owns the runner; consumers
  call through the effect. With the pool this gives the loop its own connection per
  session automatically. If this plan lands *before* EP-34, the loop would share the
  single global connection with request traffic and serialize against it — in that
  order of landing, the loop must acquire its own dedicated `Connection` at startup and
  switch to the pool when EP-34 lands (the master plan's stated fallback; the code
  difference is which runner wraps `runSession`).
  Date: 2026-07-07
- Decision: Defaults: interval 600 seconds, batch size 1000, enabled by default;
  `EN_MAINTENANCE_INTERVAL_SECONDS=0` disables the loop.
  Rationale: C4's whole point is that cleanup never ran; defaulting to off would
  recreate the finding for every operator who misses a variable. Ten minutes keeps the
  steady-state backlog tiny at single-org write rates while being far coarser than any
  request; batch 1000 matches the storage layer's existing page-size scale. `0` as an
  explicit off-switch supports debugging and one-shot environments (and the
  conformance/demo flows, which never write enough to matter).
  Date: 2026-07-07

- Decision: The maintenance loop re-throws asynchronous exceptions and logs only
  synchronous ones, rather than wrapping each pass in a bare `try @SomeException`.
  Rationale: The plan's M3 says "one pass wrapped in `try @SomeException` — a failed pass
  logs and continues". Taken literally that catches `AsyncCancelled`, which is exactly how
  `withAsync` stops the thread on shutdown; the loop would log the cancellation, sleep, and
  keep running, and the server would hang. `AsyncCancelled`'s `Exception` instance routes
  through `asyncExceptionToException`, so `fromException @SomeAsyncException` distinguishes
  it from a database failure. Recorded alternative: depend on `safe-exceptions` for
  `tryAny`, rejected as a dependency for six lines.
  Date: 2026-07-08

- Decision: `runMaintenanceLoop` returns immediately when the interval is zero; `Main.hs`
  logs `Background maintenance: disabled` at startup rather than the loop logging
  `maintenance: disabled`.
  Rationale: The plan asked for the latter, but every other subsystem announces itself in
  the same startup block (`Rate limit: …`, `Decision cache: …`), and an operator reads that
  block to learn how the process is configured. A lone line from a thread that then exits is
  the wrong shape. The observable requirement — startup says maintenance is off, and counts
  never change — is met.
  Date: 2026-07-08

- Decision: Prove the batched sessions with a scenario that seeds a synthetic backlog and a
  literal horizon (`1000`), rather than deriving the horizon from real writes.
  Rationale: The interesting boundary is `xid < horizon` versus `xid = horizon`, and a
  derived horizon cannot place a row exactly on it. The scenario seeds 25 reapable tuples,
  one deleted at exactly the horizon, and one live tuple; likewise 25 prunable transactions
  plus two at or after the horizon. The assertions were mutation-checked (expected 25 → 26
  fails with the right diagnostic) to prove they are not vacuous.
  Date: 2026-07-08


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

Completed 2026-07-08 in two commits (batched sessions; the scheduled loop plus docs).
Four milestones planned, three landed: **M1 was cancelled on evidence** — see the Decision
Log — and its goal, an efficient horizon query, is delivered by M3's pruning instead.

**Against the original purpose.** Soft-deleted tuples and `en_transaction` rows are now
removed on a schedule, in bounded batches, behind a horizon shared with token validation.
The reaper is called for the first time. The horizon query, which every read pays for,
went from 606 buffers / 4.7 ms against a 50,000-row backlog to 2 buffers / 0.04 ms once
drained. An operator can watch both counts shrink, with proof below.

### Validation transcript

Reap, prune, and steady state (M3/M4), with `EN_GC_WINDOW='1 second'`,
`EN_MAINTENANCE_INTERVAL_SECONDS=5`, `EN_MAINTENANCE_BATCH_SIZE=100`, after `just test-server`
created garbage:

```text
Background maintenance: enabled, intervalSeconds=5, batchSize=100

maintenance: horizon=836 reaped=23 pruned=53 batches=2
maintenance: horizon=838 reaped=0 pruned=0 batches=2
maintenance: horizon=839 reaped=0 pruned=0 batches=2

soft_deleted=23 -> 0
en_transaction=53 -> 0
live=1                       # the live tuple is untouched
```

Batching and bounded work (M2), from the integration suite: no call of either session
removes more than its batch, drained counts sum to the backlog (25 in batches of 10 →
`[10,10,5]`), a drained backlog returns `0`, and rows *at* the horizon survive
(`xid = 1000` is not `< 1000`). Mutation-checked: changing the expected sum to 26 fails.

Interruption mid-pass and resumption (acceptance 5). 60,000-row backlog,
`EN_MAINTENANCE_BATCH_SIZE=1` so a pass takes thousands of round trips:

```text
backlog before        = 60000
backlog mid-pass      = 38868      # pass demonstrably still running
EXIT_CODE=0  shutdown_seconds=0.03 # SIGTERM; cancellation is immediate
backlog after SIGTERM = 38510      # 21490 committed deletions stayed done
```

Restarting with `EN_MAINTENANCE_BATCH_SIZE=1000`:

```text
maintenance: horizon=27332 reaped=38510 pruned=0 batches=40
maintenance: horizon=27371 reaped=0 pruned=0 batches=2
backlog = 0     live tuples = 1
```

Safety under the default window (acceptance 4). `EN_GC_WINDOW` unset (24 hours),
maintenance every 2 s, `just test-server` three times:

```text
server smoke test passed: allowed     (x3)
maintenance: horizon=27371 reaped=0 pruned=0 batches=2   (x3)
en_transaction retained = 6      soft-deleted retained = 3
```

Nothing inside the window is touched, and every consistency token resolves. Disabled
(`EN_MAINTENANCE_INTERVAL_SECONDS=0`) with a 1-second window — where an enabled loop would
have wiped both tables:

```text
Background maintenance: disabled
maintenance pass lines: 0
en_transaction: 6 -> 6   soft_deleted: 3 -> 3
```

Bad configuration fails at startup, before the port is bound:

```text
user error (Invalid EN_MAINTENANCE_BATCH_SIZE: expected a positive integer)
user error (Invalid EN_MAINTENANCE_INTERVAL_SECONDS: expected a non-negative integer)
```

Regressions (acceptance 6): `cabal build all` clean; `cabal test en-core`,
`cabal test en-postgres` (both suites), and `cabal test en-servant` PASS;
`just start-and-test` passes against the process-compose server, which logs
`Background maintenance: enabled, intervalSeconds=600, batchSize=1000`.

### Gaps

- **No metric for maintenance.** EP-36 added `/metrics`, and reaped/pruned counts belong
  there — an operator should be able to alert on "reaped equals batch size every pass",
  which means the backlog is outgrowing the schedule. Today that signal exists only in the
  log line. Deliberately not added: it would need a counter store shared between
  `Maintenance.hs` and `Metrics.hs`, which is a small design question and not this plan's
  purpose.
- **The pass is serial and single-threaded.** Reap fully drains before prune begins. For a
  very large first pass on an old database this means the transaction table is not pruned
  until the tuple backlog is gone. Both are bounded work per batch, so the server stays
  responsive; only the ordering is arbitrary.
- **`ReapDeletedTuples` on the `TupleStore` effect remains unbatched**, as the plan
  intended. Embedded consumers calling it against a large backlog get the original
  one-unbounded-`DELETE` behavior. Its haddock now points at the batched session.
- **A pass that fails is retried only at the next interval.** With a 600-second default and
  a PostgreSQL restart, up to ten minutes of maintenance is skipped. Harmless — the next
  pass does the accumulated work — but it means the log can go quiet for an interval after
  a database blip.

### Lessons

The plan's most confident section was its most wrong. Its Decision Log spends a paragraph
adjudicating btree versus BRIN — correlation, index-only scans, block-range degradation
under pruning — and every word of it is sound in isolation. It simply never asked whether
the planner would choose an index at all. `EXPLAIN (ANALYZE, BUFFERS)` answered in one
command what the argument could not. A plan that names an expected query plan should be
read as a hypothesis to test, not a specification to implement; the acceptance criterion
that said "the EXPLAIN transcript flips from `Seq Scan` to `Index Only Scan`" is what
caught it, because it was falsifiable.

Second, the seed data matters as much as the query. The first measurement showed the index
being ignored *and* the primary-key path being fast — because the synthetic rows had
larger `xid` for older `created_at`, the opposite of how real writes land. Anti-correlated
data made a pathological plan look healthy. Correlating them reproduced the finding.


## Context and Orientation

en is a Haskell workspace at `/Users/shinzui/Keikaku/bokuno/en` (cabal, GHC 9.12.4).
The pieces this plan touches:

Storage model. The SQL schema lives in
`en-migrations/db/migrations/20260623044157_create-relation-tuples.sql` (plus an
index-only follow-up migration). Two tables matter here. `relation_tuple` holds one row
per relationship grant with `created_xid xid8` and `deleted_xid xid8 NULL` — an `xid8`
is PostgreSQL's 64-bit, epoch-qualified transaction id, and "deleted" means
`deleted_xid` is set (soft delete) so historical reads at older snapshots still see the
row. `en_transaction` gets one row per write transaction (`xid xid8 PRIMARY KEY`,
`snapshot pg_snapshot`, `schema_hash text`, `created_at timestamptz DEFAULT now()`); it
anchors consistency tokens. The **GC horizon** (garbage-collection horizon) is the
oldest transaction id still protected by the configured retention window
(`EN_GC_WINDOW`, default `24 hours`, an arbitrary PostgreSQL interval string): the
statement `oldestRetainedXidStatement` (in
`en-postgres/src/En/Postgres/TupleStore.hs`, around lines 290–299) computes it as
`coalesce(min(xid), pg_snapshot_xmin(pg_current_snapshot()))` over
`en_transaction WHERE created_at >= now() - $1::interval`. Token validation
(`validateTokenMetadata`, `en-postgres/src/En/Postgres/Revision.hs`) rejects tokens
older than this horizon, and the reaper takes it as its safety boundary — a tuple whose
`deleted_xid` is *older* than the horizon can no longer be seen by any token that
validates, so its row may be physically deleted. `reapDeletedTuplesStatement` (same
file, lines ~301–314) is today one `DELETE … WHERE deleted_xid IS NOT NULL AND
deleted_xid < $1::xid8` returning a count. The partial index
`relation_tuple_deleted_xid_idx ON relation_tuple (deleted_xid) WHERE deleted_xid IS
NOT NULL` (base migration) already serves the reaper's predicate.

Effects and wiring. SQL runs through hasql `Session`s dispatched by the `Database`
effect (`en-postgres/src/En/Postgres/Database.hs`, `runSession`). The engine-facing
`TupleStore` effect (`en-core/src/En/Effect/TupleStore.hs`) has `OldestRetainedXid` and
`ReapDeletedTuples` operations, interpreted for PostgreSQL in
`En.Postgres.TupleStore`. `en-server/app/Main.hs` builds
`runAppIO :: Eff AppEffects a -> IO (Either EnError a)` and ends in the Warp serve
call; nothing in it references reaping (that absence is finding C4). The `Justfile`
recipe `make-migration name` creates a timestamped empty file under
`en-migrations/db/migrations/`, and `run-migrations` applies each known migration with
a `to_regclass`-guarded `psql` invocation — the migrations are codd-*formatted* (plain
SQL, timestamped filenames) but dev applies them with `psql`; this plan follows that
established pattern and adds its own guard block. Dev database: `just process-up`,
env `PG_CONNECTION_STRING`/`EN_DATABASE_URL` from the dev shell.

Cross-plan integration, restated from
`docs/masterplans/6-production-harden-the-en-service.md`: this plan and EP-38 each add
their own codd migration file and must not edit the other's (timestamped filenames
prevent collisions). The maintenance thread must interact correctly with EP-36's
graceful shutdown (Warp's `runSettings` returning is what triggers `withAsync`
cancellation here). Cross-master-plan: the watch/changelog API
(`docs/plans/53-add-a-watch-changelog-api.md`) reads history from these same tables and
must bound its cursor recovery by the same GC horizon this plan prunes to — a reason the
horizon derivation stays single-sourced in `oldestRetainedXidStatement`.


## Plan of Work

Four milestones: the index (pure SQL, immediately measurable), the batched sessions
(library), the scheduled thread (server wiring), and an end-to-end proof with a shrunken
GC window.


### Milestone 1: Index the horizon query

Scope: one migration plus its dev-apply guard; the horizon query flips from a
sequential scan to an index-only scan.

Create the migration (from the repository root):

```bash
just make-migration en-transaction-horizon-index
```

Edit the created file `en-migrations/db/migrations/<timestamp>_en-transaction-horizon-index.sql`:

```sql
CREATE INDEX en_transaction_created_at_xid_idx
  ON en_transaction (created_at, xid);
```

(Plain `CREATE INDEX`, not `CONCURRENTLY`: codd runs migrations transactionally and
`CONCURRENTLY` cannot run in a transaction; existing deployments of en are dev-scale,
and the table is small once pruning exists. Note this trade-off in the migration file
as a comment for operators with large existing tables.)

Add a guard block to `run-migrations` in `Justfile`, following the two existing blocks
verbatim in style:

```bash
@if [ "$(psql "$PG_CONNECTION_STRING" -tAc "SELECT to_regclass('public.en_transaction_created_at_xid_idx') IS NOT NULL")" = "f" ]; then \
    psql "$PG_CONNECTION_STRING" -v ON_ERROR_STOP=1 -f en-migrations/db/migrations/<timestamp>_en-transaction-horizon-index.sql; \
  else \
    echo "en_transaction horizon index already applied"; \
  fi
```

Acceptance: with the dev database seeded (write a few tuples via `just test-server` or
psql inserts), `EXPLAIN` shows the flip — see Concrete Steps for the exact command and
expected plans (`Seq Scan on en_transaction` before, `Index Only Scan using
en_transaction_created_at_xid_idx` after).


### Milestone 2: Batched reap and prune sessions

Scope: `en-postgres` gains bounded-work maintenance primitives. At the end,
`En.Postgres.TupleStore` exports two new sessions and keeps the existing ones.

In `en-postgres/src/En/Postgres/TupleStore.hs`, add and export:

```haskell
-- | Physically delete up to @batch@ soft-deleted tuples whose delete is behind
-- @horizon@. Returns the number deleted; callers loop until a short batch.
reapDeletedTuplesBatchSession :: Word64 -> Int -> Session Int64

-- | Delete up to @batch@ transaction-log rows behind @horizon@ (the same value
-- token validation rejects below). Returns the number deleted.
pruneTransactionsBatchSession :: Word64 -> Int -> Session Int64
```

with statements shaped like (parameter encoding follows the existing
`reapDeletedTuplesStatement`, which passes the xid as text and casts):

```sql
-- reap batch
WITH victims AS (
  SELECT id FROM relation_tuple
  WHERE deleted_xid IS NOT NULL
    AND deleted_xid < $1::xid8
  LIMIT $2
)
DELETE FROM relation_tuple t USING victims v WHERE t.id = v.id
RETURNING t.id
-- wrapped as: WITH reaped AS (…) SELECT count(*) FROM reaped

-- prune batch
WITH victims AS (
  SELECT xid FROM en_transaction
  WHERE xid < $1::xid8
  LIMIT $2
)
DELETE FROM en_transaction t USING victims v WHERE t.xid = v.xid
RETURNING t.xid
-- wrapped as: WITH pruned AS (…) SELECT count(*) FROM pruned
```

Keep `reapDeletedTuplesSession` (unbounded) exported for compatibility with the
integration test, but point its haddock at the batched variant. Do not change the
`TupleStore` effect's `ReapDeletedTuples` operation — the in-memory interpreters
(`en-core/src/En/Conformance/Kikan.hs`, `en-core/test/Main.hs`) implement it and have
no batching concept; the server-side loop composes batches itself (next milestone), and
the effect op remains the embedded-consumer surface.

Extend `en-postgres/integration-test/Main.hs` (runs against an ephemeral PostgreSQL;
see that file's harness): after the existing reap scenario, create > batch-size
soft-deleted rows, run `reapDeletedTuplesBatchSession horizon 10` repeatedly, and
assert each call returns at most 10, the sum equals the backlog, and a final call
returns 0; mirror the same shape for `pruneTransactionsBatchSession`, asserting rows at
or above the horizon survive.

Acceptance: `cabal build en-postgres` passes; `cabal test en-postgres` passes with the
new scenarios (the integration suite is the `en-postgres-integration-tests` test-suite
in `en-postgres/en-postgres.cabal`; it provisions its own ephemeral PostgreSQL, so no
dev database is needed).


### Milestone 3: The scheduled maintenance thread

Scope: `en-server` runs the pass on an interval. At the end, a new module
`en-server/app/Maintenance.hs` (under `other-modules` in `en-server/en-server.cabal`;
add `async` to `build-depends`) exports:

```haskell
data MaintenanceConfig = MaintenanceConfig
    { intervalSeconds :: !Int   -- 0 disables
    , batchSize :: !Int
    }

loadMaintenanceConfig :: IO MaintenanceConfig
runMaintenanceLoop ::
    MaintenanceConfig ->
    (forall a. Eff AppEffects a -> IO (Either EnError a)) ->  -- runAppIO from Main
    IO ()
```

`loadMaintenanceConfig` reads `EN_MAINTENANCE_INTERVAL_SECONDS` (default 600) and
`EN_MAINTENANCE_BATCH_SIZE` (default 1000, must be >= 1) with the same fail-fast
parsing style `Main.hs` already uses. `runMaintenanceLoop` is `forever` over: sleep the
interval (`threadDelay`), then one pass wrapped in `try @SomeException` — a failed pass
logs and continues. One pass:

1. Fetch the horizon through the effect: `runAppIO (TupleStore.oldestRetainedXid)`
   (the `TupleStore` effect operation — it runs `oldestRetainedXidStatement` with the
   configured `EN_GC_WINDOW`, so the loop shares the exact horizon token validation
   uses).
2. Reap loop: `runAppIO (runSession (reapDeletedTuplesBatchSession horizon batchSize))`
   until a batch returns `< batchSize` (each iteration is its own session/transaction,
   so locks release between batches).
3. Prune loop: same shape with `pruneTransactionsBatchSession`.
4. Log one line:
   `Text.putStrLn ("maintenance: horizon=" <> … <> " reaped=" <> … <> " pruned=" <> … <> " batches=" <> …)`.

In `Main.hs`, wrap the serve call:

```haskell
withAsync (runMaintenanceLoop maintenanceConfig runAppIO) \_maintenance ->
    Warp.run port wrappedApp   -- or Warp.runSettings once EP-36 lands
```

`withAsync` cancels the loop when the serve call returns (EP-36's graceful shutdown) or
throws; because every batch is a short committed transaction, cancellation mid-pass
loses nothing — the next server start resumes where the counts left off. When
`intervalSeconds == 0`, log `maintenance: disabled` and return immediately instead of
looping. Log the active config at startup alongside the existing cache lines.

Ordering note (master plan): if EP-34 has landed, `runAppIO` runs sessions on the pool
and the loop never contends with request traffic for a connection; if it has not, the
loop shares the single connection — acceptable for dev but serialize-y, so in that
landing order acquire a dedicated `Connection` in `Main.hs` for a second
`runMaintenanceIO` runner and note it in this plan's Surprises & Discoveries when done.

Acceptance: server startup logs the maintenance config; with
`EN_MAINTENANCE_INTERVAL_SECONDS=5`, a `maintenance: …` line appears every ~5 seconds;
Ctrl-C / SIGTERM exits promptly with no hang and no exception spew from the cancelled
thread.


### Milestone 4: End-to-end proof with a shrunken GC window

Scope: validation only — demonstrate rows actually disappearing on schedule, using a
tiny `EN_GC_WINDOW` so the horizon advances within seconds. Commands and expected
output are in Concrete Steps; capture the real transcript into Outcomes. Warning to
state in the ops doc: shrinking `EN_GC_WINDOW` also shortens consistency-token
validity — the 1-second window is a test device only.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/en` in the nix dev shell.

Migration and EXPLAIN (M1):

```bash
just process-up
just run-migrations
# seed some transactions
just start-and-test
# measure
psql "$PG_CONNECTION_STRING" -c "EXPLAIN SELECT coalesce(min(xid), pg_snapshot_xmin(pg_current_snapshot()))::text::bigint FROM en_transaction WHERE created_at >= now() - '24 hours'::interval;"
```

Expected before the migration (guard block commented out or on a fresh clone at the
previous migration set):

```text
Aggregate  (…)
  ->  Seq Scan on en_transaction  (…)
        Filter: (created_at >= (now() - '24:00:00'::interval))
```

Expected after `just run-migrations` applies the new file:

```text
Aggregate  (…)
  ->  Index Only Scan using en_transaction_created_at_xid_idx on en_transaction  (…)
        Index Cond: (created_at >= (now() - '24:00:00'::interval))
```

(Planner wording varies with row counts; the acceptance point is the index name
appearing instead of `Seq Scan` once the table has enough rows to matter — seed a few
hundred via a psql `INSERT … SELECT` over `generate_series` if the planner prefers a
seq scan on a nearly-empty table, and record what you used.)

Library builds and tests (M2):

```bash
cabal build en-postgres
cabal test en-postgres
```

Expected: both succeed; the integration suite prints the new batched-reap/prune
assertions passing.

Scheduled loop end to end (M3/M4). Terminal 1:

```bash
EN_DATABASE_URL="$PG_CONNECTION_STRING" \
EN_GC_WINDOW='1 second' \
EN_MAINTENANCE_INTERVAL_SECONDS=5 \
EN_MAINTENANCE_BATCH_SIZE=100 \
  cabal run en-server
```

Terminal 2 — create garbage, then watch it disappear:

```bash
just test-server         # writes, checks, and deletes tuples -> soft-deleted rows + transactions
psql "$PG_CONNECTION_STRING" -tAc "SELECT count(*) FROM relation_tuple WHERE deleted_xid IS NOT NULL"
psql "$PG_CONNECTION_STRING" -tAc "SELECT count(*) FROM en_transaction"
sleep 12                 # > one interval past the 1-second window
psql "$PG_CONNECTION_STRING" -tAc "SELECT count(*) FROM relation_tuple WHERE deleted_xid IS NOT NULL"
psql "$PG_CONNECTION_STRING" -tAc "SELECT count(*) FROM en_transaction"
```

Expected transcript shape in terminal 2 (exact counts depend on the smoke test's
writes):

```text
1
3
0
1
```

— soft-deleted tuples drop to 0, and `en_transaction` drops to at most the rows younger
than the window (the most recent write stays). Terminal 1 meanwhile logs lines like:

```text
maintenance: horizon=1234 reaped=1 pruned=2 batches=2
```

Shutdown interaction: press Ctrl-C in terminal 1; the process exits without hanging on
the maintenance thread.


## Validation and Acceptance

Acceptance as observable behavior:

1. Index: the EXPLAIN transcript flips from `Seq Scan on en_transaction` to
   `Index Only Scan using en_transaction_created_at_xid_idx` for the horizon query;
   `just run-migrations` is idempotent (second run prints
   `en_transaction horizon index already applied`).
2. Batching: integration tests prove no single call of either batch session removes
   more than its batch size, sums equal backlogs, rows at/after the horizon survive,
   and a drained backlog returns 0.
3. Scheduling: with a 5-second interval, `maintenance:` log lines appear on schedule;
   the M4 psql counts show soft-deleted `relation_tuple` rows reaching 0 and
   `en_transaction` shrinking to the retained window, with the server untouched
   between measurements.
4. Safety: consistency tokens minted *within* the window keep validating while
   maintenance runs (`just test-server` passes repeatedly under a normal `24 hours`
   window with the loop enabled); with the loop disabled
   (`EN_MAINTENANCE_INTERVAL_SECONDS=0`), startup logs `maintenance: disabled` and
   counts never change.
5. Shutdown: SIGTERM/Ctrl-C during an active pass exits cleanly; a following restart's
   first pass completes the remaining work (run M4 twice, killing mid-pass once).
6. Regressions: `cabal build all`, `cabal test en-core`, `cabal test en-postgres`,
   `just start-and-test` all pass.


## Idempotence and Recovery

The migration is guarded (`to_regclass`) in dev and content-addressed by filename for
codd — reapplying is a no-op; if it must be rolled back,
`DROP INDEX en_transaction_created_at_xid_idx` is safe (the query reverts to a seq
scan; no data is touched). Every maintenance batch is an independent committed
transaction deleting only rows provably invisible to any valid consistency token
(strictly behind the shared GC horizon), so the pass is idempotent by construction:
re-running deletes nothing new, and interruption at any batch boundary or mid-statement
(statement-level atomicity) leaves a consistent database. The loop tolerates database
outages (a failed pass logs and retries next interval — with EP-34's pool it reconnects
automatically). There is no unsafe state to recover from short of restoring a backup,
and the pass never touches live tuples (`deleted_xid IS NULL` rows are untouchable by
its predicates).


## Interfaces and Dependencies

New/changed interfaces (full module paths):

- `En.Postgres.TupleStore` (`en-postgres/src/En/Postgres/TupleStore.hs`) exports, in
  addition to the existing surface:

  ```haskell
  reapDeletedTuplesBatchSession :: Word64 -> Int -> Hasql.Session.Session Int64
  pruneTransactionsBatchSession :: Word64 -> Int -> Hasql.Session.Session Int64
  ```

  The `TupleStore` effect (`en-core/src/En/Effect/TupleStore.hs`) is deliberately
  unchanged.
- New module `Maintenance` in `en-server/app/Maintenance.hs` (`other-modules`):
  `MaintenanceConfig(..)`, `loadMaintenanceConfig :: IO MaintenanceConfig`,
  `runMaintenanceLoop :: MaintenanceConfig -> (forall a. Eff AppEffects a -> IO (Either
  EnError a)) -> IO ()`.
- `en-server/app/Main.hs`: config load, startup log line, `withAsync` wrapping of the
  serve call.
- New migration file `en-migrations/db/migrations/<timestamp>_en-transaction-horizon-index.sql`
  (timestamp minted by `just make-migration`; EP-38 adds its own separate migration
  file — per the master plan, neither plan edits the other's).
- `Justfile`: one new guard block in `run-migrations`.
- `docs/user/service-and-operations.md`: maintenance section
  (`EN_MAINTENANCE_INTERVAL_SECONDS`, `EN_MAINTENANCE_BATCH_SIZE`, the log-line format,
  the relationship between `EN_GC_WINDOW`, token validity, and pruning).

Dependencies: `async` added to `en-server`'s `build-depends`
(`Control.Concurrent.Async.withAsync`; already in the project's transitive closure).
Everything else uses existing deps (`hasql` sessions, `effectful`). Environment
variables `EN_MAINTENANCE_INTERVAL_SECONDS` and `EN_MAINTENANCE_BATCH_SIZE` are later
absorbed by EP-38's `ServerConfig`
(`docs/plans/38-validate-configuration-and-persist-datastore-identity.md`); the names
here are the contract. The `Database`-effect-only rule (no raw connections) restates the
master plan's integration point with EP-34.
