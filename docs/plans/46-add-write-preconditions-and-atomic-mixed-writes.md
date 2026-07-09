---
id: 46
slug: add-write-preconditions-and-atomic-mixed-writes
title: "Add write preconditions and atomic mixed writes"
kind: exec-plan
created_at: 2026-07-07T15:24:59Z
master_plan: "docs/masterplans/8-correct-write-path-and-storage-semantics.md"
intention: intention_01kx48hvkeemk9j4r828132s2h
---

# Add write preconditions and atomic mixed writes

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

en is a relationship-based authorization toolkit: applications write *tuples* ("alice is a
viewer of space:project-x") into PostgreSQL and the engine answers permission checks against
them. Today the write API is fire-and-forget: `writeTuples` and `deleteTuples` take a list of
tuples and always succeed. There is no way to say "grant this only if that other grant still
exists" or "delete this only if it is still there" — so two administrators can race (finding
E1 of `docs/reviews/2026-07-07-architecture-performance-review.md`): admin A revokes alice's
access while admin B, believing alice is still a member, grants her something conditioned on
that membership; both succeed and the system ends in a state neither intended. There is also
no atomic mixed operation — "remove the old grant and add the new one" takes two requests and
two tokens, with a visible intermediate state.

After this plan, callers can attach **preconditions** to any write — "these tuples must
(not) exist" expressed as filters — that are checked *inside the write transaction*: if a
precondition fails, the whole request aborts with a typed error (`WritePreconditionFailed`)
and no consistency token, and nothing was written. Callers can also mix writes and deletes in
one atomic request that returns one token. This is the role Zanzibar's paper assigns to *lock
tuples* (optimistic concurrency: a writer names the tuples its decision depended on) and that
SpiceDB exposes as `WriteRelationships` preconditions. You can see it working in
`cabal test en-postgres-integration-tests`: two sessions race a revoke guarded by
must-exist, and exactly one wins — the loser gets `WritePreconditionFailed`, not silence.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Verify the hard dependency: docs/plans/45-adopt-touch-semantics-for-tuple-writes.md is complete (its Progress items checked; `relation_tuple_live_unique` has no `caveat_name`; `touchReplaceStatement` exists in `en-postgres/src/En/Postgres/TupleStore.hs`).
- [ ] Add `TupleFilter`, `Precondition`, `TupleWriteRequest` and the `ApplyTupleWrites` constructor to `en-core/src/En/Effect/TupleStore.hs`; re-express `writeTuples`/`deleteTuples` as wrappers; remove the old `WriteTuples`/`DeleteTuples` constructors.
- [ ] Add `WritePreconditionFailed Text` to `en-core/src/En/Error.hs`.
- [ ] Implement `applyTupleWritesSession` in `en-postgres/src/En/Postgres/TupleStore.hs` (preconditions with `FOR SHARE` locking, deletes-then-writes, explicit `ROLLBACK` on failure).
- [ ] Implement `ApplyTupleWrites` in `en-core/src/En/Conformance/Kikan.hs` (pure filter matching over the State-held tuples; requires `Error EnError :> es`).
- [ ] Confirm `en-core/src/En/Effect/CachedTupleStore.hs` still passes writes through (compile-only).
- [ ] Extend the wire DTOs in `en-servant/src/En/Servant/API.hs` (`preconditions`, `deletes` as optional fields; `PreconditionWire`, `TupleFilterWire`) and the two handlers.
- [ ] Map `WritePreconditionFailed` to HTTP 412 in `en-servant/src/En/Servant/Seam.hs`.
- [ ] Verify `en-client/src/En/Client.hs` compiles unchanged (it re-exports the API DTOs).
- [ ] Add integration scenarios: sequential grant/revoke race, concurrent two-thread race, atomic mixed write, failed precondition writes nothing.
- [ ] Add an en-servant test exercising the new wire fields end-to-end against the in-memory store, including backward compatibility of a request without the new fields.
- [ ] Run `cabal build all`, `cabal test all`, `just start-and-test`; record transcripts.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Preconditions are filter-based (`TupleFilter` with optional fields), with
  exact-tuple preconditions expressed as fully-specified filters, rather than a separate
  exact-tuple variant.
  Rationale: SpiceDB's preconditions are relationship *filters* and subsume the exact-tuple
  case; two representations of "must exist" would force every interpreter to implement the
  same check twice. `objectType` is mandatory in the filter so a precondition can always be
  served by the existing indexes rather than a full scan.
  Date: 2026-07-07
