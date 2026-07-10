---
id: 60
slug: correct-the-consistency-token-validation-boundary-and-its-error-surface
title: "Correct the consistency-token validation boundary and its error surface"
kind: exec-plan
created_at: 2026-07-10T14:20:01Z
intention: "intention_01kx66cfysevaa1eemmstdh518"
---

# Correct the consistency-token validation boundary and its error surface

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

A consistency token is en's promise that a client can name a snapshot and read at it again.
Today that promise breaks in two directions at once, and both were found while implementing
`docs/plans/53-add-a-watch-changelog-api.md`.

**It rejects tokens it should accept.** On an en whose store has seen no writes for longer
than `EN_GC_WINDOW`, a token minted from the current head revision is refused the instant it
is spent — with no writes in between, and no history reaped. Against a live server this takes
two calls to reproduce (transcript in Validation and Acceptance). Every read response carries
such a token as `checkedAt`, and `En.Client.chainFrom` exists to feed it straight back, so the
API's headline "read your own reads" idiom fails on a quiet deployment.

**It accepts tokens it should reject.** The same check passes a snapshot under which a row
that the reaper has already physically deleted is still live. A read at that token silently
reports a grant as absent that the token's snapshot says is present — the exact class of
answer the garbage-collection check exists to prevent.

Both follow from one line: `validateTokenMetadata` asks `snapshot.xmax <= oldestRetainedXid`,
which is neither necessary nor sufficient for the question it means to ask. That question is
*"can every row the reaper may already have destroyed be proven absent from this snapshot's
live set?"* — and it has an exact, cheap answer.

Separately, when a token cannot even be decoded, en puts the name of an internal Haskell
constructor on the wire: `{"code":"invalid_consistency_token","message":"TokenBadFieldCount"}`.
The `/v1` contract (`docs/plans/35-version-the-wire-contract-and-type-the-error-model.md`)
exists precisely to keep constructor names off the wire, and this is the one place still
leaking them. `docs/plans/52` and `docs/plans/53` both recorded it and declined to fix it,
because fixing it means designing the failure taxonomy rather than renaming a string.

After this change: a token minted from any revision, at any time, validates for as long as the
history it names survives, and not one transaction longer; the rule is one shared predicate
proved against PostgreSQL's own `pg_visible_in_snapshot` oracle rather than two hand-tuned
comparisons that disagree; and a malformed token is refused with a stable machine-readable
code and a message written for a human.

A third, smaller item rides along because `docs/plans/53` measured it and could not price it:
the watch feed's window query sorts rather than seeks, so draining a wide window re-scans it
once per page. This plan quantifies that cost and then decides — including deciding to leave
it alone and write the number down.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: Add `retainedHistoryVisible :: Word64 -> PgSnapshot -> Bool` to `en-postgres/src/En/Postgres/Revision.hs`, with the derivation in its Haddock.
- [ ] M1: Prove it against the PostgreSQL oracle in `en-postgres/integration-test/Main.hs`: for generated (snapshot, horizon) pairs, the predicate agrees with "every transaction below the horizon is visible", asked of the database itself.
- [ ] M1: Rewrite `validateTokenMetadata`'s garbage-collection clause to use it. Update the unit expectations in `en-postgres/test/Main.hs`.
- [ ] M1: Rewrite `validateWatchCursor` in `en-postgres/src/En/Postgres/Watch.hs` to use the same predicate, replacing the conservative `snapshot.xmin < oldestRetainedXid` special case `docs/plans/53` derived.
- [ ] M1: Investigate whether `oldestRetainedXid` is genuinely non-decreasing. Every horizon rule's soundness rests on it, including today's. Record the finding whichever way it falls; if it is not, say so loudly and scope the fix.
- [ ] M1: Regression test the reported bug end to end: a token minted from a head revision, on a store with no writes inside the garbage-collection window, is accepted.
- [ ] M2: Decide the token-decode failure taxonomy and its wire codes (see Decision Log for the opening proposal).
- [ ] M2: Replace `Text.pack (show err)` in `tokenMetadataFromPayload` with a rendering written for a client. Fix `parseExpiry`'s misuse of `TokenBadEscape` while there.
- [ ] M2: Reconcile malformed-cursor errors. `En.Lookup` and `En.LookupSubjects` raise `InvalidConsistencyToken "lookup cursor"`; `En.Postgres.Watch` raises `InvalidCursor`. One of them is wrong.
- [ ] M2: Update `en-servant/test/Main.hs`'s error-model table and the assertion in `en-postgres/integration-test/Main.hs` that currently pins the leak (`InvalidConsistencyToken "TokenBadPrefix"`).
- [ ] M3: Benchmark the watch drain against a populated table: cost per page as a function of window width and page size.
- [ ] M3: Decide from the numbers — rewrite the window query, or record the cost and close the item. Both are acceptable outcomes; shipping an unmeasured rewrite is not.
- [ ] Update `docs/plans/53`'s Surprises entry and `docs/masterplans/9-complete-the-en-api-surface.md`'s Decision Log to point at this plan's outcome.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-07-10 (pre-implementation, reproduced live): the "rejects what it should accept" half is
  not a corner case reachable only by a fresh database. It fires whenever `en_transaction` holds
  no row inside `EN_GC_WINDOW`, because `oldestRetainedXidStatement` then falls back to
  `pg_snapshot_xmin(pg_current_snapshot())` — which for an idle store equals the head snapshot's
  `xmax`. A `checkedAt` token minted milliseconds earlier is refused. See Validation and
  Acceptance for the two-call transcript.

