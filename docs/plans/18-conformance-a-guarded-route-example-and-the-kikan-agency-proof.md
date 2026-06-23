---
id: 18
slug: conformance-a-guarded-route-example-and-the-kikan-agency-proof
title: "Conformance: a guarded route example and the kikan agency proof"
kind: exec-plan
created_at: 2026-06-23T16:37:01Z
master_plan: "docs/masterplans/3-harden-en-correctness-fixes-lookup-streaming-and-performance-benchmarks.md"
---

# Conformance: a guarded route example and the kikan agency proof

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`en` (縁, "the ties that bind") is a relationship-based access-control (ReBAC) toolkit: a
Haskell library that answers the question *may THIS subject do THIS to THIS object, given how
they are related*. It is a **toolkit, not an application** — it ships no built-in authorization
rules; each consuming project supplies its own **schema** (the object types, the relations
between them, and the rewrite rules that compute permissions) as a plain Haskell value, and the
engine is generic over that schema. The first consumer is **kikan**, a separate project; this
plan does not modify kikan, it *demonstrates how a consumer like kikan plugs its schema into
`en`* and proves the result is correct.

Two things are true in the repository today, and this plan changes both so that `en` is
**proven end-to-end on its first consumer's hardest real scenario**:

1. **The fail-closed gate exists but nothing uses it.** `en-servant` ships a helper,
   `requirePermission` (in `en-servant/src/En/Servant/Authorize.hs`), that a host web service is
   meant to place in front of a protected route so the route only runs when `en` says the caller
   is allowed. It is written correctly and fail-closed — it lets the request through **only** on
   an explicit `Allowed`, and turns every other outcome into an HTTP error (a definite "no" →
   `403 Forbidden`, a "maybe, need more facts" → `403`, and an internal engine failure →
   `500`). But no route in the repository is actually guarded by it, and no test exercises it.
   After this plan, a small example host service has a route guarded by `requirePermission`, and
   a test drives all four outcomes (allowed, denied, conditional, engine-error) and asserts the
   exact HTTP behavior. A novice can run that test and watch a guest request for an off-limits
   object come back `403`.

2. **The kikan agency scenario — the "day-one conformance case" the `en` spec names — is
   exercised at the engine level but is not packaged as a reusable conformance fixture, and its
   sensitivity-tier half is not yet proven.** The scenario: a team running a project in a `space`
   invites an outside **agency** (modeled as an `org` whose people are members) to collaborate on
   *that one project and nothing else*. The team grants the agency a single relationship —
   `(space:project-x, guest_org, org:acme)` — and the guests must then be able to *view* the
   subset of the project reachable from that space, must see only items at a guest-visible
   sensitivity tier (internal items stay hidden), must compute to `view` only (never `act` or
   `admin`), and must never inherit the team's internal relations. After this plan, the kikan
   schema lives as a **named, reusable fixture module inside `en`** (it belongs in `en`, the
   toolkit, not in kikan — it is the worked example of how a consumer supplies a schema), and two
   conformance tests prove the scenario: one via `check` (a guest *can* view a shared item,
   *cannot* view an internal item, *cannot* act), and one via `lookup` (the reachable label-set
   for a guest is *exactly* the shared subset and excludes internal spaces) — the read-filter
   shape the `en` spec §6 requires.

When this plan is complete, `cabal test all` passes, and the new tests demonstrably *fail before
and pass after* the work in each milestone, proving the behavior beyond mere compilation.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: Add an example host service with one route guarded by `requirePermission`, and a test
      suite proving all four outcomes (Allowed → 200, Denied → 403, Conditional → 403,
      engine-error → 500).
- [ ] M1: Add a GraphQL-resolver-style guarded variant — an `AuthorizationEnv`-driven object gate
      inside a resolver-shaped function — alongside the Servant route, proving the same four
      fail-closed outcomes, mirroring `docs/user/graphql-integration.md`.
- [ ] M2: Extract the kikan schema and tuple fixtures into a reusable module
      (`En.Conformance.Kikan`), extend it with shared-vs-internal visibility tiers, and add a
      `check`-based agency conformance test (guest views shared item; guest cannot view internal
      item; guest cannot act).
- [ ] M3: Add a `lookup`-based agency conformance test proving the reachable label-set for a
      guest is exactly the shared subset (and excludes internal spaces) — the §6 read-filter
      shape.
- [ ] Finalize against EP-15 (generic caveat evaluator) and EP-16 (streaming lookup) once those
      land; record the reconciliation in the Decision Log.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **A kikan-shaped schema and most of the agency `check` scenario already exist** — as *private*
  fixtures inside `en-core/test/Main.hs` (the `kikanSchema` value, `fixtureTuples`, and
  assertions like "agency org member can view guest space" and "guest org view does not grant
  act"). They are not a reusable module, and the *sensitivity-tier* half (a shared item visible
  to guests vs. an internal item hidden from them) is not yet proven, nor is the `lookup`
  read-filter exclusion of internal spaces. This plan promotes those fixtures into a shared
  conformance module and completes the missing halves rather than inventing the schema from
  scratch. _(2026-06-23)_

