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
| EP-50 | Expose relationship read and delete-by-filter endpoints | docs/plans/50-expose-relationship-read-and-delete-by-filter-endpoints.md | None | None | Complete |
| EP-51 | Return checked-at consistency tokens from read responses | docs/plans/51-return-checked-at-consistency-tokens-from-read-responses.md | None | None | Complete |
| EP-52 | Add a lookup-subjects API | docs/plans/52-add-a-lookup-subjects-api.md | None | None | Complete |
| EP-53 | Add a watch changelog API | docs/plans/53-add-a-watch-changelog-api.md | None | None | Complete |
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

**All three external constraints are settled as of 2026-07-09.** Master plans 6, 7, and 8
completed before any child here started, so EP-50, EP-51, and EP-52 were all written
against the `/v1` contract and the hardened engine — none of them shipped under the
unversioned contract, and none of them had to migrate. EP-53 and EP-54 inherit the same
settled ground. EP-51 is Complete, so docs/plans/57's hard dependency is discharged (but
see Surprises: EP-57 must still make the `mintCheckedObjectGrant` fix itself).


## Integration Points

The relationship filter type — which fields of (object type, object id, relation,
subject type, subject id, subject relation, caveat name) may be constrained — is defined
by EP-50 as both a wire DTO in `en-servant/src/En/Servant/API.hs` and a core query type
consumed by the store. EP-53 reuses the same filter for scoping watch subscriptions, and
EP-54 uses it for per-type tuple enumeration during schema validation. EP-50 owns the
definition.

**Landed 2026-07-09.** The type is `RelationshipFilter` in
`en-core/src/En/Effect/TupleStore.hs`, its wire form is `RelationshipFilterWire`, and its
final field set differs from the parenthetical above: `subjectRelation` is a three-valued
`SubjectRelationFilter`, not a nullable relation name. Consumers must construct through
`validateRelationshipFilter` (core) or `relationshipFilterFromWire` (wire), which enforce
the anchoring grammar: at least one of `objectType`/`subjectType`; `objectId` requires
`objectType`; `subjectId` and a non-`Any` `subjectRelation` require `subjectType`. See
Surprises & Discoveries for why, and for the SQL-composition rule that comes with it.

**EP-53 consumed it unchanged on 2026-07-09.** `ReadChanges` takes `Maybe RelationshipFilter`
and compiles it through the same `compileFilter`; the wire request carries
`filter :: Maybe RelationshipFilterWire`, validated by the same `relationshipFilterFromWire`,
so an unanchored subscription filter is the same `400` an unanchored read filter is. Only
EP-54's per-type enumeration remains.

