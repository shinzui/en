---
id: 5
slug: add-biscuit-decision-token-support
title: "Add Biscuit decision-token support"
kind: master-plan
created_at: 2026-07-01T04:50:28Z
intention: intention_01kwe136p1expbzvj08bqwtz08
---

# Add Biscuit decision-token support

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

`en` is the relationship-based authorization engine and source of truth for
decisions. Today a gateway or resource-owning service can call `/check`,
`/batch-check`, or `/lookup`, but there is no first-class way to carry the
result of that decision through a microservice request chain. This initiative
adds an optional `en-biscuit` package that turns a successful `en` decision into
a short-lived Biscuit token: a signed, attenuable bearer credential that
downstream services can verify locally without calling `en-server` again for
the same user/object/scope decision.

After the initiative, a service can authenticate a caller with Shomei, convert
the authenticated Shomei principal into an `En.Tuple.Subject`, call `en.check`
or `en.lookup`, mint a Biscuit only when the decision is `Allowed`, and pass
that token to downstream services. The downstream service verifies the Biscuit
signature and Datalog policy locally, checks audience, expiry, subject, service,
operation, resource or container scope, schema hash, and consistency-token
metadata, and calls `en` only when it owns a new protected decision or requires
fresh graph state.

The initiative is intentionally optional. `en-core` remains free of Biscuit,
Servant, WAI, Shomei, and HTTP dependencies. `en-servant`, `en-server`, and
existing clients continue to work unchanged unless they opt into the new
package. Shomei remains the authentication system: it verifies login/session
JWTs, publishes JWKS, and produces the user principal. Biscuit does not replace
Shomei, does not authenticate browsers by itself, and must not become a
long-lived permission store. Biscuit tokens carry bounded authorization grants
derived from `en`, not copies of the relationship graph.

In scope: package scaffolding for `en-biscuit`, a typed grant model, a stable
Biscuit fact vocabulary for `en` decisions, minting helpers over `en` decisions,
local verification and attenuation helpers, Servant/WAI integration points where
they fit, and documentation/examples that show Shomei authentication followed by
`en` authorization and Biscuit delegation. Out of scope: reimplementing group
membership or inheritance in Biscuit Datalog, replacing `/lookup` or `/expand`,
changing the existing `/check` wire API, storing raw tuple writes in browsers,
or moving Shomei JWT/session concerns into `en-biscuit`.


## Decomposition Strategy

The work is split by functional boundary. `EP-28` creates the optional package
and dependency wiring so later plans have a real compilation target but
`en-core` stays dependency-light. `EP-29` defines the typed grant model and the
Biscuit fact vocabulary; every later plan consumes that vocabulary, so it is the
integration spine. `EP-30` mints grants from successful `en` decisions. `EP-31`
verifies and attenuates those grants locally in downstream services. `EP-32`
documents and demonstrates the complete adoption shape, especially the
compatibility rule that Shomei authenticates and `en-biscuit` authorizes.

This ordering keeps speculative service integration from blocking the stable
core vocabulary. It also lets a contributor validate Biscuit independently:
after `EP-29`, pure encode/decode tests prove the facts are stable; after
`EP-30`, minting tests prove `Denied` and `Conditional` fail closed; after
`EP-31`, local verification tests prove downstream services can avoid repeated
`en-server` calls inside token scope.

Rejected alternatives: putting Biscuit support in `en-core` would force every
embedded user to take a token-format dependency. Adding only documentation would
not provide a reusable, type-checked way to keep facts, audiences, and expiry
consistent across services. Making Biscuit the primary authorization model was
rejected because `en` already owns graph traversal, consistency tokens,
`lookup`, and `expand`; Biscuit should carry bounded proofs derived from those
decisions, not replace them.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 28 | Add the en-biscuit package and dependency wiring | docs/plans/28-add-the-en-biscuit-package-and-dependency-wiring.md | None | None | Complete |
| 29 | Define the en Biscuit grant vocabulary | docs/plans/29-define-the-en-biscuit-grant-vocabulary.md | EP-28 | None | Complete |
| 30 | Mint Biscuit grants from en decisions | docs/plans/30-mint-biscuit-grants-from-en-decisions.md | EP-29 | None | Complete |
| 31 | Verify and attenuate en Biscuit grants locally | docs/plans/31-verify-and-attenuate-en-biscuit-grants-locally.md | EP-29 | EP-30 | Not Started |
| 32 | Document Shomei-compatible Biscuit authorization flows | docs/plans/32-document-shomei-compatible-biscuit-authorization-flows.md | EP-30, EP-31 | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

