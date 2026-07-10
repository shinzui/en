---
id: 50
slug: expose-relationship-read-and-delete-by-filter-endpoints
title: "Expose relationship read and delete-by-filter endpoints"
kind: exec-plan
created_at: 2026-07-07T15:25:10Z
master_plan: "docs/masterplans/9-complete-the-en-api-surface.md"
intention: intention_01kx4y4empedt9g83mprcrew89
---

# Expose relationship read and delete-by-filter endpoints

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

en is a relationship-based authorization service: every grant is a stored "tuple" such
as `space:project-x#viewer@user:alice` ("alice is a viewer of space project-x"). Today
the HTTP API served by `en-server` can answer *derived* questions (`POST /check`,
`POST /lookup`, `POST /expand`) and can write or delete tuples *by exact value*
(`POST /tuples`, `DELETE /tuples`), but it cannot answer the plain operational question
"which tuples exist?". An operator who needs to audit "what grants does user alice
hold?" or to offboard alice by revoking every grant naming her has no endpoint at all —
they must write bespoke SQL against the `relation_tuple` table. This is gap E2 of the
architecture review at `docs/reviews/2026-07-07-architecture-performance-review.md` and
is coordinated by the master plan `docs/masterplans/9-complete-the-en-api-surface.md`.

After this change, two new endpoints exist. `POST /relationships/query` lists stored
tuples matching a declarative filter (object type, object id, relation, subject type,
subject id, subject relation, caveat name — each optional within stated rules), at a
requested consistency, with keyset pagination. `POST /relationships/delete` soft-deletes
every live tuple matching the same filter shape, with a mandatory `dryRun` flag: a
dry-run returns only the count of tuples that would be deleted; an actual deletion runs
the match and the soft delete in one database transaction and returns the count plus a
consistency token, so the caller can immediately verify the revocation with
`AtLeastAsFresh`. Acceptance is two curl transcripts: "list all grants for user alice"
and "offboard user alice" (dry-run, delete, then a check at the returned token showing
`Denied`).


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: Define `RelationshipFilter` and its validation in `en-core/src/En/Effect/TupleStore.hs`; add the three new effect operations (`ReadRelationships`, `CountRelationships`, `DeleteRelationships`) with smart-constructor wrappers.
- [ ] M1: Extend the in-memory interpreter `runTupleStoreInMemory` in `en-core/src/En/Conformance/Kikan.hs` to handle the three new operations.
- [ ] M1: Add en-core unit tests for filter validation and in-memory filter matching (`en-core/test/Main.hs`).
- [ ] M2: Implement the PostgreSQL sessions and statements for read, count, and transactional delete-by-filter in `en-postgres/src/En/Postgres/TupleStore.hs`.
- [ ] M2: Extend `en-postgres/integration-test/Main.hs` with read-by-filter, count, and delete-by-filter scenarios (including snapshot visibility of the returned token).
- [ ] M2: Capture `EXPLAIN` output for the index-served and seq-scan filter shapes and record it in Surprises & Discoveries.
- [ ] M3: Add wire DTOs, the two routes, and handlers in `en-servant/src/En/Servant/API.hs`; extend `en-servant/test/Main.hs`.
- [ ] M3: Add `readRelationships` and `deleteRelationships` to `EnClient` in `en-client/src/En/Client.hs`.
- [ ] M4: Run the end-to-end curl transcripts ("list grants for alice", "offboard alice") against a locally running `en-server` and paste the observed output into Validation and Acceptance.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-07-09, M0 (orientation): every plan this one asked to be sequenced behind has
  landed. `docs/plans/35` (versioned wire contract), `40`/`42` (engine semantics), and
  `49` (index trim) are all Complete, per the Exec-Plan Registries of master plans 6, 7,
  and 8. Consequences, each of which contradicts a statement written into the sections
  below on 2026-07-07:

  1. The API is served under `/v1` and every operation answers with a `MultiVerb`
     response list (`EnResponses`) mapped onto an `EnResult` sum, not a bare `Post '[JSON]`.
     Handler faults travel as `ErrorEnvelopeWire` (`{"code","message","retryable"}`), not
     `{"error": "..."}`. Every JSON transcript in this plan has been rewritten accordingly.

  2. Sum types no longer encode as `{"tag": ..., "contents": ...}`. `En.Servant.API` now
     hand-writes every aeson instance with a string discriminator — `kind` for subjects,
     `mode` for consistency, `result` for decisions, `status` for page states. The
     `SubjectIdWire`/`FullyConsistentWire` spellings in the original transcripts describe
     bytes en no longer serves.

  3. `POST /v1/relationships/delete` is taken: docs/plans/35 moved the exact-tuple delete
     there. See the Decision Log for the path this plan uses instead.

  4. `TupleFilter` already exists (docs/plans/46, write preconditions) and is nearly the
     type this plan proposes to introduce. See the Decision Log.

  5. `deleteTuplesSession` no longer exists. docs/plans/46 collapsed writes and deletes
     into `ApplyTupleWrites`, interpreted by `applyTupleWritesSession`. That session is
     the shape delete-by-filter mirrors.

