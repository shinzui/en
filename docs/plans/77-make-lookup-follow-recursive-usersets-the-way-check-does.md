---
id: 77
slug: make-lookup-follow-recursive-usersets-the-way-check-does
title: "Make lookup follow recursive usersets the way check does"
kind: exec-plan
created_at: 2026-11-13T03:40:23Z
intention: "intention_01m79fsjm3ecptm2kgr88x50d5"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-13T03:40:23Z
---

# Make lookup follow recursive usersets the way check does

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

`lookup` answers "which objects of this type can this subject reach with this permission?"
and `check` answers "can this subject reach this one object?". They must agree: an object is in
a lookup's result exactly when a check of it is allowed (or conditional, with the same
obligations). Today they disagree whenever a relation's subjects recurse through the same
object type, which is how nested groups are modelled:

```text
object user {}
object group {
  relation member: user, group#member
}
object space {
  relation viewer: user, group#member
  permission view = viewer
}
```

With `user:alice` a member of `group:inner`, `group:inner#member` a member of `group:outer`,
and `group:outer#member` a viewer of `space:s1`, `POST /v1/check` for alice viewing `space:s1`
says `allowed`, but `POST /v1/lookup` for the spaces alice can view leaves `space:s1` out. The
same truncation happens with mutual recursion (`group.member` accepting `team#member` and
`team.member` accepting `group#member`). An application that builds a list page from `lookup`
and guards the detail page with `check` shows users less than they may see, and nothing
reports the omission: the page says `exhausted`.

After this plan, lookup returns every object check allows for recursive usersets, at any
nesting depth within the evaluation budget, for direct and mutual recursion; it reports a
budget error instead of a short answer when the recursion cannot be finished; and a test in
`en-core` proves check and lookup agree over nested-group fixtures. Nothing changes for schemas
without such recursion.

The defect was found while building the load benchmark of
`docs/plans/72-build-an-en-server-load-benchmark-and-record-the-single-tenant-baseline.md`
(Surprises & Discoveries there), whose fixture was shaped to avoid it.


## Progress

- [ ] Milestone 1: failing agreement tests in `en-core` reproduce the defect for self-recursive
      and mutually recursive usersets; `cabal test en-core-interface-tests` fails on exactly
      those cases and passes everything else.
- [ ] Milestone 2: lookup evaluates recursive usersets to a fixpoint; the agreement tests and
      every existing `en-core`, `en-postgres` and `en-servant` suite pass; lookup benchmarks for
      non-recursive schemas show no regression.
- [ ] Milestone 3: the fix is proved through PostgreSQL and the HTTP server, the user guide
      states what lookup guarantees about recursion, and the ADR or plan records are updated.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Fix the general case (any cycle through a `(subject, objectType, relation)`
  subproblem), not only direct self-recursion.
  Rationale: the arrow path already special-cases direct self-recursion
  (`evalRecursiveUserset` inside `evalTupleToUserset`), and copying that special case to
  usersets would leave mutual recursion (`group` ↔ `team`) truncated in exactly the same silent
  way. A cycle-head fixpoint covers both with one mechanism.
  Date: 2026-11-13

- Decision: The fixpoint iterates candidate sets only in the monotone positions (direct
  tuples, computed usersets, arrows, unions, caveat wrappers); intersections and exclusions keep
  confirming their candidates with a forward check, as they already do.
  Rationale: union-style candidate generation only grows as assumptions grow, so iteration
  from the empty set converges; non-monotone operators are already made exact by
  `confirmCandidates`, which runs `check`, and `check` handles recursion correctly.
  Date: 2026-11-13


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

`en` is a relationship-based authorization toolkit in Haskell (GHC 9.12.4, `cabal`; enter the
development shell with `nix develop` or `direnv allow` at the repository root). The engine is
the `en-core` package. Terms used here:

- A **tuple** is one stored relationship, `object#relation@subject`, for example
  `group:outer#member@group:inner#member`. A **userset subject** is a subject of the form
  `type:id#relation` ("everyone who has `relation` on `type:id`"); `En.Tuple.SubjectSet` in
  code.
- A **recursive userset** is a relation that accepts a userset of its own object type and
  relation (`group.member: group#member`), directly or through other relations
  (`group.member: team#member`, `team.member: group#member`).
- A **subproblem** in lookup is the triple `(subject, objectType, relation)`: "which objects of
  this type does this subject have this relation on?". It is a set-valued question about a
  whole type, unlike check's subproblem, which names one object.
