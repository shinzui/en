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

- [ ] M1: Define `En.Biscuit.Grant` with object grants, scoped/container grants, audiences, expiry, and request metadata.
- [ ] M2: Define the stable Biscuit predicate vocabulary and rendering helpers.
- [ ] M3: Add pure tests for object grants, scoped grants, schema hash, consistency token, audience, expiry, and subject encoding.
- [ ] M4: Update `En.Biscuit` top-level exports.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery during planning: Biscuit facts are ordinary Datalog predicates.
  `Auth.Biscuit.Example` uses facts such as `right("file1", {allowedOperations})`
  and authorizer facts such as `time({now})`. The `en` vocabulary should
  follow that style but avoid ambiguous generic names where `en_`-prefixed
  names make provenance clearer.
  Date: 2026-07-01


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


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


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
