---
id: 26
slug: load-developer-schemas-into-the-production-server-at-runtime
title: "Load developer schemas into the production server at runtime"
kind: exec-plan
created_at: 2026-06-24T05:11:09Z
---

# Load developer schemas into the production server at runtime

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today the standalone authorization service `en-server` can only enforce one hard-coded
authorization model. Its entry point, `en-server/app/Main.hs`, builds a tiny built-in
`demoSchema` (a `user` type and a `space` type with one `viewer` relation and one `view`
permission) and serves that. A developer who wants to run `en` as a service for their own
application — with their own object types, relations, permissions, and caveats — has no way
to supply their model. The production-deployment guide
(`docs/user/production-deployment-and-performance.md`) openly says this: it instructs
developers to fork the executable and write their own Haskell `Main.hs` that imports their
schema and links it into a new binary. That means every consumer needs a Haskell toolchain,
a per-application build, and a rebuild-and-redeploy every time the model changes. There is no
single, reusable, prebuilt server.

After this change, a developer can write their authorization model in a plain text file using
`en`'s schema language (the same language already accepted by the `[schema| ... |]`
quasi-quoter), point the prebuilt `en-server` binary at that file with an environment variable
`EN_SCHEMA_PATH`, and the server will load, validate, compile, and serve that model — failing
to start (rather than serving a wrong or empty model) if the file is missing, malformed, or
invalid. Concretely, after this change the following works end-to-end with no recompilation of
`en`:

```bash
cat > /tmp/blog.en <<'EOF'
object user {}

object post {
  relation author: user
  relation reader: user, user:*
  permission view = author | reader
  permission edit = author
}
EOF

EN_DATABASE_URL='postgresql://localhost:5432/en' \
EN_SCHEMA_PATH=/tmp/blog.en \
  cabal run en-server
# en-server logs: "Loaded schema from /tmp/blog.en (schemaHash=...)"
# then a POST to /check against post#view returns a real decision for that model.
```

A second goal is to make the on-disk schema language able to express the *entire* schema
model, not a subset. The text parser that exists today (used only at compile time inside the
quasi-quoter) silently understands only a fraction of what the schema type can hold: it parses
object types, relations, and permissions built from union (`|`), computed-userset aliases, and
arrow (`parent->view`) rewrites. It does **not** parse intersection, exclusion, or caveats —
three first-class features of `en`'s model. If the runtime loader used that parser unchanged,
a developer could write a schema file that *appears* to load but cannot express caveated
(time-bounded / autonomy-bounded) grants or intersection/exclusion permissions at all. This
plan extends the parser to full coverage so a schema file can express everything the in-memory
schema type and the `En.Schema.Builder` API can express.

The plan deliberately keeps the existing compile-time path intact. A Haskell application that
prefers to compile its schema into its own binary (the embedded-library posture) continues to
work exactly as before; this plan only *adds* a runtime path, it removes nothing.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] 2026-06-24T18:31:19Z: M1: Promote the text parser into a public runtime module `En.Schema.Parse` with
  signature `parseSchema :: Text -> Either EnError Schema`; refactor `En.Schema.TH` to call
  it; add parser unit tests. (No behavior change for the quasi-quoter.)
- [x] 2026-06-24T18:34:57Z: M2: Add a runtime schema-file loader and wire `EN_SCHEMA_PATH` into `en-server`,
  replacing the hard-coded `demoSchema` when the variable is set; fail closed on
  missing/malformed/invalid files; log the loaded path and schema hash.
- [x] 2026-06-24T18:37:33Z: M3: Extend the parser to intersection (`&`) and exclusion (`but not`) permission
  rewrites; add round-trip/coverage tests proving parity with the `En.Schema.Builder` output.
- [x] 2026-06-24T18:41:55Z: M4: Extend the parser to caveat definitions and caveated rewrites (`with`), using
  explicit `context.<name>` and `payload.<name>` operand syntax; add coverage tests proving
  every `CaveatPredicate` shape parses and validates.
- [ ] M5: Update `docs/user/production-deployment-and-performance.md`,
  `docs/user/getting-started.md`, and `docs/user/service-and-operations.md` to document the
  runtime schema-loading workflow and remove the "fork the executable" instruction.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Use a runtime *text-file* loader (`EN_SCHEMA_PATH`) as the way developers supply
  schemas, and keep the compile-time/embedded path unchanged.
  Rationale: `en`'s schema is a pure, fully serializable algebraic value with no embedded
  functions — even caveats are a data AST (`En.Schema.Types.CaveatPredicate`, interpreted by
  `En.Caveat.evaluateCaveat`), not Haskell closures. A text parser that produces a `Schema`
  already exists (`parseSchema` inside `en-core/src/En/Schema/TH.hs`) and runs as an ordinary
  pure function; only its *call site* is compile-time. Reusing it at runtime is the smallest
  change that yields a single prebuilt server, and it matches how SpiceDB/OpenFGA let operators
  load a schema without recompiling the engine. Extending the same text grammar to the full model
  (M3/M4) means the file format covers everything the schema type can hold, so no second
  (machine) format is needed.
  Date: 2026-06-24

- Decision: When `EN_SCHEMA_PATH` is unset, keep serving the existing built-in `demoSchema`
  but log a prominent warning; when it is set, load that file and **fail startup** on any
  error rather than silently falling back.
  Rationale: Backward compatible (existing `cabal run en-server` demos keep working) and
  idempotent, while fail-closed behavior prevents a typo in the path from silently serving the
  wrong (demo) model in production. Authorization must fail closed.
  Date: 2026-06-24

- Decision: One schema per server process, loaded once at startup (no hot reload, no
  multi-tenant multi-schema) for this plan.
  Rationale: The engine compiles exactly one `ReachabilityGraph` (`En.Reachability.compile`)
  and the consistency layer derives one `schemaHash`. Hot reload and multi-schema are separate,
  larger designs (they require swapping the compiled graph under in-flight requests and careful
  cache/token invalidation). They are explicitly out of scope and noted as follow-ups.
  Date: 2026-06-24

