---
id: 51
slug: return-checked-at-consistency-tokens-from-read-responses
title: "Return checked-at consistency tokens from read responses"
kind: exec-plan
created_at: 2026-07-07T15:25:10Z
master_plan: "docs/masterplans/9-complete-the-en-api-surface.md"
intention: intention_01kx4y4empedt9g83mprcrew89
---

# Return checked-at consistency tokens from read responses

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

en's reads accept a **consistency token** (Zanzibar's "zookie": an opaque text value
naming a datastore snapshot) so a caller can say "answer at least as fresh as this
write". But only *writes* return tokens today — `POST /check`, `POST /batch-check`,
`POST /lookup`, and `POST /expand` return bare results with no indication of the
snapshot they were evaluated at. That breaks token chaining: a caller who checks, then
wants a follow-up lookup to be at least as fresh as that check, has nothing to pass.
It also hard-blocks HTTP Biscuit minting
(`docs/plans/57-mint-biscuit-grants-over-http.md`, master plan 10): an `EnGrant`
requires the `ConsistencyToken` its decision was made at, and the natural source — the
check response — does not supply one. This is gap E3 of
`docs/reviews/2026-07-07-architecture-performance-review.md`, coordinated by
`docs/masterplans/9-complete-the-en-api-surface.md`.

After this change, every read response carries a `checkedAt` field holding a
consistency token minted from the exact revision the read resolved to, encoded
identically to write tokens (same `en1.` codec, same datastore id and schema hash
fields, same expiry convention). A caller can write, check at `AtLeastAsFresh` the
write token, capture the check's `checkedAt`, and issue a lookup at `AtLeastAsFresh`
that token — and the whole chain round-trips. Embedded (in-process) consumers get the
same thing: the core `check`/`checkMany`/`lookup`/`expand` results now carry the
token.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1 (2026-07-09, pre-landed by docs/plans/42): `MintToken` exists on the `ConsistencyStore` effect in `en-core/src/En/Effect/ConsistencyStore.hs` with a `mintToken` smart constructor.
- [x] M1 (2026-07-09, pre-landed by docs/plans/42): `MintToken` is implemented in the PostgreSQL interpreter (`en-postgres/src/En/Postgres/Revision.hs:423`) via `encodeToken`, exactly as this plan specified.
- [x] M1 (2026-07-09, pre-landed by docs/plans/42): `MintToken` is implemented in both in-memory interpreters (`runConsistencyStoreInMemory` and `runConsistencyStoreInMemoryStrict` in `en-core/src/En/Conformance/Kikan.hs`) and in `en-example/src/En/Example/Host.hs`.
- [x] M1 (2026-07-09): Postgres round-trip test added to `en-postgres/integration-test/Main.hs` — resolving `FullyConsistent`, minting its revision, then `decodeToken` + `validateToken` through `runConsistencyStorePostgres` returns the same revision. It goes through the effect rather than the pure `tokenMetadataFromPayload`/`validateTokenMetadata` pair, which exercises the real garbage-collection-window check as well as the codec.
- [x] M2 (2026-07-09): `En.Check.check`/`checkWithBudget`/`checkCached`/`checkCachedWithBudget` return `CheckOutcome`; `checkMany`/`checkManyWithBudget` return `BatchOutcome`. `checkAtRevision*` deliberately unchanged (see Surprises). Internal callers adapted: `en-biscuit/src/En/Biscuit/Mint.hs`, `en-servant/src/En/Servant/Authorize.hs`, `en-example/src/En/Example/Host.hs`.
- [x] M2 (2026-07-09): `checkedAt :: ConsistencyToken` added to `En.Lookup.LookupPage` and `En.Expand.ExpandTree`. Lookup already threaded a token for its cursor, so both `pageLookup` and `interruptedPage` simply record it; expand mints from its resolved revision.
- [x] M2 (2026-07-09): en-core interface and conformance tests updated. New assertions: a check reports `testToken`; a `checkMany` over four pairs reports exactly one token equal to a single check's; a resumed lookup page reports the first page's token; expand reports its snapshot.
- [x] M3 (2026-07-09): `Env.checkOperation` in `en-servant/src/En/Servant/Seam.hs` returns `Eff es CheckOutcome`. `Authorize.requirePermission` and `En.Example.Host.resolveWithGate` project `.decision`. `en-server/app/Main.hs` needed no change, as predicted.
- [x] M3 (2026-07-09): `checkedAt` added to `CheckResponseWire`, `BatchCheckResponseWire`, `LookupPageWire`, `ExpandTreeWire`, and `ReadRelationshipsResponseWire`; handlers, `ToSchema` instances, and `en-servant/test/Main.hs` updated. `CheckResponseWire` and `BatchCheckResponseWire` stopped being newtypes.
- [x] M3 (2026-07-09): `en-client/src/En/Client.hs` needed only recompilation; `chainFrom` added and exported.
- [ ] M4: Run the write → check → lookup chaining transcript against a live server and paste the observed output into Validation and Acceptance.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-07-09: **Milestone 1 was already implemented, by a plan in a different master
  plan.** `docs/plans/42-stream-lookup-pages-with-validated-cursors-and-a-real-deadline.md`
  (master plan 7) landed as commit `b2ab2c5`, "fix(en-core): validate lookup cursors
  instead of obeying them". Closing the forgeable-cursor hole required the datastore to be
  able to *mint* a token for a revision so the cursor could carry one, which is the same
  primitive this plan's M1 exists to add. It landed with exactly the encoding this plan
  specified — `encodeToken TokenPayload{datastoreId, schemaHash, revision, expiresAt = Nothing}`
  — and with a Haddock comment naming `checked_at` as a future consumer:

  ```haskell
  -- en-core/src/En/Effect/ConsistencyStore.hs
  MintToken :: Revision -> ConsistencyStore m ConsistencyToken
  ```

  Interpreters exist in `en-postgres/src/En/Postgres/Revision.hs:423`,
  `en-core/src/En/Conformance/Kikan.hs` (both the permissive and the strict in-memory
  stores), and `en-example/src/En/Example/Host.hs` (both the working and the
  fault-injecting store). Only the Postgres round-trip test M1 asked for is missing.
  M1's three code items are therefore checked off as pre-landed rather than reimplemented.

