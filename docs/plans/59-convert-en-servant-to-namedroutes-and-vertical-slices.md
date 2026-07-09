---
id: 59
slug: convert-en-servant-to-namedroutes-and-vertical-slices
title: "Convert en-servant to NamedRoutes and vertical slices"
kind: exec-plan
created_at: 2026-07-09T14:39:50Z
intention: "intention_01kx3mms73ewyrfy9f61e5c3n6"
---

# Convert en-servant to NamedRoutes and vertical slices

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`en` is a Zanzibar-style relationship-based authorization service: it stores relationship
*tuples* (facts like "user:alice is `viewer` of space:project-x"), and answers four kinds of
question about them — `check` (may this subject do this?), `lookup` (which objects may this
subject reach?), `expand` (show me the subject tree behind this permission), and the writes
that create and delete the tuples. Its HTTP surface is exposed by the `en-servant` package,
and *all* of it — the six route definitions, every request and response wire type, every
handler, and every hand-written JSON codec — lives in one 1,247-line file,
`en-servant/src/En/Servant/API.hs`. That file couples the route list, the DTOs
(data-transfer objects, i.e. the on-the-wire request/response shapes), and the handlers into
a single unit that only ever grows.

After this change, the six operations become a servant **`NamedRoutes` record** (a Haskell
record with one field per route) instead of a positional **`:<|>` chain** (a flat list of
routes joined by an operator where only *position* associates a handler with its route), and
each operation's routes, DTOs, and handler move into a **vertical slice** — a module tree
named for the concept (`En.Tuple.Api`, `En.Check.Api`, `En.Lookup.Api`, `En.Expand.Api`)
rather than for the layer. Adding a seventh operation then means adding one slice module and
one field, not editing a shared 1,200-line file that every other operation also lives in.

You can see the change working three ways, all in Validation below: the standalone server
still answers `POST /v1/check` and `POST /v1/lookup` with the same JSON; a malformed request
body still comes back as the machine-readable `ErrorEnvelopeWire` (proving the
`envelopeFormatters` hook survived the refactor); and the two downstream repositories that
depend on `en` as a library — `nagare` and `kikan-en` — still build against the new module
layout without a single edit, because the public modules they import keep their exact
interfaces.

**`en` is already the reference implementation of the `MultiVerb` convention. This plan does
not touch that, and a reader must not "fix" it.** `MultiVerb` is a servant combinator that
makes an operation's error statuses part of its *type* (a type-level list of responses)
rather than exceptions thrown past it. `En/Servant/API.hs` already defines `EnResponses` (the
shared `200/400/422/503` response list), `EnResult` (the sum type a handler returns, one
constructor per status), the **hand-written** `AsUnion` instance that maps `EnResult` onto
`EnResponses` positionally — complete with its final *exhaustiveness witness* clause
(`S (S (S (S impossible))) -> case impossible of {}`, which stops compiling the moment the
response list grows) — the total `faultToResult` conversion, and the `envelopeFormatters`
`ErrorFormatters` hook that makes servant's own pre-handler errors (malformed body, unmatched
route) speak the same `ErrorEnvelopeWire`. The canonical best-practices document
(`api/servant-routes.md` in the `haskell-jitsurei` repository) was written *from* this code.
The `MultiVerb` half of that document is therefore **done** in `en`. This plan implements only
the two gaps that document also names: `NamedRoutes` and vertical slices. `EnResponses`,
`EnResult`, `AsUnion`, `faultToResult`, `ErrorEnvelopeWire`, and `envelopeFormatters` are
carried through unchanged; the only thing that happens to them is that they move to a
dedicated module (`En.Servant.Response`) and are re-exported, so no byte of their logic
changes.


## Progress

- [ ] Milestone 1: convert `EnAPI` from a `"v1" :> ( … :<|> … )` chain to a flat
      `NamedRoutes` record `EnApi`, with no module moves. Update the server assembly, the
      `En.Client` generated client (`genericClient`), the OpenAPI mount, and the
      `en-servant` test's positional handler extraction. `cabal build all` and
      `cabal test all` pass; downstream `nagare` and `kikan-en` build unchanged.
- [ ] Milestone 2: add a `Network.Wai.Test` end-to-end routing guard that drives `app env`
      over all six paths, asserts a malformed body returns `ErrorEnvelopeWire` (proving
      `envelopeFormatters` survived), and asserts an unknown path returns the 404 envelope.
      This pins behavior before the Milestone 3 file moves.
- [ ] Milestone 3: split `En.Servant.API` into vertical slices — `En.Servant.Wire` (shared
      wire vocabulary), `En.Servant.Response` (the `MultiVerb` machinery), and
      `En.Tuple.Api` / `En.Check.Api` / `En.Lookup.Api` / `En.Expand.Api` (routes + DTOs +
      handlers). Keep `En.Servant.API` as a thin re-export umbrella so its public interface
      is byte-for-byte identical and no downstream import breaks.
- [ ] Milestone 4: amend the document of record,
      `docs/plans/35-version-the-wire-contract-and-type-the-error-model.md`, whose code
      blocks specify the `:<|>` chain and positional server this plan replaces.


## Surprises & Discoveries

- Discovery (pre-implementation, recorded during planning): **`en` has essentially no live
  misordering hazard today.** The best-practices document's headline argument for
  `NamedRoutes` is that a positional `:<|>` chain silently misroutes when two routes share a
  *type*. In `en`, all six operations are `POST`s and every one carries a *distinct*
  `ReqBody` type (`WriteTuplesRequestWire`, `DeleteTuplesRequestWire`, `CheckRequestWire`,
  `BatchCheckRequestWire`, `LookupRequestWire`, `ExpandRequestWire`). `writeTuples` and
  `deleteTuples` share a response type (`EnResult WriteTuplesResponseWire`) but differ in
  request body, so even *those two* cannot be transposed without a type error. Transposing
  any two handlers in the current chain is therefore already a compile error. The motivation
  for this plan is consequently **not** "close a live misrouting bug"; it is (a) to enable
  the vertical-slice split of the monolithic `API.hs`, which a positional chain fights (a
  shared `/v1` prefix forces all operations to interleave into one chain in one file), (b) to
  replace the hand-written positional client destructuring in `En.Client` with a derived
  `genericClient`, and (c) to make a *future* seventh operation that shares a request+response
  shape structurally safe rather than accidentally safe. This is stated plainly so no reader
  oversells the change — see the Decision Log.

- (Add further discoveries here as implementation proceeds — e.g. whether
  `servant-openapi-hs` provides `HasOpenApi (NamedRoutes …)` directly; see Milestone 1.)


## Decision Log

- Decision: Do not touch the `MultiVerb` machinery's *logic* — `EnResponses`, `EnResult`, the
  hand-written `AsUnion` instance and its exhaustiveness witness, `faultToResult`,
  `ErrorEnvelopeWire`, `EnFault`, `enErrorToFault`, or `envelopeFormatters`. Move it (in
  Milestone 3) into `En.Servant.Response` and re-export it, but change no behavior.
  Rationale: `en` is the reference implementation of the `MultiVerb` convention; the
  best-practices document was written from this code. Widening the plan to touch responses
  would risk the very artifact other services copy, for no gain. The plan's two rules are
  `NamedRoutes` and vertical slices; responses are already correct.
  Date: 2026-07-09

