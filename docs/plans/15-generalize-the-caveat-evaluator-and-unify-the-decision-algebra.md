---
id: 15
slug: generalize-the-caveat-evaluator-and-unify-the-decision-algebra
title: "Generalize the caveat evaluator and unify the decision algebra"
kind: exec-plan
created_at: 2026-06-23T16:37:01Z
intention: "intention_01kvv5mecvechb6c6jv3p3zv4a"
master_plan: "docs/masterplans/3-harden-en-correctness-fixes-lookup-streaming-and-performance-benchmarks.md"
---

# Generalize the caveat evaluator and unify the decision algebra

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`en` (縁) is a relationship-based access-control engine: a Haskell library that answers the
question "may THIS subject do THIS to THIS object?" by walking a graph of relationship
**tuples** (facts like "alice owns space project-x"). The whole point of `en` is that it ships
**no built-in authorization rules**. Each consuming project (the first is a project called
**kikan**) supplies its own rules as a **schema** — a plain Haskell value describing object
types, relations, and **caveats** (small bounded conditions, e.g. "this grant is valid until a
certain time, or only up to a certain autonomy level"). The engine is supposed to be *generic*
over that schema. This is called being **schema-parametric**: the engine reads the schema and
behaves accordingly, never hard-coding any particular consumer's vocabulary.

Today that promise is broken in one place. The part of the engine that evaluates caveats does
**not** read the schema. It is hard-wired to kikan's specific caveat (a caveat literally named
`within_autonomy`) and to kikan's specific context key (`requested_autonomy`). Any other
consumer that declares a differently-named caveat gets nonsense answers. After this change, a
consumer can declare a caveat such as "admit only when the integer parameter `min_level` in the
request is at least the integer `level` stored on the tuple", and the engine will evaluate it
correctly **without any engine code mentioning that caveat by name**. You will be able to see
this working with a test that declares a brand-new caveat the engine has never heard of and
watch `check` return `Allowed` / `Denied` / `Conditional` purely from the schema and the
request.

The second thing this change fixes is invisible to a user but important to maintainers: the
three-valued decision logic (the rules for combining `Allowed`, `Denied`, and "needs more
context" results across unions, intersections, and exclusions) is **copy-pasted** between two
modules. We extract it into one shared module, `En.Decision`, so there is a single source of
truth. This module is also the agreed hand-off point ("seam") with a separate caching plan
(described under Interfaces and Dependencies); defining its function shapes cleanly now lets
that later plan add a cache without changing any answers.

The third fix removes a latent crash: one code path calls Haskell's `error` (which aborts the
program) in a situation the author believed impossible. We make that situation impossible *by
construction* instead, so the partial function disappears.

The fourth fix models **wildcard / public** subjects — the ability to say "every user can view
this" with a single tuple, written `user:*`. The `en` design document lists this as adopted,
but the code has no representation for it yet.

You will know the whole plan succeeded when: (a) `cabal build all` and `cabal test all` pass;
(b) the engine source files `En/Check.hs`, `En/Lookup.hs`, and `En/Expand.hs` no longer contain
the strings `within_autonomy`, `requested_autonomy`, `autonomyRank`, `unionDecisions`,
`intersectionDecisions`, or `error "internal error`; (c) new tests demonstrate a never-before-seen
caveat being evaluated correctly and a `user:*` public grant admitting an arbitrary user.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] **M1.1** Create `en-core/src/En/Decision.hs` exporting `CheckDecision`, `CaveatObligation`,
  and the combinators (`unionDecisions`, `intersectionDecisions`, `exclusionDecision`,
  `applyDecisionGate`, `dedupeObligations`). Add it to `exposed-modules` in `en-core.cabal`.
- [ ] **M1.2** Re-export `CheckDecision`/`CaveatObligation` from `En.Check` (so the public API is
  unchanged) and delete the copy-pasted combinators from `En.Check`.
- [ ] **M1.3** Delete the copy-pasted combinators from `En.Lookup`; import them from `En.Decision`.
- [ ] **M1.4** Audit `En.Expand`; it builds trees, not decisions, so it has no algebra to remove —
  record that finding and move on (do not invent code to delete).
- [ ] **M1.5** Remove the `error "internal error: evalThis requires a current relation"` partial in
  `En.Check.evalThis` by passing the current relation explicitly.
- [ ] **M1.6** `cabal build all` and `cabal test all` green; the existing test assertions still pass
  unchanged.
- [ ] **M2.1** Add a typed predicate AST (`CaveatPredicate`) and a `predicate` field to
  `En.Schema.CaveatDefinition`; extend `schemaHash`, `validate`, and `En.Schema.Builder`.
- [ ] **M2.2** Write `En.Caveat.evaluateCaveat :: CaveatDefinition -> CaveatPayload -> CaveatContext
  -> CheckDecision` — the generic, total, schema-driven evaluator.
- [ ] **M2.3** Rewrite `En.Check` and `En.Lookup` to look the caveat up in the schema and call the
  generic evaluator; delete `evaluateRewriteCaveat`, `evaluateTupleCaveat`,
  `evaluateWithinAutonomy`, `autonomyRank`.
- [ ] **M2.4** Re-express kikan's `within_autonomy` as a schema caveat with a predicate; update the
  test fixture and confirm every existing caveat assertion still passes.
- [ ] **M2.5** Add a test declaring a brand-new caveat (`min_level`, Integer `>=`) and prove the
  engine evaluates it with no engine code naming it.
- [ ] **M3.1** Add a public/wildcard subject form to `En.Tuple.Subject` and `En.Schema.AllowedSubject`.
- [ ] **M3.2** Handle it in `En.Check` (a `user:*` tuple grants every concrete subject of that type).
- [ ] **M3.3** Handle it in `En.Lookup` and the `En.Reachability` compiler.
- [ ] **M3.4** Add tests proving `check` admits an arbitrary user via a public grant and `lookup`
  returns the publicly-granted object.