- 2026-07-09: **The fourth Decision Log entry below is now moot, and its recorded
  concern is closed.** It says a lookup cursor-resume mints a token "from the revision
  decoded out of the cursor", and warns that finding B9 (forgeable cursors) means a forged
  cursor yields a token for a forged revision. EP-42 fixed this: `LookupCursorState` now
  carries a `ConsistencyToken` rather than a raw revision, and `resolveCursor` in
  `en-core/src/En/Lookup.hs` decodes *and validates* it through the datastore before the
  continuation reads at it. A resumed page therefore reuses the cursor's already-validated
  token verbatim, and `checkedAt` on page two is byte-identical to page one's by
  construction rather than by re-derivation. The plan's intent survives; the hazard does not.

- 2026-07-09: **`checkMany` no longer returns `[CheckDecision]`.** This plan's M2 specifies
  `BatchOutcome { decisions :: ![CheckDecision] }`, but master plan 7's engine hardening
  changed the engine to preserve per-pair failures:

  ```haskell
  -- en-core/src/En/Check.hs
  checkMany :: … -> Eff es [Either EnError CheckDecision]
  ```

  `BatchOutcome` therefore carries `decisions :: ![Either EnError CheckDecision]`. The
  `batchCheckHandler` in `en-servant/src/En/Servant/API.hs` still collapses a `Left` to
  `DeniedWire` on the wire, so no observable behavior changes — only the field's type. The
  plan's third Decision Log entry (one token per batch, not one per pair) is unaffected:
  `checkMany` still calls `resolveConsistency` exactly once.

- 2026-07-09: **`checkAtRevision` and its cached variant need no token and must not mint
  one.** They take an already-resolved `Revision` and exist so that a lookup's per-candidate
  confirmations read the snapshot the lookup pinned. Minting there would produce one token
  per confirmed candidate, all equal, all discarded. So the `CheckForCandidate` newtype in
  `en-core/src/En/Lookup.hs` keeps its `Either EnError CheckDecision` payload and no
  projection is needed at the two wrapper sites — contrary to this plan's M2 prose, which
  predates `checkAtRevisionWithBudget` being the thing `CheckForCandidate` wraps directly.

