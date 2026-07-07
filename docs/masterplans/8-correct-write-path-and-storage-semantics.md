---
id: 8
slug: correct-write-path-and-storage-semantics
title: "Correct write-path and storage semantics"
kind: master-plan
created_at: 2026-07-07T15:24:21Z
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
| EP-45 | Adopt touch semantics for tuple writes | docs/plans/45-adopt-touch-semantics-for-tuple-writes.md | None | None | Not Started |
| EP-46 | Add write preconditions and atomic mixed writes | docs/plans/46-add-write-preconditions-and-atomic-mixed-writes.md | EP-45 | None | Not Started |
| EP-47 | Fail loudly on storage decode errors and tighten write snapshots | docs/plans/47-fail-loudly-on-storage-decode-errors-and-tighten-write-snapshots.md | None | None | Not Started |
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

The wire surface for existing write endpoints (`POST /tuples`, `DELETE /tuples` in
`en-servant/src/En/Servant/API.hs`) is extended by EP-46 (precondition fields, mixed
write request) — this must be coordinated with the versioned wire contract from
docs/plans/35-version-the-wire-contract-and-type-the-error-model.md (master plan 6):
if EP-35 has landed, new fields go into the v1 envelope; if not, EP-46 adds fields to
the current DTOs and EP-35 absorbs them.


## Progress

- [ ] EP-45: uniqueness keyed on object/relation/subject; caveat changes replace atomically
- [ ] EP-45: integration tests prove payload updates and caveat additions take effect (no silent no-op, no duplicate live rows)
- [ ] EP-46: preconditions enforced transactionally; precondition failure is a typed error
- [ ] EP-46: atomic mixed write-and-delete in one request/token
- [ ] EP-47: undecodable caveat payloads and malformed cursors are errors, not defaults
- [ ] EP-47: write tokens denote exact snapshots (gap marked in-progress); GC TOCTOU invariant documented
- [ ] EP-48: N-tuple writes are O(1) round trips; bulk import/export commands exist
- [ ] EP-49: dead indexes removed (after watch-plan coordination); EXPLAIN confirms remaining index coverage
- [ ] EP-49: consistency resolution fetches only what the requested mode needs


## Surprises & Discoveries

(None yet.)


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


## Outcomes & Retrospective

(To be filled during and after implementation.)
