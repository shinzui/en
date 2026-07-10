---
id: 55
slug: support-key-rotation-and-unconditional-revocation-in-biscuit-grants
title: "Support key rotation and unconditional revocation in Biscuit grants"
kind: exec-plan
created_at: 2026-07-07T15:25:10Z
master_plan: "docs/masterplans/10-harden-the-biscuit-decision-token-layer.md"
intention: intention_01kx6ajfcjefhtvc4fhwk7fjq7
---

# Support key rotation and unconditional revocation in Biscuit grants

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today the `en-biscuit` package signs every decision token with a single issuer
secret key, and `verifyGrant` accepts exactly one public key. Rotating the
issuer key therefore requires redeploying every downstream verifier at the same
instant, or every in-flight token breaks. Worse, a token minted without an
application-level `revocationId` is irrevocable until it expires, even though
the Biscuit format gives every token free, unconditional, cryptographic
revocation identifiers (one per block).

After this change, an operator can rotate the issuer key by config alone: mint
new tokens under key id 2 while verifiers, configured with a keyset containing
both key 1 and key 2, keep accepting old tokens until they expire — no verifier
redeploy. And every minted token — with or without an application-level
revocation id — can be killed before expiry by adding any of its block
revocation ids to a revocation set that the verifier consults on every parse.

