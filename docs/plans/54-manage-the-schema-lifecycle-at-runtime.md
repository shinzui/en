---
id: 54
slug: manage-the-schema-lifecycle-at-runtime
title: "Manage the schema lifecycle at runtime"
kind: exec-plan
created_at: 2026-07-07T15:25:10Z
intention: intention_01kx4y4empedt9g83mprcrew89
master_plan: "docs/masterplans/9-complete-the-en-api-surface.md"
---

# Manage the schema lifecycle at runtime

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`docs/plans/26-load-developer-schemas-into-the-production-server-at-runtime.md` gave
`en-server` the ability to load a developer's authorization model from a text file
(`EN_SCHEMA_PATH`) at startup — and deliberately stopped there: one schema per
process, loaded once, no reload, no read-back, no validation of stored data against a
changed model (its Decision Log records hot reload as an explicit follow-up). That
leaves operators blind and rigid: there is no way to ask a running server which model
it is serving, changing the model requires a restart, and nothing warns that the new
model orphans existing grants — a schema edit that drops a relation silently strands
every tuple written under it. This is gap E6 of
`docs/reviews/2026-07-07-architecture-performance-review.md`, coordinated by
`docs/masterplans/9-complete-the-en-api-surface.md`. This plan extends plan 26;
read that plan's Context and Orientation first — its description of the schema
model, the text DSL, and the loader is assumed here.

