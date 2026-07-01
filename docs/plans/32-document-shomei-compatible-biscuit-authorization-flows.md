---
id: 32
slug: document-shomei-compatible-biscuit-authorization-flows
title: "Document Shomei-compatible Biscuit authorization flows"
kind: exec-plan
created_at: 2026-07-01T04:50:46Z
master_plan: "docs/masterplans/5-add-biscuit-decision-token-support.md"
intention: intention_01kwe136p1expbzvj08bqwtz08
---

# Document Shomei-compatible Biscuit authorization flows

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan documents and demonstrates the complete adoption flow: Shomei
authenticates the request, `en` authorizes the authenticated subject, and
Biscuit carries a short-lived proof of that authorization to downstream
services. After this change, a developer can read the docs or run an example
and understand exactly when a service can verify locally and when it must still
call `en`.

The most important user-facing correction is conceptual: Shomei is for
authentication. Biscuit is not a replacement for Shomei sessions or JWTs.
`en-biscuit` is an authorization delegation layer minted from `en` decisions.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: Update user docs to explain the Shomei authentication plus `en` authorization plus Biscuit delegation sequence.
- [ ] M2: Add an example or test that maps a verified Shomei principal to an `en` subject before minting.
- [ ] M3: Add a downstream example or test that verifies Shomei identity and Biscuit authorization locally.
- [ ] M4: Document when downstream services must still call `en`.
- [ ] M5: Update README or package docs to point to the Biscuit integration guide.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery during planning: Shomei's `AuthUser` contains `authUserId`,
  `authSessionId`, roles, scopes, and raw `AuthClaims`. That is authentication
  context. `en` should receive a mapped `SubjectId (ObjectRef (ObjectType
  "user") userId)` or an application-specific subject mapping.
  Date: 2026-07-01

- Discovery during planning: Shomei's microservice example already proves a
  downstream service can verify JWTs locally from JWKS without calling the auth
  service per request. The Biscuit docs should mirror that deployment lesson:
  local verification is useful, but it verifies a different claim type.
  Date: 2026-07-01


## Decision Log

Record every decision made while working on the plan.

- Decision: Do not add a hard dependency from `en-biscuit` to Shomei.
  Rationale: Authentication stacks differ across adopters. Shomei is the
  expected companion in this ecosystem, but the reusable interface is "verified
  identity becomes `En.Tuple.Subject`".
  Date: 2026-07-01

- Decision: Document Biscuit and Shomei as two separate bearer tokens when both
  are present.
  Rationale: A Shomei JWT proves who the caller is and may carry scopes/roles.
  An `en` Biscuit proves a recent authorization decision. Mixing them in one
  `Authorization` header without guidance will confuse services and clients.
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This plan depends on
`docs/plans/30-mint-biscuit-grants-from-en-decisions.md` and
`docs/plans/31-verify-and-attenuate-en-biscuit-grants-locally.md`. The docs
should use the actual API names those plans ship.

Current `en` docs already explain the enforcement boundary:

- `docs/user/graphql-integration.md` says a GraphQL gateway or BFF should call
  `check`, `lookup`, and batching helpers at protected data boundaries, and
  downstream services should not repeat the same user-to-object decision unless
  they own another protected resource.
- `docs/user/production-deployment-and-performance.md` says not to make every
  microservice call `en` for every internal request.
- `docs/ideas/biscuit-integration.md` is the idea note this initiative
  implements.

Current Shomei source shows the authentication boundary:

- `/Users/shinzui/Keikaku/bokuno/shomei/shomei-servant/src/Shomei/Servant/Auth.hs`
  defines `Authenticated`, `AuthUser`, and `authHandler`.
- `/Users/shinzui/Keikaku/bokuno/shomei/examples/microservice-auth-stack/src/Downstream/Service.hs`
  verifies Shomei JWTs locally from a TTL-cached JWKS.

The docs must avoid saying Biscuit authenticates a browser user. It authorizes a
request only after the service already knows the authenticated subject.


## Plan of Work

