---
id: 63
slug: adopt-the-fleet-haskell-core-standards-across-every-en-package
title: "Adopt the fleet Haskell core standards across every en package"
kind: exec-plan
created_at: 2026-08-25T20:39:37Z
intention: "intention_01m0xaavwqeznrgzs3j67m0q21"
master_plan: "docs/masterplans/11-bring-en-into-conformance-with-the-haskell-jitsurei-pattern-catalog.md"
---

# Adopt the fleet Haskell core standards across every en package

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

`en` is a Haskell project of eight cabal packages. Every one of them declares its own list
of language extensions in a `common shared` stanza, and **no two of the eight lists are the
same**. `en-core` enables nine extensions; `en-migrations` enables two; `en-postgres`
enables three, and is the only package in the repository that does *not* enable
`DuplicateRecordFields`. Seven of the eight enable `OverloadedRecordDot`; exactly one
enables `OverloadedLabels`.

That is not a style quibble. It means a module cannot be moved between packages without
first discovering which extensions its new home happens to lack, and it means the four
extensions the fleet treats as a baseline — the ones every other service can assume — are
present in `en` almost by accident.

After this plan, a contributor can state `en`'s language settings in one sentence: **every
package uses the GHC2024 language edition with the same baseline extensions, plus a small
recorded set of additions.** Three further things become true, each of which you can
observe by running a command:

- **A missing route handler fails the build instead of warning.** `en`'s API is a
  `NamedRoutes` record — a Haskell record where each field is one HTTP route — and the
  value of that shape is that adding a field breaks construction of the server record until
  you write its handler. That guarantee is only a *warning* by default. After this plan,
  deleting a field from the server record makes `cabal build all` fail.
- **`en` has a real prelude.** `en-core/src/En/Prelude.hs` exists today as a nine-line stub
  that re-exports `Prelude` and `Text`, is listed in `en-core`'s `exposed-modules`, and is
  imported by exactly zero modules. This plan fills it out into the module the fleet
  standard describes and adds the `lens` and `generic-lens` dependencies it needs.
- **Qualified imports read the same everywhere.** Three files still use the prepositive
  `import qualified X as Y` form; the rest of the tree uses the postpositive
  `import X qualified as Y`.

**This plan changes no behavior and migrates no call site.** Every test that passes before
must pass after, and the diff is almost entirely `.cabal` files. The call-site migration
onto `#label` syntax and lens operators is a separate plan,
`docs/plans/68-migrate-en-s-records-to-generic-lens-label-syntax-and-a-custom-prelude.md`,
which consumes what this one builds.


## Progress

- [x] (2026-08-25T21:16:04Z) Milestone 1 — Give all eight packages an identical baseline `common shared` stanza:
      `default-language: GHC2024` plus `DeriveAnyClass`, `DuplicateRecordFields`,
      `OverloadedLabels`, `OverloadedStrings`, keeping each package's justified additions
      and deleting the ones GHC2024 already provides. Build and test after each package.
- [x] (2026-08-25T21:18:41Z) Milestone 2 — Turn on `-Werror=missing-fields` in the shared `common warnings`
      stanza, prove it bites with a deliberate temporary deletion, and fix anything it
      surfaces.
- [x] (2026-08-25T21:19:30Z) Milestone 3 — Convert the three prepositive `import qualified` lines to the
      postpositive form.
- [ ] Milestone 4 — Add `lens` and `generic-lens` to `en-core` and fill out
      `en-core/src/En/Prelude.hs` per the fleet prelude standard, with a `PackageImports`
      per-file pragma and **without** importing `Data.Generics.Labels`. Prove the prelude
      compiles and that a scratch module can use `#label` by importing
      `Data.Generics.Labels ()` itself. Migrate no existing module.


## Surprises & Discoveries

- Discovery (2026-08-25, while planning): **`En.Prelude` already exists and is dead code.**
  `en-core/src/En/Prelude.hs` is nine lines — `module En.Prelude (module Prelude, Text)` —
  its Haddock says it "mirrors shomei's `Shomei.Prelude`" and "expands as the engine grows",
  it is listed in `en-core`'s `exposed-modules`, and
  `grep -rln "import En.Prelude" --include='*.hs' .` returns **zero** files. So Milestone 4
  fills out a module that already exists rather than creating one, and there is no existing
  importer whose expectations could break.

- Discovery (2026-08-25, while planning): **`MultilineStrings` is already in use, per-file
  rather than in a stanza.** Four modules use GHC 9.12's multiline string literals —
  `en-postgres/src/En/Postgres/TupleStore.hs`,
  `en-postgres/src/En/Postgres/Datastore.hs`, `en-postgres/integration-test/Main.hs`, and
  `en-postgres/lookup-spike/Main.hs` — for embedded SQL. The fleet standard permits adding
  `MultilineStrings` to the `common` stanza when a documented pattern justifies it, but does
  not require it. Since the extension is confined to one package's SQL-bearing modules and
  is already declared per file, this plan leaves it alone rather than promoting it to a
  project-wide default. Recorded so the omission reads as a decision.

