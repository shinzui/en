---
id: 2
slug: add-caching-support-to-en
title: "Add Caching Support to en"
kind: master-plan
created_at: 2026-06-23T15:06:38Z
intention: "intention_01kvtg84azehbsj9zgsfd71y90"
---

# Add Caching Support to en

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

This initiative adds production-grade in-process caching support to `en` so protected request paths can reuse resolved revisions, tuple reads, and authorization subproblems without changing the semantics of `check`, `lookup`, `expand`, or consistency tokens. After completion, a user running the embedded library or standalone service can enable bounded caches, observe cache hit and miss counters in tests or service logs, and verify that repeated authorization queries at the same resolved revision avoid repeated PostgreSQL reads or repeated graph traversal.

The work is deliberately local and conservative. It includes an optimized revision cache for `MinimizeLatency`, core cache interfaces and statistics, a tuple-read cache wrapper around `TupleStore`, a decision/subproblem cache for repeated `check` work and lookup confirmations, service wiring through environment variables, documentation, and validation tests. It explicitly excludes a distributed cache, cross-process invalidation, a Watch API, a materialized reverse index, and any behavior that reuses a decision across a different datastore id, schema hash, resolved revision, subject, object, permission, or caveat context.

The implementation must preserve the current safety rule: protected operations fail closed unless the engine returns `Allowed`. Cache misses must behave exactly like the uncached engine. Cache hits must only return results that would have been valid at the same resolved revision and schema hash.


## Decomposition Strategy

The initiative is decomposed by cache layer, ordered from the lowest-risk freshness primitive to higher-level cached decisions. Optimized revision caching comes first because it makes `MinimizeLatency` actually share a snapshot; without that, result caches have poor hit rates. Core cache interfaces and configuration come next because tuple-read and decision caches need a shared vocabulary for bounded maps, keys, statistics, and disabled-by-default configuration.

Tuple-read caching and authorization decision caching are separate work streams. Tuple-read caching wraps the storage boundary and can be proven with counting stores before changing the algorithms. Decision caching touches `En.Check` and the lookup confirmation path, so it depends on stable cache interfaces and benefits from tuple-read cache tests but should remain independently verifiable. Final service wiring and validation come last because it consumes all cache layers and turns them into operational behavior.

An alternative single large plan was rejected because it would couple revision semantics, cache data structures, graph traversal changes, and service configuration in one difficult review. A distributed cache plan was rejected because `en` currently targets one organization on PostgreSQL and should first get correct in-process cache semantics, matching the local-process cache pattern documented in OpenFGA and the server-side cache pattern used by SpiceDB.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-9 | Implement optimized revision caching | docs/plans/9-implement-optimized-revision-caching.md | None | None | Complete |
| EP-10 | Add core cache interfaces and configuration | docs/plans/10-add-core-cache-interfaces-and-configuration.md | None | EP-9 | Complete |
| EP-12 | Implement tuple read caching | docs/plans/12-implement-tuple-read-caching.md | EP-10 | EP-9 | Not Started |
| EP-11 | Implement authorization decision caching | docs/plans/11-implement-authorization-decision-caching.md | EP-10 | EP-12 | Not Started |
| EP-13 | Wire caching into service operations and validation | docs/plans/13-wire-caching-into-service-operations-and-validation.md | EP-9, EP-10, EP-11, EP-12 | None | Not Started |

**Cross-MasterPlan ordering (decided 2026-06-23).** MasterPlan 3 (en hardening) is implemented **in full
before** this MasterPlan. That order satisfies both hard cross-MasterPlan prerequisites naturally — **EP-9
requires MasterPlan 3 EP-14** (`docs/plans/14-harden-consistency-faithful-snapshot-visibility-gc-window-and-token-reconciliation.md`,
the faithful snapshot comparator) and **EP-11 requires MasterPlan 3 EP-15**
(`docs/plans/15-generalize-the-caveat-evaluator-and-unify-the-decision-algebra.md`, the shared
`En.Decision` module) — with no "pull-forward" carve-out and no rebase risk. By the time this MasterPlan
starts, every plan of MasterPlan 3 is complete, so EP-14 and EP-15 are *completed prerequisites*. The one
edge that points the other way — MasterPlan 3 EP-19 (BatchCheck) softly wanting EP-11's decision cache —
is an efficiency-only dependency that degrades gracefully: EP-19 ships first as a correct `check` fold
without the cross-request cache, and EP-11 (this MasterPlan) upgrades it when it lands. See the Dependency
Graph, Integration Points, and Decision Log.


