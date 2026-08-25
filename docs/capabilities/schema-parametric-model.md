---
title: "Schema-parametric authorization model"
type: Capability
description: "Supply your own object types, relations, permissions, usersets, and caveats as a Haskell value built with a checked builder DSL, and get a validated schema the engine is generic over."
generated:
  by: anthropic/claude-opus-5
  at: "2026-08-24T14:35:00Z"
capabilityId: CAP-1
provider: mori://shinzui/en
status: shipped
stability: experimental
since: unreleased
packages:
  - en-core
interface:
  - En.Schema
  - En.Schema.Builder
  - En.Schema.Types
evidence:
  - kind: test
    resource: en-core/test/Main.hs
    proves: The builder schema equals the hand-written schema and hashes identically; duplicate object types, relations, caveats, and caveat parameters are each reported as a named SchemaViolation.
  - kind: guide
    resource: docs/user/modeling.md
    proves: How to choose object types, relations vs permissions, direct and userset subjects, rewrite choices, and caveats.
  - kind: guide
    resource: docs/user/space-page-sharing.md
    proves: A full worked schema for spaces, groups, page hierarchies, documents, activities, and subtree invitations.
---

# Schema-parametric authorization model

`en` hard-codes no authorization model. A consuming application supplies a `Schema` — object
types, relations, permissions, rewrite rules, and caveat definitions — normally authored with
`En.Schema.Builder`, and every engine operation is generic over it.

## Usage

```haskell
schema = do
    user  <- Schema.object "user" []
    space <- Schema.object "space"
        [ Schema.relation "owner"  [Schema.subject "user"] Schema.this
        , Schema.relation "viewer" [Schema.subject "user"] (Schema.anyOf Schema.this [Schema.computed "owner"])
        ]
    Schema.build [user, space]
```

Validation is a separate step that yields evidence — see
[compiled reachability and schema hashing](reachability-compilation.md) and
[compile-time schema validation](compile-time-schema-validation.md).

## Limits

- The builder is fallible: `Schema.object`, `Schema.relation`, and `Schema.caveat` return
  `Either EnError`, and duplicate names are rejected at build time rather than at validation.
- Wildcard allowed-subjects cannot be usersets, and `TupleToUserset` arrows are rejected when
  the arrow's target relation is incompatible or wildcard-only.
- The public API is pre-1.0 and may change without a major bump.