`EP-28` is first because every other plan needs an `en-biscuit` package target
with dependencies on `en-core`, `biscuit-haskell`, `time`, `text`, and test
libraries. It also records any Cabal or Nix wiring needed to make the local Mori
registered dependency build under this repository's GHC.

`EP-29` depends hard on `EP-28` because the grant modules must live in a real
package. It defines the shared types and Datalog vocabulary. `EP-30` depends
hard on `EP-29` because minting must emit the vocabulary exactly. `EP-31`
depends hard on `EP-29` because verification must consume the same vocabulary;
it has only a soft dependency on `EP-30` because verifier tests can construct
test tokens directly, but integration tests become stronger once minting exists.
`EP-32` depends hard on `EP-30` and `EP-31` because the adoption docs and
examples should show the real minted and verified path, not pseudocode.

Parallelism: after `EP-29` lands, `EP-30` and `EP-31` can proceed in parallel
if they both respect the vocabulary and error types defined by `EP-29`. `EP-32`
should wait until both are complete so it documents shipped names and behavior.


## Integration Points

`en-biscuit/en-biscuit.cabal` and `cabal.project` are shared by all child plans.
`EP-28` owns the initial package stanza and package list. Later plans add
exposed modules and dependencies only when their code requires them.

`En.Biscuit.Grant` is the central shared API. `EP-29` owns the grant types,
including object grants, scoped/container grants, audiences, expiry,
schema-hash and consistency-token fields, and the subject encoding. `EP-30`
constructs those types from `en` decisions. `EP-31` consumes them during local
verification and attenuation. `EP-32` documents them.

The Biscuit Datalog vocabulary is shared by `EP-29`, `EP-30`, and `EP-31`.
`EP-29` owns predicate names and arity, for example `en_subject`, `en_right`,
`en_container_scope`, `en_schema_hash`, `en_consistency_token`,
`en_audience`, `en_request_id`, `operation`, `resource`, `service`, and
`time`. Later plans must not invent alternate predicate names for the same
concept.

`En.Biscuit.Mint` is owned by `EP-30`. Its primary, portable deliverable mints
from a *precomputed* `En.Decision.CheckDecision` (re-exported by `En.Check`), so
the reusable signing helper stays `MonadIO m` and does not entangle the engine.
Any convenience helper that *runs* a decision must call the real engine
functions `En.Check.check`, `En.Check.checkMany`, or `En.Lookup.lookup`, which
are `effectful` computations of shape
`(ConsistencyStore :> es, TupleStore :> es, Error EnError :> es) => ... -> Eff es CheckDecision`
(not `IO`, and not plain `MonadIO m` — see the Surprises & Discoveries note on
the effectful engine). Such a helper therefore runs in `Eff es` and carries
those effect constraints. Either path must mint only on `Allowed` and fail
closed on `Denied`, `Conditional`, and engine errors — the same fail-closed rule
`En.Servant.Authorize.requirePermission` already applies for route guards.

`En.Biscuit.Verify` is owned by `EP-31`. It must verify a trusted issuer key,
audience, expiry, subject, operation, resource/container coverage, schema hash,
consistency-token metadata, and optional revocation identifier. It may wrap
`biscuit-servant` or `biscuit-wai`, but the pure verifier remains usable without
Servant.

Shomei compatibility is an integration rule, not a package dependency.
`EP-32` owns the documentation and example flow. `en-biscuit` should not depend
on `shomei-core`, `shomei-jwt`, or `shomei-servant`; host applications adapt a
verified `Shomei.Servant.Auth.AuthUser` or `Shomei.Domain.Claims.AuthClaims`
into an `En.Tuple.Subject` before minting or verification.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-28: `en-biscuit` package builds as an optional target without changing `en-core` (2026-06-30)
- [x] EP-28: Biscuit dependency wiring is validated against the Mori-registered local source (2026-06-30)
- [x] EP-29: Grant types and stable Biscuit predicate vocabulary are implemented and tested (2026-06-30)
- [x] EP-29: Encoding tests prove object and container grants round-trip through Biscuit facts (2026-06-30)
- [x] EP-30: Minting helpers create tokens only after `Allowed` decisions (2026-06-30)
- [x] EP-30: Denied, conditional, and error decisions fail closed and do not mint tokens (2026-06-30)
- [ ] EP-31: Local verification accepts in-scope tokens and rejects wrong audience, expired, wrong subject, and wrong resource cases
- [ ] EP-31: Attenuation can narrow broad grants for a downstream service without contacting `en`
- [ ] EP-32: User docs explain the Shomei authentication plus `en` authorization plus Biscuit delegation flow
- [ ] EP-32: Example or test demonstrates a downstream service verifying Shomei identity and Biscuit authorization locally


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- Discovery during decomposition: `eclipse-biscuit/biscuit-haskell` is already
  registered in Mori at `/Users/shinzui/Keikaku/hub/haskell/biscuit-haskell-project`
  with packages `biscuit-haskell`, `biscuit-servant`, and `biscuit-wai`.
  `mori registry docs eclipse-biscuit/biscuit-haskell` reports no curated docs,
  so child plans must read the local source and READMEs directly.
  Date: 2026-07-01

