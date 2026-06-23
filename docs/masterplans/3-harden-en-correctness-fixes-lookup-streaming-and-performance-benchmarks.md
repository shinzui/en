---
id: 3
slug: harden-en-correctness-fixes-lookup-streaming-and-performance-benchmarks
title: "Harden en: correctness fixes, lookup streaming, and performance benchmarks"
kind: master-plan
created_at: 2026-06-23T16:35:18Z
intention: "intention_01kvv5mecvechb6c6jv3p3zv4a"
---


# Harden en: correctness fixes, lookup streaming, and performance benchmarks

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

`en` (縁) is the relationship-based authorization (ReBAC) toolkit built by MasterPlan 1
(`docs/masterplans/1-build-en-rebac-authorization-toolkit.md`). It works end to end — engine
(`en-core`), PostgreSQL store and consistency tokens (`en-postgres`/`en-migrations`), Servant
service and client (`en-servant`/`en-server`/`en-client`) — and a lookup spike already produced
green numbers. A design review then found a set of correctness gaps, fidelity gaps, and validation
gaps that should be closed before `en` is trusted in production. This initiative closes them.

After this initiative: (1) the PostgreSQL snapshot-visibility comparison that underpins the
"new-enemy" read-your-writes guarantee is a faithful port proven against a reference oracle by a
property test, point-in-time tokens cannot read vacuumed data, and soft-deleted tuples are reaped;
(2) caveats are evaluated by a generic typed evaluator driven by each consumer's schema — not a
hardcoded kikan special case — and the three-valued decision algebra lives in one shared module
instead of being copy-pasted across `check`, `lookup`, and `expand`; (3) `lookup` is genuinely
streaming with a resumable cursor and a deadline budget, so a multi-page intermediate read no longer
hard-fails; (4) the lookup spike actually traverses an intersection/exclusion path, runs at the
10,000,000-row scale the spec set as its bar, and reports real percentiles, and a `tasty-bench`
benchmark suite guards `check`/`lookup`/consistency against future performance regressions in CI;
and (5) the fail-closed `requirePermission` combinator is exercised on a real guarded route, and the
kikan schema with its agency cross-org sharing scenario is proven as the day-one conformance case.

Explicitly out of scope: caching of any kind. Optimized-revision (quantization) caching, tuple-read
caching, and authorization-decision caching are owned by **MasterPlan 2,
`docs/masterplans/2-add-caching-support-to-en.md`** (its EP-9 through EP-13). This initiative does
not implement caches; it fixes correctness, streaming, validation, and conformance. Where the two
MasterPlans touch the same files, the Integration Points section below defines the boundary. Also out
of scope: a distributed/materialized reverse index (Leopard), a Watch API, and multi-tenant Spaces
(deferred per the `en` spec `docs/spec/0001-en-overview.md` §1 and kikan C13).


## Decomposition Strategy

The review's findings cluster by functional concern, which is the decomposition. Consistency
correctness is one stream because the snapshot comparator, the GC window, the token codec, the
write-snapshot anchoring, and the `deleted_xid` sentinel are one cohesive correctness surface in
`en-postgres`/`en-migrations`/`En.Revision`, and a bug in any of them is the same class of failure (a
stale or cross-tenant read). The caveat evaluator and the duplicated decision algebra are one stream
because removing the hardcoded caveat logic and extracting the shared decision module are the same
edit to `En.Check` and `En.Lookup` (auditing `En.Expand`, which builds an audit tree and computes no
decision). Lookup streaming is its own stream because replacing the
eager-compute-then-cap traversal with a resumable, deadline-bounded one is a self-contained algorithm
change in `En.Lookup` and the `en-postgres` reads behind it. Validation-and-benchmarks is one stream
because the spike fixes, the 10M run, and the `tasty-bench` regression suite are all
measurement infrastructure with no production-code dependency. Conformance is its own stream because
it consumes the others to prove an end-to-end story (a guarded route plus the kikan agency scenario)
rather than changing the engine.

