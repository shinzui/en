---
title: "Expand a permission into its subject tree"
type: Capability
description: "Return the tree of relations and usersets that grant a permission on an object, so a reviewer can see why access holds rather than only that it holds."
generated:
  by: anthropic/claude-opus-5
  at: "2026-08-24T14:35:00Z"
capabilityId: CAP-10
provider: mori://shinzui/en
status: shipped
stability: experimental
since: unreleased
packages:
  - en-core
interface:
  - En.Expand
  - POST /v1/expand
requires:
  - CAP-5
evidence:
  - kind: test
    resource: en-servant/test/Main.hs
    proves: The expand request and ExpandTreeWire response round-trip and match the published OpenAPI schema.
  - kind: guide
    resource: docs/user/queries-and-writes.md
    proves: "The Expand section: what the tree contains and when to prefer it over lookup-subjects."
---

# Expand a permission into its subject tree

`expand` answers the audit question. Where [check](check-decisions-with-caveats.md) returns a
verdict and [lookup-subjects](lookup-subjects.md) returns a flat set, `expand` returns the
structure: the union, intersection, and exclusion nodes and the usersets underneath them that
combine to grant a permission on an object.

## Usage

```http
POST /v1/expand
{"object": "space:eng", "permission": "view"}
```

## Limits

- The tree is bounded by the [evaluation budget](evaluation-budget.md)'s `maxDepth` and
  `resultCap`; a very wide group is truncated per page rather than streamed whole.
- Expand is a review and debugging surface. It is not the enforcement path — enforce with
  [check](check-decisions-with-caveats.md) or [batch check](batch-check.md).
