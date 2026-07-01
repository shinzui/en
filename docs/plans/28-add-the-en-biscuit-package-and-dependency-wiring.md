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

- [ ] M1: Confirm the Mori-registered Biscuit dependency source and package names.
- [ ] M2: Add `en-biscuit/en-biscuit.cabal`, a placeholder source module, and the package to `cabal.project`.
- [ ] M3: Add a smoke test target proving the package builds and can import `Auth.Biscuit`.
- [ ] M4: Update repository metadata or package listing if the project uses Mori observation for new packages.


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


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


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
