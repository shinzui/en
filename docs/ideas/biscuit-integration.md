# Biscuit Integration Idea

> **Status: shipped.** This initiative is implemented as the optional
> `en-biscuit` package. For the user-facing guide and the shipped API, see
> [`docs/user/biscuit-decision-tokens.md`](../user/biscuit-decision-tokens.md).
> This note is retained as background design rationale.

This note sketches how `en` could integrate with Biscuit tokens to reduce
authorization fan-out across distributed microservices.

References:

- Biscuit website: <https://www.biscuitsec.org/>
- Biscuit specification repository: <https://github.com/eclipse-biscuit/biscuit>
- Haskell implementation: <https://github.com/eclipse-biscuit/biscuit-haskell>

The goal is not to replace `en`. `en` remains the centralized relationship
graph and the source of truth for ReBAC decisions. Biscuit can be an optional
decision-token layer that carries a short-lived, attenuable proof derived from
an `en` decision across a request chain.

## Problem

In a GraphQL gateway or backend-for-frontend, one user-facing request often
fans out to many services:

```text
client
  -> GraphQL gateway
      -> document service
      -> activity service
      -> search service
      -> notification service
```

If every downstream service repeats the same user-to-object check against
`en`, the request path develops authorization fan-out:

- More network hops to the authorization service.
- More load on the tuple store.
- More duplicated decision logic around consistency, deadlines, and caching.
- More chances for a service to accidentally make a different authorization
  decision for the same request.

The existing `en` guidance is to enforce at user-facing boundaries and
resource-owning services, then let downstream services trust narrowed requests
when they are acting on behalf of an already-authorized service. Biscuit gives
that trust boundary a concrete credential format.

## Proposed Role

Add an optional package or integration layer:

```text
en-biscuit
  En.Biscuit.Grant
  En.Biscuit.Mint
  En.Biscuit.Verify
```

The layer would:

1. Call `en.check` or `en.lookup`.
2. Mint a Biscuit only when `en` returns `Allowed`.
3. Encode the bounded grant, consistency information, and expiry in the token.
4. Let downstream services verify the token locally using the Biscuit public
   key and application-provided facts.

The architecture becomes:

```text
GraphQL gateway / resource owner
  -> en.check or en.lookup
  -> Allowed at revision R
  -> mint short-lived Biscuit
  -> call downstream services with Biscuit

Downstream service
  -> verify Biscuit signature locally
  -> check token constraints locally
  -> call en only if it owns a new protected decision
```

This turns an `en` decision into a portable proof for one request chain. It does
not move group traversal, page hierarchy inheritance, lookup, revocation review,
or long-lived authorization state into Biscuit.

## Grant Shape

A minimal grant record could be:

```haskell
data EnGrant = EnGrant
    { subject :: Subject
    , permission :: RelationName
    , object :: ObjectRef
    , consistencyToken :: ConsistencyToken
    , schemaHash :: SchemaHash
    , expiresAt :: UTCTime
    , audience :: Text
    , requestId :: Text
    }
```

For container-scoped list reads, the grant should carry a small authorized
container scope rather than a huge resource list:

```haskell
data EnScopedGrant = EnScopedGrant
    { subject :: Subject
    , permission :: RelationName
    , objectType :: ObjectType
    , containers :: [ObjectRef]
    , consistencyToken :: ConsistencyToken
    , schemaHash :: SchemaHash
    , expiresAt :: UTCTime
    , audience :: Text
    }
```

Examples:

```text
subject = user:alice
permission = view
object = document:roadmap
schema_hash = ...
consistency_token = ...
audience = document-service
expires_at = now + 60s
```

```text
subject = user:alice
permission = view
object_type = document
containers = [page:proposal, page:appendix]
audience = document-service
expires_at = now + 60s
```

The first shape is for object detail reads and mutations. The second shape is
for list reads where the gateway has already used `en.lookup` to compute a
small authorized page, folder, space, or visibility-class set.

## Minting Flow

Mint only after an `Allowed` decision:

```haskell
authorizeAndMint subject permission object = do
    decision <-
        check
            consistencyStore
            tupleStore
            graph
            MinimizeLatency
            context
            subject
            permission
            object

    case decision of
        Right Allowed ->
            mintBiscuit
                EnGrant
                    { subject = subject
                    , permission = permission
                    , object = object
                    , consistencyToken = resolvedToken
                    , schemaHash = activeSchemaHash
                    , expiresAt = now + 60
                    , audience = "document-service"
                    , requestId = requestId
                    }
        Right Denied ->
            deny
        Right (Conditional _) ->
            deny
        Left err ->
            failClosed err
```

The token authority block should contain facts that are direct outputs of the
gateway decision, not a copy of the relationship graph. A downstream verifier
should check facts such as:

```text
subject("user", "alice")
right("document", "roadmap", "view")
en_schema_hash("...")
en_consistency_token("...")
audience("document-service")
request_id("...")
```

The verifier supplies ambient facts for the request:

```text
operation("view")
resource("document", "roadmap")
service("document-service")
time("2026-06-23T15:00:00Z")
```

