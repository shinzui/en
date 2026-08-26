---
id: 68
slug: migrate-en-s-records-to-generic-lens-label-syntax-and-a-custom-prelude
title: "Migrate en's records to generic-lens label syntax and a custom prelude"
kind: exec-plan
created_at: 2026-08-25T20:39:52Z
intention: "intention_01m0xaavwqeznrgzs3j67m0q21"
master_plan: "docs/masterplans/11-bring-en-into-conformance-with-the-haskell-jitsurei-pattern-catalog.md"
---

# Migrate en's records to generic-lens label syntax and a custom prelude

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

`en` reads and writes records one way; the rest of the fleet reads and writes them another.
`en` uses GHC's `OverloadedRecordDot` with `NoFieldSelectors` — you write `config.rateLimit`
to read a field and Haskell's record-update syntax to change one. The fleet uses
`generic-lens` with `OverloadedLabels` — you write `config ^. #rateLimit` to read and
`config & #rateLimit .~ v` to change, and a `<Project>.Prelude` module carries the imports
that would otherwise appear in every file.

Both idioms are coherent. `en`'s is arguably terser for reads. But they are different, and
that difference is what this plan removes: a contributor moving between `en` and any other
service in the fleet currently has to switch record vocabularies at the repository boundary,
and code copied from a fleet reference implementation does not compile in `en` without being
rewritten first.

After this plan, every record access in `en` — about **1,970 field reads and 717 record-update
sites across 80 modules and 30,900 lines** — goes through `#label` and lens operators, and
every module imports `En.Prelude` instead of the same eight import lines. What you can observe:

```bash
grep -rn "OverloadedRecordDot" --include='*.cabal' .    # no output
grep -rln "import En.Prelude" --include='*.hs' . | wc -l # ~80
cabal build all && cabal test all                        # green
```

**This plan changes no behavior whatsoever.** It is the largest diff in its initiative and the
smallest change in what `en` does: every test that passes before must pass after, byte-for-byte
identical wire output, and `docs/api/openapi.json` unchanged. That property is what makes the
plan verifiable at all — with a diff this size, "the tests still pass and the generated
artifact is identical" is the only acceptance criterion that means anything.


## Progress

- [x] (2026-08-25 20:36-0700) Milestone 1 — Established the mechanical recipe on the smallest packages first
      (`en-migrations`, `en-example`, `en-client` — 8 modules, 677 lines between them), and
      write down the recipe that emerges: what a read becomes, what an update becomes, where
      `Data.Generics.Labels ()` goes, and what `En.Prelude` needs to gain.
- [x] (2026-08-25 20:54-0700) Milestone 2 — Migrated `en-server` (7 modules) and
      `en-biscuit` (7 modules). Preserved the server middleware composition and Biscuit
      cryptographic construction order; the isolated Biscuit suite and all eight suites passed,
      and the OpenAPI hash remained byte-identical.
- [ ] Milestone 3 — `en-servant` (13 modules), including its test suite. Highest risk: the
      wire types whose exact JSON bytes are the contract.
- [ ] Milestone 4 — `en-postgres` (9 modules), including the integration test and the lookup
      spike.
- [ ] Milestone 5 — `en-core` (36 modules), the largest package and the one every other
      depends on.
- [ ] Milestone 6 — Remove `OverloadedRecordDot` and `NoFieldSelectors` from every cabal
      stanza, confirm the tree still builds, and write the ADR recording the idiom change.


## Surprises & Discoveries

- Discovery (2026-08-25, baseline): **the previously recorded concurrent Biscuit timeout is
  still the only failing baseline check.** `cabal build all` passed; seven of eight suites
  passed under `cabal test all`, while `en-biscuit-tests` reported `authorization rejected:
  Timeout`. The same suite passed immediately in isolation. `just openapi` was clean and the
  immutable contract baseline is
  `4db31037c3d823d9c0f5e19b968165e2d7364bf9f8a971cb4a7fc2b65ec0a183`.

- Discovery (2026-08-25, Milestone 1): **EP-63 made the packages resolvable but did not make
  the generic-lens orphan visible to every Cabal component.** GHC builds components with only
  their direct `build-depends` exposed, so a module importing `Data.Generics.Labels ()` needs
  `generic-lens` directly even when it already depends on `en-core`. `en-migrations` also had
  no dependency on `en-core`, so its library and CLI could not import `En.Prelude` until that
  internal workspace dependency was declared. The already-resolved cohort did not change;
  these are component visibility edges omitted from the original plan.

- Discovery (2026-08-25, Milestone 1): **not every record can derive `Generic`.**
  `En.Servant.Seam.Env` contains the rank-polymorphic field `runPorts :: forall a. ...`; GHC
  rejects a stock `Generic (Env es)` instance because the constructor has a polymorphic
  argument. Its record-pattern destructuring remains the narrow exception to `#label` reads.
  Ordinary records encountered in the same conversion, including `ActiveSchema` and
  `CheckOutcome`, gained behavior-neutral stock `Generic` derivations.

