---
id: 1
slug: build-en-rebac-authorization-toolkit
title: "Build en ReBAC Authorization Toolkit"
kind: master-plan
created_at: 2026-06-23T04:05:40Z
intention: "intention_01kvsbcvsfepaafp5x44ykby47"
---

# Build en ReBAC Authorization Toolkit

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

This initiative turns `en` from its current scaffold into a usable Haskell relationship-based authorization toolkit and standalone service. At completion, a consuming service can define a typed relationship schema, write and delete relationship tuples, receive a consistency token, and use `check`, `lookup`, and `expand` to enforce object-level authorization. The first target shape is the kikan C13 contract: `shomei` authenticates the caller and supplies coarse roles/scopes, while `en` answers whether that caller may act on a specific object through relationships such as ownership, space membership, guest organization sharing, conversation participation, and autonomy-bounded delegation.

The implementation stays deliberately Zanzibar-inspired but not Zanzibar-scale. It targets one organization on one PostgreSQL datastore, with Postgres MVCC snapshots used for read-your-writes consistency tokens. It includes bounded caveats, reverse lookup, and a Servant API/client/server surface. It does not include multi-region distribution, request hedging, a general policy language such as OPA/Rego, a runtime schema DSL, or a materialized Leopard-style reverse index unless the lookup spike proves one must be pulled forward.

The architectural risks from the initial review are in scope: the core store interface currently returns too little information, caveats are named but not representable as concrete values, `lookup` is currently an unbounded list API despite the design requiring cursors and caps, consistency resolution has no explicit port boundary, schema validation is too weak for a public relationship vocabulary, and `expand` is specified but absent.


## Decomposition Strategy

The work is decomposed by functional concern and by the order in which decisions become hard to reverse. The first child plan stabilizes public core interfaces before algorithms are written, because these types will be consumed by every later package. Schema validation and reachability compilation then turn a consumer schema into a checked graph that algorithms can traverse. PostgreSQL storage and consistency tokens are separate because their correctness depends on database migrations, MVCC snapshot semantics, and token validation rather than graph traversal.

The query algorithms are split into forward `check` and reverse `lookup`/`expand`. `check` is the smaller algorithm and exercises the core interfaces first. `lookup` remains the largest risk, so there is a dedicated throwaway performance spike that validates the kikan read-filter shape before the production lookup implementation commits to API and storage details. The final Servant/server/client plan is last because HTTP request and response shapes should be driven by the stable core result types, cursors, consistency tokens, and error model.

An alternative decomposition by package was rejected. Planning by files such as `en-core`, `en-postgres`, and `en-servant` would hide the actual cross-package dependencies: consistency tokens span core and Postgres, lookup spans core graph traversal and store paging, and API shape must reflect all previous decisions.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-1 | Stabilize core authorization interfaces | docs/plans/1-stabilize-core-authorization-interfaces.md | None | None | Complete |
| EP-2 | Implement PostgreSQL tuple store and consistency tokens | docs/plans/2-implement-postgresql-tuple-store-and-consistency-tokens.md | EP-1 | EP-3 | Complete |
| EP-3 | Implement schema validation and reachability compilation | docs/plans/3-implement-schema-validation-and-reachability-compilation.md | EP-1 | None | Complete |
| EP-4 | Implement forward authorization check | docs/plans/4-implement-forward-authorization-check.md | EP-1, EP-3 | EP-2 | Complete |
| EP-5 | Validate bounded lookup with the kikan read-filter spike | docs/plans/5-validate-bounded-lookup-with-the-kikan-read-filter-spike.md | None | EP-1, EP-3 | Complete |
| EP-6 | Expose en through Servant server and client APIs | docs/plans/6-expose-en-through-servant-server-and-client-apis.md | EP-1, EP-2, EP-3, EP-4, EP-7 | EP-5 | Complete |
| EP-7 | Implement cursored reverse lookup and expand | docs/plans/7-implement-cursored-reverse-lookup-and-expand.md | EP-1, EP-3, EP-4 | EP-2, EP-5 | Complete |


## Dependency Graph

EP-1 is the root. It defines the shared types and ports: caveat values, check decisions, lookup cursors, store rows, consistency resolution, error surfaces, and the missing `expand` module boundary. Any implementation before EP-1 risks baking in the overly narrow scaffold interfaces.

