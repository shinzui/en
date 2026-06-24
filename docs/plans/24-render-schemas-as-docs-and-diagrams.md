---
id: 24
slug: render-schemas-as-docs-and-diagrams
title: "Render schemas as docs and diagrams"
kind: exec-plan
created_at: 2026-06-23T21:43:10Z
intention: "intention_01kvv6xk57em8tq254tz5zm8r0"
master_plan: "docs/masterplans/4-harden-the-en-schema-dsl-for-release.md"
---

# Render schemas as docs and diagrams

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`en` is a Zanzibar-style relationship-based authorization toolkit. The authorization model a
consuming project supplies — its object types, relations, permission rewrite rules, and
caveats — is an ordinary Haskell value of type `Schema`, defined in
`en-core/src/En/Schema.hs`. Today that value is something you can `check` and `lookup`
against, but you cannot *see* it: there is no way to look at a `Schema` and get a picture of
"which object can reach which other object through which relation," nor a readable reference
of "what does the `view` permission on a `space` actually expand to."

After this change, a consumer can call two pure functions on their schema value and get
human-facing artifacts back: a Mermaid diagram (text that a Markdown viewer, GitHub, or
mermaid.live renders as a node-and-arrow graph) and a Markdown reference document (a section
per object type that lists every relation, its allowed subjects, and a one-line reading of
its rewrite, plus a section describing every caveat). Concretely, a user writes
`renderMermaid mySchema` to get a `.mmd` diagram and `renderMarkdown mySchema` to get a `.md`
reference, writes the text to a file, and either pastes it into a Mermaid renderer or commits
it next to their code as living documentation. They can see the result working by pasting the
emitted Mermaid into <https://mermaid.live> and observing the `space --owner--> user`,
`space --parent--> space`, and arrow edges appear.

The deeper point — and the reason this plan is the concrete payoff of the master plan
`docs/masterplans/4-harden-the-en-schema-dsl-for-release.md` — is *why this is so easy*. The
`en` DSL is **value-level**: a `Schema` is data, a `Map ObjectType (Map RelationName
Relation)` plus a `Map CaveatName CaveatDefinition`. Generating documentation or a diagram is
therefore nothing more than a **pure fold** over that value: walk the maps, walk each
`Rewrite` tree, and emit text. The file `en-core/src/En/Schema.hs` already contains exactly
such a fold — `renderSchema :: Schema -> Text` (around line 362) — which it uses to compute a
deterministic fingerprint for consistency tokens. That existing function is the proof that
the fold is trivial and is the template for the traversal we add here. (We do **not** reuse
`renderSchema` for human output: it emits a canonical, length-prefixed hashing form like
`12#some_object`, which is unreadable on purpose. We write new, human-legible renderers that
share its traversal *shape* but not its formatting.)

Contrast this with a *type-level* DSL, where object types and relations are encoded in
Haskell's type system. There, "render the schema" would require reflecting type-level
information back down into runtime values (type families, `Typeable`, singletons, or
`GHC.Generics` plumbing) before you could fold over anything — strictly more machinery to do
strictly the same job. This plan is the demonstration that keeping the DSL value-level was the
right call: documentation and diagrams fall out for free as a one-page pure module with no new
dependencies.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] 2026-06-24: Read `en-core/src/En/Schema.hs`, `en-core/src/En/Reachability.hs`, and the
  `kikanSchema` fixture in `en-core/test/Main.hs` to confirm the types and ordering this plan
  assumes still hold.
- [x] 2026-06-24: Create `en-core/src/En/Schema/Render.hs` exporting `renderMarkdown`, `renderMermaid`,
  and `renderReachabilityMermaid` (signatures in Interfaces and Dependencies).
- [x] 2026-06-24: Implement the rewrite-to-readable-string fold (shared helper) used by both renderers.
- [x] 2026-06-24: Implement `renderMarkdown :: Schema -> Text`.
- [x] 2026-06-24: Implement `renderMermaid :: Schema -> Text`.
- [x] 2026-06-24: Implement `renderReachabilityMermaid :: ReachabilityGraph -> Text`.
- [x] 2026-06-24: Add `En.Schema.Render` to the `exposed-modules` list in `en-core/en-core.cabal`.
- [x] 2026-06-24: Add golden tests to `en-core/test/Main.hs` asserting `renderMermaid kikanSchema` and
  `renderMarkdown kikanSchema` equal embedded expected `Text`.
