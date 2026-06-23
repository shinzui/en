---
id: 17
slug: strengthen-the-lookup-spike-and-add-performance-regression-benchmarks
title: "Strengthen the lookup spike and add performance-regression benchmarks"
kind: exec-plan
created_at: 2026-06-23T16:37:01Z
intention: "intention_01kvv5mecvechb6c6jv3p3zv4a"
master_plan: "docs/masterplans/3-harden-en-correctness-fixes-lookup-streaming-and-performance-benchmarks.md"
---

# Strengthen the lookup spike and add performance-regression benchmarks

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`en` (縁, "the ties that bind") is a relationship-based access-control engine — a Haskell
library that answers the question "may THIS subject do THIS to THIS object, given how they are
related?" The single most expensive operation it offers is `lookup`: the *reverse* question
"which objects can this subject reach?" Before the engine was built, the project ran a
throwaway performance probe (a "spike") to check that `lookup`, used in the shape the engine
actually uses it, stays fast at realistic data sizes. That spike reported green numbers and the
engine was built on the strength of them.

A later review found the spike's green numbers do not prove what they claim, in four concrete
ways, and that nothing guards the real engine against future performance regressions. This plan
fixes both problems. After this change:

1. The spike harness (`en-postgres/lookup-spike/Main.hs`) actually exercises the expensive
   "exclusion" query shape it claimed to measure, so its reassuring "exclusion is as cheap as
   union" conclusion is either confirmed by a query that really does the work, or replaced with
   the true, measurably-higher cost. You can see this by running the spike and observing that the
   `intersection-exclusion` rows in its output table now differ measurably from the `union` rows.
2. The spike runs at the 10,000,000-activity-row scale the spike spec set as its pass bar (it
   previously ran only 1,000,000), and that result is appended to the spec document
   `docs/spec/0002-lookup-spike.md`. You can see this by reading the new table in that file.
3. The spike's reported "p95" (95th-percentile latency, the latency that 95% of requests beat)
   is a real tail estimate over many samples, instead of "the slowest of 7 runs." You can see
   this by reading the harness and confirming each query is timed dozens of times with a discarded
   warm-up run.
4. The spike includes a "large reachable set" case — a subject deliberately wired to reach
   *many* spaces — so the harness proves the reachable label-set staying small is a *property of
   the data shape*, not an artifact of a generator that always produces 24 spaces. You can see
   this by observing a row whose `spaces` count is large and checking whether `lookup` latency
   degrades.

5. A durable benchmark suite (`en-core/bench/Main.hs`, built with the `tasty-bench` library)
   measures the *real* engine entry points — `En.Check.check`, `En.Lookup.lookup`, and the
   consistency operations (`En.Postgres.Revision.encodeToken`/`decodeToken` and
   `comparePgSnapshot`) — records a committed baseline, and fails the build if any of those paths
   regresses past a chosen percentage. You can see this work by deliberately slowing one
   benchmarked function and observing the benchmark command exit non-zero with a "X% slower than
   baseline" message.

The spike fixes retire a false-confidence risk; the benchmark suite turns a one-time probe into a
standing guard so a future change that silently slows authorization cannot merge unnoticed.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Milestone 1 — Spike fix: make the `intersection-exclusion` variant actually traverse a
      `blocked` exclusion in `lookupLabelsCte`, and re-measure. Completed 2026-06-23.
- [x] Milestone 2 — Spike fix: widen percentile sampling (more runs, discard a warm-up) so the
      reported p95 is a real tail estimate. Completed 2026-06-23.
- [x] Milestone 3 — Spike fix: add a large-reachable-set subject case proving smallness is a
      property, not a constant. Completed 2026-06-23.
- [x] Milestone 4 — Spike fix: run the 10,000,000-activity-row sweep and append the result table
      to `docs/spec/0002-lookup-spike.md`. Completed 2026-06-23.
- [x] Milestone 5 — Benchmarks: add `tasty-bench` suites for `check`/`lookup` and consistency
      operations; verify they run and emit CSV baselines. Completed 2026-06-23.
- [x] Milestone 6 — Benchmarks: record committed CSV baselines and wire CI regression gates
      (`--baseline <committed.csv> --fail-if-slower <pct>`). Completed 2026-06-23.
- [x] Re-record the baseline against the fixed engine once EP-14 / EP-15 / EP-16 have landed, and
      re-run the 10M sweep against the streaming `lookup`. Completed 2026-06-23.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The spike's `intersection-exclusion` shape inserts `blocked` edges
  (`en-postgres/lookup-spike/Main.hs:292-298`) but the recursive query that is actually timed
  (`lookupLabelsCte`, `en-postgres/lookup-spike/Main.hs:411-457`) never references
  `relation = 'blocked'`. The union and exclusion variants therefore execute the *identical* SQL,
  so the table's near-equal numbers across shapes are an artifact, not evidence that exclusion is
  cheap. This is the headline finding the plan must correct. _(2026-06-23)_

- The 10M fixed-spike run is green for the bounded kikan shape but red for deliberately large
  reachable sets: the 1000-space scenario produced lookup p95 below 25 ms, but read-path p95 around
  876-906 ms, well above the 50 ms bar. This proves label-set smallness is load-bearing.
  _(2026-06-23)_

- Cabal rejects an `en-core` benchmark that depends on `en-postgres`, because `en-postgres` already
  depends on `en-core`. The benchmark suite is therefore split by package: `en-core-bench` covers
  `check`/`lookup`, and `en-postgres-bench` covers pure consistency-token/snapshot functions.
  _(2026-06-23)_


## Decision Log

Record every decision made while working on the plan.

- Decision: Use `tasty-bench` (registered in this machine's package mirror as
  `Bodigrim/tasty-bench`) as the benchmark library, not `criterion` or `gauge`.
  Rationale: It is featherweight, integrates with the `tasty` test framework the project already
  uses, and ships exactly the regression-gate features this plan needs out of the box: write a
  baseline with `--csv FILE`, compare a later run against it with `--baseline FILE`, and fail the
  run when a benchmark is more than N% slower with `--fail-if-slower N`. No external comparison
  tooling is required.
  Date: 2026-06-23

