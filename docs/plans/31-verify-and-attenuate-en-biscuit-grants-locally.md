---
id: 31
slug: verify-and-attenuate-en-biscuit-grants-locally
title: "Verify and attenuate en Biscuit grants locally"
kind: exec-plan
created_at: 2026-07-01T04:50:38Z
master_plan: "docs/masterplans/5-add-biscuit-decision-token-support.md"
intention: intention_01kwe136p1expbzvj08bqwtz08
---

# Verify and attenuate en Biscuit grants locally

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan adds local verification and attenuation for `en` Biscuit grants. After
this change, a downstream service can receive a token minted by a gateway or
resource-owning service, verify it locally with the Biscuit issuer public key,
check that the token matches the requested operation/resource/service, and
avoid a repeated `en-server` call when the request is inside the grant scope.

The observable behavior is a test that accepts a valid token for the right
audience, subject, operation, resource, schema hash, and expiry, and rejects
wrong-audience, expired, wrong-resource, wrong-subject, wrong-schema, and
revoked-token cases. Another test attenuates a broader token to a narrower
downstream token without contacting `en`.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: Define verification request/context types and fail-closed error values. (2026-06-30) — `VerifyRequest m`, `VerifiedGrant`, `VerifiedScope`, and `EnBiscuitVerifyError` (`SignatureInvalid`, `MalformedGrant`, `Expired`, `WrongSubject`, `WrongAudience`, `UnacceptedSchemaHash`, `OperationNotAuthorized`, `ResourceNotInScope`, `Revoked`, `RestrictionFailed`) in `en-biscuit/src/En/Biscuit/Verify.hs`.
- [x] M2: Implement pure/local verification over the shared `en_*` vocabulary. (2026-06-30) — `verifyGrant` extracts the authority-block `en_*` facts via `queryRawBiscuitFacts`/`getSingleVariableValue` and compares them in Haskell to yield precise errors; no `en-server` call.
- [x] M3: Implement attenuation helpers that add only narrowing restrictions. (2026-06-30) — `attenuateGrant`/`Attenuation`/`noAttenuation` add a `check if` block over ambient request facts (`service`, `operation`, `resource`, `time`); Biscuit guarantees added blocks only narrow.
- [~] M4: Add optional Servant/WAI helpers. (2026-06-30) — **Deferred** (allowed by the plan). Adding `biscuit-servant` needs another `source-repository-package` subdir + Servant deps for a thin adapter; the pure verifier is the deliverable and fully covers acceptance. See Decision Log.
- [x] M5: Add tests for success, failure, revocation, and attenuation cases. (2026-06-30) — `cabal test en-biscuit` → `en-biscuit tests PASS`; covers valid object/scoped, wrong audience/subject/resource/schema, expired, revoked, scope-out, and attenuation narrowing (resource + service).


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery during planning: `biscuit-servant` provides `BiscuitConfig`,
  `authHandlerWith`, `defaultBiscuitConfig`, `checkBiscuitM`, and related
  helpers. Its auth handler checks signatures and parsing first; endpoint code
  still supplies an authorizer for request-specific Datalog checks.
  Date: 2026-07-01

- Implementation 2026-06-30: fact extraction works via
  `queryRawBiscuitFacts :: Biscuit -> Query -> Either String (Set Bindings)`
  where `Bindings = Map Text Value` (from `Auth.Biscuit.Datalog.Executor`) and
  `Query` from `Auth.Biscuit.Datalog.AST`. `getSingleVariableValue` pulls a
  single typed value (via `FromValue`, incl. `UTCTime` for `en_expires_at`).
  Crucially, **`queryRawBiscuitFacts` reads only the authority block by
  default** (confirmed by the library's own `ScopedExecutor` test: a
  `trusting`-less query ignores facts added in later blocks). Since minting puts
  all `en_*` facts in the authority block and attenuation only adds `check if`
  blocks, the verifier reads the immutable grant facts and cannot be fooled by an
  attenuation block that adds facts. This is what makes the "Haskell compares
  extracted facts" design sound.
  Date: 2026-06-30

