---
id: 13
slug: wire-caching-into-service-operations-and-validation
title: "Wire caching into service operations and validation"
kind: exec-plan
created_at: 2026-06-23T15:06:50Z
intention: "intention_01kvtg84azehbsj9zgsfd71y90"
master_plan: "docs/masterplans/2-add-caching-support-to-en.md"
---

# Wire caching into service operations and validation

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan turns the lower-level cache support into a usable production feature. After implementation, `en-server` can enable or disable optimized revision, tuple-read, and decision caches through environment variables, startup logs report the active cache configuration, user docs explain the knobs and safety model, and validation shows repeated service checks can hit cache without weakening consistency. A user can start the service with cache settings and run the existing write-token-check-lookup flow while seeing cache behavior in tests or logs.


## Progress

- [ ] Add cache-related environment parsing and startup wiring in `en-server`.
- [ ] Use cached tuple store and cached check/lookup paths in `en-servant` or server wiring without breaking existing API shapes.
- [ ] Add docs for cache settings, key safety, and known limitations.
- [ ] Add integration or smoke validation covering cache-enabled service behavior.
- [ ] Run `cabal test all` where available and `cabal build all`.


## Surprises & Discoveries

None yet.


## Decision Log

- Decision: Keep caches disabled by default unless the lower-level plans choose a safe small default.
  Rationale: The project is experimental. Operators should opt into cache behavior until validation data exists for their workload.
  Date: 2026-06-23
- Decision: Wire service caching after all lower cache layers are complete.
  Rationale: Service configuration should consume stable cache constructors rather than force API churn into `en-core` or `en-postgres`.
  Date: 2026-06-23


## Outcomes & Retrospective

To be filled during and after implementation.


## Context and Orientation

`en-server/app/Main.hs` currently reads `EN_DATABASE_URL` and `EN_PORT`, constructs `postgresTupleStoreIO`, builds `postgresConsistencyStore`, and serves `En.Servant.API.app`. It uses the built-in demo schema. There is no cache configuration.

`en-servant/src/En/Servant/API.hs` defines `EnServer`, handlers for tuple writes/deletes, `check`, `lookup`, and `expand`, and the wire request/response types. If cached check or cached lookup requires additional environment fields, this module may need a backward-compatible extension.

The production deployment guide is `docs/user/production-deployment-and-performance.md`. It currently says that `en` does not yet ship a production decision cache. This plan must update that section after caching exists.

This plan depends on:

- `docs/plans/9-implement-optimized-revision-caching.md`
- `docs/plans/10-add-core-cache-interfaces-and-configuration.md`
- `docs/plans/11-implement-authorization-decision-caching.md`
- `docs/plans/12-implement-tuple-read-caching.md`


## Plan of Work

Milestone 1 adds service configuration. In `en-server/app/Main.hs`, parse environment variables such as:

- `EN_OPTIMIZED_REVISION_CACHE_TTL_MS`
- `EN_TUPLE_READ_CACHE_MAX_ENTRIES`
- `EN_DECISION_CACHE_MAX_ENTRIES`

Use names close to the final lower-level config types. A value of missing or `0` should disable that cache. Log the resolved settings at startup using `Text.putStrLn`, matching the current simple server style.

Milestone 2 wires the lower-level caches. Use the optimized PostgreSQL tuple-store constructor from EP-9. If `EN_TUPLE_READ_CACHE_MAX_ENTRIES` is positive, wrap the store with `cachedTupleStore`. If `EN_DECISION_CACHE_MAX_ENTRIES` is positive, construct a decision cache environment and make Servant handlers call cached check and cached lookup variants.

If changing `En.Servant.API.EnServer` is necessary, keep the fields explicit. For example, add optional function fields rather than hiding behavior behind globals:

```haskell
data EnServer = EnServer
    { consistencyStore :: !(ConsistencyStore IO)
    , tupleStore :: !(TupleStore IO)
    , graph :: !ReachabilityGraph
    , checkOperation :: !(CheckRequestParts -> IO (Either EnError CheckDecision))
    }
```

The exact shape can differ, but the handlers should remain easy to read and fail closed on errors or non-`Allowed` decisions.

Milestone 3 updates documentation. In `docs/user/production-deployment-and-performance.md`, replace the statement that `en` does not ship a production decision cache with the actual supported cache layers and configuration. Document:

- Caches are in-process and per service instance.
- Decision and tuple-read cache keys include resolved revision.
- `FullyConsistent` still resolves head revision.
- `AtLeastAsFresh` can reuse cache only after resolving to a revision that satisfies the token.
- Cache settings affect latency and memory, not authorization semantics.
- No distributed invalidation or materialized index exists yet.

Milestone 4 validates service behavior. Prefer an integration test if the existing test harness makes it practical. Otherwise, record a reproducible transcript in this plan, similar to the existing service plan style, showing:

1. Start `en-server` with cache environment variables.
2. Write a tuple and receive a token.
3. Check with `AtLeastAsFresh token` and receive `Allowed`.
4. Repeat the same check and observe a cache hit counter or startup/test log evidence.
5. Run lookup and expand to prove existing API behavior is unchanged.


## Concrete Steps

From the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/en
```

Inspect service wiring:

```bash
sed -n '1,140p' en-server/app/Main.hs
sed -n '80,380p' en-servant/src/En/Servant/API.hs
```

Edit:

- `en-server/app/Main.hs`
- `en-server/en-server.cabal` if new imports require package dependencies
- `en-servant/src/En/Servant/API.hs` if handler environment changes are required
- `docs/user/production-deployment-and-performance.md`
- Relevant tests or plan transcript sections

Run:

```bash
cabal build all
cabal test all
```

If `cabal test all` reports that some packages have no test suites, record that in this plan during implementation rather than treating it as a failure.


## Validation and Acceptance

Acceptance requires the service to build and the cache-enabled path to be observable. At minimum, a cache-enabled test or transcript must prove that an authorization request still returns the correct decision and that the second identical request at the same resolved revision hits a cache or avoids repeated underlying work. The production docs must accurately describe what is implemented and what remains future work.

Cross-MasterPlan (optional, soft): because MasterPlan 3 (en hardening) is implemented in full before this MasterPlan (see `docs/masterplans/2-add-caching-support-to-en.md`), MasterPlan 3 EP-17's `tasty-bench` suite (`docs/plans/17-strengthen-the-lookup-spike-and-add-performance-regression-benchmarks.md`) already exists and is kept independent of cache configuration. You may reuse that harness to measure cache-hit performance (e.g. run the same `check`/`lookup` workload with caches on vs off) instead of writing a bespoke benchmark. This is optional and does not block acceptance — counting-store transcripts proving fewer underlying reads are sufficient.


## Idempotence and Recovery

Environment parsing should be safe to repeat. Invalid numeric environment values should either fail startup with a clear message or fall back to disabled cache; choose one behavior and document it. Prefer failing startup for malformed values because silent cache misconfiguration is hard to diagnose.

If cached Servant wiring becomes too invasive, first expose the lower-level cached constructors for embedded users and keep the service disabled until a follow-up revision. Record that decision in this plan and the MasterPlan.


## Interfaces and Dependencies

This plan consumes the interfaces added by EP-9, EP-10, EP-11, and EP-12. It may touch `en-server`, `en-servant`, `en-core`, and docs, but it should not change the external HTTP request and response JSON shapes unless a prior plan explicitly required it.