- **`requirePermission` can be tested without a running web server.** A Servant handler is a
  `newtype Handler a = Handler (ExceptT ServerError IO a)`, and `Servant.runHandler ::
  Handler a -> IO (Either ServerError a)` runs one and returns either the `ServerError` (whose
  `errHTTPCode :: Int` field is `403`, `500`, …) or the success value. So the fail-closed test
  can call `requirePermission` directly and assert on `errHTTPCode`, with no `warp`/HTTP-client
  dependency. (A separate, optional end-to-end transcript via a real server is described for
  human demonstration, but the automated proof uses `runHandler`.) _(2026-06-23)_


## Decision Log

Record every decision made while working on the plan.

- Decision: The kikan schema fixture lives in `en` (a new `En.Conformance.Kikan` module under
  `en-core`), not in the kikan repository.
  Rationale: `en` is the toolkit and kikan is a consumer; the fixture's *purpose* is to
  demonstrate, inside `en`'s own test/example surface, how a consumer supplies its schema and
  how the agency scenario is proven. Putting it in kikan would couple `en`'s conformance proof to
  another repository's build. This matches MasterPlan 3 Integration Point 6, which assigns the
  kikan `Schema` fixture and guarded-route example to this plan.
  Date: 2026-06-23

- Decision: The conformance suite is *drafted now* against the current engine, but its final form
  is *reconciled after* EP-15 and EP-16 land.
  Rationale: The agency delegation uses an autonomy-/time-caveated relation, whose evaluation is
  generalized by EP-15 (`docs/plans/15-generalize-the-caveat-evaluator-and-unify-the-decision-algebra.md`),
  and the read-filter proof exercises the streaming `lookup` from EP-16
  (`docs/plans/16-make-lookup-streaming-with-resumable-cursors-and-a-deadline-budget.md`). MasterPlan 3's
  Dependency Graph places this plan in Wave 3 as a soft dependent of both: it can begin and be
  drafted in Wave 1, but should be *finalized* once those land so the conformance measures the
  fixed engine. If this plan lands first, its caveat assertions encode the engine's *current*
  hardcoded `within_autonomy` behavior and are revisited when EP-15 generalizes it; if EP-16
  changes the `lookup` cursor/state contract, the read-filter test's expected `LookupState` is
  updated to match (Integration Point 3).
  Date: 2026-06-23

- Decision: The agency scenario mirrors kikan contract C13 (the en/consumer boundary) exactly:
  guest-as-relationship (`guest_org`), reachability-scoped subset, and sensitivity-as-container
  (a `visibility_class` object), with no policy language.
  Rationale: C13 (`shinzui/kikan → docs/architecture/evolution/contracts.md`) is the authoritative
  statement of the scenario; the `en` spec §9 names it the day-one conformance case. Modeling
  sensitivity as a *container relation* (not an intersection/exclusion and not a per-item
  attribute) keeps `lookup` a pure reachability query, which is the spec §6 requirement and the
  reason `lookup` stays bounded.
  Date: 2026-06-23

- Decision: The guarded-route example is a *new* tiny `executable + test-suite` target named
  `en-example` (under a new top-level package directory), not an extension of `en-server`.
  Rationale: `en-server` is the thin standalone form of `en` (it *serves* the `en` API). The
  thing this milestone needs to demonstrate is a *host application* that *consumes* `en` to guard
  *its own* route — a different role. Keeping it a separate package keeps `en-server` focused and
  gives the conformance test a clean home. (An alternative — adding a guarded route to
  `en-server` itself — was rejected because `en-server` deliberately serves only the bare `en`
  API and pulls in PostgreSQL; the example must run with an in-memory store so a novice can run it
  with no database.)
  Date: 2026-06-23
- Decision: Milestone 1 also demonstrates the object gate in a GraphQL-resolver shape (a
  resolver-style function using a request-scoped `AuthorizationEnv`), not only as a Servant route.
  Rationale: kikan runs a GraphQL gateway in front of all services
  (`docs/user/graphql-integration.md`), so the realistic enforcement site is a resolver. Proving the
  same fail-closed behavior through a resolver-shaped function keeps the GraphQL pattern honest without
  adding a GraphQL server dependency. The native `BatchCheck` the field-capability path needs is owned
  by EP-19 (`docs/plans/19-add-batchcheck-for-graphql-field-capability-and-candidate-filtering.md`).
  Date: 2026-06-23


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you know nothing about this repository. Read it before touching code.

