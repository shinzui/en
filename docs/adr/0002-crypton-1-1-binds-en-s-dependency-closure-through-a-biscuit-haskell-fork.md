---
title: "crypton 1.1 binds en's dependency closure through a biscuit-haskell fork"
status: accepted
date: 2026-08-24
authors: [shinzui]
related:
  - docs/plans/62-replace-codd-with-pg-migrate-as-en-s-migration-system.md
  - mori://shinzui/pg-migrate
---

# ADR 2 — crypton 1.1 binds en's dependency closure through a biscuit-haskell fork

## Status

Accepted, 2026-08-24. Implemented by
[ExecPlan 62](../plans/62-replace-codd-with-pg-migrate-as-en-s-migration-system.md).

## Context

Cabal resolves exactly one version of a package for the whole project. Two of en's
dependencies disagreed about `crypton`:

  * `pg-migrate`, which computes migration checksums, requires `crypton >= 1.1 && < 1.2`.
  * `biscuit-haskell`, reached through `en-biscuit`, is pinned in `cabal.project` as a
    `source-repository-package` on the fork `shinzui/biscuit-haskell-project`. That fork
    exists because the Hackage release of `biscuit-haskell-0.4.0.0` caps
    `template-haskell < 2.22`, which excludes the 2.23 that ships with GHC 9.12.4. It
    capped `crypton ^>= 1.0`.

The solver refused outright:

```text
[__1] rejecting: crypton-1.1.4 (conflict: biscuit-haskell => crypton^>=1.0)
```

Widening the bound is **not** sufficient, and this is the part that is easy to get wrong.
crypton 1.1 replaced the deprecated `memory` package with its maintained fork `ram`. With
crypton 1.1 in the plan and `biscuit-haskell` still depending on `memory`, the solver
succeeds and the *compile* then fails, because `Ed25519.PublicKey` no longer carries a
`ByteArrayAccess` instance from the package `biscuit-haskell` is asking:

```text
src/Auth/Biscuit/Crypto.hs:101:15: error: [GHC-39999]
    • No instance for ‘memory-0.18.0:Data.ByteArray.Types.ByteArrayAccess
                         Ed25519.PublicKey’
```

`allow-newer: biscuit-haskell:crypton` therefore looks like a fix and is not one.

## Decision

Fix the bound in the package that has the wrong dependency. The fork
`shinzui/biscuit-haskell-project`, commit `61f2b31063db6bc7fe0fb885dd2da957634a525b`, makes
both halves of the change together in
`biscuit-haskell/biscuit/biscuit-haskell.cabal`:

```diff
-    crypton              ^>= 1.0,
-    memory               >= 0.15 && < 0.19,
+    crypton              >= 1.0 && < 1.2,
+    ram                  >= 0.20 && < 0.23,
```

No Haskell source change is needed: `ram` exposes the same `Data.ByteArray` module with the
same `convert`, and `src/Auth/Biscuit/Crypto.hs` is the only module in the package that
imports it.

Because the widened bound admits both crypton 1.0 and 1.1, en's `cabal.project` also
constrains `crypton >= 1.1`, so the solver cannot quietly settle on 1.0.6 and reintroduce
the conflict.

## Consequences

en's closure now resolves `crypton-1.1.4`, `ram-0.22.1`, and `tls-2.4.3`, with `memory`
absent entirely. Anything en depends on must be compatible with crypton 1.1; a dependency
that caps `crypton < 1.1` cannot enter the build plan without the same treatment.

The general rule this encodes: **prefer `ram` over `memory`** — `memory` is deprecated, and
in this ecosystem a `memory` dependency is a latent conflict with anything on crypton 1.1.

The check that matters after touching this is `cabal test en-biscuit`. It is the only thing
in the repository that exercises Ed25519 signing and verification, so it is what proves the
`memory`-to-`ram` swap is semantically neutral rather than merely type-correct. If
`cabal build` behaves inconsistently after a change here, `cabal clean` first: the swap
changes unit-id hashes across a large part of the closure, and a stale store entry produces
confusing instance errors.

This is the second reason en carries a `biscuit-haskell` fork rather than the Hackage
release; the first is the GHC 9.12 `template-haskell` bound. Both are recorded in the
comment above the pin in `cabal.project`. The fork can be dropped only when an upstream
release carries both widenings.

## Amendment — 2026-08-25

The reasoning above stands unchanged; the vehicle for it does not. Two corrections.

**The patch moved out of the corpus mirror and into a real fork.** It was originally
committed onto `shinzui/biscuit-haskell-project`, which is the corpus *mirror* of upstream
(`mori://eclipse-biscuit/biscuit-haskell`) and carries `biscuit-haskell` as a vendored
subtree. Editing the subtree in place broke the rule the corpus exists to uphold — that
reading it tells you what upstream does — and left the patch on a subtree merge in a mirror
repo, where it could not be offered upstream. It now lives on the `fix/crypton-1.1-ram`
branch of `mori://shinzui/biscuit-haskell`, a GitHub fork of
`eclipse-biscuit/biscuit-haskell`, as a single commit on top of upstream `main`. The mirror
is pure upstream again and names the fork in its `mori.dhall`.

Rebasing onto upstream `main` also picked up four commits the old pin predated, including a
negative-index guard in `get()` and a fix making `runAuthorizerWithLimits` actually honour
`maxTime`. The latter matters here: `en-biscuit` verifies tokens whose blocks an attenuating
caller controls, and before that fix the authorizer's time limit did not bound them.

**The bound in the diff above was wrong.** `crypton >= 1.0 && < 1.2` paired with `ram` is
unsound in the same way the ADR warns about, just in the other direction: crypton 1.0.6
still gets `ByteArrayAccess` from `memory`, so that range admits a plan that solves and then
fails to compile on the missing instance. The range only happened to work because en also
constrains `crypton >= 1.1`. The fork now says:

```diff
-    crypton              ^>= 1.0,
-    memory               >= 0.15 && < 0.19,
+    crypton              ^>= 1.1,
+    ram                  >= 0.20.1 && < 0.23,
```

which is the only range that is true of this source. The `crypton >= 1.1` constraint in
`cabal.project` is consequently redundant, and is kept only as a guard against the pin being
dropped.

**On dropping the fork.** Upstream `main` has carried the GHC 9.12 half
(`template-haskell < 2.24`, `megaparsec < 9.8`, `crypton` rather than `cryptonite`) for some
time but has never released it — Hackage still serves `biscuit-haskell-0.4.0.0` at revision
0 from 2024-07-31 — and the open "Release 0.5.0.0" PR does not touch the crypton bound. So
the fork cannot be dropped on that release either; it needs a release carrying the crypton
1.1 change as well.
