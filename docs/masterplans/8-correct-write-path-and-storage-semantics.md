---
id: 8
slug: correct-write-path-and-storage-semantics
title: "Correct write-path and storage semantics"
kind: master-plan
created_at: 2026-07-07T15:24:21Z
intention: intention_01kx48hvkeemk9j4r828132s2h
---

# Correct write-path and storage semantics

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

en's PostgreSQL write path has correctness traps and silent failure modes. Today,
rewriting a live tuple with a different caveat payload is silently dropped (`ON CONFLICT
DO NOTHING`) while the caller receives a success token; adding a caveat to an existing
uncaveated grant creates a second live row while the unconditional grant stays in force;
there is no way to express "write this only if that tuple still exists" (no optimistic
concurrency), so concurrent grant/revoke administrators can race; a malformed caveat
payload in the database decodes to an *empty* payload and can flip an authorization
decision; the write token's snapshot construction leaves a transaction-id gap visible,
so reads pinned to a token are not strictly repeatable; writes cost one round trip per
tuple; and three of seven indexes on `relation_tuple` are dead weight no query can use.

After this initiative, tuple writes have SpiceDB-style "touch" semantics (a write of an
existing tuple with a different caveat replaces it atomically, and uniqueness is keyed
on object/relation/subject alone); writers can attach preconditions that make
grant/revoke races impossible and can mix writes and deletes in one atomic request;
storage decode failures surface as errors instead of degraded decisions; write tokens
denote exact, repeatable snapshots; bulk import/export exists for migration into and out
of en; and the index set matches the query set. Findings addressed: Theme C (C1, C3,
C5–C9) plus gaps E1 and E9 of
`docs/reviews/2026-07-07-architecture-performance-review.md`.