**What `en` is.** `en` is a Haskell project (a Cabal multi-package workspace) that implements
relationship-based access control. You decide who-can-do-what by writing down **relationship
tuples** of the form `(object, relation, subject)` — for example `(space:project-x, owner,
user:alice)` reads "alice is the owner of the space project-x". Permissions like `view` or `act`
are *not* stored directly; they are **computed** from relations by **rewrite rules** in the
schema (for example "you may `view` a space if you are its `owner`, or a `member`, or a member of
a guest org granted access, or you can view its parent space"). To ask a question you call
`check` (a yes/no/maybe for one object) or `lookup` (list the objects of a type a subject can
reach — the "read filter"). This plan does not change the engine; it *uses* it.

**The packages you will touch, by full path.** The workspace root is
`/Users/shinzui/Keikaku/bokuno/en`. Its `cabal.project` lists the packages. The relevant ones:

- `en-core/` — the engine, with no web or database dependencies. Key modules:
  - `en-core/src/En/Schema.hs` — the `Schema` type: object types, their `Relation`s, the
    `Rewrite` algebra (`This`, `ComputedUserset`, `TupleToUserset` (an "arrow"), `Union`,
    `Intersection`, `Exclusion`, `Caveated`), and `CaveatDefinition`. `validate :: Schema ->
    Either EnError ()` checks a schema; `schemaHash` fingerprints it.
  - `en-core/src/En/Schema/Builder.hs` — ergonomic constructors (`build`, `buildWithCaveats`,
    `object`, `relation`, `permission`, `subject`, `userset`, `this`, `computed`, `arrow`,
    `anyOf`, `allOf`, `minus`, `caveated`, `caveat`, `parameter`) that build the same `Schema`
    type. The fixture uses these.
  - `en-core/src/En/Tuple.hs` — `ObjectRef` (`objectType` + `objectId`), `Subject` (either
    `SubjectId ObjectRef` for a concrete subject like `user:alice`, or `SubjectSet ObjectRef
    RelationName` for a *userset* like `org:acme#member` meaning "every member of org acme"),
    `Tuple`, and the caveat value/payload/context types.
  - `en-core/src/En/Check.hs` — `check :: ... -> m (Either EnError CheckDecision)` where
    `CheckDecision = Allowed | Denied | Conditional [CaveatObligation]`.
  - `en-core/src/En/Lookup.hs` — `lookup :: ... -> m (Either EnError LookupPage)` where a
    `LookupPage` has `objects :: [LookupObject]` (each carrying an `object :: ObjectRef` and its
    `decision`) and a `state :: LookupState` (`LookupExhausted`, `LookupHasMore cursor`, or
    `LookupTruncated cursor`).
  - `en-core/src/En/Reachability.hs` — `compile :: Schema -> Either EnError ReachabilityGraph`
    turns a schema into the graph `check`/`lookup` traverse.
  - `en-core/src/En/Effect/TupleStore.hs` — `TupleStore m`, a record of functions the engine
    reads/writes tuples through, so a test can supply an in-memory implementation.
  - `en-core/src/En/Effect/ConsistencyStore.hs` — `ConsistencyStore m`, which resolves a
    consistency request to a concrete `Revision`; its `resolveConsistency` returns
    `m (Either EnError ResolvedConsistency)`, so a test can make it return `Left` to simulate an
    engine error.
  - `en-core/test/Main.hs` — the existing engine test. **It already contains a kikan-shaped
    `kikanSchema`, an in-memory `tupleStore`/`consistencyStore`, and `fixtureTuples`, plus
    assertions for much of the agency `check` scenario.** This plan promotes those into a reusable
    module and completes them. Read it; you will move code out of it.
- `en-servant/` — the `en` HTTP API as a Servant type, plus `requirePermission`. Key modules:
  - `en-servant/src/En/Servant/Authorize.hs` — `requirePermission`. Its body (lines ~38–55) is:
    run `check`; `>>= eitherEngine` (which turns an engine `Left` into `throwError err500`); then
    `case decision of Allowed -> pure (); Denied -> throwError err403; Conditional _ -> throwError
    err403`. `AuthorizationEnv` bundles the `consistencyStore`, `tupleStore`, and `graph`.
  - `en-servant/src/En/Servant/API.hs` — the wire API; not central to this plan but the example
    server reuses its `app`-building pattern.
- `en-server/` — the standalone service. `en-server/app/Main.hs` builds a `demoSchema` (lines
  ~75–93: a trivial two-object schema) and serves the bare `en` API over PostgreSQL. This plan
  does **not** modify it (see the Decision Log); the example host is a separate package.

**Terms defined.**

- *Fail-closed*: the gate denies unless it has an explicit, positive reason to allow. Concretely,
  `requirePermission` returns success only for `Allowed`; everything else (a definite `Denied`, a
  `Conditional` that needs more context, or an engine error) becomes an HTTP error. The opposite,
  *fail-open*, would let a request through on uncertainty — a security hole.
- *guest_org*: a relation a team puts on a `space` to invite an outside org. The grant
  `(space:project-x, guest_org, org:acme)` plus the rewrite "you may view a space if you are a
  member of its guest org" gives every member of `org:acme` `view` on `project-x` — with **no
  per-person grant** — and *only* `view`: the rewrite for `act`/`admin`/`audit` does not mention
  `guest_org`, so guests never reach those. This is the "groups of groups" userset mechanism.
- *visibility class*: a coarse sensitivity tier modeled as an *object* (e.g.
  `visibility_class:shared`, `visibility_class:internal`) that items "belong to" via a relation.
  An item is visible to a viewer if the viewer is a `viewer` of the item's visibility class.
  Modeling sensitivity as a container *relation* (not as an intersection or a per-item attribute)
  keeps `lookup` a pure reachability query (spec §6/kikan C13).
- *userset*: a subject that is itself "all members of some relation," written `object#relation`
  (the `SubjectSet` constructor). `(space:s, member, org:acme#member)` means "every member of org
  acme is a member of space s".
- *autonomy-/time-caveated delegation*: a delegation tuple `(intention:42, delegate, user:carol)`
  carrying a **caveat** — a small bounded predicate — that says "this delegation only counts if
  the requested autonomy level is at most `act` and the current time is before `until`". The
  engine's `check` evaluates the caveat against request-time context (`CaveatContext`). Today this
  is the hardcoded `within_autonomy` caveat in `En.Check`/`En.Lookup`; EP-15 generalizes it.

**Tooling.** The toolchain is GHC 9.12.4 via `cabal` (the `cabal.project` pins `with-compiler:
ghc-9.12.4`). Tests are plain `exitcode-stdio-1.0` executables that `fail` on a bad assertion —
the repo does **not** use `tasty` or `hspec`; it uses hand-rolled `assertEqual`/`assertBool`
helpers (see the bottom of `en-core/test/Main.hs`). Follow that convention so you add no new
test-framework dependency.


## Plan of Work

The work is three milestones, each independently verifiable. Milestone 1 (the guarded-route
example and fail-closed proof) is fully independent and may be done first. Milestones 2 and 3
share the conformance fixture: M2 creates it and proves the agency scenario via `check`; M3 adds
the `lookup` read-filter proof on the same fixture.

### Milestone 1 — A guarded route, proven fail-closed

**Scope.** Create a new package `en-example` containing (a) a tiny host web service with exactly
one protected route that calls `requirePermission` before doing its work, wired to an in-memory
`en` store so it runs with no database, and (b) a test suite that calls `requirePermission`
directly via `Servant.runHandler` and asserts the HTTP outcome for each of the four paths.

**What exists at the end.** A `en-example/` package with:
- `en-example/src/En/Example/Host.hs` — the example host: a one-object schema (`document` with a
  `viewer` relation and a `view` permission), an in-memory `TupleStore`/`ConsistencyStore`
  builder, an `AuthorizationEnv`, a Servant API `type GuardedAPI = "documents" :> Capture "id"
  Text :> Get '[JSON] DocumentView`, and a handler that calls `requirePermission env
  MinimizeLatency emptyContext subject (RelationName "view") (document docId)` and only returns
  the document body when the gate passes.
- `en-example/test/Main.hs` — the fail-closed proof (see Concrete Steps for the exact assertions).
- `en-example/en-example.cabal` — a `library`, an `executable en-example` (so a human can `curl`
  it), and a `test-suite en-example-tests`.
- An entry added to `cabal.project` `packages:`.

**Commands.** From the workspace root: `cabal build en-example` then `cabal test en-example`.

**Acceptance (observable behavior).** `cabal test en-example` passes, and the test proves:
a request for a document the subject *is* a viewer of returns success (the handler ran); a
request for a document the subject is *not* a viewer of fails with HTTP `403`; a request whose
relation is gated by an unsatisfied caveat (a `Conditional` decision) fails with HTTP `403`; and
a request made against a store whose consistency resolution returns `Left` (a simulated engine
error) fails with HTTP `500`. Optionally, running `cabal run en-example` and issuing the two
`curl` commands in Concrete Steps shows the same allow/deny behavior over real HTTP.

**GraphQL-resolver variant (the same gate, resolver shape).** kikan will put a GraphQL gateway in
front of all services (see `docs/user/graphql-integration.md`), so the object gate most often runs
inside a *resolver*, not a Servant route. Add a second small demonstration in `en-example`: a plain
function with the shape of a GraphQL field resolver — for example `resolveDocument :: AuthorizationEnv
-> Subject -> DocumentId -> IO (Either Forbidden DocumentView)` — that calls the request-scoped
authorization environment's object gate (`check`) before loading the object and returns a fail-closed
forbidden/empty on `Denied`, `Conditional`, or engine error, exactly as the Servant route does. The
test suite asserts the same four outcomes through this resolver shape. This proves the GraphQL
integration pattern is real code, not only documentation; it deliberately does not pull in a GraphQL
server library — the gate is library-agnostic, just `en` calls in the resolver's monad. (The native
`BatchCheck` that the GraphQL field-capability path needs is a separate plan, EP-19,
`docs/plans/19-add-batchcheck-for-graphql-field-capability-and-candidate-filtering.md`; this milestone
only demonstrates the single-object gate.)