## Dependency Graph

EP-9 can start immediately. It changes `en-postgres/src/En/Postgres/TupleStore.hs` and `en-postgres/src/En/Postgres/Revision.hs` so `optimizedRevision` can return a bounded-age cached snapshot instead of always calling `headRevisionSession`. This does not require the higher-level cache abstractions, but later caches benefit from it because many `MinimizeLatency` reads will resolve to the same `Revision`. **Cross-MasterPlan hard prerequisite (satisfied by ordering):** EP-9 builds on MasterPlan 3 EP-14 (`docs/plans/14-harden-consistency-faithful-snapshot-visibility-gc-window-and-token-reconciliation.md`), which is already complete because MasterPlan 3 lands in full first. EP-14 replaces the current finite-probe `snapshotIncludes` — which it proves is unsound (the "xmax-gap" false-include) — with a faithful, oracle-tested comparator. EP-9 shares snapshots by quantizing the optimized revision, so a wrong partial-order comparison underneath it would be a correctness risk, not a cosmetic one; building on EP-14's corrected comparator removes that risk. EP-9 must preserve EP-14's `AtLeastAsFresh = max(optimized, token)` partial-order semantics.

EP-10 can also start immediately, though it has a soft dependency on EP-9 for naming consistency around freshness windows. EP-10 owns the shared cache types in `en-core`, including bounded in-memory map behavior, cache statistics, and cache key data types that include datastore id, schema hash, and revision. EP-12 and EP-11 both depend hard on EP-10 because they must use the same cache implementation and stats model.

EP-12 depends hard on EP-10 because tuple-read caching requires the shared bounded cache and statistics types. It has a soft dependency on EP-9 because optimized revisions improve hit rates, but the tuple-read wrapper can be implemented and tested with a fixed test revision before EP-9 is complete.

EP-11 depends hard on EP-10 because decision caching needs shared key and stats types. It has a soft dependency on EP-12 because both cache layers can be tested independently, but decision-cache performance validation is easier when tuple reads can also be counted. EP-11 must not depend hard on EP-12; a user should be able to enable decision caching without tuple-read caching. **Cross-MasterPlan hard prerequisite (satisfied by ordering):** EP-11 builds on MasterPlan 3 EP-15 (`docs/plans/15-generalize-the-caveat-evaluator-and-unify-the-decision-algebra.md`), already complete because MasterPlan 3 lands in full first; EP-15 extracts the three-valued algebra into a shared `En.Decision` module and rewires `En.Check`/`En.Lookup` to use it. EP-11 caches the `CheckDecision` produced by `En.Check`'s `runCheck` subproblem evaluation (the monadic, tuple-reading work) — keyed by datastore id, schema hash, resolved revision, subject, relation, object, and caveat context — without changing its three-valued result. `En.Decision` is the *seam* (it freezes the `CheckDecision` shape EP-11 caches), not itself the cache target; EP-15 first keeps that seam stable so EP-11 never has to rebase the cache key onto a moving decision type. **Cross-MasterPlan consumer:** MasterPlan 3 EP-19 (`docs/plans/19-add-batchcheck-for-graphql-field-capability-and-candidate-filtering.md`, BatchCheck) composes on top of EP-11 — EP-19 is the per-request batch surface with a within-call subproblem memo, and EP-11's per-revision decision cache is what makes pairs that overlap *across* requests cheap. Because MasterPlan 3 lands first, EP-19 ships *before* EP-11 as a correct `check` fold with no cross-request cache, and EP-11 upgrades its cross-request efficiency when it lands. For that upgrade to be drop-in, EP-11's cache key must stay batch-friendly (a plain per-pair key under one resolved revision, no per-call state), so a batch fold over `checkCached` reuses entries naturally.

