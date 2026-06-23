---
id: 8
slug: add-ergonomic-schema-builder-api
title: "Add ergonomic schema builder API"
kind: exec-plan
created_at: 2026-06-23T14:49:31Z
intention: "intention_01kvtf92heejea66xyfrrkgveg"
---

# Add ergonomic schema builder API

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan adds a small, public schema builder API so users can write `en` authorization models in terms of objects, relations, permissions, subjects, and rewrite combinators instead of manually constructing nested `Map` and `Set` values. After the change, a user following `docs/user/getting-started.md` can define a schema with a compact `En.Schema.Builder` import, compile it with the existing `En.Reachability.compile`, and get exactly the same `Schema` semantics, validation errors, schema hash, and reachability graph as before.

The change is intentionally ergonomic, not architectural. The existing `En.Schema.Schema`, `Relation`, `AllowedSubject`, `Rewrite`, caveat types, validation, hashing, and compiler remain the engine-facing model. The new builder layer constructs those same values with fewer repeated names and fewer opportunities to make impossible-by-construction mistakes such as a relation map key disagreeing with the relation record name.


## Progress

- [x] Add `en-core/src/En/Schema/Builder.hs` with a thin builder API over the existing `En.Schema` data types. Completed 2026-06-23T14:56:05Z.
- [x] Expose `En.Schema.Builder` from `en-core/en-core.cabal`. Completed 2026-06-23T14:56:05Z.
- [x] Add focused tests proving the builder produces the same semantic schema as the manual constructors, rejects empty `anyOf` and `allOf` at compile time through non-empty function arguments, and preserves validation behavior. Completed 2026-06-23T14:56:05Z and validated 2026-06-23T14:57:59Z.
- [x] Migrate the core test fixture and `en-server/app/Main.hs` demo schema to the builder where doing so improves readability without obscuring negative validation cases. Completed 2026-06-23T14:56:05Z.
- [x] Update `docs/user/getting-started.md` to introduce the builder as the default authoring API. Completed 2026-06-23T14:56:05Z.
- [x] Update `docs/user/modeling.md` with builder-style examples for permissions, allowed concrete subjects, userset subjects, and caveated rewrites. Completed 2026-06-23T14:56:05Z.
- [x] Update `docs/user/README.md`, `README.md`, and any stale examples that imply users should manually assemble schema maps. Completed 2026-06-23T14:56:05Z.
- [x] Run `cabal build all` and `cabal test en-core-interface-tests`. Completed 2026-06-23T14:57:59Z.


## Surprises & Discoveries

- Discovery: `nix fmt` formatted three unrelated files outside the plan surface: `en-core/src/En/Error.hs`, `en-core/src/En/Prelude.hs`, and `en-migrations/en-migrations.cabal`.
  Evidence: `git diff --stat` after formatting showed those files even though the implementation only touched the builder, tests, server demo, docs, and this plan. The formatter-only changes were restored so the final diff remains scoped to this plan.
  Date: 2026-06-23


## Decision Log

- Decision: Add a separate `En.Schema.Builder` module instead of changing the public `En.Schema` model.
  Rationale: `En.Schema` is already consumed by validation, schema hashing, reachability compilation, tuple checks, lookup, expand, and the Servant surface. A builder module can improve authoring ergonomics while keeping the stable data model and existing engine behavior intact.
  Date: 2026-06-23
- Decision: Recommend importing the builder qualified in docs, for example `import En.Schema.Builder qualified as Schema`.
  Rationale: Short names such as `relation`, `subject`, and `object` are readable in a schema DSL but can collide with record selectors and application domain names when imported unqualified. Qualified import keeps examples clear and avoids polluting user modules.
  Date: 2026-06-23
- Decision: Make non-empty set operations use a head argument plus a list tail rather than a bare list.
  Rationale: `validate` currently rejects `Union []` and `Intersection []` at runtime. Builder functions shaped as `anyOf :: Rewrite -> [Rewrite] -> Rewrite` and `allOf :: Rewrite -> [Rewrite] -> Rewrite` make the common builder path unable to create empty unions or intersections.
  Date: 2026-06-23