- 2026-07-09, M0 (index premise falsified): the Context and Orientation section below says
  the partial live indexes "are, however, exactly right for the delete-by-filter `UPDATE`,
  whose predicate *is* `deleted_xid IS NULL`". They were dropped by docs/plans/49 in
  `en-migrations/db/migrations/20260709232320_drop-dead-live-indexes.sql`, whose argument
  considered only reads. The delete `UPDATE` must therefore be served by
  `relation_tuple_live_unique` (partial unique, `WHERE deleted_xid IS NULL`, leading with
  `object_type`) for object-anchored filters and by `relation_tuple_subject_hist_idx` with
  a residual `deleted_xid IS NULL` for subject-anchored ones. M2's `EXPLAIN` evidence
  settles whether that residual is tolerable.


## Decision Log

Record every decision made while working on the plan.

- Decision: A filter must constrain at least `objectType` or `subjectType`; `objectId` requires `objectType`; `subjectId` and `subjectRelation` require `subjectType`; the empty filter is rejected with HTTP 400.
  Rationale: The two composite indexes that survive snapshot-visible reads (`relation_tuple_object_hist_idx` and `relation_tuple_subject_hist_idx`, created in `en-migrations/db/migrations/20260623160000_historical-read-indexes.sql`) lead with `object_type` and `subject_type` respectively. Any filter anchored on one of those columns is an index prefix scan; a filter anchored on nothing (or only on `relation`, `objectId`, or `caveatName`) is a full sequential scan of `relation_tuple`. Rather than silently offering O(table) queries, the grammar forbids un-anchored filters. `caveatName` is allowed only as a residual (post-index) predicate and its cost is documented rather than restricted, because auditing "all grants under caveat X for user Y" is a real need and is index-anchored through the subject columns.
  Date: 2026-07-07
- Decision: Both endpoints are `POST` with a JSON body: `POST /relationships/query` and `POST /relationships/delete`. No `GET` with query parameters, and no `DELETE` with a body.
  Rationale: The request carries a structured consistency value (possibly a long opaque token) and a nested filter, which fight URL encoding; and the review (A5 in `docs/reviews/2026-07-07-architecture-performance-review.md`) already flags the existing `DELETE /tuples`-with-body as proxy-hostile, so the new delete surface deliberately avoids repeating that mistake.
  Date: 2026-07-07
  Superseded 2026-07-09 in part: the `POST` decision and its rationale stand — indeed docs/plans/35 acted on the same A5 finding and already moved the exact-tuple delete from `DELETE /tuples` to `POST /v1/relationships/delete`. Only the *paths* change; see the next entry.
- Decision: The two new endpoints are `POST /v1/relationships/query` and `POST /v1/relationships/delete-by-filter`.
  Rationale: `POST /v1/relationships/delete` is already the exact-tuple delete under the frozen `v1` contract, so the path this plan reserved is taken by an operation with different semantics (it names tuples; this one names a filter). Renaming a shipped `v1` operation is a breaking change and belongs to a `v2`, not to this plan. `delete-by-filter` says what it does, at the cost of diverging from SpiceDB, where `DeleteRelationships` is itself the filtered delete. The alternative — overloading `/delete` on the presence of a `filter` key — was rejected: a request meaning "revoke these three grants" and a request meaning "revoke everything matching this pattern" must not differ by a typo.
  Date: 2026-07-09
- Decision: `RelationshipFilter` is defined as a widening of the existing `TupleFilter`, and reuses `SubjectRelationFilter` rather than the `Maybe RelationName` this plan's Milestone 1 sketch proposes.
  Rationale: `en-core/src/En/Effect/TupleStore.hs` already carries `TupleFilter`, added by docs/plans/46 for write preconditions, with the same six constrainable fields. Its subject-relation constraint is a three-valued `SubjectRelationFilter` (`AnySubjectRelation`/`NoSubjectRelation`/`ExactSubjectRelation`) whose Haddock records precisely why `Maybe RelationName` is wrong: under `Nothing`-means-any, the exact filter for `space:x#member@user:alice` also matches the userset grant `space:x#member@user:alice#admin`, which can be live at the same time. Introducing the weaker spelling for the new endpoint would put two contradictory filter dialects over one table. `RelationshipFilter` therefore differs from `TupleFilter` in exactly two ways: `objectType` becomes `Maybe` (a read anchored on `subjectType` alone is the "what does alice hold?" query this plan exists to serve), and `caveatName` is added. `TupleFilter` keeps its mandatory `objectType`, because a precondition is evaluated inside a write transaction where an unanchored filter is a sequential scan under a lock. Matching semantics are written once, against `RelationshipFilter`, and `TupleFilter`'s matcher is defined by widening into it, so the two cannot drift.
  Date: 2026-07-09
