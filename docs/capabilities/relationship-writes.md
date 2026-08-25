---
title: "Write and delete relationship tuples, with preconditions"
type: Capability
description: "Write, touch, and delete relationship tuples — individually, in batches, by filter, or as an atomic mixed write guarded by must-exist / must-not-exist preconditions — and get back the consistency token for the write."
generated:
  by: anthropic/claude-opus-5
  at: "2026-08-24T14:35:00Z"
capabilityId: CAP-11
provider: mori://shinzui/en
status: shipped
stability: experimental
since: unreleased
packages:
  - en-core
interface:
  - En.Effect.TupleStore
  - En.Tuple
  - POST /v1/relationships
  - POST /v1/relationships/delete
  - POST /v1/relationships/delete-by-filter
  - POST /v1/relationships/query
requires:
  - CAP-12
evidence:
  - kind: test
    resource: en-postgres/integration-test/Main.hs
    proves: runBatchWriteScenario, runPreconditionScenario, runTouchSemanticsScenario, runWriteRaceScenario, and runBatchTouchRaceScenario exercise batched writes, precondition failure, touch idempotence, and concurrent write races against a real PostgreSQL.
  - kind: test
    resource: en-core/test/Main.hs
    proves: Relationship filter validation and matching, widenTupleFilter agreement, store paging, and the relationship store operations over the effect interface.
  - kind: guide
    resource: docs/user/queries-and-writes.md
    proves: Write semantics, preconditions, and atomic mixed writes.
---

# Write and delete relationship tuples

Tuples are the facts the engine reads. `En.Effect.TupleStore` is the effect interface every
store implements — see [the PostgreSQL store](postgres-tuple-store.md) — and covers writing,
touching, deleting by identity, deleting by filter, counting, and paging reads.

A write returns the [consistency token](consistency-tokens-and-snapshot-reads.md) for the
revision it created, which is what makes read-your-own-writes possible without polling.

## Usage

```http
POST /v1/relationships
{"writes": [{"object": "space:eng", "relation": "viewer", "subject": "user:alice"}],
 "preconditions": [{"mustNotExist": {"object": "space:eng", "relation": "owner", "subject": "user:bob"}}]}
```

## Limits

- Preconditions are evaluated inside the write's transaction; a failed precondition aborts the
  whole mixed write rather than applying it partially.
- Deletes are soft (`xid8` tombstones) so historical snapshots stay readable. Rows are reclaimed
  by [background maintenance](standalone-authorization-server.md), and the GC window bounds how
  long a token stays resolvable.
- Tuples are not validated against the active schema on write. Drift is reported separately by
  the [tuple/schema drift report](tuple-schema-drift-report.md).
