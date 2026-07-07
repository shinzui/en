---
id: 57
slug: mint-biscuit-grants-over-http
title: "Mint Biscuit grants over HTTP"
kind: exec-plan
created_at: 2026-07-07T15:25:10Z
master_plan: "docs/masterplans/10-harden-the-biscuit-decision-token-layer.md"
---

# Mint Biscuit grants over HTTP

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today, Biscuit decision tokens can only be minted by embedded Haskell callers
of `En.Biscuit.Mint` — a pure HTTP consumer of `en-server` has no way to obtain
one (finding D3 of
`docs/reviews/2026-07-07-architecture-performance-review.md`). After this
plan, an authenticated caller can `POST /grants` to `en-server` with a
subject, permission, and object; the server runs the authorization check and,
only if the decision is `Allowed`, mints and returns a short-lived Biscuit
grant bound to the consistency token the check actually evaluated at. The
response carries the serialized token, its expiry, and its revocation ids, and
the caller forwards the token downstream in the `X-En-Biscuit` header, where
any service verifies and attenuates it locally with `En.Biscuit.Verify` — no
further `en-server` calls.

The end-to-end acceptance: `curl` mints a token from a running `en-server`,
and a downstream verifier binary verifies it locally, attenuates it, and shows
the narrowed token verifying for the narrow request but not the broad one.

## ⚠ Two external prerequisites — verify BEFORE starting

This plan must not begin implementation, and must not be deployed, until both
of the following hold. Check the named plan files' Progress sections first;
as of 2026-07-07 both are unfilled skeletons (Not Started), so this plan is
**blocked** until they land.

1. **Hard dependency:**
   `docs/plans/51-return-checked-at-consistency-tokens-from-read-responses.md`
   (master plan 9) must be **Complete**. `EnGrant` *requires* a
   `consistencyToken :: ConsistencyToken` — a non-optional field
   (`en-biscuit/src/En/Biscuit/Grant.hs`, line 103) that
   `En.Biscuit.Mint.signGrant` serializes into the signed authority block as
   the `en_consistency_token` fact (via `grantBlock`/`metaFacts` in
   `Grant.hs`). The minting flow is check-then-mint-at-that-token: the grant
   must carry the token the check evaluated at, and today no read path
   supplies one — `CheckResponseWire` is decision-only
   (`en-servant/src/En/Servant/API.hs`, lines 199–203) and `check` returns a
   bare `CheckDecision`. Fabricating a placeholder token would sign a false
   freshness claim into a bearer credential. There is no workaround; wait for
   plan 51.
2. **Hard deployment dependency:**
   `docs/plans/33-add-caller-authentication-and-rate-limiting-to-en-server.md`
   (master plan 6) must be **deployed** on any server that enables this
   endpoint. A minting endpoint on an unauthenticated server hands signed
   bearer tokens to anyone with network reach. This plan encodes the rule as a
   startup check: if grant minting is configured but caller authentication is
   not active, `en-server` refuses to start (Milestone 2). Do not weaken this
   to a warning.