- Implementation 2026-06-30: two distinct fact layers are needed. The @en_*@
  authority facts are checked in Haskell (for precise error values). Attenuation
  restrictions are enforced by running `authorizeBiscuit` with an authorizer that
  supplies *ambient request facts* — `operation(...)`, `resource(t,i)`,
  `service(...)`, `time(...)` — plus `allow if true`. An added `check if` block
  constrains those ambient facts, so Biscuit enforces the narrowing. An
  un-attenuated token has no block checks, so the authorizer step is a no-op that
  returns `Right`.
  Date: 2026-06-30

- Implementation 2026-06-30: for a scoped grant the verifier cannot traverse the
  graph, so "resource in scope" is enforced as **resource ∈ the token's
  `en_container_scope` set**, extracted as `(type,id)` pairs by iterating the
  `Set Bindings` rows (per-row pairing; `getVariableValues` would lose the
  type↔id pairing). This is the strongest sound local statement of a scoped
  grant.
  Date: 2026-06-30

- Implementation 2026-06-30: `-Wall` under GHC 9.12 *does* flag
  `-Wmissing-signatures` for top-level helpers whose types mention the biscuit
  library's `Query`/`Bindings`. Fixed by importing `Query`
  (`Auth.Biscuit.Datalog.AST`) and `Bindings` (`Auth.Biscuit.Datalog.Executor`)
  and giving explicit signatures. Also, record-dot on `VerifiedGrant` in tests
  needs its fields in scope (`import … (VerifiedGrant (..))`) because the field
  names are shared with `VerifyRequest` under `DuplicateRecordFields`; a record
  pattern is clearest.
  Date: 2026-06-30


## Decision Log

Record every decision made while working on the plan.

- Decision: Keep pure verification independent from Servant and WAI.
  Rationale: Downstream services may not use Servant, and tests should prove
  the token semantics without web-server machinery. Servant/WAI wrappers can be
  thin adapters over the pure verifier.
  Date: 2026-07-01

- Decision: Verification must not silently fall back to calling `en`.
  Rationale: The point of a Biscuit grant is local proof. Callers may choose to
  call `en` after a local failure, but the verifier itself should return a
  fail-closed error that makes the reason explicit.
  Date: 2026-07-01

- Decision (2026-06-30): Verify base-grant facts in Haskell (extracted from the
  authority block) for precise per-condition errors, and enforce attenuation via
  a Biscuit authorizer that supplies ambient request facts. Rationale: a single
  monolithic authorizer allow/deny cannot say *which* condition failed
  (wrong-audience vs expired vs wrong-subject …), which the acceptance criteria
  require; extracting facts and comparing in Haskell gives typed errors.
  Attenuation, by contrast, is naturally a Biscuit block-check over request
  facts, so it is enforced by the engine.
  Date: 2026-06-30

- Decision (2026-06-30): `VerifyRequest` keeps both `expectedAudience` and
  `serviceName`. `expectedAudience` is matched against the grant's `en_audience`
  (who the token was minted for); `serviceName` is this verifier's own identity,
  supplied as the authorizer `service` fact and the dimension attenuation can
  narrow. They are distinct: audience is the grant's target, service is the
  concrete caller. Attenuation's `narrowedService` narrows which service may use
  the token; audience (an authority fact) is not attenuable because Biscuit
  cannot change an authority fact — a genuine audience change means minting a new
  grant. This is the sound subset of the plan's "narrow audience/operation/
  resource"; the "audience" narrowing is realized as service narrowing.
  Date: 2026-06-30

- Decision (2026-06-30): `attenuateGrant` returns `m (Biscuit Open Verified)`
  (not `m (Either EnBiscuitVerifyError …)` as sketched). Rationale: `addBlock`
  cannot fail with a value, so an `Either` would always be `Right`; the plan's
  Interfaces section permitted signature refinement.
  Date: 2026-06-30

