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
- [x] M3 (2026-07-10): Implement SIGHUP reload: re-read `EN_SCHEMA_PATH`, parse/validate/compile, run the stored-tuple pass, atomically swap the `IORef`, log old/new hash and the token-invalidation warning; `EN_SCHEMA_RELOAD_FORCE=true` override (not `=1`, see Decision Log); every failure leaves the old schema serving. Unchanged file skips the swap and the warning.
- [x] M3 (2026-07-10): Live acceptance: full reload transcript in Validation and Acceptance — unchanged file, compatible edit, orphaning edit refused, unparseable file, forced activation.
- [x] M3 (2026-07-10): Reload workflow written into `docs/user/service-and-operations.md`, extending the taxonomy section M2 added.
- [ ] Deferred (recorded, not in this plan): authenticated `POST /admin/schema/reload` once `docs/plans/33-add-caller-authentication-and-rate-limiting-to-en-server.md` lands. **Note: EP-33 has since landed** (`en-server` has API keys, `EN_AUTH_DISABLED`, and role-scoped middleware), so the blocker named here is discharged; the endpoint remains unbuilt and unscoped, and `SIGHUP` remains the only reload trigger.


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

- 2026-07-10 (M3; the reload's own log line is a place to lie, and the plan nearly did): the
  swap logs "all consistency tokens minted under the previous schema hash are now invalid". A
  `SIGHUP` on a file that has not changed produces a candidate whose hash equals the active
  one, so swapping would print that sentence about tokens that are, in fact, still valid.
  Supervisors send `SIGHUP` for reasons that have nothing to do with the schema. The
  hash-equality skip the plan's Idempotence section offered as optional is therefore not an
  optimization; it is what keeps the log honest. Recorded in the Decision Log.

- 2026-07-10 (M3; the acceptance run cannot use the dev database, and this will bite the next
  plan too): the dev store holds 200,024 live grants from earlier plans' benchmarks, nearly all
  of them `space:*`. Any candidate schema that does not model `space` — including the `blog.en`
  this plan's own Concrete Steps prescribe — is refused with 200,023 orphan lines. The reload
  scenarios were run against a fresh `en_ep54` database with the migrations applied. The
  pollution is not a defect; it is what a validation pass is *for*, and running `check-schema`
  against it produced this plan's only performance datapoint: a full unanchored scan of
  200,024 live rows takes 1.8 seconds. It also found a grant the author's own `GROUP BY` had
  hidden — `space:public#member@user:*`, a wildcard — which is the orphan class (`OrphanDisallowedSubject`)
  that is hardest to predict by reading a schema.

- 2026-07-10 (M3; `cabal run` and `timeout` do not compose): `timeout 30 cabal run -v0 en-server`
  spent ~25 seconds rebuilding and was killed seconds after the port bound, so every `curl` in
  the same script failed to connect against a server whose log showed a clean startup. Use
  `cabal list-bin en-server` and run the binary. This compounds the master plan's existing
  warning about port 8080 (held here by an `ssh` tunnel, not an `en-server`): between the two,
  an acceptance run can talk to the wrong process, or to no process, and read plausibly either way.

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
- Decision: the force override is `EN_SCHEMA_RELOAD_FORCE=true`, parsed in `en-server/app/Config.hs`, not `EN_SCHEMA_RELOAD_FORCE=1` read ad hoc at reload time.
  Rationale: Every other boolean this server reads is `true`/`false` through `Config.boolean` (`EN_AUTH_DISABLED` is the precedent), every variable is listed in `knownVariables`, and the "Configuration is validated at startup" contract says an invalid value fails startup rather than being silently ignored. A variable read with `lookupEnv` inside a signal handler would honour none of that: `EN_SCHEMA_RELOAD_FORCE=yes` would silently mean "do not force", discovered only when a reload the operator expected to succeed was refused. The value cannot change in a running process either way, so parsing it at startup loses nothing and buys validation.
  Date: 2026-07-10
- Decision: a `SIGHUP` whose candidate hashes equal to the active schema skips the swap, and says so.
  Rationale: The plan's Idempotence section offered this as an implementer's choice and asked that it be recorded. Taken, for one reason beyond cost: the swap's log line ends with "all consistency tokens minted under the previous schema hash are now invalid", and that sentence would be a lie. An operator who signals a process twice, or whose supervisor sends `SIGHUP` on a config reload that did not touch the schema, must not be told their clients' tokens just died. Skipping the swap also skips a needless full-table scan.
  Date: 2026-07-10
- Decision: the reload's validation pass runs through `runAppNow` — the *active* schema's interpreter stack — rather than one built from the candidate.
  Rationale: The pass calls `headRevision` and drains `readAllTuples`. It mints no consistency token and presents none, so the schema hash embedded in the store interpreters never enters into it. Building a candidate stack to run it would imply the hash mattered, and would invite a later reader to wonder what happens to a token minted under a schema that was never activated. Nothing does, because none is.
  Date: 2026-07-10
- Decision: `loadCandidateSchema` returns a `LoadedSchema` (source, origin, validated model) rather than a bare `ValidSchema`, and is shared by `check-schema` and the reload handler.
  Rationale: The reload must put the candidate's *source text* into the new `ActiveSchema`, or `GET /v1/schema` would keep serving the text of the model that was replaced — the exact defect the endpoint exists to prevent, arriving through the exact feature that makes it possible. Sharing one loader means the schema `check-schema` vets and the schema `SIGHUP` activates cannot be read, parsed, or validated differently.
  Date: 2026-07-10
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

**Complete, 2026-07-10.** Every promise in Purpose is met and demonstrated live: `GET /v1/schema`
returns the source text, hash, origin, and load time; `SIGHUP` reloads with an atomic swap that
in-flight requests cannot straddle; the swap is gated by a stored-tuple scan that names exactly
which grants would be orphaned and why; the same scan is available offline as
`en-server check-schema <path>` with distinct exit codes for "strands grants" and "bad file"; and
the compatible-change taxonomy is in `docs/user/service-and-operations.md`, cross-checked against
the six `OrphanReason` constructors rather than written from the plan's prose.

Three things came in smaller than planned, all for the same reason — the tree had already grown
what this plan proposed to add:

- The `EnumerateTuples` store operation was **not written**. `ReadAllTuples` already had its exact
  signature, its row-id ordering, and both interpreters, added for `en-server export`.
- `ActiveSchema` carries **no `hash` field**. `ReachabilityGraph.hash` is the hash, and it is what
  `En.Check` already keys the decision cache on — which is *why* the plan's claim that the decision
  cache self-invalidates on reload is true.
- M3's worry about "a single shared connection" was stale: `docs/plans/34` landed, so the reload's
  scan takes a pooled connection like any request.

The design that mattered most was M1's, and it is worth restating because it is the whole safety
argument: `runPorts` takes an `ActiveSchema` rather than reading one. A handler that chose its graph
and let its interpreters choose their hash independently could, on a reload landing between the two,
evaluate the old model and mint a token under the new one. Making the snapshot an *argument* means
there is nothing to synchronize — the tearing state cannot be spelled. The live evidence is Scenario
3: a `fullyConsistent` check after a reload mints its `checkedAt` under the new hash, which only
happens because the interpreter stack was rebuilt from the request's snapshot.

Two gaps, both recorded rather than closed:

- **The authenticated `POST /admin/schema/reload` is still unbuilt.** Its stated blocker
  (`docs/plans/33`) has since landed, so the reason it was deferred no longer holds. `SIGHUP`
  remains the only trigger, which is defensible — process-level access is the right bar — but the
  decision should now be made on its merits rather than inherited.
- **`demoSchema` was a latent lie.** It was built with `En.Schema.Builder` while `GET /v1/schema`
  promised to return its source text. It happened to be correct, and is now derived from the text by
  the parser so it cannot stop being. Adding a read endpoint turned a harmless duplication into a
  correctness obligation; that is worth remembering the next time a value is described in two places.

One thing the plan asked for and did not get: the compatible-change taxonomy claims that editing a
permission's rewrite "strands nothing", and the validator agrees by saying nothing at all. That is
correct and also the most dangerous edit an operator can make, because every decision involving the
permission can change and no tooling here will warn them. The documentation says so in as many words.
Detecting *behavioral* schema drift — diffing decisions across two models over the stored graph — is a
real capability this plan does not provide and did not scope.


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

All scenarios below were run on 2026-07-10 against a **clean** database
(`createdb en_ep54`, then every file in `en-migrations/db/migrations/*.sql`). The dev
database is not usable for these: earlier plans left 200,024 live `space:*` grants in it, so
any candidate schema that does not model `space` refuses with 200,023 orphan lines. Not port
8080 either — it was held by an unrelated `ssh` tunnel. Check with
`lsof -nP -iTCP:8080 -sTCP:LISTEN`, and run the built binary (`cabal list-bin en-server`)
rather than `cabal run`, whose rebuild eats a `timeout`.

Test-level validation: `cabal test all` is green — `en-core` (the checker's unit tests, every
`OrphanReason` plus both directions of the caveat-payload rule), `en-postgres-integration-tests`
(the pass end to end, over a fixture larger than one drain page, with a retired grant owed no
orphan), and `en-servant` (`GET /v1/schema`, its OpenAPI shape, and every pre-existing handler
test as the regression gate for M1's `Env` rework).

### Scenario 1 — read the live schema (M1)

```bash
curl -sS localhost:8094/v1/schema
```

```json
{
  "source": "object user {}\n\nobject post {\n  relation author: user\n  relation reader: user, user:*\n  permission view = author | reader\n  permission edit = author\n}\n",
  "hash": "fnv1a64:1061a4beb2d5506c",
  "origin": "/tmp/reload.en",
  "loadedAt": "2026-07-10T14:45:36.14586Z"
}
```

The `hash` equals the startup log's `Schema hash:` line. Serving the built-in demo model
instead reports `"origin": "builtin-demo"` and `fnv1a64:88633b46c783909e`.

### Scenario 2 — an unchanged file is not a reload (M3)

```text
Schema reload: SIGHUP re-reads /tmp/reload.en; orphaning schemas are refused
...
Schema unchanged (fnv1a64:1061a4beb2d5506c); not reloading.
```

No swap, no scan, and — the point — no token-invalidation warning.

### Scenario 3 — compatible reload (M3)

Write a tuple and keep its token, append `object tag {}` to the schema file, then `SIGHUP`:

```text
Schema reloaded from /tmp/reload.en
Schema hash: fnv1a64:723e92640d5dbd67 (was fnv1a64:1061a4beb2d5506c)
WARNING: all consistency tokens minted under the previous schema hash are now invalid.
```

`GET /v1/schema` reports the new hash and a fresh `loadedAt` — without a restart. The warning
is not decoration: the token minted moments earlier is now refused, and a `fullyConsistent`
check answers normally and mints its `checkedAt` under the *new* hash, which is what proves
the interpreter stack was rebuilt from the request's snapshot rather than from startup state.

```text
$ curl … -d '{"consistency":{"mode":"atLeastAsFresh","token":"en1.…fnv1a64%3a1061a4beb2d5506c.27827%3a27828%3a."}, …}'
{"code":"invalid_consistency_token","message":"token schema hash does not match the active schema","retryable":false}

$ curl … -d '{"consistency":{"mode":"fullyConsistent"}, …}'
{"decision":{"result":"allowed"},"checkedAt":"en1.…fnv1a64%3a723e92640d5dbd67.27828%3a27828%3a."}
```

### Scenario 4 — an orphaning reload is refused (M3)

Remove `relation author` (and the two permissions naming it, or the schema fails validation
rather than stranding anything), then `SIGHUP`:

```text
Schema reload refused: 1 orphan(s) across 1 live tuple(s) under candidate fnv1a64:673195894cece659
ORPHAN post:1#author@user:alice — relation post#author not in candidate schema
reload refused; set EN_SCHEMA_RELOAD_FORCE=true to activate anyway.
```

`GET /v1/schema` still reports `fnv1a64:723e92640d5dbd67`, and the check still returns
`allowed`. The old model kept serving.

### Scenario 5 — a bad file leaves the old schema serving (M3)

```text
en-server: schema reload failed: could not parse /tmp/reload.en: SchemaViolation "object post is missing closing }"
the previous schema is still serving.
```

`GET /v1/schema` is unchanged. This is the one place the reload path deliberately diverges
from plan 26's fail-closed startup: a running authorization server must survive a bad reload
rather than exit.

### Scenario 6 — forced activation, and its sharp edge (M3)

Restart with `EN_SCHEMA_RELOAD_FORCE=true` (the startup line says so:
`… EN_SCHEMA_RELOAD_FORCE=true, orphaning schemas will be ACTIVATED`) and repeat scenario 4:

```text
Schema reload FORCED over 1 orphan(s) across 1 live tuple(s) under candidate fnv1a64:673195894cece659
ORPHAN post:1#author@user:alice — relation post#author not in candidate schema
Schema reloaded from /tmp/reload.en
Schema hash: fnv1a64:673195894cece659 (was fnv1a64:723e92640d5dbd67)
WARNING: all consistency tokens minted under the previous schema hash are now invalid.
```

The destructive model is now active. `alice`'s `view` on `post:1` flips from `allowed` to
`denied` — and the row is still in the table:

```text
$ psql "$EN_DATABASE_URL" -tAc "select object_type||':'||object_id||'#'||relation from relation_tuple where deleted_xid is null;"
post:1#author
```

Reloading the previous schema text brings the grant back. The model changed; the data never did.

### Scenario 7 — `check-schema` offline (M2)

Against the dev database's 200,024 live grants, a full unanchored scan takes **1.8 seconds**:

```text
$ en-server check-schema /tmp/full.en
0 orphan(s) across 200024 live tuple(s); candidate schema fnv1a64:89c2665aa2315f44 fits them all.
$ echo $?
0

$ en-server check-schema /tmp/blog.en | tail -1
200023 orphan(s) across 200024 live tuple(s); candidate schema fnv1a64:1061a4beb2d5506c would strand them.
$ echo $?
1

$ en-server check-schema /tmp/nope.en
en-server: could not read /tmp/nope.en: /tmp/nope.en: openFile: does not exist (No such file or directory)
$ echo $?
2
```

A candidate that parses but fails `validateSchema` also exits 2
(`invalid schema in …: UnknownRelation "unknown allowed subject object type: ghost"`), and
none of the three exit-2 paths touches the database.

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