### Milestone 2 — The kikan schema fixture and the agency `check` proof

**Scope.** Move the kikan schema, the in-memory stores, and the agency tuples out of
`en-core/test/Main.hs` into a new reusable module `En.Conformance.Kikan` (exported from a new
`en-core` library component or the existing library — see Concrete Steps), keeping the existing
engine test passing by importing from it. Extend the fixture with two visibility classes and the
tuples that place a *shared* item in the guest-visible class and an *internal* item in the
internal class. Add a conformance test that proves, via `check`, the three agency assertions.

**What exists at the end.**
- `en-core/src/En/Conformance/Kikan.hs` — exports `kikanSchema :: Schema`, `kikanGraph ::
  ReachabilityGraph` (the compiled schema), `inMemoryStores :: [Tuple] -> (ConsistencyStore IO,
  TupleStore IO)` (or equivalent), the agency `fixtureTuples :: [Tuple]`, and named `ObjectRef`
  values for the scenario (the team space, the agency org, the agency user, a shared item, an
  internal item, the two visibility classes). The schema is the C13/spec-§9 shape: object types
  `user`, `org`, `space`, `intention`, `visibility_class`; relations `member` (on `org` and
  `space`, the latter accepting the `org#member` userset), `owner`, `guest_org` (`org` → `space`,
  view-only), `parent` (space nesting), `visibility_class` (item → its class) and `viewer` (who
  may see a class); permissions `view`, `act`, `audit`; and an `intention.delegate` relation
  carrying the autonomy-/time caveat `within_autonomy`.