- Decision: Keep `En.Servant.API` and `En.Servant.Seam` as their current module paths, and
  make `En.Servant.API` a **re-export umbrella** after the slice split, preserving its exact
  export list. Do not add deprecated shim modules; none are needed.
  Rationale: `en` is a *library* consumed by two external repositories. `nagare`
  (`nagare/cli/nagare-access`) imports `En.Servant.API` (qualified as `EnApi`, using
  `EnApi.app`), `En.Servant.Seam (Env (..))`, and `En.Client (EnClient (..), enClient, …)`.
  `kikan-en` (`kikan-project/kikan-en`) imports `En.Servant.API (app)` and
  `En.Servant.Seam (AppEffects, Env (..))`. `en-server` (in-repo) imports
  `En.Servant.OpenApi (appWithOpenApi)` and `En.Servant.Seam`. `en-example` (in-repo) imports
  `En.Servant.Authorize (requirePermission)` and `En.Servant.Seam (Env (..))`. Not one of
  these references the `EnAPI` type, `apiProxy`, `server`, `EnResult`, or the individual wire
  types *except through* `En.Servant.API`'s or `En.Client`'s export list. So if those two
  modules keep their interfaces, **no downstream module breaks and no downstream version bump
  is required.** Moving the DTOs and handlers into new slice modules is invisible to
  consumers because the umbrella re-exports every name it exports today. This is the load-
  bearing difference from meibo's ExecPlan 7 (the exemplar), which *deleted* `Meibo.Api.Routes`
  and `Meibo.Api.Types`: meibo's importers were all in-repo, so a delete-and-move was safe;
  `en`'s importers are external, so the public modules must persist.
  Date: 2026-07-09

- Decision: Name the slices `En.Tuple.Api`, `En.Check.Api`, `En.Lookup.Api`, `En.Expand.Api`
  — concept as the module-path *root* under `En`, `Api` as the *leaf* — not
  `En.Servant.Tuple` etc.
  Rationale: the best-practices rule is `<Project>/<Concept>/<Layer>.hs`, never
  `<Project>/<Layer>/<Concept>.hs`. `en-core` already exposes concept modules `En.Check`,
  `En.Lookup`, `En.Expand`, and `En.Tuple`. Placing the API layer at `En.Check.Api` (in
  `en-servant`) means everything about "check" — its domain module `En.Check` in `en-core`
  and its HTTP layer `En.Check.Api` in `en-servant` — shares the `En.Check` prefix across
  packages. Reading a concept becomes one `grep En.Check`. A module `En.Check` and a module
  `En.Check.Api` coexist without conflict (the files `En/Check.hs` and `En/Check/Api.hs` sit
  side by side; they are in different packages here anyway). Packages stay split by layer
  (`en-core`, `en-servant`, `en-client`) because packages are dependency boundaries; only the
  module trees inside each package are concept-first.
  Date: 2026-07-09

