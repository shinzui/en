---
id: 14
slug: harden-consistency-faithful-snapshot-visibility-gc-window-and-token-reconciliation
title: "Harden consistency: faithful snapshot visibility, GC window, and token reconciliation"
kind: exec-plan
created_at: 2026-06-23T16:37:01Z
intention: "intention_01kvv5mecvechb6c6jv3p3zv4a"
master_plan: "docs/masterplans/3-harden-en-correctness-fixes-lookup-streaming-and-performance-benchmarks.md"
---

# Harden consistency: faithful snapshot visibility, GC window, and token reconciliation

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`en` (縁) is a relationship-based authorization toolkit. When a caller writes a relationship
("alice is a viewer of project-x"), `en` hands back a small opaque string called a **consistency
token**. The caller can later present that token on a read and say "answer as of at least this
moment" so it sees its own write — the **read-your-writes** guarantee, and the prevention of the
"new-enemy" bug (where a freshly-revoked permission still appears granted because the read ran
against an older view of the data). In `en` this is implemented on top of PostgreSQL's own
multi-version concurrency control (MVCC): a **revision** is a PostgreSQL snapshot string of the
form `xmin:xmax:xip` (explained in Context below), and comparing two revisions decides whether one
read view is "at least as fresh as" another.

Today that comparison is subtly wrong, the token can read data that PostgreSQL has already
garbage-collected (vacuumed) away, the token returned on write is not actually anchored to the
write's own snapshot, the on-disk soft-delete sentinel disagrees with the written spec, the token
text format diverges from the spec, and the core comparison function in `en-core` is a landmine
that crashes the process if anyone calls it. Each of these is a correctness gap that can produce a
**stale read** or, worse, a **cross-tenant leak** (one customer's data visible under another
customer's token).

After this change a reader can trust that: (1) `en`'s revision comparison agrees, transaction-id by
transaction-id, with PostgreSQL's own `pg_visible_in_snapshot` — proven by a property test that
generates thousands of randomized snapshot pairs and compares `en`'s answer against real PostgreSQL
as the oracle, including the two tricky cases that the current code gets wrong; (2) a token older
than the garbage-collection horizon is rejected with a clear error instead of silently reading
vacuumed-away rows, and a periodic reaper actually deletes soft-deleted tuples once they fall behind
that horizon; (3) the token returned by a write is the write transaction's own snapshot, read back
from the row the write inserted; (4) the soft-delete representation, the token text format, and the
core comparator are all internally consistent with the spec and with each other.

You can see it working by running the `en-postgres` test suites (both the pure unit suite and the
PostgreSQL-backed integration suite). The headline proof is a single property test that **fails on
the current code** for a hand-constructed "xmax-gap" snapshot pair and **passes after the fix**, and
that additionally agrees with real PostgreSQL across thousands of random cases.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Milestone 1: Replace `snapshotIncludes` with a faithful per-transaction-id port of PostgreSQL
      snapshot visibility, and add an oracle-backed property test (`en-postgres-integration-tests`)
      that compares `en`'s answer against real PostgreSQL `pg_visible_in_snapshot` over randomized
      snapshot pairs, including the xmax-gap and in-progress-xip cases. Confirm the new test fails on
      the pre-fix code for the xmax-gap pair and passes after.
- [ ] Milestone 2: Add a garbage-collection-window (GC-window) validity check to
      `validateTokenMetadata` so `AtExactSnapshot`/`AtLeastAsFresh` tokens older than the horizon are
      rejected, and add a soft-delete reaper session that deletes tuples whose `deleted_xid` is older
      than the horizon. Prove both against PostgreSQL.
- [ ] Milestone 3: Anchor the write-returned token to the write transaction's own snapshot by reading
      back the `en_transaction.snapshot` row the write inserted (stop using a separate post-commit
      `SELECT pg_current_snapshot()`).
- [ ] Milestone 4: Reconcile the `deleted_xid` sentinel between spec and code, add an index that
      serves point-in-time reads of since-deleted rows, stabilize the token format and the `expiresAt`
      timestamp encoding, and remove the `En.Revision.compareRevision` `error` stub.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: The reference oracle for the snapshot-visibility property test is real PostgreSQL's
  `pg_visible_in_snapshot(xid8, pg_snapshot)`, exercised through the existing `ephemeral-pg`
  dependency, rather than a hand-written Haskell re-derivation of the rules.
  Rationale: `pg_visible_in_snapshot` is the exact function the production read path already calls
  (see `readObjectRelationStatement` in `en-postgres/src/En/Postgres/TupleStore.hs:361-377`), so it
  is the ground truth by definition. Re-deriving the rules in Haskell to test the Haskell port would
  test our understanding against itself; the database removes that circularity.
  Date: 2026-06-23

- Decision: This plan does NOT implement quantization or any optimized-revision caching.
  `optimizedRevision` continues to alias `headRevision` exactly as it does today
  (`en-postgres/src/En/Postgres/TupleStore.hs:88-92`).
  Rationale: Quantizing `optimizedRevision` (flooring "now" to a time window so many requests share a
  snapshot and caches hit) is owned by MasterPlan 2 EP-9
  (`docs/plans/9-implement-optimized-revision-caching.md`). The boundary is fixed by MasterPlan 3
  Integration Point 1 (`docs/masterplans/3-harden-en-correctness-fixes-lookup-streaming-and-performance-benchmarks.md`):
  EP-14 fixes the *correctness* of the comparison so EP-9 can build quantization on top of a correct
  partial order; EP-14 must land first and must not implement quantization. If this plan touched the
  optimized-revision path it would create two plans editing the same seam.
  Date: 2026-06-23

- Decision: Reconcile the `deleted_xid` sentinel by making the **spec match the code**, i.e. keep
  `deleted_xid IS NULL = live` (a SQL `NULL` in the `deleted_xid` column means the tuple has never
  been deleted) and amend `docs/spec/0001-en-overview.md` §7 to drop the "sentinel max = live"
  wording.
  Rationale: The entire code path — the migration's partial unique index
  (`en-migrations/db/migrations/20260623044157_create-relation-tuples.sql:23-33`,
  `WHERE deleted_xid IS NULL`), the delete statement's `deleted_xid IS NULL` guard
  (`en-postgres/src/En/Postgres/TupleStore.hs:290-304`), and the read predicate
  `deleted_xid IS NULL OR NOT pg_visible_in_snapshot(...)`
  (`en-postgres/src/En/Postgres/TupleStore.hs:373`, `:400`) — already assumes `NULL = live`. Changing
  the code to a max-xid sentinel would mean choosing a literal `xid8` value (PostgreSQL `xid8` is a
  64-bit counter with no portable "maximum live" constant) and rewriting four sites for no behavioral
  gain, while breaking the partial indexes. The spec is one paragraph; the code is the contract. We
  move the spec.
  Date: 2026-06-23

- Decision: The garbage-collection horizon is computed from the `en_transaction` table —
  specifically `min(xid)` among transactions newer than the configured GC age — and a token is
  rejected if its revision's `xmax` is at or below that horizon. The reaper deletes `relation_tuple`
  rows whose `deleted_xid` is strictly less than the horizon (i.e. invisible to every still-valid
  token).
  Rationale: `en` owns no separate "GC clock"; the `en_transaction` rows are the only durable record
  of which revisions ever existed. Anchoring the horizon to a transaction-age cutoff keeps the rule
  expressible in one SQL query and keeps the reaper and the token check using the same horizon, so a
  token is rejected exactly when (and only when) the data it would read could have been reaped.
  Date: 2026-06-23


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes no prior knowledge of `en`. Read it before touching code.

`en` is a Haskell project laid out as a set of Cabal packages under
`/Users/shinzui/Keikaku/bokuno/en`. Four packages matter here:

- `en-core` — the engine and its abstract interfaces, with no database dependency. The two files we
  touch are `en-core/src/En/Revision.hs` (the revision and token *types*, plus the
  partial-order comparison `RevisionOrder`) and `en-core/src/En/Effect/ConsistencyStore.hs` (the
  abstract "consistency store" interface: decode a token, validate a token, resolve a read's
  freshness).
- `en-migrations` — the PostgreSQL schema as `.sql` files managed by a migration tool called
  **codd** (a tool that applies numbered SQL files to a database in order). The only migration today
  is `en-migrations/db/migrations/20260623044157_create-relation-tuples.sql`. The Haskell module
  `en-migrations/src/En/Migrations.hs` just exposes the directory path; it contains no logic.
- `en-postgres` — the PostgreSQL implementation. `en-postgres/src/En/Postgres/Revision.hs` holds the
  snapshot parsing, the comparison, and the token codec (encode/decode the token string).
  `en-postgres/src/En/Postgres/TupleStore.hs` holds the actual SQL: reading tuples at a revision,
  writing tuples, deleting tuples, and the statements that talk to PostgreSQL via a library called
  **hasql** (a typed PostgreSQL client; a `Statement params result` is a parameterized SQL string
  with encoders for `params` and decoders for `result`, and a `Session` is a sequence of statements
  run on one connection).
- The `en-postgres` package has two test suites declared in `en-postgres/en-postgres.cabal`:
  `en-postgres-revision-tests` (pure unit tests in `en-postgres/test/Main.hs`, no database) and
  `en-postgres-integration-tests` (in `en-postgres/integration-test/Main.hs`, which spins up a real
  throwaway PostgreSQL using the `ephemeral-pg` library and runs end-to-end scenarios). The property
  test that is the headline of this plan goes into the integration suite because it needs a real
  database as its oracle.

**Term: revision / `pg_snapshot`.** PostgreSQL exposes its MVCC state as a *snapshot* string
`xmin:xmax:xip`. `xmin` is the oldest transaction id (txid) that is still considered "in progress or
later" from this snapshot's point of view: every txid strictly below `xmin` has already committed
and is visible. `xmax` is the first txid that had **not yet been assigned** when the snapshot was
taken: every txid at or above `xmax` is in the future and invisible. `xip` ("transactions in
progress") is the explicit list of txids in the half-open range `[xmin, xmax)` that were still
running (uncommitted) when the snapshot was taken, and are therefore also invisible. So PostgreSQL's
visibility rule for a *committed* txid `t` against a snapshot is exactly:

```text
visible(t) =  t < xmin                       -> True
              t >= xmax                       -> False
              otherwise                       -> t is NOT in xip
```

In `en` a `Revision` (`en-core/src/En/Revision.hs:19-23`) wraps that string opaquely, and
`PgSnapshot` (`en-postgres/src/En/Postgres/Revision.hs:51-56`) is the parsed `{xmin, xmax, xip}`
form. The function `transactionVisible` (`en-postgres/src/En/Postgres/Revision.hs:113-117`) already
implements the rule above correctly for a single txid. The PostgreSQL function with the same meaning
is `pg_visible_in_snapshot(xid8, pg_snapshot)`, and the production read path already calls it
(`en-postgres/src/En/Postgres/TupleStore.hs:372-373` and `:399-400`).

**Term: revision comparison / partial order.** To answer "is read view A at least as fresh as read
view B?" `en` compares two snapshots. The comparison is **four-valued**
(`RevisionOrder = RBefore | RAfter | REqual | RConcurrent`, `en-core/src/En/Revision.hs:34-35`)
because two snapshots can be **concurrent** — neither sees a strict superset of the other's
committed transactions. This is a *partial* order, not a total order, and that is load-bearing: the
`AtLeastAsFresh` read mode picks `max(optimized, token)`, and if a concurrent optimized revision were
wrongly judged "after" the token, the read would silently drop back to the optimized revision and
miss the caller's own write. The spec calls this out
(`docs/spec/0001-en-overview.md:228-234`).

The comparison is built from a helper `snapshotIncludes candidate required`
(`en-postgres/src/En/Postgres/Revision.hs:249-264`), meaning "does `candidate` see at least every
committed transaction that `required` sees?" `comparePgSnapshot`
(`en-postgres/src/En/Postgres/Revision.hs:119-125`) calls it both ways and maps the four outcomes:
both-include = `REqual`, only-candidate-includes = `RAfter`, only-required-includes = `RBefore`,
neither = `RConcurrent`.

**The bugs this plan fixes** (each verified against the cited source):

1. **`snapshotIncludes` is a finite-probe approximation, not a faithful port**
   (`en-postgres/src/En/Postgres/Revision.hs:249-264`). Instead of deciding inclusion mathematically,
   it samples a hand-picked finite set of "probe" txids (`required.xmin`, `required.xmin - 1`,
   `required.xmax - 1`, plus the two `xip` lists) and checks visibility only at those points. Any
   committed txid in the gap `[candidate.xmax, required.xmin)` that appears in neither `xip` list is
   never probed, so the function can wrongly report "included." Concretely, if `candidate` is
   `10:15:` (sees everything below 15, nothing at/above 15) and `required` is `20:25:`, then txid 17
   is committed-and-visible in `required` (17 ≥ 20 is false, 17 ≥ 15... wait — 17 is visible in
   `required` because 17 < 20 = xmin) but invisible in `candidate` (17 ≥ 15 = xmax). A faithful
   "candidate includes required" must be False here, yet 17 is never in the probe set, so the
   approximation can return True. This is the **xmax-gap** false-include and is the read-your-writes /
   cross-tenant-leak risk. This is the plan's highest-priority milestone.

2. **No GC-window check and no reaper.** `validateTokenMetadata`
   (`en-postgres/src/En/Postgres/Revision.hs:182-190`) checks datastore id, schema hash, and expiry,
   but never checks whether the token's revision is older than what PostgreSQL still retains. So an
   `AtExactSnapshot`/`AtLeastAsFresh` token older than the last vacuum can ask to read a revision
   whose underlying soft-deleted rows have already been physically removed, returning a wrong
   (incomplete) answer instead of an error. Separately, soft-deleted tuples (rows with `deleted_xid`
   set) accumulate forever; nothing ever deletes them.

3. **Write token not anchored to its own snapshot.** `writeTuplesSession`/`deleteTuplesSession`
   (`en-postgres/src/En/Postgres/TupleStore.hs:105-125`) open a transaction, stamp tuples'
   `created_xid`/`deleted_xid` with the write transaction's id via `pg_current_xact_id()` inside
   `anchorTransactionStatement` (`:186-197`), and that same statement *also* inserts the write's true
   snapshot into `en_transaction.snapshot` (`:192`). But the token returned to the caller is built
   from a **separate** `SELECT pg_current_snapshot()` run *after* `COMMIT`
   (`:111-112`, `:122-123`, via `currentSnapshotStatement` at `:206-213`), and the
   `en_transaction.snapshot` value is never read back — making that column dead. The post-commit
   snapshot is taken in a different transaction and can already include *other* writers' transactions
   that committed in the gap, so the token over-promises freshness.

4. **`deleted_xid` sentinel mismatch + missing historical-read index.** The migration uses
   `deleted_xid IS NULL` to mean "live"
   (`en-migrations/db/migrations/20260623044157_create-relation-tuples.sql:19,33,37,42,49`) but the
   spec (`docs/spec/0001-en-overview.md:216`) says "sentinel max = live." These disagree. Separately,
   the hot indexes are partial (`WHERE deleted_xid IS NULL`, lines `:33,37,42`), so a point-in-time
   read at an *old* revision of a row that has *since* been deleted (i.e. `deleted_xid` is now set)
   cannot use those indexes and falls to a sequential scan.

5. **Token format divergence + unstable timestamp.** The token is encoded as a dotted-ASCII string
   `en1.datastore.schema.revision.expiry` (`en-postgres/src/En/Postgres/Revision.hs:131-145`) while
   the spec (`docs/spec/0001-en-overview.md:222-223`) describes an "opaque base64-proto." And
   `expiresAt` is encoded by Haskell's `show :: UTCTime`
   (`en-postgres/src/En/Postgres/Revision.hs:140`) and decoded by `readMaybe`
   (`:266-270`), which is a non-portable, non-stable format (it round-trips only within this exact
   Haskell runtime).

6. **`En.Revision.compareRevision` is an `error` stub.** `compareRevision`
   (`en-core/src/En/Revision.hs:38-40`) is `error "TODO..."`. It is exported
   (`en-core/src/En/Revision.hs:6`) and totally partial: any caller crashes the process. The real
   comparator is `comparePostgresRevision` in `en-postgres`
   (`en-postgres/src/En/Postgres/Revision.hs:127-129`). This stub is a landmine in core.


## Plan of Work

The work is four milestones. Each is independently buildable and testable, and each ends with a
command to run and a behavior to observe. Do them in order: Milestone 1 is the correctness keystone;
Milestone 4's spec/token/stub reconciliation is the cleanup the rest depends on for clarity.

Throughout, the build command is `cabal build all` and the two test commands are
`cabal test en-postgres-revision-tests` (pure, fast, no database) and
`cabal test en-postgres-integration-tests` (real PostgreSQL via `ephemeral-pg`), all run from
`/Users/shinzui/Keikaku/bokuno/en`. `cabal test all` runs every suite.


### Milestone 1 — Faithful `snapshotIncludes` + oracle-backed property test

**Scope.** Replace the finite-probe `snapshotIncludes`
(`en-postgres/src/En/Postgres/Revision.hs:249-264`) with a faithful, total port of PostgreSQL
snapshot inclusion, and add a property test that proves `en`'s `comparePgSnapshot` /
`transactionVisible` agree with real PostgreSQL `pg_visible_in_snapshot` over thousands of randomized
snapshot pairs, including the xmax-gap and in-progress-xip cases.

**What exists after.** `snapshotIncludes candidate required` returns `True` if and only if **every**
committed transaction id visible in `required` is also visible in `candidate` — decided
mathematically over the whole txid space, not by sampling probes. And a new property test in
`en-postgres/integration-test/Main.hs` (running under `ephemeral-pg`) that fails on the old code and
passes on the new.

**The faithful definition.** "Candidate includes required" means: for every txid `t`, if `t` is
visible in `required` then `t` is visible in `candidate`. We do not need to enumerate all txids; the
visibility rule is piecewise over three regions, so inclusion reduces to a finite set of conditions.
`required` makes a txid `t` visible exactly when `t < required.xmin`, or (`required.xmin <= t <
required.xmax` and `t` not in `required.xip`). `candidate` makes `t` visible exactly when
`t < candidate.xmin`, or (`candidate.xmin <= t < candidate.xmax` and `t` not in `candidate.xip`).
Inclusion holds iff there is **no** txid `t` that `required` deems visible but `candidate` deems
invisible. The set of txids `required` deems visible is `{ t : t < required.xmax } \ required.xip`
(every txid below `xmax` except the in-progress ones; note `xmin <= xmax` always, and txids below
`xmin` are visible and never in `xip`). So we must show every such `t` is also visible in
`candidate`. Equivalently:

- Every `t < candidate.xmin` is visible in `candidate`, so those are fine regardless of `required`.
- For `candidate.xmin <= t < candidate.xmax` with `t` not in `candidate.xip`, `t` is visible in
  `candidate`; for `t` in `candidate.xip`, `t` is invisible.
- Every `t >= candidate.xmax` is invisible in `candidate`.

Therefore `candidate` includes `required` iff:

1. `candidate.xmax >= required.xmax` is **necessary**: if `candidate.xmax < required.xmax`, pick the
   txid `t = candidate.xmax`. It is below `required.xmax`. Is it visible in `required`? It is unless
   it sits in `required.xip`. If it does, try the next txid not in `required.xip` in
   `[candidate.xmax, required.xmax)`; such a txid exists because `xip` lists are finite and the range
   is non-empty. That txid is visible in `required` but invisible in `candidate` (it is `>=
   candidate.xmax`). So inclusion fails. (This is exactly the xmax-gap the old code missed.)
2. Given `candidate.xmax >= required.xmax`, the only txids `required` makes visible that `candidate`
   might *not* are those in `[candidate.xmin, candidate.xmax)` that are in `candidate.xip` but that
   `required` deems visible. Precisely: for every `t` in `candidate.xip` with `t < required.xmax`,
   if `required` deems `t` visible (`t < required.xmin`, or `t` not in `required.xip`), inclusion
   fails. Conversely if no such `t` exists, every txid `required` deems visible is visible in
   `candidate`.

So the faithful implementation is:

```haskell
-- | Does @candidate@ see every committed transaction that @required@ sees?
-- A faithful port of PostgreSQL snapshot inclusion (the "at least as fresh"
-- relation), decided over the whole txid space rather than by sampling probes.
snapshotIncludes :: PgSnapshot -> PgSnapshot -> Bool
snapshotIncludes candidate required =
    candidate.xmax >= required.xmax
        && all
            (\txid -> not (transactionVisible txid required))
            -- the only txids that could break inclusion: in-progress in candidate,
            -- below required.xmax, yet visible in required.
            ( filter (< required.xmax) candidate.xip )
```

Note we no longer need the `minBounded` helper or the synthetic probe list; delete `minBounded`
(`en-postgres/src/En/Postgres/Revision.hs:262-264`) and remove `nub`/`sort` from the probe
construction if they are now unused (keep them if still used by `parsePgSnapshot`/`renderPgSnapshot`,
which they are — only the local `probeTxids` `where` clause goes away). `transactionVisible`
(`:113-117`) is reused unchanged; it is already a faithful single-txid rule.

**Why this is faithful.** Condition 1 catches the xmax-gap. Condition 2 is the complete in-progress
check: a txid that `candidate` hides only because it is in `candidate.xip` breaks inclusion exactly
when `required` would have shown it. Every other txid is handled by condition 1 plus the structure of
the visibility rule. There is no finite-sampling blind spot because we quantify over the actual
`candidate.xip` list (finite) and reason about the regions analytically.

**The oracle property test.** Add a `QuickCheck`-style randomized test to
`en-postgres/integration-test/Main.hs`. (If `QuickCheck` is not yet a dependency of the integration
suite, add it to the `en-postgres-integration-tests` stanza in `en-postgres/en-postgres.cabal`; the
suite already depends on `ephemeral-pg`, `hasql`, `en-core`, `en-postgres`, `text`, `time`,
`containers`, `base`.) The test:

1. Generates a random `PgSnapshot` by drawing `xmin` in a bounded range (say 1..40), `xmax` in
   `xmin..xmin+40`, and `xip` as a random subset of `[xmin, xmax)`. Generate **pairs** of these so
   the xmax-gap case arises naturally; also explicitly include hand-built edge pairs (the `10:15:`
   vs `20:25:` xmax-gap pair, and an in-progress-xip pair such as `10:20:[11]` vs `10:20:[12]`).
2. For each generated pair `(a, b)` and a set of probe txids drawn from `[0, max xmax + 2)`, asks the
   real database, for each probe txid `t`, `SELECT pg_visible_in_snapshot($t::xid8, $snap::pg_snapshot)`
   for `snap = a` and for `snap = b` (render with `renderPgSnapshot`). This yields PostgreSQL's
   ground-truth visibility sets `Va` and `Vb`.
3. Computes the oracle's inclusion: `a` includes `b` iff `Vb` is a subset of `Va` over the probe
   range; symmetrically for `b` includes `a`. Maps the two booleans to the same four-valued
   `RevisionOrder` that `comparePgSnapshot` produces.
4. Asserts `en`'s `comparePgSnapshot a b` equals the oracle's `RevisionOrder`, and that
   `transactionVisible t a` equals PostgreSQL's `pg_visible_in_snapshot(t, a)` for every probe.

The probe range must cover `[0, (max of both xmax) + 2)` so the xmax-gap region
`[candidate.xmax, required.xmin)` is always sampled by the *oracle comparison* (the oracle is exact
over the probe range; we make the probe range a true superset of every interesting region rather than
relying on it being faithful — the *implementation* under test is the faithful one).

**Commands.**

```bash
cd /Users/shinzui/Keikaku/bokuno/en
cabal build all
cabal test en-postgres-integration-tests
```

**Acceptance.** Before applying the `snapshotIncludes` fix, add only the test and run it against a
hand-built xmax-gap pair (`10:15:` vs `20:25:`): the test FAILS, reporting that `en` answered
`REqual`/`RAfter` where PostgreSQL's oracle says the snapshots are not mutually inclusive. After
applying the fix, the same test PASSES, and the randomized sweep (default at least 200 generated
pairs) passes with no counterexample. Capture the failing-then-passing transcript in Surprises &
Discoveries. Also run `cabal test en-postgres-revision-tests`; the existing pure assertions at
`en-postgres/test/Main.hs:54-67` (`RAfter` for `10:30:` vs `10:20:`, `RConcurrent` for `10:20:[11]`
vs `10:20:[12]`) must still pass — the faithful definition gives the same answers there.


### Milestone 2 — GC-window check + soft-delete reaper

**Scope.** Reject tokens whose revision is older than the garbage-collection horizon, and add a
reaper session that physically deletes soft-deleted tuples once they fall behind that horizon.

**What exists after.** `validateTokenMetadata` gains a GC-horizon check; a new `reapDeletedTuples`
session exists in `en-postgres/src/En/Postgres/TupleStore.hs`; the integration test proves a token
older than the horizon is rejected and that the reaper removes only safely-removable rows.

**The horizon.** Define the GC horizon as a transaction id: the smallest `xid` in `en_transaction`
whose `created_at` is newer than a configured retention window (e.g. now minus the GC age), or — if
that is simpler to start — a horizon supplied to `ConsistencyConfig`. To keep the milestone
self-contained and avoid coupling the validity check to clock skew, compute the horizon in SQL and
thread it into the validity check as a `Word64` "oldest retained xid":

```sql
-- oldest xid still inside the retention window; rows/tokens older than this may be reaped.
SELECT coalesce(min(xid), pg_snapshot_xmin(pg_current_snapshot()))::text
FROM en_transaction
WHERE created_at >= now() - $1::interval
```

`$1` is the retention interval (a string like `'24 hours'`), added to `ConsistencyConfig` as a new
field `gcWindow :: Text` (and surfaced through the `postgresConsistencyStore` constructor, which
already receives `config`). Add a hasql `Statement Text Word64` (decode the `text` column with
`readDec`, reusing the existing `parseWord` shape) and an `IO Word64` reader passed into
`postgresConsistencyStore` alongside the existing `readOptimizedRevision`/`readHeadRevision` readers
(`en-postgres/src/En/Postgres/Revision.hs:224-247`).

**The check.** Extend `validateTokenMetadata`
(`en-postgres/src/En/Postgres/Revision.hs:182-190`). It currently takes
`ConsistencyConfig -> UTCTime -> TokenMetadata`. Add the horizon as a parameter (a `Word64`), and add
a guard: parse the token's revision to a `PgSnapshot` (reuse `revisionToPgSnapshot`,
`:106-108`), and if `snapshot.xmax <= horizon` reject with
`Left (InvalidConsistencyToken "token is older than the garbage-collection window")`. The rationale:
once the horizon advances past a revision's `xmax`, every transaction that revision could
distinguish has been reaped, so the revision can no longer be answered faithfully. Wire the horizon
through `resolveConsistencyRequest` (`:192-222`) and the `postgresConsistencyStore` closure
(`:236-246`, which already calls `currentTime` per request — read the horizon there too).

**The reaper.** Add a `Session ()` to `en-postgres/src/En/Postgres/TupleStore.hs`:

```haskell
-- | Physically delete soft-deleted tuples no still-valid token could observe:
-- those whose deleted_xid is strictly below the GC horizon. Idempotent.
reapDeletedTuples :: Word64 -> Session Int64
reapDeletedTuples horizon =
    Session.statement horizon reapDeletedTuplesStatement
```

with a statement:

```sql
WITH reaped AS (
  DELETE FROM relation_tuple
  WHERE deleted_xid IS NOT NULL
    AND deleted_xid < $1::xid8
  RETURNING id
)
SELECT count(*) FROM reaped
```

The reaper deletes only rows already soft-deleted (`deleted_xid IS NOT NULL`) whose deletion happened
strictly before the horizon — so no token still inside the window can ever need them. It returns the
count for observability and is safe to run repeatedly (idempotent: a second run deletes zero). Expose
it on the `TupleStore` record if a scheduler will call it, or leave it as a session a host can run on
a timer; for this plan, expose a `reapDeletedTuples :: Word64 -> m Int64` field on `TupleStore`
(`en-core/src/En/Effect/TupleStore.hs`) wired through `postgresTupleStore`
(`en-postgres/src/En/Postgres/TupleStore.hs:77-92`). (Check `en-core/src/En/Effect/TupleStore.hs`
for the record shape and add the field; update any in-memory store implementation so it still
compiles — a no-op returning `0` is acceptable for the in-memory store.)

**Commands.**

```bash
cd /Users/shinzui/Keikaku/bokuno/en
cabal build all
cabal test en-postgres-integration-tests
```

**Acceptance.** In the integration test: write tuples, capture a token, advance the horizon past the
token's `xmax` (the test can set a tiny `gcWindow` like `'0 seconds'` so every prior txn is
out-of-window, or pass an explicit horizon above the token's `xmax`), then assert that resolving an
`AtExactSnapshot` read with that token returns
`Left (InvalidConsistencyToken "token is older than the garbage-collection window")`. Separately:
write two tuples, delete one (so it is soft-deleted), run `reapDeletedTuples` with a horizon above the
deleted row's `deleted_xid`, assert the returned count is 1 and that a fresh head-revision read still
sees the surviving tuple. Run the reaper a second time and assert it returns 0 (idempotent).


### Milestone 3 — Anchor the write token to the write's own snapshot

**Scope.** Make the token returned by `writeTuples`/`deleteTuples` carry the write transaction's own
snapshot, read back from the `en_transaction` row the write inserted, instead of a separate
post-commit `SELECT pg_current_snapshot()`.

**What exists after.** `writeTuplesSession`/`deleteTuplesSession` no longer call
`currentSnapshotStatement` after `COMMIT`; the token's revision is the value of
`en_transaction.snapshot` for the write's own `xid`. The previously-dead `snapshot` column
(`en-migrations/db/migrations/20260623044157_create-relation-tuples.sql:3`) is now read.

**The change.** `anchorTransactionStatement`
(`en-postgres/src/En/Postgres/TupleStore.hs:186-204`) already inserts `pg_current_snapshot()` into
`en_transaction.snapshot` and already `RETURNING`s `xid::text, snapshot::text` into the `Anchor`
record (`:158-162`, `:194-203`). So the snapshot the write committed under is *already returned* in
`anchor.snapshot`. The bug is purely that `writeTuplesSession` (`:105-112`) ignores `anchor.snapshot`
and instead runs `currentSnapshotStatement` (`:111`) after `COMMIT`. Fix:

```haskell
writeTuplesSession :: ConsistencyConfig -> [Tuple] -> Session ConsistencyToken
writeTuplesSession config tuples = do
    Session.script beginScript
    anchor <- Session.statement schemaHashText anchorTransactionStatement
    traverse_ (\tuple -> Session.statement (tupleInsertParams anchor.xid tuple) insertTupleStatement) tuples
    Session.script commitScript
    pure (tokenFromAnchor config anchor)   -- uses anchor.snapshot, no post-commit SELECT
  where
    SchemaHash schemaHashText = config.schemaHash
```

Apply the identical change to `deleteTuplesSession` (`:116-123`). `tokenFromAnchor`
(`:164-172`) already builds the token from `anchor.snapshot` — no change needed there. The
`currentSnapshotStatement` (`:206-213`) remains used by `headRevisionSession` (`:127-129`); do not
delete it.

**A subtlety to verify.** `pg_current_snapshot()` evaluated inside the write transaction (before
COMMIT) is the snapshot *as the write sees it*. For read-your-writes, a subsequent read at that
revision must see the write's own rows. PostgreSQL's `pg_visible_in_snapshot(created_xid, snap)` is
true when `created_xid < snap.xmax` and not in `snap.xip` — but the write's own `xid` is, at the time
`pg_current_snapshot()` runs, the *current* transaction, which appears as in-progress (and `xmax`
equals the next-unassigned id). Confirm empirically in the integration test that a read at the
anchored revision *does* see the just-written tuples; PostgreSQL's MVCC treats a snapshot's own
in-progress transaction as visible to itself when the read runs in a later transaction that observes
the now-committed xid below the snapshot's recorded `xmax`. If the test shows the anchored snapshot
does NOT see the write (because the write's own xid sits at/above the snapshot's `xmax`), fall back to
the documented alternative below and record the finding.

**Documented alternative (only if the empirical check fails).** If the write's own snapshot cannot
see the write, then anchor the token to `xmax = pg_current_xact_id() + 1` (a snapshot that includes
the write's committed xid) by constructing the revision from the returned `xid` rather than the
`snapshot` column, and record in the Decision Log exactly why the raw `en_transaction.snapshot` is
insufficient. In that case, also decide whether the `snapshot` column should be dropped from the
migration (it would again be dead) — prefer keeping it only if a reader uses it.

**Commands.**

```bash
cd /Users/shinzui/Keikaku/bokuno/en
cabal build all
cabal test en-postgres-integration-tests
```

**Acceptance.** The existing integration assertion "write token read sees tuple count = 2"
(`en-postgres/integration-test/Main.hs:96-97`) must still pass with the anchored token. Add an
assertion that the token's revision parses to a `PgSnapshot` whose `xmax` is at most the head
revision's `xmax` captured immediately after the write (the anchored snapshot must not be *fresher*
than head — it must be the write's own snapshot, not a later one that could include concurrent
writers). Confirm `currentSnapshotStatement` is no longer referenced from the write/delete sessions
(grep shows it only in `headRevisionSession`).


### Milestone 4 — Sentinel/index/token/`compareRevision` reconciliation

**Scope.** Four independent cleanups that make the spec, the schema, the token format, and the core
comparator internally consistent.

**What exists after.** The spec's §7 sentinel wording matches the `NULL = live` code; a new index
serves point-in-time reads of since-deleted rows; the token's `expiresAt` is encoded as ISO-8601 and
the format is reconciled with the spec; `En.Revision.compareRevision` is no longer an `error` stub.

**(a) Sentinel reconciliation (spec follows code).** Per the Decision Log, keep `deleted_xid IS NULL
= live` everywhere in code (no code change) and edit `docs/spec/0001-en-overview.md:216` to replace
"(xid8, sentinel max = live)" with wording that a `NULL` `deleted_xid` means live and a non-null
`deleted_xid` records the deleting transaction. Also update the comment in
`en-migrations/src/En/Migrations.hs:6` (it says "sentinel max = live") to match.

**(b) Historical-read index.** Add to
`en-migrations/db/migrations/20260623044157_create-relation-tuples.sql` a NON-partial index that
serves reads at an old revision of a since-deleted row. The two hot read statements filter on
`(object_type, object_id, relation, id)` (`readObjectRelationStatement`,
`en-postgres/src/En/Postgres/TupleStore.hs:361-377`) and on
`(object_type, relation, subject..., id)` (`readStartingWithUserStatement`, `:389-408`), both with a
visibility predicate over `created_xid`/`deleted_xid` rather than `deleted_xid IS NULL`. The existing
indexes `relation_tuple_object_live_idx` / `relation_tuple_subject_live_idx`
(`en-migrations/.../create-relation-tuples.sql:35-42`) are partial on `WHERE deleted_xid IS NULL`, so
a row that has since been deleted (now `deleted_xid IS NOT NULL`) is absent from them and an old-
revision read scans sequentially. Add two non-partial twins:

```sql
CREATE INDEX relation_tuple_object_hist_idx
  ON relation_tuple (object_type, object_id, relation, id);

CREATE INDEX relation_tuple_subject_hist_idx
  ON relation_tuple
    (subject_type, subject_id, coalesce(subject_relation, ''), object_type, relation, id);
```

Because codd applies migrations in filename order and the existing file has already been applied in
real deployments, add these in a NEW migration file with a later timestamp prefix (e.g.
`en-migrations/db/migrations/20260623160000_historical-read-indexes.sql`) rather than editing the
applied file — editing an already-applied codd migration is unsafe. Mirror the same two `CREATE
INDEX` lines into the integration test's inline `schemaSql`
(`en-postgres/integration-test/Main.hs:175-223`) so the test schema matches production.

**(c) Token format + ISO-8601 expiry.** The simplest reconciliation that satisfies the spec's intent
("opaque, carries datastore id + schema hash + revision + optional expiry, detects foreign
datastore/schema") without a protobuf dependency is to keep the structured payload but (i) stabilize
the `expiresAt` encoding to ISO-8601 and (ii) wrap the whole dotted string in base64 so the token is
opaque to callers and matches the spec's "base64" description. Concretely in
`en-postgres/src/En/Postgres/Revision.hs`:

- Replace `Text.pack (show expiresAt)` (`:140`) with an ISO-8601 formatter
  (`Data.Time.Format.ISO8601.iso8601Show`, or `formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"`)
  and replace `parseExpiry`'s `readMaybe` (`:266-270`) with the matching ISO-8601 parser
  (`iso8601ParseM` / `parseTimeM`). This removes the dependency on Haskell `Show`/`Read` round-trip.
- In `encodeToken` (`:131-145`), after building the dotted string, base64-encode it (add
  `base64` or `base64-bytestring` to `en-postgres`'s deps, or `memory`/`bytestring`'s base64 if
  already transitively available — check the cabal file). In `decodeToken` (`:147-166`), base64-decode
  first, then run the existing `Text.splitOn "."` parse. Keep the `en1` version prefix *inside* the
  base64 payload so the codec can evolve. Update the unit tests
  (`en-postgres/test/Main.hs:75-76`) that assert round-trip and bad-token rejection — they go through
  `encodeToken`/`decodeToken` so they keep working, but the literal `"en1.primary.schema.bad"` in the
  bad-token test (`:76`) must be re-expressed as a base64 of a malformed payload (or simply an
  arbitrary non-base64 string, which must decode-fail).

If a base64 dependency is undesirable, the acceptable minimal alternative is to keep the dotted-ASCII
format but **only** fix the ISO-8601 timestamp and update `docs/spec/0001-en-overview.md:222-223` to
describe the actual dotted format instead of "base64-proto." Record whichever path you take in the
Decision Log; the non-negotiable part is that `expiresAt` no longer uses `show`/`readMaybe`.

**(d) Remove the `compareRevision` `error` stub.** In `en-core/src/En/Revision.hs`, `compareRevision`
(`:38-40`) is `error`. The real comparator lives in `en-postgres` (`comparePostgresRevision`,
`en-postgres/src/En/Postgres/Revision.hs:127-129`) and `en-core` has no PostgreSQL dependency, so
`en-core` cannot host the real implementation. Make it total by **removing it from `en-core`**: delete
the `compareRevision` binding (`:38-40`) and remove it from the module export list
(`en-core/src/En/Revision.hs:6`). Then grep the whole tree for `compareRevision` to confirm no caller
breaks (`rg compareRevision` from `/Users/shinzui/Keikaku/bokuno/en`); the only comparator in use is
`comparePostgresRevision`/`comparePgSnapshot` in `en-postgres`. Update the module's Haddock if it
mentions `compareRevision`.

**Commands.**

```bash
cd /Users/shinzui/Keikaku/bokuno/en
rg compareRevision
cabal build all
cabal test all
```

**Acceptance.** `rg compareRevision` returns no hits in source after the change (or only in
documentation). `cabal build all` succeeds with no `-Wall` warning about an unused/partial
`compareRevision`. `cabal test en-postgres-revision-tests` passes including the updated token
round-trip and bad-token assertions, proving the token still encodes/decodes and rejects garbage. The
integration suite passes with the new historical-read indexes present (a since-deleted row read at an
old revision still returns it — already asserted at
`en-postgres/integration-test/Main.hs:124-127`, "old revision still sees deleted tuple"). The spec
file `docs/spec/0001-en-overview.md` no longer says "sentinel max = live."


## Concrete Steps

Run everything from `/Users/shinzui/Keikaku/bokuno/en`.

1. Read the cited files in Context to orient. Then implement Milestone 1's `snapshotIncludes` fix in
   `en-postgres/src/En/Postgres/Revision.hs`, delete the now-dead `minBounded` helper and the local
   `probeTxids` `where` clause, and add the oracle property test to
   `en-postgres/integration-test/Main.hs` (adding `QuickCheck` to the integration suite's deps in
   `en-postgres/en-postgres.cabal` if needed). Build and test:

   ```bash
   cabal build all
   cabal test en-postgres-integration-tests
   ```

   Expected: the property test (and the explicit xmax-gap case) passes; the pure suite still passes:

   ```bash
   cabal test en-postgres-revision-tests
   ```

   Expected transcript fragment:

   ```text
   en-postgres-revision-tests: PASS
   en-postgres-integration-tests: PASS
   ```

2. Milestone 2: add `gcWindow` to `ConsistencyConfig`, the horizon SQL statement and reader, the
   GC-window guard in `validateTokenMetadata`, and `reapDeletedTuples`. Wire the horizon through
   `resolveConsistencyRequest`/`postgresConsistencyStore`. Add the `reapDeletedTuples` field to
   `TupleStore` in `en-core/src/En/Effect/TupleStore.hs` and implement it in `postgresTupleStore`;
   give any in-memory store a no-op returning 0. Build and test as above.

3. Milestone 3: rewrite `writeTuplesSession`/`deleteTuplesSession` to return `tokenFromAnchor config
   anchor` and drop the post-commit `currentSnapshotStatement` call. Build and test; verify the
   empirical read-your-writes assertion.

4. Milestone 4: add the new migration file with the two historical-read indexes, mirror them into the
   integration test's `schemaSql`, fix the `expiresAt` ISO-8601 encoding (and base64-wrap the token if
   taking that path), update the unit tests' token literals, delete `compareRevision` from
   `en-core/src/En/Revision.hs` and its export, and amend `docs/spec/0001-en-overview.md` §7 and
   `en-migrations/src/En/Migrations.hs` comment. Build and run the full suite:

   ```bash
   cabal build all
   cabal test all
   ```

5. Commit after each milestone with a conventional-commit message, e.g.
   `fix(en-postgres): faithful pg_snapshot inclusion + oracle property test`,
   `feat(en-postgres): GC-window token check and soft-delete reaper`,
   `fix(en-postgres): anchor write token to the write's own snapshot`,
   `refactor(en-core,en-postgres,en-migrations): reconcile sentinel/index/token, drop compareRevision stub`.


## Validation and Acceptance

The system is validated by the two test suites and the spec edit:

- `cabal test en-postgres-revision-tests` — pure, fast. Proves the token codec round-trips and rejects
  garbage, the four-valued comparison still gives the documented `RAfter`/`RConcurrent` answers, and
  (after Milestone 4) the ISO-8601/base64 token still works.
- `cabal test en-postgres-integration-tests` — real PostgreSQL via `ephemeral-pg`. Proves: (Milestone
  1) `comparePgSnapshot` agrees with `pg_visible_in_snapshot` over randomized pairs and the explicit
  xmax-gap pair, failing on the old code and passing on the new; (Milestone 2) a token past the GC
  horizon is rejected and the reaper removes only safely-removable rows and is idempotent; (Milestone
  3) a read at the write's anchored revision sees the write's own tuples and is not fresher than head;
  (Milestone 4) a since-deleted row read at an old revision is still returned.
- A human-verifiable check: `rg compareRevision` returns no source hits; `grep -n "sentinel" docs/spec/0001-en-overview.md`
  shows the updated wording (no "max = live").

Phrase the headline acceptance as behavior: with the fix reverted, the integration property test
reports a counterexample on the `10:15:` vs `20:25:` pair ("`en` said REqual; oracle said
incomparable"); with the fix applied it reports `PASS` across the sweep.


## Idempotence and Recovery

All steps are safe to re-run. `cabal build`/`cabal test` are idempotent. The reaper is idempotent by
construction (a second run deletes zero rows). The new migration is additive (`CREATE INDEX` of new
names; if re-applied by hand use `CREATE INDEX IF NOT EXISTS` to be safe) and must be a NEW file, not
an edit to the already-applied `20260623044157_create-relation-tuples.sql`. The spec and comment edits
are text-only. If a milestone's test fails, the milestones are independent enough to revert just that
milestone's source change and re-run; commit per milestone so reverting is a single `git revert`.


## Interfaces and Dependencies

Libraries and modules used and why:

- `hasql` (`Hasql.Statement`, `Hasql.Session`, `Hasql.Encoders`, `Hasql.Decoders`) — the typed
  PostgreSQL client already used throughout `en-postgres/src/En/Postgres/TupleStore.hs`. New
  statements (horizon query, reaper) follow the existing `Statement.preparable` pattern at
  `en-postgres/src/En/Postgres/TupleStore.hs:186-213`.
- `ephemeral-pg` (`EphemeralPg.with`, `EphemeralPg.connectionSettings`) — throwaway PostgreSQL for the
  integration suite, already used at `en-postgres/integration-test/Main.hs:24,30,41`. The oracle
  property test runs `SELECT pg_visible_in_snapshot(...)` through a `hasql` session on that database.
- `QuickCheck` — randomized property generation for the oracle test; add to the
  `en-postgres-integration-tests` stanza in `en-postgres/en-postgres.cabal` if not present.
- `Data.Time.Format.ISO8601` (from `time`, already a dependency) — stable `expiresAt` encoding,
  replacing `show`/`readMaybe` at `en-postgres/src/En/Postgres/Revision.hs:140,266-270`.
- `base64`/`base64-bytestring` — only if taking the base64-wrap path for the token in Milestone 4(c);
  check whether one is already transitively available before adding.

Signatures that must exist at the end of each milestone (full module paths):

- After Milestone 1: `En.Postgres.Revision.snapshotIncludes :: PgSnapshot -> PgSnapshot -> Bool`
  (faithful, total), `En.Postgres.Revision.comparePgSnapshot :: PgSnapshot -> PgSnapshot ->
  RevisionOrder` (unchanged signature), `En.Postgres.Revision.transactionVisible :: Word64 ->
  PgSnapshot -> Bool` (unchanged).
- After Milestone 2: `En.Postgres.Revision.ConsistencyConfig` gains `gcWindow :: Text`;
  `En.Postgres.Revision.validateTokenMetadata :: ConsistencyConfig -> UTCTime -> Word64 ->
  TokenMetadata -> Either EnError ()` (new `Word64` horizon parameter);
  `En.Postgres.TupleStore.reapDeletedTuples :: Word64 -> Session Int64`; `En.Effect.TupleStore.TupleStore`
  gains `reapDeletedTuples :: Word64 -> m Int64`.
- After Milestone 3: `En.Postgres.TupleStore.writeTuplesSession` / `deleteTuplesSession` unchanged in
  type (`ConsistencyConfig -> [Tuple] -> Session ConsistencyToken`) but no longer call
  `currentSnapshotStatement`.
- After Milestone 4: `En.Revision.compareRevision` no longer exists (removed from
  `en-core/src/En/Revision.hs` and its export list); `En.Postgres.Revision.encodeToken` /
  `decodeToken` signatures unchanged, internals stabilized.

Cross-plan boundary (restated from the Decision Log and MasterPlan 3 Integration Point 1):
`optimizedRevision` stays aliased to `headRevision` (`en-postgres/src/En/Postgres/TupleStore.hs:88-92`);
this plan does not implement quantization or any caching. That is MasterPlan 2 EP-9
(`docs/plans/9-implement-optimized-revision-caching.md`), which must build on this plan's corrected
`comparePgSnapshot`. Any plan that reads or writes tuples must use the `deleted_xid IS NULL = live`
sentinel this plan settles (MasterPlan 3 Integration Point 5).
