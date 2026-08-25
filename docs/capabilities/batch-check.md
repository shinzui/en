---
title: "Batch check many subject/permission/object triples in one call"
type: Capability
description: "Submit many check pairs in one request and get one decision per pair, in order, so a GraphQL field-capability map or a candidate-filtering pass costs one round trip instead of N."
generated:
  by: anthropic/claude-opus-5
  at: "2026-08-24T14:35:00Z"
capabilityId: CAP-7
provider: mori://shinzui/en
status: shipped
stability: experimental
since: unreleased
packages:
  - en-core
  - en-servant
interface:
  - En.Check
  - POST /v1/batch-check
requires:
  - CAP-6
evidence:
  - kind: test
    resource: en-servant/test/Main.hs
    proves: The batch-check wire contract, including the batch-too-large fault, round-trips and matches its OpenAPI schema.
  - kind: guide
    resource: docs/user/graphql-integration.md
    proves: Using one batch call for field-level permissions and list-resolver candidate filtering instead of per-field fan-out.
---

# Batch check many triples in one call

`batchCheck` takes a list of `BatchPair`s and returns one decision per pair **in request
order**, sharing the snapshot and the in-request [caches](in-process-caching.md) across the
whole batch. Over HTTP it is `POST /v1/batch-check`.

This is the primitive that keeps a GraphQL gateway from issuing one
[check](check-decisions-with-caveats.md) per field per row.

## Usage

```http
POST /v1/batch-check
{"pairs": [{"subject": "user:alice", "permission": "view", "object": "space:eng"}, …]}
```

## Limits

- The server caps batch size and rejects an oversized batch with a `batchTooLarge` fault rather
  than truncating it.
- A batch is not a transaction. It is many reads at one snapshot, which is what makes the
  answers mutually consistent — it does not make them atomic with any write.
- Ordering is positional; there is no per-pair correlation id in the response.