- Decision: Record the *committed* regression baseline only after the EP-14, EP-15, and EP-16
  engine fixes have landed (consistency hardening, generalized caveats + unified decision algebra,
  and streaming `lookup`), not against today's tree.
  Rationale: A baseline is only useful if it reflects the engine we intend to keep. EP-16 replaces
  the eager-compute-then-cap `lookup` with a streaming, resumable traversal; benchmarking the
  about-to-be-replaced implementation would bake an obsolete number into CI. The benchmark
  *scaffolding* (the suite, the targets, the CI wiring) can be built and exercised now against the
  current tree; the *numbers* committed as the guard are re-recorded after the fixes. See the
  soft-dependency note at the end of this plan.
  Date: 2026-06-23

- Decision: Place the benchmark suite in `en-core` (`en-core/bench`), not in `en-postgres`.
  Rationale: `check`, `lookup`, and the decision algebra live in `en-core` and can be driven
  entirely against the in-memory `TupleStore` / `ConsistencyStore` that `en-core`'s own test suite
  already constructs (`en-core/test/Main.hs`), with no PostgreSQL process to start. That keeps the
  benchmark hermetic, fast, and deterministic, which is what a CI regression gate needs. The
  consistency *codec* operations being benchmarked (`encodeToken`/`decodeToken`,
  `comparePgSnapshot`) are pure functions exported from `En.Postgres.Revision`, so the bench
  depends on `en-postgres` as a library but never touches a database.
  Date: 2026-06-23

- Decision: Split the benchmark suite across `en-core` and `en-postgres`.
  Rationale: The original single-suite design would introduce a package cycle
  (`en-core` benchmark -> `en-postgres` -> `en-core`). Keeping engine benchmarks in `en-core` and
  consistency benchmarks in `en-postgres` preserves package layering while still giving both
  regression gates.
  Date: 2026-06-23

- Decision: Keep the benchmark target independent of any cache configuration.
  Rationale: MasterPlan 2's caching work (its EP-13) may reuse this same benchmark harness to
  measure cache-hit performance (recorded as Integration Point 4 in the parent MasterPlan,
  `docs/masterplans/3-harden-en-correctness-fixes-lookup-streaming-and-performance-benchmarks.md`).
  The bench must therefore exercise the engine functions directly, with no cache wrapper compiled
  in, so both MasterPlans can run it without conflicting configuration.
  Date: 2026-06-23


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

EP-17 completed on 2026-06-23. The lookup spike now uses a real exclusion CTE for
`intersection-exclusion`, blocks the measured subject, samples p95 over 50 post-warm-up runs, accepts
an activity-row count argument, and includes large-reachable scenarios. The default 1M run and the
10M run both completed locally. The 10M result note in `docs/spec/0002-lookup-spike.md` records a
green bounded-label shape and a red large-reachable read-path finding.

Benchmarks now exist as `en-core-bench` (`check` and `lookup`) and `en-postgres-bench` (token codec
and snapshot comparison). Baselines are committed at `en-core/bench/baseline.csv` and
`en-postgres/bench/baseline.csv`, with `.github/workflows/bench.yml` running both
`--baseline ... --fail-if-slower 25` gates. Local validation passed:
`cabal build en-lookup-spike`, `cabal run en-lookup-spike`, `cabal run en-lookup-spike -- 10000000`,
`cabal build en-core-bench`, `cabal build en-postgres-bench`, and both benchmark gate commands.


## Context and Orientation

This section assumes no prior knowledge of the repository. Read it fully before editing.

**What `en` is.** `en` is a Haskell library (a "toolkit", not an application) for
relationship-based access control. It models who is related to what (memberships, ownership,
guest-org sharing, parent/child nesting of "spaces") as a graph of *tuples*, and answers
authorization questions over that graph. A *tuple* is the fact `(object, relation, subject)`,
optionally gated by a *caveat* (a small bounded predicate, e.g. "until a timestamp"). The
repository is a set of Cabal packages under `/Users/shinzui/Keikaku/bokuno/en`:

- `en-core` — the engine, with no database or web dependency. Key modules:
  `en-core/src/En/Check.hs` (forward evaluation: does subject have permission on object?),
  `en-core/src/En/Lookup.hs` (reverse expansion: which objects can a subject reach?),
  `en-core/src/En/Reachability.hs` (compiles a `Schema` into a `ReachabilityGraph`),
  `en-core/src/En/Schema.hs` and `en-core/src/En/Schema/Builder.hs` (the authorization model and a
  convenience builder), and the effect interfaces `en-core/src/En/Effect/TupleStore.hs` and
  `en-core/src/En/Effect/ConsistencyStore.hs`.
- `en-postgres` — the PostgreSQL implementations. The module relevant to this plan is
  `en-postgres/src/En/Postgres/Revision.hs`, which holds the consistency-token codec
  (`encodeToken`, `decodeToken`) and the snapshot-visibility comparison (`comparePgSnapshot`).
  The throwaway lookup spike also lives here at `en-postgres/lookup-spike/Main.hs`.
- The spike spec is `docs/spec/0002-lookup-spike.md`; the engine overview is
  `docs/spec/0001-en-overview.md`. Both are checked into the repo and may be referenced.

**The spike, in plain terms.** `en-postgres/lookup-spike/Main.hs` is a standalone executable
(`cabal run en-lookup-spike`) that spins up a *throwaway* PostgreSQL database using the
`ephemeral-pg` library (a helper that starts a private, temporary Postgres just for the program's
lifetime), loads synthetic data, and times three SQL queries across a grid of scenarios. It uses
`hasql` (a PostgreSQL client library). The three queries are:

- The *lookup-labels* query (`lookupLabelsSql` / `lookupLabelsCte`, lines 402-457): a recursive
  query that, given a fixed subject (user id 1), computes the small set of `space` ids and
  `visibility_class` tiers that subject can reach. This is the bounded, "good" query the whole
  architecture depends on.
- The *read-path* query (`readPathStatement`, lines 358-376): uses that reachable set as a filter
  over a million-row synthetic activity table (`SELECT ... WHERE space IN (...) AND
  visibility_class IN (...) ORDER BY occurred_at DESC LIMIT 50`). This is how a real consumer would
  filter its own data.
- The *anti-pattern* query (`antiPatternStatement`, lines 377-400): the wrong way — enumerate
  activities as if each were an `en` object — which is expected to hit a 1001-row cap, demonstrating
  why the boundary discipline matters.

The grid of scenarios is `scenarios` (lines 88-95): relationship-graph sizes {1000, 10000, 100000}
× nesting depth {1, 3, 6} × guest sharing {false, true} × shape {`union`, `intersection-exclusion`}.
The generator that populates the relationship graph is `populateRelationshipsStatement` (lines
228-336); the activity-table generator is `populateActivitiesStatement` (lines 206-226), invoked
once with 1,000,000 rows in `main` (line 78).

**The four spike defects (verified against the source).** Each must be fixed by this plan:

1. *The exclusion variant never traverses an exclusion.* The generator inserts `blocked` edges only
   for the `intersection-exclusion` shape (`blocked_edges`, lines 292-298:
   `relation='blocked', subject_id=999999`). But the timed query `lookupLabelsCte` (lines 411-457)
   pins the subject at user id 1 (line 421) and never mentions `relation = 'blocked'`. The union and
   exclusion shapes therefore run identical SQL. The spec calls exclusion the expensive, non-
   streaming case (`docs/spec/0001-en-overview.md` §5 and §6; `docs/spec/0002-lookup-spike.md` §3
   "to see the cliff"), so the current "exclusion ≈ union" numbers prove nothing about that cliff.

