---
id: 3
slug: implement-schema-validation-and-reachability-compilation
title: "Implement schema validation and reachability compilation"
kind: exec-plan
created_at: 2026-06-23T04:05:49Z
intention: "intention_01kvsbcvsfepaafp5x44ykby47"
master_plan: "docs/masterplans/1-build-en-rebac-authorization-toolkit.md"
---

# Implement schema validation and reachability compilation

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan turns a consumer-supplied schema into a checked reachability graph. After it is complete, an application can define object types, relations, permissions, allowed subjects, and caveats as Haskell data, receive clear validation errors for invalid references, and compile the valid schema into a graph that `check`, `lookup`, and `expand` can traverse. The behavior is visible through tests that compile a kikan-shaped schema with space membership, guest organizations, delegation caveats, and visibility-class containers.


## Progress

- [x] Extend or consume the final schema model from EP-1, including caveat declarations and allowed subject rules. Completed 2026-06-23T05:57:00Z.
- [x] Implement schema validation for unknown object types, relations, caveats, cycles, empty set operations, and invalid tuple-to-userset arrows. Completed 2026-06-23T05:57:00Z.
- [x] Add schema hashing for token validation and standalone service startup. Completed 2026-06-23T05:57:00Z.
- [x] Implement `En.Reachability.compile` to produce graph nodes and edges annotated as direct or conditional. Completed 2026-06-23T05:57:00Z.
- [x] Add tests for union, computed userset, tuple-to-userset, intersection, exclusion, caveated rewrites, and recursion bounds. Completed 2026-06-23T05:57:00Z.
- [x] Add a kikan-shaped fixture schema that exercises guest org view-only sharing and delegation caveats. Completed 2026-06-23T05:57:00Z.
- [x] Run `cabal build all` and relevant tests. Completed 2026-06-23T05:57:00Z.


## Surprises & Discoveries

- The first reachability compiler pass incorrectly inlined `ComputedUserset` rewrites against the original target relation, so `space#view = owner + member` could not produce direct user entrypoints. The compiler now carries both the compiled target relation and the currently evaluated relation, so `This` reads allowed subjects from the inlined relation while emitted entrypoints still target the original permission.
- Recursive schema validation needs to distinguish unproductive rewrite cycles from productive recursive traversals. The kikan-shaped `space#view` fixture is recursive through `space#parent -> space#view`, but it is valid because it also reaches direct base relations such as `owner` and `member`.


## Decision Log

- Decision: Keep schema runtime-configurable as a Haskell value, not a service-side DSL.
  Rationale: The repository and kikan C13 contract choose a schema-parametric Haskell toolkit. A runtime DSL can be layered later without changing the core graph model.
  Date: 2026-06-23
- Decision: Add `AllowedSubject` declarations to each relation.
  Rationale: Validation needs to reject tuples and tuple-to-userset arrows that cannot be meaningful under the active schema. A relation-level allowed-subject set gives EP-4 and EP-7 enough type information to traverse direct and userset subjects safely.
  Date: 2026-06-23
- Decision: Treat intersection, exclusion, and caveated rewrite entrypoints as conditional in the reachability graph.
  Rationale: The MasterPlan chose the SpiceDB-style reach-then-check approach. Direct union/computed/tuple-to-userset paths can stream lookup candidates, but set subtraction, all-branches semantics, and caveats require forward confirmation before lookup emits a final result.
  Date: 2026-06-23
- Decision: Use a deterministic FNV-1a text fingerprint for the initial schema hash.
  Rationale: Tokens need a stable schema identity now, and the schema is a local Haskell value. The hash renderer orders `Map`/`Set` contents explicitly and does not rely on derived `Show`; a stronger hash can replace the private implementation later without changing the public `SchemaHash` type.
  Date: 2026-06-23


## Outcomes & Retrospective

