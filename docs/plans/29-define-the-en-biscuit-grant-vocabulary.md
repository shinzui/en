---
id: 29
slug: define-the-en-biscuit-grant-vocabulary
title: "Define the en Biscuit grant vocabulary"
kind: exec-plan
created_at: 2026-07-01T04:50:38Z
master_plan: "docs/masterplans/5-add-biscuit-decision-token-support.md"
intention: intention_01kwe136p1expbzvj08bqwtz08
---

# Define the en Biscuit grant vocabulary

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan defines the typed `en` grant model and the Biscuit Datalog vocabulary
used to serialize it. After this change, implementers have one canonical way to
represent "subject may perform permission on object" and "subject may perform
permission on objects inside these containers" as Biscuit facts.

The observable result is pure tests: a grant built from `En.Tuple.Subject`,
`En.Tuple.ObjectRef`, `En.Schema.RelationName`, `En.Revision.SchemaHash`, and
`En.Revision.ConsistencyToken` encodes to Biscuit facts with stable predicate
names, and the verifier-side parser can recover or match those facts without
knowing the relationship graph.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: Define `En.Biscuit.Grant` with object grants, scoped/container grants, audiences, expiry, and request metadata. (2026-06-30) — `EnGrant`, `EnScopedGrant`, `EnBiscuitGrant`, and token-local newtypes `Audience`/`RequestId`/`RevocationId` in `en-biscuit/src/En/Biscuit/Grant.hs`, built from `En.Tuple`/`En.Schema`/`En.Revision` types.
- [x] M2: Define the stable Biscuit predicate vocabulary and rendering helpers. (2026-06-30) — `grantBlock :: EnBiscuitGrant -> Either EnBiscuitError Block` builds facts via the `[block|…|]` quasiquoter with `{var}` antiquotation (all escaping handled by `ToTerm`); `grantFactsText` renders the same `Block` with `renderBlock`. Vocabulary: `en_subject`, `en_right`, `en_scoped_right`, `en_container_scope`, `en_schema_hash`, `en_consistency_token`, `en_audience`, `en_expires_at`, `en_request_id`, `en_revocation_id`.
- [x] M3: Add pure tests for object grants, scoped grants, schema hash, consistency token, audience, expiry, and subject encoding. (2026-06-30) — `en-biscuit/test/Main.hs` covers object/scoped grants, per-container fact count, absent optional facts, fail-closed on `SubjectWildcard`/`SubjectSet`, and a semantic injection-safety test. `cabal test en-biscuit` → `en-biscuit tests PASS`.
- [x] M4: Update `En.Biscuit` top-level exports. (2026-06-30) — `En.Biscuit` now `re-exports module En.Biscuit.Grant`; `En.Biscuit.Grant` added to the cabal `exposed-modules`.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery during planning: Biscuit facts are ordinary Datalog predicates.
  `Auth.Biscuit.Example` uses facts such as `right("file1", {allowedOperations})`
  and authorizer facts such as `time({now})`. The `en` vocabulary should
  follow that style but avoid ambiguous generic names where `en_`-prefixed
  names make provenance clearer.
  Date: 2026-07-01

- Implementation 2026-06-30: `Block` (from `Auth.Biscuit`, alias of
  `Auth.Biscuit.Datalog.AST.Block'`) is a `Monoid` (Semigroup/Monoid instances
  at `Auth/Biscuit/Datalog/AST.hs:980,992`). This is what makes a variable
  number of `en_container_scope` facts easy: build one `[block|…|]` per
  container and `mconcat` them. `renderBlock :: Block -> Text` is exported from
  the (exposed) `Auth.Biscuit.Datalog.AST` module and is what `Show Block` uses,
  so `grantFactsText` is just `fmap renderBlock . grantBlock` — a single source
  of truth for the fact text.
  Date: 2026-06-30

- Implementation 2026-06-30: the `[block|…|]` quasiquoter's `{name}`
  antiquotation resolves *in-scope Haskell identifiers at runtime* (via a `Lift`
  instance that emits `toTerm name`), including identifiers bound in `let`,
  function arguments, and list-comprehension binders. `ToTerm` instances exist
  for `Text`, `Int`, `Integer`, `Bool`, `ByteString`, and `UTCTime`
  (`Auth/Biscuit/Datalog/AST.hs:300-343`), so `en_expires_at({expiresAt})` with
  `expiresAt :: UTCTime` renders as a Datalog date term. No manual escaping is
  written anywhere in `En.Biscuit.Grant`.
  Date: 2026-06-30