The observable behavior is a test suite (`cabal test en-biscuit`) demonstrating:
a token minted with key A and a token minted with key B both verify against one
keyset containing both public keys; removing key A from the keyset makes only
the key-A token fail; and a token minted with no `revocationId` is rejected as
`Revoked` once one of its block revocation ids is in the caller's revocation
set. This plan fixes finding D1 of the architecture review
(`docs/reviews/2026-07-07-architecture-performance-review.md`) and is child
EP-55 of `docs/masterplans/10-harden-the-biscuit-decision-token-layer.md`.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1 (2026-07-10): Add `IssuerKeyId` and thread it through minting via `mkBiscuitWith`. Placed `IssuerKeyId` in the new `En.Biscuit.Keys` module (its M4 home) from the start; `signGrant` now calls `mkBiscuitWith (Just keyId)`.
- [x] M1 (2026-07-10): Introduce the `MintedGrant` result (token bytes, stamped expiry, block revocation ids) and change all mint functions to return it.
- [x] M1 (2026-07-10): Update `en-biscuit/test/Main.hs` for the new mint result type; all existing tests pass.
- [x] M1 (2026-07-10): Add a test asserting a minted token round-trips its key id (`keyIdRoundTripTest`: mint under `IssuerKeyId 7`, `parseB64` with the matching public key succeeds; the M2 rotation test completes the keyset-selection proof).
- [x] M2 (2026-07-10): Define `IssuerKeySet` (plus `singleKey`/`selectIssuerKey`) in `en-biscuit/src/En/Biscuit/Keys.hs` and expose it from `En.Biscuit`. (The module and these symbols landed with M1's commit; M2 wires them into verification.)
- [x] M2 (2026-07-10): Change `verifyGrant` to accept `IssuerKeySet` and parse via `Auth.Biscuit.parseWith` (`ParserConfig{encoding = UrlBase64, isRevoked = const (pure False), getPublicKey = selectIssuerKey keySet}`; `isRevoked` becomes the real block-id check in M3). All EP-56 verify call sites updated mechanically via a `keySetFor` helper — their fact-scoping assertions are unchanged.
- [x] M2 (2026-07-10): Add the rotation test (`keyRotationTest`): keys A and B, one overlap keyset verifies both tokens with the verifier built once; keyset without A rejects only the key-A token. Plus `legacyTokenTest`: a no-key-id token verifies with `legacyKey` set, fails without it.
- [x] M2 (2026-07-10): Add the key-selection attack test (`keySelectionAttackTest`): a token signed by key A but claiming root key id 2 (which the keyset maps to key B) is rejected `SignatureInvalid` — a holder cannot steer the verifier onto a key that would accept a forged signature.
- [ ] M3: Add `revokedBlockIds` to `VerifyRequest` and wire it into `ParserConfig.isRevoked` so every verify consults built-in revocation ids.
- [ ] M3: Map the `RevokedBiscuit` parse error to the existing `Revoked` verify error; keep the application-level `revoked` check as an optional extra.
- [ ] M3: Add tests: token without application `revocationId` is revocable by block id; application-level revocation still works.
- [ ] M4: Add the key-material text format (`parseSigningKeyText`, `parseIssuerKeySetText`, renderers) to `En.Biscuit.Keys` with tests, including rejection of malformed input.
- [ ] M4: Update `docs/user/biscuit-decision-tokens.md`: key ids, keyset config format, rotation procedure, unconditional revocation ids.
- [ ] Final: `cabal build all` and `cabal test en-biscuit` pass; Outcomes & Retrospective written.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

Carried in from EP-56 (`docs/plans/56-pin-attenuation-injection-semantics-with-tests.md`),
which landed first and pinned the fact-scoping semantics this plan builds on:

- The fact-scoping assumption **holds** against the pinned biscuit-haskell, so
  this plan builds on today's `extractAndCheck` / `resolveScope` in
  `en-biscuit/src/En/Biscuit/Verify.hs` unchanged. EP-56's contingency rewrite
  (its milestone M3) was never triggered and is retired.

- EP-56's seven new tests in `en-biscuit/test/Main.hs`
  (`attenuationForgedRightTest`, `attenuationForgedExpiryTest`,
  `attenuationForgedRevocationTest`, `attenuationForgedScopeTest`,
  `attenuationForgedSubjectTest`, `authorizerScopingTest`,
  `narrowingDirectionTest`) call `verifyGrant` with the single-`PublicKey`
  signature. M2 of this plan must update those call sites mechanically to
  `singleKey`/`IssuerKeySet` plus a `const (pure False)` `revokedBlockIds`
  check. None of their assertions depend on key material, so none of them should
  be weakened or deleted to make the new signature compile — if one starts
  failing, that is a security regression in this plan's changes, not test rot.

- The soft spot this plan's M3 closes, made precise: forged single-valued facts
  fail closed today because `getSingleVariableValue` returns `Nothing` on two
  rows and `extractAndCheck` reports `MalformedGrant`. `en_revocation_id` is the
  exception — its `Nothing` means "not revocable", not "malformed", so a holder
  who could shadow it would silently skip the revocation check. Fact scoping is
  what prevents that today. Built-in block revocation ids are signature bytes in
  the token envelope rather than Datalog facts, so after M3 that soft spot is
  gone by construction, not merely by scoping.

- `trusting previous` parses in the `query` quasiquoter but is rejected in the
  `authorizer` quasiquoter (`Auth/Biscuit/Datalog/Parser.hs:430` raises
  `PreviousInAuthorizer`). Inspect holder-block facts with
  `queryRawBiscuitFacts`, not with an authorizer policy.

- `en-biscuit/test/Main.hs` compiles with `-Wambiguous-fields`, and
  `EnGrant`/`EnScopedGrant`/`VerifyRequest`/`MintConfig` share the field names
  `revocationId`, `operation`, and `now`. Record *update* syntax on those fields
  warns; record *construction* does not. Adding `revokedBlockIds` to
  `VerifyRequest` in M3 keeps this trap alive — prefer parameterized helpers
  (the file already has `forgeableObjectGrantWith` and `objectRequest`) over
  updating a shared record literal.


## Decision Log

Record every decision made while working on the plan.

- Decision: Use biscuit-haskell's native root key id (`mkBiscuitWith` /
  `ParserConfig.getPublicKey`) as the key identifier, not an `en_*` Datalog fact
  or an HTTP header convention.
  Rationale: The Biscuit wire format has a dedicated `rootKeyId :: Maybe Int`
  field in the token wrapper (`Auth.Biscuit.Token`, field at line 189 of the
  pinned source), it is available to the parser *before* signature
  verification (facts are not — blocks are only decoded after the signature
  check), and any Biscuit implementation in any language can read it. A fact
  would be readable only after choosing a key, which is circular; a header
  would not travel with the token.
  Date: 2026-07-07