- Decision: Drop the JSON loading format (formerly milestone M5) from this plan; keep it only as
  a deferred out-of-scope follow-up.
  Rationale: Deriving `FromJSON`/`ToJSON` is nearly free, but a *serialized `Schema` format is a
  compatibility contract*: once any developer has `.json` schema files on disk, the encoding can
  never be broken across changes to the schema data types, and it adds a second load path to test
  and document. The text DSL reaches full model coverage in M3/M4, which makes the JSON path
  redundant for expressiveness, so its only lasting effect would be that standing
  format-compatibility burden — i.e. drag — for no unique capability. If a machine-generated
  schema format is ever genuinely needed (e.g. external tooling that emits schemas), it can be
  added deliberately as its own change with an explicit versioning policy.
  Date: 2026-06-24

- Decision: Caveat parameter declarations in the text DSL declare only parameter names and
  types; caveat predicates choose the value source at each operand with `context.<name>` or
  `payload.<name>`.
  Rationale: This matches the existing data model. `CaveatDefinition.parameters` stores a map
  from parameter name to `CaveatParameterType` only; the source is not a property of the
  parameter declaration. The source lives on each `CaveatOperand` as `OperandParam FromContext`
  or `OperandParam FromPayload`, and the builder exposes that as `ctxParam` and `payloadParam`.
  Requiring the source prefix at the operand site avoids a misleading declaration syntax and
  makes tuple-payload-dependent caveats visibly different from request-context-dependent caveats.
  Date: 2026-06-24

- Decision: Keep tuple-local caveat payloads out of the schema-file DSL; schema files declare
  caveat definitions and schema-level `with` rewrites only.
  Rationale: Tuple caveat payloads are relationship data supplied through `TupleCaveat` on writes,
  not schema structure. The engine evaluates a schema-level `Caveated` rewrite with an empty
  `CaveatPayload`, while it evaluates a tuple caveat with the payload stored on that tuple.
  Documentation and tests must therefore demonstrate both paths separately: a context-only
  schema-level `with` caveat, and a direct tuple relation with a tuple-local payload caveat
  supplied through the write API.
  Date: 2026-06-24

- Decision: Parse permission rewrites with `but not` as the lowest-precedence, non-associative
  exclusion operator, `|` as union, `&` as intersection, and parentheses for explicit grouping.
  Rationale: This matches the plan's readable grammar and avoids overloading a hyphen-like token
  that could be confused with identifier spelling. Making exclusion non-associative forces
  authors to parenthesize ambiguous chains instead of relying on surprising grouping.
  Date: 2026-06-24

- Decision: Parse caveats with top-level `caveat name(params) { predicate }` blocks, type-only
  parameter declarations, explicit `context.` / `payload.` operand prefixes, and a tightly bound
  rewrite `with` clause.
  Rationale: This mirrors the existing schema data model: caveat parameter declarations record
  names and types, while operand source is chosen at the use site. Binding `with` to a rewrite
  atom keeps `viewer with request_allowed | owner` readable as a caveated viewer branch unioned
  with an uncaveated owner branch; broader caveated expressions can use parentheses.
  Date: 2026-06-24


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)

- 2026-06-24T18:31:19Z: M1 completed. `En.Schema.Parse.parseSchema` is exposed from
  `en-core`, `En.Schema.TH` delegates to it, and `en-core/test/Main.hs` now exercises valid
  parsing, syntax failures, and schema-assembly failures directly. Validation passed with
  `cabal build en-core` and `cabal test en-core`.

- 2026-06-24T18:34:57Z: M2 completed. `en-server/app/Main.hs` now reads
  `EN_SCHEMA_PATH`, parses the file with `En.Schema.Parse.parseSchema`, validates the resulting
  schema, logs the source and schema hash, and fails startup on read or parse errors. Validation
  passed with `cabal build en-server`; `EN_SCHEMA_PATH=/tmp/en-blog-schema-smoke.en` logged
  `Loaded schema from /tmp/en-blog-schema-smoke.en` and `Schema hash:
  fnv1a64:1061a4beb2d5506c` before an intentionally unreachable database failed; a missing
  schema path exited non-zero with an error naming `EN_SCHEMA_PATH`; and the unset fallback
  printed the demo-schema warning plus hash. Full HTTP `POST /check` verification still requires
  a live PostgreSQL database with migrations applied.

- 2026-06-24T18:37:33Z: M3 completed. `En.Schema.Parse` now parses precedence-aware
  permission rewrites with `but not`, `|`, `&`, arrows, bare computed usersets, and grouping
  parentheses. `en-core/test/Main.hs` compares the parsed schema against an equivalent
  `En.Schema.Builder` schema for intersection, exclusion, and grouped rewrites. Validation
  passed with `cabal test en-core`; an `en-server` smoke check with
  `/tmp/en-operator-schema-smoke.en` logged `Loaded schema from
  /tmp/en-operator-schema-smoke.en` and `Schema hash: fnv1a64:42a02f6218db3acd` before the
  intentionally unreachable database failed.

- 2026-06-24T18:41:55Z: M4 completed. `En.Schema.Parse` now parses top-level caveat
  definitions, caveat parameter types (`text`, `bool`, `integer`, `timestamp`, `enum[...]`),
  predicate expressions, sourced operands (`context.<name>` and `payload.<name>`), literal
  values, membership, all six comparison operators, boolean composition, negation, and `with`
  rewrites. `en-core/test/Main.hs` compares a caveat-heavy parsed schema to an equivalent
  builder schema and verifies validation failures for unknown caveats and unknown parameters.
  Validation passed with `cabal test en-core`; an `en-server` smoke check with
  `/tmp/en-caveat-schema-smoke.en` logged `Loaded schema from /tmp/en-caveat-schema-smoke.en`
  and `Schema hash: fnv1a64:5535c0c913ac9b60` before the intentionally unreachable database
  failed. Full `POST /check` verification for `Allowed`/`Denied`/`Conditional` still requires a
  live PostgreSQL database with migrations applied.


## Context and Orientation

`en` is a relationship-based authorization toolkit organized as several Haskell packages under
the repository root `/Users/shinzui/Keikaku/bokuno/en`. The packages relevant to this plan are
`en-core` (the transport- and database-agnostic engine and schema model) and `en-server` (the
standalone HTTP service executable). The build tool is `cabal`; the project file is
`cabal.project` at the repository root, and the compiler is GHC 9.12.4. You build everything
with `cabal build all` and run the server with `cabal run en-server`.