Soft dependency: EP-55
(`docs/plans/55-support-key-rotation-and-unconditional-revocation-in-biscuit-grants.md`)
defines the issuer key-material representation this plan wires into server
config, and the `MintedGrant` result carrying revocation ids. If EP-55 has not
landed, mint single-key (see Decision Log) and record the follow-up.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M0: Verified prerequisite 1 — plan 51 Complete; located the checked-at-returning check surface it produced and recorded its exact shape here.
- [ ] M0: Verified prerequisite 2 — plan 33's auth mechanism exists; recorded how "auth is active" is detectable at startup.
- [ ] M0: Checked whether EP-55 and EP-35 have landed; recorded which key format and wire conventions apply.
- [ ] M1: Added `MintGrantRequestWire`/`MintGrantResponseWire` and the `POST /grants` route to `EnAPI` in `en-servant/src/En/Servant/API.hs`.
- [ ] M1: Added `MintEnv` and the optional `mint` field to `Env` in `en-servant/src/En/Servant/Seam.hs`; `en-servant` gains the `en-biscuit` dependency.
- [ ] M1: Implemented `mintGrantHandler`: decode, concrete-subject check, checked check at a token, fail-closed non-mint responses, TTL clamping, mint, respond.
- [ ] M1: Handler tests (or en-example round-trip) proving Allowed mints and Denied/Conditional/disabled do not.
- [ ] M2: Server config in `en-server/app/Main.hs`: issuer key env vars (EP-55 format), TTL bounds, startup refusal when minting is on but auth is off.
- [ ] M3: Downstream verifier executable `en-verify-grant` added to `en-biscuit/en-biscuit.cabal` and `en-biscuit/app/VerifyGrant.hs`.
- [ ] M3: End-to-end acceptance transcript captured: curl mints; `en-verify-grant` verifies and attenuates locally.
- [ ] M3: `docs/user/biscuit-decision-tokens.md` updated: HTTP minting section and the standard `X-En-Biscuit` header convention.
- [ ] Final: `cabal build all` and package test suites pass; Outcomes & Retrospective written.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: The endpoint mints *object grants only*
  (subject/permission/object). Scoped grants (container lists from `lookup`)
  are deferred.
  Rationale: An object grant corresponds one-to-one to a single `check`, whose
  fail-closed gating (`mintObjectGrant` mints only on `Allowed`) is already
  proven. A scoped HTTP mint would need lookup-page plumbing and a container
  bound negotiation; nothing downstream needs it yet. Record as future work.
  Date: 2026-07-07
- Decision: The downstream transport header is `X-En-Biscuit: <base64
  biscuit>`, not `Authorization: Bearer <biscuit>`.
  Rationale: `docs/user/biscuit-decision-tokens.md` ("Transport: two tokens,
  two headers", delivered by
  `docs/plans/32-document-shomei-compatible-biscuit-authorization-flows.md`)
  already establishes that `Authorization` carries the Shomei identity token
  and warns against overloading one header with two token types. This plan
  formalizes the existing convention rather than inventing a competing one.
  Date: 2026-07-07
- Decision: When minting is not configured, `POST /grants` returns 404 with
  the JSON error envelope; when the decision is `Denied` or `Conditional`, it
  returns 403 with a body naming the non-mint reason (no obligations detail
  beyond what `/check` already exposes).
  Rationale: 404 avoids advertising a disabled capability; 403 mirrors the
  fail-closed posture of `En.Servant.Authorize.requirePermission` and of
  `mintObjectGrant` itself. If EP-35's typed error model has landed, use its
  error codes instead of the bare `ErrorWire` message.
  Date: 2026-07-07
- Decision: The caller may request a TTL (`ttlSeconds`); the server rejects —
  not clamps — requests above the configured maximum, with 400.
  Rationale: Silent clamping returns a token with a different lifetime than
  requested, which callers then cache wrongly; an explicit error is
  observable. The default (absent `ttlSeconds`) is the configured default TTL.
  Date: 2026-07-07
- Decision: Wire conventions: this plan follows
  `docs/plans/35-version-the-wire-contract-and-type-the-error-model.md` if it
  has landed (versioned route prefix, typed error envelope); otherwise it
  matches the current `en-servant` style — generic-Aeson `…Wire` records,
  `jsonError` + `ErrorWire` bodies, unversioned paths — and migrates when
  EP-35 does. The route is `POST /grants` either way (under EP-35's prefix it
  becomes e.g. `POST /v1/grants`).
  Rationale: EP-35 is an unfilled skeleton today; blocking on it is
  unnecessary (unlike auth, wire style is not a safety property), but the
  contract must not fork from whatever it establishes.
  Date: 2026-07-07
- Decision: If EP-55 has not landed when this plan is implemented, configure a
  single issuer key as `EN_BISCUIT_ISSUER_SECRET_KEY=<64 hex chars>` (no key
  id), mint with the then-current `mintObjectGrantWithExpiry`, and recover
  revocation ids for the response by re-parsing the minted token with
  `Auth.Biscuit.parseB64 (toPublic secret)` and calling `getRevocationIds`.
  Record the keyed-format migration as follow-up work in this plan.
  Rationale: Keeps the response shape (`revocationIds` included) stable across
  the EP-55 transition, so HTTP clients never see the field appear later.
  Date: 2026-07-07
- Decision: The endpoint always runs its own check; it does not accept a
  caller-supplied decision.
  Rationale: A mint endpoint that trusts "I was allowed, honest" is a token
  printer. The caller supplies check inputs (consistency mode, context,
  subject, permission, object); the server derives the decision and the
  checked-at token itself.
  Date: 2026-07-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