EP-3 implemented schema validation, deterministic schema hashing, and a concrete reachability graph. The kikan-shaped fixture compiles and demonstrates direct user membership, guest-organization userset reachability, recursive parent traversal, caveated delegation, and conditional intersection/exclusion entrypoints. Invalid schema tests cover unknown references, empty set operations, invalid tuple-to-userset arrows, unknown caveats, and unproductive rewrite cycles.


## Context and Orientation

This plan depends on `docs/plans/1-stabilize-core-authorization-interfaces.md`. The current schema and reachability files are `en-core/src/En/Schema.hs` and `en-core/src/En/Reachability.hs`. `En.Schema.Rewrite` already includes `This`, `ComputedUserset`, `TupleToUserset`, `Union`, `Intersection`, `Exclusion`, and `Caveated`, but validation and compilation are placeholders.

A reachability graph is the compiled form of the schema. The engine uses it to decide which datastore query to issue next while checking or looking up permissions. Direct entrypoints are paths that can produce results without confirmation, usually under unions. Conditional entrypoints are paths under intersection, exclusion, or caveat logic; production lookup must run forward `check` to confirm those candidates.


## Plan of Work

First, implement validation. A valid schema must not reference unknown object types, relations, or caveats. `ComputedUserset` must point to a relation on the same object type. `TupleToUserset` must point through a relation whose subject can be a userset/object type compatible with the target relation. `Union`, `Intersection`, and `Exclusion` should reject empty or nonsensical forms where the engine cannot define stable semantics.

Next, define a stable schema hash over the semantic schema. This hash is included in consistency tokens so a token from a different schema can be rejected. Use deterministic ordering from `Map` and avoid relying on `Show` output if it could change accidentally.

Then implement `En.Reachability.compile`. The compiled graph should preserve enough information for forward check and reverse lookup: source and target object types, relation names, rewrite kind, whether an edge is direct or conditional, and recursion/depth information. Keep the concrete representation opaque outside `En.Reachability` unless later plans require read-only inspection helpers for tests.

Finally, add fixtures and tests. The kikan-shaped fixture should model `org:acme member user`, `space:project-x guest_org org:acme`, view-only guest access, `intention delegate user` with caveats, and visibility-class containers preferred by the spec.


## Concrete Steps

Work from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/en
```

Inspect the relevant files:

```bash
sed -n '1,240p' en-core/src/En/Schema.hs
sed -n '1,220p' en-core/src/En/Reachability.hs
sed -n '1,180p' en-core/src/En/Error.hs
```

Implement validation and compilation in `en-core`. Add tests in the repository's test structure. If no test suite exists yet, add one to `en-core/en-core.cabal` using the project's existing dependency style.

Run:

```bash
cabal build all
```

Then run the focused core test suite:

```bash
cabal test en-core-interface-tests
```


## Validation and Acceptance

A valid kikan-shaped fixture schema must compile. Invalid schemas must return structured `EnError` values rather than throwing exceptions. Tests must prove that direct and conditional entrypoints are annotated differently so lookup can avoid per-candidate checks for simple union paths and confirm hard cases.

`cabal build all` must pass. `cabal test en-core-interface-tests` must pass and includes negative validation cases for each rewrite constructor plus positive graph coverage for union, computed userset, tuple-to-userset, intersection, exclusion, caveated rewrites, and productive recursion.


## Idempotence and Recovery

Schema compilation is pure code. It can be rerun safely. If the concrete reachability graph representation changes while implementing EP-4 or EP-7, update this plan and the MasterPlan Decision Log before changing already-implemented algorithms.


## Interfaces and Dependencies

Hard dependency: `docs/plans/1-stabilize-core-authorization-interfaces.md`.

This plan owns `En.Schema` validation semantics, schema hashing, and `En.Reachability.compile`. EP-4 and EP-7 consume the compiled graph.


Revision note 2026-06-23: Added `intention_01kvsbcvsfepaafp5x44ykby47` to the plan frontmatter at the user's request.

Revision note 2026-06-23: Completed EP-3 by adding relation allowed-subject rules, schema validation, deterministic schema hashing, a concrete reachability graph compiler, and kikan-shaped test coverage.