- Testing gotcha 2026-06-30: proving injection-safety by *counting substrings*
  of the rendered fact text is wrong. `renderBlock` renders a string term with
  `show`, which escapes quotes/backslashes but leaves `en_right(` /`;` characters
  literally inside the quoted string. An object id crafted to look like a forged
  `en_right(...)` fact therefore makes `T.count "en_right(" facts == 2` even
  though there is only one real fact. The correct proof is *semantic*: mint the
  grant into a real Biscuit and run an authorizer that queries the forged fact —
  it must fail to match (the injected text is one opaque string term, not a
  fact). The test keeps a positive control (`allow if en_subject("user","alice")`
  passes) so a `Left` from the exploit query can't be mistaken for a broken
  token.
  Date: 2026-06-30


## Decision Log

Record every decision made while working on the plan.

- Decision: Prefix `en` authority facts with `en_`.
  Rationale: Downstream services may combine Shomei authentication facts,
  service-local facts, and Biscuit facts in one authorizer. Prefixing facts
  like `en_right` and `en_schema_hash` makes it clear they are derived from an
  `en` decision.
  Date: 2026-07-01

- Decision: Store Shomei identity only as the resulting `En.Tuple.Subject`, not
  as Shomei-specific claims.
  Rationale: Shomei authenticates the user, but `en-biscuit` should remain
  independent of `shomei-core`. Host applications own the mapping from
  `AuthUser` or `AuthClaims` to `Subject`.
  Date: 2026-07-01

- Decision (2026-06-30): Build facts by constructing `Block` values through the
  `[block|…|]` quasiquoter + `{var}` antiquotation and `mconcat`, rather than
  rendering Datalog text and re-parsing it. `grantFactsText` derives text from
  the `Block` via `renderBlock`. Rationale: the quasiquoter routes every dynamic
  value through `ToTerm`, so all escaping lives in the library and injection is
  impossible at the AST level; deriving text from the block keeps a single
  source of truth. `EP-30` and `EP-31` must consume `grantBlock`/the same
  vocabulary — do not hand-render Datalog strings.
  Date: 2026-06-30

- Decision (2026-06-30): `grantFactsText` returns
  `Either EnBiscuitError Text`, not the `Text` shown in the plan's Interfaces
  sketch. Rationale: rendering derives from `grantBlock`, which can fail
  (`UnsupportedSubject`); threading that `Either` through is more honest than
  swallowing errors into an empty/placeholder string. (The plan's Interfaces
  section explicitly permitted refining the signature.)
  Date: 2026-06-30

- Decision (2026-06-30): A non-concrete subject (`SubjectSet` userset or
  `SubjectWildcard`) makes `grantBlock` return `Left (UnsupportedSubject …)`
  rather than emitting any subject fact. Rationale: only `SubjectId` maps to
  `en_subject($type,$id)`; wildcard grants are deferred and a userset is not a
  single principal. Failing closed matches the initiative's mint-only-`Allowed`
  posture and prevents accidental authorization widening. `en_subject_wildcard()`
  is intentionally not emitted.
  Date: 2026-06-30


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

Outcome (2026-06-30): `En.Biscuit.Grant` gives one canonical, type-checked way
to represent an `en` decision as Biscuit facts, and the top-level `En.Biscuit`
re-exports it. All acceptance criteria hold:

- `cabal test en-biscuit` passes (`en-biscuit tests PASS`).
- The object-grant test proves `en_subject`, `en_right`, `en_schema_hash`,
  `en_consistency_token`, `en_audience`, and `en_expires_at` all appear (plus
  `en_request_id`/`en_revocation_id` when present).
- The scoped-grant test proves `en_scoped_right` and exactly one
  `en_container_scope` per container, and that optional facts are omitted when
  absent.
- `En.Biscuit.Grant` imports only `en-core` (`En.Tuple`, `En.Schema`,
  `En.Revision`) and Biscuit/base/text/time — no `en-servant`, `en-server`, or
  Shomei.
- The top-level `En.Biscuit` re-exports the grant API.

New file: `en-biscuit/src/En/Biscuit/Grant.hs`. Modified: `en-biscuit.cabal`
(exposed module + `en-core`/`text`/`time` test deps), `En/Biscuit.hs`
(re-export), `en-biscuit/test/Main.hs` (grant tests).

Deviation vs. the plan's Interfaces sketch: `grantFactsText` returns
`Either EnBiscuitError Text` (see Decision Log). The vocabulary and grant types
otherwise match the plan exactly, so `EP-30` (mint) and `EP-31` (verify) can
build on `grantBlock`/`EnBiscuitGrant`/`EnBiscuitError` as designed.


## Context and Orientation

This plan depends on
`docs/plans/28-add-the-en-biscuit-package-and-dependency-wiring.md`, which
creates the `en-biscuit` package. The core types to reuse live in:

- `en-core/src/En/Tuple.hs`: `Subject`, `ObjectRef`, tuple caveat/context
  types.
- `en-core/src/En/Schema/Types.hs`: `ObjectType`, `RelationName`, and schema
  names.
- `en-core/src/En/Revision.hs`: `ConsistencyToken`, `SchemaHash`,
  `DatastoreId`, and revision-related wrappers.
