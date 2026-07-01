---
id: 28
slug: add-the-en-biscuit-package-and-dependency-wiring
title: "Add the en-biscuit package and dependency wiring"
kind: exec-plan
created_at: 2026-07-01T04:50:38Z
master_plan: "docs/masterplans/5-add-biscuit-decision-token-support.md"
intention: intention_01kwe136p1expbzvj08bqwtz08
---

# Add the en-biscuit package and dependency wiring

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan creates the optional `en-biscuit` package that later plans use to
mint and verify Biscuit authorization grants. The immediate user-visible result
is small but important: a developer can run `cabal build en-biscuit` and see a
new package compile without changing `en-core`, `en-servant`, `en-server`, or
existing clients.

`en-biscuit` is deliberately separate from `en-core`. `en-core` stays the pure
relationship-authorization engine. `en-biscuit` is the token integration layer
over the Mori-registered `eclipse-biscuit/biscuit-haskell` dependency.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: Confirm the Mori-registered Biscuit dependency source and package names. (2026-06-30) — `mori registry search biscuit` resolves `eclipse-biscuit/biscuit-haskell` with packages `biscuit-haskell`, `biscuit-servant`, `biscuit-wai`; the library exposes `Auth.Biscuit`. Discovered the Hackage/GHC-9.12 conflict (see Surprises).
- [x] M2: Add `en-biscuit/en-biscuit.cabal`, a placeholder source module, and the package to `cabal.project`. (2026-06-30) — created `en-biscuit/en-biscuit.cabal`, `en-biscuit/src/En/Biscuit.hs`, added `en-biscuit` to `cabal.project` packages, and pinned the GHC-9.12-compatible Biscuit source via a `source-repository-package` git stanza.
- [x] M3: Add a smoke test target proving the package builds and can import `Auth.Biscuit`. (2026-06-30) — `en-biscuit/test/Main.hs` mints, serializes, re-parses, and authorizes a Biscuit; `cabal test en-biscuit` prints `en-biscuit smoke test PASS`.
- [x] M4: Update repository metadata or package listing if the project uses Mori observation for new packages. (2026-06-30) — added the `en-biscuit` package entry and the `eclipse-biscuit/biscuit-haskell` external dependency to `mori.dhall`; `mori show --full` validates and lists `en-biscuit`.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery during planning: `mori registry search biscuit` resolves
  `eclipse-biscuit/biscuit-haskell` at
  `/Users/shinzui/Keikaku/hub/haskell/biscuit-haskell-project`, with packages
  `biscuit-haskell`, `biscuit-servant`, and `biscuit-wai`.
  Date: 2026-07-01

- Discovery during planning: `mori registry docs eclipse-biscuit/biscuit-haskell`
  reports no curated docs, so implementation must inspect the local source.
  Useful files include
  `/Users/shinzui/Keikaku/hub/haskell/biscuit-haskell-project/biscuit-haskell/biscuit/src/Auth/Biscuit.hs`,
  `/Users/shinzui/Keikaku/hub/haskell/biscuit-haskell-project/biscuit-haskell/biscuit/src/Auth/Biscuit/Example.hs`,
  and
  `/Users/shinzui/Keikaku/hub/haskell/biscuit-haskell-project/biscuit-haskell/biscuit-servant/src/Auth/Biscuit/Servant.hs`.
  Date: 2026-07-01

- Discovery during implementation (2026-06-30): **the Hackage release of
  `biscuit-haskell-0.4.0.0` does not build under this project's GHC 9.12.4.** Its
  `build-depends` caps `template-haskell < 2.22`, but GHC 9.12.4 ships
  `template-haskell 2.23`, so `cabal build en-biscuit` fails to resolve with:
  `rejecting: template-haskell-2.23.0.0/installed (conflict: biscuit-haskell => template-haskell>=2.16 && <2.22)`.
  The Mori-registered source (`eclipse-biscuit/biscuit-haskell`, HEAD
  `aef4272f0d44eec75c79aa6c2dd00c4200401829` on `origin/master`, GitHub
  `shinzui/biscuit-haskell-project`) is the **same version 0.4.0.0** but has
  widened bounds (`template-haskell < 2.24`, `megaparsec < 9.8`) that build under
  GHC 9.12. This is the "Cabal/Nix wiring needed to make the local Mori
  registered dependency build under this repository's GHC" the MasterPlan
  anticipated. Resolution: a `source-repository-package` git stanza in
  `cabal.project` pinning that commit, `subdir: biscuit-haskell/biscuit`.
  Evidence: after adding the stanza, `cabal build en-biscuit` clones the repo and
  resolves/builds `biscuit-haskell-0.4.0.0` successfully.
  Date: 2026-06-30