- `en-core/test/Main.hs` — unchanged in behavior, now importing the fixture from
  `En.Conformance.Kikan` instead of defining it inline (it keeps its existing assertions).
- A new conformance test (a `test-suite en-core-conformance` in `en-core/en-core.cabal`, or a new
  section appended to `en-core/test/Main.hs` — prefer a separate suite so a failure is legible)
  with the agency `check` assertions.

**Commands.** `cabal build en-core` then `cabal test en-core`.

**Acceptance.** `cabal test en-core` passes, proving via `check`: an agency user (a member of the
guest org) gets `Allowed` for `view` on a *shared* item reachable from the shared space; the same
user gets `Denied` for `view` on an *internal* item; and the same user gets `Denied` for `act` on
the shared space (guest computes to `view` only). A non-guest outsider gets `Denied` for `view`
on everything in the project.

### Milestone 3 — The agency `lookup` read-filter proof

**Scope.** On the same `En.Conformance.Kikan` fixture, add a conformance test that calls `lookup`
to compute *the set of objects a guest can reach*, and asserts it is exactly the shared subset —
the §6 read-filter shape (a small reachable label-set the consumer would then apply as a SQL
filter over its own store), never an enumeration of the consumer's data.

**What exists at the end.** Additional assertions in the conformance suite from M2 that:
- `lookup(agencyUser, view, space)` returns exactly the shared space(s) reachable from the
  guest grant and **not** the team's internal spaces.
- `lookup(agencyUser, view, visibility_class)` (or `lookup` over the item type, depending on how
  the fixture wires items — see Concrete Steps) returns exactly the guest-visible class / shared
  items and excludes the internal class / internal items.
- A guest `lookup` for `act` returns the empty set (guests cannot act).

**Commands.** `cabal build en-core` then `cabal test en-core`.

**Acceptance.** `cabal test en-core` passes, proving the guest's reachable label-set is exactly
`{shared subset}` and excludes internal spaces/classes, and that the guest can reach nothing via
`act`. Because the result is the small label-set and not a per-item enumeration, this demonstrates
the read-filter pattern the spec §6 and kikan C13 require.


## Concrete Steps

Run everything from the workspace root `/Users/shinzui/Keikaku/bokuno/en` unless stated otherwise.
Begin by confirming a clean baseline:

```bash
cd /Users/shinzui/Keikaku/bokuno/en
cabal build all
cabal test all
```

You should see the existing `en-core-interface-tests` pass. (The `en-postgres` integration tests
require a PostgreSQL/ephemeral-pg setup; if they are not runnable in your environment, scope your
runs to the packages this plan touches, e.g. `cabal test en-core en-example`.)

### Milestone 1 steps

1. **Create the package directory and cabal file.** Create `en-example/en-example.cabal`. Model
   it on `en-servant/en-servant.cabal` (same `common warnings`/`common shared` stanzas, same
   `default-extensions`). It declares a `library` exposing `En.Example.Host` and depending on
   `base`, `aeson`, `containers`, `text`, `time`, `servant`, `servant-server`, `en-core`,
   `en-servant`; an `executable en-example` (main `app/Main.hs`) additionally depending on `warp`;
   and a `test-suite en-example-tests` (type `exitcode-stdio-1.0`, main `test/Main.hs`) depending
   on `base`, `containers`, `text`, `time`, `servant`, `servant-server`, `en-core`, `en-servant`,
   `en-example`.

2. **Register the package** by adding `en-example` to the `packages:` list in
   `cabal.project` (append a line; do not reorder existing entries).

3. **Write `en-example/src/En/Example/Host.hs`.** It defines:
   - `exampleSchema :: Schema` — one object type, built with `En.Schema.Builder`:
     ```haskell
     exampleSchema =
         Schema.build
             [ Schema.object "user" []
             , Schema.object
                 "document"
                 [ Schema.relation "viewer" [Schema.subject "user"] Schema.this
                 , Schema.permission "view" (Schema.computed "viewer")
                 ]
             ]
     ```
   - An in-memory `TupleStore IO` and `ConsistencyStore IO`. **Copy the in-memory store shape
     verbatim from the bottom of `en-core/test/Main.hs`** (`inMemoryTupleStore`, `pageTuples`,
     `tupleRow`, `consistencyStore`, `testRevision`) — they have no test-only dependencies. For
     the engine-error case the test needs a *failing* `ConsistencyStore`, so also export a
     `failingConsistencyStore :: ConsistencyStore IO` whose `resolveConsistency = \_ -> pure (Left
     (En.Error.StoreError "injected"))`.
   - `mkEnv :: ConsistencyStore IO -> TupleStore IO -> AuthorizationEnv` building the
     `AuthorizationEnv{consistencyStore, tupleStore, graph}` where `graph` is `either (error .
     show) id (compile exampleSchema)`.
   - The guarded route and handler. The handler calls
     ```haskell
     requirePermission env MinimizeLatency emptyContext (SubjectId (userRef caller))
                       (RelationName "view") (documentRef docId)
     ```
     where `emptyContext = CaveatContext Map.empty`, then returns the document view. Expose the
     handler as a Servant `Server` and `app :: AuthorizationEnv -> Subject -> Application` for the
     optional `curl` demo, and **also expose the bare handler action** (e.g. `viewDocument :: Env
     -> Subject -> Text -> Handler DocumentView`) so the test can call it through `runHandler`
     without HTTP.
   - For the `Conditional` path the host needs a relation whose rewrite is `Caveated`. Add a
     second object type to `exampleSchema`, e.g. `secret` with a relation `reader` whose rewrite
     is `Schema.caveated "needs_clearance" Schema.this` and a caveat `needs_clearance` with one
     parameter; a tuple granting `reader` under that caveat, evaluated with an *empty* context,
     yields `Conditional` (the engine reports a missing-context obligation rather than `Allowed`).
     Confirm the exact `Conditional`-producing shape against `En.Check.evaluateTupleCaveat` /
     `evaluateRewriteCaveat` — with no matching context key the current engine returns
     `Conditional [...]`, which is what the test asserts produces a `403`.

