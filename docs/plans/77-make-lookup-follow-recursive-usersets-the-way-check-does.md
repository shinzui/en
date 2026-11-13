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
  revisions:
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-13T03:59:02Z
      mode: "update"
      note: "Validated against the engine; widened to indirect arrows and the skipRecursive guard, fixed the emit-window step, tightened convergence and fixtures"
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

Two neighbouring shapes fail for the same reason and are fixed by the same change (both were
reproduced while validating this plan; see Surprises & Discoveries):

- An arrow that recurses through a computed permission instead of directly
  (`permission inherited = parent->view` with `permission view = viewer | inherited`) is
  truncated the same silent way: lookup returns only the folder the user views directly.
- A directly recursive arrow combined with a recursive userset
  (`permission view = viewer | parent->view` on a `folder` whose `viewer` accepts
  `group#member`, with `group.member: user, group#member`) does not truncate; lookup fails
  every request with `ResolutionLimitExceeded` (HTTP 422), even when no group is nested, while
  check answers normally.

After this plan, lookup returns every object check allows for recursive usersets and arrows,
at any nesting depth within the evaluation budget, for direct and mutual recursion; when the
recursion cannot be finished it reports `ResolutionLimitExceeded` (depth budget) or an empty
`LookupTruncated` page (deadline) instead of a short answer; and a test in `en-core` proves
check and lookup agree over nested-group fixtures. Nothing changes for schemas without such
recursion.

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

These were found on 2026-11-12 while validating the plan against the working tree at commit
`b89cc7a`, by running the fixtures in GHCi (`cabal repl en-core-interface-tests`) against the
unchanged engine. No source file was changed.

- Observation: the Milestone 1 fixture fails exactly as predicted, and `lookupSubjects` is
  correct.
  Evidence (objects returned by lookup, then check per object):

  ```text
  alice view space    lookup [s0,s1]   check allows s0,s1,s2,s3
  bob   view space    lookup [s4]      check allows s4,s5
  alice member group  lookup [g1]      check allows g1,g2,g3
  bob   member group  lookup [g4]      check allows g4,g5 (and teams t1,t2)
  lookupSubjects user view space:s3 -> [alice]; space:s5 -> [bob]
  ```

- Observation: a directly recursive arrow plus a recursive userset makes lookup fail outright.
  With `folder { relation parent: folder; relation viewer: user, group#member;
  permission view = viewer | parent->view }` and `group.member: user, group#member`, lookup of
  alice's `view` folders returns `Left ResolutionLimitExceeded` while check allows all three
  folders. The cause is the `&& skipRecursive == Nothing` clause in `evalRelation`'s cycle
  guard: `evalRecursiveUserset` sets `skipRecursive` to compute its seeds, the flag stays set
  for every relation evaluated underneath, the guard is therefore off, and
  `(alice, group, member)` re-enters itself until `depth` reaches `maxDepth`. The fixpoint of
  Milestone 2 cannot be built on a guard that is sometimes off, so this is in scope.

- Observation: an arrow that recurses through a computed permission is silently truncated.
  With `permission inherited = parent->view` and `permission view = viewer | inherited`,
  alice a viewer of `folder:f1`, `f2` a child of `f1` and `f3` of `f2`, lookup returns `[f1]`
  and check allows `f1, f2, f3`. `evalTupleToUserset` only recognises the arrow fixpoint when
  `computedRelation == currentRelation`; here the current relation is `inherited`, so the
  revisit of `(alice, folder, view)` hits the guard and contributes nothing.

- Observation: a recursion that passes through an exclusion is truncated too, and it is the
  only shape where the paging window (step 6 of Milestone 2) matters. With
  `group { relation member: user, group#active; relation banned: user;
  permission active = member but not banned }`, alice a member of `g1`, `g1#active` a member
  of `g2`, `g2#active` of `g3`, `g3#active` of `g4`, and alice banned from `g3`, check allows
  `g1, g2` and denies `g3, g4`; lookup returns `[g1]`. The plan's original claim that the
  `group.member` lookup exercises the window was wrong: `member` is a plain relation
  (`This`), which never sees the window.