EP-13 depends on all earlier plans. It wires cache construction into `en-server/app/Main.hs`, updates `docs/user/production-deployment-and-performance.md`, adds service-level tests or transcripts, and records validation evidence. It should not begin until the lower-level cache APIs are stable. Cross-MasterPlan (soft, optional): EP-13's cache-hit performance validation may reuse the `tasty-bench` harness MasterPlan 3 EP-17 (`docs/plans/17-strengthen-the-lookup-spike-and-add-performance-regression-benchmarks.md`) builds, which EP-17 keeps independent of cache configuration for exactly this reason; if EP-17 has not landed, EP-13 validates with its own counting-store transcripts and does not block on it.


## Integration Points

The `Revision` selection path is shared by EP-9, EP-10, EP-12, EP-11, and EP-13. EP-9 defines how `MinimizeLatency` obtains a reusable optimized revision. Later plans must treat the resolved revision as part of every cache key and must not invent separate freshness semantics.

The core cache module is owned by EP-10. The expected artifact is a new module such as `en-core/src/En/Cache.hs`, exposed from `en-core/en-core.cabal`, with bounded cache construction, lookup/insert operations, configuration records, and statistics. EP-12 and EP-11 consume this module rather than creating independent cache maps.

The tuple-store boundary is shared by EP-12, EP-11, and EP-13. EP-12 owns a wrapper around `En.Effect.TupleStore.TupleStore` that caches `readObjectRelation` and `readStartingWithUser` results by resolved revision and read parameters. EP-11 can rely on this wrapper but must not change tuple-store semantics. EP-13 decides whether the service enables the wrapper.

The check and lookup algorithms are shared by EP-11 and EP-13. EP-11 owns changes to `en-core/src/En/Check.hs` and the lookup confirmation path in `en-core/src/En/Lookup.hs`. EP-13 only wires the resulting API into service configuration and docs.

The `.cabal` files are shared integration points. EP-10 may add `En.Cache` to `en-core/en-core.cabal`; EP-12 and EP-11 may add tests in `en-core/test/Main.hs`; EP-13 may add dependencies or environment parsing in `en-server/en-server.cabal` and `en-server/app/Main.hs`. Every plan that touches package metadata must keep `cabal build all` green.

The production docs are owned by EP-13. Earlier plans may update narrow API docs if needed, but EP-13 must reconcile the final user-facing story in `docs/user/production-deployment-and-performance.md`.

**Cross-MasterPlan integration with MasterPlan 3 (en hardening).** Two of this MasterPlan's caches sit
directly on surfaces MasterPlan 3
(`docs/masterplans/3-harden-en-correctness-fixes-lookup-streaming-and-performance-benchmarks.md`) is
correcting, and one of MasterPlan 3's plans sits on top of a cache this MasterPlan builds. **MasterPlan 3 is
implemented in full before this MasterPlan** (decided 2026-06-23 — see Decision Log), so EP-14 and EP-15
are completed prerequisites for EP-9 and EP-11 by the time this MasterPlan starts.

(1) **EP-9 ← EP-14 (completed prerequisite).** EP-9's quantized optimized revision is built on the PostgreSQL
snapshot comparison in `en-postgres/src/En/Postgres/Revision.hs`; MasterPlan 3 EP-14
(`docs/plans/14-harden-consistency-faithful-snapshot-visibility-gc-window-and-token-reconciliation.md`)
replaces the current finite-probe `snapshotIncludes` — which it proves is unsound (the xmax-gap
false-include, an `optimizedRevision = headRevision` read-your-writes / cross-tenant-leak risk) — with a
faithful, oracle-tested port. Quantization that *shares* a snapshot across requests is only safe atop a
correct partial order, so EP-9 must land after EP-14 and must preserve EP-14's
`AtLeastAsFresh = max(optimized, token)` partial-order semantics. EP-14 also fixes that
`optimizedRevision` aliases `headRevision` today and explicitly leaves quantization to EP-9, so the two
do not both edit the same seam at once.