Out of scope: `en_transaction` pruning and reaper scheduling (owned by
docs/plans/37-schedule-background-maintenance-for-reaping-and-transaction-pruning.md
under master plan 6), the HTTP exposure of new write capabilities (master plan 9 owns
endpoint work; this plan changes the effect and storage layers and the existing
endpoints' behavior), and multi-tenancy.


## Decomposition Strategy

The split follows the natural layering of a write: uniqueness/replacement semantics
first (EP-45), then concurrency control on top of those semantics (EP-46), then the
orthogonal correctness sweeps (EP-47) and throughput work (EP-48), and finally index and
read-path hygiene (EP-49). EP-45 must come first because every later plan's behavior is
defined in terms of what a conflicting write *means*: preconditions (EP-46) are
specified against touch semantics, and batched writes (EP-48) must reproduce the same
conflict behavior in `unnest`-based multi-row statements. EP-47 groups the write-snapshot
tightening (C5) with the silent-decode fixes (C8) and the GC TOCTOU documentation (C7)
because all three are "storage must not lie" items verified by the same integration
suite (`en-postgres/integration-test/Main.hs`). EP-49 pairs dead-index removal (C9) with
lazy consistency resolution (C3) because both are read-path efficiency items measured
with EXPLAIN and round-trip counting.

An alternative decomposition — one plan per finding — was rejected as too granular
(eight plans, several trivial); another — merging EP-45 and EP-46 — was rejected because
touch semantics are independently valuable and verifiable, and the precondition design
deserves its own decision cycle (it changes the public `TupleStore` effect signature
that en-core consumers embed against).


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-45 | Adopt touch semantics for tuple writes | docs/plans/45-adopt-touch-semantics-for-tuple-writes.md | None | None | Complete |
| EP-46 | Add write preconditions and atomic mixed writes | docs/plans/46-add-write-preconditions-and-atomic-mixed-writes.md | EP-45 | None | Complete |
| EP-47 | Fail loudly on storage decode errors and tighten write snapshots | docs/plans/47-fail-loudly-on-storage-decode-errors-and-tighten-write-snapshots.md | None | None | Complete |
| EP-48 | Batch tuple writes and add bulk import and export | docs/plans/48-batch-tuple-writes-and-add-bulk-import-and-export.md | EP-45 | EP-46 | Complete |
| EP-49 | Trim dead indexes and resolve consistency lazily | docs/plans/49-trim-dead-indexes-and-resolve-consistency-lazily.md | None | None | Complete |


## Dependency Graph

EP-45 is the root. EP-46 hard-depends on it because a precondition like "this tuple must
not exist" is only well-defined once conflicting writes have specified replacement
semantics — implementing preconditions against today's `ON CONFLICT DO NOTHING` would
bake in behavior EP-45 is about to change. EP-48 hard-depends on EP-45 for the same
reason: a multi-row `unnest` insert must implement touch semantics, and writing it twice
(once against DO NOTHING, once against touch) is wasted work; it soft-depends on EP-46
because the batched statement should thread precondition checks if they exist by then,
but can land without them. EP-47 and EP-49 are independent of everything and of each
other; they can proceed in parallel at any time. EP-45, EP-47, and EP-49 all add or
modify codd migrations and can be worked concurrently since migration filenames are
timestamped, but they should land one at a time so each migration is tested against the
schema state it will actually meet in production.


## Integration Points

The `relation_tuple` uniqueness index (`relation_tuple_live_unique` in
`en-migrations/db/migrations/20260623044157_create-relation-tuples.sql`) is redefined by
EP-45 (drop `coalesce(caveat_name,'')` from the key; one live row per
object/relation/subject). EP-46 and EP-48 build statements against the EP-45 shape.
EP-49 removes `relation_tuple_object_live_idx`, `relation_tuple_subject_live_idx`, and
possibly `relation_tuple_created_xid_idx` — but the watch changelog plan
(docs/plans/53-add-a-watch-changelog-api.md, master plan 9) is the likely consumer of
`created_xid` indexing, so EP-49 must check that plan's status before dropping it and
record the coordination in both plans' Decision Logs. **Resolved 2026-07-09:** EP-49 dropped
both `*_live_idx` indexes (migration
`en-migrations/db/migrations/20260709232320_drop-dead-live-indexes.sql`) and **kept**
`relation_tuple_created_xid_idx`, reserved for EP-53; the mirror entries are in both Decision
Logs and a `COMMENT ON INDEX` carries the reservation in the live schema. The surviving set is
`relation_tuple_pkey`, `relation_tuple_live_unique`, `relation_tuple_object_hist_idx`,
`relation_tuple_subject_hist_idx`, `relation_tuple_deleted_xid_idx`, and the reserved
`relation_tuple_created_xid_idx`. Note that `subject_live_idx` was *not* dead — EP-46 created a
consumer for it — and was dropped on counterfactual evidence rather than on a zero scan count;
see Surprises & Discoveries.

**EP-48 raised the stakes on that index review.** Every batch write statement now depends
on `relation_tuple_live_unique` being the index a `LATERAL` probe reaches, and EP-48
measured what happens when the planner reaches for `relation_tuple_subject_hist_idx`
instead: a 55-second cross product. EP-49 must EXPLAIN the *write* statements, not only the
read path, against a populated and analyzed table at a batch size above
`EN_MAX_BATCH_SIZE`. Dropping or altering an index that the batched write statements probe
is a write-path change wearing a read-path costume.

The `TupleStore` effect (`en-core/src/En/Effect/TupleStore.hs`) write operations are
changed by EP-45 (documented touch semantics; possibly a distinct result reporting
created-vs-replaced), EP-46 (precondition parameter and a combined write-and-delete
operation), and EP-48 (bulk operations). EP-46 defines the final write signature; EP-48
extends it without altering EP-46's constructors. All three must update every
interpreter: PostgreSQL (`en-postgres/src/En/Postgres/TupleStore.hs`), the cached
interposer (`en-core/src/En/Effect/CachedTupleStore.hs`), and the in-memory conformance
store (`en-core/src/En/Conformance/Kikan.hs`). Cross-master-plan: the same effect gains
a read-side membership probe in
docs/plans/39-add-a-point-membership-probe-and-probe-first-check-evaluation.md (master
plan 7); the extensions are disjoint. **Resolved 2026-07-09:** EP-48 added exactly one
constructor, `ReadAllTuples :: Revision -> Int -> Maybe StoreCursor -> TupleStore m
TuplePage`, and left the write constructors byte-identical (`git diff bf9cd88 --
en-core/src/En/Effect/TupleStore.hs`); its batching is interpreter-internal. There is a
fourth interpreter the plan did not name — the fixture store in `en-core/test/Main.hs` —
which a new constructor also breaks until it is handled. `ReadAllTuples` is deliberately
uncached: `CachedTupleStore`'s catch-all `passthrough` forwards it, since export pages
are read once and caching them would evict hot check-path entries.

The write anchor and token minting (`writeVisibleSnapshot`, `anchorTransactionStatement`
in `en-postgres/src/En/Postgres/TupleStore.hs`) are modified by EP-47 (tightened
snapshot construction, loud parse failures) and exercised by every other plan's tests.
EP-47 owns the snapshot definition; EP-46 and EP-48 must not adjust it.

The wire surface for the write endpoints in `en-servant/src/En/Servant/API.hs` was extended
by EP-46 (precondition fields, mixed write request). **Resolved 2026-07-09:**
docs/plans/35-version-the-wire-contract-and-type-the-error-model.md (master plan 6) had
already landed, so the endpoints are `POST /v1/relationships` and
`POST /v1/relationships/delete` — not the `POST /tuples` / `DELETE /tuples` this section
originally named — and the new fields went into the v1 DTOs. EP-35's design also means new
statuses are `MultiVerb` response alternatives rather than thrown `ServerError`s: EP-46's 412
is a `PreconditionFailedFault` with a `Respond 412` in the shared `EnResponses` list, visible
in the generated OpenAPI document. Any later plan adding a status must do the same.


## Progress

- [x] EP-45: uniqueness keyed on object/relation/subject; caveat changes replace atomically
- [x] EP-45: integration tests prove payload updates and caveat additions take effect (no silent no-op, no duplicate live rows)
- [x] EP-46: preconditions enforced transactionally; precondition failure is a typed error
- [x] EP-46: atomic mixed write-and-delete in one request/token
- [x] EP-47: undecodable caveat payloads and malformed cursors are errors, not defaults
- [x] EP-47: write tokens denote exact snapshots (gap marked in-progress); GC TOCTOU invariant documented
- [x] EP-48: N-tuple writes are O(1) round trips (203 → 6 statements for 100 tuples); bulk import/export commands exist
- [x] EP-48: batch statements are pinned to index probes by LATERAL, so the plan cannot degrade with batch or table size
- [x] EP-49: dead indexes removed (after watch-plan coordination); EXPLAIN confirms remaining index coverage
- [x] EP-49: consistency resolution fetches only what the requested mode needs


## Surprises & Discoveries

**The wire contract is already versioned (affects EP-46).** This master plan's Integration
Points section names `POST /tuples` and `DELETE /tuples` as the endpoints EP-46 extends, and
poses the "if EP-35 has landed" conditional. It has landed: the endpoints are
`POST /v1/relationships` and `POST /v1/relationships/delete` (see the `test-server` recipe in
`Justfile`). EP-46's precondition fields therefore go into the v1 envelope, and the
conditional in Integration Points is resolved — no coordination with docs/plans/35 is needed.
Discovered while implementing EP-45, 2026-07-09.

**Zero-row statement results cannot stand in for a row's absence (affects EP-48).** EP-45's
plan specified the touch protocol as "soft-delete a differing live row, then insert with
`ON CONFLICT DO NOTHING`", inferring an idempotent no-op when both statements affect zero
rows. Under `READ COMMITTED` each statement takes its own snapshot, so a writer committing a
*different* caveat between them produces (0, 0) indefinitely and the write is silently
dropped — finding C1 again, in racing form. The delivered protocol instead observes the
identical live row with an explicit `SELECT EXISTS` over the full key, and falls back to an
`INSERT` without `ON CONFLICT` so PostgreSQL raises `unique_violation` when it cannot
converge. **EP-48 must carry this forward:** an `unnest`-based multi-row touch cannot verify
per-tuple with `SELECT EXISTS` and needs a set-oriented equivalent (for example, `RETURNING`
the inserted keys and comparing against the requested set). A batched statement that merely
reproduces "retire, then insert … DO NOTHING" would reintroduce the silent drop across the
whole batch. Discovered while implementing EP-45, 2026-07-09.

**Racing same-key writers now fail loudly rather than silently (affects EP-46).** Two writers
inserting different caveats for one identity, neither seeing a pre-existing live row, race the
unique index; the loser surfaces `StoreError`. This is the honest outcome, but it is not an
*arbitration* mechanism — a caller cannot say "write this only if that tuple still exists".
EP-46's preconditions remain the typed tool for that, and EP-46 should specify what a
precondition failure returns versus what this unique-violation `StoreError` returns, so the
two are distinguishable by callers. Discovered while implementing EP-45, 2026-07-09.

**`Justfile`'s `run-migrations` has grown a third guard stanza.** A
`20260709023019_datastore-metadata.sql` migration landed after this master plan was written.
EP-45 appended its guard as the fourth. EP-47 and EP-49, which also add migrations, should
expect to append rather than assume the plan-time stanza count.

**A must-exist precondition must lock `FOR UPDATE`, never `FOR SHARE` (affects EP-48).** EP-46's
plan specified `FOR SHARE`, reasoning that a racing revoke's `UPDATE` would have to wait for the
share lock. It would — but the racer's own must-exist check also holds a share lock, and share
locks are compatible, so both transactions pass their preconditions and then deadlock upgrading
to the exclusive lock their `UPDATE` needs. PostgreSQL returns `40P01 deadlock detected`, which
surfaces as `503 store_error, retryable: true` — an outage report for an arbitration loss, and one
a retry-on-retryable client spins on. `FOR UPDATE` blocks the second transaction at the `SELECT`;
when the first commits, the second re-evaluates the row under `READ COMMITTED` and fails its
precondition. **EP-48 must preserve this** when it rewrites `applyTupleWritesSession` with
`unnest` batches: a batched precondition check still has to take exclusive row locks, and a
set-oriented lock is the natural generalization of the current `LIMIT 1 … FOR UPDATE`.
Discovered while implementing EP-46, 2026-07-09.

**A concurrency test that never establishes overlap certifies nothing.** EP-46's two-`forkIO`
race scenario passed against the broken `FOR SHARE` implementation, because the first thread
completed its whole transaction before the second reached the row. The working shape: a third
connection holds the contended row's lock, the test *asserts both racers are blocked on it*, and
only then releases it. Any concurrency scenario added by EP-47, EP-48, or EP-49 should be written
this way, and should be run once against the bug it claims to catch. The integration suite now
needs `-threaded` for this reason. Discovered while implementing EP-46, 2026-07-09.

**`cabal test all | grep FAIL` is not a test result.** Two suites failed to *compile* against
EP-46's effect-constructor change and the grep reported no failures, because a suite that never
builds never prints one. Check the exit code. Discovered while implementing EP-46, 2026-07-09.

**The final write signature is `ApplyTupleWrites :: TupleWriteRequest -> TupleStore m
ConsistencyToken` (binds EP-48).** `writeTuples` and `deleteTuples` survive as helper functions
building degenerate requests, so call sites did not churn. `TupleFilter` carries a three-valued
`SubjectRelationFilter` rather than a `Maybe RelationName` — "any relation" and "no relation" are
different questions, and conflating them lets a must-exist precondition be satisfied by a
different grant than the one it names. EP-48 extends this effect (bulk export) without altering
the constructor. Discovered while implementing EP-46, 2026-07-09.


**The write session now returns an `Anchor`, not a token (binds EP-48).** EP-47 moved token
minting out of `applyTupleWritesSession` and into `interpretTupleStorePostgres`, so the session's
type is `Either Text Anchor`: `Left` is EP-46's precondition failure, and the interpreter mints
from the `Right`, turning a snapshot that will not parse into a `StoreError` rather than a token
that cannot see its own write. **EP-48's batched `applyTupleWritesSession` must keep this shape** —
it owns the write statements, not the token. Per Integration Points, EP-48 calls
`writeVisibleSnapshot`/`tokenFromAnchor` unmodified. Discovered while implementing EP-47, 2026-07-09.

**Adding an `EnError` constructor forces an `en-servant` edit (affects EP-48, EP-49).**
`enErrorToFault` in `en-servant/src/En/Servant/Seam.hs` is a total case over `EnError`, so a new
constructor breaks the build until it has an HTTP mapping. EP-47's `InvalidCursor` joins the
`BadRequestFault` family as a non-retryable 400 under the stable code `invalid_cursor`. Any later
plan adding a constructor must budget for the same edit, and must pick a status that already has a
`Respond` alternative in `EnResponses` or add one (see the resolved note in Integration Points).
Discovered while implementing EP-47, 2026-07-09.

**A row planted by raw SQL is invisible at every token already in hand (affects EP-48).** EP-47's
malformed-payload scenario passed green while asserting nothing: it planted a corrupt row with a
raw `INSERT`, then read at a revision minted *before* that insert, so the visibility predicate
excluded the row and no decode ever ran. Any scenario that seeds state outside the effect — which
EP-48's bulk-import tests will do constantly — must take a fresh `headRevision` after seeding.
Discovered while implementing EP-47, 2026-07-09.

**C7 is documented, not closed.** The GC TOCTOU remains reachable in principle: token validation
reads the horizon, then the tuple read runs, and the reaper can delete in between. EP-47 states the
`EN_GC_WINDOW` ≫ request-duration invariant in the deployment guide, the spec §7, and the operations
guide's variable table. Closing the race would require holding the horizon against the reaper for
the read's duration — a design decision no finding in the review asked for, and out of scope for
every plan in this master plan. Discovered while implementing EP-47, 2026-07-09.

**Batching a statement changes its plan, and `unnest` carries no statistics (binds EP-49, and any
later batched statement).** Finding C6 counts round trips, so EP-48's plan reasoned entirely about
round trips. But collapsing N indexed single-row statements into one N-row join replaces a plan the
planner cannot get wrong with one it *estimates* — and a `Function Scan` gives it nothing to estimate
from. Past roughly a thousand entries PostgreSQL abandoned the nested loop over
`relation_tuple_live_unique` and chose a merge join over `relation_tuple_subject_hist_idx`, whose
columns are the subject plus the object *type* and not the object id. `object_id` — the only
discriminating column in a bulk import — was demoted to a join filter, and the merge computed the
cross product: **55.8 seconds and 500 million discarded pairs for one 5,000-tuple statement against a
100,000-row table.** The measured crossover sat between batch sizes 1,000 and 2,000, and
`EN_MAX_BATCH_SIZE` defaults to **1,000**; an operator raising it slightly would have bought a table
scan per HTTP write, with no code change and no warning.

It hid from every check this master plan had specified. Integration tables are small. The 100-tuple
statement-count measurement is small. And the *first* 100,000-tuple import ran in 3.12 s because
autoanalyze had not yet fired — the second took 272 s. A performance property that depends on when
autovacuum last ran is not a property.

The fix pins all three batch statements to a `LATERAL` probe driven by the unnested batch, so the
batch is always the outer relation and each entry probes the unique index once (`LIMIT 1` is exact
under `relation_tuple_live_unique`, and also stops the planner flattening the subquery back into the
join). 55,792 ms → 14.4 ms; the 100k re-import 272 s → 3.57 s. **EP-49 inherits two obligations:** its
EXPLAIN work must run against a table large enough to have statistics and at a batch size well above
`EN_MAX_BATCH_SIZE`, not against an empty fixture; and `relation_tuple_subject_hist_idx` is now known
to be the index the planner reaches for when it goes wrong here, which is context for any decision
about it. Discovered while implementing EP-48, 2026-07-09.

**Two ways an integration suite can certify nothing, both found in scenarios written for EP-48
(affects EP-49).** First, a retry ladder can launder a bug: a two-copy duplicate-key batch resolves
last-wins *by accident* of the retry, because each attempt inserts the earliest surviving copy and
drops the rest. The scenario passed against the deliberately broken code. Four copies are needed —
that is where the fallback's `ON CONFLICT`-less insert receives two same-identity rows and raises.
Second, within one transaction a batch always converges on its first attempt, so the convergence
check, the second attempt, the fallback, and the ordinal bookkeeping were all unreachable from a
single-connection suite; an injected off-by-one in the ordinal mapping left the entire suite green.
Only `runBatchTouchRaceScenario`, which forces a racer to hold an uncommitted conflicting row and
asserts the writer is blocked before releasing it, reaches them. Both scenarios were then run once
against the bug they claim to catch, per EP-46's standing rule. Discovered while implementing EP-48,
2026-07-09.

**`loadServerConfig` fails closed without API keys, which is right for a server and wrong for a
tool.** `en-server import` binds no port and serves no request, yet the shared configuration loader
refused to start it without `EN_API_KEYS_READ_WRITE`. EP-48 split `StoreConfig` out of `ServerConfig`
(`en-server/app/Config.hs`); `loadStoreConfig` reads only `EN_DATABASE_URL`, `EN_SCHEMA_PATH`,
`EN_GC_WINDOW`, and `EN_POOL_*`, and `parseServerConfig` is defined in terms of `parseStoreConfig` so
the two cannot drift. Any later plan adding an `en-server` subcommand should reach for
`withSubcommandStore` rather than `loadServerConfig`. Discovered while implementing EP-48, 2026-07-09.

**`cabal build en-postgres` does not relink `en-server`.** The first post-fix measurement of the
`LATERAL` rewrite showed no improvement at all, because `cabal list-bin en-server` still named a
binary linking the pre-fix library. Build the executable before timing it. Discovered while
implementing EP-48, 2026-07-09.

**A plan's "this index is dead" gate outlived the code it was written against (EP-49, and a
lesson for any audit plan).** EP-49 predicted both partial `*_live_idx` indexes would appear in
no query plan, and installed a stop sign: if one *does* appear, keep it. The stop sign fired —
but for a reason EP-49 could not have known, because EP-46 landed in between and added
subject-scoped precondition filters (`TupleFilter` makes `objectId` optional while `objectType`
is mandatory), which the planner serves from `relation_tuple_subject_live_idx`. The gate's text
said keep; the gate's *purpose* was "do not regress a plan". A counterfactual — drop the index
inside a rolled-back transaction, re-EXPLAIN — showed `relation_tuple_subject_hist_idx` taking
over with a byte-identical `Index Cond`, equal buffers, and lower latency. Used is not needed.
Both indexes were dropped; a 20,000-row insert went 0.573 s → 0.378 s, and dropping only the
genuinely-dead one measured within noise. **The generalizable rule: an audit that asks "is this
index scanned?" is asking the wrong question. Ask "does removing it change any plan?" — the
counterfactual is cheap, exact, and immune to a sibling plan having quietly created a consumer.**
Discovered while implementing EP-49, 2026-07-09.