- Discovery (2026-08-25, Milestone 2): **an executable's labels can require `Generic`
  support in upstream packages before those packages' own migration milestones.** The server
  reads `CacheConfig`, `CacheStats`, `TupleRow`, `ReachabilityGraph`, `Revision`,
  `OrphanReport`, `ConsistencyConfig`, and `OptimizedRevisionConfig`; their owning `en-core`
  and `en-postgres` modules gained stock `Generic` derivations now so the server could use the
  shared idiom. These instances are representation-only and do not alter construction,
  serialization, or runtime behavior.

- Discovery (2026-08-25, while planning): **the work is very unevenly distributed, which
  decides the milestone order.** Counting field-access sites and record-update sites per
  package:

  ```text
  en-core        36 files  12,788 lines   619 reads   284 updates
  en-postgres     9 files   6,285 lines   425 reads   153 updates
  en-servant     13 files   6,131 lines   496 reads   193 updates
  en-biscuit      7 files   2,749 lines   103 reads    56 updates
  en-server       7 files   2,265 lines   120 reads    16 updates
  en-example      3 files     360 lines     2 reads     6 updates
  en-migrations   4 files     215 lines     1 read      8 updates
  en-client       1 file      102 lines     8 reads     1 update
  ```

  Three packages hold 87% of the work and five hold 13%. So the plan starts with the trivial
  ones — not because they matter, but because they are where the recipe gets established
  cheaply, before it is applied 1,500 times.

- Discovery (2026-08-25, while planning): **`en-servant`'s wire types are the risk
  concentration, and they are risky for a reason that has nothing to do with lenses.** `en`'s
  `…Wire` types carry hand-written `ToJSON`/`FromJSON` instances that pin exact JSON bytes,
  because those bytes are the published contract. A mechanical rewrite that touches an
  instance body — even to change how a field is *read* inside it — is a change to code whose
  output is a contract. The golden wire tests in `en-servant/test/Main.hs` are the guard, and
  Milestone 3 must run them and confirm `docs/api/openapi.json` is byte-identical, not merely
  that the package compiles.

(Add further entries as work proceeds.)


## Decision Log

- Decision: Migrate package by package, smallest first, rather than by idiom (all reads, then
  all updates) or all at once.
  Rationale: package boundaries are the only boundaries in this tree that keep the build
  green at intermediate points, because `OverloadedRecordDot` and `OverloadedLabels` are
  enabled per package and can coexist. A migration organized by idiom would leave every
  package half-converted at every checkpoint, so a failure would have no clean revert. Going
  smallest-first means the recipe is established on 677 lines before it is applied to 12,788.
  Date: 2026-08-25

- Decision: Import `Data.Generics.Labels ()` per module, never from `En.Prelude`.
  Rationale: this is the fleet standard's most emphatic rule and the reason is mechanical
  rather than stylistic. `#label`'s meaning comes from an **orphan** `IsLabel` instance.
  Re-exporting it from the prelude forces the generic-lens interpretation of `#label` onto
  every module that imports the prelude — which is, after this plan, every module — and any
  module needing a *different* `IsLabel` instance then breaks in a way that cannot be repaired
  at the use site. The standard names the keiki DSL as the concrete casualty. `en` does not
  use keiki today, which is exactly why the temptation to "just put it in the prelude" is
  strong and why the discipline has to be recorded rather than discovered later.
  Date: 2026-08-25

- Decision: Keep `en`'s hand-written `ToJSON`/`FromJSON` instances and do not take the
  opportunity to switch any of them to generic derivation.
  Rationale: those instances exist to pin exact JSON bytes, which are `en`'s published wire
  contract. Generic derivation would produce *a* correct-looking encoding and silently change
  field ordering, optionality handling, or sum encoding. This plan's whole verifiable property
  is that behavior is unchanged; folding in a codec change would destroy the one acceptance
  criterion that makes a diff this size reviewable. If a codec should be simplified, that is
  its own plan with its own golden-test story.
  Date: 2026-08-25

- Decision: Remove `OverloadedRecordDot` and `NoFieldSelectors` in a final milestone rather
  than package by package.
  Rationale: leaving them enabled during the migration means a partially converted module
  compiles, which is what allows a package to be converted in several commits rather than one
  enormous one. Removing them at the end turns "is anything still using the old idiom?" from a
  grep into a compile error — which is a far better guarantee than a grep, because a grep for
  `x.field` cannot distinguish a record access from a qualified name.
  Date: 2026-08-25

- Decision: Add `generic-lens` to each Cabal component that imports
  `Data.Generics.Labels ()`, and add `en-core` only where a component imports `En.Prelude`
  without already depending on it.
  Rationale: Cabal hides transitive packages, so the per-module import discipline prescribed
  by the catalog necessarily has a matching per-component dependency discipline. These edits
  expose the dependency cohort EP-63 already resolved; they do not introduce a new library or
  version into the project closure.
  Date: 2026-08-25