The originally-proposed sixth stream — quantized optimized revision and decision caching — was
**removed** after discovering MasterPlan 2 already owns it (EP-9 optimized-revision caching is exactly
the "quantization is missing, `optimizedRevision = headRevision`" finding; EP-11 is decision caching).
Duplicating it here would create two plans editing the same `optimizedRevision` path. Instead this
MasterPlan records the cross-MasterPlan integration and lets MasterPlan 2 own caching. A single
omnibus "fix everything" plan was rejected because it would couple snapshot-visibility correctness,
graph-traversal streaming, and benchmark tooling into one unreviewable change; the streams (now six, after EP-19 was added — see the Decision Log) are
each independently verifiable.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-14 | Harden consistency: faithful snapshot visibility, GC window, and token reconciliation | docs/plans/14-harden-consistency-faithful-snapshot-visibility-gc-window-and-token-reconciliation.md | None | None | Complete |
| EP-15 | Generalize the caveat evaluator and unify the decision algebra | docs/plans/15-generalize-the-caveat-evaluator-and-unify-the-decision-algebra.md | None | None | Complete |
| EP-16 | Make lookup streaming with resumable cursors and a deadline budget | docs/plans/16-make-lookup-streaming-with-resumable-cursors-and-a-deadline-budget.md | None | EP-15 | Complete |
| EP-17 | Strengthen the lookup spike and add performance-regression benchmarks | docs/plans/17-strengthen-the-lookup-spike-and-add-performance-regression-benchmarks.md | None | EP-14, EP-15, EP-16 | Not Started |
| EP-18 | Conformance: a guarded route example and the kikan agency proof | docs/plans/18-conformance-a-guarded-route-example-and-the-kikan-agency-proof.md | None | EP-15, EP-16 | Not Started |
| EP-19 | Add BatchCheck for GraphQL field-capability and candidate filtering | docs/plans/19-add-batchcheck-for-graphql-field-capability-and-candidate-filtering.md | None | EP-15 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.


## Dependency Graph

There are no hard dependencies; every plan can begin against the current tree. The soft dependencies
describe what each plan *benefits* from, and define three natural waves.

**Wave 1 (start immediately, fully parallel): EP-14 and EP-15.** EP-14 (consistency) touches only
`en-postgres/src/En/Postgres/Revision.hs`, `en-postgres/src/En/Postgres/TupleStore.hs`,
`en-migrations`, and `en-core/src/En/Revision.hs`. EP-15 (caveats + decision algebra) touches only
`en-core/src/En/Schema.hs`, `En/Check.hs`, `En/Lookup.hs`, `En/Expand.hs` and a new shared decision
module. The two streams do not share files, so they proceed in parallel. EP-17's spike fixes and
benchmark scaffolding and EP-18's guarded-route example also have no hard prerequisite and may begin
in Wave 1, though they only become *meaningful* once the fixes they measure/exercise land.

**Wave 2: EP-16 (lookup streaming).** It softly depends on EP-15 because EP-15 extracts the shared
decision-algebra module (`En.Decision`) that `lookup`'s reach-then-check confirmation should call; if
EP-16 runs first it must either temporarily duplicate that logic or coordinate the extraction. Doing
EP-15 first avoids re-touching `En.Lookup` twice.

**Wave 3: EP-17 (validation + benchmarks) and EP-18 (conformance).** EP-17 softly depends on EP-14,
EP-15, and EP-16 because the regression baselines and the 10M run should measure the *fixed* engine
(notably the streaming `lookup` from EP-16 and the real exclusion traversal it enables). EP-18 softly
depends on EP-15 (the kikan agency scenario uses autonomy-leveled, caveated delegation, which needs
the generic caveat evaluator) and EP-16 (the read-filter conformance exercises streaming `lookup`).
Both can be drafted earlier but should be *finalized* last.

**EP-19 (BatchCheck)** belongs in this wave too. It softly depends on EP-15 (it evaluates many checks
through the shared `En.Decision` path) and on MasterPlan 2 EP-11
(`docs/plans/11-implement-authorization-decision-caching.md`), whose per-revision decision cache makes
a batch of overlapping checks cheap; EP-17 benchmarks it. A correct `BatchCheck` that simply folds
`check` over the batch (resolving consistency once, with a within-call subproblem memo) can be built as
soon as EP-15 lands — the cache is an efficiency layer, not a correctness prerequisite.


## Integration Points