4. **Write `en-example/test/Main.hs`.** Use the repo's hand-rolled assertion style. The core
   helper:
   ```haskell
   httpCodeOf :: Handler a -> IO (Maybe Int)
   httpCodeOf h = either (Just . errHTTPCode) (const Nothing) <$> runHandler h
   ```
   (`runHandler` and `errHTTPCode` come from `Servant`.) Then four assertions, each calling the
   guarded handler with a fixture that forces one outcome:
   - **Allowed → 200:** a store containing `(document:doc1, viewer, user:alice)`; calling the
     handler as `user:alice` for `doc1` returns `Nothing` from `httpCodeOf` (the handler ran; no
     error). Assert `Nothing`.
   - **Denied → 403:** the same store; calling as `user:bob` (no viewer tuple) for `doc1`. Assert
     `Just 403`.
   - **Conditional → 403:** a store granting `(secret:s1, reader, user:alice)` under
     `needs_clearance`; calling the secret-guarded handler as `user:alice` with an empty context.
     Assert `Just 403`.
   - **Engine error → 500:** build the env with `failingConsistencyStore`; any call. Assert
     `Just 500`.

5. **Build and test:**
   ```bash
   cabal build en-example
   cabal test en-example
   ```
   Expected: the suite prints nothing and exits 0 (the hand-rolled harness only emits on failure).
   To *see it work before the route is wired*, temporarily change the handler to `pure
   documentView` without `requirePermission`; the Denied/Conditional/engine-error assertions then
   fail (they get `Nothing`/`Just 200` instead of `403`/`500`), proving the guard is load-bearing.
   Revert.

6. **(Optional) Human transcript.** Run the server and exercise it:
   ```bash
   cabal run en-example
   # in another shell, with the example seeded so user "alice" is a viewer of doc1:
   curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/documents/doc1   # expect 200
   curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/documents/secret # expect 403
   ```
   (How the caller identity is supplied — a header, a fixed demo subject — is the host's choice;
   the simplest demo fixes a single demo subject and varies the document. State your choice in a
   comment in `Host.hs`.)

### Milestone 2 steps

1. **Create `en-core/src/En/Conformance/Kikan.hs`.** Move the following *out of*
   `en-core/test/Main.hs` and into this module, exporting them: `kikanSchema`; the named
   `ObjectRef` values (`user`, `bob`, `agencyUser`, `space`, `guestSpace`, `usersetMemberSpace`,
   `childSpace`, `auditedSpace`, `exclusionSpace`, `guestOrg`, `intention`, etc.); `fixtureTuples`;
   `autonomyCaveat`; the caveat contexts (`requestContext`, `adminContext`, `missingAutonomyContext`,
   `expiredContext`); and the in-memory store builders (`inMemoryTupleStore`, `pageTuples`,
   `tupleRow`, `consistencyStore`, `testRevision`). Add `kikanGraph :: ReachabilityGraph =
   either (error . show) id (compile kikanSchema)`. Keep `En.Schema.Builder` as the construction
   path. **Add the module to `exposed-modules` in `en-core/en-core.cabal`.**

2. **Update `en-core/test/Main.hs`** to `import En.Conformance.Kikan` and delete the now-duplicated
   local definitions. Re-run `cabal test en-core` to confirm the existing assertions still pass
   (they now run against the extracted fixture). This is a pure refactor with no behavior change —
   if the existing test still passes, the extraction is faithful.

3. **Extend the fixture with sensitivity tiers.** In `En.Conformance.Kikan`:
   - The schema already has a `visibility_class` object type with a `viewer` relation and the
     `space.view` rewrite already includes `Schema.arrow "visibility_class" "viewer"`. Confirm the
     `space` object also has a `visibility_class` relation (item → its class). If items are
     `space`s in this fixture, this is already present; if you introduce a distinct item object
     type (e.g. `activity`-shaped `intention`s), give it a `visibility_class` relation and a
     `view` permission that arrows through it. **Prefer reusing `space` as the item** to keep the
     fixture minimal and aligned with the existing assertions.
   - Add two `ObjectRef`s: `sharedClass = visibility_class:shared` and `internalClass =
     visibility_class:internal`.
   - Add tuples so a guest can reach `sharedClass` but not `internalClass`. Concretely: make the
     agency user (or the guest org userset) a `viewer` of `sharedClass`
     (`(visibility_class:shared, viewer, org:acme#member)` or `(…, viewer, user:agency-alice)`),
     and make a `sharedItem` space carry `(sharedItem, visibility_class, visibility_class:shared)`
     and an `internalItem` space carry `(internalItem, visibility_class, visibility_class:internal)`.
     Do **not** grant the guest `viewer` on `internalClass`. Now `view` on `sharedItem` is
     reachable for the guest via the visibility-class arrow, while `view` on `internalItem` is
     not (the guest is not a member, owner, guest_org of it, nor a viewer of its class).
   - Keep the existing `guest_org` grant `(guestSpace, guest_org, guestOrg)` and
     `(guestOrg, member, agencyUser)` so the reachability-scoped half (guest reaches what is
     reachable from the shared space) still holds.

