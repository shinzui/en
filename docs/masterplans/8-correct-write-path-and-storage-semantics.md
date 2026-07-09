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
| EP-48 | Batch tuple writes and add bulk import and export | docs/plans/48-batch-tuple-writes-and-add-bulk-import-and-export.md | EP-45 | EP-46 | Not Started |
| EP-49 | Trim dead indexes and resolve consistency lazily | docs/plans/49-trim-dead-indexes-and-resolve-consistency-lazily.md | None | None | Not Started |


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
record the coordination in both plans' Decision Logs.

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
plan 7); the extensions are disjoint.

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
- [ ] EP-48: N-tuple writes are O(1) round trips; bulk import/export commands exist
- [ ] EP-49: dead indexes removed (after watch-plan coordination); EXPLAIN confirms remaining index coverage
- [ ] EP-49: consistency resolution fetches only what the requested mode needs


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


## Outcomes & Retrospective

(To be filled during and after implementation.)