**EP-49's TTL-cached horizon would have been a security regression; the plan's own rationale was
inverted (affects any later plan that caches `oldestRetainedXid`).** EP-49's Decision Log
mandated putting the GC horizon behind the optimized-revision TTL cache, reasoning a stale
horizon "can only *under*-state how much history is retained, never accept a too-old token".
Both halves are backwards. `oldestRetainedXidStatement` is `min(xid)` over transactions inside
the GC window, so as wall-clock advances the horizon **rises monotonically**;
`validateTokenMetadata` rejects when `snapshot.xmax <= horizon`, so a *larger* horizon rejects
*more*. A TTL-stale horizon is therefore **smaller, and rejects fewer tokens** — it honours
tokens whose history the reaper already destroyed, for up to one TTL. That widens EP-47's
documented C7 TOCTOU window from request-duration to `TTL + request-duration`, through
`EN_OPTIMIZED_REVISION_CACHE_TTL_MS`, a knob whose documented meaning is "how stale may a
revision be". An operator raising it to cut read latency would silently extend how long an
expired consistency token keeps working. The cache was not built; `TtlCache a` is generalized so
it can be added later behind its own knob. **Any later plan that wants to cache the horizon must
supply a fresh safety argument and its own configuration knob — never this one.** Lazy resolution
alone met the full acceptance table (1/1/1/2), because the horizon fetch vanishes entirely from
the token-less modes that dominate the check path. Discovered while implementing EP-49,
2026-07-09.