A **schema** in `en` is a value of type `Schema`, defined in
`en-core/src/En/Schema/Types.hs` and re-exported from `en-core/src/En/Schema.hs`. It is a plain
algebraic data value: a map of object types to their relations, and a map of caveat names to
caveat definitions. Nothing inside a `Schema` is a function — it is data through and through,
which is why it can be parsed from text, validated, compiled, and hashed. The key pieces of that
data type are:

- An **object type** (`En.Schema.Types.ObjectType`, a wrapper around `Text`) such as `user`,
  `post`, or `space`. Each object type owns a set of named **relations**.
- A **relation** (`En.Schema.Types.Relation`) such as `author` or `viewer`. A relation lists
  the kinds of **subjects** allowed to fill it. A subject kind is either a plain object type
  (`user`), a **userset** written `group#member` (the members of some relation on another
  object), or a **wildcard** written `user:*` (meaning "every user", i.e. a public grant). In
  the current schema model a relation's own rewrite is always `This` (directly written tuples);
  the interesting rewrites live on permissions.
- A **permission** is, in this model, a relation whose rewrite is a **userset-rewrite
  expression** rather than `This`. The rewrite expression type is `En.Schema.Types.Rewrite`,
  which is the Zanzibar relation algebra:
  - `This` — directly assigned tuples.
  - `ComputedUserset RelationName` — "the members of another relation on the same object",
    written in text as a bare relation name (e.g. `author`). This is an alias.
  - `TupleToUserset tupleset computed` — "follow the `tupleset` relation to a target object,
    then take the `computed` relation on that target", written in text with an arrow
    (e.g. `parent->view`).
  - `Union [Rewrite]` — additive access ("any of"), written with `|`.
  - `Intersection [Rewrite]` — "all of", **not currently parseable from text**.
  - `Exclusion a b` — "`a` but not `b`", **not currently parseable from text**.
  - `Caveated caveatName rewrite` — a rewrite gated by a named caveat, **not currently
    parseable from text**.
- A **caveat** (`En.Schema.Types.CaveatDefinition`) is a bounded condition attached to a grant
  — for example "only during business hours" or "only at autonomy level >= 2". It has a name,
  a map of typed **parameters**, and a **predicate** (`En.Schema.Types.CaveatPredicate`). The
  parameter map records only each parameter's type. Whether a parameter value comes from the
  request context or from a tuple-local payload is recorded on each predicate operand, not in the
  parameter declaration. The predicate is itself a small data AST:
  - `PredTrue` — always allow.
  - `PredCompare comparator left right` — compare two **operands** with one of
    `CmpEq, CmpNe, CmpLt, CmpLe, CmpGt, CmpGe` (`En.Schema.Types.CaveatCompare`).
  - `PredAnd [CaveatPredicate]`, `PredOr [CaveatPredicate]`, `PredNot CaveatPredicate`.
  - `PredMember operand [CaveatValue]` — "operand is one of these literal values".
  An **operand** (`En.Schema.Types.CaveatOperand`) is either a literal value
  (`OperandLiteral CaveatValue`) or a named parameter with a **source**
  (`OperandParam source name`). The source (`En.Schema.Types.CaveatSource`) is either
  `FromContext` (supplied by the caller on each request) or `FromPayload` (stored on the tuple
  when the grant was written). Schema-level `Caveated` rewrites are evaluated with an empty tuple
  payload, so a `with` caveat that references `payload.<name>` will deny because no payload is
  available on that path. Payload-dependent caveats are enforced as tuple-local caveats on direct
  tuples. A **caveat value**
  (`En.Caveat.Value.CaveatValue`) is one of a text, bool, integer, timestamp, or enum literal.
  The runtime interpreter that evaluates these predicates against a request is `En.Caveat.evaluateCaveat` in
  `en-core/src/En/Caveat.hs`; this plan does not change evaluation, only how the predicate gets
  into the schema.

There are two existing ways to construct a `Schema`, and a third that this plan adds:

1. The **builder API**, `En.Schema.Builder` in `en-core/src/En/Schema/Builder.hs`. This is the
   Haskell-value way: you call functions like `object`, `relation`, `permission`, `subject`,
   `userset`, `wildcardSubject`, and combine rewrites with the `RewriteExpr` type class methods
   `computed`, `arrow`, `anyOf` (union), `allOf` (intersection), `minus` (exclusion), and
   `caveated`, plus the caveat constructors `caveat`, `parameter`, `ctxParam`, `payloadParam`,
   `litText`, `litBool`, `litInteger`, `litTimestamp`, `litEnum`, the comparison helpers
   `cmpEq`/`cmpNe`/`cmpLt`/`cmpLe`/`cmpGt`/`cmpGe`, and the predicate constructors `predTrue`,
   `predAnd`, `predOr`, `predNot`, `predMember`. The builder exposes the **full** model: every
   `Rewrite` constructor and every `CaveatPredicate` shape is reachable through it. Builder
   functions return `Either EnError ...`, and the final `build` / `buildWithCaveats` assembles
   a `Schema`.

2. The **text schema language**, parsed today only at compile time. The parser lives inside
   `en-core/src/En/Schema/TH.hs` (Template Haskell module) as the functions `parseSchema`,
   `parseObjects`, `parseObject`, `parseRelation`, `parseSubject`, `parsePermission`,
   `parsePermissionRewrite`, `parsePermissionRewriteTerm`, and helpers `splitArrow`,
   `commaList`, `pipeList`, `sourceLines`. The quasi-quoter `schema :: QuasiQuoter` (also in
   that module, used as `[schema| ... |]`) calls `parseSchema` at compile time and splices the
   resulting validated schema into the program. The grammar it accepts today is, by example:

   ```text
   object user {}
   object space {
     relation owner: user
     relation parent: space
     relation viewer: user, user:*
     permission view = owner | parent->view
   }
   ```

   That is: `object <name> {}` or a block `object <name> { ... }`; inside a block, lines of the
   form `relation <name>: <subject>, <subject>, ...` where a subject is `type`, `type#relation`
   (userset), or `type:*` (wildcard); and `permission <name> = <term> | <term> | ...` where a
   term is a bare relation name (computed alias) or `tupleset->computed` (arrow). Lines may end
   with an optional `;`. The parser is a hand-written line-oriented recursive parser; it does
   **not** use a parser-combinator library. Crucially, the term parser only understands `|`
   (union), bare names, and `->` arrows. It has **no** syntax for intersection, exclusion, or
   caveats, and there is no syntax for declaring a `caveat` at all. Confirm this for yourself by
   reading `parsePermissionRewrite` and `parsePermissionRewriteTerm` in
   `en-core/src/En/Schema/TH.hs`: the only combinator is `pipeList` (split on `|`), and a term
   is either `splitArrow` or a bare `computed` reference. This subset is the core problem M3 and
   M4 fix.

