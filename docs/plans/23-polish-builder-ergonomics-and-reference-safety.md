---
id: 23
slug: polish-builder-ergonomics-and-reference-safety
title: "Polish builder ergonomics and reference safety"
kind: exec-plan
created_at: 2026-06-23T21:43:10Z
intention: "intention_01kvv6xk57em8tq254tz5zm8r0"
master_plan: "docs/masterplans/4-harden-the-en-schema-dsl-for-release.md"
---

# Polish builder ergonomics and reference safety

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`en` is a Zanzibar-style relationship-based authorization toolkit. A consuming
project (for example "kikan") describes its authorization model as a value of
type `Schema` — the object types, the relations between them, the computed
"permission" rewrite rules, and the caveats. Authors build that value with a
small value-level helper library in `en-core/src/En/Schema/Builder.hs` (imported
in user code as `En.Schema.Builder qualified as Schema`). A "value-level
builder" just means a set of ordinary Haskell functions, like `Schema.relation`,
`Schema.permission`, and `Schema.computed`, that you call to assemble the
`Schema` record; there is no code generation and no fancy type machinery today.

The builder is pleasant, but it lets you write two kinds of mistakes that the
compiler happily accepts and that only blow up later, at runtime, when
`En.Schema.validate` is run inside `compile`:

1. A "permission" with no usable rule. In Zanzibar a *relation* is a place you
   can store facts (called "tuples"), and a *permission* is a *computed*
   relation: it stores nothing of its own and instead derives its members from
   other relations. The builder exposes `permission name rewrite`, defined as
   `relation name [] rewrite` — a relation with an empty list of allowed
   subjects (nobody may write tuples to it). The problem: you can write
   `Schema.permission "view" Schema.this`. `Schema.this` is the rewrite meaning
   "the directly-stored tuples on this relation" (Zanzibar `_this`). A
   permission has no directly-stored tuples (its allowed-subject set is empty),
   so `permission "view" this` is *always invalid*. `validate` rejects it at
   runtime with "relation with This must declare at least one allowed subject"
   (see the guard in `en-core/src/En/Schema.hs` around line 203). The shape
   should simply be unrepresentable.

2. Stringly-typed cross-references. Inside one object you refer to a sibling
   relation by re-typing its name: `Schema.computed "owner"`,
   `Schema.arrow "guest_org" "member"`. A typo such as `Schema.computed "ownr"`
   compiles fine and only fails at runtime validation with
   "ComputedUserset rejects unknown relation". There is no help from ordinary
   Haskell name resolution.

After this change, an author gains two concrete, observable wins. First,
`Schema.permission "view" Schema.this` will **fail to compile** — a type error
the moment you write the always-invalid shape, instead of a runtime surprise at
startup. The common, correct case `Schema.permission "view" (Schema.computed
"owner")` stays exactly as short as before. Second, an author may *opt in* to a
handle-based API for intra-object references: bind a relation to a Haskell value
(`let owner = ...`) and pass that value to `computed`/`arrow` instead of a
string, so a typo becomes an ordinary "variable not in scope" compile error.
The existing string-based combinators keep working unchanged; the handle API is
purely additive and opt-in.

You can see both working by running the test suite: a new positive test proves
the handle form and the string form compile to the *same* `Schema` value, and a
documented "does-not-compile" fixture (kept commented in the test file, with
instructions to uncomment and observe the type error) demonstrates that
`permission this` is rejected by the type checker. The acceptance command is
`cabal test en-core-interface-tests`, plus `cabal build all` for the whole
workspace.


## Progress

- [x] 2026-06-24: Read EP-20 (`docs/plans/20-detect-duplicate-names-in-the-schema-builder.md`)
      to learn which duplicate-detection helpers it added to
      `en-core/src/En/Schema/Builder.hs`, then rebase these edits on top without
      redefining them.
- [x] 2026-06-24: Add a `PermissionRewrite` newtype and its smart constructors to
      `En.Schema.Builder`, and re-type `permission` to take a `PermissionRewrite`
      so `permission "view" this` no longer compiles.
- [x] 2026-06-24: Keep `this`, `computed`, `arrow`, `anyOf`, `allOf`, `minus`, `caveated`
      producing plain `Rewrite` for use inside `relation`; add the permission-side
      constructors so permissions read identically at the call site.
- [x] 2026-06-24: Add an opt-in handle API: a `RelationHandle` value returned alongside
      `relation`, consumable by `computed`/`arrow`, so a relation can be referenced by a
      bound value rather than a re-typed string.