- Decision: Replace the `WriteTuples` and `DeleteTuples` effect constructors with a single
  `ApplyTupleWrites :: TupleWriteRequest -> TupleStore m ConsistencyToken`, keeping
  `writeTuples` and `deleteTuples` as helper functions that build degenerate requests.
  Rationale: The master plan assigns this plan the *final* write signature. One constructor
  means every interpreter (PostgreSQL, in-memory, cached interposer) implements the
  transactional semantics exactly once; keeping three write constructors would triplicate the
  precondition logic or leave the old paths precondition-free and semantically divergent. The
  helper functions keep every existing call site (`en-servant/src/En/Servant/API.hs`, tests,
  examples) source-compatible.
  Date: 2026-07-07
- Decision: Within one `TupleWriteRequest`, preconditions are evaluated first, then deletes,
  then writes.
  Rationale: Deletes-before-writes makes "replace grant X with grant Y on the same key" a
  natural single request; the reverse order would have the delete immediately retire the
  fresh write. Preconditions first means a failed request provably performed no work.
  Date: 2026-07-07
- Decision: Must-exist preconditions lock the matched live rows with `FOR SHARE`;
  must-not-exist preconditions are a plain existence check backstopped by the
  `relation_tuple_live_unique` index from docs/plans/45.
  Rationale: Under PostgreSQL READ COMMITTED, an unlocked must-exist check could pass while a
  concurrent transaction soft-deletes the row and commits — the race E1 describes. `FOR
  SHARE` makes the concurrent soft-delete (an UPDATE) block until we commit, or makes our
  check re-evaluate and fail if the delete committed first. Absent rows cannot be locked, so
  must-not-exist relies on the unique index turning a racing duplicate insert into a loud
  unique-violation (`StoreError`) rather than silent duplication — fail-closed either way.
  Date: 2026-07-07
- Decision: A failed precondition issues an explicit `ROLLBACK` and surfaces as a new
  `EnError` constructor `WritePreconditionFailed Text` (the text names the failing
  precondition); no token is minted.
  Rationale: The transaction is not in an aborted state when a precondition check merely
  returns zero rows, so hasql's automatic reset does not apply — the session must roll back
  itself. A dedicated constructor lets callers (and, later, the typed wire error model of
  docs/plans/35-version-the-wire-contract-and-type-the-error-model.md) distinguish an
  arbitration loss from an outage.
  Date: 2026-07-07
- Decision: Wire changes are additive optional fields on the existing DTOs
  (`WriteTuplesRequestWire` gains `preconditions` and `deletes`; `DeleteTuplesRequestWire`
  gains `preconditions`), not new endpoints, and `WritePreconditionFailed` maps to HTTP 412.
  Rationale: The master plan's integration point: docs/plans/35 (versioned wire contract) has
  not landed at authoring time (its file is an unfilled skeleton), so this plan adds fields
  to the current DTOs and EP-35 absorbs them into the v1 envelope when it lands — the
  implementer must re-check docs/plans/35's Progress section before starting and put the
  fields in the v1 envelope instead if it has landed. Optional (`Maybe`) fields keep old
  request bodies decoding unchanged. The narrow 412 special-case in
  `enErrorToServerError` is recorded here so EP-35 subsumes rather than duplicates it.
  Date: 2026-07-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This plan is a child of `docs/masterplans/8-correct-write-path-and-storage-semantics.md` and
