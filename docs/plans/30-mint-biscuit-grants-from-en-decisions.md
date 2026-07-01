---
id: 30
slug: mint-biscuit-grants-from-en-decisions
title: "Mint Biscuit grants from en decisions"
kind: exec-plan
created_at: 2026-07-01T04:50:38Z
master_plan: "docs/masterplans/5-add-biscuit-decision-token-support.md"
intention: intention_01kwe136p1expbzvj08bqwtz08
---

# Mint Biscuit grants from en decisions

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan adds `En.Biscuit.Mint`, the API that turns successful `en`
authorization decisions into signed Biscuit tokens. After this change, a
gateway or resource-owning service can call `en.check` or `en.lookup`, mint a
short-lived grant only when the result is allowed, and forward the token to a
downstream service.

The observable behavior is a test that performs an `Allowed` check, mints a
Biscuit, serializes it, parses it with the public key, and sees the expected
`en_*` facts. Tests also prove `Denied`, `Conditional`, and engine errors do
not mint tokens.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: Define minting configuration, errors, and key handling in `En.Biscuit.Mint`. (2026-06-30) — `MintConfig m { issuerSecretKey, defaultTtl, now }` and `EnBiscuitMintError` (`DecisionDenied`, `DecisionConditional [CaveatObligation]`, `EngineError EnError`, `EmptyLookupScope`, `LookupScopeTooLarge Int Int`, `GrantEncodingError EnBiscuitError`).
- [x] M2: Implement object-grant minting from a `CheckDecision` or from a caller-supplied check action. (2026-06-30) — portable `MonadIO m` `mintObjectGrant`/`mintObjectGrantWithExpiry` (precomputed decision), plus the `Eff es` `mintCheckedObjectGrant` that runs `En.Check.check` and surfaces engine errors as `EngineError`.
- [x] M3: Implement scoped-grant minting from bounded lookup/container results. (2026-06-30) — `mintScopedGrant`/`mintScopedGrantWithExpiry` reject empty (`EmptyLookupScope`) and oversized (`LookupScopeTooLarge`) container lists.
- [x] M4: Add tests proving allowed-only minting, expiry defaults, schema hash and consistency-token propagation, and fail-closed behavior. (2026-06-30) — `cabal test en-biscuit` → `en-biscuit tests PASS`; covers Allowed-mints-en_right, Denied/Conditional/engine-error non-mints, `now + defaultTtl` expiry window, consistency-token/schema-hash propagation, and scoped bounds.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery during planning: `Auth.Biscuit.mkBiscuit` signs an authority block
  with a `SecretKey`, and `serializeB64` emits the bearer-token form that
  `biscuit-servant` can later parse from an Authorization header.
  Date: 2026-07-01

- Implementation 2026-06-30: `mkBiscuit :: SecretKey -> Block -> IO (Biscuit Open Verified)`
  cannot fail with a value (it returns a `Biscuit`, not an `Either`), so the
  planned `BiscuitBuildFailed Text` error constructor would be unconstructable
  dead code. It was dropped; the only pre-sign failure is grant encoding, carried
  by `GrantEncodingError EnBiscuitError` (e.g. a non-concrete subject from
  EP-29). An empty scope needed its own constructor (`EmptyLookupScope`) since
  "too large" does not describe zero containers.
  Date: 2026-06-30

- Implementation 2026-06-30: to test "engine errors are surfaced and do not
  mint", the reliable trigger is an unknown relation: `En.Check.check` does
  `either throwError pure =<< runCheck …` (`en-core/src/En/Check.hs:68`) and
  `runCheck` returns `Left (UnknownRelation …)` for a relation absent from the
  reachability graph (`En/Check.hs:187`). The in-memory `runConsistencyStoreInMemory`
  never errors (it always resolves to `testRevision`), so consistency is not a
  usable error source. `mintCheckedObjectGrant` checking permission
  `"no-such-permission"` therefore yields `Left (EngineError (UnknownRelation …))`.
  Date: 2026-06-30

- Implementation 2026-06-30: `runErrorNoCallStack @EnError`
  (`Effectful.Error.Static`) discharges the engine's `Error EnError` effect
  locally inside `mintCheckedObjectGrant`, so its constraints are only
  `(ConsistencyStore :> es, TupleStore :> es, IOE :> es)` — the caller does not
  need `Error EnError`. This is what keeps the "runs a decision" convenience an
  `Eff es` wrapper without leaking a `MonadIO`-only or Biscuit surface back into
  `en-core`, exactly as the MasterPlan requires.
  Date: 2026-06-30