- A **fixpoint** is the result of repeating a computation, feeding each round's answer back in,
  until the answer stops changing.

The files that matter:

- `en-core/src/En/Lookup.hs` is the lookup engine. `evalRelation` evaluates a subproblem; it
  keeps a `visited :: Set Subproblem` in `EvalState` and, when it meets a subproblem already in
  `visited` (and no arrow step is being skipped), returns the empty map. `evalThis` handles
  direct tuples: it reads the rows whose subject is the requested subject, then, for each
  allowed userset subject `T#r` of the relation, recursively evaluates `(subject, T, r)` with
  `evalRelation` and reads the rows whose subject is one of the resulting `T:x#r`. For
  `group.member: group#member` that recursive call is the very subproblem being evaluated, so it
  hits `visited` and contributes nothing: only groups the subject is a direct member of are
  ever used, which is the defect. `evalTupleToUserset` handles arrows (`parent->view`) and
  already contains a fixpoint for direct self-recursive arrows (`evalRecursiveUserset`,
  `expandRecursive`, guarded by `skipRecursive`); read it as the model of the iteration this
  plan generalizes. `evalRewrite` dispatches on the rewrite; `confirmCandidates` runs a forward
  check on candidates for `Intersection` and `Exclusion`. Results are
  `type LookupObjects = Map ObjectRef LookupObject`, combined by `mergeObjects`, which keeps the
  stronger decision (`combineDecisions`).
- `en-core/src/En/Check.hs` is check. Its subproblem names a concrete object, so a nested
  group is a different subproblem at each level and recursion terminates correctly; its
  "a revisited subproblem contributes no members" rule is right for it.