`en` is a relationship-based authorization engine; `en-server` is its
standalone HTTP service. The pieces this plan touches:

- `en-servant/src/En/Servant/API.hs` — the Servant API type `EnAPI` (lines
  92–98: `/tuples`, `/check`, `/batch-check`, `/lookup`, `/expand`), the
  `…Wire` JSON record types, the handlers, and the wire conversion helpers
  (`subjectFromWire`, `objectRefFromWire`, `consistencyFromWire`,
  `contextFromWire`). New endpoints are added here.
- `en-servant/src/En/Servant/Seam.hs` — the `Env es` record (line 37): the
  seam holding `runPorts` (run an engine action in IO), the compiled
  `graph`, the `checkOperation`, and knobs like `maxBatchSize`. Handlers get
  everything through `Env`. The JSON error envelope is `ErrorWire` via
  `jsonError`.
- `en-server/app/Main.hs` — the executable: reads env vars (`EN_DATABASE_URL`,
  `EN_PORT`, `EN_SCHEMA_PATH`, cache knobs), builds the `Env`, and runs Warp.
  The active schema hash is computed here (`activeSchemaHash`, line 43) but is
  not currently in `Env` — minting needs it, since every grant embeds
  `en_schema_hash`.
- `en-biscuit/` — the token layer. `En.Biscuit.Mint.mintObjectGrantWithExpiry`
  takes a `MintConfig` (issuer secret key, TTL, clock), a `CheckDecision`, and
  an `EnGrant`, and mints only on `Allowed` — `Denied`, `Conditional`, engine
  errors, and unencodable grants (e.g. non-concrete subjects) all fail closed.
  `EnGrant` (`en-biscuit/src/En/Biscuit/Grant.hs`) requires `subject`,
  `permission`, `object`, `consistencyToken` (line 103, non-optional),
  `schemaHash`, `expiresAt`, `audience`, and optional `requestId`/
  `revocationId`. `En.Biscuit.Verify.verifyGrant`/`attenuateGrant` do local
  verification/attenuation. If EP-55 has landed, minting also takes an
  `IssuerKeyId`, returns a `MintedGrant` (token, expiry, revocation ids), and
  key material has the text formats in `En.Biscuit.Keys`
  (`parseSigningKeyText`: `"<id>:<64-hex>"`; `parseIssuerKeySetText`:
  `"<id>:<hex>,…[,legacy:<hex>]"`).
- `docs/user/biscuit-decision-tokens.md` — the user guide (the
  Shomei-compatible flow doc from `docs/plans/32-…`). It already defines the
  two-header transport (`Authorization: Bearer <shomei-jwt>` for identity,
  `X-En-Biscuit: <base64-biscuit>` for the decision proof).

Terms: a *consistency token* (zookie) is an opaque string naming a store
revision; `AtLeastAsFresh <token>` asks the engine to answer no staler than
that revision. The *checked-at token* is the token for the revision a check
actually evaluated at — plan 51's deliverable is that read responses return
it. A *grant* is the signed proof of one `Allowed` decision; the *audience* is
the service the grant is intended for; *attenuation* is a holder appending
narrowing checks to a token offline.

Review and master plan context: this plan implements finding D3 of
`docs/reviews/2026-07-07-architecture-performance-review.md` (see also E3
there, which is plan 51) and is child EP-57 of
`docs/masterplans/10-harden-the-biscuit-decision-token-layer.md`. Integration
points restated so this plan stands alone: the wire contract and error
envelope follow `docs/plans/35-…` when it lands (Decision Log); caller
authentication and rate limiting come from `docs/plans/33-…` and gate
deployment; server configuration conventions come from `docs/plans/38-…`
(validated env vars — follow its patterns if landed, plain env vars
otherwise); issuer key material representation comes from EP-55; the
fact-scoping safety of handing tokens to arbitrary holders is pinned by EP-56
(`docs/plans/56-pin-attenuation-injection-semantics-with-tests.md`).


## Plan of Work

