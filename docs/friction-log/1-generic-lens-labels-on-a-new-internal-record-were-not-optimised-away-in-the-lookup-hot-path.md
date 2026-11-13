---
type: Friction Entry
title: "Generic-lens labels on a new internal record were not optimised away in the lookup hot path"
description: "Reading a new Evaluated record through #objects/#assumed, as the project's label convention suggests, cost about a third of the smallest lookup benchmark, and the cause took six bench cycles of bisection to find."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-13T04:29:16Z"
frictionId: FRIC-1
status: logged
impact: slowdown
kind: interface
origin: "mori://shinzui/en"
affects: "mori://ekmett/lens"
plan: "docs/plans/77-make-lookup-follow-recursive-usersets-the-way-check-does.md"
workaround: "Pattern-match accessors (evaluatedObjects, evaluatedAssumed) with INLINE pragmas instead of #label lenses on Evaluated"
---
# Generic-lens labels on a new internal record were not optimised away in the lookup hot path

## Attempted

Replacing Either EnError LookupObjects with an Evaluated record in En.Lookup without regressing lookup/reachable-spaces

## Encountered

reachable-spaces went from 2.8us to 3.7-4.3us with no extra evaluation; replacing the label lenses with pattern matches and INLINE accessors brought it to 2.4us

## Workaround

Pattern-match accessors (evaluatedObjects, evaluatedAssumed) with INLINE pragmas instead of #label lenses on Evaluated