- Decision (2026-06-30): Defer the optional Servant/WAI module (M4). Rationale:
  the plan explicitly allows leaving pure verification as the deliverable if the
  web dependency adds drag. `biscuit-servant` would require a second
  `source-repository-package` subdir and Servant deps for a thin adapter over
  `verifyGrant`, and adds nothing to the acceptance criteria (all of which are
  about the pure verifier + attenuation). A host application can wrap `verifyGrant`
  in its own `Handler` in a few lines.
  Date: 2026-06-30


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

Outcome (2026-06-30): `En.Biscuit.Verify` lets a downstream service verify a
token locally and attenuate it before forwarding — no `en-server` round trip.
All acceptance criteria hold (proven by `cabal test en-biscuit`):

- Valid object grant (right subject/operation/resource/audience/schema, before
  expiry) → `Right VerifiedGrant`.
- Wrong audience → `WrongAudience`; expired → `Expired`; wrong subject →
  `WrongSubject`; wrong resource → `ResourceNotInScope`; unaccepted schema →
  `UnacceptedSchemaHash`; revoked → `Revoked` (all distinct, fail-closed).
- Scoped grant: request for an in-scope container succeeds; a resource outside
  the scope → `ResourceNotInScope`.
- Attenuated token: narrowed request (narrowed resource + service) verifies; the
  other in-scope resource and a different service both → `RestrictionFailed`,
  i.e. the token verifies for the narrowed request but not the broader original.

Deliverables: `en-biscuit/src/En/Biscuit/Verify.hs` (verification + attenuation),
re-exported from `En.Biscuit`; `en-biscuit` gained a `containers` dep. The pure
verifier is independent of Servant/WAI. Deviations (see Decision Log):
`attenuateGrant` returns the biscuit directly (no `Either`); `VerifyRequest`
keeps `expectedAudience` (grant target) and `serviceName` (caller identity, the
attenuable dimension); the optional Servant module (M4) is deferred.

This closes the core initiative: mint (EP-30) → verify/attenuate (EP-31) both
over the EP-29 vocabulary. EP-32 documents the end-to-end Shomei→en→Biscuit flow.


## Context and Orientation

This plan depends on
`docs/plans/29-define-the-en-biscuit-grant-vocabulary.md`. It can proceed in
parallel with `docs/plans/30-mint-biscuit-grants-from-en-decisions.md` after
the vocabulary exists, but integration tests become stronger once real minting
helpers exist.

Local verification means the downstream service checks a signed Biscuit and an
authorizer policy in its own process. It does not call `en-server` for graph
traversal. The verifier uses request facts supplied by the service: service
audience, operation, target resource, current time, authenticated subject, and
accepted schema hashes.

Attenuation means adding a new Biscuit block that narrows authority, for
example from "view documents in page:proposal for document-service" to "view
thumbnail for document:roadmap for thumbnail-service". Biscuit's `addBlock`
supports this shape: holders can add checks, but they cannot remove the
authority block or broaden earlier checks.


## Plan of Work

Milestone 1 creates `en-biscuit/src/En/Biscuit/Verify.hs`. Define the reusable
API over `MonadIO m` rather than concrete `IO`, so host applications can call it
from `Handler`, `ReaderT`, or their own application monad:

```haskell
data VerifyRequest m = VerifyRequest
    { expectedSubject :: Subject
    , expectedAudience :: Audience
    , operation :: RelationName
    , resource :: ObjectRef
    , serviceName :: Audience
    , acceptedSchemaHashes :: Set SchemaHash
    , now :: UTCTime
    , revoked :: RevocationId -> m Bool
    }
```

Define `EnBiscuitVerifyError` with constructors for parse/signature failure,
authorization failure, wrong audience, expired token, wrong subject,
wrong-resource/scope, unaccepted schema hash, consistency-token mismatch if
metadata is decoded, and revoked token.