EP-2 depends hard on EP-1 because the Postgres store must implement the final store and consistency interfaces, not the placeholder `TupleStore` shape. EP-2 has a soft dependency on EP-3 because schema hashes and validation rules inform token validation, but the migration and snapshot work can proceed using deterministic placeholder schema hashes if necessary.

EP-3 depends hard on EP-1 because schema validation must validate the final schema model, caveat definitions, allowed subject references, wildcard/public support if included, and rewrite expressions.

EP-4 depends hard on EP-1 and EP-3. A forward check algorithm needs stable result types and a compiled reachability graph. It can use an in-memory store, so EP-2 is only a soft dependency.

EP-5 is intentionally independent. It is a throwaway performance proof over the kikan read-filter shape and does not need the real engine. Its results inform EP-7 and may force the MasterPlan to pull forward a materialized reverse index or tighten the supported schema shape.

EP-7 depends hard on EP-1, EP-3, and EP-4. Reverse lookup needs the cursor/result interfaces, the reachability graph, and forward check confirmation for conditional entrypoints such as intersection, exclusion, and caveats. EP-2 is a soft dependency because production lookup must eventually page through the Postgres store, but the algorithm can be proven against an in-memory store. EP-5 is a soft dependency because the spike may reshape caps, pagination, or supported schema guidance.

EP-6 depends on the complete library behavior. Servant and client APIs should expose the final decision, cursor, token, error, and tuple-write shapes rather than placeholder types.


## Integration Points

The core authorization result types are defined in EP-1 and consumed by EP-4, EP-7, and EP-6. These include the decision type for `check`, the membership type for conditional/caveated results, and the request context passed to caveat evaluation.

The `TupleStore` and consistency ports are defined in EP-1, implemented by EP-2, used by EP-4 and EP-7, and exposed indirectly through EP-6. The shared artifact is `en-core/src/En/Effect/TupleStore.hs` plus any new consistency module introduced by EP-1.

The schema model is defined initially by EP-1 and validated/compiled by EP-3. EP-4 and EP-7 consume the compiled reachability graph, and EP-6 loads or receives the active schema for standalone service startup.

The PostgreSQL schema is owned by EP-2. It includes the `relation_tuple` and `en_transaction` tables, indexes for forward and reverse reads, xid-based soft deletion, caveat payload columns, and any metadata needed for token validation. EP-7 must ensure its paging queries can be backed by those indexes.

The lookup cursor and cap semantics are defined by EP-1, validated by EP-5, implemented by EP-7, and exposed over HTTP by EP-6. Later plans must preserve bounded results and make truncation observable.

The Servant API is owned by EP-6 but must not invent new semantics. It serializes the core request/response types from EP-1, writes through EP-2, and invokes EP-4 and EP-7.


## Progress

- [x] EP-1: Define final core result, caveat, tuple-store, consistency, lookup cursor, and expand interfaces.
- [x] EP-1: Add focused compile and interface tests proving the skeleton no longer exposes unbounded or information-losing APIs.
- [x] EP-2: Add codd migration schema for `relation_tuple` and `en_transaction`.
- [x] EP-2: Add Postgres `pg_snapshot` parsing, rendering, partial-order comparison, and token codec tests.
- [x] EP-2: Implement revision resolution for `MinimizeLatency`, `FullyConsistent`, `AtLeastAsFresh`, and `AtExactSnapshot`.
- [x] EP-2: Implement and test the hasql-backed tuple store with MVCC snapshot reads and write tokens.
- [x] EP-3: Validate schema definitions, caveat declarations, allowed subject shapes, and rewrite references.
- [x] EP-3: Compile valid schemas into a reachability graph annotated for direct and conditional entrypoints.
- [x] EP-4: Implement forward `check` over the compiled graph and store rows.
- [x] EP-4: Prove caveated, userset, tuple-to-userset, intersection, exclusion, and recursion-limit behavior with tests.
- [x] EP-5: Build and run the kikan read-filter lookup spike over synthetic relationship and activity data.
- [x] EP-5: Append p95 results and a green/red decision to `docs/spec/0002-lookup-spike.md`.
- [x] EP-7: Implement production cursored reverse lookup with caps, truncation, and reach-then-check confirmation.
- [x] EP-7: Implement `expand` for review and audit UIs.
- [x] EP-6: Define Servant API, handlers, client functions, and server wiring over the completed libraries.
- [x] EP-6: Validate the standalone service with an end-to-end write-token-check-lookup scenario.