- 2026-07-10 (pre-implementation): write tokens are immune and read tokens are not, which is why
  this survived. `En.Postgres.TupleStore.writeVisibleSnapshot` raises a write token's `xmax` past
  the writing transaction's own xid so the token can see its own write. That raise happens to lift
  `xmax` above the horizon too. Nothing raises a head revision's `xmax`, so `checkedAt` — added by
  `docs/plans/51` to *every* read response — has no such protection. The bug was introduced by a
  plan that added a token where none had been, not by the check itself.


## Decision Log

Record every decision made while working on the plan.

- Decision: The garbage-collection check is `retainedHistoryVisible horizon snapshot`, defined as
  "every transaction id below `horizon` is visible in `snapshot`", and spelled
  `horizon <= snapshot.xmax && all (\t -> t < snapshot.xmin || t >= horizon) snapshot.xip`.
  Rationale: This is the exact condition, derived rather than tuned. The reaper physically deletes
  a row only when `deleted_xid < horizon` (`reapDeletedTuplesStatement`). Such a row is dangerous
  to a reader at snapshot `S` only if it is still *live* at `S` — that is, if its deletion is
  **not** visible in `S`. If every transaction below the horizon is visible in `S`, then every
  reaped row's deletion is visible in `S`, so no reaped row is live at `S`, so `S` can be served
  exactly from the surviving rows. (Its creation is older than its deletion, so it is visible too;
  a reaped row therefore contributes nothing at `S` in either direction.) Conversely if some
  `t < horizon` is invisible in `S`, a row deleted at `t` is live at `S` and may already be gone,
  so `S` must be refused. The two-clause spelling is that statement with the enumeration removed:
  `t >= xmax` is invisible, so `horizon <= xmax`; and among `xmin <= t < xmax` the invisible ones
  are exactly `xip`.
  Date: 2026-07-10
- Decision: The existing rule, `snapshot.xmax <= horizon` ⇒ reject, is replaced rather than
  loosened, because it errs in both directions.
  Rationale: It rejects `27807:27807:` at horizon `27807` (the live bug: `xmax == horizon`, yet
  every transaction below `27807` is visible, so nothing reaped is live). It accepts
  `849:851:849` at horizon `850` (`xmax > horizon`, yet `849` is in-flight and therefore invisible,
  so a row deleted at `849` is live at the snapshot and reapable — the reader would be served a
  snapshot missing a grant it should see). No adjustment of the comparison or its strictness
  produces both answers; only asking the right question does.
  Date: 2026-07-10
- Decision: `En.Postgres.Watch.validateWatchCursor` adopts the same predicate, retiring the
  `snapshot.xmin < oldestRetainedXid` rule `docs/plans/53` derived for it.
  Rationale: That rule is sound — `horizon <= xmin` implies the predicate — but strictly
  conservative, and it exists only because the token rule could not be reused. Once the token rule
  is correct, a watch window and a read token are asking the identical question of the identical
  horizon, and should not answer it with two functions. `docs/plans/53`'s Decision Log entry
  claiming the two must diverge on the horizon is superseded by this one; its entry on the
  *schema hash* divergence is not, and stays.
  Date: 2026-07-10