- Decision: The filter's SQL predicate is composed from the fields actually present, rather than sent as a fixed parameter list guarded by `($n::text IS NULL OR column = $n)`.
  Rationale: Milestone 2 anticipated the question and asked for `EXPLAIN` evidence before choosing. The null-guard form is index-friendly only under a *custom* plan, where PostgreSQL substitutes the parameter and folds `NULL IS NULL OR …` away. hasql issues `Statement.preparable` statements, so PostgreSQL may switch to a generic plan after five executions — at which point the guard is opaque, the qual cannot become an index condition, and every filtered read degrades to a sequential scan on a hot endpoint, silently and only in production. Composing the predicate makes the anchored columns real equality quals under every plan type. The shape space is bounded (seven optional fields, and validation forbids the unanchored ones), so the prepared-statement cache sees a handful of texts. Both forms are measured in M2 and the plans recorded in Surprises & Discoveries.
  Date: 2026-07-09
- Decision: The new wire types get hand-written aeson and `ToSchema` instances, not derived ones.
  Rationale: `En.Servant.API`'s section comment requires the wire shape to be "a reviewed artifact rather than a side effect of generic derivation", and `En.Servant.OpenApi`'s header notes that generic derivation "would resurrect exactly the constructor-tagged shapes those instances exist to remove". The Milestone 3 sketch below says `deriving Generic, FromJSON/ToJSON`; that instruction predates docs/plans/35 and is not followed. The new sum type `RelationshipsStateWire` reuses the `status` discriminator and the `exhausted`/`hasMore`/`truncated` vocabulary that `LookupStateWire` and `ExpandStateWire` already share.
  Date: 2026-07-09
- Decision: `dryRun` is a mandatory (not defaulted) field of the delete request.
  Rationale: Delete-by-filter is the most destructive operation in the API. Aeson's generic decoding rejects a missing field, so a caller must always state intent explicitly; a typo'd or omitted flag cannot silently destroy grants.
  Date: 2026-07-07
- Decision: Delete-by-filter is a single storage operation (`DeleteRelationships`) that runs one `BEGIN … COMMIT` transaction containing the `en_transaction` anchor insert and one `UPDATE relation_tuple SET deleted_xid = <anchor xid> WHERE <filter> AND deleted_xid IS NULL` with a `RETURNING`-based count, mirroring `deleteTuplesSession` in `en-postgres/src/En/Postgres/TupleStore.hs`.
  Rationale: Matching rows and soft-deleting them in the same transaction means the returned count and the returned token describe exactly the same set of rows; a read-then-delete across two transactions could miss or double-count grants written concurrently. The token is minted from the anchor exactly as tuple writes mint theirs (`tokenFromAnchor`), so `AtLeastAsFresh` at the returned token observes the revocation.
  Date: 2026-07-07
- Decision: The query response does not carry a `checkedAt` consistency token in this plan; `docs/plans/51-return-checked-at-consistency-tokens-from-read-responses.md` owns that convention and adds the field to this endpoint's response DTO when it lands (or this plan adds it following EP-51's convention if EP-51 lands first — see Interfaces and Dependencies).
  Rationale: Minting read tokens requires the `MintToken` consistency-store operation EP-51 introduces; duplicating that machinery here would create two owners for one convention. The delete response *does* return a token because deletion is a write and the write path already returns tokens today.
  Date: 2026-07-07
- Decision: This plan defines `RelationshipFilter` in `en-core/src/En/Effect/TupleStore.hs` (next to `UsersetQuery`) and the wire DTO `RelationshipFilterWire` in `en-servant/src/En/Servant/API.hs`. Per the master plan's Integration Points, EP-50 owns this type; `docs/plans/53-add-a-watch-changelog-api.md` (watch scoping) and `docs/plans/54-manage-the-schema-lifecycle-at-runtime.md` (per-type tuple enumeration) reuse it unchanged.
  Rationale: One filter grammar, one SQL compilation, one validation function — divergent filter dialects across three endpoints would be strictly worse.
  Date: 2026-07-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

The repository root is `/Users/shinzui/Keikaku/bokuno/en`. en is a Haskell project
(GHC 9.12.4, built with `cabal`) organized as several packages: `en-core` (the
storage-agnostic engine: schema, check/lookup/expand algorithms, and the *effects* —
typed interfaces — that storage implements), `en-postgres` (the PostgreSQL
implementation of those effects), `en-servant` (the HTTP API as a Servant type plus
handlers), `en-server` (the standalone executable), `en-client` (the typed HTTP
client), and `en-migrations` (SQL migrations). This plan is scoped by the master plan
`docs/masterplans/9-complete-the-en-api-surface.md` and fixes gap E2 of
`docs/reviews/2026-07-07-architecture-performance-review.md`.

