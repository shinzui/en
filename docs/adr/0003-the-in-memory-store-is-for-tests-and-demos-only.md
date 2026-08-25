---
title: "the in-memory store is for tests and demos only"
status: accepted
date: 2026-08-25
authors: [shinzui]
related:
  - docs/plans/58-add-a-mutable-in-memory-tuple-store-for-tests-and-demos.md
---

# ADR 3 — the in-memory store is for tests and demos only

## Status

Accepted, 2026-08-25. Implemented by
[ExecPlan 58](../plans/58-add-a-mutable-in-memory-tuple-store-for-tests-and-demos.md).

## Context

en's authorization algorithms depend on `TupleStore` and `ConsistencyStore` effects. Before
ExecPlan 58, production PostgreSQL was the only interpreter with historical revisions. The
Kikan conformance fixture in `En.Conformance.Kikan` mutates a pure tuple list, but every read
sees that list's current value and its maintenance operations are placeholders. It cannot
prove exact-snapshot behavior around a deletion, stable cursors across mutation, token
ownership, or garbage-collection expiry.

Tests, embedded examples, and databaseless demonstrations need those behaviors without
starting PostgreSQL. They also need the fake to implement the whole current store boundary:
a partial interpreter that ignores preconditions, touch identity, filter deletes, or the
changelog can make an integration pass even though production would behave differently.

A process-local store cannot replace PostgreSQL for real authorization data. Its contents
vanish on restart, two application instances have independent worlds, and a monotonically
increasing counter is only a single-process model of PostgreSQL's partially ordered
transaction snapshots.

## Decision

`en-core` exports `En.Store.InMemory` as a complete, historical interpreter for tests and
demos.

  * `InMemoryWorld` is opaque. Callers share the handle but cannot mutate its `IORef` or
    violate revision, row-id, and garbage-collection invariants.
  * Every successful mutating request is one atomic state transition and one revision,
    including a successful no-op. A failed precondition changes nothing.
  * Writes mirror production touch semantics, precondition order, deletes-before-writes,
    relationship filters, and net changelog behavior.
  * Revisions and tokens include a per-world identity. Tokens from another in-memory world
    and cursors from another store fail through typed `EnError`s.
  * Historical rows remain readable at exact snapshots until reaping raises the retained
    horizon past them.
  * `en-server` has no configuration path selecting this interpreter. Production deployments
    use `en-postgres`.

`En.Conformance.Kikan` remains a separate pure fixture interpreter. It is not rewritten or
aliased to the mutable store because its ability to run under `runPureEff` and its simple
current-list semantics are useful to the conformance suite.

## Consequences

An embedded test can now allocate one world, run `writeTuples`, and observe ordinary
`check`/`lookup` results change without a database. `en-example` uses that public path, so the
runnable demonstration exercises mutation rather than passing a prebuilt tuple list to a
fixture.

Adding a constructor to `TupleStore` or changing production-visible write, filter, changelog,
cursor, token, or reaping semantics now requires reviewing three interpreters:
`En.Postgres.TupleStore`, `En.Store.InMemory`, and `En.Conformance.Kikan`. The mutable store
should mirror production semantics where a single-process model can do so honestly; Kikan may
remain deliberately simpler when its fixture contract says so.

The in-memory store is convenient enough to tempt production use, so its module documentation
and user guide state the non-production boundary explicitly. Durability and cross-instance
agreement are not optional optimizations for authorization data; no flag should weaken that
boundary.
