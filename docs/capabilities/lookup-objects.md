---
title: "Lookup the objects a subject can reach"
type: Capability
description: "Answer lookup(subject, permission, objectType) as a paged, cursor-resumable list of objects the subject may reach, with a per-request deadline and an explicit exhausted/limited outcome."
generated:
  by: anthropic/claude-opus-5
  at: "2026-08-24T14:35:00Z"
capabilityId: CAP-8
provider: mori://shinzui/en
status: shipped
stability: experimental
since: unreleased
packages:
  - en-core
interface:
  - En.Lookup
requires:
  - CAP-5
  - CAP-12
evidence:
  - kind: conformance
    resource: en-core/conformance/Main.hs
    proves: Guest view reaches exactly the shared subset and guest act reaches nothing, each reported with an explicit LookupExhausted outcome.
  - kind: benchmark
    resource: en-core/bench/Main.hs
    proves: The lookup benchmark group covers reachable-spaces and wide-fanout traversals, guarding against resolution regressions.
  - kind: example
    resource: en-postgres/lookup-spike/Main.hs
    proves: The executable spike behind docs/spec/0002-lookup-spike.md, exercising the reverse-index strategy end to end.
  - kind: guide
    resource: docs/user/queries-and-writes.md
    proves: "The Lookup section: limits, cursors, and reading the page outcome."
---

# Lookup the objects a subject can reach

`lookup` is the read-filter primitive: given a subject and a permission, return the objects of
a type the subject may reach. It is the reverse of
[check](check-decisions-with-caveats.md) and is what a list endpoint should call instead of
checking every candidate row.

A page reports its outcome explicitly — exhausted, or stopped at a limit or deadline with a
cursor to resume from. A caller that ignores the outcome and treats a short page as "that is
everything" will silently under-report.

## Usage

```haskell
Lookup.lookup graph MinimizeLatency (lookupRequest subject permission (ObjectType "space") (LookupLimit 100))
```

## Limits

- Results are bounded by `resultCap` in the [evaluation budget](evaluation-budget.md) and by the
  per-request deadline; both are reported in the page outcome rather than as an error.
- A deadline is a live clock poll and a budget is a static bound. Raising `maxDepth` buys a slow
  lookup no extra time, and a generous deadline permits no extra recursion.
- Lookup quality depends on the model: see the lookup-friendly modeling section of
  `docs/user/modeling.md`.