(2) **EP-11 ← EP-15 (completed prerequisite).** MasterPlan 3 EP-15
(`docs/plans/15-generalize-the-caveat-evaluator-and-unify-the-decision-algebra.md`) extracts the
three-valued algebra into a shared `En.Decision` module and rewires `En.Check`/`En.Lookup` to use it.
EP-11's decision cache wraps `En.Check`'s `runCheck` subproblem evaluation — the monadic, tuple-reading
work — caching the resulting `CheckDecision` by datastore id, schema hash, resolved revision, subject,
relation, object, and caveat context, without changing the three-valued result. `En.Decision` is the
*seam* that freezes the `CheckDecision` shape EP-11 keys on; landing EP-15 first means EP-11 never
rebases its cache key onto a moving decision type. (The pure `En.Decision` combinators are cheap and are
*not* the cache target; the expensive, cacheable unit is the monadic `check`/subproblem path in
`En.Check`.)

(3) **EP-11 → EP-19 (this MasterPlan is the prerequisite).** MasterPlan 3 EP-19
(`docs/plans/19-add-batchcheck-for-graphql-field-capability-and-candidate-filtering.md`) adds a
`BatchCheck` for the kikan GraphQL gateway's field-capability and candidate-filtering fan-out. It
composes with EP-11: EP-19 is the per-request batch surface with a within-call subproblem memo, and
EP-11's per-revision decision cache is what makes pairs that overlap *across* requests cheap. EP-19 is a
correct fold of `check` even without EP-11 (the cache is an efficiency layer, not a correctness
prerequisite). Because MasterPlan 3 lands first, EP-19 ships before EP-11 in its uncached-fold form and
EP-11 later upgrades its cross-request efficiency; EP-11's cache key must stay batch-friendly — a plain
per-pair key under one resolved revision with no per-call state — so a batch fold over `checkCached`
reuses entries naturally once EP-11 lands.

With MasterPlan 3 implemented in full first, EP-9←EP-14 and EP-11←EP-15 are satisfied by construction (no
"whichever lands second rebases" reconciliation is needed). The only outstanding cross-MasterPlan edge is
the soft, gracefully-degrading EP-11→EP-19 efficiency upgrade.


## Progress

- [x] EP-9: Add an optimized revision cache configuration and implementation for PostgreSQL-backed stores.
- [x] EP-9: Prove `MinimizeLatency` can reuse a cached optimized revision while `FullyConsistent` still reads the head revision.
- [x] EP-10: Add shared bounded cache types, cache configuration, and cache statistics in `en-core`.
- [x] EP-10: Add focused tests proving cache keys include datastore id, schema hash, revision, and request-shaping values.
- [ ] EP-12: Add a `TupleStore` cache wrapper for object-relation and reverse userset reads.
- [ ] EP-12: Prove repeated tuple reads at the same revision hit cache and reads at different revisions miss.
- [ ] EP-11: Add decision/subproblem caching for forward `check` and lookup confirmation checks.
- [ ] EP-11: Prove repeated authorization checks reuse cached subproblems without changing `Allowed`, `Denied`, or `Conditional` results.
- [ ] EP-13: Wire cache configuration into `en-server` and embedded-library examples.
- [ ] EP-13: Update production docs and run full build/test validation with cache-enabled scenarios.


## Surprises & Discoveries

- A review of the implemented `en` confirmed the gap EP-9 targets: `optimizedRevision` currently
  aliases `headRevisionSession` in `en-postgres/src/En/Postgres/TupleStore.hs` (no quantization, no
  shared snapshot), so `MinimizeLatency` reads head every time and result-cache hit rates would be poor
  until EP-9 lands — exactly this MasterPlan's premise. _(2026-06-23)_
- Cross-MasterPlan coordination: MasterPlan 3
  (`docs/masterplans/3-harden-en-correctness-fixes-lookup-streaming-and-performance-benchmarks.md`)
  hardens the same `Revision`/`En.Check` surfaces this MasterPlan caches — its EP-14 fixes the
  `comparePgSnapshot`/`snapshotIncludes` partial-order comparison, and its EP-15 extracts a shared
  `En.Decision` module. EP-9 and EP-11 here must build on those (see the cross-MasterPlan Integration
  Points paragraph and Decision Log). _(2026-06-23)_