**1. The PostgreSQL revision path (`en-postgres/.../Revision.hs`, `.../TupleStore.hs`) — shared with
MasterPlan 2.** EP-14 (this MasterPlan) owns the *correctness* of snapshot comparison
(`comparePgSnapshot`/`snapshotIncludes`), the consistency token codec, write-snapshot anchoring, and
the `optimizedRevision` *semantics as currently defined* (today `optimizedRevision = headRevision`).
MasterPlan 2 EP-9 (`docs/plans/9-implement-optimized-revision-caching.md`) owns *replacing*
`optimizedRevision` with a quantized, bounded-age cached snapshot. These edit the same two files.
**Boundary:** EP-14 must land its comparator/oracle fix first (so MasterPlan 2 quantization is built
on a correct comparison), and must not itself implement quantization. MasterPlan 2 EP-9 must build its
quantized revision on top of EP-14's corrected `comparePgSnapshot` and must keep EP-14's
`AtLeastAsFresh = max(optimized, token)` partial-order logic intact. Whichever lands second rebases
onto the first; coordinate before either merges.

**2. The shared decision-algebra module (`en-core/src/En/Decision.hs`, new) — shared with MasterPlan
2.** EP-15 (this MasterPlan) defines `En.Decision` (the three-valued `Allowed`/`Denied`/`Conditional`
union/intersection/exclusion/caveat-gate combinators) and rewrites `En.Check` and `En.Lookup` to use
it instead of their copy-pasted copies (auditing `En.Expand`, which builds an audit tree and computes
no decision). MasterPlan 2 EP-11
(`docs/plans/11-implement-authorization-decision-caching.md`) wraps `En.Check` and the lookup
confirmation path with a decision cache. **Boundary:** EP-15 owns the *shape* of the decision
functions; EP-11 wraps them without changing their results. If EP-15 lands first (preferred), EP-11
caches the unified functions; if EP-11 lands first, EP-15 must preserve the cache key/seam EP-11
introduced.

**3. The `lookup` traversal and its cursor (`en-core/src/En/Lookup.hs`, `en-servant` pagination
wire).** EP-16 owns the resumable cursor and deadline budget that replace the eager
`runLookup`/`pageLookup`/`ensureExhausted` path. The Servant `LookupStateWire`
(exhausted/has-more/truncated) in `en-servant/src/En/Servant/API.hs` already exists; EP-16 makes the
cursor it carries a real resumable token rather than an integer offset. EP-17 benchmarks this path and
EP-18 consumes it for read-filter conformance; both must use EP-16's final cursor contract.

**4. The lookup spike harness and the benchmark suite (`en-postgres/lookup-spike/`, a new
`tasty-bench` target).** EP-17 owns both. MasterPlan 2 EP-13 validation may reuse the benchmark
harness to measure cache-hit performance; EP-17 should keep the bench target independent of cache
configuration so both MasterPlans can run it.

**5. The `relation_tuple` schema and the `deleted_xid` sentinel
(`en-migrations/db/migrations/*.sql`).** EP-14 owns the decision between the current `deleted_xid IS
NULL = live` and the spec's `sentinel max-xid = live`, and the historical-read index. Any other plan
that writes or reads tuples (EP-16's streaming reads, EP-18's conformance fixtures) must use whatever
EP-14 settles; EP-14 should land its migration early in Wave 1 to avoid churn.

**6. The kikan schema value and `requirePermission` (`en-servant/src/En/Servant/Authorize.hs`, a new
example/conformance target).** EP-18 owns the kikan `Schema` fixture (spaces, orgs, intentions,
`guest_org`, visibility-class containers, autonomy-/time-caveated delegation) and the guarded-route
example. It consumes EP-15's caveat evaluator and EP-16's streaming `lookup`.

**7. The batch-check path (`En.Check`/`En.Decision`, an `en-servant` batch endpoint, `en-client`) —
shared with MasterPlan 2 and the kikan GraphQL gateway.** EP-19 adds a `BatchCheck` that evaluates many
`(subject, permission, object)` pairs under one resolved revision with shared subproblem memoization,
plus the matching `en-servant` endpoint and `en-client` method. It is the server-side realization of
the `checkMany` helper described in `docs/user/graphql-integration.md` (the gateway's field-capability
and candidate-filtering path). EP-19 owns the batch API shape; MasterPlan 2 EP-11's decision cache is
what makes overlapping pairs *across requests* cheap (compose: EP-19 is the surface and the
within-request memo, EP-11 the cross-request cache). EP-17 benchmarks the batch path as the
GraphQL-field workload.