- `en-core/src/En/LookupSubjects.hs` (the reverse question, "which subjects can reach this
  object?") keys its subproblems on `(object, relation)` and is not affected; Milestone 1 adds
  one agreement case for it anyway, so the claim is tested rather than argued.
- `en-core/test/Main.hs` is the interface test suite (`en-core-interface-tests`). It runs the
  engine against the in-memory store (`runTupleStoreInMemory` from
  `en-core/src/En/Conformance/Kikan.hs`) with helpers `check`, `lookupEngine`, `lookupRequest`,
  `lookupPage` and `allowed`; schemas are written with the `[schema| … |]` quasi-quoter or
  parsed with `En.Schema.Parse.parseSchema`. Existing lookup cases sit near the assertion
  "lookup returns direct and recursive view spaces".
- `en-core/bench/Main.hs` is the engine micro-benchmark (`cabal bench en-core-bench`).
- `en-postgres/integration-test/Main.hs` (`en-postgres-integration-tests`) runs the engine over
  real PostgreSQL via `ephemeral-pg`.
- `en-server/loadbench/` holds the HTTP load benchmark; its fixture comment in
  `en-server/loadbench/Fixture.hs` explains how it avoids this defect.
- `docs/user/queries-and-writes.md` (section "Lookup") documents lookup for users.

Relevant ADRs: [ADR 3](../adr/0003-the-in-memory-store-is-for-tests-and-demos-only.md) says the
in-memory store is for tests and demos only, which is why Milestone 3 repeats the proof over
PostgreSQL. No other ADR bears on lookup's evaluation.


## Plan of Work

### Milestone 1: reproduce the defect as a failing agreement test

Add to `en-core/test/Main.hs` a small nested-groups fixture and an agreement assertion.

The schema is the one under Purpose plus a mutual pair:

```text
object user {}
object team {
  relation member: user, group#member
}
object group {
  relation member: user, group#member, team#member
}
object space {
  relation viewer: user, group#member
  permission view = viewer
}
```

Tuples: `group:g1#member@user:alice`, `group:g2#member@group:g1#member`,
`group:g3#member@group:g2#member` (three levels of direct recursion); `team:t1#member@user:bob`,
`group:g4#member@team:t1#member`, `team:t2#member@group:g4#member`,
`group:g5#member@team:t2#member` (mutual recursion, two turns); and one space per group as its
only viewer: `space:s1#viewer@group:g1#member` through `space:s5#viewer@group:g5#member`, plus
`space:s0#viewer@user:alice` as a direct grant.

The agreement assertion: for every user in the fixture and every space, `check` for
`view` is `Allowed` exactly when `lookup` for that user's `view` spaces contains the space with
an `Allowed` decision. Write it as one helper that computes both sides and reports the
difference by name, so a failure reads like:

```text
lookup/check disagree for user:alice view space: check allows [space:s2,space:s3] that lookup omits
```

Also assert the expected lookups directly: alice views `s0, s1, s2, s3`; bob views `s4, s5`. Add
the same pair of cases for `group` itself (`lookup` of groups alice is a `member` of must be
`g1, g2, g3`), because there the recursive relation is the *top-level* relation of the request,
which is evaluated with an emit window (see Milestone 2). Add one `lookupSubjects` agreement case
(users who can view `space:s3` must be `alice`) as a guard on the reverse direction.

Acceptance: `cabal test en-core-interface-tests` fails, and the failures are exactly the new
recursive cases (alice's `s2`, `s3`; bob's `s5`; alice's groups `g2`, `g3`); the
`lookupSubjects` case and every pre-existing case pass. Record the failing output in Progress.
Do not commit a red suite to `master`: commit Milestone 1 together with Milestone 2, or mark the
new cases as expected failures in a way the suite reports, and say which in the Decision Log.

### Milestone 2: evaluate recursive subproblems to a fixpoint

Replace "a revisited subproblem contributes nothing" in `evalRelation` with "a revisited
subproblem contributes its current approximation, and the first subproblem on the cycle (the
cycle head) repeats until its result stops growing". Concretely:

1. Give `EvalState` a map of assumptions, `assumptions :: Map Subproblem LookupObjects`. When
   `evalRelation` meets a subproblem that is in `visited`, it returns the assumption for it
   (empty if none) instead of `Map.empty`, and reports that it did so.
2. Report it by widening the internal result type. Today every evaluator returns
   `Either EnError LookupObjects`. Introduce a record for internal results, for example
   `data Evaluated = Evaluated {objects :: LookupObjects, assumed :: Set Subproblem}`, where
   `assumed` lists the in-progress subproblems whose assumption this result depended on. Merge
   `assumed` with set union wherever results are merged (`mergeObjects`, `mergeAllObjects`, the
   branches of `evalRewrite`, `evalThis`, `evalTupleToUserset`). Keep the public types
   (`LookupPage`, `LookupObject`) unchanged; convert at `runLookup`.
3. In `evalRelation`, after evaluating subproblem `p`: if `p` is not in the result's `assumed`
   set, the result is final for `p`; return it with `assumed` unchanged. If it is, `p` is a cycle
   head: set `assumptions[p]` to the result and evaluate `p` again, repeating until the objects
   and their decisions are equal to the previous round's, then return the converged result with
   `p` removed from `assumed`. Results that still mention an outer head stay provisional and
   converge when that head does.
4. Bound the iteration. Each round calls `requireBudget deadline` (as `expandRecursive` does
   per round) and counts against `maxDepth`; exceeding it returns
   `Left ResolutionLimitExceeded`, never a partial set. Candidate sets only grow from round to
   round in the monotone positions, so in a finite store the loop ends; the bound is for the
   budget, not correctness.
5. Leave the existing arrow fixpoint (`skipRecursive`, `evalRecursiveUserset`) in place unless
   the general mechanism makes it redundant *and* the existing arrow tests still pass without it;
   if you remove it, record that in the Decision Log.
6. The top-level relation of a request is evaluated with an `EmitWindow` (a watermark and a
   confirmation budget used for paging). A window must not truncate a round whose output feeds
   the next round. When the top-level subproblem turns out to be a cycle head, iterate without
   the window and apply it once to the converged result. The `group` lookup case from
   Milestone 1 exercises this.
7. Equality between rounds compares object keys and decisions; `LookupObject` and
   `CheckDecision` (`en-core/src/En/Decision.hs`) both derive `Eq`, so `LookupObjects` values
   compare directly.

Non-recursive schemas never revisit a subproblem, so their `assumed` sets stay empty and they
take exactly one pass, as today. Check that claim with the benchmarks below rather than assume
it.

Acceptance: `cabal test en-core-interface-tests en-core-conformance` passes, including every
Milestone 1 case; `cabal build all` has no new warnings; `cabal bench en-core-bench` shows the
lookup benchmarks for non-recursive schemas within the bench's noise of their pre-change values
(record both in Progress).

### Milestone 3: prove it end to end and document it

Add a scenario to `en-postgres/integration-test/Main.hs` that writes the Milestone 1 tuples into
PostgreSQL and asserts the same lookups, so the proof does not rest on the in-memory store (ADR
3). Add a request pair to the Hurl suite (`en-servant/test/hurl/lookups.hurl`) only if the
suite's demo schema can express a recursive userset; otherwise rely on the server-level check
below.

Then run the server-level check that found the defect: change
`en-server/loadbench/fixtures/bench.en` and `en-server/loadbench/Fixture.hs` back to granting the
first 5,000 spaces to *outer* groups (two levels) and confirm `cabal run en-server-loadbench --
run --smoke` passes with `lookupExpectedCount = 105`. Only keep that fixture change if the owner
of `docs/masterplans/12-serve-several-isolated-tenants-from-one-en-server.md` agrees, because it
changes the workload the recorded baseline was measured on; otherwise revert it and record the
run as evidence only.

Update `docs/user/queries-and-writes.md` under "Lookup" with one paragraph: lookup follows
recursive usersets (nested groups) to any depth the evaluation budget allows and agrees with
check; a recursion deeper than the budget is reported as an error, not as a short result.
Update the Surprises & Discoveries entry in
`docs/plans/72-build-an-en-server-load-benchmark-and-record-the-single-tenant-baseline.md` and
the corresponding entry in the MasterPlan to point at this plan as the fix.

Acceptance: `cabal test en-postgres-integration-tests` passes with the new scenario; the
loadbench smoke run with the two-level fixture passes; the guide states the guarantee.


## Concrete Steps

From the repository root, inside the development shell:

```bash
cabal build en-core
cabal test en-core-interface-tests
```

After Milestone 1 the suite fails on the new cases only, for example:

```text
lookup/check disagree for user:alice view space: check allows [space:s2,space:s3] that lookup omits
```

Record benchmark numbers before changing `En.Lookup` so there is something to compare with:

```bash
cabal bench en-core-bench 2>&1 | tee .dev/lookup-bench-before.txt
```

After Milestone 2:

```bash
cabal test en-core-interface-tests en-core-conformance
cabal bench en-core-bench 2>&1 | tee .dev/lookup-bench-after.txt
cabal build all
cabal test en-servant-tests
```

After Milestone 3:

```bash
cabal test en-postgres-integration-tests
cabal build en-server:exe:en-server en-server-loadbench
cabal run -v0 en-server-loadbench -- run --smoke
nix fmt
```

Commit with Conventional Commits and the plan's trailers:

```text
fix(en-core): make lookup follow recursive usersets to a fixpoint

ExecPlan: docs/plans/77-make-lookup-follow-recursive-usersets-the-way-check-does.md
Intention: intention_01m79fsjm3ecptm2kgr88x50d5
```


## Validation and Acceptance

The plan is accepted when:

- For the Milestone 1 fixture, lookup for alice's `view` spaces is exactly `s0, s1, s2, s3`, for
  bob's is `s4, s5`, and for alice's `member` groups is `g1, g2, g3`, each `Allowed`; and the
  agreement helper reports no difference between check and lookup for any fixture user.
- Making the recursion deeper than `maxDepth` (for example a chain of groups longer than the
  budget in a test with a small `EvaluationBudget`, using `lookupEngineBudgeted`) returns
  `ResolutionLimitExceeded`, not a page that omits the deep objects.
- Paging is unaffected: the alice `view` lookup with `LookupLimit 1` returns the same four
  spaces over four pages, in key order, ending `LookupExhausted`.
- Every pre-existing test in `en-core`, `en-postgres` and `en-servant` passes unchanged, and the
  non-recursive lookup benchmarks show no regression beyond noise.
- The PostgreSQL scenario passes, and the user guide states the guarantee.


## Idempotence and Recovery

All tests build their own in-memory or ephemeral PostgreSQL state and can be re-run freely. The
change is confined to `en-core/src/En/Lookup.hs` and tests; reverting that file's commit
restores today's behaviour. No migration, wire type or configuration changes. The loadbench
fixture experiment in Milestone 3 is reverted unless explicitly kept.


## Interfaces and Dependencies

No new libraries. The public API of `En.Lookup` (`lookup`, `lookupWithDeadline*`,
`lookupCached*`, `LookupRequest`, `LookupPage`, `LookupObject`, `LookupState`, cursors) must not
change shape; only internal evaluator types change. The cursor encoding (`encodeLookupCursor`,
`decodeLookupCursor`) must keep decoding cursors issued before the change. `en-servant` and
`en-server` depend on `En.Lookup` only through that public API and need no edits.

This plan is independent of
`docs/masterplans/12-serve-several-isolated-tenants-from-one-en-server.md`, which excludes
changes to `en-core`; the only coupling is the optional loadbench fixture change in Milestone 3.