- Discovery during implementation (2026-06-30): `Auth.Biscuit.serializeB64`
  returns a strict `ByteString`, which is **not** a `Foldable`, so `null` from
  the `Prelude` does not apply to it. The smoke test uses
  `Data.ByteString.null` instead. Minor, but recorded because later plans that
  handle serialized tokens will hit the same distinction.
  Date: 2026-06-30

- Repo layout note (2026-06-30): `en-example` is present in `cabal.project` but
  was **not** listed in `mori.dhall`; `mori.dhall` is a curated subset, not an
  exhaustive package list. `en-biscuit` was still added to `mori.dhall` per M4
  because it introduces a new external dependency worth registering.
  Date: 2026-06-30


## Decision Log

Record every decision made while working on the plan.

- Decision: Create a new package named `en-biscuit`.
  Rationale: Biscuit is a token-format integration. Keeping it in a separate
  package preserves `en-core`'s role as a transport- and token-agnostic engine.
  Date: 2026-07-01

- Decision: Start with `biscuit-haskell` only, and add `biscuit-servant` or
  `biscuit-wai` in later plans only when integration helpers require them.
  Rationale: The core grant, minting, and verification code can be pure and
  should not force Servant or WAI dependencies until a module uses those APIs.
  Date: 2026-07-01

- Decision (2026-06-30): Wire the GHC-9.12-compatible Biscuit source through a
  `source-repository-package` git stanza in `cabal.project` (pinned to commit
  `aef4272f0d44eec75c79aa6c2dd00c4200401829`, `subdir: biscuit-haskell/biscuit`)
  rather than a local absolute `packages:` path or the Hackage release.
  Rationale: the Hackage `biscuit-haskell-0.4.0.0` cannot build under GHC 9.12.4
  (template-haskell bound conflict — see Surprises). A local absolute path
  (`/Users/shinzui/Keikaku/hub/...`) would be machine-specific and break for any
  other contributor or CI; a pinned git commit is reproducible across machines
  and needs no user-home checkout. Only the `biscuit-haskell` subdir is pulled
  in; `biscuit-servant`/`biscuit-wai` remain deferred to ExecPlan 31.
  Date: 2026-06-30

- Decision (2026-06-30): Register `en-biscuit` in `mori.dhall` and add
  `eclipse-biscuit/biscuit-haskell` to the project's external `dependencies`
  list. Rationale: M4 asks to update package metadata; the new package pulls in
  a new external dependency, so recording both keeps `mori`'s dependency graph
  accurate for future reverse-dependency lookups.
  Date: 2026-06-30


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

Outcome (2026-06-30): The optional `en-biscuit` package exists and builds. A
developer can run `cabal build en-biscuit` and `cabal test en-biscuit` and see a
new package compile and a smoke test pass, without changing `en-core`,
`en-servant`, `en-server`, or existing clients. All acceptance criteria hold:

- `cabal build en-biscuit` succeeds.
- `cabal test en-biscuit` succeeds (`en-biscuit smoke test PASS`).
- `cabal build all` succeeds.
- `en-core/en-core.cabal` has no `biscuit-haskell`/`biscuit-servant`/`biscuit-wai`
  dependency (`grep -i biscuit en-core/en-core.cabal` → none).
- `cabal.project` lists `en-biscuit`.
- `mori show --full` validates and lists the `en-biscuit` package.

Files created: `en-biscuit/en-biscuit.cabal`, `en-biscuit/src/En/Biscuit.hs`
(placeholder top-level module, currently exports nothing), `en-biscuit/test/Main.hs`.
Files modified: `cabal.project` (package entry + Biscuit `source-repository-package`),
`mori.dhall` (package + external dependency).

Gap vs. original plan: the plan assumed `biscuit-haskell` would resolve straight
from Hackage; it does not under GHC 9.12.4, so a pinned git source was required
(see Decision Log / Surprises). This is the intended place to absorb that wiring
and keeps later plans (EP-29..EP-32) free of dependency-resolution concerns. The
`En.Biscuit` module is an intentionally empty placeholder; EP-29 fills it with
the grant vocabulary and begins re-exporting real submodules.


