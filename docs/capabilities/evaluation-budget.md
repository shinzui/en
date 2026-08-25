---
title: "Operator-configurable evaluation budget"
type: Capability
description: "One record bounding recursion depth, storage read batch size, and returned result size for check, lookup, and expand, configurable by the operator rather than hard-coded per engine."
generated:
  by: anthropic/claude-opus-5
  at: "2026-08-24T14:35:00Z"
capabilityId: CAP-16
provider: mori://shinzui/en
status: shipped
stability: experimental
since: unreleased
packages:
  - en-core
interface:
  - En.Budget
evidence:
  - kind: module
    resource: en-core/src/En/Budget.hs
    proves: EvaluationBudget's three fields and their documented semantics, with defaultEvaluationBudget = maxDepth 25, pageLimit 1000, resultCap 1000.
  - kind: test
    resource: en-core/test/Main.hs
    proves: Depth-bounded evaluation errors under a reduced maxDepth rather than returning a decision.
  - kind: guide
    resource: docs/user/production-deployment-and-performance.md
    proves: "The Timeouts and Limits section: choosing budget values for a deployment."
---

# Operator-configurable evaluation budget

`EvaluationBudget` is a static bound the engine carries for its whole life:

- `maxDepth` (default 25) — recursion bound; exceeding it fails with `ResolutionLimitExceeded`.
- `pageLimit` (default 1000) — storage read batch size. A *batch* size, not a result ceiling:
  the engines drain pages until the store reports exhaustion, so a relation wider than one page
  is a large group, not a resolution failure.
- `resultCap` (default 1000) — bound on returned results per page.

It is deliberately **engine configuration, not a per-request wire field**: a client that could
raise `maxDepth` remotely would hold an amplification lever.

## Limits

- A budget is not a deadline. [Lookup](lookup-objects.md)'s deadline is a live clock poll and is
  threaded separately; raising depth buys no extra time and a generous deadline permits no extra
  recursion.
- Changing `pageLimit` trades store round trips against peak memory and cannot change an answer.
  Changing `maxDepth` or `resultCap` can.
