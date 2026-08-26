---
id: 64
slug: serve-kubernetes-health-probes-from-servant-health
title: "Serve Kubernetes health probes from servant-health"
kind: exec-plan
created_at: 2026-08-25T20:39:40Z
intention: "intention_01m0xaavwqeznrgzs3j67m0q21"
master_plan: "docs/masterplans/11-bring-en-into-conformance-with-the-haskell-jitsurei-pattern-catalog.md"
---

# Serve Kubernetes health probes from servant-health

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

`en-server` tells an orchestrator whether it is healthy through two endpoints it wrote
itself. `GET /healthz` always answers `200 {"status":"ok"}`. `GET /readyz` pings PostgreSQL
and answers either `200 {"status":"ok"}` or `503` with an error body. Both are served by a
WAI middleware in `en-server/app/Health.hs` that inspects the request path and never reaches
the servant application at all, which means they are absent from `en`'s OpenAPI document and
invisible to anything reading the API type.

Two things are wrong with that, and only one of them is about conformance.

The **substantive** problem is that a failing `/readyz` tells you nothing. It answers `503`
with `{"code":"store_error", ...}` — the same body a real request gets during an outage. It
does not say which check failed, and it does not say *when the failure began*. An operator
looking at a pod that has been out of rotation for ten minutes cannot tell from the probe
whether it just failed or has been failing since startup.

The **conformance** problem is that the fleet's paths are `/health/live` and
`/health/ready`, and the probe surface is owned by a released package rather than written
per service. The reason the fleet centralizes it is specific: both probe responses carry the
same body type, so the `AsUnion` instance that maps a passed probe to `200` and a failed
probe to `503` is the only place that mapping exists. Getting it backwards compiles
perfectly. That one dangerous instance belongs in one tested package.

After this plan:

```bash
curl -s -i http://127.0.0.1:8080/health/ready
```

answers, while PostgreSQL is down:

```text
HTTP/1.1 503 Service Unavailable
Content-Type: application/json

{"status":"failed","check":"postgres","failingSince":"2026-08-25T19:04:11.221Z"}
```

and `GET /health/live` still answers `200` — because liveness must never depend on a
database, or a database outage restarts every otherwise-healthy pod in the fleet. Both
routes appear in `docs/api/openapi.json`, because they are now real servant routes on the
API record. And a test proves the two probes are not wired to each other's checks, which is
the failure the shared body type otherwise makes invisible.


## Progress

- [x] (2026-08-26 00:11Z) Milestone 1 — Proved the `servant-health` cohort resolves against `en`'s pinned
      dependency closure (`cabal build all` with the dependency added and nothing else
      changed), and recorded `servant-health-0.1.0.0`. No code yet.
- [x] (2026-08-26 00:20Z) Milestone 2 — Mounted `HealthApi` under `"health"` on `en`'s API record, built the two
      probe checks from `en-server`'s existing liveness and readiness logic with
      `safeCheck`, `withProbeTimeout`, `sequenceChecks`, and failure trackers, and served
      them. `/healthz` and `/readyz` still answer during this milestone. A live database
      stop proved readiness returns 503 with a stable `failingSince` while liveness remains
      200.
- [x] (2026-08-26 00:23Z) Milestone 3 — Added the `servant-health:testkit` contract test,
      watched it fail against a deliberately swapped wiring, then restored the correct
      order and passed all four cases under the threaded runtime.
- [x] (2026-08-26 00:25Z) Milestone 4 — Deleted `en-server/app/Health.hs` and every reference to `/healthz` and
      `/readyz`: the middleware layer in `en-server/app/Main.hs`, the auth and rate-limit
      exemptions in `en-server/app/Middleware.hs`, the metrics path list in
      `en-server/app/Metrics.hs`, the log exclusion in `en-server/app/Observability.hs`, the
      readiness wait in `justfile`, and the probe path in `process-compose.yaml`.
- [x] (2026-08-26 00:29Z) Milestone 5a — Exempted exactly the two package-owned probe
      routes from the problem-details conformance test by name, documented them as
      unauthenticated, and normalized their OpenAPI responses to one canonical JSON media
      type.
- [ ] Milestone 5b — Regenerate `docs/api/openapi.json`, write the ADR recording that the
      probe surface is `servant-health`'s, and run final validation.


## Surprises & Discoveries

- Discovery (2026-08-25, while planning): **`en`'s readiness check pings twice on purpose,
  and that subtlety must survive the migration.** `en-server/app/Main.hs` defines
  `checkReady = do { healthy <- ping; if healthy then pure True else ping }`, and its comment
  explains why: after a PostgreSQL restart, the first session on a stale pooled connection
  fails at the *statement* level, which `hasql-pool` does not treat as grounds to discard the
  connection — only a connection-level failure retires it. A single-shot probe would
  therefore flap to unready against a perfectly healthy database, and would spend the failure
  a real request could have absorbed. Wrapping the naive single ping in `boolCheck` would
  reintroduce that flap. The double-ping goes *inside* the check.

- Discovery (2026-08-25, while planning): **`/healthz` and `/readyz` are referenced from six
  places, not one.** Beyond `en-server/app/Health.hs` itself:
  `en-server/app/Middleware.hs:70` exempts them from authentication and rate limiting,
  `en-server/app/Metrics.hs:105,109` names them in a path list,
  `en-server/app/Observability.hs:52` excludes them from the request log, `justfile:43` polls
  `/healthz` to decide the server has started, and `process-compose.yaml:45` uses `/readyz`
  as its probe path. Milestone 4's checklist is that list; missing one leaves a dangling
  reference to a route that no longer exists.