After this change: `GET /schema` returns the exact schema source text the server is
serving, its hash, where it was loaded from, and when. Sending the server `SIGHUP`
reloads the schema file with an atomic swap — in-flight requests finish on the old
schema, new requests see the new one — and the reload is gated by a stored-tuple
validation pass that scans every live grant against the candidate schema and refuses
activation (unless explicitly forced) when grants would be orphaned, printing exactly
which and why. The same pass is available offline as `en-server check-schema
<path>`, so a schema change can be vetted before deployment. The plan also documents
the compatible-change taxonomy (what edits are safe, what edits strand data, what
edits merely change decisions) and states precisely what happens to outstanding
consistency tokens on reload — they are all invalidated, and the server says so
loudly.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1 (2026-07-10): Introduce `ActiveSchema` and the schema handle: `Env` in `en-servant/src/En/Servant/Seam.hs` gains `readActiveSchema`; `runPorts` becomes snapshot-taking; handlers in `en-servant/src/En/Servant/API.hs` and `en-servant/src/En/Servant/Authorize.hs` read one snapshot per request; `en-server/app/Main.hs` builds the `IORef`. Behavior unchanged; `cabal test en-core en-servant en-example` green.
- [x] M1 (2026-07-10): Add `GET /v1/schema` (route, `SchemaInfoWire`, handler, `EnClient.readSchema`), serving source text, hash, origin, and load time. Served hash equals the startup log's; `/v1/openapi.json` lists the path.
- [x] M2 (2026-07-10): live-tuple enumeration primitive — **cancelled, pre-landed**. `ReadAllTuples` already is `EnumerateTuples`, in the effect and in both interpreters. See Surprises & Discoveries.
- [x] M2 (2026-07-10): Implement `En.SchemaCheck.validateTuplesAgainstSchema` (pure per-tuple checks, orphan report types) with en-core unit tests covering every orphan class, both directions of the caveat-payload rule, and the "one reason per tuple" ordering.
- [x] M2 (2026-07-10): Add the `check-schema` subcommand to `en-server/app/Main.hs` with its report output and exit codes (0/1/2, all four exercised live); integration-test the pass against an ephemeral database over a fixture larger than one drain page, plus a retired grant that is owed no orphan.
- [x] M2 (2026-07-10): Write the compatible-change taxonomy into `docs/user/service-and-operations.md`, cross-checked line by line against the six `OrphanReason` constructors and their rendered messages.
- [ ] M3: Implement SIGHUP reload: re-read `EN_SCHEMA_PATH`, parse/validate/compile, run the stored-tuple pass, atomically swap the `IORef`, log old/new hash and the token-invalidation warning; `EN_SCHEMA_RELOAD_FORCE=1` override; failure leaves the old schema serving.
- [ ] M3: Live acceptance: reload transcript (schema edit → SIGHUP → `GET /schema` shows new hash; old token rejected; orphaning edit refused) pasted into Validation and Acceptance.
- [ ] Deferred (recorded, not in this plan): authenticated `POST /admin/schema/reload` once `docs/plans/33-add-caller-authentication-and-rate-limiting-to-en-server.md` lands.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-07-10 (orientation; **cancels M2's enumeration primitive**): `EnumerateTuples` already
  exists, under another name and with the exact signature this plan proposes for it.
  `ReadAllTuples :: Revision -> Int -> Maybe StoreCursor -> TupleStore m TuplePage` is a
  constructor of `TupleStore` in `en-core/src/En/Effect/TupleStore.hs`, documented as "every
  tuple live at @revision@, ordered by internal row id and keyset-paginated: the whole graph,
  page by page", and it is implemented in both interpreters this plan names —
  `en-postgres/src/En/Postgres/TupleStore.hs:133` (`readAllTuplesSession`) and
  `en-core/src/En/Conformance/Kikan.hs:199`. It was added for `en-server export`, which drains
  it at a pinned head revision exactly as the validation pass must. Its Haddock even states the
  property orphan detection depends on — ordering by row id, not by any tuple field, so the scan
  needs no index of its own and no anchoring. This plan adds no store operation at all.

- 2026-07-10 (orientation; **simplifies M1's `ActiveSchema`**): the schema hash is already
  carried by the compiled graph. `ReachabilityGraph` in `en-core/src/En/Reachability.hs:43` has
  fields `relations`, `caveats`, and `hash :: !SchemaHash`, and `En.Check` reads it as
  `graph.hash` when it builds a `SubproblemKey` (`en-core/src/En/Check.hs:444`) — which is *why*
  the decision cache self-invalidates on reload, as this plan's Decision Log asserts. A separate
  `hash` field on `ActiveSchema` would be a second copy of a value that is already there, and
  two copies can disagree. See the Decision Log.

- 2026-07-10 (orientation; **resolves M3's open question about the connection**):
  `docs/plans/34-pool-database-connections-in-en-server.md` has landed (commit `a32e8f5`, "serve
  every request from a hasql connection pool"). M3's note — "be mindful the server currently has
  a single shared connection — review A2 — so the pass briefly contends with request traffic" —
  is stale. `runAppIO` runs through `runDatabasePool pool`, so the reload's validation pass takes
  a pooled connection like any request, and the contention it costs is one pool slot for the
  duration of the scan.

- 2026-07-10 (M1; the demo schema's source text was a hazard the moment `GET /v1/schema` existed):
  `demoSchema` was built with `En.Schema.Builder`, so serving a `source` for it meant writing the
  equivalent DSL text by hand and trusting it. It happened to be right — a server started with the
  hand-written text in a file reported `fnv1a64:88633b46c783909e`, the same hash the built-in model
  reports — but nothing enforced it, and the endpoint's whole promise is that `source` *is* the model
  being served. `demoSchema` is now `parseSchema demoSchemaSource`, so the text is the source of
  truth and the model is derived from it by the same parser `EN_SCHEMA_PATH` goes through. The hash
  is unchanged, which is the evidence the two were equivalent; `En.Schema.Builder` is no longer
  imported by `en-server`.

- 2026-07-10 (M1; a Haskell detail that will bite the next plan touching these records): GHC solves
  the `HasField` constraint behind `active.graph.hash` only when the record field is *in scope* at
  the use site. `En.Servant.API` and `en-server/app/Main.hs` therefore import
  `En.Reachability (ReachabilityGraph (..))` purely for its `hash` field, and removing that import
  as "redundant" produces `No instance for HasField "hash" ReachabilityGraph SchemaHash` rather than
  an unused-import warning. Under `NoFieldSelectors` the error is worse: it points at the *other*
  record with a `hash` field (`SchemaInfoWire`) and suggests using that one.

- 2026-07-10 (orientation; **corrects M2's description of `en-server`'s argument handling**):
  `en-server/app/Main.hs` does not "currently ignore `getArgs`". It has a `Command` sum
  (`Serve`/`Import`/`Export`), a `parseCommand`, and a `usage` that exits 2 — the exit code this
  plan reserves for "file or schema invalid". `check-schema` is a fourth constructor, and it
  wants the existing `withSubcommandStore` prologue (which loads `StoreConfig`, not
  `ServerConfig`, precisely because a command that binds no port has no API keys or TLS material
  to configure). Note the collision: `usage` already exits 2, so a `check-schema` invocation with
  a bad *candidate* file must be distinguishable in prose from one with bad *arguments*.


## Decision Log

Record every decision made while working on the plan.

- Decision: `GET /schema` serves the *stored source text* captured at load time (plus hash, origin, load time), not a rendering of the in-memory `Schema` value.
  Rationale: The only renderers that exist (`en-core/src/En/Schema/Render.hs`) produce Markdown and Mermaid for documentation — plan 26's Interfaces section explicitly notes there is no `Schema -> Text` serializer for the loadable DSL, and inventing one is a standing round-trip contract this plan does not need. The source text is what the operator wrote and what a `check-schema` run should be diffed against; keeping it verbatim is both cheaper and more useful. The built-in demo schema (no file) serves a canned source string labeled `origin: "builtin-demo"`.
  Date: 2026-07-07
- Decision: Reload is triggered by `SIGHUP` in this plan; an authenticated admin endpoint (`POST /admin/schema/reload`) is deferred until `docs/plans/33-add-caller-authentication-and-rate-limiting-to-en-server.md` (master plan 6) lands.
  Rationale: The API is completely unauthenticated today (review A1/E8). Adding an unauthenticated HTTP route that swaps the authorization model would be the single worst endpoint in the service. `SIGHUP` requires process-level access, matches operator expectations (nginx, PostgreSQL), and needs no auth story. The deferred endpoint is recorded in Progress so it is not forgotten.
  Date: 2026-07-07
- Decision: The swap mechanism is one `IORef ActiveSchema` in `en-server/app/Main.hs`, snapshot-read once per request. `Env.runPorts` changes type to take the snapshot (`forall a. ActiveSchema -> Eff es a -> IO (Either EnError a)`) so the reachability graph the handler evaluates against and the schema hash the interpreters mint/validate tokens with come from the *same* snapshot.
  Rationale: The schema hash is baked into `ConsistencyConfig`, which the store interpreters capture when the effect stack is built (see `runConsistencyStorePostgres` and `runTupleStorePostgres` usage in `en-server/app/Main.hs`). If the handler read the graph and the interpreter read the hash independently, a swap between the two reads would evaluate on the old graph while minting tokens under the new hash — a torn request. Passing one snapshot through `runPorts` makes tearing impossible and gives the "in-flight requests finish on the old schema" guarantee for free: a request holds its snapshot; `atomicWriteIORef` affects only later reads. `IORef` with `atomicWriteIORef` suffices because there is exactly one writer (the signal handler) and readers never write.
  Date: 2026-07-07
- Decision: The stored-tuple validation pass runs on every reload and blocks activation when it finds orphans, unless `EN_SCHEMA_RELOAD_FORCE=1` is set; it is also exposed offline as the `check-schema` subcommand.
  Rationale: Fail-closed by default — the same posture plan 26 chose for startup. The force override exists because intentionally destructive migrations are legitimate (an operator removing a feature wants its grants dead); forcing is explicit, logged, and leaves the orphan report in the log. The offline subcommand exists so CI or a deploy pipeline can vet a schema against production data before any process is touched.
  Date: 2026-07-07
- Decision: Tuple enumeration for the validation pass uses a dedicated full-scan storage operation (`EnumerateTuples`: all live-at-head tuples, id-keyset paged) rather than requiring `docs/plans/50-expose-relationship-read-and-delete-by-filter-endpoints.md`'s filter.
  Rationale: The soft dependency in the master plan says EP-54 *wants* EP-50's filter for per-type enumeration but can use store effects directly. On inspection the filter is anchored (it requires an object type or subject type), and orphan detection must find tuples whose types are *not in the new schema* — an unanchored scan by construction. A validation pass is an admin operation where a sequential scan is acceptable and honest. If EP-50 has landed, its `RelationshipFilter` machinery can share the SQL plumbing, but the unanchored enumeration is still this plan's own primitive.
  Date: 2026-07-07
- Decision: Outstanding consistency tokens are invalidated by any reload that changes the schema text at all, and reload logs this as a prominent warning with the old and new hash. No token-migration mechanism is added.
  Rationale: This is existing behavior, verified in `validateTokenMetadata` (`en-postgres/src/En/Postgres/Revision.hs`): a token whose embedded schema hash differs from the active `ConsistencyConfig.schemaHash` is rejected with "token schema hash does not match the active schema". The hash (`schemaHash` in `en-core/src/En/Schema.hs`) covers the entire rendered model, so even a purely additive edit rotates it. Plan 26's Idempotence section already documents "treat a schema change like a migration"; this plan makes the moment observable (the warning names both hashes) rather than changing the mechanism. Accepting old-hash tokens after compatible changes would require a hash-compatibility oracle and is out of scope; recorded as a possible future refinement.
  Date: 2026-07-07
- Decision: Caches survive reload untouched: the decision cache self-invalidates because `SubproblemKey` includes the schema hash (see `decisionCacheOps` in `en-core/src/En/Check.hs`), so post-reload lookups miss; the tuple-read cache is schema-independent (keyed by revision and query, not by model) and stays valid.
  Rationale: Verified in source; flushing them on reload would be harmless but unnecessary. If implementation finds a `TupleReadKey` component that does depend on the schema, flush it and amend this entry.
  Date: 2026-07-07
- Decision: `validateTuplesAgainstSchema` returns an `OrphanReport { scanned, orphans }`, not the bare `[TupleOrphan]` this plan's Interfaces section specifies.
  Rationale: The report line the plan itself specifies — "N orphan(s) across M live tuple(s)" — needs the scanned count, and recovering it with a second full scan would double the cost of an already-sequential pass. "0 orphans" over an empty store and over 200,000 grants are different reports, and an operator about to force a destructive schema through needs to know which one they are reading. The scan visits every row either way, so the count is free.
  Date: 2026-07-10
- Decision: `check-schema` loads and validates its candidate *before* the store configuration, and reports candidate failures through a `candidateFailure` that exits 2 rather than the existing `configFailure` that exits 1.
  Rationale: Exit 1 is reserved for "this candidate strands live grants", which is the answer a deploy pipeline gates on. If a typo in a schema file also exited 1, the pipeline could not tell a broken file from a destructive migration — the worst possible confusion for this command. Loading the candidate first additionally means a bad file costs no database round trip and emits no "serving the built-in demo schema" warning from a command that serves nothing. The 2 is shared with `usage`, which is honest: both mean the operator handed the command something it cannot act on.
  Date: 2026-07-10
- Decision: `demoSchema` is parsed from `demoSchemaSource`, not built with `En.Schema.Builder` alongside a hand-written source string.
  Rationale: See Surprises. `GET /v1/schema` promises `source` is the text of the model being served; a builder-built model plus a string asserting its text can only be kept in step by discipline, and the endpoint exists precisely because operators cannot see the model otherwise. Deriving the model from the text makes the promise structural. The demo model's hash is unchanged (`fnv1a64:88633b46c783909e`), which is the evidence the two spellings agreed.
  Date: 2026-07-10
- Decision: `GET /v1/schema` is a plain `Get`, not a `MultiVerb` over `EnResponses`, and carries no `checkedAt`.
  Rationale: It reads one `IORef` and cannot fail, so it has no fault to return into a response alternative; giving it the shared five-alternative list would document four statuses it can never produce. On `checkedAt`, the master plan left this plan to decide: the field names the tuple-store snapshot a read was evaluated at, and this operation reads no tuples and describes no revision. `loadedAt` is the analogous freshness handle and answers the only question a caller can ask. The OpenAPI test asserts the endpoint documents exactly a `200`, so a later refactor cannot quietly give it the fault list.
  Date: 2026-07-10
- Decision: `ActiveSchema` carries no `hash` field. The hash is `active.graph.hash`.
  Rationale: `ReachabilityGraph` already carries `hash :: SchemaHash`, and `En.Check` reads it from there to key the decision cache. A second copy on `ActiveSchema` would have to be kept equal to the first by convention, and the one place it could silently diverge — a reload that swapped the graph but reused the old hash — is precisely the torn state M1's snapshot discipline exists to make impossible. The `ConsistencyConfig` each request's interpreter stack is built with therefore reads `snapshot.graph.hash`, so graph and hash cannot come apart by construction rather than by care. `SchemaInfoWire.hash` renders the same value.
  Date: 2026-07-10
- Decision: The enumeration primitive is `ReadAllTuples`, which already exists; `EnumerateTuples` is not added.
  Rationale: See Surprises. Its signature is the one this plan specified for `EnumerateTuples`, its Haddock states the row-id ordering the unanchored scan needs, and it is implemented in both interpreters. Adding a synonym would give the store two names for one query and every future interpreter two obligations. The plan's argument for *why* an unanchored scan is the right primitive — orphan detection must find tuples whose types are absent from the new schema, which no anchored filter can express — is unaffected and is why `ReadAllTuples` rather than `ReadRelationships` is the right existing operation to reach for.
  Date: 2026-07-10
- Decision: This plan owns the runtime schema handle. Every other endpoint (including those added by `docs/plans/50`, `51`, `52`, `53`) reads the schema through `ActiveSchema` after M1; plans implemented before this one use the existing immutable `Env.graph` argument and this plan rewires them during M1.
  Rationale: Restates the master plan's Integration Points so this plan stands alone; a second schema-state mechanism must not appear.
  Date: 2026-07-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

The repository root is `/Users/shinzui/Keikaku/bokuno/en` (Haskell, GHC 9.12.4,
`cabal`). Read `docs/plans/26-load-developer-schemas-into-the-production-server-at-runtime.md`
before starting: it defines the schema model (`Schema` in
`en-core/src/En/Schema/Types.hs`), the text DSL and its parser
(`En.Schema.Parse.parseSchema`, `en-core/src/En/Schema/Parse.hs`), and the startup
loader this plan generalizes. This plan fixes gap E6 of
`docs/reviews/2026-07-07-architecture-performance-review.md` under
`docs/masterplans/9-complete-the-en-api-surface.md`.

Current schema flow, from `en-server/app/Main.hs`: `loadSchema` reads
`EN_SCHEMA_PATH` (or falls back to the built-in `demoSchema` with a warning), parses
with `parseSchema`, then `main` validates (`validateSchema`, returning the
`ValidSchema` evidence type), hashes (`schemaHash` — an FNV-1a-64 fingerprint of the
whole rendered model, e.g. `fnv1a64:1061a4beb2d5506c`), compiles
(`En.Reachability.compile` into the `ReachabilityGraph` the evaluators walk), and
threads the pieces into two places: the `Env` record
(`en-servant/src/En/Servant/Seam.hs`) as the immutable `graph` field that every
handler passes to check/lookup/expand, and `ConsistencyConfig`
(`en-postgres/src/En/Postgres/Revision.hs`) whose `schemaHash` the store interpreters
embed in every minted consistency token and check on every presented one
(`validateTokenMetadata` rejects a mismatch with "token schema hash does not match the
active schema"). Both are captured once at startup — that is exactly what this plan
makes swappable.

`Env` and the request path: each Servant handler calls `runEngine env action`, which
invokes `env.runPorts` — a closure built in `Main.hs` (`runAppIO`) that assembles the
effect interpreter stack (database connection, error handling, tuple store with the
`ConsistencyConfig`, consistency store with the same config) and runs the action.
Handlers also read `env.graph` directly as an argument to the engine functions. The
per-request lifecycle is therefore: handler reads graph → handler calls runPorts →
interpreters use config. M1 restructures this so one `ActiveSchema` snapshot feeds
all of it.

Tuple/schema compatibility, grounded in the actual types. A stored tuple
(`En.Tuple.Tuple`) names an object type, a relation, a subject (concrete, userset, or
wildcard), and optionally a caveat name plus typed payload. The schema constrains all
of these: `Schema.objectTypes :: Map ObjectType (Map RelationName Relation)` says
which relations exist; `Relation.allowedSubjects :: Set AllowedSubject` (fields
`objectType`, `relation :: Maybe RelationName`, `wildcard :: Bool`) says which
subject shapes a relation accepts; `Schema.caveats :: Map CaveatName
CaveatDefinition` (with `parameters :: Map CaveatParameterName CaveatParameterType`)
says which caveats exist and what their parameters' types are. `validateSchema`
(`en-core/src/En/Schema.hs`) checks the schema's *internal* consistency only — no
code anywhere checks stored tuples against a schema; that check is what M2 builds.

The dev workflow commands (Justfile): `just process-up` starts the local PostgreSQL
under process-compose; `just run-migrations` applies
`en-migrations/db/migrations/*.sql` with `psql`; `just start-server` does both then
`cabal run en-server`; `just process-down` stops services. The integration test suite
`en-postgres-integration-tests` uses `ephemeral-pg` and needs no dev database.

External sequencing restated from the master plan: prefer landing
`docs/plans/35-version-the-wire-contract-and-type-the-error-model.md` (master plan 6)
first so `GET /schema` is born inside the versioned wire contract. The soft
dependency on `docs/plans/50` and this plan's ownership of the schema handle are
covered in the Decision Log.


## Plan of Work

Three milestones: the schema handle plus the read endpoint (M1), the stored-tuple
validation pass, subcommand, and taxonomy (M2), and SIGHUP reload with the atomic
swap (M3). M2 is independent of M1 (it needs no server); M3 needs both.


### Milestone 1: the ActiveSchema handle and GET /schema

Scope: after this milestone the server's schema state lives behind one readable
handle, request handling takes a consistent per-request snapshot, and `GET /schema`
reports the live model. Externally visible behavior otherwise unchanged.

Define (in `en-servant/src/En/Servant/Seam.hs`, since both en-servant and en-server
need it):

```haskell
data ActiveSchema = ActiveSchema
    { graph :: !ReachabilityGraph
    , hash :: !SchemaHash
    , source :: !Text        -- verbatim schema text (or the canned demo source)
    , origin :: !Text        -- file path, or "builtin-demo"
    , loadedAt :: !UTCTime
    }
```

Rework `Env es`: replace `graph :: ReachabilityGraph` with
`readActiveSchema :: IO ActiveSchema`, and change
`runPorts :: forall a. Eff es a -> IO (Either EnError a)` to
`runPorts :: forall a. ActiveSchema -> Eff es a -> IO (Either EnError a)`.
`runEngine` gains the snapshot parameter. Every handler in
`en-servant/src/En/Servant/API.hs` starts with
`active <- liftIO env.readActiveSchema` and uses `active.graph` where it used
`env.graph`, passing `active` to `runEngine`. Adapt
`en-servant/src/En/Servant/Authorize.hs` the same way, and update
`en-servant/test/Main.hs` (test envs become `readActiveSchema = pure fixedSnapshot`
with `runPorts _ = …`).

In `en-server/app/Main.hs`: extend `loadSchema` to also return the raw source text
(it already reads the file; keep the text) and a canned demo source for the fallback;
build `ActiveSchema`, create `activeSchemaRef <- newIORef activeSchema`, set
`readActiveSchema = readIORef activeSchemaRef`, and make `runAppIO` take the snapshot
and construct that request's `ConsistencyConfig` from `snapshot.hash` (the
interpreter stack is already assembled per `runPorts` invocation, so this is moving
the config construction inside). Keep the startup log lines from plan 26 (loaded
path, schema hash) unchanged.

Add the read endpoint to `EnAPI`:

```haskell
        :<|> "schema" :> Get '[JSON] SchemaInfoWire
```

with `SchemaInfoWire { source :: Text, hash :: Text, origin :: Text, loadedAt ::
UTCTime }`, a handler that reads the snapshot, and an `EnClient.readSchema` field in
`en-client/src/En/Client.hs`. (This response carries no `checkedAt` token — it is
server metadata, not a tuple-store read, so the convention of `docs/plans/51` does
not apply.)

Acceptance: `cabal build all` and all existing test suites pass; against a running
server, `curl -sS localhost:8080/schema` returns the source text and the same hash
the startup log printed.


### Milestone 2: the stored-tuple validation pass, subcommand, and taxonomy

Scope: after this milestone `en-server check-schema <path>` connects to the
database, scans every live grant against the candidate schema, and prints a precise
orphan report; the pure checker lives in en-core with unit tests; the taxonomy is
documented.

Enumeration primitive. Add to `En.Effect.TupleStore`
(`en-core/src/En/Effect/TupleStore.hs`):

```haskell
    EnumerateTuples :: Revision -> Int -> Maybe StoreCursor -> TupleStore m TuplePage
```

("all tuples live at this revision, id-keyset paged, no filter"). PostgreSQL
implementation in `en-postgres/src/En/Postgres/TupleStore.hs` is
`readObjectRelationStatement` minus the object/relation predicates; in-memory
implementation in `en-core/src/En/Conformance/Kikan.hs` pages the fixture list. This
is deliberately a sequential scan (see Decision Log).

Pure checker. Create `en-core/src/En/SchemaCheck.hs` (add to `exposed-modules`):

```haskell
data TupleOrphan = TupleOrphan
    { tuple :: !Tuple
    , reason :: !OrphanReason
    }

data OrphanReason
    = OrphanUnknownObjectType !ObjectType
    | OrphanUnknownRelation !ObjectType !RelationName
    | OrphanDisallowedSubject !Subject          -- subject shape not in allowedSubjects
    | OrphanUnknownSubjectType !ObjectType      -- subject's type absent from schema
    | OrphanUnknownCaveat !CaveatName
    | OrphanCaveatPayloadMismatch !CaveatName ![Text]  -- per-key type errors

checkTupleAgainstSchema :: ValidSchema -> Tuple -> Maybe TupleOrphan

validateTuplesAgainstSchema ::
    (TupleStore :> es) =>
    ValidSchema -> Revision -> Eff es [TupleOrphan]   -- drains EnumerateTuples pages
```

`checkTupleAgainstSchema` implements exactly: the tuple's object type must be a key
of `schema.objectTypes`; its relation must exist on that type; the subject must match
some `AllowedSubject` of the relation (`SubjectId t` needs an entry with
`objectType = t, relation = Nothing, wildcard = False`; `SubjectSet t r` needs
`objectType = t, relation = Just r`; `SubjectWildcard t` needs
`objectType = t, wildcard = True`), and the subject's own type (and, for usersets,
the named relation on it) must exist in the schema; a caveat's name must be in
`schema.caveats`, every payload key must be a declared parameter, and each payload
value's type must match the declared `CaveatParameterType` (including enum-value
membership for `ParameterEnum`). Unit-test every reason in `en-core/test/Main.hs`
with hand-built schemas and tuples, including the negative case (a fully valid tuple
returns `Nothing`).

Subcommand. `en-server/app/Main.hs` currently ignores `getArgs`; add dispatch: no
arguments = serve (unchanged); `check-schema <path>` = read/parse/validate the
candidate file (reusing plan 26's loader pieces), connect via `EN_DATABASE_URL`,
resolve the head revision, run `validateTuplesAgainstSchema`, print a report, and
exit 0 (clean) / 1 (orphans found) / 2 (file or schema invalid). Report format, one
orphan per line plus a summary:

```text
ORPHAN space:project-x#viewer@user:alice — relation space#viewer not in candidate schema
1 orphan(s) across 1 live tuple(s); candidate schema fnv1a64:9f… would strand them.
```

Integration-test the pass in `en-postgres/integration-test/Main.hs`: seed tuples,
validate against a schema missing one relation, assert the exact orphan set; validate
against a superset schema, assert none.

Taxonomy. Add a "Changing the schema" section to
`docs/user/service-and-operations.md` stating, as prose, the classification below
(this is the deliverable's source of truth; keep the document and the validator's
behavior in lockstep):

- **Compatible (no orphans possible):** adding object types; adding relations or
  permissions to existing types; widening a relation's allowed subjects (new subject
  type, new userset, adding wildcard); adding caveat definitions; adding caveat
  parameters (existing payloads simply do not use them).
- **Behavioral, not structural (allowed; changes decisions, warn in docs):** editing
  a permission's rewrite expression (permissions are computed, never stored, so no
  tuple can be orphaned — but every decision involving the permission can change);
  editing a caveat's predicate without touching its parameters.
- **Blocked unless forced (strands live grants — the validator detects each):**
  removing an object type that live tuples use as object or subject
  (`OrphanUnknownObjectType`/`OrphanUnknownSubjectType`); removing a relation with
  live tuples (`OrphanUnknownRelation`), which includes renames (a rename is a
  remove plus an add); narrowing allowed subjects below a shape that live tuples use,
  including removing a wildcard allowance (`OrphanDisallowedSubject`); removing a
  caveat definition with live caveated tuples (`OrphanUnknownCaveat`); changing a
  caveat parameter's type, or removing a parameter, when live payloads carry the old
  shape (`OrphanCaveatPayloadMismatch`).
- **Always true, for every change of any size:** the schema hash rotates, so *all*
  outstanding consistency tokens — including write tokens clients are holding for
  read-your-writes — are rejected afterwards with "token schema hash does not match
  the active schema" (`validateTokenMetadata`,
  `en-postgres/src/En/Postgres/Revision.hs`). Treat any schema change like a
  migration; clients must be prepared to fall back from `AtLeastAsFresh` chaining to
  `FullyConsistent` and re-acquire tokens.

Acceptance: `cabal test en-core` (checker units), `cabal test
en-postgres-integration-tests` (the pass), and a manual `check-schema` transcript as
in Concrete Steps.


### Milestone 3: SIGHUP reload with atomic swap

Scope: after this milestone an operator edits the schema file, sends `SIGHUP`, and
the server serves the new model without restarting — or refuses, loudly and safely.

In `en-server/app/Main.hs`, install a handler before starting Warp (add `unix` to
`en-server/en-server.cabal` build-depends):

```haskell
_ <- installHandler sigHUP (Catch (reloadSchema activeSchemaRef runValidationPass)) Nothing
```

`reloadSchema`: if the process was started without `EN_SCHEMA_PATH`, log
"SIGHUP received but no EN_SCHEMA_PATH is set; nothing to reload" and return. Else
re-read the file, `parseSchema`, `validateSchema`, `schemaHash`, `compile` — any
failure logs the error and *returns without swapping* (the old schema keeps
serving; this mirrors plan 26's fail-closed startup, but a running server must
survive a bad reload rather than exit). Then run the M2 validation pass against the
head revision under the *candidate* schema: if orphans are found and
`EN_SCHEMA_RELOAD_FORCE` is not `1`, log the orphan report and
"reload refused; set EN_SCHEMA_RELOAD_FORCE=1 to activate anyway" and return.
Otherwise build the new `ActiveSchema` (fresh `loadedAt`) and `atomicWriteIORef`.
Always log, on success:

```text
Schema reloaded from /path/to/schema.en
Schema hash: fnv1a64:<new> (was fnv1a64:<old>)
WARNING: all consistency tokens minted under the previous schema hash are now invalid.
```

Concurrency notes to honor in code: the handler runs in its own thread (GHC's signal
handling); serialize reloads with an `MVar ()` guard so overlapping SIGHUPs queue;
the validation pass uses its own database session via the same connection machinery
`runAppIO` uses (be mindful the server currently has a single shared connection —
review A2 — so the pass briefly contends with request traffic; if
`docs/plans/34-pool-database-connections-in-en-server.md` has landed, take a pooled
connection instead, and record which).

In-flight consistency: nothing else is needed — M1's snapshot discipline already
guarantees a request begun before the swap completes wholly on the old
graph-and-hash, and a request begun after sees wholly the new one.

Update `docs/user/service-and-operations.md` with the reload workflow (`kill -HUP`,
the force variable, the refusal behavior, the token warning), extending the section
M2 added.

Acceptance: the live transcript in Validation and Acceptance.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/en` in the dev shell.

Build and database-free tests:

```bash
cabal build all
cabal test en-core
cabal test en-servant
```

Storage-level tests (ephemeral PostgreSQL):

```bash
cabal test en-postgres-integration-tests
```

Dev database and server for the live scenarios:

```bash
just process-up
cat > /tmp/blog.en <<'EOF'
object user {}

object post {
  relation author: user
  relation reader: user, user:*
  permission view = author | reader
  permission edit = author
}
EOF
EN_SCHEMA_PATH=/tmp/blog.en just start-server
```

Expected startup log includes `Loaded schema from /tmp/blog.en` and
`Schema hash: fnv1a64:…` (plan 26's lines, unchanged).

Offline validation of a candidate schema (after M2; server not required, database
required):

```bash
cabal run en-server -- check-schema /tmp/blog-v2.en
```

Expected: the orphan report or `0 orphan(s)…`, with exit code 1 or 0 respectively
(check with `echo $?`).

Stop services when done:

```bash
just process-down
```


## Validation and Acceptance

Scenario 1 — read the live schema (after M1):

```bash
curl -sS localhost:8080/schema
```

```json
{
  "source": "object user {}\n\nobject post {\n  relation author: user\n  …",
  "hash": "fnv1a64:…",
  "origin": "/tmp/blog.en",
  "loadedAt": "2026-07-07T…Z"
}
```

The `hash` must equal the startup log's `Schema hash:` line.

Scenario 2 — compatible reload (after M3). Write a tuple and capture its token, then
append a new relation to `/tmp/blog.en` (compatible: additive):

```bash
TOKEN=$(curl -sS -X POST localhost:8080/tuples -H 'content-type: application/json' -d '{
  "tuples": [{"object": {"objectType": "post", "objectId": "1"}, "relation": "author",
              "subject": {"tag": "SubjectIdWire", "contents": {"objectType": "user", "objectId": "alice"}},
              "caveat": null}]}' | jq -r '.token')
printf '\nobject tag {}\n' >> /tmp/blog.en
kill -HUP "$(pgrep -f en-server | head -1)"
```

Expected server log:

```text
Schema reloaded from /tmp/blog.en
Schema hash: fnv1a64:<new> (was fnv1a64:<old>)
WARNING: all consistency tokens minted under the previous schema hash are now invalid.
```

`curl -sS localhost:8080/schema` now shows the new source and new hash — without a
restart. And the old token is dead, as documented: a check with
`{"tag": "AtLeastAsFreshWire", "contents": "$TOKEN"}` fails with the
schema-hash-mismatch token error (an HTTP 500 with that message under today's
collapsed error model — review A3 — or the typed error once `docs/plans/35` lands),
while the same check with `{"tag": "FullyConsistentWire"}` returns
`{"decision": {"tag": "AllowedWire"}, …}`.

Scenario 3 — orphaning reload refused. Edit `/tmp/blog.en` removing
`relation author…` (which the tuple from scenario 2 uses), `kill -HUP` again.
Expected server log:

```text
Schema reload refused: 1 orphan(s) found against candidate fnv1a64:…
ORPHAN post:1#author@user:alice — relation post#author not in candidate schema
reload refused; set EN_SCHEMA_RELOAD_FORCE=1 to activate anyway
```

`GET /schema` still shows scenario 2's schema (old model keeps serving); checks
still work. Restarting the server with `EN_SCHEMA_RELOAD_FORCE=1` in the environment
and repeating the SIGHUP activates the destructive schema (forced path).

Scenario 4 — `check-schema` offline (after M2): as shown in Concrete Steps, the
subcommand prints the same orphan line for the scenario-3 candidate and exits 1;
against the scenario-2 schema it prints `0 orphan(s)` and exits 0.

Test-level validation: the M2 unit tests cover every `OrphanReason`; the integration
suite covers the pass end to end; the servant suite covers `GET /schema` and the
snapshot-passing `Env` rework (all pre-existing handler tests still green is itself
the regression gate for M1).


## Idempotence and Recovery

`GET /schema` and `check-schema` are read-only and freely repeatable. SIGHUP reload
is idempotent for an unchanged file (same hash in, same hash out — implementers may
skip the swap when hashes match and log "schema unchanged", which also skips the
token-invalidation warning; record the choice). Every reload failure mode —
unreadable file, parse error, validation error, orphan refusal — leaves the previous
`ActiveSchema` serving untouched, so the worst outcome of a bad reload is a log
message; recovery is "fix the file, signal again". The one deliberately sharp edge is
forced activation: it strands the reported grants (they become unevaluatable under
the new model, though the rows remain until deleted or reaped) and, like every
reload, invalidates all outstanding tokens; both facts are in the log and in
`docs/user/service-and-operations.md`. If a forced reload was a mistake, reload the
previous schema text again — the tuples were never modified, only the model
interpreting them.


## Interfaces and Dependencies

End-state interfaces, by full module path:

- `En.Servant.Seam` (`en-servant/src/En/Servant/Seam.hs`): `ActiveSchema { graph,
  hash, source, origin, loadedAt }`; `Env` gains
  `readActiveSchema :: IO ActiveSchema` and `runPorts :: forall a. ActiveSchema ->
  Eff es a -> IO (Either EnError a)`; `runEngine` takes the snapshot.
- `En.Servant.API` (`en-servant/src/En/Servant/API.hs`): route `GET /schema`;
  `SchemaInfoWire { source, hash, origin, loadedAt }`; all handlers snapshot-read.
- `En.Effect.TupleStore` (`en-core/src/En/Effect/TupleStore.hs`): constructor
  `EnumerateTuples :: Revision -> Int -> Maybe StoreCursor -> TupleStore m TuplePage`
  with smart constructor `enumerateTuples`; implemented in
  `en-postgres/src/En/Postgres/TupleStore.hs` and
  `en-core/src/En/Conformance/Kikan.hs`.
- `En.SchemaCheck` (`en-core/src/En/SchemaCheck.hs`, new; in
  `en-core/en-core.cabal` exposed-modules): `TupleOrphan`, `OrphanReason`,
  `checkTupleAgainstSchema :: ValidSchema -> Tuple -> Maybe TupleOrphan`,
  `validateTuplesAgainstSchema :: (TupleStore :> es) => ValidSchema -> Revision ->
  Eff es [TupleOrphan]`.
- `en-server/app/Main.hs`: the `IORef ActiveSchema`, the SIGHUP handler
  (`System.Posix.Signals` from the `unix` package — new build-depends entry in
  `en-server/en-server.cabal`), `EN_SCHEMA_RELOAD_FORCE`, and the `check-schema`
  subcommand with exit codes 0/1/2.
- `En.Client` (`en-client/src/En/Client.hs`): `EnClient` gains `readSchema`.
- `docs/user/service-and-operations.md`: the compatible-change taxonomy and reload
  workflow sections.

Dependencies and coordination, restated so this plan stands alone: this plan extends
`docs/plans/26-load-developer-schemas-into-the-production-server-at-runtime.md`
(startup loading, text DSL, fail-closed conventions — all reused, none changed). It
soft-depends on `docs/plans/50-expose-relationship-read-and-delete-by-filter-endpoints.md`
only in the weakened sense recorded in the Decision Log (a dedicated unanchored
enumeration replaces the filter for orphan detection). Per
`docs/masterplans/9-complete-the-en-api-surface.md`, this plan owns the schema
handle: endpoints from `docs/plans/50/51/52/53` implemented earlier are rewired to
`ActiveSchema` during M1, and any implemented later use it from the start. The
authenticated reload endpoint waits for
`docs/plans/33-add-caller-authentication-and-rate-limiting-to-en-server.md`; the
connection-sharing note in M3 references
`docs/plans/34-pool-database-connections-in-en-server.md`. Prefer landing after
`docs/plans/35-version-the-wire-contract-and-type-the-error-model.md` (versioned
contract). New package dependency: `unix` (en-server only).