A **tuple** is one stored grant: an object (`ObjectRef` = object type + object id), a
relation name, and a subject. A subject (`En.Tuple.Subject`) is one of `SubjectId`
(a concrete object, e.g. `user:alice`), `SubjectSet` (all members of a relation on
another object, e.g. `org:acme#member`), or `SubjectWildcard` (every object of a type,
e.g. `user:*`). A tuple may carry a **caveat** (a named condition plus a payload) that
makes the grant conditional. The Haskell type is `En.Tuple.Tuple` in
`en-core/src/En/Tuple.hs`.

The **tuple-store effect** is the storage interface, defined in
`en-core/src/En/Effect/TupleStore.hs` as an `effectful` dynamic effect (a GADT
`TupleStore :: Effect` whose constructors are the storage operations, plus
smart-constructor functions that `send` them). Reads take a `Revision` — an opaque
snapshot identifier resolved from the caller's consistency request — and return a
`TuplePage` (`rows :: [TupleRow]`, `state :: PageState` where `PageState` is
`Exhausted`, `HasMore cursor`, or `Truncated cursor`). The two existing read operations
are `ReadObjectRelation` (all tuples of one object+relation) and `ReadStartingWithUser`
(reverse lookup by subject list). Writes (`WriteTuples`, `DeleteTuples`) take exact
tuples and return a `ConsistencyToken` — an opaque text token (Zanzibar's "zookie")
that encodes the datastore id, schema hash, and the write's snapshot, letting later
reads request `AtLeastAsFresh` that write.

The PostgreSQL interpreter lives in `en-postgres/src/En/Postgres/TupleStore.hs`.
Storage is a single table `relation_tuple` (see
`en-migrations/db/migrations/20260623044157_create-relation-tuples.sql`) with columns
`object_type, object_id, relation, subject_type, subject_id, subject_relation,
caveat_name, caveat_payload, created_xid, deleted_xid` and a `bigserial id` primary
key used for keyset pagination (`WHERE id > $cursor ORDER BY id LIMIT n+1`; see
`pageFromRows`). Deletes are *soft*: `deleted_xid` is set to the deleting
transaction's xid8; reads filter with
`pg_visible_in_snapshot(created_xid, $snapshot) AND (deleted_xid IS NULL OR NOT
pg_visible_in_snapshot(deleted_xid, $snapshot))`, so a read at an old snapshot still
sees tuples deleted later. Every write transaction first inserts an anchor row into
`en_transaction` (`anchorTransactionStatement`) recording its xid and snapshot; the
returned token is minted from that anchor (`tokenFromAnchor`).

Wildcard subjects are stored flattened: `flattenSubject` maps `SubjectWildcard` to
`subject_id = "*"` with `subject_relation IS NULL`. A filter on
`subjectType = "user", subjectId = "*"` therefore matches wildcard grants — no special
casing is needed, but the plan's tests must cover it.

The indexes that matter (from the two migration files under
`en-migrations/db/migrations/`):

- `relation_tuple_object_hist_idx (object_type, object_id, relation, id)` — serves any
  filter whose constrained columns form a prefix of that list. `objectType` alone,
  `objectType+objectId`, and `objectType+objectId+relation` are index prefix scans.
  `objectType+relation` without `objectId` scans the `object_type` prefix and applies
  `relation` as a residual filter — still index-assisted, but it reads every row of
  that object type.
- `relation_tuple_subject_hist_idx (subject_type, subject_id,
  coalesce(subject_relation,''), object_type, relation, id)` — serves subject-anchored
  filters. Note the third column is the *expression* `coalesce(subject_relation,'')`,
  so the generated SQL must compare `coalesce(subject_relation,'') = $x` (not
  `subject_relation = $x`) for the index to match; this is the same convention
  `readStartingWithUserStatement` already uses.
- The partial "live" indexes (`relation_tuple_object_live_idx`,
  `relation_tuple_subject_live_idx`) are unusable by snapshot-visible reads (review
  C9) because the read predicate is `pg_visible_in_snapshot`, never bare
  `deleted_xid IS NULL`. They are, however, exactly right for the delete-by-filter
  `UPDATE`, whose predicate *is* `deleted_xid IS NULL`.
- `caveat_name` appears in no index. A caveat-name constraint is always a residual
  predicate evaluated after the index scan; this is documented cost, not a rejected
  shape, because it is always combined with an index anchor under this plan's grammar.

Filter shapes that would be pure sequential scans — no `objectType` and no
`subjectType` — are rejected by validation (see Decision Log).

The HTTP layer: `en-servant/src/En/Servant/API.hs` defines the Servant API type
`EnAPI`, the wire DTOs (suffix `Wire`, generic Aeson encoding — sum types encode as
`{"tag": "...", "contents": ...}`), and the handlers. Handlers run engine actions
through `runEngine` from `en-servant/src/En/Servant/Seam.hs`, which uses the
`Env es` record's `runPorts` to interpret the effect stack. `en-client/src/En/Client.hs`
derives a client record from the same API type — adding a route means adding a field
there. The in-memory store used by conformance and servant tests is
`runTupleStoreInMemory` in `en-core/src/En/Conformance/Kikan.hs`; it must interpret
every `TupleStore` constructor, so adding constructors is a compile-enforced todo.

External sequencing restated from the master plan: prefer landing
`docs/plans/35-version-the-wire-contract-and-type-the-error-model.md` (master plan 6:
versioned wire contract and typed error envelope) *before* this plan, so the new
endpoints are born inside the versioned contract instead of being migrated later. If
EP-35 has landed, put the new routes under its version prefix and use its error
envelope; the JSON shapes in this plan's transcripts show the current unversioned
contract and must be adjusted accordingly.


## Plan of Work

The work proceeds core-outward in four milestones: filter type and effect operations
with the in-memory interpreter (M1), the PostgreSQL implementation with integration
tests (M2), the HTTP endpoints and client (M3), and the end-to-end acceptance
transcripts (M4). Each milestone leaves `cabal build all` and the existing tests green.


### Milestone 1: RelationshipFilter and the store operations, in core

Scope: after this milestone, `en-core` exposes a validated filter type and three new
store operations, and the in-memory interpreter supports them, so everything above the
storage boundary can be written and tested without PostgreSQL.

In `en-core/src/En/Effect/TupleStore.hs`, add:

```haskell
-- | A declarative tuple filter. Owned by this module (EP-50); reused by the
-- watch feed (EP-53) and schema validation (EP-54). Construct via
-- 'validateRelationshipFilter' to enforce the anchoring rules.
data RelationshipFilter = RelationshipFilter
    { objectType :: !(Maybe ObjectType)
    , objectId :: !(Maybe Text)
    , relation :: !(Maybe RelationName)
    , subjectType :: !(Maybe ObjectType)
    , subjectId :: !(Maybe Text)
    , subjectRelation :: !(Maybe RelationName)
    , caveatName :: !(Maybe CaveatName)
    }
    deriving stock (Eq, Show)

-- | Enforce the filter grammar: at least one of objectType/subjectType;
-- objectId requires objectType; subjectId and subjectRelation require
-- subjectType. Returns the reason on rejection.
validateRelationshipFilter :: RelationshipFilter -> Either Text RelationshipFilter
```

(`CaveatName` needs importing from `En.Schema`.) Add three constructors to the
`TupleStore` GADT and their smart constructors, exporting all of it:

```haskell
    ReadRelationships :: Revision -> RelationshipFilter -> Int -> Maybe StoreCursor -> TupleStore m TuplePage
    CountRelationships :: Revision -> RelationshipFilter -> TupleStore m Int64
    DeleteRelationships :: RelationshipFilter -> TupleStore m (Int64, ConsistencyToken)
```

`ReadRelationships` mirrors `ReadObjectRelation`'s shape (revision, limit, cursor →
`TuplePage`). `CountRelationships` is the dry-run primitive: how many live-at-revision
tuples match. `DeleteRelationships` takes no revision because it acts on the current
live state inside its own transaction, exactly like `DeleteTuples`; it returns the
number of rows soft-deleted plus the write token.