- Decision: `getPublicKey` in `ParserConfig` is a total function
  `Maybe Int -> PublicKey`, so an unknown key id cannot produce a distinct
  typed error through the public parsing API. Unknown ids resolve to a
  deterministic fallback key from the keyset and fail as `SignatureInvalid`.
  Rationale: The library offers no `Maybe`-returning selector, and the
  `rootKeyId` field accessor is not exported from the exposed `Auth.Biscuit`
  module (only the unexposed `Auth.Biscuit.Token` exports it), so pre-inspecting
  the id for a precise `UnknownIssuerKey` error is not possible without
  depending on library internals. Failing as `SignatureInvalid` is fail-closed
  and correct; precision is sacrificed knowingly.
  Date: 2026-07-07
- Decision: All mint functions return a `MintedGrant` record (serialized token,
  stamped expiry, block revocation ids) instead of bare `ByteString`.
  Rationale: An issuer that wants to be able to revoke a token must record its
  revocation ids at mint time; `Auth.Biscuit.getRevocationIds` provides them
  from the freshly minted `Biscuit` value. EP-57 (HTTP minting,
  `docs/plans/57-mint-biscuit-grants-over-http.md`) needs exactly this triple
  for its response body. Breaking the internal mint contract once, here, is the
  master plan's stated reason for bundling key ids and revocation in one plan.
  Date: 2026-07-07
- Decision: Keep the application-level `revocationId` fact and the
  `revoked :: RevocationId -> m Bool` check as an optional extra layer.
  Rationale: Application-level ids are human-assignable and can name a whole
  family of tokens (e.g. one id per session), which block ids cannot. The
  built-in block ids become the unconditional baseline; the application id
  remains a convenience.
  Date: 2026-07-07
- Decision: Key-material configuration format is plain text: `<key-id>:<hex>`
  entries, comma-separated for keysets, with an optional `legacy:<hex>` entry
  for tokens minted before this plan (which carry no key id).
  Rationale: EP-57 wires this into environment-variable server config
  (`docs/plans/38-validate-configuration-and-persist-datastore-identity.md`
  owns the config record); env vars want a single-line text format. Hex is what
  `Auth.Biscuit.parseSecretKeyHex` / `parsePublicKeyHex` already consume, and
  the repository's own tests already use hex key literals
  (`en-biscuit/test/Main.hs`, `loadSecret`).
  Date: 2026-07-07
- Decision: Test that a holder cannot steer issuer-key selection.
  Rationale: EP-56 pinned fact scoping under a single key, leaving key selection
  untested. `rootKeyId` is attacker-visible metadata in the Biscuit envelope, and
  once `verifyGrant` picks a key from a keyset by that id, "which key does the
  verifier reach for" becomes a new attack surface introduced by *this* plan. A
  token minted under key A whose `rootKeyId` is rewritten to name key B must fail
  signature verification, and the test must say so explicitly rather than relying
  on it falling out of the crypto.
  Date: 2026-07-10
- Decision: A revocation *distribution* mechanism (shared store or feed) stays
  out of scope; this plan only guarantees every token is revocable in
  principle, via a caller-supplied membership check.
  Rationale: Restates the master plan's decision; the watch API
  (`docs/plans/53-add-a-watch-changelog-api.md`) is the natural future carrier.
  Date: 2026-07-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

`en` is a relationship-based authorization engine. The optional `en-biscuit`
package turns a successful `en` authorization decision into a short-lived,
signed [Biscuit] bearer token that downstream services verify locally, without
calling `en` again. A *Biscuit* is a token format whose payload is a chain of
cryptographically signed blocks: the first block (the "authority block")
carries the issuer's facts; later blocks can be appended by any holder but can
only *narrow* what the token authorizes.