- Decision: Preserve record-pattern access for records that cannot have a lawful generic-lens
  representation, beginning with the rank-polymorphic `En.Servant.Seam.Env`.
  Rationale: GHC cannot derive `Generic` for a constructor with a polymorphic field, and
  wrapping `runPorts` would break the public `Env` construction surface used by embedded
  consumers. Fleet consistency does not justify a source-level API break in a plan whose
  acceptance criterion is no behavior or interface change. All fields of ordinary `Generic`
  records still use `#label`.
  Date: 2026-08-25

- Decision: Add behavior-neutral `Generic` derivations to cross-package record types when the
  first migrated consumer needs label access, even if the owning package's mechanical sweep is
  scheduled later.
  Rationale: the package milestones order call sites, not type ownership. Deferring the instance
  would force a migrated consumer to retain the old idiom, while deriving it early neither
  changes the value representation nor expands the dependency closure.
  Date: 2026-08-25

(Add further entries as work proceeds.)


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### What this repository is

`en` is a Haskell implementation of relationship-based authorization (ReBAC) in the style of
Google Zanzibar: it stores relationship *tuples* — facts like "user:alice is `viewer` of
space:project-x" — and answers questions about them over HTTP. It is built with `cabal` and
GHC 9.12.4, pinned by `cabal.project`, and work happens inside a nix development shell. It has
eight packages: `en-core` (the engine), `en-postgres` (PostgreSQL interpreters),
`en-servant` (the HTTP API), `en-server` (the executable), `en-client`, `en-biscuit`,
`en-example`, and `en-migrations`.

### Terms used in this plan

**A record field selector** is the function GHC generates from a record field — `name r`.
**`NoFieldSelectors`** turns that generation off, so the field name is usable in construction
and pattern matching but not as a function.

**`OverloadedRecordDot`** is GHC's built-in dot syntax: `r.name` reads a field of `r`. It is
what `en` uses today, and it works through a `HasField` instance GHC provides automatically.

**`OverloadedLabels`** enables the `#name` syntax. `#name` on its own means nothing — its
meaning comes from an `IsLabel` instance, and which instance is in scope decides what it
means.

**`generic-lens`** supplies an `IsLabel` instance, in the module `Data.Generics.Labels`, that
makes `#name` a **lens** over any record deriving `Generic`. That instance is an **orphan** —
defined in neither `IsLabel`'s module nor the record's — which is why *where it is imported*
matters and is the subject of this plan's most important discipline.

**A lens** is a first-class accessor: `r ^. #name` reads, `r & #name .~ v` writes,
`r & #name %~ f` modifies, and lenses compose with `.` so `r ^. #store . #poolSize` reaches a
nested field. Orphan instances propagate **transitively**: a module importing a module that
imports `Data.Generics.Labels` also sees the instance, so the per-module import limits
exposure rather than strictly scoping it.

**A prelude module** is a project-local module re-exporting the imports nearly every file
needs.

### The rules this plan implements

Two documents in the fleet's Haskell pattern catalog govern this work. Resolve either with
`mori path <uri>`; today they land under `patterns/core/` in the working copy at
`/Users/shinzui/Keikaku/bokuno/haskell-jitsurei`.

**`mori://shinzui/haskell-jitsurei/docs/core-record-patterns`** — the record conventions.
Restated, the parts that bind this plan:

- Field access goes through generic lens: `state ^. #status`, not a selector and not dot
  syntax.
- **Always prefer lens operators over Haskell's record update syntax.** `r & #a .~ x` rather
  than `r {a = x}`; `?~` for setting a `Maybe`; `%~` for modifying; `at` and `ix` for map
  fields, where `at` returns a `Maybe` and is for insert/delete while `ix` only updates if the
  key exists and silently does nothing otherwise.
- **Read fields consistently.** Mixing record access and lens access within one function is
  called out by name as the wrong outcome; a function should use one or the other throughout.
- No field prefixes — rely on `DuplicateRecordFields`. Always strict fields (`!`). Always
  explicit deriving strategies.
- **Import `Data.Generics.Labels ()` in each module that uses `#label`**, with a plain
  unqualified import. Keep it out of modules that only *define* domain types, so consumers can
  import the types without inheriting the orphan.

**`mori://shinzui/haskell-jitsurei/docs/core-custom-prelude`** — the prelude. Restated:

- Name it `<Project>.Prelude`, put it in the core library package, collect re-exports with
  `as X`, and export `module X` plus `module Control.Lens` directly.
- Enable `PackageImports` with a **per-file pragma**, never as a `default-extension`: package
  qualification exists only to disambiguate this module's re-exports.
