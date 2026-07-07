---
id: 44
slug: make-evaluation-budgets-configurable-and-trim-hot-path-overhead
title: "Make evaluation budgets configurable and trim hot-path overhead"
kind: exec-plan
created_at: 2026-07-07T15:24:51Z
master_plan: "docs/masterplans/7-fix-the-en-evaluation-engine.md"
---

# Make evaluation budgets configurable and trim hot-path overhead

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`en` (縁)'s three query engines — `check`, `lookup`, `expand` in `en-core` — share three
magic numbers, each **duplicated as a private constant in all three modules**:
`maxDepth = 25` (recursion budget), `pageLimit = 1000` (storage read batch size), and
`resultCap = 1000` (result-set bound). An operator cannot raise the depth budget for a
deeply nested schema or shrink page sizes for a memory-tight embedded deployment
without editing library source (finding B11's neighbor, B12, in
`docs/reviews/2026-07-07-architecture-performance-review.md`; the constants are listed
there explicitly). Around those constants, the review's B11/B12 catalog a layer of
structural drag: per-row list appends (`decisions <> [d]`) inside evaluation folds,
O(n²) `elem`-based deduplication, linear `visited` lists, a per-union-node re-sort of
the lookup result map, cache-statistics writes through `atomicModifyIORef'` even when
the cache is disabled (a CAS contention point under concurrency), an O(n) full-map scan
to find the eviction victim on every insert past capacity, and a compiled `EntryPoint`
reachability graph that no engine consumes (only a renderer and tests do). And the
benchmark suite that should catch regressions here measures a two-tuple toy fixture.

After this plan: a single `EvaluationBudget` record (defaults identical to today's
constants) is threaded through all three engines and constructed once by consumers —
budget changes are configuration, not source edits; the hot-path fixes above are
applied with the review as the checklist; the dead `EntryPoint` machinery has a decided
home (relocated to the render layer, per the Decision Log); and
`en-core/bench/Main.hs` gains wide-relation and deep-nesting fixtures whose
before/after numbers are recorded in this plan as the acceptance evidence.

You can see it working: run `cabal bench en-core:en-core-bench` before and after and
compare the recorded numbers; run a check with `maxDepth = 3` in a test and watch a
depth-4 chain fail with `ResolutionLimitExceeded` while the default succeeds — without
recompiling anything but the test.


## Progress

- [ ] M0: baseline — build/test; confirm which of docs/plans/39/40/41/42/43 landed
  (this plan runs last by design and tunes their final shape); record the current
  constant sites and bench numbers.
- [ ] M1: benchmark fixtures first — wide-relation and deep-nesting groups in
  `en-core/bench/Main.hs`; baseline numbers recorded in this plan.
- [ ] M2: `En.Budget.EvaluationBudget` record; threaded through check/lookup/expand as
  `…WithBudget` variants; constants deduplicated to the one module; defaults preserved;
  budget-override test.
