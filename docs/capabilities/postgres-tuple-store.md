---
title: "PostgreSQL tuple store"
type: Capability
description: "A hasql-backed implementation of the tuple store and consistency store effects, with xid8 soft-delete, filtered and paged reads, and a connection-pooled session runner."
generated:
  by: anthropic/claude-opus-5
  at: "2026-08-24T14:35:00Z"
capabilityId: CAP-13
provider: mori://shinzui/en
status: shipped
stability: experimental
since: unreleased
packages:
  - en-postgres
interface:
  - En.Postgres.TupleStore
  - En.Postgres.Revision
  - En.Postgres.Database
  - En.Postgres.Datastore
requires:
  - CAP-11
  - CAP-14
evidence:
  - kind: test
    resource: en-postgres/integration-test/Main.hs
    proves: The full store scenario suite against an ephemeral PostgreSQL — tuple store operations, probes, touch semantics, decode strictness, relationship filters, read-all-tuples, and maintenance batches.
  - kind: benchmark
    resource: en-postgres/bench/Main.hs
    proves: The consistency benchmark group measures token encode/decode and pg_snapshot comparison, the per-request costs every store read pays.
  - kind: guide
    resource: docs/user/service-and-operations.md
    proves: "The PostgreSQL store section: connection settings, pooling, and operational constraints."
---

# PostgreSQL tuple store

`en-postgres` implements en-core's `TupleStore` and `ConsistencyStore` effects over
[hasql](https://hackage.haskell.org/package/hasql), plus the `pg_snapshot` machinery behind
[consistency tokens](consistency-tokens-and-snapshot-reads.md). It is the only store
implementation this repository ships and proves.

Deletes are logical: a row carries an `xid8` tombstone rather than being removed, which is what
lets a token-pinned read see the graph as it was.

## Usage

```haskell
pool <- Pool.acquire poolSettings
runStoreIO pool consistencyConfig (check graph MinimizeLatency ctx subject perm object)
```

## Limits

- The integration suite requires a real PostgreSQL (it starts an ephemeral one); it is not part
  of the pure test suite.
- Datastore identity lives in a metadata row. Restoring a dump into a datastore with a different
  id invalidates outstanding tokens — this is called out as an operational warning, not a
  recoverable error.
- Tombstoned rows accumulate until [background maintenance](standalone-authorization-server.md)
  reclaims them.