Milestone 1 updates documentation. Add a Biscuit section to
`docs/user/production-deployment-and-performance.md` and/or create a new
`docs/user/biscuit-decision-tokens.md`. The guide must show this sequence:

```text
Client presents Shomei JWT/session
Gateway verifies Shomei identity locally or through Shomei guard
Gateway maps AuthUser/AuthClaims to En.Tuple.Subject
Gateway calls en.check or en.lookup
Gateway mints short-lived Biscuit only for Allowed
Downstream verifies Shomei identity and Biscuit authorization locally
Downstream calls en only for new or fresh decisions
```

Milestone 2 adds an example or test that maps a Shomei principal to an `en`
subject. Do not import Shomei in `en-biscuit`; if the example lives in
`en-example`, use a tiny local stand-in type with fields named like Shomei's
`AuthUser`, or put the Shomei-specific code in documentation. The reusable
function should look like:

```haskell
subjectFromUserId :: Text -> Subject
subjectFromUserId userId =
    SubjectId (ObjectRef (ObjectType "user") userId)
```

Milestone 3 adds a downstream verification example. The example should make it
obvious that a downstream service checks identity and authorization separately.
If a single HTTP request needs two bearer values, document the chosen transport,
for example `Authorization: Bearer <shomei-jwt>` plus `X-En-Biscuit: <token>`,
or another explicit header. Avoid silently overloading one header with two token
types.

Milestone 4 documents "when to still call `en`" in the user docs. Include at
least these cases: new protected decision, token outside scope, token expired or
too stale, revocation-sensitive operation, protected mutation, lookup scope not
carried by the token, and expand/audit UI.

Milestone 5 updates `docs/user/README.md` or the main `README.md` so users can
find the Biscuit guide.


## Concrete Steps

Work from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/en
sed -n '1,220p' docs/user/graphql-integration.md
sed -n '1,220p' docs/user/production-deployment-and-performance.md
sed -n '1,180p' /Users/shinzui/Keikaku/bokuno/shomei/shomei-servant/src/Shomei/Servant/Auth.hs
```

After documentation and examples:

```bash
cabal test en-biscuit
cabal test en-example
rg -n "Shomei|Biscuit|en-biscuit|X-En-Biscuit|Authorization" docs/user docs/ideas README.md
```

Expected test result:

```text
Test suite en-biscuit-tests: PASS
Test suite en-example-tests: PASS
```


## Validation and Acceptance

Acceptance requires:

- User docs state plainly that Shomei is authentication and `en-biscuit` is
  authorization delegation.
- Docs include a sequence diagram or text flow from Shomei authentication to
  `en.check`/`en.lookup` to Biscuit minting to downstream local verification.
- Docs list the cases where downstream services still call `en`.
- Examples or tests prove an authenticated principal is mapped to `Subject`
  before minting.
- Examples or tests prove a downstream request fails if either identity
  verification or Biscuit authorization fails.
- `docs/ideas/biscuit-integration.md` is either updated to point to the shipped
  guide or clearly marked as background design.


## Idempotence and Recovery

Documentation edits are safe to repeat. If importing Shomei directly into
`en-example` introduces a large dependency cycle or Cabal build burden, keep the
example Shomei-shaped but dependency-free and document the exact real Shomei
types by file path. Do not add Shomei as an `en-biscuit` dependency to make an
example convenient.


## Interfaces and Dependencies

Files likely touched:

- `docs/user/production-deployment-and-performance.md`
- `docs/user/graphql-integration.md`
- `docs/user/service-and-operations.md`
- `docs/user/README.md`
- Optional new `docs/user/biscuit-decision-tokens.md`
- Optional example/test files under `en-example/`

Required conceptual interface:

```haskell
-- Shomei side, in host application code:
-- AuthUser or AuthClaims has already been verified.

subjectFromAuthenticatedUser :: AuthenticatedUserLike -> Subject

-- en side:
-- call check/lookup for that subject

-- en-biscuit side:
-- mint only after Allowed; downstream verifies local token facts
```

The plan may reference Shomei source files, but reusable `en-biscuit` modules
must remain independent of Shomei packages.