- 2026-07-09: **EP-50 landed first, so `ReadRelationshipsResponseWire` gains `checkedAt`
  here.** Its handler already resolves consistency and holds the revision, so the field
  costs one `mintToken` call and no extra store round trip (`MintToken` is a pure encode in
  every interpreter — `pure (encodeToken …)`, no database session).


## Decision Log

Record every decision made while working on the plan.

- Decision: Mint read tokens through a new `ConsistencyStore` effect operation `MintToken :: Revision -> ConsistencyStore m ConsistencyToken`, rather than encoding tokens in en-core or in the HTTP layer.
  Rationale: Token encoding is datastore-specific — the PostgreSQL codec (`encodeToken` in `en-postgres/src/En/Postgres/Revision.hs`) embeds the datastore id, schema hash, and a `pg_snapshot` revision, none of which en-core knows. The `ConsistencyStore` effect already owns decoding and validation (`DecodeToken`, `ValidateToken`); minting is the missing inverse and belongs behind the same boundary, so embedded, hosted, and test consumers all get correctly minted tokens from one code path.
  Date: 2026-07-07
- Decision: Read tokens are minted exactly like write tokens: `encodeToken TokenPayload{datastoreId = config.datastoreId, schemaHash = config.schemaHash, revision, expiresAt = Nothing}`.
  Rationale: Verified in source — write tokens (`tokenFromAnchor` in `en-postgres/src/En/Postgres/TupleStore.hs`) carry `expiresAt = Nothing`; expiry is enforced at validation time only when present, and staleness is separately bounded by the GC-window check in `validateTokenMetadata` (`en-postgres/src/En/Postgres/Revision.hs`). Giving read tokens a different expiry convention than write tokens would create two token classes with different lifetimes for no benefit; the GC horizon already bounds both.
  Date: 2026-07-07
- Decision: A batch check returns exactly one `checkedAt` token for the whole batch, not one per pair.
  Rationale: Verified in `en-core/src/En/Check.hs`: `checkMany` calls `resolveConsistency` once and evaluates every pair against that single resolved revision, so per-pair tokens would all encode the same snapshot. One token states that fact honestly and keeps the response small.
  Date: 2026-07-07
- Decision: On lookup's cursor-resume path (a request carrying a `cursor`), the token is minted from the revision decoded out of the cursor, without re-resolving consistency.
  Rationale: That *is* the revision the page was evaluated at (`lookupWithDeadlineWithChecker` in `en-core/src/En/Lookup.hs` takes the revision from the cursor so pages of one traversal share a snapshot); minting anything else would misreport. The review's B9 finding — lookup cursors are client-forgeable and unvalidated — means a forged cursor yields a token for a forged revision; that token is still subject to datastore/schema/GC validation when later *used*, and closing the forgeability hole itself is owned by `docs/plans/42-stream-lookup-pages-with-validated-cursors-and-a-real-deadline.md` (master plan 7). Recorded so EP-42 knows this consumer exists.
  Date: 2026-07-07
- Decision: Change the core return types in place (`check` returns `CheckOutcome`, `checkMany` returns `BatchOutcome`, `LookupPage`/`ExpandTree` gain a field) rather than adding parallel `*WithToken` variants.
  Rationale: The project is pre-1.0 and en-core's callers are all in this repository; a parallel API would double the surface and let new code keep using token-less reads, defeating the point. The compiler enumerates every call site to fix.
  Date: 2026-07-07
- Decision: `checkMany`'s per-pair fail-closed behavior (errors become `Denied`, review B5) is left untouched; only the return shape changes.
  Rationale: Reworking batch error semantics is engine-hardening work owned by master plan 7. This plan changes what reads *return*, not how they evaluate.
  Date: 2026-07-07
- Decision: `BatchOutcome.decisions` has type `[Either EnError CheckDecision]`, not the `[CheckDecision]` this plan's Milestone 2 wrote.
  Rationale: Master plan 7's engine hardening already changed `checkMany` to preserve per-pair failures, and this plan's own decision above says not to rework that. Carrying the `Either` through is the shape-only change the decision above promises. The wire is unchanged: `batchCheckHandler` still collapses a `Left` to `DeniedWire`.
  Date: 2026-07-09