2. *The 10,000,000-row case was never run.* `main` loads 1,000,000 activity rows (line 78) and the
   appended Result Note acknowledges the 10M case was skipped
   (`docs/spec/0002-lookup-spike.md`, around the "default run did not execute the 10,000,000" note,
   spec lines 112-114). The spike's own pass bar is stated at 10M rows
   (`docs/spec/0002-lookup-spike.md` §4: "End-to-end filtered page p95 < ~50 ms at 10M
   `kawa_activity` rows").

3. *"p95" is the max of a handful of runs.* The harness times each query 7 times for lookup/read
   and 3 times for anti (`timedRuns 7` / `timedRuns 3`, lines 101-103), and `percentile` computes
   the index `ceiling(0.95 * n) - 1` (lines 139-143). With n = 7 that index is 6 (the last, i.e.
   the maximum); with n = 3 it is 2 (again the maximum). So the reported "p95" is just "the slowest
   observed run", not a tail estimate, and there is no warm-up discard, so the first (cold) run
   pollutes the sample.

4. *Label-set smallness is baked into the generator.* The generator hard-codes 24 "hot spaces"
   (`hot_spaces = 24`, line 246) and 4 visibility classes (`class_id` from 1 to 4, line 289), and
   the reachable subject (user 1) is wired to exactly those. Every scenario therefore reports
   `spaces = 24, classes = 4` regardless of graph size. That confirms "given a small set, lookup is
   fast" but not the architecturally load-bearing claim that the set *stays* small — it cannot,
   because the generator can never produce a large one.

**What the benchmark suite must measure.** The durable artifact is a `tasty-bench` benchmark suite.
`tasty-bench` is a small Haskell benchmarking library: you describe benchmarks with `bench "name"
(nf f x)` (or the IO variants below), group them with `bgroup "label" [...]`, and run them with
`defaultMain [...]`. The functions to benchmark, by exact symbol:

- `En.Check.check` (`en-core/src/En/Check.hs:47-58`) — forward evaluation. Signature:
  `check :: Monad m => ConsistencyStore m -> TupleStore m -> ReachabilityGraph -> Consistency ->
  CaveatContext -> Subject -> RelationName -> ObjectRef -> m (Either EnError CheckDecision)`. It
  returns in a monad `m`; the bench will instantiate `m = IO`. Bench it in two shapes: a *shallow*
  check (a direct owner on a space → resolves in one hop) and a *nested* check (recursion through
  the `parent` relation, several hops).
- `En.Lookup.lookup` (`en-core/src/En/Lookup.hs:83-90`) — reverse expansion. Signature:
  `lookup :: Monad m => ConsistencyStore m -> TupleStore m -> ReachabilityGraph -> Consistency ->
  LookupRequest -> m (Either EnError LookupPage)`. Bench the reachable-label-set path: list the
  spaces a subject can `view`.
- `En.Postgres.Revision.encodeToken` and `decodeToken`
  (`en-postgres/src/En/Postgres/Revision.hs:131-166`) — the consistency token codec. `encodeToken
  :: TokenPayload -> ConsistencyToken` and `decodeToken :: ConsistencyToken -> Either
  TokenDecodeError TokenPayload`. Both are pure.
- `En.Postgres.Revision.comparePgSnapshot`
  (`en-postgres/src/En/Postgres/Revision.hs:119-125`) — the snapshot-visibility comparison that
  underpins read-your-writes. `comparePgSnapshot :: PgSnapshot -> PgSnapshot -> RevisionOrder`. Pure.

**Reusable fixtures already exist.** `en-core/test/Main.hs` already builds everything the bench
needs to drive `check`/`lookup` without a database: an in-memory `TupleStore IO`
(`inMemoryTupleStore`, around line 544), a stub `ConsistencyStore IO` (`consistencyStore`, around
line 598), the `kikanSchema` value (around line 286), the compiled `ReachabilityGraph` (via
`En.Reachability.compile`), and the sample subjects/objects (`user`, `space`, `childSpace`,
`agencyUser`, etc., lines 680-776). The bench will construct equivalents of these (copy the minimal
fixture into the bench `Main.hs`, since the test module is not a library and cannot be imported).

**Term definitions used below.**
- *p95 / percentile*: the latency value that 95% of measured runs are at or below — a tail-latency
  estimate. Meaningful only over many samples.
- *warm-up run*: a first, discarded execution so JIT-like effects (query planning, cache priming)
  do not pollute the timed sample.
- *baseline (CSV)*: a recorded snapshot of benchmark timings, written by `tasty-bench`'s `--csv`
  flag, that future runs are compared against with `--baseline`.
- *regression gate*: a CI check that fails the build if a benchmark is more than a chosen percentage
  slower than the baseline (`--fail-if-slower`).


## Plan of Work

The work is two independent threads sharing one plan: strengthening the spike (Milestones 1-4) and
adding the regression-benchmark suite (Milestones 5-6). The spike milestones edit one file,
`en-postgres/lookup-spike/Main.hs`, plus the spec note in `docs/spec/0002-lookup-spike.md`. The
benchmark milestones add a new target `en-core/bench/Main.hs`, edit `en-core/en-core.cabal`, edit
`cabal.project` if a dependency override is needed, and add a benchmark CSV and a CI gate. Do the
spike fixes first (they are the higher-value risk retirement), then the benchmarks. The committed
baseline numbers are recorded last, after the soft-dependency engine fixes land (see the closing
note and the Decision Log).


### Milestone 1 — Make the exclusion variant actually traverse an exclusion

Scope: change the timed lookup query so that, for the `intersection-exclusion` shape, a space the
subject would otherwise reach is *excluded* when it carries a `blocked` edge for that subject — so
the recursive query genuinely does the extra, expensive work the spec attributes to exclusion. The
`union` shape must keep running the exact query it runs today (so the two shapes are now genuinely
different and comparable).

What exists after: `lookupLabelsCte` (or a shape-parameterised pair of CTE definitions) where the
`intersection-exclusion` run subtracts blocked spaces. The harness currently builds one fixed SQL
string for all scenarios; introduce a shape parameter so the exclusion run uses a query whose
`reachable_spaces` is the union-reachable set *minus* the set of spaces that have a
`('space', space_id, 'blocked', 'user', <subject>, NULL)` tuple. Concretely:

1. In the generator (`populateRelationshipsStatement`, the `blocked_edges` CTE at lines 292-298),
   change the blocked subject from the sentinel `999999` to the *measured subject* (`subject_id =
   1`), so the exclusion actually applies to the user being looked up. Today it blocks a user who is
   never queried, which is a second reason the exclusion is a no-op. Block a subset of the hot
   spaces (e.g. half of them) so the exclusion removes some but not all reachable spaces — that is
   what makes the cost difference observable rather than trivially emptying the set.
2. Add a second CTE definition, `lookupLabelsCteExcluding`, identical to `lookupLabelsCte` except
   that `reachable_spaces` (or a new final `reachable_spaces_final`) is filtered:
   `... WHERE NOT EXISTS (SELECT 1 FROM spike_relation_tuple b WHERE b.object_type='space' AND
   b.object_id = reachable.space_id AND b.relation='blocked' AND b.subject_type='user' AND
   b.subject_id=1)`. Wire the statements so the `intersection-exclusion` scenario selects this CTE
   and the `union` scenario selects the original. The cleanest way is to make `lookupLabelsStatement`,
   `readPathStatement`, and `antiPatternStatement` take the scenario's `shape` and choose the CTE;
   `measureScenario` already has the `Scenario` in hand (lines 97-99).
3. Keep the result columns identical so the output table shape is unchanged.

Commands (working directory `/Users/shinzui/Keikaku/bokuno/en`):

```bash
cabal build en-lookup-spike
cabal run en-lookup-spike
```

Acceptance (observable behavior): in the printed table, for matched rows that differ only in
`shape`, the `intersection-exclusion` row now shows a *different* `lookup p95 ms` and/or a smaller
`spaces` count than the corresponding `union` row — proving the exclusion query does different work.
If, after a correct implementation, the numbers are still essentially equal, that is itself a real
finding (Postgres resolves the `NOT EXISTS` cheaply at this scale); record it in Surprises &
Discoveries with the evidence, because then the conclusion is genuine rather than an artifact.


### Milestone 2 — Report a real tail percentile

Scope: make the reported p95 a real tail estimate by widening the sample and discarding a warm-up.

What exists after: `measureScenario` (lines 97-121) times each query many more times and drops the
first (cold) run before computing percentiles. Concretely:

1. Raise the sample counts: change `timedRuns 7` for lookup and read, and `timedRuns 3` for anti, to
   a larger count — at least 50 for lookup/read and 30 for anti (these queries run in
   ~1 ms, so 50 runs is well under a second of wall time per query). Define a constant
   `sampleRuns = 50` and `antiSampleRuns = 30` near the top of the file rather than scattering
   literals.
2. Add a warm-up: before the timed loop, run each query once and discard it (or run
   `sampleRuns + 1` and drop the first measurement). The simplest implementation is to time
   `sampleRuns + 1` runs and `drop 1` the resulting list before passing it to `percentiles`.
3. The `percentile` function (lines 139-143) is then correct as written: with n = 50, the p95 index
   `ceiling(0.95 * 50) - 1 = 47` is the 48th-smallest of 50 — a genuine 95th-percentile value, not
   the max.

Commands:

```bash
cabal run en-lookup-spike
```

Acceptance: the run completes in comparable wall-clock time (seconds, not minutes — the queries are
sub-millisecond), and the reported p95 values are stable across two consecutive runs to within a
small margin (e.g. the p95 no longer swings with a single cold outlier). Record a before/after p95
pair in Surprises & Discoveries.


### Milestone 3 — Prove smallness is a property, not a constant

Scope: add a scenario where the measured subject is *legitimately reachable to many spaces*, so the
harness can show whether `lookup` degrades when the reachable set is genuinely large — distinguishing
"the set stays small because of the data shape" from "the set is small because the generator hard-
codes 24."

What exists after: a new dimension or a new fixed scenario in `scenarios` (lines 88-95) and a
matching branch in `populateRelationshipsStatement` (lines 228-336) that wires user 1 to reach a
large number of spaces — e.g. make user 1 a direct `member` of many spaces (hundreds to low
thousands), bounded by `maxSpaceId` (line 86, currently 20000). Concretely:

1. Add a `largeReachable :: Bool` field to `Scenario` (or a new `shape` value
   `"union-large-reachable"`; a boolean field is cleaner). Thread it through the encoder list in
   `populateRelationshipsStatement` and the table renderer (`renderMeasurement`, lines 471-492) so
   the new column appears.
2. In the generator, when `largeReachable` is true, additionally insert `('space', s, 'member',
   'user', 1, NULL)` for `s` in `generate_series(1, N)` with N large (e.g. 1000). This makes the
   reachable space set genuinely large for the measured subject. The activity table already spans
   `maxSpaceId = 20000` spaces (line 86), so these spaces exist as filter targets.
3. Run the existing lookup/read/anti queries against this subject. The `spaces` count column will
   now report the large number for these rows.

Commands:

```bash
cabal run en-lookup-spike
```

Acceptance: the table contains rows whose `spaces` count is large (e.g. ~1000), and the
corresponding `lookup p95 ms` and `read p95 ms` are observed. Two outcomes are both acceptable and
must be recorded: (a) lookup stays fast and the read-path scales gently with the larger `IN` list —
evidence that the architecture tolerates larger reachable sets; or (b) lookup/read degrade past the
spec's bars (`lookup p95 < 25 ms`, `read p95 < 50 ms`, `docs/spec/0002-lookup-spike.md` §4) — a
genuine finding that smallness is load-bearing and must be enforced by schema discipline. Either way,
record the numbers and the interpretation in Surprises & Discoveries.


### Milestone 4 — Run the 10,000,000-row sweep and append it to the spec

Scope: run the spike at the 10M activity-row scale the spec set as its bar, and append the resulting
table to the spike spec.

What exists after: the harness can populate 10,000,000 activity rows, and a new dated Result Note
table is appended to `docs/spec/0002-lookup-spike.md`. Concretely:

1. Make the activity-row count configurable rather than the hard-coded `1000000` literal in `main`
   (line 78). Read it from the first command-line argument with a default of 1,000,000:
   `getArgs` and parse an `Int64`; fall back to 1,000,000 if absent. The anti-pattern relation rows
   are populated by the same statement (`populateActivitiesStatement`, lines 206-226), so they scale
   together. Update the printed header line in `renderResults` (line 464) to state the actual row
   count instead of the hard-coded "1,000,000" / "10,000,000 was not run" text.
2. Run the 10M sweep. Loading 10,000,000 rows into an `UNLOGGED` table takes time and memory; the
   table is `UNLOGGED` (line 179) which already speeds bulk load. If local resources cannot hold the
   full grid at 10M, run a reduced grid at 10M (e.g. only depth 6, both shapes, guest on/off) and say
   so in the note.
3. Append a new section `## 8. Result Note — <date> (10M scale)` to `docs/spec/0002-lookup-spike.md`
   with the produced table and a green/red verdict against §4's bars
   (`lookup p95 < 25 ms`, `read p95 < 50 ms`). Do not delete the existing §7 note; this is additive.

Commands:

```bash
# default 1M (unchanged behavior):
cabal run en-lookup-spike
# 10M scale (new):
cabal run en-lookup-spike -- 10000000
```

Acceptance: `docs/spec/0002-lookup-spike.md` gains a new dated 10M result table, and the
`read p95 ms` column at 10M rows is reported and compared against the 50 ms bar. The reader can re-run
`cabal run en-lookup-spike -- 10000000` and reproduce comparable numbers.


### Milestone 5 — Add the `tasty-bench` benchmark suite

Scope: create a benchmark executable that measures the real engine entry points and emits a CSV.

What exists after: a new file `en-core/bench/Main.hs`, a new `benchmark` stanza in
`en-core/en-core.cabal`, and (if needed) a `cabal.project` dependency-override block making
`tasty-bench` available. `cabal bench en-core` runs and prints timings; with `--csv` it writes a CSV.

1. Add the benchmark stanza to `en-core/en-core.cabal`. The project uses `cabal-version: 3.0` and a
   `common` stanza named `warnings`/`shared` (lines 20-35 of that file). Add:

   ```cabal
   benchmark en-core-bench
     import:         warnings, shared
     type:           exitcode-stdio-1.0
     hs-source-dirs: bench
     main-is:        Main.hs
     ghc-options:    -fproc-alignment=64
     build-depends:
       , base
       , containers
       , en-core
       , en-postgres
       , tasty-bench
       , text
       , time
   ```

   The `-fproc-alignment=64` flag is recommended by `tasty-bench` so results are not skewed by
   cache-line alignment changes between builds (important for a regression gate). The dependency on
   `en-postgres` is for the pure consistency functions only (`encodeToken`/`decodeToken`,
   `comparePgSnapshot`); no database is started.

2. If `cabal build en-core-bench` reports that `tasty-bench` is not found, add a dependency-override
   block to `cabal.project`. The project's `cabal.project` (read it: it lists the local packages and
   has a comment "each milestone appends its own block; none rewrites another's") expects local deps
   to be referenced as `source-repository-package` or a local `packages:` path. `tasty-bench` is
   registered on this machine at `/Users/shinzui/Keikaku/hub/haskell/tasty-bench-project` (find it
   with `mori registry show Bodigrim/tasty-bench --full`). Append a block:

   ```cabal
   -- EP-17: tasty-bench for the en-core regression benchmark suite.
   packages: /Users/shinzui/Keikaku/hub/haskell/tasty-bench-project/tasty-bench
   ```

   (Verify the exact subdirectory holding `tasty-bench.cabal` — `mori registry show` prints the
   path; the cabal file is at `<path>/tasty-bench.cabal` or a `tasty-bench/` subdirectory under it.)
   If `tasty-bench` is already resolvable from the configured package index, skip this step. Do not
   rewrite existing blocks in `cabal.project`; append only.