- Discovery (2026-08-26, Milestone 1): **the pre-existing `en-biscuit-tests` authorization
  timeout remains sensitive to full-suite concurrency and is unrelated to the new
  dependency.** Both the baseline and post-dependency `cabal test all` runs passed the other
  seven suites but failed this one with `authorization rejected: Timeout`; the same suite
  passed immediately in isolation both times. This reproduces the known EP-61 baseline and
  does not block the dependency-resolution proof.

  ```text
  Test suite en-biscuit-tests: FAIL
  en-biscuit test FAILED: smoke test: authorization rejected: Timeout
  $ cabal test en-biscuit-tests
  Test suite en-biscuit-tests: PASS
  ```

- Discovery (2026-08-26, Milestone 2): **three Mori-registered consumers call the
  source-compatible `app env` builder, so changing it to require probe arguments would
  create an unnecessary cross-repository break.** `mori://shinzui/kikan-en`,
  `mori://shinzui/nagare`, and `mori://shinzui/meibo` all use the embedded builder. The
  implementation therefore adds explicit `appWithProbes` / `appWithOpenApiProbes` seams
  while retaining the existing entry points with healthy defaults. The standalone binary
  uses the explicit seam and therefore always supplies real checks.

- Discovery (2026-08-26, Milestone 2): **the released wire vocabulary is `ok` / `failed`,
  with `check: "all"` for a healthy result, rather than the `healthy` / `unhealthy`
  examples this plan originally carried.** The live packaged server confirmed the released
  `servant-health-0.1.0.0` implementation read through Mori: with PostgreSQL stopped,
  liveness stayed 200 and two readiness responses reused the exact same failure onset.

  ```text
  GET /health/live  -> 200 {"check":"all","failingSince":null,"status":"ok"}
  GET /health/ready -> 503 {"check":"postgres","failingSince":"2026-08-26T00:19:23.413931Z","status":"failed"}
  GET /health/ready -> 503 {"check":"postgres","failingSince":"2026-08-26T00:19:23.413931Z","status":"failed"}
  ```

- Discovery (2026-08-26, Milestone 3): **the shared contract test catches exactly the
  compile-clean dispatch error it was designed for.** Passing readiness as liveness and
  liveness as readiness compiled, but both asymmetric cases failed at the expected route;
  restoring `(liveness, readiness)` made the full matrix pass.

  ```text
  readiness failing: ready answers 503, live still 200: FAIL
    GET /health/ready: status code
    expected: 503
     but got: 200
  liveness failing: live answers 503, ready still 200: FAIL
    GET /health/live: status code
    expected: 503
     but got: 200

  # Correct wiring
  All 4 tests passed (0.00s)
  ```

- Discovery (2026-08-26, Milestone 4): **an obsolete probe path reaches authentication
  before routing, so an unauthenticated request correctly returns 401 rather than exposing
  whether the route exists.** Supplying the development bearer key reaches Servant and
  proves both obsolete paths return the RFC 9457 404. The new paths remain reachable
  without credentials and the process-compose readiness state is `Ready` at
  `/health/ready`.

- Discovery (2026-08-26, Milestone 5): **the released MultiVerb OpenAPI generator emits
  two spellings of the same JSON media type for probe responses:** `application/json` and
  `application/json;charset=utf-8`. The live server legitimately includes the charset, but
  publishing two OpenAPI content-map entries makes a generated client model two variants
  where the wire has one. `normalizeProbeContent` removes only the charset spelling from
  the two exact paths sourced from `Servant.Health.Paths.healthRawPaths`.

(Add further entries as work proceeds.)


## Decision Log

- Decision: Move the probes onto the servant API record and into the OpenAPI document,
  reversing the judgment recorded in `en-server/app/Health.hs`'s own Haddock.
  Rationale: that module argues the probes "describe the *process*, not the versioned wire
  contract, so they live here rather than in `en-servant`'s API type: they are outside `/v1`
  and absent from the OpenAPI document." The reasoning is sound and the conclusion is now
  wrong, for a reason the module could not have known. The fleet standard puts the probe
  surface in a released package precisely because the 200/503 `AsUnion` mapping is dangerous
  — both alternatives carry the same body type, so swapping them compiles — and consuming
  that package means mounting its `HealthApi` record, which is a servant route by
  construction. Appearing in the OpenAPI document is a consequence, not a goal; it is also
  harmless, since the document is generated rather than hand-written and a probe route in it
  misleads nobody. The "outside `/v1`" property is preserved: the mount is `"health"`, a
  sibling of `"v1"`, not a child.
  Date: 2026-08-25

- Decision: Do not make `/healthz` and `/readyz` permanent aliases of the new paths.
  Rationale: an alias would have to be either a second pair of servant routes (duplicating
  the routes in the OpenAPI document, which then advertises four probes) or a surviving WAI
  shim (keeping `Health.hs` alive, which is the thing this plan removes). Both consumers of
  the old paths are inside this repository — `justfile` and `process-compose.yaml` — and
  both are updated by Milestone 4, so there is no external caller to break. A deployment
  running an older Kubernetes manifest against a newer image would fail its probes, which is
  a rollout-ordering concern for whoever deploys this and is called out in Validation rather
  than papered over with an alias that would then live forever.
  Date: 2026-08-25

- Decision: Keep `en`'s double-ping readiness semantics, placing the retry inside the
  `boolCheck` action rather than relying on Kubernetes' `failureThreshold`.
  Rationale: the two mechanisms guard different things. `failureThreshold` tolerates a probe
  that fails for any reason, over a window of seconds. The double ping specifically absorbs
  the one stale-connection statement failure that `hasql-pool` will not retire, which is a
  property of `en`'s connection pool rather than a general flakiness allowance. Deleting it
  in favour of a threshold would make the probe report unready on a healthy database and
  would burn the pool's stale connection on the probe instead of letting a real request
  absorb it — both of which `en-server/app/Main.hs` already documents.
  Date: 2026-08-25