Milestone 0 — prerequisite verification (no code). Read the Progress sections
of `docs/plans/51-…` and `docs/plans/33-…`. If plan 51 is not Complete, stop:
this plan is blocked (see the prerequisites banner). If it is Complete, find
the surface it added for checked-at tokens — expect either `CheckResponseWire`
gaining a `checkedAt` field and/or an `Env` check operation returning
`(CheckDecision, ConsistencyToken)` — and record the exact names here (update
this plan; it is a living document). Likewise record how plan 33 exposes
"authentication is enabled" (a config flag, an auth env record, or the
presence of an API-key set) — Milestone 2's startup check needs a concrete
predicate. Record EP-55/EP-35 status. Acceptance: this plan's Context section
updated with the real shapes, and the Progress items for M0 checked.

Milestone 1 — the endpoint. Scope: `en-servant` gains the route, wire types,
env plumbing, and handler; nothing server-side yet. Add `en-biscuit` to the
`build-depends` of the `en-servant` library in
`en-servant/en-servant.cabal`. In `en-servant/src/En/Servant/Seam.hs` add:

```haskell
data MintEnv = MintEnv
    { issuerSecretKey :: SecretKey        -- from config; never logged
    , issuerKeyId :: IssuerKeyId          -- omit if EP-55 has not landed
    , defaultTtl :: NominalDiffTime
    , maxTtl :: NominalDiffTime
    , audience :: Text -> Audience        -- or store nothing and pass through; see below
    , schemaHash :: SchemaHash            -- the active schema hash
    }
```

(the `audience` field is just `Audience` construction — callers name their
target audience in the request; keep `MintEnv` to key, TTLs, and schema hash
if that is simpler) and extend `Env es` with `mint :: !(Maybe MintEnv)`.
`Nothing` means the endpoint is disabled. In
`en-servant/src/En/Servant/API.hs` add the wire types:

```haskell
data MintGrantRequestWire = MintGrantRequestWire
    { consistency :: !ConsistencyWire
    , context :: !CaveatContextWire
    , subject :: !SubjectWire        -- must be SubjectIdWire; others: 400
    , permission :: !Text
    , object :: !ObjectRefWire
    , audience :: !Text              -- the downstream service this grant targets
    , ttlSeconds :: !(Maybe Int)     -- <= configured max, else 400; default: configured default
    , requestId :: !(Maybe Text)     -- optional correlation id, echoed into en_request_id
    }

data MintGrantResponseWire = MintGrantResponseWire
    { token :: !Text                 -- URL-safe base64 Biscuit (serializeB64 output)
    , expiresAt :: !UTCTime
    , revocationIds :: ![Text]       -- hex-encoded built-in block revocation ids
    , checkedAt :: !Text             -- the consistency token the check evaluated at
    }
```

and the route `"grants" :> ReqBody '[JSON] MintGrantRequestWire :> Post
'[JSON] MintGrantResponseWire` appended to `EnAPI`, with `mintGrantHandler`
wired into `server`. The handler, in order: if `env.mint` is `Nothing`, throw
404 via `jsonError`; decode subject/object/consistency/context with the
existing `either400` helpers; reject non-`SubjectIdWire` subjects with 400
("grants require a concrete subject" — `grantBlock` would fail closed anyway,
but a 400 is a clearer contract than a 500); validate `ttlSeconds` (positive,
`<= maxTtl`); run the checked check through the plan-51 surface recorded in
M0, obtaining `(decision, checkedAtToken)`; on `Denied`/`Conditional` throw
403 (never mint — and note `mintObjectGrant` enforces this again
independently); on `Allowed`, build the `EnGrant` with `consistencyToken =
checkedAtToken`, `schemaHash = mintEnv.schemaHash`, `audience` and
`requestId` from the request, `revocationId = Nothing` (built-in block ids
are the revocation mechanism; see EP-55), and call
`mintObjectGrantWithExpiry` with expiry `now + requestedOrDefaultTtl`
(`MintConfig.now = liftIO getCurrentTime`). Serialize the response:
`token` from the minted bytes (UTF-8 decode of the base64 `ByteString`),
`revocationIds` hex-encoded (`Auth.Biscuit.Utils.encodeHex'` or equivalent;
from `MintedGrant.revocationIds` if EP-55 landed, else re-parse as per the
Decision Log). Acceptance for M1: a test (extend the existing en-servant or
en-example test arrangement if one exists; otherwise an in-process
`Network.Wai.Test` or en-client round-trip against `app` with the in-memory
stores) proving: `Allowed` request → 200 with a token that
`En.Biscuit.Verify.verifyGrant` accepts for the same
subject/operation/resource/audience and whose recovered `consistencyToken`
equals the response's `checkedAt`; `Denied` request → 403 and no token;
`mint = Nothing` → 404.