3. Write `en-core/bench/Main.hs`. It must construct the fixtures (copy the minimal subset from
   `en-core/test/Main.hs`: `kikanSchema` via the `En.Schema.Builder` helpers, `compile` it to a
   `ReachabilityGraph`, an in-memory `TupleStore IO` over a small fixture tuple list, the stub
   `ConsistencyStore IO`, and the `user`/`space`/`childSpace`/`agencyUser` object refs and the
   `requestContext`). Because `check`/`lookup` run in `IO`, use `tasty-bench`'s `nfAppIO`/`whnfAppIO`
   to benchmark an `IO` action and force its result; use `nf`/`whnf` for the pure consistency
   functions. The skeleton:

   ```haskell
   module Main (main) where

   import Test.Tasty.Bench (Benchmark, bench, bgroup, defaultMain, nf, nfAppIO, whnf)

   import En.Check (check)
   import En.Lookup (lookup)
   import En.Postgres.Revision (PgSnapshot (..), TokenPayload (..), comparePgSnapshot, decodeToken, encodeToken)
   -- ... plus Schema, Reachability, Revision, Tuple, Effect.* imports, and the copied fixtures ...

   import Prelude hiding (lookup)

   main :: IO ()
   main =
       defaultMain
           [ bgroup "check"
               [ bench "shallow-owner" $ nfAppIO (\() -> check consistencyStore tupleStore graph MinimizeLatency requestContext (SubjectId user) (RelationName "view") space) ()
               , bench "nested-parent" $ nfAppIO (\() -> check consistencyStore tupleStore graph MinimizeLatency requestContext (SubjectId user) (RelationName "view") childSpace) ()
               ]
           , bgroup "lookup"
               [ bench "reachable-spaces" $ nfAppIO (\() -> lookup consistencyStore tupleStore graph MinimizeLatency viewSpacesRequest) ()
               ]
           , bgroup "consistency"
               [ bench "encodeToken" $ nf encodeToken sampleTokenPayload
               , bench "decodeToken" $ nf decodeToken sampleEncodedToken
               , bench "comparePgSnapshot" $ nf (uncurry comparePgSnapshot) (snapshotA, snapshotB)
               ]
           ]
   ```

   `nfAppIO f x` benchmarks the IO action `f x` and forces (`nf` = normal form) its result fully, so
   the engine actually computes the decision rather than returning a lazy thunk; the `\() -> ...` /
   `()` shape just satisfies `nfAppIO`'s "function applied to argument" form. `nf`/`whnf` benchmark a
   pure function applied to an argument. Because `check`/`lookup` return `Either EnError ...` which is
   a finite structure, `nfAppIO` is the right choice (it forces the whole `Either` and its contents).

   Provide a *nested* check fixture: ensure the in-memory tuple list includes the recursive `parent`
   chain so `check ... childSpace` walks through `space` (mirror the `childSpace`/`parent`/`space`
   tuples from `en-core/test/Main.hs`, lines 619-630). Provide `viewSpacesRequest :: LookupRequest`
   listing spaces the `user` can `view`. Provide `sampleTokenPayload`, `sampleEncodedToken` (=
   `encodeToken sampleTokenPayload`), and two `PgSnapshot` values for the comparison.

