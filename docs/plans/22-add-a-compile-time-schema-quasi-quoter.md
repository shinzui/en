---
id: 22
slug: add-a-compile-time-schema-quasi-quoter
title: "Add a compile-time schema quasi-quoter"
kind: exec-plan
created_at: 2026-06-23T21:43:10Z
intention: "intention_01kvv6xk57em8tq254tz5zm8r0"
master_plan: "docs/masterplans/4-harden-the-en-schema-dsl-for-release.md"
---

# Add a compile-time schema quasi-quoter

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`en` is a Zanzibar-style relationship-based authorization toolkit. "Zanzibar-style" means
permissions are computed by following relationship facts (tuples like "alice is owner of
space project-x") through rewrite rules ("you can view a space if you own it, are a member,
or can view its parent"). The whole authorization model is supplied by the consuming project
as an ordinary Haskell value of type `Schema`, defined in `en-core/src/En/Schema.hs`. Today
authors build that value with the combinators in `en-core/src/En/Schema/Builder.hs` — for
example `Schema.permission "view" (Schema.computed "owner")`. Those combinators take plain
`Text`, so a typo such as `Schema.computed "ownr"` (referring to a relation that does not
exist) compiles cleanly and only blows up much later, at runtime, when the schema is
validated or compiled. The error surfaces in production code or, at best, in a unit test —
never at the moment you wrote the typo.

After this change, an author can opt into a **compile-time-validated** authoring path. They
write their schema in a special expression and, if it references a relation/caveat/object
that does not exist, declares an empty union, contains an unproductive rewrite cycle, or
otherwise fails the existing `validate` checks, **the build fails** with the exact same
human-readable validation message — at the call site, before any test runs. The result of a
successful compile-time-validated schema is a `ValidSchema` value (the evidence type
introduced by EP-21, see below): proof, carried in the type, that the schema passed
validation. The runtime path is untouched; nobody who prefers the existing builder is forced
to change anything. This is "lightweight type-safety without inventing a type-level DSL": we
move existing runtime checks to compile time using Template Haskell.

You can see it working two ways. First, `cabal build all` and
`cabal test en-core-interface-tests` from the repository root still pass, and a new test
asserts a compile-time-validated schema is *equal* to the builder-authored `kikanSchema`
fixture in `en-core/test/Main.hs`. Second, a deliberately broken fixture (for example one
with `Schema.computed "ownr"`) **fails to compile** with the schema-validation error text,
proving the typo was caught at build time. We capture that failing-build transcript in this
plan so a reader can recognize success.

"Template Haskell" (TH) is GHC's metaprogramming facility: code that runs *during
compilation* and produces ordinary Haskell expressions that are then compiled as if you had
typed them. We use it to run `validateSchema` while GHC is building the module. "Splice"
means "insert a TH-produced expression here", written `$(...)` (untyped) or `$$(...)`
(typed). "`Lift`" is the type class that lets a runtime value (built during compilation) be
turned back into source code GHC can embed in the output binary — we need it so the validated
`Schema` value computed at compile time can be baked into the program.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] 2026-06-24: Confirm EP-21 (`docs/plans/21-introduce-a-validated-schema-evidence-type.md`) is landed and `En.Schema` exports `ValidSchema` and `validateSchema :: Schema -> Either EnError ValidSchema`, with `En.Schema.Internal.unsafeValidSchema` available for TH.
- [x] 2026-06-24: Milestone 0 (PROTOTYPING): add `template-haskell` to the `en-core` library `build-depends`; add `DeriveLift` to default-extensions; derive `Lift` for the schema data types and confirm `nix develop --command cabal build en-core:lib:en-core` succeeds.
- [x] 2026-06-24: Milestone 0 (PROTOTYPING): add `En.Schema.TH` with `mkValidSchema :: Schema -> Code Q ValidSchema`; wire a permanent test that splices `kikanSchema` through it and asserts equality with the builder fixture.
- [x] 2026-06-24: Milestone 0 (PROTOTYPING): create a *should-not-compile* fixture using `Schema.computed "ownr"`, run it manually, and capture the validation error transcript; confirm the build fails.
- [x] 2026-06-24: Milestone 0 (PROTOTYPING): promote approach (B), the typed-TH function over the existing builder surface, to the real implementation.
- [x] 2026-06-24: Milestone 1: harden `En.Schema.TH` with final API, doc comments, error formatting, and a good-path test in `en-core-interface-tests`.
- [x] 2026-06-24: Milestone 1: encode the should-not-compile cases as committed, runnable manual checks: `BadSchema.hs` for unknown relation and `DuplicateName.hs` for EP-20 duplicate relation.
- [x] 2026-06-24: Milestone 2 (OPTIONAL, budget permitting): add the `schema` QuasiQuoter (`[schema| ... |]`) with a small textual grammar parsed to `Schema`, validated at compile time, spliced as `ValidSchema`.
- [x] 2026-06-24: Update `exposed-modules` in `en-core/en-core.cabal`; run `nix develop --command cabal build all` and `nix develop --command cabal test en-core-interface-tests`; record outputs.
- [x] 2026-06-24: Final retrospective after landing Milestone 2.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

During plan authoring (2026-06-23) the following feasibility facts were established by
compiling throwaway modules against the repo's toolchain (GHC 9.12.4,
`template-haskell-2.23.0.0`, `containers-0.7`, `time` as pinned by `cabal.project`):