- Decision: Preserve the existing `server env`, `app env`, and `appWithOpenApi env`
  entry points and add probe-parameterized siblings for the standalone server and the
  contract test.
  Rationale: the existing entry points are consumed directly by
  `mori://shinzui/kikan-en`, `mori://shinzui/nagare`, and `mori://shinzui/meibo`.
  Requiring two new arguments would break those consumers even though only the packaged
  `en-server` owns the PostgreSQL pool needed for a truthful readiness check. The compatible
  builders retain healthy defaults for embedded hosts; `en-server` uses
  `appWithOpenApiProbes` and supplies the checks built once at startup by `mkProbes`.
  Date: 2026-08-26

- Decision: Exempt exactly `/health/live` and `/health/ready` from the RFC 9457
  problem-details media-type rule, sourcing both names from
  `Servant.Health.Paths.healthRawPaths`.
  Rationale: a 503 probe report is a typed observation of current system state, not an API
  error document. Its fixed `ProbeStatus` body is consumed by orchestrators and operators,
  so replacing it with `ProblemDetails` would violate the `servant-health` contract. The
  test holds the exemptions in an exact `Set` rather than using a `/health` prefix, so a
  future route cannot become exempt accidentally.
  Date: 2026-08-26

(Add further entries as work proceeds.)


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### What this repository is

`en` is a Haskell implementation of relationship-based authorization (ReBAC) in the style
of Google Zanzibar: it stores relationship *tuples* — facts like "user:alice is `viewer` of
space:project-x" — and answers questions about them over HTTP. It is built with `cabal` and
GHC 9.12.4, pinned by `cabal.project`, and work happens inside a nix development shell.

Three of its eight packages matter here. **`en-servant`** owns the HTTP API type
(`en-servant/src/En/Servant/API.hs`), its handlers, and the OpenAPI generator
(`en-servant/src/En/Servant/OpenApi.hs`). **`en-server`** is the standalone executable:
`en-server/app/Main.hs` assembles a WAI middleware stack around the servant application, and
`en-server/app/Health.hs`, `Middleware.hs`, `Metrics.hs`, and `Observability.hs` are its
supporting modules. **`en-postgres`** owns the PostgreSQL interpreters and the connection
pool the readiness check pings.

### Terms used in this plan

**A liveness probe** answers "is this process able to respond at all". A failed liveness
probe tells Kubernetes to **restart the container**, so the check must stay in-process and
must never depend on PostgreSQL, DNS, or another service — otherwise a database outage
restarts every healthy replica in the fleet at once.

**A readiness probe** answers "should this pod receive traffic right now". A failed
readiness probe **removes the pod from the service endpoints** without restarting it, so it
should check exactly the dependencies whose failure this pod's restart cannot fix. For `en`,
that is PostgreSQL and nothing else.

**WAI** is Haskell's web-application interface. A **WAI middleware** is a function wrapping
an application, able to answer a request itself without passing it inward — which is how
`en`'s probes work today.

**`NamedRoutes`** is the servant style `en` uses: the API is a Haskell record whose fields
are routes, and the server is a record of the same shape whose fields are handlers.

**`MultiVerb`** is the servant combinator that lets one route declare several possible HTTP
statuses as a list of alternatives, mapped onto a plain Haskell sum by an **`AsUnion`**
instance. This is the mechanism `servant-health` uses for its 200/503 pair, and the reason
that instance is dangerous is that both alternatives carry the **same body type**, so
mapping the wrong constructor to the wrong status type-checks.

**An RFC 9457 problem document** is the fleet's standard error body, served as
`application/problem+json`. It matters here only because a probe report is explicitly
**not** one, and must be exempted from the conformance test that enforces it.

### The rule this plan implements

Recorded canonically at
`mori://shinzui/haskell-jitsurei/docs/api-health-endpoints` (resolve it with `mori path`;
today it lands at `patterns/api/health-endpoints.md` in the working copy at
`/Users/shinzui/Keikaku/bokuno/haskell-jitsurei`). Restated in full, so this plan is
self-contained:

> Every service serves `/health/live` (is the process alive) and `/health/ready` (should it
> receive traffic); liveness never checks dependencies, while readiness checks exactly the
> dependencies whose failure this pod's restart cannot fix. The typed probe surface comes
> from the released `servant-health` package — services supply checks and mount the routes;
> they never re-implement the probe code.

And the specific obligations that follow:

- Wrap **every** check in `safeCheck` so a thrown exception becomes a failed probe rather
  than a 500.
- Bound the liveness check with `withProbeTimeout` (microseconds), so a deadlocked or
  starved process fails liveness.
- Compose readiness with `sequenceChecks` (first failure wins).
- Wrap each probe with `newFailureTracker` so the wire field `failingSince` reports when the
  failure *began* across repeated probe calls, not the current instant.
- Do **not** add downstream HTTP services or brokers to readiness merely because the process
  calls them; a downstream readiness dependency cascades one outage across the fleet.
- Use `servant-health:testkit`'s `probeContractTests` as the required per-service test.
- Build the request logger's exclusion predicate and the problem-details exemption list from
  `Servant.Health.Paths.healthRawPaths`, not from string literals that can drift.
- A probe report describes current system state and is **not** an RFC 9457 error document.
  Exempt these named routes from the problem-details conformance test.

### What `servant-health` provides

Version 0.1.0.0, released on Hackage and registered in Mori as `shinzui/servant-health` with
an `Active` lifecycle. Its working copy is at `/Users/shinzui/Keikaku/bokuno/servant-health`.
The surface this plan uses, read from that source on 2026-08-25:

From `Servant.Health`: the `ProbeStatus` wire type (fields exactly `status`, `check`,
`failingSince`, with a non-orphan `ToSchema` that always matches the JSON codec); the
`ProbeResponses` `MultiVerb` list and its `ProbeResult` sum; the check seam
`ProbeCheck` (an `IO ProbeVerdict`, where `ProbeVerdict` is `Healthy` or
`Unhealthy <check> <since>`); the route record

```haskell
data HealthApi mode = HealthApi
  { live :: mode :- "live" :> MultiVerb 'GET '[JSON] ProbeResponses ProbeResult,
    ready :: mode :- "ready" :> MultiVerb 'GET '[JSON] ProbeResponses ProbeResult
  }
```

and the server, which is `MonadIO`-general so it composes with `en`'s `Handler`:

```haskell
healthServer :: (MonadIO m) => ProbeCheck -> ProbeCheck -> HealthApi (AsServerT m)
```

From `Servant.Health.Check`: `boolCheck`, `sequenceChecks`, `safeCheck`, `withProbeTimeout`,
and `newFailureTracker`.

From `Servant.Health.Paths`: `healthMountSegment = "health"`, `liveRawPath = "/health/live"`,
`readyRawPath = "/health/ready"`, and `healthRawPaths = [liveRawPath, readyRawPath]`, all
`ByteString`. Its own Haddock says to use these "in request-logger exclusion predicates and
conformance-test exemption lists instead of restating string literals".

From `servant-health:testkit`, module `Servant.Health.TestKit`:

```haskell
probeContractTests ::
  TestName ->
  (ProbeCheck -> ProbeCheck -> IO Application) ->
  TestTree
```

The kit owns the two checks so it can flip them between cases, and asserts the full matrix:
both healthy (two 200s with the healthy body), readiness failing alone (503 naming the
failed check **while liveness still answers 200**), liveness failing alone (the mirror
image), and the `application/json` content type. Those two "still answers 200"
cross-assertions are the dispatch proof — they are exactly what fails when the two probes are
wired to each other's checks. The kit also asserts the test suite is built with the threaded
runtime.

### Where `en` stands today

`en-server/app/Health.hs` is a single exported function:

```haskell
-- | Serve @GET \/healthz@ and @GET \/readyz@; pass everything else inward.
healthRoutes :: IO Bool -> Middleware
healthRoutes checkReady inner request respond
  | requestMethod request /= methodGet = inner request respond
  | otherwise =
      case pathInfo request of
        ["healthz"] -> respond alive
        ["readyz"] -> do
          ready <- checkReady
          respond (if ready then alive else notReady)
        _ -> inner request respond
```

The readiness action is built in `en-server/app/Main.hs` around line 361:

```haskell
      checkReady :: IO Bool
      checkReady = do
        healthy <- ping
        if healthy then pure True else ping
```

with a comment explaining the double ping (see Surprises & Discoveries). `ping` runs a
session through `En.Postgres.Database.runSession`, so it goes through the connection pool
rather than holding a raw connection.

The middleware stack in `Main.hs` around line 415 composes, outermost first:

```haskell
  let wrappedApp =
        authMiddleware serverConfig.auth
          . rateLimit
          . requestIdMiddleware
          . requestLogger
          . metricsMiddleware metrics
          . healthRoutes checkReady
          . metricsRoute metrics [...]
          $ appWithOpenApi serverEnv
```

`en`'s API record, in `en-servant/src/En/Servant/API.hs` around line 91:

```haskell
  { relationships :: mode :- "v1" :> NamedRoutes TupleRoutes,
    checks :: mode :- "v1" :> NamedRoutes CheckRoutes,
    lookups :: mode :- "v1" :> NamedRoutes LookupRoutes,
    expands :: mode :- "v1" :> NamedRoutes ExpandRoutes,
    schema :: mode :- "v1" :> NamedRoutes SchemaRoutes
  }
```

The five other references to the old paths are listed in Surprises & Discoveries.

### Relevant Architecture Decision Records

`en`'s ADRs live in `docs/adr/` as ordinary Markdown files with frontmatter `title`,
`status`, `date`, `authors`, `related`, and a body headed `# ADR N — <title>`. `mori.dhall`
declares one OKF bundle, `docs/capabilities`, and **none** at `docs/adr`, so the repository's
existing filesystem convention is authoritative and no OKF frontmatter belongs on an ADR
written here. Continue the numbering from the highest existing `ADR-N`.