- Decision: `checkAtRevision` and `checkCachedAtRevision` keep returning a bare `Either EnError CheckDecision` and mint nothing.
  Rationale: They take an already-resolved `Revision` — the whole reason they exist is that a lookup's per-candidate confirmations must read the snapshot the lookup pinned rather than re-resolving. Minting inside them would produce one identical token per confirmed candidate, all discarded. `En.Lookup.CheckForCandidate` wraps them directly, so no projection is needed there either.
  Date: 2026-07-09
- Decision: `ReadRelationshipsResponseWire` (EP-50's relationship-query response) gains `checkedAt` in this plan's M3, as this plan's Interfaces section directs.
  Rationale: EP-50 landed first and deliberately omitted the field pending this plan. Its handler already calls `resolveConsistency` and holds the revision, so the field costs one `mintToken` and no extra store round trip — `MintToken` is `pure (encodeToken …)` in every interpreter, never a database session.
  Date: 2026-07-09
- Decision: `mintCheckedObjectGrant` in `en-biscuit/src/En/Biscuit/Mint.hs` is adapted to the new `CheckOutcome` by projecting `.decision`, and is *not* changed to stamp the grant with `outcome.checkedAt`.
  Rationale: That function currently mints an `EnGrant` carrying the caller-supplied `grant.consistencyToken`, which need not be the snapshot the decision it just made was made at — precisely the defect this plan's Purpose describes. Fixing it is a behavior change to an authorization-token library, and `docs/plans/57-mint-biscuit-grants-over-http.md` (master plan 10) hard-depends on this plan for exactly that purpose. Silently re-stamping a security token's snapshot from inside a plan scoped to "what reads return" would be the wrong place to make that call. A comment at the call site records it for EP-57.
  Date: 2026-07-09
- Decision: en-core and en-servant land in one commit rather than one per milestone.
  Rationale: Changing `check`'s return type breaks every downstream package at compile time. A commit containing only M2 would not build, violating the requirement that each commit leave the codebase in a working state.
  Date: 2026-07-09


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

The repository root is `/Users/shinzui/Keikaku/bokuno/en` (Haskell, GHC 9.12.4,
`cabal`). Packages touched: `en-core` (engine and effect interfaces), `en-postgres`
(PostgreSQL interpreters), `en-servant` (HTTP API), `en-server` (executable),
`en-client` (typed client). This plan fixes gap E3 of
`docs/reviews/2026-07-07-architecture-performance-review.md` under
`docs/masterplans/9-complete-the-en-api-surface.md`.

Consistency machinery, as it exists today. A **revision** (`En.Revision.Revision`,
`en-core/src/En/Revision.hs`) is an opaque snapshot identifier; for PostgreSQL it wraps
a rendered `pg_snapshot` (`xmin:xmax:xip`). A **consistency token**
(`ConsistencyToken`) is the caller-visible form: the PostgreSQL codec in
`en-postgres/src/En/Postgres/Revision.hs` encodes `en1.<datastoreId>.<schemaHash>.
<revision>.<expiresAt?>` (percent-escaped fields; see `encodeToken`/`decodeToken`).
Validation (`validateTokenMetadata`) rejects tokens from another datastore, another
schema hash, expired tokens, and tokens older than the garbage-collection window.

Every read starts by resolving the caller's requested `Consistency`
(`MinimizeLatency` / `FullyConsistent` / `AtLeastAsFresh token` /
`AtExactSnapshot token`) into a concrete revision via the `ConsistencyStore` effect
(`en-core/src/En/Effect/ConsistencyStore.hs`): `resolveConsistency` returns
`ResolvedConsistency { consistency, revision }`. The PostgreSQL interpreter is
`runConsistencyStorePostgres` in `en-postgres/src/En/Postgres/Revision.hs`; the
in-memory test interpreter is `runConsistencyStoreInMemory` in
`en-core/src/En/Conformance/Kikan.hs`.

Where the resolved revision currently dies, by call site:

- `En.Check.check` (`en-core/src/En/Check.hs`): resolves, evaluates, returns only
  `CheckDecision`.
- `En.Check.checkMany`: resolves **once** for the whole batch, evaluates every pair at
  that revision, returns `[CheckDecision]`.
- `En.Lookup.lookupWithDeadlineWithChecker` (`en-core/src/En/Lookup.hs`): with no
  cursor, resolves and evaluates; with a cursor, takes the revision from the decoded
  cursor (`LookupCursorState.revision`) so later pages stay on the first page's
  snapshot. Returns `LookupPage { objects, state }`.
- `En.Expand.expand` (`en-core/src/En/Expand.hs`): resolves, evaluates, returns
  `ExpandTree { root, permission, children, state }`.

There is no minting operation on the effect; `encodeToken` is only called by the write
path (`tokenFromAnchor` in `en-postgres/src/En/Postgres/TupleStore.hs`).

The HTTP layer: `en-servant/src/En/Servant/API.hs` holds the wire DTOs
(`CheckResponseWire` is decision-only; `BatchCheckResponseWire` is a bare decision
list; `LookupPageWire` and `ExpandTreeWire` have no token field) and the handlers.
Handlers reach the engine through `Env es` (`en-servant/src/En/Servant/Seam.hs`),
whose `checkOperation` and `lookupWithDeadlineOperation` fields are function values
constructed in `en-server/app/Main.hs` (choosing cached or uncached engine variants).
`en-servant/src/En/Servant/Authorize.hs` contains the `requirePermission` helper that
also consumes a check — read it and adapt its use of the decision (it only needs the
decision; project the field). `en-client/src/En/Client.hs` derives its client record
from the API type, so response-shape changes flow through automatically.

Downstream dependency, restated so this plan stands alone:
`docs/plans/57-mint-biscuit-grants-over-http.md` (master plan 10) hard-depends on this
plan — an `EnGrant` (see `en-biscuit`) requires the `ConsistencyToken` of the decision
it wraps, and the HTTP minting flow gets it from the check response's `checkedAt`.
Sibling plans in master plan 9 (`docs/plans/50`, `52`, `53`) must include the same
`checkedAt` field in their new read-response DTOs from day one; this plan owns the
convention and reconciles any that landed first.

External sequencing restated from the master plan: prefer landing
`docs/plans/35-version-the-wire-contract-and-type-the-error-model.md` (master plan 6:
versioned wire contract, typed error envelope) before this plan, so the added fields
are born inside the versioned contract. The JSON in this plan shows the current
unversioned shapes; adjust if EP-35 has landed.


## Plan of Work

Three code milestones (minting primitive; core result types; wire and server), then an
end-to-end demonstration. Each leaves `cabal build all` and existing tests green.


### Milestone 1: the MintToken operation

Scope: after this milestone, any code holding a resolved `Revision` can obtain the
canonical token for it through the `ConsistencyStore` effect, in both the PostgreSQL
and in-memory interpreters, and a test proves mint-then-validate round-trips.

In `en-core/src/En/Effect/ConsistencyStore.hs`, add a constructor and smart
constructor, and export both:

```haskell
data ConsistencyStore :: Effect where
    DecodeToken :: ConsistencyToken -> ConsistencyStore m TokenMetadata
    ValidateToken :: TokenMetadata -> ConsistencyStore m ()
    ResolveConsistency :: Consistency -> ConsistencyStore m ResolvedConsistency
    MintToken :: Revision -> ConsistencyStore m ConsistencyToken

mintToken :: (ConsistencyStore :> es) => Revision -> Eff es ConsistencyToken
mintToken =
    send . MintToken
```

In `en-postgres/src/En/Postgres/Revision.hs`, extend `runConsistencyStorePostgres`'s
`interpret_` with:

```haskell
        MintToken revision ->
            pure
                ( encodeToken
                    TokenPayload
                        { datastoreId = config.datastoreId
                        , schemaHash = config.schemaHash
                        , revision
                        , expiresAt = Nothing
                        }
                )
```

This is byte-for-byte the write-token construction (`tokenFromAnchor`) applied to a
read revision — same codec, same datastore id and schema hash, same `Nothing` expiry.
In `en-core/src/En/Conformance/Kikan.hs`, extend `runConsistencyStoreInMemory` with
`MintToken revision -> pure (ConsistencyToken ("in-memory:" <> revision.revisionEncoding))`
(deterministic, so tests can assert on it; the in-memory `DecodeToken` is already a
stub and need not decode this shape).

Add a round-trip test where the Postgres interpreters run (the
`en-postgres-revision-tests` suite in `en-postgres/test/Main.hs` for the pure codec
part, and/or `en-postgres/integration-test/Main.hs` for the effectful part): resolving
`FullyConsistent` and minting its revision produces a token that
`tokenMetadataFromPayload` decodes and `validateTokenMetadata` accepts under the same
`ConsistencyConfig`.

Acceptance: `cabal build all`, `cabal test en-postgres-revision-tests` (and the
integration suite if extended) pass.


### Milestone 2: core results carry the token

Scope: after this milestone the four read algorithms in en-core return their
checked-at token, and core tests prove it.

In `en-core/src/En/Check.hs`, define and export:

```haskell
data CheckOutcome = CheckOutcome
    { decision :: !CheckDecision
    , checkedAt :: !ConsistencyToken
    }
    deriving stock (Eq, Show)

data BatchOutcome = BatchOutcome
    { decisions :: ![CheckDecision]
    , checkedAt :: !ConsistencyToken
    }
    deriving stock (Eq, Show)
```

`check` and `checkCached` become `... -> Eff es CheckOutcome`: after
`resolveConsistency`, call `mintToken revision` and pair it with the decision.
`checkMany` becomes `... -> Eff es BatchOutcome`: it already resolves once for the
whole batch; mint once. Note `checkMany`'s constraint list has no `Error EnError`
today and `MintToken` introduces no failure, so the signature otherwise stands.

In `en-core/src/En/Lookup.hs`, add `checkedAt :: !ConsistencyToken` to `LookupPage`.
In `lookupWithDeadlineWithChecker`, mint from whichever revision the page is evaluated
at: the freshly resolved one on the first page, or the cursor-decoded one on resume
(see Decision Log). Pass the token down into `pageLookup` (or mint beside its call)
so the constructed page carries it. The internal `CheckForCandidate` checker used by
`confirmCandidates` still needs a bare decision; adapt it by projecting `.decision`
from `CheckOutcome` at the two wrapper sites (`lookupWithDeadline` wrapping `check`,
`lookupWithDeadlineCached` wrapping `checkCached`) so confirmation logic is unchanged
and no extra tokens are minted per candidate.

In `en-core/src/En/Expand.hs`, add `checkedAt :: !ConsistencyToken` to `ExpandTree`;
`expand` mints from its resolved revision and stores it in the constructed tree.

Update the en-core test suites (`en-core/test/Main.hs`,
`en-core/conformance/Main.hs`) for the new shapes. Add assertions that: a check run
under the in-memory interpreters yields
`checkedAt = ConsistencyToken "in-memory:test-revision"`; a `checkMany` over several
pairs yields exactly one token equal to a single check's token at the same
consistency; lookup's second page (cursor resume) yields the same `checkedAt` as the
first page.

Acceptance: `cabal build en-core && cabal test en-core` passes (both suites).


### Milestone 3: wire DTOs, seam, server, client

Scope: after this milestone every HTTP read response carries `checkedAt` and the
typed client exposes it.

In `en-servant/src/En/Servant/Seam.hs`, update the `Env` field types:
`checkOperation` returns `Eff es CheckOutcome`; `lookupWithDeadlineOperation` already
returns `Lookup.LookupPage`, which now carries the token — no shape change beyond
recompilation. In `en-server/app/Main.hs` the `checkOperation` /
`lookupWithDeadlineOperation` definitions recompile against the new engine types
unchanged in structure. Read `en-servant/src/En/Servant/Authorize.hs` and project
`.decision` where it consumes a check result.

In `en-servant/src/En/Servant/API.hs`:

```haskell
data CheckResponseWire = CheckResponseWire
    { decision :: !CheckDecisionWire
    , checkedAt :: !Text
    }

data BatchCheckResponseWire = BatchCheckResponseWire
    { decisions :: ![CheckDecisionWire]
    , checkedAt :: !Text
    }
```

(`CheckResponseWire` stops being a `newtype`.) Add `checkedAt :: !Text` to
`LookupPageWire` and `ExpandTreeWire`; extend `lookupPageToWire` and
`expandTreeToWire` to copy the token's text (unwrap `ConsistencyToken`). Handlers:
`checkHandler` and `batchCheckHandler` project decision(s) and token from
`CheckOutcome`/`BatchOutcome`; `lookupHandler`/`expandHandler` need only the
conversion updates. Extend `en-servant/test/Main.hs`: every read handler's response
now contains a non-empty `checkedAt`, and — the chaining property — a handler-level
check followed by a lookup at `AtLeastAsFreshWire` of the returned token succeeds
under the in-memory interpreters (whose `DecodeToken`/`ValidateToken` accept any
token).

`en-client/src/En/Client.hs` re-exports the wire types, so `EnClient` callers see
`checkedAt` after recompilation. Add one convenience so chaining is one expression:

```haskell
-- | Chain a follow-up read at least as fresh as a previous response's token.
chainFrom :: Text -> ConsistencyWire
chainFrom = AtLeastAsFreshWire
```

Acceptance: `cabal build all && cabal test en-servant` passes.


### Milestone 4: end-to-end chaining demonstration

Scope: run the write → check → lookup chain against a live server (commands below) and
record the transcript in Validation and Acceptance. This proves the headline behavior
that master plan 9's Progress line and `docs/plans/57` both need.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/en` inside the dev shell (direnv
provides `cabal`, `just`, `psql`, `process-compose`, and `EN_DATABASE_URL`).

