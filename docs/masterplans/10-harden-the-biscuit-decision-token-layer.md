---
id: 10
slug: harden-the-biscuit-decision-token-layer
title: "Harden the Biscuit decision-token layer"
kind: master-plan
created_at: 2026-07-07T15:24:21Z
intention: intention_01kx6ajfcjefhtvc4fhwk7fjq7
---

# Harden the Biscuit decision-token layer

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

en-biscuit mints short-lived, attenuable Biscuit tokens from successful en authorization
decisions so downstream services can verify grants locally without calling en. The
review (`docs/reviews/2026-07-07-architecture-performance-review.md`, Theme D) found
three weaknesses. Key management is single-key: `verifyGrant` accepts exactly one public
key and tokens carry no key identifier, so rotating the issuer key requires
simultaneously redeploying every verifier in the fleet. Revocation is opt-in per token —
a grant minted without a `revocationId` is irrevocable until expiry, even though the
Biscuit format provides unconditional per-block cryptographic revocation identifiers for
free. And the safety of holder attenuation rests on an untested assumption about
biscuit-haskell's fact scoping: nothing proves that a holder-added block injecting
forged `en_right` or `en_expires_at` facts is ignored. Finally, minting is
embedded-only: a pure HTTP consumer of en-server has no way to obtain decision tokens at
all.

After this initiative, issuer keys carry identifiers and verifiers accept a keyset, so
rotation is a config rollout rather than a synchronized redeploy; every token is
revocable by its built-in block revocation ids regardless of whether the minter supplied
an application-level revocation id; the attenuation-injection semantics of the
biscuit-haskell dependency are pinned by tests that would fail on a regression; and
en-server can mint decision tokens over HTTP, fed by the checked-at consistency tokens
that read responses return. In scope: en-biscuit (`Mint.hs`, `Verify.hs`, `Grant.hs`),
its tests, and one new en-server endpoint. Out of scope: sealed tokens and third-party
blocks (record as future work), a revocation *distribution* mechanism (a shared
revocation store or feed — the watch API in docs/plans/53-add-a-watch-changelog-api.md
is the natural future carrier), and any change to the en-core decision engine.


## Decomposition Strategy

Three children, one per failure mode, each independently verifiable. EP-55 (keys and
revocation) bundles key identifiers, multi-key verification, and unconditional
revocation ids because all three change the mint/verify contract in
`en-biscuit/src/En/Biscuit/Mint.hs` and `Verify.hs` and should break that internal API
exactly once. EP-56 (attenuation pinning) is test-only and deliberately separate: it
must be able to land first and fail loudly if the dependency's semantics are not what
`extractAndCheck`'s use of `queryRawBiscuitFacts` assumes, without waiting on any
feature work. EP-57 (HTTP minting) is the only child with an external dependency — it
needs read responses to carry checked-at consistency tokens
(docs/plans/51-return-checked-at-consistency-tokens-from-read-responses.md, master plan
9) because `EnGrant` requires a `ConsistencyToken` and the check response is its natural
source.

An alternative merging EP-55 and EP-57 ("productionize minting") was rejected because
EP-57 is blocked on another master plan while EP-55 is not; coupling them would
needlessly serialize the key-rotation fix.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-55 | Support key rotation and unconditional revocation in Biscuit grants | docs/plans/55-support-key-rotation-and-unconditional-revocation-in-biscuit-grants.md | None | None | Complete |
| EP-56 | Pin attenuation-injection semantics with tests | docs/plans/56-pin-attenuation-injection-semantics-with-tests.md | None | None | Complete |
| EP-57 | Mint Biscuit grants over HTTP | docs/plans/57-mint-biscuit-grants-over-http.md | None | EP-55 | Not Started |


## Dependency Graph

EP-55 and EP-56 are fully parallel; EP-56 should ideally run first because it is cheap
and its outcome could reshape EP-55's verification code (if the fact-scoping assumption
fails, `extractAndCheck` in `en-biscuit/src/En/Biscuit/Verify.hs` needs a rewrite that
EP-55 would otherwise build on top of). EP-57 soft-depends on EP-55 so the HTTP endpoint
mints tokens in the final keyed format rather than the legacy single-key format.
EP-57 additionally has a hard *external* dependency, not expressible in the registry:
docs/plans/51-return-checked-at-consistency-tokens-from-read-responses.md (master plan
9) must be Complete, because the minting endpoint's request flow is
check-then-mint-at-that-token and today no read response supplies a token. It also
composes with caller authentication
(docs/plans/33-add-caller-authentication-and-rate-limiting-to-en-server.md, master plan
6): a minting endpoint on an unauthenticated server would hand bearer tokens to anyone,
so EP-57 must not be deployed before EP-33 lands.


