---
id: 1
slug: stabilize-core-authorization-interfaces
title: "Stabilize core authorization interfaces"
kind: exec-plan
created_at: 2026-06-23T04:05:49Z
intention: "intention_01kvsbcvsfepaafp5x44ykby47"
master_plan: "docs/masterplans/1-build-en-rebac-authorization-toolkit.md"
---

# Stabilize core authorization interfaces

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan fixes the public shape of `en-core` before storage and algorithms are implemented. After this change, later plans can represent concrete caveat payloads, conditional authorization decisions, bounded lookup pages, store rows with provenance, consistency-token resolution, and the missing `expand` surface. The observable outcome is that `cabal build all` passes and focused tests can construct a caveated tuple, run a store query that returns tuple rows instead of bare object ids, and typecheck calls to `check`, `lookup`, and `expand` using the new result types.


## Progress

- [x] Replace the placeholder caveat model with typed caveat values, request context, and caveat evaluation result types. Completed 2026-06-23.
- [x] Replace `check :: ... -> m Bool` with a decision type that can represent allowed, denied, and conditional/missing-context results. Completed 2026-06-23.
- [x] Replace unbounded `lookup :: ... -> m [ObjectRef]` with a bounded page/cursor/truncation API. Completed 2026-06-23.
- [x] Replace `readStartingWithUser :: ... -> m [ObjectRef]` with a store-row API that preserves tuple subject, object, relation, caveat payload, and enough provenance for algorithms. Completed 2026-06-23.
- [x] Add an explicit consistency resolver/store boundary for decoding tokens, validating schema/datastore identity, checking GC-window validity, and choosing a revision for each `Consistency` mode. Completed 2026-06-23.
- [x] Add the missing `En.Expand` module and export it from `en-core/en-core.cabal`. Completed 2026-06-23.
- [x] Add compile-focused tests or doctest-style examples that prove the new interfaces can express the kikan C13 examples. Completed 2026-06-23.
- [x] Run `cabal build all`. Completed 2026-06-23.


## Surprises & Discoveries

- The current scaffold compiles, but the interfaces encode several decisions that contradict `docs/spec/0001-en-overview.md`. In particular, `En.Effect.TupleStore.readStartingWithUser` returns only `[ObjectRef]`, `En.Check.check` returns `Bool`, and `En.Lookup.lookup` returns `[ObjectRef]`.
- The first compile-focused test found that using the same constructor names for schema parameter kinds and runtime caveat values made client code ambiguous. The public constructors are now split as `ParameterEnum`/`ParameterTimestamp` for schema declarations and `ValueEnum`/`ValueTimestamp` for tuple or request values.


## Decision Log

- Decision: Treat this plan as a hard dependency for storage, schema, check, lookup, and API work.
  Rationale: Once algorithms and HTTP clients exist, changing these signatures will be expensive. The initial architecture review found the scaffold too narrow for caveats, cursors, consistency resolution, and audit/expand behavior.
  Date: 2026-06-23
- Decision: Keep the EP-1 implementation at the interface layer and leave algorithm bodies as placeholders.
  Rationale: Later child plans own schema validation, tuple storage, forward check, reverse lookup, and expand behavior. EP-1 only needs stable public types and compile coverage so those plans have a target.
  Date: 2026-06-23
- Decision: Use distinct constructor families for caveat parameter types and caveat values.
  Rationale: The initial test used both declarations and values in the same module, which exposed ambiguous constructors. Distinct names make normal client imports work without qualification.
  Date: 2026-06-23


## Outcomes & Retrospective

EP-1 stabilized the `en-core` public interfaces without implementing the later algorithms. Caveats now carry typed tuple payloads and request context, `check` returns `CheckDecision`, `lookup` uses bounded requests and pages, tuple-store reads return paged `TupleRow` values, consistency resolution has an explicit `En.Effect.ConsistencyStore` boundary, and `En.Expand` is exposed. A compile-focused `en-core-interface-tests` suite constructs the kikan-shaped caveated tuple, conditional decision, lookup page, and expand request/tree.

Validation completed 2026-06-23:

```text
cabal build all
cabal test all
1 of 1 test suites (1 of 1 test cases) passed.
```


## Context and Orientation

The repository is a Haskell multi-package Cabal project rooted at `/Users/shinzui/Keikaku/bokuno/en`. The current packages are listed in `cabal.project`: `en-core`, `en-migrations`, `en-postgres`, `en-servant`, `en-server`, and `en-client`.

`en-core` is intended to be transport- and database-agnostic. Its current exposed modules are declared in `en-core/en-core.cabal`. The files relevant to this plan are `en-core/src/En/Schema.hs`, `en-core/src/En/Tuple.hs`, `en-core/src/En/Revision.hs`, `en-core/src/En/Reachability.hs`, `en-core/src/En/Check.hs`, `en-core/src/En/Lookup.hs`, `en-core/src/En/Error.hs`, and `en-core/src/En/Effect/TupleStore.hs`.

