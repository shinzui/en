---
id: 4
slug: implement-forward-authorization-check
title: "Implement forward authorization check"
kind: exec-plan
created_at: 2026-06-23T04:05:49Z
intention: "intention_01kvsbcvsfepaafp5x44ykby47"
master_plan: "docs/masterplans/1-build-en-rebac-authorization-toolkit.md"
---

# Implement forward authorization check

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan implements the core yes/no object gate: given a subject, permission, object, request context, and consistency mode, answer whether access is allowed, denied, or conditional because caveat context is missing. After it is complete, embedded users can call `En.Check.check` against an in-memory store and the kikan-shaped schema to verify direct ownership, space membership, guest organization view-only sharing, and caveated delegation.


## Progress

- [ ] Resolve the requested consistency mode to a revision before reading store rows.
- [ ] Implement forward traversal for `This`, `ComputedUserset`, `TupleToUserset`, and `Union`.
- [ ] Implement bounded handling for `Intersection` and `Exclusion`.
- [ ] Evaluate tuple and rewrite caveats using request context and return conditional decisions when context is missing.
- [ ] Enforce recursion, breadth, and deadline limits with `ResolutionLimitExceeded`.
- [ ] Add an in-memory tuple store for deterministic tests if EP-1 has not already added one.
- [ ] Test kikan C13 cases: owner, member, guest org view-only, delegation autonomy, time-bounded delegation, and denied internal-only access.
- [ ] Run `cabal build all` and relevant tests.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Implement `check` before production `lookup`.
  Rationale: Lookup needs reach-then-check confirmation for conditional entrypoints, so forward check is a prerequisite for correct reverse expansion.
  Date: 2026-06-23


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This plan depends on `docs/plans/1-stabilize-core-authorization-interfaces.md` and `docs/plans/3-implement-schema-validation-and-reachability-compilation.md`. It has a soft dependency on `docs/plans/2-implement-postgresql-tuple-store-and-consistency-tokens.md`; the first implementation can use an in-memory store as long as it goes through the same core interfaces.

The current `en-core/src/En/Check.hs` is a placeholder. It imports `TupleStore`, `ReachabilityGraph`, `Consistency`, `RelationName`, `ObjectRef`, and `Subject`, and currently has `check = error "TODO..."`. This plan replaces that placeholder with real traversal.

Forward check means starting from a target object and permission and asking whether a subject is a member of the computed userset. A userset is a set of subjects computed by rewrite rules. `TupleToUserset` is the arrow operation: follow tuples on one relation to another object, then evaluate a relation on that target object.


## Plan of Work

Start by defining or using the traversal state from EP-1 and EP-3: resolved revision, compiled graph, request context, subject being checked, target object and relation, recursion depth, visited subproblems, and cache of subproblem decisions.

Implement the simple rewrite cases first. `This` checks direct tuples on the target object and relation. `ComputedUserset` evaluates another relation on the same object. `TupleToUserset` reads tuples on the tupleset relation and recursively checks the computed relation on the referenced subject/object set. `Union` allows access if any branch allows access.

Then implement hard cases. `Intersection` allows only when all branches allow. `Exclusion` allows when the base allows and the subtract branch does not. Caveats must combine with branch results: an otherwise allowed path with missing context should return a conditional result rather than false, so API callers can distinguish denied access from insufficient context.

Add recursion and breadth limits. Cycles in relationship graphs must not loop forever. If a configured bound is exceeded, return `ResolutionLimitExceeded` through the core error model.


## Concrete Steps

Work from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/en
```

Inspect current check and dependency modules:

```bash
sed -n '1,220p' en-core/src/En/Check.hs
sed -n '1,260p' en-core/src/En/Reachability.hs
sed -n '1,260p' en-core/src/En/Effect/TupleStore.hs
```

Implement `En.Check.check` and supporting helpers. Prefer private helper functions in `En.Check` until duplication with `En.Lookup` becomes clear. Add tests under `en-core` using the kikan-shaped schema fixture from EP-3.

Run:

```bash
cabal build all
cabal test en-core
```


## Validation and Acceptance

Tests must demonstrate that a direct owner is allowed, a non-member is denied, a user in an agency org granted `guest_org` receives `view` but not `act`, a delegate with autonomy below the requested action is denied or conditional according to caveat semantics, and an expired `until` caveat denies access. Tests must also cover recursion limits and at least one userset subject.

If EP-2 is complete, add at least one integration test that exercises Postgres-backed check through the same core function. If EP-2 is not complete, record that integration as remaining work.


## Idempotence and Recovery

The algorithm should be deterministic for a fixed store snapshot and schema. Tests should not depend on wall-clock time except through explicit request context values. If caveat behavior changes while implementing EP-7, update this plan's Decision Log and keep old tests until replacement tests prove the new semantics.


## Interfaces and Dependencies

Hard dependencies: `docs/plans/1-stabilize-core-authorization-interfaces.md` and `docs/plans/3-implement-schema-validation-and-reachability-compilation.md`.

Soft dependency: `docs/plans/2-implement-postgresql-tuple-store-and-consistency-tokens.md`.

This plan owns `en-core/src/En/Check.hs` and any in-memory test store helpers needed to verify it. EP-7 consumes `check` for conditional lookup confirmation.


Revision note 2026-06-23: Added `intention_01kvsbcvsfepaafp5x44ykby47` to the plan frontmatter at the user's request.