- [ ] Final: `cabal build all && cabal test all` green; grep checks from Purpose hold.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **The task brief says the decision algebra is copy-pasted across `En.Check`, `En.Lookup`, *and*
  `En.Expand`. It is only in the first two.** `En.Expand` (`en-core/src/En/Expand.hs`) builds an
  `ExpandTree` of `ExpandNode` values for audit UIs; it never computes a `CheckDecision` and has
  no `unionDecisions`/`intersectionDecisions`. The duplication is `En.Check` lines 248–285 and
  `En.Lookup` lines 475–505 only. Milestone 1 therefore rewires Check and Lookup and merely audits
  Expand. _(2026-06-23, from reading the sources.)_

- **`CaveatDefinition` has no predicate field today.** `En.Schema.CaveatDefinition`
  (`en-core/src/En/Schema.hs` lines 66–70) is `{ name, parameters }` — it declares *what kinds of
  values* a caveat takes but not *how to decide*. The hard-coded evaluator embeds the decision
  logic in Haskell. Generalizing requires adding the decision logic to the schema as data; see
  Milestone 2. _(2026-06-23.)_


## Decision Log

Record every decision made while working on the plan.

- Decision: Represent a caveat's decision rule as a **small typed predicate AST** stored on
  `CaveatDefinition`, not as a general expression language and not as a Haskell function.
  Rationale: The `en` spec (`docs/spec/0001-en-overview.md` §3) mandates the caveat evaluator be
  "non-Turing-complete and total" with "no CEL". A closed AST of comparisons, boolean operators,
  and membership over the already-declared parameter kinds satisfies this: every node is total,
  there is no recursion through user data, and it serializes into the existing `schemaHash` so two
  schemas with different rules get different consistency-token fingerprints. A bare Haskell
  `function` field would not be `Eq`/`Show`/serializable and would defeat `schemaHash`.
  Date: 2026-06-23

- Decision: `En.Decision` is the integration seam with the caching plan; its functions take plain
  values and return plain `CheckDecision`, with no monad and no I/O.
  Rationale: Master plan `docs/masterplans/3-harden-en-correctness-fixes-lookup-streaming-and-performance-benchmarks.md`
  Integration Point 2 states EP-11 (a separate plan) will wrap these without changing results. Pure
  combinators are trivially wrappable/cacheable. We freeze their shapes here.
  Date: 2026-06-23

- Decision: Migrate kikan's autonomy/time semantics to be expressed **as a schema caveat predicate**,
  not engine special cases. The engine will no longer contain the words `within_autonomy`,
  `requested_autonomy`, or an autonomy ranking.
  Rationale: This is the literal definition of "schema-parametric" from the spec §1. The autonomy
  ordering (read/view < act < admin) becomes a `ParameterEnum` whose declared order is the ranking,
  so "requested ≤ granted" is an ordered-enum comparison the generic evaluator already understands.
  Date: 2026-06-23

- Decision: Keep `CheckDecision` three-valued (`Allowed | Denied | Conditional [CaveatObligation]`)
  throughout. Do not collapse `Conditional` into `Denied`.
  Rationale: `Conditional` carries the caveat obligations a caller must satisfy and is surfaced on
  the wire (`En.Lookup.LookupObject.decision`, the Servant API). Collapsing it would lose
  information the design depends on. The master plan and the spec both require it.
  Date: 2026-06-23

- Decision: Model wildcard/public as a new explicit constructor (`SubjectWildcard ObjectType`) rather
  than overloading an object id of `"*"`.
  Rationale: An explicit constructor cannot be confused with a real object whose id happens to be
  `"*"`, is exhaustively matched by the compiler (so we cannot forget a case), and matches how
  OpenFGA/SpiceDB model `type:*` as a first-class wildcard.
  Date: 2026-06-23


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you have never seen this repository. Read it fully before editing.

`en` is a Haskell project built with **Cabal** (the standard Haskell build tool). The repository
root is `/Users/shinzui/Keikaku/bokuno/en`. It is a multi-package project; the package you will
edit is **`en-core`**, the database- and transport-agnostic engine, under `en-core/`. Its build
file is `en-core/en-core.cabal` and its source is under `en-core/src/En/`. There is a single test
executable defined in that cabal file (`test-suite en-core-interface-tests`, `main-is: Main.hs`)
whose source is `en-core/test/Main.hs`. Tests here are a plain `IO ()` program full of
`assertEqual`/`assertBool` calls — there is no test framework; a test "fails" by calling `fail`,
which makes the executable exit non-zero. You run everything from the repository root with
`cabal build all` and `cabal test all`.

The compiler is GHC 9.12.4 (pinned in `cabal.project`). The code uses several modern extensions
enabled project-wide in the cabal file's `common shared` stanza, the two that matter most here:

- **`OverloadedRecordDot`** lets you write `record.field` to access a field. You will see
  `state.depth`, `tuple.subject`, `graph.relations` throughout.
- **`DuplicateRecordFields`** + **`NoFieldSelectors`** (the latter is a per-module `LANGUAGE`
  pragma at the top of some files): many records reuse field names like `objectType`, `relation`,
  `subject`. With `NoFieldSelectors` you may *not* use the field as a bare function; you must use
  dot syntax or record-pattern syntax. `En.Lookup` and `En.Expand` have this pragma; `En.Check`
  and `En.Schema` do not. Mind this when moving code between modules.

Warnings are errors-adjacent: the cabal `common warnings` stanza enables `-Wall -Wcompat
-Wincomplete-patterns -Wincomplete-uni-patterns -Wpartial-fields` and more. A non-exhaustive
`case` or an unused import will produce a warning that you should clean up; adding a constructor
(Milestone 3) will produce incomplete-pattern warnings everywhere that constructor is not handled,
which is exactly how you find the call sites you must update.

### The model, in plain language