- Discovery (2026-08-25, baseline validation): **the aggregate test runner can exhaust the
  Biscuit smoke test's fixed authorization timeout while the suite is healthy in
  isolation.** The first `cabal test all` run passed the other seven suites but reported
  `en-biscuit test FAILED: smoke test: authorization rejected: Timeout`; immediately
  running `cabal test en-biscuit-tests --test-show-details=direct` passed. Treat this as a
  pre-existing concurrency-sensitive baseline flake and confirm the suite independently
  whenever an aggregate run repeats it.

- Discovery (2026-08-25, Milestone 1): **`en-core` still needs its generated record
  selectors.** Adding the optional `NoFieldSelectors` extension made `cabal build all`
  fail in `En.Schema` because `En.Schema.Internal` no longer exported the generated
  `unValidSchema` selector. The four fleet-baseline extensions do not require
  `NoFieldSelectors`, so `en-core` retains selector generation until EP-68 migrates that
  call site with the rest of the record-idiom sweep.

  ```text
  src/En/Schema.hs:49:46: error: [GHC-61689]
      Module ‘En.Schema.Internal’ does not export ‘unValidSchema’.
      Notice that ‘unValidSchema’ is a field selector ... suppressed by NoFieldSelectors.
  ```

- Discovery (2026-08-25, Milestone 2): **the targeted missing-handler guard fires as a
  build error.** Temporarily omitting the `schema` field from the `EnApi` server record
  made `cabal build all` fail with the exact warning group promoted to an error; restoring
  the field returned the tree to a successful build.

  ```text
  src/En/Servant/API.hs:108:3: error: [GHC-20125]
      [-Wmissing-fields, Werror=missing-fields]
      Fields of ‘EnApi’ not initialised:
          schema :: mode0 :- ("v1" :> NamedRoutes SchemaRoutes)
  ```

- Discovery (2026-08-25, Milestone 3): **the commit hook parses fixture modules outside
  their Cabal stanza.** Cabal correctly supplies GHC2024 and compiles postpositive
  qualified imports, but the treefmt Fourmolu invocation only supplied three unrelated
  parser flags and rejected `import En.Schema.Builder qualified as Schema`. The three
  standalone fixtures therefore carry an explicit, redundant `ImportQualifiedPost`
  pragma so both Cabal and repository tooling accept the fleet import form.

  ```text
  The GHC parser (in Haddock mode) failed:
    Found `qualified' in postpositive position.
  ```

(Add further entries as work proceeds.)


## Decision Log

- Decision: Keep `NoFieldSelectors` and `OverloadedRecordDot` in the packages that have them
  today, alongside the newly added baseline extensions, rather than removing them as part of
  this plan.
  Rationale: those two extensions are what make `en`'s current record idiom work, and
  roughly 1,400 call sites still depend on it. Removing them here would break the build
  everywhere for no gain, since the migration onto `#label` is a separate plan
  (`docs/plans/68-...`) sequenced last in this initiative. The baseline extensions this plan
  adds coexist with them without conflict — `OverloadedLabels` and `OverloadedRecordDot` are
  independent mechanisms — so both idioms compile during the transition. `docs/plans/68-...`
  owns deciding whether the two extensions come out at the end.
  Date: 2026-08-25

- Decision: Delete `DerivingStrategies`, `LambdaCase`, `DataKinds`, and `DeriveGeneric` from
  the per-package extension lists rather than carrying them forward.
  Rationale: the GHC2024 language edition already provides `DataKinds`,
  `DerivingStrategies`, and `LambdaCase`, and `DeriveGeneric` has been on by default since
  GHC 9.2. Listing an extension GHC2024 already implies is noise that makes the *real*
  additions harder to see, and the fleet standard says so explicitly. Every package already
  declares `default-language: GHC2024`, so removing them is a no-op that must be verified by
  building rather than assumed.
  Date: 2026-08-25

- Decision: Do not promote `MultilineStrings` to the shared stanza.
  Rationale: see Surprises & Discoveries. It is used by four SQL-bearing modules in one
  package and already declared with per-file pragmas. The standard permits promotion but
  does not require it, and a project-wide default would invite multiline literals into
  modules where ordinary string literals are clearer.
  Date: 2026-08-25

- Decision: Keep `NoFieldSelectors` out of `en-core` during this baseline-only plan.
  Rationale: the optional extension suppresses `unValidSchema`, which remains part of
  `En.Schema`'s implementation. Rewriting that call site would start the record migration
  owned by EP-68, while omitting the optional extension preserves behavior and still gives
  `en-core` the mandatory GHC2024 baseline.
  Date: 2026-08-25

