---
id: 20
slug: detect-duplicate-names-in-the-schema-builder
title: "Detect duplicate names in the schema builder"
kind: exec-plan
created_at: 2026-06-23T21:43:10Z
intention: "intention_01kvv6xk57em8tq254tz5zm8r0"
master_plan: "docs/masterplans/4-harden-the-en-schema-dsl-for-release.md"
---

# Detect duplicate names in the schema builder

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`en` is an authorization toolkit. The authorization model — which object types exist,
which relations they have, which permissions are derived, and which caveats (conditional
rules) gate access — is written as a Haskell value called a `Schema`. Most consumers do
not hand-build that value; they author it through a small constructor library, the
"builder DSL", in the module `En.Schema.Builder` (file `en-core/src/En/Schema/Builder.hs`).
A typical schema looks like `Schema.object "space" [ Schema.relation "owner" ... ,
Schema.relation "member" ... ]`.

Today the builder has a silent, security-relevant bug. Internally it collects the
relations of an object (and the object types of a schema, the caveats of a schema, and the
parameters of a caveat) into a `Data.Map.Strict.Map` using `Map.fromList`. `Map.fromList`
resolves duplicate keys by **silently keeping the last value and discarding all earlier
ones**. So if someone writes the same name twice — `Schema.object "space" [ relation
"owner" subjectsA rewriteA, relation "owner" subjectsB rewriteB ]` — the first `owner`
relation is silently thrown away and only the second survives. In an authorization model,
a silently dropped relation is a hole: the access rule the author believed they declared
is simply not in the compiled model, and nothing tells them. The runtime validator
`En.Schema.validate` cannot catch this, because by the time it runs the duplicate has
already been collapsed away inside the `Map`; `validate` only ever sees the single
surviving entry.

After this change, the builder **detects and reports** a duplicate name instead of
silently swallowing it, for all four name classes that flow through `Map.fromList`:
object types, relations within one object, caveats, and parameters within one caveat. The
user-visible behavior is that the builder entry points return `Either EnError Schema`
(and `Either EnError SchemaObject`, etc.) and produce a `Left (SchemaViolation "duplicate
relation declared: space#owner")` (or the analogous message for the other three classes)
when a name is declared more than once. A consumer can see this working by writing a
schema with two relations named `owner` on the same object and observing that building it
yields a descriptive `Left` rather than a quietly-wrong `Schema`. The error wording is
stable and descriptive on purpose, because a sibling plan (`docs/plans/22-add-a-compile-time-schema-quasi-quoter.md`)
will surface the *same* duplicate condition at compile time and should be able to reuse
this message.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Read `en-core/src/En/Schema/Builder.hs`, `en-core/src/En/Schema.hs`, and
      `en-core/src/En/Error.hs` and confirm the three `Map.fromList` sites (around lines
      74, 86, and 123 of `Builder.hs`) match the descriptions in this plan.
- [ ] Add the `fromListUnique` helper to `En.Schema.Builder` and the `SchemaError` import
      wiring as described under Plan of Work (Milestone 1).
- [ ] Change `buildWithCaveats`, `build`, `object`, `caveat`, and `caveatWith` to return
      `Either EnError ...` and route every collection through `fromListUnique` with a
      duplicate-message builder for each of the four name classes (Milestone 1).
- [ ] Write the four NEW negative tests in `en-core/test/Main.hs` (one per name class),
      each asserting the build returns `Left (SchemaViolation <expected message>)`
      (Milestone 2).
- [ ] Confirm the new tests FAIL against the unmodified builder (run them on a stash of
      the builder change to prove they catch the bug), then pass after the fix
      (Milestone 2).
- [ ] Update the existing call sites that now see an `Either`: the `kikanSchema` /
      `kikanSchemaManual` fixtures and helpers in `en-core/test/Main.hs`, and `demoSchema`
      in `en-server/app/Main.hs` (Milestone 3).
- [ ] Run `cabal build all` and `cabal test en-core-interface-tests` from the repo root
      and confirm both pass (Validation and Acceptance).
