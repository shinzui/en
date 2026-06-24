---
id: 21
slug: introduce-a-validated-schema-evidence-type
title: "Introduce a validated-schema evidence type"
kind: exec-plan
created_at: 2026-06-23T21:43:10Z
intention: "intention_01kvv6xk57em8tq254tz5zm8r0"
master_plan: "docs/masterplans/4-harden-the-en-schema-dsl-for-release.md"
---

# Introduce a validated-schema evidence type

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`en` is a Zanzibar-style relationship-based authorization toolkit. "Zanzibar-style" means
permissions are computed by following relationship tuples (facts like "alice is owner of
space project-x") through a set of rewrite rules (for example, "you can view a space if you
own it, are a member, or can view its parent"). The whole authorization model is supplied
by the consuming project as an ordinary Haskell value of type `Schema` (defined in
`en-core/src/En/Schema.hs`). Because the model is just a value, it can be malformed: it can
reference a relation that does not exist, declare an empty union, or contain a rewrite cycle
with no base case. The function `validate :: Schema -> Either EnError ()` (also in
`en-core/src/En/Schema.hs`) checks for exactly these problems, and today the engine's
compiler `compile :: Schema -> Either EnError ReachabilityGraph`
(`en-core/src/En/Reachability.hs`) calls `validate` internally as its first step. So
validation happens, but nothing in the *types* records that it happened: any `Schema` value,
validated or not, can be passed to `compile`, to `schemaHash` (the function that fingerprints
a schema into consistency-token metadata), or to any future consumer, and the author has only
discipline — not the compiler — stopping them from feeding an unvalidated schema to the engine.

After this change, there will be a new type `ValidSchema` (a `newtype` wrapper around
`Schema`) whose mere existence is *evidence* that the wrapped schema passed validation. The
only way to obtain a `ValidSchema` will be to call `validateSchema :: Schema -> Either EnError
ValidSchema`, which runs the same checks `validate` runs and, on success, hands back the
schema wrapped in the evidence type. There will be no exported `ValidSchema` constructor and
no other exported function that produces one, so it is impossible to construct a `ValidSchema`
that bypassed validation. `compile` will be changed to take a `ValidSchema` instead of a
`Schema`, and because validation is the only way `compile` could ever fail (verified by
reading its body — it has no other error path), `compile` becomes a *total* function:
`compile :: ValidSchema -> ReachabilityGraph`, no `Either`. The consistency-token fingerprint
function will likewise demand evidence: `schemaHash :: ValidSchema -> SchemaHash`, so the
value hashed into tokens is provably the one that was validated. A convenience function
`compileSchema :: Schema -> Either EnError ReachabilityGraph` will preserve the old one-call
ergonomics for the common path by running `validateSchema` and then `compile`.

What someone can do after this change that they could not before: they can no longer
accidentally compile or hash an unvalidated schema — the type system rejects it at compile
time. You can see this working two ways. First, `cabal build all` from the repository root
still succeeds and `cabal test en-core-interface-tests` still passes, including a new test
proving that an *invalid* schema yields `Left` from `validateSchema` and therefore produces no
`ValidSchema`. Second, if you (as an experiment) try to write `compile someRawSchema` where
`someRawSchema :: Schema`, the build fails with a GHC type error saying it expected
`ValidSchema` but got `Schema` — the malformed-schema-reaches-engine bug is now unrepresentable.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] 2026-06-24: Add the `ValidSchema` newtype to `En.Schema.Internal` and add `validateSchema :: Schema -> Either EnError ValidSchema`, keeping `validate :: Schema -> Either EnError ()` as a thin wrapper.
- [x] 2026-06-24: Update the `En.Schema` module export list: export `ValidSchema` (type only, no constructor), `unValidSchema`, and `validateSchema`; change `schemaHash` to operate on `ValidSchema`.
- [x] 2026-06-24: Change `schemaHash` to `schemaHash :: ValidSchema -> SchemaHash` and route its internal rendering through the wrapped `Schema`.
- [x] 2026-06-24: Change `compile` in `En.Reachability` to `compile :: ValidSchema -> ReachabilityGraph` (total, no `Either`) and add `compileSchema :: Schema -> Either EnError ReachabilityGraph`.
- [x] 2026-06-24: Update `En.Reachability`'s imports and export list (export `compile` and `compileSchema`); update the internal use of `schemaHash` to pass the `ValidSchema`.
- [x] 2026-06-24: Update `en-server/app/Main.hs` to call `validateSchema demoSchema` once and reuse the resulting `ValidSchema` for both `compile` and `schemaHash`.
- [x] 2026-06-24: Update all compiled non-server call sites: `en-core/test/Main.hs`, `en-core/src/En/Conformance/Kikan.hs`, `en-core/bench/Main.hs`, `en-example/src/En/Example/Host.hs`, and `en-postgres/integration-test/Main.hs`.
- [x] 2026-06-24: Add tests: a `ValidSchema` is only obtainable via `validateSchema`; an invalid schema yields `Left`; `compileSchema` round-trips the existing `kikanSchema` fixture to an identical `ReachabilityGraph`.
- [x] 2026-06-24: Add a new module `En.Schema.Internal` that is the definition home of the `ValidSchema` newtype and exports its constructor plus `unsafeValidSchema :: Schema -> ValidSchema`, marked internal/unsafe, for the EP-22 Template Haskell splice path only.
- [x] 2026-06-24: Break the resulting `En.Schema` <-> `En.Schema.Internal` import cycle by factoring the bare `Schema`/data declarations into `En.Schema.Types`; record the choice in the Decision Log.
- [x] 2026-06-24: Add `En.Schema.Internal` and `En.Schema.Types` to `en-core/en-core.cabal` `exposed-modules`; confirm no new `build-depends` are needed.
- [x] 2026-06-24: Run `cabal build all` and `cabal test en-core-interface-tests` from the repository root and confirm both pass.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery: the validated-schema change touches more compiled call sites than the initial
  plan named. In addition to `en-server/app/Main.hs` and `en-core/test/Main.hs`,
  `en-core/src/En/Conformance/Kikan.hs`, `en-core/bench/Main.hs`,
  `en-example/src/En/Example/Host.hs`, and `en-postgres/integration-test/Main.hs` needed
  updates so raw schemas pass through `compileSchema` or `validateSchema` before compile/hash.
  Date: 2026-06-24