- Validation against MasterPlan 3 surfaced a one-directional dependency this MasterPlan had not
  recorded: MasterPlan 3 added **EP-19 (BatchCheck)** after its initial decomposition, and EP-19's
  dependency graph and Integration Point 7 declare a soft dependency on **this MasterPlan's EP-11** —
  EP-11's per-revision decision cache is what makes a batch of overlapping checks cheap across requests.
  Recorded as Integration Point (3) and a Decision Log entry so EP-11's cache key is designed to be
  batch-friendly. _(2026-06-23)_
- Validation also confirmed the child plans EP-9 and EP-11 carried **no** cross-MasterPlan references in
  their own bodies — all coordination lived only in this MasterPlan's prose. Since each ExecPlan must be
  self-contained for an implementer reading it in isolation, the cross-MasterPlan prerequisite notes
  were cascaded into EP-9, EP-11, and EP-13. _(2026-06-23)_
- EP-9 implementation had to account for the later effectful migration (`docs/plans/25-adopt-effectful-for-the-en-effect-stack.md`). Instead of adding the obsolete record-of-functions `postgresTupleStoreIOWithOptimizedRevision`, EP-9 preserved the uncached `runTupleStorePostgres` interpreter and added `runTupleStorePostgresWithOptimizedRevisionCache` as the opt-in cached interpreter for EP-13 service wiring. _(2026-06-23)_
- EP-10 preserved the current `Revision` invariant: `en-core/src/En/Revision.hs` intentionally has no global `Ord Revision` because revisions are semantically partially ordered. The cache key types in `En.Cache` therefore define local `Ord` instances that compare `revisionEncoding` only as an opaque identity component for `Map` storage. _(2026-06-24)_


## Decision Log

- Decision: Create a dedicated caching MasterPlan instead of appending work to the completed ReBAC toolkit MasterPlan.
  Rationale: The first MasterPlan is complete and covers core ReBAC behavior. Caching is a cross-cutting production initiative with several independently verifiable layers and deserves its own progress, dependency, and retrospective tracking.
  Date: 2026-06-23
- Decision: Pass `intention_01kvtg84azehbsj9zgsfd71y90` to the MasterPlan and every child ExecPlan.
  Rationale: The user explicitly requested that this caching planning work use that intention id, so the frontmatter carries it for tracking.
  Date: 2026-06-23
- Decision: Start with in-process bounded caches and exclude distributed invalidation.
  Rationale: `en` currently targets a single organization on PostgreSQL and already resolves reads to explicit revisions. In-process revision-scoped caches can be correct and useful without introducing cross-process coherence complexity.
  Date: 2026-06-23
- Decision: Make cache keys include resolved revision and schema identity rather than trying to invalidate decisions on every write.
  Rationale: The tuple store already supports point-in-time reads. A decision at revision R is safe to reuse only for R and the same schema hash; a later write produces a later revision and naturally misses without active invalidation.
  Date: 2026-06-23
- Decision: Implement **MasterPlan 3 in full before this MasterPlan**, rather than interleaving or
  pulling individual plans forward.
  Rationale: Of the three cross-MasterPlan edges, two are hard and point MasterPlan 3 → MasterPlan 2
  (EP-9←EP-14, EP-11←EP-15) and only one points back (EP-19←EP-11), and that one is soft (efficiency,
  not correctness). Implementing MasterPlan 3 first therefore satisfies both hard prerequisites by
  construction with no rebase risk: EP-9's snapshot-sharing quantization is built on EP-14's corrected
  partial-order comparator (the current `snapshotIncludes` has an xmax-gap false-include EP-14 proves is
  a read-your-writes / cross-tenant-leak risk), and EP-11's decision cache keys on the `CheckDecision`
  shape EP-15 has already relocated into the shared `En.Decision` module. The single back-edge degrades
  gracefully — EP-19 ships first as a correct uncached `check` fold and EP-11 upgrades its cross-request
  efficiency later. This was chosen over the interleaved "pull EP-14/EP-15 forward" alternative because
  the rest of MasterPlan 3 (EP-16/17/18) has no dependency on this MasterPlan, so a clean
  MasterPlan-3-first order has the same prerequisite guarantees with less sequencing overhead. (Supersedes
  the earlier soft-dependency decision of 2026-06-23.)
  Date: 2026-06-23
