---
title: "Check a permission, with caveats and obligations"
type: Capability
description: "Answer check(subject, permission, object) as Allowed, Denied, or Conditional with the caveat obligations still outstanding, evaluated over the compiled reachability graph at a named consistency."
generated:
  by: anthropic/claude-opus-5
  at: "2026-08-24T14:35:00Z"
capabilityId: CAP-6
provider: mori://shinzui/en
status: shipped
stability: experimental
since: unreleased
packages:
  - en-core
interface:
  - En.Check
  - En.Caveat
  - En.Decision
requires:
  - CAP-5
  - CAP-12
evidence:
  - kind: conformance
    resource: en-core/conformance/Main.hs
    proves: The kikan agency contract — a guest can view a shared item, cannot view an internal item, cannot act on the shared space, a non-guest cannot view the shared item, and a check reports the snapshot it was decided at.
  - kind: test
    resource: en-core/test/Main.hs
    proves: Residual decision algebra over union, intersection, and exclusion; obligation de-duplication; caveat evaluation and residual application.
  - kind: guide
    resource: docs/user/queries-and-writes.md
    proves: "The Check section: call shape, consistency modes, and how to treat a Conditional result."
---

# Check a permission, with caveats and obligations

`check` is the gate. It resolves a permission over the
[compiled reachability graph](reachability-compilation.md) and returns a `CheckDecision`:

- `Allowed` — the permission holds at the snapshot it reports in `checkedAt`.
- `Denied` — it does not.
- `Conditional obligations` — it holds only if the listed caveats are satisfied, and the
  request did not carry the context needed to decide them.

Caveats are bounded ABAC conditions attached to a rewrite rule (time windows, autonomy levels).
`En.Caveat` evaluates them against request context and `En.Decision` carries the residual when
they cannot be discharged.

## Usage

```haskell
check consistencyStore tupleStore graph MinimizeLatency context subject permission object
```

## Limits

- **`Conditional` is not `Allowed`.** Treat it as denied until the missing context is supplied
  and the query returns `Allowed`. Every shipped example — the Servant handler, the GraphQL
  resolver — fails closed on it.
- Traversal is bounded by the [evaluation budget](evaluation-budget.md); exceeding `maxDepth`
  fails with `ResolutionLimitExceeded` rather than returning a decision.
