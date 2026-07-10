---
id: 9
slug: complete-the-en-api-surface
title: "Complete the en API surface"
kind: master-plan
created_at: 2026-07-07T15:24:21Z
intention: intention_01kx4y4empedt9g83mprcrew89
---

# Complete the en API surface

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Measured against Zanzibar, SpiceDB, and OpenFGA, en's API surface is missing the
standard companions to check/lookup/expand. There is no way to list or filter
relationships over HTTP (the store effects exist; no endpoint does), so an operator
cannot answer "what grants exist for user X?" or offboard a user without bespoke SQL.
Read responses never return the consistency token they evaluated at, breaking zookie
chaining and blocking HTTP Biscuit minting. There is no flat, cursored "who has access
to this object?" query (lookup-subjects) — expand returns a tree that callers would have
to flatten themselves, incorrectly. There is no watch/changelog feed for downstream
cache invalidation, search-index ACL sync, or revocation signals, even though the
xid8 soft-delete design means the changelog already exists in the tables. And the schema
is loaded once at startup with no reload, no read-schema endpoint, and no validation of
stored tuples against a changed schema.

After this initiative, en's HTTP API supports: reading relationships by filter and
deleting by filter; checked-at consistency tokens on every read response;
lookup-subjects with correct caveat/operator handling; a cursored watch feed of tuple
changes since a revision, bounded by the GC horizon; and a managed schema lifecycle
(read endpoint, explicit reload, stored-tuple validation against a candidate schema, and
a documented compatible-change taxonomy). Findings addressed: gaps E2–E6 of
`docs/reviews/2026-07-07-architecture-performance-review.md`.

Out of scope: gRPC and non-Haskell SDKs (explicit non-goals), OpenAPI generation (owned
by docs/plans/35-version-the-wire-contract-and-type-the-error-model.md under master
plan 6), multi-tenancy, and Biscuit endpoints (master plan 10, which consumes EP-51's
tokens).


## Decomposition Strategy

Each child delivers one externally visible API capability, independently demonstrable
with curl against a running en-server, which is exactly the granularity the gap analysis
used. EP-50 (relationship read + delete-by-filter) is one plan because delete-by-filter
falls out nearly for free once the read filter exists — they share the filter grammar
and its SQL compilation. EP-51 (checked-at tokens) is small but isolated because it
touches the semantics of every read response and unblocks two other initiatives (client
freshness chaining and HTTP Biscuit minting in
docs/plans/57-mint-biscuit-grants-over-http.md). EP-52 (lookup-subjects) is a real
algorithm addition to en-core plus an endpoint, kept separate from the engine master
plan because it is a new feature, not a fix. EP-53 (watch) spans storage (changelog
query over `relation_tuple`/`en_transaction`), core (a new effect), and API (a cursored
feed endpoint) — one vertical slice. EP-54 (schema lifecycle) collects everything about
schemas-at-runtime because reload, read-back, and validation share the schema-hash and
token-invalidation machinery.

An alternative decomposition splitting each vertical slice into core/storage/API layers
was rejected: it would triple the plan count and none of the layers is independently
verifiable without the others.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-50 | Expose relationship read and delete-by-filter endpoints | docs/plans/50-expose-relationship-read-and-delete-by-filter-endpoints.md | None | None | In Progress |
| EP-51 | Return checked-at consistency tokens from read responses | docs/plans/51-return-checked-at-consistency-tokens-from-read-responses.md | None | None | Not Started |
| EP-52 | Add a lookup-subjects API | docs/plans/52-add-a-lookup-subjects-api.md | None | None | Not Started |
| EP-53 | Add a watch changelog API | docs/plans/53-add-a-watch-changelog-api.md | None | None | Not Started |
| EP-54 | Manage the schema lifecycle at runtime | docs/plans/54-manage-the-schema-lifecycle-at-runtime.md | None | EP-50 | Not Started |


## Dependency Graph

All five children are implementable in parallel against the current tree; none produces
an artifact another cannot stub. EP-54 soft-depends on EP-50 because its stored-tuple
validation pass wants the relationship read filter to enumerate tuples per type, but it
can use the store effects directly if EP-50 has not landed. The meaningful ordering
constraints are external. First, all new endpoints must land inside whatever versioned
wire contract and error envelope
docs/plans/35-version-the-wire-contract-and-type-the-error-model.md (master plan 6)
establishes — implementing EP-50/51/52/53 before EP-35 means shipping them under the
unversioned contract and migrating them once EP-35 lands; prefer landing EP-35 first.
Second, EP-52 (lookup-subjects) shares evaluation machinery with the engine fixes in
master plan 7; it benefits from the cycle semantics of docs/plans/40 and the cursor
discipline of docs/plans/42, and implementing it before those means inheriting the
engine's current defects in a brand-new API. Third,
docs/plans/57-mint-biscuit-grants-over-http.md (master plan 10) hard-depends on EP-51.