- Decision: Whether `oldestRetainedXid` is non-decreasing is an open question this plan must
  answer before it can claim the new rule is safe.
  Rationale: Every horizon rule — the current one included — is sound only if the horizon never
  moves backwards. Reaping at time `T1` destroys rows below `H(T1)`; validation at `T2 > T1`
  reasons about `H(T2)`, and the argument above needs `H(T1) <= H(T2)`.
  `oldestRetainedXidStatement` computes `coalesce(min(xid), pg_snapshot_xmin(pg_current_snapshot()))`
  over `en_transaction` rows inside the window. The `min(xid)` branch rises as rows age out. The
  `coalesce` fallback need not: a long-running open write transaction pins `pg_snapshot_xmin` low,
  so a store whose `en_transaction` rows all age out could see the horizon drop from `min(xid)` to
  that pinned value. The Haddock in `En.Postgres.Revision` already *asserts* monotonicity ("the
  horizon rises monotonically as transactions age out of the window") without proving it. If the
  assertion is false, the fix belongs here, because this plan is the one that leans on it.
  Date: 2026-07-10
- Decision (opening proposal, to be confirmed in M2): token failures split into three stable wire
  codes rather than the one they share today — `malformed_consistency_token` (the token is not a
  token: bad prefix, field count, escape, or unparseable snapshot), `consistency_token_expired`
  (well-formed, but its history is gone or its `expiresAt` has passed), and
  `invalid_consistency_token` retained for the rest (wrong datastore, wrong schema hash).
  Rationale: These are three different things for a client to do — fix the bug, re-read and retry,
  reconfigure — and today they are indistinguishable without parsing prose. `docs/plans/35` froze
  the *envelope*, not the set of codes; adding a code is additive for a client that switches on
  the codes it knows. `docs/plans/53` already draws exactly this line for watch cursors
  (`invalid_cursor` for malformed, `invalid_consistency_token` for expired), so the taxonomy is
  half-built already and merely inconsistent.
  Date: 2026-07-10
- Decision: M3's acceptable outcomes include "measured, documented, not changed".
  Rationale: `docs/plans/53` recorded the drain's re-scan as a bounded cost and declined to price
  it. A rewrite to `UNION` arms with per-arm keyset seeks is not obviously available — neither xid
  index carries `id`, so a composite `(created_xid, id)` still cannot yield `id` order across a
  `created_xid` range — and a rewrite adopted without a number is how a plan trades a known cost
  for an unknown one. The milestone's deliverable is the number.
  Date: 2026-07-10


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

The repository root is `/Users/shinzui/Keikaku/bokuno/en` (Haskell, GHC 9.12.4, `cabal`).
Packages touched: `en-postgres` (the rule and the codec), `en-core` (the `EnError` sum, if M2's
taxonomy adds a constructor), `en-servant` (the error-model table). No migration, no wire-shape
change to any request or response body.

**How en names a snapshot.** PostgreSQL identifies every transaction with a 64-bit `xid8`. A
*snapshot* is rendered `xmin:xmax:xip` — `xmin` is the oldest still-running transaction id,
`xmax` is one past the newest assigned id, and `xip` lists the ids in between that were still in
flight. A transaction `t` is *visible* in snapshot `S` when `t < S.xmin`, or when `t < S.xmax`
and `t ∉ S.xip`. That is PostgreSQL's `pg_visible_in_snapshot`, mirrored in Haskell as
`transactionVisible` in `en-postgres/src/En/Postgres/Revision.hs`. A `Revision` in en-core is that
rendered snapshot as opaque text; a `ConsistencyToken` wraps it with the datastore id, the schema
hash, and an optional expiry (`encodeToken` / `decodeToken`, same file).

**How en stores history.** Every grant is a row in `relation_tuple`, stamped with the `created_xid`
that inserted it and, once retired, the `deleted_xid` that soft-deleted it (see
`en-migrations/db/migrations/20260623044157_create-relation-tuples.sql`). A read at revision `R`
returns rows whose creation is visible in `R` and whose deletion, if any, is not. Nothing is
updated in place, so history accumulates.

**How en throws history away.** `reapDeletedTuplesStatement` in
`en-postgres/src/En/Postgres/TupleStore.hs` physically deletes rows where
`deleted_xid < horizon`. `pruneTransactionsBatchStatement` deletes `en_transaction` rows where
`xid < horizon`. Both take the same horizon, computed by `oldestRetainedXidStatement`:

```sql
SELECT coalesce(min(xid), pg_snapshot_xmin(pg_current_snapshot()))::text::bigint
FROM en_transaction
WHERE created_at >= now() - $1::interval
```

where `$1` is `EN_GC_WINDOW` (default `24 hours`, validated as a positive interval by
`en-server/app/Config.hs`). Read that `coalesce` carefully: when no write has landed inside the
window, there is no `min(xid)` to take, and the horizon becomes the *current* snapshot's `xmin`.
On an idle store that is also the current snapshot's `xmax`. This is the trigger for the whole
first half of this plan.

**Where the rule lives.** `validateTokenMetadata` in `en-postgres/src/En/Postgres/Revision.hs`
(around line 292) checks, in order: datastore id, schema hash, wall-clock expiry, that the
revision parses as a snapshot, and finally

```haskell
if snapshot.xmax <= oldestRetainedXid
    then Left (InvalidConsistencyToken "token is older than the garbage-collection window")
    else Right ()
```

That last clause is what M1 replaces. It is called from `runConsistencyStorePostgres`'s
`ValidateToken` and from `resolveConsistencyRequest`, so it governs every `atExactSnapshot` and
`atLeastAsFresh` request, and every validated lookup and lookup-subjects cursor.

`En.Postgres.Watch.validateWatchCursor` (in `en-postgres/src/En/Postgres/Watch.hs`) asks the same
question of a watch cursor's window start, but spells it `snapshot.xmin < oldestRetainedXid` ⇒
reject. `docs/plans/53-add-a-watch-changelog-api.md` derived that rule after discovering the token
rule expired a one-poll-old subscription; its Haddock carries the derivation. It is sound and
conservative. M1 makes the two one function.

**Where the leak lives.** `tokenMetadataFromPayload`, same file, around line 283:

```haskell
case decodeToken token of
    Left err -> Left (InvalidConsistencyToken (Text.pack (show err)))
```

`TokenDecodeError` is an internal sum with four constructors — `TokenBadPrefix`,
`TokenBadFieldCount`, `TokenBadEscape Text`, `TokenBadSnapshot Text` — and `show` puts their names
in the HTTP response body. `En.Servant.Seam.enErrorToFault` maps `InvalidConsistencyToken detail`
to a `400` with stable code `invalid_consistency_token` and `message = detail`, so the code is
already stable and only the message is wrong. Note also that `parseExpiry` (same file, ~line 461)
reports an unparseable ISO-8601 expiry as `TokenBadEscape`, which is simply the wrong constructor.

**What pins the current behavior in tests.** `en-postgres/integration-test/Main.hs` line 232 asserts
`Left (InvalidConsistencyToken "TokenBadPrefix")` — a test that locks the leak in place, and must
change. `en-postgres/test/Main.hs` (around lines 149–161) asserts each `validateTokenMetadata`
message. `en-servant/test/Main.hs` line 872 maps `InvalidConsistencyToken "bad token"` to
`(400, "invalid_consistency_token", False)` in an error-model table.

**The oracle you will test against.** `en-postgres/integration-test/Main.hs` already runs
`runSnapshotOracleScenario`, which asks a real PostgreSQL for `pg_visible_in_snapshot(t, S)` over a
range of `t` (`visibleRows`, `snapshotVisibilityStatement`) and checks `transactionVisible` against
it, over ~240 generated snapshot pairs (`generatedSnapshotPairs`, `snapshotFromSeed`). M1's
predicate is a statement *about* visibility, so it can be proved the same way, against the same
oracle, rather than against a re-implementation of the thing under test.

**Terms.** *Reaped* means physically deleted by the reaper, unrecoverable. *Live at `S`* means the
row's creation is visible in `S` and its deletion is not. *Horizon* means `oldestRetainedXid`. A
*head revision* is `pg_current_snapshot()` at the moment it was taken; `checkedAt` on every read
response is a token minted from the revision the read resolved to, which for `fullyConsistent` is a
head revision.


## Plan of Work

Three milestones, independently verifiable, in dependency order. M2 and M3 do not depend on each
other and could swap.


### Milestone 1: one correct horizon rule, proved against PostgreSQL

Scope: after this milestone one predicate governs both consistency tokens and watch cursors, it is
the exact condition rather than an approximation, an oracle test proves it, and the reported bug has
a regression test.

In `en-postgres/src/En/Postgres/Revision.hs`, add and export:

```haskell
-- | Is every transaction below @horizon@ visible in @snapshot@?
retainedHistoryVisible :: Word64 -> PgSnapshot -> Bool
retainedHistoryVisible horizon snapshot =
    horizon <= snapshot.xmax
        && all (\txid -> txid < snapshot.xmin || txid >= horizon) snapshot.xip
```

Write the derivation from this plan's first Decision Log entry into its Haddock, including the two
counterexamples (`27807:27807:` at horizon `27807`, accepted; `849:851:849` at horizon `850`,
rejected) — they are the whole argument for why the old comparison could not simply be adjusted.
Note in the Haddock that the second clause skips `xip` entries below `xmin`: `transactionVisible`
already reports those visible, and a real `pg_snapshot` never carries them, but the parser accepts
them and the predicate must agree with the function, not with PostgreSQL's invariants.

Replace `validateTokenMetadata`'s final clause with

```haskell
if retainedHistoryVisible oldestRetainedXid snapshot
    then Right ()
    else Left (InvalidConsistencyToken "token is older than the garbage-collection window")
```

and `validateWatchCursor`'s with the same call, deleting `En.Postgres.Watch`'s bespoke
`snapshot.xmin < oldestRetainedXid` and rewriting its Haddock to point at the shared predicate.
`En.Postgres.Watch` keeps its own *message* ("watch cursor is older than …") and keeps omitting the
schema-hash check.

Then the oracle test, in `en-postgres/integration-test/Main.hs`, extending
`runSnapshotOracleScenario` or beside it. For each generated snapshot `S` and each horizon `H` drawn
from `[0 .. S.xmax + 2]`, ask the database which transactions below `H` it considers visible in `S`,
and assert

```haskell
retainedHistoryVisible H S == and [ visible | (t, visible) <- oracleVisibility, t < H ]
```

This is the property, stated exactly, checked against the authority. It is what makes the predicate
a fact rather than an opinion.

Add the regression test for the reported bug — the one an integration suite can hold and a unit test
cannot, because it needs a real `en_transaction` and a real horizon. In a scenario with a
`ConsistencyConfig` whose `gcWindow` is short enough that no anchor row survives it: take
`headRevision`, mint a token from it via `ConsistencyStore.mintToken`, and assert
`ConsistencyStore.validateToken` accepts it. Under today's code this fails; under M1's it passes.
Then assert the converse still holds — a token pinning a genuinely pruned snapshot is still refused —
so the milestone cannot be satisfied by deleting the check.

Update `en-postgres/test/Main.hs`'s `validateTokenMetadata` expectations, and add unit coverage of
`retainedHistoryVisible` at its boundaries: `horizon == xmax` accepted, `horizon == xmax + 1`
refused, an `xip` entry at `horizon - 1` refused, an `xip` entry at `horizon` accepted.

Finally, the monotonicity question. Determine whether `oldestRetainedXidStatement` can return a
smaller value than it returned earlier. The suspect is the `coalesce` fallback: `min(xid)` over a
non-empty window rises, but when the window empties the answer becomes
`pg_snapshot_xmin(pg_current_snapshot())`, which a long-running open transaction can hold below the
`min(xid)` previously reported. Try to construct it in the integration suite (open a transaction that
acquires an xid via `pg_current_xact_id()` and holds it; observe the horizon before and after the
anchor rows age out). Whatever the answer, record it in Surprises & Discoveries. If the horizon can
move backwards, then rows reaped under a higher horizon can be resurrected as "still needed" by a
token validated under a lower one, and *both* the old rule and the new one are unsound — in which
case this plan grows a fourth milestone to make the horizon a monotone high-water mark, and that is
a finding worth the whole plan.

Acceptance: `cabal build all && cabal test en-postgres-revision-tests && cabal test
en-postgres-integration-tests` pass, the oracle property holds over the generated pairs, and the
regression test in Validation and Acceptance goes from red to green.


### Milestone 2: a token failure a client can act on

Scope: after this milestone no internal constructor name reaches the wire, and a client can tell
"your token is gibberish" from "your token is too old" from "your token is for another datastore"
without parsing prose.

First settle the taxonomy. The opening proposal is in the Decision Log: three codes,
`malformed_consistency_token` / `consistency_token_expired` / `invalid_consistency_token`. Confirm or
revise it, and record the outcome. Two constraints bear on the choice. `En.Error.EnError` is a closed
sum pattern-matched across `en-core`, `en-postgres`, `en-servant`, and `en-biscuit`, so adding a
constructor is a compile-enforced change and every site must be visited — which is the point, not the
cost. And `En.Servant.Seam.enErrorToFault` is the single mapping from `EnError` to
`(status, code, retryable)`, so codes are added there and nowhere else.

Then, in `en-postgres/src/En/Postgres/Revision.hs`, give `TokenDecodeError` a rendering written for a
client — a function, not a `Show` instance, because `Show` is for the operator and the two audiences
want different text. Something to the effect of "not an en consistency token", "consistency token is
truncated or has extra fields", "consistency token contains an invalid escape sequence",
"consistency token does not carry a PostgreSQL snapshot". Route `tokenMetadataFromPayload` through it.
Do not echo the offending token back in the message; a caller that sent it has it, and an operator
reading a log does not need it twice.

While there, fix `parseExpiry`: an unparseable ISO-8601 expiry is not a bad escape sequence. Either
add a constructor or reuse `TokenBadSnapshot`'s shape with an honest name. This is a one-line bug and
it is in the code path this milestone is already rewriting.

Then reconcile the cursor errors. `En.Lookup` (line ~979) and `En.LookupSubjects` (line ~812) raise
`InvalidConsistencyToken "lookup cursor"` when a cursor is malformed. `En.Postgres.Watch` raises
`InvalidCursor`, whose own Haddock in `en-core/src/En/Error.hs` argues at length that a malformed
cursor is a different artifact obtained a different way and must not be confused with a token fault.
`docs/plans/53` followed that Haddock. Lookup predates it. Decide which is right — the Haddock's
argument is strong and the two lookup sites are the deviation — and make them agree. This changes the
wire code for a malformed lookup cursor from `invalid_consistency_token` to `invalid_cursor`; call
that out explicitly in the Decision Log, because it is a client-visible change to a frozen contract's
*behavior* even though it adds no field.

Update the tests that pin the current strings: `en-postgres/integration-test/Main.hs` line 232
(`InvalidConsistencyToken "TokenBadPrefix"`), the assertions around lines 236 and 254,
`en-postgres/test/Main.hs` lines 149–161 and 216, `en-core/test/Main.hs` lines 543–546,
`en-core/conformance/Main.hs` lines 147 and 157, and `en-servant/test/Main.hs`'s error-model table at
line 872. Add a golden assertion that no response body in the servant suite contains a string
matching an internal constructor name — the guard that stops this regressing.

Acceptance: `cabal build all && cabal test all` pass, and the two `curl` transcripts in Validation and
Acceptance that currently print `TokenBadPrefix` and `TokenBadFieldCount` print prose under stable
codes.


### Milestone 3: price the watch drain, then decide

Scope: after this milestone the cost of draining a wide watch window is a measured number in this
plan, and either the query has been rewritten on the strength of it or the number is recorded and the
item is closed.

The situation, from `docs/plans/53`'s Surprises: `readChangesStatement` in
`en-postgres/src/En/Postgres/TupleStore.hs` bounds both of its arms by the window-start snapshot's
`xmin`, and PostgreSQL answers with a `BitmapOr` over `relation_tuple_created_xid_idx` and
`relation_tuple_deleted_xid_idx`. Neither index carries `id`, so the `ORDER BY id ASC` becomes a
`Sort` and the keyset predicate `id > $4` becomes a `Filter` rather than an index seek. A drain of a
window holding `W` changes at page size `L` therefore touches all `W` matched rows on each of its
`W/L` pages.

Measure first, in `en-postgres/bench/Main.hs` (a `tasty-bench` suite already exists) or as a
throwaway scenario against a populated ephemeral database. Vary `W` (the number of changes inside the
window) across at least three orders of magnitude and `L` across the page sizes a real consumer would
use, and report time and buffers per page. The question the numbers must answer: at the largest window
`EN_GC_WINDOW` permits, is a full drain's cost acceptable, or does it grow into the thing the GC
horizon was supposed to bound?

Only then consider the rewrite, and consider it sceptically. The obvious shape — two `UNION`ed arms,
each with its own keyset seek — does not fall out: an index on `(created_xid, id)` orders by `id` only
within a single `created_xid`, so a range scan over `created_xid >= $xmin` still cannot emit `id`
order without a sort. A row created *and* deleted inside the window matches both arms, so any `UNION
ALL` needs a `DISTINCT ON (id)` that reintroduces a sort of its own. And the primary-key scan that
*would* seek (`id > $cursor`, with the visibility predicates as filters) is the plan
`readAllTuplesStatement` already uses, and it reads the whole table — which is cheap exactly when the
window is wide and ruinous when it is narrow. There may be a real answer here (choosing the plan by
estimated window width, say), and there may not.

Acceptance: the numbers are in this plan's Validation and Acceptance section, and the Decision Log
records what was done about them and why. "Nothing, and here is why" is a passing grade. A rewrite
without a before-and-after table is not.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/en` in the dev shell.

Build and database-free tests:

```bash
cabal build all
cabal test en-core
cabal test en-servant
cabal test en-postgres-revision-tests
```

Storage tests (ephemeral PostgreSQL, no dev database needed):

```bash
cabal test en-postgres-integration-tests
```

Everything:

```bash
cabal test all
```

Dev PostgreSQL and a server for the live reproduction. **Do not use port 8080**: on this machine it
is held by an unrelated `ssh` tunnel that answers `GET /healthz` with `200`, so an acceptance run
against it exercises nothing. Check first, then bind something free.

```bash
lsof -nP -iTCP:8080 -sTCP:LISTEN
just process-up && just run-migrations
EN_PORT=8099 EN_AUTH_DISABLED=true EN_GC_WINDOW="1 second" "$(cabal list-bin en-server)"
```

`EN_GC_WINDOW="1 second"` is what makes the bug reachable in seconds rather than in a day: it ages
every `en_transaction` row out of the retention window almost immediately, which drives
`oldestRetainedXidStatement` onto its `coalesce` fallback. It must be a *positive* interval —
`en-server/app/Config.hs` rejects `0 seconds`.

Stop everything with `just process-down`.


## Validation and Acceptance

### The bug, as it stands today (recorded 2026-07-10, before any change)

Against a live server started as above. A check at `fullyConsistent` mints a `checkedAt` token:

```bash
curl -sS -X POST localhost:8099/v1/check -H 'content-type: application/json' -d '{
  "consistency": {"mode": "fullyConsistent"}, "context": {"values": {}},
  "subject": {"kind": "id", "objectType": "user", "objectId": "alice"},
  "permission": "view", "object": {"objectType": "space", "objectId": "watch-demo"}}'