Milestone 2 — server configuration and the auth gate. Scope:
`en-server/app/Main.hs`. Read the new env vars: `EN_BISCUIT_ISSUER_SECRET_KEY`
(EP-55 format `"<id>:<64 hex>"`, parsed with `parseSigningKeyText`; bare hex
if EP-55 has not landed), `EN_BISCUIT_DEFAULT_TTL_SECONDS` (default 300),
`EN_BISCUIT_MAX_TTL_SECONDS` (default 3600, must be >= default TTL). If the
key var is unset, `mint = Nothing` and the server logs
`Biscuit grant minting: disabled`. If it is set but malformed, `fail` at
startup with the parse error (never start with a half-configured issuer). If
it is set and valid, build `MintEnv` (the `schemaHash` is `activeSchemaHash`,
already computed at line 43) — and then apply the deployment gate: using the
predicate recorded in M0, if caller authentication (plan 33) is not active,
`fail` at startup with:

```text
EN_BISCUIT_ISSUER_SECRET_KEY is set but caller authentication is not enabled.
A grant-minting endpoint on an unauthenticated server would hand bearer
tokens to anyone. Enable authentication (docs/plans/33) or unset the key.
```

Log `Biscuit grant minting: enabled (key id N, defaultTtl=…s, maxTtl=…s)` on
success — never log the key material. Acceptance for M2: starting the server
with a key but no auth exits non-zero printing the message above; with key
and auth it starts and logs the enabled line; with neither it starts with
minting disabled and `POST /grants` returns 404.

Milestone 3 — downstream verifier binary, end-to-end proof, documentation.
Scope: a small executable so the acceptance does not require writing Haskell
at demo time. Add to `en-biscuit/en-biscuit.cabal` an executable
`en-verify-grant` (`hs-source-dirs: app`, `main-is: VerifyGrant.hs`,
depending on `en-biscuit`, `en-core`, `base`, `bytestring`, `text`,
`containers`, `time`, `biscuit-haskell`). The program reads the serialized
token on stdin; takes `--subject user:alice --operation view --resource
space:project-x --audience document-service --schema-hash <hash>` style
arguments; reads issuer public keys from `EN_BISCUIT_ISSUER_PUBLIC_KEYS`
(EP-55 keyset format, `parseIssuerKeySetText`; a bare hex public key if EP-55
has not landed); calls `verifyGrant` with `now = getCurrentTime` and empty
revocation sets; prints `verified: …` with the recovered grant fields or
`REJECTED: <error>` and exits non-zero. With `--attenuate-resource <t:i>` it
additionally re-parses the token as `Open` (`asOpen`), applies
`attenuateGrant noAttenuation{narrowedResource = …}`, and verifies the
narrowed token twice — once for the narrowed resource (must verify) and once
for the original broader resource (must print the `RestrictionFailed`
rejection) — demonstrating offline attenuation. Then update
`docs/user/biscuit-decision-tokens.md`: a new "Minting over HTTP" section
documenting `POST /grants` (request/response shapes, 403/404/400 behaviors,
the auth requirement) and an explicit statement that the standard header for
presenting a grant to a downstream service is `X-En-Biscuit` (formalizing the
existing Transport section). Acceptance for M3 is the end-to-end transcript
in Validation and Acceptance below.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/en`.
Prerequisite check first (M0):

```bash
cd /Users/shinzui/Keikaku/bokuno/en
grep -n "\- \[x\]" docs/plans/51-return-checked-at-consistency-tokens-from-read-responses.md | head
grep -n "\- \[x\]" docs/plans/33-add-caller-authentication-and-rate-limiting-to-en-server.md | head
```

If either shows no checked items (their state as of 2026-07-07), stop and
mark this plan blocked. During implementation, build and test per milestone:

```bash
cabal build en-servant en-server en-biscuit
cabal test en-biscuit
cabal test all
```

For the end-to-end run, the local stack uses the Justfile (`just --list`
shows recipes; `process-up` starts Postgres via process-compose,
`run-migrations` applies the SQL):

```bash
just process-up
just run-migrations
EN_DATABASE_URL="$PG_CONNECTION_STRING" \
  EN_BISCUIT_ISSUER_SECRET_KEY="1:a2c4ead323536b925f3488ee83e0888b79c2761405ca7c0c9a018c7c1905eecc" \
  <auth env vars from docs/plans/33> \
  cabal run en-server