## Integration Points

The grant token format is extended by EP-55 and consumed by EP-56's tests and EP-57's
endpoint. Note the mechanics live outside the Datalog fact vocabulary: the key
identifier travels in the Biscuit protobuf envelope (`rootKeyId`), and revocation ids
are per-block signature bytes, so the `en_*` fact vocabulary in
`en-biscuit/src/En/Biscuit/Grant.hs` is untouched. EP-55 owns the token-format change
and must keep the documented Shomei-compatible flow
(`docs/user/biscuit-decision-tokens.md`,
`docs/plans/32-document-shomei-compatible-biscuit-authorization-flows.md`) in sync.

The verify entry point (`verifyGrant` in `en-biscuit/src/En/Biscuit/Verify.hs`) changes
signature in EP-55 (keyset plus key-id selection instead of a single `PublicKey`;
revocation check consults built-in block revocation ids). EP-56's tests target whichever
signature exists when they run and are updated by EP-55 if EP-56 lands first — both
plans note this.

The new minting endpoint (EP-57) lives in `en-servant`/`en-server` and must follow the
external conventions of master plan 6: the versioned wire contract and typed error
envelope (docs/plans/35), caller authentication (docs/plans/33), and the config record
(docs/plans/38) for issuer-key configuration. Issuer secret-key material moves from an
in-memory `SecretKey` (`MintConfig` in `Mint.hs`) to configuration with a documented
loading path; EP-55 defines the key-material representation, EP-57 wires it into server
config.


## Progress

- [x] EP-55 (2026-07-10): tokens carry a key id; verifiers accept a keyset; rotation demonstrated without redeploying verifiers (`keyRotationTest`, `legacyTokenTest`, `keySelectionAttackTest`)
- [x] EP-55 (2026-07-10): every token revocable via built-in block revocation ids; application revocationId remains optional (`blockRevocationTest`)
- [x] EP-56: holder-attenuated blocks injecting en_right/en_expires_at facts proven ignored or rejected
- [ ] EP-57: authenticated HTTP endpoint mints a grant from a fresh check at a checked-at token
- [ ] EP-57: minted-over-HTTP token verifies and attenuates locally end-to-end


## Surprises & Discoveries

- EP-56: the fact-scoping assumption **holds** against the pinned
  biscuit-haskell. No rewrite of `extractAndCheck` is needed, so EP-55 builds on
  today's `Verify.hs` shape unchanged — the conditional dependency the
  Decomposition Strategy warned about never materialized. EP-55 is unblocked
  exactly as registered.

- EP-56: the forged facts are not uniformly dangerous, which sharpens what EP-55
  must preserve. Only `en_container_scope` is genuinely exploitable if scoping
  ever breaks, because `resolveScope`'s `containerRefs` keeps *every* matching
  row; the single-valued facts go through `getSingleVariableValue`, which returns
  `Nothing` on two rows and so fails closed with `MalformedGrant`. The exception
  is `en_revocation_id`, whose `Nothing` means "not revocable" rather than
  "malformed" — a visible forged row would silently skip the revocation check
  rather than fail. **EP-55 must keep this in mind**: its unconditional
  block-revocation-id check is precisely what removes that soft spot, since
  built-in revocation ids are signature bytes in the token envelope and cannot be
  shadowed by a Datalog fact at all.

- EP-56: `trusting previous` parses in the `query` quasiquoter but is rejected in
  the `authorizer` quasiquoter (`Auth/Biscuit/Datalog/Parser.hs:430`,
  `PreviousInAuthorizer`). Any plan reaching for an authorizer policy to inspect
  holder-block facts must use `queryRawBiscuitFacts` instead.

- EP-56: the new tests were validated by mutation — making `resolveScope` trust
  holder blocks turns the suite red — so they are a genuine tripwire for a future
  `cabal.project` re-pin of biscuit-haskell, not merely green assertions.