```

```json
{"decision":{"result":"denied"},"checkedAt":"en1.0c9c482f-6b7f-49d4-b106-c4c65a3ae6e5.fnv1a64%3a88633b46c783909e.27807%3a27807%3a."}
```

Spending that token immediately, with no write in between, is a `400`:

```bash
curl -sS -X POST localhost:8099/v1/check -H 'content-type: application/json' -d '{
  "consistency": {"mode": "atExactSnapshot", "token": "en1.0c9c…27807%3a27807%3a."}, "context": {"values": {}},
  "subject": {"kind": "id", "objectType": "user", "objectId": "alice"},
  "permission": "view", "object": {"objectType": "space", "objectId": "watch-demo"}}'
```

```json
{"code":"invalid_consistency_token","message":"token is older than the garbage-collection window","retryable":false}
```

The token's snapshot is `27807:27807:` and the horizon is `27807`, so `xmax <= horizon` fires. Nothing
has been reaped; no write has occurred. `En.Client.chainFrom` is the documented way to feed a
`checkedAt` into the next read, and on this store it cannot be used at all.

The asymmetry that hid this. A *write* token minted at the same instant is accepted, because
`writeVisibleSnapshot` raised its `xmax` past the writing transaction's own xid:

```text
write token: en1.…27807%3a27808%3a.     atExactSnapshot -> HTTP 200
```

…but two seconds later, once its own `en_transaction` anchor has aged out of the one-second window,
even that token is refused:

```json
{"code":"invalid_consistency_token","message":"token is older than the garbage-collection window","retryable":false}
```

And the leak, on any server:

```bash
curl -sS -X POST localhost:8099/v1/check -H 'content-type: application/json' \
  -d '{"consistency": {"mode": "atExactSnapshot", "token": "xn1.a.b.c.d"}, …}'