- [ ] M3: consumer wiring — `en-servant` `Env` carries a budget; `en-server` constructs
  it (env-var parsing deferred to docs/plans/38's config record if not landed);
  `maxBatchSize` note.
- [ ] M4: hot-path fixes in `En.Check`/`En.Lookup`/`En.Expand`/`En.Decision`/
  `En.Caveat` — strict accumulation, Set-based visited, Set/Map dedupe, single
  top-level lookup merge.
- [ ] M5: cache mechanics in `En.Cache` — no stat writes when disabled, O(log n)
  eviction; test updates with Decision Log entries.
- [ ] M6: `EntryPoint` relocation to the render layer; `ReachabilityGraph` slims down;
  tests moved.
- [ ] M7: after-numbers recorded; before/after table in this plan; regression guard
  notes.
- [ ] Final: full suite green; Outcomes filled; master plan progress rows updated.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: The budget record is `EvaluationBudget { maxDepth :: Int, pageLimit :: Int,
  resultCap :: Int }` in a new module `En.Budget`, with
  `defaultEvaluationBudget = EvaluationBudget 25 1000 1000`. No caveat-evaluation limit
  field yet.
  Rationale: those three are the constants actually duplicated today
  (`en-core/src/En/Check.hs` lines 163–167, `en-core/src/En/Lookup.hs` lines 215–222,
  `en-core/src/En/Expand.hs` lines 116–123). Caveat evaluation is a bounded pure fold
  over a schema-validated predicate — there is no runaway to budget; adding a
  speculative knob would be configuration surface without a consumer. The record can
  grow additively later.
  Date: 2026-07-07
- Decision: Budgets enter through new `…WithBudget` entry points
  (`checkWithBudget`, `lookupWithDeadlineAndBudget`, `expandWithBudget`, and cached
  variants); the existing names stay as thin wrappers applying
  `defaultEvaluationBudget`. Budgets are per-engine configuration, not per-request wire
  fields.
  Rationale: keeps every existing call site (tests, en-servant, en-example, benches)
  compiling unchanged, which matters for a plan that lands last on top of five others.
  Per-request budget override on the wire was reviewed under A7 (client-supplied
  deadline is already a DoS-shaped knob) — letting clients raise `maxDepth` remotely is
  an amplification hazard; the server-level record is the right altitude. The deadline
  (docs/plans/42) stays a separate argument: it is a *clock*, not a static bound.
  Date: 2026-07-07
- Decision: Cache eviction keeps FIFO (insertion-order victim) semantics but replaces
  the O(n) `oldestKey` scan with an O(log n) side index `Map Int key` keyed by the
  existing `sequenceNumber`. True LRU (bump-on-hit) is rejected; `psqueues` is not
  added.
  Rationale: LRU requires a write on every cache *hit*, re-introducing exactly the
  disabled-path CAS contention this plan removes on the read side — the review's
  complaint is "eviction better than O(n) oldestKey", which FIFO-with-index delivers
  with zero new read-path cost. `en-core/en-core.cabal` depends on `containers` but not
  `psqueues`; the Map-based index avoids a new dependency for identical asymptotics at
  this scale. Recorded so a future concurrency plan can revisit LRU alongside striped
  caches.
  Date: 2026-07-07
- Decision: When a cache is disabled (or zero-capacity), `lookupCache` returns
  `Nothing` via a plain `pure` — it stops counting misses — and `insertCache` remains a
  no-op. The existing test asserting "disabled cache records misses but not inserts"
  (`en-core/test/Main.hs` lines ~702–708) is rewritten to assert stats stay zero.
  Rationale: mutating shared state per read on a *disabled* feature is pure contention
  (review B12: "mutates stats on every hit/miss even when disabled, a CAS contention
  point"); a disabled cache's stats have no operational meaning. Behavior change is
  test-visible only, hence this entry.
  Date: 2026-07-07
- Decision: The `EntryPoint` machinery is **relocated to the render layer, not
  deleted**: the `entries` field leaves `ReachabilityGraph`
  (`en-core/src/En/Reachability.hs` lines 39–45), and entry-point compilation
  (`compileRelation`/`compileRewrite`, lines 121–188) moves behind a pure function the
  renderer calls on demand.
  Rationale: reading the consumers settles it — `graph.entries` is consumed only by
  `En.Schema.Render.renderReachabilityMermaid` (`en-core/src/En/Schema/Render.hs` lines
  102–129) and by reachability tests in `en-core/test/Main.hs` (`hasEntry`
  assertions); no engine reads it. Deletion was rejected because the renderer is a
  shipped feature (schema diagrams) and the `EntryPoint.path` structure is the natural
  seed for a future explain/trace feature (review E12) — relocation keeps it alive
  where it is used and stops every engine consumer paying to build and carry it.
  Master-plan condition honored: no other child plan adopted `entries` (EP-39–EP-43
  confirmed at M0).
  Date: 2026-07-07
- Decision: The FNV-1a schema-hash concern (review B12's last item) is out of scope.
  Rationale: changing the schema fingerprint invalidates every persisted consistency
  token (the hash is embedded in tokens); that blast radius belongs with the
  schema-lifecycle work (docs/plans/54-manage-the-schema-lifecycle-at-runtime.md), not
  a hot-path sweep.
  Date: 2026-07-07
- Decision: Benchmarks land *first* (M1), before any optimization.
  Rationale: "record before/after numbers as acceptance evidence" is only honest if the
  before numbers exist on the unoptimized tree; tasty-bench makes the comparison cheap
  (`--baseline`). If docs/plans/39 already added a `check-wide` group, extend rather
  than duplicate it (reconcile at M0).
  Date: 2026-07-07


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

You are in the `en` repository (working tree `/Users/shinzui/Keikaku/bokuno/en`; paths
repository-relative), a Haskell Cabal multi-package project on GHC 9.12.4 using
`effectful`. This plan is EP-44 of
`docs/masterplans/7-fix-the-en-evaluation-engine.md` — deliberately the **last** child
plan, tuning the engine shape the others finish — and addresses findings B11 and B12 of
`docs/reviews/2026-07-07-architecture-performance-review.md`.

Packages: **`en-core`** (engines, cache, decision algebra, benchmarks), **`en-servant`**
(the `Env` seam), **`en-server`** (constructs the seam at boot). Definitions:

- **Budget vs deadline**: a *budget* is a static bound (depth 25, page size 1000); a
  *deadline* (`En.Lookup.Deadline`, from docs/plans/42) is a live clock poll. This plan
  owns budgets; deadlines are consumed as-is.
- **The constant sites** (grep `maxDepth\|pageLimit\|resultCap` under `en-core/src`):
  `En/Check.hs` (`maxDepth`, `pageLimit`), `En/Lookup.hs` (`maxDepth`, `pageLimit`,
  `resultCap`), `En/Expand.hs` (`maxDepth`, `pageLimit`, `resultCap`). Each engine's
  `EvalState`/loops read them as module-level CAFs.
- **The hot-path items**, with the review's own citations (line numbers may have
  drifted after EP-39…EP-43 — re-verify at M0 and update here):
  list-append accumulation in `En.Check`'s folds (review cites `Check.hs:381,408-417,
  444`); `acc <> page.rows` in the page-drain loops (`En.Lookup.readRowsForSubjects`,
  `En.Expand.readObjectRows`, and EP-39's `drainObjectRelation`); O(n²) `elem` dedupe in
  `En.Decision.dedupeObligations` (`Decision.hs:76-82`) and `En.Caveat.dedupe`
  (`Caveat.hs:142-148`); `visited` kept as a list with `elem` membership tests in all
  three engines' `EvalState`s; `mergeLookupObjects` rebuilding and re-sorting a `Map`
  at every union node (`Lookup.hs:538-552`).
- **The cache** (`en-core/src/En/Cache.hs`): a bounded map in one `IORef`.
  `lookupCache` (lines 114–128) runs `atomicModifyIORef'` even when
  `config.enabled = False`, purely to count a miss. `insertCache` (lines 130–148) calls
  `evictOldest` → `oldestKey` (lines 162–180), a full `Map.foldrWithKey` scan per
  eviction. `CacheStats` counts hits/misses/inserts/evictions; `cacheStats` reads them.
- **`EntryPoint` machinery** (`en-core/src/En/Reachability.hs`): `compile` builds both
  `relations` (the map every engine traverses) and `entries :: Map RelationRef
  [EntryPoint]` (reverse-edge metadata with `path :: [RewriteStep]`). Consumers of
  `entries`: `En.Schema.Render.renderReachabilityMermaid` and the `hasEntry` test
  assertions — nothing else (re-verify with a grep at M0).
- **Benchmarks**: `en-core/bench/Main.hs` is a `tasty-bench` suite (`benchmark
  en-core-bench` in `en-core/en-core.cabal`, run with
  `cabal bench en-core:en-core-bench`); it currently measures `check`, `checkMany`, and
  `lookup` over a **two-tuple** fixture (`benchTuples`, lines 80–84) — the review calls
  this out explicitly. `en-core/bench/baseline.csv` exists for tasty-bench's
  `--baseline` comparison flow.
- **The seam**: `en-servant/src/En/Servant/Seam.hs` defines
  `Env es { runPorts, graph, checkOperation, lookupWithDeadlineOperation,
  maxBatchSize }`; `en-server/app/Main.hs` constructs it at boot. `maxBatchSize` is a
  transport bound and *stays* on `Env` (it is not an engine budget).

Integration points restated from the master plan so this plan stands alone:

- **This plan runs after EP-39/40/41/42/43 by design** ("it tunes and deduplicates code
  the other plans finish shaping, and it deletes or relocates the unused reachability
  `EntryPoint` machinery only after confirming no other child plan adopted it"). At M0,
  list which landed; where one has not, skip the touchpoints that depend on it and
  record the gap here rather than improvising.
- **Engine configuration slots into the server config record** of
  docs/plans/38-validate-configuration-and-persist-datastore-identity.md (master plan
  6) *if that has landed*; otherwise `en-server` constructs `defaultEvaluationBudget`
  inline and docs/plans/38 later lifts it into validated config. Do not build env-var
  validation here — that is 38's scope.
- The lookup deadline default (3,000 ms in `en-servant/src/En/Servant/API.hs`
  `lookupDeadline`) is adjacent but owned by the A7 remediation in master plan 6; leave
  it, note it.


## Plan of Work


### M0 — Baseline, landed-plan inventory, and measurements

Build and test; grep the constant sites and `entries` consumers to confirm the Context
section; record which of EP-39…EP-43 are on the tree. Then capture baseline numbers:

```bash
cabal bench en-core:en-core-bench --benchmark-options='--csv en-core/bench/before-ep44.csv'
```

Paste the timing lines into this plan (Concrete Steps) — they are the "before" half of
the acceptance evidence.


### M1 — Benchmarks that can see the problem

Scope: fixtures wide and deep enough that the M4/M5 fixes move the numbers. In
`en-core/bench/Main.hs` (extending, not replacing, the existing groups; if
docs/plans/39 added `check-wide`, grow it instead of duplicating):

- **Wide-relation fixture**: one `folder` object with 5,000 direct `viewer` tuples plus
  one nested-group attachment. Benches: `check/wide-member` (subject present),
  `check/wide-non-member`, `checkMany/wide-overlapping` (three pairs sharing
  subproblems), and `lookup/wide-fanout` (a subject reaching 1,200 folders — reuse the
  test suite's streaming fixture shape).
- **Deep-nesting fixture**: a `parent` chain of 20 spaces (`space:s1 … space:s20`,
  each the parent of the next) with the viewer at the root; bench `check/deep-nested`
  on the leaf via the `parent->view` arrow, and `expand/deep-nested` expanding the
  leaf. Depth 20 sits under the default `maxDepth = 25` yet exercises the `visited`
  list and recursion machinery hard.

Keep fixtures as top-level CAFs so construction cost stays out of the measured region
(the existing file's pattern). Run and record:

```bash
cabal bench en-core:en-core-bench
```

Acceptance: all new benches run to completion on the unoptimized tree and their numbers
are recorded here. (Note: on a pre-EP-39 tree the wide checks would error — that is why
the inventory in M0 matters.)


### M2 — The EvaluationBudget record and threading

Scope: one source of truth for the three numbers. Create `en-core/src/En/Budget.hs`
(add to `exposed-modules` in `en-core/en-core.cabal`):

```haskell
-- | Static evaluation bounds shared by check, lookup, and expand.
module En.Budget (
    EvaluationBudget (..),
    defaultEvaluationBudget,
) where

data EvaluationBudget = EvaluationBudget
    { maxDepth :: !Int
    -- ^ Recursion depth bound; exceeding it fails with ResolutionLimitExceeded.
    , pageLimit :: !Int
    -- ^ Storage read batch size (a batch size, not a result ceiling — drains loop).
    , resultCap :: !Int
    -- ^ Bound on returned result sets (lookup objects, expand nodes) per page.
    }
    deriving stock (Eq, Show)

defaultEvaluationBudget :: EvaluationBudget
defaultEvaluationBudget = EvaluationBudget{maxDepth = 25, pageLimit = 1000, resultCap = 1000}
```

Then, in each engine, delete the module-level constants and thread the record: the
least invasive carrier is the existing `EvalState` (add a `budget :: !EvaluationBudget`
field set once at `initialState`) plus a `budget` parameter on the drain helpers that
read `pageLimit` outside `EvalState`. Add the public entry points —
`En.Check.checkWithBudget` (and `checkCachedWithBudget`, `checkManyWithBudget`),
`En.Lookup.lookupWithDeadlineAndBudget` (and the cached variant),
`En.Expand.expandWithBudget` — each taking `EvaluationBudget` as the first argument;
redefine the existing names as wrappers applying `defaultEvaluationBudget`, so no call
site changes.

Tests (`en-core/test/Main.hs`): a budget-override assertion — with
`defaultEvaluationBudget{maxDepth = 3}`, checking through a 4-deep parent chain yields
`Left ResolutionLimitExceeded` while the default budget yields `Right Allowed` on the
same fixtures; and with `pageLimit = 10` the 1,200-folder streaming lookup still
returns the complete set (draining makes page size behavior-invisible — the assertion
that proves `pageLimit` is a batch size, not a semantics knob).

```bash
cabal test en-core:en-core-interface-tests
cabal test en-core:en-core-conformance
```

Acceptance: suite green with zero call-site churn; the two override assertions pass;
`grep -rn "maxDepth\s*=\s*25" en-core/src` matches only `En/Budget.hs`.


### M3 — Consumer wiring

Scope: make the budget reachable from deployments. In
`en-servant/src/En/Servant/Seam.hs`, add `budget :: !EvaluationBudget` to `Env` and pass
it through the operations `Env` carries (`checkOperation`,
`lookupWithDeadlineOperation` — their stored functions become the `…WithBudget`
variants partially applied with `env.budget`; handler code in
`en-servant/src/En/Servant/API.hs` does not change shape). In `en-server/app/Main.hs`,
construct `defaultEvaluationBudget` where the `Env` is built, with a comment: lifted
into validated configuration by
docs/plans/38-validate-configuration-and-persist-datastore-identity.md. Update
`en-servant/test/Main.hs` env literals (compiler-forced). Embedded consumers
(en-example) keep using the default-budget wrappers untouched.

```bash
cabal build all
cabal test en-servant:en-servant-tests
```


### M4 — Hot-path fixes in the engines and algebra

Scope: the review's B12 list, item by item, each safe to land separately (one commit
per item; re-run the focused tests after each):

1. **Strict accumulation in evaluation folds** (`En.Check`): replace every
   `decisions <> [d]` inside `foldM` steps with prepend-then-reverse (or fold the
   decision algebra incrementally where EP-40's short-circuit fold already does).
   Same treatment for the drain loops' `acc <> page.rows` in `En.Lookup`, `En.Expand`,
   and `En.Check`'s `drainObjectRelation`: accumulate reversed pages and
   `concat . reverse` once.
2. **Set-based `visited`**: change `EvalState.visited` from `[Subproblem]` to
   `Set Subproblem` in all three engines (`Subproblem` in `En.Check` already derives
   `Ord`; add `deriving stock (Eq, Ord, Show)` to the `Subproblem` types in `En.Lookup`
   and `En.Expand` — check the field types all have `Ord`; they are
   `Subject`/`ObjectType`/`ObjectRef`/`RelationName`, all `Ord` already). Membership
   test becomes `Set.member`, insertion `Set.insert`.
3. **Dedupe via `Set`/`Map`**: rewrite `En.Decision.dedupeObligations` and
   `En.Caveat.dedupe` as order-preserving nub-by-Set (walk the list once, keep a seen
   `Set`); `CaveatObligation` needs `Ord` — add it (fields `CaveatName` and `[Text]`
   are `Ord`). Keep first-occurrence order so `Conditional` payloads stay stable for
   tests.
4. **Single merge at the top of lookup unions**: in `En.Lookup`, union branches
   currently return already-merged (sorted, deduplicated) lists and every `Union` node
   re-merges (`mergeLookupObjects . concat`). Change internal traversal results to
   *unmerged* accumulations (the `Map ObjectRef LookupObject` that `insertObjects`
   already maintains is the natural carrier), merging/sorting **once** where results
   become externally visible (page assembly, and before candidate confirmation which
   needs deduplicated candidates). Reconcile carefully with the EP-42 traversal
   restructure — the watermark logic depends on final sorted order only, which is
   unchanged.

```bash
cabal test en-core:en-core-interface-tests
cabal test en-core:en-core-conformance
cabal bench en-core:en-core-bench
```

Acceptance: suite green after every item; bench deltas noted per item in this plan.


### M5 — Cache mechanics

Scope: `en-core/src/En/Cache.hs`, two changes:

1. **Disabled path is read-only**: `lookupCache` with `not enabled || maxEntries <= 0`
   becomes `pure Nothing` (no `atomicModifyIORef'`); enabled-path stat writes are
   unchanged. Update the disabled-cache stats test per the Decision Log (stats stay
   all-zero when disabled).
2. **O(log n) eviction**: extend `CacheState` with `bySequence :: !(Map Int key)`
   maintained alongside `entries` (insert adds both; re-inserting an existing key must
   drop its old sequence entry — look up the old `CacheEntry.sequenceNumber` first).
   `evictOldest` becomes `Map.lookupMin bySequence` + two deletes per victim. Delete
   `oldestKey`. The existing eviction test ("bounded cache evicts oldest entry",
   `en-core/test/Main.hs` lines ~690–700) must pass unchanged — FIFO semantics are
   preserved by construction.

```bash
cabal test en-core:en-core-interface-tests
```

Acceptance: cache tests green (with the one documented rewrite); a quick bench of
repeated `insertCache` past capacity (add a micro-bench `cache/evict-churn` to
`en-core/bench/Main.hs`) shows the improvement.


### M6 — Relocate the EntryPoint machinery

Scope: engines stop paying for renderer metadata. Per the Decision Log:

1. `en-core/src/En/Reachability.hs`: remove `entries` from `ReachabilityGraph`; keep
   `EntryPoint`, `EntryKind`, `SubjectSelector`, `RewriteStep` and the compilation
   (`compileRelation`/`compileRewrite`) but expose them through a standalone pure
   function `entryPoints :: ValidSchema -> Map RelationRef [EntryPoint]` (same
   construction `compile` performs today, minus the graph embedding). `compile` now
   builds only `relations`, `caveats`, `hash`.
2. `en-core/src/En/Schema/Render.hs`: `renderReachabilityMermaid` takes the entries map
   (or a `ValidSchema` and calls `entryPoints` itself — pick whichever keeps its one
   test call site simplest and record it). Check `renderReachabilityMermaid`'s callers
   (tests; docs tooling from docs/plans/24 if any scripts call it) and update.
3. `en-core/test/Main.hs`: the `hasEntry` reachability assertions (lines ~277–281 and
   the wildcard entry check ~388) switch from `graph.entries` to
   `entryPoints validKikan`. The assertions' content is unchanged — they test the
   compilation, which still exists, just not on the hot struct.
4. Leave a breadcrumb comment at `entryPoints` naming review finding E12
   (explain/trace) as the prospective next consumer.

```bash
cabal build all
cabal test all
```

Acceptance: everything green; `ReachabilityGraph` no longer carries `entries` (grep
proves no engine references remain); renderer output tests byte-identical.


### M7 — After-numbers and the evidence table

Re-run the full bench suite and record:

```bash
cabal bench en-core:en-core-bench --benchmark-options='--csv en-core/bench/after-ep44.csv'
```

Build a small before/after table in this plan (benchmark name, before, after, delta)
from `before-ep44.csv`/`after-ep44.csv`, and refresh `en-core/bench/baseline.csv` with
the new numbers if that file's convention is to track the current expected baseline
(confirm its provenance at M0 — if it belongs to docs/plans/17's regression flow,
follow that flow's update procedure instead of overwriting silently).


### Final — wrap-up

Full suite; Outcomes & Retrospective; tick the EP-44 rows in
`docs/masterplans/7-fix-the-en-evaluation-engine.md`; Revision Note here.

```bash
cabal build all
cabal test all
```


## Concrete Steps

All commands from `/Users/shinzui/Keikaku/bokuno/en`:

```bash
cabal build all
cabal test all                                   # M0 baseline, Final
cabal bench en-core:en-core-bench                # M0/M1/M4/M5/M7 measurements
cabal bench en-core:en-core-bench --benchmark-options='--csv en-core/bench/before-ep44.csv'   # M0
cabal bench en-core:en-core-bench --benchmark-options='--csv en-core/bench/after-ep44.csv'    # M7
cabal test en-core:en-core-interface-tests       # M2/M4/M5/M6 inner loop
cabal test en-core:en-core-conformance
cabal test en-servant:en-servant-tests           # M3
```

Record here as work proceeds: the M0 landed-plan inventory; the M1 baseline bench
lines (expected shape below); per-item M4 deltas; the M7 table.

```text
check
  wide-member:      OK
    XXX μs ± XX μs
  deep-nested:      OK
    XXX μs ± XX μs
```

(tasty-bench output shape; real numbers replace the placeholders.)


## Validation and Acceptance

1. **Budgets are configuration**: a test constructs
   `defaultEvaluationBudget{maxDepth = 3}` and observes `Left
   ResolutionLimitExceeded` on a depth-4 chain that succeeds under defaults; a
   `pageLimit = 10` budget returns the identical 1,200-object lookup result set
   (batch size is invisible to semantics). No engine module contains a private
   depth/page/cap constant: `grep -rn "maxDepth\|resultCap" en-core/src/En/Check.hs
   en-core/src/En/Lookup.hs en-core/src/En/Expand.hs` shows only budget-field reads.
2. **Default behavior unchanged**: the entire pre-existing suite passes without
   modifying any assertion except the two documented rewrites (disabled-cache stats,
   and none other expected — every additional test change requires its own Decision
   Log entry).
3. **Hot-path evidence**: the M7 before/after table shows improvements on
   `check/wide-*`, `check/deep-nested`, `lookup/wide-fanout`, `expand/deep-nested`,
   and `cache/evict-churn`, with the raw CSVs (`en-core/bench/before-ep44.csv`,
   `after-ep44.csv`) checked in alongside. No benchmark regresses beyond noise
   (tasty-bench ±).
4. **Cache mechanics**: disabled caches perform no `IORef` writes on lookup (asserted
   via the rewritten stats test: all-zero stats after traffic); eviction preserves
   FIFO victims (existing test unchanged) with the `Map.lookupMin` implementation.
5. **EntryPoint relocation**: `ReachabilityGraph` has no `entries` field; the mermaid
   reachability renderer and its tests still produce byte-identical output through
   `En.Reachability.entryPoints`; engines compile without importing `EntryPoint`.


## Idempotence and Recovery

Everything is code, tests, and benchmark CSVs — re-runnable, no migrations, no
persistent state. Benchmarks are the only environment-sensitive step: run them on a
quiet machine and prefer relative deltas over absolute times; keep the before/after
CSVs from the same machine and GHC. Land M4's items as one commit each so any
regression bisects to a single transformation; M2's wrapper strategy means a botched
threading reverts to a single commit without touching call sites. If M6 turns up an
unexpected `entries` consumer (something outside render/tests), stop, record it in
Surprises & Discoveries, and downgrade M6 to "keep field, build lazily" pending a
follow-up decision — the rest of the plan does not depend on it.


## Interfaces and Dependencies

No new package dependencies (`containers` covers the Set/Map work; `psqueues`
explicitly rejected in the Decision Log; `tasty-bench` already drives the bench suite).

End-state interfaces (full module paths):

- `En.Budget.EvaluationBudget { maxDepth, pageLimit, resultCap :: Int }` and
  `En.Budget.defaultEvaluationBudget`, exposed from `en-core` (new `exposed-modules`
  entry in `en-core/en-core.cabal`).
- `En.Check.checkWithBudget`, `En.Check.checkCachedWithBudget`,
  `En.Check.checkManyWithBudget`; `En.Lookup.lookupWithDeadlineAndBudget` (and cached
  variant); `En.Expand.expandWithBudget` — each `EvaluationBudget`-first; existing
  names preserved as default-budget wrappers with unchanged signatures.
- `En.Servant.Seam.Env` gains `budget :: !EvaluationBudget`; `en-server/app/Main.hs`
  constructs it (validated config deferred to docs/plans/38).
- `En.Decision.dedupeObligations` and `En.Caveat.dedupe` order-preserving and
  O(n log n); `CaveatObligation` gains `Ord`.
- `En.Cache`: read-only disabled path; `CacheState.bySequence :: Map Int key`;
  `oldestKey` deleted. Public API (`newCache`/`lookupCache`/`insertCache`/`cacheStats`)
  unchanged.
- `En.Reachability`: `ReachabilityGraph` without `entries`;
  `entryPoints :: ValidSchema -> Map RelationRef [EntryPoint]` exported;
  `En.Schema.Render.renderReachabilityMermaid` consumes it.
- `en-core/bench/Main.hs`: groups `check-wide`, `check/deep-nested` (naming reconciled
  with any EP-39 additions), `lookup/wide-fanout`, `expand/deep-nested`,
  `cache/evict-churn`; CSVs `en-core/bench/before-ep44.csv` / `after-ep44.csv`.

Consumed from other plans (all land before this one per the master plan's soft
ordering): the probe-first check shape from docs/plans/39; the short-circuit folds from
docs/plans/40; the residual-cache value type from docs/plans/41 (cache mechanics here
are value-type-agnostic); the lookup traversal/deadline structure from docs/plans/42
(the single-merge change must respect its watermark ordering); operator-preserving
expand from docs/plans/43 (deep-nesting bench expands through operator nodes). Consumed
by: docs/plans/38 (config record hosts the budget) and future explain/trace work
(`entryPoints`).
