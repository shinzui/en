---
id: 56
slug: pin-attenuation-injection-semantics-with-tests
title: "Pin attenuation-injection semantics with tests"
kind: exec-plan
created_at: 2026-07-07T15:25:10Z
master_plan: "docs/masterplans/10-harden-the-biscuit-decision-token-layer.md"
intention: intention_01kx6ajfcjefhtvc4fhwk7fjq7
---

# Pin attenuation-injection semantics with tests

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

The entire safety story of `en-biscuit` attenuation rests on one assumption
about the `biscuit-haskell` dependency: facts added by a *holder-attenuated
block* (a block any bearer of the token can append) are invisible to the
verifier's fact queries and to authorizer policies, so a holder cannot widen a
grant by forging `en_right`, `en_expires_at`, `en_revocation_id`, or
`en_container_scope` facts in an appended block. The existing test suite
proves *mint-time* injection safety (punctuation in field values cannot break
out of a string term — `en-biscuit/test/Main.hs` lines 224–260) but has no
test in which an attacker-controlled *block* adds forged facts. That is
finding D2 of `docs/reviews/2026-07-07-architecture-performance-review.md`.

This plan is test-only. After it, `cabal test en-biscuit` contains tests that
would fail loudly if a biscuit-haskell upgrade (or a change to
`extractAndCheck` in `en-biscuit/src/En/Biscuit/Verify.hs`) ever let a
holder-added fact widen a grant — a tripwire for the dependency. Each test
first proves the forged fact genuinely exists in the token (via an explicitly
`trusting previous` query), then proves the verifier and plain authorizers do
not see it. If any assertion fails, the assumption is false: this plan then
stops, records the evidence, escalates, and switches to its contingency
milestone. This is child EP-56 of
`docs/masterplans/10-harden-the-biscuit-decision-token-layer.md`; the master
plan wants it to run first because its outcome could reshape the verification
code that EP-55
(`docs/plans/55-support-key-rotation-and-unconditional-revocation-in-biscuit-grants.md`)
builds on — EP-55 builds on whichever verify code shape survives this plan.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: Confirm the `trusting previous` query syntax works through `queryRawBiscuitFacts` with a two-block token (spike assertion inside the first new test).
- [x] M1: Forged `en_right` test — object grant, holder block adds a broader `en_right`; verifier rejects the widened request, accepts the original; positive controls prove the forged fact is physically present.
- [x] M1: Forged `en_expires_at` test — holder block adds a later expiry; verification after the real expiry returns `Expired`.
- [x] M1: Forged `en_revocation_id` tests — shadowing a real id does not evade `Revoked`; adding an id to an id-less token does not reach the revocation callback.
- [x] M1: Forged `en_container_scope` and `en_subject` tests — scoped grant cannot gain a container; subject cannot be re-pointed.
- [x] M2: Authorizer-policy scoping test — `authorizeBiscuit` with a non-`trusting` `allow if` over the forged fact denies.
- [x] M2: Narrowing-direction tests — attenuation makes previously passing requests fail (correct), and no forged-fact-plus-check combination makes a previously failing request pass.
- [x] Final: `cabal test en-biscuit` passes; the library-promise summary below is confirmed against observed behavior; Outcomes & Retrospective written.
- [x] Contingency (only if an M1/M2 assertion fails): not triggered — every assertion held on the first run. M3 was not executed and no production module changed.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The scoping assumption **holds**. Every M1/M2 assertion passed on the first
  run against the pinned `biscuit-haskell`; the contingency milestone M3 was
  never entered and no production module was touched.