- Decision: Export the wrapper types `SchemaObject`, `SchemaRelation`, `SubjectSpec`, `CaveatSpec`, and `ParameterSpec` abstractly from `En.Schema.Builder`.
  Rationale: Public function signatures mention these types, and abstract exports let callers write type signatures without exposing constructors that would make future duplicate-name checks or richer builder diagnostics harder to add.
  Date: 2026-06-23
- Decision: Keep raw `En.Schema` constructors in negative validation tests and in the manual equality fixture, while moving the positive `kikanSchema` fixture and `en-server` demo schema to the builder.
  Rationale: Negative tests intentionally construct invalid schemas such as empty unions, unknown computed usersets, and incompatible tuple-to-userset arrows. Keeping those cases manual preserves their clarity while still making the normal authoring path use `En.Schema.Builder`.
  Date: 2026-06-23


## Outcomes & Retrospective

Implemented `En.Schema.Builder` as a public, dependency-light authoring layer over the existing `En.Schema` data model. The core positive fixture and `en-server` demo schema now use the builder, while raw constructors remain in tests that intentionally create invalid schemas and in a manual fixture used to prove builder equivalence. User-facing docs now introduce `En.Schema.Builder` as the default authoring API and no longer show `relationEntry`, raw `AllowedSubject{...}`, `ComputedUserset (RelationName ...)`, or `TupleToUserset (RelationName ...)` examples.

Validation passed on 2026-06-23 with:

```text
cabal build all
```

and:

```text
Test suite en-core-interface-tests: PASS
1 of 1 test suites (1 of 1 test cases) passed.
```

The final user-facing stale-example search:

```bash
rg "relationEntry|AllowedSubject\\{|ComputedUserset \\(RelationName|TupleToUserset \\(RelationName" docs/user README.md
```

returned no matches.


## Context and Orientation

The current repository is a Haskell library and service named `en`, located at `/Users/shinzui/Keikaku/bokuno/en`. Its `mori.dhall` identifies six packages: `en-core`, `en-migrations`, `en-postgres`, `en-servant`, `en-server`, and `en-client`. The package affected by this plan is `en-core`, because schema authoring types live there and all other packages consume the resulting core values.

The existing schema model is in `en-core/src/En/Schema.hs`. A `Schema` is a record with `objectTypes :: Map ObjectType (Map RelationName Relation)` and `caveats :: Map CaveatName CaveatDefinition`. An object type is a named kind of thing such as `user`, `org`, or `space`. A relation is a named edge or permission on an object type, such as `owner`, `member`, or `view`. An allowed subject is the shape of subject a direct tuple may store, for example a concrete `user` or the userset `org#member`. A rewrite is the Zanzibar-style expression that computes effective members of a relation; `This` means direct tuples, `ComputedUserset` means another relation on the same object, `TupleToUserset` means follow a relation to another object and then evaluate a relation there, and `Union`, `Intersection`, `Exclusion`, and `Caveated` compose or gate those expressions.

The current authoring style is literal and repetitive. `docs/user/getting-started.md`, `docs/user/modeling.md`, `en-server/app/Main.hs`, and `en-core/test/Main.hs` all manually assemble schemas with `Map.fromList`, `Set.singleton`, `RelationName "..."`, `ObjectType "..."`, and local helpers named `relationEntry`. This exposes implementation details that the user should not have to care about and allows local helper mistakes such as constructing a map key and relation record with different names. The core validator catches those mistakes, but a builder can avoid them in normal code.

`en-core/en-core.cabal` currently exposes `En.Schema` but not a builder module. The test suite is `en-core-interface-tests`, with its main file at `en-core/test/Main.hs`. The standalone demo schema is in `en-server/app/Main.hs`. User-facing docs start at `docs/user/README.md`, and the two schema authoring pages that need the most attention are `docs/user/getting-started.md` and `docs/user/modeling.md`.