- Decision: Add `ImportQualifiedPost` pragmas only to the three standalone schema fixtures.
  Rationale: they already receive the extension through GHC2024 in Cabal, but the formatter
  hook parses staged files independently and does not inherit package defaults. A local
  redundant pragma makes that tooling boundary explicit without changing the project's
  language baseline or the fixture behavior.
  Date: 2026-08-25

(Add further entries as work proceeds.)


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### What this repository is

`en` is a Haskell implementation of relationship-based authorization (ReBAC) in the style
of Google Zanzibar: it stores relationship *tuples* — facts like "user:alice is `viewer` of
space:project-x" — and answers questions about them over HTTP. It is built with `cabal` and
GHC 9.12.4, pinned by `cabal.project` at the repository root, and work happens inside a nix
development shell.

The repository has eight packages, each in its own top-level directory with a matching
`.cabal` file:

- `en-core` — the authorization engine, schema language, and effect definitions.
- `en-postgres` — the PostgreSQL interpreters for those effects, written with `hasql`.
- `en-servant` — the HTTP API type, its handlers, and the OpenAPI document generator.
- `en-server` — the standalone server executable and its WAI middleware.
- `en-client` — a generated Haskell client for the API.
- `en-biscuit` — an optional Biscuit decision-token layer.
- `en-example` — a runnable example application.
- `en-migrations` — the database schema, owned as a `pg-migrate` component.

### Terms used in this plan

**A cabal `common` stanza** is a named block of settings that other stanzas in the same
`.cabal` file can pull in with `import: <name>`. Every `en` package has two: `common
warnings` (its `ghc-options`) and `common shared` (its `default-language` and
`default-extensions`). Every library, executable, test-suite, and benchmark stanza in the
file writes `import: warnings, shared`, so editing the common stanza changes the whole
package at once.

**A language extension** is an opt-in change to Haskell's syntax or type system, named in
`default-extensions` (applying to every module in the package) or in a `{-# LANGUAGE X #-}`
pragma at the top of one file.

**A language edition** — here `GHC2024` — is a named bundle of extensions that GHC turns on
together. Because `GHC2024` already includes `DataKinds`, `DerivingStrategies`,
`LambdaCase`, and `ImportQualifiedPost` among others, listing those separately in
`default-extensions` is redundant.

**`NamedRoutes`** is the servant style `en` uses for its HTTP API: the API is a Haskell
record whose fields are routes, and the server is a record of the same shape whose fields
are handlers. Its safety property is that adding a route field breaks construction of the
server record — *provided* the missing field is an error rather than a warning.

**A prelude module** here means a project-local module that re-exports the imports nearly
every file needs, so one `import En.Prelude` replaces ten import lines.

**`generic-lens`** is a library that derives a lens for any field of any record deriving
`Generic`, reached through the `#fieldName` syntax that `OverloadedLabels` enables. The
`#label`-to-lens meaning comes from an **orphan instance** — an instance defined in neither
the class's module nor the type's — living in `Data.Generics.Labels`. Where that module is
imported decides which modules see that meaning, which is why this plan is careful about it.

### The rules this plan implements

The conventions are recorded canonically in the fleet's Haskell pattern catalog, whose
project handle is `mori://shinzui/haskell-jitsurei`. Two documents govern this plan:

- `mori://shinzui/haskell-jitsurei/docs/core-standards` — the baseline: minimum GHC
  version, language edition, the four mandatory extensions, and import style.
- `mori://shinzui/haskell-jitsurei/docs/core-custom-prelude` — the prelude's shape, its
  `PackageImports` pragma, and the rule against re-exporting `Data.Generics.Labels`.

A third is consulted for one rule only:
`mori://shinzui/haskell-jitsurei/docs/api-servant-routes`, which is where
`-Werror=missing-fields` comes from. Resolve any of these to a file on this machine with
`mori path <uri>`; today they land under `patterns/` in the working copy at
`/Users/shinzui/Keikaku/bokuno/haskell-jitsurei`. Everything needed from them is restated
below, so neither that repository nor a working `mori` is required to execute this plan.

Restated in full, the baseline is:

> **GHC 9.12 or newer.** Every package must use the `GHC2024` language edition and enable
> `DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`, and `OverloadedStrings` in
> a `common` stanza that every other stanza imports. These are the minimum; projects may add
> to them but should not relax them. Qualified imports use the postpositive form
> (`import Data.Text qualified as Text`), which GHC2024 provides through
> `ImportQualifiedPost`.