## Integration Points

The relationship filter type — which fields of (object type, object id, relation,
subject type, subject id, caveat name) may be constrained — is defined by EP-50 as both
a wire DTO in `en-servant/src/En/Servant/API.hs` and a core query type consumed by the
store. EP-53 reuses the same filter for scoping watch subscriptions, and EP-54 uses it
for per-type tuple enumeration during schema validation. EP-50 owns the definition.

Checked-at token plumbing is defined by EP-51: `check`/`lookup`/`expand` results in
`en-core` gain the resolved revision, and every read response DTO gains a token field.
EP-52 and EP-53 must include the same field in their new response DTOs from day one
(they consume EP-51's convention; if they land first, they add the field following the
review's E3 description and EP-51 reconciles).

The watch changelog storage query (EP-53) reads `relation_tuple.created_xid`/
`deleted_xid` ordered by transaction visibility, likely via
`relation_tuple_created_xid_idx` — the index that
docs/plans/49-trim-dead-indexes-and-resolve-consistency-lazily.md (master plan 8)
proposes to drop as dead. EP-53 and EP-49 must reconcile before either lands the index
change; whichever goes first records the outcome in both Decision Logs. EP-53's cursor
recovery is bounded by the GC horizon maintained by
docs/plans/37-schedule-background-maintenance-for-reaping-and-transaction-pruning.md
(master plan 6): once `en_transaction` rows and reaped tuples are pruned, a watch cursor
older than the horizon must return a typed "cursor expired" error, exactly like a stale
consistency token.

Schema state in `en-server` (currently a `ValidSchema` loaded once from
`EN_SCHEMA_PATH` in `en-server/app/Main.hs`) becomes mutable state under EP-54 (reload
swaps it atomically; in-flight requests keep the old schema). Every other endpoint reads
the schema through whatever handle EP-54 introduces; until then, plans use the existing
immutable argument and EP-54 rewires them.


## Progress

- [ ] EP-50: GET/query endpoint lists relationships by filter with keyset pagination
- [ ] EP-50: delete-by-filter endpoint with dry-run count; offboarding a user is one call
- [ ] EP-51: every read response carries the token it was evaluated at; write-then-read-at-token round-trips
- [ ] EP-52: lookup-subjects returns a flat, cursored subject set with correct caveat and operator handling
- [ ] EP-53: watch feed streams tuple changes since a revision; expired cursors rejected with a typed error
- [ ] EP-54: schema read endpoint and explicit reload without restart; old-schema requests drain safely
- [ ] EP-54: stored-tuple validation against a candidate schema; compatible-change taxonomy documented


## Surprises & Discoveries

- 2026-07-09 (EP-50, affects EP-51/53/54): the external sequencing this plan recommended
  has already happened. Master plans 6, 7, and 8 are all Complete, so
  docs/plans/35 (versioned wire contract), docs/plans/40 and 42 (engine semantics), and
  docs/plans/49 (index trim) all landed before any child here started. Every child must
  therefore be written against the `/v1` path prefix, the `EnResponses`/`EnResult`
  `MultiVerb` response list, and the `ErrorEnvelopeWire` error envelope defined in
  `en-servant/src/En/Servant/API.hs` and `en-servant/src/En/Servant/Seam.hs`. The
  JSON transcripts written into the child plans on 2026-07-07 predate that contract and
  are stale wherever they show unversioned paths or `{"tag": ...}` sum encodings.

- 2026-07-09 (EP-50, binds EP-53 and EP-54): the tree already has a live tuple filter.
  `TupleFilter` in `en-core/src/En/Effect/TupleStore.hs`, added by docs/plans/46 for write
  preconditions, carries exactly the fields EP-50's `RelationshipFilter` proposed, minus
  `caveatName`, with `objectType` mandatory, and with a strictly better subject-relation
  encoding: a three-valued `SubjectRelationFilter` (`Any`/`No`/`Exact`) rather than
  `Maybe RelationName`. The `Maybe` spelling the child plan proposed is the exact
  ambiguity `SubjectRelationFilter`'s Haddock says it exists to remove — under it, a
  filter for `space:x#member@user:alice` also matches
  `space:x#member@user:alice#admin`. EP-50 therefore defines `RelationshipFilter` as a
  widening of `TupleFilter` (optional `objectType`, added `caveatName`, same
  `SubjectRelationFilter`), and EP-53/EP-54 consume that shape, not the one their
  Integration Points paragraph describes.

- 2026-07-09 (EP-50, wire-surface conflict): `POST /v1/relationships/delete` already
  exists — docs/plans/35 moved the exact-tuple delete there, off `DELETE /tuples`. EP-50's
  proposed path for delete-by-filter collides with it. The two operations are genuinely
  different (one names tuples, one names a filter), and renaming a frozen `v1` operation
  is a breaking change outside this initiative's scope, so delete-by-filter lands at
  `POST /v1/relationships/delete-by-filter`. Note this diverges from SpiceDB, where
  `DeleteRelationships` *is* the filtered delete.

- 2026-07-09 (EP-50, storage): the partial "live" indexes EP-50's Context section reserves
  for the delete-by-filter `UPDATE` — "exactly right for the delete-by-filter `UPDATE`,
  whose predicate *is* `deleted_xid IS NULL`" — no longer exist. docs/plans/49 dropped both
  `relation_tuple_object_live_idx` and `relation_tuple_subject_live_idx` in
  `en-migrations/db/migrations/20260709232320_drop-dead-live-indexes.sql`, after EP-50's
  plan was written and on the strength of an argument that only counted *reads*. EP-50 does
  not resurrect them: the surviving partial unique index `relation_tuple_live_unique`
  (six identity columns, `WHERE deleted_xid IS NULL`) leads with `object_type` and serves
  object-anchored deletes, and subject-anchored deletes ride
  `relation_tuple_subject_hist_idx` with `deleted_xid IS NULL` as a residual. M2's `EXPLAIN`
  evidence decides whether that residual is acceptable; if it is not, the reinstatement
  belongs in a plan of its own, with the write-amplification cost EP-49 measured.
  `relation_tuple_created_xid_idx`, which EP-53's watch query wants, was *not* dropped.

- 2026-07-09 (EP-50, storage): there is no longer a `DeleteTuples` store operation to
  mirror. docs/plans/46 collapsed writes and deletes into one `ApplyTupleWrites`
  constructor interpreted by `applyTupleWritesSession`. EP-50's delete-by-filter session
  follows that session's transaction shape (`BEGIN`, anchor insert, mutate, `COMMIT`,
  `tokenFromAnchor`) rather than the `deleteTuplesSession` its plan names, which no
  longer exists.