## Progress

- [x] EP-14: Replace `snapshotIncludes` with a faithful port and prove it against a reference oracle via a property test.
- [x] EP-14: Add a GC-window check for `AtExactSnapshot`/`AtLeastAsFresh` tokens and a soft-delete reaper job.
- [x] EP-14: Anchor the write-returned token to the transaction's own snapshot (stop using a post-commit `pg_current_snapshot()`), or document why not.
- [x] EP-14: Reconcile the `deleted_xid` sentinel (NULL vs max-xid) and add an index that serves point-in-time reads of since-deleted rows; reconcile the token format (base64-proto + ISO-8601 expiry) and remove the `En.Revision.compareRevision` error stub.
- [x] EP-15: Replace the hardcoded `within_autonomy`/`requested_autonomy` caveat logic with a generic typed evaluator over `CaveatDefinition`/`CaveatParameterType`.
- [x] EP-15: Extract the three-valued decision algebra into `En.Decision` and use it from `En.Check` and `En.Lookup` (audit `En.Expand`, which computes no decision); remove the `evalThis` error partial; model wildcard/public subjects.
- [x] EP-16: Replace eager-compute-then-cap `lookup` with a resumable cursor and a deadline budget; remove the `ensureExhausted` hard-fail on multi-page intermediate reads.
- [x] EP-16: Prove a `lookup` that spans multiple storage pages returns complete, correctly-cursored results without erroring.
- [ ] EP-17: Fix the spike so the intersection/exclusion variant actually traverses an exclusion; run the 10,000,000-row sweep; widen percentile sampling; add a large-reachable-set subject case.
- [ ] EP-17: Add a `tasty-bench` suite for `check`/`lookup`/consistency with recorded baselines and a CI regression gate.
- [ ] EP-18: Wire `requirePermission` into a real guarded route with a test proving fail-closed behavior (deny, conditional, and engine-error all 403/500).
- [ ] EP-18: Encode the kikan schema and prove the agency cross-org sharing scenario (guest org sees a subset; sensitive items hidden) end to end.
- [ ] EP-18: Add a GraphQL-resolver-style guarded example (the `en-client`-driven object gate inside a resolver) alongside the Servant `requirePermission` route, mirroring `docs/user/graphql-integration.md`.
- [ ] EP-19: Add a `BatchCheck` engine operation (many pairs, one resolved revision, shared subproblem memo, bounded concurrency, order-preserving, fail-closed per pair) plus an `en-servant` batch endpoint with a max-batch-size and an `en-client` method.
- [ ] EP-19: Prove a batch of overlapping checks returns correct per-pair three-valued decisions and shares subproblem work versus N single calls (and benchmark it under EP-17).


## Surprises & Discoveries

- The originally-proposed quantized-optimized-revision / decision-caching workstream is already owned
  by MasterPlan 2 (`docs/masterplans/2-add-caching-support-to-en.md`): its EP-9 is exactly the
  "`optimizedRevision = headRevision`, quantization missing" review finding, and its EP-11 is decision
  caching. This MasterPlan therefore drops that stream and records the cross-MasterPlan integration in
  Integration Points 1 and 2 instead of duplicating it. _(2026-06-23)_
- Drafting the child plans surfaced four facts that shaped them: (1) the duplicated decision algebra
  lives only in `En.Check` and `En.Lookup` — `En.Expand` builds an audit tree and computes no
  `CheckDecision`, so EP-15 audits Expand rather than rewiring it. (2) The kikan schema fixture and much
  of the agency `check` scenario already exist as private fixtures in `en-core/test/Main.hs` (built by
  MasterPlan 1), so EP-18 is extraction + completion, not authoring. (3) The repo has no CI yet (no
  `.github/workflows`), so EP-17's regression gate is greenfield CI. (4) The spike's §7 "green" verdict
  was recorded at 1M rows though the spec §4 bar is 10M — the gap EP-17 closes. _(2026-06-23)_
- EP-14's PostgreSQL oracle found that snapshot inclusion cannot be reduced to
  `candidate.xmax >= required.xmax`: a lower-`xmax` snapshot can include a higher-`xmax` snapshot if
  the entire gap is present in the required snapshot's `xip`. EP-14 therefore landed a gap-coverage
  rule rather than the initial simplified formula. _(2026-06-23)_
