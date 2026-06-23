---
id: 4
slug: harden-the-en-schema-dsl-for-release
title: "Harden the en schema DSL for release"
kind: master-plan
created_at: 2026-06-23T21:42:59Z
intention: "intention_01kvv6xk57em8tq254tz5zm8r0"
---

# Harden the en schema DSL for release

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

`en` is a schema-parametric, Zanzibar-style relationship-based authorization toolkit:
the consuming project supplies an authorization model as a `Schema` *value*, and the
engine validates it, hashes it into consistency-token metadata, and compiles it into a
reachability graph that `check`/`lookup`/`expand` traverse. Today that schema is authored
through `En.Schema.Builder` (see `en-core/src/En/Schema/Builder.hs`), a thin value-level
combinator DSL: `object "space" [relation "member" [subject "user"] this, permission
"view" (anyOf (computed "owner") [...])]`. The builder is ergonomically pleasant but
defers every correctness check to a runtime `validate` pass, and it has at least one
soundness gap (silent duplicate-name dropping) that is unacceptable in an authorization
model where a dropped relation is a security hole.

This initiative hardens that DSL for its initial public release. A deliberate
architectural decision anchors the whole effort: **the schema stays a value-level data
structure; we do not move to a type-level DSL.** The reasons are recorded in the Decision
Log. The win is concentrated where it matters — soundness of the builder, a type that
proves a schema was validated, an optional compile-time authoring path that rejects typos
before runtime, ergonomic refinements that make invalid models harder to express, and a
renderer that turns the schema value into human-facing documentation and diagrams.

After this initiative, a `Schema` author can: trust that the builder never silently drops
a duplicated object/relation/caveat/parameter and instead reports it; carry a
`ValidSchema` value whose existence is evidence that validation succeeded, demanded by
`compile` and consistency-token hashing so an unvalidated schema cannot reach the engine;
optionally author a schema with a compile-time-checked quasi-quoter so a misspelled
relation or unknown caveat fails the build, not the first request; rely on the builder to
make a handful of always-invalid shapes (a permission whose rewrite is bare `this`)
unrepresentable; and generate a Mermaid diagram and a Markdown reference of any schema or
its compiled reachability graph with a single function call.

In scope: `en-core` schema authoring, validation-evidence typing, an opt-in
Template-Haskell authoring path, builder ergonomics, and a pure renderer module, plus the
documentation and the single `en-server` call site that consume these. Explicitly out of
scope: any change to the wire protocol, the PostgreSQL store, the on-the-fly evaluation
semantics of `check`/`lookup`/`expand`, the consistency-token *format* (only the type that
feeds `schemaHash` may change), and any type-level encoding of the schema. Non-Haskell or
runtime-loaded schemas must keep working unchanged; nothing here may make the value-level
`Schema` harder to construct programmatically or to load from a future external source.


## Decomposition Strategy

The work splits into five functional concerns, each independently verifiable, ordered so
the foundational soundness fix lands first and the higher-level authoring and rendering
layers build on a stable core. The guiding principle was to separate *soundness of the
existing builder* (a bug fix that must not wait) from *new type-safety surface*
(`ValidSchema`), from *new authoring syntax* (the quasi-quoter), from *ergonomic
refinements* (small builder changes), from *output generation* (rendering). Each concern
touches a different primary surface, so they can be reviewed and shipped on their own.

`EP-20 (duplicate detection)` is first because it is a correctness bug in the current
builder and because the compile-time authoring path in `EP-22` should reject duplicates
at compile time too, so the duplicate-detection logic must exist before the quasi-quoter
consumes it. `EP-21 (validated-schema evidence type)` introduces the `ValidSchema`
newtype and threads it through `compile`/`schemaHash`; it changes the core API's central
type signatures, so it is the natural integration spine that `EP-22` and `EP-24` consume.
`EP-22 (compile-time quasi-quoter)` is the most speculative and the only one that adds a
new dependency (`template-haskell`); it is deliberately last in the hard-dependency chain
and carries an explicit prototyping milestone, so if it proves too costly it can be cut
without disturbing the others. `EP-23 (ergonomics & reference safety)` and `EP-24
(rendering)` are leaf concerns that depend only softly on the spine and can proceed in
parallel once the core types are stable.