Commands:

```bash
cabal build en-core-bench
cabal bench en-core --benchmark-options='--stdev 5'
cabal bench en-core --benchmark-options='--csv bench-baseline.csv'
```

(`cabal bench en-core` runs all benchmark stanzas in `en-core`; pass `tasty-bench` flags through
`--benchmark-options`. `--stdev 5` tells `tasty-bench` to keep iterating until the relative standard
deviation is under 5%, giving stabler numbers for a baseline.)

Acceptance: `cabal bench en-core` prints a tree of timings like:

```text
check
  shallow-owner: OK
    1.2 μs ± 80 ns
  nested-parent: OK
    3.4 μs ± 0.2 μs
lookup
  reachable-spaces: OK
    ...
consistency
  encodeToken: OK
    ...
All N tests passed
```

and `cabal bench en-core --benchmark-options='--csv bench-baseline.csv'` writes a CSV whose header is
`Name,Mean (ps),2*Stdev (ps)` with one row per benchmark.


### Milestone 6 — Record a committed baseline and wire the CI regression gate

Scope: commit a baseline CSV and add a CI step that fails when a benchmarked path regresses.

What exists after: a committed baseline file (e.g. `en-core/bench/baseline.csv`), a CI job that runs
the bench against it with a slow-down threshold, and a demonstrated failure when a function is
deliberately slowed.