Each extension is mandatory for a stated reason. `DeriveAnyClass` is required by the
explicit `deriving anyclass (...)` strategy — and is safe as a global default *only because*
deriving strategies are always written explicitly, since with it enabled a strategy-less
`deriving (C)` can silently pick the anyclass path and produce an empty instance.
`DuplicateRecordFields` lets records share field names without prefixes.
`OverloadedLabels` enables the `#fieldName` syntax. `OverloadedStrings` is needed for `Text`
literals.

And the prelude rule, restated:

> Name the module `<Project>.Prelude` and put it in the core library package. Collect
> re-exports with `as X` and export `module X`. Enable `PackageImports` with a **per-file
> pragma**, never as a `default-extension`, because package-qualified imports exist only to
> disambiguate this module's re-exports. Export `Control.Lens` directly. **Do not** import
> `Data.Generics.Labels` in the prelude: its orphan `IsLabel` instance would then be forced
> on every module in the project, breaking any module that needs a different `IsLabel`
> instance, and the breakage cannot be repaired at the use site.

### Where `en` stands today

Every package already declares `default-language: GHC2024`, so the language edition is not
at issue. The extension lists are, and here they are in full as of 2026-08-25:

```text
en-core         BlockArguments DeriveAnyClass DeriveLift DerivingStrategies
                DuplicateRecordFields LambdaCase OverloadedLabels
                OverloadedRecordDot OverloadedStrings
en-postgres     DerivingStrategies OverloadedRecordDot OverloadedStrings
en-servant      BlockArguments DataKinds DeriveAnyClass DeriveGeneric
                DuplicateRecordFields LambdaCase NoFieldSelectors
                OverloadedRecordDot OverloadedStrings TypeFamilies
en-server       BlockArguments DuplicateRecordFields NoFieldSelectors
                OverloadedRecordDot OverloadedStrings
en-client       DuplicateRecordFields NoFieldSelectors OverloadedRecordDot
                OverloadedStrings
en-biscuit      DuplicateRecordFields NoFieldSelectors OverloadedRecordDot
                OverloadedStrings
en-example      DataKinds DeriveAnyClass DeriveGeneric DuplicateRecordFields
                LambdaCase NoFieldSelectors OverloadedRecordDot OverloadedStrings
                TypeFamilies
en-migrations   LambdaCase OverloadedStrings
```

Read against the baseline: `DeriveAnyClass` is missing from five packages,
`OverloadedLabels` from seven, and `DuplicateRecordFields` from two (`en-postgres` and
`en-migrations`). `OverloadedStrings` is the only one of the four that is already universal.

The warning stanza is identical in all eight and contains no `-Werror` of any kind:

```cabal
common warnings
  ghc-options:
    -Wall -Wcompat -Widentities -Wincomplete-record-updates
    -Wincomplete-uni-patterns -Wpartial-fields -Wredundant-constraints
```

`grep -rn "^import qualified" --include='*.hs' .` returns exactly three hits, all in
`en-core`'s test fixtures: `en-core/test/fixtures/BadSchema.hs:7`,
`en-core/test/fixtures/DuplicateName.hs:7`, and
`en-core/test/fixtures/BadPermissionThis.hs:5`. Each is
`import qualified En.Schema.Builder as Schema`.

Neither `lens` nor `generic-lens` appears in any `.cabal` file:
`grep -rn "generic-lens" --include='*.cabal' .` is empty.

### Relevant Architecture Decision Records

`en`'s ADRs live in `docs/adr/` as ordinary Markdown files. `mori.dhall` declares one OKF
bundle, `docs/capabilities`, and none at `docs/adr`, so the repository's existing
filesystem convention is authoritative; do not add OKF frontmatter to an ADR here.

