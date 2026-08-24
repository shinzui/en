---
title: "en's schema is an append-only pg-migrate component"
status: accepted
date: 2026-08-24
authors: [shinzui]
related:
  - docs/plans/62-replace-codd-with-pg-migrate-as-en-s-migration-system.md
  - mori://shinzui/pg-migrate
---

# ADR 1 — en's schema is an append-only pg-migrate component

## Status

Accepted, 2026-08-24. Implemented by
[ExecPlan 62](../plans/62-replace-codd-with-pg-migrate-as-en-s-migration-system.md).

## Context

en's PostgreSQL schema had no migration tool. The repository claimed its SQL was
"codd-managed", but no codd binary was in the development shell, no codd configuration
existed anywhere in the tree, and no database held a codd ledger. What actually applied the
schema was a shell recipe, `run-migrations` in `Justfile`, that probed the live database for
each migration's side effect — "does table `relation_tuple` exist yet?", "does index
`relation_tuple_live_unique` still mention `caveat_name`?" — and shelled out to `psql` when
the probe said no.

Three things follow from that design, and all three bit:

  * Every new migration required inventing a new probe, and a subtly wrong probe silently
    skipped or silently re-ran a migration.
  * Nothing recorded what a given database had received, so nothing could detect that an
    already-applied SQL file had later been edited.
  * The integration test suite could not reuse any of it, so it carried a second,
    hand-maintained copy of the schema in a Haskell string literal. That copy had already
    drifted: it omitted `en_datastore_metadata` entirely, so the tests proved en worked
    against a schema no real database had.

## Decision

en's schema is owned by [pg-migrate](https://hackage.haskell.org/package/pg-migrate)
(`mori://shinzui/pg-migrate`), as a single component named `en`.

  * The SQL lives in `en-migrations/migrations/`, listed one file per line, in execution
    order, in a plain-text `manifest`.
  * The bytes are embedded into the binary at compile time by Template Haskell, so nothing
    reads a migrations directory at run time. A `.sql` file in that directory that is not
    listed in the manifest **fails the build** rather than being silently skipped.
  * `en-migrations/app/Main.hs` builds the `en-migrate` executable, which is the only
    supported way to apply migrations.
  * `en-server` neither applies nor verifies migrations at startup. Migrations are an
    explicit deployment or administrative job. `en-server` only names that job when it finds
    a schema it cannot use.
  * The `en-postgres` integration suite migrates its ephemeral database with the same plan
    `en-migrate up` applies, so there is exactly one description of en's schema in the
    repository.

**Migrations are append-only.** pg-migrate's ledger, in the database's `pgmigrate` schema,
records a SHA-256 checksum over each applied migration's exact bytes. Editing an
already-applied file changes that checksum and makes `en-migrate verify` fail. The forward
path for a mistake is always a new appended migration — never an edit, and never a hand
correction of the ledger.

The component name `en` and each migration's name are equally durable: a migration's
identity is `component/name` (`en/0001-en-bootstrap`), and that string is what the ledger
stores. Renaming either orphans every applied row.

## Consequences

Adding a migration is `just make-migration 0002-name "description"`, which writes the file
and appends it to the manifest atomically — there is no second step to forget, and no probe
to invent. `just run-migrations` (`en-migrate up`) is idempotent by construction: it consults
the ledger and applies only what is pending, and two processes running it at once are safe
because the second waits on a PostgreSQL advisory lock. `en-migrate verify` exits 2 when the
database disagrees with the declared plan, which is the pre-deploy check the probes could
never offer.

The cost is that a mistake in an applied migration cannot be tidied away. That is the point:
it is the guarantee en had no way to offer before.

Two operational notes worth keeping:

  * The manifest-membership check runs when GHC compiles
    `En.Migrations.Internal.Definition`. When no Haskell source has changed, `cabal` reports
    "Up to date" and never invokes GHC, so a stray `.sql` file can sit unnoticed locally
    until a clean build. The `RecompilePlugin` pragma on that module governs GHC's
    recompilation decision, not cabal's; CI gets the check for free from a cold build.
  * A database with real data must never be "fixed" by dropping and re-migrating. The
    forward-only path for one is pg-migrate's history import
    (`mori://shinzui/pg-migrate`, `docs/operations/history-import.md`). en had no users and
    no deployed database when this was adopted, which is the only reason its six predecessor
    migrations could be squashed into one bootstrap file.