- Discovery during decomposition: Shomei is authentication, not authorization.
  `Shomei.Servant.Auth.Authenticated` verifies a Bearer JWT or session cookie
  and produces `AuthUser`; the microservice example verifies Shomei JWTs
  locally against a TTL-cached JWKS. That does not conflict with `en-biscuit`;
  it is the identity precondition for minting or verifying authorization
  grants.
  Date: 2026-07-01

- Discovery during decomposition: the existing `en-servant` cabal description
  already says route protection is based on an `en.check` decision against a
  caller's verified Shomei identity. The Biscuit work should preserve that
  ordering and make downstream delegation explicit.
  Date: 2026-07-01

- Validation 2026-06-30: the `en-core` engine is `effectful`, not `IO`. `check`,
  `checkMany`, and `checkCached` (`en-core/src/En/Check.hs`) and `lookup`,
  `lookupWithDeadline` (`en-core/src/En/Lookup.hs`) are `Eff es` functions
  constrained by `(ConsistencyStore :> es, TupleStore :> es, Error EnError :> es)`.
  There is no `en` record or namespace value; the prose shorthand `en.check`
  means the module-qualified function `En.Check.check`. Consequence for `EP-30`:
  a helper that *runs* a decision cannot be `MonadIO m`; it must run in `Eff es`
  with the engine effect constraints. The `MonadIO m` surface is correct only for
  helpers that take a precomputed `CheckDecision` and do Biscuit signing/parsing
  (which works because `Eff es` is a `MonadIO` when `IOE :> es`). The migration
  to `effectful` is already landed (see the `en effectful migration` ExecPlan 25;
  commits `d30ba63`, `d03f599`, `f047f58`).
  Date: 2026-06-30