3. The **runtime text loader** this plan adds (M1, M2).

Validation and compilation already exist and are unchanged by this plan. `validateSchema ::
Schema -> Either EnError ValidSchema` lives in `en-core/src/En/Schema.hs` and checks the schema
for internal consistency, returning a `ValidSchema` evidence wrapper. `schemaHash ::
ValidSchema -> SchemaHash` derives a stable hash of the model; the consistency layer embeds this
hash in every consistency token so that tokens minted under one schema are rejected under
another (see `en-server/app/Main.hs`, which already calls `validateSchema` and `schemaHash` on
the demo schema and threads the hash into `ConsistencyConfig`). `compile :: ValidSchema ->
ReachabilityGraph` lives in `en-core/src/En/Reachability.hs` and turns the validated schema into
the graph the engine queries. The server entry point already performs exactly this
validate → hash → compile sequence on `demoSchema`; this plan only changes *where the schema
comes from*.

The server entry point to modify is `en-server/app/Main.hs`. Read it before starting: it reads
environment variables (`EN_DATABASE_URL`, `EN_PORT`, `EN_GC_WINDOW`, and three cache-tuning
variables), connects to PostgreSQL, validates and compiles `demoSchema`, builds the effectful
runner stack, constructs a Servant `Env`, and runs Warp. The `demoSchema` value and its
helper text are defined at the bottom of that file. The `requiredEnv` and
`optionalNonNegativeIntEnv` helpers there are the established pattern for reading and validating
environment variables, and the file already uses `System.Environment.lookupEnv`; reuse those
patterns.

The test suites you will extend are `en-core`'s interface test
(`en-core/test/Main.hs`, the `en-core-interface-tests` suite in
`en-core/en-core.cabal`). It is a hand-rolled test harness (no `tasty`/`hspec`) using local
`assertEqual`/`assertBool`-style helpers; follow its existing style. Fixture schema files used
by the quasi-quoter tests live under `en-core/test/fixtures/` (e.g. `BadQuotedSchema.hs`,
`DuplicateQuotedSchema.hs`); this is where compile-failure fixtures live.


## Plan of Work

The work proceeds in five milestones. M1 and M2 together deliver the headline capability — a
prebuilt server that loads a developer's schema file — for the subset of the model the text
language already covers. M3 and M4 widen the text language to the full model so that subset is
no longer a limitation. M5 updates the user documentation. Each milestone is independently
verifiable and leaves the tree building and tests passing.


### Milestone 1: Promote the parser into a public runtime module

Scope: make the existing text parser callable at runtime from a clean public module without
changing its behavior or grammar. At the end of this milestone, `en-core` exposes a new module
`En.Schema.Parse` with `parseSchema :: Text -> Either EnError Schema`, the quasi-quoter in
`En.Schema.TH` is refactored to call it (so there is exactly one parser, not two copies), and
new unit tests exercise the parser directly on `Text` input.

Create `en-core/src/En/Schema/Parse.hs`. Move the parsing functions currently in
`en-core/src/En/Schema/TH.hs` (`parseObjects`, `parseObject`, `parseObjectHeader`,
`takeObjectBody`, `parseObjectLine`, `parseRelation`, `parseSubject`, `parsePermission`,
`parsePermissionRewrite`, `parsePermissionRewriteTerm`, `splitArrow`, `commaList`, `pipeList`,
`sourceLines`, and the `ObjectHeader` type) into the new module. Change the public entry point's
type. Today the TH-internal function is `parseSchema :: String -> Either String (Either EnError
Schema)` — a `String` in, and a nested `Either` where the outer `String` is a syntax error and
the inner `EnError` is a builder/assembly error. For the public runtime API, collapse this to a
single error channel returning the project's standard error type:

```haskell
-- en-core/src/En/Schema/Parse.hs
module En.Schema.Parse (parseSchema) where

import Data.Text (Text)
import En.Error (EnError (..))
import En.Schema (Schema)
-- ... builder imports ...

-- | Parse en's text schema language into a 'Schema'. Syntax errors and
--   schema-assembly errors are both reported as 'EnError'.
parseSchema :: Text -> Either EnError Schema
```

Map a syntax error (the former `Left String`) onto the existing `EnError` constructor used for
schema problems. Read `en-core/src/En/Error.hs` to choose the right constructor (the builder
already uses `SchemaViolation`; reuse it, wrapping the syntax message as its `Text` payload, so
the loader has one uniform error type to show). Keep the grammar byte-for-byte identical in this
milestone — only the module location and the outer type change.

Refactor `en-core/src/En/Schema/TH.hs` to import `En.Schema.Parse` and call the new
`parseSchema`. The quasi-quoter's `quoteSchemaExp` currently calls the local
`parseSchema :: String -> Either String (Either EnError Schema)`; rewrite it to call
`En.Schema.Parse.parseSchema . Text.pack` and adapt the error handling so a parse failure still
produces a compile-time `fail` with a clear message (the quasi-quoter must keep failing the
build on a bad schema, exactly as the existing fixture `en-core/test/fixtures/BadQuotedSchema.hs`
expects). Remove the now-duplicated parsing helpers from `TH.hs`.

Add `En.Schema.Parse` to the `exposed-modules` list of `en-core/en-core.cabal` (the library
stanza around line 41). No new dependencies are required — the parser uses only `text` and
`containers`, already present.