- `en-core/src/En/Check.hs`: `CheckDecision`, whose `Allowed` result is the
  only decision that later plans may mint.

A Biscuit fact is a Datalog predicate stored in a signed token, for example
`en_right("document", "roadmap", "view")`. An authorizer is the verifier-side
Datalog program that supplies request facts such as `operation("view")` and
decides whether to allow the request.


## Plan of Work

Milestone 1 creates `en-biscuit/src/En/Biscuit/Grant.hs`. Define small
newtypes for values that are not already represented in `en-core`, such as
`Audience`, `RequestId`, and `RevocationId`. Define two grant shapes:

```haskell
data EnGrant = EnGrant
    { subject :: Subject
    , permission :: RelationName
    , object :: ObjectRef
    , consistencyToken :: ConsistencyToken
    , schemaHash :: SchemaHash
    , expiresAt :: UTCTime
    , audience :: Audience
    , requestId :: Maybe RequestId
    , revocationId :: Maybe RevocationId
    }

data EnScopedGrant = EnScopedGrant
    { subject :: Subject
    , permission :: RelationName
    , objectType :: ObjectType
    , containers :: [ObjectRef]
    , consistencyToken :: ConsistencyToken
    , schemaHash :: SchemaHash
    , expiresAt :: UTCTime
    , audience :: Audience
    , requestId :: Maybe RequestId
    , revocationId :: Maybe RevocationId
    }
```

Milestone 2 defines rendering helpers that convert grants into Biscuit block
source or into `Auth.Biscuit.Datalog.AST.Block` values. Prefer structured
helpers if the Biscuit library exposes stable constructors; otherwise render
small Datalog snippets and parse them with `Auth.Biscuit.block`, keeping all
escaping in one module. The stable vocabulary is:

- `en_subject($type, $id)` for `SubjectId (ObjectRef type id)`.
- `en_subject_wildcard()` only if a future use requires wildcard grants. Do not
  emit wildcard grants in this plan.
- `en_right($object_type, $object_id, $permission)` for object grants.
- `en_container_scope($container_type, $container_id)` for scoped grants.
- `en_scoped_right($object_type, $permission)` for scoped grants.
- `en_schema_hash($hash)`.
- `en_consistency_token($token)`.
- `en_audience($audience)`.
- `en_expires_at($timestamp)`.
- `en_request_id($request_id)` when present.
- `en_revocation_id($revocation_id)` when present.

Milestone 3 adds `en-biscuit/test/Main.hs` coverage for both grant shapes. The
tests should inspect rendered fact text or query the produced Biscuit block to
prove each expected predicate is present. They should also prove strings with
quotes or punctuation cannot break out of facts.

Milestone 4 updates `en-biscuit/src/En/Biscuit.hs` to re-export
`En.Biscuit.Grant`.


## Concrete Steps

Work from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/en
rg -n "newtype ObjectType|newtype RelationName|data Subject|newtype ConsistencyToken|newtype SchemaHash" en-core/src
sed -n '1,220p' /Users/shinzui/Keikaku/hub/haskell/biscuit-haskell-project/biscuit-haskell/biscuit/src/Auth/Biscuit.hs
```

After implementing the module and tests:

```bash
cabal test en-biscuit
cabal build all
```

Expected test result:

```text
Test suite en-biscuit-tests: PASS
```


## Validation and Acceptance

Acceptance requires:

- `cabal test en-biscuit` passes.
- A test for an object grant proves these facts exist:
  `en_subject`, `en_right`, `en_schema_hash`, `en_consistency_token`,
  `en_audience`, and `en_expires_at`.
- A test for a scoped grant proves `en_scoped_right` and one
  `en_container_scope` fact per container exist.
- The `En.Biscuit.Grant` module imports only `en-core` and Biscuit/library
  dependencies; it does not import `en-servant`, `en-server`, or Shomei.
- The top-level `En.Biscuit` module re-exports the grant API.


## Idempotence and Recovery

This plan is additive. Re-running tests is safe. If the Biscuit AST constructors
are too unstable or verbose, render Datalog snippets in a single internal
helper and parse them through the library parser. Record that decision here
before proceeding so `EP-30` and `EP-31` consume the same helper.


## Interfaces and Dependencies

New module:

- `en-biscuit/src/En/Biscuit/Grant.hs`

Required exported API:

```haskell
newtype Audience = Audience Text
newtype RequestId = RequestId Text
newtype RevocationId = RevocationId Text

data EnGrant
data EnScopedGrant
data EnBiscuitGrant = ObjectGrant EnGrant | ScopedGrant EnScopedGrant

grantBlock :: EnBiscuitGrant -> Either EnBiscuitError Block
grantFactsText :: EnBiscuitGrant -> Text
```

If the exact `Block` type requires a different signature, update this plan with
the real `Auth.Biscuit` type and keep `grantFactsText` or an equivalent testable
representation.