- `trusting previous` parses in the `query` quasiquoter but is *rejected* in the
  `authorizer` quasiquoter, so the M1 fallback ("prove presence via an
  `authorizeBiscuit` policy annotated `trusting previous`") could never have
  worked. `Auth/Biscuit/Datalog/Parser.hs:430` errors with `PreviousInAuthorizer`
  when `inAuthorizer` is set, and `authorizer` is built from `authorizerParser`
  (which sets it) while `query` is built from `queryParser False`. This does not
  matter — the primary path works — but the plan's stated fallback was not
  viable. Anyone reaching for it should instead query the parsed biscuit
  directly with `queryRawBiscuitFacts`.

- The tests were verified to be non-vacuous by mutation, not just by inspection.
  Adding `trusting previous` to the `en_container_scope` query in
  `resolveScope` (`en-biscuit/src/En/Biscuit/Verify.hs:279`) — i.e. simulating
  exactly the regression this plan guards against — turns the suite red with the
  intended message, and the source was then restored:

    ```text
    en-biscuit test FAILED: verify forged scope: the added container is out of scope: expected Left ResourceNotInScope, got Right <verified grant>
    Test suite en-biscuit-tests: FAIL
    ```

- Not all forged facts are equally dangerous, and the tests now record the
  distinction. `en_container_scope` is the one genuinely exploitable shape:
  `resolveScope` gathers *every* matching row via `containerRefs`, so a visible
  holder fact would directly widen the scope (as the mutation above proves).
  The single-valued facts (`en_subject`, `en_expires_at`, `en_right`,
  `en_revocation_id`) are read through `getSingleVariableValue`, which returns
  `Nothing` on two rows — a visible forged fact would therefore surface
  `MalformedGrant` (fail-closed) rather than a widened grant. `en_revocation_id`
  is the exception worth naming: it is *optional*, so `Nothing` means "not
  revocable" rather than "malformed", and a visible shadowing fact would silently
  skip the revocation check. That is why `attenuationForgedRevocationTest`
  asserts `Revoked` rather than merely "not `Right`". This asymmetry is also why
  each forged-fact test asserts the genuine request still returns `Right`: a
  bare "the widened request fails" assertion would pass vacuously under
  `MalformedGrant`.

- `en-biscuit/test/Main.hs` compiles with `-Wambiguous-fields` active, and
  `EnGrant`/`EnScopedGrant`/`VerifyRequest`/`MintConfig` share field names
  (`revocationId`, `operation`, `now`). Record *update* syntax on those fields
  warns; record *construction* does not. The new helpers
  (`forgeableObjectGrantWith`, `objectRequest`) take the varying field as a
  parameter for this reason rather than updating a shared literal.


## Decision Log

Record every decision made while working on the plan.

- Decision: This plan changes no production code — only
  `en-biscuit/test/Main.hs` — unless the contingency milestone triggers.
  Rationale: The master plan deliberately keeps EP-56 test-only and
  independent so it can land before any feature work and act as a tripwire
  for biscuit-haskell upgrades.
  Date: 2026-07-07
- Decision: Every forged-fact test must include a positive control proving the
  forged fact is physically present in the token, via a query annotated
  `trusting previous`.
  Rationale: Without the control, a test could pass vacuously (e.g. the
  attenuation block silently failed to serialize the fact) and pin nothing.
  The `trusting previous` annotation is the library's documented way to opt in
  to reading facts from all blocks (`queryRawBiscuitFacts` haddock,
  `Auth/Biscuit/Token.hs:206–217` in the pinned source).
  Date: 2026-07-07
- Decision: Pin the semantics at three layers — raw fact query
  (`queryRawBiscuitFacts`, what `extractAndCheck` uses), the full verifier
  (`verifyGrant`), and authorizer policies (`authorizeBiscuit`).
  Rationale: `extractAndCheck` protects en's own verifier, but downstream
  services in other stacks may authorize with plain Biscuit authorizers; the
  policy-scoping guarantee is part of what the documentation promises them.
  Date: 2026-07-07
- Decision: Extend the existing single test binary `en-biscuit/test/Main.hs`
  rather than adding a new test-suite stanza.
  Rationale: The package uses one plain `exitcode-stdio-1.0` binary with
  hand-rolled asserts; the new tests follow `injectionSafetyTest`'s existing
  pattern and reuse its helpers (`die`, `assertVerifyError`, `mkVerifyRequest`).
  Date: 2026-07-07
- Decision: If the scoping assumption proves FALSE, the fix is specified here
  as contingency milestone M3 (rewrite `extractAndCheck` to authority-scoped
  extraction), not as a separate plan — but it must not begin until the
  failure is recorded in Surprises & Discoveries and escalated.
  Rationale: The task is "pin the semantics"; discovering they do not hold is
  a security finding for the whole layer (and for EP-55/EP-57, which must not
  build on a broken verifier) and needs a human decision before code changes.
  Date: 2026-07-07
- Decision: Prove the tests are a real tripwire by mutating `resolveScope` to
  trust holder blocks, observing the failure, and restoring the source — rather
  than trusting that the assertions would catch a regression.
  Rationale: A test that pins a dependency assumption is worthless if it passes
  for the wrong reason. The plan's positive controls prove the forged fact is
  *present*; the mutation proves the exploit assertions are *load-bearing*.
  `en_container_scope` was chosen as the mutation site because it is the only
  fact whose extraction path (`containerRefs`, which keeps every row) would
  widen a grant rather than fail closed.
  Date: 2026-07-10
- Decision: Assert the exact error constructor *and* that the genuine request
  still returns `Right`, in every forged-fact test.
  Rationale: Four of the five forged facts are read with
  `getSingleVariableValue`, which returns `Nothing` when the holder's row is
  visible alongside the authority's. A test asserting only "the widened request
  fails" would pass under `MalformedGrant` — i.e. it would stay green while
  extraction was actually broken. The success assertion is what distinguishes
  "the forged fact was ignored" from "the forged fact broke the token".
  Date: 2026-07-10
- Decision: In `narrowingDirectionTest`, pin `ResourceNotInScope` for the
  `folder:f9` request rather than accepting either that or `RestrictionFailed`.
  Rationale: The plan allowed either, because the attacker's own `check if`
  could in principle trip first. It does not: `extractAndCheck` runs the scope
  test before `runRestrictions`, so `f9` is rejected as out-of-scope and never
  reaches the authorizer. Pinning the observed constructor makes a future
  reordering of those two steps visible. The `folder:f1` request, which does
  reach the authorizer, is separately pinned to `RestrictionFailed`.
  Date: 2026-07-10


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

The plan's purpose was to convert an untested assumption into a tripwire. That is
done, and the assumption survived. `cabal test en-biscuit` now runs seven new
tests — `attenuationForgedRightTest`, `attenuationForgedExpiryTest`,
`attenuationForgedRevocationTest`, `attenuationForgedScopeTest`,
`attenuationForgedSubjectTest`, `authorizerScopingTest`, and
`narrowingDirectionTest` — covering all five `en_*` grant facts a holder might
forge, at all three layers the Decision Log named: the raw fact query that
`extractAndCheck` depends on, the full `verifyGrant` verifier, and plain
`authorizeBiscuit` policies for downstream services that never touch en's
verifier. Finding D2 of
`docs/reviews/2026-07-07-architecture-performance-review.md` is closed. Only
`en-biscuit/test/Main.hs` changed; contingency milestone M3 was not triggered.

What the suite now guarantees, and would fail loudly on: a holder-appended block
containing forged `en_right` (either a new object or a broader permission),
`en_expires_at`, `en_revocation_id` (shadowing a real id, or planted into an
id-less token), `en_container_scope`, or `en_subject` changes no `verifyGrant`
outcome and satisfies no un-annotated `allow if` policy — while a
`trusting previous` control proves in each case that the forged fact really is in
the token, so no test can pass because the attack failed to build.

Two things exceed the plan as written. First, the tests were validated by
mutation rather than by inspection: temporarily making `resolveScope` trust
holder blocks turns the suite red with the expected message (transcript in
Surprises & Discoveries), which is the evidence that these assertions are
load-bearing rather than incidentally green. Second, the plan under-specified the
planted-revocation case; the `IORef` assertion proves not just that the token
verifies but that the forged id never reached the caller's revocation callback,
which is the property that actually matters.

One gap is worth naming for the sibling plans: this plan pins *fact* scoping, not
*key* scoping. Every test signs with a single deterministic issuer key. When
EP-55
(`docs/plans/55-support-key-rotation-and-unconditional-revocation-in-biscuit-grants.md`)
introduces a keyset and `rootKeyId` selection, the analogous question — can a
holder influence which key a verifier selects? — is new ground and is not covered
here. The seven tests will need their `verifyGrant` call sites updated
mechanically (`singleKey` plus a `const (pure False)` block check, per the
Interfaces and Dependencies section below), but every assertion in them remains
correct as written, because none of them depend on the key material.


## Context and Orientation

`en-biscuit` (package directory `en-biscuit/`) turns successful `en`
authorization decisions into signed Biscuit tokens. A *Biscuit* is a bearer
token made of signed blocks: block 0, the *authority block*, is written by the
issuer at mint time and carries the `en_*` grant facts (vocabulary defined in
`en-biscuit/src/En/Biscuit/Grant.hs`); any holder may append further blocks
with `Auth.Biscuit.addBlock` (*attenuation*), and the format's contract is
that appended blocks can only narrow, never widen, what the token authorizes.
`En.Biscuit.Verify.attenuateGrant` (`en-biscuit/src/En/Biscuit/Verify.hs`,
lines 351–357) appends `check if` clauses this way — but nothing stops a
malicious holder from calling `addBlock` themselves with a block containing
*facts* instead of checks, e.g. a forged
`en_right("document", "secret", "view")`.

The verifier, `verifyGrant` in `en-biscuit/src/En/Biscuit/Verify.hs`, extracts
grant facts with `extractAndCheck` (lines 209–258), whose `queryFacts` helper
(line 385) calls `Auth.Biscuit.queryRawBiscuitFacts` with un-annotated queries
like `[query|en_right($ot, $oid, $perm)|]`. Whether a forged block fact is
visible to those queries is entirely the dependency's behavior. Here is what
the pinned biscuit-haskell source (checked out at
`/Users/shinzui/Keikaku/hub/haskell/biscuit-haskell-project/biscuit-haskell/biscuit/src/`,
pinned by the `source-repository-package` stanza in `cabal.project`) actually
promises — this is the semantics the tests pin:

- Every fact is stored with an *origin*: the set of block ids it came from.
  `FactGroup` (`Auth/Biscuit/Datalog/Executor.hs:176`) is a map from origin
  sets to fact sets; `collectWorld`
  (`Auth/Biscuit/Datalog/ScopedExecutor.hs:284–291`) files block *n*'s facts
  under origin `{n}`, with the authority block at id 0 and holder blocks at
  1, 2, ….
- A query or rule body without a `trusting` annotation defaults to the scope
  `OnlyAuthority`: `keepAuthorized'` (`Auth/Biscuit/Datalog/Executor.hs:197–210`)
  maps that to block id set `{0}`, adds the current evaluation context's id,
  and then keeps only fact groups whose origin is a *subset* of that set. A
  holder block's fact (origin `{1}`) survives only if the query explicitly
  says `trusting previous` or names the block.
- `queryRawBiscuitFacts` (`Auth/Biscuit/Token.hs:238–240`, via
  `queryAvailableFacts`, `Auth/Biscuit/Datalog/ScopedExecutor.hs:297–304`)
  evaluates queries in the authorizer's context, so un-annotated queries see
  authority facts only.
- Authorizer checks and policies in `authorizeBiscuit` go through the same
  `keepAuthorized'` filter (`checkPolicy` / `isQueryItemSatisfied`,
  `Auth/Biscuit/Datalog/Executor.hs:246–262`), so an `allow if …` policy also
  sees authority facts only. A holder block's *own* `check if` clauses
  additionally see that block's own facts — which can only make the token
  fail more, i.e. narrow.

So the library's design intends exactly the property `extractAndCheck`
assumes. What no test in this repository proves is that the *shipped, pinned
build* behaves this way end-to-end through en's verifier, and that a future
`cabal.project` re-pin cannot silently regress it. Tests live in
`en-biscuit/test/Main.hs` (single binary, hand-rolled asserts, deterministic
key via `loadSecret`, fixed clocks `verifyNow`/`afterExpiry`/`sampleExpiry`).
The pattern to extend is `injectionSafetyTest` (lines 224–260): build the
malicious artifact, then a *positive control* proving the attack artifact is
real, then the exploit assertion proving it is inert.

This plan implements finding D2 of
`docs/reviews/2026-07-07-architecture-performance-review.md` under master plan
`docs/masterplans/10-harden-the-biscuit-decision-token-layer.md`. Integration
points restated: EP-55 changes `verifyGrant`'s signature (single `PublicKey`
becomes a keyset) — these tests target whichever signature exists when they
run, and whichever plan lands second updates the other's call sites; the
assertions here are about fact scoping and survive that change untouched.
EP-57 (`docs/plans/57-mint-biscuit-grants-over-http.md`) hands minted tokens
to arbitrary HTTP callers, which makes this plan's guarantee — holders cannot
widen — a precondition for that endpoint's safety.