Add direct parser unit tests to `en-core/test/Main.hs`. At minimum: a valid multi-object schema
string parses to `Right` and the resulting schema, after `validateSchema`, has the expected
object types and permission rewrites; a malformed string (e.g. a permission with no `=`, or an
object missing its closing `}`) parses to `Left` with an `EnError`; and a schema string that is
syntactically fine but semantically invalid still surfaces as `Left`. Follow the file's existing
assertion style.

Acceptance: `cabal build en-core` succeeds; `cabal test en-core` passes including the new parser
tests; the existing quasi-quoter compile-failure fixture still fails to compile when exercised by
its test (no regression in `[schema| ... |]`).


### Milestone 2: Load a schema file in en-server via EN_SCHEMA_PATH

Scope: wire runtime loading into the server. At the end of this milestone, the prebuilt
`en-server` loads a schema from the path in `EN_SCHEMA_PATH` (when set), validates and compiles
it, fails to start on any error, logs the loaded path and schema hash, and falls back to the
built-in demo schema with a warning when the variable is unset.

Add a small loader to `en-server` (either inline in `en-server/app/Main.hs` or in a new
`en-server/app/SchemaSource.hs` module added to the executable's `other-modules` in
`en-server/en-server.cabal`). The loader's responsibility:

```haskell
-- Resolve the schema the server should serve.
-- Returns the *raw* Schema; the caller still runs validateSchema/compile.
loadSchema :: IO Schema
loadSchema = do
  lookupEnv "EN_SCHEMA_PATH" >>= \case
    Nothing -> do
      Text.putStrLn "WARNING: EN_SCHEMA_PATH not set; serving the built-in demo schema. \
                    \Set EN_SCHEMA_PATH=/path/to/schema.en to serve your own model."
      pure demoSchema
    Just path -> do
      contents <- Text.readFile path        -- may throw IOException; see below
      case parseSchema contents of
        Left err  -> fail ("Failed to parse schema at " <> path <> ": " <> show err)
        Right sch -> pure sch
```

Handle a missing or unreadable file explicitly: wrap `Text.readFile` so that an `IOException`
(file not found, permission denied) becomes a clear `fail` message naming the path and the
`EN_SCHEMA_PATH` variable, mirroring the helpful style of the existing `requiredEnv` and the
PostgreSQL connection-failure message in `Main.hs`. Use `Control.Exception.try` /
`catch` around the read.

In `main`, replace the line that currently validates `demoSchema`:

```haskell
validSchema <- either (fail . ("Invalid built-in demo schema: " <>) . show) pure (validateSchema demoSchema)
```

with a version that first calls `loadSchema`, then validates the result and reports a
source-aware error:

```haskell
rawSchema <- loadSchema
validSchema <- either (fail . ("Invalid schema: " <>) . show) pure (validateSchema rawSchema)
```

Keep `demoSchema` in the file as the fallback. After computing `validSchema`, log the schema
hash so an operator can confirm which model is live and correlate it with consistency tokens
(the hash already prints nowhere; add a line). Add, near the existing startup `putStrLn` lines:

```haskell
Text.putStrLn ("Schema hash: " <> renderSchemaHash (schemaHash validSchema))
```

(Use whatever rendering the `SchemaHash` newtype already supports; if it has no `Text`
renderer, `Text.pack . show` is acceptable for a log line. Read `En.Revision`/`En.Schema` to
confirm the `SchemaHash` accessor.) When `EN_SCHEMA_PATH` was used, also log
`"Loaded schema from <path>"`.

`en-server.cabal` already depends on `en-core`; if you add a separate `SchemaSource` module, add
it to `other-modules` and ensure `text` is in the executable's `build-depends` (it is, since
`Main.hs` already imports `Data.Text`).

Acceptance: with a running PostgreSQL and migrations applied (see Concrete Steps), starting
`EN_SCHEMA_PATH=/tmp/blog.en cabal run en-server` logs `Loaded schema from /tmp/blog.en` and a
schema hash, and a `POST /check` against an object type defined only in `blog.en` (not in the
demo schema) returns a real decision. Starting with `EN_SCHEMA_PATH=/tmp/does-not-exist.en`
prints a clear error naming the path and exits non-zero without binding the port. Starting with
`EN_SCHEMA_PATH` unset prints the demo-schema warning and still serves the demo model. The text
schema language used by `blog.en` here is limited to the M1 grammar (objects, relations,
unions, computed aliases, arrows, wildcards); intersection/exclusion/caveats arrive in M3/M4.


### Milestone 3: Parse intersection and exclusion

Scope: extend the text grammar so permission rewrites can express `Intersection` and
`Exclusion`, closing two of the three coverage gaps. At the end of this milestone a schema file
can use `&` for intersection and `but not` for exclusion, and tests prove the parsed result
equals the value the builder produces for the same model.

Extend the permission-rewrite parser in `en-core/src/En/Schema/Parse.hs`. The current chain is
`parsePermissionRewrite` (splits on `|` and folds into `anyOf`) then
`parsePermissionRewriteTerm` (a term is an arrow or a computed name). Introduce operator
precedence so a rewrite expression supports three binary operators with this precedence, lowest
to highest binding: `but not` (exclusion), then `|` (union), then `&` (intersection); arrows and
bare names are the atoms. Concretely, parse in layers:

```text
expr        := exclusion
exclusion   := union ( "but not" union )?      -- En.Schema.Types.Exclusion (left, right); non-associative, exactly two sides
union       := intersection ( "|" intersection )*   -- Union [...]
intersection:= atom ( "&" atom )*                    -- Intersection [...]
atom        := name "->" name                        -- TupleToUserset (arrow)
             | name                                   -- ComputedUserset (computed alias)
             | "(" expr ")"                           -- grouping
```

Add parentheses support so authors can override precedence; this requires the term scanner to
respect nesting when splitting on operators (the current `pipeList`/`commaList` split naively on
the delimiter, which is unsafe once parentheses exist). Replace the naive split helpers used for
rewrite expressions with a small splitter that does not split inside parentheses. Keep the
builder mapping explicit: `|` → `anyOf`/`Union`, `&` → `allOf`/`Intersection`, `but not` →
`minus`/`Exclusion`. Use the `En.Schema.Builder` combinators (`anyOf`, `allOf`, `minus`,
`arrow`, `computed`) rather than constructing `Rewrite` directly, so the parser stays aligned
with the builder's validation. Choose `but not` (two words) for exclusion rather than a bare `-`
to avoid ambiguity with hyphenated identifiers; record this in the Decision Log when you
implement it.