- Decision: Design EP-11's decision cache key to be batch-friendly so MasterPlan 3 EP-19 (BatchCheck)
  composes on top of it.
  Rationale: EP-19 (`docs/plans/19-add-batchcheck-for-graphql-field-capability-and-candidate-filtering.md`)
  fans out many `(subject, permission, object)` decisions per GraphQL request and softly depends on
  EP-11 to make pairs overlapping across requests cheap. A plain per-pair key under one resolved revision
  (no per-call state) lets a batch fold over `checkCached` reuse entries with no EP-19-specific cache
  code. EP-19 does not block EP-11 (it is a correct `check` fold without the cache); the cache is the
  cross-request efficiency layer.
  Date: 2026-06-23


## Outcomes & Retrospective

EP-9 is complete. `en-postgres` now exposes an optimized revision cache configuration and an opt-in PostgreSQL tuple-store interpreter that caches only `OptimizedRevision` reads. Focused tests prove enabled TTL reuse, expiry refresh, disabled behavior, and `FullyConsistent` head-revision selection; `nix develop -c cabal test en-postgres-revision-tests` and `nix develop -c cabal build all` pass as of 2026-06-23T23:59:54Z.

EP-10 is complete. `en-core` now exposes `En.Cache` with bounded in-process cache operations, hit/miss/insert/eviction stats, and shared tuple-read/decision/subproblem cache keys. Focused tests prove hit, miss, disabled, eviction, schema-hash separation, revision separation, caveat-context separation, and tuple-read request-shape separation; `nix develop -c cabal test en-core-interface-tests` and `nix develop -c cabal build all` pass as of 2026-06-24T00:05:35Z.


---

**Revision note (2026-06-23).** Recorded the cross-MasterPlan coordination with MasterPlan 3 (en
hardening): a Surprises entry confirming the `optimizedRevision = headRevision` gap EP-9 targets, a
cross-MasterPlan Integration Points paragraph, soft cross-plan ordering notes on the EP-9 and EP-11
dependency paragraphs, and a Decision Log entry sequencing EP-9 after MasterPlan 3 EP-14 and EP-11
after EP-15. No child plans changed and no scope was added to this MasterPlan.

**Revision note (2026-06-23, validation pass).** Validated this MasterPlan against MasterPlan 3 and its
child plans (EP-14, EP-15, EP-19) and reconciled three gaps. (1) Settled the cross-MasterPlan ordering:
**MasterPlan 3 is implemented in full before this MasterPlan**, which satisfies the hard EP-9←EP-14 and
EP-11←EP-15 prerequisites by construction (no pull-forward carve-out, no rebase). Updated the Registry
note, both dependency paragraphs, the Integration Points paragraph, and the Decision Log (superseding the
earlier soft-dependency decision). The interleaved "pull EP-14/EP-15 forward" alternative was considered
and rejected because the rest of MasterPlan 3 has no dependency on this MasterPlan. (2) Added the
previously-unrecorded EP-11→EP-19 (BatchCheck) consumer relationship — Integration Point (3), a Surprises
entry, and a Decision Log entry requiring EP-11's cache key to be batch-friendly; noted EP-19 ships before
EP-11 (uncached fold) and EP-11 upgrades its cross-request efficiency later. (3) Added a soft, optional
note that EP-13 may reuse MasterPlan 3 EP-17's `tasty-bench` harness. Also tightened the EP-11 wording to
state the cache target is `En.Check`'s monadic `runCheck` subproblem path (with `En.Decision` as the type
seam), not the pure combinators. Cascaded the cross-MasterPlan prerequisite notes into the child plans
EP-9, EP-11, and EP-13 for self-containment. No scope was added to this MasterPlan.