Milestone 2 implements verification. Use `Auth.Biscuit.parseB64` or
`parseWith` with a `ParserConfig` that supplies the issuer public key and
revocation check. Build an authorizer that supplies ambient facts:

```text
operation("view");
resource("document", "roadmap");
service("document-service");
time(2026-07-01T00:00:00Z);
```

The authorizer should allow only when `en_right` or `en_scoped_right` plus
container scope matches the request, `en_audience` matches service,
`en_subject` matches the authenticated subject, `en_schema_hash` is accepted,
and the expiry check passes.

Milestone 3 adds attenuation in `En.Biscuit.Attenuate` or the same
`Verify` module if smaller. It should accept a verified/open token and add a
block containing only restrictions: narrower audience, operation, resource,
expiry no later than the original, and optional request id. It must not create
new `en_right` facts that broaden authority.

Milestone 4 adds optional web helpers. If `biscuit-servant` works cleanly,
create `En.Biscuit.Servant` with a helper that extracts a Biscuit token and
runs `verifyGrant` inside a handler. Keep this module in `en-biscuit` but put
the Servant dependency behind that module only. If adding the dependency causes
unacceptable build drag, document the reason and leave pure verification as the
deliverable.

Milestone 5 adds tests. Prefer in-process tests that use the minting helper from
`EP-30` once available. If `EP-30` is not complete, construct test tokens
directly with the grant vocabulary from `EP-29`.


## Concrete Steps

Work from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/en
sed -n '419,580p' /Users/shinzui/Keikaku/hub/haskell/biscuit-haskell-project/biscuit-haskell/biscuit-servant/src/Auth/Biscuit/Servant.hs
sed -n '1,220p' /Users/shinzui/Keikaku/hub/haskell/biscuit-haskell-project/biscuit-haskell/biscuit/src/Auth/Biscuit.hs
```

After implementation:

```bash
cabal test en-biscuit
cabal build all
```

Expected result:

```text
Test suite en-biscuit-tests: PASS
```


## Validation and Acceptance

Acceptance requires tests for:

- Valid object grant: subject `user:alice`, operation `view`, resource
  `document:roadmap`, service `document-service`, accepted schema hash, and
  current time before expiry returns success.
- Wrong audience returns a verification error.
- Expired token returns a verification error.
- Wrong subject returns a verification error.
- Wrong resource returns a verification error.
- Unaccepted schema hash returns a verification error.
- Revoked token returns a verification error.
- Scoped grant with matching container succeeds, and a resource outside the
  supplied scope fails.
- Attenuated token can narrow audience/operation/resource and still verifies
  for the narrowed request but not for the broader original request.


## Idempotence and Recovery

Verification tests should use fixed timestamps and deterministic keys. If
Biscuit authorizer syntax is difficult to generate dynamically, write a small
builder function that renders only the fixed predicates needed by this package
and test escaping. Do not duplicate the grant vocabulary; consume the constants
or helpers from `En.Biscuit.Grant`.

If `biscuit-servant` integration is blocked by version or API mismatch, keep
the pure verifier and record the blocker. The pure verifier is sufficient for
the initiative's core value.


## Interfaces and Dependencies

New modules:

- `en-biscuit/src/En/Biscuit/Verify.hs`
- Optional: `en-biscuit/src/En/Biscuit/Servant.hs`

Target API shape:

```haskell
data VerifyRequest m
data EnBiscuitVerifyError

verifyGrant ::
    MonadIO m =>
    PublicKey ->
    ByteString ->
    VerifyRequest m ->
    m (Either EnBiscuitVerifyError VerifiedGrant)

attenuateGrant ::
    MonadIO m =>
    Attenuation ->
    Biscuit Open Verified ->
    m (Either EnBiscuitVerifyError (Biscuit Open Verified))
```

`VerifiedGrant` should expose the matched subject, audience, operation,
resource or scope, schema hash, consistency token, expiry, and request id so a
handler can log or propagate them without re-parsing the token.