## Plan of Work

Milestone 1 — forged-fact injection tests through the verifier. This
milestone adds one test function per forged fact to
`en-biscuit/test/Main.hs`, registered in `main` after `shomeiFlowTest`. At its
end, the suite proves that a holder-attenuated block adding forged grant facts
cannot change any `verifyGrant` outcome. Each test follows the same shape:
mint a genuine grant (reuse `loadSecret`, `sampleObjectGrant`,
`mkVerifyRequest`, the fixed clocks), obtain an `Open` biscuit (either mint
and re-parse then `asOpen`, or build directly with `mkBiscuit secret
grantBlk` as `attenuationTests` does — the direct build is simpler),
`addBlock` a block of forged facts, serialize, and then assert three things:

1. Positive control (attack is real): `queryRawBiscuitFacts` with a
   `trusting previous`-annotated query finds the forged fact. For example:

    ```haskell
    forged <- either (die . show) pure
        (queryRawBiscuitFacts parsed [query|en_right("document", "secret", "view") trusting previous|])
    assertBool "forged fact must be present in the token" (not (Set.null forged))
    ```

   The first new test doubles as a syntax spike: if the `query` quasiquoter
   rejects `trusting previous` (it should not — scope annotations are part of
   the Datalog grammar in `Auth/Biscuit/Datalog/Parser.hs`), record the
   deviation in Surprises & Discoveries and fall back to proving presence via
   `authorizeBiscuit` with an `allow if en_right("document","secret","view")
   trusting previous;` policy.