- [x] 2026-06-24: Add a "Visualize your schema" section to `docs/user/modeling.md` showing the emitted
  Mermaid for `kikanSchema`.
- [x] 2026-06-24: Run `nix develop --command cabal build all` and
  `nix develop --command cabal test en-core-interface-tests`; confirm both pass.
- [x] 2026-06-24: Confirm the emitted Mermaid is committed in `docs/user/modeling.md`; no local
  Mermaid CLI (`mmdc`/`mermaid`) is installed, and no new renderer dependency was added.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery: the hand-written ordering in this plan was illustrative, not the actual golden
  order. `Map.toAscList` sorts `space` relations alphabetically as `act`, `audit`,
  `guest_org`, `member`, `member_not_owner`, `owner`, `parent`, `view`, `visibility_class`.
  Evidence: generated `renderMarkdown kikanSchema` and `renderMermaid kikanSchema` with
  `ghc -e` after implementing the renderer and embedded that output in the golden tests.
  Date: 2026-06-24

- Discovery: no local Mermaid CLI is installed (`command -v mmdc` and `command -v mermaid`
  both exit non-zero). The implementation keeps the no-new-dependencies decision and validates
  the diagram text through deterministic golden tests plus the committed Mermaid block in
  `docs/user/modeling.md`.
  Date: 2026-06-24


## Decision Log

Record every decision made while working on the plan.

- Decision: Render from `Schema` directly for both `renderMarkdown` and `renderMermaid`, and
  add a separate `renderReachabilityMermaid :: ReachabilityGraph -> Text` rather than only one
  graph-based renderer.
  Rationale: Rendering documentation does not require a *valid* schema, so it must not depend
  on validation or compilation; a user mid-edit with a slightly broken schema still benefits
  from a diagram. The `Schema`-based renderers therefore stand alone with no dependency on
  `compile` or on EP-21's `ValidSchema`. The reachability variant is offered as well because
  `ReachabilityGraph.entries` is *already* an edge set with the rewrite paths fully expanded
  (e.g. it resolves `view` down to the concrete subject types that can reach it), which makes a
  "who can ultimately reach what" diagram trivial — a different and complementary view from the
  syntactic per-relation diagram.
  Date: 2026-06-23

- Decision: Do not reuse `renderSchema` from `En.Schema`.
  Rationale: `renderSchema` is a canonical *hashing* form (length-prefixed, `:`/`|`/`,`
  delimited) tuned for a stable fingerprint, not for humans. Reusing it would couple human
  output to the hash format and make either one hard to change. We write fresh renderers that
  copy its *traversal* (the `Map.toAscList` / `Set.toAscList` ordering and the `Rewrite`
  case-split) but not its formatting.
  Date: 2026-06-23

- Decision: Add no new build dependencies; use only `text` and `containers` (both already
  present).
  Rationale: The renderer is a string fold. Pulling in a Mermaid or diagram library would
  contradict the whole point — that diagrams fall out of the value-level model for free.
  Date: 2026-06-23

- Decision: Mark caveated edges in the diagram with a parenthetical caveat note on the edge
  label (e.g. `intention -. "delegate (within_autonomy)" .-> user` using a dotted Mermaid
  edge), and never crash on caveats.
  Rationale: Caveats are a real, visible part of the model; a reader scanning the diagram
  should be able to tell a conditional edge from an unconditional one at a glance.
  Date: 2026-06-23

- Decision: Use stable generated Mermaid ids such as `object_space` rather than raw object
  names as ids.
  Rationale: Kikan object names happen to be Mermaid-safe, but a general renderer should handle
  punctuation and other non-id characters without producing invalid graph syntax. The visible
  node labels remain the original object type names.
  Date: 2026-06-24


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