Add coverage tests in `en-core/test/Main.hs` that parse representative strings and compare the
resulting `Schema` to one constructed with the builder for the same model — for example, that
`permission view = editor & active` parses to the same permission rewrite as
`allOf (computed (relationRef "editor")) [computed (relationRef "active")]`, that
`permission view = viewer but not banned` matches `minus`, and that grouping like
`permission view = (a | b) & c` nests correctly. Equality is decidable because `Rewrite` derives
`Eq` (see `en-core/src/En/Schema/Types.hs`).

Acceptance: `cabal test en-core` passes with the new tests; a schema file using `&` and
`but not` loads in `en-server` (extend the M2 manual check with such a file) and produces
decisions consistent with the algebra (an intersection denies when either side denies; an
exclusion denies when the right side allows).


### Milestone 4: Parse caveat definitions and caveated rewrites

Scope: close the final coverage gap — caveats. At the end of this milestone a schema file can
declare named caveats with typed parameters and a predicate, and attach them to rewrites with a
`with` clause, and tests prove every `CaveatPredicate` shape round-trips through the parser.

This is the hardest milestone because the caveat predicate is a full little expression language.
Define the grammar precisely and implement it in `en-core/src/En/Schema/Parse.hs`. Proposed
concrete syntax (record it in the Decision Log on implementation):

```text
caveat request_allowed(allowed: bool) {
  context.allowed == true
}

object document {
  relation viewer: user
  permission view = viewer with request_allowed
}
```

Grammar details to implement:

- A top-level `caveat <name>( <params> ) { <predicate> }` block, parsed alongside `object`
  blocks at the top level (extend `parseObjects`/the top-level dispatcher to recognize a
  `caveat ` prefix in addition to `object `, and collect caveats separately so they can be
  passed to `En.Schema.Builder.buildWithCaveats`). The current top level only handles `object`;
  add a branch.
- A parameter is `<name>: <type>`, where `<type>` is one of `text`, `bool`, `integer`,
  `timestamp`, or `enum[value1, value2, ...]`. These map to
  `ParameterText`, `ParameterBool`, `ParameterInteger`, `ParameterTimestamp`, and
  `ParameterEnum [Text]` in `en-core/src/En/Schema/Types.hs`. Do not put `from context` or
  `from payload` on the declaration; the existing `CaveatDefinition` type has no source field on
  parameters. Use `En.Schema.Builder.parameter` for the declarations.
- A predicate expression supporting, in precedence order lowest-to-highest: `|` (→ `predOr`),
  `&` (→ `predAnd`), `!` prefix (→ `predNot`), then atoms. Atoms are:
  - a comparison `<operand> <cmp> <operand>` where `<cmp>` is one of `==`, `!=`, `<`, `<=`,
    `>`, `>=` mapping to `cmpEq/cmpNe/cmpLt/cmpLe/cmpGt/cmpGe`, which construct
    `PredCompare` values;
  - a membership `<operand> in [ <literal>, <literal>, ... ]` (→ `predMember`);
  - the literal `true` (→ `predTrue`);
  - a parenthesized sub-predicate.
  An operand is either an explicitly sourced declared parameter, written `context.<name>` or
  `payload.<name>`, or a literal. `context.<name>` maps to `Schema.ctxParam "<name>"`;
  `payload.<name>` maps to `Schema.payloadParam "<name>"`. A literal is a quoted string
  (`"x"` → `litText`), `true`/`false` (→ `litBool` — disambiguate from the `true` predicate by
  context: bare `true` as a whole predicate is `PredTrue`, whereas `context.flag == true` uses a
  bool literal operand), an integer (→ `litInteger`), a timestamp literal written
  `timestamp("2026-06-24T12:00:00Z")` (→ `litTimestamp` using `Data.Time.Format.ISO8601` or the
  equivalent `time` parser that returns `UTCTime`), or an enum literal written `enum("read")`
  (→ `litEnum`). Define the literal lexer carefully and test each shape. A parameter reference
  to an undeclared name should either be rejected during parsing with `SchemaViolation` or caught
  by `validateSchema`; in either case the tests must assert that parse-plus-validation fails.
- A caveated rewrite: extend the M3 atom grammar with `<rewrite-atom> with <caveatName>` mapping
  to `caveated`/`Caveated`. Decide precedence of `with` relative to `&`/`|`/`but not` (bind
  `with` tightly to its atom) and record it. A schema-level `with` caveat is evaluated with an
  empty tuple payload by `En.Check.applyRewriteCaveat` and `En.Lookup.applyRewriteCaveat`, so
  examples and end-to-end tests for `with` must use context-only operands or literals. Payload
  operands are still valid in caveat definitions, but they are exercised through tuple-local
  caveats on direct relation tuples.

Pass collected caveats to `En.Schema.Builder.buildWithCaveats` instead of `build` when any
caveats are present (the builder already exposes `buildWithCaveats`; confirm its signature in
`en-core/src/En/Schema/Builder.hs`).

Add coverage tests in `en-core/test/Main.hs` that parse a schema exercising every
`CaveatPredicate` constructor (`PredTrue`, `PredCompare` for all six comparators, `PredAnd`,
`PredOr`, `PredNot`, `PredMember`) and both operand sources, and compare the parsed
`CaveatDefinition` to a builder-constructed one for equality (`CaveatPredicate` and
`CaveatDefinition` derive `Eq`). Add negative tests for unknown caveat names referenced by a
`with` clause and unknown parameters referenced in a predicate. Because `parseSchema` returns a
raw `Schema`, some reference errors are validation errors rather than syntax errors; assert that
the parse-plus-`validateSchema` path returns `Left EnError`, not necessarily that parsing alone
fails.

Acceptance: `cabal test en-core` passes; a schema file with a context-only `with` caveat loads
in `en-server`, and `POST /check` yields `Allowed` when the request context satisfies the
predicate, `Denied` when it does not, and `Conditional` when required context is missing. A
separate manual scenario writes a tuple-local caveat payload through `POST /tuples` and checks a
payload-dependent caveat such as `context.clearance >= payload.level`, proving that caveat
definitions parsed from the schema file are also enforced for tuple-local payloads.