2. Raw-query scoping (what `extractAndCheck` relies on): the same query
   *without* the annotation returns no bindings.
3. Verifier behavior: `verifyGrant` returns the same results as for the
   un-attenuated token — success for the genuine request, the precise
   fail-closed error for the widened one.

The individual tests:

- *Forged `en_right`* (`attenuationForgedRightTest`): authority grants
  `view` on `document:roadmap`; holder block adds
  `en_right("document", "secret", "view")`. Verify for `document:secret` →
  `ResourceNotInScope`; verify for `document:roadmap` → `Right …` (the forged
  fact must not even disturb extraction — if scoping failed, two `en_right`
  rows would make `getSingleVariableValue` ambiguous and surface
  `MalformedGrant`, which is why the success assertion matters as much as the
  failure one). Also forge a broader *permission* the same way
  (`en_right("document", "roadmap", "admin")`) and verify operation `admin` →
  `OperationNotAuthorized`.
- *Forged `en_expires_at`* (`attenuationForgedExpiryTest`): mint with the
  standard config so the real expiry is `sampleExpiry + 3600s` (01:00Z);
  holder block adds `en_expires_at({farFuture})` for some 2027 timestamp.
  Verify at `afterExpiry` (02:00Z, past real expiry, before the forged one) →
  `Expired`.