- Implementation 2026-06-30: record /update/ on `expiresAt`
  (`grant{expiresAt = …}`) triggers GHC's `-Wambiguous-fields` because that
  field is shared by `EnGrant` and `EnScopedGrant` under `DuplicateRecordFields`
  (a mechanism GHC warns it will drop). Record /construction/ is unambiguous, so
  `withObjectExpiry`/`withScopedExpiry` rebuild the record explicitly. Relevant
  for EP-31 if it needs to attenuate/rewrite grant fields.
  Date: 2026-06-30

- Validation 2026-06-30: `En.Check.check`/`checkMany` and `En.Lookup.lookup` are
  `effectful` functions, e.g.
  `check :: (ConsistencyStore :> es, TupleStore :> es, Error EnError :> es) => ReachabilityGraph -> Consistency -> CaveatContext -> Subject -> RelationName -> ObjectRef -> Eff es CheckDecision`
  (`en-core/src/En/Check.hs`). `CheckDecision(Allowed | Denied | Conditional [CaveatObligation])`
  is defined in `En.Decision` and re-exported by `En.Check`. Consequence for the
  M2 "higher-level helper that runs a caller-provided check action": that helper
  must run in `Eff es` with the engine effect constraints above — it is NOT
  `MonadIO m`. The `MonadIO m` signatures in "Interfaces and Dependencies"
  (`mintObjectGrant`/`mintScopedGrant`) remain correct precisely because they
  take a precomputed `CheckDecision` and only perform Biscuit signing; keep that
  low-level "decision → token" API as the required deliverable and expose any
  check-running convenience as a separate `Eff es` wrapper.
  Date: 2026-06-30


## Decision Log

Record every decision made while working on the plan.

- Decision: Make minting usable both from precomputed decisions and from helper
  functions that run `en.check`.
  Rationale: Some callers already use `en-servant` or `en-client` and will have
  a `CheckResponseWire`; embedded Haskell services can call `check` directly.
  The token layer should not force one deployment shape.
  Date: 2026-07-01

- Decision: Treat `Conditional` as not mintable.
  Rationale: A conditional decision means required caveat context was not fully
  satisfied. A portable downstream grant must not erase that uncertainty.
  Date: 2026-07-01

- Decision (2026-06-30): The issuer controls token lifetime. `mintObjectGrant`/
  `mintScopedGrant` stamp expiry as `now + defaultTtl` (from `MintConfig`),
  overwriting whatever `EnGrant.expiresAt` the caller supplied; explicit expiry
  goes through the `…WithExpiry` variants. Rationale: a grant builder must not be
  able to forge a long-lived token by setting a far-future `expiresAt`; the
  minting service's configured TTL is authoritative. This satisfies the
  acceptance rule "expiry is now + defaultTtl unless an explicit expiry is
  supplied" while keeping `EnGrant.expiresAt` (a required EP-29 field) meaningful
  as the value the token actually carries.
  Date: 2026-06-30

- Decision (2026-06-30): `mintScopedGrant` takes no `CheckDecision`. Rationale:
  the caller derives the bounded container list from `en.lookup` (which is itself
  a set of allowed containers); scoped minting records that bounded scope and
  enforces its size, it does not re-run a per-object decision. Object minting,
  which corresponds to a single `en.check`, is the path gated on `Allowed`.
  Date: 2026-06-30

- Decision (2026-06-30): Dropped the planned `BiscuitBuildFailed Text` error
  constructor. Rationale: `mkBiscuit` returns `IO Biscuit`, not `IO (Either …)`,
  so there is no build-failure value to carry; keeping the constructor would be
  unconstructable. Grant-encoding failures use `GrantEncodingError`. (The plan's
  Interfaces section permitted adjusting the error set.)
  Date: 2026-06-30


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

Outcome (2026-06-30): `En.Biscuit.Mint` turns successful `en` decisions into
signed Biscuit tokens and fails closed on everything else. All acceptance
criteria hold (proven by `cabal test en-biscuit`):

- `Allowed` object decision mints a token containing `en_right` (and the
  supplied `en_consistency_token`/`en_schema_hash`).
- `Denied` → `Left DecisionDenied`; `mkBiscuit` is not called.
- `Conditional` → `Left (DecisionConditional obligations)`; not minted.
- Engine errors (via the `Eff es` `mintCheckedObjectGrant` path) → `Left
  (EngineError …)`; not minted.
- Token expiry is `now + defaultTtl` (asserted by an authorizer date window);
  `…WithExpiry` variants allow an explicit expiry.
- Scoped minting emits one `en_container_scope` per container and rejects empty
  (`EmptyLookupScope`) and oversized (`LookupScopeTooLarge`) scopes.

Deliverables: the portable `MonadIO m` "decision → token" API
(`mintObjectGrant`, `mintScopedGrant`, `…WithExpiry`) is the required target;
`mintCheckedObjectGrant` is the `Eff es` convenience that runs `En.Check.check`.
`en-core` gained no Biscuit or `MonadIO`-only surface. New file:
`en-biscuit/src/En/Biscuit/Mint.hs`; `En.Biscuit` re-exports it; `en-biscuit`
gained `effectful`/`effectful-core` deps (library) and `containers`/`effectful`/
`effectful-core` (test).

