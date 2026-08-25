---
title: "Lookup the subjects that can reach an object"
type: Capability
description: "Answer the reverse question — which subjects hold a permission on a given object — as a paged, cursor-resumable list, for share sheets, audits, and notification fan-out."
generated:
  by: anthropic/claude-opus-5
  at: "2026-08-24T14:35:00Z"
capabilityId: CAP-9
provider: mori://shinzui/en
status: shipped
stability: experimental
since: unreleased
packages:
  - en-core
interface:
  - En.LookupSubjects
  - POST /v1/lookup-subjects
requires:
  - CAP-5
  - CAP-12
evidence:
  - kind: conformance
    resource: en-core/conformance/Main.hs
    proves: lookupSubjectsTests exercise the reverse traversal against the kikan fixture.
  - kind: test
    resource: en-servant/test/Main.hs
    proves: The lookup-subjects request/response wire contract round-trips and matches its OpenAPI schema.
---

# Lookup the subjects that can reach an object

`lookupSubjects` walks the [reachability graph](reachability-compilation.md) in the other
direction from [lookup](lookup-objects.md): given an object and a permission, page through the
subjects that hold it. Cursors carry their own state type (`LookupSubjectsCursor`), so a
resumed page reads the same window rather than a smear across snapshots.

## Usage

```http
POST /v1/lookup-subjects
{"object": "space:eng", "permission": "view", "limit": 100}
```

## Limits

- Same budget and deadline bounds as [lookup](lookup-objects.md); check the page state before
  treating a result as complete.
- This enumerates subjects the graph can reach. For a *why*, use
  [expand](expand-subject-tree.md), which returns the tree rather than the flattened set.