curl -sS -X POST localhost:8099/v1/check -H 'content-type: application/json' \
  -d '{"consistency": {"mode": "atExactSnapshot", "token": "en1.a.b.c"}, …}'
```

```json
{"code":"invalid_consistency_token","message":"TokenBadPrefix","retryable":false}
{"code":"invalid_consistency_token","message":"TokenBadFieldCount","retryable":false}
```

### What must be true afterwards

**M1.** The first transcript above returns `200` and a decision, not a `400`. The write-token
transcript returns `200` at both instants. A token pinning a snapshot whose history has genuinely been
reaped — construct it by reaping with a horizon above the token's `xmax` — still returns `400` with
the same message and code. The oracle property holds: for every generated snapshot `S` and horizon `H`
in the integration suite, `retainedHistoryVisible H S` agrees with PostgreSQL's own verdict on whether
every transaction below `H` is visible in `S`. The watch feed's own acceptance transcript in
`docs/plans/53-add-a-watch-changelog-api.md` still passes unchanged, which is the check that unifying
the two rules did not loosen the one that was already right.

**M2.** The two leak transcripts return prose under stable codes — no string in any response body
matches an internal constructor name. The three (or however many M2 settles on) codes are each
reachable, and each is asserted in `en-servant/test/Main.hs`'s error-model table. A malformed lookup
cursor and a malformed watch cursor produce the same code as each other.

**M3.** This section carries a table of time and buffers per page against window width and page size,
and the Decision Log says what was done about it. If the query was rewritten, the table has a
before-and-after column and `docs/plans/53`'s `EXPLAIN` is superseded here.

### Test-level validation

`cabal test all` is green. `en-postgres-revision-tests` covers `retainedHistoryVisible`'s boundaries
and `validateTokenMetadata`'s messages; `en-postgres-integration-tests` covers the oracle property,
the head-revision regression, the still-rejected genuinely-stale token, and the monotonicity
investigation's finding; `en-servant-tests` covers the error-model table and the no-constructor-names
guard.


## Idempotence and Recovery

Every change here is to pure validation logic, its error rendering, and tests. Nothing writes to the
database, nothing migrates schema, and no stored data changes shape, so every step is safely
re-runnable and `git checkout` is a complete rollback.

Two changes are visible to running clients and deserve the caution that implies. M1 makes validation
*accept* tokens it used to reject; a client cannot be broken by a token starting to work, and the
converse — a token that used to be accepted and now is not — is exactly the `849:851:849` unsoundness
being fixed, whose acceptance was the bug. M2 changes the `code` on a malformed token and on a
malformed lookup cursor; a client switching on `invalid_consistency_token` to mean "retry with a fresh
read" would previously have retried forever on a gibberish token, and will now see
`malformed_consistency_token` and stop. Note both in the eventual release notes.

If M1's monotonicity investigation finds the horizon can move backwards, stop. Do not ship a rule that
depends on an assumption just disproved — record the finding, and treat the high-water-mark fix as a
blocking prerequisite rather than a follow-up. The current rule shares the dependency, so the tree is
no worse in the meantime.


## Interfaces and Dependencies

End-state interfaces, by full module path:

- `En.Postgres.Revision` (`en-postgres/src/En/Postgres/Revision.hs`): new export
  `retainedHistoryVisible :: Word64 -> PgSnapshot -> Bool`. `validateTokenMetadata ::
  ConsistencyConfig -> UTCTime -> Word64 -> TokenMetadata -> Either EnError ()` keeps its signature and
  changes its garbage-collection clause. `tokenMetadataFromPayload :: ConsistencyToken -> Either EnError
  TokenMetadata` keeps its signature and stops rendering `TokenDecodeError` with `show`. A new
  `renderTokenDecodeError :: TokenDecodeError -> Text` (name to taste) is exported for tests.
- `En.Postgres.Watch` (`en-postgres/src/En/Postgres/Watch.hs`): `validateWatchCursor ::
  ConsistencyConfig -> Word64 -> DatastoreId -> WatchCursorState -> Either EnError WatchCursorState`
  keeps its signature and delegates its horizon clause to `retainedHistoryVisible`.
- `En.Error` (`en-core/src/En/Error.hs`): possibly one or two new constructors, per M2's taxonomy
  decision. `EnError` is a closed sum, so this is compile-enforced across `en-core`, `en-postgres`,
  `en-servant`, and `en-biscuit`.
- `En.Servant.Seam` (`en-servant/src/En/Servant/Seam.hs`): `enErrorToFault` gains the new codes. It is
  the only place a wire code is chosen.
- `En.Postgres.TupleStore` (`en-postgres/src/En/Postgres/TupleStore.hs`): `readChangesStatement`
  changes only if M3's numbers justify it.

Dependencies, restated so this plan stands alone. No hard dependency on any open plan. It corrects
code introduced by `docs/plans/51-return-checked-at-consistency-tokens-from-read-responses.md` (which
minted the first read tokens from head revisions), `docs/plans/53-add-a-watch-changelog-api.md` (which
found the bug and worked around it locally), and code that predates both (`validateTokenMetadata`,
`tokenMetadataFromPayload`). It touches the error taxonomy that
`docs/plans/35-version-the-wire-contract-and-type-the-error-model.md` established; that plan is
Complete, and its envelope is unchanged here — only the set of `code` values grows.
`docs/plans/37-schedule-background-maintenance-for-reaping-and-transaction-pruning.md` is not yet
landed and owns the reaping cadence; M1's monotonicity finding is input to it, and if that plan lands
first it must not be assumed to have fixed anything recorded here. No new package dependencies are
required.

On completion, update the Surprises entry in `docs/plans/53-add-a-watch-changelog-api.md` that records
the latent `checkedAt` defect, and the Decision Log entry in
`docs/masterplans/9-complete-the-en-api-surface.md` that says the defect "belongs to no plan currently
open" — it belongs to this one.