- Decision: The relationship-write slice is `En.Tuple.Api` (matching `en-core`'s `En.Tuple`),
  even though its URL prefix is `/v1/relationships` and its request/response types are named
  `…Tuples…`.
  Rationale: the concept `en-core` already owns is the `Tuple`; the wire vocabulary calls a
  written tuple a "relationship" but the domain type is `En.Tuple.Tuple`. Keeping the slice
  under the `En.Tuple` prefix keeps the grep-one-prefix property. The URL string stays
  `/v1/relationships`; module names and URL segments are independent.
  Date: 2026-07-09

- Decision: Put the wire vocabulary shared by two or more operations —
  `ObjectRefWire`, `SubjectWire`, `ConsistencyWire`, `CaveatValueWire`, `CaveatPayloadWire`,
  `CaveatContextWire`, `CheckDecisionWire`, `CaveatObligationWire` — plus their
  `…ToWire`/`…FromWire` conversions in a single shared module `En.Servant.Wire`, rather than
  in any one slice.
  Rationale: `ObjectRefWire` and `SubjectWire` appear in every operation; `ConsistencyWire`,
  `CaveatValueWire`, and `CaveatContextWire` appear in check/lookup/expand; `CheckDecisionWire`
  appears in both check (`CheckResponseWire`) and lookup (`LookupObjectWire`). A type used by
  more than one slice has no single owning slice, exactly as meibo put `MembershipView` (shared
  by team and role) in a shared module. Placing it in one slice would force the other slices to
  depend on that slice's `Api` module, coupling verticals that should be independent.
  Date: 2026-07-09

- Decision: Keep the `ToSchema` OpenAPI instances in `En.Servant.OpenApi` (they are already a
  separate description layer, deliberately holding orphan instances so that describing the API
  stays separable from serving it); only update their imports to pull the wire types from
  their new homes.
  Rationale: those instances are not part of any operation's runtime behavior and are already
  isolated; moving them into slices would spread orphan instances across four modules for no
  benefit and complicate the golden OpenAPI test.
  Date: 2026-07-09

- Decision: Do the `NamedRoutes` type change first (Milestone 1), the behavioral guard second
  (Milestone 2), and the module moves third (Milestone 3), in three separate commits.
  Rationale: interleaving a type-shape change with a file move produces a diff a reviewer
  cannot read. Landing the guard test between them means the large mechanical move is protected
  by an end-to-end behavioral check.
  Date: 2026-07-09


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### What this repository is

`en` is a Haskell implementation of relationship-based authorization (ReBAC), in the style of
Google Zanzibar. It is built with `cabal` and GHC 9.12.4, pinned by `cabal.project` at the
repository root, `/Users/shinzui/Keikaku/bokuno/en`. The packages, each a directory at the
repository root with its own `.cabal` file:

- `en-core` — the engine: schema, reachability graph, the `check`/`lookup`/`expand`
  algorithms, tuple and caveat domain types, effect *ports* (the `TupleStore`,
  `CachedTupleStore`, and `ConsistencyStore` interfaces). No HTTP.
- `en-servant` — the HTTP contract as a servant API type, the handlers, the JSON codecs, the
  OpenAPI document, and `requirePermission` (a fail-closed helper for hosts that embed `en`).
  **This is the package this plan changes.**
- `en-client` — a typed Haskell client (`En.Client`) derived from the API type.
- `en-postgres` — the PostgreSQL adapters implementing the `en-core` ports.
- `en-server` — the deployable standalone executable.
- `en-biscuit` — an optional Biscuit-token grant layer (untouched by this plan).
- `en-example` — a worked example of embedding `en` via `requirePermission`.
- `en-migrations` — SQL schema migrations.

### Terms used in this plan

**Servant** is the Haskell library `en` uses to describe an HTTP API as a *type*. A route is a
type built from combinators joined by `:>`, for example
`"v1" :> "check" :> ReqBody '[JSON] CheckRequestWire :> Post '[JSON] CheckResponseWire`
describes `POST /v1/check`.

**`:<|>`** (pronounced "alt") is servant's operator for "this route *or* that route". An API
built with it is a positional chain: `A :<|> B :<|> C`. The server must supply handlers in
exactly the same order: `handlerA :<|> handlerB :<|> handlerC`. Nothing but position
associates a handler with its route. `en`'s current `EnAPI` is such a chain of six operations.

**`NamedRoutes`** is servant's alternative: the API is a Haskell *record*, one field per route,
parameterized by a type variable conventionally called `mode`. Each field joins its name to
its route type with the `:-` operator (from `Servant.API.Generic`). Servant instantiates
`mode` differently for different purposes: `AsApi` yields a description, `AsServerT m` yields a
record of handlers, `AsClientT` yields a record of client functions. Because handlers are
supplied by *field name*, a transposition is a type error rather than a silent misroute, and
because each field can mount a whole sub-record, the route tree can follow the *module*
structure instead of the URL structure.

**`MultiVerb`** is a servant combinator, already used throughout `en`. Instead of a route
ending in `Post '[JSON] X` and throwing an exception to signal an error status, the route ends
in a `MultiVerb` whose type-level list (`en`'s `EnResponses`) enumerates every status the
operation can answer with, and the handler returns a plain sum type (`en`'s `EnResult`) with
one constructor per status. **This plan does not change any of this**; it is described here so
the reader is not surprised to see it and does not try to "improve" it.

**`AsUnion`** is the servant type class that maps `EnResult` onto `EnResponses`. `en` writes
its instance **by hand** (not via `GenericAsUnion`) so that a change to the response list
breaks the build loudly. Its last clause,
`fromUnion (S (S (S (S impossible)))) -> case impossible of {}`, is the *exhaustiveness
witness*: the union has exactly four positions, so the fifth shift is uninhabited. Leave it
exactly as it is.

**A vertical slice** means every module belonging to one concept shares one module-path prefix
named for that concept, and the *layer* (domain, API, handler) is the last component of the
path — never the first. So `En.Check.Api`, never `En.Servant.Check`.

**A DTO (data-transfer object)** is an on-the-wire request or response shape — in `en`, the
`…Wire` types (`CheckRequestWire`, `LookupPageWire`, and so on), each with a hand-written
`ToJSON`/`FromJSON` instance that fixes the exact JSON bytes.

**`ErrorEnvelopeWire`** is `en`'s single error-body shape: `{code, message, retryable}`. `code`
is a stable machine-readable identifier a client branches on; `retryable` says whether retrying
an unchanged request can help (true only for `503` store outages). It lives in
`En.Servant.Seam` and is untouched.

**`envelopeFormatters`** is an `ErrorFormatters` value installed in the servant serving context
(`serveWithContext apiProxy (envelopeFormatters :. EmptyContext) …`) so that errors servant
raises *before any handler runs* — a body that fails to parse, a route that matches nothing —
come back as `ErrorEnvelopeWire` rather than servant's default plain-text body. It is the hook
Milestone 2's malformed-body assertion proves still works.

### The current state

`en-servant/src/En/Servant/API.hs` (1,247 lines) is `en`'s monolith. It contains, in one file:

- The `EnResponses` response-list alias, the `EnResult` sum, the hand-written `AsUnion`
  instance with its exhaustiveness witness, and `faultToResult`.
- The `EnAPI` type: `"v1" :> ( writeTuples :<|> deleteTuples :<|> check :<|> batchCheck :<|>
  lookup :<|> expand )`, a positional chain of **six** operations. All six are `POST`s. The
  paths are `/v1/relationships` (write), `/v1/relationships/delete` (delete — a `POST`, not a
  `DELETE`, deliberately; see below), `/v1/check`, `/v1/batch-check`, `/v1/lookup`,
  `/v1/expand`.
- `apiProxy`, `server` (the positional handler chain), and `app` (the
  `serveWithContext … envelopeFormatters …` assembly).
- `envelopeFormatters` itself.
- Every wire DTO with its hand-written `ToJSON`/`FromJSON`: `ObjectRefWire`, `SubjectWire`,
  `CaveatValueWire`, `CaveatPayloadWire`, `CaveatContextWire`, `TupleCaveatWire`, `TupleWire`,
  `ConsistencyWire`, `CheckRequestWire`, `CheckDecisionWire`, `CaveatObligationWire`,
  `CheckResponseWire`, `BatchCheckPairWire`, `BatchCheckRequestWire`, `BatchCheckResponseWire`,
  `LookupRequestWire`, `LookupObjectWire`, `LookupStateWire`, `LookupPageWire`,
  `ExpandRequestWire`, `ExpandNodeWire`, `ExpandStateWire`, `ExpandTreeWire`,
  `WriteTuplesRequestWire`, `DeleteTuplesRequestWire`, `WriteTuplesResponseWire`.
- Every handler: `writeTuplesHandler`, `deleteTuplesHandler`, `checkHandler`,
  `batchCheckHandler`, `lookupHandler` (and its `lookupDeadline` helper), `expandHandler`.
- Every domain↔wire conversion: `objectRefToWire`/`FromWire`, `subjectToWire`/`FromWire`,
  `tupleToWire`/`FromWire`, `consistencyToWire`/`FromWire`, `decisionToWire`,
  `lookupPageToWire`, `expandTreeToWire`, and their helpers, plus the `enHandler`, `engine`,
  `orInvalid`, and `traverseOrInvalid` handler-plumbing helpers.

The two supporting modules:

- `en-servant/src/En/Servant/Seam.hs` — the "seam" between `en`'s effectful engine and
  servant's `Handler`. Holds `Env` (the handler environment), `AppEffects`, `EnServer`,
  `ErrorEnvelopeWire`, `EnFault`, `enErrorToFault`, `faultToServerError`, `runEngineEither`,
  and the small constructors `badRequest`/`invalidRequest`/`batchTooLarge`/`notFound`. **Stays
  put and unchanged** — downstream imports it directly.
- `en-servant/src/En/Servant/OpenApi.hs` — the OpenAPI 3.1 document. Defines `ServedAPI`
  (`EnAPI :<|> "v1" :> "openapi.json" :> Get '[JSON] OpenApi`), `enOpenApi`, and
  `appWithOpenApi` (what `en-server` actually serves), plus one hand-written `ToSchema` orphan
  instance per wire type. **Stays as a module; its imports change in Milestone 3.**
- `en-servant/src/En/Servant/Authorize.hs` — `requirePermission`, the fail-closed embed helper.
  **Untouched.**

`en-client/src/En/Client.hs` currently builds its public `EnClient` record by **positional
destructuring** of the servant client:

```haskell
enClient = EnClient { writeTuples, deleteTuples, check, batchCheck, lookup, expand }
  where
    writeTuples :<|> deleteTuples :<|> check :<|> batchCheck :<|> lookup :<|> expand =
        client apiProxy
```

This is exactly the positional fragility `NamedRoutes` removes; Milestone 1 replaces it with
`genericClient`.

`en-servant/test/Main.hs` (a plain `exitcode-stdio` program of hand-rolled assertions, not
hspec) extracts individual handlers from `server env` the same positional way, four times over:

```haskell
batchHandler env = batch
  where
    _write :<|> _delete :<|> _check :<|> batch :<|> _lookup :<|> _expand = server env
```

Milestone 1 rewrites these to record-field pattern binds; Milestone 3 lets the test import the
slice handlers directly and drop the extraction entirely.

### One thing that must be preserved: delete is a POST, not a DELETE

`En/Servant/API.hs` documents, and this plan keeps, that tuple deletion is
`POST /v1/relationships/delete` carrying a request body, **not** `DELETE /v1/relationships`.
Two reasons are recorded in the code: HTTP intermediaries are permitted to drop a `DELETE`
body, and — the subtler one — servant raises `405 Method Not Allowed` *outside*
`ErrorFormatters` and a `405` **does not consume the request body**, leaving an unread body on
the wire. Modelling the operation as a `POST` avoids both. Do not "restore" a `DELETE` verb
during this refactor.

### Downstream consumers (why the module paths matter)

Two repositories depend on `en` as a library. The plan's Decision Log commits to keeping their
imports working; here is the exact surface so the implementer can verify it:

- **`nagare`** at `/Users/shinzui/Keikaku/bokuno/nagare`, package `nagare/cli/nagare-access`
  (`.cabal` depends on `en-client`, `en-core`, `en-servant`):
  - `src/Nagare/Access/En.hs` imports from `En.Client`: `EnClient (..)`, `enClient`,
    `CheckRequestWire (..)`, `CheckResponseWire (..)`, `CheckDecisionWire (..)`,
    `ConsistencyWire (..)`, `ObjectRefWire (..)`, `SubjectWire (..)`, `CaveatContextWire (..)`.
    It calls `client.check` via `OverloadedRecordDot` on the plain `EnClient` record.
  - `test/Spec.hs` imports `En.Servant.API qualified as EnApi` and calls `EnApi.app env`; imports
    `En.Servant.Seam (Env (..))`; and imports `en-core` concept modules `En.Check`, `En.Lookup`,
    `En.Reachability`, `En.Schema`, `En.Schema.Builder`, `En.Tuple`, `En.Error`,
    `En.Effect.ConsistencyStore`, `En.Effect.TupleStore`, `En.Conformance.Kikan`, and
    `En.Client`.
- **`kikan-en`** at `/Users/shinzui/Keikaku/bokuno/kikan-project/kikan-en` (`.cabal` depends on
  `en-core`, `en-postgres`, `en-servant`):
  - `src/Kikan/En/Server.hs` imports `En.Servant.API (app)` and
    `En.Servant.Seam (AppEffects, Env (..))`, plus many `en-core`/`en-postgres` modules.
  - Other modules import `en-core`/`en-postgres` concept modules only.

The only `en-servant`/`en-client` symbols any downstream file touches are: `app` (from
`En.Servant.API`), `Env`/`AppEffects` (from `En.Servant.Seam`), and `EnClient`/`enClient`/the
`…Wire` types (from `En.Client`). No downstream file references the `EnAPI` type name,
`apiProxy`, `server`, `EnResult`, or `EnResponses` directly. Keeping `En.Servant.API`,
`En.Servant.Seam`, and `En.Client` interface-stable therefore breaks nothing downstream.

**How downstream resolves the `en` dependency.** Before trusting a downstream build as
evidence, confirm each downstream repo actually consumes the *local working tree* of `en` and
not a pinned git revision. Check each repo's `cabal.project`:

```bash
grep -nE "en-core|en-servant|en-client|en-postgres|location:|../en|source-repository" \
  /Users/shinzui/Keikaku/bokuno/nagare/cabal.project \
  /Users/shinzui/Keikaku/bokuno/kikan-project/kikan-en/cabal.project
```

If a repo pins `en` by a `source-repository-package` git `tag`, a local `en` change will not
reach it until the tag is repointed; to validate against local `en`, temporarily add the `en`
package directories as local `packages:` entries (or a `source-repository-package` with a
local path) in that repo's `cabal.project.local`, build, then revert. Record what you find in
Surprises & Discoveries — the resolution mechanism determines whether "downstream builds" is
even a meaningful local check or must instead be asserted by review of the unchanged import
lists.

### Build and test commands

All `en` commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/en`. The project
uses a nix dev shell and a `justfile`.

```bash
cabal build all
cabal test all
```

`cabal test all` runs the `en-servant-tests` suite (`en-servant/test/Main.hs`, the wire-golden,
error-model, OpenAPI, and handler tests) among others across packages. The `justfile` also has
`just start-server` (runs migrations, then `cabal run en-server`) and `just start-and-test`
(brings up `process-compose`, waits on `GET /healthz`, runs the HTTP smoke test).

### The rules this plan implements

These are recorded canonically in the `haskell-jitsurei` repository at `api/servant-routes.md`.
Per the ExecPlan requirement of self-containment, the two rules are restated in full:

1. **Define the API as a `NamedRoutes` record, never as a positional `:<|>` chain.** A record
   makes handler↔route association by field name. `:<|>` stays correct for *mounting* records
   inside a host API, where the alternatives have distinct types — for example
   `ServedAPI = NamedRoutes EnApi :<|> "v1" :> "openapi.json" :> Get '[JSON] OpenApi` keeps its
   `:<|>`, because mounting the whole API next to the OpenAPI route is what `:<|>` is for. It is
   never correct for enumerating the routes *inside* one API.

2. **Organize modules by concept, not by layer.** The layer is the leaf of the module path.
   Packages stay split by layer because packages are dependency boundaries; module trees inside
   each package are concept-first: `<Project>/<Concept>/<Layer>.hs`.

The second rule is the *reason* for the first. A positional chain forces layer-first structure:
because all six `en` operations share the `/v1` prefix, a chain must weave them into one list in
one file, so the URL structure dictates the module structure and every operation's routes, DTOs,
and handlers pile into one `API.hs` that nobody can own a slice of. With `NamedRoutes`, each
concept exports its own route record and handler record, the umbrella record names them as
fields, and several fields mount at the same `/v1` prefix.


## Plan of Work

### Milestone 1 — Convert `EnAPI` to a flat `NamedRoutes` record

Scope: `en-servant/src/En/Servant/API.hs`, `en-servant/src/En/Servant/OpenApi.hs`,
`en-client/src/En/Client.hs`, and `en-servant/test/Main.hs`. No files move; no DTO, handler,
or response-type logic changes. At the end, `EnAPI` is a record, the server is a record of
handlers, the client is `genericClient`, and `cabal build all && cabal test all` passes, as do
the `nagare` and `kikan-en` builds.

**The record.** Replace the `type EnAPI = "v1" :> ( … :<|> … )` alias with a flat record
`EnApi mode` carrying one field per operation, each field holding the *full* path including its
`"v1"` prefix (the shared prefix is not factored out yet — that is Milestone 3's slicing job).
Keep every `MultiVerb`, every `EnResponses "<description>" …`, and every `EnResult …` exactly as
it is today; only the enclosing shape changes.

```haskell
data EnApi mode = EnApi
  { writeTuples ::
      mode
        :- "v1"
          :> "relationships"
          :> ReqBody '[JSON] WriteTuplesRequestWire
          :> MultiVerb
               'POST
               '[JSON]
               (EnResponses "Consistency token for the write" WriteTuplesResponseWire)
               (EnResult WriteTuplesResponseWire)
  , deleteTuples ::
      mode
        :- "v1"
          :> "relationships"
          :> "delete"
          :> ReqBody '[JSON] DeleteTuplesRequestWire
          :> MultiVerb
               'POST
               '[JSON]
               (EnResponses "Consistency token for the deletion" WriteTuplesResponseWire)
               (EnResult WriteTuplesResponseWire)
  , check ::
      mode
        :- "v1"
          :> "check"
          :> ReqBody '[JSON] CheckRequestWire
          :> MultiVerb 'POST '[JSON] (EnResponses "The authorization decision" CheckResponseWire) (EnResult CheckResponseWire)
  , batchCheck ::
      mode
        :- "v1"
          :> "batch-check"
          :> ReqBody '[JSON] BatchCheckRequestWire
          :> MultiVerb 'POST '[JSON] (EnResponses "One decision per requested pair, in order" BatchCheckResponseWire) (EnResult BatchCheckResponseWire)
  , lookup ::
      mode
        :- "v1"
          :> "lookup"
          :> ReqBody '[JSON] LookupRequestWire
          :> MultiVerb 'POST '[JSON] (EnResponses "A page of authorized objects" LookupPageWire) (EnResult LookupPageWire)
  , expand ::
      mode
        :- "v1"
          :> "expand"
          :> ReqBody '[JSON] ExpandRequestWire
          :> MultiVerb 'POST '[JSON] (EnResponses "The permission's subject tree" ExpandTreeWire) (EnResult ExpandTreeWire)
  }
  deriving stock (Generic)

-- | Kept as a synonym so existing references to the name @EnAPI@ (all internal to
-- en-servant) and @apiProxy@'s type keep reading naturally.
type EnAPI = NamedRoutes EnApi

apiProxy :: Proxy EnAPI
apiProxy = Proxy
```

The module already sets `DataKinds` and `TypeOperators` (via the `shared` cabal stanza and the
file's `{-# LANGUAGE TypeOperators #-}`). Add imports of `Servant.API.Generic (type (:-))`,
`Servant.Server.Generic (AsServerT)`, `Servant.API (NamedRoutes)`, and `GHC.Generics (Generic)`.
Export the record type and its constructor: change the export `EnAPI` to `EnAPI, EnApi (..)`.

**The server.** Rewrite `server` from the positional chain to a record. Its type signature can
stay spelled `Server EnAPI`, because `Server (NamedRoutes EnApi)` *is*
`EnApi (AsServerT Handler)`:

```haskell
server ::
  (ConsistencyStore Effectful.:> es, TupleStore Effectful.:> es, Error EnError Effectful.:> es, IOE Effectful.:> es) =>
  Env es ->
  Server EnAPI
server env =
  EnApi
    { writeTuples = writeTuplesHandler env
    , deleteTuples = deleteTuplesHandler env
    , check = checkHandler env
    , batchCheck = batchCheckHandler env
    , lookup = lookupHandler env
    , expand = expandHandler env
    }
```

`app` is unchanged in spelling —
`serveWithContext apiProxy (envelopeFormatters :. EmptyContext) (server env)` — and now serves
the `NamedRoutes` proxy. Remove the now-unused `import Servant (… type (:<|>) (..) …)` from
`API.hs` if nothing else uses it (the record has no `:<|>`).

**A gotcha to plan for: `en-servant` sets `NoFieldSelectors`.** The `shared` cabal stanza lists
`NoFieldSelectors`, so the record fields (`writeTuples`, `check`, …) do **not** generate
top-level selector functions. This does not affect the record *type* (servant reaches fields via
`Generic`, not selectors) nor record *construction* (`EnApi { … }` is fine). It only means you
cannot write `writeTuples someRecord` or `someRecord.writeTuples` to *read* a field; to pull a
handler out you must pattern-bind, e.g. `let EnApi{check} = server env in check` (with
`NamedFieldPuns`, which `GHC2024` enables). This matters for the test rewrite below and for the
client.

**The client.** In `en-client/src/En/Client.hs`, keep the public `EnClient` record and
`enClient` value exactly as they are (nagare depends on both, and on `client.check` via record
dot). Change only how `enClient` is built — from positional `client apiProxy` to
`genericClient`, destructured by a record pattern (a pattern needs no selectors, so it is
`NoFieldSelectors`-safe even if `en-client` also sets it):

```haskell
import Prelude hiding (lookup)

import Servant.Client (ClientM)
import Servant.Client.Generic (AsClientT, genericClient)

import En.Servant.API

-- EnClient and its record fields are unchanged.

enClient :: EnClient
enClient =
  EnClient
    { writeTuples
    , deleteTuples
    , check
    , batchCheck
    , lookup
    , expand
    }
  where
    EnApi
      { writeTuples
      , deleteTuples
      , check
      , batchCheck
      , lookup
      , expand
      } = genericClient :: EnApi (AsClientT ClientM)
```

Remove the old `import Servant.API ((:<|>) (..))` and the `client` import. The annotation
`:: EnApi (AsClientT ClientM)` is required so GHC fixes the client monad to `ClientM`. Add
`servant-client` if not already a dependency of `en-client` (it is — `client`/`ClientM` came
from it).

**The OpenAPI mount.** In `En/Servant/OpenApi.hs`, `ServedAPI` stays
`EnAPI :<|> "v1" :> "openapi.json" :> Get '[JSON] OpenApi` — the `:<|>` here is the *correct*
mounting use and needs no change (now `EnAPI = NamedRoutes EnApi`). `appWithOpenApi`'s body
`server env :<|> pure enOpenApi` also stays: `ServerT (NamedRoutes EnApi :<|> Get … OpenApi)`
is `EnApi (AsServerT Handler) :<|> Handler OpenApi`, and `server env` already has the left type.
`enOpenApi = toOpenApi apiProxy` must still typecheck — **verify** that `servant-openapi-hs`
provides `HasOpenApi (NamedRoutes EnApi)`. It should (the library derives it through the
generic servant representation). If, and only if, that instance is missing, replace
`toOpenApi apiProxy` with `toOpenApi (Proxy @(ToServantApi EnApi))` (importing
`Servant.API.Generic (ToServantApi)`), which describes the identical flattened API; record the
outcome in Surprises & Discoveries either way.

**The test.** In `en-servant/test/Main.hs`, the four helpers `batchHandler`, `checkHandler`,
`lookupHandler`, `expandHandler` currently destructure `server env` positionally. Rewrite each
to a record field bind, and drop `import Servant (… type (:<|>) (..))`:

```haskell
batchHandler :: Env TestEffects -> BatchCheckRequestWire -> Handler (EnResult BatchCheckResponseWire)
batchHandler env = batchCheck where EnApi{batchCheck} = server env

checkHandler :: Env TestEffects -> CheckRequestWire -> Handler (EnResult CheckResponseWire)
checkHandler env = check where EnApi{check} = server env

lookupHandler :: Env TestEffects -> LookupRequestWire -> Handler (EnResult LookupPageWire)
lookupHandler env = lookup where EnApi{lookup} = server env

expandHandler :: Env TestEffects -> ExpandRequestWire -> Handler (EnResult ExpandTreeWire)
expandHandler env = expand where EnApi{expand} = server env
```

`server` and `EnApi (..)` must be added to the test's `import En.Servant.API ( … )` list.
`NamedFieldPuns` is on under `GHC2024`. (Milestone 3 will let these import the slice handlers
directly and remove even this, but keeping the extraction in Milestone 1 isolates the type
change from the move.)

Acceptance: `cabal build all && cabal test all` succeeds; `git diff --stat` shows no file
renames; and both downstream repos build (see Concrete Steps for the exact commands and the
`cabal.project` caveat).

### Milestone 2 — A behavioral routing and envelope guard

Scope: `en-servant/test/Main.hs` (extend it) and `en-servant/en-servant.cabal` (test-suite
dependencies). This milestone exists because Milestone 1's benefit is otherwise invisible — the
code compiles before and after and no behavior changed — and because Milestone 3 moves a lot of
code and must be protected by an end-to-end check that exercises real routing and the
`envelopeFormatters` hook, neither of which the existing golden/handler unit tests drive.

Be honest about what this guards. As recorded in Surprises & Discoveries, `en` has no live
misordering hazard: all six routes carry distinct `ReqBody` types, so a transposition is already
a compile error. This test is therefore *not* a "prove the misrouting bug is gone" test (there
is none); it pins the observable HTTP behavior — that each path routes to the right handler and
that pre-handler errors still speak `ErrorEnvelopeWire` — so the Milestone 3 move cannot
silently change it.

Drive the real WAI `Application`, `app env`, with `Network.Wai.Test`, reusing the in-memory
fixtures the test already imports (`fixtureTuples` and `kikanGraph` from `En.Conformance.Kikan`,
wired into `Env` exactly as the existing `main` does). Add a `routingTests :: IO ()` and call it
from `main`. Add `wai` and `wai-extra` to the `en-servant-tests` `build-depends`.

The assertions, all against `app env`:

- `POST /v1/check` with the valid body
  `{"consistency":{"mode":"minimizeLatency"},"context":{"values":{}},"subject":{"kind":"id","objectType":"user","objectId":"alice"},"permission":"view","object":{"objectType":"space","objectId":"project-x"}}`
  returns HTTP 200 and a body that decodes to `CheckResponseWire` (with the `kikanGraph`
  fixtures, `alice` `view` on `project-x` is `allowed`, so assert
  `{"decision":{"result":"allowed"}}`).
- `POST /v1/lookup` with a valid `LookupRequestWire` body returns 200 and a body decoding to
  `LookupPageWire`.
- `POST /v1/relationships`, `/v1/relationships/delete`, `/v1/batch-check`, and `/v1/expand`
  each return 200 for a valid body (proving all six fields route). For the two write paths,
  drive them against the in-memory store's write path or, if the in-memory `TupleStore` fixture
  is read-only, assert the routing reaches the handler by sending a body that yields a typed
  `EnResult` (a 200 with a token, or a 400 envelope) rather than a 404 — a 404 would mean the
  path did not match. State in a comment which outcome the fixture produces.
- **The envelope guard (the point of this milestone):** `POST /v1/check` with a malformed body
  (`not json at all`) returns HTTP 400 and a body that decodes to `ErrorEnvelopeWire` with
  `code == "malformed_request_body"`. This proves `envelopeFormatters`'
  `bodyParserErrorFormatter` is installed and produces the envelope.
- `POST /v1/no-such-path` returns HTTP 404 and a body decoding to `ErrorEnvelopeWire` with
  `code == "not_found"`, proving `notFoundErrorFormatter`.

A `Network.Wai.Test` sketch (adapt names to the actual `wai-extra` API in the pinned version):

```haskell
import Network.Wai.Test
  ( SRequest (..), SResponse (..), defaultRequest, runSession, setPath, srequest )
import Network.HTTP.Types (methodPost)

postJson :: Application -> ByteString -> ByteString -> IO SResponse
postJson application path body =
  runSession
    ( srequest
        SRequest
          { simpleRequest =
              setPath defaultRequest {requestMethod = methodPost} path
          , simpleRequestBody = body
          }
    )
    application
```

Assert on `simpleStatus` and `simpleBody`. Use the same hand-rolled `assertEqual`/`assertBool`
the test file already defines.

Acceptance: `cabal test all` passes. As a manual confirmation that the guard bites, temporarily
change the `check` field's path in `EnApi` from `"check"` to `"checkx"`, rebuild, and confirm
the `POST /v1/check` assertion now fails (a 404); then revert.

### Milestone 3 — Split `En.Servant.API` into vertical slices

Scope: create new modules in `en-servant`, move DTOs/handlers/conversions into them, reduce
`En.Servant.API` to a re-export umbrella, and update `En.Servant.OpenApi`, `En.Client`, the
test, and `en-servant.cabal`. **No type or behavior changes** — only relocation and the record
restructure into sub-records. `nagare` and `kikan-en` build unchanged.

The target module set inside `en-servant/src`:

```text
En/Servant/Wire.hs      -- shared wire vocabulary + conversions:
                        --   ObjectRefWire, SubjectWire, ConsistencyWire, CaveatValueWire,
                        --   CaveatPayloadWire, CaveatContextWire, CheckDecisionWire,
                        --   CaveatObligationWire, plus objectRefTo/FromWire, subjectTo/FromWire,
                        --   consistencyTo/FromWire, valueTo/FromWire, payloadTo/FromWire,
                        --   contextFromWire, decisionToWire, obligationToWire, unknownVariant
En/Servant/Response.hs  -- the MultiVerb machinery (logic unchanged):
                        --   EnResponses, EnResult (..), the hand-written AsUnion instance with
                        --   its exhaustiveness witness, faultToResult, and the handler plumbing
                        --   enHandler, engine, orInvalid, traverseOrInvalid
En/Tuple/Api.hs         -- writeTuples/deleteTuples routes (TupleRoutes record), DTOs
                        --   (WriteTuplesRequestWire, DeleteTuplesRequestWire,
                        --   WriteTuplesResponseWire, TupleWire, TupleCaveatWire), handlers
                        --   (writeTuplesHandler, deleteTuplesHandler), conversions
                        --   (tupleTo/FromWire, tupleCaveatTo/FromWire, tokenToWire)
En/Check/Api.hs         -- check/batch-check routes (CheckRoutes record), DTOs (CheckRequestWire,
                        --   CheckResponseWire, BatchCheckPairWire, BatchCheckRequestWire,
                        --   BatchCheckResponseWire), handlers (checkHandler, batchCheckHandler)
En/Lookup/Api.hs        -- lookup route (LookupRoutes record), DTOs (LookupRequestWire,
                        --   LookupObjectWire, LookupStateWire, LookupPageWire), handler
                        --   (lookupHandler, lookupDeadline), conversions (lookupPageToWire, …)
En/Expand/Api.hs        -- expand route (ExpandRoutes record), DTOs (ExpandRequestWire,
                        --   ExpandNodeWire, ExpandStateWire, ExpandTreeWire), handler
                        --   (expandHandler), conversions (expandTreeToWire, expandNodeToWire, …)
En/Servant/API.hs       -- the umbrella: the EnApi record (mounting the four sub-records), server,
                        --   app, apiProxy, envelopeFormatters, and a re-export list identical to
                        --   today's
En/Servant/Seam.hs      -- unchanged
En/Servant/OpenApi.hs   -- unchanged logic; imports updated to the new type homes
En/Servant/Authorize.hs -- unchanged
```

**The sub-records and the umbrella.** Each slice exports a route record and a handler builder.
For example `En.Check.Api`:

```haskell
data CheckRoutes mode = CheckRoutes
  { check ::
      mode :- "check" :> ReqBody '[JSON] CheckRequestWire
             :> MultiVerb 'POST '[JSON] (EnResponses "The authorization decision" CheckResponseWire) (EnResult CheckResponseWire)
  , batchCheck ::
      mode :- "batch-check" :> ReqBody '[JSON] BatchCheckRequestWire
             :> MultiVerb 'POST '[JSON] (EnResponses "One decision per requested pair, in order" BatchCheckResponseWire) (EnResult BatchCheckResponseWire)
  }
  deriving stock (Generic)

checkRoutesServer ::
  (ConsistencyStore Effectful.:> es, TupleStore Effectful.:> es) =>
  Env es -> CheckRoutes (AsServerT Handler)
checkRoutesServer env =
  CheckRoutes { check = checkHandler env, batchCheck = batchCheckHandler env }
```

Note the `"v1"` prefix is **not** in the slice; it is factored to the umbrella so several
slices mount under one prefix — the shared-prefix property that makes slicing possible. The
umbrella in `En.Servant.API`:

```haskell
data EnApi mode = EnApi
  { relationships :: mode :- "v1" :> NamedRoutes TupleRoutes
  , checks :: mode :- "v1" :> NamedRoutes CheckRoutes
  , lookups :: mode :- "v1" :> NamedRoutes LookupRoutes
  , expands :: mode :- "v1" :> NamedRoutes ExpandRoutes
  }
  deriving stock (Generic)

type EnAPI = NamedRoutes EnApi

server env =
  EnApi
    { relationships = tupleRoutesServer env
    , checks = checkRoutesServer env
    , lookups = lookupRoutesServer env
    , expands = expandRoutesServer env
    }
```

The four umbrella fields all mount at `"v1"` — different fields, one prefix, each owned by its
slice. This is precisely the layout the best-practices document prescribes.

**`En.Servant.API` becomes a re-export umbrella with an identical interface.** Its module header
today exports `EnAPI`, `apiProxy`, `EnServer`, `Env (..)`, `server`, `app`,
`envelopeFormatters`, `EnResponses`, `EnResult (..)`, every `…Wire` type, and the public
conversions (`objectRefToWire`, `objectRefFromWire`, `subjectToWire`, `subjectFromWire`,
`tupleToWire`, `tupleFromWire`, `consistencyToWire`, `consistencyFromWire`). After the split it
must export the **same names**, now by re-export:

```haskell
module En.Servant.API
  ( -- the umbrella's own definitions
    EnAPI, EnApi (..), apiProxy, server, app, envelopeFormatters,
    -- re-exported from the seam (as today)
    EnServer, Env (..),
    -- re-exported from the response module
    EnResponses, EnResult (..),
    -- re-exported wire vocabulary
    module En.Servant.Wire,
    -- re-exported slice DTOs
    module En.Tuple.Api,
    module En.Check.Api,
    module En.Lookup.Api,
    module En.Expand.Api,
  ) where
```

Prefer explicit re-export of the exact names over `module X` re-exports if any name would
otherwise leak or collide; the acceptance test is that the export list a consumer sees is a
superset-equal of today's. Verify mechanically (see Concrete Steps): compare the sorted set of
names `nagare` and the test import from `En.Servant.API`/`En.Client` against the new exports.

**`DuplicateRecordFields` and `NoFieldSelectors` make the split clean.** Both are on in the
`shared` stanza. `CheckRoutes` and `EnApi` can both have a field named `check`-family without a
selector clash (there are no selectors), and the many `…Wire` records that share field names
(`values`, `object`, `subject`, `permission`, …) already rely on `DuplicateRecordFields`; the
codecs use `OverloadedRecordDot` (`wire.objectType`), which continues to work per record.

**Update the OpenAPI module.** `En/Servant/OpenApi.hs` imports every wire type from
`En.Servant.API` today; change those imports to the slice/shared modules
(`En.Servant.Wire`, `En.Tuple.Api`, `En.Check.Api`, `En.Lookup.Api`, `En.Expand.Api`) and
`ErrorEnvelopeWire` still from `En.Servant.Seam`. The `ToSchema` orphan instances and
`enOpenApi`/`ServedAPI`/`appWithOpenApi` are otherwise unchanged. Because the umbrella
re-exports everything, the import could even stay `import En.Servant.API`; prefer the direct
slice imports so the description module also reads concept-first.

**Update the client and test imports.** `En.Client` imports `En.Servant.API` (`..`) — unchanged,
since the umbrella still exports all the names it needs. The test currently imports a long list
of `…Wire` types from `En.Servant.API`; it can keep importing them from `En.Servant.API`
(re-exported) with zero edits, *or* switch to slice imports. Choose zero edits for the DTO
imports to keep the diff small; do switch the four handler helpers to import
`checkHandler`/`batchCheckHandler`/`lookupHandler`/`expandHandler`/`writeTuplesHandler`/
`deleteTuplesHandler` directly from the slices and delete the record-extraction helpers added in
Milestone 1 (they are no longer needed once the handlers are exported by name).

**Update the cabal file.** Add the six new modules to `en-servant/en-servant.cabal`'s
`exposed-modules`. The handlers reference `en-core` concept modules (`En.Check`, `En.Lookup`,
`En.Expand`, `En.Effect.TupleStore`, `En.Effect.ConsistencyStore`, `En.Schema`, `En.Revision`,
`En.Tuple`, `En.Error`) and `effectful` — all already dependencies of `en-servant`; no new
library dependency is needed for the slices.

Use `git mv` where a module is essentially a relocation of an existing block so history follows
where practical; where a slice is assembled from scattered pieces of `API.hs`, a plain add plus
a shrink of `API.hs` is unavoidable — that is expected.

Acceptance: `cabal build all && cabal test all` passes, including the Milestone 2 routing test
unchanged; `grep -c ':<|>' en-servant/src/En/Servant/API.hs` is `0` for the route/server
definitions (the only permissible `:<|>` in `en-servant` is the OpenAPI *mount* in
`OpenApi.hs`); `find en-servant/src -name '*.hs' | grep -iE 'Check|Lookup|Expand|Tuple'` shows
the concept as a directory component (`En/Check/Api.hs`), not a filename under a layer; and both
downstream repos build with no edits.

### Milestone 4 — Amend the document of record

`docs/plans/35-version-the-wire-contract-and-type-the-error-model.md` is the ExecPlan that
established `en`'s current servant surface. Its code blocks specify the `:<|>` chain
(`type EnAPI = "v1" :> ( "relationships" :> … :<|> … )`), the positional server
(`server env :<|> pure enOpenApi`), and even a note about the positional test pattern matches
(`_write :<|> _delete :<|> …`). Those blocks now describe a shape the code no longer has.

Per the ExecPlan revision protocol, do not rewrite plan 35's history. Instead:

- Update the `EnAPI` type block and the server-assembly block in plan 35's relevant milestone
  sections in place to the `NamedRoutes` record form, so a novice reading plan 35 alone is not
  led into rebuilding the chain. Keep its `EnResponses`/`EnResult`/`AsUnion` content intact —
  that content is still accurate and is the reference other services copy.
- Append a dated revision note at the bottom of plan 35 stating: the route type moved to
  `NamedRoutes` under this plan
  (`docs/plans/59-convert-en-servant-to-namedroutes-and-vertical-slices.md`); the DTOs and
  handlers moved into vertical slices (`En.Tuple.Api`, `En.Check.Api`, `En.Lookup.Api`,
  `En.Expand.Api`) with `En.Servant.API` kept as a re-export umbrella for backward compatibility;
  and the `MultiVerb` response model it specifies is unchanged.

Acceptance: plan 35's route-type and server blocks contain no `:<|>` except the OpenAPI mount,
and it carries a dated revision note naming plan 59.


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/en` inside the nix dev shell.

```bash
cd /Users/shinzui/Keikaku/bokuno/en
cabal build all    # baseline: must succeed before you start
cabal test all     # baseline: must pass before you start
```

Confirm how downstream resolves `en`, so a "downstream builds" claim is meaningful:

```bash
grep -nE "en-core|en-servant|en-client|en-postgres|location:|\.\./en|source-repository" \
  /Users/shinzui/Keikaku/bokuno/nagare/cabal.project \
  /Users/shinzui/Keikaku/bokuno/kikan-project/kikan-en/cabal.project
```

Milestone 1 — find every consumer of the route type and client before editing:

```bash
grep -rn "EnAPI\|apiProxy\|:<|>\|client apiProxy\|genericClient" \
  en-servant/src en-client/src en-servant/test | grep -v dist-newstyle
```

Edit `en-servant/src/En/Servant/API.hs`, then `en-client/src/En/Client.hs`, then
`en-servant/test/Main.hs`, then re-check `en-servant/src/En/Servant/OpenApi.hs` builds. Build
after each file; GHC's errors name the next site.

```bash
cabal build all
cabal test all
```

Build downstream (adjust per the `cabal.project` finding; if `en` is git-pinned there, point a
`cabal.project.local` at the local `en` packages first, then revert after):

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare && cabal build all
cd /Users/shinzui/Keikaku/bokuno/kikan-project/kikan-en && cabal build all
```

Commit Milestone 1. Every commit on this plan carries both trailers:

```text
refactor(en-servant): EnAPI as a NamedRoutes record

Convert the six-operation :<|> chain to a flat NamedRoutes record, derive the
en-client via genericClient, and replace the test's positional handler
extraction with record field binds. No wire, handler, or response-type logic
changes; downstream nagare and kikan-en build unchanged.

ExecPlan: docs/plans/59-convert-en-servant-to-namedroutes-and-vertical-slices.md
Intention: intention_01kx3mms73ewyrfy9f61e5c3n6
```

Milestone 2 — extend `en-servant/test/Main.hs`, add `wai`/`wai-extra` to the test stanza,
`cabal test all`, then the deliberate-break check (change a path, confirm failure, revert).
Commit:

```text
test(en-servant): end-to-end routing and envelope guard

ExecPlan: docs/plans/59-convert-en-servant-to-namedroutes-and-vertical-slices.md
Intention: intention_01kx3mms73ewyrfy9f61e5c3n6
```

Milestone 3 — create the slice modules, shrink `En.Servant.API` to the umbrella, update
`OpenApi.hs`/`En.Client`/the test/`en-servant.cabal`. After building, prove the interface did
not shrink:

```bash
# The names nagare and the test pull from the en-servant/en-client public surface:
grep -rhoE "En(Api|Client)?\.[A-Za-z]+|[A-Za-z]+Wire" \
  /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-access/src/Nagare/Access/En.hs \
  | sort -u
cabal build all && cabal test all
cd /Users/shinzui/Keikaku/bokuno/nagare && cabal build all
cd /Users/shinzui/Keikaku/bokuno/kikan-project/kikan-en && cabal build all
```

Commit:

```text
refactor(en-servant): vertical slices for tuple/check/lookup/expand

Move each operation's routes, DTOs, and handler into En.<Concept>.Api; add
En.Servant.Wire (shared vocabulary) and En.Servant.Response (the MultiVerb
machinery). En.Servant.API becomes a re-export umbrella with an identical
public interface, so nagare and kikan-en build with no edits.

ExecPlan: docs/plans/59-convert-en-servant-to-namedroutes-and-vertical-slices.md
Intention: intention_01kx3mms73ewyrfy9f61e5c3n6
```

Milestone 4 — amend `docs/plans/35-…md`. Commit:

```text
docs(en): update EP-35 route blocks for the NamedRoutes refactor

ExecPlan: docs/plans/59-convert-en-servant-to-namedroutes-and-vertical-slices.md
Intention: intention_01kx3mms73ewyrfy9f61e5c3n6
```


## Validation and Acceptance

Beyond `cabal build all && cabal test all`, prove the running service still answers correctly
and that the error envelope still comes back on a malformed body.

Start the standalone server. Authentication is required unless disabled; disable it for the
smoke test so no bearer token is needed:

```bash
cd /Users/shinzui/Keikaku/bokuno/en
EN_AUTH_DISABLED=true just start-server   # runs migrations, then cabal run en-server
```

`start-server` applies migrations against the configured PostgreSQL (`EN_DATABASE_URL` /
`PG_CONNECTION_STRING`) and serves on `EN_PORT` (default 8080). In another shell:

Check endpoint — a well-formed request routes and returns a typed decision. Against a fresh
store with no tuples for this pair, the decision is `denied`, which still proves routing and
the `MultiVerb` success path:

```bash
curl -s -X POST http://localhost:8080/v1/check \
  -H 'content-type: application/json' \
  -d '{"consistency":{"mode":"minimizeLatency"},"context":{"values":{}},"subject":{"kind":"id","objectType":"user","objectId":"alice"},"permission":"view","object":{"objectType":"space","objectId":"project-x"}}'
```

Expected: HTTP 200 with a body of the form `{"decision":{"result":"denied"}}` (or
`{"result":"allowed"}` if tuples grant it). Any 200 `CheckResponseWire` proves `POST /v1/check`
routes to the check handler.

Lookup endpoint:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8080/v1/lookup \
  -H 'content-type: application/json' \
  -d '{"consistency":{"mode":"minimizeLatency"},"subject":{"kind":"id","objectType":"user","objectId":"alice"},"permission":"view","objectType":"space","context":{"values":{}},"limit":10,"cursor":null,"deadlineMillis":null}'
```

Expected: `200`. A `404` would mean `/v1/lookup` did not route — a regression.

**The envelope guard (critical).** A malformed body must come back as the machine-readable
envelope, proving `envelopeFormatters` survived the refactor:

```bash
curl -s -w '\n%{http_code}\n' -X POST http://localhost:8080/v1/check \
  -H 'content-type: application/json' -d 'not json at all'
```

Expected: a JSON body `{"code":"malformed_request_body","message":"…","retryable":false}`
followed by `400`. A plain-text body or a `500` means the `bodyParserErrorFormatter` hook was
lost — stop and fix before proceeding.

Unmatched route — the `notFoundErrorFormatter` envelope:

```bash
curl -s -w '\n%{http_code}\n' -X POST http://localhost:8080/v1/no-such-path -d '{}'
```

Expected: `{"code":"not_found","message":"no such endpoint","retryable":false}` and `404`.

OpenAPI document still describes exactly the served operations:

```bash
curl -s http://localhost:8080/v1/openapi.json | python3 -c 'import sys,json; d=json.load(sys.stdin); print(sorted(d["paths"].keys()))'
```

Expected: `['/v1/batch-check', '/v1/check', '/v1/expand', '/v1/lookup', '/v1/relationships', '/v1/relationships/delete']`.
This is the same set the `openApiDocumentTests` in `en-servant/test/Main.hs` already asserts;
the curl is the runtime confirmation.

Structural acceptance — the thing the slice half of this plan is *for*:

```bash
find en-servant/src -name '*.hs' | grep -iE 'Check|Lookup|Expand|Tuple'
```

Expected: `En/Check/Api.hs`, `En/Lookup/Api.hs`, `En/Expand/Api.hs`, `En/Tuple/Api.hs` — the
concept is a directory, the layer (`Api`) is the filename. No output line puts the concept as
the filename under a layer directory.

```bash
grep -n ':<|>' en-servant/src/En/Servant/API.hs
```

Expected: no matches (the umbrella record has no `:<|>`; the only `:<|>` left in `en-servant`
is the OpenAPI *mount* in `OpenApi.hs`, which is correct).

Downstream proof — both external consumers build against the new layout with no edits:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare && cabal build all && cabal test all
cd /Users/shinzui/Keikaku/bokuno/kikan-project/kikan-en && cabal build all && cabal test all
```

Expected: both succeed. Because no downstream file was edited, success here is the proof that
`En.Servant.API`, `En.Servant.Seam`, and `En.Client` kept their interfaces — the central
promise of this plan for a library with external consumers.


## Idempotence and Recovery

Milestones 1, 2, and 4 are ordinary edits; re-running the build is safe and repeated edits
converge. Commit after each milestone so there is always a clean point to return to;
`git checkout -- .` discards uncommitted work and `git reset --hard HEAD` returns to the last
commit.

Milestone 3 relocates code across modules. Use `git mv` where a module is a straight
relocation so history follows; where a slice is assembled from scattered fragments of
`API.hs`, add the new module and shrink `API.hs` in the same commit. If a move goes wrong
mid-way, the working tree is recoverable with `git checkout -- .` (uncommitted) or
`git reset --hard HEAD` (to the milestone boundary). The riskiest property to preserve is
`En.Servant.API`'s export list; the mechanical name-set comparison in Concrete Steps catches a
dropped re-export before the downstream builds do.

The database is untouched by this plan. `just start-server` runs migrations that are
idempotent (each guarded by an existence check in the `justfile`); no schema changes originate
here. The standalone server can be restarted freely.

If `servant-openapi-hs` turns out to lack `HasOpenApi (NamedRoutes EnApi)` (see Milestone 1),
the fallback `toOpenApi (Proxy @(ToServantApi EnApi))` is a one-line change and is fully
equivalent for document generation; note which path was taken in Surprises & Discoveries.


## Interfaces and Dependencies

No new *library* dependencies for the `en-servant` library or `en-client`. `servant` already
supplies `NamedRoutes`; `Servant.API.Generic` supplies `:-` and `ToServantApi`;
`Servant.Server.Generic` supplies `AsServerT`; `Servant.Client.Generic` supplies `AsClientT`
and `genericClient`. Milestone 2 adds `wai` and `wai-extra` to the `en-servant-tests`
`build-depends` only.

At the end of Milestone 1 these must exist:

```haskell
-- en-servant/src/En/Servant/API.hs
data EnApi mode              -- a Generic record, six fields
type EnAPI = NamedRoutes EnApi
apiProxy :: Proxy EnAPI
server  :: (…) => Env es -> Server EnAPI          -- = EnApi (AsServerT Handler)
app     :: (…) => Env es -> Application

-- en-client/src/En/Client.hs
enClient :: EnClient          -- unchanged type; now built from genericClient
```

At the end of Milestone 3 these must exist, and `En.Servant.API` must still export every name it
exports today:

```haskell
-- en-servant/src/En/Servant/Wire.hs
data ObjectRefWire; data SubjectWire; data ConsistencyWire; data CaveatValueWire
data CaveatPayloadWire; data CaveatContextWire; data CheckDecisionWire; data CaveatObligationWire
-- + objectRefToWire/FromWire, subjectToWire/FromWire, consistencyToWire/FromWire, …

-- en-servant/src/En/Servant/Response.hs
type EnResponses (description :: Symbol) a
data EnResult a
instance AsUnion '[Respond 200 …, Respond 400 …, Respond 422 …, Respond 503 …] (EnResult a)
faultToResult :: EnFault -> EnResult a

-- en-servant/src/En/Tuple/Api.hs
data TupleRoutes mode
tupleRoutesServer :: (…) => Env es -> TupleRoutes (AsServerT Handler)
-- + WriteTuplesRequestWire, DeleteTuplesRequestWire, WriteTuplesResponseWire, TupleWire,
--   TupleCaveatWire, writeTuplesHandler, deleteTuplesHandler

-- en-servant/src/En/Check/Api.hs
data CheckRoutes mode
checkRoutesServer :: (…) => Env es -> CheckRoutes (AsServerT Handler)
-- + CheckRequestWire, CheckResponseWire, BatchCheckPairWire, BatchCheckRequestWire,
--   BatchCheckResponseWire, checkHandler, batchCheckHandler

-- en-servant/src/En/Lookup/Api.hs
data LookupRoutes mode
lookupRoutesServer :: (…) => Env es -> LookupRoutes (AsServerT Handler)
-- + LookupRequestWire, LookupObjectWire, LookupStateWire, LookupPageWire, lookupHandler

-- en-servant/src/En/Expand/Api.hs
data ExpandRoutes mode
expandRoutesServer :: (…) => Env es -> ExpandRoutes (AsServerT Handler)
-- + ExpandRequestWire, ExpandNodeWire, ExpandStateWire, ExpandTreeWire, expandHandler

-- en-servant/src/En/Servant/API.hs  (umbrella; unchanged public interface)
data EnApi mode              -- now four fields, each mounting a NamedRoutes sub-record at "v1"
type EnAPI = NamedRoutes EnApi
apiProxy, server, app, envelopeFormatters
-- re-exports: EnServer, Env (..), EnResponses, EnResult (..), every …Wire type, the public
-- conversions — identical to today.
```

`En.Servant.Seam` (`Env`, `AppEffects`, `EnServer`, `ErrorEnvelopeWire`, `EnFault`,
`enErrorToFault`, `faultToServerError`, `runEngineEither`, `badRequest`, `invalidRequest`,
`batchTooLarge`, `notFound`) and `En.Servant.Authorize` (`requirePermission`) are unchanged
throughout, because `en-server`, `en-example`, `nagare`, and `kikan-en` import them directly.