Filter semantics, stated once and implemented identically everywhere: a tuple matches
when every *present* field equals the corresponding tuple component. `subjectType` and
`subjectId` compare against the flattened subject (so `subjectId = "*"` matches
wildcard grants); `subjectRelation` present means "userset subjects with exactly this
relation"; `subjectRelation` absent means "any subject shape". `caveatName` present
matches tuples whose caveat has that name (tuples without a caveat do not match).

Extend `runTupleStoreInMemory` in `en-core/src/En/Conformance/Kikan.hs` with the three
new cases: implement a pure `matchesFilter :: RelationshipFilter -> Tuple -> Bool` and
reuse `pageTuples` for `ReadRelationships`; `CountRelationships` returns the match
count; `DeleteRelationships` returns the match count and
`ConsistencyToken "in-memory-delete"` (the in-memory store is immutable fixture data,
same as its existing `DeleteTuples` case — tests assert the count and token shape, not
mutation).

Add unit tests to `en-core/test/Main.hs` (the hand-rolled `en-core-interface-tests`
suite — follow its existing assertion style): validation accepts/rejects the documented
shapes; `matchesFilter` behavior over the kikan fixture tuples including a wildcard
tuple and a caveated tuple; paging of `ReadRelationships` through the in-memory store.

Acceptance: `cabal build en-core && cabal test en-core` passes; the new tests fail if
`validateRelationshipFilter` accepts an empty filter.


### Milestone 2: PostgreSQL implementation and integration tests

Scope: after this milestone the real store serves filtered reads, counts, and
transactional delete-by-filter, proven by the ephemeral-database integration suite.

In `en-postgres/src/En/Postgres/TupleStore.hs`, handle the three new constructors in
`interpretTupleStorePostgres`. Because the filter has optional fields, the simplest
correct SQL is a single prepared statement per operation with nullable parameters and
`($n::text IS NULL OR column = $n)` guards for each field, keeping the mandatory
anchors as real predicates. Concretely, the read statement follows
`readObjectRelationStatement`'s shape:

