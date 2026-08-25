---
title: "Consistency tokens and snapshot reads"
type: Capability
description: "Pin a read to a PostgreSQL snapshot with an en1. consistency token that encodes datastore identity, schema hash, and revision, and choose per request between minimum latency, at-least-this-snapshot, and fully consistent."
generated:
  by: anthropic/claude-opus-5
  at: "2026-08-24T14:35:00Z"
capabilityId: CAP-12
provider: mori://shinzui/en
status: shipped
stability: experimental
since: unreleased
packages:
  - en-core
  - en-postgres
interface:
  - En.Revision
  - En.Effect.ConsistencyStore
  - En.Postgres.Revision
evidence:
  - kind: test
    resource: en-postgres/test/Main.hs
    proves: pg_snapshot parses and renders canonically; transaction visibility for old, in-flight, and future xids; RBefore/RAfter/RConcurrent snapshot comparison; token codec round-trip; and rejection of a malformed snapshot in a token.
  - kind: test
    resource: en-postgres/integration-test/Main.hs
    proves: runSnapshotRepeatabilityScenario, runHorizonMonotonicityScenario, and runConsistencyFetchCountScenario prove repeatable snapshot reads, a monotonic GC horizon, and the number of consistency fetches a request performs.
  - kind: guide
    resource: docs/user/production-deployment-and-performance.md
    proves: The consistency-modes section, and why the GC window must stay much longer than any request.
---

# Consistency tokens and snapshot reads

Every read reports the revision it was decided at as an opaque `en1.` token. A token carries
three things: the datastore id, the schema hash, and the `pg_snapshot` revision. Presenting it
back pins a later read to that snapshot.

The three modes are:

- `MinimizeLatency` — read at whatever snapshot is cheapest.
- `AtExactSnapshot token` — read at the snapshot the token pins (read-your-own-writes).
- fully consistent — read at the current head.

Because the schema hash is inside the token, a token minted under one model is refused under
another — which is what makes [schema reload](schema-reload-and-preflight.md) safe to warn about
rather than silently wrong.

## Usage

```haskell
token <- writeTuples …                       -- token for the write
check … (AtExactSnapshot token) … subject permission object
```

## Limits

- **The GC window bounds token lifetime.** Once the horizon passes a token's snapshot the token
  stops resolving. Keep the window much longer than any request that might carry one.
- Datastore identity is part of the token. A restore into a differently-identified datastore
  invalidates every token in flight — see the backup/restore warning in
  `docs/user/service-and-operations.md`.
- Snapshot comparison is a partial order: two snapshots can be `RConcurrent`, and neither is
  "later".