- *Forged `en_revocation_id`* (`attenuationForgedRevocationTest`), two
  scenarios. Shadowing: mint with `revocationId = Just (RevocationId
  "rev-1")`; holder adds `en_revocation_id("rev-clean")`; verify with
  `revoked = \r -> pure (r == RevocationId "rev-1")` → still `Revoked`.
  Planting: mint with `revocationId = Nothing`; holder adds
  `en_revocation_id("rev-x")`; verify with a `revoked` callback that writes
  every id it is asked about into an `IORef [RevocationId]` and returns
  `False` → verification succeeds *and* the ref stays empty, proving the
  forged id never reaches the callback (the verifier read `Nothing`, not the
  forged fact).
- *Forged `en_container_scope`* (`attenuationForgedScopeTest`): scoped grant
  over containers `folder:f1`/`folder:f2`; holder adds
  `en_container_scope("folder", "f9")`. Verify for `folder:f9` →
  `ResourceNotInScope`; for `folder:f1` → success.
- *Forged `en_subject`* (`attenuationForgedSubjectTest`): grant for
  `user:alice`; holder adds `en_subject("user", "mallory")`. Verify with
  `expectedSubject = user:mallory` → `WrongSubject`; with `user:alice` →
  success.

Milestone 2 — authorizer-policy scoping and the narrowing direction. Two more
tests. First, `authorizerScopingTest` pins the guarantee for consumers that do
not use en's verifier at all: against the forged-`en_right` token from M1's
construction, `authorizeBiscuit parsed [authorizer|allow if
en_right("document", "secret", "view");|]` must return `Left` (no policy
matched — un-annotated policies read authority facts only), while the same
authorizer over the *genuine* fact returns `Right`. Second,
`narrowingDirectionTest` pins that attenuation is one-way. The existing
`attenuationTests` (lines 517–587) already prove a narrowed token fails
requests the parent passed — that is the correct direction and stays. The new
test pins the impossible direction: take a scoped grant over `folder:f1`/
`folder:f2`, append a block that *combines* a forged widening fact with a
matching check (`en_container_scope("folder", "f9")` plus
`check if resource($t, $i), $t == "folder", $i == "f9"`) — the strongest
shape an attacker can produce, since a block's own checks *can* see its own
facts — and assert `verifyGrant` for `folder:f9` still fails (the check
constrains ambient facts but `extractAndCheck`'s scope test reads authority
containers only; the outcome is `ResourceNotInScope`, or `RestrictionFailed`
if the added check trips first against a non-f9 request — assert the request
fails, and assert the specific constructor observed so a future change is
noticed). Also assert the parent token (without the malicious block) behaves
identically to before, i.e. the attack block did not have to be "accepted" by
anyone to be inert.