One ADR bears directly on this plan:
[ADR 2 — crypton 1.1 binds en's dependency closure through a biscuit-haskell fork](../adr/0002-crypton-1-1-binds-en-s-dependency-closure-through-a-biscuit-haskell-fork.md).
Its point, restated: cabal resolves exactly one version of a package for the whole project,
and `en`'s closure is already tightly bound. `pg-migrate` computes migration checksums with
`crypton >= 1.1`; the published `biscuit-haskell` cannot live with that, so `cabal.project`
pins a fork by `source-repository-package`. The ADR also records a trap worth carrying into
Milestone 4: **relaxing a version bound alone is not enough** — the solver can succeed while
the compile then fails on a missing instance. This plan adds two libraries (`lens`,
`generic-lens`) to that closure, so Milestone 4 proves the solve *and* the build rather than
assuming that a successful `cabal build` plan means success.

The other two ADRs were read and do not constrain this work:
[ADR 1](../adr/0001-en-s-schema-is-an-append-only-pg-migrate-component.md) governs schema
migrations, and this plan touches no schema;
[ADR 3](../adr/0003-the-in-memory-store-is-for-tests-and-demos-only.md) governs the
in-memory store's status, and this plan touches no interpreter.

### How this plan relates to the others in its initiative

This is the first child plan of
`docs/masterplans/11-bring-en-into-conformance-with-the-haskell-jitsurei-pattern-catalog.md`.
It has **no hard dependencies** and can start immediately. Two later plans consume it:

- `docs/plans/68-migrate-en-s-records-to-generic-lens-label-syntax-and-a-custom-prelude.md`
  hard-depends on this plan's Milestone 4 — it migrates call sites onto the `En.Prelude`
  and the `generic-lens` dependency established here.
- Every plan that adds a route to the API record benefits from Milestone 2's
  `-Werror=missing-fields`, which is why this plan runs first.

### Build and test commands

Work from `/Users/shinzui/Keikaku/bokuno/en` inside the nix development shell.

```bash
cd /Users/shinzui/Keikaku/bokuno/en
cabal build all
cabal test all
```

`cabal test all` runs every package's test suite. Some suites need a database; the
`justfile` at the repository root has the surrounding targets (`just process-up`,
`just run-migrations`, `just test-server`). If `cabal test all` does not pass **before** you
start, fix that first rather than blaming your own changes.


## Plan of Work

The order is chosen so that each milestone is verifiable on its own and so that the riskiest
change — adding two libraries to a tightly bound dependency closure — comes last, when the
rest is already committed and a `git reset --hard` costs nothing.

### Milestone 1 — One baseline stanza, eight packages

Scope: the `common shared` stanza in all eight `.cabal` files. No `.hs` file changes.

Rewrite each package's `default-extensions` list as the baseline four plus that package's
justified additions, dropping anything GHC2024 already provides. The target lists:

```text
baseline (all eight)   DeriveAnyClass DuplicateRecordFields OverloadedLabels
                       OverloadedStrings

en-core          + BlockArguments DeriveLift NoFieldSelectors OverloadedRecordDot
en-postgres      + OverloadedRecordDot
en-servant       + BlockArguments NoFieldSelectors OverloadedRecordDot TypeFamilies
en-server        + BlockArguments NoFieldSelectors OverloadedRecordDot
en-client        + NoFieldSelectors OverloadedRecordDot
en-biscuit       + NoFieldSelectors OverloadedRecordDot
en-example       + NoFieldSelectors OverloadedRecordDot TypeFamilies
en-migrations    + (none)
```

Three notes on that table. `DerivingStrategies`, `LambdaCase`, `DataKinds`, and
`DeriveGeneric` do not appear anywhere because GHC2024 supplies the first three and GHC has
supplied `DeriveGeneric` by default since 9.2 — removing them is the point, not an
oversight. `en-core` gains `NoFieldSelectors`, which it did not have, purely so the eight
packages differ only where there is a reason; if that turns out to break a module that
relies on a generated field selector, keep the selector-based code and record the exception
here rather than forcing it. And `en-migrations` ends with the bare baseline, losing its
`LambdaCase` line to GHC2024.

Work one package at a time and run `cabal build all` after each, because a removed extension
fails loudly and locally. Expect `DuplicateRecordFields` newly arriving in `en-postgres` and
`en-migrations` to be the most likely source of a genuine new error: with it on, an
ambiguous field reference that previously resolved becomes ambiguous. If that happens, fix
the reference rather than dropping the extension.

Acceptance: `cabal build all && cabal test all` passes; every `.cabal` file's `common
shared` stanza contains the same four baseline extensions; and
`git diff --stat` shows only `.cabal` files, or `.cabal` files plus a small number of
disambiguating `.hs` edits explained in Surprises & Discoveries.

### Milestone 2 — Make a missing handler an error

Scope: the `common warnings` stanza in all eight `.cabal` files, plus whatever the new error
surfaces.

The `NamedRoutes` guarantee `en` relies on — that adding a route to the API record breaks
the build until a handler exists — is by default only a warning. GHC reports a missing field
in a record construction as `-Wmissing-fields`, which `-Wall` turns on but nothing turns
fatal. Add one line to the shared warnings stanza in each package:

```cabal
common warnings
  ghc-options:
    -Wall -Wcompat -Widentities -Wincomplete-record-updates
    -Wincomplete-uni-patterns -Wpartial-fields -Wredundant-constraints
    -Werror=missing-fields
```

Then **prove it bites**, because a guard you have not seen fire is a guard you are trusting
on faith. Temporarily delete one field from the server record in
`en-servant/src/En/Servant/API.hs`, run `cabal build all`, and watch it fail with a
`missing-fields` error rather than a warning. Restore the field. Do not commit the deletion;
paste the error into Surprises & Discoveries as evidence.

Use `-Werror=missing-fields` specifically, not a blanket `-Werror`. A blanket `-Werror` makes
every future GHC deprecation a build break for everyone, which is a different and much larger
policy decision than this plan is making.

Acceptance: `cabal build all && cabal test all` passes with the flag on; the deliberate
temporary deletion produced a build **error**, and its text is recorded below.

### Milestone 3 — One import style

Scope: three lines in three files.

```text
en-core/test/fixtures/BadSchema.hs:7
en-core/test/fixtures/DuplicateName.hs:7
en-core/test/fixtures/BadPermissionThis.hs:5
```

Each reads `import qualified En.Schema.Builder as Schema`; each becomes
`import En.Schema.Builder qualified as Schema`. The postpositive form keeps the module name
in the same column as unqualified imports, which is why the fleet standardized on it;
GHC2024 provides it through `ImportQualifiedPost`, so no extension is needed.

These three files are *fixtures* — modules that are expected to fail compilation in a
controlled way, used by `en-core`'s test suite to check that the schema builder rejects bad
input. Changing an import line does not change what they are testing, but run the suite and
confirm rather than assuming.

Acceptance: `grep -rn "^import qualified" --include='*.hs' .` returns nothing;
`cabal test all` passes.

### Milestone 4 — A real prelude, and the lens dependencies

Scope: `en-core/en-core.cabal` and `en-core/src/En/Prelude.hs`. **No existing module is
migrated to import the prelude.**

First the dependencies. Add to `en-core`'s library stanza:

```cabal
    , generic-lens ^>=2.3
    , lens         ^>=5.3
```

Those bounds are what the fleet standard names, verified against Hackage on 2026-07-24
(`generic-lens` 2.3.0.0, `lens` 5.3.6). **Re-verify them before committing**: run
`cabal build all` and read `dist-newstyle/cache/plan.json` for what the solver actually
chose, and check the current released versions rather than trusting a date-stamped claim.
This matters more here than it usually would, because of ADR 2: `en`'s closure is pinned by
`crypton >= 1.1` and a forked `biscuit-haskell`, and `lens` has a wide dependency footprint.
If the solver cannot find a plan, do not widen a bound and move on — ADR 2 records that the
solver can succeed while the compile then fails on a missing instance. Find out *which*
package is in conflict and record it in Surprises & Discoveries.

Then the module. `en-core/src/En/Prelude.hs` currently reads, in full:

```haskell
-- | A thin internal prelude for en-core. Kept minimal for now; expands as the
-- engine grows (mirrors shomei's @Shomei.Prelude@).
module En.Prelude
  ( module Prelude,
    Text,
  )
where

import Data.Text (Text)
```

Replace it with the fleet shape. The essential mechanics, each of which matters:

```haskell
{-# LANGUAGE PackageImports #-}

-- | en's project prelude. One @import En.Prelude@ replaces the imports that appear in
-- nearly every module.
--
-- The @PackageImports@ pragma is per-file deliberately: package-qualified imports exist
-- only to disambiguate this module's re-exports, and enabling the extension project-wide
-- would encourage them elsewhere, where they add noise without benefit.
--
-- NOTE: do NOT import @Data.Generics.Labels@ here. Its orphan @IsLabel@ instance is what
-- gives @#field@ its generic-lens meaning, and re-exporting it from the prelude forces
-- that meaning on every module in the project — including any module that needs a
-- different @IsLabel@ instance, which then cannot be repaired at the use site. Import it
-- per-module, in each module that uses @#label@ over a @Generic@ record.
module En.Prelude
  ( module X,
    module Control.Lens,
  )
where

import "base" Control.Applicative as X ((<|>))
import "base" Control.Monad as X (guard, unless, void, when)
import "base" Control.Monad.IO.Class as X (MonadIO, liftIO)
import "base" Data.List.NonEmpty as X (NonEmpty (..))
import "base" Data.Maybe as X (fromMaybe, isJust, isNothing)
import "base" Data.Proxy as X (Proxy (..))
import "base" GHC.Generics as X (Generic)
import "lens" Control.Lens
import "text" Data.Text as X (Text)
import "time" Data.Time as X (UTCTime, getCurrentTime)
```

Four properties to preserve. The `as X` aliases are what `module X` in the export list
collects — an import without `as X` is not re-exported. `Control.Lens` is exported directly
rather than through `X` because a blanket re-export of the operators is the point. The
`PackageImports` pragma is per-file, never a `default-extension`. And `aeson` re-exports are
deliberately omitted here: the fleet example includes them, but `en`'s wire types have
hand-written `ToJSON`/`FromJSON` instances that pin exact JSON bytes, and pulling the aeson
vocabulary into every module would invite generic derivation into modules where the exact
bytes are the contract. Add them later if a real need appears, and record why.

Note the module drops `module Prelude` from its export list. Nothing imports `En.Prelude`
today, so nothing can break; and re-exporting the standard `Prelude` from a prelude that
callers import *alongside* the implicit one produces ambiguity at every use site.

Finally, **prove `#label` works without the prelude enabling it**. Add a small test module —
`en-core/test/` is the right home — that defines a two-field record deriving `Generic`,
imports `En.Prelude` and `Data.Generics.Labels ()`, and asserts a round trip:

```haskell
import Data.Generics.Labels ()
import En.Prelude

data Probe = Probe {name :: !Text, count :: !Int}
  deriving stock (Generic, Eq, Show)

-- assert: (Probe "a" 1 ^. #name) == "a"
-- assert: (Probe "a" 1 & #count .~ 7) == Probe "a" 7
```

This is the acceptance evidence for the whole milestone: it shows the dependency resolves,
the prelude exports the operators, and the per-module `Data.Generics.Labels ()` import is
sufficient to give `#label` its meaning. Keep the test — it is the regression guard that
`docs/plans/68-...` depends on before it migrates 1,400 call sites.

Acceptance: `cabal build all && cabal test all` passes; the new prelude test is green;
`grep -rn "Data.Generics.Labels" en-core/src/En/Prelude.hs` is **empty**; and
`grep -rln "import En.Prelude" --include='*.hs' .` names only the new test module, because
this plan migrates nothing.


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/en` inside the nix development shell. Establish a
baseline first:

```bash
cd /Users/shinzui/Keikaku/bokuno/en
cabal build all
cabal test all
```

Take an inventory you can diff against at the end:

```bash
for f in en-*/*.cabal; do
  echo "### $f"
  sed -n '/^common shared/,/^$/p' "$f"
done
```

Milestone 1, one package at a time:

```bash
$EDITOR en-core/en-core.cabal        # rewrite the default-extensions list
cabal build all                      # after each package, not after all eight
```

Commit when all eight build and test:

```text
build(cabal): one baseline extension set across every package

Give all eight packages the fleet baseline -- DeriveAnyClass,
DuplicateRecordFields, OverloadedLabels, OverloadedStrings -- and drop the
extensions GHC2024 already provides. Per-package additions stay where they
are justified.

MasterPlan: docs/masterplans/11-bring-en-into-conformance-with-the-haskell-jitsurei-pattern-catalog.md
ExecPlan: docs/plans/63-adopt-the-fleet-haskell-core-standards-across-every-en-package.md
Intention: intention_01m0xaavwqeznrgzs3j67m0q21
```

Milestone 2, including the proof:

```bash
# add -Werror=missing-fields to each common warnings stanza, then:
cabal build all
# now delete one field from the server record in en-servant/src/En/Servant/API.hs
cabal build all        # must FAIL with a missing-fields error, not warn
git checkout -- en-servant/src/En/Servant/API.hs
cabal build all && cabal test all
```

Milestone 3:

```bash
grep -rn "^import qualified" --include='*.hs' .   # three hits before
# edit each to the postpositive form, then:
grep -rn "^import qualified" --include='*.hs' .   # no hits after
cabal test all
```

Milestone 4:

```bash
$EDITOR en-core/en-core.cabal          # add generic-lens and lens
cabal build all                        # the solve is the first thing to prove
python3 -c 'import json; p=json.load(open("dist-newstyle/cache/plan.json")); \
  print(sorted({(u["pkg-name"], u["pkg-version"]) for u in p["install-plan"] \
  if u.get("pkg-name") in ("lens","generic-lens")}))'
$EDITOR en-core/src/En/Prelude.hs      # fill it out
$EDITOR en-core/test/...               # add the #label probe test
cabal build all && cabal test all
```

Every commit on this plan carries all three trailers, as shown above.


## Validation and Acceptance

The whole plan is verifiable from the shell. Run each of these and compare against the
stated expectation.

**The baseline is uniform.** Every package's stanza contains the same four extensions:

```bash
for f in en-*/*.cabal; do
  printf '%-16s' "$(basename "$f" .cabal)"
  for e in DeriveAnyClass DuplicateRecordFields OverloadedLabels OverloadedStrings; do
    if sed -n '/^common shared/,/^$/p' "$f" | grep -q "  $e\$"; then
      printf 'y'
    else
      printf 'N'
    fi
  done
  echo
done
```

Expected: eight lines, each ending `yyyy`. Any `N` is a package that was missed.

**GHC2024's own extensions are gone from the lists.** None of these should appear in any
`common shared` stanza:

```bash
grep -rn "DerivingStrategies\|LambdaCase\|DataKinds\|DeriveGeneric" --include='*.cabal' .
```

Expected: no output.

**A missing route handler is an error.** With `en-servant/src/En/Servant/API.hs` temporarily
missing one field from its server record, `cabal build all` fails, and the message names
`missing-fields`. Restore the file afterwards. The captured error text belongs in Surprises
& Discoveries, and its presence there is what proves this was actually observed rather than
assumed.

**Import style is uniform.**

```bash
grep -rn "^import qualified" --include='*.hs' .
```

Expected: no output.

**The prelude works and does not leak `#label`.**

```bash
grep -n "Data.Generics.Labels" en-core/src/En/Prelude.hs   # expected: no output
grep -n "PackageImports" en-core/src/En/Prelude.hs         # expected: line 1
grep -rn "PackageImports" --include='*.cabal' .            # expected: no output
grep -rln "import En.Prelude" --include='*.hs' .           # expected: only the new test
cabal test all
```

The last of those is the substantive one: the new probe test asserts
`Probe "a" 1 ^. #name == "a"` and `(Probe "a" 1 & #count .~ 7) == Probe "a" 7`, which fails
to compile if `generic-lens` is missing, if `OverloadedLabels` is off, or if the per-module
`Data.Generics.Labels ()` import is not sufficient.

**Nothing regressed.** `cabal build all && cabal test all` passes, and the full test suite's
count of passing tests is the same as at the baseline plus the new probe test. This plan
changes no behavior, so any change in test results is a bug in the plan's execution.


## Idempotence and Recovery

Every step here is an ordinary source edit. Nothing touches the database, no migration is
added, no persistent state is read or written. `cabal build all` and `cabal test all` are
pure functions of the tree, so re-running any step is safe and converges.

Commit at each milestone boundary so there is always a clean point to return to.
`git checkout -- .` discards uncommitted work; `git reset --hard HEAD` returns to the last
commit.

Two specific recovery notes.

**If Milestone 1 breaks a package you cannot quickly fix**, restore that one file
(`git checkout -- <package>/<package>.cabal`) and move on to the next package rather than
leaving the tree unbuildable. Record the package and the error in Surprises & Discoveries
and come back to it. The milestone is not complete until all eight are converted, but a
partial conversion that builds is a much better place to stop than a full one that does not.

**If Milestone 4's solve fails**, the safe response is to revert
`en-core/en-core.cabal` and diagnose before trying again. Do not reach for `allow-newer` or
a widened bound as a first move: ADR 2 records the specific failure mode where the solver
succeeds after a bound is relaxed and the *compile* then fails on a missing instance, which
is a much more confusing place to be than an honest solver error. Run
`cabal build all -v2` and read which package pair is in conflict.


## Interfaces and Dependencies

### Libraries

Two are added, both to `en-core`'s library stanza only:

- **`lens ^>=5.3`** — the lens operators (`^.`, `.~`, `?~`, `%~`, `&`) the prelude
  re-exports. Nothing else in `en` uses it today.
- **`generic-lens ^>=2.3`** — supplies the orphan `IsLabel` instance in
  `Data.Generics.Labels` that gives `#fieldName` its meaning as a lens over any `Generic`
  record.

Those bounds come from the fleet standard, verified against Hackage on 2026-07-24
(`generic-lens` 2.3.0.0, `lens` 5.3.6). **Re-verify against Hackage and record what the
solver actually resolved** in this section when the milestone lands, per the MasterPlan's
rule that every child plan proves its cohort before writing code. `en`'s closure is bound by
`crypton >= 1.1` and a forked `biscuit-haskell` under
[ADR 2](../adr/0002-crypton-1-1-binds-en-s-dependency-closure-through-a-biscuit-haskell-fork.md).

No package is removed, no pin changes, and `cabal.project` is not edited.

### Modules and their shape at the end

`En.Prelude`, exposed from `en-core` (it is already in `exposed-modules`; do not add it
twice):

```haskell
{-# LANGUAGE PackageImports #-}
module En.Prelude (module X, module Control.Lens) where
```

Its export list re-exports, via `as X`: `Generic`; `void`, `when`, `unless`, `guard`;
`fromMaybe`, `isJust`, `isNothing`; `Proxy (..)`; `(<|>)`; `MonadIO`, `liftIO`;
`NonEmpty (..)`; `Text`; `UTCTime`, `getCurrentTime`. And, directly, the whole of
`Control.Lens`. It must **not** export or import `Data.Generics.Labels`.

One new test module in `en-core/test/` defining a `Generic` probe record and asserting
`^. #field` and `& #field .~ v` behave, importing `Data.Generics.Labels ()` itself.

### Modules that must not change

No `.hs` file outside `en-core/src/En/Prelude.hs`, the three test fixtures in Milestone 3,
and the new probe test should appear in this plan's diff. If one does — because a newly
enabled extension forced a disambiguation — that is acceptable, but it must be named in
Surprises & Discoveries with the error that forced it. A large `.hs` diff means the plan has
drifted into `docs/plans/68-...`'s scope and should stop.