The package has three modules, all under `en-biscuit/src/`:

- `En/Biscuit/Grant.hs` — the typed grant model (`EnGrant`, `EnScopedGrant`)
  and the stable `en_*` Datalog fact vocabulary the grant serializes to. The
  optional `RevocationId` newtype (line 93) and the optional
  `revocationId :: Maybe RevocationId` grant fields live here.
- `En/Biscuit/Mint.hs` — minting. `MintConfig` (lines 86–99) holds a raw
  in-memory `issuerSecretKey :: SecretKey`, a `defaultTtl`, and a clock.
  `signGrant` (lines 254–264) is the only call site of `Auth.Biscuit.mkBiscuit`
  and returns serialized bytes.
- `En/Biscuit/Verify.hs` — local verification and attenuation. `verifyGrant`
  (lines 185–203) takes exactly one `PublicKey`, parses with
  `Auth.Biscuit.parseB64`, extracts the `en_*` facts, and compares them in
  Haskell for precise errors. The revocation check at line 198 is
  `maybe (pure False) request.revoked mRevocationId` — it fires *only* when the
  token carries an application-level `en_revocation_id` fact. A token minted
  without one is irrevocable until expiry. This is the exact weakness this plan
  removes.

Tests are a single binary at `en-biscuit/test/Main.hs`; the cabal package is
`en-biscuit/en-biscuit.cabal`. The user-facing guide is
`docs/user/biscuit-decision-tokens.md` (delivered by
`docs/plans/32-document-shomei-compatible-biscuit-authorization-flows.md`).
This plan implements finding D1 of
`docs/reviews/2026-07-07-architecture-performance-review.md` under
`docs/masterplans/10-harden-the-biscuit-decision-token-layer.md`.

What the biscuit-haskell dependency actually provides (verified in the pinned
source at `/Users/shinzui/Keikaku/hub/haskell/biscuit-haskell-project/biscuit-haskell/biscuit/src/`,
the `source-repository-package` pinned in `cabal.project`):

- *Root key id.* `mkBiscuitWith :: Maybe Int -> SecretKey -> Block -> IO
  (Biscuit Open Verified)` (`Auth/Biscuit/Token.hs:276`) embeds an optional
  integer key identifier in the token wrapper; `mkBiscuit` is literally
  `mkBiscuitWith Nothing`. The id is serialized in the token's protobuf
  envelope and recovered at parse time before signature verification.
- *Keyed parsing.* `parseWith :: Applicative m => ParserConfig m -> ByteString
  -> m (Either ParseError (Biscuit OpenOrSealed Verified))` with
  `ParserConfig { encoding :: BiscuitEncoding, isRevoked :: Set ByteString ->
  m Bool, getPublicKey :: Maybe Int -> PublicKey }`
  (`Auth/Biscuit/Token.hs:523–531`). `getPublicKey` receives the token's root
  key id and selects the verification key. Note it is a *total* pure function.
- *Built-in revocation ids.* Every block's revocation id is its signature
  bytes. `checkRevocation` (`Auth/Biscuit/Token.hs:448–453`) collects the ids
  of *all* blocks and calls `isRevoked` on the set *before blocks are even
  decoded*; a hit yields the `RevokedBiscuit` constructor of `ParseError`.
  `getRevocationIds :: Biscuit proof check -> NonEmpty ByteString`
  (`Auth/Biscuit/Token.hs:552–556`) exposes the same ids for inspection, e.g.
  at mint time. `fromRevocationList` (`Auth/Biscuit.hs:347`) builds an
  `isRevoked` from a static list.
- *Key codecs.* `parseSecretKeyHex`, `parsePublicKeyHex`,
  `serializeSecretKeyHex`, `serializePublicKeyHex` (all exported from
  `Auth.Biscuit`) — ed25519 keys, 32 bytes, so 64 hex characters.

Terms used below: a *keyset* is a map from key id to public key that a verifier
trusts; the *overlap window* is the period during rotation when tokens signed
by both the old and the new key are in flight and must both verify; a *block
revocation id* is the signature bytes of one token block, unique per minted
token (and per attenuation), usable as an unforgeable "kill this token" handle.


