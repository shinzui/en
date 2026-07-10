# Biscuit Decision Tokens

This guide explains the optional `en-biscuit` package: how to turn a successful
`en` authorization decision into a short-lived [Biscuit](https://www.biscuitsec.org/)
token, forward it through a chain of microservices, and verify it locally in a
downstream service without calling `en-server` again for the same decision.

Read [Production Deployment and Performance](production-deployment-and-performance.md)
first. `en-biscuit` is one tool for the problem that guide describes — keeping
authorization from becoming a fan-out where every internal hop re-asks `en` the
same question.

## The one thing to get right: Shomei authenticates, `en` authorizes, Biscuit delegates

These are three different jobs and three different tokens. Do not collapse them.

| Layer | Question it answers | Token | Owner |
| --- | --- | --- | --- |
| **Shomei** | *Who is calling?* (identity, session, roles) | Shomei JWT / session cookie | `shomei-*` |
| **`en`** | *May this subject do this to this object?* | — (a decision, not a token) | `en-core` |
| **`en-biscuit`** | *Here is a short-lived, signed proof of a recent `en` decision* | Biscuit | `en-biscuit` |

A Biscuit **is not** a login. It does not authenticate a browser user, it does
not replace a Shomei session, and it must not become a long-lived permission
store. It carries a bounded proof of one authorization decision. Revocation,
group membership, inheritance, and graph traversal all stay in `en`.

`en-biscuit` deliberately does **not** depend on `shomei-core`, `shomei-jwt`, or
`shomei-servant`. The only contract between the layers is: *a verified identity
becomes an `En.Tuple.Subject`.* Your host application owns that mapping.

## The end-to-end flow

```text
Client presents a Shomei JWT / session
        │
        ▼
Gateway verifies the Shomei identity            (Shomei: authentication)
        │   Shomei.Servant.Auth.Authenticated → AuthUser
        ▼
Gateway maps AuthUser / AuthClaims → En.Tuple.Subject
        │
        ▼
Gateway calls En.Check.check / En.Lookup.lookup  (en: authorization)
        │
        ▼
Gateway mints a short-lived Biscuit — only if the decision is Allowed
        │   En.Biscuit.Mint.mintObjectGrant
        ▼
Gateway forwards the request downstream with two tokens:
        │   Authorization: Bearer <shomei-jwt>     (still who the caller is)
        │   X-En-Biscuit:   <biscuit>              (the en decision proof)
        ▼
Downstream verifies the Shomei identity locally  (Shomei: JWKS, TTL-cached)
Downstream verifies the Biscuit locally          (en-biscuit: no en-server call)
        │   En.Biscuit.Verify.verifyGrant
        ▼
Downstream calls en only for a NEW protected decision or fresher graph state
```

Shomei's own microservice example
(`shomei/examples/microservice-auth-stack/src/Downstream/Service.hs`) already
shows a downstream service verifying Shomei JWTs locally from a TTL-cached JWKS.
`en-biscuit` mirrors that deployment lesson for authorization: local
verification is valuable, but the Biscuit verifies a *different* claim (a bounded
`en` decision) than the Shomei JWT (identity).

## Step 1 — map a verified identity to an `en` subject

The reusable interface is just `Text -> Subject`. In host code you build it from
a *verified* `Shomei.Servant.Auth.AuthUser` or `Shomei.Domain.Claims.AuthClaims`
(see `shomei/shomei-servant/src/Shomei/Servant/Auth.hs`):

```haskell
import Data.Text (Text)
import En.Tuple (ObjectRef (..), Subject (..))
import En.Schema (ObjectType (..))

-- | Map an authenticated user id to an en subject. Your application decides the
-- object type and id convention; this is the whole coupling between Shomei and en.
subjectFromUserId :: Text -> Subject
subjectFromUserId userId =
    SubjectId (ObjectRef (ObjectType "user") userId)

-- e.g. in a Servant handler that has already run Shomei's Authenticated guard:
-- let subject = subjectFromUserId authUser.authUserId
```

Keep this mapping in your application, not in `en-biscuit`. Different adopters
authenticate differently; the only thing `en-biscuit` needs is the resulting
`Subject`.

## Step 2 — decide, then mint (gateway side)

Minting lives in `En.Biscuit.Mint`. Only an `Allowed` decision produces a token;
`Denied`, `Conditional`, engine errors, and unencodable grants all return a
`Left EnBiscuitMintError` and never sign anything — the same fail-closed rule
`En.Servant.Authorize.requirePermission` applies to route guards.

```haskell
import En.Biscuit.Grant
import En.Biscuit.Keys (IssuerKeyId (..))
import En.Biscuit.Mint
import En.Revision (ConsistencyToken (..), SchemaHash (..))
import En.Schema (ObjectType (..), RelationName (..))
import En.Tuple (ObjectRef (..))

-- The issuer key is the Biscuit signing key. It is NOT a Shomei key.
config :: MintConfig IO
config =
    MintConfig
        { issuerSecretKey = issuerKey        -- Auth.Biscuit.SecretKey
        , issuerKeyId = IssuerKeyId 1         -- stamped into the token envelope;
                                              -- bump it when you rotate the key
        , defaultTtl = 300                    -- seconds; keep it short
        , now = getCurrentTime
        }

-- Build the grant that describes the decision, then mint it.
mintForDecision :: CheckDecision -> Subject -> IO (Either EnBiscuitMintError MintedGrant)
mintForDecision decision subject =
    mintObjectGrant config decision $
        EnGrant
            { subject = subject
            , permission = RelationName "view"
            , object = ObjectRef (ObjectType "document") "roadmap"
            , consistencyToken = ConsistencyToken "<from the en read>"
            , schemaHash = SchemaHash "<the active schema hash>"
            , expiresAt = someTime          -- overwritten by config's now + defaultTtl
            , audience = Audience "document-service"
            , requestId = Nothing
            , revocationId = Nothing
            }
```

Every mint returns a `MintedGrant` on success: `token` (the URL-safe base64
Biscuit you forward), `expiresAt` (the expiry actually stamped in), and
`revocationIds` (the token's built-in per-block revocation ids). Record
`revocationIds` if you might need to revoke the token before it expires — see
[Key rotation and revocation](#key-rotation-and-revocation).

Notes:

- **The issuer controls the lifetime.** `mintObjectGrant`/`mintScopedGrant` stamp
  the expiry as `now + defaultTtl`, overwriting the grant's `expiresAt`, so a
  grant builder cannot forge a long-lived token. Use
  `mintObjectGrantWithExpiry` / `mintScopedGrantWithExpiry` for an explicit
  absolute expiry.
- **The key id travels in the token envelope, not in a fact.** `issuerKeyId` is
  written to the Biscuit protobuf wrapper (`rootKeyId`), not to the `en_*`
  Datalog vocabulary, so the wire fact vocabulary is unchanged. A verifier in any
  language reads it from the envelope before checking the signature.
- **Non-concrete subjects fail closed.** A userset (`SubjectSet`) or wildcard
  (`SubjectWildcard`) subject is rejected with `GrantEncodingError`; only a
  concrete `SubjectId` is mintable.
- **List reads use `mintScopedGrant`.** It takes a `maxContainers` bound and a
  bounded list of container `ObjectRef`s you derived from `en.lookup`. It rejects
  an empty scope (`EmptyLookupScope`) and an oversized one (`LookupScopeTooLarge`)
  — a token must not become a dump of every authorized resource.
- **Running the check yourself.** If you want the token layer to *run* the
  decision, `mintCheckedObjectGrant` is an `effectful` helper
  (`(ConsistencyStore :> es, TupleStore :> es, IOE :> es) => …`) that calls
  `En.Check.check` and surfaces engine errors as `EngineError` without minting.
  The portable `MonadIO` `mintObjectGrant` above (precomputed decision) stays the
  reusable deliverable so `en-core` never gains a token or `MonadIO`-only surface.

## Step 3 — verify locally (downstream side)

Verification lives in `En.Biscuit.Verify`. It parses and checks the issuer
signature, then verifies expiry, subject, audience, schema hash, operation,
resource/scope, revocation, and any attenuation restrictions — all in-process. It
never falls back to calling `en`; each failure is a distinct, explicit
`EnBiscuitVerifyError`.

```haskell
import qualified Data.Set as Set
import En.Biscuit.Keys (IssuerKeySet)
import En.Biscuit.Verify

verifyDownstream :: IssuerKeySet -> ByteString -> Subject -> IO (Either EnBiscuitVerifyError VerifiedGrant)
verifyDownstream issuerKeys token authenticatedSubject =
    verifyGrant issuerKeys token $
        VerifyRequest
            { expectedSubject = authenticatedSubject   -- from the downstream's own Shomei check
            , expectedAudience = Audience "document-service"
            , operation = RelationName "view"
            , resource = ObjectRef (ObjectType "document") "roadmap"
            , serviceName = Audience "document-service" -- this service's identity
            , acceptedSchemaHashes = Set.singleton (SchemaHash "<accepted hash>")
            , now = requestTime
            , revoked = \_ -> pure False                -- optional en_revocation_id check
            , revokedBlockIds = \_ -> pure False        -- built-in block-id revocation set
            }
```

`verifyGrant` takes an **`IssuerKeySet`**, not a single public key: the token's
envelope key id selects which trusted key checks the signature. A downstream that
trusts one issuer key uses `singleKey (IssuerKeyId 1) issuerPublicKey`; during a
key rotation it trusts a keyset holding both the old and the new key. Building a
keyset from configuration is covered in [Key rotation and
revocation](#key-rotation-and-revocation).

`revokedBlockIds` is consulted on **every** token — build it with
`Auth.Biscuit.fromRevocationList` from your revocation set, or `\_ -> pure False`
if you keep none. `revoked` is the older, optional layer that fires only for
tokens carrying an application-level `en_revocation_id`.

`expectedSubject` must be the subject the downstream **independently**
authenticated (via its own local Shomei verification), not a value taken from the
Biscuit. That is what ties the two tokens together: the Biscuit says "subject X
was allowed", and the downstream confirms the *caller* really is X. If either the
identity check or the Biscuit check fails, the request is refused.

`expectedAudience` is the audience the grant was minted for; `serviceName` is this
verifying service's own identity (used for attenuation, below). On success you get
a `VerifiedGrant` with the recovered subject, audience, operation, scope, schema
hash, consistency token, expiry, and request id — log or propagate it without
re-parsing.

## Step 4 — attenuate before forwarding (optional)

A holder can narrow a token before passing it further down the chain, without
contacting `en`. Attenuation can only *restrict*: Biscuit guarantees an added
block cannot remove authority or broaden an earlier check.

```haskell
import En.Biscuit.Verify

-- Narrow a broad (e.g. scoped) token to one resource and one downstream service.
narrow :: Biscuit Open Verified -> IO (Biscuit Open Verified)
narrow token =
    attenuateGrant
        noAttenuation
            { narrowedResource = Just (ObjectRef (ObjectType "folder") "f1")
            , narrowedService = Just (Audience "thumbnail-service")
            }
        token
```

The narrowed token verifies for the narrowed request (resource `folder:f1`,
service `thumbnail-service`) but not for the broader original — a request for a
different resource or a different service fails with `RestrictionFailed`.

## Key rotation and revocation

Two operational levers live in `En.Biscuit.Keys`: rotating the issuer signing key
without a synchronized fleet redeploy, and revoking any token before it expires.

### Key ids and keyset configuration

Every minted token carries an integer **key id** in its Biscuit envelope
(`MintConfig.issuerKeyId`). A verifier holds an **`IssuerKeySet`** — a map from
key id to trusted public key — and selects the checking key by the token's id.
`En.Biscuit.Keys` provides a single-line text format so key material can come from
environment-variable configuration:

```text
# One signing key for the minter: "<key-id>:<64 hex chars>"
EN_BISCUIT_SIGNING_KEY=2:8f3c…d1

# The verifier's trusted keyset: comma-separated "<key-id>:<hex>" public keys,
# with an optional "legacy:<hex>" entry for tokens minted before key ids existed.
EN_BISCUIT_ISSUER_KEYS=1:a91b…7e,2:5c04…9d,legacy:d3aa…20
```

Parse them with `parseSigningKeyText` (minter) and `parseIssuerKeySetText`
(verifier); `renderIssuerKeySetText` is the inverse. Malformed entries — a
non-integer id, non-hex or wrong-length key material, a duplicate id, or empty
input — are rejected with an error naming the offending entry. In code,
`singleKey (IssuerKeyId 1) pub` builds a one-key set directly.

### Rotating the issuer key — a config-only rollout

Rotation is a configuration change; no verifier binary is rebuilt or redeployed
mid-flight.

1. **Generate** a new signing key and assign it the next key id (e.g. id `2`).
2. **Add** its public key to every verifier's `EN_BISCUIT_ISSUER_KEYS` alongside
   the current one and roll that config out. Verifiers now trust `{1, 2}`; nothing
   else changes. This is the *overlap window*.
3. **Switch** the minter's `EN_BISCUIT_SIGNING_KEY` to `2:<new secret>`. New
   tokens are signed by key 2; in-flight tokens signed by key 1 keep verifying
   against the same keyset — no coordinated cutover.
4. **Drop** key `1` from the verifiers' keysets once the longest possible token
   TTL has elapsed since the switch, so no key-1 token can still be in flight.

Tokens minted before key ids existed carry no id; configure them a `legacy:` key
so verifiers keep honoring them through the transition, then remove it once they
have all expired.

### Revoking a token before it expires

Every token is revocable, whether or not the minter supplied an application-level
`revocationId`. Each Biscuit block (the authority block plus any attenuation
blocks) has a **built-in revocation id** — its signature bytes — reported at mint
time in `MintedGrant.revocationIds`. To revoke a token, add any of its ids to the
set your verifiers consult and pass that set as `VerifyRequest.revokedBlockIds`
(via `Auth.Biscuit.fromRevocationList`). A matching id makes `verifyGrant` return
`Left Revoked` on every verifier, before the token's blocks are even decoded.

Record `MintedGrant.revocationIds` at mint time for any token you might need to
kill early. Revoking an attenuation block's id kills that narrowed token while the
parent stays valid. Distributing the revocation set to verifiers (a shared store
or feed) is out of scope for `en-biscuit`; this layer only guarantees every token
is revocable in principle.

## When a downstream service must still call `en`

Local Biscuit verification is only safe *inside the token's scope*. Call `en`
(directly or via `en-server`) when any of these hold:

- **A new protected decision** — the request touches an object/permission the
  token does not cover.
- **Out of scope** — the resource is not the object grant's resource, nor one of
  a scoped grant's containers (`ResourceNotInScope`).
- **Expired or too stale** — `now` is past the token's expiry, or the operation
  needs fresher graph state than the token's `en_consistency_token` guarantees.
- **A revocation-sensitive operation** — high-value actions should re-check
  against `en` and the revocation list rather than trust a cached grant.
- **A protected mutation** — writes should be authorized against current graph
  state, not a short-lived read proof.
- **A lookup the token does not carry** — list/filter endpoints whose scope is
  broader than the token's containers.
- **`expand` / audit UI** — anything that needs the relationship graph itself.

If in doubt, call `en`. The Biscuit is an optimization for the common
in-scope case, not a replacement for the source of truth.

## Transport: two tokens, two headers

When a request carries both an identity and an `en` decision proof, keep them in
separate, explicitly named headers so services and clients are never confused
about which is which:

```text
Authorization: Bearer <shomei-jwt>
X-En-Biscuit:   <base64-biscuit>
```

Do not overload a single `Authorization` header with two token types.

## Security checklist

- The **issuer signing key** (`MintConfig.issuerSecretKey`) is separate from
  Shomei's JWT signing keys. Distribute only the **public** keyset to downstream
  verifiers, addressed by key id.
- Keep `defaultTtl` short (seconds to a few minutes). Expiry is issuer-controlled.
- **Rotate the issuer key by config, not redeploy.** Assign each signing key a
  key id and give verifiers a keyset holding both the outgoing and incoming key
  during the overlap window. See [Key rotation and
  revocation](#key-rotation-and-revocation).
- **Record `MintedGrant.revocationIds` at mint time** for any token you might need
  to revoke before expiry — every token has them, and passing them to
  `revokedBlockIds` revokes the token regardless of whether it carries an
  application-level `revocationId`.
- Scope tokens narrowly (specific audience, operation, resource/containers) so a
  stale grant cannot be replayed broadly.
- Downstream services must authenticate the caller independently and pass the
  authenticated subject as `expectedSubject`; never trust the Biscuit's subject
  as proof of identity.

## API summary

| Package module | What it gives you |
| --- | --- |
| `En.Biscuit.Grant` | `EnGrant`, `EnScopedGrant`, `EnBiscuitGrant`, `Audience`/`RequestId`/`RevocationId`, and the stable `en_*` Biscuit fact vocabulary |
| `En.Biscuit.Keys` | `IssuerKeyId`, `IssuerKeySet`, `singleKey`/`selectIssuerKey`, and the `parseSigningKeyText`/`parseIssuerKeySetText`/`renderIssuerKeySetText` config codecs |
| `En.Biscuit.Mint` | `MintConfig` (with `issuerKeyId`), `MintedGrant`, `mintObjectGrant`/`mintScopedGrant` (+ `…WithExpiry`), `mintCheckedObjectGrant`, `EnBiscuitMintError` |
| `En.Biscuit.Verify` | `VerifyRequest` (with `revokedBlockIds`), `verifyGrant` (takes an `IssuerKeySet`), `VerifiedGrant`, `EnBiscuitVerifyError`, `attenuateGrant`, `Attenuation`/`noAttenuation` |
| `En.Biscuit` | Re-exports all of the above |

See `docs/ideas/biscuit-integration.md` for the original design rationale.