Milestone 3 — contingency, executed ONLY if an M1/M2 assertion fails. If any
forged fact is visible to an un-annotated query or changes a `verifyGrant` or
`authorizeBiscuit` outcome, the layer's core assumption is false. Then: stop
all other work on this plan; paste the failing test output into Surprises &
Discoveries; update the master plan's Surprises section and mark EP-55/EP-57
blocked in its registry notes; escalate to the maintainer before touching
production code. The fix, once green-lit, is specified here so this plan
remains self-contained: rewrite `extractAndCheck` and `resolveScope` in
`en-biscuit/src/En/Biscuit/Verify.hs` so extraction is authority-scoped *by
construction* rather than by query default — parse the token, take the
authority block's facts alone (the authority `Block` is what
`En.Biscuit.Grant.grantBlock` produced at mint time; if no exposed API yields
per-block facts, evaluate each `en_*` query through
`queryRawBiscuitFactsWithLimits` against a single-block reconstruction, or
pattern-match the `Block`'s facts via `Auth.Biscuit.Datalog.AST` — the AST
module is exposed) — and make the M1/M2 tests the acceptance criteria of this
milestone: they must pass against the rewritten verifier with no test
weakened. EP-55 then builds on the rewritten shape (both plans note this).


## Concrete Steps

Work from the repository root. Read the mechanism before writing tests:

```bash
cd /Users/shinzui/Keikaku/bokuno/en
sed -n '205,260p' en-biscuit/src/En/Biscuit/Verify.hs
sed -n '378,410p' en-biscuit/src/En/Biscuit/Verify.hs
sed -n '206,241p' /Users/shinzui/Keikaku/hub/haskell/biscuit-haskell-project/biscuit-haskell/biscuit/src/Auth/Biscuit/Token.hs
sed -n '176,215p' /Users/shinzui/Keikaku/hub/haskell/biscuit-haskell-project/biscuit-haskell/biscuit/src/Auth/Biscuit/Datalog/Executor.hs
sed -n '224,260p' en-biscuit/test/Main.hs
```

Then edit `en-biscuit/test/Main.hs` only: add the six test functions from M1
and M2, register them in `main`, and extend the import list as needed
(`Data.IORef`, `queryRawBiscuitFacts`, `query`, `asOpen` if used). Blocks of
forged facts are built with the same `[block|…|]` quasiquoter the production
code uses, e.g. `addBlock [block|en_right("document", "secret", "view");|]
biscuit`. After each test function compiles, run:

```bash
cabal test en-biscuit
```

Expected output:

```text
en-biscuit tests PASS
Test suite en-biscuit-tests: PASS
```

If instead an assertion fails, the failure prints via the suite's `die`
helper, e.g.:

```text
en-biscuit test FAILED: forged en_right: widened request must be rejected, got Right <verified grant>
Test suite en-biscuit-tests: FAIL
```