- Observation: cyclic data (adding `group:g1#member@group:g3#member` to the fixture) leaves
  lookup at `[s0,s1]` while check allows `s0..s3`. It terminates today; it must still
  terminate after the change.

- Observation: check's depth bound for nested groups, at the default `maxDepth = 25`: an
  allowed check through a chain of 23 groups succeeds and 24 fails with
  `ResolutionLimitExceeded`; a denied check succeeds at 22 and fails at 23. Lookup's nesting
  depth for the same question is constant (3), so its bound has to come from the round count.

- Observation: `en-core/test/Main.hs` does not import `En.LookupSubjects` and has no helper
  for it; only `en-core/conformance/Main.hs` uses it.


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

- Decision: The cycle guard in `evalRelation` becomes unconditional, and the arrow fixpoint
  keeps working by re-entering through `evalRewrite` instead of switching the guard off.
  Rationale: the `skipRecursive == Nothing` exception is what turns "recursive arrow plus
  nested groups" into `ResolutionLimitExceeded`, and a guard that is sometimes off cannot
  detect cycle heads. Keeping `expandRecursive` (which reads only the new frontier each round)
  preserves today's cost for directly recursive arrows, which is the shape the existing
  benchmark and the demo schema use. This replaces the earlier "leave it in place" wording of
  step 5.
  Date: 2026-11-12

- Decision: Two rounds are equal when they hold the same objects and, per object, the same
  decision with `Conditional` obligations compared as sets. A head that has not reached
  equality after `maxDepth` rounds fails with `ResolutionLimitExceeded`.
  Rationale: the set of objects only grows, so it settles; obligation lists are ordered
  (`dedupeObligations` keeps first occurrence) and their order can depend on the previous
  round, so comparing lists could report a difference that is only a reordering. The round
  bound keeps any remaining non-convergence loud rather than short. This narrows the claim in
  the previous entry: convergence is argued for object sets, and tested for decisions.
  Date: 2026-11-12

- Decision: When the request's top-level subproblem is a cycle head, the windowed first round
  is discarded and the iteration restarts with no emit window; the page is then cut by
  `pageLookup`, which already filters by the watermark and takes the limit.
  Rationale: a window truncates confirmation at `limit + 1` and drops everything at or below
  the watermark, so a windowed round fed back as an assumption loses objects (on a later page
  the first round is empty and the lookup "converges" on nothing). The price is that such
  lookups confirm every candidate on every page; that is accepted for correctness and noted in
  the user guide.
  Date: 2026-11-12