- [x] 2026-06-24: Update `en-core/test/Main.hs`: convert the `kikanSchema` permission rewrites
      to the new permission constructors (graph unchanged), add a semantic-equality
      test for the handle form, and add the commented does-not-compile fixture for
      `permission this`.
- [x] 2026-06-24: Add `en-core/test/fixtures/BadPermissionThis.hs` as a runnable manual
      should-not-compile fixture for the `permission this` type error.
- [x] 2026-06-24: Update `en-server/app/Main.hs` (`demoSchema`) to the new permission
      constructors if it uses bare-`this` permissions (it does not, but verify).
- [x] 2026-06-24: Update `docs/user/getting-started.md` and `docs/user/modeling.md` to state
      the permission rule and show the handle API, with builder-style examples.
- [x] 2026-06-24: Run `nix develop --command cabal build all` and
      `nix develop --command cabal test en-core-interface-tests`; confirm both pass.


## Surprises & Discoveries

- Discovery: `validate` rejects `This` anywhere inside a relation whose allowed-subject set is
  empty, not only when the top-level rewrite is exactly `This`.
  Evidence: `rewriteContainsThis` recursively traverses `Union`, `Intersection`, `Exclusion`,
  and `Caveated` in `en-core/src/En/Schema.hs`. The builder implementation therefore makes
  `PermissionRewrite` recursive too: permission-side `anyOf`, `allOf`, `minus`, and `caveated`
  take `PermissionRewrite` branches, so `this` cannot be smuggled inside a larger permission
  expression.
  Date: 2026-06-24

- Discovery: the originally planned `RelationRef` typeclass made existing string-literal calls
  such as `Schema.computed "owner"` ambiguous under `OverloadedStrings`.
  Evidence: `nix develop --command cabal build en-core:lib:en-core` failed in
  `En.Conformance.Kikan` with ambiguous `RelationRef a` and `IsString a` constraints.
  Date: 2026-06-24


## Decision Log

- Decision: Make `permission` reject a bare `this` via a dedicated restricted
  rewrite type (option **(a)** from the task framing), not via a runtime/build-time
  guard (option (b)).
  Rationale: Option (a) moves the error from runtime to *compile time*, which is
  the strongest guarantee and matches the project's stated goal of making
  always-invalid shapes unrepresentable. A runtime guard (option (b)) would still
  let `permission "view" this` typecheck and would only fail when the program runs,
  which is exactly the status quo we want to remove. The concrete shape chosen is a
  `newtype PermissionRewrite = PermissionRewrite Rewrite` with its own non-exported
  constructor and a set of smart constructors (`computed`, `arrow`, `anyOf`,
  `allOf`, `minus`, `caveated`) that build a `PermissionRewrite`. There is
  deliberately **no** `this :: PermissionRewrite`, so `permission "view" this`
  cannot typecheck. The common case stays trivial because the permission-side
  `computed`/`arrow`/`anyOf`/`allOf`/`minus`/`caveated` read identically to the
  relation-side ones at the call site.
  Date: 2026-06-23