For EP-31: verify against the exact facts minted here — `en_right`,
`en_scoped_right`, `en_container_scope`, `en_audience`, `en_expires_at`,
`en_consistency_token`, `en_schema_hash`, and (when present) `en_request_id`/
`en_revocation_id` — and treat token expiry as issuer-authoritative.


## Context and Orientation

This plan depends on
`docs/plans/29-define-the-en-biscuit-grant-vocabulary.md`. That plan defines
`En.Biscuit.Grant` and the `en_*` facts. This plan adds signing and decision
gating.

Relevant current modules:

- `en-core/src/En/Check.hs` exposes `check`, `checkCached`, `checkMany`, and
  `CheckDecision`.
- `en-core/src/En/Lookup.hs` exposes `lookup` and `lookupWithDeadline`, which
  return reachable objects and their decisions.
- `en-core/src/En/Revision.hs` defines `ConsistencyToken` and `SchemaHash`.
- `en-servant/src/En/Servant/API.hs` exposes `/check`, `/batch-check`, and
  `/lookup` wire endpoints, but this plan should not require the HTTP API.

A minting key is the Biscuit issuer's private key. Downstream services verify
tokens with the corresponding public key. This key is separate from Shomei's
JWT signing keys.


## Plan of Work

Milestone 1 creates `en-biscuit/src/En/Biscuit/Mint.hs`. Define a
configuration type:

```haskell
data MintConfig m = MintConfig
    { issuerSecretKey :: SecretKey
    , defaultTtl :: NominalDiffTime
    , now :: m UTCTime
    }
```

Define an error type such as `EnBiscuitMintError` with constructors for
`DecisionDenied`, `DecisionConditional`, `EngineError EnError`,
`LookupScopeTooLarge`, and `BiscuitBuildFailed Text`.

Milestone 2 implements object-grant minting. Provide a function that accepts a
precomputed `CheckDecision` plus grant fields and returns a serialized Biscuit,
and a higher-level helper that runs a caller-provided check action. The important
rule is simple: only `Allowed` reaches `mkBiscuit`.

Milestone 3 implements scoped-grant minting for list reads. This helper should
accept a bounded list of container `ObjectRef`s that the caller already derived
from `en.lookup`. It must reject empty or oversized container lists according to
a caller-supplied maximum. It must not attempt to store a huge list of every
authorized resource in a token.

Milestone 4 adds tests. Use the in-memory conformance store from
`En.Conformance.Kikan` or a tiny local fixture. Tests should mint with a
deterministic key from `parseSecretKeyHex`, serialize with `serializeB64`, parse
with the public key, and query facts or verify with a permissive authorizer.


## Concrete Steps

Work from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/en
sed -n '1,220p' en-core/src/En/Check.hs
sed -n '1,220p' en-core/src/En/Lookup.hs
sed -n '1,180p' /Users/shinzui/Keikaku/hub/haskell/biscuit-haskell-project/biscuit-haskell/biscuit/src/Auth/Biscuit/Example.hs
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

Acceptance requires tests proving:

- `Allowed` object decision mints a token containing `en_right`.
- `Denied` returns `DecisionDenied` and does not call `mkBiscuit`.
- `Conditional` returns `DecisionConditional` and does not mint.
- Engine errors are surfaced as mint errors and do not mint.
- The token expiry is `now + defaultTtl` unless an explicit expiry is supplied.
- The token contains the supplied `ConsistencyToken` and `SchemaHash`.
- Scoped minting emits container facts and rejects a list larger than the
  configured maximum.


## Idempotence and Recovery

Minting tests should use deterministic keys and fixed timestamps so they are
repeatable. If the serialized Biscuit changes byte-for-byte due to library
internals, assert semantic facts through parsing or authorizer queries rather
than golden bytes.

If a higher-level helper entangles too much of the `effectful` engine stack,
keep the low-level "decision to token" API and record the embedded-helper
adjustment in this plan. The lower-level API is the required deliverable.


## Interfaces and Dependencies

New module:

- `en-biscuit/src/En/Biscuit/Mint.hs`

Target API shape:

```haskell
data MintConfig m
data EnBiscuitMintError

mintObjectGrant ::
    MonadIO m =>
    MintConfig m ->
    CheckDecision ->
    EnGrant ->
    m (Either EnBiscuitMintError ByteString)

mintScopedGrant ::
    MonadIO m =>
    MintConfig m ->
    Int ->
    EnScopedGrant ->
    m (Either EnBiscuitMintError ByteString)
```

If the implementation returns an open verified `Biscuit` instead of serialized
bytes, also provide a serialization helper so downstream HTTP examples can carry
the token in a header.
