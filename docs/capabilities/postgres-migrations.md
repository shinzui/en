---
title: "PostgreSQL schema as an append-only pg-migrate component"
type: Capability
description: "en's database schema as a pg-migrate migration component whose SQL is embedded at compile time from an ordered manifest, applied by an en-migrate CLI with per-file checksums, advisory-lock safety, and machine-readable exit codes."
generated:
  by: anthropic/claude-opus-5
  at: "2026-08-24T14:35:00Z"
capabilityId: CAP-14
provider: mori://shinzui/en
status: shipped
stability: experimental
since: unreleased
packages:
  - en-migrations
interface:
  - En.Migrations
  - en-migrate
evidence:
  - kind: test
    resource: en-migrations/test/Main.hs
    proves: "A database-free suite that forces enMigrations and enMigrationPlan, so an invalid component name, a .sql file the embedder accepted but the definition layer rejects, or a plan-level ordering fault fails in CI before anything touches a database."
  - kind: module
    resource: en-migrations/src/En/Migrations.hs
    proves: "enMigrationPlan and enMigrations expose the single embedded component; the module documents the four tables it defines and the append-only rule."
  - kind: module
    resource: en-migrations/app/Main.hs
    proves: "The en-migrate CLI's plan/list/check/new commands work without a database, text or JSON output is selectable, and distinct exit codes separate success, verification failure (2), bad input (64), and runtime failure (1)."
  - kind: test
    resource: en-postgres/integration-test/Main.hs
    proves: "The integration database is migrated with the real plan before every store scenario runs."
  - kind: guide
    resource: docs/adr/0001-en-s-schema-is-an-append-only-pg-migrate-component.md
    proves: "Why the schema is append-only, what the ledger checksums, and the two operational traps: the manifest check only runs when cabal invokes GHC, and a database with real data is repaired by history import rather than a drop."
---

# PostgreSQL schema as an append-only pg-migrate component

`en-migrations` owns the schema [the PostgreSQL store](postgres-tuple-store.md) expects. The SQL
lives in `en-migrations/migrations`, is listed in an ordered `manifest`, and is **embedded into
the binary at compile time** — nothing reads a migrations directory at run time, and an unlisted
`.sql` file fails the build.

Four tables: `relation_tuple` (the authorization facts, with `created_xid`/`deleted_xid` for
MVCC soft-delete), `en_transaction` (one row per write, anchoring
[consistency tokens](consistency-tokens-and-snapshot-reads.md)), `en_datastore_metadata` (this
database's persistent identity), and `en_gc_horizon` (the GC high-water mark).

## Usage

```bash
cabal run en-migrate -- status     # what this database has applied
cabal run en-migrate -- up         # apply what is outstanding
cabal run en-migrate -- verify     # re-check applied files against their checksums
just make-migration name=0002-whatever
```

`plan`, `list`, `check`, and `new` never touch a database, so an absent `DATABASE_URL` does not
stop them.

## Limits

- **Append-only, and the checksum is why.** The ledger records each applied file's exact bytes.
  Never edit an applied migration and never hand-correct the ledger — the forward path for a
  mistake is a new migration, or `verify` starts failing.
- The manifest check only runs when cabal actually invokes GHC. A cached build will not catch a
  newly added but unlisted `.sql` file.
- A database holding real data is repaired by history import, not by a drop and recreate.