Build and test without a database:

```bash
cabal build all
cabal test en-core
cabal test en-servant
cabal test en-postgres-revision-tests
```

Integration tests (throwaway PostgreSQL via ephemeral-pg; dev shell only):

```bash
cabal test en-postgres-integration-tests
```

Start the dev PostgreSQL and server (the Justfile: `process-up` starts PostgreSQL via
process-compose and waits for readiness; `start-server` applies migrations with `psql`
then runs `cabal run en-server`):

```bash
just process-up
just start-server
```

Then run the transcript in Validation and Acceptance. Afterwards:

```bash
just process-down
```

The repository's existing smoke test (`just test-server`, with the server already
running) must still pass — it asserts on `.decision.tag`, which this plan preserves.


## Validation and Acceptance

The acceptance scenario is token chaining across a write, a check, and a lookup,
using the built-in demo schema (`user`, `space#viewer`, permission `view`; served when
`EN_SCHEMA_PATH` is unset — see `en-server/app/Main.hs`).

Step 1 — write a grant and capture the write token:

```bash
WRITE_TOKEN=$(curl -sS -X POST localhost:8080/tuples -H 'content-type: application/json' -d '{
  "tuples": [{
    "object": {"objectType": "space", "objectId": "project-x"},
    "relation": "viewer",
    "subject": {"tag": "SubjectIdWire", "contents": {"objectType": "user", "objectId": "alice"}},
    "caveat": null
  }]
}' | jq -r '.token')
```