fixes gap E1 of `docs/reviews/2026-07-07-architecture-performance-review.md`. It
**hard-depends on docs/plans/45-adopt-touch-semantics-for-tuple-writes.md**: preconditions
are specified against *touch semantics* (a write conflicting with a differing live row
atomically replaces it; identical rewrites are no-ops; live-tuple uniqueness is keyed on
object/relation/subject without the caveat name). Before starting, open docs/plans/45 and
confirm its Progress checklist is complete; concretely verify that
`en-postgres/src/En/Postgres/TupleStore.hs` contains `touchReplaceStatement` and that the
migration re-keying `relation_tuple_live_unique` exists under
`en-migrations/db/migrations/`. Implementing preconditions against the older
`ON CONFLICT DO NOTHING` behavior would encode conflict semantics that plan replaces.

en is a Haskell project at `/Users/shinzui/Keikaku/bokuno/en` split into Cabal packages. The
files this plan touches:

- `en-core/src/En/Effect/TupleStore.hs` — the storage interface as an `effectful` *effect* (a
  GADT of operations interpreted by concrete stores). Today the write operations are
  `WriteTuples :: [Tuple] -> TupleStore m ConsistencyToken` and `DeleteTuples :: [Tuple] ->
  TupleStore m ConsistencyToken`. A `Tuple` (`en-core/src/En/Tuple.hs`) is `{object, relation,
  subject, caveat}`; a `ConsistencyToken` (`en-core/src/En/Revision.hs`) is the opaque string
  a write returns so later reads can see it ("read-your-writes").
- `en-core/src/En/Error.hs` — `EnError`, the closed error type (six constructors today).
- `en-postgres/src/En/Postgres/TupleStore.hs` — the hasql interpreter. After docs/plans/45,
  `writeTuplesSession` runs `BEGIN`; an *anchor* statement (inserting the write transaction's
  xid and snapshot into `en_transaction`, from which the token is minted); per-tuple touch
  statements; `COMMIT`. Sessions hand-roll `BEGIN`/`COMMIT` as `Session.script` calls. A row
  is *live* when `deleted_xid IS NULL`; deletes stamp `deleted_xid` (soft delete).
- `en-core/src/En/Conformance/Kikan.hs` — `runTupleStoreInMemory`, the in-memory interpreter
  (after docs/plans/45: stateful over `Effectful.State.Static.Local`, with pure helpers
  `tupleKey`/`touchTuple`/`deleteTupleByKey`). Used by `en-core` tests, the conformance
  suite (`en-core/conformance/Main.hs`, which runs under `runPureEff`), benchmarks,
  `en-servant/test/Main.hs`, and `en-example`.
- `en-core/src/En/Effect/CachedTupleStore.hs` — a read-cache interposer; its catch-all
  `passthrough` clause forwards any non-read operation, so it needs no code change, only a
  compile check.