```

(the hex key above is the deterministic test key from
`en-biscuit/test/Main.hs`; use a freshly generated key outside of demos). In
a second shell, seed a tuple and mint — the demo schema
(`en-server/app/Main.hs`, `demoSchema`) grants `view` on `space` via
`viewer`, exactly as the Justfile smoke test does:

```bash
url="http://localhost:8080"
curl -sS -X POST "$url/tuples" -H 'content-type: application/json' \
  -d '{"tuples":[{"object":{"objectType":"space","objectId":"project-x"},"relation":"viewer","subject":{"tag":"SubjectIdWire","contents":{"objectType":"user","objectId":"alice"}},"caveat":null}]}'
curl -sS -X POST "$url/grants" -H 'content-type: application/json' \
  <auth headers from docs/plans/33> \
  -d '{"consistency":{"tag":"FullyConsistentWire"},"context":{"values":{}},"subject":{"tag":"SubjectIdWire","contents":{"objectType":"user","objectId":"alice"}},"permission":"view","object":{"objectType":"space","objectId":"project-x"},"audience":"document-service","ttlSeconds":300,"requestId":"demo-1"}' \
  | tee /tmp/grant.json
```

Expected response shape (values vary):

```json
{"token":"En0KEwoEZmlsZTEYAyIJ…","expiresAt":"2026-07-07T12:05:00Z","revocationIds":["9f3c…"],"checkedAt":"eyJ4aWQi…"}
```

Then verify and attenuate downstream, with no further server contact:

```bash
jq -r '.token' /tmp/grant.json | \
  EN_BISCUIT_ISSUER_PUBLIC_KEYS="1:$(<public key hex for key 1>)" \
  cabal run en-verify-grant -- \
    --subject user:alice --operation view --resource space:project-x \
    --audience document-service --schema-hash "$(<the hash en-server logged>)" \
    --attenuate-resource space:project-x
```

Expected output:

```text
verified: subject=user:alice operation=view resource=space:project-x expires=2026-07-07T12:05:00Z
attenuated: narrowed request verifies; broader request REJECTED (RestrictionFailed …)
```

Negative checks:

```bash
# Denied: bob has no tuple -> 403, no token
curl -sS -o /dev/null -w '%{http_code}\n' -X POST "$url/grants" -H 'content-type: application/json' \
  <auth headers> \
  -d '{"consistency":{"tag":"FullyConsistentWire"},"context":{"values":{}},"subject":{"tag":"SubjectIdWire","contents":{"objectType":"user","objectId":"bob"}},"permission":"view","object":{"objectType":"space","objectId":"project-x"},"audience":"document-service"}'
# -> 403

# TTL above the max -> 400; minting unconfigured server -> 404 on /grants
```

And the startup gate:

```bash
EN_DATABASE_URL="$PG_CONNECTION_STRING" \
  EN_BISCUIT_ISSUER_SECRET_KEY="1:a2c4…eecc" \
  cabal run en-server   # with auth NOT configured