## Context and Orientation

The repository currently has packages `en-core`, `en-migrations`,
`en-postgres`, `en-servant`, `en-server`, `en-client`, and `en-example` listed
in `cabal.project`. `en-core/en-core.cabal` exposes the core authorization
types and algorithms. `en-servant/en-servant.cabal` exposes the HTTP API and
authorization helper. There is no `en-biscuit` directory yet.

The dependency lookup required by this repository's `AGENTS.md` has already
identified the local Biscuit source through Mori. Before implementation, run
the same commands again so the implementer works from current registry state:

```bash
mori registry search biscuit
mori registry show eclipse-biscuit/biscuit-haskell --full
mori registry docs eclipse-biscuit/biscuit-haskell
```

The `biscuit-haskell` package exposes `Auth.Biscuit`. The source exports
`newSecret`, `toPublic`, `SecretKey`, `PublicKey`, `mkBiscuit`, `addBlock`,
`parseB64`, `parseWith`, `authorizeBiscuit`, the `[block| ... |]` and
`[authorizer| ... |]` quasiquoters, and key parsing/serialization helpers.
Those names are in
`/Users/shinzui/Keikaku/hub/haskell/biscuit-haskell-project/biscuit-haskell/biscuit/src/Auth/Biscuit.hs`.


## Plan of Work

Milestone 1 confirms dependency availability. Re-run the Mori commands above,
then inspect the Biscuit cabal files under the registered local path. Record the
exact package names that Cabal should depend on.

Milestone 2 adds the package. Create `en-biscuit/en-biscuit.cabal` following the
style of `en-client/en-client.cabal` and `en-servant/en-servant.cabal`. Add
`en-biscuit` to the `packages:` list in `cabal.project`. Create
`en-biscuit/src/En/Biscuit.hs` as a small top-level module that re-exports
future modules but initially only compiles.

Milestone 3 adds a smoke test. Create `en-biscuit/test/Main.hs` and a
`test-suite en-biscuit-tests` stanza. The test should import `Auth.Biscuit`,
parse or generate a key with library APIs, and assert a trivial fact so Cabal
proves the dependency is wired correctly.

Milestone 4 updates project metadata if this repository tracks packages through
Mori. Run `mori show --full` before and after implementation. If the new
package is missing from `mori.dhall`, update it in the smallest style that
matches the existing file and validate with `mori show --full`.


## Concrete Steps

Work from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/en
mori show --full
mori registry search biscuit
mori registry show eclipse-biscuit/biscuit-haskell --full
```

Create the package files, then build:

```bash
cabal build en-biscuit
cabal test en-biscuit
```

Expected result:

```text
Build profile: -w ghc-9.12.4 -O1
...
Build completed
...
Test suite en-biscuit-tests: PASS
```


## Validation and Acceptance

Acceptance requires all of these:

- `cabal build en-biscuit` succeeds.
- `cabal test en-biscuit` succeeds.
- `cabal build all` still succeeds or any unrelated pre-existing failure is
  documented in this plan's Surprises & Discoveries section with the exact
  command output.
- `en-core/en-core.cabal` has no dependency on `biscuit-haskell`,
  `biscuit-servant`, or `biscuit-wai`.
- `cabal.project` lists `en-biscuit` as a package.


## Idempotence and Recovery

Adding a Cabal package is additive. Re-running the build and test commands is
safe. If Cabal cannot resolve `biscuit-haskell`, first re-check the Mori entry
and the local dependency source path. Do not search `/` or `/nix/store`; use
Mori to locate dependency source and inspect only the registered path.

If the package name or exposed modules differ from the plan, update this plan's
Decision Log before changing code so later child plans consume the corrected
names.


## Interfaces and Dependencies

New files at the end of this plan:

- `en-biscuit/en-biscuit.cabal`
- `en-biscuit/src/En/Biscuit.hs`
- `en-biscuit/test/Main.hs`

Required package dependencies for the initial package:

- `base`
- `en-core`
- `biscuit-haskell`
- `bytestring`
- `text`
- `time`

`biscuit-servant` and `biscuit-wai` are deliberately deferred to
`docs/plans/31-verify-and-attenuate-en-biscuit-grants-locally.md` unless a
smoke test proves they are needed earlier.