One ADR constrains this plan:
[ADR 2 — crypton 1.1 binds en's dependency closure through a biscuit-haskell fork](../adr/0002-crypton-1-1-binds-en-s-dependency-closure-through-a-biscuit-haskell-fork.md).
Cabal resolves exactly one version of a package for the whole project, and `en`'s closure is
already tightly bound: `pg-migrate` requires `crypton >= 1.1`, which forces a forked
`biscuit-haskell` pinned by `source-repository-package` in `cabal.project`. This plan adds
`servant-health` and `servant-health:testkit` to that closure, which is why Milestone 1 is a
resolution proof with no code in it. The ADR also records the trap: relaxing a bound alone
can let the solver succeed while the compile fails on a missing instance, so "it solved" is
not the acceptance criterion — "it built" is.

[ADR 1](../adr/0001-en-s-schema-is-an-append-only-pg-migrate-component.md) and
[ADR 3](../adr/0003-the-in-memory-store-is-for-tests-and-demos-only.md) were read and do not
constrain this work: this plan adds no migration and changes no store interpreter.

This plan **owes a new ADR**, per its parent MasterPlan's Integration Points: that `en`'s
health-probe surface is `servant-health`'s and is never re-implemented in the service. Write
it in Milestone 5.

### How this plan relates to the others in its initiative

This is a child of
`docs/masterplans/11-bring-en-into-conformance-with-the-haskell-jitsurei-pattern-catalog.md`.

It **hard-depends on**
`docs/plans/61-adopt-rfc-9457-problem-details-and-close-the-api-conformance-audit.md`. Two
reasons. Milestone 5 exempts the probe routes from a conformance test that EP-61's Milestone
6 creates, so that test must exist. And EP-61's Milestone 5 converts `/readyz`'s failure body
to a problem document in `en-server/app/Health.hs` — the module *this* plan deletes. Running
this plan first would leave EP-61's Milestone 5 unable to type-check against the tree.

**That ordering means EP-61 converts a body this plan then deletes, one wave later.** That is
deliberate and is recorded in the MasterPlan's Decision Log: the alternatives were re-opening
a recently revised plan, or leaving `en` serving one endpoint in the old error dialect while
every other surface converted — the two-dialect outcome EP-61 exists to prevent. If you are
implementing this plan and find yourself deleting a freshly written problem-details renderer
in `Health.hs`, that is expected, not a mistake.

It **soft-depends on**
`docs/plans/63-adopt-the-fleet-haskell-core-standards-across-every-en-package.md`, whose
`-Werror=missing-fields` makes adding a field to the API record break the build until its
handler exists — useful here, since Milestone 2 adds exactly such a field.

`docs/plans/65-instrument-en-with-opentelemetry-and-a-conformant-production-request-log.md`
**hard-depends on this plan** for `Servant.Health.Paths.healthRawPaths`, and it owns the
final ordering of the middleware stack. **This plan must therefore leave the stack in a state
EP-65 can reorder rather than rebuild**: remove the `healthRoutes` layer, change nothing else
about the composition.

`docs/plans/66-add-a-hurl-black-box-api-suite-for-en-server.md` hard-depends on this plan
because its `health.hurl` file asserts the `servant-health` probe body at the new paths.

### Build and test commands

Work from `/Users/shinzui/Keikaku/bokuno/en` inside the nix development shell.

```bash
cd /Users/shinzui/Keikaku/bokuno/en
cabal build all
cabal test all
just openapi          # regenerates docs/api/openapi.json and fails on drift
```

For a live server: `just process-up` starts PostgreSQL, `just run-migrations` applies the
schema, `just start-server` runs `en-server`. If these do not work before you start, fix that
first.


## Plan of Work

### Milestone 1 — Prove the dependency resolves

Scope: `en-servant/en-servant.cabal` and `en-servant`'s test stanza. No `.hs` file changes.

Add the dependency and build. Nothing else.

```cabal
library
  build-depends:
    , servant-health ^>=0.1

test-suite en-servant-test
  build-depends:
    , servant-health:testkit ^>=0.1
```

`servant-health` goes in `en-servant` rather than `en-server` because the routes join the
API record, which `en-servant` owns. The `testkit` sub-library goes in whichever test suite
will host the contract test — `en-servant`'s, since that is where the application is
assembled from an `Env`.

Then run `cabal build all` and record what resolved:

```bash
python3 -c 'import json; p=json.load(open("dist-newstyle/cache/plan.json")); \
  print(sorted({(u["pkg-name"], u["pkg-version"]) for u in p["install-plan"] \
  if "servant-health" in u.get("pkg-name","")}))'
```

Expected: `servant-health 0.1.0.0`. If the solver fails, **stop and diagnose before doing
anything else** — per ADR 2, do not reach for `allow-newer` as a first move; find out which
package pair is in conflict with `cabal build all -v2` and record it in Surprises &
Discoveries. The whole point of making this its own milestone is that a conflict discovered
here costs nothing, while one discovered after Milestone 2 costs a milestone of work.

Acceptance: `cabal build all && cabal test all` passes with the dependency present and no
code using it; the resolved version is recorded in Interfaces and Dependencies.

### Milestone 2 — Mount the probes, keep the old ones

Scope: `en-servant/src/En/Servant/API.hs`, a new module for the checks, and
`en-server/app/Main.hs`. At the end, all four paths answer: `/health/live`, `/health/ready`,
`/healthz`, and `/readyz`. Serving both pairs briefly is what makes this milestone
independently verifiable — you can `curl` the new pair and the old pair and compare.

Add the field to the API record, as a sibling of `"v1"` rather than a child, so the probes
stay outside the versioned surface:

```haskell
  { health :: mode :- "health" :> NamedRoutes HealthApi,
    relationships :: mode :- "v1" :> NamedRoutes TupleRoutes,
    ...
  }
```

Use `Servant.Health.Paths.healthMountSegment` as the documented source of the literal
`"health"` — the segment must match the package's own path constants, and the constant is
there so the two cannot drift.

Then build the checks. Put them in a new module rather than inline in `Main.hs`, because
Milestone 3's test needs to construct them too. `en-server/app/Probes.hs` is the natural home
if the test assembles the application from `en-server`; if the test lives in `en-servant`,
put the module there instead and note the choice in the Decision Log.

Liveness must **not** touch PostgreSQL. `en`'s current `/healthz` is an unconditional 200,
which is a defensible liveness check but a weak one: it proves the socket accepted a
connection and nothing more. Give it something in-process to prove — reading the active
schema `IORef` that `Main.hs` already maintains is the natural candidate, since a process
that cannot read it is not serving anything useful — and bound it with a timeout so a starved
process fails:

```haskell
liveness =
  trackLive
    . withProbeTimeout 2_000_000 "liveness"
    . safeCheck "liveness"
    $ boolCheck "liveness" inProcessResponsive
```

Readiness pings PostgreSQL, and **the double ping goes inside the check** (see Surprises &
Discoveries — a single-shot probe flaps against a healthy database after a PostgreSQL
restart, because `hasql-pool` does not retire a connection on a statement-level failure):

```haskell
readiness =
  trackReady . sequenceChecks $
    [ safeCheck "postgres" (boolCheck "postgres" pingTwice) ]
```

Do **not** add any other dependency to readiness. `en` has exactly one hard runtime
dependency, and the standard is explicit that adding downstream services cascades one
outage across the fleet.

Wrap each probe with its own `newFailureTracker` — one per probe, created once at startup,
never per request — so `failingSince` reports when the failure began rather than the current
instant. A tracker created per request always reports "now", which is the bug this milestone
must not ship.

Wire the handler into the server record with `healthServer liveness readiness`.
`-Werror=missing-fields` (from `docs/plans/63-...`) makes the build fail until you do.

Acceptance: `cabal build all && cabal test all` passes. Against a running server,
`curl -s http://127.0.0.1:8080/health/live` and `.../health/ready` both answer `200` with a
JSON body carrying `status`, `check`, and `failingSince`; `/healthz` and `/readyz` still
answer as before. Stop PostgreSQL (`just process-down`, or stop just the database) and
confirm `/health/ready` answers `503` naming `postgres` while `/health/live` still answers
`200` — that asymmetry is the whole point of the split, and seeing it is worth the minute it
takes.

### Milestone 3 — Prove the wiring, by breaking it first

Scope: `en-servant`'s test suite (or `en-server`'s, matching Milestone 2's choice).

Mounting the routes is three lines and the two routes share one handler type, so a service
that swaps its liveness and readiness checks compiles cleanly and passes every ordinary test.
The package ships the proof:

```haskell
import Servant.Health.TestKit (probeContractTests)

probeTests :: TestTree
probeTests = probeContractTests "en probes" $ \liveCheck readyCheck ->
  pure (appWith testEnv liveCheck readyCheck)
```

The application builder must take the two checks as parameters so the kit can flip them
between cases — which means Milestone 2's assembly needs a seam that accepts them rather than
constructing them internally. If it does not, add one now; that refactor is part of this
milestone.

**Swap the two arguments deliberately and watch the test fail before making it pass.** The
kit's two "still answers 200" cross-assertions are precisely what catches this, and a guard
you have not seen fire is a guard you are trusting on faith. Paste the failure into Surprises
& Discoveries, then restore the correct wiring.

Note the kit also asserts the test suite is built with the threaded runtime, so the test
stanza needs `-threaded` in its `ghc-options` if it does not have it.

Acceptance: `cabal test all` passes; the deliberate swap produced a failure whose text is
recorded below.

### Milestone 4 — Remove the old surface

Scope: six files, listed in Surprises & Discoveries. This is a deletion milestone; do it as
its own commit so the diff is readable as a removal rather than a rewrite.

Delete `en-server/app/Health.hs` and its `other-modules` entry in `en-server/en-server.cabal`.
Remove the `. healthRoutes checkReady` layer from the middleware stack in
`en-server/app/Main.hs` — **and change nothing else about that composition**, because
`docs/plans/65-...` owns its final ordering and needs a stack it can reorder rather than
rebuild.

Then the five references:

- `en-server/app/Middleware.hs:70` — the auth and rate-limit exemption, which today reads
  ``pathInfo request `elem` [["healthz"], ["readyz"]]``. The probes still need exempting; a
  Kubernetes probe cannot carry credentials. Rewrite the predicate in terms of
  `Servant.Health.Paths.healthRawPaths`, comparing `rawPathInfo` rather than `pathInfo`, so
  it cannot drift from the mounted routes.
- `en-server/app/Metrics.hs:105,109` — the path list naming both probes. Update to the new
  paths, again from the constants.
- `en-server/app/Observability.hs:52` — `isProbePath`, the request-log exclusion. Same
  rewrite. (`docs/plans/65-...` revisits this function for trace correlation; leaving it
  correct here means that plan does not have to fix two things at once.)
- `justfile:43` — the readiness poll that decides `en-server` has started, currently
  `curl -fsS -o /dev/null "$url/healthz"`. Point it at `/health/live`: the target is asking
  "is the process up", which is liveness. The surrounding error message at `justfile:47`
  names `/healthz` too and must change with it.
- `process-compose.yaml:45` — `path: /readyz` becomes `path: /health/ready`.

Acceptance: `grep -rn "healthz\|readyz" . --exclude-dir=dist-newstyle --exclude-dir=.git`
returns **nothing** outside `docs/plans/` and `docs/masterplans/`;
`cabal build all && cabal test all` passes; `just start-server` still reports the server
started; and a live `curl` of `/healthz` returns the API's 404 problem document rather than
`200`.

### Milestone 5 — Exempt, regenerate, and record

Scope: `en-servant/test/Main.hs`, `docs/api/openapi.json`, and a new file in `docs/adr/`.

The problem-details conformance test created by
`docs/plans/61-adopt-rfc-9457-problem-details-and-close-the-api-conformance-audit.md`'s
Milestone 6 asserts that every error response in the generated document is keyed by
`application/problem+json`. The probe routes answer `503` with `application/json`, which is
correct — a probe report describes current system state and is not an error document — so
they must be exempted **by name**.

Take the names from `Servant.Health.Paths` rather than writing string literals, so the
exemption and the mounted route cannot drift apart. Exempt exactly the two paths, never a
prefix or a predicate that could silently grow to cover a real endpoint. Record the
justification in this plan's Decision Log, per the standard's requirement that each
exemption be a recorded decision rather than an accident.

Regenerate the document as its own commit:

```bash
cabal run en-openapi
just openapi        # must be clean afterwards
```

Read the diff rather than skimming it: two new operations should appear under
`/health/live` and `/health/ready`, each with a `200` and a `503`, both keyed by
`application/json`, with a `ProbeStatus` schema in `components.schemas`.

Finally, write the ADR. It records a durable architecture boundary — that the probe surface
belongs to `servant-health` and is never re-implemented in the service — and its value is
that the tempting future change ("it is three lines, just inline them") is exactly the one
the standard forbids, for a reason invisible at the call site. Follow the existing file
convention: `docs/adr/000N-<slug>.md`, frontmatter `title`, `status: accepted`, `date`,
`authors: [shinzui]`, `related:` naming this plan and
`mori://shinzui/servant-health`; body headed `# ADR N — <title>` with `## Status`,
`## Context`, `## Decision`, and `## Consequences`. Do not add OKF frontmatter.

Acceptance: `cabal test all` passes with the conformance test green and the exemption
present; `just openapi` is clean on a freshly regenerated tree; the ADR exists and this
plan's Decision Log names it.


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/en` inside the nix development shell. Baseline
first:

```bash
cd /Users/shinzui/Keikaku/bokuno/en
cabal build all
cabal test all
just openapi        # must be clean before you start
```

Find every reference to the old paths mechanically rather than trusting this plan's list:

```bash
grep -rn "healthz\|readyz" . \
  --exclude-dir=dist-newstyle --exclude-dir=.git --exclude-dir=docs
```

Treat the result as Milestone 4's checklist and re-run it at the end of that milestone.

Read the package you are about to depend on, from the source that matches the resolved
version:

```bash
mori registry show shinzui/servant-health --full
sed -n '1,40p' /Users/shinzui/Keikaku/bokuno/servant-health/src/Servant/Health/Paths.hs
grep -n "healthServer ::" -A6 /Users/shinzui/Keikaku/bokuno/servant-health/src/Servant/Health.hs
```

Confirm that checkout's `version:` field matches what `dist-newstyle/cache/plan.json`
resolved before trusting what you read there — a development checkout can sit ahead of its
release.

Then milestone by milestone. Every commit carries all three trailers:

```text
feat(en-servant): serve /health/live and /health/ready from servant-health

Mount the package's HealthApi record under "health", build en's liveness and
readiness checks from its combinators, and keep the double-ping readiness
semantics the connection pool requires.

MasterPlan: docs/masterplans/11-bring-en-into-conformance-with-the-haskell-jitsurei-pattern-catalog.md
ExecPlan: docs/plans/64-serve-kubernetes-health-probes-from-servant-health.md
Intention: intention_01m0xaavwqeznrgzs3j67m0q21
```


## Validation and Acceptance

### The live service

Start the stack and exercise both probes.

```bash
just process-up
just run-migrations
just start-server &
```

Healthy:

```bash
curl -s -i http://127.0.0.1:8080/health/live
curl -s -i http://127.0.0.1:8080/health/ready
```

Expected — both `200`, both `application/json`, both with a `status` of `ok`:

```text
HTTP/1.1 200 OK
Content-Type: application/json

{"status":"ok","check":"all","failingSince":null}
```

Now stop PostgreSQL while leaving `en-server` running, and probe again. This is the
observation that proves the split is real:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/health/live    # 200
curl -s http://127.0.0.1:8080/health/ready                                    # 503 + body
```

Expected: liveness **still 200** — a database outage must not restart the pod — and readiness
`503` with a body naming the failing check:

```json
{"status":"failed","check":"postgres","failingSince":"2026-08-25T19:04:11.221Z"}
```

Wait thirty seconds and probe readiness again. **`failingSince` must not move.** That is the
failure-tracker assertion, and it is the one thing a casual implementation gets wrong: a
tracker constructed per request reports the current instant every time, which looks correct
in a single response and is useless to an operator.

Bring PostgreSQL back, wait for the pool, and confirm readiness returns to `200` with
`failingSince` back to `null`.

The old paths must be gone. When authentication is enabled, supply a valid bearer key so
the request reaches routing; without one the outer authentication middleware correctly
answers 401 before Servant can answer 404:

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  -H 'Authorization: Bearer <development-key>' \
  http://127.0.0.1:8080/healthz   # 404
curl -s -o /dev/null -w '%{http_code}\n' \
  -H 'Authorization: Bearer <development-key>' \
  http://127.0.0.1:8080/readyz    # 404
```

And the probes must remain reachable without credentials — start the server with
authentication enabled and confirm both answer `200` with no `Authorization` header, which is
the `Middleware.hs` exemption still working through the new constants.

### The generated document

```bash
python3 - <<'PY'
import json
d = json.load(open("docs/api/openapi.json"))
for p in sorted(d["paths"]):
    if p.startswith("/health"):
        for m, o in d["paths"][p].items():
            print(m.upper(), p, sorted(o.get("responses", {})),
                  sorted(o.get("responses", {}).get("503", {}).get("content", {})))
print("ProbeStatus in schemas:", "ProbeStatus" in d["components"]["schemas"])
PY
```

Expected: `GET /health/live` and `GET /health/ready`, each with responses `['200', '503']`,
the `503` keyed by `['application/json']` — **not** `application/problem+json`, because a
probe report is not an error document — and `ProbeStatus` present in the schemas.

### What the test suite must additionally prove

`probeContractTests` covers the matrix, and its two cross-assertions ("readiness failing:
ready answers 503, live still 200", and the mirror image) are the dispatch proof. Beyond
running green, this milestone must have been observed **failing** with the two checks
deliberately swapped; that transcript belongs in Surprises & Discoveries.

The problem-details conformance test must still pass, with the two probe routes exempted by
name and nothing else newly exempted. Check the exemption list itself: it should name exactly
two paths, sourced from `Servant.Health.Paths`, not a prefix match.

### Deployment note

The probe paths change, so a Kubernetes manifest or Docker health check pointing at
`/healthz` or `/readyz` will fail against an image built after this plan. Update the manifest
in the same rollout. The standard's shape:

```yaml
livenessProbe:
  httpGet:
    path: /health/live
    port: http
  periodSeconds: 10
  timeoutSeconds: 2
  failureThreshold: 3
readinessProbe:
  httpGet:
    path: /health/ready
    port: http
  periodSeconds: 5
  timeoutSeconds: 2
  failureThreshold: 2
```

`en`'s deployment manifests are not in this repository, so this plan cannot change them; it
can only say clearly that they need changing.


## Idempotence and Recovery

Every step is an ordinary source edit plus a regenerated build artifact. Nothing touches the
database: this plan adds no migration, changes no table, and reads no persistent state it
also writes. `cabal build all` and `cabal test all` are pure functions of the tree.
`cabal run en-openapi` overwrites `docs/api/openapi.json` from the route types, so running it
twice produces the same bytes; `just openapi` is that plus `git diff --exit-code`.

Commit at each milestone boundary. `git checkout -- .` discards uncommitted work;
`git reset --hard HEAD` returns to the last commit.

Three specific recovery notes.

**If Milestone 1's solve fails**, revert `en-servant/en-servant.cabal` and diagnose before
trying again. Per ADR 2, do not widen a bound or add `allow-newer` as a first move: the
solver can succeed after a relaxed bound and the compile then fail on a missing instance,
which is a far more confusing place to be than an honest solver error. Run
`cabal build all -v2` and identify the conflicting pair.

**If Milestone 2 leaves the server unable to start**, the old probes are still mounted, so
`just start-server` and its `/healthz` poll still work — that is why Milestone 2 keeps both
pairs alive. Reverting Milestone 2 alone returns to a fully working server.

**Milestone 4 is the point of no return for the old paths.** Before committing it, confirm
Milestone 2's new probes actually answer against a live server; do not take the test suite's
word for it, since `Wai.Test` does not prove the packaged executable binds a socket and
applies its middleware. If something goes wrong after Milestone 4 is committed, the fastest
recovery is `git revert` of that single commit, which restores `Health.hs` and all five
references together.


## Interfaces and Dependencies

### Libraries

One package and one of its sub-libraries are added:

- **`servant-health ^>=0.1`** in `en-servant`'s library stanza. Owns the probe wire contract
  (`ProbeStatus`), the `HealthApi` route record, the `MonadIO`-general `healthServer`, the
  check combinators, and the path constants. Most importantly it owns the 200/503 `AsUnion`
  instance, which is the one piece of code this plan must not re-implement.
- **`servant-health:testkit ^>=0.1`** in the test suite that hosts the contract test. Owns
  `probeContractTests` and the checks it flips between cases.

Registered in Mori as `shinzui/servant-health`, `Active`, released on Hackage at 0.1.0.0.
The solver resolved **`servant-health-0.1.0.0`** in Milestone 1. Hackage's preferred-version
metadata and the upstream `v0.1.0.0` tag independently confirmed that this is the current
release, satisfying the MasterPlan's rule that each child plan proves its cohort before
writing code. `en`'s closure
is bound by `crypton >= 1.1` and a forked `biscuit-haskell` under
[ADR 2](../adr/0002-crypton-1-1-binds-en-s-dependency-closure-through-a-biscuit-haskell-fork.md).

Nothing is removed. `cabal.project` is not edited. The test stanza hosting the contract test
needs `-threaded` in its `ghc-options`, which the kit asserts.

### Types and functions that must exist, by milestone

At the end of **Milestone 2**, in `en-servant/src/En/Servant/API.hs`:

```haskell
health :: mode :- "health" :> NamedRoutes HealthApi   -- new field on the API record
```

and in the probes module (`en-server/app/Probes.hs` or the `en-servant` equivalent):

```haskell
mkProbes :: IO Bool -> IO Bool -> IO (ProbeCheck, ProbeCheck)
  -- takes an in-process responsiveness action and en's double PostgreSQL ping; returns
  -- (liveness, readiness), each already wrapped in its own failure tracker. Called ONCE
  -- at startup, never per request.
```

The application assembly must expose a seam taking the two checks as parameters, so
Milestone 3's test can supply its own:

```haskell
appWithProbes :: Env es -> ProbeCheck -> ProbeCheck -> Application
appWithOpenApiProbes :: Env es -> ProbeCheck -> ProbeCheck -> Application
```

At the end of **Milestone 4**, `en-server/app/Health.hs` does not exist, and
`Middleware.hs`, `Metrics.hs`, and `Observability.hs` reference
`Servant.Health.Paths.healthRawPaths` rather than string literals.

At the end of **Milestone 5**, `en-servant/test/Main.hs` carries the exemption list naming
exactly `Servant.Health.Paths.liveRawPath` and `readyRawPath`, and `docs/adr/` has one new
record.

### Modules that must not change

`en-server/app/Main.hs`'s middleware **composition order** beyond removing the
`healthRoutes` layer — `docs/plans/65-...` owns the final ordering and must be able to
reorder rather than rebuild.

`En.Servant.Seam`'s exports (`Env`, `AppEffects`, `MintEnv`, `ActiveSchema`, `EnServer`,
`runEngine`, `runEngineEither`) and `En.Servant.API`'s exports of `app` and the re-export
umbrella: `nagare` and `kikan-en` import those modules directly. Adding a field to the API
record changes `EnApi`'s shape, which is exported — so if either consumer constructs an
`EnApi` value rather than only calling `app`, it will need the new field. `kikan-en` is known
to import only `app`, `Env`, and `AppEffects`, so it is safe; confirm before assuming the
same of `nagare`, and record what you find.