- [ ] Fill in Surprises & Discoveries, Decision Log dates, and Outcomes & Retrospective.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Implement duplicate detection inside the builder by routing every
  `Map.fromList` collection through a new `fromListUnique :: Ord k => (k -> EnError) ->
  [(k, v)] -> Either EnError (Map k v)` helper, and lift the affected builder entry points
  (`build`, `buildWithCaveats`, `object`, `caveat`, `caveatWith`) to return
  `Either EnError ...`. The duplicate is reported with the existing
  `En.Error.SchemaViolation Text` constructor.
  Rationale: Two options were considered (analysis below). Both were judged against the
  goal of catching the duplicate *before* it is lost.

  Option A — "validation-side detection": keep the builder pure (returning `Schema`,
  `SchemaObject`, etc.) and make `En.Schema.validate` report duplicates. This is
  structurally impossible without changing the data model, because the duplicate is gone
  the instant `Map.fromList` runs inside the builder; `validate` only receives the final
  `Schema`, whose `Map`s already contain one entry per name. To make it work the builder
  would have to *carry* the original association lists (or a per-key count) alongside the
  `Map` so `validate` could inspect multiplicity — i.e. either change the public `Schema`
  type in `En.Schema` to hold redundant bookkeeping the rest of the engine
  (reachability, check, lookup, hashing) does not want, or invent a parallel "unvalidated
  schema" type. That is a larger, more invasive change that pollutes the core data model
  for a builder-only concern.

  Option B (chosen) — "builder-side detection via `fromListUnique`": the builder is the
  exact place that has both the duplicate information (the raw list, before deduping) and
  the obligation to dedupe, so it is the natural place to detect the collision. The cost
  is that `build`/`object`/`caveat` change from pure values to `Either EnError ...`, which
  is a breaking API change touching the two call sites (`en-core/test/Main.hs` and
  `en-server/app/Main.hs`). That cost is small, mechanical, and contained, and the
  resulting signatures honestly advertise that schema construction can fail. We do not
  introduce a new `EnError` constructor; `SchemaViolation Text` already means "a schema is
  structurally invalid", which is exactly this case, and reusing it keeps the error
  surface closed and avoids a churny breaking change to `En.Error`.
  Rationale (continued): `validate` is intentionally *not* extended to re-check
  duplicates, because after this change a `Schema` value can no longer contain an
  undetected duplicate name in any of the four classes — the only way to obtain a `Schema`
  is through the builder (or by hand-constructing `Map`s, which cannot have duplicate
  keys by definition). Duplicate detection therefore belongs at construction time, not
  re-validation time.
  Date: (to be filled when the decision is committed)