## Decision Log

- Decision: Prefer landing the versioned wire contract (docs/plans/35, master plan 6) before these endpoints.
  Rationale: New endpoints shipped under the unversioned, constructor-leaking contract would need a second breaking migration; sequencing avoids shipping the same surface twice.
  Date: 2026-07-07
- Decision: Keep lookup-subjects here rather than in the engine master plan.
  Rationale: It is a new capability with its own wire surface and algorithm; the engine plan fixes existing behavior. The soft ordering after docs/plans/40 and 42 is recorded in the Dependency Graph.
  Date: 2026-07-07
- Decision: Build watch on the existing xid8 soft-delete tables rather than a new outbox/changelog table.
  Rationale: The review (E5) observes the changelog substantially exists in relation_tuple + en_transaction; a cursored "changes since revision" query is much cheaper than introducing and backfilling a new table. Revisit only if EP-53's implementation disproves this.
  Date: 2026-07-07
- Decision: `RelationshipFilter` is a widening of the existing `TupleFilter`, and reuses its `SubjectRelationFilter` rather than the `Maybe RelationName` the child plans describe.
  Rationale: See Surprises. Two filter dialects over one table would be strictly worse, and `Maybe RelationName` cannot distinguish "any subject shape" from "a subject carrying no relation". `TupleFilter` keeps its mandatory `objectType` because a precondition is evaluated inside a write transaction, where an unanchored filter is a sequential scan under a lock; `RelationshipFilter` relaxes it because a read endpoint anchored on `subjectType` alone is the "what does alice hold?" query this initiative exists to serve. EP-53 and EP-54 consume `RelationshipFilter` unchanged.
  Date: 2026-07-09
- Decision: Delete-by-filter is served at `POST /v1/relationships/delete-by-filter`, not `POST /v1/relationships/delete`.
  Rationale: The latter path is already the exact-tuple delete under the frozen v1 contract. Recorded here because it changes the URL every child plan and the review's E2 description assume.
  Date: 2026-07-09
- Decision: EP-49's index trim is settled ahead of EP-53, not concurrently with it.
  Rationale: The Integration Points paragraph asks EP-53 and EP-49 to reconcile before either lands. EP-49 is Complete: it dropped the two partial `*_live_idx` indexes and kept `relation_tuple_created_xid_idx`, which is the index EP-53's changelog query wants. There is nothing left to reconcile; EP-53 inherits a settled index set and must record that it did.
  Date: 2026-07-09


## Outcomes & Retrospective

(To be filled during and after implementation.)