- **Do not** import `Data.Generics.Labels` here. See the Decision Log.
- The prelude is the right home for small, domain-agnostic definitions used across the
  project.

### Where `en` stands today

`grep -rn "generic-lens" --include='*.cabal' .` is empty before
`docs/plans/63-adopt-the-fleet-haskell-core-standards-across-every-en-package.md` lands.
`grep -rln "import En.Prelude" --include='*.hs' .` returns nothing: `En.Prelude` exists at
`en-core/src/En/Prelude.hs`, is listed in `en-core`'s `exposed-modules`, and is imported by no
module at all.

Seven of the eight packages enable `OverloadedRecordDot`; six enable `NoFieldSelectors`. The
per-package volumes are in Surprises & Discoveries.

`en-servant`'s `…Wire` types (`CheckRequestWire`, `LookupPageWire`, and the rest) carry
hand-written `ToJSON`/`FromJSON` instances that fix the exact JSON bytes, and
`en-servant/test/Main.hs` holds golden tests over them plus the OpenAPI document conformance
tests. `docs/api/openapi.json` is a checked-in build product, regenerated by
`cabal run en-openapi` and drift-checked by `just openapi`.

### Relevant Architecture Decision Records

`en`'s ADRs live in `docs/adr/` as ordinary Markdown files with frontmatter `title`, `status`,
`date`, `authors`, `related`, and a body headed `# ADR N — <title>`. `mori.dhall` declares one
OKF bundle, `docs/capabilities`, and **none** at `docs/adr`, so the repository's filesystem
convention is authoritative; no OKF frontmatter belongs on an ADR written here.

All three existing ADRs were read.
[ADR 1](../adr/0001-en-s-schema-is-an-append-only-pg-migrate-component.md) governs schema
migrations and this plan adds none.
[ADR 3](../adr/0003-the-in-memory-store-is-for-tests-and-demos-only.md) governs the in-memory
store's status and this plan changes no interpreter's behavior.
[ADR 2](../adr/0002-crypton-1-1-binds-en-s-dependency-closure-through-a-biscuit-haskell-fork.md)
is the one to know about, but indirectly: it explains why `en`'s dependency closure is tightly
bound, and the `lens` and `generic-lens` additions that closure has to absorb are added by
`docs/plans/63-...`, not here. **This plan adds no dependency** — if you find yourself editing
a `build-depends` list for any reason other than removing something, stop and check whether
the work belongs in EP-63.

This plan **owes a new ADR**, per its parent MasterPlan's Integration Points: that `en`'s
record idiom is generic-lens `#label`, superseding the `OverloadedRecordDot` idiom. It is
durable because it governs every module written afterwards, and because both idioms are
individually coherent — a future contributor needs to know which one won and why, or they will
reasonably reintroduce the other. Write it in Milestone 6.

### How this plan relates to the others in its initiative

This is a child of
`docs/masterplans/11-bring-en-into-conformance-with-the-haskell-jitsurei-pattern-catalog.md`,
and it is sequenced **last in the whole initiative**.

It **hard-depends on**
`docs/plans/63-adopt-the-fleet-haskell-core-standards-across-every-en-package.md`, which adds
`lens` and `generic-lens` to `en-core`, fills out `En.Prelude`, puts `OverloadedLabels` in
every package's stanza, and leaves behind a probe test proving `#label` resolves through a
per-module `Data.Generics.Labels ()` import. Without EP-63 nothing here compiles.

It **soft-depends on every other plan in the initiative** —
`docs/plans/61-...`, `64-...`, `65-...`, `66-...`, and `67-...` — purely for sequencing.
Nothing here needs their artifacts. It is last because it conflicts with everything: a sweep
running concurrently with targeted work produces merge conflicts on files neither change is
really about, and running it after means it converts the code those plans add rather than
leaving the tree in two idioms and requiring a second pass.

**If you are implementing this plan and an earlier plan is still in flight, stop and wait.**
That is the entire reason for the ordering, and starting early costs far more than it saves.

### Build and test commands

Work from `/Users/shinzui/Keikaku/bokuno/en` inside the nix development shell.

```bash
cd /Users/shinzui/Keikaku/bokuno/en
cabal build all
cabal test all
just openapi        # must be clean before you start and after every milestone
```


## Plan of Work

Package by package, smallest first. Each milestone leaves the tree building and every test
passing, because `OverloadedRecordDot` stays enabled until Milestone 6 and the two idioms
coexist.

### Milestone 1 — The recipe, established cheaply

Scope: `en-migrations` (4 modules, 215 lines), `en-example` (3 modules, 360 lines), and
`en-client` (1 module, 102 lines). Eleven field reads and fifteen record updates between them
— which is the point. This milestone is about producing a recipe, not about converting code
that matters.

The four transformations:

```haskell
-- read
config.rateLimit                    ==>  config ^. #rateLimit
config.store.poolSize               ==>  config ^. #store . #poolSize

-- update
r {name = x}                        ==>  r & #name .~ x
r {name = x, count = n}             ==>  r & #name .~ x & #count .~ n
r {slot = Just v}                   ==>  r & #slot ?~ v
r {count = count r + 1}             ==>  r & #count %~ (+ 1)

-- map fields
m {entries = Map.insert k v (entries m)}  ==>  m & #entries . at k ?~ v
```

Each converted module gains `import En.Prelude` and, if it uses `#label`, a plain
`import Data.Generics.Labels ()`. Modules that only *define* types and never manipulate them
should **not** get the labels import — keeping the orphan out of definition modules is what
lets a future consumer import `en`'s types without inheriting it.

As you go, note what `En.Prelude` is missing. EP-63 gave it `Generic`, the common `Control.
Monad` and `Data.Maybe` helpers, `Proxy`, `MonadIO`, `NonEmpty`, `Text`, `UTCTime`, and all of
`Control.Lens`. If a re-export would remove the same import line from a dozen modules, add it
— but **do not** add the aeson vocabulary: EP-63 deliberately left it out because `en`'s wire
types have hand-written codecs and pulling generic derivation's vocabulary into every module
invites exactly the change this plan's Decision Log forbids.

Then **write the recipe down**, in this section, as the thing Milestones 2 through 5 follow.
Include the transformations that turned out to be non-obvious — nested updates, `Maybe`
fields, map fields, and any place where the mechanical rewrite produced something worse than
the original and you chose differently.

The recipe established by the first three packages is:

- Import `En.Prelude` when its re-exports replace vocabulary the module uses. Import
  `Data.Generics.Labels ()` separately in every module containing `#label`; add
  `generic-lens` to that module's Cabal component because Cabal does not expose the transitive
  package through `en-core`. Do not add either import to a definition-only leaf merely to hit
  an import count: an unused prelude import is compiler-confirmed boilerplate.
- A field read becomes `value ^. #field`; a nested read composes labels as
  `value ^. #outer . #inner`. A read of a function-valued field is parenthesized before
  application: `(client ^. #check) request`.
- A true record update becomes a left-to-right lens chain: `value & #field .~ replacement`,
  `?~` when supplying the contents of `Just`, and `%~` when computing from the field's old
  value. Record *construction* remains constructor syntax; it is not an update and lens
  construction would be less total and less readable.
- Use `at key ?~ value` for map insertion, `at key .~ Nothing` for deletion, and `ix key %~ f`
  only when deliberately modifying an existing key. These operators differ on an absent key,
  so a mechanical `Map.insert` rewrite must preserve the original behavior.
- Add `deriving stock (Generic, ...)` to an ordinary record before using its labels. When GHC
  rejects `Generic` because a field is rank-polymorphic, preserve record-pattern access for
  that record and document the exception; do not redesign a public type during this
  behavior-preserving sweep.
- Resolve names newly exported by `Control.Lens` by hiding them from `En.Prelude`, as in
  `import En.Prelude hiding (List)`, rather than qualifying an operator or weakening the
  prelude. Keep hand-written codecs and middleware order untouched.

Acceptance: `cabal build all && cabal test all` passes; `just openapi` clean; the three
packages contain no `.field` record access (verified by removing `OverloadedRecordDot` from
just those three stanzas, building, and putting it back if anything else breaks); the recipe
is written down.

### Milestone 2 — `en-server` and `en-biscuit`

Scope: `en-server` (7 modules, 2,265 lines, 120 reads, 16 updates) and `en-biscuit`
(7 modules, 2,749 lines, 103 reads, 56 updates).

Mechanical application of Milestone 1's recipe. Two things to watch.

`en-server/app/Main.hs` is the most contended file in the whole initiative — three earlier
plans touch its middleware stack. Convert it, but do not restructure it: a record-access
rewrite that also reorders middleware makes the diff unreviewable and would silently undo
`docs/plans/65-...`'s carefully ordered composition.

`en-biscuit` deals with cryptographic token construction. Its record updates build values
whose exact field content is security-relevant; a lens rewrite is behavior-preserving, but run
its test suite specifically and read the diff for any place where an update's *order* of field
assignments changed, since `&`-chained lens sets apply left to right and a chain that reads a
field it also sets is not the same as a record update that reads the original throughout.

Acceptance: `cabal build all && cabal test all` passes; `just openapi` clean; both packages'
suites green.

### Milestone 3 — `en-servant`

Scope: 13 modules, 6,131 lines, 496 reads, 193 updates, plus the test suite. **The highest-risk
milestone**, and not because of its size.

`en`'s `…Wire` types carry hand-written `ToJSON`/`FromJSON` instances that pin the exact JSON
bytes of the published contract. Converting a field read *inside* one of those instances is a
change to code whose output is a contract. It is still behavior-preserving — a lens read
returns the same value a dot read did — but this is the place where a slip is expensive and
invisible, because a wrong encoding compiles.

