---
id: 19
slug: add-batchcheck-for-graphql-field-capability-and-candidate-filtering
title: "Add BatchCheck for GraphQL field-capability and candidate filtering"
kind: exec-plan
created_at: 2026-06-23T20:26:36Z
intention: "intention_01kvv5mecvechb6c6jv3p3zv4a"
master_plan: "docs/masterplans/3-harden-en-correctness-fixes-lookup-streaming-and-performance-benchmarks.md"
---

# Add BatchCheck for GraphQL field-capability and candidate filtering

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`en` (縁) is a relationship-based access-control engine: a Haskell library that answers
"may THIS subject do THIS to THIS object?" by walking a graph of relationship **tuples**
(facts such as "alice owns space project-x"). Today it answers exactly one such question per
call. The function `check` (in `en-core/src/En/Check.hs`) takes a single subject, a single
permission, and a single object, and returns one three-valued decision: `Allowed`, `Denied`,
or `Conditional` ("the relationship path exists but a caveat still needs request context
before you may treat it as allowed"). The HTTP service exposes that as a `POST /check`
endpoint (in `en-servant/src/En/Servant/API.hs`), and the Haskell client exposes it as a
`check` method (in `en-client/src/En/Client.hs`).

This is a problem for one very common caller: a **GraphQL gateway**. A GraphQL gateway is a
single server that sits in front of many backend services and answers one client query by
fanning out to several of them. Two GraphQL situations need *many* authorization decisions to
answer *one* client request:

1. **Field-level capabilities.** A `Document` type might expose boolean fields `canEdit`,
   `canShare`, `canDelete`. Each is a separate "may this user do X to this document?"
   question. A single document with three such fields is three decisions; a page of twenty
   documents is sixty.
2. **Candidate post-filtering.** When a list is too large or too dynamic to enumerate with
   `lookup` (the reverse query that lists objects a subject can reach), the gateway instead
   fetches a database page of candidate rows and then asks, for each candidate, "may this
   user view it?" — again, many decisions for one list.

The repository's own integration guide, `docs/user/graphql-integration.md`, already tells
GraphQL authors to "collect field permission checks through the request-scoped `checkMany`
helper" and sketches a `GraphQLAuthz` environment whose `checkMany :: [AuthzCheck] -> m
[CheckDecision]` method does exactly this. But that same guide admits the gap in plain words:

> `checkMany` is an application helper. `en` currently exposes single `check` and `lookup`
> operations, so production GraphQL callers that need many decisions should add a small
> batching layer around `check`.

Doing that batching *on the caller's side*, over HTTP, means N separate `POST /check` round
trips for N decisions — N network hops, N consistency resolutions, and N independent
graph traversals that cannot share any work even when they overlap (e.g. `canEdit`,
`canShare`, and `canDelete` on the same document all walk the same ownership chain).

**What you can do after this change.** A caller — embedded in Haskell, or over HTTP, or
through the typed client — can hand `en` a *list* of `(subject, permission, object)` pairs
plus one consistency choice and one request context, and get back a list of three-valued
decisions **in the same order as the input**, computed in a single call. Internally `en`
resolves the consistency snapshot **once** for the whole batch, removes duplicate pairs,
shares overlapping graph work between pairs, runs the work with bounded concurrency, and
**fails closed per pair** (if evaluating one pair errors, that pair comes back not-`Allowed`,
and the rest of the batch still succeeds). This is the server-side realization of the
`checkMany` helper the GraphQL guide describes.

**How you will see it working.** A test in `en-core/test/Main.hs` hands `checkMany` a batch of
overlapping pairs and asserts (a) every pair gets the same decision it would have gotten from
an individual `check`, in input order; (b) the batch resolves consistency exactly once
(observed via a counting consistency store whose resolve-count is asserted to be `1`); and
(c) the batch performs strictly fewer storage reads than N independent `check` calls would,
because overlapping subproblems are computed once (observed via a counting tuple store). A
second test confirms a pair whose evaluation errors comes back not-`Allowed` while its
batch-mates still resolve. At the HTTP layer, a `POST /batch-check` request with overlapping
pairs returns ordered decisions, and a request whose pair-count exceeds the configured maximum
is rejected with HTTP 400.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Milestone 1 (engine): add `En.Check.checkMany` (a new exported function in
      `en-core/src/En/Check.hs`) that resolves consistency once, deduplicates pairs, memoizes
      shared subproblems within the call, and returns per-pair decisions in input order with
      fail-closed per-pair error handling.
- [x] Milestone 1: add `en-core/test` cases proving order preservation, single consistency
      resolution, fewer storage reads than N `check` calls, and fail-closed-per-pair.
- [x] Milestone 2 (HTTP): add `BatchCheckRequestWire`/`BatchCheckResponseWire` and a
      `POST /batch-check` endpoint to `en-servant/src/En/Servant/API.hs`, with a configurable
      maximum batch size enforced as HTTP 400 on oversized batches.
- [x] Milestone 2: add an `en-servant` test suite proving ordered decisions and the oversize
      rejection (the package has no `test/` directory today; create one and register it).
- [x] Milestone 3 (client): add the `batchCheck` method to `En.Client.EnClient` in
      `en-client/src/En/Client.hs` so HTTP consumers get it typed.
- [x] Run `cabal build all` and `cabal test all` green after each milestone.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **The within-call memo can be tested without exposing internals.** A counting `TupleStore`
  wrapped around the existing kikan fixture showed that one overlapping batch performs fewer
  tuple reads than the same pairs executed as independent `check` calls. This proves the memo is
  load-bearing while keeping `Subproblem` private to `En.Check`. _(2026-06-23)_

- **Core BatchCheck stays sequential to preserve sharing.** The final `checkMany` implementation
  evaluates distinct pairs in input-first order through one memo. This matches the plan's
  bounded-concurrency note: parallelism can be added later with a thread-safe memo, but a naive
  parallel implementation would race on an empty memo and lose the read-sharing property.
  _(2026-06-23)_

- **The existing `en-core-bench` gate could absorb BatchCheck directly.** Although EP-17 landed
  before EP-19, the benchmark target was easy to extend with `checkMany/overlapping`; refreshing
  `en-core/bench/baseline.csv` and running the `--fail-if-slower 25` gate passed with four
  benchmarks. _(2026-06-23)_


## Decision Log

Record every decision made while working on the plan.

- Decision: Resolve the consistency revision exactly **once** per batch and pass that single
  resolved `Revision` to every pair's evaluation, rather than calling the public `check`
  (which resolves consistency itself) once per pair.
  Rationale: Consistency resolution is the operation that picks the snapshot every read runs
  at. Resolving it per pair would (a) cost N resolutions and (b) risk different pairs in one
  logical request reading at *different* snapshots — exactly the "confusing UI behavior" the
  GraphQL guide warns about under "keep consistency stable across related checks." One
  resolution makes the whole batch a single point-in-time view. The existing private worker
  `runCheck` already takes a `Revision` directly (see `En/Check.hs` line ~65), so the batch
  evaluator can reuse it after resolving once.
  Date: 2026-06-23

- Decision: Add a **within-call memo** — a `Map` keyed by `(Revision, Subproblem)` that caches
  the `CheckDecision` of relation subproblems for the duration of one `checkMany` call — and
  state explicitly that this is **not** the same thing as MasterPlan 2 EP-11's decision cache
  (`docs/plans/11-implement-authorization-decision-caching.md`).
  Rationale: The within-call memo handles *intra-batch* overlap (the three `canX` checks on one
  document share an ownership walk). EP-11's process cache handles *cross-request* reuse (the
  same check next request). They compose and are independent: BatchCheck must be correct with
  **no** EP-11 cache present, so the memo lives entirely inside `checkMany` and is discarded
  when the call returns. If EP-11 later lands a process cache, `checkMany` can consult it for
  each subproblem, but correctness never depends on it.
  Date: 2026-06-23

- Decision: Share the three-valued decision algebra (`unionDecisions`/`intersectionDecisions`/
  exclusion/caveat-gate) by reusing whatever `En.Check` already uses. If EP-15
  (`docs/plans/15-generalize-the-caveat-evaluator-and-unify-the-decision-algebra.md`) has
  landed and extracted `En.Decision`, route through that. If EP-15 has **not** landed,
  `checkMany` reuses the same private worker (`runCheck`) that `En.Check.check` already calls,
  so it is byte-for-byte the same algebra `check` uses — and we rebase onto `En.Decision` when
  EP-15 lands.
  Rationale: MasterPlan 3 Integration Point 2 designates `En.Decision` as the single source of
  truth for the decision algebra. `checkMany` must not fork a third copy. Reusing `runCheck`
  (today) guarantees the batch and single paths agree by construction; rebasing later is a
  mechanical follow-up, not a redesign. EP-19 is listed in MasterPlan 3 with a soft dependency
  on EP-15 for exactly this reason.
  Date: 2026-06-23

- Decision: Default the maximum batch size to **1000** pairs, configurable on the server.
  Rationale: 1000 matches `en`'s existing bounded-result conventions — the per-page
  `pageLimit = 1000` in `En/Check.hs` (line ~98) and the lookup default cap of 1000 the spec
  cites (`docs/spec/0001-en-overview.md` §5). A bound is mandatory: the GraphQL guide's final
  checklist item is "query depth, complexity, lookup limits, and batch sizes are bounded,"
  and an unbounded batch is a denial-of-service vector (one request pinning the engine). 1000
  is generous for field-capability and candidate-page use (a screen rarely needs more) while
  remaining a hard ceiling. The engine function `checkMany` itself does **not** enforce a size
  cap — bounding is a transport-layer policy, so the cap lives in the Servant handler where an
  oversized request maps cleanly to HTTP 400.
  Date: 2026-06-23

- Decision: Fail **closed per pair**, never per batch. An engine error on one pair yields that
  pair's slot as not-`Allowed` (specifically `Denied`) in the result list; it does not abort
  the whole call.
  Rationale: The GraphQL guide's "Failure behavior" section is explicit: "Treat `Denied`,
  `Conditional`, timeouts, and engine errors as not allowed." For a batch, aborting the whole
  request on one bad pair would deny *every* field/candidate (a correctness-safe but
  user-hostile outcome), while returning a default-allow on error would be a security hole. A
  per-pair `Denied`-on-error is the fail-closed choice that keeps the other pairs answerable.
  Date: 2026-06-23

- Decision: BatchCheck returns the per-pair `CheckDecision` directly and does **not** itself
  collapse `Conditional` into deny.
  Rationale: A `Conditional` result carries caveat obligations the caller may be able to
  satisfy and retry (the guide: "retry only if the resolver can supply missing caveat
  context"). Collapsing it server-side would throw away that information. The caller decides
  product semantics; `en` reports the three-valued truth. This matches the single-`check`
  contract, which also returns `Conditional` verbatim.
  Date: 2026-06-23

- Decision: Export `CheckDecisionWire` and `CaveatObligationWire` from `En.Servant.API`.
  Rationale: BatchCheck returns a list of wire decisions directly. These constructors were already
  part of the JSON response shape through `CheckResponseWire`, but not explicitly exported. The
  new `en-servant` test and downstream clients need to construct/compare the decision values
  without relying on opaque JSON.
  Date: 2026-06-23


## Outcomes & Retrospective

EP-19 added `BatchPair` and `checkMany` to `En.Check`. The batch path resolves consistency once,
deduplicates identical pairs, shares completed subproblems through a within-call memo, preserves
input order, and maps per-pair engine errors to `Denied` while leaving the outer `Left` for
batch-wide consistency resolution failures.

The HTTP layer now exposes `POST /batch-check` with `BatchCheck*Wire` DTOs, a configurable
`maxBatchSize` on `EnServer`, and an `en-servant` test proving ordered decisions and HTTP 400 for an
oversized request. `En.Client` exposes the matching typed `batchCheck` method. The `en-core-bench`
target now includes `checkMany/overlapping` with a recorded baseline.

Validation completed with `cabal build all`, `cabal test all`, and the `en-core` benchmark gate
passing.


## Context and Orientation

This section assumes you have never seen this repository. Read it fully before editing.

`en` is a Haskell project split into several packages, each its own Cabal package under the
repository root (paths below are repository-relative). The three packages this plan touches:

- **`en-core`** — the engine. No HTTP, no database. It defines the model and the algorithms.
  Cabal file: `en-core/en-core.cabal`. Its single test suite is `en-core/test/Main.hs` (a
  hand-rolled test runner, described below).
- **`en-servant`** — the HTTP layer. It expresses the service as a *Servant API type* (Servant
  is a Haskell library where an HTTP API is described as a type and the server/client are
  derived from it) and provides the handlers. Cabal file: `en-servant/en-servant.cabal`. It
  has **no** `test/` directory today; this plan adds one.
- **`en-client`** — a typed Haskell client for the HTTP service, derived from the same Servant
  API type. Cabal file: `en-client/en-client.cabal`. File: `en-client/src/En/Client.hs`.

### The single-check engine you are extending

The whole engine for a *single* decision lives in `en-core/src/En/Check.hs`. Read it; the
batch path reuses its internals. The key shapes:

- `CheckDecision` is the three-valued result (lines ~34–42):

```haskell
data CheckDecision
    = Allowed
    | Denied
    | Conditional ![CaveatObligation]
    deriving stock (Eq, Show)
```

  `Conditional` carries a list of `CaveatObligation` values (line ~28), each naming a caveat
  and the request-context keys it is still missing. A **caveat** is a small bounded condition
  attached to a relationship (e.g. "this grant is valid until time T" or "only up to autonomy
  level act"); when the engine reaches a path gated by a caveat it cannot fully evaluate from
  the supplied request context, it returns `Conditional` instead of guessing.

- The public entry point is `check` (lines ~47–63). Its signature:

```haskell
check ::
    (Monad m) =>
    ConsistencyStore m ->
    TupleStore m ->
    ReachabilityGraph ->
    Consistency ->
    CaveatContext ->
    Subject ->
    RelationName ->
    ObjectRef ->
    m (Either EnError CheckDecision)
```

  Its body resolves the consistency snapshot and then delegates to the private worker:

```haskell
check consistencyStore tupleStore graph consistency context subject permission object = do
    resolved <- consistencyStore.resolveConsistency consistency
    case resolved of
        Left err -> pure (Left err)
        Right ResolvedConsistency{revision} ->
            runCheck tupleStore graph context revision subject permission object
```

  This is the crux for the batch path: **`runCheck` (line ~65) takes a resolved `Revision`
  directly and does not touch the consistency store.** The batch function will call
  `resolveConsistency` *once*, then call `runCheck` (or its memoized variant) per pair.

Definitions of the terms in that signature, so you need no other file:

- `ConsistencyStore m` (defined in `en-core/src/En/Effect/ConsistencyStore.hs`) — a record of
  functions abstracting "how does a token become a concrete snapshot revision?" Its method
  `resolveConsistency :: Consistency -> m (Either EnError ResolvedConsistency)` turns a
  consistency *request* into a `ResolvedConsistency{ consistency, revision }`. A **revision**
  is a concrete point-in-time snapshot of the relationship graph; every storage read happens
  "as of" some revision. Resolving consistency is the step that *picks* that snapshot.
- `TupleStore m` (defined in `en-core/src/En/Effect/TupleStore.hs`) — a record of functions
  abstracting storage. The reads the engine uses are `readObjectRelation :: Revision ->
  ObjectRef -> RelationName -> Int -> Maybe StoreCursor -> m TuplePage` (rows for a given
  object+relation) and `readStartingWithUser` (the reverse query). These are the operations a
  "counting store" in the tests will tally to prove the batch does fewer reads.
- `ReachabilityGraph` (from `En.Reachability`) — the compiled schema, telling the engine which
  relation rewrites to evaluate. Treat it as opaque here.
- `Consistency` (from `En.Revision`) — the *request* for a snapshot. Its constructors are
  `MinimizeLatency`, `FullyConsistent`, `AtLeastAsFresh token`, `AtExactSnapshot token`.
- `CaveatContext` (from `En.Tuple`) — request-time facts (a map) used to evaluate caveats.
- `Subject`, `RelationName`, `ObjectRef` (from `En.Tuple`/`En.Schema`) — *who*, *what action/
  permission*, *which object*. In `en`, a "permission" is a relation, so `permission` has type
  `RelationName`.
- `EnError` (from `En.Error`) — the closed set of engine failures (`UnknownRelation`,
  `SchemaViolation`, `MissingCaveatContext`, `InvalidConsistencyToken`,
  `ResolutionLimitExceeded`, `StoreError`). A pair's evaluation returning `Left EnError` is the
  "engine error on a pair" the fail-closed rule handles.

`runCheck` internally drives `evalRelation`, which carries an `EvalState{ depth, visited }`
where `visited :: [Subproblem]` and `Subproblem{ subject, object, relation }` (lines ~78–88).
A **subproblem** is "does this subject have this relation on this object?" — the recursive unit
of work. Two different top-level pairs that walk through the same intermediate relationship
will hit the *same* `Subproblem`. This is precisely the overlap the within-call memo exploits.
(Note: `Subproblem` is **not** currently exported from `En.Check`. The memo can be built
without exporting it, since the memoization happens inside `En.Check` itself — see Plan of
Work.)

### The HTTP layer you are extending

`en-servant/src/En/Servant/API.hs` defines `EnAPI` (line ~84), the Servant API type. It is a
chain of endpoints joined by `:<|>`:

```haskell
type EnAPI =
    "tuples" :> ReqBody '[JSON] WriteTuplesRequestWire :> Post '[JSON] WriteTuplesResponseWire
        :<|> "tuples" :> ReqBody '[JSON] DeleteTuplesRequestWire :> Delete '[JSON] WriteTuplesResponseWire
        :<|> "check" :> ReqBody '[JSON] CheckRequestWire :> Post '[JSON] CheckResponseWire
        :<|> "lookup" :> ReqBody '[JSON] LookupRequestWire :> Post '[JSON] LookupPageWire
        :<|> "expand" :> ReqBody '[JSON] ExpandRequestWire :> Post '[JSON] ExpandTreeWire
```

The pattern to mirror is the existing single-check wiring:

- `CheckRequestWire` (lines ~170–178) holds `consistency`, `context`, `subject`, `permission`,
  `object` — the JSON-serializable ("wire") forms of the engine arguments. "Wire" means the
  on-the-network representation; each has a `…toWire`/`…fromWire` conversion to/from the engine
  type, with validation that returns `Either Text` (a `Left` becomes HTTP 400).
- `CheckResponseWire` (lines ~194–198) wraps one `CheckDecisionWire`. `CheckDecisionWire`
  (lines ~180–185) is the wire form of `CheckDecision`: `AllowedWire | DeniedWire |
  ConditionalWire [CaveatObligationWire]`.
- `checkHandler` (lines ~303–322) decodes each wire field (turning a `Left` into HTTP 400 via
  `either400`), calls `check`, maps any `Left EnError` to HTTP 500 via `eitherEngine`, and
  wraps the decision with `decisionToWire`.
- `EnServer` (lines ~94–98) is the handler environment: `consistencyStore`, `tupleStore`,
  `graph`. The batch endpoint needs **one more field**, the maximum batch size, so `EnServer`
  gains `maxBatchSize :: !Int`.
- Helpers you will reuse: `consistencyFromWire`, `contextFromWire`, `subjectFromWire`,
  `objectRefFromWire`, `decisionToWire`, `either400`, `eitherEngine`, `jsonError` (all in this
  file). Servant's `err400` is already imported (line ~55).

### The client you are extending

`en-client/src/En/Client.hs` defines `EnClient`, a record of one function per endpoint, derived
from `apiProxy` by `client` (lines ~23–37). Each new endpoint adds one record field and one
binding in the `where` clause's `:<|>` pattern — the pattern must match the *exact* order and
shape of `EnAPI`.

### The test harness

`en-core/test/Main.hs` is a single `main :: IO ()` that runs assertions with two hand-rolled
helpers (lines ~804–828):

```haskell
assertBool :: String -> Bool -> IO ()
assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
```

There is **no** tasty/hspec; assertions `fail` on mismatch and a passing run exits 0. The file
already builds an in-memory tuple store (`inMemoryTupleStore`, line ~544), a `consistencyStore`
(line ~598), a compiled `graph`, and a kikan-shaped fixture with named subjects/objects (e.g.
`user`, `bob`, `space`, `childSpace`, `auditedSpace`, `exclusionSpace`, `intention`). Existing
`check` assertions (lines ~102–116) show the exact call shape and expected results — your batch
assertions reuse these same fixtures so "the batch agrees with N single checks" is provable
against known-good values.

### Where this plan sits among the others (read by path only)

This plan is **EP-19** in MasterPlan 3,
`docs/masterplans/3-harden-en-correctness-fixes-lookup-streaming-and-performance-benchmarks.md`.
Its relevant relationships:

- **Soft dependency on EP-15**
  (`docs/plans/15-generalize-the-caveat-evaluator-and-unify-the-decision-algebra.md`): EP-15
  extracts the three-valued decision algebra into a new module `En.Decision` and unifies
  `En.Check`/`En.Lookup` onto it (MasterPlan 3 Integration Point 2). `checkMany` reuses the
  same algebra `check` uses, so once EP-15 lands `checkMany` rides along automatically (it
  calls `runCheck`, which EP-15 rewires). If EP-15 has not landed, `checkMany` still reuses
  `runCheck` and is identical to `check`'s algebra by construction; see the Decision Log.
- **Cross-MasterPlan note — MasterPlan 2 EP-11**
  (`docs/plans/11-implement-authorization-decision-caching.md`): EP-11 adds a *process-lifetime*
  decision cache keyed by datastore id, schema hash, resolved revision, subject, permission,
  object, and caveat context. That **composes** with BatchCheck and is **orthogonal**: EP-11's
  cache serves cross-request reuse; BatchCheck's within-call memo serves intra-batch overlap.
  BatchCheck must be correct with no EP-11 cache present (Decision Log).
- **Downstream — EP-17**
  (`docs/plans/17-strengthen-the-lookup-spike-and-add-performance-regression-benchmarks.md`):
  EP-17 owns the benchmark suite and will add a **BatchCheck benchmark** that measures a batch
  of overlapping pairs against N independent `check` calls. This plan does not add benchmarks;
  it only makes `checkMany` exist and behave so EP-17 can measure it.

This plan does **not** depend on any of the above having landed. It edits only `En.Check`
(additively), `En.Servant.API`, the `en-servant` cabal/test, and `En.Client`.


## Plan of Work

The work is three independent, sequenced milestones: the engine function, the HTTP endpoint,
and the client method. Each is independently verifiable. The HTTP and client milestones depend
on the engine milestone's exported `checkMany` existing; the client milestone depends on the
servant milestone's `EnAPI` change.

### Milestone 1 — `En.Check.checkMany` (the engine batch)

**Scope.** Add one exported function, `checkMany`, to `en-core/src/En/Check.hs`, plus a small
exported pair type, without changing the behavior of `check`. `checkMany` resolves consistency
once, deduplicates pairs, memoizes shared subproblems within the call, runs each distinct pair,
and returns decisions in input order, failing closed per pair.

**What exists after.** `En.Check` exports `checkMany` and an input type. A novice can call it
from `en-core/test/Main.hs` and observe ordered, correct, three-valued decisions; a counting
consistency store proves one resolution; a counting tuple store proves fewer reads than N
`check` calls; an error-injecting store proves per-pair fail-closed.

**Design.**

Add an exported pair type and the function. Edit the module export list (lines ~2–6) to add
`checkMany` and `BatchPair (..)`:

```haskell
module En.Check (
    CheckDecision (..),
    CaveatObligation (..),
    BatchPair (..),
    check,
    checkMany,
) where
```

Add the input type near `CheckDecision`:

```haskell
-- | One (subject, permission, object) question in a batch. A 'checkMany' call
-- evaluates many of these against ONE resolved consistency snapshot and ONE
-- caveat context, returning a 'CheckDecision' per pair in input order.
data BatchPair = BatchPair
    { subject :: !Subject
    , permission :: !RelationName
    , object :: !ObjectRef
    }
    deriving stock (Eq, Ord, Show)
```

`Ord` is required so pairs can be `Map` keys for deduplication. `Subject`, `RelationName`, and
`ObjectRef` already derive `Ord` upstream (they are used as map keys elsewhere); if any does
not, add the missing `deriving stock Ord` to it in `En.Tuple`/`En.Schema` — verify with the
compiler and record it in Surprises & Discoveries if so.

Now the function. Its signature mirrors `check` but takes a list of pairs and returns a list of
decisions:

```haskell
checkMany ::
    (Monad m) =>
    ConsistencyStore m ->
    TupleStore m ->
    ReachabilityGraph ->
    Consistency ->
    CaveatContext ->
    [BatchPair] ->
    m (Either EnError [CheckDecision])
```

The `Either EnError` at the *outer* level covers the single batch-wide failure mode:
**consistency resolution failed** (no snapshot, so nothing can be evaluated — fail the whole
call, there is no meaningful per-pair answer). Per-*pair* engine errors do **not** surface as
`Left`; they become `Denied` inside the returned list. (Rationale in the Decision Log:
consistency resolution is the one truly batch-wide precondition; everything after it is
per-pair.)

The body, in prose so a novice can implement it:

1. **Resolve consistency once.** Call `consistencyStore.resolveConsistency consistency`. On
   `Left err`, return `pure (Left err)` — the whole batch fails because no snapshot exists. On
   `Right ResolvedConsistency{revision}`, bind `revision` and proceed. This is the single
   resolution the headline acceptance asserts (a counting store sees exactly one call).

2. **Deduplicate.** Build the set of *distinct* pairs from the input list. Identical pairs (same
   subject, permission, object) are evaluated once. Preserve a way to map each distinct pair
   back to every input position so the output can be reassembled in input order.

3. **Evaluate each distinct pair, sharing subproblem work via a within-call memo.** Maintain a
   memo `Map (Revision, Subproblem) CheckDecision` threaded through the evaluation of the whole
   batch. The memo is keyed by `(Revision, Subproblem)` exactly as the spec's perf section
   prescribes ("Cache decisions keyed by `(revision, subproblem)` and batch checks",
   `docs/spec/0001-en-overview.md` §6). Because the whole batch shares one `revision`, the
   `Revision` component is constant within a call, but it is kept in the key so the memo's shape
   matches the EP-11 cache key and a future rebase is mechanical.

   For each distinct pair, evaluate it via a **memoized variant of `runCheck`**. Concretely,
   refactor the existing recursion so that the `evalRelation` step (line ~111), which already
   computes a `Subproblem`, consults the memo before recursing: if `(revision, subproblem)` is
   present, return the cached `CheckDecision`; otherwise compute it, store it, and return it.
   Thread the memo as additional state alongside `EvalState`, or as an explicit `StateT`-style
   accumulator passed through the monad — whichever keeps the diff smallest. The single-pair
   `check` path is left calling the **unmemoized** `runCheck` so its behavior is byte-for-byte
   unchanged (the memo is a batch-only optimization; a single check has nothing to share with).

   Implementation note on the memo and the visited-set: `evalRelation`'s `visited` list (line
   ~80) is a **cycle guard** (it makes a repeated subproblem on the *current path* an error,
   `ResolutionLimitExceeded`), which is a different mechanism from the memo (which caches
   *completed* subproblem results to reuse across pairs). Keep them distinct: the cycle guard
   stays per-traversal; the memo persists across pairs within the call. A subproblem is only
   written to the memo once it has been **fully resolved** to a `CheckDecision` (not while it is
   still on the `visited` stack), so the memo never caches a partially-computed or cyclic result.

4. **Fail closed per pair.** Evaluating a distinct pair returns `m (Either EnError
   CheckDecision)`. Map `Left _` to `Denied` for that pair (the fail-closed choice; see Decision
   Log). Do **not** propagate it to the outer `Either`. A pair that errors must not prevent its
   batch-mates from resolving.

5. **Bounded concurrency.** The `m` here is a `Monad`, not necessarily `IO`, so genuine parallel
   evaluation is only available when `m ~ IO`. For the core function keep evaluation
   **sequential** over the *distinct* pairs (sequential evaluation through one shared memo is
   what actually produces the "fewer reads" win, because a later pair reuses an earlier pair's
   memo entries — parallel evaluation would race on an empty memo and lose sharing). Document in
   the function's haddock that "bounded concurrency" for the deployed service is a transport
   concern: the Servant handler runs in `IO` and MAY evaluate distinct pairs with a bounded
   pool (e.g. a semaphore of width `min(maxBatchSize, fixed-cap)`), but the within-call memo is
   the primary work-sharing mechanism and is preserved regardless. (If a future revision wants
   concurrency *and* sharing, it needs a thread-safe memo — note that as a possible follow-up,
   not a requirement here.)

6. **Reassemble in input order.** Using the position map from step 2, produce the output list so
   that the decision at index *i* is the decision for the input pair at index *i*. Duplicated
   input pairs all receive the same (single-evaluated) decision. Return `pure (Right
   decisions)`.

**Commands.**

```bash
cd /Users/shinzui/Keikaku/bokuno/en
cabal build en-core
cabal test en-core-interface-tests
```

**Acceptance (behavior).** Add these assertions to `en-core/test/Main.hs`, reusing the existing
fixtures (`consistencyStore`, `tupleStore`, `graph`, `requestContext`, and the named
subjects/objects). All four must hold:

1. **Order + agreement.** A batch of pairs drawn from the existing single-check cases — e.g.
   `[BatchPair (SubjectId user) (RelationName "view") space, BatchPair (SubjectId bob)
   (RelationName "view") space, BatchPair (SubjectId user) (RelationName "audit") space,
   BatchPair (SubjectId memberOwner) (RelationName "member_not_owner") exclusionSpace]` — returns
   `Right [Allowed, Denied, Denied, Denied]` (matching the known single-check results at lines
   ~102, ~103, ~108, ~111), in that order. Assert with `assertEqual`.

2. **Consistency resolved once.** Wrap `consistencyStore` in a *counting* store that increments
   an `IORef Int` on every `resolveConsistency` call (and otherwise delegates). Run a batch of
   several pairs through `checkMany` and assert the counter reads `1`.

3. **Fewer storage reads than N checks.** Wrap `tupleStore` in a counting store that increments
   an `IORef Int` on every `readObjectRelation`/`readStartingWithUser`. Construct a batch with
   deliberate overlap — e.g. three pairs that all walk the same object's ownership chain (such
   as `view`, and two relations that both compute through `owner` on the same `space`). Record
   the read count for `checkMany`, then reset the counter and run the same pairs as N
   independent `check` calls and record that count. Assert `batchReads < independentReads`
   strictly. (If the chosen fixtures happen not to overlap, the counts would be equal — pick
   pairs known to share a subproblem; the `audit` relation on `auditedSpace`, which is
   `Intersection [owner, member]`, shares its `owner` and `member` reads with separate `owner`
   and `member` checks on the same object.)

4. **Fail closed per pair.** Wrap `tupleStore` so that a read for *one specific object* returns
   a `StoreError`-producing page (or have `resolveConsistency` succeed but a targeted read fail)
   while reads for other objects succeed. Run a batch `[goodPair, badPair, goodPair2]` and assert
   the result is `Right [<expected good>, Denied, <expected good2>]` — i.e. the whole call still
   returns `Right`, the bad pair is `Denied`, and the good pairs are unaffected. (Use whichever
   `EnError` the in-memory store can be made to produce; `ensureExhausted` already turns a
   multi-page intermediate read into `Left ResolutionLimitExceeded`, so a fixture object with
   more than `pageLimit` rows is one way to force a per-pair error without new machinery.)

### Milestone 2 — `POST /batch-check` with a max batch size (the HTTP endpoint)

**Scope.** Add `BatchCheckRequestWire`/`BatchCheckResponseWire`, a `"batch-check"` endpoint to
`EnAPI`, a `batchCheckHandler`, and a `maxBatchSize` field on `EnServer`, in
`en-servant/src/En/Servant/API.hs`. Create an `en-servant` test suite proving ordered decisions
and the oversize-400 rejection.

**What exists after.** The running service accepts `POST /batch-check` with a JSON body of
pairs + consistency + context, returns ordered decisions, and rejects a body whose pair list
exceeds `maxBatchSize` with HTTP 400.

**Design.**

Add the wire types alongside `CheckRequestWire` (after line ~198). A pair on the wire reuses the
existing `SubjectWire`/`ObjectRefWire`:

```haskell
data BatchCheckPairWire = BatchCheckPairWire
    { subject :: !SubjectWire
    , permission :: !Text
    , object :: !ObjectRefWire
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

data BatchCheckRequestWire = BatchCheckRequestWire
    { consistency :: !ConsistencyWire
    , context :: !CaveatContextWire
    , pairs :: ![BatchCheckPairWire]
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

newtype BatchCheckResponseWire = BatchCheckResponseWire
    { decisions :: [CheckDecisionWire]
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)
```

Export all three from the module's export list (the block at lines ~4–37) — add
`BatchCheckPairWire (..)`, `BatchCheckRequestWire (..)`, `BatchCheckResponseWire (..)`.

Add the endpoint to `EnAPI` (after the `"check"` line, ~87) so the route order is stable and the
client pattern can mirror it:

```haskell
        :<|> "batch-check" :> ReqBody '[JSON] BatchCheckRequestWire :> Post '[JSON] BatchCheckResponseWire
```

Add `maxBatchSize :: !Int` to `EnServer` (lines ~94–98). Wire `batchCheckHandler env` into
`server` (lines ~100–106) in the matching position, and add the binding.

The handler:

```haskell
batchCheckHandler :: EnServer -> BatchCheckRequestWire -> Handler BatchCheckResponseWire
batchCheckHandler env request = do
    -- Enforce the configured maximum batch size FIRST, before any decoding work.
    if length request.pairs > env.maxBatchSize
        then throwError (jsonError err400 "batch exceeds maximum batch size")
        else pure ()
    consistency <- either400 (consistencyFromWire request.consistency)
    context <- either400 (contextFromWire request.context)
    pairs <- traverseOr400 pairFromWire request.pairs
    decisions <-
        liftIO
            ( checkMany
                env.consistencyStore
                env.tupleStore
                env.graph
                consistency
                context
                pairs
            )
            >>= eitherEngine
    pure BatchCheckResponseWire{decisions = decisionToWire <$> decisions}
  where
    pairFromWire :: BatchCheckPairWire -> Either Text BatchPair
    pairFromWire wire =
        BatchPair
            <$> subjectFromWire wire.subject
            <*> ( if Text.null wire.permission
                    then Left "permission must not be empty"
                    else Right (RelationName wire.permission)
                )
            <*> objectRefFromWire wire.object
```

Notes: the size check runs **before** decoding so an oversized payload is rejected cheaply with
HTTP 400 (`err400` is already imported). `eitherEngine` maps the *outer* `Left EnError` (a
batch-wide failure, i.e. consistency resolution failed) to HTTP 500 — per-pair errors never
reach here because `checkMany` folds them into `Denied`. Import `checkMany` and `BatchPair` by
adding them to the `En.Check (...)` import (line ~65). Add `length`/`Text.null` only if not
already in scope (`Text` is imported; `length` is from Prelude).

Because `EnServer` gained a field, every construction site of `EnServer` must supply
`maxBatchSize`. Search the repo (`grep -rn "EnServer {" en-server en-servant` and the test
files) and set a default (1000) at each. If `en-server` has a config/CLI, thread an optional
override there; otherwise hard-code 1000 with a comment pointing at this plan's Decision Log.

**Create the `en-servant` test suite.** The package has no `test/` directory. Add a `test-suite`
stanza to `en-servant/en-servant.cabal` (mirror `en-core`'s stanza: `type: exitcode-stdio-1.0`,
`hs-source-dirs: test`, `main-is: Main.hs`, depending on `en-servant`, `en-core`, `base`,
`text`, `containers`, and — for exercising handlers in-process — `wai`, `warp`, `http-client`,
`servant-client`, `aeson`, or simply call the handler functions directly in `Handler`/`IO`
without a live server if that is simpler). The lightest test that proves the behavior calls
`batchCheckHandler` against an `EnServer` built from the same in-memory stores the `en-core`
test uses (you can re-create small fixtures inline; do not depend on `en-core`'s private test
module). Assertions:

- A request with two pairs of known outcome returns `BatchCheckResponseWire{decisions =
  [AllowedWire, DeniedWire]}` (or the appropriate wire decisions), in order.
- A request whose `pairs` length is `maxBatchSize + 1` causes the handler to throw a
  `ServerError` with `errHTTPCode == 400`. Running a handler returns `Handler a = ExceptT
  ServerError IO a`; run it with `runHandler` (from `Servant.Server.Internal.Handler`, or
  `Servant`'s `runHandler`) and assert the `Left ServerError{ errHTTPCode = 400 }`.

**Commands.**

```bash
cd /Users/shinzui/Keikaku/bokuno/en
cabal build en-servant
cabal test en-servant
```

**Acceptance (behavior).** `cabal test en-servant` passes, demonstrating: (a) a batch request
returns ordered decisions matching what individual checks would return; (b) an oversized batch
yields HTTP 400 (`errHTTPCode == 400`) with the JSON error body `{"error":"batch exceeds
maximum batch size"}`. If you stand up a live server (`warp`), `curl -s -X POST
http://localhost:PORT/batch-check -d @body.json` returns a JSON object `{"decisions":[...]}`
with one entry per input pair; posting `maxBatchSize + 1` pairs returns HTTP 400.

### Milestone 3 — `batchCheck` on the client

**Scope.** Add one field to `EnClient` and one binding in `enClient`, in
`en-client/src/En/Client.hs`, so HTTP consumers call `batchCheck` typed.

**What exists after.** `EnClient` has `batchCheck :: BatchCheckRequestWire -> ClientM
BatchCheckResponseWire`, and `enClient.batchCheck` is bound from `apiProxy`. Because the client
re-exports `En.Servant.API` (line ~5: `module En.Servant.API`), the wire types are already in
scope for consumers.

**Design.** Add the field to the record (lines ~15–21) in the **same position** the endpoint
occupies in `EnAPI` (right after `check`):

```haskell
data EnClient = EnClient
    { writeTuples :: WriteTuplesRequestWire -> ClientM WriteTuplesResponseWire
    , deleteTuples :: DeleteTuplesRequestWire -> ClientM WriteTuplesResponseWire
    , check :: CheckRequestWire -> ClientM CheckResponseWire
    , batchCheck :: BatchCheckRequestWire -> ClientM BatchCheckResponseWire
    , lookup :: LookupRequestWire -> ClientM LookupPageWire
    , expand :: ExpandRequestWire -> ClientM ExpandTreeWire
    }
```

Update `enClient` (lines ~23–37) to include `batchCheck` in the record and — critically — in the
`:<|>` destructuring pattern, **in the exact order of `EnAPI`** (writeTuples, deleteTuples,
check, batchCheck, lookup, expand). Servant derives the client tuple positionally; a mismatched
order compiles but calls the wrong endpoint, so the pattern order must equal the `EnAPI` order
exactly.

**Commands.**

```bash
cd /Users/shinzui/Keikaku/bokuno/en
cabal build en-client
cabal build all
cabal test all
```

**Acceptance (behavior).** `cabal build all` succeeds with the new field; `EnClient` now has a
`batchCheck` method. If a round-trip test exists or is added (a `warp` server + `runClientM`),
calling `enClient.batchCheck` with a request returns the same ordered decisions the server
computed. At minimum, the type checks and `cabal build all` / `cabal test all` stay green,
proving the client API type still matches the server API type (a Servant mismatch is a compile
error in the derived client).


## Concrete Steps

Run everything from the repository root unless noted.

```bash
cd /Users/shinzui/Keikaku/bokuno/en
```

Milestone 1 — engine:

```bash
# Edit en-core/src/En/Check.hs: export BatchPair (..) and checkMany; add BatchPair;
# add the memoized batch evaluator reusing the runCheck recursion.
# Edit en-core/test/Main.hs: add the four assertions (order, single-resolve, fewer-reads,
# fail-closed) plus the counting/error-injecting store wrappers.
cabal build en-core
cabal test en-core-interface-tests
```

Expected (abridged) transcript on success — the hand-rolled runner prints nothing per
assertion and exits 0:

```text
Build profile: -w ghc ... -O1
... (compilation) ...
Running 1 test suites...
Test suite en-core-interface-tests: RUNNING...
Test suite en-core-interface-tests: PASS
1 of 1 test suites passed
```

A failing assertion prints its label and the expected/actual values and exits non-zero, e.g.:

```text
Test suite en-core-interface-tests: FAIL
batch agrees with single checks
expected: Right [Allowed,Denied,Denied,Denied]
actual:   Right [Allowed,Denied,Denied,Allowed]
```

Milestone 2 — HTTP:

```bash
# Edit en-servant/src/En/Servant/API.hs: wire types, EnAPI endpoint, EnServer.maxBatchSize,
# server wiring, batchCheckHandler. Fix all EnServer construction sites for the new field.
# Add en-servant/test/Main.hs and the test-suite stanza in en-servant/en-servant.cabal.
cabal build en-servant
cabal test en-servant
```

Milestone 3 — client + full build:

```bash
# Edit en-client/src/En/Client.hs: add batchCheck field + binding (order matches EnAPI).
cabal build all
cabal test all
```

Expected final transcript:

```text
... 
all test suites passed
```


## Validation and Acceptance

The plan is complete when **all** of the following hold and `cabal build all` + `cabal test
all` are green:

1. **Engine batch agrees with single checks, in order.** The `en-core` order-agreement
   assertion passes: a mixed batch returns exactly the list of decisions the corresponding
   individual `check` calls return, position for position.

2. **Consistency resolved once.** The counting-consistency-store assertion reads `1` after a
   multi-pair batch. Evidence: the `IORef` counter `assertEqual`'d to `1`.

3. **Fewer storage reads than N checks.** The counting-tuple-store assertion shows
   `batchReads < independentReads` for an overlapping batch. This is the demonstrable
   work-sharing the headline acceptance requires — it proves the within-call memo is real, not
   cosmetic.

4. **Fail closed per pair.** The error-injection assertion shows a batch with one erroring pair
   returns `Right` overall, with that pair `Denied` and its batch-mates unaffected. No engine
   error aborts the batch into an accidental allow, and no error denies the whole batch.

5. **Oversized batch rejected.** The `en-servant` test shows a request with `maxBatchSize + 1`
   pairs produces a `ServerError` with `errHTTPCode == 400`.

6. **Ordered decisions over HTTP.** The `en-servant` test shows a within-limit batch returns
   `BatchCheckResponseWire{decisions}` with one wire decision per input pair, in input order.

7. **Client typed.** `EnClient` exposes `batchCheck`; `cabal build all` proves the derived
   client still matches the server API type.

Phrase every assertion as observed behavior (input → output), not as "a function was added."
The "fewer reads" and "resolved once" assertions are the ones that distinguish a *real* batch
from a thin loop over `check`; do not skip them.


## Idempotence and Recovery

Every edit is additive and re-runnable. Re-running `cabal build`/`cabal test` is safe and
idempotent. If a milestone half-lands:

- **Milestone 1 partial** (e.g. `checkMany` compiles but an assertion fails): the change is
  isolated to `En.Check` (additive — `check` is untouched) and `en-core/test/Main.hs`. Revert
  those two files to restore green; re-apply the memo logic. Because `check` is never modified,
  the rest of the system keeps working regardless of `checkMany`'s state.

- **Milestone 2 partial** (endpoint added but a handler/`EnServer` site missed): a missing
  `maxBatchSize` at a construction site is a *compile error*, which is the safe failure — the
  build fails loudly rather than running with a wrong default. Find every site with `grep -rn
  "EnServer {" en-server en-servant` (and any test files) and set `maxBatchSize = 1000`.

- **Milestone 3 partial** (client field/pattern mismatch): a wrong `:<|>` pattern order is a
  compile error if the field count differs; if the count matches but the order is wrong it
  compiles but misroutes — guard against this by keeping the `EnClient` record order, the
  `enClient` record order, and the `:<|>` pattern order all identical to the `EnAPI` order, and
  by adding a client round-trip test if practical.

No migrations, no destructive operations, no state to back up. The only shared-surface caution
is the `EnAPI` type and the `EnClient` derivation: they must agree, and the compiler enforces
agreement, so a green `cabal build all` is itself the recovery signal.


## Interfaces and Dependencies

**Libraries/modules used and why.** Only existing dependencies — no new packages for the engine
or client. `en-core` already depends on `containers` (for the memo `Map`) and `base` (for
`IORef` in tests, via the test stanza). `en-servant` already depends on `aeson`, `servant`,
`servant-server`, `text`, `containers`, `en-core`; the new test suite may add `wai`/`warp`/
`http-client`/`servant-client`/`hspec`-or-bare-`base` to `en-servant.cabal`'s test stanza only
(keep the library stanza's dependencies unchanged). `en-client` adds no dependency.

**Types and signatures that must exist at the end of each milestone.**

End of Milestone 1 (in `en-core/src/En/Check.hs`, exported):

```haskell
data BatchPair = BatchPair
    { subject :: !Subject
    , permission :: !RelationName
    , object :: !ObjectRef
    }
    deriving stock (Eq, Ord, Show)

checkMany ::
    (Monad m) =>
    ConsistencyStore m ->
    TupleStore m ->
    ReachabilityGraph ->
    Consistency ->
    CaveatContext ->
    [BatchPair] ->
    m (Either EnError [CheckDecision])
```

Contract: outer `Left EnError` iff consistency resolution fails; otherwise `Right decisions`
with `length decisions == length inputPairs`, `decisions !! i` is the decision for input pair
`i`, identical input pairs share one evaluation, a per-pair engine error yields `Denied` at that
pair's positions, and consistency is resolved exactly once.

End of Milestone 2 (in `en-servant/src/En/Servant/API.hs`, exported):

```haskell
data BatchCheckPairWire = BatchCheckPairWire
    { subject :: !SubjectWire, permission :: !Text, object :: !ObjectRefWire }

data BatchCheckRequestWire = BatchCheckRequestWire
    { consistency :: !ConsistencyWire, context :: !CaveatContextWire, pairs :: ![BatchCheckPairWire] }

newtype BatchCheckResponseWire = BatchCheckResponseWire { decisions :: [CheckDecisionWire] }
```

with `EnAPI` extended by
`"batch-check" :> ReqBody '[JSON] BatchCheckRequestWire :> Post '[JSON] BatchCheckResponseWire`
(immediately after the `"check"` route), `EnServer` gaining `maxBatchSize :: !Int`, and
`batchCheckHandler :: EnServer -> BatchCheckRequestWire -> Handler BatchCheckResponseWire`
enforcing `length pairs <= maxBatchSize` (else HTTP 400).

End of Milestone 3 (in `en-client/src/En/Client.hs`):

```haskell
data EnClient = EnClient
    { ...
    , batchCheck :: BatchCheckRequestWire -> ClientM BatchCheckResponseWire
    , ...
    }
```

with the `enClient` `:<|>` destructuring order equal to the `EnAPI` order.

**Cross-plan seams (by path only).**

- `checkMany` reuses the decision algebra that `En.Check.check` uses (today via the private
  `runCheck`). When EP-15
  (`docs/plans/15-generalize-the-caveat-evaluator-and-unify-the-decision-algebra.md`) extracts
  `En.Decision`, `checkMany` rides along because it shares `runCheck`'s recursion; rebase the
  memo onto `En.Decision` then.
- The within-call memo (`Map (Revision, Subproblem) CheckDecision`) shares its *key shape* with
  MasterPlan 2 EP-11's decision cache
  (`docs/plans/11-implement-authorization-decision-caching.md`). They are independent;
  `checkMany` must be correct with no EP-11 cache present.
- EP-17
  (`docs/plans/17-strengthen-the-lookup-spike-and-add-performance-regression-benchmarks.md`)
  will add a BatchCheck benchmark over `checkMany`; this plan only provides the function.
