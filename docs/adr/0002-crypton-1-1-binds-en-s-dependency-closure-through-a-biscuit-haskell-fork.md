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