- Decision: Agreement between check and lookup is asserted only where neither returns
  `ResolutionLimitExceeded`.
  Rationale: check's depth grows with the chain under one object while lookup's bound is a
  round count over everything the subject reaches, so near the budget one can fail where the
  other answers. Both fail loudly; neither returns a short answer.
  Date: 2026-11-12


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
  `visited` (and no arrow step is being skipped), returns the empty map. `EvalState` is passed
  down as an argument and never returned, so anything a callee must tell its caller (such as
  "I used an assumption") has to travel in the result. `evalRelation` also fails with
  `ResolutionLimitExceeded` when `depth` (one per nested relation) reaches
  `budget.maxDepth`, which is 25 by default (`en-core/src/En/Budget.hs`). `evalThis` handles
  direct tuples: it reads the rows whose subject is the requested subject, then, for each
  allowed userset subject `T#r` of the relation, recursively evaluates `(subject, T, r)` with
  `evalRelation` and reads the rows whose subject is one of the resulting `T:x#r`. For
  `group.member: group#member` that recursive call is the very subproblem being evaluated, so it
  hits `visited` and contributes nothing: only groups the subject is a direct member of are
  ever used, which is the defect. `evalTupleToUserset` handles arrows (`parent->view`) and
  already contains a fixpoint for direct self-recursive arrows (`evalRecursiveUserset`,
  `expandRecursive`, guarded by `skipRecursive`); read it as the model of the iteration this
  plan generalizes. It works in two steps: `evalRecursiveUserset` re-evaluates the relation
  being evaluated with `skipRecursive` set, so the arrow branch returns nothing and the result
  is the "seeds" reachable without the arrow; `expandRecursive` then follows the arrow from the
  seeds, one frontier per round. The arrow is recognised only when the arrow's target relation
  is the relation being evaluated (`computedRelation == currentRelation`), and `skipRecursive`
  stays set for everything evaluated under the seeds, which disables the cycle guard there
  (see Surprises & Discoveries). `evalRewrite` dispatches on the rewrite and decides who gets
  the `EmitWindow`: `Union` and `Caveated` pass it on, `Intersection` and `Exclusion` use it in
  `confirmCandidates`, and `This`, `ComputedUserset` and arrows never see it.
  `confirmCandidates` runs a forward check on candidates for `Intersection` and `Exclusion`;
  with a window it skips candidates at or below the watermark and stops after `limit + 1`
  allowed ones. `pageLookup` applies the watermark and the limit again to the final list.
  Results are
  `type LookupObjects = Map ObjectRef LookupObject`, combined by `mergeObjects`, which keeps the
  stronger decision (`combineDecisions`).
- `en-core/src/En/Check.hs` is check. Its subproblem names a concrete object, so a nested
  group is a different subproblem at each level and recursion terminates correctly; its
  "a revisited subproblem contributes no members" rule is right for it.
- `en-core/src/En/LookupSubjects.hs` (the reverse question, "which subjects can reach this
  object?") keys its subproblems on `(object, relation)` and is not affected (confirmed by
  running it on the fixture); Milestone 1 adds one agreement case for it anyway as a guard.
  `en-core/test/Main.hs` does not import this module yet; `en-core/conformance/Main.hs` shows
  how to build a `LookupSubjectsRequest` and call `lookupSubjects`.
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

The helper compares `Conditional` obligations as sets, and it skips (and names) any pair where
either side returns `ResolutionLimitExceeded`; see the Decision Log.

