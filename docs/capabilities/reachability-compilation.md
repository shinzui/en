---
title: "Reachability compilation and schema hashing"
type: Capability
description: "Compile a validated schema into a reachability graph that indexes which subject shapes can reach which relations, and carries an insertion-order-independent schema hash."
generated:
  by: anthropic/claude-opus-5
  at: "2026-08-24T14:35:00Z"
capabilityId: CAP-5
provider: mori://shinzui/en
status: shipped
stability: experimental
since: unreleased
packages:
  - en-core
interface:
  - En.Reachability
  - En.Schema
requires:
  - CAP-1
evidence:
  - kind: test
    resource: en-core/test/Main.hs
    proves: compileSchema round-trips identically to compile . validateSchema; the graph carries the schema hash; the hash is stable across map insertion order; direct, userset, recursive-parent, and conditional entrypoints are each asserted present.
  - kind: test
    resource: en-core/test/Main.hs
    proves: Unproductive rewrite cycles, empty Union/Intersection branches, unknown computed relations, unknown caveats, and wildcard-only arrows are each rejected by validateSchema.
  - kind: guide
    resource: docs/user/modeling.md
    proves: The validation rules a model has to satisfy, and how rewrite choices affect reachability.
---

# Reachability compilation and schema hashing

`validateSchema` turns a raw [schema](schema-parametric-model.md) into a `ValidSchema` —
evidence that the model passed every structural rule — and `compile` turns that into a
`ReachabilityGraph`. Every read operation takes the graph, not the schema.

The graph carries a `SchemaHash` that is independent of map insertion order. That hash is what
makes a [consistency token](consistency-tokens-and-snapshot-reads.md) refuse to be replayed
against a different model.

## Usage

```haskell
valid <- either throwIO pure (validateSchema mySchema)
let graph = compile valid
```

## Limits

- Validation is structural. It proves the rewrite rules are well-formed and productive; it does
  not prove the model expresses the policy you intended.
- `maxDepth` in the [evaluation budget](evaluation-budget.md) bounds traversal at query time,
  not at compile time — a legal schema can still exceed the budget on a deep instance graph.
