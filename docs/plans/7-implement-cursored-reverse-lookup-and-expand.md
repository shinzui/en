---
id: 7
slug: implement-cursored-reverse-lookup-and-expand
title: "Implement cursored reverse lookup and expand"
kind: exec-plan
created_at: 2026-06-23T04:08:29Z
intention: "intention_01kvsbcvsfepaafp5x44ykby47"
master_plan: "docs/masterplans/1-build-en-rebac-authorization-toolkit.md"
---

# Implement cursored reverse lookup and expand

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan implements the production reverse-query surface. After it is complete, an embedded caller can ask which objects a subject may access and receive a bounded, cursorable page with explicit truncation semantics. The plan also implements `expand(object, permission)`, which explains who can reach an object for review and audit UIs. Production lookup uses the same relationship semantics as `check` and confirms conditional entrypoints with forward checks.


## Progress

- [x] Implement reverse expansion over the compiled reachability graph using the bounded page/cursor API from EP-1. Completed 2026-06-23.
- [x] Preserve direct versus conditional entrypoint behavior from EP-3. Completed 2026-06-23.
- [x] Confirm conditional candidates by calling EP-4 forward `check`. Completed 2026-06-23.
- [x] Propagate caveat obligations or missing context through lookup results. Completed 2026-06-23.
- [x] Enforce result caps, recursion/depth limits, deadlines if configured, and deterministic cursor resume. Completed 2026-06-23 except no deadline option exists yet in the core request type.
- [x] Add tests for direct union lookup, userset lookup, tuple-to-userset lookup, caveated lookup, intersection/exclusion confirmation, cycles, and pagination. Completed 2026-06-23 for core lookup behavior.
- [x] Implement `expand` result construction for audit/review use. Completed 2026-06-23.
- [x] Run `cabal build all` and relevant tests. Completed 2026-06-23.


## Surprises & Discoveries

- The EP-1 `LookupPage` shape carried only `[ObjectRef]`, which could not preserve conditional caveat obligations. Lookup now returns `LookupObject` values with the object and its `CheckDecision`, so EP-6 can expose conditional lookup results without losing information.
- Recursive tuple-to-userset lookup needs a bounded transitive walk. Treating a repeated relation as an immediate error prevents valid parent/container schemas from returning descendants, so the implementation skips the currently-recursive branch while computing base objects and then expands descendants with a depth cap.
- `expand` can stay explanatory rather than authorization-filtering. It resolves consistency and walks the rewrite tree from an object relation to direct subjects and usersets, preserving caveat markers so audit/review UIs can display why a subject path is conditional.


## Decision Log

- Decision: Use reach-then-check for conditional lookup entrypoints.
  Rationale: The initial spec chooses the SpiceDB-style skeleton: reverse expansion produces candidates, and forward check confirms intersection, exclusion, and caveated paths.
  Date: 2026-06-23
- Decision: Add `ConsistencyStore` to lookup.
  Rationale: Lookup must honor the same consistency-token resolution boundary as forward `check`; using only `TupleStore` would either ignore `AtLeastAsFresh`/`AtExactSnapshot` tokens or duplicate datastore-specific token logic in core traversal.
  Date: 2026-06-23
- Decision: Carry per-object `CheckDecision` in lookup results.
  Rationale: Conditional caveated paths are valid lookup results but cannot be represented by a bare object id. The result page now preserves `Allowed` versus `Conditional` for each object.
  Date: 2026-06-23
- Decision: Keep `expand` as a structural explanation tree.
  Rationale: `expand` is for review and audit UIs, so it should show direct subjects, usersets, tuple-to-userset hops, caveat markers, and boolean rewrite branches instead of collapsing the graph into a yes/no authorization result.
  Date: 2026-06-23


## Outcomes & Retrospective

EP-7 implemented the production core reverse-query surface. `En.Lookup.lookup` now resolves
consistency through `ConsistencyStore`, returns bounded cursor pages of `LookupObject` values, carries
per-object `CheckDecision` values for conditional caveated results, recursively expands tuple-to-userset
container paths, and confirms intersection/exclusion candidates with forward `check`. `En.Expand.expand`
now builds bounded explanatory trees containing direct subjects, usersets, tuple-to-userset branches,
and caveat markers. The core tests cover direct lookup, userset subjects, tuple-to-userset recursion,
caveated lookup, intersection/exclusion confirmation, deterministic pagination, and expand trees. The
Postgres integration test also verifies lookup cursor paging over the Hasql-backed tuple store.

