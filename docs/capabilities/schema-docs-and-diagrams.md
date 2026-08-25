---
title: "Render a schema as docs and diagrams"
type: Capability
description: "Render a schema to Markdown reference text, a Mermaid schema diagram, or a Mermaid reachability diagram, with byte-stable output suitable for checking into a repository."
generated:
  by: anthropic/claude-opus-5
  at: "2026-08-24T14:35:00Z"
capabilityId: CAP-4
provider: mori://shinzui/en
status: shipped
stability: experimental
since: unreleased
packages:
  - en-core
interface:
  - En.Schema.Render
requires:
  - CAP-1
evidence:
  - kind: test
    resource: en-core/test/Main.hs
    proves: renderMarkdown, renderMermaid, and renderReachabilityMermaid each emit a stable, asserted-equal rendering of the kikan fixture.
  - kind: guide
    resource: docs/user/modeling.md
    proves: The "Visualize your schema" section shows the rendered output in context.
---

# Render a schema as docs and diagrams

Three total functions turn a model into reviewable artifacts: `renderMarkdown` for a reference
table, `renderMermaid` for the declared [schema](schema-parametric-model.md), and
`renderReachabilityMermaid` for the [compiled reachability graph](reachability-compilation.md)
— which is the one that shows what the rewrite rules actually resolve to.

## Usage

```haskell
Text.putStrLn (renderMarkdown mySchema)
Text.putStrLn (renderReachabilityMermaid validatedSchema)
```

## Limits

- Rendering is one-way; there is no reader that turns Markdown or Mermaid back into a schema.
- Output stability is asserted by a golden test, so a rendering change is a test change — treat
  the format as an interface, not an implementation detail.
