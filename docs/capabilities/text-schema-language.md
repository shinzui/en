---
title: "Text schema language"
type: Capability
description: "Parse en's line-oriented text schema language into a Schema, so a server or an application can load its authorization model from a file at runtime instead of compiling it in."
generated:
  by: anthropic/claude-opus-5
  at: "2026-08-24T14:35:00Z"
capabilityId: CAP-3
provider: mori://shinzui/en
status: shipped
stability: experimental
since: unreleased
packages:
  - en-core
interface:
  - En.Schema.Parse
requires:
  - CAP-1
evidence:
  - kind: test
    resource: en-core/test/Main.hs
    proves: Direct parser tests and caveat parser tests round-trip the text form, and the quasi-quoter path builds an equal schema from the same source.
  - kind: guide
    resource: docs/user/getting-started.md
    proves: Section 6 runs the standalone server from a schema file.
---

# Text schema language

`parseSchema :: Text -> Either EnError Schema` reads en's text schema language, so the model
does not have to be a compiled-in Haskell value. This is what lets
[the standalone server](standalone-authorization-server.md) take `EN_SCHEMA_PATH` and what
makes [schema reload](schema-reload-and-preflight.md) possible at all.

## Usage

```haskell
case parseSchema sourceText of
    Left err     -> die (show err)
    Right schema -> either die pure (validateSchema schema)
```

## Limits

- Parsing is not validation: `parseSchema` produces a raw `Schema`, and `validateSchema` still
  has to accept it before it can be compiled.
- A parse failure is an `EnError`, not a positioned diagnostic with a source span.