1. Record the baseline:

   ```bash
   cabal bench en-core --benchmark-options='--stdev 3 --csv en-core/bench/baseline.csv'
   ```

   Commit `en-core/bench/baseline.csv`. **Per the Decision Log, the *authoritative* committed
   baseline is recorded only after EP-14/EP-15/EP-16 land** (see the closing note). Until then,
   commit a *provisional* baseline so the gate is wired and demonstrable, and mark it provisional in
   a comment at the top of the file (CSV lines beginning with `#` are not standard, so instead note
   the provisional status in this plan's Progress and in the CI job comment).

2. Add a CI regression gate. There is currently no `.github/workflows` directory in the repo (verify
   with `ls .github/workflows`). Create `.github/workflows/bench.yml` (or, if the project later
   standardizes a different CI system, add the step there) whose core command is:

   ```bash
   cabal bench en-core --benchmark-options='--baseline en-core/bench/baseline.csv --fail-if-slower 25 --hide-successes'
   ```

   `--baseline FILE` reads the committed timings; `--fail-if-slower 25` makes the benchmark *fail*
   (non-zero exit) if any benchmark is more than 25% slower than its baseline entry;
   `--hide-successes` keeps the log focused on regressions. Choose 25% as the initial threshold — wide
   enough to tolerate CI-runner noise, tight enough to catch a real algorithmic regression; record the
   choice and revisit it if CI proves flaky. Do *not* set `--fail-if-faster` (a function getting
   faster should not fail CI; if it gets dramatically faster you simply re-record the baseline).

3. Prove the gate works. Temporarily slow a benchmarked function — the cleanest demonstration is to
   insert a deliberate delay or redundant work into `En.Check.check`'s evaluation (e.g. wrap the
   result in a forced re-computation), rebuild, and run the gate command. It must exit non-zero with a
   message naming the regressed benchmark and the percentage. Then revert the deliberate slowdown and
   confirm the gate passes. Capture both transcripts in Surprises & Discoveries.

Commands:

```bash
# record baseline:
cabal bench en-core --benchmark-options='--stdev 3 --csv en-core/bench/baseline.csv'
# gate (passes against its own baseline):
cabal bench en-core --benchmark-options='--baseline en-core/bench/baseline.csv --fail-if-slower 25'
# after deliberately slowing check, the same gate command must fail:
cabal bench en-core --benchmark-options='--baseline en-core/bench/baseline.csv --fail-if-slower 25'; echo "exit=$?"
```

Acceptance: against an unmodified tree the gate command exits 0 ("All N tests passed"); after a
deliberate slowdown to a benchmarked function the identical command exits non-zero and prints a line
like `shallow-owner: FAIL ... 120% more than baseline`. This is the durable, observable guarantee the
plan delivers.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/en` unless stated. Run them in order.

```bash
# --- Spike fixes (Milestones 1-4): edit en-postgres/lookup-spike/Main.hs, then ---
cabal build en-lookup-spike
cabal run en-lookup-spike                 # 1M default; inspect the table
cabal run en-lookup-spike -- 10000000     # 10M sweep (Milestone 4)

# --- Benchmarks (Milestones 5-6): add en-core/bench/Main.hs + cabal stanza, then ---
cabal build en-core-bench
cabal bench en-core --benchmark-options='--stdev 5'                       # smoke run
cabal bench en-core --benchmark-options='--stdev 3 --csv en-core/bench/baseline.csv'   # record baseline
cabal bench en-core --benchmark-options='--baseline en-core/bench/baseline.csv --fail-if-slower 25'  # gate
```

Expected smoke-run transcript (numbers will vary by machine):

```text
All
  check
    shallow-owner: OK
      1.1 μs ± 90 ns
    nested-parent: OK
      3.0 μs ± 0.2 μs
  lookup
    reachable-spaces: OK
      8.5 μs ± 0.6 μs
  consistency
    encodeToken: OK
      640 ns ±  40 ns
    decodeToken: OK
      810 ns ±  55 ns
    comparePgSnapshot: OK
      210 ns ±  12 ns
