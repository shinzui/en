---
title: "Compile-time schema validation"
type: Capability
description: "Validate a schema during compilation with a Template Haskell splice or a quasi-quoter, so an invalid model fails the build with the same error the runtime validator would return."
generated:
  by: anthropic/claude-opus-5
  at: "2026-08-24T14:35:00Z"
capabilityId: CAP-2
provider: mori://shinzui/en
status: shipped
stability: experimental
since: unreleased
packages:
  - en-core
interface:
  - En.Schema.TH
requires:
  - CAP-1
evidence:
  - kind: test
    resource: en-core/test/Main.hs
    proves: A compile-time validated schema equals the builder fixture, and the `schema` quasi-quoter builds a schema equal to the compact fixture.
  - kind: test
    resource: en-core/test/fixtures/BadSchema.hs
    proves: An invalid schema is rejected at splice time rather than at startup; sibling fixtures cover bad permissions, duplicate names, and bad quoted schemas.
---

# Compile-time schema validation

`mkValidSchema` and `mkValidSchemaEither` run the ordinary validator inside a Template Haskell
splice: if the [schema](schema-parametric-model.md) is invalid the module fails to build with
the same `EnError` text the runtime validator produces, and if it is valid the splice yields a
`ValidSchema` — the evidence type [reachability compilation](reachability-compilation.md)
consumes. The `schema` quasi-quoter does the same for the
[text schema language](text-schema-language.md).

## Usage

```haskell
validated :: ValidSchema
validated = $$(mkValidSchemaEither kikanSchema)
```

## Limits

- Template Haskell is required in the consuming module, which rules this out for schemas that
  are only known at runtime — load those with the [text schema language](text-schema-language.md).
- The splice validates the schema, not the tuples already in a store; drift between the two is
  reported separately by the [tuple/schema drift report](tuple-schema-drift-report.md).