- EP-14 also proved that the raw `pg_current_snapshot()` stored inside a write transaction does not
  see the write's own xid when used later as a token revision. The returned token now stays anchored
  to the write xid but constructs a write-visible snapshot from it. _(2026-06-23)_
- EP-15 landed the generic caveat evaluator, shared decision algebra, and explicit wildcard subject
  model. Wildcard tuples match concrete `SubjectId` values of the same type only; userset subjects are
  intentionally not matched by `type:*`. _(2026-06-23)_
- EP-16 landed drained multi-page lookup reads, revision-pinned object-key cursors, the deadline seam
  and Servant `deadlineMillis` field, plus a PostgreSQL integration proof over 1,500 rows.
  _(2026-06-23)_


## Decision Log

- Decision: Scope this MasterPlan to the review's correctness/fidelity/validation gaps and exclude all
  caching.
  Rationale: MasterPlan 2 already owns caching (optimized-revision/quantization, tuple-read, and
  decision caching). Duplicating it would put two plans on the same `optimizedRevision` and
  `En.Check` seams. Cross-MasterPlan boundaries are captured in Integration Points 1 and 2.
  Date: 2026-06-23

- Decision: Five child plans (EP-14..EP-18) grouped by functional concern, with no hard dependencies.
  Rationale: The streams touch disjoint files in Wave 1 (consistency vs caveats), and the remaining
  streams (streaming, validation, conformance) layer on via soft dependencies. This maximizes parallel
  progress and keeps each plan independently verifiable, per the decomposition principles.
  Date: 2026-06-23

- Decision: EP-14 lands the snapshot-comparator fix and the `deleted_xid`/migration decision early in
  Wave 1.
  Rationale: Both are integration points (with MasterPlan 2's quantization and with every tuple
  reader/writer). Settling them first prevents downstream rebasing.
  Date: 2026-06-23

- Decision: Treat the quantization gap as MasterPlan 2's responsibility, not a bug to fix here, but
  require EP-14's corrected comparator to land before MasterPlan 2 EP-9 builds quantization on it.
  Rationale: Quantization that shares snapshots is only safe atop a correct partial-order comparison;
  fixing correctness first is the right order across the two MasterPlans.
  Date: 2026-06-23

- Decision: Add EP-19 (BatchCheck) to the decomposition after the initial five plans, prompted by the
  kikan decision to put a GraphQL gateway in front of all services.
  Rationale: GraphQL resolution fans out — field-capability fields (`canEdit`/`canShare`/…) and
  candidate post-filtering need many object×permission decisions per request. `en` exposes only single
  `check` today, so the `checkMany` helper in `docs/user/graphql-integration.md` would cost N
  round-trips. A server-side `BatchCheck` (one resolved revision, shared subproblem memoization) is the
  right surface; it composes with MasterPlan 2 EP-11's decision cache and is benchmarked by EP-17.
  EP-18 additionally gains a resolver-style guarded example so the GraphQL pattern is proven, not just
  documented.
  Date: 2026-06-23

- Decision: Mark EP-14 complete after landing the consistency hardening implementation.
  Rationale: The child plan's source changes, migration/spec cleanup, and validation are complete:
  `cabal build all`, `cabal test en-postgres-revision-tests`, and
  `cabal test en-postgres-integration-tests` passed. EP-14 also recorded the oracle-discovered
  comparator correction and the write-token fallback in its living sections.
  Date: 2026-06-23


## Outcomes & Retrospective

(To be filled during and after implementation.)


---

**Revision note (2026-06-23).** Added EP-19 (BatchCheck) to support the kikan GraphQL gateway: a new
registry row, a Wave-3 dependency-graph note, Integration Point 7 (the batch path, shared with
MasterPlan 2 EP-11 and realizing the `checkMany` helper in `docs/user/graphql-integration.md`), and
Progress bullets. Updated EP-18's scope with a GraphQL-resolver-style guarded example. Amended
`docs/user/graphql-integration.md` with the planned `BatchCheck`, the Relay-cursor alignment with
EP-16, and a deny-by-default directive note. Changed the Decomposition wording from "five streams" to
"streams" and noted the sixth.