## Plan of Work

The work is four milestones. M1 changes minting, M2 changes verification, M3
makes revocation unconditional, M4 defines the config representation and
updates documentation. Each compiles and passes tests on its own; M2 and M3
both touch `verifyGrant`, so land them in order.

Milestone 1 — key ids at mint, and a richer mint result. In
`en-biscuit/src/En/Biscuit/Mint.hs`, add a newtype
`IssuerKeyId = IssuerKeyId Int` (deriving `Eq`, `Ord`, `Show`) — or place it in
the new `En.Biscuit.Keys` module of M4 from the start if you prefer one home;
either way it must be exported from `En.Biscuit`. Add
`issuerKeyId :: IssuerKeyId` to `MintConfig`. In `signGrant`, replace
`mkBiscuit secret blk` with `mkBiscuitWith (Just keyId) secret blk` where
`keyId` is the config's id unwrapped. Define:

```haskell
data MintedGrant = MintedGrant
    { token :: ByteString
    -- ^ The URL-safe base64 serialized Biscuit ('serializeB64').
    , expiresAt :: UTCTime
    -- ^ The expiry actually stamped into the token.
    , revocationIds :: NonEmpty ByteString
    -- ^ Raw built-in revocation ids of every block ('getRevocationIds'),
    -- in block order. Record these if you ever want to revoke the token.
    }
```

Change `mintObjectGrant`, `mintObjectGrantWithExpiry`, `mintScopedGrant`,
`mintScopedGrantWithExpiry`, and `mintCheckedObjectGrant` to return
`Either EnBiscuitMintError MintedGrant`. `signGrant` gains the stamped expiry
as an argument so it can populate the record, and calls `getRevocationIds` on
the freshly minted biscuit before serializing. Update every test in
`en-biscuit/test/Main.hs` that pattern-matches `Right bytes` to project
`minted.token` instead (there are call sites in `mintAllowedTest`,
`mintScopedTest`, `mintCheckedTest`, `verifyObjectTests`, `verifyScopedTests`,
and `shomeiFlowTest`). Acceptance for M1: `cabal test en-biscuit` passes, and a
new test proves the key id round-trips (mint with `IssuerKeyId 7`; the M2
keyset test completes the proof — until M2 lands, assert instead that
`parseB64` with the correct public key still verifies, since a key id changes
routing, not the signature).

Milestone 2 — keyset verification. Create
`en-biscuit/src/En/Biscuit/Keys.hs` (add it to `exposed-modules` in
`en-biscuit/en-biscuit.cabal` and to the re-exports in
`en-biscuit/src/En/Biscuit.hs`). Define:

```haskell
data IssuerKeySet = IssuerKeySet
    { keysById :: Map IssuerKeyId PublicKey
    -- ^ Trusted issuer keys, addressed by the token's root key id.
    , legacyKey :: Maybe PublicKey
    -- ^ Key for tokens that carry no root key id (minted before EP-55).
    }

-- | Total selection, as 'ParserConfig.getPublicKey' requires. Unknown ids and
-- an absent legacy key fall back to a deterministic member of the keyset (the
-- highest key id, else the legacy key); the signature check then fails closed.
selectIssuerKey :: IssuerKeySet -> Maybe Int -> PublicKey

singleKey :: IssuerKeyId -> PublicKey -> IssuerKeySet
```

A keyset must be non-empty; make the smart constructors enforce it (an empty
keyset has no total selection). In `en-biscuit/src/En/Biscuit/Verify.hs`,
change `verifyGrant` to:

```haskell
verifyGrant ::
    (MonadIO m) =>
    IssuerKeySet ->
    ByteString ->
    VerifyRequest m ->
    m (Either EnBiscuitVerifyError VerifiedGrant)
```