```sql
SELECT id, object_type, object_id, relation, subject_type, subject_id, subject_relation,
       caveat_name, caveat_payload, created_xid::text, deleted_xid::text
FROM relation_tuple
WHERE ($2::text IS NULL OR object_type = $2)
  AND ($3::text IS NULL OR object_id = $3)
  AND ($4::text IS NULL OR relation = $4)
  AND ($5::text IS NULL OR subject_type = $5)
  AND ($6::text IS NULL OR subject_id = $6)
  AND ($7::text IS NULL OR coalesce(subject_relation, '') = $7)
  AND ($8::text IS NULL OR caveat_name = $8)
  AND id > $10
  AND pg_visible_in_snapshot(created_xid, $1::pg_snapshot)
  AND (deleted_xid IS NULL OR NOT pg_visible_in_snapshot(deleted_xid, $1::pg_snapshot))
ORDER BY id ASC
LIMIT $9
```

Reuse `tupleRowDecoder`, `pageFromRows`, and the cursor convention unchanged. The count
statement is the same `WHERE` with `SELECT count(*)` and no cursor/limit. The delete
session mirrors `deleteTuplesSession` exactly — `BEGIN`, anchor insert, one statement,
`COMMIT`, token from anchor — with the statement:

```sql
WITH deleted AS (
  UPDATE relation_tuple
  SET deleted_xid = $1::xid8
  WHERE ($2::text IS NULL OR object_type = $2)
    AND ($3::text IS NULL OR object_id = $3)
    AND ($4::text IS NULL OR relation = $4)
    AND ($5::text IS NULL OR subject_type = $5)
    AND ($6::text IS NULL OR subject_id = $6)
    AND ($7::text IS NULL OR coalesce(subject_relation, '') = $7)
    AND ($8::text IS NULL OR caveat_name = $8)
    AND deleted_xid IS NULL
  RETURNING id
)
SELECT count(*) FROM deleted
```

Be aware that `column = $n`-with-null-guard predicates can defeat index prefix use in
some PostgreSQL plans. As part of this milestone run `EXPLAIN (ANALYZE, BUFFERS)` for
the three canonical shapes (object-anchored, subject-anchored, subject-anchored plus
caveat residual) against a seeded table; if the planner refuses the hist indexes for
the null-guard form, switch to building the statement text dynamically from the present
fields (a small, bounded set of shapes — still parameterized values, only the predicate
list varies) and record the outcome in Surprises & Discoveries. Correctness first, then
verify the plan.

Extend `en-postgres/integration-test/Main.hs` (suite `en-postgres-integration-tests`;
it uses `ephemeral-pg` to start a throwaway PostgreSQL, so it needs PostgreSQL binaries
from the dev shell but no running database): write a small fixture set spanning two
object types, userset and wildcard subjects, and a caveated tuple; assert filtered
reads by each anchored shape; assert `CountRelationships` equals the read cardinality;
run `DeleteRelationships` for one subject and assert (a) the count, (b) a read at a
pre-delete snapshot still sees the tuples, and (c) a read at the returned token's
revision does not.

Acceptance: `cabal test en-postgres-integration-tests` passes.


### Milestone 3: HTTP endpoints, wire DTOs, and client

Scope: after this milestone `en-server` serves both endpoints and `en-client` can call
them.

In `en-servant/src/En/Servant/API.hs`, add wire DTOs (deriving `Generic`,
`FromJSON`/`ToJSON` like their neighbors) and conversions:

```haskell
data RelationshipFilterWire = RelationshipFilterWire
    { objectType :: !(Maybe Text)
    , objectId :: !(Maybe Text)
    , relation :: !(Maybe Text)
    , subjectType :: !(Maybe Text)
    , subjectId :: !(Maybe Text)
    , subjectRelation :: !(Maybe Text)
    , caveatName :: !(Maybe Text)
    }

data ReadRelationshipsRequestWire = ReadRelationshipsRequestWire
    { consistency :: !ConsistencyWire
    , filter :: !RelationshipFilterWire
    , limit :: !Int
    , cursor :: !(Maybe Text)
    }

data RelationshipsStateWire
    = RelationshipsExhaustedWire
    | RelationshipsHasMoreWire !Text

data ReadRelationshipsResponseWire = ReadRelationshipsResponseWire
    { relationships :: ![TupleWire]
    , state :: !RelationshipsStateWire
    }

data DeleteRelationshipsRequestWire = DeleteRelationshipsRequestWire
    { filter :: !RelationshipFilterWire
    , dryRun :: !Bool
    }

data DeleteRelationshipsResponseWire = DeleteRelationshipsResponseWire
    { dryRun :: !Bool
    , count :: !Int64
    , token :: !(Maybe Text)  -- present iff dryRun = False
    }
```

`filterFromWire :: RelationshipFilterWire -> Either Text RelationshipFilter` converts
and then applies `validateRelationshipFilter`; handlers reject with the existing
`either400` helper. Add two routes to `EnAPI`:

```haskell
        :<|> "relationships" :> "query" :> ReqBody '[JSON] ReadRelationshipsRequestWire :> Post '[JSON] ReadRelationshipsResponseWire
        :<|> "relationships" :> "delete" :> ReqBody '[JSON] DeleteRelationshipsRequestWire :> Post '[JSON] DeleteRelationshipsResponseWire
```

The query handler resolves consistency via `resolveConsistency` (import from
`En.Effect.ConsistencyStore`, exactly as `En.Check.check` does) and calls
`readRelationships resolved.revision filter limit cursor`; a page's `PageState` maps to
`RelationshipsStateWire` (`Truncated` maps to `HasMoreWire` too — the store never emits
`Truncated` for this operation today, but total mapping keeps the compiler happy). The
delete handler branches on `dryRun`: dry-run resolves `FullyConsistent` and calls
`countRelationships`; otherwise it calls `deleteRelationships` and returns count and
token. Wire both handlers into `server` and note that `server`'s constraint list may
need `ConsistencyStore` additions for the new handlers (it already carries it).

Add the two fields to `EnClient` in `en-client/src/En/Client.hs` (the `:<|>` pattern
match must be extended in the same order as the API type). Extend
`en-servant/test/Main.hs` following its existing style (it exercises handlers against
the in-memory interpreters from `En.Conformance.Kikan`): a query round-trip, a
validation rejection (empty filter → 400), and a delete dry-run.

Acceptance: `cabal build all && cabal test en-servant` passes.


### Milestone 4: end-to-end acceptance against a running server

Scope: run the two operator stories against a real server and capture the transcripts
into Validation and Acceptance. No code changes expected; this milestone exists so the
plan's headline claim is demonstrated, not assumed.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/en`, inside
the project dev shell (direnv loads it; it provides `cabal`, `just`, `psql`,
`process-compose`, and sets `PG_CONNECTION_STRING`/`EN_DATABASE_URL`).

Build and unit/conformance tests (no database needed):

```bash
cabal build all
cabal test en-core
cabal test en-servant
```

Integration tests (ephemeral PostgreSQL, needs only the dev shell):

```bash
cabal test en-postgres-integration-tests
```

Start the local development PostgreSQL and the server (the Justfile owns this:
`process-up` starts PostgreSQL via process-compose and waits for `pg_ctl status`;
`run-migrations` applies the SQL files under `en-migrations/db/migrations/` with
`psql`; `start-server` runs migrations then `cabal run en-server`):

```bash
just process-up
just start-server
```

Expected server startup log includes:

```text
en-server listening on :8080
```

When finished:

```bash
just process-down
```

The demo schema (served when `EN_SCHEMA_PATH` is unset — see
`en-server/app/Main.hs`) has object types `user` and `space` with relation `viewer`
and permission `view`; the transcripts below use it. Seed one grant first:

```bash
curl -sS -X POST localhost:8080/tuples -H 'content-type: application/json' -d '{
  "tuples": [{
    "object": {"objectType": "space", "objectId": "project-x"},
    "relation": "viewer",
    "subject": {"tag": "SubjectIdWire", "contents": {"objectType": "user", "objectId": "alice"}},
    "caveat": null
  }]
}'
```


## Validation and Acceptance

Acceptance scenario 1 — "list all grants for user alice". After seeding as above:

```bash
curl -sS -X POST localhost:8080/relationships/query -H 'content-type: application/json' -d '{
  "consistency": {"tag": "FullyConsistentWire"},
  "filter": {"objectType": null, "objectId": null, "relation": null,
             "subjectType": "user", "subjectId": "alice",
             "subjectRelation": null, "caveatName": null},
  "limit": 100,
  "cursor": null
}'
```

Expected response (one tuple, exhausted page):

```json
{
  "relationships": [
    {
      "object": {"objectType": "space", "objectId": "project-x"},
      "relation": "viewer",
      "subject": {"tag": "SubjectIdWire", "contents": {"objectType": "user", "objectId": "alice"}},
      "caveat": null
    }
  ],
  "state": {"tag": "RelationshipsExhaustedWire"}
}
```

Acceptance scenario 2 — "offboard user alice". First the mandatory dry run:

```bash
curl -sS -X POST localhost:8080/relationships/delete -H 'content-type: application/json' -d '{
  "filter": {"objectType": null, "objectId": null, "relation": null,
             "subjectType": "user", "subjectId": "alice",
             "subjectRelation": null, "caveatName": null},
  "dryRun": true
}'
```

```json
{"dryRun": true, "count": 1, "token": null}
```

Then the actual deletion, which returns a token:

```bash
curl -sS -X POST localhost:8080/relationships/delete -H 'content-type: application/json' -d '{
  "filter": {"objectType": null, "objectId": null, "relation": null,
             "subjectType": "user", "subjectId": "alice",
             "subjectRelation": null, "caveatName": null},
  "dryRun": false
}'
```