This plan builds on the completed schema validation work recorded in `docs/plans/3-implement-schema-validation-and-reachability-compilation.md`. That plan implemented `validate`, `schemaHash`, and `En.Reachability.compile`. This plan must not weaken those semantics; it only adds a friendlier way to produce the same values.


## Plan of Work

Milestone 1 adds the builder module without changing existing call sites. Create `en-core/src/En/Schema/Builder.hs` and expose it from `en-core/en-core.cabal`. The module should import `En.Schema` and construct only the existing public data types. At the end of this milestone, existing code still compiles, and a new test can define a schema through the builder and compare it to the equivalent manually constructed schema.

The builder API should be deliberately small:

```haskell
module En.Schema.Builder
    ( build
    , buildWithCaveats
    , object
    , relation
    , permission
    , subject
    , userset
    , caveat
    , parameter
    , this
    , computed
    , arrow
    , anyOf
    , allOf
    , minus
    , caveated
    ) where
```

Use private wrapper types so the builder can accept lists while still returning the existing `Schema`:

```haskell
data SchemaObject = ...
data SchemaRelation = ...
data SubjectSpec = ...
data CaveatSpec = ...
data ParameterSpec = ...
```

The externally useful function signatures should be:

```haskell
build :: [SchemaObject] -> Schema
buildWithCaveats :: [CaveatSpec] -> [SchemaObject] -> Schema
object :: Text -> [SchemaRelation] -> SchemaObject
relation :: Text -> [SubjectSpec] -> Rewrite -> SchemaRelation
permission :: Text -> Rewrite -> SchemaRelation
subject :: Text -> SubjectSpec
userset :: Text -> Text -> SubjectSpec
caveat :: Text -> [ParameterSpec] -> CaveatSpec
parameter :: Text -> CaveatParameterType -> ParameterSpec
this :: Rewrite
computed :: Text -> Rewrite
arrow :: Text -> Text -> Rewrite
anyOf :: Rewrite -> [Rewrite] -> Rewrite
allOf :: Rewrite -> [Rewrite] -> Rewrite
minus :: Rewrite -> Rewrite -> Rewrite
caveated :: Text -> Rewrite -> Rewrite
```

`build` should produce `Schema{objectTypes = ..., caveats = Map.empty}`. `buildWithCaveats` should construct both `objectTypes` and `caveats`. `object` should turn a `Text` into `ObjectType` and relation list into a `Map RelationName Relation`. `relation` should accept direct tuple subject shapes and any rewrite. `permission` should be equivalent to `relation name [] rewrite`, because permissions are computed relations that usually should not accept direct writes. `subject` should construct a concrete subject shape, and `userset` should construct an allowed userset subject shape. `caveat` and `parameter` should construct `CaveatDefinition` values. The rewrite aliases should just wrap existing constructors: `this = This`, `computed name = ComputedUserset (RelationName name)`, `arrow tupleset computedRelation = TupleToUserset (RelationName tupleset) (RelationName computedRelation)`, `anyOf first rest = Union (first : rest)`, `allOf first rest = Intersection (first : rest)`, `minus = Exclusion`, and `caveated name rewrite = Caveated (CaveatName name) rewrite`.

Milestone 2 adds tests and migrates internal examples. Add builder imports to `en-core/test/Main.hs`, preferably qualified as `Schema`. Add a test that `schemaHash builderSchema == schemaHash manualSchema` and that `validate builderSchema == Right ()` for a kikan-shaped fixture. Convert the main positive fixture `kikanSchema` to the builder if the resulting code is clearly easier to read. Keep some negative validation helpers manual when they are intentionally constructing invalid `Schema` values that the builder would make awkward or impossible. Update `en-server/app/Main.hs` to use the builder for its demo schema and remove its local `relationEntry` and `userSubject` helpers if they become unused. At the end of this milestone, the test suite proves the builder is behavior-preserving and the demo server no longer demonstrates the old map-heavy API.