4. **Add the conformance suite.** Add to `en-core/en-core.cabal` a new
   `test-suite en-core-conformance` (type `exitcode-stdio-1.0`, `hs-source-dirs: conformance`,
   `main-is: Main.hs`, depending on `base`, `containers`, `text`, `time`, `en-core`). In
   `en-core/conformance/Main.hs`, import `En.Conformance.Kikan`, reuse the hand-rolled assertion
   helpers, and assert (using `requestContext`, which supplies a benign autonomy/time context):
   ```text
   "guest can view a shared item"         Right Allowed  = check … (SubjectId agencyUser) view sharedItem
   "guest cannot view an internal item"   Right Denied   = check … (SubjectId agencyUser) view internalItem
   "guest cannot act on the shared space" Right Denied   = check … (SubjectId agencyUser) act  guestSpace
   "non-guest cannot view the project"    Right Denied   = check … (SubjectId bob)        view sharedItem
   ```

5. **Prove fail-before/pass-after.** Before adding the `internalItem`/`internalClass` tuples, the
   "guest cannot view an internal item" assertion cannot be written meaningfully (there is no
   internal item). After adding them, run:
   ```bash
   cabal build en-core
   cabal test en-core
   ```
   To demonstrate the assertion is load-bearing, temporarily add a tuple granting the guest
   `viewer` on `internalClass`; the "cannot view an internal item" assertion then fails (it gets
   `Allowed`). Remove that tuple.

### Milestone 3 steps

1. **Add `lookup` assertions to `en-core/conformance/Main.hs`.** Import `En.Lookup` and assert
   (the exact `LookupPage` shape follows the existing `lookup` assertions in
   `en-core/test/Main.hs` — a `LookupPage{objects = [...], state = LookupExhausted}` with objects
   sorted by `ObjectRef`, each carrying `decision = Allowed`):
   ```text
   "guest view reaches exactly the shared subset"
       Right (page [allowed guestSpace, allowed sharedItem] LookupExhausted)
       = lookup … (SubjectId agencyUser) view (ObjectType "space") …
   "guest view excludes internal spaces"
       (the page above must NOT contain internalItem)
   "guest act reaches nothing"
       Right (page [] LookupExhausted)
       = lookup … (SubjectId agencyUser) act (ObjectType "space") …
   ```
   Compute the *exact* expected object list by first running `lookup` and reading what the engine
   returns (the set is small and deterministic — objects come back sorted), then encode that as
   the expectation. The assertion's *meaning* is the spec §6 read-filter: this small set is what a
   consumer (kawa) would turn into `… WHERE space IN (:reachable)`, never an enumeration of items.

2. **Build and test:**
   ```bash
   cabal build en-core
   cabal test en-core
   ```
   Expected: the conformance suite passes, and the "excludes internal spaces" check confirms
   `internalItem` is absent from the guest's reachable set.

3. **Demonstrate the read-filter is bounded.** Add a comment in `conformance/Main.hs` noting that
   the returned set is the reachable *label-set* (a handful of spaces/classes), and that the
   consumer applies it as a predicate over its own store — so `lookup` never enumerates the
   consumer's high-cardinality data (spec §6, kikan C13). No code is needed for this beyond the
   assertion that the set is exactly the shared subset.

### Finalization against EP-15 and EP-16

When EP-15 (`docs/plans/15-generalize-the-caveat-evaluator-and-unify-the-decision-algebra.md`) lands,
the `within_autonomy` caveat is no longer hardcoded; re-check the delegation assertions in the
existing engine test (they may need their `CaveatContext` keys renamed to whatever the generic
evaluator reads from `CaveatDefinition`). When EP-16
(`docs/plans/16-make-lookup-streaming-with-resumable-cursors-and-a-deadline-budget.md`) lands, the
`lookup` cursor becomes a real resumable token; update any `LookupState` expectation in the M3
assertions to the new cursor contract (Integration Point 3 of MasterPlan 3). Record both
reconciliations in the Decision Log and tick the final Progress item.


## Validation and Acceptance

The change is validated by tests that fail before and pass after, plus an optional HTTP transcript.

**Milestone 1.** `cabal test en-example`. The suite asserts: `httpCodeOf (allowed call) == Nothing`
(handler ran), `== Just 403` for the denied call, `== Just 403` for the conditional call, and
`== Just 500` for the engine-error call. The load-bearing-ness of the guard is demonstrated by
temporarily removing `requirePermission` and watching three assertions fail. Optional HTTP proof:
`curl …/documents/doc1` returns `200`, `curl …/documents/secret` returns `403`.