That transcript is the contingency trigger — capture it verbatim into
Surprises & Discoveries and follow Milestone 3's protocol. Finish with a full
workspace build to confirm nothing else was disturbed:

```bash
cabal build all
```


## Validation and Acceptance

Acceptance is `cabal test en-biscuit` passing with all of the following
observable behaviors, each of which fails today's assumptions loudly if the
dependency regresses:

- For every forged fact (`en_right` object, `en_right` permission,
  `en_expires_at`, `en_revocation_id` shadowed and planted,
  `en_container_scope`, `en_subject`): the `trusting previous` control finds
  the fact; the un-annotated query does not; `verifyGrant` accepts the genuine
  request and rejects the widened request with the exact error named in the
  Plan of Work (`ResourceNotInScope`, `OperationNotAuthorized`, `Expired`,
  `Revoked`, `WrongSubject`).
- The planted-revocation-id scenario's `IORef` log is empty after
  verification: the forged id never reached the caller's revocation check.
- `authorizeBiscuit` with a non-`trusting` `allow if` policy over a forged
  fact returns `Left`; over the genuine authority fact returns `Right`.
- Attenuation direction: the narrowed token fails a request its parent passed
  (pre-existing `attenuationTests`, unchanged), and no combination of forged
  facts and holder-added checks makes any token pass a request its parent
  failed.
- No production module changed (verify with `git diff --stat` — only
  `en-biscuit/test/Main.hs` and this plan file), unless Milestone 3 was
  triggered and its protocol followed.

Interpreting results: every test failure here is a *security finding*, not a
flake — the tests use fixed keys and clocks and no IO beyond the library.
Success means the semantics are pinned: any future biscuit-haskell re-pin in
`cabal.project` that changes fact scoping turns the suite red.


## Idempotence and Recovery

The plan only adds deterministic tests; running them repeatedly is safe and
required. Fixed keys (`loadSecret`) and fixed clocks (`sampleExpiry`,
`verifyNow`, `afterExpiry`) make every run identical. If a positive control
fails (the forged fact is not even present), the attack construction is wrong
— fix the test, not the assertion; `grantFactsText`-style rendering or
`show`ing the parsed biscuit helps debug what the block actually contains. If
the `trusting previous` annotation is rejected by the quasiquoter, use the
authorizer-policy fallback described in M1 and record the deviation. Do not
weaken an exploit assertion to make it pass: a failing exploit assertion is
the discovery this plan exists to make, and Milestone 3 is its only sanctioned
response.


## Interfaces and Dependencies

No new dependencies and no new modules. Everything used is already in
`en-biscuit`'s test-suite dependency set (`en-biscuit/en-biscuit.cabal`,
`test-suite en-biscuit-tests`): `biscuit-haskell` (`Auth.Biscuit`:
`addBlock`, `mkBiscuit`, `parseB64`, `serializeB64`, `authorizeBiscuit`,
`authorizer`, `block`, `query`, `queryRawBiscuitFacts`, `newSecret`,
`parseSecretKeyHex`, `toPublic`), `containers`, `text`, `time`, `en-biscuit`,
`en-core`. `Data.IORef` is in `base`.

Functions that must exist at the end (all in `en-biscuit/test/Main.hs`, all
`:: IO ()`, all registered in `main`): `attenuationForgedRightTest`,
`attenuationForgedExpiryTest`, `attenuationForgedRevocationTest`,
`attenuationForgedScopeTest`, `attenuationForgedSubjectTest`,
`authorizerScopingTest`, `narrowingDirectionTest`.

Production interfaces exercised but not changed (unless M3 triggers):
`En.Biscuit.Verify.verifyGrant`, `En.Biscuit.Verify.attenuateGrant`,
`En.Biscuit.Mint.mintObjectGrant`/`mintScopedGrant`,
`En.Biscuit.Grant.grantBlock`. Signature note: if EP-55
(`docs/plans/55-support-key-rotation-and-unconditional-revocation-in-biscuit-grants.md`)
has already landed, `verifyGrant` takes an `IssuerKeySet` and `VerifyRequest`
has a `revokedBlockIds` field — call it accordingly (`singleKey` + a
`const (pure False)` block check); if it has not, use the single-`PublicKey`
signature shown in today's source. Either way the assertions are identical,
and whichever plan lands second mechanically updates the other's call sites.