Step 2 — check at least as fresh as the write; capture `checkedAt`:

```bash
curl -sS -X POST localhost:8080/check -H 'content-type: application/json' -d "{
  \"consistency\": {\"tag\": \"AtLeastAsFreshWire\", \"contents\": \"$WRITE_TOKEN\"},
  \"context\": {\"values\": {}},
  \"subject\": {\"tag\": \"SubjectIdWire\", \"contents\": {\"objectType\": \"user\", \"objectId\": \"alice\"}},
  \"permission\": \"view\",
  \"object\": {\"objectType\": \"space\", \"objectId\": \"project-x\"}
}"
```

Expected shape:

```json
{"decision": {"tag": "AllowedWire"}, "checkedAt": "en1.…"}
```

Step 3 — lookup at least as fresh as the check's token; the chain round-trips:

```bash
CHECKED_AT=<the checkedAt value from step 2>
curl -sS -X POST localhost:8080/lookup -H 'content-type: application/json' -d "{
  \"consistency\": {\"tag\": \"AtLeastAsFreshWire\", \"contents\": \"$CHECKED_AT\"},
  \"subject\": {\"tag\": \"SubjectIdWire\", \"contents\": {\"objectType\": \"user\", \"objectId\": \"alice\"}},
  \"permission\": \"view\",
  \"objectType\": \"space\",
  \"context\": {\"values\": {}},
  \"limit\": 10,
  \"cursor\": null,
  \"deadlineMillis\": null
}"
```

