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

Storage and wire milestones of ExecPlan 69 are implemented. Integrating bounded
pruning into maintenance and proving the final consumer evidence path remain
required before the complete capability is ready.
No existing `en1` token format changes, and a generation is neither a signature nor
permission that can be cached and reused without reauthorization.