A **tuple** (`En.Tuple.Tuple`, `en-core/src/En/Tuple.hs` lines 65–71) is one authorization fact:
`object`, `relation`, `subject`, and an optional `caveat`. Example in words: "space:project-x has
relation owner with subject user:alice". The **subject** (`En.Tuple.Subject`, lines 33–36) is
either a concrete object (`SubjectId ObjectRef`, e.g. `user:alice`) or a **userset**
(`SubjectSet ObjectRef RelationName`, e.g. `org:acme#member`, meaning "everyone who is a member of
org acme"). An **`ObjectRef`** (lines 24–28) is `{ objectType, objectId }`, e.g.
`ObjectType "user"` + `"alice"`.

A **schema** (`En.Schema.Schema`, `en-core/src/En/Schema.hs` lines 73–77) has two maps:
`objectTypes` (each object type to its relations) and `caveats` (each caveat name to its
definition). A **relation** (`En.Schema.Relation`, lines 80–85) carries `allowedSubjects` (which
subject shapes a direct tuple may use, type `Set AllowedSubject`) and a **rewrite**
(`En.Schema.Rewrite`, lines 103–116) — the rule for computing the relation's effective members.
The rewrite constructors are `This` (directly-assigned tuples), `ComputedUserset r` (the members of
another relation on the same object), `TupleToUserset tupleset computed` (an "arrow": follow a
tupleset relation, then a relation on the target), `Union`, `Intersection`, `Exclusion a b`
("a but not b"), and `Caveated caveatName rewrite` (gate a rewrite behind a named caveat).

An **`AllowedSubject`** (`En.Schema.hs` lines 93–97) is `{ objectType, relation :: Maybe
RelationName }`: `relation = Nothing` accepts a concrete subject of that type (`user:alice`);
`relation = Just r` accepts the userset `type#r` (`org:acme#member`).

### Caveats, in plain language

A **caveat** is a small bounded condition attached to a grant. There are two coordinates of data:

- The **`CaveatDefinition`** in the schema (`En.Schema.hs` lines 66–70): `{ name, parameters }`,
  where `parameters :: Map CaveatParameterName CaveatParameterType`. The
  **`CaveatParameterType`** (lines 57–63) is one of `ParameterText`, `ParameterBool`,
  `ParameterInteger`, `ParameterTimestamp`, or `ParameterEnum [Text]` (an enum whose `[Text]` is the
  ordered list of permitted values). This declares *what kinds of values* the caveat reads. It does
  **not** currently declare *how to decide* — that is the gap this plan closes.
- The **values**, in two `Map Text CaveatValue` bags (`En.Tuple.hs`): the **`CaveatPayload`**
  (lines 47–49) is the arguments stored on the tuple at write time (e.g. "granted autonomy = act,
  until = 2026-07-01"); the **`CaveatContext`** (lines 51–55) is the request-time facts supplied at
  check time (e.g. "requested autonomy = act, current_time = now"). A **`CaveatValue`** (lines
  39–45) is `ValueText`, `ValueBool`, `ValueInteger`, `ValueTimestamp`, or `ValueEnum`.

So a caveat evaluation reads keys from two maps (payload and context), compares them, and yields a
yes/no/needs-more answer. Today that comparison is hard-coded for one caveat.

### The decision algebra, in plain language

Evaluation returns a **`CheckDecision`** (`En.Check.hs` lines 38–42): `Allowed`, `Denied`, or
`Conditional [CaveatObligation]`. **`Conditional`** means "the graph path exists, but one or more
caveats still need request context before the caller may treat this as allowed"; each
**`CaveatObligation`** (lines 28–32) is `{ caveat :: CaveatName, missingContext :: [Text] }` — the
caveat that is unresolved and the names of the context keys it still wants. This three-valued result
is deliberate and is surfaced to callers; we keep it.

The **combinators** decide how to fold many `CheckDecision`s into one:

- `unionDecisions` (`En.Check.hs` lines 248–260): `Allowed` wins if any branch is `Allowed`; else if
  any branch is `Conditional`, the result is `Conditional` with all obligations merged; else
  `Denied`.
- `intersectionDecisions` (lines 262–274): `Denied` if any branch is `Denied`; `Allowed` only if all
  are `Allowed`; otherwise `Conditional` with merged obligations.
- `exclusionDecision` (lines 276–281): used for "a but not b" — it negates a `Denied`/`Allowed` and
  passes `Conditional` through unchanged.
- `applyDecisionGate` (lines 283–285): `applyDecisionGate gate decision = intersectionDecisions
  [gate, decision]` — apply a caveat gate to an inner decision.
- `dedupeObligations` (lines 338–344): removes duplicate obligations while preserving order.

These exact functions are duplicated verbatim in `En.Lookup.hs` (lines 475–505 and 558–564). The
duplication is the maintenance hazard Milestone 1 removes.

### The hard-coded caveat logic (what we are deleting)

In `En.Check.hs`:

- `evaluateRewriteCaveat` (lines 287–290) is called for a `Caveated` rewrite. It ignores the caveat
  definition and returns `Allowed` if the context map merely *contains the key* `requested_autonomy`,
  else `Conditional` demanding that key. This is wrong for any caveat that is not autonomy-shaped.
- `evaluateTupleCaveat` (lines 292–297) special-cases the literal caveat name `within_autonomy`
  (calling `evaluateWithinAutonomy`) and returns `Conditional` for every other caveat name.
- `evaluateWithinAutonomy` (lines 299–327) and `autonomyRank` (lines 329–336) hard-code the kikan
  semantics: read autonomy from payload key `autonomy` and context key `requested_autonomy`, rank
  them with a fixed `read/view < act < admin` table, read an optional time bound from payload key
  `until` against context key `current_time`.

`En.Lookup.hs` contains byte-for-byte copies: `evaluateRewriteCaveat` (lines 507–510),
`evaluateTupleCaveat` (lines 512–517), `evaluateWithinAutonomy` (lines 519–547), `autonomyRank`
(lines 549–556).

### The `evalThis` partial (what we are removing)

`En.Check.evalThis` (lines 182–207) needs to know which relation it is reading direct tuples for.
It currently recovers it by peeking at the head of the visited-subproblem list:

```haskell
stateRelation =
    case state.visited of
        Subproblem{relation} : _ -> relation
        [] -> error "internal error: evalThis requires a current relation"
```

The `[]` branch calls `error`, which crashes the whole program. The relation is in fact always
known at the call site (`evalRewrite` matches `This` and already has the relation in scope via the
`evalRelation` that dispatched it). Milestone 1 threads the relation in as an explicit argument so
the empty-list case cannot arise and the partial vanishes.

### How the engine is wired together

`En.Reachability.compile` (`en-core/src/En/Reachability.hs` lines 87–106) turns a `Schema` into a
`ReachabilityGraph` (its `relations` field is a `Map RelationRef Relation`, and `entries` maps each
target relation to the reverse-traversal `EntryPoint`s that reach it). `En.Check.check` walks this
graph forward to answer one yes/no/conditional question; `En.Lookup.lookup` walks it in reverse to
list reachable objects; `En.Expand.expand` walks it to build an audit tree. All three take a
`ConsistencyStore` and a `TupleStore` (effect interfaces under `En.Effect.*`) plus a
`CaveatContext`.

This plan is **EP-15** of the master plan
`docs/masterplans/3-harden-en-correctness-fixes-lookup-streaming-and-performance-benchmarks.md`.
Its Integration Point 2 states that the shared module `En.Decision` you create here is the seam a
separate plan (EP-11, decision caching, in a *different* master plan) will wrap. You do not
implement any caching; you only define clean pure functions. Reference other plans by path only;
do not duplicate their content.


## Plan of Work

The work is three milestones. Milestone 1 is a pure refactor (no behavior change) that extracts the
shared module and removes the partial — it is the safest first step and unblocks the rest. Milestone
2 is the substantive change: a generic schema-driven caveat evaluator. Milestone 3 adds the wildcard
subject. Each milestone ends green on `cabal build all && cabal test all`.


### Milestone 1 — Extract `En.Decision`, rewire Check/Lookup, remove the `evalThis` partial

**Scope.** Move the three-valued decision types and combinators into a new module
`en-core/src/En/Decision.hs`; make `En.Check` and `En.Lookup` import them instead of defining their
own; remove the `error` partial in `En.Check.evalThis`. No behavior changes; every existing test
assertion must still pass unchanged.

**What will exist at the end.** A new module `En.Decision` exporting `CheckDecision (..)`,
`CaveatObligation (..)`, `unionDecisions`, `intersectionDecisions`, `exclusionDecision`,
`applyDecisionGate`, and `dedupeObligations`. `En.Check` re-exports `CheckDecision` and
`CaveatObligation` from `En.Decision` (so its public module interface — what `En.Lookup`, `En.Expand`,
and the tests import — is unchanged), and `En.Check.evalThis` takes the relation as a parameter.
`En.Lookup` imports the combinators from `En.Decision` and no longer defines them.

**Steps.**

1. Create `en-core/src/En/Decision.hs`. Move, verbatim, the type declarations `CaveatObligation`
   (currently `En.Check.hs` lines 28–32) and `CheckDecision` (lines 38–42), and the functions
   `unionDecisions` (248–260), `intersectionDecisions` (262–274), `exclusionDecision` (276–281),
   `applyDecisionGate` (283–285), and `dedupeObligations` (338–344). The module needs imports
   `Data.Text (Text)` and `En.Schema (CaveatName (..))`. It depends on nothing else. Concretely the
   module body is:

   ```haskell
   -- | The three-valued authorization decision and its combinators.
   --
   -- This is the single source of truth for how partial results compose under
   -- union / intersection / exclusion / caveat gating. It is a pure, total,
   -- I/O-free module so that En.Check, En.Lookup (and any future caching layer,
   -- see master plan EP-11) can share exactly one implementation.
   module En.Decision (
       CheckDecision (..),
       CaveatObligation (..),
       unionDecisions,
       intersectionDecisions,
       exclusionDecision,
       applyDecisionGate,
       dedupeObligations,
   ) where

   import Data.List (foldl')
   import Data.Text (Text)

   import En.Schema (CaveatName)

   data CaveatObligation = CaveatObligation
       { caveat :: !CaveatName
       , missingContext :: ![Text]
       }
       deriving stock (Eq, Show)

   data CheckDecision
       = Allowed
       | Denied
       | Conditional ![CaveatObligation]
       deriving stock (Eq, Show)

   -- (unionDecisions, intersectionDecisions, exclusionDecision,
   --  applyDecisionGate, dedupeObligations: moved verbatim from En.Check)
   ```

   Note `foldl'` comes from `Data.List` (the existing `En.Check` relies on it being in scope via
   `GHC2024`'s Prelude; import it explicitly in the new module to be safe — if GHC reports it as
   already in scope, drop the import to silence the redundant-import warning).

2. Add `En.Decision` to the `exposed-modules` list in `en-core/en-core.cabal` (the `library`
   stanza, alphabetically after `En.Check`).

3. Edit `En.Check.hs`: delete the moved declarations and functions; add
   `import En.Decision (CheckDecision (..), CaveatObligation (..), unionDecisions,
   intersectionDecisions, exclusionDecision, applyDecisionGate, dedupeObligations)`. Keep
   `En.Check`'s export list exporting `CheckDecision (..)` and `CaveatObligation (..)` — because the
   constructors are now re-exported from `En.Decision`, this is a legal re-export and every existing
   importer of `En.Check` keeps compiling unchanged.

4. Edit `En.Lookup.hs`: delete its local `unionDecisions`, `intersectionDecisions`,
   `applyDecisionGate`, and `dedupeObligations` (lines 475–505, 558–564); import them from
   `En.Decision`. It already imports `CheckDecision`/`CaveatObligation` via `En.Check`; leave that or
   switch it to `En.Decision` — either compiles. Note `En.Lookup` has no local `exclusionDecision`
   (its `Exclusion` branch goes through `confirmCandidates`), so nothing to remove there.

5. Remove the `evalThis` partial in `En.Check.hs`. Change `evalThis`'s signature to take the current
   `RelationName` explicitly (add a `RelationName` parameter), pass it from the `This ->` branch of
   `evalRewrite` (which receives `relation` from `evalRelation`'s caller — thread it through), and
   replace the `stateRelation`/`error` block with the parameter. After this change the file must not
   contain the string `error "internal error`.

6. Audit `En.Expand.hs`: confirm it computes no `CheckDecision` and has no combinators to remove.
   Record the finding in Surprises & Discoveries (already seeded). Make no code change there.

**Commands (run from `/Users/shinzui/Keikaku/bokuno/en`).**

```bash
cabal build all
cabal test all
```

**Acceptance.** Both commands succeed. `cabal test all` prints no failure and exits 0 — meaning every
pre-existing assertion in `en-core/test/Main.hs` (e.g. "owner can view a space", "delegation caveat
denies higher autonomy", "lookup confirms intersection candidates") still passes with the algebra now
living in `En.Decision`. The following greps return nothing:

```bash
grep -n 'unionDecisions\|intersectionDecisions\|dedupeObligations' en-core/src/En/Lookup.hs
grep -n 'error "internal error' en-core/src/En/Check.hs
```


### Milestone 2 — A generic typed caveat evaluator over `CaveatDefinition`

**Scope.** Add a small typed predicate AST to the schema, write one total evaluator that interprets
a caveat's declared predicate against the tuple payload and request context, rewire `En.Check` and
`En.Lookup` to call it, delete all hard-coded autonomy logic, and re-express kikan's `within_autonomy`
as a schema caveat. The autonomy ranking becomes the *declared order of an enum parameter*, so the
engine never names autonomy.

**What will exist at the end.** `En.Schema.CaveatDefinition` gains a `predicate :: CaveatPredicate`
field. A new `CaveatPredicate` type expresses comparisons / boolean ops / membership over the
caveat's declared parameters, reading each operand from either the tuple payload or the request
context. A new module `En.Caveat` exports `evaluateCaveat :: CaveatDefinition -> CaveatPayload ->
CaveatContext -> CheckDecision`. `En.Check` and `En.Lookup` look the caveat name up in the schema's
`caveats` map and call `evaluateCaveat`; they contain no caveat name literals. The engine source
files contain none of `within_autonomy`, `requested_autonomy`, `autonomyRank`.

**The predicate AST (design).** Keep it closed, total, and non-Turing-complete (spec §3). Operands
reference a named value in one of the two bags; literals are `CaveatValue`s; comparisons and boolean
operators are the only combinators; membership tests an operand against an enum or a literal set.
Define it in `En.Schema` (so it serializes into `schemaHash` and validates alongside parameters):

```haskell
-- | Where a predicate operand reads its value from.
data CaveatSource
    = FromContext   -- ^ a request-time fact (CaveatContext)
    | FromPayload   -- ^ a value stored on the tuple (CaveatPayload)
    deriving stock (Eq, Ord, Show)

-- | A leaf value in a predicate: a named lookup, or a constant.
data CaveatOperand
    = OperandParam !CaveatSource !CaveatParameterName  -- ^ read this declared parameter
    | OperandLiteral !CaveatValue                      -- ^ a constant
    deriving stock (Eq, Show)

-- | Comparison operators. Ordering uses the natural order of the CaveatValue
-- (integers/timestamps numerically; enums by declared position; text/bool by Ord).
data CaveatCompare = CmpEq | CmpNe | CmpLt | CmpLe | CmpGt | CmpGe
    deriving stock (Eq, Ord, Show)

-- | The closed, total predicate language. No recursion through user data, no
-- general expression evaluator — exactly comparisons, boolean ops, membership.
data CaveatPredicate
    = PredTrue                                   -- ^ always admits (an unconditional grant)
    | PredCompare !CaveatCompare !CaveatOperand !CaveatOperand
    | PredAnd ![CaveatPredicate]
    | PredOr ![CaveatPredicate]
    | PredNot !CaveatPredicate
    | PredMember !CaveatOperand ![CaveatValue]   -- ^ operand ∈ the given set
    deriving stock (Eq, Show)
```

Note `CaveatPredicate` references `CaveatValue` (currently in `En.Tuple`) and `CaveatParameterName`
(in `En.Schema`). `En.Tuple` imports from `En.Schema`, so to avoid a cycle, **move `CaveatValue`,
`CaveatPayload`, and `CaveatContext` from `En.Tuple` into `En.Schema`** (they are pure data with no
`En.Tuple` dependencies) and re-export them from `En.Tuple` for source compatibility (so existing
imports `import En.Tuple (CaveatValue (..), ...)` keep working). If you prefer not to move them,
the alternative is a new tiny module `En.Caveat.Value` that both `En.Schema` and `En.Tuple` import;
choose whichever produces no import cycle and record the choice in the Decision Log.

**Ordering for enums.** A `ParameterEnum [Text]` declares an *ordered* list; comparing two
`ValueEnum` operands of an enum parameter must compare by **declared position**, not lexicographically.
The evaluator therefore needs the parameter's declared type to know the enum's order. `evaluateCaveat`
receives the whole `CaveatDefinition`, so it has `parameters` and can resolve an `OperandParam`'s
declared `CaveatParameterType`. Comparing two enum values not in the declared list, or comparing
mismatched kinds (e.g. an integer against a timestamp), yields `Denied` (a well-typed schema avoids
this; validation in M2.1 rejects predicates that reference undeclared parameters).

**The evaluator (semantics).** `evaluateCaveat def payload context`:

- Walk the predicate. For each `OperandParam source name`, look the value up in the relevant bag
  (`context` for `FromContext`, `payload` for `FromPayload`). If a referenced parameter is **absent**
  from its bag, the predicate cannot be decided yet: collect that parameter's name (only context
  misses become obligations — a missing payload value means the tuple was written without it, which is
  a definite `Denied`, not a request the caller can fix; record this rule in the Decision Log).
- If any **context** operand needed by a reachable part of the predicate is missing, return
  `Conditional [CaveatObligation { caveat = def.name, missingContext = <missing context keys> }]`.
- Otherwise evaluate the now-total predicate to a `Bool`; `True → Allowed`, `False → Denied`.
- `PredTrue → Allowed` always (unconditional grant; the migration of an always-on grant).

This is total: every operand lookup is a `Map.lookup` returning `Maybe`, every comparison is defined,
booleans fold over finite lists. There is no loop and no user-supplied code.

**Steps.**

1. **M2.1 Schema.** Add `CaveatSource`, `CaveatOperand`, `CaveatCompare`, `CaveatPredicate` to
   `En.Schema` and export them. Add `predicate :: !CaveatPredicate` to `CaveatDefinition` (lines
   66–70). Extend `validate` (the `validateCaveatDefinition` helper, lines 125–129) to reject a
   predicate whose `OperandParam` names a parameter not in `definition.parameters`, and whose
   `PredCompare`/`PredMember` mix incompatible declared kinds. Extend `schemaHash`'s `renderSchema`
   (the `renderCaveatDefinition` helper, lines 343–349) to render the predicate so two caveats with
   different rules hash differently. Extend `En.Schema.Builder` with constructors so consumers can
   author predicates ergonomically (e.g. `predTrue`, `ctxParam`, `payloadParam`, `litEnum`,
   `litInteger`, `litTimestamp`, `cmpLe`, `predAnd`, `predOr`, and a `caveatWith name params
   predicate` that supersedes the current `caveat` which can default to `PredTrue`). If `CaveatValue`
   moved to `En.Schema`, also re-export it from `En.Tuple`.

2. **M2.2 Evaluator.** Create `en-core/src/En/Caveat.hs` exporting
   `evaluateCaveat :: CaveatDefinition -> CaveatPayload -> CaveatContext -> CheckDecision`. It imports
   `En.Decision (CheckDecision (..), CaveatObligation (..))` and the schema types. Implement the
   semantics above. Add `En.Caveat` to `exposed-modules`.

3. **M2.3 Rewire.** In `En.Check`, replace `evaluateRewriteCaveat caveat context` (the `Caveated`
   branch, line 170) and `evaluateTupleCaveat context tuple.caveat` (lines 199, 206, 239) with a
   helper that (a) looks the caveat name up in `graph` (the `ReachabilityGraph` does not carry the
   `caveats` map today — **thread the `Schema`'s caveats into the graph**: add a `caveats :: Map
   CaveatName CaveatDefinition` field to `En.Reachability.ReachabilityGraph` populated by `compile`,
   so `check`/`lookup` can resolve a caveat to its definition without re-plumbing the whole `Schema`),
   and (b) calls `evaluateCaveat definition payload context`. For a `Caveated` *rewrite* there is no
   tuple payload, so pass an empty `CaveatPayload`; for a *tuple* caveat pass the tuple's payload.
   Delete `evaluateRewriteCaveat`, `evaluateTupleCaveat`, `evaluateWithinAutonomy`, `autonomyRank`
   from `En.Check`. Do the identical replacement and deletion in `En.Lookup` (its `evaluateRewriteCaveat`
   at 507, `evaluateTupleCaveat` at 512, etc.). If a caveat name is referenced but absent from the
   schema's `caveats` map, return `Left (UnknownRelation ...)` or a new `EnError` constructor — reuse
   `UnknownRelation` with a "unknown caveat" message to avoid touching `En.Error`, unless you judge a
   dedicated constructor clearer (record the choice).

4. **M2.4 Migrate kikan.** In `en-core/test/Main.hs`, change the `within_autonomy` caveat fixture so
   its semantics are carried by a predicate instead of the engine. Declare `requested_autonomy` and
   `granted_autonomy` (or keep payload key `autonomy`) as `ParameterEnum ["read", "act", "admin"]`
   (declared order encodes the ranking — note "view" and "read" were both rank 0 in the old table; if
   the fixture still needs "view", include it at the same rank by listing it, or normalize the fixture
   to "read"; record this normalization). Declare `current_time` and `until` as `ParameterTimestamp`.
   The predicate is, in words: "`requested_autonomy` (context) ≤ `autonomy` (payload) AND
   (`current_time` (context) ≤ `until` (payload))". Express the time clause so that a tuple with no
   `until` admits unconditionally — model this by either (a) making `until` required and always
   writing it, or (b) an `PredOr [ <until absent → treated as PredTrue> , current_time ≤ until ]`.
   Because a missing *payload* `until` is `Denied` under our rule, prefer modeling "no expiry" as a
   sentinel far-future timestamp written on the tuple, OR add the time clause only when the grant has
   an expiry; pick one and document it. The existing assertions that must still pass unchanged:
   "delegation caveat allows matching autonomy and time" → `Allowed`; "delegation caveat denies higher
   autonomy" (admin requested, act granted) → `Denied`; "delegation caveat is conditional with missing
   context" (no `requested_autonomy`) → `Conditional [within_autonomy missing requested_autonomy]`;
   "expired delegation caveat denies access" → `Denied`. Keep the obligation's `caveat` name as
   `within_autonomy` and `missingContext = ["requested_autonomy"]` so those assertions match.

5. **M2.5 Prove genericity.** Add a new object type and caveat to a *separate* small schema in the
   test (do not disturb kikan) named, say, `min_level`: a caveat with one Integer parameter `level`
   on the payload and one Integer context key `clearance`, predicate `clearance ≥ level`. Write tuples
   and run `check`:
   - context `clearance = 5`, tuple `level = 3` → `Allowed`.
   - context `clearance = 2`, tuple `level = 3` → `Denied`.
   - context missing `clearance` → `Conditional [CaveatObligation min_level ["clearance"]]`.
   Add an `assertBool` that the engine source contains no mention of `min_level`:
   this is verified out-of-band by the grep in Acceptance rather than in Haskell.

**Commands.**

```bash
cabal build all
cabal test all
grep -rn 'within_autonomy\|requested_autonomy\|autonomyRank' en-core/src/En/Check.hs en-core/src/En/Lookup.hs
```

**Acceptance.** `cabal test all` exits 0 with the migrated kikan caveat assertions passing *and* the
new `min_level` assertions passing. The grep over `En/Check.hs` and `En/Lookup.hs` returns nothing —
demonstrating the engine no longer names any caveat. The clinching behavioral proof: a caveat the
engine has never seen (`min_level`, with an Integer `>=` predicate) admits and denies correctly purely
from schema + context, and removing the old hard-coded `within_autonomy` branch did not break the
kikan caveat tests.


### Milestone 3 — Wildcard / public subjects

**Scope.** Model the public/wildcard subject `type:*` so a single tuple can grant a relation to every
concrete subject of a type. Handle it in `check`, `lookup`, and the reachability compiler. The spec
§2 lists "Wildcards / public" as **Adopted (model-level)**, but the code has no representation.

**What will exist at the end.** `En.Tuple.Subject` gains `SubjectWildcard ObjectType` (a tuple whose
subject is "everyone of this type"). `En.Schema.AllowedSubject` can express that a relation accepts a
wildcard of a type (add a `wildcard :: Bool` flag, or a sibling constructor — choose and document; a
`wildcard` boolean on the existing record is least disruptive). `check` returns `Allowed` for a
concrete subject `user:alice` when a tuple `object#relation@user:*` exists. `lookup` returns objects
reachable via a wildcard grant for the queried subject. `compile` emits a reverse entrypoint for the
wildcard source.

**Steps.**

1. **M3.1 Model.** Add `SubjectWildcard ObjectType` to `En.Tuple.Subject` (lines 33–36). Adding a
   constructor will trigger `-Wincomplete-patterns` warnings at every `case` on `Subject` — those
   warnings are your worklist for M3.2–M3.3. Decide how `AllowedSubject` records "this relation
   accepts a wildcard": add `wildcard :: !Bool` (default `False`) to `AllowedSubject` (lines 93–97)
   and update `En.Schema.Builder.subject`/`userset` plus a new `wildcardSubject` helper, the
   `renderAllowedSubject` in `schemaHash`, and `validate`'s `validateAllowedSubject`.

2. **M3.2 Check.** In `En.Check.evalThis`, when reading direct rows, a row whose `tuple.subject` is
   `SubjectWildcard t` matches the queried `subject` iff the queried subject's object type is `t`
   (`SubjectId (ObjectRef t' _)` with `t' == t`, and analogously decide whether a wildcard matches a
   userset subject — document the rule; the simplest correct rule is "a `type:*` wildcard matches any
   concrete `SubjectId` of `type`, and does not match `SubjectSet`"). Apply any tuple caveat exactly
   as for a normal match.

3. **M3.3 Lookup + compiler.** In `En.Reachability.compile` (the `This ->` branch, lines 124–134),
   emit an additional `EntryPoint` whose `source` is the wildcard for each allowed subject marked
   `wildcard`. In `En.Lookup.evalThis`, when looking up objects for a subject, also query for rows
   whose subject is the wildcard of the queried subject's type (extend `readRowsForSubjects` or add a
   wildcard query alongside the direct-subject query). Ensure `SubjectWildcard` is handled in any
   `case tuple.subject of` in `En.Lookup` and `En.Expand` (Expand should render a wildcard as a
   subject node).

4. **M3.4 Tests.** In `en-core/test/Main.hs`, add a public space: a tuple
   `space:public-space # view @ user:*`, mark `space#owner` (or a new `public_viewer` relation) as
   accepting a wildcard `user` subject. Assert: `check ... (SubjectId someArbitraryUser) view
   public-space` → `Allowed` for a user with no other relationship; and a `lookup` of `view` for that
   arbitrary user includes `public-space`. Confirm a `SubjectSet` query is not spuriously matched by
   the wildcard.

**Commands.**

```bash
cabal build all
cabal test all
```

**Acceptance.** `cabal test all` exits 0; the new wildcard assertions pass: an arbitrary user with no
direct or group relationship is `Allowed` to `view` the public space via the `user:*` tuple, and
`lookup` for that user lists the public space. Adding the constructor produced no remaining
incomplete-pattern warnings (all `case`s handle `SubjectWildcard`).


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/en`.

Baseline before you start (everything should already be green):

```bash
cabal build all
cabal test all
```

Expected tail of a successful test run (the suite is a plain program that exits 0 on success and
prints nothing on a pass; Cabal reports it):

```text
1 of 1 test suites (1 of 1 test cases) passed.
```

Work milestone by milestone. After each file edit, rebuild just `en-core` for a fast loop:

```bash
cabal build en-core
cabal test en-core
```

After Milestone 1, verify the refactor removed the duplication and the partial:

```bash
grep -n 'unionDecisions\|intersectionDecisions\|dedupeObligations' en-core/src/En/Lookup.hs   # expect: no output
grep -n 'error "internal error' en-core/src/En/Check.hs                                        # expect: no output
test -f en-core/src/En/Decision.hs && echo "En.Decision exists"
```

After Milestone 2:

```bash
grep -rn 'within_autonomy\|requested_autonomy\|autonomyRank' en-core/src/En/Check.hs en-core/src/En/Lookup.hs  # expect: no output
test -f en-core/src/En/Caveat.hs && echo "En.Caveat exists"
```

After Milestone 3 and at the end:

```bash
cabal build all
cabal test all
grep -rn 'SubjectWildcard' en-core/src/En/Tuple.hs en-core/src/En/Check.hs en-core/src/En/Lookup.hs  # expect: hits in all three
```


## Validation and Acceptance

Acceptance is phrased as observable behavior, proven by the test suite in
`en-core/test/Main.hs` (run with `cabal test all` from the repo root, exit code 0 = pass).

**Milestone 1 (refactor is behavior-preserving).** Every assertion that existed before the plan still
passes with the algebra living in `En.Decision`: e.g. `assertEqual "intersection requires every branch"
(Right Denied) =<< check ...` and `assertEqual "lookup confirms intersection candidates" ...` are
unchanged and green. The greps for the moved combinators and the `error` partial return nothing.

**Milestone 2 (generic, schema-driven caveats).** The decisive new behavior: a caveat the engine has
never seen by name is evaluated correctly. Concretely, with a schema declaring caveat `min_level`
(Integer payload `level`, Integer context `clearance`, predicate `clearance >= level`):

- `check` with context `clearance = 5` and a tuple carrying `level = 3` returns `Right Allowed`.
- `check` with context `clearance = 2` and the same tuple returns `Right Denied`.
- `check` with context missing `clearance` returns
  `Right (Conditional [CaveatObligation { caveat = CaveatName "min_level", missingContext = ["clearance"] }])`.

And the migrated kikan caveat still behaves as before: matching autonomy+time → `Allowed`; higher
autonomy requested → `Denied`; missing `requested_autonomy` → `Conditional [... missing
requested_autonomy]`; expired → `Denied`. The grep proves `En/Check.hs` and `En/Lookup.hs` name no
caveat.

**Milestone 3 (wildcard/public).** With a tuple `space:public-space # view @ user:*`:

- `check (SubjectId user:carol) view space:public-space` returns `Right Allowed` even though carol has
  no owner/member/guest relationship to that space.
- `lookup` of `view` over object type `space` for `user:carol` includes `space:public-space`.
- A userset subject query is not matched by the wildcard (documented rule), proven by an assertion.

**Whole plan.** `cabal build all && cabal test all` exits 0; the three Purpose grep checks hold.


## Idempotence and Recovery

Every step is an ordinary source edit under version control; nothing is destructive and there is no
database migration in this plan (it is `en-core` only). Re-running `cabal build all` / `cabal test
all` is always safe and is the way to check your state. If a milestone's edits leave the tree not
compiling, `git diff` shows exactly what changed and `git checkout -- <file>` reverts a single file.
Because Milestone 1 is a pure refactor, you can land it independently and return later; Milestones 2
and 3 are likewise independent of each other (2 touches caveats, 3 touches subjects) and may be done
in either order after Milestone 1. Commit at the end of each milestone with a Conventional Commits
message (e.g. `refactor(en-core): extract En.Decision and remove evalThis partial`,
`feat(en-core): generic schema-driven caveat evaluator`,
`feat(en-core): model wildcard/public subjects`). Do not create a feature branch unless asked;
commit to the current branch.

If `cabal` reports a dependency or plan error rather than a compile error, run `cabal build all` once
more (the first invocation can be a configure step) before investigating; do not edit `cabal.project`
(it carries unrelated package entries and a comment forbidding cross-rewrites).


## Interfaces and Dependencies

All work is in package **`en-core`** (`en-core/en-core.cabal`); no new external dependency is added
(the predicate AST, evaluator, and wildcard subject use only `containers`, `text`, and `time`, all
already declared). New and changed module interfaces, by milestone:

**Milestone 1 — `En.Decision` (new module, `en-core/src/En/Decision.hs`).** Pure, total, I/O-free.
This is **Integration Point 2** with the master plan
`docs/masterplans/3-harden-en-correctness-fixes-lookup-streaming-and-performance-benchmarks.md`:
a separate decision-caching plan (EP-11) will *wrap* these functions without changing their results,
so their shapes are frozen here.

```haskell
module En.Decision (CheckDecision (..), CaveatObligation (..),
                    unionDecisions, intersectionDecisions, exclusionDecision,
                    applyDecisionGate, dedupeObligations) where

data CaveatObligation = CaveatObligation { caveat :: !CaveatName, missingContext :: ![Text] }
data CheckDecision = Allowed | Denied | Conditional ![CaveatObligation]

unionDecisions        :: [CheckDecision] -> CheckDecision
intersectionDecisions :: [CheckDecision] -> CheckDecision
exclusionDecision     :: CheckDecision -> CheckDecision
applyDecisionGate     :: CheckDecision -> CheckDecision -> CheckDecision
dedupeObligations     :: [CaveatObligation] -> [CaveatObligation]
```

`En.Check` continues to export `CheckDecision (..)` and `CaveatObligation (..)` (re-exported from
`En.Decision`) so no downstream importer changes. `En.Check.evalThis` gains an explicit
`RelationName` parameter; its empty-list `error` is removed.

**Milestone 2 — `En.Schema` additions and `En.Caveat` (new module).**

```haskell
-- En.Schema (added types, all deriving Eq/Show; CaveatValue may move here from En.Tuple)
data CaveatSource    = FromContext | FromPayload
data CaveatOperand   = OperandParam !CaveatSource !CaveatParameterName | OperandLiteral !CaveatValue
data CaveatCompare   = CmpEq | CmpNe | CmpLt | CmpLe | CmpGt | CmpGe
data CaveatPredicate = PredTrue
                     | PredCompare !CaveatCompare !CaveatOperand !CaveatOperand
                     | PredAnd ![CaveatPredicate] | PredOr ![CaveatPredicate] | PredNot !CaveatPredicate
                     | PredMember !CaveatOperand ![CaveatValue]

data CaveatDefinition = CaveatDefinition
    { name       :: !CaveatName
    , parameters :: !(Map CaveatParameterName CaveatParameterType)
    , predicate  :: !CaveatPredicate    -- NEW
    }

-- En.Caveat (new module, en-core/src/En/Caveat.hs)
evaluateCaveat :: CaveatDefinition -> CaveatPayload -> CaveatContext -> CheckDecision
```

`En.Reachability.ReachabilityGraph` gains a `caveats :: !(Map CaveatName CaveatDefinition)` field
populated by `compile`, so `En.Check`/`En.Lookup` resolve a caveat name to its definition without
plumbing the full `Schema`. `validate` rejects predicates referencing undeclared parameters or
mixing incompatible declared kinds; `schemaHash` renders the predicate. `En.Schema.Builder` gains
predicate constructors and a `caveatWith` (the existing `caveat` defaults its predicate to `PredTrue`
for source compatibility).

**Milestone 3 — `En.Tuple` and `En.Schema` subject additions.**

```haskell
-- En.Tuple
data Subject = SubjectId ObjectRef | SubjectSet ObjectRef RelationName | SubjectWildcard ObjectType  -- NEW

-- En.Schema
data AllowedSubject = AllowedSubject
    { objectType :: !ObjectType, relation :: !(Maybe RelationName), wildcard :: !Bool }  -- wildcard NEW
```

`En.Reachability.compile` emits a wildcard `EntryPoint` for each allowed subject with `wildcard =
True`. `En.Check` and `En.Lookup` match a `user:*` wildcard against concrete `SubjectId` subjects of
that type (not against `SubjectSet`). `En.Schema.Builder` gains `wildcardSubject :: Text ->
SubjectSpec` and threads `wildcard` through `subject`/`userset`. `En.Expand` renders a
`SubjectWildcard` as a subject node.

The only external boundary touched by this plan is the seam in Integration Point 2; no other plan's
files are edited. Reference the master plan and sibling plans by path only.