Checked-at token plumbing is defined by EP-51: `check`/`lookup`/`expand` results in
`en-core` gain the resolved revision, and every read response DTO gains a token field.
EP-52 and EP-53 must include the same field in their new response DTOs from day one
(they consume EP-51's convention; if they land first, they add the field following the
review's E3 description and EP-51 reconciles).

**Landed 2026-07-09.** The convention is: wire field `checkedAt :: !Text`, last in the
response object; core field `checkedAt :: !ConsistencyToken` on the result record; minted
by `mintToken` (the `ConsistencyStore` effect operation, a pure encode) from the revision
the read *resolved to*, never echoed from the request. `check`/`checkCached` return
`CheckOutcome`, `checkMany` returns `BatchOutcome`, and `LookupPage`/`ExpandTree` carry the
field. `ReadRelationshipsResponseWire` (EP-50's) gained it here. The cursored-read rule is
load-bearing and is spelled out in Surprises & Discoveries: on resume, take the token from
the cursor's validated token and do not re-resolve the request's `consistency`. EP-52 and
EP-53 are both cursored.

**EP-52 consumed this on 2026-07-09 and confirmed it live.** `LookupSubjectsPageWire` ends
with `checkedAt`, minted from the resolved revision. A page-two request that asked for
`minimizeLatency` and carried a page-one cursor correctly reported page one's snapshot
(`27802:27802:`). EP-53 must do the same. Only EP-54's schema-read endpoint remains, and it
is not a tuple read: whether it carries `checkedAt` at all is EP-54's to decide and record.

**EP-53 consumed it on 2026-07-09 and confirmed it live too.** `WatchResponseWire` ends with
`checkedAt`, minted from the window's *end* revision. A drain's page two reported
`27807:27807:` — the end its cursor carried — while the head had already advanced past it.
But see Surprises: a `checkedAt` token minted from a head revision stops validating the moment
one write lands, because `validateTokenMetadata` rejects on `xmax <= horizon` and a head
snapshot's `xmax` is the next unassigned xid. EP-53 sidestepped this for cursors by deriving a
different rule; the token convention itself is untouched and unexercised at that boundary.

The watch changelog storage query (EP-53) reads `relation_tuple.created_xid`/
`deleted_xid` ordered by transaction visibility, likely via
`relation_tuple_created_xid_idx` — the index that
docs/plans/49-trim-dead-indexes-and-resolve-consistency-lazily.md (master plan 8)
proposes to drop as dead. EP-53 and EP-49 must reconcile before either lands the index
change; whichever goes first records the outcome in both Decision Logs.

**Resolved 2026-07-09, nothing left to reconcile.** EP-49 is Complete. It dropped only the
two partial live indexes (`relation_tuple_object_live_idx`,
`relation_tuple_subject_live_idx`) in
`en-migrations/db/migrations/20260709232320_drop-dead-live-indexes.sql`.
`relation_tuple_created_xid_idx` survives, so EP-53 inherits the index its changelog query
wants. EP-50 separately confirmed by `EXPLAIN` that the delete-by-filter `UPDATE` is still
index-served without the dropped live indexes, so there is no case for reinstating them. EP-53's cursor
recovery is bounded by the GC horizon maintained by
docs/plans/37-schedule-background-maintenance-for-reaping-and-transaction-pruning.md
(master plan 6): once `en_transaction` rows and reaped tuples are pruned, a watch cursor
older than the horizon must return a typed "cursor expired" error, exactly like a stale
consistency token.

**Landed 2026-07-09, and the index is now load-bearing.** EP-53's `ReadChanges` bounds both
xid arms by the window-start snapshot's `xmin`, and `EXPLAIN` against a 250,000-row table
shows a `BitmapOr` over `relation_tuple_created_xid_idx` and `relation_tuple_deleted_xid_idx`
with that bound as each arm's `Index Cond`. The `UNION ALL` fallback EP-53's plan reserved was
not needed. Nothing further is owed in either Decision Log. Two corrections to the paragraph
above, both recorded in Surprises: the cursor-expired check is **not** "exactly like a stale
consistency token" — it is `horizon <= start.xmin`, and the token rule would both expire a
one-poll-old subscription and admit a window that loses a deletion; and the error it raises is
`InvalidConsistencyToken` only for expiry, while a cursor this store never issued raises
`InvalidCursor` (wire code `invalid_cursor`). EP-37 must record the mirror entry when it
lands, and must record the `xmin` rule, not the `xmax` one.

Schema state in `en-server` (currently a `ValidSchema` loaded once from
`EN_SCHEMA_PATH` in `en-server/app/Main.hs`) becomes mutable state under EP-54 (reload
swaps it atomically; in-flight requests keep the old schema). Every other endpoint reads
the schema through whatever handle EP-54 introduces; until then, plans use the existing
immutable argument and EP-54 rewires them.

**Two notes for EP-54, as of 2026-07-09.** `POST /v1/watch` reads no schema at all — tuple
change events are schema-independent data — and EP-53 deliberately omitted the schema-hash
check from watch-cursor validation for exactly that reason: expiring every watch consumer on
a reload would sever the revocation feed at the moment an operator changes the model. EP-54
must not "fix" that omission. Separately, `Env` now carries `watchOperation`, so EP-54's
schema handle is the second field added to it in this initiative; keep its type out of
`en-postgres`, because `en-example` and `en-servant`'s test suite build an `Env` and neither
depends on that package.


## Progress

- [x] EP-50 (2026-07-09): `POST /v1/relationships/query` lists relationships by filter with keyset pagination
- [x] EP-50 (2026-07-09): `POST /v1/relationships/delete-by-filter` with a mandatory dry-run flag; offboarding a user is one call
- [x] EP-51 (2026-07-09): every read response carries the token it was evaluated at; write-then-read-at-token round-trips
- [x] EP-52 (2026-07-09): `POST /v1/lookup-subjects` returns a flat, cursored subject set with correct caveat, operator, and wildcard handling
- [x] EP-53 (2026-07-09): `POST /v1/watch` streams tuple changes since a revision, cursor, or token, optionally filtered; expired cursors rejected with a typed error
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

- 2026-07-09 (EP-50 complete; binds EP-53 and EP-54): the shared filter now exists and is
  **not** the shape the Integration Points section below describes. `RelationshipFilter`
  in `en-core/src/En/Effect/TupleStore.hs` has fields `objectType :: Maybe ObjectType`,
  `objectId :: Maybe Text`, `relation :: Maybe RelationName`,
  `subjectType :: Maybe ObjectType`, `subjectId :: Maybe Text`,
  `subjectRelation :: SubjectRelationFilter` (three-valued, *not* `Maybe RelationName`),
  and `caveatName :: Maybe CaveatName`. Construct it through
  `validateRelationshipFilter`, which enforces the anchoring grammar; `widenTupleFilter`
  converts a precondition's `TupleFilter` into one. The wire form is
  `RelationshipFilterWire` in `en-servant/src/En/Servant/API.hs`, with
  `relationshipFilterFromWire` doing conversion and validation as one step. EP-53 scopes
  watch subscriptions with this type and EP-54 enumerates tuples per type with it; neither
  should redefine it, and neither should widen its field set without updating the other.

- 2026-07-09 (EP-50 complete; binds every plan that adds an endpoint): a prepared statement
  whose optional predicates are sent as `($n::text IS NULL OR column = $n)` guards is
  index-served only under PostgreSQL's *custom* plan, which it stops building after a
  statement's fifth execution. Measured on 250,000 rows, the generic plan abandons the
  anchor index for a primary-key scan: 3527 buffers and 40.6 ms against 4 buffers and
  0.033 ms. The regression is invisible to tests, to a development server, and to a curl
  transcript, all of which execute a statement once or twice. EP-53's changelog query and
  EP-54's per-type enumeration both take optional predicates and must compose their
  `WHERE` clause from the fields actually present, as `compileFilter` in
  `en-postgres/src/En/Postgres/TupleStore.hs` does. Evidence is in EP-50's Surprises &
  Discoveries.

- 2026-07-09 (EP-50 complete; binds EP-51, EP-52, EP-53): the new-endpoint pattern is
  established and should be copied rather than reinvented. A route is a `MultiVerb` over
  `EnResponses`, its handler returns `EnResult` and reports faults as values through
  `enHandler`/`orInvalid` rather than throwing, its wire types get hand-written aeson
  instances with a string discriminator (`status` for page states — reuse
  `exhausted`/`hasMore`/`truncated`), and it gets a hand-written `ToSchema` instance in
  `en-servant/src/En/Servant/OpenApi.hs`. That last is compile-enforced: adding a route to
  `EnAPI` without a schema fails to build. `en-servant/test/Main.hs` now destructures
  `server`'s handler chain exactly once, into a `Handlers` record — add a field there, not
  a seventh positional pattern.

- 2026-07-09 (EP-50 complete; affects any plan running the server by hand): `just
  start-server` binds port 8080, which `just process-up` may already be serving from an
  older `en-server` binary. The second bind fails, but `GET /healthz` still answers `200`
  from the stale process, so an acceptance run against 8080 silently exercises the wrong
  build. Use `EN_PORT=<free> EN_AUTH_DISABLED=true cabal run en-server` instead.
  **EP-51 confirms and widens this**: on the same machine 8080 was held by an unrelated
  `ssh` tunnel, not an `en-server` at all. Anything listening there will answer. Check with
  `lsof -nP -iTCP:8080 -sTCP:LISTEN` before assuming what you are talking to.

- 2026-07-09 (EP-51 complete; **cancels EP-51's Milestone 1 and rewrites what EP-53 may
  assume**): the token-minting primitive EP-51 was to introduce already existed.
  `docs/plans/42` (master plan 7) added `MintToken` to the `ConsistencyStore` effect in
  commit `b2ab2c5`, because closing the forgeable-lookup-cursor hole required the datastore
  to mint a token a cursor could carry. It landed with the exact encoding EP-51 specified
  and a Haddock naming `checked_at` as a future consumer. Every interpreter implements it:
  `en-postgres/src/En/Postgres/Revision.hs`, both in-memory stores in
  `en-core/src/En/Conformance/Kikan.hs`, and both stores in
  `en-example/src/En/Example/Host.hs`. `MintToken` is a *pure encode* in all of them —
  `pure (encodeToken …)`, never a database session — so a read response can carry a token
  at no round-trip cost. EP-53's watch feed should mint its cursor and its `checkedAt` the
  same way rather than inventing a revision encoding.

- 2026-07-09 (EP-51 complete; **binds EP-52 and EP-53**): the `checkedAt` convention is now
  fixed and must be copied. On the wire it is `checkedAt :: !Text`, placed **last** in the
  response object (the hand-written `toEncoding` fixes field order, and the golden tests in
  `en-servant/test/Main.hs` assert exact bytes). In core it is
  `checkedAt :: !ConsistencyToken` on the result record. It is minted from the revision the
  read *resolved to*, never echoed from the request: a check at `AtLeastAsFresh` a token
  whose revision was `27796:27797:` was observed reporting `27797:27797:`, because
  "no older than" resolved something fresher. For a **cursored** read — which both EP-52 and
  EP-53 are — the resume path must take the token from the cursor's *validated* token and
  must **not** re-resolve the request's `consistency`. EP-51 observed a lookup page-two
  request asking for `minimizeLatency` and correctly receiving page one's snapshot. A
  cursored read that re-resolves silently spans two snapshots and produces a page with gaps.

- 2026-07-09 (EP-51 complete; affects `docs/plans/57`, master plan 10): EP-51's hard
  dependency for Biscuit minting is discharged — `CheckResponseWire.checkedAt` exists — but
  EP-51 deliberately did **not** rewire `mintCheckedObjectGrant` in
  `en-biscuit/src/En/Biscuit/Mint.hs`. That function still stamps the minted `EnGrant` with
  the *caller-supplied* `grant.consistencyToken` rather than `outcome.checkedAt`, the
  snapshot its decision was actually made at. It is now a one-line fix and it belongs to
  EP-57, which owns grant semantics; re-stamping an authorization token's snapshot from
  inside a plan scoped to "what reads return" would be the wrong place to decide it. A
  comment at the call site records this. EP-57 must not assume it was already done.

- 2026-07-09 (EP-51 complete; corrects this master plan's Integration Points below):
  `checkMany` returns `BatchOutcome { decisions :: ![Either EnError CheckDecision],
  checkedAt :: !ConsistencyToken }` — the `Either` because master plan 7's engine hardening
  already made batch checks preserve per-pair failures. `check` and `checkCached` return
  `CheckOutcome { decision, checkedAt }`. `checkAtRevision` and `checkCachedAtRevision`
  return a bare decision and mint nothing: they take an already-resolved revision, and
  minting inside them would emit one identical, discarded token per confirmed lookup
  candidate.

- 2026-07-09 (EP-52 complete; **binds EP-53 and EP-54**): adding a field to
  `En.Servant.Seam.Env` breaks every construction site, and there are three, not one:
  `en-server/app/Main.hs`, `en-example/src/En/Example/Host.hs`, and
  `en-servant/test/Main.hs`. EP-52 added `lookupSubjectsWithDeadlineOperation`. A plan that
  adds an engine operation reachable from a handler pays this cost; a plan that calls the
  store effects directly from the handler (as EP-50's read/delete-by-filter does) does not.
  EP-53's watch feed is a store read and should follow EP-50; EP-54's schema handle is
  state, not an operation, and will have to touch all three regardless.

- 2026-07-09 (EP-52 complete; **binds EP-53 and EP-54, and every plan adding a wire type**):
  a new wire type can break an *existing, untouched* test. `LookupSubjectsRequestWire`
  carries both `deadlineMillis` and `limit`, which until then named `LookupRequestWire`
  uniquely, so a record update in `en-servant/test/Main.hs` that had compiled for months
  became `[GHC-99339] Ambiguous record update`. GHC narrows a record update by its field
  set, then by the field types, and only then falls back to the expected type — warning
  `-Wambiguous-fields` that the fallback is going away. Three older updates in that file
  already ride it. A plan adding a wire type whose field names overlap an existing one
  should expect to fix call sites it did not write.

- 2026-07-09 (EP-52 complete; **affects EP-53, and every endpoint that accepts a token**):
  a tampered consistency token is refused with the right status and the right stable `code`,
  but the envelope's `message` is a Haskell constructor name —
  `{"code":"invalid_consistency_token","message":"TokenBadFieldCount","retryable":false}`.
  `en-postgres/src/En/Postgres/Revision.hs:281` builds it as
  `InvalidConsistencyToken (Text.pack (show err))` over the internal `TokenDecodeError` sum.
  Nothing a client should depend on is broken, and EP-52 did not fix it — it predates the
  plan and belongs to no plan currently open. EP-53's watch cursor validates through the
  same function and inherits it. Whoever fixes it should note that the `v1` contract
  (docs/plans/35) exists precisely to keep internal constructor names off the wire.

- 2026-07-09 (EP-52 complete; **corrects the third Surprises entry above, in EP-52's
  favour**): the "inherit the engine's current defects in a brand-new API" risk this master
  plan's Dependency Graph raised for EP-52 never materialized, because docs/plans/40 and 42
  landed first. `check` treats a revisited subproblem as the empty set, so lookup-subjects'
  confirmation step could delegate to it without forking cycle semantics; and `MintToken`
  plus validated cursors were already in place. Six conformance scenarios — group nesting,
  caveat satisfied, caveat unsatisfied, exclusion, intersection, wildcard — passed on their
  first run. That is what "reach-then-check delegating to the one evaluator" is for, and
  EP-53 should reach for the same posture wherever its changelog feed needs a decision.


- 2026-07-09 (EP-53 complete; **binds EP-54, and corrects this master plan's own guidance to
  EP-53**): the garbage-collection check `validateTokenMetadata` performs — reject when
  `snapshot.xmax <= oldestRetainedXid` — is not reusable for a cursor minted from a head
  revision, and EP-53's plan told it to copy that check anyway. A `headRevision` snapshot's
  `xmax` is the next *unassigned* xid; the first write afterwards is assigned exactly that
  xid, inserts its `en_transaction` anchor, and the horizon rises to meet it. A watch
  subscription therefore expired one poll after birth, which the integration test caught on
  its first run. The rule a revision window actually needs is `horizon <= start.xmin`: the
  reaper removes rows whose `deleted_xid < horizon`, and if the horizon is at or below the
  window's `xmin` then every such row is visible at the window's start, hence not live there,
  hence owed no event. The token rule is also *unsound* here — a snapshot `849:851:849` passes
  it against a horizon of `850` while a row deleted at `849` is both live at the start and
  reapable. **The same sharp edge exists for `checkedAt` tokens minted from a head revision
  (EP-51's convention): mint at `fullyConsistent`, let one write land, and the token no longer
  validates.** Nothing in the tree exercises it, and no open plan owns it. EP-54 must not
  assume a head-derived token or revision keeps validating across a write.

- 2026-07-09 (EP-53 complete; **binds EP-54**): the shared filter EP-50 defined is now
  consumed by a second caller, unchanged, and the composition rule held. `ReadChanges` takes
  `Maybe RelationshipFilter` and compiles it through the same `compileFilter` in
  `en-postgres/src/En/Postgres/TupleStore.hs`, so its predicates are composed rather than sent
  as `($n IS NULL OR column = $n)` guards. EP-54's per-type tuple enumeration is the third
  caller and must do the same. Note the storage operation grew a filter argument at birth
  rather than acquiring one later: EP-50 had landed, so deferring it would have meant
  revisiting the effect, the interpreter, the in-memory stub, and the endpoint.

- 2026-07-09 (EP-53 complete; **binds EP-54**): `En.Servant.Seam.Env` now has a
  `watchOperation` field, so EP-52's warning about `Env`'s three construction sites
  (`en-server/app/Main.hs`, `en-example/src/En/Example/Host.hs`, `en-servant/test/Main.hs`)
  has now been paid twice. EP-53 kept the cost from growing: `WatchStart` and `WatchBatch`
  live in a new en-core module `En.Watch`, not in `En.Postgres.Watch`, because `en-example`
  and `en-servant`'s test suite build an `Env` and neither depends on `en-postgres`. EP-54's
  schema handle is state rather than an operation and will touch all three sites regardless —
  but it should keep any type it puts in `Env` out of `en-postgres` for the same reason.

- 2026-07-09 (EP-53 complete; **settles what the Integration Points paragraph left open, and
  frees EP-49's index question forever**): the changelog query does use
  `relation_tuple_created_xid_idx`, and `EXPLAIN` proves it. Both xid arms are bounded by the
  window-start snapshot's `xmin`, and the planner answers with a `BitmapOr` over
  `relation_tuple_created_xid_idx` and `relation_tuple_deleted_xid_idx`, each with the `xmin`
  bound as its `Index Cond`. The `UNION ALL` fallback EP-53's plan reserved was never needed.
  The index EP-49 kept on this plan's promise is now load-bearing; nothing further is owed in
  either Decision Log. A cost was found and recorded rather than fixed: neither index carries
  `id`, so the `ORDER BY id` is a sort and the keyset predicate a filter, making a drain of a
  wide window re-scan it once per page. See EP-53's Surprises for the remedy and why it is out
  of scope.

- 2026-07-09 (EP-53 complete; **EP-54 is now the only plan left, and its `checkedAt` question
  is answered by precedent, not by rule**): every tuple-read response in the API now ends with
  `checkedAt` — `check`, `batch-check`, `lookup`, `lookup-subjects`, `expand`,
  `relationships/query`, and now `watch`. `POST /v1/watch` mints it from the window's *end*
  revision, and a resuming poll takes that end from its cursor and re-resolves nothing, which
  EP-51's rule demanded and the live transcript confirmed (page two of a drain reported
  `27807:27807:` while the head had already moved past it). EP-54's schema-read endpoint is
  not a tuple read, so as the Integration Points below say, whether it carries `checkedAt` at
  all remains EP-54's to decide and record.


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
- Decision: EP-51's Milestone 1 is marked complete as pre-landed rather than reimplemented, and EP-51's fourth Decision Log entry is recorded as moot.
  Rationale: `docs/plans/42` (master plan 7) already added `MintToken` with the exact encoding EP-51 specified, and already replaced the forgeable raw revision in lookup cursors with a validated token. Reimplementing either would have been a no-op at best and a fork of the token format at worst. Recorded here because it is the second time a child of this master plan has found its groundwork already laid by a master plan that ran first — see the first Surprises entry.
  Date: 2026-07-09
- Decision: `checkedAt` is the snapshot the read resolved to, not the token the request supplied.
  Rationale: Observed live: a check at `AtLeastAsFresh` a write token pinning `27796:27797:` reported `27797:27797:`. "No older than" permits a fresher snapshot, and reporting the request's token back would misstate what was read — the precise defect the field exists to fix. Every child adding a read endpoint must mint from the resolved revision.
  Date: 2026-07-09
- Decision: EP-51 does not fix `mintCheckedObjectGrant`'s use of the caller-supplied `consistencyToken`; `docs/plans/57` does.
  Rationale: The function mints an `EnGrant` stamped with a token the caller chose rather than the one its decision was made at — exactly the E3 defect, in the one place it is a security property rather than an ergonomic one. EP-51's scope is what reads return. Changing an authorization token's recorded snapshot is a semantic change to en-biscuit, and EP-57 hard-depends on EP-51 for the express purpose of making it. Left as a one-line fix with a comment at the call site.
  Date: 2026-07-09
- Decision: Lookup-subjects does not port `En.Lookup`'s `EmitWindow` (the watermark-and-confirm-budget optimization that bounds intersection/exclusion confirmation to the current page). It confirms every candidate.
  Rationale: The window is sound only where a confirmation's output goes straight into the page, so it threads a `Maybe EmitWindow` through every rewrite node with per-constructor rules about when to pass it on. Copying that into a brand-new evaluator buys a constant factor and risks a page with gaps if one rule is copied wrong. `docs/plans/42` owns lookup's paging mechanics; EP-52's page vocabulary, cursor discipline, and traversal shape are identical to lookup's, so a future generalization transfers mechanically rather than needing invention. Recorded here because the same choice faces EP-53's cursored watch feed.
  Date: 2026-07-09
- Decision: The lookup-subjects engine operation reaches its handler through `En.Servant.Seam.Env`, adding a field, rather than being called directly from the handler as EP-50's store reads are.
  Rationale: The server must be able to substitute the decision-cached variant, and only the host knows whether the cache is enabled. The cost is that all three `Env` construction sites change. EP-50 needed no such field because a filtered relationship read is a store effect the handler can `send` itself, and there is nothing to substitute. EP-53 should follow EP-50; EP-54 will touch all three sites regardless, because a reloadable schema is state rather than an operation.
  Date: 2026-07-09
- Decision: The `TokenBadFieldCount` leak in `en-postgres/src/En/Postgres/Revision.hs` is recorded, not fixed, by EP-52.
  Rationale: It predates this initiative, affects every token-bearing endpoint rather than the one EP-52 added, and fixing it means designing stable codes for the token-decode failure modes — a wire-contract question that belongs beside `docs/plans/35`'s error model, not inside a plan scoped to one new read. EP-53 inherits it and should not assume it was handled.
  Date: 2026-07-09
- Decision: EP-53 confirmed the leak still exists and still did not fix it. A tampered `startToken` on `POST /v1/watch` surfaces a `TokenDecodeError` constructor name; the watch cursor's own failures do not.
  Rationale: Unchanged from the entry above. The fix is a wire-contract design task, and EP-53 is scoped to one new read. EP-54 inherits it in turn.
  Date: 2026-07-09
- Decision: The watch cursor's garbage-collection check is `horizon <= start.xmin`, diverging from `validateTokenMetadata`'s `horizon < revision.xmax`, and EP-53's own Decision Log entry saying it "checks the GC horizon exactly as `validateTokenMetadata` does" is superseded.
  Rationale: See Surprises. The token rule is unusable for a head-derived cursor and unsound for a revision window, in opposite directions. The window's condition is derivable from what the reaper removes, so it was derived rather than copied. Recorded at master-plan level because it also identifies a latent defect in EP-51's `checkedAt` convention that no open plan owns.
  Date: 2026-07-09
- Decision: `WatchStart` and `WatchBatch` live in en-core (`En.Watch`), not in `En.Postgres.Watch` as EP-53's plan specified. Only the cursor codec, its validation, and the `watch` orchestration are datastore-specific.
  Rationale: `Env.watchOperation`'s type names both, and two of `Env`'s three construction sites (`en-example`, `en-servant`'s test suite) do not depend on `en-postgres`. Forcing that dependency to name a type whose constructors carry `Text` would buy nothing. The types are genuinely neutral: the cursor is opaque `Text` at this layer and `checkedAt` is a `ConsistencyToken`.
  Date: 2026-07-09
- Decision: The watch feed is a pull API and stays one. EP-53 shipped no NDJSON, no SSE, and no long-poll.
  Rationale: Unchanged from EP-53's own 2026-07-07 entry, restated here because the endpoint now exists and the temptation to add streaming to it will arrive. Every streaming design still needs the cursor semantics EP-53 built, and wire streaming for large results is separately tracked as review gap E13.
  Date: 2026-07-09


## Outcomes & Retrospective

(To be filled during and after implementation.)
