---
title: "Biscuit decision tokens: mint, verify, attenuate"
type: Capability
description: "Turn a successful en decision into a short-lived signed Biscuit a downstream service can verify locally and attenuate before forwarding, with key ids, keyset rotation, and block-based revocation."
generated:
  by: anthropic/claude-opus-5
  at: "2026-08-24T14:35:00Z"
capabilityId: CAP-24
provider: mori://shinzui/en
status: shipped
stability: experimental
since: unreleased
packages:
  - en-biscuit
interface:
  - En.Biscuit.Mint
  - En.Biscuit.Verify
  - En.Biscuit.Keys
  - En.Biscuit.Grant
  - POST /v1/grants
  - en-verify-grant
requires:
  - CAP-6
evidence:
  - kind: test
    resource: en-biscuit/test/Main.hs
    proves: Twenty-seven scenarios covering object and scoped grants, fail-closed minting, key-id round-trip, key rotation, legacy tokens, block revocation, attenuation and its narrowing direction, authorizer scoping, and forged right/expiry/revocation/scope/subject attempts — plus a key-selection attack and a datalog injection-safety test.
  - kind: example
    resource: en-biscuit/app/VerifyGrant.hs
    proves: A runnable verifier that prints the verified subject, operation, resource, expiry, and request id, then demonstrates that an attenuated token is accepted by its target service and rejected for a different one.
  - kind: guide
    resource: docs/user/biscuit-decision-tokens.md
    proves: The end-to-end flow — Shomei authenticates, en authorizes, Biscuit delegates — with minting over HTTP, local verification, attenuation, key rotation, and revocation.
---

# Biscuit decision tokens: mint, verify, attenuate

An optional layer that carries an authorization decision across a service boundary without the
downstream service calling back. The division of labour it enforces:

> **Shomei authenticates, `en` authorizes, Biscuit delegates.**

A gateway runs a [check](check-decisions-with-caveats.md); on `Allowed` it mints a short-lived
Biscuit carrying the subject, the operation, the resource, and an expiry. A downstream service
verifies that token **locally** against a trusted keyset — no network call to `en` — and may
attenuate it (narrow it to one service, one resource, a shorter expiry) before forwarding.

Minting is fail-closed: `mintCheckedObjectGrant` runs the check itself and refuses to mint on
anything but `Allowed`. Over HTTP it is `POST /v1/grants`, and
[the server](standalone-authorization-server.md) refuses to start with minting enabled unless
caller authentication is also on.

Keys are `<key-id>:<hex>` entries, so rotation is a config-only rollout: publish the new public
key in the verifier keyset, then switch the minter's signing key. A `legacy:<hex>` entry covers
tokens minted before key ids existed.

## Limits

- **Attenuation only narrows.** A block can never widen a grant, and the tests assert forged
  rights, expiries, revocations, scopes, and subjects are all rejected — but this is a property
  of Biscuit's block model, so a verifier that skips `runRestrictions` loses it.
- Revocation is block-based and depends on the verifier consulting a revocation list; there is no
  push invalidation. Keep TTLs short.
- `en-core` stays token-agnostic. This package depends on `biscuit-haskell`; nothing else does.