- `containers-0.7` already provides `Lift` instances for `Data.Map.Strict.Map` and
  `Data.Set.Set`. A module splicing `$( [| Map.fromList [(1,2)] |] )` and
  `$( [| Set.fromList [1,2] |] )` compiled with exit code 0. Therefore **no
  `th-lift-instances` dependency is required** for the container fields of `Schema`.
- `Data.Text.Text` and strict-field records derive/lift cleanly: a `newtype Wrap = Wrap Text`
  and `data Rec = Rec { a :: !Text, b :: !Int }` both `deriving stock (Show, Lift)` compiled.
- `Data.Time.UTCTime` (carried by `CaveatValue`'s `ValueTimestamp`) has a working `Lift`
  instance in the pinned `time`; `data Holds = Holds UTCTime deriving Lift` compiled. So even
  the timestamp-carrying caveat values lift without extra packages.

Net discovery: the *only* new package this plan needs is `template-haskell`, which ships with
GHC. That is recorded as the single notable dependency cost in the Decision Log.

(Further surprises to be recorded during implementation.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Start with approach (B) — a Template-Haskell *function* over the existing builder
  (`mkValidSchema :: Schema -> Code Q ValidSchema`, used as `$$(mkValidSchema someSchema)`) —
  and treat the (A) text quasi-quoter (`[schema| ... |]`) as an optional later milestone.
  Rationale: (B) reuses the entire existing `En.Schema.Builder` surface, so there is **no new
  grammar to design, parse, or document**. It needs only two capabilities: evaluate the
  builder-produced `Schema` at compile time and re-emit it via `Lift`. This proves the core
  loop — "validate at compile time → splice `ValidSchema` → fail the build on a bad schema" —
  with the smallest possible new surface, which is exactly what a prototype should de-risk.
  Approach (A) is strictly more work (a textual grammar, a parser, parse-error reporting) and
  buys ergonomics/documentation value that is worthless if the core loop does not work. Build
  the loop first, decorate later.
  Date: 2026-06-23

- Decision: Use **typed** Template Haskell (`Code Q ValidSchema`, spliced with `$$(...)`)
  rather than untyped (`Q Exp`, spliced with `$(...)`) for approach (B).
  Rationale: typed TH gives us a checked result type at the splice site — the splice is
  guaranteed to produce a `ValidSchema`, so a misuse is itself a type error. The quasi-quoter
  in (A), if built, must be untyped (a `QuasiQuoter`'s expression field returns `Q Exp`), but
  (A) is optional. For (B) the typed form is both safer and barely more code.
  Date: 2026-06-23

- Decision: Derive `Lift` for the `En.Schema` types via the `DeriveLift` GHC extension and
  `deriving stock Lift`, rather than hand-writing instances.
  Rationale: hand-written `Lift` is mechanical, large, and a maintenance hazard (it must track
  every constructor). `DeriveLift` is exactly the standard tool. The types needing the
  instance are: `ObjectType`, `RelationName`, `CaveatName`, `CaveatParameterName`,
  `CaveatParameterType`, `CaveatSource`, `CaveatOperand`, `CaveatCompare`, `CaveatPredicate`,
  `CaveatDefinition`, `CaveatValue`, `Rewrite`, `AllowedSubject`, `Relation`, and `Schema`.
  The container fields (`Map`, `Set`) and leaf types (`Text`, `Integer`, `Bool`, `UTCTime`)
  already have `Lift` instances (see Surprises & Discoveries), so the derivation closes.
  `CaveatValue` lives in `En.Caveat.Value`; its `Lift` instance is added there. We do **not**
  derive `Lift` for `ValidSchema`: it is excluded on purpose (see the next decision).
  Date: 2026-06-23

- Decision: Lift goes through the inner `Schema` plus EP-21's internal wrapper
  `En.Schema.Internal.unsafeValidSchema`, never through a `Lift ValidSchema` instance.
  Rationale: EP-21 hides the public `ValidSchema` constructor (only `validateSchema` produces
  one). A derived `Lift ValidSchema` generates code that names that hidden constructor at the
  splice site, where it is out of scope, so every call site would fail to build — `Lift
  ValidSchema` is therefore unusable here. The coordinated fix (EP-21 supplies the other half)
  is an internal module `En.Schema.Internal` re-exporting the raw constructor as
  `unsafeValidSchema :: Schema -> ValidSchema`. `mkValidSchema` runs `validateSchema` at COMPILE
  time (turning unknown-relation/duplicate-name errors into build errors via `fail`), and on
  success lifts only the inner `Schema` and splices `unsafeValidSchema <lifted Schema>`. This
  respects EP-21's hidden constructor while still validating at compile time, and it trims the
  `DeriveLift` list — `ValidSchema` is deliberately absent from it.
  Date: 2026-06-23

- Decision: `template-haskell` is added to the `en-core` **library** `build-depends`. This is
  the ONLY plan in the master plan that introduces a new dependency.
  Rationale called out as a cost: it widens the library's dependency footprint and means the
  core library now links the TH machinery. `template-haskell` ships with GHC (no new package
  to fetch from Hackage; version `2.23.0.0` is already in the global package db for the pinned
  GHC 9.12.4), so the cost is bounded — it is a boot library, not a third-party dependency,
  and it does not pull in a transitive tree. We accept it because the compile-time-validation
  win requires TH and there is no lighter mechanism. We keep the blast radius small by putting
  all TH in one new module (`En.Schema.TH`) so the rest of the library is unaffected.
  Date: 2026-06-23

- Decision: The new module is named `En.Schema.TH`.
  Rationale: it advertises that the module is the Template-Haskell authoring entry point,
  parallel to `En.Schema.Builder`. If the (A) quasi-quoter milestone lands, the
  `schema` `QuasiQuoter` is also exported from `En.Schema.TH` (a quasi-quoter is conventionally
  co-located with its TH support), so a single import gives an author both styles.
  Date: 2026-06-23

- Decision: Demonstrate the compile-failure case with a dedicated fixture target that is
  **built manually** (not part of the cabal test executable), with the expected stderr
  transcript recorded in this plan, rather than attempting an inline "assert this does not
  compile" test.
  Rationale: a `cabal test` executable must itself compile to run; you cannot put a
  known-non-compiling splice inside it. Options considered: (1) `-fdefer-type-errors` — does
  not help because our failure is a TH `fail`/compile error from `validateSchema`, not a type
  error, so it is not deferrable; (2) a `doctest`/`should_fail` test harness — adds a new test
  dependency for one case, rejected to keep dependencies minimal; (3) a separate fixture
  module under a non-built path that the developer/CI compiles on demand and compares stderr —
  chosen, documented with the exact command and expected output in Validation and Acceptance.
  Date: 2026-06-23

- Decision: The compile-time path must reject duplicate names with the SAME `EnError` wording
  that EP-20 (`docs/plans/20-detect-duplicate-names-in-the-schema-builder.md`) introduces.
  Rationale: we get this for free because we route everything through `validateSchema`. Once
  EP-20 makes the builder/`validate` reject duplicate object/relation/caveat names with a
  specific `EnError`, our TH splice — which calls `validateSchema` — will surface that exact
  message as a compile error. We add a test fixture exercising a duplicate-name schema once
  EP-20 lands. Soft dependency: if EP-20 is not yet merged, the duplicate-name case simply is
  not yet caught by either path; nothing in this plan needs to change when it lands.
  Date: 2026-06-23

- Decision: Add `mkValidSchemaEither :: Either EnError Schema -> Code Q ValidSchema` alongside
  `mkValidSchema :: Schema -> Code Q ValidSchema`.
  Rationale: EP-20 made the builder entry points return `Either EnError ...`, so duplicate
  object/relation/caveat/parameter declarations fail before a raw `Schema` exists. A TH helper
  that accepts builder results lets compile-time authoring surface those builder-side
  `EnError`s directly, with the same error text, instead of forcing users to unwrap with
  `error` before calling `mkValidSchema`. `mkValidSchema` remains the simple raw-schema API and
  delegates to `mkValidSchemaEither . Right`.
  Date: 2026-06-24

- Decision: Land the optional `[schema| ... |]` quasi-quoter with an intentionally small,
  line-oriented grammar: `object name {}`, `object name { ... }`, `relation name: subject,
  object#relation, object:*`, and `permission name = this | computed | tupleset->computed`
  where `|` builds a union.
  Rationale: the compile-time guarantee is the feature; the text grammar should be only large
  enough to make that authoring path real without committing the project to a full SpiceDB
  parser before EP-23/EP-24 shape the public DSL documentation. The quasi-quoter routes
  builder-produced `EnError`s through `mkValidSchemaEither`, so duplicate declarations and
  validation failures share the same `schema validation failed at compile time:` wording as the
  typed TH helper.
  Date: 2026-06-24


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation. The prototyping milestone's retrospective must
explicitly state whether approach (B) is promoted to the real implementation or discarded, and
why; the final entry must compare the delivered behavior against the Purpose above — namely
that a typo like `Schema.computed "ownr"` now fails the build with the validation message.)

2026-06-24 milestone note: approach (B) is promoted. `En.Schema.TH.mkValidSchema` validates a
raw `Schema` at compile time and splices a `ValidSchema`; `mkValidSchemaEither` does the same
for fallible builder results, preserving EP-20 duplicate-declaration errors at compile time.
The good path is now a permanent `en-core-interface-tests` assertion named
`compile-time validated schema equals builder fixture`. The bad-path fixtures fail manually
with the intended messages:

```text
schema validation failed at compile time: UnknownRelation "unknown relation: space#ownr"
schema validation failed at compile time: SchemaViolation "duplicate relation declared: space#owner"
```

2026-06-24 final note: Milestone 2 landed. `En.Schema.TH.schema` is an expression-only
quasi-quoter that parses the compact object/relation/permission grammar described in the
Decision Log, builds the same `Schema` value through `En.Schema.Builder`, validates it at
compile time, and splices a `ValidSchema`. `en-core-interface-tests` now includes
`schema quasi-quoter builds compact schema`, comparing a quoted schema against the equivalent
builder fixture. Two additional manual fixtures prove the text path fails the build with the
same validation wording:

```text
schema validation failed at compile time: UnknownRelation "unknown relation: space#ownr"
schema validation failed at compile time: SchemaViolation "duplicate relation declared: space#owner"
```

EP-22 is complete.


## Context and Orientation

The reader is assumed to know nothing about this repository. Here is what matters.

The authorization model is a value of type `Schema`, defined in `en-core/src/En/Schema.hs`.
That module exports the model types — `Schema`, `ObjectType`, `RelationName`, `Relation`,
`AllowedSubject`, `Rewrite` (with constructors `This`, `ComputedUserset`, `TupleToUserset`,
`Union`, `Intersection`, `Exclusion`, `Caveated`), `CaveatName`, `CaveatParameterName`,
`CaveatParameterType` (`ParameterText`, `ParameterBool`, `ParameterInteger`,
`ParameterTimestamp`, `ParameterEnum [Text]`), `CaveatDefinition`, plus caveat-predicate
types (`CaveatSource`, `CaveatOperand`, `CaveatCompare`, `CaveatPredicate`) — and the function
`validate :: Schema -> Either EnError ()`. Every model type `deriving stock (Eq, Show)`; the
small newtypes and the predicate types also derive `Ord`. `CaveatValue` is re-exported here
but defined in `en-core/src/En/Caveat/Value.hs`.

`validate` is the runtime gate: it checks that every relation referenced by a rewrite exists,
that allowed-subject object types and usersets exist, that `Union`/`Intersection` are
non-empty, that caveats referenced by `Caveated` are declared, that map keys match the names
they index, and that rewrite cycles have a productive base. On success it returns
`Right ()`; on failure `Left` of an `EnError` carrying a human-readable message (for example
`UnknownRelation "unknown relation: space#ownr"` or
`SchemaViolation "union rewrite is empty: space#view"`). `EnError` is defined in
`en-core/src/En/Error.hs`.

Authors today build a `Schema` with the combinators in `en-core/src/En/Schema/Builder.hs`,
re-exported in tests as `Schema`. The realistic example is `kikanSchema` in
`en-core/test/Main.hs` (starting at line 307): it declares object types `user`, `org`,
`visibility_class`, `space`, and `intention`, a `within_autonomy` caveat, and permissions
like `view` built from `Schema.anyOf (Schema.computed "owner") [...]`. We will use this exact
fixture as our golden value: a compile-time-validated schema authored through our new path
must be `==` to `kikanSchema`.

EP-21 (`docs/plans/21-introduce-a-validated-schema-evidence-type.md`) is a **hard
prerequisite**. It introduces `newtype ValidSchema = ValidSchema Schema` whose constructor is
not exported, together with `validateSchema :: Schema -> Either EnError ValidSchema` (the only
public way to obtain a `ValidSchema`). It also changes `compile` to take `ValidSchema`. As a
coordinated half of this plan, EP-21 additionally exposes an **internal** module
`En.Schema.Internal` re-exporting the raw constructor as
`unsafeValidSchema :: Schema -> ValidSchema`, which exists solely so this plan can rebuild a
`ValidSchema` at a TH splice site without naming the hidden public constructor. If, when you
start, EP-21's body is still skeletal or unmerged, rely on this description: `ValidSchema` is
an evidence newtype over `Schema` produced publicly only by `validateSchema`, with an internal
`unsafeValidSchema` wrapper for TH. Our quasi-quoter / TH function must splice a `ValidSchema`,
i.e. a schema **proven valid at compile time**. We do that by running `validateSchema` at
compile time, then — on success — lifting the inner `Schema` and wrapping it with
`unsafeValidSchema` at the splice site. We deliberately do **not** lift a `ValidSchema`
directly: a derived `Lift ValidSchema` would reference the hidden public constructor out of
scope and break every call site. Because validation happens before the lift, the wrapper is
only ever applied to a schema already proven valid, so the evidence invariant is preserved.

EP-20 (`docs/plans/20-detect-duplicate-names-in-the-schema-builder.md`) is a **soft**
prerequisite: when it makes the builder/`validate` reject duplicate object/relation/caveat
names, our compile-time path inherits that rejection automatically because we route through
`validateSchema`. We surface the *same* `EnError` wording EP-20 defines, as a compile error.

The toolchain (from `cabal.project`) is GHC 9.12.4, with `template-haskell-2.23.0.0` and
`containers-0.7` in the package database — these versions matter because they already provide
the `Lift` instances we depend on (see Surprises & Discoveries).

Key terms used below, defined in plain language:

- **Template Haskell (TH)**: code that runs during compilation and emits Haskell expressions.
- **Splice**: the insertion point where a TH expression is placed into your program; written
  `$(e)` for untyped TH or `$$(e)` for typed TH.
- **`Lift`**: the class `Language.Haskell.TH.Syntax.Lift`; `lift :: a -> Q Exp` turns a value
  computed during compilation into source GHC can embed. `DeriveLift` is the GHC extension
  that derives it.
- **`Code Q a`**: the typed-TH representation of an expression of type `a`; spliced with
  `$$(...)`. In `template-haskell-2.23.0.0` this is `Language.Haskell.TH.Syntax.Code Q a`.
- **`QuasiQuoter`**: a record (`Language.Haskell.TH.Quote.QuasiQuoter`) that lets you write
  `[name| ...arbitrary text... |]`; the `quoteExp` field parses that text to a `Q Exp`.


## Plan of Work

The work is split into a mandatory prototyping milestone, a hardening milestone, and an
optional quasi-quoter milestone. We lead with prototyping because this is the most speculative
plan in the master plan: it relies on compile-time evaluation and `Lift` working for the whole
`Schema` type and on being able to demonstrate a *build failure* in a maintainable way.

### Milestone 0 — PROTOTYPING: prove the validate-at-compile-time loop end to end

Scope: prove, with the smallest possible new surface, that we can (a) derive `Lift` for the
full `Schema` type (NOT `ValidSchema`), (b) evaluate a builder-authored `Schema` at compile
time, run `validateSchema`, and splice `unsafeValidSchema <lifted Schema>` to rebuild the
`ValidSchema`, and (c) cause a *build failure* with
the validation message when the schema is bad. At the end of this milestone there exists a new
module `En.Schema.TH` exporting one function, a throwaway good-path test confirming equality
with `kikanSchema`, and a recorded transcript of the bad-path build failure. If any of these
cannot be made to work, approach (B) is discarded and the Decision Log is updated; but the
feasibility probes in Surprises & Discoveries already indicate it will work.

Work:

1. In `en-core/en-core.cabal`, add `template-haskell` to the **library** `build-depends`, and
   add `DeriveLift` to the `common shared` `default-extensions`.

2. In `en-core/src/En/Caveat/Value.hs`, add `Lift` to the `deriving stock` clause of
   `CaveatValue` (and any sibling types in that file that `Schema` transitively contains and
   that are not already covered). `UTCTime`'s `Lift` instance comes from `time`.

3. In `en-core/src/En/Schema.hs`, add `Lift` to the `deriving stock` clause of every model
   type listed in the Decision Log: `ObjectType`, `RelationName`, `CaveatName`,
   `CaveatParameterName`, `CaveatParameterType`, `CaveatSource`, `CaveatOperand`,
   `CaveatCompare`, `CaveatPredicate`, `CaveatDefinition`, `Rewrite`, `AllowedSubject`,
   `Relation`, and `Schema`. Import `Language.Haskell.TH.Syntax (Lift)`. Do **not** change any
   field, constructor, or existing instance — `Lift` is purely additive.

4. Create `en-core/src/En/Schema/TH.hs` exporting `mkValidSchema`. Its job: take a `Schema`
   value available at compile time, validate it, and either splice the corresponding
   `ValidSchema` or fail the build with the validation message.

   The critical subtlety, coordinated with EP-21: EP-21 deliberately **hides** the
   `ValidSchema` constructor — `validateSchema :: Schema -> Either EnError ValidSchema` is the
   only public producer. This means we must **not** derive or use `Lift ValidSchema`: a derived
   `Lift ValidSchema` would emit code that names the `ValidSchema` constructor at the splice
   site, where it is out of scope, so every call site would fail to build. EP-21 is adding the
   other half of this fix: an internal module `En.Schema.Internal` that re-exports the raw
   constructor as `unsafeValidSchema :: Schema -> ValidSchema` for exactly this purpose. So we
   lift only the **inner `Schema`** (which has a `Lift` instance from steps 2–3) and splice an
   *application of the internal wrapper* to it. The spliced code is `unsafeValidSchema <lifted
   Schema>`, never a lifted `ValidSchema`. Validation happens at compile time, before the lift,
   so the wrapper is only ever applied to a schema we already proved valid. Concretely:

   ```haskell
   {-# LANGUAGE TemplateHaskellQuotes #-}

   module En.Schema.TH (mkValidSchema) where

   import Language.Haskell.TH.Syntax (Code, Q)
   import qualified Language.Haskell.TH.Syntax as TH

   import En.Schema (Schema)
   -- EP-21 provides these; adjust the import paths if EP-21 names them differently.
   import En.Schema.Validated (ValidSchema, validateSchema)
   -- EP-21's internal module re-exporting the raw constructor as a wrapper.
   import En.Schema.Internal (unsafeValidSchema)

   -- | Validate a 'Schema' at compile time and splice the proven-valid value.
   --
   -- Use as @$$(mkValidSchema mySchema)@ where @mySchema :: Schema@ is a CAF
   -- (a top-level, argument-free binding) built with "En.Schema.Builder".
   -- A schema that fails validation fails the build with the validation message.
   --
   -- At compile time we run 'validateSchema'; on 'Left' we 'fail' (turning the
   -- 'EnError' into a build error). On 'Right' we lift the INNER 'Schema' and
   -- wrap it with 'unsafeValidSchema' at the splice site. We never lift a
   -- 'ValidSchema' (its constructor is hidden, hence the internal wrapper).
   mkValidSchema :: Schema -> Code Q ValidSchema
   mkValidSchema schema =
       case validateSchema schema of
           Left err -> TH.liftCode (fail ("schema validation failed at compile time: " <> show err))
           Right _valid ->
               -- 'schema' appears free in the quotation, so only 'Lift Schema'
               -- (and its components) is required. 'unsafeValidSchema' is applied
               -- inside the spliced code, in scope via this module's import of
               -- En.Schema.Internal at the call site's package.
               [|| unsafeValidSchema schema ||]
   ```

   Note on the quote `[|| schema ||]`: `schema` appears free inside the typed quotation, so it
   must be `Lift`-able — which is exactly why steps 2–3 derive `Lift` for `Schema` and its
   components (and **only** those, never `ValidSchema`). `unsafeValidSchema` is a top-level
   name, so it is resolved by GHC at the splice site through the normal name machinery (TH
   captures the fully-qualified name), not via `Lift`. The `TemplateHaskellQuotes` pragma
   enables quotation syntax without requiring the full `TemplateHaskell` extension in this
   module's *definitions*; the *call sites* that splice `$$(...)` enable `TemplateHaskell`
   themselves.

5. Add `En.Schema.TH` to the library's `exposed-modules` in `en-core/en-core.cabal`.

6. Good-path probe: add a temporary test (or a `cabal repl` snippet) that defines
   `validatedKikan :: ValidSchema; validatedKikan = $$(mkValidSchema kikanSchema)` in a module
   that enables `{-# LANGUAGE TemplateHaskell #-}`, and asserts that unwrapping it equals
   `kikanSchema`. Since `ValidSchema`'s field is not exported, compare via a public accessor
   from EP-21 (it provides one, e.g. `unValidSchema`/`validSchema`), or compare the recompiled
   `validateSchema kikanSchema` `Right` payload. The acceptance is simply that this compiles
   and the equality holds.

7. Bad-path probe: create `en-core/test/fixtures/BadSchema.hs` (a path **not** in any cabal
   target) containing a schema with `Schema.computed "ownr"` spliced through `mkValidSchema`.
   Compile it manually with `cabal exec -- ghc -fno-code ...` (exact command in Concrete
   Steps) and confirm the build fails with the validation message. Record the transcript.

### Milestone 1 — Harden and integrate the TH path

Scope: turn the prototype into the shipped feature. At the end, `En.Schema.TH` has doc
comments and clean error formatting, the good-path test lives inside
`en-core-interface-tests`, and the bad-path is a documented, repeatable check.

Work: finalize `mkValidSchema`'s name and Haddock; format the compile error so it reads as a
schema problem (prefix `schema validation failed at compile time:` followed by the `EnError`
message). Add a permanent test to `en-core/test/Main.hs` that splices `kikanSchema` through
`mkValidSchema` and asserts equality with the builder fixture (this is the good path and must
pass under `cabal test en-core-interface-tests`). Keep the bad-path fixture under
`en-core/test/fixtures/BadSchema.hs` and document in Validation and Acceptance the exact manual
`ghc` invocation and the expected stderr. If EP-20 has landed, add a second fixture
`en-core/test/fixtures/DuplicateName.hs` exercising a duplicate relation name and record its
(EP-20-defined) error transcript too.

### Milestone 2 — OPTIONAL: the `[schema| ... |]` quasi-quoter

Scope, budget permitting only: add ergonomic textual authoring. At the end, an author can
write a schema in a compact SpiceDB-like text block and get the same compile-time validation.
This milestone is strictly additive and does not change Milestone 1.

Work: design a minimal text grammar, write a small total parser from `String` to
`Either String (Either EnError Schema)` (no new parser dependency — a hand-written parser using
`Data.Text`), define `schema :: QuasiQuoter` in `En.Schema.TH` whose `quoteExp` parses the
body, on parse failure calls `fail` (build error), on success delegates to
`mkValidSchemaEither` so builder errors and validation errors share the same compile-time
format. The grammar deliberately covers only:

```text
schema      ::= object*
object      ::= "object" name "{}"
              | "object" name "{" object-line* "}"
object-line ::= "relation" name ":" subject ("," subject)*
              | "permission" name "=" rewrite
subject     ::= object | object "#" relation | object ":*"
rewrite     ::= term ("|" term)*
term        ::= "this" | relation | relation "->" relation
```

Whitespace is line-oriented; a declaration occupies one line, blank lines are ignored, and a
trailing semicolon is ignored. The parser maps relation declarations to
`Builder.relation ... Builder.this`, permission terms to `Builder.this`, `Builder.computed`,
`Builder.arrow`, and `|` unions to `Builder.anyOf`.


## Concrete Steps

All commands assume the working directory is the repository root
`/Users/shinzui/Keikaku/bokuno/en` unless noted.

1. Edit `en-core/en-core.cabal`. Under `common shared` add `DeriveLift` to
   `default-extensions`. Under `library` `build-depends` add `template-haskell` and under
   `exposed-modules` add `En.Schema.TH`:

   ```diff
   diff --git a/en-core/en-core.cabal b/en-core/en-core.cabal
   @@ common shared default-extensions
        DeriveAnyClass
   +    DeriveLift
        DerivingStrategies
   @@ library exposed-modules
        En.Schema.Builder
   +    En.Schema.TH
        En.Tuple
   @@ library build-depends
        , base                  >=4.19 && <5
        , bytestring
        , containers
   +    , template-haskell
        , text
   ```

2. Edit `en-core/src/En/Caveat/Value.hs`: add `Lift` to the `deriving stock` clauses of the
   caveat value types and import `Language.Haskell.TH.Syntax (Lift)`.

3. Edit `en-core/src/En/Schema.hs`: import `Language.Haskell.TH.Syntax (Lift)` and add `Lift`
   to the `deriving stock` clause of each model type named in the Plan of Work, step 3.

4. Create `en-core/src/En/Schema/TH.hs` with the `mkValidSchema` definition shown in the Plan
   of Work, step 4.

5. Build the library:

   ```bash
   cabal build en-core
   ```

   Expected: it compiles. A successful tail looks like:

   ```text
   [n of m] Compiling En.Schema.TH     ( en-core/src/En/Schema/TH.hs, ... )
   ```

6. Good-path check via REPL (fast feedback before touching the test suite):

   ```bash
   cabal repl en-core-interface-tests
   ```

   then in the REPL:

   ```text
   ghci> :set -XTemplateHaskell
   ghci> import En.Schema.TH
   ghci> let v = $$(mkValidSchema kikanSchema)
   ghci> -- compare against the fixture using EP-21's accessor (name per EP-21)
   ghci> validateSchema kikanSchema == Right v
   True
   ```

7. Bad-path check. Create `en-core/test/fixtures/BadSchema.hs`:

   ```haskell
   {-# LANGUAGE TemplateHaskell #-}
   module BadSchema where

   import En.Schema.TH (mkValidSchema)
   import En.Schema.Validated (ValidSchema)
   import qualified En.Schema.Builder as Schema

   badSchema :: ValidSchema
   badSchema =
       $$(mkValidSchema
            (Schema.build
                [ Schema.object "space"
                    [ Schema.relation "owner" [Schema.subject "user"] Schema.this
                    , Schema.permission "view" (Schema.computed "ownr")  -- typo: no such relation
                    ]
                , Schema.object "user" []
                ]))
   ```

   Compile it manually (it is not in any cabal target, so we point ghc at it through the
   package environment that `cabal` sets up):

   ```bash
   cabal build en-core   # ensure the library is built first
   cabal exec -- ghc -fno-code -ien-core/src en-core/test/fixtures/BadSchema.hs
   ```

   Expected: a non-zero exit and a compile error. See Validation and Acceptance for the exact
   expected transcript.

8. Wire the permanent good-path test into `en-core/test/Main.hs` (Milestone 1), then:

   ```bash
   cabal build all
   cabal test en-core-interface-tests
   ```

   Expected: both succeed; the new test passes.

(Transcripts above are updated to match reality as work proceeds.)


## Validation and Acceptance

Acceptance is behavioral and has three observable parts.

First, the library and full build still work:

```bash
nix develop --command cabal build all
```

Expected: ends with no errors (exit 0).

Second, a compile-time-validated schema equals the builder fixture. A permanent test in
`en-core/test/Main.hs` defines `validatedKikan = $$(mkValidSchema kikanSchema)` and asserts
that the validated schema is the same model as `kikanSchema`. Run:

```bash
nix develop --command cabal test en-core-interface-tests
```

Expected: the suite passes, including `compile-time validated schema equals builder fixture`
and `schema quasi-quoter builds compact schema`.

Third — the headline behavior — a deliberately broken schema **fails to compile** with the
validation message. With `en-core/test/fixtures/BadSchema.hs` from Concrete Steps in place:

```bash
nix develop --command cabal exec -- ghc -fno-code -package en-core en-core/test/fixtures/BadSchema.hs
```

Expected: a non-zero exit and a compile error whose text contains the `validate`/EP-21
message for the typo (`computed "ownr"` references a relation that does not exist on `space`).
The transcript looks like:

```text
en-core/test/fixtures/BadSchema.hs:12:7: error: [GHC-39584]
    • schema validation failed at compile time: UnknownRelation "unknown relation: space#ownr"
    • In the Template Haskell splice
        $$(mkValidSchema ...)
  |
12 |     $$( mkValidSchema $
   |       ^^^^^^^^^^^^^^^^^...
```

The load-bearing part is the line `schema validation failed at compile time:
UnknownRelation "unknown relation: space#ownr"`: this proves the typo was caught **at build
time**, not at runtime, which is the entire point of the plan. (The exact `EnError` wording —
`UnknownRelation "unknown relation: space#ownr"` — comes from `En.Schema.validate` as read in
`en-core/src/En/Schema.hs`; if EP-21 reformats `validateSchema`'s error, update this expected
string to match, keeping the `space#ownr` reference intact.)

To prove the test is meaningful (it fails before and passes after), the good-path test should
be observed to fail if you intentionally corrupt the fixture (e.g. change `kikanSchema` so the
TH-spliced value differs) and pass when restored. Record both observations during
implementation.

If EP-20 has landed, also compile `en-core/test/fixtures/DuplicateName.hs` and confirm the
build fails with EP-20's duplicate-name `EnError` text, demonstrating the soft dependency is
honored:

```text
en-core/test/fixtures/DuplicateName.hs:12:7: error: [GHC-39584]
    • schema validation failed at compile time: SchemaViolation "duplicate relation declared: space#owner"
```

The quasi-quoter path has two equivalent manual checks:

```bash
nix develop --command cabal exec -- ghc -fno-code -package en-core en-core/test/fixtures/BadQuotedSchema.hs
nix develop --command cabal exec -- ghc -fno-code -package en-core en-core/test/fixtures/DuplicateQuotedSchema.hs
```

Expected: both exit non-zero. The load-bearing error lines are:

```text
schema validation failed at compile time: UnknownRelation "unknown relation: space#ownr"
schema validation failed at compile time: SchemaViolation "duplicate relation declared: space#owner"
```


## Idempotence and Recovery

Every step is additive and repeatable. Adding `Lift` deriving, the `template-haskell`
dependency, the `DeriveLift` extension, and the new `En.Schema.TH` module changes nothing about
existing behavior: the runtime path (service, `en-client`, runtime-loaded schemas) never calls
into `En.Schema.TH`, and the existing builder authoring is untouched. Re-running
`cabal build all` and `cabal test en-core-interface-tests` is safe any number of times.

If the `Lift` derivation fails to compile for some type (for example a future field type that
lacks a `Lift` instance), the recovery is local: hand-write a `Lift` instance for that one type
in the module that defines it, leaving every other type on `DeriveLift`. The feasibility probes
recorded in Surprises & Discoveries show all current field types lift cleanly, so this should
not arise for the present `Schema`.

If EP-21 is not yet merged when you start, do not attempt to fabricate a `ValidSchema`
constructor here — that would defeat the evidence invariant. Block on EP-21 (it is a HARD
dependency) and mark the corresponding Progress item as remaining.

The bad-path fixtures under `en-core/test/fixtures/` are deliberately **not** part of any cabal
target, so they cannot break `cabal build all` or `cabal test`. They are compiled only on
demand by the manual `ghc` invocation in Validation and Acceptance. To remove the feature
entirely, delete `En.Schema.TH`, the fixtures, the `exposed-modules` entry, the
`template-haskell` dependency, the `DeriveLift` extension, and the `Lift` deriving clauses;
nothing else depends on them.


## Interfaces and Dependencies

Libraries and why:

- `template-haskell` (boot library shipped with GHC 9.12.4, version `2.23.0.0`): provides the
  `Code`, `Q`, `Lift`, and quotation machinery used by `En.Schema.TH`. Added to the `en-core`
  **library** `build-depends`. This is the single new dependency this plan introduces (see the
  Decision Log for the cost rationale). No `th-lift-instances` or other package is needed,
  because `containers-0.7` already supplies `Lift` for `Map`/`Set` and `time` supplies it for
  `UTCTime` (verified — see Surprises & Discoveries).

Hard dependency on another plan:

- EP-21, `docs/plans/21-introduce-a-validated-schema-evidence-type.md`. Requires three things:
  (1) `newtype ValidSchema = ValidSchema Schema` with the constructor unexported from the
  public module; (2) `validateSchema :: Schema -> Either EnError ValidSchema`, the only public
  producer, plus a public accessor to unwrap a `ValidSchema` for test comparison; and (3) — the
  coordinated half of this plan — an **internal** module `En.Schema.Internal` re-exporting the
  raw constructor as `unsafeValidSchema :: Schema -> ValidSchema`. `En.Schema.TH` imports
  `validateSchema`/`ValidSchema` from EP-21's public module (assumed `En.Schema.Validated`) and
  `unsafeValidSchema` from `En.Schema.Internal`; adjust both import paths to whatever EP-21
  finally names them. `En.Schema.Internal` exists for exactly this use: it lets `mkValidSchema`
  rebuild a `ValidSchema` at the splice site by applying `unsafeValidSchema` to the lifted inner
  `Schema`, so we never lift a `ValidSchema` (whose constructor is hidden) and never name the
  hidden constructor in generated code. The lift therefore requires only `Lift Schema` and its
  components, never `Lift ValidSchema`.

Soft dependency on another plan:

- EP-20, `docs/plans/20-detect-duplicate-names-in-the-schema-builder.md`. When merged, its
  duplicate-name `EnError` is surfaced as a compile error by our path with no code change here.

Modules and signatures that must exist at each milestone's end (full paths):

- After Milestone 0: `En.Schema.TH` (file `en-core/src/En/Schema/TH.hs`) exports
  `mkValidSchema :: En.Schema.Schema -> Language.Haskell.TH.Syntax.Code Language.Haskell.TH.Syntax.Q En.Schema.Validated.ValidSchema`,
  and internally imports `unsafeValidSchema` from EP-21's `En.Schema.Internal` to wrap the
  lifted inner `Schema` at the splice site. `En.Schema` (file `en-core/src/En/Schema.hs`) and
  `En.Caveat.Value` (file `en-core/src/En/Caveat/Value.hs`) additionally `deriving stock Lift`
  for every model type named in Plan of Work step 3 — **but not `ValidSchema`**.
  `en-core/en-core.cabal` lists `En.Schema.TH` under `exposed-modules` and `template-haskell`
  under the library `build-depends`, with `DeriveLift` in `default-extensions`.

- After Milestone 1: the same plus a passing good-path case in
  `en-core/test/Main.hs` (executed by `cabal test en-core-interface-tests`) and a recorded,
  repeatable bad-path compile-failure check using `en-core/test/fixtures/BadSchema.hs`.

- After Milestone 2 (optional): `En.Schema.TH` additionally exports
  `schema :: Language.Haskell.TH.Quote.QuasiQuoter`, whose `quoteExp` parses the bracketed text
  to a `Schema`, validates it at compile time via `validateSchema`, and splices
  `unsafeValidSchema <lifted Schema>` (the same validate-and-wrap tail as `mkValidSchema`),
  failing the build on parse or validation error.


## Revision Notes

- 2026-06-23: Cross-plan reconciliation with EP-21. Originally `mkValidSchema` planned to
  re-run `validateSchema` *inside* the spliced code (or, as an alternative, lift a `ValidSchema`
  directly). Both are wrong given EP-21's design: EP-21 hides the public `ValidSchema`
  constructor, so a `Lift ValidSchema` instance would emit that hidden constructor at the splice
  site (out of scope → build failure at every call site). Revised so that `mkValidSchema` runs
  `validateSchema` at COMPILE time only, and on success lifts the **inner `Schema`** and splices
  `unsafeValidSchema <lifted Schema>`, where `unsafeValidSchema :: Schema -> ValidSchema` is a
  new internal wrapper EP-21 now exposes from `En.Schema.Internal` specifically for this. This
  keeps `validateSchema` as the sole *public* producer of evidence while letting TH rebuild a
  `ValidSchema` without naming the hidden constructor, and it removes `ValidSchema` from the
  `DeriveLift` list (only `Lift Schema` and its components are needed). Updated: Purpose context,
  Context and Orientation (EP-21 paragraph), Plan of Work step 4 and the Milestone 0 scope,
  Decision Log (added the lift-via-inner-Schema decision; trimmed the `DeriveLift` decision),
  and Interfaces and Dependencies (explicit `En.Schema.Internal` dependency).