# -> exits non-zero: "…caller authentication is not enabled…"
```


## Validation and Acceptance

Acceptance is end-to-end observable behavior:

1. With auth configured and a valid issuer key, `POST /grants` for a
   subject/permission/object pair that `POST /check` would answer `Allowed`
   returns HTTP 200 with `token`, `expiresAt` (equal to request time plus the
   requested TTL within clock skew), non-empty `revocationIds`, and a
   `checkedAt` consistency token.
2. The returned token verifies locally: `en-verify-grant` (or
   `verifyGrant` in a test) accepts it for the same subject, operation,
   resource, and audience, before expiry, against the issuer public keyset —
   and the `VerifiedGrant.consistencyToken` equals the response's
   `checkedAt`.
3. The token attenuates offline: narrowing to the resource (or a service)
   yields a token that verifies for the narrowed request and is rejected
   (`RestrictionFailed`) for the broader one — no `en-server` call involved.
4. Fail-closed non-mints: a `Denied` pair returns 403 with a JSON error and
   no token; a `Conditional` decision (caveated schema, missing context)
   returns 403; `ttlSeconds` above the configured max returns 400; a
   `SubjectSetWire`/`SubjectWildcardWire` subject returns 400; a server
   without `EN_BISCUIT_ISSUER_SECRET_KEY` returns 404 on `/grants` while all
   other endpoints work.
5. The startup gate holds: issuer key set + auth off = the server refuses to
   start with the documented message; unauthenticated requests to `/grants`
   on a properly configured server are rejected by the plan-33 auth layer
   before the handler runs.
6. In-process tests covering 1, 2, and 4 run in `cabal test all` so CI pins
   the behavior without a live Postgres where possible (in-memory stores via
   the seam, as `en-biscuit/test/Main.hs` does with
   `En.Conformance.Kikan`).

Success in tests looks like the suites' PASS lines; the live transcript in
Concrete Steps is the human-verifiable proof.


## Idempotence and Recovery

All curl steps are idempotent: tuple writes use `ON CONFLICT DO NOTHING`
semantics at the store level, and each mint issues an independent token —
re-running mints another token, which is normal (tokens are short-lived and
per-request-chain). `just process-up`/`just run-migrations` are re-runnable
(migrations are guarded by `to_regclass` checks). If the server refuses to
start due to the auth gate, either configure auth or unset
`EN_BISCUIT_ISSUER_SECRET_KEY`; there is no state to clean up. If EP-55 lands
mid-implementation, switch the key parsing and mint result handling to its
API in one commit (both variants are described in the Plan of Work; the
response shape does not change). If plan 51's surface differs from what M0
recorded, update M0's record and the handler; the invariant that must never
be violated is: the `consistencyToken` signed into the grant is the token the
decision was actually evaluated at — never a fabricated value, never a token
from a different request.


## Interfaces and Dependencies

Dependencies: `en-servant` gains `en-biscuit` (and transitively
`biscuit-haskell`) in `en-servant/en-servant.cabal`; `en-server` needs no new
direct dependency beyond what `Env` carries; `en-biscuit` gains the
`en-verify-grant` executable stanza. External plan interfaces: plan 51's
checked-at check surface (hard, recorded in M0); plan 33's auth-active
predicate (hard for deployment and the startup gate); EP-55's
`En.Biscuit.Keys.parseSigningKeyText`/`parseIssuerKeySetText`,
`IssuerKeyId`, and `MintedGrant` (soft, with the single-key fallback in the
Decision Log); EP-35's error envelope (soft, wire-style only).

Signatures that must exist at completion:

`En.Servant.Seam` (`en-servant/src/En/Servant/Seam.hs`):

```haskell
data MintEnv   -- issuer key material, key id (if EP-55), defaultTtl, maxTtl, schemaHash
data Env es    -- gains: mint :: !(Maybe MintEnv)
```

`En.Servant.API` (`en-servant/src/En/Servant/API.hs`):

```haskell
data MintGrantRequestWire   -- consistency, context, subject, permission, object, audience, ttlSeconds, requestId
data MintGrantResponseWire  -- token, expiresAt, revocationIds, checkedAt
-- EnAPI gains: "grants" :> ReqBody '[JSON] MintGrantRequestWire :> Post '[JSON] MintGrantResponseWire
mintGrantHandler :: {- same constraint set as checkHandler plus IOE -} Env es -> MintGrantRequestWire -> Handler MintGrantResponseWire
```

`en-biscuit/app/VerifyGrant.hs` — executable `en-verify-grant`: stdin token,
CLI flags for the verify request, `EN_BISCUIT_ISSUER_PUBLIC_KEYS` env,
exit 0 on verified / non-zero on rejection, `--attenuate-resource` for the
offline-narrowing demonstration.

`docs/user/biscuit-decision-tokens.md` — gains the "Minting over HTTP"
section and the formalized `X-En-Biscuit` header convention; this document is
also the Shomei-flow doc owned by `docs/plans/32-…`, so keep its three-layer
framing (Shomei authenticates, en authorizes, Biscuit delegates) intact.