Validation completed 2026-06-23:

```text
cabal build all
Up to date

cabal test all
... all test suites passed ...
```


## Context and Orientation

This plan depends on `docs/plans/1-stabilize-core-authorization-interfaces.md`, `docs/plans/3-implement-schema-validation-and-reachability-compilation.md`, and `docs/plans/4-implement-forward-authorization-check.md`. It has soft dependencies on `docs/plans/2-implement-postgresql-tuple-store-and-consistency-tokens.md` and `docs/plans/5-validate-bounded-lookup-with-the-kikan-read-filter-spike.md`.

The current `en-core/src/En/Lookup.hs` is a placeholder with an unbounded list return. EP-1 should replace that with a page request/result. The current repository has no `En.Expand` implementation until EP-1 introduces the module.

Reverse lookup means starting from a subject and permission and finding objects of a requested type that the subject can reach. It must not be used to enumerate huge per-object streams such as every activity in kawa; the intended use is to return small reachable label sets such as spaces and visibility classes.


## Plan of Work

Start with an in-memory store and the compiled graph from EP-3. Implement a producer/mapper style traversal in ordinary Haskell code. A producer issues `readStartingWithUser` queries to find candidate objects for a subject. A mapper turns found resources into next subjects when traversing userset paths. The implementation may use a small custom cursor type before adopting a streaming library; do not introduce a streaming dependency unless it simplifies cursor correctness and fits the codebase.

Direct entrypoints can emit candidate objects into the result page. Conditional entrypoints must call `En.Check.check` from EP-4 before emitting. If `check` returns a conditional caveat result, lookup should preserve that condition in its result rather than silently allow or deny.

Implement pagination deterministically. A cursor must identify enough traversal state to resume without duplicating or skipping results for a fixed revision. Respect the requested limit and return a next cursor when more results may exist.

Implement `expand` after lookup. `expand` starts from object and permission and returns a tree or graph explaining the usersets and subjects that can reach it. It can share traversal helpers with check/lookup, but its output is explanatory rather than a boolean decision or object page.


## Concrete Steps

Work from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/en
```

Inspect the query modules:

```bash
sed -n '1,220p' en-core/src/En/Lookup.hs
sed -n '1,220p' en-core/src/En/Check.hs
sed -n '1,240p' en-core/src/En/Reachability.hs
```

If EP-5 is complete, read the results section appended to `docs/spec/0002-lookup-spike.md` and update this plan if the spike changes the cap, cursor, or materialization strategy.

Implement lookup and expand in `en-core`. Add tests in `en-core` for both in-memory store behavior and, if EP-2 is complete, Postgres-backed paging behavior.

Run:

```bash
cabal build all
cabal test en-core
```


## Validation and Acceptance

Tests must show that lookup returns the same effective authorization set as repeated check over a small fixture, but with bounded pages and stable cursors. Tests must also show that an intersection/exclusion candidate is not emitted unless forward check confirms it, that caveated candidates preserve conditional information, and that a depth limit produces `ResolutionLimitExceeded`.

For `expand`, tests should show an object's permission tree includes direct subjects, userset subjects, and caveat markers where present.


## Idempotence and Recovery

The lookup algorithm should be pure with respect to a fixed store revision. Cursor tests should use deterministic fixtures. If the EP-5 spike is red, stop before implementing production lookup and update the MasterPlan with the new materialized-index or schema-tightening decision.


## Interfaces and Dependencies

Hard dependencies: `docs/plans/1-stabilize-core-authorization-interfaces.md`, `docs/plans/3-implement-schema-validation-and-reachability-compilation.md`, and `docs/plans/4-implement-forward-authorization-check.md`.

Soft dependencies: `docs/plans/2-implement-postgresql-tuple-store-and-consistency-tokens.md` and `docs/plans/5-validate-bounded-lookup-with-the-kikan-read-filter-spike.md`.

This plan owns `en-core/src/En/Lookup.hs` and `en-core/src/En/Expand.hs`. EP-6 exposes these functions over HTTP and through the client.


Revision note 2026-06-23: Added `intention_01kvsbcvsfepaafp5x44ykby47` to the plan frontmatter at the user's request.