## Surprises & Discoveries

- The initial architecture review found that the package split is sound, but several public interfaces are too narrow for the documented semantics. The most important examples are `readStartingWithUser :: Revision -> UsersetQuery -> m [ObjectRef]`, `check :: ... -> m Bool`, and `lookup :: ... -> m [ObjectRef]`.
- The lookup spike from `docs/spec/0002-lookup-spike.md` is not a substitute for production lookup. It validates the performance shape and informs EP-7, but EP-7 still must implement the real cursored algorithm.
- The generated child plan numbering reflects creation time. EP-6 is the final integration plan even though EP-7 must complete before it; the registry and dependency graph, not file number order alone, define implementation order.
- EP-1 discovered that caveat schema declaration constructors and runtime caveat value constructors must be distinct for normal client imports. The final interface uses `Parameter*` constructors for schema parameter kinds and `Value*` constructors for tuple/request values.
- EP-2 found that the Postgres snapshot order must compare only the required snapshot's known transaction horizon. Comparing future transaction visibility symmetrically made a newer snapshot appear older; `en-postgres-revision-tests` now covers this case and the concurrent case.
- EP-2 now exposes a real `ConsistencyStore IO` constructor over supplied head/optimized revision readers. The remaining storage work can wire those readers to Hasql statements without changing `en-core`.
- EP-2 found that write tokens must be minted from a post-commit snapshot. Capturing `pg_current_snapshot()` inside the write transaction did not make that transaction's `xid` visible to `pg_visible_in_snapshot`, and the new `en-postgres-integration-tests` caught the issue.
- EP-3 found that productive recursive schemas need a base path check rather than a blanket cycle rejection. The kikan-shaped `space#view` recursion through `space#parent` is valid because it can also reach direct `owner`/`member` bases; pure computed-userset cycles without a base are rejected.
- EP-4 found that forward check requires object-side tuple reads in addition to Zanzibar's reverse `ReadStartingWithUser` primitive. `TupleStore` now exposes `readObjectRelation` for check and keeps `readStartingWithUser` for lookup.
- EP-5 found that the intended kikan read-filter shape remains bounded in the spike: the reachable label set stayed at 24 spaces and 4 visibility classes across 1k, 10k, and 100k relationship tuples, while the anti-pattern hit the 1001-result cap in every scenario.
- EP-7 found that bare lookup object ids are insufficient for caveated reverse results. `LookupPage` now carries `LookupObject` entries with per-object `CheckDecision` values so conditional caveat obligations can reach EP-6's HTTP surface.
- EP-6 found that the repository has no runtime schema parser or schema-file format yet. The standalone server therefore runs a built-in demo schema for the service smoke path, while the embedded library API remains schema-parametric through `Schema` and `ReachabilityGraph`.


## Decision Log

- Decision: Make EP-1 the root plan and require it before algorithm or storage implementation.
  Rationale: The existing scaffold exposes APIs that cannot carry caveat payloads, conditional results, lookup cursors, or store-row provenance. Stabilizing these interfaces first prevents later rewrites.
  Date: 2026-06-23
- Decision: Split the lookup work into a throwaway spike and a production implementation.
  Rationale: The kikan read-filter performance risk should be retired before building the full engine, but the spike intentionally excludes consistency, caveats, the full compiler, and production cursors.
  Date: 2026-06-23
- Decision: Keep the Servant/server/client work last.
  Rationale: HTTP and client APIs should serialize stable core semantics rather than force the library to preserve temporary placeholder shapes.
  Date: 2026-06-23
- Decision: Proceed without an intention ID.
  Rationale: The intention prompt tool was unavailable in the current mode, and the user asked for the plan now. The plan can be updated later to add an `intention` frontmatter field if needed.
  Date: 2026-06-23
- Decision: Add intention metadata to the MasterPlan and all child ExecPlans.
  Rationale: The user supplied `intention_01kvsbcvsfepaafp5x44ykby47` after plan creation, so the plan set now carries the shared intention in frontmatter for tracking.
  Date: 2026-06-23
- Decision: Keep EP-1 scoped to stable public interfaces and compile coverage.
  Rationale: Schema validation, storage behavior, forward check, reverse lookup, expand traversal, and API handlers each have dedicated child plans. EP-1 should provide the types and effect boundaries those plans consume without prematurely implementing their behavior.
  Date: 2026-06-23