- `en-servant/src/En/Servant/API.hs` — the HTTP surface. `POST /tuples` takes
  `WriteTuplesRequestWire { tuples :: [TupleWire] }`; `DELETE /tuples` takes
  `DeleteTuplesRequestWire` of the same shape; both return `WriteTuplesResponseWire { token ::
  Text }`. Handlers convert wire types with `tupleFromWire` and call the effect helpers via
  `runEngine`. `en-servant/src/En/Servant/Seam.hs` maps every `EnError` to HTTP 500 today
  (finding A3; the typed error model is docs/plans/35's job).
- `en-client/src/En/Client.hs` — a servant-client record over the same API type; it re-exports
  `En.Servant.API`, so DTO field additions flow through without client-code changes.
- `en-postgres/integration-test/Main.hs` — the `en-postgres-integration-tests` suite. It
  starts a throwaway PostgreSQL with `ephemeral-pg` (no external service; PostgreSQL binaries
  must be on `PATH`, which the project dev shell provides), creates the schema from an inline
  `schemaSql` string that mirrors the migration files, and asserts with `assertEqual`.
  `en-servant/test/Main.hs` tests handlers against the in-memory store via `runHandler`.

Term: **precondition / optimistic concurrency control (OCC)**. A writer states the facts its
decision depended on ("alice is still a member"); the store re-verifies them inside the write
transaction and rejects the write if they no longer hold. Zanzibar implements this with *lock
tuples* named in the write RPC; SpiceDB with `preconditions` on `WriteRelationships`. The
alternative — read, decide, write without a guard — is exactly the E1 race.

Integration points restated from the master plan
(`docs/masterplans/8-correct-write-path-and-storage-semantics.md`):

- **The `relation_tuple_live_unique` index shape is owned by docs/plans/45**; this plan builds
  statements against that shape and must not alter the index.
- **This plan (EP-46) defines the final `TupleStore` write signature.**
  docs/plans/48-batch-tuple-writes-and-add-bulk-import-and-export.md extends the effect (bulk
  export) *without altering this plan's constructors* and reimplements this plan's session
  with `unnest` batches — so keep the session logic factored into named statements it can
  reuse.
- **The write-token snapshot definition (`writeVisibleSnapshot`, `tokenFromAnchor`) is owned
  by docs/plans/47**; this plan must not adjust it — `applyTupleWritesSession` mints its token
  exactly the way `writeTuplesSession` does at the time of implementation.
- **Wire coordination**: the write-endpoint DTO changes must be coordinated with
  docs/plans/35-version-the-wire-contract-and-type-the-error-model.md as described in the
  Decision Log above (fields go into the v1 envelope if EP-35 has landed; otherwise into the
  current DTOs for EP-35 to absorb).


## Plan of Work

Three milestones: the effect and its two interpreters (the semantic core), the wire surface,
and the race-proving tests.


### Milestone 1 — Effect types and both store implementations

Scope: the new request/precondition types, the single write constructor, and working
PostgreSQL and in-memory implementations. At the end, embedded (library) callers can already
use preconditions and mixed writes; `cabal build all` and the existing suites pass.

In `en-core/src/En/Effect/TupleStore.hs` add (and export):

```haskell
-- | A filter over live tuples. 'Nothing' fields match anything. 'objectType'
-- is mandatory so precondition checks are always index-served.
data TupleFilter = TupleFilter
    { objectType :: !ObjectType
    , objectId :: !(Maybe Text)
    , relation :: !(Maybe RelationName)
    , subjectType :: !(Maybe ObjectType)
    , subjectId :: !(Maybe Text)
    , subjectRelation :: !(Maybe RelationName)
    }
    deriving stock (Eq, Show)

-- | A fact the write transaction re-verifies before applying any change.
data Precondition
    = TupleMustExist !TupleFilter
    | TupleMustNotExist !TupleFilter
    deriving stock (Eq, Show)

-- | One atomic write request: preconditions checked first, then deletes,
-- then writes, all in a single transaction minting a single token.
data TupleWriteRequest = TupleWriteRequest
    { preconditions :: ![Precondition]
    , writes :: ![Tuple]
    , deletes :: ![Tuple]
    }
    deriving stock (Eq, Show)
```

Replace the `WriteTuples` and `DeleteTuples` constructors with

```haskell
    ApplyTupleWrites :: TupleWriteRequest -> TupleStore m ConsistencyToken
```

and keep the old names as helpers so call sites do not churn:

```haskell
applyTupleWrites :: (TupleStore :> es) => TupleWriteRequest -> Eff es ConsistencyToken
applyTupleWrites = send . ApplyTupleWrites

writeTuples :: (TupleStore :> es) => [Tuple] -> Eff es ConsistencyToken
writeTuples tuples = applyTupleWrites TupleWriteRequest{preconditions = [], writes = tuples, deletes = []}

deleteTuples :: (TupleStore :> es) => [Tuple] -> Eff es ConsistencyToken
deleteTuples tuples = applyTupleWrites TupleWriteRequest{preconditions = [], writes = [], deletes = tuples}
```

In `en-core/src/En/Error.hs` add a constructor with a Haddock in the file's existing style:

```haskell
  | -- | A write precondition did not hold at the write transaction's snapshot.
    WritePreconditionFailed Text
```

PostgreSQL interpreter (`en-postgres/src/En/Postgres/TupleStore.hs`): replace
`writeTuplesSession`/`deleteTuplesSession` with one
`applyTupleWritesSession :: ConsistencyConfig -> TupleWriteRequest -> Session (Either Text
ConsistencyToken)` that runs, in order: `BEGIN`; the anchor statement; one precondition
statement per precondition; if any fails, `ROLLBACK` and return `Left description` (the
session must roll back explicitly — the transaction is healthy, merely unwanted); otherwise
the per-tuple delete statements (from docs/plans/45, caveat-ignoring), then the per-tuple
touch steps, then `COMMIT`, returning `Right (tokenFromAnchor config anchor)`. The
interpreter case becomes:

```haskell
ApplyTupleWrites request ->
    orThrow =<< runSession (applyTupleWritesSession config request)
        >>= either (throwError . WritePreconditionFailed) pure
```

(shape it so hasql transport errors still map to `StoreError` via the existing `orThrow` and
only the precondition outcome maps to `WritePreconditionFailed`). The two precondition
statements, following the existing `Statement.preparable` pattern with a
`Decoders.rowList`/`Decoders.singleRow` result:

```sql
-- must-exist: lock matching live rows so a racing revoke serializes with us.
SELECT id
FROM relation_tuple
WHERE object_type = $1
  AND ($2::text IS NULL OR object_id = $2)
  AND ($3::text IS NULL OR relation = $3)
  AND ($4::text IS NULL OR subject_type = $4)
  AND ($5::text IS NULL OR subject_id = $5)
  AND ($6::text IS NULL OR coalesce(subject_relation, '') = $6)
  AND deleted_xid IS NULL
LIMIT 1
FOR SHARE
```

```sql
-- must-not-exist: plain existence probe (absent rows cannot be locked; the
-- live-unique index from docs/plans/45 backstops racing inserts).
SELECT exists (
  SELECT 1
  FROM relation_tuple
  WHERE object_type = $1
    AND ($2::text IS NULL OR object_id = $2)
    AND ($3::text IS NULL OR relation = $3)
    AND ($4::text IS NULL OR subject_type = $4)
    AND ($5::text IS NULL OR subject_id = $5)
    AND ($6::text IS NULL OR coalesce(subject_relation, '') = $6)
    AND deleted_xid IS NULL
)
```

`TupleMustExist` fails when the first query returns no row; `TupleMustNotExist` fails when
the second returns `true`. The `FOR SHARE` is the concurrency keystone: a racing
`deleteTuples` is an `UPDATE … SET deleted_xid` on the same row, which must wait for our
share lock; conversely if the revoke committed first, our `SELECT … FOR SHARE` re-evaluates
the row under READ COMMITTED, finds `deleted_xid` set, matches nothing, and the precondition
fails. Failure text: a stable, human-readable rendering such as
`"must-exist: space:project-x#member@user:alice"` built from the filter.

In-memory interpreter (`en-core/src/En/Conformance/Kikan.hs`): implement
`ApplyTupleWrites request` against the `State [Tuple]` from docs/plans/45. Add a pure
`matchesFilter :: TupleFilter -> Tuple -> Bool` (flatten the subject with the same
wildcard/userset conventions the PostgreSQL store uses — a `SubjectWildcard` stores
`subject_id = "*"`, a `SubjectSet` carries its relation). Evaluate preconditions against the
current state; on failure `throwError (WritePreconditionFailed description)` — this adds an
`Error EnError :> es` constraint to `runTupleStoreInMemory`. Every existing caller already
interprets `Error EnError` beneath the store (`runErrorNoCallStack` in
`en-core/test/Main.hs`, `en-core/conformance/Main.hs`, `en-core/bench/Main.hs`,
`en-servant/test/Main.hs`, `en-example`), so this is a constraint addition, not a call-site
rewrite; fix any ordering compile errors by keeping `runTupleStoreInMemory` interpreted
*above* `runErrorNoCallStack` in each stack, as today. On success apply deletes
(`deleteTupleByKey`), then writes (`touchTuple`), and return the existing constant token.

Acceptance: `cabal build all` passes; `cabal test all` passes with zero behavioral changes
(the helpers make the old operations degenerate requests with empty preconditions).


### Milestone 2 — Wire surface: precondition fields and mixed writes over HTTP

Scope: the two existing write endpoints accept preconditions and mixed writes; the client
package follows for free. At the end, an HTTP caller can issue the guarded revoke.

First re-check the coordination gate: open
`docs/plans/35-version-the-wire-contract-and-type-the-error-model.md`. If its Progress shows
the v1 envelope landed, add the fields to the v1 request types instead of the legacy DTOs and
record that in this Decision Log. Otherwise (the expected case at authoring time — EP-35 is an
unfilled skeleton) proceed as follows.

In `en-servant/src/En/Servant/API.hs`:

- Add wire types (Generic JSON, matching the file's existing derive style):

  ```haskell
  data TupleFilterWire = TupleFilterWire
      { objectType :: !Text
      , objectId :: !(Maybe Text)
      , relation :: !(Maybe Text)
      , subjectType :: !(Maybe Text)
      , subjectId :: !(Maybe Text)
      , subjectRelation :: !(Maybe Text)
      }

  data PreconditionWire
      = TupleMustExistWire !TupleFilterWire
      | TupleMustNotExistWire !TupleFilterWire
  ```

  plus `preconditionFromWire :: PreconditionWire -> Either Text Precondition` (reject an
  empty `objectType`, mirroring `objectRefFromWire`'s validation style) and export the new
  types.
- Extend the request DTOs with optional fields (aeson's Generic decoding treats an omitted
  `Maybe` field as `Nothing`, so existing clients keep working — pin that with a test):

  ```haskell
  data WriteTuplesRequestWire = WriteTuplesRequestWire
      { tuples :: ![TupleWire]
      , deletes :: !(Maybe [TupleWire])
      , preconditions :: !(Maybe [PreconditionWire])
      }

  data DeleteTuplesRequestWire = DeleteTuplesRequestWire
      { tuples :: ![TupleWire]
      , preconditions :: !(Maybe [PreconditionWire])
      }
  ```

  (`WriteTuplesRequestWire` loses its `newtype` status; keep field names as shown so the JSON
  keys read naturally: `tuples` are writes, `deletes` are deletes.)
- Rewrite the two handlers to build a `TupleWriteRequest` and call `applyTupleWrites`:
  `writeTuplesHandler` maps `tuples`→`writes`, `fromMaybe [] deletes`→`deletes`,
  converted `preconditions`; `deleteTuplesHandler` maps `tuples`→`deletes`.

In `en-servant/src/En/Servant/Seam.hs`, split `enErrorToServerError` so
`WritePreconditionFailed message` returns `jsonError err412 message` (import `err412`) and
every other constructor keeps the current 500 mapping — a deliberately narrow special case
that docs/plans/35's typed error model will subsume.

`en-client/src/En/Client.hs` re-exports `En.Servant.API` and its record fields are typed by
the same DTOs, so it needs no edit — but build it to prove that
(`cabal build en-client`).

Acceptance: an en-servant test (in `en-servant/test/Main.hs`, which drives handlers with
`runHandler` against the in-memory store) proves (a) a request JSON *without* the new fields
still decodes and succeeds — encode a legacy body literally with `Data.Aeson.decode` to pin
backward compatibility; (b) a write with a failing `TupleMustNotExistWire` precondition
returns a `ServerError` with `errHTTPCode = 412`.


### Milestone 3 — Proving the race is gone

Scope: integration scenarios in `en-postgres/integration-test/Main.hs` demonstrating the E1
race losing deterministically, plus mixed-write atomicity. At the end,
`cabal test en-postgres-integration-tests` proves the headline behavior.

1. **Sequential guarded revoke**: write tuple T; issue
   `applyTupleWrites TupleWriteRequest{preconditions = [TupleMustExist (exactFilter T)],
   writes = [], deletes = [T]}` — succeeds with a token; issue the identical request again —
   returns `Left (WritePreconditionFailed …)` (assert on the constructor, not the exact
   text). Before this plan the second revoke silently "succeeded" with a token despite doing
   nothing.
2. **Concurrent two-session race**: acquire a *second* connection from the same
   `ephemeral-pg` database (`Connection.acquire (Pg.connectionSettings database)` — the
   suite's `acquire` helper already does this). Write T. Fork two threads
   (`Control.Concurrent.forkIO` plus `MVar`s to collect results; no new dependency), each
   running the guarded revoke from step 1 on its own connection. Join both and assert exactly
   one `Right token` and one `Left (WritePreconditionFailed …)`. The `FOR SHARE` lock makes
   this deterministic rather than timing-dependent: whichever transaction locks the row
   first wins; the other blocks, re-evaluates, and fails its precondition.
3. **Atomic mixed write**: one request with `deletes = [T]`, `writes = [U]` (same identity
   key, different caveat is a good choice) returns one token; `readStartingWithUser` at that
   token shows U live and T gone. One request, one token, no intermediate state to observe.
4. **Failed precondition writes nothing**: a request with `writes = [V]` (a fresh tuple) and
   a failing `TupleMustNotExist` precondition returns `Left`; a `FullyConsistent`-resolved
   read (or a read at a subsequent write's token) shows V absent — the transaction rolled
   back, and the connection still serves the next scenario (proving the explicit `ROLLBACK`
   left the session healthy).

`exactFilter` is a small test helper turning a `Tuple` into the fully-specified
`TupleFilter` for its identity key.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/en`.

1. Verify the hard dependency (see Context): docs/plans/45 complete;
   `grep -n touchReplaceStatement en-postgres/src/En/Postgres/TupleStore.hs` finds the
   statement; `ls en-migrations/db/migrations/` shows the touch-semantics migration. Also
   re-check `docs/plans/35-version-the-wire-contract-and-type-the-error-model.md` Progress
   for the wire-coordination gate.
2. Milestone 1 edits, then:

   ```bash
   cabal build all
   cabal test all
   ```

   Expected: everything passes with unchanged behavior (the integration suite needs no
   running service — `ephemeral-pg` starts its own throwaway PostgreSQL; the dev shell
   supplies the PostgreSQL binaries it launches).
3. Milestone 2 edits, then:

   ```bash
   cabal build en-servant en-client
   cabal test en-servant-tests
   ```

   Expected: the 412 assertion and the legacy-body decode assertion pass.
4. Milestone 3 scenarios, then:

   ```bash
   cabal test en-postgres-integration-tests
   ```

   Expected transcript fragment on failure regression (what pre-fix code would print for
   scenario 1):

   ```text
   second guarded revoke fails with WritePreconditionFailed
   expected: True
   actual:   False
   ```

   and a clean `1 of 1 test suites (1 of 1 test cases) passed.` when correct.
5. Dev-server smoke (brings up the dev PostgreSQL via process-compose, applies migrations,
   starts en-server, runs the HTTP round trip):

   ```bash
   just process-up
   just start-and-test
   ```

   Expected final line: `server smoke test passed: AllowedWire`. Optionally exercise a
   precondition over HTTP by hand:

   ```bash
   curl -sS -o /dev/null -w '%{http_code}\n' -X POST "http://localhost:8080/tuples" \
     -H 'content-type: application/json' \
     -d '{"tuples":[],"preconditions":[{"tag":"TupleMustExistWire","contents":{"objectType":"space","objectId":"nope","relation":"viewer","subjectType":"user","subjectId":"nobody","subjectRelation":null}}]}'
   ```

   Expected output: `412`.
6. Commit per milestone with the plan trailer, e.g.:

   ```text
   feat(en-core,en-postgres): add write preconditions and atomic mixed writes

   ExecPlan: docs/plans/46-add-write-preconditions-and-atomic-mixed-writes.md
   ```


## Validation and Acceptance

- The concurrent-race integration scenario is the headline: two sessions issue the same
  must-exist-guarded revoke and *exactly one* receives a token; the other receives
  `WritePreconditionFailed` — run `cabal test en-postgres-integration-tests` and observe it
  pass repeatedly (run it three times; the `FOR SHARE` design makes the outcome
  deterministic, so no flakes).
- A failed precondition provably writes nothing and returns no token (scenario 4).
- HTTP: a request with a failing precondition returns status 412 with the JSON error
  envelope; a legacy request body without the new fields behaves exactly as before
  (en-servant test + the curl transcript above).
- `cabal test all` passes — the constraint change to `runTupleStoreInMemory` and the
  constructor consolidation broke no consumer.


## Idempotence and Recovery

All build/test commands are idempotent. No migration is added by this plan (the schema
already supports it). The effect-signature change is source-breaking for out-of-tree
consumers of the `WriteTuples`/`DeleteTuples` *constructors* (not the helper functions);
in-tree, the compiler enumerates every affected site — fix them in the same commit so every
commit builds. The `FOR SHARE`-based session is safe to retry from the caller's side: a
failed request performed no writes, and re-issuing it re-evaluates preconditions afresh. If
Milestone 2's wire change needs reverting independently, it is confined to `en-servant` and
reverts cleanly without touching the effect layer.


## Interfaces and Dependencies

- `effectful`/`effectful-core` — effect definition and `throwError` in the in-memory store.
- `hasql` — the two precondition statements follow the existing `Statement.preparable`
  pattern in `en-postgres/src/En/Postgres/TupleStore.hs`.
- `aeson` (Generic) — the new wire types; no new package dependencies anywhere.
- `base` (`Control.Concurrent`, `MVar`) — the two-thread race test; deliberately no `async`
  dependency.

Signatures that must exist at the end (full module paths):

- `En.Effect.TupleStore.TupleFilter`, `En.Effect.TupleStore.Precondition`,
  `En.Effect.TupleStore.TupleWriteRequest` (records as in Milestone 1);
  `En.Effect.TupleStore.TupleStore` with `ApplyTupleWrites :: TupleWriteRequest -> TupleStore
  m ConsistencyToken` and *without* `WriteTuples`/`DeleteTuples` constructors;
  `En.Effect.TupleStore.applyTupleWrites`, `.writeTuples`, `.deleteTuples` helpers.
- `En.Error.EnError` with `WritePreconditionFailed Text`.
- `En.Postgres.TupleStore.applyTupleWritesSession :: ConsistencyConfig -> TupleWriteRequest
  -> Session (Either Text ConsistencyToken)` (internal).
- `En.Conformance.Kikan.runTupleStoreInMemory :: (Error EnError :> es) => [Tuple] -> Eff
  (TupleStore : es) a -> Eff es a`.
- `En.Servant.API.PreconditionWire`, `.TupleFilterWire`; `WriteTuplesRequestWire` with
  `tuples`/`deletes`/`preconditions`; `DeleteTuplesRequestWire` with
  `tuples`/`preconditions`.

Cross-plan boundary (restated): the uniqueness index is docs/plans/45's (consumed here,
never altered); this plan's `ApplyTupleWrites` is the final write signature that
docs/plans/48 batches with `unnest` and extends (bulk export) without altering; the token's
snapshot construction (`writeVisibleSnapshot`) is docs/plans/47's and is called here exactly
as the pre-existing sessions call it; the wire fields land per the EP-35 coordination
recorded in the Decision Log.