Completed on 2026-06-24. `En.Schema.Render` now exposes pure `renderMarkdown`,
`renderMermaid`, and `renderReachabilityMermaid` folds. The two schema renderers are covered
by Kikan golden tests in `en-core-interface-tests`, and `docs/user/modeling.md` includes the
generated Mermaid block plus write-to-file examples. The reachability renderer is implemented
as the complementary resolved-graph view over `ReachabilityGraph.entries`.

Validation evidence:

```bash
nix develop --command cabal build all
nix develop --command cabal test en-core-interface-tests
```

Both pass. Visual rendering was not automated because no Mermaid CLI is installed and this
plan explicitly avoids adding a renderer dependency.


## Context and Orientation

This section assumes you have never seen this repository. Here is everything you need.

The repository root is `/Users/shinzui/Keikaku/bokuno/en`. The package you will edit is
`en-core`, whose Cabal file is `en-core/en-core.cabal`, library sources under
`en-core/src/En/`, and test under `en-core/test/Main.hs`. The build tool is `cabal`; the test
suite is named `en-core-interface-tests`.

The single most important file is `en-core/src/En/Schema.hs`. It defines the value-level
authorization model. The relevant types, in plain language:

- `Schema` is a record with two fields. `objectTypes :: Map ObjectType (Map RelationName
  Relation)` maps each object type (a `newtype ObjectType` wrapping `Text`, e.g. `space`) to
  its relations, keyed by `RelationName` (also a `Text` newtype, e.g. `owner`). `caveats ::
  Map CaveatName CaveatDefinition` lists the named conditions that can gate a relation.