- Decision: The duplicate-error messages are stable, descriptive, and qualified by their
  enclosing scope: `"duplicate object type declared: <name>"`,
  `"duplicate relation declared: <object>#<relation>"`,
  `"duplicate caveat declared: <name>"`, and
  `"duplicate caveat parameter declared: <caveat>.<parameter>"`.
  Rationale: `docs/plans/22-add-a-compile-time-schema-quasi-quoter.md` (EP-22) will surface
  the same duplicate condition at compile time and is expected to reuse this wording, so
  it must not change casually. The `<object>#<relation>` form mirrors the existing
  `relationText` rendering used elsewhere in `En.Schema.validate` (e.g. "relation map key
  does not match relation name: space#owner"), keeping the engine's diagnostics consistent.
  Date: (to be filled when the decision is committed)


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This task lives entirely inside the `en-core` library and its test suite, with one tiny
follow-on edit in `en-server`. The reader needs to know four files.

`en-core/src/En/Schema.hs` defines the raw authorization data types and the runtime
validator. The relevant types are `Schema` (a record with `objectTypes ::
Map ObjectType (Map RelationName Relation)` and `caveats :: Map CaveatName
CaveatDefinition`), `Relation`, `AllowedSubject`, `Rewrite`, and `CaveatDefinition` (which
itself holds `parameters :: Map CaveatParameterName CaveatParameterType`). The function
`validate :: Schema -> Either EnError ()` checks references and rewrite shapes; it is *not*
where duplicates can be caught, for the reason explained in the Decision Log. The newtypes
`ObjectType`, `RelationName`, `CaveatName`, and `CaveatParameterName` all wrap `Text` and
all derive `Ord`, so each is usable as a `Map` key and each can be rendered back to its
`Text` for an error message.

`en-core/src/En/Error.hs` defines `data EnError` — the closed set of engine failures. The
constructor this plan uses is `SchemaViolation Text`, documented as "A relationship tuple
referenced a subject/object that violates the schema", which we treat more broadly as "the
schema is structurally invalid". `EnError` derives `Eq` and `Show`, so tests can compare
an expected `Left (SchemaViolation "...")` for exact equality.

`en-core/src/En/Schema/Builder.hs` is the builder DSL this plan edits. It defines opaque
wrapper types `SchemaObject`, `SchemaRelation`, `CaveatSpec`, and `ParameterSpec`, plus the
entry points. The four problem sites are:

```haskell
buildWithCaveats :: [CaveatSpec] -> [SchemaObject] -> Schema
buildWithCaveats caveatSpecs objectSpecs =
    Raw.Schema (Map.fromList (objectEntry <$> objectSpecs)) (Map.fromList (caveatEntry <$> caveatSpecs))
    -- ^ object types collapse here          ^ caveats collapse here

object :: Text -> [SchemaRelation] -> SchemaObject
object name relations =
    SchemaObject (Raw.ObjectType name) (Map.fromList (relationEntry <$> relations))
    -- ^ relations within one object collapse here

caveatWith :: Text -> [ParameterSpec] -> CaveatPredicate -> CaveatSpec
caveatWith name parameterSpecs predicate =
    CaveatSpec caveatName (Raw.CaveatDefinition caveatName (Map.fromList (parameterEntry <$> parameterSpecs)) predicate)
    -- ^ caveat parameters collapse here
```

`build = buildWithCaveats []` and `caveat name params = caveatWith name params PredTrue`,
so fixing `buildWithCaveats` and `caveatWith` automatically fixes `build` and `caveat`
once their signatures are lifted to `Either`. The term **userset rewrite** appears in the
types but is irrelevant here: this change only touches how the builder *collects named
entries into maps*, never how rewrites are constructed, so the combinators `this`,
`computed`, `arrow`, `anyOf`, `allOf`, `minus`, `caveated`, and the `cmp*`/`pred*`/`lit*`
helpers are untouched.

`en-core/test/Main.hs` is the single test executable for `en-core` (cabal test-suite
`en-core-interface-tests`, `main-is: test/Main.hs`). It is a plain `IO ()` `main` that
runs assertions via three helpers defined near the bottom of the file: `assertEqual ::
(Eq a, Show a) => String -> a -> a -> IO ()`, `assertBool :: String -> Bool -> IO ()`, and
`assertValidationFails :: String -> Schema -> IO ()`. The fixture `kikanSchema` (around
lines 303–360) is authored with the builder; the parallel `kikanSchemaManual` is the same
schema hand-built from raw `En.Schema` constructors, and `main` asserts the two are equal.
There is no test framework; failures are raised with `fail`.

`en-server/app/Main.hs` builds a tiny `demoSchema :: Schema` with `Schema.build [...]`
(around line 78). It is the only non-test consumer of `Schema.build` in the repo.

Throughout, the import alias is `import En.Schema.Builder qualified as Schema`, so call
sites write `Schema.build`, `Schema.object`, `Schema.relation`, and so on.


## Plan of Work

The work proceeds in three small, independently verifiable milestones: change the builder,
prove the change with new failing-then-passing tests, then repair the existing call sites.

### Milestone 1 — Builder detects duplicates

Scope: edit `en-core/src/En/Schema/Builder.hs` so that every name-keyed collection is
built through a helper that rejects duplicate keys, and lift the affected entry points to
`Either EnError ...`. At the end of this milestone the library compiles on its own terms,
but `en-core/test/Main.hs` and `en-server/app/Main.hs` will not yet compile (they still
treat the results as pure values) — that is expected and is repaired in Milestone 3.

Add an import of the error type at the top of `Builder.hs` (next to the existing
`En.Schema` imports):

```haskell
import En.Error (EnError (SchemaViolation))
import Data.Text qualified as Text
```

Add the helper. It folds the association list left-to-right, inserting each key and
failing the first time it meets a key already present:

```haskell
-- | Build a 'Map' from an association list, failing on the first duplicate key
-- instead of silently keeping the last value (which 'Map.fromList' does). The
-- @onDuplicate@ callback turns the offending key into a descriptive 'EnError'.
fromListUnique :: (Ord k) => (k -> EnError) -> [(k, v)] -> Either EnError (Map.Map k v)
fromListUnique onDuplicate =
    foldM insertUnique Map.empty
  where
    insertUnique acc (key, value)
        | Map.member key acc = Left (onDuplicate key)
        | otherwise = Right (Map.insert key value acc)
```

`foldM` comes from `Control.Monad` — add `import Control.Monad (foldM)`.

Lift `buildWithCaveats` (and therefore `build`) to `Either`, routing both collections
through `fromListUnique` with per-class duplicate messages:

```haskell
build :: [SchemaObject] -> Either EnError Schema
build =
    buildWithCaveats []

buildWithCaveats :: [CaveatSpec] -> [SchemaObject] -> Either EnError Schema
buildWithCaveats caveatSpecs objectSpecs = do
    objectTypes <- fromListUnique duplicateObjectType (objectEntry <$> objectSpecs)
    caveats <- fromListUnique duplicateCaveat (caveatEntry <$> caveatSpecs)
    pure (Raw.Schema objectTypes caveats)
  where
    objectEntry (SchemaObject name relations) = (name, relations)
    caveatEntry (CaveatSpec name definition) = (name, definition)

    duplicateObjectType (Raw.ObjectType name) =
        SchemaViolation ("duplicate object type declared: " <> name)

    duplicateCaveat (Raw.CaveatName name) =
        SchemaViolation ("duplicate caveat declared: " <> name)
```

Lift `object` to `Either`. Its relation key is a `RelationName`, but the message must be
scoped by the object name, so build the message from both:

```haskell
object :: Text -> [SchemaRelation] -> Either EnError SchemaObject
object name relations = do
    relationMap <- fromListUnique duplicateRelation (relationEntry <$> relations)
    pure (SchemaObject objectType relationMap)
  where
    objectType = Raw.ObjectType name
    relationEntry (SchemaRelation relationName relationValue) = (relationName, relationValue)

    duplicateRelation (Raw.RelationName relationName) =
        SchemaViolation ("duplicate relation declared: " <> name <> "#" <> relationName)
```

Lift `caveatWith` (and therefore `caveat`) to `Either`, scoping the parameter message by
the caveat name:

```haskell
caveat :: Text -> [ParameterSpec] -> Either EnError CaveatSpec
caveat name parameterSpecs =
    caveatWith name parameterSpecs PredTrue

caveatWith :: Text -> [ParameterSpec] -> CaveatPredicate -> Either EnError CaveatSpec
caveatWith name parameterSpecs predicate = do
    parameterMap <- fromListUnique duplicateParameter (parameterEntry <$> parameterSpecs)
    pure (CaveatSpec caveatName (Raw.CaveatDefinition caveatName parameterMap predicate))
  where
    caveatName = Raw.CaveatName name
    parameterEntry (ParameterSpec parameterName parameterType) = (parameterName, parameterType)

    duplicateParameter (Raw.CaveatParameterName parameterName) =
        SchemaViolation ("duplicate caveat parameter declared: " <> name <> "." <> parameterName)
```

Note that `buildWithCaveats` consumes `SchemaObject` and `CaveatSpec` values, which are now
produced by `object`/`caveat` *inside* an `Either`. The call sites (Milestone 3) will use
`traverse`/`do`-notation to thread those `Either`s, so `buildWithCaveats` itself still
takes plain `[SchemaObject]`/`[CaveatSpec]` — it does not need to take lists of `Either`.
Keep `relation`, `permission`, `subject`, `userset`, `parameter`, and all the rewrite and
predicate combinators exactly as they are; they construct single values and have no
collection step.

The export list at the top of the module already exports `build`, `buildWithCaveats`,
`object`, `caveat`, and `caveatWith`; only their types change, so the export list needs no
edit. Do **not** export `fromListUnique` — it is an internal helper.

Acceptance for Milestone 1: `cabal build en-core:lib:en-core` succeeds (the library alone,
not the test suite or the server). Command and expected result are in Concrete Steps.

### Milestone 2 — New negative tests prove each duplicate class is caught

Scope: add four focused tests to `en-core/test/Main.hs`, one per name class, each building
a schema (or sub-value) that declares a name twice and asserting the result is the exact
expected `Left (SchemaViolation ...)`. Critically, demonstrate the tests *fail* against the
unmodified builder before the Milestone 1 change and *pass* after it — this is what proves
the tests catch the real bug rather than trivially passing.

Because the builder now returns `Either`, the cleanest assertion form is a new tiny helper
placed near the other assertion helpers at the bottom of `en-core/test/Main.hs`:

```haskell
assertLeftEq :: (Eq a, Show a, Show b) => String -> a -> Either a b -> IO ()
assertLeftEq label expected actual =
    case actual of
        Left value | value == expected -> pure ()
        _ ->
            fail $
                label
                    <> "\nexpected: Left "
                    <> show expected
                    <> "\nactual:   "
                    <> show actual
```

Add the four tests inside `main`, near the existing `assertValidationFails` block (around
line 98–105). Each constructs the smallest schema that exhibits the class of duplicate:

```haskell
    assertLeftEq
        "duplicate relation is reported"
        (SchemaViolation "duplicate relation declared: space#owner")
        ( Schema.object
            "space"
            [ Schema.relation "owner" [Schema.subject "user"] Schema.this
            , Schema.relation "owner" [Schema.subject "user"] Schema.this
            ]
        )
    assertLeftEq
        "duplicate object type is reported"
        (SchemaViolation "duplicate object type declared: space")
        ( do
            spaceA <- Schema.object "space" [Schema.relation "owner" [Schema.subject "user"] Schema.this]
            spaceB <- Schema.object "space" [Schema.relation "member" [Schema.subject "user"] Schema.this]
            user <- Schema.object "user" []
            Schema.build [user, spaceA, spaceB]
        )
    assertLeftEq
        "duplicate caveat is reported"
        (SchemaViolation "duplicate caveat declared: within_window")
        ( do
            user <- Schema.object "user" []
            c1 <- Schema.caveat "within_window" [Schema.parameter "until" ParameterTimestamp]
            c2 <- Schema.caveat "within_window" [Schema.parameter "from" ParameterTimestamp]
            Schema.buildWithCaveats [c1, c2] [user]
        )
    assertLeftEq
        "duplicate caveat parameter is reported"
        (SchemaViolation "duplicate caveat parameter declared: within_window.until")
        ( Schema.caveat
            "within_window"
            [ Schema.parameter "until" ParameterTimestamp
            , Schema.parameter "until" ParameterTimestamp
            ]
        )
```

Each of these uses `do`-notation in the `Either EnError` monad: when `object`/`caveat`
succeeds it binds the value, and the first duplicate short-circuits with `Left`. The
relation and parameter cases short-circuit *inside* `object`/`caveat`, so they do not even
need to reach `build`. `SchemaViolation` and `ParameterTimestamp` are already imported in
`en-core/test/Main.hs` (verify the import list near the top includes `EnError (..)` from
`En.Error` and `CaveatParameterType (..)` from `En.Schema`; add them if missing).

To prove the tests are meaningful, temporarily verify they fail against the pre-fix
builder. The practical way: `git stash` the Builder.hs change, then re-run the suite; the
duplicate tests will fail because the unmodified builder returns a pure `Schema`/`SchemaObject`
(not an `Either`) and the file will not even compile against `assertLeftEq`. Because the
pre-fix builder is pure, a cleaner demonstration of the *behavioral* bug is to add, on the
pre-fix builder, a one-off check that `Schema.object "space" [relation "owner" .. ,
relation "owner" ..]` silently yields an object whose relation map has size 1 — i.e. the
second `owner` overwrote the first. Record whichever demonstration you run, with its
output, in Surprises & Discoveries. Then restore the fix and confirm all four tests pass.

Acceptance for Milestone 2: after Milestones 1 and 3, `cabal test en-core-interface-tests`
runs to completion with no `fail`, and the four new assertions are present.

### Milestone 3 — Repair existing call sites for the new `Either` signatures

Scope: the two existing consumers of the lifted entry points must thread the `Either`. At
the end, `cabal build all` succeeds across the whole project.

In `en-core/test/Main.hs`, the `kikanSchema` fixture is built with
`Schema.buildWithCaveats [...] [...]` where the inner list elements are now
`Either EnError SchemaObject` / `Either EnError CaveatSpec`. Rewrite the fixture to thread
the `Either`. Because `kikanSchema :: Schema` is used pervasively, keep it a `Schema` by
unwrapping a known-good build with a partial-but-test-only helper, or restructure as
follows. The simplest mechanical change that preserves the `Schema` type used everywhere
else is to introduce a helper that turns a builder result into a value and `error`s on
`Left` (acceptable in a test fixture that is known to be valid):

```haskell
orFail :: Either EnError a -> a
orFail = either (\err -> error ("builder produced an invalid fixture: " <> show err)) id

kikanSchema :: Schema
kikanSchema =
    orFail
        ( Schema.buildWithCaveats
            <$> traverse id
                    [ Schema.caveatWith "within_autonomy" [...] (...) ]
            <*> pure []   -- placeholder; see note below
        )
```

That applicative shape is awkward; prefer plain `do`-notation wrapped by `orFail`:

```haskell
kikanSchema :: Schema
kikanSchema =
    orFail $ do
        withinAutonomy <-
            Schema.caveatWith
                "within_autonomy"
                [ Schema.parameter "requested_autonomy" (ParameterEnum ["read", "act"])
                , Schema.parameter "autonomy" (ParameterEnum ["read", "act", "admin"])
                , Schema.parameter "current_time" ParameterTimestamp
                , Schema.parameter "until" ParameterTimestamp
                ]
                ( Schema.predAnd
                    [ Schema.cmpLe (Schema.ctxParam "requested_autonomy") (Schema.payloadParam "autonomy")
                    , Schema.cmpLe (Schema.ctxParam "current_time") (Schema.payloadParam "until")
                    ]
                )
        user <- Schema.object "user" []
        org <- Schema.object "org" [ Schema.relation "member" [Schema.subject "user"] Schema.this ]
        visibilityClass <- Schema.object "visibility_class" [ Schema.relation "viewer" [Schema.subject "user"] Schema.this ]
        space <-
            Schema.object
                "space"
                [ Schema.relation "owner" [Schema.subject "user"] Schema.this
                , Schema.relation "member" [Schema.subject "user", Schema.userset "org" "member"] Schema.this
                , Schema.relation "guest_org" [Schema.subject "org"] Schema.this
                , Schema.relation "parent" [Schema.subject "space"] Schema.this
                , Schema.relation "visibility_class" [Schema.subject "visibility_class"] Schema.this
                , Schema.permission "view" (Schema.anyOf (Schema.computed "owner") [ Schema.computed "member", Schema.arrow "guest_org" "member", Schema.arrow "parent" "view", Schema.arrow "visibility_class" "viewer" ])
                , Schema.permission "act" (Schema.anyOf (Schema.computed "owner") [Schema.computed "member"])
                , Schema.permission "audit" (Schema.allOf (Schema.computed "owner") [Schema.computed "member"])
                , Schema.permission "member_not_owner" (Schema.minus (Schema.computed "member") (Schema.computed "owner"))
                -- ...preserve any remaining permissions exactly as in the current fixture...
                ]
        Schema.buildWithCaveats [withinAutonomy] [user, org, visibilityClass, space]
```

Read the *current* `kikanSchema` body (around lines 303–360) in full and reproduce every
relation and permission it declares; do not drop any while transcribing into `do`-notation.
The `orFail` helper keeps `kikanSchema :: Schema`, so the many downstream uses
(`validate kikanSchema`, `compile kikanSchema`, the `kikanSchemaManual` equality assertion,
the hash assertion) compile unchanged.

In `en-server/app/Main.hs`, `demoSchema :: Schema` is built with `Schema.build [...]`,
which now returns `Either EnError Schema`. Apply the same pattern: add a local `orFail`
(or inline `either (error . show) id`) and thread the inner `object` calls:

```haskell
demoSchema :: Schema
demoSchema =
    either (error . ("invalid demo schema: " <>) . show) id $ do
        user <- Schema.object "user" []
        space <-
            Schema.object
                "space"
                [ Schema.relation "viewer" [Schema.subject "user"] Schema.this
                , Schema.permission "view" (Schema.computed "viewer")
                ]
        Schema.build [user, space]
```

`En.Error (EnError (..))` (or at least `EnError`) must be in scope in `en-server/app/Main.hs`
for the `show` on the error; it is already imported there. If only `Schema` and `schemaHash`
are imported from `En.Schema`, no change is needed because `show` works on the `EnError`
through its `Show` instance without naming the type. Adjust the import only if the compiler
asks.

Acceptance for Milestone 3: `cabal build all` succeeds; `cabal test en-core-interface-tests`
passes including the four new assertions.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/en`.

Confirm the starting state builds and tests pass before changing anything:

```bash
cabal build all
cabal test en-core-interface-tests
```

Expected: both succeed. The test run ends with something like:

```text
Test suite en-core-interface-tests: PASS
1 of 1 test suites (1 of 1 test cases) passed.
```

Apply Milestone 1 (edit `en-core/src/En/Schema/Builder.hs`), then compile the library alone
to catch builder-internal mistakes before the call sites confuse the picture:

```bash
cabal build en-core:lib:en-core
```

Expected: it compiles. (The test suite and server will not yet — that is fine.)

Apply Milestone 2 (add the four tests and `assertLeftEq` to `en-core/test/Main.hs`) and
Milestone 3 (repair `kikanSchema` in `en-core/test/Main.hs` and `demoSchema` in
`en-server/app/Main.hs`). Then build and test the whole project:

```bash
cabal build all
cabal test en-core-interface-tests
```

Expected: both succeed, with the test suite reporting PASS as above. If a test `fail`s, its
label (for example `duplicate relation is reported`) and the expected-vs-actual lines print
to stdout, telling you which class regressed.

To demonstrate the tests are meaningful (they catch the real bug), stash only the builder
fix and re-run:

```bash
git stash push -- en-core/src/En/Schema/Builder.hs
cabal test en-core-interface-tests
git stash pop
```

Expected without the fix: compilation fails (the test file uses `assertLeftEq` against
results the old builder returns as pure values), or — if you instead demonstrated the bug
with the size-1 relation-map check on the pure builder — that check shows the map silently
contains one entry. Record the observed output in Surprises & Discoveries. After
`git stash pop`, re-run `cabal test en-core-interface-tests` and confirm PASS.


## Validation and Acceptance

The change is acceptance-complete when all of the following hold, each verifiable by a
human running a command from the repo root.

`cabal build all` succeeds with no errors, proving the lifted `Either` signatures are
threaded correctly through both call sites (`en-core/test/Main.hs`, `en-server/app/Main.hs`).

`cabal test en-core-interface-tests` succeeds and includes the four new assertions. The
behavioral proof is each new assertion: building a schema with a duplicate name yields the
exact `Left (SchemaViolation ...)` the test expects. Concretely, a schema with two
`Schema.relation "owner"` entries on object `space` produces
`Left (SchemaViolation "duplicate relation declared: space#owner")`; the analogous object,
caveat, and parameter duplicates produce
`Left (SchemaViolation "duplicate object type declared: space")`,
`Left (SchemaViolation "duplicate caveat declared: within_window")`, and
`Left (SchemaViolation "duplicate caveat parameter declared: within_window.until")`
respectively.

The negative tests must FAIL before the fix and PASS after it, demonstrated via the
`git stash` procedure in Concrete Steps. This distinguishes a real guard from a test that
would pass regardless.

The existing equality assertions remain green: `builder schema equals manual schema`
(`kikanSchema == kikanSchemaManual`) and `builder schema hash matches manual schema hash`
must still pass, proving the refactor of `kikanSchema` into `do`-notation preserved every
relation and permission and did not perturb the resulting `Schema`.


## Idempotence and Recovery

Every step is a source edit or a build/test command; none touches a database, network, or
filesystem outside the working tree, so all steps are safe to repeat. Re-running
`cabal build all` or `cabal test en-core-interface-tests` any number of times is harmless
and produces the same result.

If a milestone leaves the tree in a non-compiling intermediate state (expected after
Milestone 1, before Milestone 3), that is recoverable simply by completing Milestone 3 or by
`git checkout -- <file>` / `git stash` to revert. The `git stash push -- en-core/src/En/Schema/Builder.hs`
demonstration in Concrete Steps is fully reversible with `git stash pop`; if interrupted,
`git stash list` shows the saved entry and `git stash pop` restores it.

No data migration or destructive operation is involved. The only API change is the lifted
return types; if the change must be rolled back, reverting `en-core/src/En/Schema/Builder.hs`
and the two call-site files restores the prior behavior exactly.


## Interfaces and Dependencies

This plan uses only modules already on `en-core`'s dependency list (see
`en-core/en-core.cabal`): `containers` (`Data.Map.Strict`), `base` (`Control.Monad.foldM`),
and `text` (`Data.Text`). No new package dependency is introduced.

At the end of Milestone 1, `En.Schema.Builder` (file `en-core/src/En/Schema/Builder.hs`)
must export these entry points with exactly these signatures:

```haskell
build            :: [SchemaObject] -> Either EnError Schema
buildWithCaveats :: [CaveatSpec] -> [SchemaObject] -> Either EnError Schema
object           :: Text -> [SchemaRelation] -> Either EnError SchemaObject
caveat           :: Text -> [ParameterSpec] -> Either EnError CaveatSpec
caveatWith       :: Text -> [ParameterSpec] -> CaveatPredicate -> Either EnError CaveatSpec
```

and must define (but not export) the internal helper:

```haskell
fromListUnique :: (Ord k) => (k -> EnError) -> [(k, v)] -> Either EnError (Map.Map k v)
```

The error surface is the existing `En.Error.EnError` constructor `SchemaViolation Text`
(file `en-core/src/En/Error.hs`); no new constructor is added. The four duplicate messages
are an explicit, documented integration point with
`docs/plans/22-add-a-compile-time-schema-quasi-quoter.md` (EP-22), which will detect the
same duplicate condition at compile time and is expected to reuse these exact strings:
`"duplicate object type declared: <name>"`,
`"duplicate relation declared: <object>#<relation>"`,
`"duplicate caveat declared: <name>"`, and
`"duplicate caveat parameter declared: <caveat>.<parameter>"`. Do not change this wording
without updating EP-22.

This plan has no upstream dependencies and is intended to land first in the schema-DSL
hardening sequence. It softly precedes EP-21 (which introduces a validated-schema evidence
type and will build on the now-fallible builder entry points) and EP-23 (which also edits
`en-core/src/En/Schema/Builder.hs`). The coordination requirement is that **EP-23 must not
redefine `fromListUnique` or re-lift these entry points**; it should treat the
`Either EnError ...` signatures established here as fixed and reuse `fromListUnique` if it
needs duplicate-safe collection of its own. The two call sites this plan modifies —
`en-core/test/Main.hs` (the `kikanSchema` fixture and the new tests) and
`en-server/app/Main.hs` (`demoSchema`) — are the complete set of consumers of the lifted
entry points in the repository as of this plan; any future caller of `build`/`object`/
`caveat` must thread the `Either` accordingly.