- EP-56 pins *fact* scoping only. Whether a holder can influence which issuer key
  a verifier selects is untested ground that arrives with EP-55's `rootKeyId`
  keyset selection; EP-55 should carry that test itself. EP-56's seven tests need
  only a mechanical `verifyGrant` call-site update when EP-55 lands (`singleKey`
  plus a `const (pure False)` block check); none of their assertions depend on
  key material.

- EP-55 landed (2026-07-10) and confirmed both predictions above. EP-56's seven
  fact-scoping tests took exactly the mechanical call-site update through a shared
  `keySetFor` helper — no assertion changed. The key-selection surface EP-56
  flagged is now closed by `keySelectionAttackTest`: an A-signed token claiming
  key id 2 fails `SignatureInvalid` against a keyset mapping id 2 → key B, because
  `selectIssuerKey` routes by the attacker-visible id but the crypto rejects the
  mismatch.

- **Interface change EP-57 must consume** (`docs/plans/57-mint-biscuit-grants-over-http.md`):
  the token-format contract is now broken exactly once, as intended. `verifyGrant`
  takes an `En.Biscuit.Keys.IssuerKeySet` (not a single `PublicKey`);
  `VerifyRequest` now *requires* a `revokedBlockIds :: Set ByteString -> m Bool`
  field; and every mint function returns `En.Biscuit.Mint.MintedGrant` (`token`,
  `expiresAt`, `revocationIds`) instead of bare `ByteString`. `MintConfig` gained
  `issuerKeyId :: IssuerKeyId`. EP-57 loads issuer key material via
  `parseSigningKeyText` / `parseIssuerKeySetText` from `En.Biscuit.Keys` and
  returns the `MintedGrant` fields in its HTTP response body. The
  `EN_BISCUIT_SIGNING_KEY` / `EN_BISCUIT_ISSUER_KEYS` text formats are documented
  in `docs/user/biscuit-decision-tokens.md` (Key rotation and revocation).

- Deviation from EP-55's sketch, recorded for EP-57's benefit: the entire
  `En.Biscuit.Keys` module (identity, keyset, and text codecs) was created in the
  M1 commit rather than accreted across milestones — the plan explicitly permitted
  one home for `IssuerKeyId`. So all of `En.Biscuit.Keys` is available as of the
  first EP-55 commit, not staged by milestone.


## Decision Log

- Decision: Keep EP-56 test-only and independent.
  Rationale: It pins a dependency assumption the whole layer rests on; it must be able to run before any feature work and act as a tripwire for biscuit-haskell upgrades.
  Date: 2026-07-07
- Decision: Express EP-57's dependency on checked-at tokens as an external hard dependency on docs/plans/51 (master plan 9).
  Rationale: The registry only models dependencies within this master plan; the cross-plan requirement is real (EnGrant needs a ConsistencyToken whose source is the check response) and is recorded here and in EP-57 itself.
  Date: 2026-07-07
- Decision: Defer a revocation distribution mechanism.
  Rationale: Storing/serving revocation lists is a service concern; the watch API (docs/plans/53) is the natural carrier once it exists. This plan only guarantees every token is revocable in principle.
  Date: 2026-07-07
- Decision: EP-55 proceeds against the existing `Verify.hs` shape; the M3 contingency in EP-56 is retired.
  Rationale: EP-56 landed green, so the fact-scoping assumption `extractAndCheck` rests on is confirmed against the pinned biscuit-haskell and no authority-scoped rewrite is required. The soft ordering EP-56-before-EP-55 has paid off exactly as intended: EP-55 now knows which verifier it is building on.
  Date: 2026-07-10
- Decision: EP-55 must additionally test whether a holder can influence issuer-key selection.
  Rationale: EP-56 pins fact scoping under a single key. Key-id selection (`rootKeyId`) is attacker-visible metadata in the token envelope, and "which key does the verifier reach for" is a new attack surface that arrives only with EP-55's keyset. It belongs in the plan that introduces it, not in a retrofit of EP-56.
  Date: 2026-07-10


## Outcomes & Retrospective

(To be filled during and after implementation.)


---

Revision note (2026-07-07): Corrected the Integration Points section — key identifiers
and revocation ids are carried by the Biscuit token envelope and block signatures, not
by new `en_*` Datalog facts, so EP-55 does not change the grant fact vocabulary. Found
while grounding EP-55/EP-56 in the biscuit-haskell source. Also noted there: the
downstream header convention is the existing `X-En-Biscuit` header per
`docs/user/biscuit-decision-tokens.md` (EP-57 Decision Log), not `Authorization: Bearer`.