- A `Relation` has `relationName :: RelationName`, `allowedSubjects :: Set AllowedSubject`
  (the subject shapes that may be written directly into this relation as tuples), and
  `rewrite :: Rewrite` (how the relation's effective members are computed).
- An `AllowedSubject` has `objectType :: ObjectType` and `relation :: Maybe RelationName`.
  When `relation` is `Nothing` it means a concrete subject like `user:alice`; when it is
  `Just r` it means a *userset* subject like `org:acme#member` — "every member of org acme."
- A `Rewrite` is a small expression tree. Its constructors are: `This` (the directly written
  tuples on this relation); `ComputedUserset RelationName` (the members of another relation on
  the *same* object, e.g. `view` includes `owner`); `TupleToUserset tupleset computed` (an
  *arrow*: follow the `tupleset` relation to another object, then take that object's `computed`
  relation — e.g. `parent→view` means "anyone who can view the parent space"); `Union
  [Rewrite]` (any branch grants); `Intersection [Rewrite]` (every branch must grant);
  `Exclusion a b` ("a but not b"); and `Caveated CaveatName Rewrite` (the inner rewrite gated
  by a named condition).
- A `CaveatDefinition` has `name :: CaveatName`, `parameters :: Map CaveatParameterName
  CaveatParameterType`, and `predicate :: CaveatPredicate`. For this plan you only need the
  name and the parameters (and their types: `ParameterText`, `ParameterBool`,
  `ParameterInteger`, `ParameterTimestamp`, `ParameterEnum [Text]`); you do not need to render
  the predicate expression in full.

Crucially, `En/Schema.hs` already contains `renderSchema :: Schema -> Text` (around line 362).
It folds the whole schema into a canonical string for hashing. Read it: it is your template.
Notice it always traverses with `Map.toAscList` and `Set.toAscList`, which gives a *stable*,
sorted ordering independent of how the maps were built. Your renderers must do the same so
their output is deterministic and golden-testable.

The second relevant file is `en-core/src/En/Reachability.hs`. The function `compile :: Schema
-> Either EnError ReachabilityGraph` turns a schema into a `ReachabilityGraph`. That graph's
`entries :: Map RelationRef [EntryPoint]` is already an edge set: for each target
`RelationRef` (an `objectType` + `relation` pair) it lists the `EntryPoint`s that can reach
it. An `EntryPoint` has `source :: SubjectSelector` (an `objectType` + `Maybe relation`), a
`kind :: EntryKind` (`Direct` or `Conditional`), and `caveats :: [CaveatName]`. Because
`compile` *expands* rewrites — it resolves `space#view` all the way down to the concrete
subject types that can reach it — `entries` captures the fully-resolved "who can reach what"
relation, which is the basis for `renderReachabilityMermaid`.

The golden fixture you will render in tests lives in `en-core/test/Main.hs`: `kikanSchema`
(around line 307). It has object types `user` (no relations), `org` (relation `member`),
`visibility_class` (relation `viewer`), `space` (relations `owner`, `member`, `guest_org`,
`parent`, `visibility_class` and permissions `view`, `act`, `audit`, `member_not_owner`), and
`intention` (relation `delegate`, permission `view`). It declares one caveat, `within_autonomy`,
with parameters `requested_autonomy` and `autonomy` (both enums) and `current_time` and
`until` (both timestamps). The fixture's `intention#delegate` is **not** caveated in
`kikanSchema` itself (the caveat is only declared); the diagram still shows the
`within_autonomy` caveat exists via the Markdown caveats section. (A separate snippet in
`docs/user/modeling.md` shows a caveated `delegate` for illustration; do not confuse the two.)

Two terms of art used below, defined once: a **fold** is a function that walks a data
structure and accumulates a result — here, walking the schema maps and building up `Text`. A
**Mermaid diagram** is plain text in a small graph language; tools like GitHub, VS Code, and
mermaid.live turn lines such as `space --owner--> user` into drawn boxes and arrows.


## Plan of Work

The work is one new module, one Cabal line, two golden tests, and one docs section. It is
small enough to do in a single milestone, but it is described below as three checkpoints so a
novice can verify progress incrementally.

**Milestone 1 — the renderer module compiles.** Create
`en-core/src/En/Schema/Render.hs` with module header `module En.Schema.Render (renderMarkdown,
renderMermaid, renderReachabilityMermaid) where`. Import `Data.Text` (qualified as `Text`),
`Data.Map.Strict` (qualified as `Map`), `Data.Set` (qualified as `Set`), and the schema and
reachability types from `En.Schema` and `En.Reachability`. Because the package enables
`OverloadedStrings`, `LambdaCase`, and `OverloadedRecordDot` by default (see the `common
shared` stanza in `en-core/en-core.cabal`), you can write string literals as `Text`, use
`\case`, and use `record.field` accessors directly.

First write the shared helper that turns a `Rewrite` into a readable one-line string, because
both renderers use it. The mapping is:

- `This` → `"<self>"` (direct tuples; in context the relation's allowed subjects are shown
  separately, so `This` alone reads as "directly assigned").
- `ComputedUserset r` → the relation name `r` (e.g. `owner`).
- `TupleToUserset tupleset computed` → `tupleset <> "→" <> computed` (e.g. `parent→view`).
- `Union rs` → the rendered branches joined with `" ∪ "`.
- `Intersection rs` → branches joined with `" ∩ "`.
- `Exclusion a b` → `a <> " ∖ " <> b`.
- `Caveated c r` → `r <> " [" <> c <> "]"` (the inner rewrite, then the caveat in brackets).

Then add `En.Schema.Render` to the `exposed-modules` list in `en-core/en-core.cabal` (it is an
alphabetized list; insert it between `En.Reachability`/`En.Revision` region appropriately, but
exact position does not matter to Cabal). Run `cabal build all`. Acceptance: the package
compiles with no warnings (the library uses `-Wall -Werror`-adjacent flags via the `warnings`
common stanza; keep the module warning-clean — no unused imports).

**Milestone 2 — the two `Schema` renderers produce the expected text.** Implement
`renderMarkdown` and `renderMermaid` as folds over `schema.objectTypes` (via
`Map.toAscList`) and `schema.caveats`. `renderMarkdown` emits one `## <objectType>` section
per object type, and within it one bullet per relation reading `**<relation>** — subjects:
<allowed subjects>; rule: <readable rewrite>`, followed by a `## Caveats` section. `renderMermaid`
emits `flowchart LR`, then one declared node per object type, then one edge per relation. Use
`Map.toAscList`/`Set.toAscList` everywhere for determinism. Add the two golden tests (see
Concrete Steps for the exact expected strings) to `en-core/test/Main.hs`. Acceptance: `cabal
test en-core-interface-tests` passes.

**Milestone 3 — docs and visual confirmation.** Add a "Visualize your schema" section to
`docs/user/modeling.md` containing the emitted Mermaid for `kikanSchema` in a ` ```mermaid `
fenced block, plus a one-paragraph note on how to write it to a file. Paste the emitted
Mermaid into <https://mermaid.live> and confirm it draws the object/relation graph. Acceptance:
the diagram renders and shows `space` with arrows to `user`, `org`, `space` (self via
`parent`), and `visibility_class`.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/en`.

Create the module file `en-core/src/En/Schema/Render.hs`. The traversal is a direct copy of
the shape in `renderSchema`; only the formatting differs. The Mermaid edge encoding is: each
relation on an object type produces edges to the things it references. A `This` relation with
allowed subjects draws a solid edge to each allowed subject's object type, labelled with the
relation name (and `#rel` appended when the allowed subject is a userset). A `ComputedUserset`,
`TupleToUserset`, `Union`/`Intersection`/`Exclusion`, or `Caveated` permission draws edges
derived from its readable rewrite string, with caveated edges drawn dotted (`-. "label" .->`).

The renderer must emit, for the `kikanSchema` fixture, exactly this Mermaid (object types in
ascending order `intention, org, space, user, visibility_class`; relations within each in
ascending order). Show this in the plan so a reader can eyeball it:

```text
flowchart LR
  object_intention["intention"]
  object_org["org"]
  object_space["space"]
  object_user["user"]
  object_visibility_class["visibility_class"]
  object_intention -->|delegate| object_user
  object_intention -->|"view = delegate"| object_intention
  object_org -->|member| object_user
  object_space -->|"act = owner ∪ member"| object_space
  object_space -->|"audit = owner ∩ member"| object_space
  object_space -->|guest_org| object_org
  object_space -->|"member (org#member)"| object_org
  object_space -->|member| object_user
  object_space -->|"member_not_owner = member ∖ owner"| object_space
  object_space -->|owner| object_user
  object_space -->|parent| object_space
  object_space -->|"view = owner ∪ member ∪ guest_org→member ∪ parent→view ∪ visibility_class→viewer"| object_space
  object_space -->|visibility_class| object_visibility_class
  object_visibility_class -->|viewer| object_user
```

The encoding choices, stated so a reader can reproduce them: a relation whose rewrite is `This`
draws one labelled edge per allowed subject, from the owning object type to the subject's
object type, label = the relation name; when the allowed subject is a userset (`relation =
Just r`), the label gains a `" (objectType#r)"` suffix so the reader sees `space
--"member (org#member)"--> org`. A relation whose rewrite is not `This` (a computed permission)
draws a single self-edge from the owning object type back to itself, labelled
`"<relation> = <readable rewrite>"`, because a computed permission is a derived membership *on
the same object*. Caveated edges are drawn with Mermaid's dotted-arrow syntax and the caveat
name in the label; the `kikanSchema` fixture has no caveated relation, so all its edges are
solid (the dotted form is exercised by the modeling-doc snippet and can be covered by a focused
unit assertion).

The renderer must emit, for the same fixture, exactly this Markdown. Show it in the plan:

```text
# Schema reference

## intention

- **delegate** — subjects: user; rule: directly assigned
- **view** — subjects: (none); rule: delegate

## org

- **member** — subjects: user; rule: directly assigned

## space

- **act** — subjects: (none); rule: owner ∪ member
- **audit** — subjects: (none); rule: owner ∩ member
- **guest_org** — subjects: org; rule: directly assigned
- **member** — subjects: org#member, user; rule: directly assigned
- **member_not_owner** — subjects: (none); rule: member ∖ owner
- **owner** — subjects: user; rule: directly assigned
- **parent** — subjects: space; rule: directly assigned
- **view** — subjects: (none); rule: owner ∪ member ∪ guest_org→member ∪ parent→view ∪ visibility_class→viewer
- **visibility_class** — subjects: visibility_class; rule: directly assigned

## user

(no relations)

## visibility_class

- **viewer** — subjects: user; rule: directly assigned

## Caveats

- **within_autonomy** — parameters: autonomy: enum[act, admin, read], current_time: timestamp, requested_autonomy: enum[act, read], until: timestamp
```

Note two formatting details the golden output above commits to. First, within `## space` the
relations are listed in ascending `RelationName` order, which puts the `view`/`act`/`audit`/
`member_not_owner` permissions after the stored relations only because their names sort that
way relative to the others — verify the exact order against `Map.toAscList` when you implement;
the order shown is `owner, member, guest_org, parent, visibility_class, view, act, audit,
member_not_owner` if the builder preserves insertion, but `Map RelationName` is **sorted**, so
the *actual* emitted order is alphabetical: `act, audit, guest_org, member, member_not_owner,
owner, parent, view, visibility_class`. **Implement against `Map.toAscList` and regenerate the
expected strings from the real output** rather than trusting the hand-written order above; the
blocks here are illustrative of *format*, and the test must embed whatever the deterministic
sorted fold actually produces. Second, enum parameter values are rendered sorted and
deduplicated (`enum[act, admin, read]`), matching how `renderSchema` already normalizes enums
with `Set.toAscList (Set.fromList values)`.

Because the exact alphabetical ordering is easy to get subtly wrong by hand, the recommended
way to produce the golden strings is to implement the renderers, then run a tiny throwaway
expression in `cabal repl` to print `renderMarkdown kikanSchema` and `renderMermaid
kikanSchema`, and paste the verified output into both the test file and this plan. Update the
two ` ```text ` blocks above to match the real output as part of finishing the work, and note
the correction in Decision Log.

Add the module to Cabal. Edit `en-core/en-core.cabal`, in the library `exposed-modules` list,
adding the line `En.Schema.Render` (alphabetical placement after `En.Schema.Builder`):

```diff
     En.Schema
     En.Schema.Builder
+    En.Schema.Render
     En.Tuple
```

Add the golden tests. In `en-core/test/Main.hs`, import `En.Schema.Render (renderMarkdown,
renderMermaid)` and add two test cases that assert equality against the embedded expected
`Text` (use the project's existing assertion style — read the top of `Main.hs` to match how
other equality tests are written). Embed the expected strings verified from the repl.

Build and test:

```bash
cabal build all
cabal test en-core-interface-tests
```

Expected: the build completes warning-clean and the test suite reports all tests passing,
including the two new render golden tests, for example:

```text
en-core-interface-tests: PASS
All N tests passed
```

Finally, add the docs section to `docs/user/modeling.md` (append a new `## Visualize your
schema` section) with the verified Mermaid in a ` ```mermaid ` block and a short note:

```text
## Visualize your schema

Because a `Schema` is an ordinary value, `En.Schema.Render` folds it into a Mermaid diagram
and a Markdown reference with no extra dependencies:

    import En.Schema.Render (renderMermaid, renderMarkdown)
    import qualified Data.Text.IO as Text

    Text.writeFile "schema.mmd" (renderMermaid mySchema)
    Text.writeFile "schema.md"  (renderMarkdown mySchema)

Paste schema.mmd into https://mermaid.live to see the object/relation graph.
```


## Validation and Acceptance

Acceptance is behavioral, not "code exists." There are three checks.

First, the build is clean: from the repository root, `cabal build all` completes with no
errors and no warnings introduced by the new module (the library compiles under the strict
warning flags in the `warnings` common stanza of `en-core/en-core.cabal`).

Second, the golden tests pass: `cabal test en-core-interface-tests` reports all tests passing.
The two new tests assert that `renderMarkdown kikanSchema` and `renderMermaid kikanSchema`
equal the exact `Text` embedded in `en-core/test/Main.hs`. These tests prove the renderers
produce *specific, deterministic* output — not merely that they run. To convince yourself they
are meaningful, temporarily change one character in an expected string and observe the test
fail with a clear diff, then revert.

Third, visual confirmation: copy the Mermaid text from the new section in
`docs/user/modeling.md` and paste it into <https://mermaid.live> (or open the Markdown file in
any Mermaid-aware viewer such as GitHub). You should see five boxes — `intention`, `org`,
`space`, `user`, `visibility_class` — with labelled arrows: `space` to `user` (owner, member),
`space` to `org` (member userset, guest_org), a self-loop on `space` (parent, and the computed
`view`/`act`/`audit`/`member_not_owner` permissions), `space` to `visibility_class`, `org` to
`user` (member), and `intention` to `user` (delegate) plus a self-loop for `view`. Seeing this
graph is the proof that a value-level schema renders to a real diagram with a one-page fold.


