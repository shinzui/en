---
id: 25
slug: adopt-effectful-for-the-en-effect-stack
title: "Adopt effectful for the en effect stack"
kind: exec-plan
created_at: 2026-06-23T22:14:36Z
intention: "intention_01kvv8qebteknry0963yjpwasn"
---

# Adopt effectful for the en effect stack

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today the en authorization engine reaches its storage through two hand-rolled "record of
functions" values: `TupleStore m` and `ConsistencyStore m`, defined in
`en-core/src/En/Effect/TupleStore.hs` and `en-core/src/En/Effect/ConsistencyStore.hs`.
A record of functions is literally a Haskell record whose fields are functions; for example
`TupleStore m` has a field `readObjectRelation :: Revision -> ObjectRef -> RelationName ->
Int -> Maybe StoreCursor -> m TuplePage`. The engine takes one of these records as an
explicit argument and calls its fields. This works, but it is *not* how the author's other
Haskell services are built. Those services (notably the sibling project `shomei`, whose
package layout — `*-core`, `*-postgres`, `*-servant`, `*-server`, `*-client` — mirrors en's
exactly) use the `effectful` library. en's own source even says so: the header of
`En/Effect/TupleStore.hs` reads *"Integration with a concrete effect system follows shomei's
`Shomei.Effect.*` convention; refined as the engine lands."* This plan performs that refinement.

After this change, an en effect (the tuple store, the consistency store) is an `effectful`
*effect*: a small datatype the engine *requests* operations from, with concrete behavior
supplied by a separate *interpreter*. The engine functions `check`, `lookup`, and `expand`
will be written in `effectful`'s monad `Eff` with effect constraints
(`(TupleStore :> es, ConsistencyStore :> es, Error EnError :> es) => ... -> Eff es a`), exactly
like every workflow in `shomei-core`. A novice will be able to: build en-core against
`effectful`; run the en-core test suite against a pure in-memory interpreter; run en-postgres
against a real PostgreSQL interpreter; and start `en-server` and issue a `check` over HTTP that
returns the same answers as before. The user-visible behavior of the service is unchanged — the
win is that en now composes with the author's standard `effectful` stack (shared interpreters,
local interpreters for tests, `Error`-based failure, bracketed transactions), so future effects
(metrics, tracing, caching) drop in the same way they do in `shomei`.

Concretely, "introduce effectful" here means **Option B** from the audit that preceded this
plan: reformulate the two store interfaces as real `effectful` effects rather than merely
instantiating the existing records at `m = Eff es`. We deliberately reject the smaller "Option A"
(keep the records, set `m = Eff es`) because the stated goal is to *match* the rest of the stack,
and the records are explicitly a placeholder.

This plan was authored just before MasterPlan 3
(`docs/masterplans/3-harden-en-correctness-fixes-lookup-streaming-and-performance-benchmarks.md`)
completed, and was reconciled against the finished tree on 2026-06-23 (see the Revision Notes).
The migration's surface is therefore larger than "two effects and three engine functions": the
engine now also exposes **`checkMany`** (the EP-19 batch operation, `En.Check.checkMany` /
`BatchPair`); en-core ships an exposed in-memory store module **`En.Conformance.Kikan`** (the
EP-18 conformance fixture, providing `inMemoryTupleStore` / `consistencyStore` as
record-of-functions in `IO`) that several packages import; there is a seventh package
**`en-example`** (the EP-18 guarded-route / GraphQL-resolver host) that builds the store records
and calls the engine directly; en-servant has a **`/batch-check`** handler; and there are
`tasty-bench` benchmark and conformance test targets that exercise the engine. All of these are in
scope and are accounted for below. (`en-client` remains out of scope: it is a pure `servant`
HTTP client — its `batchCheck` is just another `ClientM` endpoint and it never references the
stores.)


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] **M1 — en-core effects + engine + in-memory interpreter.** Add `effectful`/`effectful-core` deps; reformulate `TupleStore`/`ConsistencyStore` as `effectful` effects; migrate `Check` (incl. `checkMany`), `Lookup`, and `Expand` to `Eff es` with `Error EnError`; reformulate `En.Conformance.Kikan`'s `inMemoryTupleStore`/`consistencyStore` into in-memory *interpreters*; port the three en-core engine-consuming targets (`en-core-interface-tests`, `en-core-conformance`, `en-core-bench`); `cabal test en-core` and the `en-core-bench` gate green.
- [ ] **M2 — en-postgres interpreters.** Add a `Database` effect (hasql); replace the record constructors with `runTupleStorePostgres` / `runConsistencyStorePostgres`; `cabal test en-postgres` green. (`en-postgres-bench` is pure snapshot-codec benchmarking — confirm it still builds; no engine/store changes needed there.)
- [ ] **M3 — en-servant seam + en-example host.** Replace IO-store record fields with an `Eff`→`Handler` seam (`AppEffects`, `Env`, `runEngine`); migrate all handlers including the `/batch-check` (`checkMany`) handler; migrate the `en-example` package (`AuthorizationEnv`, `failingConsistencyStore`, the resolver-style `check` gate) and its test; `cabal build en-servant en-example` and `cabal test en-servant en-example` green.
- [ ] **M4 — en-server assembly.** Compose `runAppIO` in `en-server/app/Main.hs`; server boots; end-to-end `check` over HTTP returns the expected decision.
- [ ] **M5 — whole-repo build/test + en-client check + cleanup.** `cabal build all` and `cabal test all` green (including `en-core-conformance`, `en-servant-tests`, `en-example-tests`, both benchmark gates); confirm `en-client` builds unchanged; remove dead code.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Take Option B (reformulate the two stores as `effectful` effects), not Option A
  (instantiate the existing records at `m = Eff es`).
  Rationale: The explicit goal is consistency with the author's other services (`shomei`,
  `kafka-effectful`), which use `effectful` effects with `send`/`interpret`. en-core's own
  comment names this as the intended end state, marking the records as a placeholder.
  Date: 2026-06-23

- Decision: Failures flow through `effectful`'s `Error EnError` effect rather than the current
  `m (Either EnError a)` return convention. The engine entry points (`check`, `checkMany`,
  `lookup`, `expand`) return `Eff es a` and may `throwError` an `EnError`; the boundary (the
  en-servant seam and the test harness) runs `runErrorNoCallStack @EnError` and maps a `Left` to
  its existing response.
  Rationale: This is exactly shomei's convention (`Error AuthError`, `runErrorNoCallStack` in
  `runAppIO`). It removes the manual `Either` plumbing inside the engine. The existing
  `Either EnError`-returning *pure* helpers (caveat evaluation, schema lookups, `ensureExhausted`)
  are kept as-is and bridged at their call sites with `either throwError pure`, which keeps the
  diff mechanical.
  Date: 2026-06-23

- Decision: en-postgres gets its own `Database` effect (`En.Postgres.Database`) modeled directly
  on `shomei-postgres`'s `Shomei.Postgres.Database` (a dynamic effect wrapping a hasql runner),
  but interpreted against a single hasql `Connection` (`runDatabaseConnection`) rather than a
  `Pool`, because `en-server/app/Main.hs` currently acquires one `Connection`. A pool can be
  added later without touching the effect's interface.
  Rationale: Reuses the proven shomei pattern; matches en's current connection management;
  isolates "how SQL runs" behind one effect that the two store interpreters share.
  Date: 2026-06-23

