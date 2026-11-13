---
title: "generic-lens labels are en's record access idiom"
status: accepted
date: 2026-08-25
authors: [shinzui]
related:
  - docs/plans/68-migrate-en-s-records-to-generic-lens-label-syntax-and-a-custom-prelude.md
  - docs/plans/77-make-lookup-follow-recursive-usersets-the-way-check-does.md
  - docs/masterplans/11-bring-en-into-conformance-with-the-haskell-jitsurei-pattern-catalog.md
  - mori://shinzui/haskell-jitsurei/docs/core-record-patterns
  - mori://shinzui/haskell-jitsurei/docs/core-custom-prelude
---

# ADR 7 — generic-lens labels are en's record access idiom

## Status

Accepted, 2026-08-25. Implemented by
[ExecPlan 68](../plans/68-migrate-en-s-records-to-generic-lens-label-syntax-and-a-custom-prelude.md).

## Context

The fleet Haskell catalog standardizes record reads and updates on `generic-lens`
`#label` optics and places common lens operators in a project prelude. Before this decision,
en instead enabled `OverloadedRecordDot` and usually `NoFieldSelectors` package-wide. Both
idioms are coherent, but their difference made code copied between en and fleet reference
implementations fail until every record expression was rewritten.

Adopting the fleet idiom required a repository-wide mechanical migration. The planning
inventory covered roughly 30,900 lines, 1,970 field reads, and 717 update sites. That scale
made behavior preservation—not local terseness—the governing constraint: all existing tests,
golden wire encodings, and the generated OpenAPI document had to remain unchanged.

`Data.Generics.Labels` supplies the `IsLabel` instance that gives `#field` its record-lens
meaning. That instance is an orphan. Importing it from `En.Prelude` would impose its meaning
on every transitive prelude consumer and prevent a module from choosing another label
interpretation, including label-based DSLs used elsewhere in the fleet.

## Decision

En reads `Generic` record fields with `value ^. #field` and changes them with lens operators
such as `.~`, `%~`, `?~`, `at`, and `ix`. Modules use `En.Prelude` for the common lens and
project vocabulary, but every module that needs generic record labels imports
`Data.Generics.Labels ()` directly. `En.Prelude` must never import or re-export that orphan
instance.

`OverloadedRecordDot` is not a package default. `NoFieldSelectors` is also not a package
default, but a module may enable it locally when generated selectors would collide with an
existing top-level API. Records with fields for which GHC cannot derive `Generic`, such as a
rank-polymorphic field, may retain record-pattern access. Foreign records that do not expose
`Generic` use their dependency's exported selectors or update functions through qualified
imports. These are explicit representation constraints, not a second preferred idiom.

Hand-written JSON instances remain hand-written. Adding `Generic` for label access does not
authorize changing serialization, field names, constructor order, or wire shape.

## Consequences

Contributors can move record-oriented code between en and the fleet examples without
translating its access syntax. Ordinary records that participate in label access derive
`Generic`, and Cabal components importing `Data.Generics.Labels` declare `generic-lens`
directly because Cabal does not expose transitive dependencies.

The migration is intentionally broad but behavior-neutral. All eight test suites pass, the
schema Template Haskell negative fixtures retain their expected compiler failures, and
`docs/api/openapi.json` remains byte-identical at SHA-256
`4db31037c3d823d9c0f5e19b968165e2d7364bf9f8a971cb4a7fc2b65ec0a183`.

The final compiler check found ten core source lines containing fourteen old reads after the
guarded textual pass, plus six PostgreSQL and Servant source lines during package-extension
removal. This is why future migrations must finish by disabling the old extension and
compiling every component, including tests and benchmarks, rather than treating a source
grep as proof.

Local `NoFieldSelectors` pragmas remain where selector generation creates real name clashes;
the pragma is a conflict-control tool there, not permission to restore record-dot access.

## Measured hot-predicate exception — 2026-10-13

[ExecPlan 70](../plans/70-characterize-and-bound-grant-generation-overhead.md)
ran the unchanged PostgreSQL pure benchmark against its committed baseline.
`comparePgSnapshot` measured 922 ns versus an 80.4 ns baseline after the label
migration. Focused INLINE pragmas and module-level -O2 still measured 1.15 us and
758 ns. Record-pattern projections in `transactionVisible`, `snapshotIncludes`
and `hasRequiredVisibleFutureGap` restored 81.8 ns without changing their
algorithms or the baseline. The codec benchmarks remained within their limits.

Allow these three hot snapshot predicates to bind their fields with record
patterns. Keep ordinary Generic record access as labels. This is a measured
exception at a small pure boundary, not permission for a general access-style
migration. Any expansion should have equivalent benchmark evidence and preserve
behavior under the existing revision and PostgreSQL integration tests.

## Measured lookup-evaluator exception — 2026-11-13

[ExecPlan 77](../plans/77-make-lookup-follow-recursive-usersets-the-way-check-does.md)
replaced the lookup evaluator's internal result, `Either EnError LookupObjects`, with
`Either EnError Evaluated`, a record of the objects and the set of in-progress
subproblems they depend on. Reading that record through `#objects` and `#assumed`
measured `lookup/reachable-spaces` at 3.7–4.3 µs against a 2.8 µs baseline, with the
evaluation itself traced as unchanged (three subproblem evaluations, against four
before). INLINE record-pattern accessors (`evaluatedObjects`, `evaluatedAssumed`)
measured 2.4 µs. `lookup/wide-fanout` stayed within noise of its baseline either way.

Allow `En.Lookup` to read `Evaluated` through those accessors; `Evaluated` derives no
`Generic`. This is a second measured exception, at one internal type on the lookup hot
path; every other record in `En.Lookup`, including `EvalState`, keeps label access.