- Discovery: factoring the raw data declarations into `En.Schema.Types` was straightforward
  and kept `En.Schema`'s public re-exports intact while avoiding `.hs-boot`.
  `nix develop --command cabal build en-core:lib:en-core` compiled the new
  `En.Schema.Types`, `En.Schema.Internal`, `En.Schema`, and downstream modules successfully.
  Date: 2026-06-24


## Decision Log

Record every decision made while working on the plan.

- Decision: Keep `validate :: Schema -> Either EnError ()` as a thin wrapper rather than
  removing it. `validateSchema` becomes the primary function (it returns the evidence), and
  `validate` is redefined as `validate = void . validateSchema` (equivalently `() <$
  validateSchema schema`).
  Rationale: The test harness `en-core/test/Main.hs` calls `validate` directly in nine
  `assertValidationFails` cases and one positive case, and `validate` is exported from
  `En.Schema`. Keeping it as a wrapper means those call sites and any external consumer keep
  working unchanged, while all the real checking logic lives in one place. There is no
  behavioral divergence because `validate` is defined in terms of `validateSchema`.
  Date: 2026-06-23

- Decision: Make `compile` total: `compile :: ValidSchema -> ReachabilityGraph` with no
  `Either`.
  Rationale: Reading `compile` in `en-core/src/En/Reachability.hs`, its body is
  `do { validate schema; pure ReachabilityGraph{...} }`. The only failure path is the
  `validate schema` line; the `ReachabilityGraph` construction itself is pure and total
  (it builds maps and lists, with no partial functions). Once the caller has already proven
  validation by holding a `ValidSchema`, there is nothing left for `compile` to fail on, so
  returning a bare `ReachabilityGraph` is honest and removes an impossible error branch from
  every caller.
  Date: 2026-06-23

