---
title: "Grant generations follow committed owner writes"
status: accepted
date: 2026-09-08
authors: [shinzui]
related:
  - docs/plans/69-expose-stable-grant-generations-at-authorization-snapshots.md
  - mori://shinzui/koyomi/plans/5-expose-authorized-calendar-http-apis-and-typed-clients
---

# ADR 8 — Grant generations follow committed owner writes

## Context

A schema fingerprint does not detect relation-tuple changes. A PostgreSQL snapshot
also changes when unrelated transactions commit, so using it as a stable grant
generation can invalidate a consumer's authorization during its own cursor write.
Consumers need owner metadata that changes with grant transactions and can be
resolved at the exact snapshot of a decision.

## Decision

Append a generation migration without changing the installed bootstrap migration.
Stamp each committed `en_transaction` anchor using a deferred constraint trigger.
An incremented singleton counter row remains locked through commit, making the
history order follow successful commit order even when XIDs were allocated in the
opposite order. Failed transactions roll back their counter/history changes with
their grant changes. Repeated anchor updates in one transaction stamp once.
Successful no-op grant-write requests may conservatively advance the generation.

Store the generation with its explicit write XID and resolve it with
`pg_visible_in_snapshot`, just as tuple visibility is reconstructed. Initialization
creates generation zero at the migration XID; older snapshots have no generation.
Never fabricate a value for missing history. The public renderer is `gg1_` plus
the nonnegative decimal generation; datastore and schema binding remain necessary.

For retention, preserve the greatest generation below the durably advanced owner
horizon, plus every row at or above that horizon. Only older rows below the horizon
may be deleted, in bounded batches using `SKIP LOCKED`. This floor remains visible
to every valid snapshot. XID order and generation order are not interchangeable.

## Consequences

This adds a short serialization point at grant commit, not at the beginning of
mutation evaluation. Database writes outside the owner anchor path do not advance
the generation. Direct administrative tuple changes that bypass owner mutation
APIs are outside this contract. Missing/corrupt generation state must fail a write
or metadata read rather than silently weakening the evidence.

Single-check responses now carry optional `grantGeneration` metadata. The live
PostgreSQL host resolves the exact `checkedAt` token under the captured schema,
reads its visible generation, and validates retention again afterward. Missing
history fails unavailable. Embedded hosts without this capability explicitly
return `Nothing`; the JSON field is omitted, preserving legacy wire decoding.
Adding `Env.grantGenerationOperation` and `CheckResponseWire.grantGeneration`
requires source updates for embedded hosts and response constructors.

Storage and wire milestones of ExecPlan 69 are implemented. The scheduled owner
worker now prunes generations after advancing the durable horizon and completing
tuple/transaction cleanup. Each statement respects the existing row limit; the
worker reports `generationsPruned` and includes these statements in its batch
count. Locked victims can remain for the next pass. PostgreSQL tests prove
concurrent pruning skips locked rows, rollback restores deletions, retry drains
eligible rows and the retained floor survives. The actual scheduled-service gate
reclaims 96 obsolete generations with matching logs and verifies fresh decisions
against the retained floor. The final consumer gate now also proves real calendar
HTTP pagination through the En-backed evidence port: cursor writes preserve
generations, revocation invalidates saved pages, and downgrade/regrant cannot
revive old detailed cursors. ExecPlan 69 is complete. Production identity and
directory integration remain outside this owner capability.
No existing `en1` token format changes, and a generation is neither a signature nor
permission that can be cached and reused without reauthorization.

## Performance and retained-history lookup — 2026-10-13

[ExecPlan 70](../plans/70-characterize-and-bound-grant-generation-overhead.md)
measured the former descending visibility scan growing linearly with historical
distance: at one million rows it filtered about 500k/1m entries for midpoint/floor
snapshots. Preserve commit order and retention, and replace that scan with one
SQL statement using a bounded fast path and recursive numeric bisection.

Visible generations form a prefix because generation N+1 cannot take the
singleton lock until N's transaction finishes. The search tries at most 33 newest
rows, then seeks a successor at each overflow-safe midpoint. A missing key reduces
the upper interval; it is not an invisible generation. Each iteration halves the
interval or better. Nonnegative Int64 keys cap the search at 64 iterations even
with sparse retained history. Endpoint seeks plus one seek per iteration bound
logical search work; B-tree traversal and PostgreSQL's chosen physical plan have
their own costs. Tiny-table scans are acceptable. The performance spike verifies
index plans on larger fixtures, and operators must keep statistics current.
The lazy scalar fallback avoids executing recursive work on fresh/distance-32
reads. Empty/no-visible history returns absence and fails unavailable at the
public metadata boundary.

Decode the token minted by the check, read its generation, then validate that
same metadata once. This uses two database sessions and preserves the post-read
retention defense. Run both actions under one engine invocation and one captured
active schema. Token faults discovered only in metadata become retryable 503;
initial client-token faults retain 400. Embedded hosts still explicitly omit the
optional generation field.

The singleton is acquired by the deferred trigger and remains held through
commit. Coordinated real transactions verify this lock lifetime, inverted XID
allocation, xip snapshots and rollback. The critical section contains only the
counter update and history insert after the existing once-per-XID check; retain
this deliberate serialization point. No migration bytes or persistent schema
artifacts change for the inline lookup.

The million-row reference fixture occupied about 89 bytes per generation,
including both indexes. Pruning bounds deleted rows and acquired locks, not
buffers or wall time, and normal vacuum is still needed. Test-host capacity and
latency are documented in the deployment guide together with the disposable
cluster's non-durable settings. Operators must measure their own durability,
network and hardware class rather than treat those numbers as service guarantees.
