---
type: Friction Entry
title: "just hurl does not run the write-path Hurl flow"
description: "en-servant/test/hurl/run.sh only format-checks relationships.hurl and perimeter.hurl, so 'just hurl' passing says nothing about writes; the mutating flow needs a separate hand-typed hurl command."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-14T00:05:10Z"
frictionId: FRIC-4
status: "accepted"
impact: detour
kind: tooling
origin: "mori://shinzui/en"
affects: "mori://shinzui/en"
plan: "docs/plans/78-refuse-writes-of-tuples-the-active-schema-cannot-interpret.md"
workaround: "ran hurl --test on relationships.hurl directly against a disposable database (en-servant/test/hurl/README.md, Opt-in flows)"
resolution: "The opt-in split is deliberate (relationships.hurl mutates state) and documented in en-servant/test/hurl/README.md; plans that touch writes must name the opt-in command, as plan 78 now does."
amended:
  - by: "claude-code/claude-opus-5-5"
    at: "2026-11-14T00:20:42Z"
    change: "Status set to accepted."
---
# just hurl does not run the write-path Hurl flow

## Attempted

validating a write-path change with the Hurl suite as the plan's Concrete Steps describe

## Encountered

just hurl ran 6 read-only files; the new schema_violation request in relationships.hurl was never executed

## Workaround

ran hurl --test on relationships.hurl directly against a disposable database (en-servant/test/hurl/README.md, Opt-in flows)