Milestone 3 updates the docs. Rewrite the schema sections of `docs/user/getting-started.md` so the first schema example uses `En.Schema.Builder qualified as Schema` and reads as a model definition. Update `docs/user/modeling.md` to replace `relationEntry`, `AllowedSubject{...}`, `ComputedUserset (RelationName "...")`, and `TupleToUserset (RelationName "...") (RelationName "...")` examples with builder forms. Mention that `En.Schema` still exports the raw data constructors for advanced users and tests that need to construct invalid schemas deliberately. Update `docs/user/README.md` and `README.md` where they describe schemas as Haskell values so readers know the recommended authoring API is the builder.

Milestone 4 validates and cleans up. Run the build and focused test commands. Search for remaining user-facing examples of `relationEntry`, manual `Map.fromList` schema construction, or raw `AllowedSubject` snippets. It is acceptable for internal tests to keep raw constructors for negative cases, but docs should present the builder as the default.


## Concrete Steps

Start from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/en
```

Confirm the project identity and package layout:

```bash
mori show --full
```

Expected output includes `shinzui/en`, package `en-core`, and the package path `en-core`.

Inspect the current schema API and existing authoring examples:

```bash
sed -n '1,220p' en-core/src/En/Schema.hs
sed -n '1,90p' en-core/en-core.cabal
sed -n '280,430p' en-core/test/Main.hs
sed -n '70,115p' en-server/app/Main.hs
sed -n '1,120p' docs/user/getting-started.md
sed -n '35,135p' docs/user/modeling.md
```

Create `en-core/src/En/Schema/Builder.hs`. Implement the functions listed in Plan of Work with `Data.Map.Strict.fromList`, `Data.Set.fromList`, and constructors imported from `En.Schema`. Keep the module dependency-free beyond `containers`, `text`, and `en-core`'s existing dependencies.

Expose the module in `en-core/en-core.cabal` by adding `En.Schema.Builder` to the `exposed-modules` stanza near `En.Schema`.

Add tests in `en-core/test/Main.hs`. A minimal positive test should look like this in shape, though it should be adapted to the surrounding test style:

```haskell
builderSchema :: Schema
builderSchema =
    Schema.build
        [ Schema.object "user" []
        , Schema.object "space"
            [ Schema.relation "viewer" [Schema.subject "user"] Schema.this
            , Schema.permission "view" (Schema.computed "viewer")
            ]
        ]