All 6 tests passed
```

This section must be updated with the real transcripts as work proceeds.


## Validation and Acceptance

The plan is validated by behavior, not by code shape:

- **Exclusion really differs (M1).** Run `cabal run en-lookup-spike`. In the output table, compare
  rows that differ only in the `shape` column. The `intersection-exclusion` rows must show a
  measurably different `lookup p95 ms` and/or a smaller reachable `spaces` count than the matching
  `union` rows. If they are still equal after a correct implementation, that equality is now a real
  measurement of Postgres handling the exclusion cheaply (record it), not the previous artifact of
  identical SQL.
- **Real tail percentile (M2).** Run the spike twice. The reported p95 values must be stable between
  runs (no single cold outlier dominating), and the harness source must show ≥ 50 timed runs for
  lookup/read with the first run discarded.
- **Smallness is a property (M3).** The table must include rows whose `spaces` count is large
  (e.g. ~1000), with their `lookup`/`read` p95 values reported and compared to the spec bars.
- **10M scale recorded (M4).** `docs/spec/0002-lookup-spike.md` must contain a new dated 10M result
  table with a green/red verdict against the §4 bars (`lookup p95 < 25 ms`, `read p95 < 50 ms`).
- **Benchmark suite runs (M5).** `cabal bench en-core` prints a passing tree covering
  `check`/`lookup`/`consistency`, and `--csv` writes a readable CSV.
- **Regression gate bites (M6).** Against the baseline the gate exits 0; after a deliberate slowdown
  to a benchmarked function the same command exits non-zero naming the regression. This is the
  headline acceptance: a slowdown cannot pass unnoticed.

Also run the existing engine tests to confirm nothing in `en-core` was disturbed by the bench
fixtures (the bench copies fixtures; it must not edit library code):

```bash
cabal test en-core
```


## Idempotence and Recovery

- The spike is inherently idempotent: each `cabal run en-lookup-spike` starts a *fresh* ephemeral
  PostgreSQL (via `ephemeral-pg`), creates its tables with `DROP TABLE IF EXISTS ...` (`resetSql`,
  lines 163-204), and tears the database down on exit. Re-running never accumulates state. If a run
  fails because the machine lacks a working `pg_ctl`/`initdb` on `PATH`, `ephemeral-pg` reports a
  start error (`main` prints "ephemeral-pg failed to start"); install PostgreSQL client binaries and
  retry. The 10M run needs more disk/RAM for the temporary cluster; if it OOMs, reduce the grid at
  10M (Milestone 4 step 2) and retry.
- The benchmark suite is pure measurement; re-running is always safe. Re-recording the baseline
  (`--csv`) simply overwrites the CSV — commit the new file when you intend to move the baseline.
- Editing `cabal.project` is additive (append a block; never rewrite an existing one), so re-applying
  the step is safe; a duplicate `packages:` line for the same path is harmless but should be removed.
- The deliberate-slowdown demonstration in Milestone 6 **must be reverted** before committing; the
  acceptance requires the gate to pass on the unmodified tree. If you forget, `cabal test en-core`
  and the gate against baseline will both reveal it.


## Interfaces and Dependencies

Libraries used and why:

- `tasty-bench` (registered as `Bodigrim/tasty-bench`) — the benchmark framework. Used for its
  `--csv` baseline recording, `--baseline` comparison, and `--fail-if-slower` regression gate.
  Imported as `Test.Tasty.Bench`, using `defaultMain`, `bgroup`, `bench`, `nf`, `whnf`, `nfAppIO`,
  `whnfAppIO`. Note the suite **must** call `Test.Tasty.Bench.defaultMain`, not
  `Test.Tasty.defaultMain`.
- `ephemeral-pg` and `hasql` — already used by the spike; no new usage beyond making the activity-row
  count and the exclusion CTE selectable.

Functions and types that must exist at the end of each milestone (full module paths):

- After M1-M4: `en-postgres/lookup-spike/Main.hs` exposes a shape-aware lookup CTE
  (`lookupLabelsCte` for `union`, `lookupLabelsCteExcluding` for `intersection-exclusion`), a
  configurable activity-row count read from `getArgs`, a `largeReachable` scenario dimension on the
  `Scenario` record, and `sampleRuns`/`antiSampleRuns` constants ≥ 50/30 with a discarded warm-up.
  `docs/spec/0002-lookup-spike.md` gains a dated 10M Result Note section.
- After M5: `en-core/en-core.cabal` declares `benchmark en-core-bench` (type `exitcode-stdio-1.0`,
  `hs-source-dirs: bench`, `main-is: Main.hs`, depends on `en-core`, `en-postgres`, `tasty-bench`).
  `en-core/bench/Main.hs` exists with `main :: IO ()` calling `Test.Tasty.Bench.defaultMain`, and
  benchmarks `En.Check.check` (`en-core/src/En/Check.hs:47`), `En.Lookup.lookup`
  (`en-core/src/En/Lookup.hs:83`), `En.Postgres.Revision.encodeToken`/`decodeToken`
  (`en-postgres/src/En/Postgres/Revision.hs:131`/`:147`), and
  `En.Postgres.Revision.comparePgSnapshot` (`en-postgres/src/En/Postgres/Revision.hs:119`).
- After M6: `en-core/bench/baseline.csv` exists and is committed; a CI workflow runs the gate command
  with `--baseline en-core/bench/baseline.csv --fail-if-slower 25`.

The benchmark target depends on the library functions only via their *exported* signatures; it does
not depend on any cache module or cache configuration (Decision Log: cache-config-independence, so
MasterPlan 2 EP-13 can reuse the harness — Integration Point 4 in
`docs/masterplans/3-harden-en-correctness-fixes-lookup-streaming-and-performance-benchmarks.md`).


## Soft dependencies on other plans (and what they mean for sequencing)

This plan has *no hard dependency* — every milestone can begin against the current tree. It has three
*soft* dependencies, meaning the work is only fully *meaningful* once those land, and the committed
baseline / 10M numbers should measure the *fixed* engine:

- `docs/plans/16-make-lookup-streaming-with-resumable-cursors-and-a-deadline-budget.md` (EP-16)
  replaces the eager "compute all candidates, then cap" `lookup` with a streaming, resumable,
  deadline-bounded traversal, and removes the `ensureExhausted` hard-fail on multi-page intermediate
  reads (`en-core/src/En/Lookup.hs:414-419`). The benchmark's `lookup` numbers and the spike's
  exclusion-cliff measurement should reflect that streaming implementation, not the about-to-be-
  replaced one.
- `docs/plans/15-generalize-the-caveat-evaluator-and-unify-the-decision-algebra.md` (EP-15)
  generalizes the hardcoded caveat evaluator and extracts the shared three-valued decision algebra
  into `En.Decision`, which `check`/`lookup` will call. Benchmarking before this lands measures
  copy-pasted decision logic that is about to change.
- `docs/plans/14-harden-consistency-faithful-snapshot-visibility-gc-window-and-token-reconciliation.md`
  (EP-14) replaces the snapshot-visibility comparison (`snapshotIncludes`/`comparePgSnapshot` in
  `en-postgres/src/En/Postgres/Revision.hs`) with a faithful port and reconciles the token format.
  The `consistency` benchmarks (`comparePgSnapshot`, `encodeToken`/`decodeToken`) should measure the
  corrected implementations.

Therefore: build and exercise the spike fixes and the benchmark *scaffolding* now (Milestones 1-6),
committing a clearly-labelled **provisional** baseline so the CI gate is live and demonstrable; then,
once EP-14/EP-15/EP-16 are merged, **re-record the baseline** and **re-run the 10M sweep** against the
fixed engine and replace the provisional numbers. This sequencing is recorded in the Decision Log and
tracked in the final Progress checkbox.


---

Revision note (2026-06-23): Initial full draft of EP-17, fleshed out from the skeleton against the
ExecPlan spec (`.claude/skills/exec-plan/PLANS.md`), the spike spec (`docs/spec/0002-lookup-spike.md`),
the engine overview (`docs/spec/0001-en-overview.md`), the parent MasterPlan
(`docs/masterplans/3-harden-en-correctness-fixes-lookup-streaming-and-performance-benchmarks.md`,
Integration Point 4 and the EP-14/15/16 soft dependencies), and the source files cited by file:line.
All four spike defects were verified directly against `en-postgres/lookup-spike/Main.hs`, and the
benchmark targets were confirmed against the real signatures in `en-core/src/En/Check.hs`,
`en-core/src/En/Lookup.hs`, and `en-postgres/src/En/Postgres/Revision.hs`. The reusable in-memory
fixtures in `en-core/test/Main.hs` were identified as the basis for the bench fixtures.