An alternative decomposition — one plan per file, or a single "harden the DSL" megaplan —
was rejected. A megaplan would exceed the ExecPlan size guidance (more than five
milestones across unrelated modules) and would couple a security-relevant bug fix to a
speculative TH feature, blocking the release on the riskiest piece. Splitting by file
would have put `Builder.hs` changes from `EP-20` and `EP-23` in the same plan despite
their being different concerns (soundness vs. ergonomics), and would have scattered the
`ValidSchema` change across every consumer's plan instead of owning it in one.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 20 | Detect duplicate names in the schema builder | docs/plans/20-detect-duplicate-names-in-the-schema-builder.md | None | None | Not Started |
| 21 | Introduce a validated-schema evidence type | docs/plans/21-introduce-a-validated-schema-evidence-type.md | None | EP-20 | Not Started |
| 22 | Add a compile-time schema quasi-quoter | docs/plans/22-add-a-compile-time-schema-quasi-quoter.md | EP-21 | EP-20 | Not Started |
| 23 | Polish builder ergonomics and reference safety | docs/plans/23-polish-builder-ergonomics-and-reference-safety.md | None | EP-20 | Not Started |
| 24 | Render schemas as docs and diagrams | docs/plans/24-render-schemas-as-docs-and-diagrams.md | None | EP-21 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

`EP-20` has no dependencies and should land first; it is a self-contained soundness fix in
`En.Schema.Builder`. `EP-21` has a soft dependency on `EP-20`: both touch the
build-then-validate boundary, and `ValidSchema` is most coherent if duplicate detection is
already a validation-time guarantee, but `EP-21` does not need `EP-20`'s code to compile.
`EP-22` has a hard dependency on `EP-21` because the quasi-quoter's whole purpose is to
splice a `ValidSchema` (a schema proven valid at compile time), so the type must exist
first; it also softly depends on `EP-20` so the compile-time path rejects duplicates.
`EP-23` softly depends on `EP-20` only because both edit `En.Schema.Builder` and should be
sequenced to avoid textual conflicts; its behavior is independent. `EP-24` softly depends
on `EP-21` because the renderer should accept whatever the canonical validated-schema type
is, but it can render a plain `Schema` if `EP-21` is not yet merged.

Parallelism: once `EP-20` is complete, `EP-21`, `EP-23`, and `EP-24` can proceed
concurrently (different primary files: the core `En.Schema`/`compile` spine, the builder
ergonomics, and a new renderer module). `EP-22` must wait for `EP-21`. The critical path
is `EP-20 → EP-21 → EP-22`.


## Integration Points