### Milestone 5: Documentation

Scope: make the new workflow discoverable and remove the obsolete "fork the executable"
guidance. At the end, the user docs describe loading a schema file into the prebuilt server.

Update `docs/user/production-deployment-and-performance.md`: in the "Dedicated Service" section,
replace the paragraph that tells developers to write their own executable importing the
production schema with the `EN_SCHEMA_PATH` workflow (a text schema file, validated and compiled
at startup, fail-closed). Note that the embedded-library path remains available for Haskell
applications that prefer compiling the schema in. Update `docs/user/getting-started.md` to show
the minimal "write a `.en` file, set `EN_SCHEMA_PATH`, run the server" flow. Update
`docs/user/service-and-operations.md` with the new environment variable in its configuration
reference and the startup log lines (loaded path, schema hash) operators will see. Keep all
documentation in plain prose consistent with the existing style of those files.

Acceptance: the three docs mention `EN_SCHEMA_PATH`, none of them still instruct the reader to
fork `en-server`, and the getting-started example matches the commands in this plan's Concrete
Steps.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/en` unless stated
otherwise. The compiler is GHC 9.12.4 via `cabal`.

Build the whole project to confirm a clean starting point:

```bash
cabal build all
```

Expected: it compiles to completion (the tree builds today; the most recent commit is a build
fix). If this fails before you change anything, stop and resolve the environment first.

After M1, build and test the core package:

```bash
cabal build en-core
cabal test en-core
```

Expected: the `en-core-interface-tests` suite runs and prints its assertions passing, including
the new `En.Schema.Parse` tests.

To exercise the server end-to-end (M2 onward) you need a PostgreSQL database with the `en`
migrations applied. The migrations directory is reported by the server itself and lives under
`en-migrations`; the standalone tooling uses `codd`. The integration test suite uses
`ephemeral-pg` to spin up a throwaway PostgreSQL, which is the easiest way to get a ready
database locally; consult `en-postgres/integration-test/Main.hs` for how it constructs a
connection string if you need an ad-hoc database. Once you have a database URL, write a schema
file and start the server:

```bash
cat > /tmp/blog.en <<'EOF'
object user {}

object post {
  relation author: user
  relation reader: user, user:*
  permission view = author | reader
  permission edit = author
}
EOF

EN_DATABASE_URL='postgresql://localhost:5432/en' \
EN_SCHEMA_PATH=/tmp/blog.en \
  cabal run en-server
```

Expected startup log (order may vary):

```text
en-server listening on :8080
Loaded schema from /tmp/blog.en
Schema hash: <hex-or-opaque-hash>
...cache configuration lines...
```

In another terminal, write a tuple and check it against the `post` model that exists only in the
file (not in the demo schema). The exact JSON request bodies follow the `*Wire` types in
`en-servant/src/En/Servant/API.hs`; read that file for the precise field names before composing
the request. A check against `post#view` for an authored post should return an `Allowed`
decision:

```bash
curl -s localhost:8080/check -H 'content-type: application/json' \
  -d '{ ... CheckRequestWire body for post:1 #view user:alice ... }'
# expect: {"decision":"Allowed"} (field shape per CheckResponseWire)
```

Verify fail-closed behavior:

```bash
EN_DATABASE_URL='postgresql://localhost:5432/en' \
EN_SCHEMA_PATH=/tmp/nope.en \
  cabal run en-server
# expect: a clear error naming /tmp/nope.en and EN_SCHEMA_PATH, non-zero exit, port not bound.
```

Verify the unset-variable fallback:

```bash
EN_DATABASE_URL='postgresql://localhost:5432/en' cabal run en-server
# expect: a WARNING line about serving the built-in demo schema, then normal startup.
```

After M3, extend `/tmp/blog.en` with intersection and exclusion and repeat the check, confirming
the decision reflects the new algebra.

After M4, use two caveat scenarios. First, add a context-only schema-level rewrite caveat:

```text
caveat request_allowed(allowed: bool) {
  context.allowed == true
}

object user {}

object document {
  relation viewer: user
  permission view = viewer with request_allowed
}
```

Write a direct `document#viewer@user` tuple, then `POST /check` with context
`allowed = true`, `allowed = false`, and no `allowed` value. Expect `Allowed`, `Denied`, and
`Conditional` respectively.

Second, add a payload-dependent caveat definition that is not attached with `with`:

```text
caveat min_level(clearance: integer, level: integer) {
  context.clearance >= payload.level
}
```

Write a direct tuple whose `TupleCaveatWire` is `min_level` with payload `level = 3`, then
check with context `clearance = 5` and `clearance = 2`. Expect `Allowed` and `Denied`. Compose
the exact JSON from the derived wire types in `en-servant/src/En/Servant/API.hs`; the important
observable behavior is that the caveat definition came from the runtime-loaded schema file while
the tuple payload came from the write request.


## Validation and Acceptance

The change is validated at three levels.

Unit level: `cabal test en-core` exercises the parser directly. After M1 it proves valid text
parses and invalid text fails. After M3 it proves intersection/exclusion parse to the same
`Rewrite` values the builder produces. After M4 it proves every `CaveatPredicate` shape and both
operand sources round-trip. These are decidable equality checks because the schema data types
derive `Eq`.

Integration level: starting `en-server` with `EN_SCHEMA_PATH` pointed at a text file and issuing
HTTP `check`/`lookup` requests against object types and permissions that exist *only* in that
file (and not in the built-in demo schema) proves the server is genuinely serving the
developer-supplied model and not the demo. A caveated grant that allows inside a time window and
denies outside it proves caveats parsed from text are actually enforced by the engine.

Failure behavior: starting with a non-existent or malformed `EN_SCHEMA_PATH` must exit non-zero
with a message naming the path, and must not bind the port — confirming the fail-closed contract.
Starting with the variable unset must warn and serve the demo schema — confirming backward
compatibility.

Acceptance is the end-to-end scenario in Purpose / Big Picture: a developer writes a `.en` file
describing their own model, sets `EN_SCHEMA_PATH`, runs the prebuilt `en-server` with no
recompilation of `en`, and observes correct authorization decisions for that model — including
intersection, exclusion, and caveats once M3–M4 land.