**The maintenance batch statements hash-joined a full table scan; fixed in EP-49 with a `ctid`
join (binds docs/plans/37-schedule-background-maintenance-for-reaping-and-transaction-pruning.md,
master plan 6).** EP-49's EXPLAIN sweep found `reapDeletedTuplesBatchStatement` planning as a
`Hash Join` whose outer side is a `Seq Scan` of all 250,024 rows, to reap a `LIMIT 1000` victim
set: 27 ms. PostgreSQL's estimates are nearly tied (6684.93 hash join vs 6903.11 nested loop) and
it picks the slower plan, pricing 1,000 cached primary-key probes as random I/O.

What makes it severe rather than untidy is the loop: `drain` in `en-server/app/Maintenance.hs`
re-runs the batch session until it returns a short batch, so a backlog of `B` rows costs
`B / batchSize` full table scans. The cost is `table_pages × batches` — quadratic in table size,
on the one code path guaranteed to meet large tables. `pruneTransactionsBatchStatement` carries
the identical shape over `en_transaction`, which accrues a row per write transaction.

Joining the victim CTE back on `ctid` rather than the primary key turns both into a nested loop
over a `Tid Scan`: 27.0 ms → 2.2 ms per reap batch, and a full 50,015-row drain 1.330 s → 0.194 s.
`MATERIALIZED` and `id IN (subquery)` were both tried and still seq-scan — the row estimate was
never wrong, only the costing of the probes. `ctid` is safe because soft-deleted rows are never
updated again (both writers restrict their `UPDATE` to `deleted_xid IS NULL`), `en_transaction`
rows are never updated, and vacuum cannot recycle a line pointer for a tuple the statement's own
snapshot can still see. It is self-correcting rather than immune: on a small table the planner
still hash-joins on `ctid`, harmlessly, which is why the plan shape cannot be asserted from the
ephemeral integration fixture.