## Idempotence and Recovery

Every step here is additive and safe to repeat. Creating
`en-core/src/En/Schema/Render.hs` is a new file; re-running the build after creating it is
harmless. Adding the `En.Schema.Render` line to `en-core/en-core.cabal` is idempotent if you
check the list first — adding it twice would be a duplicate-module Cabal error, so confirm it
appears exactly once. The golden tests are pure equality assertions with no side effects; they
can run any number of times. The docs edit appends a section; if you re-run it, ensure you do
not append the section twice (search `docs/user/modeling.md` for "Visualize your schema"
first).

If a golden test fails because the expected string drifted from the real output (most likely
due to map ordering you predicted by hand), the recovery is to regenerate the expected text
from the real renderer in `cabal repl` and paste it back, recording the correction in the
Decision Log. No data is mutated and nothing is destructive; there is no migration and no
rollback needed beyond `git checkout` on the touched files.


## Interfaces and Dependencies

The new module is `En.Schema.Render`, source file `en-core/src/En/Schema/Render.hs`, added to
the `exposed-modules` of the `en-core` library in `en-core/en-core.cabal`. It introduces **no
new build dependencies**: it uses only `text` and `containers`, both already declared in the
library's `build-depends`. It imports types from `En.Schema` (`Schema`, `ObjectType`,
`RelationName`, `Relation`, `AllowedSubject`, `Rewrite`, `CaveatName`,
`CaveatParameterName`, `CaveatParameterType`, `CaveatDefinition`) and, for the graph variant,
from `En.Reachability` (`ReachabilityGraph`, `RelationRef`, `SubjectSelector`, `EntryPoint`,
`EntryKind`).