and replace the pure `parseB64 publicKey token` call with `parseWith` using
`ParserConfig { encoding = UrlBase64, isRevoked = …M3…, getPublicKey =
selectIssuerKey keySet }` (until M3 lands, `isRevoked = const (pure False)`
preserves behavior). `parseWith` runs in the verifier's `m`; `MonadIO m`
already satisfies its `Applicative m` constraint. Update all `verifyGrant`
call sites in `en-biscuit/test/Main.hs` to pass
`singleKey (IssuerKeyId 1) public` (or a richer keyset in the new tests).
Acceptance for M2 is the rotation story as a test: generate secret keys A and
B; mint token TA with `issuerKeyId = IssuerKeyId 1` and key A, token TB with
`IssuerKeyId 2` and key B; one keyset `{1 -> pubA, 2 -> pubB}` verifies both
TA and TB (the overlap window, with no change to the verifier between the two
calls); a second keyset `{2 -> pubB}` verifies TB and rejects TA with
`SignatureInvalid`. Also test the legacy path: a token minted via plain
`mkBiscuit`-era behavior (mint with... after M1 all mints carry an id, so
construct the legacy token directly with `Auth.Biscuit.mkBiscuit` over
`grantBlock` output, as `attenuationTests` already does) verifies against a
keyset whose `legacyKey` is set and fails against one without it.

Milestone 3 — unconditional revocation. Add to `VerifyRequest` in
`en-biscuit/src/En/Biscuit/Verify.hs`:

```haskell
    , revokedBlockIds :: Set ByteString -> m Bool
    -- ^ Whether ANY of the token's built-in block revocation ids is revoked.
    -- Consulted on every verification, before blocks are decoded. Use
    -- 'Auth.Biscuit.fromRevocationList' for a static list, or
    -- @const (pure False)@ if you do not maintain a revocation set.
```

Pass it as `ParserConfig.isRevoked`. In `verifyGrant`'s error mapping,
translate the `RevokedBiscuit` parse-error constructor to the existing
`Revoked` verify error and every other `ParseError` to `SignatureInvalid`
(today's line 193 collapses all parse errors into `SignatureInvalid`; after
this milestone revocation is distinguishable again). The application-level
check at line 198 stays exactly as it is — an optional second layer. Update
the test helper `mkVerifyRequest` for the new field. Acceptance: a token
minted with `revocationId = Nothing` verifies with an empty revocation set,
and is rejected with `Revoked` when `revokedBlockIds` is
`fromRevocationList minted.revocationIds` (using the ids the M1 `MintedGrant`
reported); the existing application-level revocation test still passes; an
attenuated token is also revocable by its *added block's* id (attenuation
appends a block, so `getRevocationIds` of the attenuated token has one more
entry — revoking only that entry kills the attenuated token but not the
parent, which is correct and worth pinning).

Milestone 4 — key-material representation and documentation. In
`En.Biscuit.Keys`, add the text codec the server config (EP-57) will consume:

```haskell
-- "2:<64 hex chars>" -> (IssuerKeyId 2, SecretKey)
parseSigningKeyText :: Text -> Either Text (IssuerKeyId, SecretKey)

-- "1:<hex>,2:<hex>" with an optional "legacy:<hex>" entry -> IssuerKeySet
parseIssuerKeySetText :: Text -> Either Text IssuerKeySet

renderIssuerKeySetText :: IssuerKeySet -> Text
```