## Idempotence and Recovery

Every step is safe to repeat. The parser and loader are pure/read-only with respect to the
schema file (they never write it). Re-running `cabal build`/`cabal test` is idempotent. Starting
and stopping `en-server` repeatedly with different `EN_SCHEMA_PATH` values is safe; the server
loads the schema once at startup and never mutates the file. Because the server fails closed on a
bad schema, a mistaken file cannot leave the service running with a half-loaded model — it simply
does not start, and you fix the file and start again.

The one cross-cutting concern is the **schema hash**. The consistency layer embeds
`schemaHash validSchema` into consistency tokens. Changing the served schema (editing the file,
or switching from the demo schema to a file) changes the hash, and consistency tokens minted
under the old hash are rejected after the change — this is the existing, intended behavior, not a
regression introduced here. Treat a schema change like a database migration: roll it out
deliberately, and expect old tokens to be invalidated. This plan does not change that mechanism;
it only changes where the schema originates. Document this in M5.

The milestones are ordered so value lands incrementally and each is shippable on its own: M1–M2
deliver a working developer-schema server for the union/computed/arrow subset, M3 adds
intersection/exclusion, and M4 adds caveats. If M4 (caveats) proves larger than expected, M1–M3
remain valuable and shippable, and caveat support can land in a later increment without
disturbing them.


## Interfaces and Dependencies

New and changed interfaces, by milestone, using full module paths:

- M1: New module `En.Schema.Parse` in `en-core/src/En/Schema/Parse.hs` exporting
  `parseSchema :: Text -> Either EnError Schema`. `En.Schema.TH` is refactored to depend on it;
  its public surface (the `schema` quasi-quoter and `mkValidSchema`/`mkValidSchemaEither`)
  is unchanged. `En.Schema.Parse` is added to `exposed-modules` in `en-core/en-core.cabal`.
  Dependencies: `text`, `containers` (already present). The error type is `En.Error.EnError`
  (reuse `SchemaViolation` for syntax errors).

- M2: A loader function `loadSchema :: IO Schema` in `en-server` (in `en-server/app/Main.hs` or
  a new `en-server/app/SchemaSource.hs` listed under the executable's `other-modules` in
  `en-server/en-server.cabal`). It reads the environment variable `EN_SCHEMA_PATH`. `main` in
  `en-server/app/Main.hs` is changed to call `loadSchema` before `validateSchema`. New runtime
  contract: `EN_SCHEMA_PATH` (optional; when set, fail closed on read/parse/validate error;
  when unset, warn and use `demoSchema`). Dependencies: `en-core` (already present), `text`
  (already present), `Control.Exception` from `base` for catching read failures.

- M3: `En.Schema.Parse` gains parentheses and the operators `&` (→ `En.Schema.Builder.allOf` /
  `En.Schema.Types.Intersection`) and `but not` (→ `En.Schema.Builder.minus` /
  `En.Schema.Types.Exclusion`). No new dependencies.

- M4: `En.Schema.Parse` gains a top-level `caveat` block parser producing
  `En.Schema.Types.CaveatDefinition` values and a `with` clause producing
  `En.Schema.Types.Caveated` rewrites; the parser calls `En.Schema.Builder.buildWithCaveats`,
  the caveat constructors (`caveatWith`, `parameter`, `ctxParam`, `payloadParam`), the literal
  helpers (`litText`, `litBool`, `litInteger`, `litTimestamp`, `litEnum`), the comparison
  helpers (`cmpEq`…`cmpGe`), and the predicate constructors (`predTrue`, `predAnd`, `predOr`,
  `predNot`, `predMember`). Parameter declarations use type-only syntax, including
  `enum[...]`; predicate operands use `context.<name>` and `payload.<name>` to select
  `FromContext` or `FromPayload`. No new dependencies (`time` already present for timestamps).

- M5: Documentation only — `docs/user/production-deployment-and-performance.md`,
  `docs/user/getting-started.md`, `docs/user/service-and-operations.md`. No code interfaces.

Out of scope (explicit follow-ups, not part of this plan): hot reload of the schema without
restart; serving multiple schemas from one process (multi-tenant); a `zed`-style schema-write
admin endpoint; a JSON (or other machine-generated) schema loading format — deliberately
deferred because a serialized `Schema` encoding becomes a compatibility contract (see the Decision
Log entry dated 2026-06-24), so it should only be added with an explicit versioning policy if
external tooling ever needs it; and a DSL serializer (`Schema → Text`) — note that
`En.Schema.Render` produces Markdown and Mermaid for documentation, not the loadable text
language, so there is no text round-trip serializer today and this plan does not add one.


## Revision Notes

- 2026-06-24: Removed the JSON loading format (formerly milestone M5) from the committed plan and
  renumbered the documentation milestone from M6 to M5; the plan now has five milestones instead
  of six. Reason: a serialized `Schema` format is a long-lived compatibility contract whose only
  unique benefit (full-model expressiveness from a file) is already delivered by the text DSL once
  M3/M4 land, so committing to it would add standing maintenance drag for no distinct capability.
  JSON is retained only as a deferred out-of-scope follow-up with the rationale recorded in the
  Decision Log. Affected sections updated: Purpose / Big Picture, Progress, Decision Log, Plan of
  Work (intro and removed milestone), Validation and Acceptance, Idempotence and Recovery, and
  Interfaces and Dependencies.

- 2026-06-24: Corrected the caveat DSL design after checking `En.Schema.Types`,
  `En.Schema.Builder`, and the check/lookup caveat evaluation paths. Reason: parameter source is
  carried by `CaveatOperand`, not by `CaveatDefinition.parameters`, and schema-level `with`
  rewrites evaluate with an empty tuple payload. The plan now requires `context.<name>` /
  `payload.<name>` operand syntax, explicit `enum[...]` parameter types and `enum("...")`
  literals, validation-aware negative tests, and separate end-to-end checks for schema-level
  context caveats and tuple-local payload caveats. Affected sections updated: Progress, Decision
  Log, Context and Orientation, Milestone 4, Concrete Steps, and Interfaces and Dependencies.