Also assert the expected lookups directly: alice views `s0, s1, s2, s3`; bob views `s4, s5`. Add
the same pair of cases for `group` itself (`lookup` of groups alice is a `member` of must be
`g1, g2, g3`; bob's must be `g4, g5`), because there the recursive relation is the *top-level*
relation of the request. Add one `lookupSubjects` agreement case (users who can view `space:s3`
must be `alice`) as a guard on the reverse direction; this needs an `En.LookupSubjects` import
and a small helper in `en-core/test/Main.hs`, modelled on `en-core/conformance/Main.hs`.

Add four more fixtures, each a few tuples, each asserted with the same agreement helper. The
first three were run against the unchanged engine while validating this plan (see Surprises &
Discoveries for their current results):

1. Cyclic data: the fixture above plus `group:g1#member@group:g3#member`. Expected: alice still
   views exactly `s0, s1, s2, s3`, and the lookup terminates.
2. Arrow through a computed permission:

    ```text
    object user {}
    object folder {
      relation parent: folder
      relation viewer: user
      permission inherited = parent->view
      permission view = viewer | inherited
    }
    ```

   with `folder:f1#viewer@user:alice`, `folder:f2#parent@folder:f1`, `folder:f3#parent@folder:f2`.
   Expected: alice views `f1, f2, f3`.
3. Recursive arrow plus recursive userset:

    ```text
    object user {}
    object group {
      relation member: user, group#member
    }
    object folder {
      relation parent: folder
      relation viewer: user, group#member
      permission view = viewer | parent->view
    }
    ```

   with `group:g1#member@user:alice`, `group:g2#member@group:g1#member`,
   `folder:f1#viewer@group:g1#member`, `folder:f2#viewer@group:g2#member`,
   `folder:f3#parent@folder:f1`. Expected: alice views `f1, f2, f3`.
4. Recursion through an exclusion, which is the case that exercises the emit window:

    ```text
    object user {}
    object group {
      relation member: user, group#active
      relation banned: user
      permission active = member but not banned
    }
    ```

   with `group:g1#member@user:alice` and `group:gN+1#member@group:gN#active` for N = 1..3.
   Expected: alice is `active` on `g1, g2, g3, g4`, and paging with `LookupLimit 1` returns
   those four over four pages, in key order, ending `LookupExhausted`. With
   `group:g3#banned@user:alice` added, expected `g1, g2` only (check denies `g3` and `g4`).

Add one caveated cycle so convergence of decisions is tested, not only of object sets: reuse a
caveat already defined for the existing caveated-group cases in `en-core/test/Main.hs` (search
for `caveatedGroupTuples`), put it on two membership tuples that form a cycle
(`group:a#member@group:b#member` and `group:b#member@group:a#member`, both caveated, plus an
uncaveated `group:a#member@user:alice`), and assert with an empty `CaveatContext` that lookup
returns and agrees with check on `a` and `b`. If check and lookup turn out to order the same
obligations differently, that is why the helper compares them as sets; if they differ in
content, stop and record it in Surprises & Discoveries before continuing.

Acceptance: `cabal test en-core-interface-tests` fails, and the failures are exactly the new
recursive cases: alice's `s2`, `s3`; bob's `s5`; alice's groups `g2`, `g3`; bob's group `g5`;
the cyclic-data case; `f2`, `f3` of fixture 2; all of fixture 3 (today
`Left ResolutionLimitExceeded`); and `g2..g4` of fixture 4. The `lookupSubjects` case and every
pre-existing case pass. The suite is a single sequence of assertions that stops at the first
failure, so to see every failure in one run make the new cases collect their mismatches and
report them together. Record the failing output in Progress.
Do not commit a red suite to `master`: commit Milestone 1 together with Milestone 2, or mark the
new cases as expected failures in a way the suite reports, and say which in the Decision Log.

### Milestone 2: evaluate recursive subproblems to a fixpoint

Replace "a revisited subproblem contributes nothing" in `evalRelation` with "a revisited
subproblem contributes its current approximation, and the first subproblem on the cycle (the
cycle head) repeats until its result stops growing". Concretely:

1. Give `EvalState` a map of assumptions, `assumptions :: Map Subproblem LookupObjects`. When
   `evalRelation` meets a subproblem that is in `visited`, it returns the assumption for it
   (empty if none) instead of `Map.empty`, and reports that it did so. The guard is
   unconditional: delete the `&& skipRecursive == Nothing` clause (step 5 keeps the arrow
   fixpoint working without it).
2. Report it by widening the internal result type. Today every evaluator returns
   `Either EnError LookupObjects`. Introduce a record for internal results, for example
   `data Evaluated = Evaluated {objects :: LookupObjects, assumed :: Set Subproblem}`, where
   `assumed` lists the in-progress subproblems whose assumption this result depended on. Carry
   `assumed` with set union through every place results are combined or transformed:
   `mergeObjects` and `mergeAllObjects`, the branches of `evalRewrite`, `evalThis` (the
   userset results it reads rows for), `evalTupleToUserset` (including the seeds and
   `expandRecursive`), `confirmCandidates` (its output depends on the candidates it was given)
   and `applyRewriteCaveat`. Dropping it at any one of these makes a provisional result look
   final. Keep the public types (`LookupPage`, `LookupObject`) unchanged; convert at
   `runLookup`.
3. In `evalRelation`, after evaluating subproblem `p`: if `p` is not in the result's `assumed`
   set, the result is final for `p`; return it with `assumed` unchanged. If it is, `p` is a cycle
   head: evaluate `p` again with `assumptions[p]` set to the result (the state is an argument,
   so this is a local loop that passes a modified state down), repeating until a round equals
   the previous one (step 7), then return the converged result with `p` removed from `assumed`.
   Each round's result replaces the assumption; it is computed afresh from the store and the
   previous assumption, not merged into it. Results that still mention an outer head stay
   provisional and converge when that head does; an inner head restarts from the empty
   assumption on each round of an outer one, which is correct and costs rounds multiplied by
   rounds.
4. Bound the iteration with a round counter per head: call `requireBudget deadline` before each
   round (as `expandRecursive` does), and when the counter reaches `budget.maxDepth` without
   convergence return `Left ResolutionLimitExceeded`, never a partial set. A chain of N nested
   groups needs N + 1 rounds (N to grow, one to see no change), so the default budget of 25
   resolves chains of up to 24, next to check's 23 (see Surprises & Discoveries). The nesting
   `depth` is separate and does not grow with rounds.
5. Keep the arrow fixpoint for directly recursive arrows, but stop it from disabling the guard.
   In `evalRecursiveUserset`, compute the seeds by calling `evalRewrite` on the current
   relation's own rewrite (look it up with `lookupRelation graph objectType currentRelation`;
   pass `Nothing` for the window) with `skipRecursive` set, instead of calling `evalRelation`
   on the subproblem that is already in `visited`. Then have `evalRelation` clear
   `skipRecursive` in the state it passes down whenever it descends into a new subproblem, so
   the skip applies only inside the rewrite of the relation that asked for it. Arrows that
   recurse indirectly (fixture 2 of Milestone 1) are not special-cased: their revisit hits the
   guard and they converge through the general mechanism. If, after this, removing
   `skipRecursive`, `evalRecursiveUserset` and `expandRecursive` altogether still passes every
   test and does not regress `lookup/reachable-spaces` in the benchmark, you may remove them;
   record that in the Decision Log.