**Milestone 2.** `cabal test en-core`. The refactor is validated by the *existing*
`en-core-interface-tests` continuing to pass against the extracted fixture. The new
`en-core-conformance` suite asserts (via `check`): guest views a shared item (`Allowed`); guest
cannot view an internal item (`Denied`); guest cannot act on the shared space (`Denied`); a
non-guest cannot view the project (`Denied`). Load-bearing-ness is demonstrated by temporarily
granting the guest `viewer` on the internal class and watching "cannot view an internal item"
fail.

**Milestone 3.** `cabal test en-core`. The conformance suite additionally asserts (via `lookup`):
the guest's reachable `space` set under `view` is exactly the shared subset and excludes
`internalItem`; the guest's reachable set under `act` is empty. This is the §6 read-filter shape —
a bounded label-set, not an enumeration.

**Whole-plan acceptance.** From the workspace root, `cabal build all` succeeds and `cabal test
en-core en-example` passes (and `cabal test all` passes wherever the PostgreSQL-backed
`en-postgres` integration tests can run). A reader can point to: a `403` for a guest's
off-limits request, a `500` for an engine fault, and a guest `lookup` that returns exactly the
shared spaces and no internal ones.


## Idempotence and Recovery

Every step is additive and safe to repeat. `cabal build` and `cabal test` are idempotent. Adding
`en-example` to `cabal.project` is a one-line append; running it twice is harmless (cabal
deduplicates, or you simply see the line already present). The Milestone 2 refactor (moving
fixtures from `en-core/test/Main.hs` into `En.Conformance.Kikan`) is the one step with a "halfway"
risk: if you move a definition but forget to delete the original, you get a duplicate-binding
compile error — the fix is to delete the inline copy and import from the module. Because the
extracted fixture is validated by the *existing* engine test continuing to pass, a faithful
extraction is self-checking: if `en-core-interface-tests` still passes, the move was correct; if
it fails, you changed behavior and should diff against the original definitions. No step deletes
or migrates data, touches the database schema, or modifies `en-server`. To roll back any
milestone, `git checkout` the affected files and remove the `en-example` line from `cabal.project`.


## Interfaces and Dependencies

**Libraries and why.** `en-core` (the engine: `check`, `lookup`, `compile`, the `Schema` and
`Tuple` types, the store effects) — the substrate everything proves. `en-servant` (provides
`requirePermission` and `AuthorizationEnv`) — the gate Milestone 1 exercises. `servant` /
`servant-server` (the `Handler` monad, `runHandler`, `errHTTPCode`, the API combinators) — to host
and test the guarded route. `warp` (only in the `en-example` executable) — to optionally serve the
demo over HTTP. `containers`, `text`, `time` — for the in-memory fixtures. No new test framework is
introduced; the repo's hand-rolled `assertEqual`/`assertBool` pattern is reused.

**Types/signatures that must exist at the end of each milestone.**

End of Milestone 1 (in `En.Example.Host`):

```haskell
exampleSchema :: En.Schema.Schema
mkEnv :: ConsistencyStore IO -> TupleStore IO -> AuthorizationEnv
failingConsistencyStore :: ConsistencyStore IO
viewDocument :: AuthorizationEnv -> Subject -> Text -> Handler DocumentView   -- callable via runHandler
app :: AuthorizationEnv -> Subject -> Application                              -- for the optional curl demo
```

and in `en-example/test/Main.hs`:

```haskell
httpCodeOf :: Servant.Handler a -> IO (Maybe Int)   -- Nothing on success, Just (errHTTPCode e) on failure
```

End of Milestone 2 (in `En.Conformance.Kikan`):

```haskell
kikanSchema  :: En.Schema.Schema
kikanGraph   :: En.Reachability.ReachabilityGraph
fixtureTuples :: [En.Tuple.Tuple]
inMemoryTupleStore :: [Tuple] -> TupleStore IO
consistencyStore   :: ConsistencyStore IO
-- named ObjectRefs: agencyUser, bob, guestOrg, guestSpace, sharedItem, internalItem,
--                   sharedClass, internalClass, intention, …
-- caveat contexts: requestContext, missingAutonomyContext, expiredContext, adminContext
```

The conformance suite uses `En.Check.check :: ConsistencyStore m -> TupleStore m ->
ReachabilityGraph -> Consistency -> CaveatContext -> Subject -> RelationName -> ObjectRef ->
m (Either EnError CheckDecision)`.

End of Milestone 3: the same fixture plus assertions over `En.Lookup.lookup :: ConsistencyStore m
-> TupleStore m -> ReachabilityGraph -> Consistency -> LookupRequest -> m (Either EnError
LookupPage)`, building `LookupRequest{subject, permission, objectType, context, limit, cursor}`.

**Cross-plan references (by path only, per the spec).** Soft dependencies:
`docs/plans/15-generalize-the-caveat-evaluator-and-unify-the-decision-algebra.md` (the generic
caveat evaluator the delegation caveat will use) and
`docs/plans/16-make-lookup-streaming-with-resumable-cursors-and-a-deadline-budget.md` (the
streaming `lookup` the read-filter proof exercises). This plan is EP-18 in
`docs/masterplans/3-harden-en-correctness-fixes-lookup-streaming-and-performance-benchmarks.md`
(see its Integration Point 6 and the Wave-3 soft dependencies). The agency scenario it proves is
kikan contract C13 (`shinzui/kikan → docs/architecture/evolution/contracts.md`) and the `en` spec
`docs/spec/0001-en-overview.md` §6 (the read-filter/perf boundary) and §9 (the day-one
conformance case).