```json
{"dryRun": false, "count": 1, "token": "en1.…"}
```

Finally, a check at the returned token proves the revocation is visible:

```bash
curl -sS -X POST localhost:8080/check -H 'content-type: application/json' -d '{
  "consistency": {"tag": "AtLeastAsFreshWire", "contents": "<token from previous response>"},
  "context": {"values": {}},
  "subject": {"tag": "SubjectIdWire", "contents": {"objectType": "user", "objectId": "alice"}},
  "permission": "view",
  "object": {"objectType": "space", "objectId": "project-x"}
}'
```

```json
{"decision": {"tag": "DeniedWire"}}
```

A rejected filter (nothing anchored) must return HTTP 400 with the JSON error envelope
(`{"error": "..."}` under the current contract). Test-level validation: the new cases
in `cabal test en-core`, `cabal test en-servant`, and
`cabal test en-postgres-integration-tests` all pass; the integration suite includes the
snapshot-visibility assertion (pre-delete reads still see the tuples; reads at the
returned token do not). If `docs/plans/35`'s versioned contract has landed, adjust
paths and JSON shapes to it and note the adjustment in the Decision Log.


## Idempotence and Recovery

All read paths are pure with respect to a fixed revision and safe to repeat. The delete
endpoint is idempotent in effect: re-running the same filter delete soft-deletes only
rows still live (`deleted_xid IS NULL`), so a retry after a timeout deletes nothing new
and returns `count: 0` with a fresh token — safe. Because deletes are soft (rows are
retained until the garbage-collection reaper prunes them behind the GC window), an
accidental over-broad delete is recoverable while the window holds by re-inserting the
tuples read at a pre-delete snapshot; state this in operator-facing docs but build no
undo endpoint here. Dry-run first is enforced socially, not mechanically — the
mandatory `dryRun` field makes intent explicit but does not sequence calls. If M2's
`EXPLAIN` check forces a switch from null-guard predicates to dynamically composed
statements, that is a contained rewrite of one module; the effect signatures and tests
do not change.


## Interfaces and Dependencies

New interfaces at the end of the plan, by full module path:

- `En.Effect.TupleStore` (`en-core/src/En/Effect/TupleStore.hs`): `RelationshipFilter`,
  `validateRelationshipFilter :: RelationshipFilter -> Either Text RelationshipFilter`,
  GADT constructors `ReadRelationships`, `CountRelationships`, `DeleteRelationships`,
  and smart constructors `readRelationships :: (TupleStore :> es) => Revision ->
  RelationshipFilter -> Int -> Maybe StoreCursor -> Eff es TuplePage`,
  `countRelationships :: (TupleStore :> es) => Revision -> RelationshipFilter -> Eff es
  Int64`, `deleteRelationships :: (TupleStore :> es) => RelationshipFilter -> Eff es
  (Int64, ConsistencyToken)`.
- `En.Conformance.Kikan` (`en-core/src/En/Conformance/Kikan.hs`): in-memory
  interpretation of the three constructors; a pure `matchesFilter` helper may be
  exported for reuse in tests.
- `En.Postgres.TupleStore` (`en-postgres/src/En/Postgres/TupleStore.hs`): the three
  sessions/statements described in M2. No schema migration is required — the plan uses
  existing tables and indexes only.
- `En.Servant.API` (`en-servant/src/En/Servant/API.hs`): the routes
  `POST /relationships/query` and `POST /relationships/delete`, wire types
  `RelationshipFilterWire`, `ReadRelationshipsRequestWire`,
  `ReadRelationshipsResponseWire`, `RelationshipsStateWire`,
  `DeleteRelationshipsRequestWire`, `DeleteRelationshipsResponseWire`, and
  `filterFromWire`/`filterToWire` conversions.
- `En.Client` (`en-client/src/En/Client.hs`): fields `readRelationships` and
  `deleteRelationships` on `EnClient`.

Dependencies and coordination, restated so this plan stands alone: this plan has no
hard dependency on other plans. It should preferably land after
`docs/plans/35-version-the-wire-contract-and-type-the-error-model.md` (versioned wire
contract; see Context and Orientation). It *owns* the `RelationshipFilter` type per
`docs/masterplans/9-complete-the-en-api-surface.md`;
`docs/plans/53-add-a-watch-changelog-api.md` reuses it to scope watch subscriptions and
`docs/plans/54-manage-the-schema-lifecycle-at-runtime.md` reuses it to enumerate tuples
per type during schema validation — do not change its field set without updating both.
`docs/plans/51-return-checked-at-consistency-tokens-from-read-responses.md` owns the
`checkedAt` read-token convention and will add that field to
`ReadRelationshipsResponseWire`; if EP-51 lands first, add the field here during M3
following its convention and record the reconciliation in both Decision Logs. No new
Haskell package dependencies are required (`hasql`, `aeson`, `servant`, `effectful` are
already in scope in the touched packages).