So the guard is not the compiler here; it is the golden tests and the generated document.
Run `cabal test all` after **every module**, not every package, and run `just openapi` at the
end of the milestone expecting **zero** drift. `docs/api/openapi.json` must be byte-identical:
this plan changes no type, no field name, and no codec, so any diff at all in that file means
something changed that should not have.

Resist the standing temptation while you are in these modules: do not replace a hand-written
codec with generic derivation, however mechanical it looks. The Decision Log records why.

Acceptance: `cabal build all && cabal test all` passes with the golden wire tests green;
`git diff --stat docs/api/openapi.json` shows **no change**; the error-model table in
`en-servant/test/Main.hs` still pins the same `(status, code, retryable)` triples.

### Milestone 4 — `en-postgres`

Scope: 9 modules, 6,285 lines, 425 reads, 153 updates, including
`en-postgres/integration-test/Main.hs` and `en-postgres/lookup-spike/Main.hs`.

Mechanical, with one wrinkle worth knowing: four modules in this package use GHC 9.12's
`MultilineStrings` for embedded SQL, declared with per-file pragmas rather than in the cabal
stanza. Nothing about this migration touches those literals, but a mechanical rewrite tool run
over the file must not reformat inside them.

The integration test needs a database. Run it —
`just process-up && just run-migrations` first — rather than relying on `cabal test all`
skipping it, because the interpreters this package holds are where a behavior change would
actually hurt.

Acceptance: `cabal build all && cabal test all` passes; the integration test passes against a
real database; `just openapi` clean.

### Milestone 5 — `en-core`

Scope: 36 modules, 12,788 lines, 619 reads, 284 updates. The largest package and the one every
other depends on, which is why it is last: by now the recipe has been applied to 44 modules
and whatever was going to be surprising about it has been.

Two things specific to this package. It holds the schema DSL and its Template Haskell
quasi-quoter (`En.Schema.TH`), where `#label` and TH splices can interact in ways ordinary
modules do not — convert it carefully and run `en-core`'s suite immediately after. And it holds
`En.Prelude` itself, which must **not** gain a `Data.Generics.Labels` import no matter how
convenient it looks by this point; the Decision Log records why, and by Milestone 5 the
temptation is at its strongest because 44 modules have each written that import line.

`en-core`'s test suite includes the three fixture modules under `en-core/test/fixtures/` that
are *expected* to fail compilation, as negative tests of the schema builder. Converting them
must preserve the specific failure each one tests — check the expected error messages still
match, rather than only that the suite is green.

Acceptance: `cabal build all && cabal test all` passes; `just openapi` clean;
`grep -rln "import En.Prelude" --include='*.hs' . | wc -l` is close to 80;
`grep -n "Data.Generics.Labels" en-core/src/En/Prelude.hs` is empty.

### Milestone 6 — Turn off the old idiom, and record the decision

Scope: all eight `.cabal` files, and one new file in `docs/adr/`.

Remove `OverloadedRecordDot` and `NoFieldSelectors` from every `common shared` stanza, then
build. **This is the real completeness check**, and it is why the removal was deferred to the
end: a grep for `x.field` cannot distinguish a record access from a module-qualified name or a
composed function, but the compiler can. Anything still using the old idiom is now an error
naming the exact site.

Expect a handful of stragglers. Fix them, and note in Surprises & Discoveries how many the
compiler found that the greps had missed — that number is the honest measure of how well the
mechanical passes worked, and it is worth knowing before anyone plans a similar sweep again.

`NoFieldSelectors` deserves one moment of thought rather than reflexive removal: without it,
GHC generates selector functions for every field, which can newly shadow or conflict with
same-named top-level functions in modules that previously had no selectors. If removing it
causes ambiguity errors, keeping it is defensible — record the choice here rather than fighting
the compiler for symmetry's sake.

Then write the ADR: `en`'s record idiom is generic-lens `#label` with lens operators and the
`En.Prelude` custom prelude, superseding `OverloadedRecordDot`/`NoFieldSelectors`. Record why
(fleet consistency; code copied from fleet references now compiles), what it cost (the numbers
in Surprises & Discoveries), and — most importantly — the `Data.Generics.Labels` discipline,
because that is the part a future contributor will otherwise undo for convenience. Follow the
existing convention: `docs/adr/000N-<slug>.md`, frontmatter `title`, `status: accepted`,
`date`, `authors: [shinzui]`, `related:` naming this plan and its MasterPlan; body headed
`# ADR N — <title>` with `## Status`, `## Context`, `## Decision`, `## Consequences`. No OKF
frontmatter.