6. The top-level relation of a request is evaluated with an `EmitWindow` (a watermark and a
   confirmation budget used for paging). A window must not truncate a round whose output feeds
   the next round. Evaluate the top-level subproblem with the window as today; if its result
   says it is a cycle head, discard that result and run the iteration of step 3 from the empty
   assumption with `Nothing` for the window. No separate "apply the window" step is needed
   afterwards: `pageLookup` already drops objects at or below the watermark and takes the
   limit. Fixture 4 of Milestone 1, paged with `LookupLimit 1`, exercises this; the
   `group.member` lookup does not, because a plain relation never sees the window. Inner
   subproblems always get `Nothing` already.
7. Equality between rounds: the same object keys, and per object the same decision, comparing
   `Conditional` obligations as sets (for example by mapping each decision to
   `Maybe (Set CaveatObligation)`; `CaveatObligation` in `en-core/src/En/Decision.hs` derives
   `Ord`). Do not compare the `LookupObjects` maps with `==`: obligation lists are ordered and
   a reordering is not a change.

Non-recursive schemas never revisit a subproblem, so their `assumed` sets stay empty and they
take exactly one pass, as today. Check that claim with the benchmarks below rather than assume
it.

Recursive lookups get slower by design: each round re-reads the direct rows and the rows for
every object in the assumption, and re-runs any confirmation inside the cycle, so a two-level
nesting costs about three passes. Measure it rather than guess: add one benchmark to
`en-core/bench/Main.hs` next to `lookup/reachable-spaces` that looks up spaces through two
levels of nested groups (a few hundred spaces, in-memory store like its neighbours) and record
its time in Progress. There is no pre-change number to compare with, because the pre-change
answer is wrong; the number is the baseline for any later optimisation (reading only the
objects added in the last round, as `expandRecursive` does), which is out of scope here.

Acceptance: `cabal test en-core-interface-tests en-core-conformance` passes, including every
Milestone 1 case; `cabal build all` has no new warnings; `cabal bench en-core-bench` shows the
existing lookup benchmarks (`lookup/reachable-spaces`, which uses a directly recursive arrow,
and `lookup/wide-fanout`) within the bench's noise of their pre-change values, and the new
nested-group benchmark's time is recorded (all in Progress).