The exported signatures that must exist at completion:

```haskell
-- | Fold a schema into a human-readable Markdown reference: one section per
-- object type listing each relation, its allowed subjects, and a readable
-- rendering of its rewrite, plus a Caveats section.
renderMarkdown :: Schema -> Text

-- | Fold a schema into a Mermaid flowchart whose nodes are object types and
-- whose edges are relations and rewrites. Direct (This) relations draw labelled
-- edges to their allowed subject types; computed permissions draw a labelled
-- self-edge reading "<relation> = <rewrite>"; caveated edges are drawn dotted
-- with the caveat name in the label.
renderMermaid :: Schema -> Text

-- | Fold a *compiled* reachability graph into a Mermaid flowchart whose edges
-- are the fully-expanded entry points (subject type -> target relation),
-- marking Conditional entries dotted. Complements renderMermaid: this shows
-- "who can ultimately reach what" after rewrites are resolved, whereas
-- renderMermaid shows the syntactic per-relation structure.
renderReachabilityMermaid :: ReachabilityGraph -> Text
```

All three are pure `Text`-returning folds; none performs I/O or requires `IO`. They take the
plain `Schema`/`ReachabilityGraph` values, so this plan stands entirely on its own.

On the soft dependency on `docs/plans/21-introduce-a-validated-schema-evidence-type.md`: EP-21
introduces `newtype ValidSchema = ValidSchema Schema`, obtainable only via `validateSchema ::
Schema -> Either EnError ValidSchema`, and changes `compile`/`schemaHash` to demand that
evidence. This plan deliberately does **not** depend on EP-21: rendering does not require a
valid schema (a user mid-edit still wants a diagram), so `renderMarkdown` and `renderMermaid`
take `Schema`. If EP-21 has merged when you implement this, nothing changes — a caller holding
a `ValidSchema` simply unwraps it (the `ValidSchema` value *contains* the `Schema`) before
calling the renderers; we do not add a `ValidSchema`-typed overload, to keep the surface
minimal and the plan order-independent. Likewise, `renderReachabilityMermaid` takes the
already-compiled `ReachabilityGraph` (produced by `En.Reachability.compile`), so a caller who
has compiled their schema can render the resolved graph without re-validating.