This was taken *inside* this master plan despite Vision & Scope assigning reaper work to EP-37,
because EP-37 owns *when* maintenance runs, not the plan shape of statements that already exist,
and because this master plan's own Decision Log binds every batched statement over
`relation_tuple` to an index-probe plan. Scope is a reason to route a fix, not a reason to ship a
known quadratic drain. The mirror note is in EP-37's Decision Log.

Note also that the sweep initially *appeared* to show EP-49 causing this — the plan changed
between the pre- and post-drop runs because autovacuum moved the `deleted_xid` statistics.
Recreating the dropped indexes in a rolled-back transaction produced a byte-identical plan,
proving the drop innocent. **A before/after EXPLAIN across a schema change is not a controlled
experiment unless statistics are held still or the counterfactual is run in the same session.**
Discovered and fixed while implementing EP-49, 2026-07-09.

**The precondition statements are sargable only because PostgreSQL re-plans them per execution
(affects any plan touching `TupleFilter` SQL).** `lockMatchingLiveTupleStatement` and
`matchingLiveTupleExistsStatement` are `Statement.preparable`, and their
`($n::text IS NULL OR col = $n)` idiom becomes an index condition only after the planner folds a
known-NULL parameter away — which a *custom* plan does and a *generic* plan cannot. Under
`plan_cache_mode = force_generic_plan` both collapse to a parallel sequential scan of the whole
table (250,019 rows removed by filter, 19.3 ms versus 0.059 ms), and the `lock` variant does it
holding `FOR UPDATE` inside a write transaction. This is not a live defect — PostgreSQL adopts a
generic plan only when its estimated cost is no worse than the custom average, and here generic is
~500× dearer, so custom wins permanently; the driven-workload `idx_scan` counters confirm the real
server takes the index. It is recorded because the safety margin lives in the planner's cost
comparison rather than in the SQL, and an edit that makes the generic plan look cheap would put a
full-table lock scan inside every guarded write with no other symptom. Discovered while
implementing EP-49, 2026-07-09.