- Decision: Provide `compileSchema :: Schema -> Either EnError ReachabilityGraph` as a
  convenience that runs `validateSchema` then `compile`.
  Rationale: The common path is "I have a raw `Schema`, give me its graph or tell me why
  it's invalid." Without `compileSchema`, every such caller would have to write
  `fmap compile (validateSchema s)` by hand. `compileSchema` preserves the exact ergonomics
  and signature of the *old* `compile`, so callers that do not care about holding the
  `ValidSchema` evidence (for example the test harness's `compile kikanSchema` calls) migrate
  by a simple rename.
  Date: 2026-06-23

- Decision: Change `schemaHash` to `schemaHash :: ValidSchema -> SchemaHash` rather than
  adding a second function and keeping the `Schema` version.
  Rationale: The master plan (`docs/masterplans/4-harden-the-en-schema-dsl-for-release.md`)
  states the goal that the value feeding consistency-token metadata must be provably
  validated. Keeping a `Schema`-taking `schemaHash` around would leave the unvalidated path
  open, defeating the purpose. `en-server/app/Main.hs` and
  `en-postgres/integration-test/Main.hs` are updated by this plan because they need a
  `SchemaHash` from a local schema value; the en-postgres library modules consume a
  precomputed `SchemaHash` value through config and never call `schemaHash` themselves
  (verified: `En.Postgres.Revision` and `En.Postgres.TupleStore` receive `schemaHash` as a
  record field on `ConsistencyConfig`, not the function), so there is no hidden library
  caller to break.
  Date: 2026-06-23

- Decision: Expose `unValidSchema :: ValidSchema -> Schema` (a read-only accessor) but no
  way to *construct* a `ValidSchema` other than `validateSchema`.
  Rationale: Renderers and the future quasi-quoter (EP-22, EP-24) need to read the wrapped
  `Schema` back out (for example to render it as docs). Exposing the accessor is safe: it
  only lets you go from evidence to the underlying value, never the reverse. The constructor
  `ValidSchema` itself is deliberately *not* in the public `En.Schema` export list, which is
  what makes the evidence trustworthy.
  Date: 2026-06-23

- Decision: Add an internal module `En.Schema.Internal` that is the *home* of the
  `ValidSchema` newtype and re-exports its constructor plus an `unsafeValidSchema :: Schema ->
  ValidSchema` alias; keep the public `En.Schema` module hiding the constructor and exposing
  only `ValidSchema` (type), `unValidSchema`, `validate`, `validateSchema`, and `schemaHash`.
  Add `En.Schema.Internal` to `en-core/en-core.cabal` `exposed-modules`.
  Rationale: EP-22 (`docs/plans/22-add-a-compile-time-schema-quasi-quoter.md`) must splice a
  `ValidSchema` value into a user's module via Template Haskell. A derived/automatic `Lift
  ValidSchema` instance would emit code that names the `ValidSchema` constructor at the splice
  site, where — because the public module hides it — the constructor is not in scope, so the
  user's build would fail and EP-22 could not reconstruct the value. A `.Internal` module is
  the conventional Haskell escape hatch: it is the single, named, auditable surface where the
  constructor is available, and importing a `.Internal` module is a well-understood signal that
  the caller is knowingly stepping outside the safe public contract. Ordinary users who
  `import En.Schema` still cannot fabricate evidence. Crucially, this does NOT weaken the
  guarantee: the only sanctioned non-validating use of the constructor is the EP-22 TH splice,
  and that path still runs `validateSchema` at *compile time* before wrapping — so a spliced
  `ValidSchema` is backed by a real validation, it just happens during compilation rather than
  at runtime. I chose to make `En.Schema.Internal` the type's *definition home* (rather than
  having `En.Schema` define it and `En.Schema.Internal` re-export from it) because a Haskell
  module cannot re-export a constructor that the defining module's export list does not itself
  export; placing the newtype in the Internal module lets both `En.Schema` (curated, no
  constructor) and `En.Schema.TH` (via Internal, with constructor) import exactly what each
  needs from a single source of truth.
  Date: 2026-06-23 (added during cross-plan reconciliation with EP-22)

- Decision: Break the `En.Schema` <-> `En.Schema.Internal` import cycle by factoring the bare
  `Schema` data declarations into a small `En.Schema.Types` module that both import, rather
  than using an `.hs-boot` file.
  Rationale: `En.Schema.Internal` references `Schema` in the `ValidSchema` newtype's field, and
  `En.Schema` imports `ValidSchema` from `En.Schema.Internal` — a mutual import that Haskell
  rejects without `.hs-boot` stubs. `.hs-boot` files are easy to get subtly wrong (the boot
  signature must match exactly) and harder for a novice to maintain, so the default is to move
  the bare `data Schema`/`data ...` declarations into `En.Schema.Types`, which has no cyclic
  dependency: `En.Schema.Types` imports neither `En.Schema` nor `En.Schema.Internal`, and both
  of those import `En.Schema.Types`. The public surface is identical either way: `En.Schema`
  still re-exports `Schema (..)` so existing `import En.Schema (Schema (..))` call sites (the
  builder, the tests, the server) are unaffected. This decision is local to this plan and does
  not change any signature EP-22 or EP-24 consumes.
  Date: 2026-06-24


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

Completed on 2026-06-24. `ValidSchema` is defined in `En.Schema.Internal`, with the
constructor exposed only from that internal module; `En.Schema` re-exports the type name,
`unValidSchema`, `validateSchema`, and a compatibility `validate` wrapper. The raw schema
data declarations now live in `En.Schema.Types`, which avoids an import cycle and preserves
the existing `En.Schema` public re-export surface. `schemaHash` requires `ValidSchema`,
`compile` is total on `ValidSchema`, and `compileSchema` preserves the old raw-schema
ergonomics by validating before compiling.

All compiled callers were migrated. `en-server/app/Main.hs` validates `demoSchema` once and
reuses the evidence for `compile` and `schemaHash`; tests, conformance fixtures, benchmarks,
examples, and the PostgreSQL integration test use either `compileSchema` or a validated
schema value as appropriate. Validation passed with:

```bash
nix develop --command cabal build all
nix develop --command cabal test en-core-interface-tests
```


## Context and Orientation

You are working in the `en` repository (root: the directory containing `en-core/`,
`en-server/`, `en-postgres/`, and `docs/`). `en` is a library and server implementing
ReBAC (relationship-based access control): authorization decisions are computed from
relationship facts plus a rule model. The rule model is a value of type `Schema`.

The files you must understand:

`en-core/src/En/Schema/Types.hs` defines the raw `Schema` data type and everything it
contains. A `Schema` has two fields: `objectTypes` (a map from object type to its relations)
and `caveats` (named conditional predicates). `en-core/src/En/Schema.hs` re-exports those
types, defines `validateSchema :: Schema -> Either EnError ValidSchema`, preserves
`validate :: Schema -> Either EnError ()` as a wrapper, and defines
`schemaHash :: ValidSchema -> SchemaHash`. `schemaHash` renders the wrapped schema to a
canonical text form and hashes it with FNV-1a (a small, deterministic, non-cryptographic
hash) into a `SchemaHash` value used as part of consistency-token metadata. The package uses
GHC2024 with `DerivingStrategies` and `OverloadedRecordDot` enabled (see
`en-core/en-core.cabal`), so record access is written `schema.objectTypes` and newtypes
derive via `deriving stock`.

"Newtype" means a zero-cost wrapper around a single existing type; at runtime it is
identical to the wrapped value, but at compile time it is a distinct type. We use that
distinctness to carry a *proof*: a `ValidSchema` is "a `Schema` that has been validated," and
because we will not export its constructor, no one can fabricate that proof.

`en-core/src/En/Reachability.hs` defines `ReachabilityGraph` (the compiled, traversable form
of a schema), `compile :: ValidSchema -> ReachabilityGraph`, and
`compileSchema :: Schema -> Either EnError ReachabilityGraph`. The total `compile` unwraps
the validated schema, constructs the graph, and stores `hash = schemaHash validSchema`.
`compileSchema` preserves the old raw-schema ergonomics by running `validateSchema` and then
`compile`.

`en-core/src/En/Schema/Builder.hs` provides ergonomic constructors (`build`,
`buildWithCaveats`, `object`, `relation`, `permission`, and so on) that assemble a `Schema`
value. These functions return a plain `Schema` and do *not* validate. That is intentional and
must stay that way: the master plan
(`docs/masterplans/4-harden-the-en-schema-dsl-for-release.md`) mandates that `Schema` remain
freely constructible programmatically. `ValidSchema` is an *additional* evidence layer, not a
replacement for `Schema`, and the builder is out of scope for this plan.

`en-core/src/En/Error.hs` defines `EnError`, the closed sum of engine failures. Validation
failures surface as `SchemaViolation Text` and `UnknownRelation Text`.

`en-server/app/Main.hs` validates `demoSchema` once with `validateSchema`, then reuses the
resulting `ValidSchema` for both `compile` and `schemaHash` inside its `ConsistencyConfig`.
`demoSchema :: Schema` is built at the bottom of the file with the builder.

`en-postgres/src/En/Postgres/Revision.hs` and `en-postgres/src/En/Postgres/TupleStore.hs`
consume a *precomputed* `SchemaHash` through a `schemaHash` field on `ConsistencyConfig`; they
never call the `schemaHash` function. This plan does not touch them, and changing the
`schemaHash` function's signature does not affect them because they only see the already-built
`SchemaHash` value.

`en-core/test/Main.hs` is the interface test harness for `en-core`. It imports the shared
fixture schema `kikanSchema`, validates it into `validKikan`, compiles it with total
`compile validKikan`, checks `graph.hash == schemaHash validKikan`, and runs many
`check`/`lookup`/`expand` assertions against the resulting graph. It also has
`assertValidationFails` cases that each call `validate` on a deliberately broken schema and
expect `Left`, plus evidence-specific assertions for `validateSchema` and `compileSchema`.

Two checked-in sibling plans depend on this one and must consume (not redefine) the types it
introduces: `docs/plans/22-add-a-compile-time-schema-quasi-quoter.md` will splice a
`ValidSchema` from a Template Haskell quasi-quoter, and
`docs/plans/24-render-schemas-as-docs-and-diagrams.md` will accept a `ValidSchema` (or
`Schema`) as render input. There is also a soft relationship to
`docs/plans/20-detect-duplicate-names-in-the-schema-builder.md`: if EP-20 folds duplicate-name
detection into `validate`/`validateSchema`, then `validateSchema` will naturally reject
duplicates too. This plan does not depend on EP-20's code and must compile without it.


## Plan of Work

The work is small and tightly coupled (one type change ripples through four call sites), so
it is organized as four short milestones (1, 2, 2.5, 3), each independently buildable. Read
Milestone 2.5 before starting Milestone 1: it changes *where* the `ValidSchema` newtype is
defined (in a small private module `En.Schema.Internal` rather than directly in `En.Schema`) so
that the EP-22 Template Haskell splice path has a sanctioned way to name the constructor. The
guidance below is written with that final layout already in place.

### Milestone 1 — Define `ValidSchema` and `validateSchema`

Scope: introduce the evidence type and its sole *public* producer, and re-point `schemaHash` to
demand evidence. The evidence newtype itself is declared in a new private module
`En.Schema.Internal` (created here; the rationale and full contents are in Milestone 2.5), and
`En.Schema` imports it and re-exports only the safe parts. At the end of this milestone the new
types exist and `en-core` *as a library* compiles, even though `En.Reachability`, `en-server`,
and the tests have not yet been updated (so `cabal build all` will not pass yet — that is
expected and is fixed in Milestones 2 and 3). The command to run is
`cabal build en-core:lib:en-core` from the repository root; acceptance is that the library
target alone compiles.

First, create `en-core/src/En/Schema/Internal.hs` defining the newtype as its single home (see
Milestone 2.5 for the complete file and the doc comment), and add `En.Schema.Internal` to the
`exposed-modules` list in `en-core/en-core.cabal`. The newtype is:

```haskell
-- | Evidence that a 'Schema' passed validation. Defined here (the Internal module)
-- so both "En.Schema" (which re-exports it WITHOUT the constructor) and
-- "En.Schema.TH" (the EP-22 splice path, which needs the constructor) can see it.
-- The constructor is NOT re-exported from "En.Schema", so ordinary code that
-- imports "En.Schema" cannot fabricate evidence.
newtype ValidSchema = ValidSchema {unValidSchema :: Schema}
    deriving stock (Eq, Show)
```

The remaining Milestone 1 edits are in `en-core/src/En/Schema.hs`.

First, add `import En.Schema.Internal (ValidSchema (..), unValidSchema)` to the import block of
`En.Schema.hs`. This brings the constructor into `En.Schema` so `validateSchema` can use it
internally, but the public *export* list (below) will deliberately re-export `ValidSchema`
without `(..)`, so downstream importers of `En.Schema` never see the constructor.

Second, add `validateSchema` next to `validate`, and redefine `validate` as a thin wrapper.
Replace the current `validate :: Schema -> Either EnError ()` definition's *type signature and
first equation* so that the checking logic moves under `validateSchema` and `validate` becomes
a one-liner. The existing `where`-bound helpers (`validateCaveatDefinition`,
`validateObjectType`, and so on) stay attached to `validateSchema`:

```haskell
-- | Validate a schema and, on success, return it wrapped as evidence.
validateSchema :: Schema -> Either EnError ValidSchema
validateSchema schema = do
    traverse_ validateCaveatDefinition (Map.toAscList schema.caveats)
    traverse_ validateObjectType (Map.toAscList schema.objectTypes)
    validateProductiveCycles schema
    pure (ValidSchema schema)
  where
    -- (all existing helper definitions unchanged)

-- | Validate schema references and rewrite shapes before compilation.
validate :: Schema -> Either EnError ()
validate = void . validateSchema
```

This requires importing `void`; add `import Control.Monad (void)` to the import block. (Verify
whether `Control.Monad` is already imported; if so just add `void` to the existing list.)

Third, change `schemaHash` to take a `ValidSchema`. Its current definition is point-free over
`renderSchema`; rewrite it to unwrap the evidence first:

```haskell
-- | A deterministic semantic schema fingerprint for consistency-token metadata.
-- Takes a 'ValidSchema' so the value fed into token metadata is provably validated.
schemaHash :: ValidSchema -> SchemaHash
schemaHash (ValidSchema schema) =
    SchemaHash (("fnv1a64:" <>) (Text.pack (showHex (fnv1a64 (renderSchema schema)) "")))
```

`renderSchema :: Schema -> Text` and every other helper stay unchanged — they still operate on
the raw `Schema` internally; only the public entry point now requires evidence.

Fourth, update the module export list at the top (lines ~12–32). Re-export `ValidSchema` and
`unValidSchema` (both imported from `En.Schema.Internal`) — note that writing `ValidSchema (..)`
in the export list would re-export the constructor, which we must NOT do; instead export the
*type* and the *field accessor* separately so the constructor stays hidden from public importers.
Write:

```haskell
module En.Schema (
    Schema (..),
    -- ... existing exports unchanged ...
    ValidSchema,        -- type only; constructor intentionally hidden
    unValidSchema,
    validate,
    validateSchema,
    schemaHash,
) where
```

Exporting `ValidSchema` (bare, with no `(..)`) exports only the type name. Exporting
`unValidSchema` separately gives read access to the wrapped schema without exposing the
constructor. This is the linchpin of the design: there is no path to a `ValidSchema` except
`validateSchema`.

### Milestone 2 — Make `compile` take evidence and become total; add `compileSchema`

Scope: change `en-core/src/En/Reachability.hs` so the compiler demands a `ValidSchema` and is
total, and add the `compileSchema` convenience. At the end, `cabal build en-core:lib:en-core`
still passes (now the whole `en-core` library, including reachability, compiles). The command
is the same `cabal build en-core:lib:en-core`; acceptance is a clean library build. The tests
still will not pass until Milestone 3.

The edits, all in `en-core/src/En/Reachability.hs`:

Change the import of `En.Schema` to bring in `ValidSchema` and `validateSchema` and to keep
`schemaHash`. Drop the `validate` import (no longer used here) and the `EnError` import if it
becomes unused — but `EnError` is still used by `compileSchema`'s signature, so keep it. The
import list becomes (add `ValidSchema`, `validateSchema`; remove `validate`):

```haskell
import En.Schema (
    AllowedSubject (..),
    CaveatDefinition,
    CaveatName,
    ObjectType,
    Relation (..),
    RelationName,
    Rewrite (..),
    Schema (..),
    ValidSchema,
    schemaHash,
    validateSchema,
 )
```

Replace the `compile` definition (lines ~89–109). It now destructures the `ValidSchema` to get
the underlying `Schema` for the existing traversal logic, drops the `validate schema` line and
the surrounding `do`/`Either`, and passes the `ValidSchema` to `schemaHash`. Because we cannot
pattern-match on the hidden constructor outside `En.Schema`, unwrap with the exported
`unValidSchema` accessor:

```haskell
-- | Compile a validated schema into the reachability graph 'En.Check.check' and
-- 'En.Lookup.lookup' traverse. Total: the only thing that could fail is validation,
-- and the 'ValidSchema' argument is proof that already happened.
compile :: ValidSchema -> ReachabilityGraph
compile valid =
    ReachabilityGraph
        { entries =
            Map.fromList
                [ (target, compileRelation schema target relation)
                | (objectType, relations) <- Map.toAscList schema.objectTypes
                , (relationName, relation) <- Map.toAscList relations
                , let target = RelationRef{objectType, relation = relationName}
                ]
        , relations =
            Map.fromList
                [ (RelationRef{objectType, relation = relationName}, relation)
                | (objectType, objectRelations) <- Map.toAscList schema.objectTypes
                , (relationName, relation) <- Map.toAscList objectRelations
                ]
        , caveats = schema.caveats
        , hash = schemaHash valid
        }
  where
    schema = unValidSchema valid
```

Add `compileSchema` immediately after `compile`:

```haskell
-- | Validate a raw schema and compile it in one step, preserving the old
-- @compile :: Schema -> Either EnError ReachabilityGraph@ ergonomics.
compileSchema :: Schema -> Either EnError ReachabilityGraph
compileSchema schema = compile <$> validateSchema schema
```

Update the module export list at the top of `En.Reachability` (line ~9) to export both
`compile` and the new `compileSchema`:

```haskell
module En.Reachability (
    ReachabilityGraph (..),
    RelationRef (..),
    SubjectSelector (..),
    EntryPoint (..),
    EntryKind (..),
    RewriteStep (..),
    compile,
    compileSchema,
) where
```

Note `EnError` is still imported (used in `compileSchema`); leave its import in place.

### Milestone 2.5 — Add the `En.Schema.Internal` escape hatch for the EP-22 splice

Scope: add a new module, `En.Schema.Internal`, that deliberately re-exports the `ValidSchema`
constructor and an `unsafeValidSchema :: Schema -> ValidSchema` smart-constructor alias, so the
compile-time quasi-quoter in `docs/plans/22-add-a-compile-time-schema-quasi-quoter.md` (EP-22)
can wrap a schema it has *already validated at compile time* into a `ValidSchema` value to
splice. This is required because Template Haskell's splice mechanism works by emitting source
that is type-checked at the *use* site. If EP-22 derived an automatic `Lift ValidSchema`
instance, the generated expression would name the `ValidSchema` constructor at the splice site,
where — because the public `En.Schema` module hides that constructor — it is not in scope, and
the user's build would fail. The Internal module is the single, named, auditable place where
the constructor is exposed; ordinary users never import it. At the end of this milestone,
`cabal build en-core:lib:en-core` still passes and the new module is part of the library. The
command is the same `cabal build en-core:lib:en-core`; acceptance is a clean library build that
now also exposes `En.Schema.Internal`.

Why this preserves the guarantee: the *only* sanctioned non-validating use of the constructor
is the EP-22 TH splice, and that path still runs `validateSchema` at compile time before it
wraps — so the spliced `ValidSchema` is still backed by a real validation, it just happens
during compilation rather than at runtime. Ordinary application code continues to `import
En.Schema`, where the constructor remains invisible, so the runtime evidence property is
untouched. The Internal module is, by convention in Haskell libraries, an explicit "you are
voiding the warranty" surface: code that imports a `.Internal` module is opting out of the safe
public contract knowingly.

A subtlety drives the module layout, so understand it before writing the file. In Haskell, a
module's export list is the visibility boundary: if `En.Schema`'s export list names
`ValidSchema` *without* `(..)`, then no other module — not even one in the same package — can
import the constructor *from `En.Schema`*. That is exactly the public guarantee we want. But
`En.Schema.Internal` also needs the constructor, and it cannot get it from a module that hides
it. The clean resolution (chosen here) is to make `En.Schema.Internal` the *definition home* of
the newtype: the newtype is declared there, the Internal module exports the constructor, and
`En.Schema` *imports* it from Internal and re-exports only the safe parts. This way the
constructor has a single source of truth that both modules can see, while the public face stays
honest. (The rejected alternative — defining the newtype in `En.Schema` and exporting
`ValidSchema (..)` so Internal can re-export it — would leak the constructor through the public
module, defeating the purpose.)

Therefore the complete file `en-core/src/En/Schema/Internal.hs` is:

```haskell
{- | INTERNAL. Home of the 'ValidSchema' newtype and its constructor, which the
public "En.Schema" module deliberately re-exports WITHOUT the constructor.
Importing this module lets you build a 'ValidSchema' WITHOUT running
'validateSchema', which defeats the evidence guarantee.

Do NOT import this to bypass validation. The only sanctioned use is the
compile-time Template Haskell path in @En.Schema.TH@ (see
@docs/plans/22-add-a-compile-time-schema-quasi-quoter.md@), which runs
'validateSchema' at compile time and then wraps the proven-valid schema for
splicing. There is no constructor in scope at a TH splice site, so that path
needs this module.
-}
module En.Schema.Internal (
    ValidSchema (..),
    unsafeValidSchema,
) where

import En.Schema.Types (Schema)   -- see note below on where 'Schema' comes from

-- | Evidence that a 'Schema' passed validation. Re-exported by "En.Schema"
-- WITHOUT this constructor, so ordinary code cannot fabricate evidence.
newtype ValidSchema = ValidSchema {unValidSchema :: Schema}
    deriving stock (Eq, Show)

-- | INTERNAL/UNSAFE. Wrap a 'Schema' as a 'ValidSchema' without validating it.
-- Equivalent to the bare constructor; provided as a clearly-named alias so call
-- sites read as "unsafe". Only the @En.Schema.TH@ compile-time path should use
-- this, and only after running 'validateSchema' at compile time.
unsafeValidSchema :: Schema -> ValidSchema
unsafeValidSchema = ValidSchema
```

The implementation uses the recommended import-cycle fix: the raw schema data declarations
live in `en-core/src/En/Schema/Types.hs`, and both `En.Schema` and
`En.Schema.Internal` import that module. No `.hs-boot` file is needed. `En.Schema` keeps the
existing public surface by re-exporting `Schema (..)`, `ObjectType (..)`, `Relation (..)`,
and the other raw types from `En.Schema.Types`, so existing consumers can continue importing
from `En.Schema`.

With the newtype's home moved to `En.Schema.Internal`, update Milestone 1's edits accordingly:
`En.Schema.hs` no longer *declares* the newtype; it adds
`import En.Schema.Internal (ValidSchema (..), unValidSchema)`, uses the constructor internally
inside `validateSchema` (`pure (ValidSchema schema)`), and re-exports only `ValidSchema` (type,
no `(..)`) and `unValidSchema` — never the constructor and never `unsafeValidSchema`. Everything
else in Milestone 1 (the `validateSchema`/`validate`/`schemaHash` definitions and the public
export list that names `ValidSchema` without `(..)`) stays as written. The net public surface is:
`import En.Schema` cannot fabricate evidence, while `import En.Schema.Internal` (used solely by
`En.Schema.TH` in EP-22) can.

Finally, add the new module(s) to the library. Edit `en-core/en-core.cabal` and add
`En.Schema.Internal` to the `exposed-modules` list (alphabetically near `En.Schema` and
`En.Schema.Builder`). If you took the recommended `En.Schema.Types` factoring to break the
import cycle (see the discussion above), add `En.Schema.Types` to `exposed-modules` as well (or
to `other-modules` if no out-of-package consumer needs the bare `Schema` type). No new
`build-depends` are needed — the new modules depend only on `base`/`containers`/`text`/`time`,
all already present.

### Milestone 3 — Update the server call site, the tests, and add new tests

Scope: migrate every compiled call site to the new API and add tests that prove the
evidence property. The implementation updates `en-server/app/Main.hs`,
`en-core/test/Main.hs`, `en-core/src/En/Conformance/Kikan.hs`, `en-core/bench/Main.hs`,
`en-example/src/En/Example/Host.hs`, and `en-postgres/integration-test/Main.hs`. At the
end, `cabal build all` and `cabal test en-core-interface-tests` both pass. Commands:
`cabal build all` then `cabal test en-core-interface-tests`, both from the repository root.
Acceptance: the build is clean and every test assertion passes, including the new ones.

Edit `en-server/app/Main.hs`. Change the import from `En.Schema (Schema, schemaHash)` to also
bring in `ValidSchema` and `validateSchema`, and import `compileSchema` is *not* needed because
the server wants the `ValidSchema` to reuse it for both `compile` and `schemaHash`. Validate
once at the top of `main`, then build the graph with the total `compile` and feed the same
evidence to `schemaHash`. Concretely:

Change line 15 from `import En.Reachability (compile)` to keep `compile` (still used). Change
line 17 to `import En.Schema (Schema, ValidSchema, schemaHash, validateSchema)`. Replace the
graph line (line 28) and the `schemaHash demoSchema` usage (line 42) with a single validation
followed by reuse:

```haskell
    validSchema <- either (fail . ("Invalid built-in demo schema: " <>) . show) pure (validateSchema demoSchema)
    let graph = compile validSchema
```

and inside the `ConsistencyConfig` record change `schemaHash = schemaHash demoSchema` to
`schemaHash = schemaHash validSchema`. Because `compile` is now total, `graph` is bound with a
pure `let` rather than `<-`/`fail`; the only failure path that remains is `validateSchema`,
which is handled by the `either (fail ...) pure` above.

Edit `en-core/test/Main.hs`. The harness currently imports `compile` from `En.Reachability`
and `validate`/`schemaHash` from `En.Schema`. Make these changes:

In the `En.Reachability` import block (lines ~34–42), add `compileSchema` (keep `compile`,
which the new tests will use directly against a `ValidSchema`).

In the `En.Schema` import block (lines ~44–61), add `ValidSchema` and `validateSchema` (keep
`validate` and `schemaHash`).

The existing positive `validate` assertions and the nine `assertValidationFails` cases keep
working unchanged because `validate` is still exported and still has type
`Schema -> Either EnError ()`.

The two places that call `compile` on a raw schema must change. Line ~89
`graph <- either (fail . show) pure (compile kikanSchema)` becomes
`graph <- either (fail . show) pure (compileSchema kikanSchema)`. Line ~120
`minLevelGraph <- either (fail . show) pure (compile minLevelSchema)` becomes
`minLevelGraph <- either (fail . show) pure (compileSchema minLevelSchema)`.

The two `schemaHash` call sites currently pass raw schemas: line ~86
`assertEqual "builder schema hash matches manual schema hash" (schemaHash kikanSchemaManual)
(schemaHash kikanSchema)`, line ~90 `assertEqual "graph stores schema hash" (schemaHash
kikanSchema) graph.hash`, and line ~91 the reordered-schema stability check. Since `schemaHash`
now needs a `ValidSchema`, validate first and reuse. The cleanest approach is to introduce
local validated bindings at the top of `main` and use them everywhere a hash is needed. Add,
near the start of `main`:

```haskell
    validKikan <- either (fail . show) pure (validateSchema kikanSchema)
    validKikanManual <- either (fail . show) pure (validateSchema kikanSchemaManual)
    validKikanReordered <- either (fail . show) pure (validateSchema kikanSchemaReordered)
```

Then rewrite the three hash assertions to use these bindings, for example
`assertEqual "builder schema hash matches manual schema hash" (schemaHash validKikanManual)
(schemaHash validKikan)`, `assertEqual "graph stores schema hash" (schemaHash validKikan)
graph.hash`, and `assertEqual "schema hash is stable across map insertion order" (schemaHash
validKikan) (schemaHash validKikanReordered)`.

Finally, add three new assertions that prove the evidence property and the round-trip. Place
them after the existing schema-hash assertions in `main`:

```haskell
    assertBool "validateSchema produces evidence for a valid schema" (isRight (validateSchema kikanSchema))
    assertBool "validateSchema rejects an invalid schema (no evidence)" (isLeft (validateSchema unproductiveCycleSchema))
    assertEqual "compileSchema round-trips identically to compile . validateSchema" (Right (compile validKikan)) (compileSchema kikanSchema)
```

The first asserts a `ValidSchema` is obtainable for a good schema; the second asserts an
invalid schema yields `Left` and therefore no `ValidSchema` (we reuse the existing
`unproductiveCycleSchema` fixture, which `validate` already rejects); the third asserts
`compileSchema kikanSchema` equals `compile` applied to the separately validated schema,
proving the convenience wrapper and the fixture's compiled graph are unchanged (`ReachabilityGraph`
derives `Eq`). Add `import Data.Either (isLeft, isRight)` to the test's imports for the helpers
(verify it is not already imported; if `Data.Either` is present, add the names to it).

It is also worth keeping the original "graph for kikan is unchanged" guarantee explicit. The
existing `check`/`lookup`/`expand` assertions already exercise the graph built from
`kikanSchema`; because `compileSchema kikanSchema` produces the same `ReachabilityGraph` value
the old `compile kikanSchema` did (same inputs, same pure construction), those assertions
continue to pass unchanged and serve as the end-to-end proof that behavior is preserved.

Also migrate the additional compiled callers discovered during implementation:
`en-core/src/En/Conformance/Kikan.hs`, `en-core/bench/Main.hs`, and
`en-example/src/En/Example/Host.hs` use `compileSchema` for raw schema fixtures.
`en-postgres/integration-test/Main.hs` validates `checkSchema` once, uses the resulting
`ValidSchema` for `Schema.schemaHash`, and passes that same evidence to total `compile`.


## Concrete Steps

All commands are run from the repository root (the directory containing `en-core/`,
`en-server/`, and `cabal.project`). The toolchain is Cabal with GHC; the build defines the
`en-core` library, the `en-core-interface-tests` test suite, and the `en-server` executable.

Step 1 — make the Milestone 1 edits: create `en-core/src/En/Schema/Internal.hs` (defining the
`ValidSchema` newtype), add `En.Schema.Internal` to `en-core/en-core.cabal` `exposed-modules`,
and edit `en-core/src/En/Schema.hs` (import the newtype from Internal, add `validateSchema`,
re-point `schemaHash`, update the export list). Then build just the library to check the type
compiles:

```bash
cabal build en-core:lib:en-core
```

At the end of Milestone 1 this will succeed for the library. (If you build `all` now it will
fail, because `En.Reachability` still calls the old `compile`/`schemaHash` shapes — that is
expected until Milestone 2.)

Step 2 — make the Milestone 2 edits to `en-core/src/En/Reachability.hs`, then rebuild the
library:

```bash
cabal build en-core:lib:en-core
```

Expected: a clean build with no errors. If GHC reports `Variable not in scope: validate`, you
left a stale reference in `En.Reachability`; remove it (compile no longer calls `validate`).

Step 2.5 — make the Milestone 2.5 edits: finish `en-core/src/En/Schema/Internal.hs` by adding
the `unsafeValidSchema` alias and the internal-only export list, and confirm `En.Schema.Internal`
is in `en-core/en-core.cabal`. (If you already created the file in full during Step 1, this step
is just verification.) Rebuild the library:

```bash
cabal build en-core:lib:en-core
```

Expected: a clean library build that now exposes `En.Schema.Internal`. You can sanity-check the
module is exposed with `cabal repl en-core` and `:browse En.Schema.Internal`, which should list
`ValidSchema`, `unValidSchema`, and `unsafeValidSchema`.

Step 3 — make the Milestone 3 edits to all compiled callers named above, then build
everything:

```bash
cabal build all
```

Expected: all targets compile. A useful negative check that the evidence type does its job:
temporarily change a test line to `compile kikanSchema` (passing a raw `Schema`) and rebuild;
GHC should fail with a message resembling:

```text
    • Couldn't match expected type 'ValidSchema'
                  with actual type 'Schema'
    • In the first argument of 'compile', namely 'kikanSchema'
```

Revert that temporary change before continuing.

Step 4 — run the interface test suite:

```bash
cabal test en-core-interface-tests
```

Expected: the suite exits 0. A passing run prints a summary line resembling:

```text
1 of 1 test suites (1 of 1 test cases) passed.
```

If an assertion fails, the harness prints the assertion label followed by `expected:` and
`actual:` lines (see `assertEqual`/`assertBool` in `en-core/test/Main.hs`), which tells you
exactly which property regressed.

This section will be updated with the actual observed transcripts as the work is executed.


## Validation and Acceptance

The change is internal (it adds a type-level guarantee), so its impact is demonstrated through
the type checker plus tests that fail before and pass after.

The primary acceptance is behavioral: from the repository root, `cabal build all` succeeds and
`cabal test en-core-interface-tests` passes. Among the passing assertions are three new ones
added by this plan, each phrased as a concrete input/output:

Given the well-formed fixture `kikanSchema`, `validateSchema kikanSchema` returns `Right
(...)` — that is, evidence is obtainable — so the assertion "validateSchema produces evidence
for a valid schema" holds.

Given the deliberately broken fixture `unproductiveCycleSchema` (two relations `a` and `b`
that compute each other with no `This` base case), `validateSchema unproductiveCycleSchema`
returns `Left (SchemaViolation "...")` — no `ValidSchema` is produced — so the assertion
"validateSchema rejects an invalid schema (no evidence)" holds. This is the core safety
property: an invalid schema can never become evidence.

Given `kikanSchema`, `compileSchema kikanSchema` equals `Right (compile validKikan)` where
`validKikan` is the same schema validated independently, so the assertion "compileSchema
round-trips identically" holds. Because `ReachabilityGraph` derives `Eq`, this is an exact
structural equality, proving the reachability graph for `kikanSchema` is byte-for-byte
unchanged from before this plan.

Beyond those three, the entire pre-existing suite — the `check`, `lookup`, and `expand`
scenarios that run against the graph compiled from `kikanSchema`, and the nine
`assertValidationFails` cases — continues to pass unchanged, which demonstrates that rerouting
`compile` and `schemaHash` through the evidence type changed no runtime behavior.

The type-level guarantee itself is acceptance too: after this change, `compile` expects a
`ValidSchema`. The negative check in Concrete Steps (temporarily passing a raw `Schema` to
`compile` and observing the GHC type error) demonstrates that an unvalidated schema can no
longer reach the engine — the bug this plan exists to prevent is now a compile error.


## Idempotence and Recovery

Every step in this plan is an additive or substitutive source-code edit followed by a build or
test command, and all of those are safe to repeat. Re-running `cabal build all` or `cabal test
en-core-interface-tests` any number of times has no side effects beyond recompilation; there
are no migrations, no data writes, and no destructive operations. The `en-postgres` and
`en-server` runtime paths are untouched at runtime — only the server's startup code changes,
and it changes how the schema is validated, not what it writes.

If an edit leaves the tree in a non-building state mid-milestone, that is expected between
milestones (Milestone 1 leaves `En.Reachability` referring to the old `compile` shape until
Milestone 2 fixes it). The recovery path is simply to finish the next milestone's edits; the
plan is ordered so that completing all four milestones (1, 2, 2.5, 3) always reaches a clean
`cabal build all`. This plan adds `en-core/src/En/Schema/Internal.hs` and
`en-core/src/En/Schema/Types.hs`, and edits `en-core/src/En/Schema.hs`,
`en-core/src/En/Reachability.hs`, `en-core/en-core.cabal`, `en-server/app/Main.hs`,
`en-core/test/Main.hs`, `en-core/src/En/Conformance/Kikan.hs`, `en-core/bench/Main.hs`,
`en-example/src/En/Example/Host.hs`, and `en-postgres/integration-test/Main.hs`. To
abandon the work entirely, restore those edited files and remove the two new schema
modules.

Because `ValidSchema` is a zero-cost newtype and `validate` is preserved as a wrapper over
`validateSchema`, there is no behavioral drift to recover from even on partial application: any
external code still calling `validate` keeps the exact same semantics.


## Interfaces and Dependencies

This plan touches only `en-core` and the one server that consumes it. No new libraries or
external dependencies are introduced. The only standard-library additions are
`Control.Monad (void)` in `En.Schema` and `Data.Either (isLeft, isRight)` in the test harness,
both from `base`, which is already a dependency. This plan adds one new exposed module,
`En.Schema.Internal`, and (under the recommended cycle-resolution) one more module
`En.Schema.Types` that holds the bare `Schema` data declarations. So `en-core/en-core.cabal`
requires adding `En.Schema.Internal` (and `En.Schema.Types`, as `exposed-modules` or
`other-modules`) to the library stanza. No new `build-depends` are needed (the new modules use
only the already-present `base`/`containers`/`text`/`time`).

This plan OWNS the following types and signatures. They must exist, with these exact shapes, at
completion. Sibling plans consume them and must not redefine them.

The `ValidSchema` newtype is defined in the new module `En.Schema.Internal`
(`en-core/src/En/Schema/Internal.hs`), which is its single source of truth. That module's
public surface (it is a deliberately-unsafe internal module) is:

```haskell
module En.Schema.Internal (
    ValidSchema (..),          -- constructor INCLUDED here (this is the escape hatch)
    unValidSchema,             -- field accessor (also re-exported safely by En.Schema)
    unsafeValidSchema,         -- = ValidSchema; named "unsafe" so call sites read clearly
) where

import En.Schema.Types (Schema)   -- bare data type, factored out to break the import cycle

newtype ValidSchema = ValidSchema {unValidSchema :: Schema}
    deriving stock (Eq, Show)

unsafeValidSchema :: Schema -> ValidSchema   -- INTERNAL/UNSAFE; wraps WITHOUT validating
```

At the end of Milestone 1, module `En.Schema` (`en-core/src/En/Schema.hs`) imports the type
from `En.Schema.Internal` and re-exports only the safe parts:

```haskell
-- imported by En.Schema:  import En.Schema.Internal (ValidSchema (..), unValidSchema)
-- re-exported by En.Schema (public surface):
--   ValidSchema  -- type ONLY, no (..): the constructor is NOT public
--   unValidSchema, validate, validateSchema, schemaHash

validateSchema :: Schema -> Either EnError ValidSchema
validate       :: Schema -> Either EnError ()                 -- thin wrapper: void . validateSchema
schemaHash     :: ValidSchema -> SchemaHash
unValidSchema  :: ValidSchema -> Schema                        -- the exported accessor
```

So an ordinary `import En.Schema` cannot fabricate evidence (no constructor, no
`unsafeValidSchema`), while `import En.Schema.Internal` — used solely by `En.Schema.TH` in
EP-22 — can wrap a compile-time-validated schema. `EnError` comes from `En.Error`; `SchemaHash`
from `En.Revision`.

At the end of Milestone 2, in module `En.Reachability` (`en-core/src/En/Reachability.hs`):

```haskell
compile       :: ValidSchema -> ReachabilityGraph                  -- total, no Either
compileSchema :: Schema -> Either EnError ReachabilityGraph        -- compile <$> validateSchema
```

Both are exported. `compile` imports `ValidSchema`, `validateSchema`, and `schemaHash` from
`En.Schema`; it no longer imports `validate`.

At the end of Milestone 3, `en-server/app/Main.hs` validates `demoSchema` exactly once into a
local `validSchema :: ValidSchema` and reuses it for `compile validSchema` (now total) and
`schemaHash validSchema` inside its `ConsistencyConfig`. The test harness
`en-core/test/Main.hs` uses `compileSchema` where it previously used `compile`, and validated
local bindings (`validKikan`, `validKikanManual`, `validKikanReordered`) wherever `schemaHash`
is needed. `en-core/src/En/Conformance/Kikan.hs`, `en-core/bench/Main.hs`, and
`en-example/src/En/Example/Host.hs` use `compileSchema` for raw schema fixtures.
`en-postgres/integration-test/Main.hs` validates `checkSchema` once and reuses that
`ValidSchema` for both `Schema.schemaHash` and total `compile`.

Integration points with other checked-in plans:

`docs/plans/22-add-a-compile-time-schema-quasi-quoter.md` (EP-22) hard-depends on this plan. Its
quasi-quoter will splice a `ValidSchema` produced at compile time. The integration contract is:
EP-22's `En.Schema.TH` module imports `validateSchema` from the public `En.Schema` and imports
the constructor (via `ValidSchema (..)`) or `unsafeValidSchema` from `En.Schema.Internal`
(`en-core/src/En/Schema/Internal.hs`, owned and created by THIS plan). At splice-generation time
EP-22 runs `validateSchema` on the parsed schema at *compile time*; on `Right valid` it emits a
splice that reconstructs the value using the constructor/`unsafeValidSchema` from
`En.Schema.Internal`, and on `Left err` it fails the build with a Template Haskell error carrying
the `EnError` text. EP-22 must NOT define its own evidence type, must NOT add its own constructor
re-export (it consumes the one here), and must NOT re-touch the `en-server/app/Main.hs` call
site — this plan owns that update. The reason the constructor must come from `En.Schema.Internal`
rather than `En.Schema` is purely a Haskell scoping fact: the public `En.Schema` hides the
constructor, so a splice that named it via `En.Schema` would not type-check at the user's call
site; `En.Schema.Internal` is the single sanctioned surface where it is in scope. Because the
splice still validates at compile time before wrapping, the evidence guarantee is preserved end
to end.

`docs/plans/24-render-schemas-as-docs-and-diagrams.md` (EP-24) soft-depends on this plan. Its
renderer accepts a `ValidSchema` (preferred, since rendering a validated model is the safe
default) or a plain `Schema`; it reads the underlying schema via the exported `unValidSchema`
accessor rather than re-validating or redefining anything. EP-24 must not re-touch the
`en-server` call site either.

`docs/plans/20-detect-duplicate-names-in-the-schema-builder.md` (EP-20) is a soft dependency,
not a hard one. If EP-20 adds duplicate-name detection inside `validate`/`validateSchema`, then
`validateSchema` will reject duplicate-named objects/relations as part of producing a
`ValidSchema`, which strengthens the evidence at no cost to this plan. This plan does not need
EP-20's code to compile, and nothing here assumes duplicate detection is present.

`en-postgres` (`En.Postgres.Revision`, `En.Postgres.TupleStore`) is explicitly NOT a
dependency of the `schemaHash` signature change: those modules receive an already-computed
`SchemaHash` value through the `schemaHash` field of `ConsistencyConfig` and never call the
`schemaHash` function, so changing the function to take a `ValidSchema` does not affect them.