- Validation 2026-06-30: `En.Servant.Authorize.requirePermission`
  (`en-servant/src/En/Servant/Authorize.hs`) already gates a route on a decision
  and fails closed on **both** `Denied` and `Conditional` (each throws `err403`).
  The `en-biscuit` mint rule ("mint only `Allowed`; `Conditional` is not
  mintable") and the `EP-31` verifier are the downstream-local analog of this
  guard and share exactly that semantics. `EP-32` docs should present the Biscuit
  verifier as the delegated, local counterpart of `requirePermission`, not a new
  policy.
  Date: 2026-06-30

- Validation 2026-06-30: the Shomei→`en` route guard is currently aspirational.
  `en-servant`'s cabal description references a "verified shomei identity
  (kikan C11)", but no Shomei import, JWT/JWKS handling, or header-to-`Subject`
  extraction exists in `en-servant` today; `requirePermission` takes an
  already-built `Subject`. This reinforces the initiative's decision to keep
  `shomei-*` out of `en-biscuit` deps and leave the `AuthUser`/`AuthClaims` →
  `En.Tuple.Subject` mapping to host applications (`EP-32`).
  Date: 2026-06-30

- EP-28 outcome 2026-06-30: the Hackage `biscuit-haskell-0.4.0.0` release does
  **not** build under this repo's GHC 9.12.4 — it caps `template-haskell < 2.22`
  while GHC 9.12.4 ships `template-haskell 2.23`. The Mori-registered source
  (`eclipse-biscuit/biscuit-haskell`, GitHub `shinzui/biscuit-haskell-project`,
  commit `aef4272f0d44eec75c79aa6c2dd00c4200401829` on `origin/master`) is the
  same version 0.4.0.0 but has widened bounds (`template-haskell < 2.24`,
  `megaparsec < 9.8`). EP-28 wired it via a `source-repository-package` git
  stanza in `cabal.project` (`subdir: biscuit-haskell/biscuit`, only the
  `biscuit-haskell` package). Consequence for **all later plans**: `biscuit-haskell`
  is available from that pinned commit, not Hackage; when EP-31 needs
  `biscuit-servant`/`biscuit-wai`, add sibling `source-repository-package`
  stanzas for `subdir: biscuit-haskell/biscuit-servant` and
  `biscuit-haskell/biscuit-wai` at the same (or a newer verified) commit rather
  than expecting Hackage to resolve. The `En.Biscuit` module is currently an
  empty placeholder awaiting EP-29's grant vocabulary.
  Date: 2026-06-30

- EP-30 outcome 2026-06-30: `en-biscuit/src/En/Biscuit/Mint.hs` mints tokens
  from `en` decisions, re-exported from `En.Biscuit`. Two layers, as the
  MasterPlan specified: (1) the portable `MonadIO m` "decision → token" API —
  `mintObjectGrant`/`mintObjectGrantWithExpiry` (precomputed `CheckDecision`) and
  `mintScopedGrant`/`mintScopedGrantWithExpiry` (bounded container list); (2) the
  `Eff es` convenience `mintCheckedObjectGrant`, constrained by
  `(ConsistencyStore :> es, TupleStore :> es, IOE :> es)`, which runs
  `En.Check.check` and discharges `Error EnError` locally (via
  `runErrorNoCallStack @EnError`) into `EngineError`. Mint fails closed on
  `Denied`/`Conditional`/engine-error/`GrantEncodingError`; only `Allowed` (and
  bounded, non-empty scopes) reach `mkBiscuit`. Issuer-authoritative expiry:
  mint stamps `now + defaultTtl`, overwriting any caller-supplied `expiresAt`
  (`…WithExpiry` for explicit). Consequences for **EP-31**: verify against the
  exact minted facts (`en_right`, `en_scoped_right`, `en_container_scope`,
  `en_audience`, `en_expires_at`, `en_consistency_token`, `en_schema_hash`,
  optional `en_request_id`/`en_revocation_id`) and treat expiry as
  issuer-controlled. `EnBiscuitMintError` dropped the planned
  `BiscuitBuildFailed` (mkBiscuit can't fail with a value) and added
  `EmptyLookupScope`/`GrantEncodingError`. `en-biscuit` now depends on
  `effectful`/`effectful-core`; `en-core` still has no Biscuit surface.
  Date: 2026-06-30

- EP-29 outcome 2026-06-30: the grant vocabulary is implemented in
  `en-biscuit/src/En/Biscuit/Grant.hs` and re-exported from `En.Biscuit`. Two
  contracts later plans (`EP-30` mint, `EP-31` verify) must consume as-is:
  (1) **API** — `EnGrant`, `EnScopedGrant`, `EnBiscuitGrant(ObjectGrant|ScopedGrant)`,
  the token-local newtypes `Audience`/`RequestId`/`RevocationId`,
  `EnBiscuitError(UnsupportedSubject)`, and
  `grantBlock :: EnBiscuitGrant -> Either EnBiscuitError Block` (the single fact
  builder) plus `grantFactsText :: EnBiscuitGrant -> Either EnBiscuitError Text`.
  Note `grantFactsText` returns `Either` (refined from the plan's `Text`).
  (2) **Vocabulary** — `en_subject`, `en_right`, `en_scoped_right`,
  `en_container_scope`, `en_schema_hash`, `en_consistency_token`, `en_audience`,
  `en_expires_at`, `en_request_id`, `en_revocation_id`. Facts are built via the
  `[block|…|]` quasiquoter (`ToTerm` escaping; `Block` is a `Monoid`, so
  per-container facts `mconcat`), and a non-concrete subject (`SubjectSet`/
  `SubjectWildcard`) fails closed with `UnsupportedSubject` — `EP-30` minting
  must propagate that as a non-mint, consistent with mint-only-`Allowed`.
  `EP-31` should verify against these exact predicate names/arities. Injection
  safety is proven semantically (mint + authorizer query of a forged fact), not
  by substring counting.
  Date: 2026-06-30

- Validation 2026-06-30: the grant vocabulary types all exist as `EP-29` assumes.
  `Subject = SubjectId ObjectRef | SubjectSet ObjectRef RelationName | SubjectWildcard ObjectType`
  (`en-core/src/En/Tuple.hs`); `ObjectRef` is `{ objectType :: ObjectType, objectId :: Text }`;
  `ObjectType`/`RelationName` live in `En.Schema.Types`; `SchemaHash`,
  `ConsistencyToken`, and `DatastoreId` are `newtype … Text` in
  `en-core/src/En/Revision.hs`. `Subject` includes a third `SubjectWildcard`
  constructor — `EP-29` correctly defers `en_subject_wildcard()` rather than
  emitting wildcard grants.
  Date: 2026-06-30


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Add Biscuit support as a new optional `en-biscuit` package rather
  than adding Biscuit dependencies to `en-core`.
  Rationale: `en-core` is the transport- and database-agnostic engine. Keeping
  Biscuit optional preserves embedded users who want plain `check`, `lookup`,
  and `expand` without a token format dependency.
  Date: 2026-07-01

- Decision: Treat Shomei as authentication only and keep it out of
  `en-biscuit` dependencies.
  Rationale: Shomei verifies identity and session state through JWT/JWKS and
  produces a principal. `en` decides whether that principal can perform an
  action. Biscuit carries a bounded proof of that authorization decision.
  Mixing these layers would make ownership unclear and could let an
  authorization token be mistaken for login/session proof.
  Date: 2026-07-01

- Decision: Tokens are short-lived decision grants, not long-lived permission
  state.
  Rationale: Revocation and graph traversal remain in `en`. A Biscuit can safely
  reduce repeated downstream checks only while its audience, expiry, and scope
  are narrow enough that stale authorization is acceptable.
  Date: 2026-07-01

- Decision: Use the Mori-registered `eclipse-biscuit/biscuit-haskell` source,
  including `biscuit-servant` and `biscuit-wai` where useful, after validating
  the actual APIs in local source.
  Rationale: The repository already has the dependency indexed locally, and the
  API surface includes `mkBiscuit`, `addBlock`, `parseB64`, `parseWith`,
  `authorizeBiscuit`, `authorizer`, `block`, `defaultBiscuitConfig`,
  `authHandlerWith`, and `checkBiscuitM`, which match the needed mint, verify,
  and Servant integration shapes.
  Date: 2026-07-01

- Decision: Public `en-biscuit` minting and verification helpers should be
  polymorphic over `MonadIO m` rather than returning concrete `IO`.
  Rationale: Biscuit's Haskell APIs perform `IO`, but host applications will
  call the helpers from `Handler`, `ReaderT`, `Eff es`, or another application
  monad. `MonadIO m` keeps the reusable package easy to embed while still
  allowing thin `IO` convenience wrappers where useful. This applies to the
  helpers that take a precomputed `CheckDecision` and only do Biscuit
  signing/parsing.
  Date: 2026-07-01

- Decision (refinement 2026-06-30): a helper that *runs* an `en` decision (rather
  than accepting a precomputed one) must run in `effectful`'s `Eff es`, not
  `MonadIO m`. `En.Check.check`/`checkMany` and `En.Lookup.lookup` are
  `(ConsistencyStore :> es, TupleStore :> es, Error EnError :> es) => … -> Eff es _`.
  The `MonadIO m` "decision → token" API is therefore the required, portable
  deliverable in `EP-30`; any check-running convenience is an `Eff es` wrapper
  layered on top, so `en-core` never gains a Biscuit or `MonadIO`-only surface.
  Rationale: keeps the token layer embeddable by both `Eff`-based hosts (this
  repo's `en-server`, which interprets `Eff` down to Servant `Handler`) and any
  future non-`effectful` caller.
  Date: 2026-06-30


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

(To be filled during and after implementation.)


## Revision Notes

- 2026-06-30 — Validation pass against the current `en` tree (requested: "is the
  plan correct and does it fit the vision and architecture of en?"). Verdict:
  the decomposition, ordering, dependency graph, and the optional-package
  boundary are sound, and every referenced type/function exists as the child
  plans assume. Corrections applied to reflect the codebase as it stands after
  the `effectful` migration (ExecPlan 25):
  - Integration Points (`En.Biscuit.Mint`): clarified that `check`/`checkMany`/
    `lookup` are `Eff es` engine functions, that the portable deliverable mints
    from a precomputed `CheckDecision`, and that a decision-running helper runs
    in `Eff es` with engine effect constraints.
  - Decision Log: refined the `MonadIO m` decision and added a follow-up decision
    separating the portable `MonadIO m` "decision → token" API from any `Eff es`
    check-running convenience.
  - Surprises & Discoveries: recorded the effectful engine shape, the
    `requirePermission` fail-closed analog (Denied and Conditional both 403), the
    currently-aspirational Shomei guard in `en-servant`, and confirmation of the
    `EP-29` grant vocabulary types (including the deferred `SubjectWildcard`).
  No child plans were restructured; `EP-30` already hedged toward the low-level
  "decision → token" API as its required deliverable, which this pass confirms as
  the correct primary target.