Expected: HTTP 200 with `space:project-x` in `objects`, a `state` of
`LookupExhaustedWire`, and the page's own `checkedAt` present. A negative control:
tamper with one character of `CHECKED_AT` inside the revision field and the lookup
must fail with the invalid-token error (HTTP 500 under today's collapsed error model —
review A3; a typed 4xx once `docs/plans/35` lands).

Batch semantics: `POST /batch-check` with two pairs returns
`{"decisions": [...], "checkedAt": "en1.…"}` — one token, per the Decision Log.

Test-level validation: the M1 mint/validate round-trip test, the M2 core assertions
(single batch token; cursor-resume page reuses the first page's token), and the M3
handler tests all pass under `cabal test en-core`, `cabal test en-servant`,
`cabal test en-postgres-revision-tests`.


## Idempotence and Recovery

Every step is additive and repeatable: minting a token is a pure encoding of an
existing revision (no database write — verify no `en_transaction` row count change
across a read in the integration test if in doubt), so repeated reads mint equal or
newer tokens and never mutate state. The type changes are compiler-enforced; if a
milestone is interrupted mid-refactor, `cabal build all` lists exactly the remaining
call sites. There is no migration and no data risk. If a wire consumer outside this
repository cannot tolerate the added response fields (added fields are
backward-compatible for tolerant JSON readers; the project's own generic decoders
require them only on *requests*), coordinate through
`docs/plans/35-version-the-wire-contract-and-type-the-error-model.md`'s versioning
rather than reverting.


## Interfaces and Dependencies

End-state interfaces, by full module path:

- `En.Effect.ConsistencyStore` (`en-core/src/En/Effect/ConsistencyStore.hs`):
  constructor `MintToken :: Revision -> ConsistencyStore m ConsistencyToken`;
  `mintToken :: (ConsistencyStore :> es) => Revision -> Eff es ConsistencyToken`.
- `En.Postgres.Revision` (`en-postgres/src/En/Postgres/Revision.hs`):
  `runConsistencyStorePostgres` handles `MintToken` via `encodeToken` with the
  interpreter's `ConsistencyConfig` (datastore id, schema hash) and
  `expiresAt = Nothing`.
- `En.Conformance.Kikan` (`en-core/src/En/Conformance/Kikan.hs`):
  `runConsistencyStoreInMemory` handles `MintToken` deterministically.
- `En.Check` (`en-core/src/En/Check.hs`): `CheckOutcome { decision, checkedAt }`,
  `BatchOutcome { decisions, checkedAt }`;
  `check, checkCached :: … -> Eff es CheckOutcome`;
  `checkMany :: … -> Eff es BatchOutcome`.
- `En.Lookup` (`en-core/src/En/Lookup.hs`): `LookupPage` gains
  `checkedAt :: ConsistencyToken`.
- `En.Expand` (`en-core/src/En/Expand.hs`): `ExpandTree` gains
  `checkedAt :: ConsistencyToken`.
- `En.Servant.Seam` (`en-servant/src/En/Servant/Seam.hs`): `Env.checkOperation`
  returns `Eff es CheckOutcome`.
- `En.Servant.API` (`en-servant/src/En/Servant/API.hs`): `CheckResponseWire`,
  `BatchCheckResponseWire`, `LookupPageWire`, `ExpandTreeWire` each carry
  `checkedAt :: Text`.
- `En.Client` (`en-client/src/En/Client.hs`): `chainFrom :: Text -> ConsistencyWire`.

Dependencies and coordination, restated so this plan stands alone: no hard
dependencies; prefer landing after
`docs/plans/35-version-the-wire-contract-and-type-the-error-model.md` (versioned wire
contract — see Context and Orientation).
`docs/plans/57-mint-biscuit-grants-over-http.md` (master plan 10) hard-depends on this
plan's `checkedAt` on the check response. Per
`docs/masterplans/9-complete-the-en-api-surface.md`, this plan owns the checked-at
convention: `docs/plans/52-add-a-lookup-subjects-api.md` and
`docs/plans/53-add-a-watch-changelog-api.md` include the same field in their new read
DTOs from day one (if either landed first with the field, reconcile encodings here
and record it in both Decision Logs), and
`docs/plans/50-expose-relationship-read-and-delete-by-filter-endpoints.md`'s
relationship-query response deliberately omits the field until this plan adds it (per
EP-50's Decision Log) — if EP-50 has already landed, extend
`ReadRelationshipsResponseWire` with `checkedAt` during M3 here. No new package
dependencies are required.