Acceptance: `grep -rn "OverloadedRecordDot" --include='*.cabal' .` is empty;
`cabal build all && cabal test all` passes; `just openapi` clean; the ADR exists and this
plan's Decision Log names it.


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/en` inside the nix development shell. Baseline, and
capture it — with a diff this size you will want a number to compare against:

```bash
cd /Users/shinzui/Keikaku/bokuno/en
cabal build all
cabal test all 2>&1 | tail -20        # record the passing test counts
just openapi                          # must be clean before you start
sha256sum docs/api/openapi.json       # record this; it must not change
```

Confirm EP-63 has landed, since nothing here works without it:

```bash
grep -n "generic-lens" en-core/en-core.cabal          # must be present
grep -n "PackageImports" en-core/src/En/Prelude.hs    # must be line 1
grep -c "" en-core/src/En/Prelude.hs                  # must be much more than 9 lines
```

Per-package inventory, to know what you are walking into:

```bash
for p in en-migrations en-example en-client en-server en-biscuit en-servant en-postgres en-core; do
  printf '%-14s reads=%-5s updates=%s\n' "$p" \
    "$(grep -rohE "\b[a-z][A-Za-z0-9_']*\.[a-z][A-Za-z0-9_']*" --include='*.hs' "$p" | wc -l)" \
    "$(grep -rn '{ *[a-z][A-Za-z0-9_'"'"']* *=' --include='*.hs' "$p" | wc -l)"
done
```

Those greps are approximate — the read count includes module-qualified names, which is why
Milestone 6's compiler check is the real completeness test rather than a grep returning zero.

Convert a module, build, test, commit. Small commits: one package per several commits is
right, and a single commit spanning two packages is not.

```text
refactor(en-server): read and update records through generic-lens labels

Mechanical conversion to #label reads and lens operators; import En.Prelude
and Data.Generics.Labels per module. No behavior change: the middleware
composition, the wire shapes, and the generated OpenAPI document are all
byte-identical.