- Decision: Treat EP-2 as complete after the Hasql tuple store passed both pure revision tests and the ephemeral-pg integration test.
  Rationale: The storage slice now demonstrates write-token read-your-writes, delete-token hiding, and old-token historical reads against a real PostgreSQL instance.
  Date: 2026-06-23
- Decision: Treat EP-3 as complete after the kikan-shaped schema fixture validates and compiles into direct, conditional, caveated, and recursive reachability entrypoints.
  Rationale: EP-4 and EP-7 now have concrete schema validation and graph artifacts to consume rather than placeholders.
  Date: 2026-06-23
- Decision: Treat EP-4 as complete after in-memory kikan checks and the Postgres-backed write-token-check integration test pass.
  Rationale: The forward authorization gate now resolves consistency, traverses the compiled schema over tuple-store rows, evaluates bounded caveats, and reports traversal limits through the core error model.
  Date: 2026-06-23
- Decision: Treat EP-5 as complete after the `ephemeral-pg` spike produced a green 1M-row read-filter result and documented the skipped 10M-row case.
  Rationale: The measured lookup p95 is far below the target at 100k relationship tuples/depth 6, the indexed consumer read path is below the target at the required 1M-row scale, and the remaining 10M check is explicitly recorded as optional/where-feasible evidence.
  Date: 2026-06-23
- Decision: Treat EP-7 as complete after core lookup/expand tests and Postgres-backed lookup paging passed.
  Rationale: The core algorithms now resolve consistency, preserve conditional lookup decisions, confirm conditional candidates with forward check, return deterministic cursors, build expand trees, and exercise the Hasql tuple-store path through the integration suite.
  Date: 2026-06-23
- Decision: Treat EP-6 as complete after the Servant API/client/server surfaces built, all tests passed, and the plan recorded a reproducible write-token-check-lookup-expand HTTP transcript against the built-in demo schema.
  Rationale: The service can now expose the completed library over HTTP and the missing arbitrary schema loader is an explicit future extension rather than a hidden incomplete code path.
  Date: 2026-06-23


## Outcomes & Retrospective

The MasterPlan delivered the intended first usable ReBAC toolkit slice. `en-core` now has schema-parametric interfaces for tuples, consistency, caveats, checks, lookup pages, and expand trees. `en-postgres` implements the Hasql-backed tuple store and MVCC consistency tokens against the codd migration schema. The schema compiler validates relation rewrites and compiles reachability for direct, recursive, caveated, intersection, exclusion, and tuple-to-userset paths. Forward check, bounded reverse lookup, and expand now run over the same store and reachability graph.

The Postgres-backed behavior is covered by `ephemeral-pg` integration tests for write-token read-your-writes, delete visibility, check, and lookup paging. The lookup spike documented the kikan read-filter shape as green at the required scale. `en-servant`, `en-client`, and `en-server` expose the completed engine through typed Servant handlers, a derived Haskell client, and a runnable Warp service.

The main known limitation is runtime schema loading for the standalone server. Consumers embedding the library can define typed schemas directly today; the server currently starts with a built-in demo schema until a schema DSL or JSON schema format is designed.


Revision note 2026-06-23: Added `intention_01kvsbcvsfepaafp5x44ykby47` to this MasterPlan and all child ExecPlan frontmatter at the user's request.

Revision note 2026-06-23: Completed EP-1 and updated the registry, aggregate progress, discoveries, and decisions to reflect the stabilized `en-core` interface surface.

Revision note 2026-06-23: Completed EP-2 and updated aggregate progress after adding the Hasql tuple store and `ephemeral-pg` integration coverage.

Revision note 2026-06-23: Completed EP-3 and updated aggregate progress after adding schema validation, deterministic schema hashing, and reachability compilation.

Revision note 2026-06-23: Completed EP-4 and updated aggregate progress after adding consistency-aware forward checks and Postgres-backed check coverage.

Revision note 2026-06-23: Completed EP-5 after adding and running the `ephemeral-pg` lookup spike, recording p95 timings, and marking the kikan read-filter shape green at 1M activity rows.

Revision note 2026-06-23: Completed EP-7 after implementing bounded reverse lookup, explanatory expand trees, core traversal tests, and Postgres-backed lookup paging coverage.

Revision note 2026-06-23: Completed EP-6 after adding the Servant API/client/server integration surface and documenting the write-token-check-lookup-expand HTTP transcript.