## Decision Log

- Decision: Order touch semantics (EP-45) before preconditions (EP-46) as a hard dependency.
  Rationale: Preconditions are specified against conflict behavior; defining them over ON CONFLICT DO NOTHING would encode semantics the very next plan changes.
  Date: 2026-07-07
- Decision: Keep en_transaction pruning out of this master plan.
  Rationale: It is a scheduled-job wiring concern owned by docs/plans/37 (master plan 6); this plan owns what writes mean, not when maintenance runs.
  Date: 2026-07-07
- Decision: EP-49 must coordinate with the watch API plan before dropping relation_tuple_created_xid_idx.
  Rationale: A changelog feed ordered by created_xid is the one plausible consumer of that index; dropping and re-adding an index on a large table is avoidable churn.
  Date: 2026-07-07
- Decision: The touch protocol verifies an identical live row by observing it, not by inferring it from zero-row statement counts; a non-converging retry falls back to an INSERT without ON CONFLICT so PostgreSQL raises unique_violation.
  Rationale: The inference is unsound under READ COMMITTED and its failure mode is finding C1 itself, in racing form. EP-48 inherits this constraint for its batched statements.
  Date: 2026-07-09
- Decision: EP-45 left the TupleStore effect signature untouched, as planned; EP-46 still owns the final write signature.
  Rationale: Touch semantics are observable through reads, so no created-vs-replaced result was needed; changing the signature twice in consecutive plans would churn every interpreter for no behavioral gain.
  Date: 2026-07-09
- Decision: Must-exist preconditions lock FOR UPDATE, not FOR SHARE; EP-48's batched checks inherit this.
  Rationale: Share locks are compatible, so two racing guarded writes both pass their checks and then deadlock upgrading to the exclusive lock their UPDATE needs. The loser gets a retryable-looking 503 for what is actually an arbitration loss.
  Date: 2026-07-09