Key ids are non-negative integers; whitespace around entries is trimmed;
duplicate ids, empty input, non-hex material, and wrong-length keys are
errors naming the offending entry. Add unit tests for the codec (round-trip
plus each rejection). Then update `docs/user/biscuit-decision-tokens.md`: the
`MintConfig` example gains `issuerKeyId`; the verification example takes an
`IssuerKeySet`; add a "Key rotation" subsection describing the config-only
procedure (add the new public key to every verifier's keyset, switch the
minter's signing key, drop the old key after the longest TTL has elapsed); the
"Security checklist" gains "record `MintedGrant.revocationIds` at mint time if
you need pre-expiry revocation — every token has them, `revocationId` is
optional extra"; the "Transport" section is unchanged. This document is the
Shomei-compatible flow documentation delivered by
`docs/plans/32-document-shomei-compatible-biscuit-authorization-flows.md`;
keeping it in sync is an integration obligation of this plan (master plan 10,
Integration Points). Do not change the `en_*` fact vocabulary in
`En/Biscuit/Grant.hs` — the key id lives in the token envelope, not in facts,
so the wire vocabulary is untouched (record this in the doc so verifier
authors in other languages know to read the envelope field).

Coordination note: EP-56
(`docs/plans/56-pin-attenuation-injection-semantics-with-tests.md`) pins fact
scoping with tests against whichever `verifyGrant` signature exists when it
runs. If EP-56 landed first, this plan updates those tests to the keyset
signature; if this plan lands first, EP-56 targets the new signature. Both
plans carry this note.


## Concrete Steps

Work from the repository root. Re-read the primary sources first:

```bash
cd /Users/shinzui/Keikaku/bokuno/en
sed -n '1,120p' en-biscuit/src/En/Biscuit/Mint.hs
sed -n '180,260p' en-biscuit/src/En/Biscuit/Verify.hs
sed -n '260,360p' /Users/shinzui/Keikaku/hub/haskell/biscuit-haskell-project/biscuit-haskell/biscuit/src/Auth/Biscuit.hs
sed -n '440,560p' /Users/shinzui/Keikaku/hub/haskell/biscuit-haskell-project/biscuit-haskell/biscuit/src/Auth/Biscuit/Token.hs
```

Then, per milestone: edit the files named in the Plan of Work, keep
`en-biscuit/en-biscuit.cabal` `exposed-modules` in sync when adding
`En.Biscuit.Keys`, and after each milestone run:

```bash
cabal build en-biscuit
cabal test en-biscuit
```

Expected test output (the suite prints its own marker before the harness
result):

```text
en-biscuit tests PASS
Test suite en-biscuit-tests: PASS
```

Before finishing, confirm nothing else in the workspace consumed the old mint
or verify signatures (today only the test suite does, but check):

```bash
grep -rn "mintObjectGrant\|mintScopedGrant\|verifyGrant\|MintConfig" --include='*.hs' en-servant en-server en-client en-example en-core en-postgres
cabal build all
```

Expected: no hits outside `en-biscuit` (if EP-57 has landed in the meantime,
its call sites in `en-servant`/`en-server` must be updated in the same
change), and a clean `cabal build all`.


## Validation and Acceptance

Acceptance is behavioral, proven by `cabal test en-biscuit`:

- Rotation without verifier redeploy: token TA minted with key A / id 1 and
  token TB minted with key B / id 2 both return `Right VerifiedGrant` against
  a single keyset `{1 -> pubA, 2 -> pubB}` — the overlap window — with the
  verifier constructed once and never reconfigured between the two calls.
- Retirement: against keyset `{2 -> pubB}`, TB verifies and TA returns
  `Left (SignatureInvalid …)`.
- Legacy tokens: a token minted with no root key id verifies against a keyset
  with `legacyKey = Just pubLegacy` and fails without it.
- Unconditional revocation: a token minted with `revocationId = Nothing`
  returns `Left Revoked` when any of the `MintedGrant.revocationIds` reported
  at mint time is in the `revokedBlockIds` set, and `Right …` when the set is
  empty. An attenuated token is revocable via the id of its added block while
  the parent token stays valid.
- Application-level revocation unchanged: the existing `verifyObjectTests`
  revocation case (`revoked = \r -> pure (r == RevocationId "rev-1")`) still
  returns `Left Revoked`.
- Key-material codec: `parseIssuerKeySetText "1:<hexA>,2:<hexB>"` round-trips
  through `renderIssuerKeySetText`; malformed entries (bad id, bad hex, wrong
  length, duplicate id, empty string) each return `Left` with a message naming
  the entry.
- Every pre-existing test in `en-biscuit/test/Main.hs` still passes.

Beyond tests, the documented rotation procedure in
`docs/user/biscuit-decision-tokens.md` must read as a pure config rollout: at
no step does it instruct rebuilding or redeploying a verifier binary.


## Idempotence and Recovery

All steps are ordinary source edits plus test runs; they are safe to repeat.
Tests use the deterministic key from `Auth.Biscuit.parseSecretKeyHex` (see
`loadSecret` in `en-biscuit/test/Main.hs`) and fixed timestamps, so runs are
reproducible; generate second/third keys with `newSecret` inside the test or
add more fixed hex literals — prefer fixed literals for reproducibility.

If the `MintedGrant` return-type change causes churn you want to stage, land
M1 as two commits (record type first, call-site updates second) — but do not
keep a parallel `ByteString`-returning API: the master plan wants this
contract broken exactly once. If `parseWith`'s monadic shape fights the
existing pure `extractAndCheck` structure, keep `extractAndCheck` pure and do
only the parse effectfully, as `verifyGrant` already does with the revocation
action. If EP-56's tests are present, update their `verifyGrant` call sites
mechanically (keyset + `revokedBlockIds` field); their assertions are about
fact scoping and are unaffected by key routing.


## Interfaces and Dependencies

Libraries: `biscuit-haskell` (pinned via `source-repository-package` in
`cabal.project` to the GHC-9.12-compatible source; the modules used —
`Auth.Biscuit` only — already ship every needed function: `mkBiscuitWith`,
`parseWith`, `ParserConfig(..)`, `BiscuitEncoding(..)`, `fromRevocationList`,
`getRevocationIds`, `parseSecretKeyHex`, `parsePublicKeyHex`,
`serializePublicKeyHex`). `containers` (already a dependency) for `Map`/`Set`.
No new package dependencies.

Modules and signatures that must exist at completion:

`En.Biscuit.Keys` (new, `en-biscuit/src/En/Biscuit/Keys.hs`):

```haskell
newtype IssuerKeyId = IssuerKeyId Int

data IssuerKeySet -- keysById :: Map IssuerKeyId PublicKey, legacyKey :: Maybe PublicKey

singleKey :: IssuerKeyId -> PublicKey -> IssuerKeySet
selectIssuerKey :: IssuerKeySet -> Maybe Int -> PublicKey
parseSigningKeyText :: Text -> Either Text (IssuerKeyId, SecretKey)
parseIssuerKeySetText :: Text -> Either Text IssuerKeySet
renderIssuerKeySetText :: IssuerKeySet -> Text
```

`En.Biscuit.Mint` (changed):

```haskell
data MintConfig m -- gains issuerKeyId :: IssuerKeyId
data MintedGrant  -- token :: ByteString, expiresAt :: UTCTime, revocationIds :: NonEmpty ByteString

mintObjectGrant :: MonadIO m => MintConfig m -> CheckDecision -> EnGrant -> m (Either EnBiscuitMintError MintedGrant)
-- likewise mintObjectGrantWithExpiry, mintScopedGrant, mintScopedGrantWithExpiry, mintCheckedObjectGrant
```

`En.Biscuit.Verify` (changed):

```haskell
data VerifyRequest m -- gains revokedBlockIds :: Set ByteString -> m Bool

verifyGrant :: MonadIO m => IssuerKeySet -> ByteString -> VerifyRequest m -> m (Either EnBiscuitVerifyError VerifiedGrant)
```

`En.Biscuit` re-exports `En.Biscuit.Keys`. Downstream consumer: EP-57
(`docs/plans/57-mint-biscuit-grants-over-http.md`) reads
`parseSigningKeyText` / `parseIssuerKeySetText` output from server config and
returns `MintedGrant` fields over HTTP; that plan soft-depends on this one and
mints single-key if this plan has not landed. EP-56
(`docs/plans/56-pin-attenuation-injection-semantics-with-tests.md`) tests
target whichever `verifyGrant` signature exists first — see the coordination
note in the Plan of Work.