The verifier policy requires the token to match the operation, resource,
service audience, and expiry.

## Attenuation

Biscuit's useful extra capability is attenuation. A service that receives a
broad token can pass on a narrower token without contacting the original
issuer.

Example:

```text
Gateway token:
  user:alice may view documents in page:proposal subtree for document-service

Document service attenuates before calling thumbnail service:
  user:alice may view thumbnails for document:roadmap only
```

The attenuated token should only add restrictions:

```text
resource("document", "roadmap")
operation("thumbnail")
audience("thumbnail-service")
expires_at <= original_expires_at
```

This is the main reason to use Biscuit rather than a plain signed JSON token:
the holder can safely narrow authority for the next hop.

## GraphQL Examples

Object detail resolver:

```text
Query.document(id: "roadmap")
  -> en.check user:alice view document:roadmap
  -> mint Biscuit for document:roadmap view, audience document-service
  -> call document service with Biscuit
  -> document service verifies locally
```

List resolver:

```text
Query.documents
  -> en.lookup user:alice view page
  -> keep Allowed pages [page:proposal, page:appendix]
  -> mint Biscuit with containers [page:proposal, page:appendix]
  -> call document service
  -> document service verifies token and applies:
       WHERE page_id = ANY(:authorized_pages)
```

Service-to-service fan-out:

```text
GraphQL gateway
  -> en.check user:alice view page:proposal
  -> mint page-scoped Biscuit for activity-service and search-service

activity-service
  -> verify token
  -> query activity WHERE page_id is under page:proposal

search-service
  -> verify token
  -> restrict search index query to page:proposal scope
```

## Invitation Example

Before a page invitation is accepted, the application can use a Biscuit as the
signed invite capability:

```text
subject_email("external@example.com")
invite("page", "proposal", "viewer")
invited_by("user", "alice")
expires_at("2026-06-30T00:00:00Z")
audience("invitation-service")
```

When the recipient accepts:

```text
Invitation service
  -> verifies Biscuit
  -> checks token has not expired or been revoked
  -> resolves/creates user:external
  -> writes en tuple:
       page:proposal#viewer@user:external
```

After acceptance, runtime authorization goes back through `en`. The Biscuit
invite token is not the long-lived access grant; it is a signed, expiring way to
claim the invitation.

## Verification Rules

Downstream services should verify:

- Biscuit signature is valid for a trusted issuer key.
- Token audience matches the service.
- Expiry has not passed.
- Operation matches the requested handler.
- Resource or container scope covers the requested resource.
- Subject matches the authenticated request chain if identity is also present.
- `schemaHash` is accepted by the deployment.
- Consistency token is from the expected `en` datastore and schema.
- Optional revocation id is not in a service-local or centralized revocation
  set.

If any check fails, the service fails closed.

## When to Still Call en

A downstream service should still call `en` when:

- It owns a new protected decision not represented in the token.
- The request is outside the Biscuit scope.
- The token is expired or too stale for the operation.
- The operation is revocation-sensitive.
- The service is performing a protected mutation.
- The service needs `lookup` for a container set the token does not carry.
- The service needs `expand` for review or audit UI.

Biscuit should reduce repeated checks, not hide cases where a fresh graph
decision is required.

## Revocation and Freshness

Biscuit tokens should be short-lived. A good default for request-chain tokens is
tens of seconds to a few minutes.

Revocation should be explicit:

- For ordinary request tokens, rely primarily on short expiry.
- For invite tokens, store invitation state and reject already-used, expired,
  or revoked invitations.
- For high-risk delegation, keep revocation identifiers and check them during
  verification.

The `en` consistency token inside the Biscuit is a statement about the graph
revision used to make the original decision. It is not a guarantee that the
decision is still current after revocation. Use shorter expiries or require a
fresh `en.check` for sensitive operations.

## Package Boundary

A future package should keep Biscuit optional:

```text
en-core
  no Biscuit dependency

en-biscuit
  depends on en-core
  depends on biscuit-haskell
  provides grant encoding, minting, verification helpers

host application
  decides key management, token transport, audiences, revocation, and freshness
```

This avoids making the core authorization engine depend on one token format and
keeps embedded users free to use plain `check` and `lookup`.

## Non-Goals

The integration should not:

- Reimplement group membership or page inheritance in Biscuit Datalog.
- Put the full `en` relationship graph into tokens.
- Replace `lookup` for list authorization.
- Replace `expand` for audit and review.
- Make long-lived object permissions depend on bearer tokens.
- Expose raw `en` tuple writes to browsers.

Keep relationship logic in `en`. Use Biscuit for bounded, portable,
attenuable grants derived from `en` decisions.

## Open Questions

- What is the exact Datalog vocabulary for `en` grants?
- Should grants carry object scope, container scope, or both?
- How should `ConsistencyToken` be encoded in Biscuit facts?
- Should `schemaHash` be mandatory in every grant?
- What is the default token lifetime for request-chain delegation?
- Should `en-biscuit` provide WAI/Servant helpers using `biscuit-wai` and
  `biscuit-servant`?
- Where should revocation identifiers be stored for invite tokens and
  high-risk delegated tokens?