- Decision: The wire-coordination conditional with docs/plans/35 is resolved in the affirmative; new statuses ship as MultiVerb response alternatives.
  Rationale: EP-35 landed on 2026-07-08, before EP-46 began. Its typed error model routes every handler failure through EnFault into a declared response alternative, so a status reachable only via a thrown ServerError would be absent from the API type and the OpenAPI document.
  Date: 2026-07-09
- Decision: Token minting lives in the interpreter, not the write session; EP-48's batched session returns an Anchor.
  Rationale: A snapshot that will not parse is not a database error, and hasql's Session has no ergonomic channel for a pure post-processing failure. Lifting the fallible step makes it a first-class StoreError instead of the silent fallback that minted a token unable to see its own write.
  Date: 2026-07-09
- Decision: EP-47 maps InvalidCursor to a 400 itself rather than deferring the HTTP mapping to docs/plans/35.
  Rationale: enErrorToFault is a total case; the mapping is a build requirement, not a scheduling choice. docs/plans/35 has landed and already provides the non-retryable BadRequestFault this belongs in.
  Date: 2026-07-09
- Decision: Every batched statement over relation_tuple drives from the unnested batch through a LATERAL probe of relation_tuple_live_unique, never as a bare join and never via NOT EXISTS. This binds EP-49 and any later plan that batches a statement.
  Rationale: A Function Scan has no statistics, so the plan is the planner's guess rather than the statement's property. Left to choose, it picks a merge join on an index without object_id past ~1,000 entries and computes the cross product — 55.8 seconds for one 5,000-tuple statement, against 14.4 milliseconds for the LATERAL form. EN_MAX_BATCH_SIZE defaults to 1,000, one step from the cliff, and autoanalyze can move the cliff under a running import.
  Date: 2026-07-09
- Decision: A batched statement's cost is argued from its EXPLAIN plan at production batch and table sizes, not from its round-trip count. EP-49's index review must EXPLAIN against a populated, analyzed table.
  Rationale: EP-48 delivered finding C6's round-trip reduction (203 → 6) in a change that simultaneously introduced a 55-second statement. Round-trip count and cost are independent axes, and this master plan's acceptance criteria only measured the first.
  Date: 2026-07-09
- Decision: Bulk import and export read StoreConfig, not ServerConfig; en-server subcommands never require serving credentials.
  Rationale: A command that binds no port has no API keys, rate limit, or TLS material to configure. loadServerConfig's fail-closed behavior is correct for a server and was refusing a bulk load.
  Date: 2026-07-09
- Decision: The EP-49 ↔ EP-53 coordination is resolved as KEEP: relation_tuple_created_xid_idx survives, reserved for the watch changelog feed. Mirror entries are recorded in both plans' Decision Logs, and a COMMENT ON INDEX records the reservation in the live schema.
  Rationale: docs/plans/53 is Not Started, but its Decision Log affirmatively claims the index — its window query bounds each arm with `created_xid >= $start_xmin::xid8` precisely to keep it load-bearing, and states "this plan is the consumer that keeps it". That is the affirmative claim EP-49's gate looked for. Dropping and re-adding an index on a large table is avoidable churn. If EP-53 later abandons the xmin-bounded design, EP-53 owns the drop.
  Date: 2026-07-09
- Decision: An index audit is settled by counterfactual removal, not by scan counters. relation_tuple_subject_live_idx was dropped despite appearing in a live query plan.
  Rationale: EP-49's gate assumed an index the planner chooses is an index the planner needs. EP-46 falsified that by adding subject-scoped precondition filters that select the index; dropping it hands the identical Index Cond to relation_tuple_subject_hist_idx with equal buffers and lower latency. Nothing regresses, so the gate's purpose is met while its text is not. Both live indexes had to go together for the write win (0.573 s → 0.378 s on a 20k-row insert); dropping the unambiguously dead one alone was within measurement noise.
  Date: 2026-07-09
- Decision: The garbage-collection horizon is not cached. EP-49's mandate to put it behind the optimized-revision TTL is reversed; TtlCache is still generalized to `TtlCache a`.
  Rationale: EP-49's safety argument was inverted. The horizon rises monotonically and validateTokenMetadata rejects when snapshot.xmax <= horizon, so a TTL-stale (smaller) horizon rejects fewer tokens — it honours tokens whose history the reaper destroyed, for up to one TTL, widening EP-47's C7 window. Worse, it would do so through EN_OPTIMIZED_REVISION_CACHE_TTL_MS, overloading a read-latency knob with a token-expiry meaning. Lazy resolution alone delivers finding C3's full acceptance table (1/1/1/2). Any future horizon cache needs its own knob and its own argument.
  Date: 2026-07-09


## Outcomes & Retrospective

All five child plans are Complete. Every finding this master plan claimed is addressed:
Theme C (C1, C3, C5–C9) plus gaps E1 and E9 of
`docs/reviews/2026-07-07-architecture-performance-review.md`.