A caveat is a bounded condition attached to a tuple or rewrite. The kikan C13 contract requires caveats such as `{autonomy: act, until: 2026-07-01}` on delegation tuples. A caveat is not only a name; it needs stored arguments from the tuple and request context supplied at check time, such as the current time or requested autonomy level.

A consistency token is an opaque value returned by writes and presented on reads to request a snapshot at least as fresh as that write. `en-core/src/En/Revision.hs` currently defines `Revision`, `ConsistencyToken`, and `Consistency`, but it leaves token decoding and freshness resolution implicit.

Lookup is reverse authorization: given a subject and permission, list objects the subject can reach. The design in `docs/spec/0001-en-overview.md` requires bounded, cursorable results because live reverse expansion must not enumerate unbounded object sets.


## Plan of Work

First, revise `En.Tuple` and `En.Schema` so caveats have concrete typed data. Keep the first implementation deliberately small: define a generic caveat value type that can represent text, booleans, timestamps, integers, and ordered enum-like autonomy levels. Define tuple caveat payloads separately from request context so stored grant facts and read-time facts are not conflated.

Next, revise `En.Check` to return a decision ADT instead of `Bool`. The ADT should be able to distinguish an unconditional allow, a deny, and a conditional result that carries missing caveat context or unevaluated caveat obligations. Keep the result type in `en-core` so both embedded library users and Servant handlers share it.

Then revise `En.Lookup` around a page request and page result. The request should carry a limit and optional cursor. The response should carry the returned objects, a next cursor when more results may exist, and an explicit truncation or exhaustion marker. Do not expose an unbounded list API as the primary surface.

Then revise `En.Effect.TupleStore`. Replace the bare `[ObjectRef]` return with a store row or edge type containing at least the object, relation, subject, tuple caveat, and a stable row identity or cursor key if needed for paging. Preserve `readStartingWithUser` as the conceptual primitive, but make it return enough information for caveat evaluation, conditional lookup confirmation, expand, and debugging.

Then introduce a consistency resolver boundary. A practical shape is a new `En.Effect.ConsistencyStore` or a field group on a store environment that can decode a `ConsistencyToken`, validate datastore id and schema hash, check the GC window, compare revisions with a partial order, and resolve `MinimizeLatency`, `AtLeastAsFresh`, `AtExactSnapshot`, and `FullyConsistent` to a concrete `Revision`.

Finally, add `En.Expand` as an exposed module with a placeholder implementation and final result types. `expand(object, permission)` should return a tree or graph-shaped value suitable for review and audit UIs. It can be unimplemented in this plan, but the type must exist so later storage and API plans can target it.


## Concrete Steps

Work from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/en
```

Inspect the current interfaces before editing:

```bash
sed -n '1,220p' en-core/src/En/Tuple.hs
sed -n '1,220p' en-core/src/En/Effect/TupleStore.hs
sed -n '1,180p' en-core/src/En/Check.hs
sed -n '1,180p' en-core/src/En/Lookup.hs
```

Edit the core modules named in the Plan of Work. Add a test suite if the project has one by then; otherwise add small modules or examples only when they are wired into Cabal. Update `en-core/en-core.cabal` to expose any new modules such as `En.Expand` and any new effect module.

Run:

```bash
cabal build all
```

The expected success shape is a normal Cabal build ending with `Building executable 'en-server'` or reporting all components up to date.


## Validation and Acceptance

Acceptance requires more than compilation. A reviewer should be able to read the public `en-core` modules and see that each architecture finding is addressed: caveats have payloads, check is not just `Bool`, lookup is bounded and cursorable, store reads return tuple rows or edges rather than only object refs, consistency resolution is explicit, and `En.Expand` exists.

If tests are added, run:

```bash
cabal test all
```

At minimum, `cabal build all` must pass from a clean checkout. If `cabal test all` has no suites, record that in this plan during implementation rather than treating it as a failure.


## Idempotence and Recovery

The work is additive and signature-changing inside an early scaffold. If later implementation discovers a type needs adjustment, update this plan's Decision Log and change the downstream child plans before committing to algorithm work. Avoid editing generated build artifacts. Do not revert unrelated user changes such as `.seihou/config.dhall`.


## Interfaces and Dependencies

This plan has no hard dependencies. It defines the interfaces consumed by every other child plan in `docs/masterplans/1-build-en-rebac-authorization-toolkit.md`.

The final signatures are implementation decisions, but the following capabilities must exist: a caveat payload type, a request context type, an authorization decision type, a lookup page request/result type, a tuple-store row/edge type, a consistency resolution boundary, and an expand result type.


Revision note 2026-06-23: Added `intention_01kvsbcvsfepaafp5x44ykby47` to the plan frontmatter at the user's request.

Revision note 2026-06-23: Implemented EP-1 by replacing the placeholder core interfaces with typed caveat, check, lookup, tuple-store, consistency, and expand surfaces, then added compile-focused interface coverage.