The build → validate → `ValidSchema` → `compile`/`schemaHash` pipeline is the central
shared artifact. `EP-21` owns it: it defines `ValidSchema` (a newtype over `Schema`
produced only by `validate`/the builder's validating entry point) and changes
`En.Reachability.compile` and `En.Schema.schemaHash`'s callers to demand it. `EP-22`
consumes `ValidSchema` as the type its quasi-quoter splices. `EP-24` consumes it as the
input type for rendering. The single non-test consumer of `compile` and `schemaHash`
today is `en-server/app/Main.hs` (lines 28 and 42); `EP-21` is responsible for updating
it, and `EP-22`/`EP-24` must not re-change that call site.

The `EnError` value used to report a duplicate name is a shared artifact between `EP-20`
and `EP-22`. `EP-20` owns the choice (reuse `SchemaViolation Text` from
`en-core/src/En/Error.hs`, or add a dedicated constructor); `EP-22` must surface that same
error as a compile-time TH error rather than inventing its own wording.

The `En.Schema.Builder` module is a shared file between `EP-20` (duplicate detection in
`build`/`object`/`caveat`) and `EP-23` (a non-`this` `permission`, handle-style
references). They must agree on the module's export list and not redefine the same
helper; sequencing `EP-20` before `EP-23` keeps the diffs clean.

`En.Schema.Internal` (and a supporting `En.Schema.Types`) is a shared artifact between
`EP-21` and `EP-22`. `EP-21`'s `ValidSchema` constructor is hidden in the public
`En.Schema` so that only `validateSchema` can produce the evidence value. But `EP-22`'s
Template-Haskell splice must reconstruct a `ValidSchema` at the user's splice site, and a
hidden constructor cannot be referenced there. `EP-21` therefore owns a three-module
layout: `En.Schema.Types` holds the bare `Schema (..)` data declarations (factored out to
avoid an import cycle, since `ValidSchema` wraps `Schema`); `En.Schema.Internal` is the
unsafe surface that defines and exports `ValidSchema (..)`, `unValidSchema`, and
`unsafeValidSchema :: Schema -> ValidSchema`; and the public `En.Schema` re-exports
`Schema (..)`, the `ValidSchema` *type only* (no constructor), `unValidSchema`,
`validate`, `validateSchema`, and `schemaHash :: ValidSchema -> SchemaHash`. `EP-22`
consumes `En.Schema.Internal` by lifting the *inner* `Schema` (via its `Lift` instance)
and wrapping with the internal constructor, so it never needs a `Lift ValidSchema`; the
compile-time `validateSchema` still runs before the wrap, preserving the guarantee.
Ordinary consumers import `En.Schema` and cannot fabricate a `ValidSchema`. The
`En.Schema.Types` refactor must keep `En.Schema`'s existing re-exports intact so no
current call site (`En.Reachability`, `En.Check`, `En.Lookup`, `En.Expand`, the builder)
breaks.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [ ] EP-20: Builder rejects duplicate object/relation/caveat/parameter names with an `EnError`
- [ ] EP-20: Tests prove each duplicate class is reported rather than silently dropped
- [ ] EP-21: `ValidSchema` newtype defined; `validate` (and a validating builder entry point) produce it
- [ ] EP-21: `compile`/`schemaHash` consumers demand `ValidSchema`; `en-server` call site updated
- [ ] EP-22: Prototype a quasi-quoter that parses a compact schema syntax and runs `validate` at compile time
- [ ] EP-22: `[schema| … |]` splices a `ValidSchema` and fails the build on unknown relations/caveats/duplicates
- [ ] EP-23: `permission` cannot be given a bare `this`; intra-object references can be made by handle
- [ ] EP-23: Builder docs updated; always-invalid shapes are unrepresentable through the builder
- [ ] EP-24: `En.Schema.Render` folds a schema into a Mermaid diagram
- [ ] EP-24: `En.Schema.Render` folds a schema (and/or its reachability graph) into a Markdown reference


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- Discovery (during decomposition): hiding the `ValidSchema` constructor (EP-21) collides
  with EP-22's Template-Haskell splice. A derived `Lift ValidSchema` emits code naming the
  constructor at the user's splice site, where it is out of scope, so the build would fail.
  Resolution: EP-21 exposes an `En.Schema.Internal` escape hatch; EP-22 lifts the inner
  `Schema` and wraps it through that internal constructor (never `Lift ValidSchema`), with
  compile-time `validateSchema` still gating the wrap. Recorded as a new Integration Point
  and reconciled into both child plans before implementation began.
  Date: 2026-06-23

- Note for implementers: EP-23 makes the rewrite combinators (`computed`, `arrow`,
  `anyOf`, etc.) return-polymorphic so `permission` can reject a bare `this` at compile
  time. EP-22 (approach B) reuses the builder surface to construct schemas for the TH path;
  type inference should still resolve those combinators, but EP-22's implementer should
  build against EP-23's combinator signatures if both have merged. Not a hard conflict;
  flagged so the interaction is not a surprise at integration time.
  Date: 2026-06-23


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Keep the schema value-level; do not replace the DSL with a type-level encoding.
  Rationale: `en` is schema-parametric and ships as a standalone service. The `Schema`
  value is hashed into consistency tokens, compiled to a reachability graph, loaded by
  `en-server`, and exchanged with `en-client`; a type-level schema would benefit only the
  single Haskell consumer that authors its model in source and would still have to be
  reified to a value for hashing, compilation, and the wire — an extra layer, not a
  replacement. The invariants worth catching (productive-cycle detection in
  `validateProductiveCycles`, arrow target compatibility) are graph-global fixpoint
  properties that no practical type-level encoding catches without a type-level graph
  solver, so a runtime `validate` is required regardless. Type-level encodings also make
  documentation and diagram generation *harder* (they must reflect types back into
  values), whereas value-level data is already the ideal IR for the renderer in EP-24.
  The genuine type-level win — statically checking `check`/`lookup` call sites against a
  schema — requires the schema known at compile time, which the service cannot have; it
  belongs in a future opt-in companion, not the v1 core.
  Date: 2026-06-23

- Decision: Decompose into five plans — duplicate detection, validated-schema evidence
  type, compile-time quasi-quoter, ergonomics/reference safety, and rendering — rather
  than one megaplan or a per-file split.
  Rationale: separates a security-relevant soundness bug (EP-20) from new type surface
  (EP-21), speculative new syntax (EP-22), small refinements (EP-23), and output
  generation (EP-24), so the release is not gated on the riskiest piece and each concern
  is independently verifiable. See the Decomposition Strategy section.
  Date: 2026-06-23

- Decision: The compile-time authoring path (EP-22, Template Haskell) is opt-in and the
  last link in the hard-dependency chain, with an explicit prototyping milestone.
  Rationale: it is the only plan that adds a dependency (`template-haskell`) and the most
  likely to be cut on cost/benefit grounds; isolating it keeps the rest of the initiative
  shippable if it is deferred.
  Date: 2026-06-23


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

(To be filled during and after implementation.)