**What exists now that did not before.** A write of an existing tuple with a different caveat
replaces it atomically, keyed on object/relation/subject alone (C1, EP-45). Writers attach
must-exist and must-not-exist preconditions and mix writes with deletes in one atomic request
and one token (E1, EP-46). Storage decode failures — malformed caveat payloads, malformed
cursors — are typed errors rather than silently-empty defaults that could flip an
authorization decision (C8, EP-47). Write tokens denote exact, repeatable snapshots (C5,
EP-47). N-tuple writes cost O(1) round trips, 203 → 6 statements for 100 tuples, and
`en-server import`/`export` exist for migration into and out of en (C6, E9, EP-48). The index
set matches the query set, and consistency resolution fetches only what the requested mode
needs (C9, C3, EP-49). C7 is documented rather than closed, deliberately and with the
reasoning recorded.

**Measured.** Write path: 203 → 6 statements per 100-tuple write; a 5,000-entry batch
statement 55,792 ms → 14.4 ms once pinned to a `LATERAL` index probe; a 100,000-tuple
re-import 272 s → 3.57 s; a 20,000-row insert 0.573 s → 0.378 s after the dead indexes went,
with ~36 MB of index storage reclaimed. Read path: consistency resolution 3 → 1 round trips
for `MinimizeLatency`, `FullyConsistent` and `AtExactSnapshot`, 3 → 2 for `AtLeastAsFresh`.
Maintenance: a full reap of a 50,015-row backlog on a 250,024-row table 1.330 s → 0.194 s, and
the drain is no longer quadratic in table size.

**The decomposition held.** EP-45 before EP-46 was the right hard dependency and paid for
itself immediately: EP-45's discovery that zero-row statement counts cannot stand in for a
row's absence became a constraint EP-48 inherited, and preconditions specified against
`ON CONFLICT DO NOTHING` would have encoded semantics EP-45 then changed. EP-47 and EP-49 were
correctly identified as independent. The one seam that leaked was EP-46 → EP-49: EP-46 added
statement shapes that made an index EP-49 had already condemned load-bearing, and only the
EXPLAIN gate caught it. A plan that names specific code artifacts as dead is making a claim
about a working tree it will not meet.

**Three lessons worth carrying forward, each learned by a plan being wrong in writing.**

1. *Round-trip count and cost are independent axes.* EP-48 delivered C6's round-trip reduction
   in a change that simultaneously introduced a 55-second statement, because a `Function Scan`
   carries no statistics and the planner guessed. Every batched statement over `relation_tuple`
   is now pinned to a `LATERAL` probe, and the acceptance bar for a batched statement is its
   EXPLAIN plan at production batch and table sizes — never its round-trip count.

2. *An index audit must ask "does removing it change any plan?", not "is it scanned?"* EP-49
   asked the second question, got "yes" for `subject_live_idx`, and would have kept 20 MB of
   write amplification buying a plan measurably slower than its fallback. The counterfactual —
   drop inside a rolled-back transaction, re-EXPLAIN — is cheap, exact, and immune to a sibling
   plan having quietly created a consumer. It also proved the drop innocent of a reaper plan
   regression that autovacuum had caused.

3. *A cache's safety argument must name the direction of staleness.* EP-49's plan asserted a
   TTL-stale GC horizon is "strictly conservative". It is the precise opposite: the horizon
   rises monotonically, validation rejects below it, so a stale horizon accepts expired tokens.
   Shipping it would have widened a documented TOCTOU race through a knob labelled for read
   latency. The lazy-resolution work delivered C3's full acceptance table without it.

**Tests can certify nothing, in more ways than a plan anticipates.** This initiative found:
a concurrency scenario that never established overlap (EP-46); `cabal test all | grep FAIL`
reporting success for suites that failed to compile (EP-46); a malformed-payload scenario
reading at a revision minted before it planted the row, so no decode ever ran (EP-47); a retry
ladder laundering a duplicate-key bug until a fourth copy was added (EP-48); a single-connection
suite leaving the convergence check, the fallback, and the ordinal mapping unreachable (EP-48);
and a seed script whose row count was an artifact of its own `ON CONFLICT` clause (EP-49). The
standing rule EP-46 introduced — run every new scenario once against the bug it claims to catch
— caught the last three and was applied to both of EP-49's new assertions.

**A fourth lesson, learned late.** Scope routes a fix; it does not license shipping a known
defect. The reaper's quadratic drain was filed as "EP-37's problem" and recorded, because this
master plan's Vision & Scope names reaper work as out of scope — but EP-37 owns *when*
maintenance runs, not the plan shape of statements that already existed, and this master plan's
own Decision Log binds every batched statement over `relation_tuple` to an index-probe plan. The
severity argument (the batch session is drained in a loop, so the cost is
`table_pages × batches`) was never made until it was challenged. The fix took one statement
rewrite each and the EXPLAIN harness was already warm. When a boundary and a measured defect
disagree, make the severity argument out loud before invoking the boundary.

**Left open, with owners.** The precondition
statements are sargable only because PostgreSQL prefers a custom plan to a generic one, a
margin that lives in the cost model rather than the SQL. C7's GC TOCTOU remains reachable in
principle, bounded by the `EN_GC_WINDOW` ≫ request-duration invariant EP-47 documented in the
deployment guide, the spec §7, and the operations guide. `relation_tuple_created_xid_idx` is
retained on EP-53's promise; if that plan abandons its `created_xid`-bounded window, it owns
the drop.