### Milestone 3: prove it end to end and document it

Add a scenario to `en-postgres/integration-test/Main.hs` that writes the Milestone 1 tuples into
PostgreSQL and asserts the same lookups, so the proof does not rest on the in-memory store (ADR
3). Add a request pair to the Hurl suite (`en-servant/test/hurl/lookups.hurl`) only if the
suite's demo schema can express a recursive userset; otherwise rely on the server-level check
below.

Then run the server-level check that found the defect: change `en-server/loadbench/Fixture.hs`
to grant the first 5,000 spaces to the *outer* group `g(50 + I mod 50)#member` instead of the
inner one (two levels; `en-server/loadbench/fixtures/bench.en` already lets `space.viewer`
accept `group#member` and needs no change) and confirm `cabal run en-server-loadbench --
run --smoke` passes with `lookupExpectedCount = 105`. Only keep that fixture change if the owner
of `docs/masterplans/12-serve-several-isolated-tenants-from-one-en-server.md` agrees, because it
changes the workload the recorded baseline was measured on; otherwise revert it and record the
run as evidence only.

Update `docs/user/queries-and-writes.md` under "Lookup" with one paragraph: lookup follows
recursive usersets (nested groups) and recursive arrows to any depth the evaluation budget
allows and agrees with check; a recursion deeper than the budget is reported as an error
(`ResolutionLimitExceeded`, HTTP 422 `resolution_limit_exceeded`), not as a short result; and a
permission that is itself recursive through an intersection or exclusion confirms all its
candidates on every page, so it pages more slowly than other lookups.
Update the Surprises & Discoveries entry in
`docs/plans/72-build-an-en-server-load-benchmark-and-record-the-single-tenant-baseline.md` and
the corresponding entry in the MasterPlan (which already names this plan as the follow-up) to
say the defect is fixed, and correct the comment at the top of
`en-server/loadbench/Fixture.hs`, which describes the defect as current behaviour.

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
- The four extra fixtures of Milestone 1 return what it lists: the cyclic-data lookup
  terminates with `s0..s3`; the indirect arrow returns `f1, f2, f3`; the recursive arrow with
  nested groups returns `f1, f2, f3` instead of `ResolutionLimitExceeded`; and the recursion
  through an exclusion returns `g1..g4` (or `g1, g2` with the ban). The caveated cycle
  converges and agrees with check.
- Making the recursion deeper than `maxDepth` returns `ResolutionLimitExceeded`, not a page
  that omits the deep objects: with `lookupEngineBudgeted (defaultEvaluationBudget & #maxDepth
  .~ 5)`, alice's `view` lookup over a chain of three nested groups succeeds and over a chain
  of ten fails with `Left ResolutionLimitExceeded`. (The budget cannot go below 3 here, because
  `view`, `viewer` and `member` nest three deep before any round is counted.)
- Paging is unaffected: the alice `view` lookup with `LookupLimit 1` returns the same four
  spaces over four pages, in key order, ending `LookupExhausted`; and so does the `active`
  lookup of fixture 4, which is the case where the emit window could lose objects.
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


## Revision Notes

- 2026-11-12: Validated against the working tree by running the fixtures against the unchanged
  engine. The predicted failures are exact. The revision widens scope to two neighbouring
  defects with the same cause (indirectly recursive arrows are truncated; a recursive arrow
  combined with nested groups fails with `ResolutionLimitExceeded`), makes the cycle guard
  unconditional and re-scopes `skipRecursive` (step 5), corrects the emit-window step and the
  fixture that exercises it (step 6), defines round equality and the round bound precisely
  (steps 4 and 7), adds fixtures for cyclic data, exclusion and a caveated cycle, adds a
  nested-group benchmark, and corrects small factual points (no `En.LookupSubjects` helper in
  the test suite; `bench.en` needs no change).