- Decision: Keep `anyOf`/`allOf` as `head + tail` (a required first argument plus a
  list) — do **not** change them to take a single list.
  Rationale: This is an existing *good* design and is in scope only to document.
  `validate` rejects an empty `Union`/`Intersection` at runtime ("union rewrite is
  empty"). Taking `Rewrite -> [Rewrite] -> Rewrite` guarantees at least one branch
  *by construction*, so an empty union/intersection is unrepresentable through the
  builder. The new `PermissionRewrite` versions of `anyOf`/`allOf` will preserve the
  same head+tail shape for the same reason.
  Date: 2026-06-23

- Decision: The handle API is additive and opt-in; the string combinators stay.
  Rationale: Breaking existing authoring is unacceptable, and cross-*object* arrows
  fundamentally cannot use intra-object handles (the target object's relations are
  defined in a different `object` block and are out of lexical scope). Handles solve
  only intra-object reference safety; this is stated plainly as a limit rather than
  papered over.
  Date: 2026-06-23

- Decision: Implement handles as a concrete `RelationHandle` with an `IsString` instance and a
  `relationRef :: Text -> RelationHandle` helper, rather than the planned `RelationRef`
  typeclass.
  Rationale: a typeclass over both `Text` and `RelationHandle` made unchanged
  `Schema.computed "owner"` call sites ambiguous. A concrete handle keeps those call sites
  unchanged in modules that already use `OverloadedStrings` (the documented builder mode), and
  `relationH` still returns a bound value that catches intra-object typos through Haskell name
  resolution. Callers with dynamic `Text` names can use `Schema.relationRef name`.
  Date: 2026-06-24


## Outcomes & Retrospective

Completed on 2026-06-24. `Schema.permission` now requires `PermissionRewrite`, whose
constructor is hidden; `Schema.this` remains a plain `Rewrite`, so
`Schema.permission "view" Schema.this` fails at compile time. The permission-side rewrite
surface is recursive, so `this` cannot appear inside permission unions, intersections,
exclusions, or caveated rewrites through the builder. `relationH` returns both a
`SchemaRelation` and a `RelationHandle`, and `computed`/`arrow` consume that handle while
continuing to accept string literals via `OverloadedStrings`.

Validation evidence:

```bash
nix develop --command cabal build all
nix develop --command cabal test en-core-interface-tests
nix develop --command cabal exec -- ghc -fno-code -package en-core en-core/test/fixtures/BadPermissionThis.hs
```

The first two commands pass. The manual fixture exits non-zero with:

```text
Couldn't match expected type ‘Schema.PermissionRewrite’
              with actual type ‘En.Schema.Types.Rewrite’
```


## Context and Orientation

This task touches one library module, one test module, one demo app, and two
user docs. Everything lives under the repository root
`/Users/shinzui/Keikaku/bokuno/en`. The reader needs no prior knowledge beyond
this section.

The data model lives in `en-core/src/En/Schema.hs`. A `Schema` is two maps: from
`ObjectType` to its relations, and from `CaveatName` to caveat definitions. A
`Relation` is a record with a `relationName`, a set of `allowedSubjects` (the
shapes that may be stored as direct tuples), and a `rewrite`. The `Rewrite` type
is the Zanzibar relation algebra:

```haskell
data Rewrite
    = This                                   -- directly-stored tuples (_this)
    | ComputedUserset RelationName           -- another relation on the same object
    | TupleToUserset RelationName RelationName-- arrow: follow a relation, then a relation on the target
    | Union [Rewrite]
    | Intersection [Rewrite]
    | Exclusion Rewrite Rewrite              -- "a but not b"
    | Caveated CaveatName Rewrite            -- gated by a named caveat
```

`En.Schema.validate :: Schema -> Either EnError ()` checks references and shapes
before compilation. Two checks matter here. First, in `validateRelation`
(around line 203), if a relation's `allowedSubjects` set is empty *and* its
rewrite contains `This`, validation fails with "relation with This must declare
at least one allowed subject". Second, in `validateRewrite` (around line 247),
an empty `Union` or `Intersection` fails with "<label> rewrite is empty". These
are the runtime checks the builder should make unreachable.

The builder lives in `en-core/src/En/Schema/Builder.hs`. It is a thin façade
over `En.Schema` that constructs the same public types. The relevant exports
today:

```haskell
relation   :: Text -> [SubjectSpec] -> Rewrite -> SchemaRelation
permission :: Text -> Rewrite -> SchemaRelation       -- = relation name []
this       :: Rewrite
computed   :: Text -> Rewrite
arrow      :: Text -> Text -> Rewrite
anyOf      :: Rewrite -> [Rewrite] -> Rewrite          -- Union (first : rest)
allOf      :: Rewrite -> [Rewrite] -> Rewrite          -- Intersection (first : rest)
minus      :: Rewrite -> Rewrite -> Rewrite            -- Exclusion
caveated   :: Text -> Rewrite -> Rewrite
```

Note the *term of art* used throughout: a "permission" is just a relation whose
`allowedSubjects` is empty and whose `rewrite` is computed from other relations;
it stores no tuples of its own. A "handle" here means a Haskell value that stands
for a relation by reference, so the compiler resolves the name instead of a
string being matched at runtime.

The test suite lives in `en-core/test/Main.hs`. Two fixtures anchor the builder:
`kikanSchema` (around line 307) is built entirely with the builder, and
`kikanSchemaManual` (around line 372) is the byte-for-byte equivalent built with
raw `En.Schema` constructors. The test `"builder schema equals manual schema"`
(line 85) asserts `kikanSchemaManual == kikanSchema`, and
`"builder schema hash matches manual schema hash"` (line 86) asserts their
`schemaHash` values are equal. These two assertions are the guard rail: any
change to the builder that alters the compiled `Schema` will fail them. The
builder unit tests at lines 87–88 already assert that `anyOf`/`allOf` build the
expected non-empty `Union`/`Intersection`. The helper `relationRef` at line 534
is a test-only `Reachability` construct and is unrelated to the handle API
proposed here — do not confuse the two names.

The demo app `en-server/app/Main.hs` builds a `demoSchema` with the builder and
uses `permission`/`computed`; it must continue to compile.

The two user docs that introduce the builder are
`docs/user/getting-started.md` (section "2. Build a schema", around line 33,
shows `Schema.permission "view" (Schema.computed "viewer")`) and
`docs/user/modeling.md` (section "Relations vs permissions", around line 20,
and "Rewrite choices"). Both were updated by a prior, checked-in plan,
`docs/plans/8-add-ergonomic-schema-builder-api.md`, and both must reflect the
new permission rule and the handle API after this change.


## Plan of Work

The work is three milestones. Milestone 1 makes `permission this` a compile
error. Milestone 2 adds the opt-in handle API. Milestone 3 updates docs and
proves everything with tests. Each milestone is independently verifiable with
`cabal build all` and `cabal test en-core-interface-tests`.

Before any edits, read `docs/plans/20-detect-duplicate-names-in-the-schema-builder.md`
and inspect the *current* `en-core/src/En/Schema/Builder.hs`. EP-20 ("Detect
duplicate names in the schema builder") is a soft dependency that edits the same
file and is expected to land first. If EP-20 has already introduced
duplicate-name detection (for example by changing `object`/`build` to return an
`Either` or to call a `requireUnique` helper), build on top of it: do not
redefine its helpers, and thread your new signatures through whatever return
type EP-20 settled on. If EP-20 has not landed yet, proceed against the current
signatures and leave a note in the Decision Log to re-check on rebase.

### Milestone 1 — `permission` cannot take a bare `this`

Scope: introduce a restricted rewrite type for permissions so the always-invalid
`permission "view" this` is a compile-time type error, while the correct case
stays as short as today. At the end, `En.Schema.Builder` exports a
`PermissionRewrite` type and permission-side constructors, `permission` takes a
`PermissionRewrite`, and the workspace compiles with `kikanSchema` migrated to
the new constructors.

In `en-core/src/En/Schema/Builder.hs`:

- Add `newtype PermissionRewrite = PermissionRewrite Rewrite`. Export the *type*
  `PermissionRewrite` but **not** its constructor, so values can only be made via
  the smart constructors below. This is what makes `this` unusable in permission
  position: there is no `this :: PermissionRewrite`.
- Add a small helper `permissionRewrite :: PermissionRewrite -> Rewrite` (local,
  unexported) that unwraps, used by `permission`.
- Change `permission`'s signature from
  `permission :: Text -> Rewrite -> SchemaRelation` to
  `permission :: Text -> PermissionRewrite -> SchemaRelation`, implemented as
  `permission name body = relation name [] (permissionRewrite body)`.
- Add permission-side smart constructors that mirror the existing rewrite
  combinators but produce `PermissionRewrite`. To keep call sites identical
  (`Schema.computed "owner"` reads the same whether it is in a relation or a
  permission), make `computed`, `arrow`, `anyOf`, `allOf`, `minus`, and
  `caveated` *overloaded* over the result type using a tiny class. Define:

```haskell
class RewriteResult r where
    fromRewrite :: Rewrite -> r

instance RewriteResult Rewrite where
    fromRewrite = id

instance RewriteResult PermissionRewrite where
    fromRewrite = PermissionRewrite
```

  Then re-type the combinators to return any `RewriteResult`:

```haskell
computed :: RewriteResult r => Text -> r
computed = fromRewrite . Raw.ComputedUserset . Raw.RelationName

arrow :: RewriteResult r => Text -> Text -> r
arrow tupleset comp =
    fromRewrite (Raw.TupleToUserset (Raw.RelationName tupleset) (Raw.RelationName comp))

minus :: RewriteResult r => Rewrite -> Rewrite -> r
minus a b = fromRewrite (Raw.Exclusion a b)

caveated :: RewriteResult r => Text -> Rewrite -> r
caveated name body = fromRewrite (Raw.Caveated (Raw.CaveatName name) body)

anyOf :: RewriteResult r => Rewrite -> [Rewrite] -> r
anyOf first rest = fromRewrite (Raw.Union (first : rest))

allOf :: RewriteResult r => Rewrite -> [Rewrite] -> r
allOf first rest = fromRewrite (Raw.Intersection (first : rest))
```

  Keep `this :: Rewrite` exactly as it is — crucially it is **not** overloaded,
  so it can never be a `PermissionRewrite`. Inside `relation` the combinators
  resolve `r ~ Rewrite` from `relation`'s third argument type; inside
  `permission` they resolve `r ~ PermissionRewrite`. The result is that
  `permission "view" (computed "owner")` and `relation "x" subs (computed
  "owner")` both compile and read identically, but `permission "view" this`
  fails to typecheck because `this :: Rewrite` cannot be passed where a
  `PermissionRewrite` is expected. The arguments to `anyOf`/`allOf`/`minus`/
  `caveated` stay plain `Rewrite`, which is correct: the *branches* of a
  permission union may themselves be `this`-free rewrites like `computed
  "owner"`, and only the top-level permission body needs to be `this`-free. This
  matches the runtime check, which only rejects `This` when the relation's
  allowed-subject set is empty — and permission branches are `ComputedUserset`/
  `TupleToUserset`/etc., never bare `This`.

  Add the `RewriteResult` class to the module export list as needed (export the
  class so the instance methods resolve in user code; the instances are exported
  automatically). Enable `FlexibleInstances` and `MultiParamTypeClasses` only if
  required — a single-parameter class over `Rewrite`/`PermissionRewrite` needs no
  extensions beyond what the module already uses; verify by building.

Then migrate the `kikanSchema` fixture in `en-core/test/Main.hs` (lines 339–369)
so each `Schema.permission ...` body uses the now-overloaded combinators. Because
the combinators are overloaded, the *text* of those call sites need not change at
all — the existing `Schema.anyOf (Schema.computed "owner") [...]` resolves to
`PermissionRewrite` automatically in `permission` position. Confirm
`"builder schema equals manual schema"` and the hash test still pass: the
compiled `Schema` is byte-for-byte identical because `PermissionRewrite` is just
a wrapper unwrapped immediately by `permission`.

Acceptance for Milestone 1: `cabal build all` succeeds; `cabal test
en-core-interface-tests` passes (the equality and hash assertions prove the graph
is unchanged). Manually adding `Schema.permission "x" Schema.this` anywhere
produces a type error mentioning `Rewrite`/`PermissionRewrite`.

### Milestone 2 — opt-in handle API for intra-object references

Scope: let an author bind a relation to a value and reference it without
re-typing its name, catching intra-object typos as "variable not in scope"
compile errors. At the end, `En.Schema.Builder` exports a `RelationHandle`
type and a way to obtain one, and `computed`/`arrow` accept either a `Text` name
(today) or a `RelationHandle` (new) without breaking existing callers.

The cleanest additive shape that does not disturb existing string callers is a
second overload axis on the *name* argument, mirroring how Milestone 1 overloaded
the *result*. Introduce:

```haskell
newtype RelationHandle = RelationHandle Raw.RelationName

class RelationRef a where
    toRelationName :: a -> Raw.RelationName

instance RelationRef Text where
    toRelationName = Raw.RelationName

instance RelationRef RelationHandle where
    toRelationName (RelationHandle n) = n
```

Re-type `computed` and the first argument family of `arrow` to accept any
`RelationRef`:

```haskell
computed :: (RelationRef a, RewriteResult r) => a -> r
computed ref = fromRewrite (Raw.ComputedUserset (toRelationName ref))

arrow :: (RelationRef a, RelationRef b, RewriteResult r) => a -> b -> r
arrow tupleset comp =
    fromRewrite (Raw.TupleToUserset (toRelationName tupleset) (toRelationName comp))
```

With `OverloadedStrings` already in scope in user modules, `computed "owner"`
still works (string literal resolves to `Text`), and `computed ownerHandle`
works when `ownerHandle :: RelationHandle`.

A handle must come from somewhere. The least invasive source is to have
`relation` *also* expose its name as a handle, via a companion that returns both
the `SchemaRelation` and a handle, used in a `let`/`where` binding:

```haskell
-- Returns the relation plus a handle naming it, for intra-object references.
relationH :: RelationRef a => Text -> [SubjectSpec] -> Rewrite -> (SchemaRelation, RelationHandle)
relationH name subs rw = (relation name subs rw, RelationHandle (Raw.RelationName name))
```

The author pattern becomes:

```haskell
Schema.object "space"
    ( let (ownerRel, owner)   = Schema.relationH "owner"  [Schema.subject "user"] Schema.this
          (memberRel, member) = Schema.relationH "member" [Schema.subject "user"] Schema.this
       in [ ownerRel
          , memberRel
          , Schema.permission "view" (Schema.anyOf (Schema.computed owner) [Schema.computed member])
          ]
    )
```

A typo — `Schema.computed ownr` — is now a compile error ("Variable not in
scope: ownr"), caught by ordinary Haskell name resolution. Crucially, this is
**opt-in**: authors who prefer strings keep writing `Schema.computed "owner"`
unchanged, and `kikanSchema` need not adopt handles.

Honest limit, stated plainly: handles work only for references *within the same
object* block, because that is the only place the relation's binding is in
lexical scope. Cross-object `arrow`s — `Schema.arrow "guest_org" "member"`, where
`member` is a relation on the *target* object `org` — still take strings, because
the target object's relations are defined in a different `object` block and are
out of scope at the arrow's call site. We do not attempt to solve cross-object
references here; doing so safely would require a type-level DSL, which is
explicitly out of scope. The `arrow` overload above still *accepts* a handle for
its second argument when one happens to be in scope, but in practice the
target-relation argument of a cross-object arrow will remain a string.

If wiring `relationH` through whatever return shape EP-20 imposes on `object`
proves invasive (for example if EP-20 made `object` return `Either`), scope
Milestone 2 down to the smaller, clearly-marked deliverable: ship only the
`RelationHandle` type, the `RelationRef` class with its two instances, and the
overloaded `computed`/`arrow`, plus a documented example that constructs a handle
explicitly via `RelationHandle (RelationName "owner")` in a `let`. Note that
choice in the Decision Log and the Progress checklist if taken.

Acceptance for Milestone 2: `cabal build all` succeeds; a new test (Milestone 3)
proves a handle-built object equals the equivalent string-built object.

### Milestone 3 — tests and docs

Scope: prove the new behavior and update user-facing documentation. At the end,
the test suite contains a semantic-equality test for handles and a documented
does-not-compile fixture for `permission this`, and both user docs describe the
permission rule and the handle API.

In `en-core/test/Main.hs`:

- Add a positive test asserting the handle form produces the same `Schema` as the
  string form. Build a tiny two-relation object twice — once with string
  references, once with handles — wrap each in `Schema.build`, and assert
  equality. Example body:

```haskell
let stringObj =
        Schema.object "doc"
            [ Schema.relation "owner" [Schema.subject "user"] Schema.this
            , Schema.permission "view" (Schema.computed "owner")
            ]
    handleObj =
        Schema.object "doc"
            ( let (ownerRel, owner) = Schema.relationH "owner" [Schema.subject "user"] Schema.this
               in [ ownerRel
                  , Schema.permission "view" (Schema.computed owner)
                  ]
            )
assertEqual "handle form equals string form"
    (Schema.build [Schema.object "user" [], stringObj])
    (Schema.build [Schema.object "user" [], handleObj])
```

- Add a *commented-out* does-not-compile fixture and an inline comment explaining
  it, so a reader can paste it in and observe the type error:

```haskell
-- Negative compile fixture: a permission may not be a bare `this`.
-- Uncommenting the next line must FAIL to compile with a type error roughly:
--   Couldn't match type 'Rewrite' with 'PermissionRewrite'
--   ...in the second argument of 'Schema.permission'
-- badPermission :: Schema.SchemaRelation
-- badPermission = Schema.permission "view" Schema.this
```

  Because an automated test cannot assert a compile failure inside the same
  module without a separate build, this fixture is documentation-as-test: it is
  kept commented and the Validation section instructs the reviewer to uncomment
  it, run `cabal build en-core`, observe the error, and re-comment it. This is the
  honest demonstration when the restriction is type-level.

- Leave the existing `"builder schema equals manual schema"`, hash, and `anyOf`/
  `allOf` tests unchanged; they continue to guard that the compiled graph is
  unchanged.

In `en-server/app/Main.hs`: verify `demoSchema` still compiles. It already uses
`permission`/`computed` with no bare-`this` permission, so it should need no edit;
confirm by building.

In `docs/user/getting-started.md` (section "2. Build a schema", around line 33):
add a sentence stating that a permission is computed and may not be a bare
`this` — use `Schema.relation` with allowed subjects when you want a writable
base, and `Schema.permission` with `Schema.computed`/`Schema.arrow`/
`Schema.anyOf`/etc. for computed rules. Keep the existing example as-is (it is
already correct).

In `docs/user/modeling.md` (section "Relations vs permissions", around line 20,
and "Rewrite choices"): (1) add a short paragraph stating that
`Schema.permission` now rejects a bare `Schema.this` at compile time, and that
`Schema.this` belongs only inside a `Schema.relation` that declares allowed
subjects; (2) document the two *unchanged* good designs — the non-empty
`anyOf`/`allOf` head+tail shape (explain it makes an empty union/intersection
unrepresentable, mirroring the runtime "rewrite is empty" check) and the
relation-vs-permission distinction; (3) add a short "Reference safety with
handles" subsection showing the opt-in `relationH`/handle pattern from
Milestone 2, and stating the cross-object limitation in one sentence.

Acceptance for Milestone 3: `cabal test en-core-interface-tests` passes including
the new handle-equality test; the docs render with valid fenced code blocks; the
commented negative fixture produces the documented type error when uncommented.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/en`.

First, orient on the dependency and the current builder:

```bash
sed -n '1,140p' en-core/src/En/Schema/Builder.hs
cat docs/plans/20-detect-duplicate-names-in-the-schema-builder.md
```

Make the Milestone 1 edits to `en-core/src/En/Schema/Builder.hs` (add
`PermissionRewrite`, the `RewriteResult` class and instances, re-type `permission`
and the combinators), then build:

```bash
nix develop --command cabal build en-core
```

Expected: a clean build. If GHC reports a missing extension for the class
instances, add the needed pragma (for example `{-# LANGUAGE FlexibleInstances #-}`)
to the top of `en-core/src/En/Schema/Builder.hs` and rebuild.

Make the Milestone 2 edits (add `RelationHandle`, `RelationRef` class and
instances, overload `computed`/`arrow`, add `relationH`), then build again:

```bash
nix develop --command cabal build all
```

Make the Milestone 3 edits to `en-core/test/Main.hs` and the two docs, then run
the tests:

```bash
nix develop --command cabal test en-core-interface-tests
```

Expected transcript (abbreviated):

```text
Build profile: ...
...
en-core-interface-tests> Test suite en-core-interface-tests: RUNNING...
en-core-interface-tests> Test suite en-core-interface-tests: PASS
en-core-interface-tests> 1 of 1 test suites (1 of 1 test cases) passed.
```

To demonstrate the compile-time rejection of `permission this`, compile the
manual should-not-compile fixture:

```bash
nix develop --command cabal exec -- ghc -fno-code -package en-core en-core/test/fixtures/BadPermissionThis.hs
```

Expected: a type error similar to:

```text
en-core/test/Main.hs:NN:NN: error:
    • Couldn't match type 'En.Schema.Rewrite'
                     with 'En.Schema.Builder.PermissionRewrite'
      Expected: PermissionRewrite
        Actual: Rewrite
    • In the second argument of 'Schema.permission', namely 'Schema.this'
```

Confirm the suite is green with
`nix develop --command cabal test en-core-interface-tests`.


## Validation and Acceptance

The change is acceptable when all of the following hold.

`nix develop --command cabal build all` from the repository root succeeds with no errors. This proves
the library, the demo server (`en-server/app/Main.hs`), and all dependents still
compile under the new `permission` signature and the overloaded combinators.

`nix develop --command cabal test en-core-interface-tests` passes. The two pre-existing guard tests —
`"builder schema equals manual schema"` and
`"builder schema hash matches manual schema hash"` — prove the `kikanSchema`
fixture compiles to exactly the same `Schema` value (and the same `schemaHash`)
as before, so the `PermissionRewrite` wrapper introduced no behavioral change.
The new test `"handle form equals string form"` proves the opt-in handle API
produces a `Schema` byte-for-byte identical to the string form, so authors can
adopt handles with zero semantic difference.

The compile-time rejection is demonstrated, not merely asserted:
`en-core/test/fixtures/BadPermissionThis.hs` fails to compile with a type error naming
`PermissionRewrite`/`Rewrite`. This proves the always-invalid shape is rejected by the
compiler, not by a runtime check at startup.

The docs are validated by reading them: `docs/user/getting-started.md` and
`docs/user/modeling.md` must state that a permission cannot be a bare `this`,
must document the unchanged non-empty `anyOf`/`allOf` head+tail design and the
relation-vs-permission distinction, and must show the opt-in handle pattern with
its cross-object limitation. Every fenced code block in those docs carries a
language tag.


## Idempotence and Recovery

Every step is a source edit re-run through `cabal`, which is naturally
idempotent: building or testing repeatedly produces the same result, and editing
a file to the same target content is safe to repeat. There are no migrations,
no generated artifacts, and no destructive operations.

If a build breaks midway, the safest recovery is to revert the builder module to
its committed state and re-apply the edits in milestone order, building after
each milestone so a failure is localized:

```bash
git checkout -- en-core/src/En/Schema/Builder.hs
```

If the overloading causes ambiguous-type errors at a call site (GHC cannot infer
`r` or `a`), the fix is local: annotate that call site, or — for the combinators
— rely on the surrounding `relation`/`permission` argument type to drive
resolution (it does in all current call sites). The `kikanSchema` fixture should
need no annotations because every combinator there sits inside a `relation` or
`permission` argument whose type fixes the result.

If EP-20 lands after these edits and conflicts in `En.Schema.Builder`, rebase by
re-reading EP-20's helpers and re-threading these signatures through its return
types; do not duplicate its duplicate-detection helpers. Record the rebase in the
Decision Log.


## Interfaces and Dependencies

This plan depends only on modules already in the workspace; it adds no new
package dependencies.

`En.Schema` (`en-core/src/En/Schema.hs`) supplies the data model and `validate`.
This plan does not change `En.Schema`. In particular it does **not** touch
`compile` or `schemaHash` — those belong to a separate plan (EP-21) — and the
existing hash test guards that they are unaffected.

`En.Schema.Builder` (`en-core/src/En/Schema/Builder.hs`) is the module this plan
edits. At the end of Milestone 1 it must export, in addition to its current
exports:

```haskell
PermissionRewrite          -- type only; constructor not exported
RewriteResult (fromRewrite)
permission :: Text -> PermissionRewrite -> SchemaRelation
computed   :: (RelationRef a, RewriteResult r) => a -> r   -- (RelationRef added in M2)
arrow      :: (RelationRef a, RelationRef b, RewriteResult r) => a -> b -> r
anyOf      :: RewriteResult r => Rewrite -> [Rewrite] -> r
allOf      :: RewriteResult r => Rewrite -> [Rewrite] -> r
minus      :: RewriteResult r => Rewrite -> Rewrite -> r
caveated   :: RewriteResult r => Text -> Rewrite -> r
this       :: Rewrite                                       -- unchanged, NOT overloaded
```

At the end of Milestone 2 it must additionally export:

```haskell
RelationHandle             -- type only; constructor not exported
RelationRef (toRelationName)
relationH  :: Text -> [SubjectSpec] -> Rewrite -> (SchemaRelation, RelationHandle)
```

(If Milestone 1 is implemented before Milestone 2, `computed`/`arrow` first ship
with only the `RewriteResult` constraint and gain the `RelationRef` constraint in
Milestone 2; this is a compatible widening because `Text` is a `RelationRef`.)

`En.Schema.Builder` continues to construct only the public `En.Schema` types;
`PermissionRewrite` and `RelationHandle` are builder-internal wrappers that never
appear in a `Schema`. Their constructors are unexported precisely so the only way
to obtain them is through the smart constructors, which is what enforces the
restrictions.

Soft dependency on `docs/plans/20-detect-duplicate-names-in-the-schema-builder.md`
(EP-20, "Detect duplicate names in the schema builder"). EP-20 also edits
`en-core/src/En/Schema/Builder.hs` and is expected to **land first**; it owns the
duplicate-name-detection helpers. EP-23 must not redefine those helpers and must
rebase its builder edits on top of whatever signatures EP-20 settles on (notably
if EP-20 changes the return type of `object` or `build`, thread `permission`,
`relation`, and `relationH` through that shape rather than reintroducing the old
one). EP-23 must **not** change `compile` or `schemaHash`; that is EP-21's domain.

Test module `en-core/test/Main.hs` consumes the builder. It must keep the
`kikanSchema`/`kikanSchemaManual` equality and hash tests green (graph unchanged),
gain a `"handle form equals string form"` test, and carry the commented
`badPermission` does-not-compile fixture. The demo `en-server/app/Main.hs` must
continue to compile under the new `permission` signature.