MasterPlan: docs/masterplans/11-bring-en-into-conformance-with-the-haskell-jitsurei-pattern-catalog.md
ExecPlan: docs/plans/68-migrate-en-s-records-to-generic-lens-label-syntax-and-a-custom-prelude.md
Intention: intention_01m0xaavwqeznrgzs3j67m0q21
```

After every milestone, re-check the invariant that makes this plan verifiable:

```bash
cabal test all
sha256sum docs/api/openapi.json       # must equal the baseline
```


## Validation and Acceptance

This plan changes no behavior, so acceptance is entirely about proving that nothing moved
while 30,000 lines were rewritten. Four checks, in increasing order of strength.

**The test suite is unchanged, not merely green.** Compare the passing test counts against the
baseline captured in Concrete Steps. A green suite with fewer tests than before means a test
stopped being run — which a large refactor can cause by, for example, breaking a test module's
export list in a way that silently drops a group.

**The published contract is byte-identical.**

```bash
sha256sum docs/api/openapi.json
git diff --stat docs/api/openapi.json
```

Expected: the same hash as the baseline, and an empty diff. This plan changes no type, no field
name, and no codec, so **any** change here is a defect. This is the single most valuable check
in the plan, because it covers every wire type at once and cannot be satisfied by accident.

**The wire bytes are unchanged.** `en-servant/test/Main.hs`'s golden tests pin exact JSON for
the `…Wire` types, and its error-model table pins `(status, code, retryable)` for every engine
error. Both must pass without their expectations being edited. If you find yourself updating a
golden expectation during this plan, stop: the golden test is telling you the refactor changed
behavior, and it is right.

**The old idiom is gone, proved by the compiler.**

```bash
grep -rn "OverloadedRecordDot\|NoFieldSelectors" --include='*.cabal' .
cabal build all
```

Expected: no output from the grep, and a clean build. A grep for `x.field` is *not* an
acceptable substitute — it cannot distinguish a record access from a qualified name — which is
why Milestone 6 removes the extension and lets GHC find the stragglers.

**The prelude discipline held.**

```bash
grep -n "Data.Generics.Labels" en-core/src/En/Prelude.hs      # expected: no output
grep -rn "PackageImports" --include='*.cabal' .               # expected: no output
grep -rln "import En.Prelude" --include='*.hs' . | wc -l      # expected: ~80
```

The first is the one that matters. If `Data.Generics.Labels` has migrated into the prelude at
any point during this plan, the orphan `IsLabel` instance is now forced on every module in
`en`, and the plan has traded a style inconsistency for a real constraint on `en`'s future
consumers.

**A live end-to-end check.** Beyond the test suites, start the server and run one real request,
because a refactor of this size deserves one observation that does not come from a test
harness:

```bash
just process-up && just run-migrations && just start-server &
just test-server        # or `just hurl`, once docs/plans/66-... has landed
```

Expected: the same output as before this plan.


## Idempotence and Recovery

Every step is an ordinary source edit. Nothing touches the database, adds a migration, or
changes persistent state. `cabal build all` and `cabal test all` are pure functions of the
tree, and `cabal run en-openapi` regenerates the document deterministically.

The safety property that makes this plan tractable is that **both idioms compile
simultaneously** until Milestone 6. `OverloadedRecordDot` and `OverloadedLabels` are
independent mechanisms, so a half-converted module, a half-converted package, and a
half-converted tree all build. That is why the migration can proceed in small commits and why
any commit is a safe stopping point.

Commit per module or per small group of modules, never per package. `git checkout -- <file>`
discards one file's conversion; `git reset --hard HEAD` returns to the last commit.

Four recovery notes.

**If a converted module will not compile and the fix is not obvious**, revert that one file and
move on. There is no ordering constraint between modules within a package, so a single
stubborn module can be left for last without blocking anything. Record it in Surprises &
Discoveries — a module that resists mechanical conversion usually has something interesting in
it.

**If `docs/api/openapi.json` drifts**, stop immediately and find out why before continuing.
This plan cannot legitimately change it. The likeliest cause is that a codec was touched — a
field's optionality, a sum's encoding, a record's field order — which means behavior changed,
which means the refactor was not mechanical. Revert to the last commit where the hash matched.

**If a golden wire test fails**, the same applies with more force. Do not update the
expectation. The golden test is the contract; the refactor is what must change.

**If Milestone 6's extension removal produces a wall of errors**, that is the check working,
not a disaster — each error names a site the earlier passes missed. If it produces *ambiguity*
errors rather than "not in scope" errors, that is `NoFieldSelectors`'s removal generating
selectors that shadow existing names; keeping `NoFieldSelectors` is a legitimate answer, and
the Decision Log is where to record it.


## Interfaces and Dependencies

### Libraries

**No new external library enters the project closure.** `lens` and `generic-lens` arrive in
`docs/plans/63-adopt-the-fleet-haskell-core-standards-across-every-en-package.md`, along with
`OverloadedLabels` in every package's stanza and the filled-out `En.Prelude`. This plan does
add direct `generic-lens` `build-depends` edges to each Cabal component that imports
`Data.Generics.Labels ()`, because Cabal hides transitive packages, and adds the internal
`en-core` edge where a component newly imports `En.Prelude`. These expose the versions already
resolved by EP-63 rather than selecting a new dependency cohort.

The 2026-08-25 verification found `generic-lens` 2.3.0.0 as Hackage's newest normal
release and the matching upstream tag `2.3.0.0`; `dist-newstyle/cache/plan.json` resolves
`generic-lens` 2.3.0.0 and `lens` 5.3.6. The existing `>=2.2 && <2.4` direct bound therefore
admits the authoritative current release without widening EP-63's tested major-version cohort.

Two extensions are **removed**, in Milestone 6: `OverloadedRecordDot` from seven packages and
`NoFieldSelectors` from six — the latter subject to the ambiguity caveat above.

Because nothing is added, this is one of only two child plans in its initiative with no
dependency cohort to prove against
[ADR 2](../adr/0002-crypton-1-1-binds-en-s-dependency-closure-through-a-biscuit-haskell-fork.md).

### What must be true at the end

Every `.hs` module in `en` that manipulates a record:

```haskell
import Data.Generics.Labels ()   -- plain import; enables #label HERE only
import En.Prelude                -- Text, Generic, MonadIO, ..., and all of Control.Lens
```

reads fields with `^.` and `#label`, updates them with `.~`, `?~`, `%~`, `at`, and `ix`, and
does not mix lens access with record access inside one function.

`en-core/src/En/Prelude.hs` keeps its per-file `{-# LANGUAGE PackageImports #-}` pragma, keeps
exporting `module X` and `module Control.Lens`, and **never** imports `Data.Generics.Labels`.

Modules that only *define* domain types and never manipulate them do not import
`Data.Generics.Labels`, so a consumer can import `en`'s types without inheriting the orphan
instance.

### What must not change

**Anything observable.** No wire type's JSON bytes, no route, no status code, no error code, no
handler behavior, no SQL. `docs/api/openapi.json` byte-identical. The golden wire tests and the
error-model table passing with their expectations untouched.

**Hand-written `ToJSON`/`FromJSON` instances stay hand-written.** The Decision Log records why;
the golden tests enforce it.

**`En.Servant.Seam`'s exports** (`Env`, `AppEffects`, `MintEnv`, `ActiveSchema`, `EnServer`,
`runEngine`, `runEngineEither`) and **`En.Servant.API`'s exports** of `app` and its re-export
umbrella — `nagare` and `kikan-en` import those modules directly. This plan changes how `en`
reads its own records, not what it exports; if an export list changes, something has gone
wrong.

**The middleware composition in `en-server/app/Main.hs`.**
`docs/plans/65-instrument-en-with-opentelemetry-and-a-conformant-production-request-log.md`
establishes an ordering that is load-bearing — the tracing middleware outermost, the Servant
route naming directly inside it, the request logger inside that — and a record-access refactor
must not disturb it.
