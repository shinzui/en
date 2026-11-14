---
title: "Writes are validated against the active schema"
status: accepted
date: 2026-11-13
authors: [shinzui]
related:
  - docs/plans/78-refuse-writes-of-tuples-the-active-schema-cannot-interpret.md
  - docs/improvement-requests/serve-several-isolated-tenants-from-one-en-server.md
  - docs/adr/0003-the-in-memory-store-is-for-tests-and-demos-only.md
  - docs/adr/0009-tenancy-is-a-property-of-the-standalone-host.md
---

# ADR 12 — Writes are validated against the active schema

## Status

Accepted, 2026-11-13. Implemented by
[ExecPlan 78](../plans/78-refuse-writes-of-tuples-the-active-schema-cannot-interpret.md).

## Context

Until this decision En stored any tuple it was asked to write. A misspelt relation, an object
type the schema does not define, a subject the relation does not accept, a write to a
permission, or an undefined caveat all answered `200` with a consistency token, and the grant
then never took effect: no check, lookup or expand can reach a tuple the schema cannot
interpret. The mistake surfaced only later, as an *orphan* in the report of
`en-server check-schema` or of a `SIGHUP` schema reload.

The orphan rule already existed: `En.SchemaCheck.checkTupleAgainstSchema` decides whether a
schema can interpret a tuple, and it was used only to scan a whole store against a candidate
schema. The tenancy work found the gap when IR-2 AC-2 assumed a write of another tenant's type
would be refused, which En had never done in any mode.

## Decision

- A write is refused, whole and before anything is stored, when any tuple it would write is an
  orphan under the schema the request is served under. The rule is `checkTupleAgainstSchema`
  itself, so the set a write refuses and the set `check-schema` and reload report are one set.
  Over HTTP the answer is the existing `400 schema_violation`, naming the first offending tuple;
  `en-server import` refuses the line, naming the file line, before its batch is written.
- Deletes are never checked, nor is the delete half of a mixed write. Deleting an orphan is the
  remedy for a schema change that stranded tuples, and refusing it would leave no way to remove
  them. Preconditions are filters, not grants, and are not checked.
- The check is a pure function in `en-core` (`validateTupleWrites`) with a thin checked write
  operation beside the unchecked ones (`applyValidatedTupleWrites` beside `applyTupleWrites`).
  It is not part of the `TupleStore` effect or its interpreters: the store is deliberately
  schema-agnostic (it stamps a schema hash, it does not interpret a schema), and both
  interpreters (PostgreSQL and the in-memory store of
  [ADR 3](0003-the-in-memory-store-is-for-tests-and-demos-only.md)) would otherwise need the
  same logic.
- The request's schema snapshot, `En.Servant.Seam.ActiveSchema`, carries the `ValidSchema` its
  `graph` was compiled from. The compiled graph cannot answer the question (it has no entry for
  a type with no relations, such as `object user {}`), and holding both in one atomically
  swapped value means a reload cannot validate a write under one schema and evaluate it under
  another. In tenant mode the snapshot is the writer's tenant's
  ([ADR 9](0009-tenancy-is-a-property-of-the-standalone-host.md)).
- There is no opt-out. A client writing tuples its schema cannot interpret already has grants
  that never apply; there is no correct behaviour to preserve.

## Consequences

- Orphans can now arise only from schema changes (including a forced reload), which is exactly
  the case `check-schema` and reload's orphan report exist for.
- An export taken from a store that holds orphans does not import into a server running the
  same schema; the operator runs `check-schema` and deletes or migrates the orphans first.
- Every host that builds an `ActiveSchema` itself must set `validSchema` (as `en-example` does).
  Embedded hosts calling `applyTupleWrites` directly stay unchecked unless they switch to
  `applyValidatedTupleWrites`.
- The check is pure and runs once per written tuple against in-memory maps; it adds no database
  round trip, and a refused write never acquires a connection.