- Decision: The consistency-store interpreter calls `liftIO getCurrentTime` directly and obtains
  revisions by calling the `TupleStore` effect's operations, rather than introducing a separate
  `Clock` effect or threading `IO` actions as parameters (the current
  `postgresConsistencyStore` takes `IO UTCTime`, `IO Revision`, … arguments).
  Rationale: Mirrors what the current code already does (it passes `getCurrentTime` and the tuple
  store's revision actions), keeps the milestone small, and avoids a speculative `Clock` effect.
  A `Clock` effect can be introduced later to match shomei's `Shomei.Effect.Clock` if test
  determinism over time becomes necessary.
  Date: 2026-06-23

- Decision: No dependency-spike milestone for `effectful`. The `effectful`/`effectful-core`
  dependency is known-good on GHC 9.12.4 — it is already in use across 10+ of the author's
  projects on this exact toolchain (e.g. `shomei`, `kafka-effectful`). The Cabal `build-depends`
  additions are folded into the milestone that first needs them (M1 for en-core, M2 for
  en-postgres, M3 for en-servant, M4 for en-server).
  Rationale: De-risking a dependency that the rest of the fleet already builds against is wasted
  ceremony. Removing the spike makes M1 the first milestone.
  Date: 2026-06-23

- Decision: This is a single ExecPlan with milestones, not a MasterPlan.
  Rationale: The work is one coherent, tightly sequential migration (each layer only compiles
  once the layer below it is migrated); it is not several independently shippable initiatives.
  Date: 2026-06-23

- Decision: The in-memory interpreter is a *reformulation of the existing
  `En.Conformance.Kikan` store records*, not a brand-new `En.Effect.InMemory` module. MasterPlan
  3 (EP-18) already shipped `En.Conformance.Kikan` as an exposed en-core module exporting
  `inMemoryTupleStore :: [Tuple] -> TupleStore IO` and `consistencyStore :: ConsistencyStore IO`,
  imported by `en-core/test/Main.hs`, `en-servant/test/Main.hs`, and `en-example`. The migration
  turns these into interpreters (`runTupleStoreInMemory` / `runConsistencyStoreInMemory`) in the
  same module, so every existing importer is updated in one place rather than competing with a new
  module.
  Rationale: Least churn, and it keeps the cross-package in-memory store in its existing home.
  Date: 2026-06-23

- Decision: Reconcile this plan against the completed MasterPlan 3 tree (EP-14 through EP-19) on
  2026-06-23. The reconciliation adds to scope: `En.Check.checkMany`/`BatchPair` (a third engine
  entry point), the `En.Conformance.Kikan` interpreters (above), the seventh package `en-example`
  (which imports `AuthorizationEnv`/`requirePermission` and calls `check` directly, with its own
  `failingConsistencyStore` fault-injection record), the en-servant `/batch-check` handler, and the
  `en-core-conformance` / `en-core-bench` / `en-servant-tests` / `en-example-tests` targets that
  consume the engine. It also confirms two things stay out of scope: `en-client` (pure HTTP client)
  and `en-postgres-bench` (pure snapshot-codec benchmarking — touches no store or engine).
  Rationale: This plan was authored minutes before MasterPlan 3 finished; an accurate plan must
  reflect the engine surface and package set that now exist.
  Date: 2026-06-23


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

en is a relationship-based authorization (ReBAC) toolkit — a library and a standalone service
that answers questions like "may user U *view* object O?" by walking relationship tuples. It is
split into **seven** Cabal packages, all listed in the repository-root `cabal.project` (the
`cabal.project` also lists two local non-en packages used as build inputs: `ephemeral-pg`, a
throwaway-PostgreSQL fixture for integration tests, and `tasty-bench`, the benchmark library):

- `en-core` — the transport- and database-agnostic engine. Defines the model, the
  schema→reachability compiler, the `check`/`checkMany`/`lookup`/`expand` algorithms, and (since
  MasterPlan 3 EP-18) the exposed conformance fixture `En.Conformance.Kikan` which ships an
  in-memory store. Depends on no database or web library. Source under `en-core/src/`.
- `en-migrations` — PostgreSQL schema migrations. **Not touched by this plan.**
- `en-postgres` — PostgreSQL implementations of the storage interfaces, built on `hasql`
  (a PostgreSQL client library). Source under `en-postgres/src/`.
- `en-servant` — the HTTP API, built with `servant` (a library for describing web APIs as types)
  and `servant-server`. Includes the `/batch-check` endpoint (MasterPlan 3 EP-19). Source under
  `en-servant/src/`.
- `en-server` — the standalone executable that wires everything together. Source is the single
  file `en-server/app/Main.hs`.
- `en-client` — a Haskell client for the HTTP service. **Unaffected by this migration** (it is a
  pure `servant` `ClientM` client and never references the stores); M5 only verifies it still
  builds.
- `en-example` — **(new in MasterPlan 3 EP-18)** a host package demonstrating the fail-closed
  `requirePermission` guard and a GraphQL-resolver-style object gate. Source under
  `en-example/src/` (`En.Example.Host`), with `en-example/app/Main.hs` and a test. **Affected**:
  it imports `En.Servant.Authorize (AuthorizationEnv, requirePermission)`, builds
  `ConsistencyStore IO` / `TupleStore IO` values (including its own `failingConsistencyStore`),
  and calls `check` directly, so it migrates with the seam in M3.

The toolchain is GHC 9.12.4 (pinned in `cabal.project`) with the `GHC2024` language edition and
a shared set of default extensions declared in each `.cabal` file's `common shared` stanza
(`BlockArguments`, `DerivingStrategies`, `LambdaCase`, `OverloadedRecordDot`, etc.). Build and
test with the `cabal` command from the repository root, `/Users/shinzui/Keikaku/bokuno/en`.

### Terms of art (defined in plain language)

- **`effectful`** — a Haskell effect-system library. It provides a monad `Eff es`, where `es` is
  a type-level list of *effects* currently in scope. Code written in `Eff es` can use any effect
  in `es`. The library is registered locally; `mori registry show effectful/effectful --full`
  prints its on-disk path (`/Users/shinzui/Keikaku/hub/haskell/effectful-project`). Its two Cabal
  packages are `effectful` and `effectful-core`.
- **An *effect*** — a small datatype describing a set of operations. In `effectful`'s *dynamic
  dispatch* style (the style shomei and this plan use), an effect is a GADT (a generalized
  algebraic datatype — a datatype whose constructors each declare their own result type) of kind
  `Effect`, plus `type instance DispatchOf TheEffect = Dynamic`. Each constructor is one
  operation. Example from `shomei-core/src/Shomei/Effect/UserStore.hs`:

  ```haskell
  data UserStore :: Effect where
    CreateUser :: NewUser -> UserStore m User
    FindUserById :: UserId -> UserStore m (Maybe User)
  type instance DispatchOf UserStore = Dynamic
  ```

- **A *smart constructor*** — a thin function that *sends* one operation into the current `Eff`
  stack. `send` is `effectful`'s primitive for "request this operation." Example:

  ```haskell
  createUser :: (UserStore :> es) => NewUser -> Eff es User
  createUser = send . CreateUser
  ```

  The constraint `(UserStore :> es)` reads "the `UserStore` effect is an element of the effect
  list `es`." Callers use the smart constructor; they never see `send`.
- **An *interpreter*** — a function that *handles* an effect by giving each operation concrete
  behavior, removing that effect from the stack. The primitive is `interpret_` (from
  `Effectful.Dispatch.Dynamic`). Its type shape is
  `(... constraints ...) => Eff (TheEffect : es) a -> Eff es a`. Example from
  `shomei-postgres/src/Shomei/Postgres/UserStore.hs`:

  ```haskell
  runUserStorePostgres ::
    (Database :> es, IOE :> es, Error AuthError :> es) =>
    Eff (UserStore : es) a -> Eff es a
  runUserStorePostgres = interpret_ \case
    CreateUser nu -> do ...
    FindUserById uid -> do ...
  ```

- **`IOE`** — the effect that grants the ability to run `IO`. `liftIO` works whenever
  `(IOE :> es)`. `runEff :: Eff '[IOE] a -> IO a` is the base runner that turns a fully
  interpreted program back into `IO`.
- **`Error e`** — `effectful`'s typed-error effect (`Effectful.Error.Static`). `throwError ::
  (Error e :> es) => e -> Eff es a` raises; `runErrorNoCallStack :: Eff (Error e : es) a ->
  Eff es (Either e a)` handles the effect and surfaces the result as `Either e a` (the
  `NoCallStack` variant omits a call-stack wrapper, which is what shomei uses).
- **The *seam*** — shomei's name (`shomei-servant/src/Shomei/Servant/Seam.hs`) for the small
  bridge that runs an `Eff` program down to `IO` inside a `servant` `Handler`. `Handler` is
  servant's handler monad (`ExceptT ServerError IO`). The seam runs the effect stack and maps a
  domain error to a `ServerError`.
- **Interpreter *order is load-bearing.*** Interpreters are applied as a function composition.
  Read **right to left, the composition peels effects head-to-tail off the stack list.** So the
  *rightmost* interpreter handles the *head* of the `AppEffects` list, and the *leftmost*
  (`runEff`) handles the base (`IOE`). An interpreter for effect A that *uses* effect B must run
  while B is still in scope — i.e. A must sit *above* B in the list (A handled to the right of B
  in the composition). shomei documents this in `shomei-server/src/Shomei/Server/App.hs`.

### What exists today (the starting point)

`en-core/src/En/Effect/TupleStore.hs` defines `data TupleStore m = TupleStore { readObjectRelation
:: ...; readStartingWithUser :: ...; writeTuples :: [Tuple] -> m ConsistencyToken; deleteTuples ::
...; headRevision :: m Revision; optimizedRevision :: m Revision; oldestRetainedXid :: m Word64;
reapDeletedTuples :: Word64 -> m Int64 }`, plus the data types `UsersetQuery`, `StoreCursor`,
`TupleRowId`, `TupleRow`, `TuplePage`, `PageState`. These data types stay; only the
record-of-functions becomes an effect.

`en-core/src/En/Effect/ConsistencyStore.hs` defines `data ConsistencyStore m = ConsistencyStore {
decodeToken :: ConsistencyToken -> m (Either EnError TokenMetadata); validateToken :: TokenMetadata
-> m (Either EnError ()); resolveConsistency :: Consistency -> m (Either EnError
ResolvedConsistency) }`, plus `TokenMetadata` and `ResolvedConsistency` (which stay).

`en-core/src/En/Check.hs` exposes `check :: (Monad m) => ConsistencyStore m -> TupleStore m ->
ReachabilityGraph -> Consistency -> CaveatContext -> Subject -> RelationName -> ObjectRef -> m
(Either EnError CheckDecision)`, and internally `runCheck`, `evalRelation`, `evalRewrite`,
`evalThis`, `evalTupleToUserset`, all `(Monad m) =>` and all taking the store records as explicit
arguments. `evalThis`/`evalTupleToUserset` call `tupleStore.readObjectRelation …` and
`tupleStore.readStartingWithUser …`. Pure helpers `applyRewriteCaveat`, `applyTupleCaveat`,
`evaluateNamedCaveat`, and `ensureExhausted` return `Either EnError …`. **It also exposes
`checkMany :: (Monad m) => ConsistencyStore m -> TupleStore m -> ReachabilityGraph -> Consistency
-> CaveatContext -> [BatchPair] -> m (Either EnError [CheckDecision])`** (MasterPlan 3 EP-19), the
batch operation: it resolves consistency once, deduplicates the `[BatchPair]`, evaluates each
distinct pair with a shared within-call subproblem memo (a `foldM` over `dedupePairs pairs`), and
returns one decision per input pair in input order, defaulting to `Denied` (fail-closed). It must
be migrated exactly like `check` — the store arguments drop, the constraints become
`(ConsistencyStore :> es, TupleStore :> es, Error EnError :> es)`, the `resolveConsistency`
`Left`-plumbing collapses, and it returns `Eff es [CheckDecision]`. The `BatchPair` type stays.

`en-core/src/En/Conformance/Kikan.hs` (MasterPlan 3 EP-18) is an **exposed** module — not test
code — that ships the shared in-memory store: `inMemoryTupleStore :: [Tuple] -> TupleStore IO`
(an `IORef`-free pure pager built from a tuple list) and `consistencyStore :: ConsistencyStore IO`,
plus the kikan `Schema`/`ReachabilityGraph` and the agency fixtures (`fixtureTuples`,
`agencyTuples`, contexts, object refs). It is imported by `en-core/test/Main.hs` and
`en-servant/test/Main.hs`. Because these are the record-of-functions being removed, this module's
two store values must be reformulated into `effectful` interpreters (see M1(e)); every importer
then switches from "pass the record" to "run under the interpreter."

`en-core/src/En/Lookup.hs` exposes `lookup`, `lookupWithDeadline`, `runLookup`
(`(Monad m) =>`, store records as arguments), plus a `Deadline m = Deadline { remainingBudget ::
m Bool }` newtype used to bound work; `noDeadline :: (Applicative m) => Deadline m = Deadline
(pure True)`.

`en-core/src/En/Expand.hs` exposes `expand`, `runExpand`, `expandRelation`, `expandRewrite`,
`expandThis`, `expandTupleToUserset`, `nodeFromRow`, `readObjectRows` — same shape.

`en-core/src/En/Error.hs` defines `data EnError = … deriving stock (Eq, Show)`.

`en-postgres/src/En/Postgres/TupleStore.hs` defines `PostgresSessionRunner m = PostgresSessionRunner
{ run :: forall a. Session a -> m a }` (already monad-polymorphic), `postgresTupleStore ::
PostgresSessionRunner m -> ConsistencyConfig -> TupleStore m` (builds the record), the IO
conveniences `hasqlConnectionRunner` / `postgresTupleStoreIO`, `runStoreSession :: Connection ->
Session a -> IO a`, and the pure session builders `writeTuplesSession`, `deleteTuplesSession`,
`readObjectRelationSession`, `readStartingWithUserSession`, `headRevisionSession`,
`oldestRetainedXidSession`, plus encode/decode helpers. The session builders stay; the wiring
changes.

`en-postgres/src/En/Postgres/Revision.hs` defines `postgresConsistencyStore :: ConsistencyConfig ->
IO UTCTime -> IO Revision -> IO Revision -> IO Word64 -> ConsistencyStore IO` (the one genuinely
IO-pinned constructor) plus the pure helpers `tokenMetadataFromPayload`, `validateTokenMetadata`,
`resolveConsistencyRequest`, `ConsistencyConfig`, token encode/decode, and the `pg_snapshot`
machinery (all stay).

`en-servant/src/En/Servant/API.hs` defines `data EnServer = EnServer { consistencyStore ::
ConsistencyStore IO, tupleStore :: TupleStore IO, graph :: ReachabilityGraph }`, the `EnAPI` type,
`server`, `app :: EnServer -> Application`, and the handlers `writeTuplesHandler`,
`deleteTuplesHandler`, `checkHandler`, **`batchHandler`** (the `/batch-check` route, which calls
`checkMany` — MasterPlan 3 EP-19, with `BatchCheckRequestWire`/`BatchCheckResponseWire` and a
`maxBatchSize` guard), `lookupHandler`, `expandHandler`, each running in `Handler` and calling the
engine via `liftIO (check env.consistencyStore env.tupleStore env.graph …) >>= eitherEngine`,
where `eitherEngine :: Either EnError a -> Handler a`.
`en-servant/src/En/Servant/Authorize.hs` defines `AuthorizationEnv` (same two `… IO` fields plus
`graph`) and `requirePermission`, with the same `liftIO (check …) >>= eitherEngine` shape.

`en-example/src/En/Example/Host.hs` (MasterPlan 3 EP-18) defines `mkEnv :: ConsistencyStore IO ->
TupleStore IO -> AuthorizationEnv`, a guarded Servant `app`, `requirePermission`-based handlers
(`viewDocument`/`viewSecret`), resolver-style gates (`resolveDocument`/`resolveSecret`/
`resolveWithGate`) that call `check env.consistencyStore env.tupleStore env.graph …` directly, its
own `inMemoryTupleStore :: [Tuple] -> TupleStore IO`, and a `failingConsistencyStore ::
ConsistencyStore IO` whose `resolveConsistency` always fails (used to prove the engine-error path
maps to a 500). `en-example/app/Main.hs` and `en-example/test/Main.hs` build the env from
`En.Conformance.Kikan`'s store and the local ones. All of this consumes the two store records and
migrates with the seam.

`en-server/app/Main.hs` acquires a single hasql `Connection`, builds `tupleStore =
postgresTupleStoreIO connection config`, then `consistencyStore = postgresConsistencyStore config
getCurrentTime tupleStore.optimizedRevision tupleStore.headRevision tupleStore.oldestRetainedXid`,
assembles `EnServer{…}`, and serves it with Warp.

`en-core/test/Main.hs` imports `En.Conformance.Kikan` and asserts engine outcomes such as
`assertEqual "owner can view a space" (Right Allowed) =<< check consistencyStore tupleStore graph
MinimizeLatency requestContext (SubjectId user) (RelationName "view") space`, where
`consistencyStore`/`tupleStore` are the Kikan in-memory store. `en-core/bench/Main.hs` (the
`en-core-bench` `tasty-bench` target, with a recorded `en-core/bench/baseline.csv`) benchmarks
`check`, `checkMany`, and `Lookup.lookup` against that same store. `en-core/test` also holds the
`en-core-conformance` suite. These call sites all change to run the `Eff` stack against the new
in-memory interpreter. By contrast `en-postgres/bench/Main.hs` (the `en-postgres-bench` target)
benchmarks only the pure snapshot-codec functions (`comparePgSnapshot`, `decodeToken`,
`encodeToken`) — it touches no store and needs no change.

### The reference implementation to mirror (shomei)

`shomei` is the same author's sibling project with the identical five-library layout and is
already on `effectful`. Read these files while implementing — they are the canonical shape:

- Effect definition: `shomei-core/src/Shomei/Effect/UserStore.hs` (GADT + `DispatchOf` + smart
  constructors).
- PostgreSQL interpreter: `shomei-postgres/src/Shomei/Postgres/UserStore.hs` (`interpret_`,
  `Database`/`Error`/`IOE` constraints).
- The shared SQL effect: `shomei-postgres/src/Shomei/Postgres/Database.hs` (`Database` GADT,
  `runSession`, `runDatabasePool`).
- In-memory interpreter for tests: `shomei-core/src/Shomei/Effect/InMemory.hs` (`IORef`-backed
  `World`, one `run…` per effect, a `runInMemory` that stacks them over `IOE`).
- The servant seam: `shomei-servant/src/Shomei/Servant/Seam.hs` (`AppEffects`, `Env { runPorts ::
  forall a. Eff AppEffects a -> IO … }`, `runAuth`/`runPort`).
- The server interpreter assembly: `shomei-server/src/Shomei/Server/App.hs` (`AppEffects`,
  `runAppIO = runEff . runErrorNoCallStack . runDatabasePool … . run…Postgres`, with the
  load-bearing-order comment).


## Plan of Work

The migration proceeds bottom-up through the package graph: `en-core` first (it depends on no one),
then `en-postgres`, then `en-servant`, then `en-server`, with a final whole-repo pass. Each
milestone leaves the repository building and (where a test suite exists) testing green, so work can
stop and resume between milestones. Commit at the end of every milestone (and at any other working
stopping point) with both trailers:

```text
ExecPlan: docs/plans/25-adopt-effectful-for-the-en-effect-stack.md
Intention: intention_01kvv8qebteknry0963yjpwasn
```

### Milestone M1 — en-core effects, engine, and in-memory interpreter

Scope: the heart of the migration. At the end, `en-core` exposes the two stores as `effectful`
effects, the engine is written in `Eff es` with `Error EnError`, a pure in-memory interpreter
exists, and `cabal test en-core` passes against it. This is one milestone (not three) because the
engine will not compile against the new effects until both the effects and the engine are migrated,
and the test suite is the proof, so the in-memory interpreter must land with them.

**(0) Add the dependency.** Add `effectful` and `effectful-core` to the `library`
`build-depends` of `en-core/en-core.cabal` (and to the test stanza's `build-depends`). These are
Mori-registered and already in use across the author's GHC 9.12.4 projects, so no spike is needed;
if `cabal` cannot resolve them, add a `packages:` entry to `cabal.project` pointing at the on-disk
location from `mori registry show effectful/effectful --full`
(`/Users/shinzui/Keikaku/hub/haskell/effectful-project`, containing `effectful/` and
`effectful-core/`), appended as a **new block** at the end of `cabal.project` per its banner comment.

**(a) Reformulate `En.Effect.TupleStore`.** Keep the data types (`UsersetQuery`, `StoreCursor`,
`TupleRowId`, `TupleRow`, `TuplePage`, `PageState`). Replace the `data TupleStore m = …` record
with a dynamic effect. Add the file-level pragmas `{-# LANGUAGE DataKinds #-}`,
`{-# LANGUAGE GADTs #-}`, `{-# LANGUAGE TypeFamilies #-}` (matching shomei's effect modules) and
import `Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))` and
`Effectful.Dispatch.Dynamic (send)`. Define:

```haskell
data TupleStore :: Effect where
  ReadObjectRelation :: Revision -> ObjectRef -> RelationName -> Int -> Maybe StoreCursor -> TupleStore m TuplePage
  ReadStartingWithUser :: Revision -> UsersetQuery -> TupleStore m TuplePage
  WriteTuples :: [Tuple] -> TupleStore m ConsistencyToken
  DeleteTuples :: [Tuple] -> TupleStore m ConsistencyToken
  HeadRevision :: TupleStore m Revision
  OptimizedRevision :: TupleStore m Revision
  OldestRetainedXid :: TupleStore m Word64
  ReapDeletedTuples :: Word64 -> TupleStore m Int64

type instance DispatchOf TupleStore = Dynamic
```

Export one smart constructor per operation (lower-camelCase names matching the old field names, so
downstream call sites change as little as possible):

```haskell
readObjectRelation :: (TupleStore :> es) => Revision -> ObjectRef -> RelationName -> Int -> Maybe StoreCursor -> Eff es TuplePage
readObjectRelation r o rel lim cur = send (ReadObjectRelation r o rel lim cur)
-- …and similarly readStartingWithUser, writeTuples, deleteTuples, headRevision,
--    optimizedRevision, oldestRetainedXid, reapDeletedTuples
```

Update the module export list to export `TupleStore (..)`, the data types as before, and every
smart constructor.

**(b) Reformulate `En.Effect.ConsistencyStore`.** Keep `TokenMetadata` and `ResolvedConsistency`.
The three operations previously returned `m (Either EnError …)`; now they return the success value
directly and the *interpreter* will require `Error EnError`. Add the same three pragmas and the
`Effectful` imports. Define:

```haskell
data ConsistencyStore :: Effect where
  DecodeToken :: ConsistencyToken -> ConsistencyStore m TokenMetadata
  ValidateToken :: TokenMetadata -> ConsistencyStore m ()
  ResolveConsistency :: Consistency -> ConsistencyStore m ResolvedConsistency

type instance DispatchOf ConsistencyStore = Dynamic
```

with smart constructors `decodeToken`, `validateToken`, `resolveConsistency`. Note this module no
longer needs to import `EnError` (the error now lives in the interpreters); confirm and drop the
now-unused import to satisfy `-Wall`/`-Wredundant-constraints`.

**(c) Migrate `En.Check`.** Change `check` (and `runCheck`, `evalRelation`, `evalRewrite`,
`evalThis`, `evalTupleToUserset`) from `(Monad m) => ConsistencyStore m -> TupleStore m -> … -> m
(Either EnError a)` to effect-constrained `Eff` functions that **no longer take the store records
as arguments**:

```haskell
check ::
  (ConsistencyStore :> es, TupleStore :> es, Error EnError :> es) =>
  ReachabilityGraph -> Consistency -> CaveatContext -> Subject -> RelationName -> ObjectRef ->
  Eff es CheckDecision
check graph consistency context subject permission object = do
  ResolvedConsistency{revision} <- resolveConsistency consistency
  runCheck graph context revision subject permission object
```

Inside the eval functions, replace `tupleStore.readObjectRelation …` with the smart constructor
`readObjectRelation …` and `tupleStore.readStartingWithUser …` with `readStartingWithUser …`.
Where the old code matched `Left err -> pure (Left err)` on a `resolveConsistency`/store result,
delete the manual plumbing — `resolveConsistency` now yields the value directly (the interpreter
throws on failure). Where a *pure* helper returns `Either EnError a`
(`applyRewriteCaveat`, `applyTupleCaveat`, `evaluateNamedCaveat`, `ensureExhausted`), keep the
helper as-is and bridge at the call site with `either throwError pure (…)`. Import `Effectful (Eff,
(:>))`, `Effectful.Error.Static (Error, throwError)`, and the two store effects with their smart
constructors.

Migrate **`checkMany`** in the same file the same way:

```haskell
checkMany ::
  (ConsistencyStore :> es, TupleStore :> es, Error EnError :> es) =>
  ReachabilityGraph -> Consistency -> CaveatContext -> [BatchPair] -> Eff es [CheckDecision]
checkMany graph consistency context pairs = do
  ResolvedConsistency{revision} <- resolveConsistency consistency
  (decisionsByPair, _memo) <- foldM (evaluateDistinct revision) (Map.empty, Map.empty) (dedupePairs pairs)
  pure [Map.findWithDefault Denied pair decisionsByPair | pair <- pairs]
  where evaluateDistinct revision (decisionsByPair, memo) pair = …  -- body unchanged, now in Eff es
```

The `resolveConsistency` `Left`-plumbing collapses (the value flows directly; the interpreter
throws on failure); the `foldM` over `dedupePairs pairs` and the per-pair memo are unchanged except
that `evaluateDistinct` now runs in `Eff es` and its inner `check`/eval calls use the smart
constructors. `BatchPair` and `dedupePairs` keep their current definitions. The fail-closed
`Map.findWithDefault Denied` behavior is preserved verbatim.

**(d) Migrate `En.Lookup` and `En.Expand`** the same way. For `Lookup`, the `Deadline m` newtype
becomes `Deadline es = Deadline { remainingBudget :: Eff es Bool }` (or keep it polymorphic as
`Deadline (Eff es) Bool` by leaving it `newtype Deadline m = Deadline { remainingBudget :: m Bool }`
and instantiating `m = Eff es` at use sites — prefer the latter, smaller change, and keep
`noDeadline :: (Applicative m) => Deadline m`). `lookup`, `lookupWithDeadline`, `runLookup` drop the
store arguments and gain the effect constraints. `Expand`'s `expand`, `runExpand`, and helpers do
the same; `readObjectRows` calls the `readObjectRelation` smart constructor.

**(e) Reformulate the in-memory store in `en-core/src/En/Conformance/Kikan.hs`.** Do **not** invent
a new `En.Effect.InMemory` module — MasterPlan 3 EP-18 already shipped the shared in-memory store
here as `inMemoryTupleStore :: [Tuple] -> TupleStore IO` and `consistencyStore :: ConsistencyStore
IO`, and `en-core/test/Main.hs`, `en-servant/test/Main.hs`, and `en-example` import them. Convert
those two values into interpreters in the same module, keeping the rest of the file (the kikan
schema, graph, fixtures, contexts, object refs) untouched. The pure pager logic inside
`inMemoryTupleStore` (the `pageTuples`/`tupleRow`/`decodeTestCursor` helpers) moves into the
interpreter body verbatim:

```haskell
-- The tuple list is fixed test data, so the interpreter is pure over IOE (no IORef needed):
runTupleStoreInMemory :: (Error EnError :> es) => [Tuple] -> Eff (TupleStore : es) a -> Eff es a
runTupleStoreInMemory tuples = interpret_ \case
  ReadObjectRelation rev obj rel lim cur -> pure (pageTuples lim cur (matching …))
  ReadStartingWithUser rev q             -> pure (pageTuples q.queryLimit q.queryCursor (matching …))
  WriteTuples _                          -> throwError …  -- as the record did (read-only fixture)
  …  -- headRevision/optimizedRevision/oldestRetainedXid return the fixture's fixed revision

runConsistencyStoreInMemory :: (Error EnError :> es) => Eff (ConsistencyStore : es) a -> Eff es a
runConsistencyStoreInMemory = interpret_ \case
  ResolveConsistency _ -> pure (ResolvedConsistency …)  -- the fixed snapshot the record returned
  DecodeToken …        -> …
  ValidateToken …      -> pure ()
```

Match each operation's behavior to what the current record fields return (read them first), and
`throwError` exactly where the records returned `Left`. Export the two `run…InMemory` functions
(and keep exporting the fixtures). Neither interpreter needs `IOE` because the fixture store is
pure; add it only if a chosen implementation genuinely needs `IO`. Add `effectful`/`effectful-core`
to the `en-core` library `build-depends` (already required by M1(0)).

**(f) Port the three en-core engine-consuming targets.** Each replaces "pass the record to `check`"
with "run the engine under the interpreters." Define a shared runner (in each target, or a tiny
exposed test helper) — note `ConsistencyStore` is the head of the list, so its interpreter is
rightmost and may call `TupleStore` operations still in scope to its left:

```haskell
runEngine :: [Tuple] -> Eff '[ConsistencyStore, TupleStore, Error EnError] a -> Either EnError a
runEngine tuples = runPureEff . runErrorNoCallStack . runTupleStoreInMemory tuples . runConsistencyStoreInMemory
-- (runPureEff if the interpreters are pure; runEff in IO if any needs IOE)
```

1. `en-core/test/Main.hs` (`en-core-interface-tests`): each `assertEqual "…" (Right Allowed) =<<
   check consistencyStore tupleStore graph …` becomes `assertEqual "…" (Right Allowed) (runEngine
   fixtureTuples (check graph …))` (drop `=<<` if the runner is pure).
2. `en-core/test` `en-core-conformance` suite: same mechanical change to its `check`/`lookup` calls.
3. `en-core/bench/Main.hs` (`en-core-bench`): the three `bench` groups call `check`, `checkMany`,
   and `Lookup.lookup`; wrap each benched action in `runEngine` so it benchmarks the interpreted
   engine. Keep `en-core/bench/baseline.csv` as the regression baseline; if the `effectful`
   indirection shifts timings beyond the gate's tolerance, re-record the baseline and note the
   shift in Surprises & Discoveries (do not silently widen the gate).

Add `effectful`/`effectful-core` to the `test-suite en-core-interface-tests`, `test-suite
en-core-conformance`, and `benchmark en-core-bench` `build-depends` stanzas.

Acceptance: `cabal test en-core` (both suites) passes with the same decisions as before
(`Allowed`/`Denied`/`Conditional`), and `cabal bench en-core` runs green against the baseline. The
diff must show the engine functions no longer take store
records and the test exercises the in-memory interpreter.

### Milestone M2 — en-postgres interpreters

Scope: replace the record constructors with real interpreters backed by PostgreSQL. At the end,
`en-postgres` builds and its revision tests pass; the integration test is updated to run the new
interpreters.

**(a) Add `en-postgres/src/En/Postgres/Database.hs`** modeled on
`shomei-postgres/src/Shomei/Postgres/Database.hs`, but interpreted against a single `Connection`:

```haskell
data Database :: Effect where
  RunSession :: Session a -> Database m (Either Hasql.SessionError a)
type instance DispatchOf Database = Dynamic

runSession :: (Database :> es) => Session a -> Eff es (Either Hasql.SessionError a)
runSession = send . RunSession

runDatabaseConnection :: (IOE :> es) => Connection -> Eff (Database : es) a -> Eff es a
runDatabaseConnection conn = interpret_ \case
  RunSession sess -> liftIO (Connection.use conn sess)
```

(Use whatever error type `Hasql.Connection.use` returns in the pinned hasql version — confirm by
reading the hasql source via `mori registry show hasql/hasql --full`; the current
`runStoreSession` already calls `Connection.use connection session >>= \case Right … Left …` and
renders the error with `Hasql.toDetailedText`, so reuse that type.) Add the module to
`exposed-modules` and `effectful`/`effectful-core` to `build-depends`.

**(b) Replace the tuple-store constructor.** In `en-postgres/src/En/Postgres/TupleStore.hs`, keep
all the `…Session` builder functions unchanged. Remove `PostgresSessionRunner`,
`hasqlConnectionRunner`, `postgresTupleStore`, `postgresTupleStoreIO`, and `runStoreSession`, and
add:

```haskell
runTupleStorePostgres ::
  (Database :> es, IOE :> es, Error EnError :> es) =>
  ConsistencyConfig -> Eff (TupleStore : es) a -> Eff es a
runTupleStorePostgres config = interpret_ \case
  ReadObjectRelation rev obj rel lim cur -> orThrow =<< runSession (readObjectRelationSession rev obj rel lim cur)
  ReadStartingWithUser rev q            -> orThrow =<< runSession (readStartingWithUserSession rev q)
  WriteTuples tuples                    -> orThrow =<< runSession (writeTuplesSession config tuples)
  DeleteTuples tuples                   -> orThrow =<< runSession (deleteTuplesSession config tuples)
  HeadRevision                          -> orThrow =<< runSession headRevisionSession
  OptimizedRevision                     -> orThrow =<< runSession headRevisionSession
  OldestRetainedXid                     -> orThrow =<< runSession (oldestRetainedXidSession config.gcWindow)
  ReapDeletedTuples horizon             -> orThrow =<< runSession (reapDeletedTuplesSession horizon)
  where
    orThrow = either (throwError . toEnError) pure
```

Define `toEnError :: Hasql.SessionError -> EnError` (pick the appropriate `EnError` constructor for
an infrastructure failure — read `En/Error.hs` to choose; render details with
`Hasql.toDetailedText` as the current code does). Note `reapDeletedTuples` was previously both an
exported standalone function and a record field; keep the standalone session builder (rename to
`reapDeletedTuplesSession` if needed to avoid the clash) and route the effect operation to it.

**(c) Replace the consistency-store constructor.** In `en-postgres/src/En/Postgres/Revision.hs`,
keep `tokenMetadataFromPayload`, `validateTokenMetadata`, `resolveConsistencyRequest`,
`ConsistencyConfig`, and the `pg_snapshot` machinery. Replace `postgresConsistencyStore` with:

```haskell
runConsistencyStorePostgres ::
  (TupleStore :> es, IOE :> es, Error EnError :> es) =>
  ConsistencyConfig -> Eff (ConsistencyStore : es) a -> Eff es a
runConsistencyStorePostgres config = interpret_ \case
  DecodeToken tok          -> pure (tokenMetadataFromPayload …) -- or throwError on a decode failure
  ValidateToken meta       -> do now <- liftIO getCurrentTime; oldestXid <- oldestRetainedXid; either throwError pure (validateTokenMetadata config now oldestXid meta)
  ResolveConsistency req   -> do now <- liftIO getCurrentTime; optimized <- optimizedRevision; currentHead <- headRevision; oldestXid <- oldestRetainedXid; either throwError pure (resolveConsistencyRequest optimized currentHead tokenMetadataFromPayload (validateTokenMetadata config now oldestXid) req)
```

The interpreter obtains revisions by calling the `TupleStore` smart constructors
(`optimizedRevision`, `headRevision`, `oldestRetainedXid`) — which is why it requires
`(TupleStore :> es)` and must be interpreted *above* `TupleStore` in the stack — and reads the
clock with `liftIO getCurrentTime`. Translate the old `Either EnError` results with
`either throwError pure`.

**(d) Update the en-postgres tests.** `en-postgres/test/Main.hs` (the revision/unit tests) and
`en-postgres/integration-test/Main.hs` must run the new interpreters instead of constructing
records. Provide the same `runEngine`-style helper, composing
`runEff . runErrorNoCallStack . runDatabaseConnection conn . runTupleStorePostgres config .
runConsistencyStorePostgres config`. (Note `ConsistencyStore` is interpreted to the right of
`TupleStore`, which is to the right of `Database`.)

Acceptance: `cabal build en-postgres`; `cabal test en-postgres:en-postgres-revision-tests` passes.
The integration test (`en-postgres:en-postgres-integration-tests`, which needs the
`ephemeral-pg` PostgreSQL fixture) passes when run with a database available. The
`en-postgres-bench` target benchmarks only the pure snapshot codec (no store, no engine) and needs
no source change; just confirm `cabal build en-postgres:en-postgres-bench` still compiles.

### Milestone M3 — en-servant seam + en-example host

Scope: replace the IO-store record fields with an `Eff`→`Handler` seam, then migrate the
`en-example` package that consumes it. At the end, `en-servant` and `en-example` build, all
handlers (including `/batch-check`) call the smart-constructor engine inside `Eff`, and both test
suites pass.

**(a) Add `en-servant/src/En/Servant/Seam.hs`** modeled on `shomei-servant/src/Shomei/Servant/Seam.hs`:

```haskell
type AppEffects = '[ConsistencyStore, TupleStore, Error EnError, Database, IOE]

data Env = Env
  { runPorts :: !(forall a. Eff AppEffects a -> IO (Either EnError a))
  , graph :: !ReachabilityGraph
  }

runEngine :: Env -> Eff AppEffects a -> Handler a
runEngine env action = do
  result <- liftIO (env.runPorts action)
  either (throwError . enErrorToServerError) pure result
```

`enErrorToServerError :: EnError -> ServerError` reuses the JSON-error shape currently in
`En/Servant/API.hs`'s `eitherEngine`/`jsonError` (map to `err500` for engine failures, mirroring
today's behavior). The `graph` lives in `Env` because the engine still takes the
`ReachabilityGraph` as a plain argument.

**(b) Rewrite the handlers** in `en-servant/src/En/Servant/API.hs`. Replace `data EnServer { …
ConsistencyStore IO, TupleStore IO, graph }` with the `Env` from the seam (or keep the name
`EnServer = Env`). Each handler becomes, e.g.:

```haskell
checkHandler :: Env -> CheckRequestWire -> Handler CheckResponseWire
checkHandler env request = do
  consistency <- either400 (consistencyFromWire request.consistency)
  context     <- either400 (contextFromWire request.context)
  subject     <- either400 (subjectFromWire request.subject)
  object      <- either400 (objectRefFromWire request.object)
  decision    <- runEngine env (check env.graph consistency context subject (RelationName request.permission) object)
  pure CheckResponseWire{decision = decisionToWire decision}
```

Note the engine call no longer passes stores; they are supplied by `runPorts`. `writeTuplesHandler`
/`deleteTuplesHandler` call `writeTuples`/`deleteTuples` smart constructors through `runEngine`.
The **`batchHandler`** (the `/batch-check` route) calls `checkMany`: after decoding and
size-checking the `[BatchPair]` (keep the existing `maxBatchSize` 400 guard), it becomes
`decisions <- runEngine env (checkMany env.graph consistency context pairs)`. Drop the now-unused
`liftIO`/`eitherEngine` plumbing (or fold it into the seam).

**(c) Rewrite `En.Servant.Authorize`** the same way: `AuthorizationEnv` becomes the seam `Env`,
and `requirePermission` calls `runEngine env (check …)` then branches `Allowed`/`Denied`/
`Conditional` as before.

**(d) Update `en-servant/test/Main.hs`.** It imports `consistencyStore`, `inMemoryTupleStore`,
`fixtureTuples`, `kikanGraph` from `En.Conformance.Kikan` and assembles an `EnServer`/`app` to
exercise the routes (including the oversized-batch 400 case). Build its `Env.runPorts` from the
in-memory interpreters reformulated in M1(e): `runPorts = pure . runPureEff . runErrorNoCallStack .
runTupleStoreInMemory fixtureTuples . runConsistencyStoreInMemory` (wrap in `pure` to match the
`forall a. Eff AppEffects a -> IO (Either EnError a)` shape; or run in `IO` via `runEff` if any
interpreter needs `IOE`). Note this test's `AppEffects` has no `Database` effect — the seam's
`Env.runPorts` is a plain function field, so a test may supply a runner over a *different* effect
list than the production one, as long as it produces `IO (Either EnError a)`. (This is exactly how
shomei's seam lets the in-memory test stack and the postgres stack share one `Env`.)

**(e) Migrate the `en-example` package.** In `en-example/src/En/Example/Host.hs`: `mkEnv` now builds
the seam `Env` (a `runPorts` plus `graph`) instead of an `AuthorizationEnv` record; the
`requirePermission`-based handlers (`viewDocument`/`viewSecret`) and the resolver gates
(`resolveDocument`/`resolveSecret`/`resolveWithGate`) call the migrated `requirePermission`/`check`
through the seam; the local `inMemoryTupleStore :: [Tuple] -> TupleStore IO` and
`failingConsistencyStore :: ConsistencyStore IO` become interpreters
(`runTupleStoreInMemory'`/`runConsistencyStoreFailing`, the latter a one-line interpreter whose
`ResolveConsistency` always `throwError`s — preserving the 500-path proof). Update
`en-example/app/Main.hs` and `en-example/test/Main.hs` to assemble the env from the interpreters.

Add `effectful`/`effectful-core` and `en-postgres` (for the `Database` effect type named in
`AppEffects`) to `en-servant.cabal` `build-depends` if not already present, and
`effectful`/`effectful-core` to `en-example.cabal`.

Acceptance: `cabal build en-servant en-example`; `cabal test en-servant en-example` pass —
including en-servant's ordered batch-decision and HTTP-400-oversized-batch assertions and
en-example's allowed/denied/conditional/engine-error fail-closed assertions.

### Milestone M4 — en-server assembly

Scope: compose the real interpreter stack and boot the service. At the end, `en-server` builds, the
binary starts, and an HTTP `check` returns the same decision as before the migration.

In `en-server/app/Main.hs`, after acquiring the `Connection` and compiling the `graph`, build the
runner and `Env`:

```haskell
let runAppIO :: forall a. Eff AppEffects a -> IO (Either EnError a)
    runAppIO =
      runEff
        . runDatabaseConnection connection
        . runErrorNoCallStack
        . runTupleStorePostgres config
        . runConsistencyStorePostgres config
    serverEnv = Env { runPorts = runAppIO, graph = graph }
Warp.run port (app serverEnv)
```

Read the composition right-to-left: `runConsistencyStorePostgres` (rightmost) handles the head
effect `ConsistencyStore` and may call `TupleStore`; `runTupleStorePostgres` handles `TupleStore`
and may call `Database`; `runErrorNoCallStack` handles `Error EnError` and produces the `Either`;
`runDatabaseConnection` handles `Database`; `runEff` handles `IOE`. This order matches the
`AppEffects` list in the seam (M3a). Delete the old `tupleStore = postgresTupleStoreIO …` and
`consistencyStore = postgresConsistencyStore …` lines. Add `effectful` to `en-server.cabal`
`build-depends`.

Acceptance: `cabal build en-server`; `cabal run en-server` boots against a migrated database
(`EN_DATABASE_URL` set; migrations from `en-migrations` applied) and prints "en-server listening
on :8080"; the end-to-end transcript in Validation returns the expected decision.

### Milestone M5 — whole-repo build/test, en-client check, cleanup

Scope: prove the whole workspace is green and nothing was left half-migrated. Confirm `en-client`
still builds unchanged (it is a `servant` `ClientM` client — its `batchCheck`/`check`/… are wire
endpoints and it never references the stores, so the migration should not touch it; if it fails to
build, something leaked and must be investigated). Run every target that consumes the engine:
`en-core-interface-tests`, `en-core-conformance`, `en-core-bench`, `en-servant-tests`,
`en-example-tests`, and both PostgreSQL test suites; confirm `en-core-bench` and `en-postgres-bench`
still pass their regression gates (re-record `en-core/bench/baseline.csv` only if the `effectful`
indirection shifted timings, and document it). Remove any dead code, unused imports, and stale
exports flagged by `-Wall`. Update the module header comments in `En/Effect/TupleStore.hs` and
`En/Effect/ConsistencyStore.hs` (which currently say integration with an effect system "follows
shomei's convention … refined as the engine lands") to state that the effect-system integration is
now complete.

Acceptance: from the repo root, `cabal build all`, `cabal test all`, and `cabal bench all` all
succeed (integration tests requiring PostgreSQL run when a database is available; otherwise note
the skip).


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/en`, unless stated.

If `cabal` cannot resolve `effectful`, discover its on-disk path with
`mori registry show effectful/effectful --full` and add a `packages:` block to `cabal.project`.

Per-milestone build/test loop:

```bash
# M1
cabal build en-core
cabal test  en-core                  # en-core-interface-tests + en-core-conformance
cabal bench en-core                  # en-core-bench, vs en-core/bench/baseline.csv

# M2
cabal build en-postgres
cabal test  en-postgres:en-postgres-revision-tests
cabal build en-postgres:en-postgres-bench    # pure snapshot codec; build-only check
# Integration (needs PostgreSQL via the ephemeral-pg fixture):
cabal test  en-postgres:en-postgres-integration-tests

# M3
cabal build en-servant en-example
cabal test  en-servant en-example

# M4
cabal build en-server

# M5
cabal build all
cabal test  all
cabal bench all
```

Expected shape of a green core test run (M1) — the suite is `exitcode-stdio`, so success is exit
code 0 with the assertion lines printing and no `assertEqual` failure:

```text
Build profile: -w ghc-9.12.4 -O1
...
Test suite en-core-interface-tests: RUNNING...
Test suite en-core-interface-tests: PASS
```

End-to-end check against the running server (M4), in a second terminal once `en-server` is
listening on `:8080` (the built-in demo schema defines a `space` with a `viewer` relation and a
`view` permission):

```bash
# Grant: make user:alice a viewer of space:s1
curl -s -X POST localhost:8080/tuples \
  -H 'content-type: application/json' \
  -d '{"tuples":[{"object":{"objectType":"space","objectId":"s1"},"relation":"viewer","subject":{"tag":"SubjectIdWire","contents":{"objectType":"user","objectId":"alice"}}}]}'

# Check: may user:alice view space:s1 ?  -> expect an "Allowed" decision in the JSON body
curl -s -X POST localhost:8080/check \
  -H 'content-type: application/json' \
  -d '{"permission":"view","object":{"objectType":"space","objectId":"s1"},"subject":{"tag":"SubjectIdWire","contents":{"objectType":"user","objectId":"alice"}},"consistency":...,"context":...}'
```

The exact request bodies must match the existing wire encoders in `En/Servant/API.hs`
(`WriteTuplesRequestWire`, `CheckRequestWire`, `SubjectWire`, `consistencyFromWire`,
`contextFromWire`); read those types to fill in `consistency`/`context`. The point of the
transcript is that the decision returned after the migration is identical to before it — capture
both and compare. Record the actual transcript in Surprises & Discoveries / Outcomes.


## Validation and Acceptance

The migration is internal (it changes how effects are threaded), so acceptance is anchored on
*behavior that is observably unchanged* plus *the new effect machinery actually being exercised*:

1. **en-core decisions unchanged.** `cabal test en-core` (both `en-core-interface-tests` and
   `en-core-conformance`) passes the same assertions as before the migration (owner can view;
   non-member cannot; intersection requires every branch; parent recursion grants view; the kikan
   agency shared-vs-internal scenario; `checkMany` ordered per-pair decisions and read-sharing;
   etc.). The decisions (`Allowed`/`Denied`/`Conditional`) are byte-for-byte the same; only the
   harness changed (it now runs `runErrorNoCallStack . runTupleStoreInMemory .
   runConsistencyStoreInMemory` over the reformulated `En.Conformance.Kikan` interpreters). This
   proves the engine — including `checkMany` — is genuinely running through `effectful`
   interpreters, not just compiling. `cabal bench en-core` passes its baseline gate.

2. **en-postgres behavior unchanged.** `cabal test en-postgres:en-postgres-revision-tests` passes;
   the integration suite passes against a real database. The SQL is identical (the `…Session`
   builders are untouched); only the interpreter wrapping them changed.

3. **Service and example behavior unchanged.** With `en-server` running against a migrated
   database, the write-then-check transcript above returns the same decision the pre-migration
   server returned for the same inputs, and `/batch-check` returns the same ordered per-pair
   decisions. A database outage still surfaces as a `5xx`, not a hang. `cabal test en-example`
   still proves the fail-closed mapping (allowed → 200; denied/conditional → 403; engine error via
   `failingConsistencyStore` → 500).

4. **The records are gone.** Grep proves the old API is fully removed and the new one is in place
   across all seven packages:

   ```bash
   # No record-of-functions stores or IO-pinned constructors remain:
   grep -rn 'data TupleStore m\|data ConsistencyStore m\|postgresTupleStoreIO\|postgresConsistencyStore\|PostgresSessionRunner\|:: TupleStore IO\|:: ConsistencyStore IO\|AuthorizationEnv' en-core en-postgres en-servant en-server en-example
   # Expect: no matches (AuthorizationEnv is replaced by the seam Env).

   # The engine entry points are effect-constrained:
   grep -n ':> es' en-core/src/En/Check.hs en-core/src/En/Lookup.hs en-core/src/En/Expand.hs
   # Expect: matches on check, checkMany, lookup, expand showing
   #   (TupleStore :> es), (ConsistencyStore :> es), (Error EnError :> es).
   ```

5. **Whole workspace green.** `cabal build all`, `cabal test all`, and `cabal bench all` succeed.


## Idempotence and Recovery

Every step is additive-then-subtractive and re-runnable. `cabal build` / `cabal test` are
naturally idempotent. The `init-plan.ts` script already created this file and refuses to overwrite
it, so re-running plan creation is safe. If a milestone leaves the tree non-compiling, recover by
reverting that milestone's commit (`git revert` or `git restore` the touched files) — because each
milestone is committed only when green, the previous commit is always a working state. The only
external state is PostgreSQL: the integration tests use the Mori-registered `ephemeral-pg` fixture
(already in `cabal.project`), which spins up and tears down its own database, so they can be run
repeatedly without manual cleanup. `cabal.project` edits must be appended as new blocks (per its
banner comment) so milestones never clobber each other's dependency overrides.


## Interfaces and Dependencies

Libraries added: `effectful` and `effectful-core` (Mori-registered at
`/Users/shinzui/Keikaku/hub/haskell/effectful-project`), used in `en-core`, `en-postgres`,
`en-servant`, `en-server`, and `en-example`. `hasql` remains the PostgreSQL client (already a
dependency of `en-postgres`). `servant`/`servant-server` remain unchanged. `tasty-bench` (already
in `cabal.project`) backs the `en-core-bench`/`en-postgres-bench` targets. `en-client` gains no
dependency (out of scope). No new external services.

Signatures that must exist at the end of each milestone (full module paths):

- M1, `En.Effect.TupleStore`: `data TupleStore :: Effect` with `DispatchOf TupleStore = Dynamic`
  and smart constructors `readObjectRelation`, `readStartingWithUser`, `writeTuples`,
  `deleteTuples`, `headRevision`, `optimizedRevision`, `oldestRetainedXid`, `reapDeletedTuples`,
  each `(TupleStore :> es) => … -> Eff es …`.
- M1, `En.Effect.ConsistencyStore`: `data ConsistencyStore :: Effect` with `Dynamic` dispatch and
  smart constructors `decodeToken`, `validateToken`, `resolveConsistency`.
- M1, `En.Check`: `check :: (ConsistencyStore :> es, TupleStore :> es, Error EnError :> es) =>
  ReachabilityGraph -> Consistency -> CaveatContext -> Subject -> RelationName -> ObjectRef ->
  Eff es CheckDecision`; and `checkMany :: (ConsistencyStore :> es, TupleStore :> es, Error EnError
  :> es) => ReachabilityGraph -> Consistency -> CaveatContext -> [BatchPair] -> Eff es
  [CheckDecision]` (`BatchPair` unchanged). Analogous shapes for `En.Lookup.lookup`/
  `lookupWithDeadline` and `En.Expand.expand`.
- M1, `En.Conformance.Kikan` (reformulated, not new): `runTupleStoreInMemory :: (Error EnError :>
  es) => [Tuple] -> Eff (TupleStore : es) a -> Eff es a` and `runConsistencyStoreInMemory ::
  (Error EnError :> es) => Eff (ConsistencyStore : es) a -> Eff es a` (add `IOE :> es` only if the
  chosen implementation needs `IO`). The kikan schema/graph/fixtures keep their current exports.
- M2, `En.Postgres.Database`: `data Database :: Effect`, `runSession`, `runDatabaseConnection ::
  (IOE :> es) => Connection -> Eff (Database : es) a -> Eff es a`.
- M2, `En.Postgres.TupleStore`: `runTupleStorePostgres :: (Database :> es, IOE :> es, Error EnError
  :> es) => ConsistencyConfig -> Eff (TupleStore : es) a -> Eff es a`.
- M2, `En.Postgres.Revision`: `runConsistencyStorePostgres :: (TupleStore :> es, IOE :> es, Error
  EnError :> es) => ConsistencyConfig -> Eff (ConsistencyStore : es) a -> Eff es a`.
- M3, `En.Servant.Seam`: `type AppEffects = '[ConsistencyStore, TupleStore, Error EnError, Database,
  IOE]`; `data Env = Env { runPorts :: forall a. Eff AppEffects a -> IO (Either EnError a), graph ::
  ReachabilityGraph }`; `runEngine :: Env -> Eff AppEffects a -> Handler a`. The `batchHandler`
  (`/batch-check`) calls `checkMany` through `runEngine`. Note `Env.runPorts` is a plain function
  field, so the en-servant/en-example tests may supply a runner over an in-memory effect list (no
  `Database`) as long as it yields `IO (Either EnError a)`.
- M3, `en-example` (`En.Example.Host`): `mkEnv` returns the seam `Env`; `failingConsistencyStore`
  becomes an interpreter `runConsistencyStoreFailing :: (Error EnError :> es) => Eff
  (ConsistencyStore : es) a -> Eff es a` whose `ResolveConsistency` always `throwError`s.
- M4, `en-server/app/Main.hs`: `runAppIO :: Eff AppEffects a -> IO (Either EnError a)` composed as
  `runEff . runDatabaseConnection connection . runErrorNoCallStack . runTupleStorePostgres config .
  runConsistencyStorePostgres config`.

The load-bearing constraint across milestones: in `AppEffects`, `ConsistencyStore` sits above
`TupleStore` (its interpreter calls tuple-store operations), and both sit above `Database` and
`IOE`. Any reordering that puts `TupleStore` out of scope when `runConsistencyStorePostgres` runs
will fail to type-check — which is the desired safety net.


## Revision Notes

- 2026-06-23: Removed the original "M0 — Dependency spike" milestone. The `effectful`/
  `effectful-core` dependency is known-good on GHC 9.12.4 across 10+ of the author's projects on
  this toolchain, so proving it builds is wasted ceremony. The Cabal `build-depends` additions are
  now folded into the milestone that first needs them (en-core's addition is step M1(0)). Updated
  Progress, Decision Log, Plan of Work, and Concrete Steps accordingly; M1–M5 are now the full set.

- 2026-06-23: **Reconciled against the completed MasterPlan 3** (EP-14 through EP-19), which landed
  after this plan was authored. The migration surface grew, and the plan now reflects it across all
  sections: (1) a seventh package, **`en-example`** (EP-18), which imports `AuthorizationEnv`/
  `requirePermission`, builds the store records (including its own `failingConsistencyStore`), and
  calls `check` directly — added to the package list, Context, M3 (new step (e)), and Validation.
  (2) **`En.Check.checkMany`/`BatchPair`** (EP-19), a third engine entry point — added to Context,
  M1(c), the seam's `batchHandler` (M3(b)), and Interfaces. (3) **`En.Conformance.Kikan`** (EP-18)
  is an *exposed* en-core module already shipping the in-memory store (`inMemoryTupleStore`/
  `consistencyStore`) consumed by en-core and en-servant tests; M1(e) now *reformulates it into
  interpreters in place* rather than inventing a new `En.Effect.InMemory`/`World` (Decision Log
  updated; the obsolete `World`-based interface dropped from Interfaces). (4) The en-servant
  **`/batch-check`** handler — added to M3. (5) New `tasty-bench`/conformance targets
  (`en-core-conformance`, `en-core-bench`, `en-servant-tests`, `en-example-tests`) that consume the
  engine — added to M1(f), M3, M5, Concrete Steps, and Validation; the baseline-CSV re-record
  caveat is noted. (6) Confirmed two things stay out of scope: **`en-client`** (pure `ClientM`;
  `batchCheck` is just an endpoint) and **`en-postgres-bench`** (pure snapshot-codec benchmarking,
  no store/engine). No design decision changed — only the inventory of files the migration touches.