```

Then assert that it validates and compiles:

```haskell
assertEqual "builder schema validates" (Right ()) (validate builderSchema)
_ <- either (fail . show) pure (compile builderSchema)
```

For behavior preservation, compare either direct equality with an equivalent manual `Schema` or compare `schemaHash` and selected reachability entries. Direct equality is stronger if the expected value is not too verbose.

Update `en-server/app/Main.hs` so `demoSchema` uses the builder. The final code should not need local `relationEntry` or `userSubject` helpers for the demo schema.

Update docs and examples. Search for stale map-heavy schema snippets:

```bash
rg "relationEntry|AllowedSubject\\{|ComputedUserset \\(RelationName|TupleToUserset \\(RelationName|Schema\\s*\\{|objectTypes\\s*=\\s*Map\\.fromList" docs README.md en-server/app en-core/test
```

Do not blindly remove every match. Keep raw constructor examples where the text is explicitly explaining internal types or invalid test construction. Replace user-facing schema authoring examples with the builder.

Run formatting and validation:

```bash
nix fmt
cabal build all
cabal test en-core-interface-tests
```

Expected successful test output contains a final success line from Cabal for `en-core-interface-tests`, with no failing assertions. If `nix fmt` reports formatting changes, review them with `git diff` before continuing.


## Validation and Acceptance

The primary acceptance criterion is that users can define schemas through `En.Schema.Builder` and pass them to the existing `compile`, `check`, `lookup`, and `expand` code without adapters. This is observable by running `cabal test en-core-interface-tests`; the test suite must include a builder-authored schema that validates, compiles, and has the same semantic hash or equality as its manual equivalent.

The build must pass:

```bash
cabal build all
```

The focused core tests must pass:

```bash
cabal test en-core-interface-tests
```

Docs acceptance is textual but concrete. After implementation, a reader opening `docs/user/getting-started.md` should see `import En.Schema.Builder qualified as Schema` and a schema example that does not require `Data.Map.Strict`, `Data.Set`, a local `relationEntry` helper, or raw `AllowedSubject` records. `docs/user/modeling.md` should show `Schema.subject`, `Schema.userset`, `Schema.computed`, `Schema.arrow`, `Schema.anyOf`, and `Schema.caveated` examples.

Run this search after docs are updated:

```bash
rg "relationEntry|AllowedSubject\\{|ComputedUserset \\(RelationName|TupleToUserset \\(RelationName" docs/user README.md
```

The preferred result is no matches in user-facing docs. If a match remains, it must be in a paragraph explicitly explaining the raw `En.Schema` constructors for advanced use.


## Idempotence and Recovery

This work is additive and safe to repeat. Creating `en-core/src/En/Schema/Builder.hs` and exposing it from Cabal does not change storage, migrations, wire formats, consistency tokens, or runtime service configuration. Re-running `nix fmt`, `cabal build all`, and `cabal test en-core-interface-tests` is safe.

If the builder module introduces naming conflicts in a call site, prefer qualified imports such as `import En.Schema.Builder qualified as Schema` instead of renaming the builder API. If converting the large `kikanSchema` fixture makes negative validation tests harder to read, keep negative helpers manual and document that choice in this plan's Decision Log during implementation.

If a validation or reachability test fails after migrating a schema to the builder, compare the manual and builder values with direct equality or `schemaHash`. A mismatch usually means the builder constructed an allowed subject or relation name differently than the original schema. Fix the builder or call site; do not loosen validation to make the test pass.


## Interfaces and Dependencies

Add one public module:

```text
en-core/src/En/Schema/Builder.hs
```

Expose it in:

```text
en-core/en-core.cabal
```

The builder module depends on the existing `En.Schema` types and the already-declared `containers` and `text` package dependencies. It should not add new third-party dependencies.

The following public functions must exist at the end of the plan:

```haskell
build :: [SchemaObject] -> Schema
buildWithCaveats :: [CaveatSpec] -> [SchemaObject] -> Schema
object :: Text -> [SchemaRelation] -> SchemaObject
relation :: Text -> [SubjectSpec] -> Rewrite -> SchemaRelation
permission :: Text -> Rewrite -> SchemaRelation
subject :: Text -> SubjectSpec
userset :: Text -> Text -> SubjectSpec
caveat :: Text -> [ParameterSpec] -> CaveatSpec
parameter :: Text -> CaveatParameterType -> ParameterSpec
this :: Rewrite
computed :: Text -> Rewrite
arrow :: Text -> Text -> Rewrite
anyOf :: Rewrite -> [Rewrite] -> Rewrite
allOf :: Rewrite -> [Rewrite] -> Rewrite
minus :: Rewrite -> Rewrite -> Rewrite
caveated :: Text -> Rewrite -> Rewrite
```

The wrapper types `SchemaObject`, `SchemaRelation`, `SubjectSpec`, `CaveatSpec`, and `ParameterSpec` may be exported abstractly if Haddock or user type signatures need them. Do not expose their constructors unless there is a concrete use case; keeping them abstract preserves freedom to add duplicate-name checks or richer errors later without breaking callers.

The existing `En.Schema.validate :: Schema -> Either EnError ()`, `En.Schema.schemaHash :: Schema -> SchemaHash`, and `En.Reachability.compile :: Schema -> Either EnError ReachabilityGraph` interfaces must remain unchanged.

Revision note 2026-06-23: Created this ExecPlan for adding a schema builder API and updating all relevant docs, associated with `intention_01kvtf92heejea66xyfrrkgveg`.
