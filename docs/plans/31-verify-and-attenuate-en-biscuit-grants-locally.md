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

- [ ] M1: Define verification request/context types and fail-closed error values.
- [ ] M2: Implement pure/local verification over the shared `en_*` vocabulary.
- [ ] M3: Implement attenuation helpers that add only narrowing restrictions.
- [ ] M4: Add optional Servant/WAI helpers if they fit without making pure verification depend on web libraries.
- [ ] M5: Add tests for success, failure, revocation, and attenuation cases.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery during planning: `biscuit-servant` provides `BiscuitConfig`,
  `authHandlerWith`, `defaultBiscuitConfig`, `checkBiscuitM`, and related
  helpers. Its auth handler checks signatures and parsing first; endpoint code
  still supplies an authorizer for request-specific Datalog checks.
  Date: 2026-07-01


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


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


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
