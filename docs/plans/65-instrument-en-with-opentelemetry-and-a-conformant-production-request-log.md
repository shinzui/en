---
id: 65
slug: instrument-en-with-opentelemetry-and-a-conformant-production-request-log
title: "Instrument en with OpenTelemetry and a conformant production request log"
kind: exec-plan
created_at: 2026-08-25T20:39:43Z
intention: "intention_01m0xaavwqeznrgzs3j67m0q21"
master_plan: "docs/masterplans/11-bring-en-into-conformance-with-the-haskell-jitsurei-pattern-catalog.md"
---

# Instrument en with OpenTelemetry and a conformant production request log

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

`en` emits no traces and no metrics to any telemetry backend. If a request to
`POST /v1/check` is slow, there is no way to see where the time went; if a caller reports an
error, there is no way to follow that one request through `en` and out to PostgreSQL. `en`
does write one JSON line per request to stdout — which is more than many services manage —
but that line carries no trace identifier, so it cannot be joined to anything.

After this plan, a request arriving with a W3C `traceparent` header produces a span in your
OTLP collector named by its **Servant route** — `POST v1/check`, not the bare `POST` that a
naive WAI instrumentation produces — and the access-log line for that same request carries
the matching `trace_id` and `span_id`. Concretely, given

```text
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
```

`en-server` writes:

```json
{"duration_ms":3.4,"method":"POST","path":"/v1/check","span_id":"10a3e37aac7ffcd5","status":200,"time":"2026-08-25T19:11:41.355741Z","trace_id":"4bf92f3577b34da6a3ce929d0e0e4736","user_agent":"curl/8.20.0"}
```

and the collector shows a span named `POST v1/check` carrying
`http.route = v1/check`, correlated to that log line by trace id.

The route dimension is the point. Without it, every span in the service is named `GET`,
`POST`, or `DELETE`, and per-endpoint latency, per-endpoint error rate, and any
`spanmetrics` aggregation have nothing to group by — the data arrives and is useless.

This plan also brings `en`'s existing access log to the fleet's exact field set. That is a
smaller job than it sounds: `en`'s logger was already written to the right shape for the
right reasons (see Surprises & Discoveries). What changes is the field names, the addition of
trace correlation, and the removal of two fields that are not in the bounded set.


## Progress

- [ ] Milestone 1 — Prove the OpenTelemetry cohort resolves against `en`'s pinned dependency
      closure: five released packages plus the forked Servant instrumentation pinned in
      `cabal.project`. `cabal build all` with the dependencies added and no code using them.
      Record every resolved version.
- [ ] Milestone 2 — Own the provider lifetimes in `en-server/app/Main.hs`: a tracer provider
      and a meter provider, both initialized globally inside `bracket`s that flush and shut
      down on exit, with an explicit disabled mode for local development.
- [ ] Milestone 3 — Install the WAI middleware outermost and
      `openTelemetryServantMiddleware` directly inside it, with the rest of the stack inside
      that. Prove a request produces a span named by its Servant route, not by its method.
- [ ] Milestone 4 — Conform the request logger: the bounded field set, `trace_id` and
      `span_id` read from the server span's context, and the probe-path exclusion built from
      `Servant.Health.Paths.healthRawPaths`.
- [ ] Milestone 5 — Document the telemetry environment variables, add them to the local
      development stack, and write the ADR recording that telemetry configuration lives
      outside the binary.


## Surprises & Discoveries

- Discovery (2026-08-25, while planning): **`en`'s hand-written request logger already made
  the standard's hardest call, independently and correctly.** The production request-logging
  standard's central negative rule is "do not promote `wai-extra`'s JSON formatter", because
  `formatAsJSON` serializes every request header while redacting only `Cookie` — writing each
  caller's `Authorization: Bearer <secret>` to stdout on every request — and because its
  `CustomOutputFormatWithDetails` carrier buffers the whole request body and accumulates the
  entire response into an `IORef Builder` before responding. The Haddock at the top of
  `en-server/app/Observability.hs` states exactly that reasoning and rejects `wai-extra` for
  exactly those two reasons, in a module written before the standard existed. Milestone 4 is
  therefore a field-set alignment, not a rewrite.

- Discovery (2026-08-25, while planning): **`en-server` is already built for the SDK.** The
  standard requires `-threaded` on every executable that initializes a tracer provider —
  without it, provider initialization fails at runtime with `The hs-opentelemetry batch
  processor does not work without the -threaded GHC flag!`.
  `en-server/en-server.cabal` already carries
  `ghc-options: -threaded -rtsopts -with-rtsopts=-N`. Nothing to do, but worth confirming
  rather than discovering at runtime.

- Discovery (2026-08-25, while planning): **`en` already excludes probe paths from its access
  log**, in `en-server/app/Observability.hs:52`'s `isProbePath`, with a comment giving the
  standard's own reason: "Probes fire every few seconds and would drown the log. They are
  also the two paths with nothing to correlate." Milestone 4 changes where the path constants
  come from, not whether the exclusion exists.

(Add further entries as work proceeds.)


## Decision Log

- Decision: Give telemetry an explicit enabled/disabled mode rather than relying on the
  absence of `OTEL_EXPORTER_OTLP_ENDPOINT`.
  Rationale: `en`'s local development stack (`just process-up`, `just start-server`) runs
  with no collector, and its test suites start servers in-process. A tracer provider that
  initializes and then fails to export produces either noisy warnings or silent buffering,
  neither of which is a good default for a developer who did not ask for telemetry. An
  explicit mode also makes the disabled path testable. The fleet reference implementation
  (`HospitalCapacity.Telemetry.withTelemetry`) does exactly this, so the shape is not novel.
  Date: 2026-08-25

- Decision: Drop `requestId` and `caller` from the access-log line, replacing their
  correlation role with `trace_id` and `span_id`.
  Rationale: the standard's field set is bounded deliberately — `time`, `method`, `path`,
  `status`, `duration_ms`, `trace_id`, `span_id`, `user_agent` — and its reasoning is that
  every additional field is a place for unbounded or sensitive data to leak. `requestId`
  existed to let a client's error report be matched against a server log line, which is
  exactly what `trace_id` does, better, and across services rather than within one. `caller`
  named the authenticated API key, which is bounded and useful but is *not* in the standard's
  set; it is dropped here rather than kept as an unrecorded local addition. If operations
  finds it genuinely necessary, re-add it as a named decision with a security review, which
  is the process the standard prescribes for exactly this case.
  Date: 2026-08-25

- Decision: Keep the `X-Request-Id` **response header** and its middleware, while removing
  the field from the log line.
  Rationale: these are two different things that happen to live in the same module. The
  header is a client-facing affordance — a caller can quote it in a bug report — and removing
  it would be a user-visible change this plan has no reason to make. The log *field* is
  redundant once `trace_id` is present. Keeping the header while dropping the field is the
  narrow change; note that `requestIdMiddleware` therefore stays in the stack.
  Date: 2026-08-25

- Decision: Do not instrument `hasql` in this plan, even though `shinzui/hasql-opentelemetry`
  exists and `en`'s work is database-bound.
  Rationale: the fleet standard covers the SDK lifecycle, the WAI middleware, Servant route
  naming, keiro, and the outbox — it says nothing about database instrumentation, so adding
  it here would be inventing scope rather than conforming. It is also a genuinely separate
  question: `en` runs its sessions through an effect stack and a connection pool, and where a
  span should start and end in that arrangement deserves its own thought. Recorded as a
  follow-up rather than folded in silently.
  Date: 2026-08-25

(Add further entries as work proceeds.)


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### What this repository is

`en` is a Haskell implementation of relationship-based authorization (ReBAC) in the style of
Google Zanzibar: it stores relationship *tuples* — facts like "user:alice is `viewer` of
space:project-x" — and answers questions about them over HTTP. It is built with `cabal` and
GHC 9.12.4, pinned by `cabal.project`, and work happens inside a nix development shell.

Two of its eight packages matter here. **`en-server`** is the standalone executable:
`en-server/app/Main.hs` assembles a WAI middleware stack around the servant application, and
`en-server/app/Observability.hs` holds the request-id middleware and the JSON access logger.
**`en-servant`** owns the HTTP API type in `en-servant/src/En/Servant/API.hs`, which is a
`NamedRoutes` record — needed here because the Servant instrumentation takes the API's
`Proxy`.

### Terms used in this plan

**OpenTelemetry** is a vendor-neutral standard for traces, metrics, and logs. **OTLP** is its
wire protocol; a **collector** is the process that receives OTLP and forwards it onward.

**A span** is one timed operation with a name and attributes. A **trace** is a tree of spans
sharing a trace id. A **server span** is the span an HTTP server opens for one incoming
request.

**W3C trace context** is the propagation format: an incoming `traceparent` header carries the
caller's trace id and span id, so the server's span becomes a child of the caller's rather
than the root of a new trace.

**A tracer provider** is the object that creates spans and owns the pipeline that exports
them, including a **batch span processor** that buffers spans and flushes them in groups — the
component that requires GHC's threaded runtime. A **meter provider** is its metrics
counterpart.

**Installing a provider globally** means putting it where library code can find it without
being handed it explicitly. This matters for ordering: the WAI middleware constructor reads
both global providers *at construction time* and builds its HTTP instruments then, so it must
be created after both global installs.

**`http.route`** is the OpenTelemetry semantic-convention attribute holding the route
*template* — `v1/relationships/{filter}` rather than the concrete path. It is what makes
per-endpoint aggregation possible, and it is low-cardinality by construction.

**WAI middleware composition is outside-in.** In `f (g (h app))`, `f` sees the request first
and the response last. So "outermost" means leftmost.

**A bounded field set** in logging means a fixed list of fields, chosen so no unbounded or
sensitive value can enter — the opposite of serializing whatever headers happen to arrive.

### The rules this plan implements

Two standards govern this work, both in the fleet's Haskell pattern catalog. Resolve either
with `mori path <uri>`; today they land under `patterns/api/` in the working copy at
`/Users/shinzui/Keikaku/bokuno/haskell-jitsurei`.

**`mori://shinzui/haskell-jitsurei/docs/api-opentelemetry-integration`**, restated:

> Every service initializes one tracer provider and one meter provider in brackets in
> `main`, creates the WAI middleware only after installing those providers globally, adds
> the Servant instrumentation middleware directly inside it, and passes the same tracer into
> keiro.

`en` has no keiro, so the last clause has nothing to apply to. The rest yields these specific
obligations:

- `-threaded` on every executable that initializes a provider. Not an optimization — the
  batch span processor fails at runtime without it.
- `bracket` the providers so buffered spans get a chance to leave before exit:
  `forceFlushTracerProvider` then `shutdownTracerProvider`, and `shutdownMeterProvider` for
  metrics. Never initialize a provider per request.
- Create `newOpenTelemetryWaiMiddleware` **after** both global installs, because its 1.0.0.0
  implementation reads both providers and builds its instruments at construction time.
- The tracing middleware is **leftmost**; `openTelemetryServantMiddleware` directly inside
  it; everything else inside that. Both other orderings are named as wrong in the standard:
  a logger outside the tracer runs before a server span exists and cannot correlate, and the
  Servant instrumentation outside the tracer finds no span to annotate and opens a redundant
  one of its own.
- Set `OTEL_SEMCONV_STABILITY_OPT_IN=http`, or the middleware emits legacy attribute names
  rather than stable ones like `http.request.method`, `url.path`, `http.response.status_code`.
- Configure telemetry through the environment, not the binary. Note the 1.0.0.0 exporter
  quirk the standard flags: `OTEL_EXPORTER_OTLP_ENDPOINT` takes the **base** URL, because the
  exporter appends `/v1/traces` and `/v1/metrics` itself; giving it a path-suffixed URL makes
  it append twice.
- The Servant instrumentation must come from **our fork**, pinned by commit — see below.

**`mori://shinzui/haskell-jitsurei/docs/api-request-logging`**, restated:

> `logStdoutDev` is for local development; a production service emits one bounded JSON
> request record per response, correlated to the trace, with strict data minimization.

The required field set is exactly: `time` (UTC ISO-8601 at response time), `method`, `path`
(`rawPathInfo`, without the query string), `status`, `duration_ms` (monotonic), `trace_id`
and `span_id` (lowercase Base16, when present), and `user_agent` — the only header allowed by
default. And the prohibitions: never read or log request bodies; never capture response
bodies; never log `Authorization`, `Cookie`, `Set-Cookie`, or arbitrary headers; never log the
raw query string by default, because credentials and one-time tokens routinely arrive there
despite API rules. Do not add unbounded high-cardinality values; put diagnostic detail in
structured application logs correlated by `trace_id`. If telemetry is disabled or sampling
drops a root span before it has a usable context, **omit** the correlation fields rather than
writing fake zero ids.

Exclude `/health/live` and `/health/ready` by predicate, built from
`Servant.Health.Paths.healthRawPaths` rather than string literals. Other exclusions require a
recorded reason; in particular, do not exclude authenticated application endpoints merely
because their traffic volume is high.

### The fork, and why it is not optional

`hs-opentelemetry-instrumentation-servant` must come from
`mori://shinzui/hs-opentelemetry-instrumentation-servant`, pinned by commit in
`cabal.project`:

```cabal
source-repository-package
  type: git
  location: https://github.com/shinzui/hs-opentelemetry-instrumentation-servant.git
  tag: 5e99a7857032484abc669076704dee4335e7d0ad
```

The package is not on Hackage in either form, and 0.3.0.0 exists only as a commit. The fork
is upstream plus two commits, both upstreamable and kept PR-ready:

- **`HasEndpoint` instances for `MultiVerb` and `AuthProtect`.** Upstream's instance list
  reaches `Verb`, `NoContentVerb`, `UVerb`, `Stream`, `Raw`, and `BasicAuth` and stops. `en`'s
  API is a `NamedRoutes` record of `MultiVerb` endpoints, so against upstream the
  `openTelemetryServantMiddleware` call site is a **type error**, not a missing attribute.
- **`hs-opentelemetry-api >=0.3 && <1.1`** replacing upstream's `==0.3.*`, so the package
  admits the 1.0.0.0 cohort. No `allow-newer` is needed and no source change was required.

Pin the commit rather than the branch so an upgrade is a deliberate edit.

What the instrumentation emits, and three things worth knowing before writing a dashboard
against it. The route format is servant-shaped — `:name` placeholders and **no leading
slash** — so a span is named `POST v1/check`, not `POST /v1/check`. This is conformant (the
convention requires low cardinality with static segments preserved, and permits custom
formatting provided the instrumentation documents it) but queries must match what is actually
emitted. The middleware also adds the **legacy** `http.method` attribute unconditionally, so
spans carry both it and the stable `http.request.method`; build queries on the stable one.
And when no route matches, the middleware passes through and the span keeps its method-only
name with no `http.route` — correct, since unrouted scanner paths must never become span
names, but it means 404s are indistinguishable in trace search.

`en` declares no `Raw` route, so the standard's `Raw`-fallback warning does not apply. Confirm
that with `grep -rn "Raw" en-servant/src` rather than assuming.

### Where `en` stands today

`grep -rln "opentelemetry\|OpenTelemetry" --include='*.hs' --include='*.cabal' .` returns
**nothing**. There is no provider, no exporter, no instrumentation, and no telemetry
configuration.

`en-server/en-server.cabal` already has `ghc-options: -threaded -rtsopts -with-rtsopts=-N` on
the executable stanza.

The middleware stack in `en-server/app/Main.hs` around line 415 composes, outermost first —
and its comment explains the current ordering, which was chosen for reasons unrelated to
tracing and which this plan changes:

```haskell
  let wrappedApp =
        authMiddleware serverConfig.auth
          . rateLimit
          . requestIdMiddleware
          . requestLogger
          . metricsMiddleware metrics
          . healthRoutes checkReady        -- removed by docs/plans/64-...
          . metricsRoute metrics [...]
          $ appWithOpenApi serverEnv
```

The access logger in `en-server/app/Observability.hs` writes, per response:

```haskell
logLine timestamp request status elapsedNs =
  object
    [ "time" .= timestamp,
      "requestId" .= headerText requestIdHeaderName,
      "caller" .= headerText callerHeaderName,
      "method" .= decode (requestMethod request),
      "path" .= decode (rawPathInfo request),
      "status" .= status.statusCode,
      "durationMs" .= (fromIntegral elapsedNs / 1e6 :: Double)
    ]
```

Read against the required set: `time`, `method`, `path`, and `status` already match;
`durationMs` needs renaming to `duration_ms`; `user_agent` is missing; `trace_id` and
`span_id` are missing; `requestId` and `caller` are extra. Duration is already measured on
the monotonic clock (`getMonotonicTimeNSec`), which the standard requires so an NTP step
cannot produce a negative latency, and writes are already serialized through an `MVar` so
concurrent responses cannot interleave bytes.

`en` also serves `GET /metrics` in Prometheus text format from `en-server/app/Metrics.hs`.
That is a separate mechanism from OpenTelemetry metrics and this plan does not remove it; see
the Decision Log if you are tempted to.

### Relevant Architecture Decision Records

`en`'s ADRs live in `docs/adr/` as ordinary Markdown files with frontmatter `title`,
`status`, `date`, `authors`, `related`, and a body headed `# ADR N — <title>`. `mori.dhall`
declares one OKF bundle, `docs/capabilities`, and **none** at `docs/adr`, so the repository's
filesystem convention is authoritative; no OKF frontmatter belongs on an ADR written here.

[ADR 2 — crypton 1.1 binds en's dependency closure through a biscuit-haskell fork](../adr/0002-crypton-1-1-binds-en-s-dependency-closure-through-a-biscuit-haskell-fork.md)
constrains this plan more than any other in its initiative, because this plan adds **six**
packages to `en`'s closure — five released and one forked — and a second
`source-repository-package` stanza to a `cabal.project` that already carries one. The ADR's
substance: cabal resolves exactly one version of a package for the whole project, `en`'s
closure is already bound by `pg-migrate`'s `crypton >= 1.1` and the forked
`biscuit-haskell` that requirement forced, and **relaxing a bound alone is not enough** —
the solver can succeed while the compile fails on a missing instance. Milestone 1 is a
resolution *and build* proof for exactly this reason.

The other two ADRs were read and do not constrain this work.

This plan **owes a new ADR**, per its parent MasterPlan's Integration Points: that `en`'s
telemetry configuration lives outside the binary, and that the Servant instrumentation comes
from a pinned fork. Write it in Milestone 5.

### How this plan relates to the others in its initiative

This is a child of
`docs/masterplans/11-bring-en-into-conformance-with-the-haskell-jitsurei-pattern-catalog.md`.

It **hard-depends on**
`docs/plans/64-serve-kubernetes-health-probes-from-servant-health.md`, for one specific
artifact: `Servant.Health.Paths.healthRawPaths`, the constants the access-log exclusion
predicate must be built from so it cannot drift from the mounted routes. Written before
EP-64, the predicate would name `/healthz` and `/readyz` literally and then be rewritten.

**This plan owns the final ordering of `en-server`'s middleware stack.** EP-64 removes the
`healthRoutes` layer and changes nothing else, deliberately leaving a stack this plan can
reorder. Milestone 3 carries the target composition verbatim.

It **soft-depends on**
`docs/plans/63-adopt-the-fleet-haskell-core-standards-across-every-en-package.md`.

`docs/plans/66-add-a-hurl-black-box-api-suite-for-en-server.md` soft-depends on this plan: a
black-box suite is a natural place to assert that a `traceparent` header round-trips, but it
does not need this plan to exist.

### Build and test commands

Work from `/Users/shinzui/Keikaku/bokuno/en` inside the nix development shell.

```bash
cd /Users/shinzui/Keikaku/bokuno/en
cabal build all
cabal test all
just process-up && just run-migrations && just start-server
```


## Plan of Work

### Milestone 1 — Prove six new packages resolve

Scope: `en-server/en-server.cabal` and `cabal.project`. No `.hs` file changes.

This milestone exists because of ADR 2, and because a dependency conflict discovered here
costs one revert while the same conflict discovered in Milestone 3 costs two milestones of
work.

Add to `en-server`'s executable stanza:

```cabal
    , hs-opentelemetry-api                    ==1.0.*
    , hs-opentelemetry-sdk                    ==1.0.*
    , hs-opentelemetry-exporter-otlp          ==1.0.*
    , hs-opentelemetry-instrumentation-wai    ==1.0.*
    , hs-opentelemetry-instrumentation-servant ==0.3.*
```

and to `cabal.project`, alongside the existing `biscuit-haskell` stanza:

```cabal
source-repository-package
  type:     git
  location: https://github.com/shinzui/hs-opentelemetry-instrumentation-servant.git
  tag:      5e99a7857032484abc669076704dee4335e7d0ad
```

Write a comment above that stanza explaining why it is a fork and a pin, in the style of the
existing `biscuit-haskell` comment: upstream's `HasEndpoint` instance list does not reach
`MultiVerb` or `AuthProtect`, so against upstream the middleware call site is a type error,
not a missing attribute; and upstream's `hs-opentelemetry-api ==0.3.*` bound excludes the
1.0.0 cohort. A future reader must be able to tell a load-bearing pin from an incidental one.

Then build, and record what resolved:

```bash
cabal build all
python3 -c 'import json; p=json.load(open("dist-newstyle/cache/plan.json")); \
  print(sorted({(u["pkg-name"], u["pkg-version"]) for u in p["install-plan"] \
  if "opentelemetry" in u.get("pkg-name","")}))'
```

Keep the API, SDK, exporter, propagator, semantic-conventions, and WAI instrumentation
packages on **one compatible cohort**. If the solver fails, stop and diagnose with
`cabal build all -v2` — do not add `allow-newer` as a first move, for the reason ADR 2
records.

Acceptance: `cabal build all && cabal test all` passes with all six dependencies present and
no code using them; every resolved OpenTelemetry version is recorded in Interfaces and
Dependencies.

### Milestone 2 — Own the provider lifetimes

Scope: a new module (`en-server/app/Telemetry.hs`) and `en-server/app/Main.hs`.

Two providers, both installed globally, both bracketed. The ordering constraint is
load-bearing: `newOpenTelemetryWaiMiddleware` reads both global providers and builds its HTTP
instruments **at construction time**, so it must be created after both installs — which is
why the middleware construction lives inside the inner bracket rather than before them.

```haskell
main :: IO ()
main =
  bracket OTel.initializeGlobalTracerProvider flushAndShutdown $ \provider ->
    bracket
      OTelMetric.initializeGlobalMeterProvider
      (\mp -> void (OTelMetric.shutdownMeterProvider mp Nothing))
      $ \_ -> do
        let tracer = OTel.makeTracer provider instrumentationLibrary OTel.tracerOptions
        otelMiddleware <- newOpenTelemetryWaiMiddleware
        ...
  where
    flushAndShutdown p =
      void (OTel.forceFlushTracerProvider p Nothing)
        *> void (OTel.shutdownTracerProvider p Nothing)

instrumentationLibrary :: OTel.InstrumentationLibrary
instrumentationLibrary =
  OTel.InstrumentationLibrary
    { OTel.libraryName = "en-server",
      OTel.libraryVersion = "<en-server's version>",
      OTel.librarySchemaUrl = "",
      OTel.libraryAttributes = Attributes.emptyAttributes
    }
```

`forceFlushTracerProvider` before `shutdownTracerProvider` is what gives buffered spans a
chance to leave before the process exits; skipping the flush loses whatever the batch
processor was holding.

Add the **disabled mode** (see the Decision Log). `en`'s development stack runs with no
collector and its tests start servers in-process, so telemetry must be explicitly switchable
off rather than initializing and failing to export. Put the switch in `en-server`'s existing
configuration validation so an invalid combination is caught at startup rather than at first
export, and make the disabled path a no-op middleware so the rest of the stack does not
branch. The fleet reference for this shape is `HospitalCapacity.Telemetry.withTelemetry` in
`keiro-runtime-jitsurei`; that application is worker-shaped with no HTTP server, so copy its
provider lifetime and add the WAI step here.

**`en-server` already has `-threaded`**, but confirm it rather than assuming — without it,
provider initialization fails at runtime with a message naming the batch processor.

Acceptance: `cabal build all && cabal test all` passes; `just start-server` starts and stops
cleanly with telemetry disabled; with telemetry enabled and no collector reachable, the
server still starts and still serves (buffered spans that cannot export must not take the
service down), and shutting it down does not hang.

### Milestone 3 — Order the stack, and get the route into the span

Scope: `en-server/app/Main.hs`.

The composition, exactly. Outermost first, so the tracing wrapper is leftmost:

```haskell
  let wrappedApp =
        otelMiddleware
          . openTelemetryServantMiddleware provider enApiProxy
          . authMiddleware serverConfig.auth
          . rateLimit
          . requestIdMiddleware
          . requestLogger
          . metricsMiddleware metrics
          . metricsRoute metrics [...]
          $ appWithOpenApi serverEnv
```

Both other orderings are wrong, and the standard names them: the request logger outside the
tracer runs before a server span exists and cannot correlate, and
`openTelemetryServantMiddleware` outside the tracer finds no span to annotate and opens a
redundant one of its own.

Note this moves `authMiddleware` from outermost to third. `en`'s current comment justifies
authentication being outermost so "a log line can name a verified caller" and so rate-limit
buckets are per-caller. The first reason dissolves in Milestone 4, which drops the `caller`
field. The second survives: rate limiting stays inside authentication, so buckets are still
per-caller. **Rewrite that comment** rather than leaving it describing an order that no longer
holds — a stale comment about middleware ordering is worse than none, because the ordering is
exactly what a reader cannot infer.

`enApiProxy` must be the same `Proxy` passed to `serve`. If the API is mounted under a
prefix, the proxy must carry that prefix too, or nothing matches and no route is ever
recorded.

Then **prove the route reaches the span**, because this is the entire value of the milestone
and it fails silently. Point the server at a collector (or an OTLP debug receiver), send a
request with a `traceparent`, and confirm the span name. Expected: `POST v1/check` — servant
shape, no leading slash — carrying `http.route = v1/check`, `http.framework = servant`, and
both `http.request.method` and the legacy `http.method`. A span named bare `POST` with no
`http.route` means the Servant middleware is not seeing the span, which means the ordering is
wrong.

Set `OTEL_SEMCONV_STABILITY_OPT_IN=http` before that test, or you will see legacy attribute
names throughout and conclude something is broken when it is merely unconfigured.

Acceptance: `cabal build all && cabal test all` passes; a traced request produces a span
named by its route, and the transcript is recorded in Surprises & Discoveries; the middleware
comment in `Main.hs` describes the order that is actually there.

### Milestone 4 — Conform the access log

Scope: `en-server/app/Observability.hs`.

Rewrite `logLine` to the required field set and nothing else:

```haskell
    [ "time" .= now,
      "method" .= decode (requestMethod request),
      "path" .= decode (rawPathInfo request),
      "status" .= statusCode (responseStatus response),
      "duration_ms" .= durationMs,
      "user_agent" .= fmap decode (lookup hUserAgent (requestHeaders request))
    ]
      <> correlation
```

with correlation read from the server span's context:

```haskell
correlationFields :: Request -> IO [Pair]
correlationFields request =
  case requestContext request >>= lookupSpan of
    Nothing -> pure []
    Just span' -> do
      context <- getSpanContext span'
      pure
        [ "trace_id" .= traceIdBaseEncodedText Base16 (traceId context),
          "span_id" .= spanIdBaseEncodedText Base16 (spanId context)
        ]
```

`requestContext` reads what the OTel WAI middleware stored in the request vault, so it
returns `Nothing` unless this logger runs **inside** that middleware — which Milestone 3
arranged. The `Nothing` case omitting the fields is required, not merely tolerated: writing
zero ids when telemetry is disabled or a root span was sampled away produces log lines that
join to nothing and look like real correlation.

Changes from what is there: `durationMs` becomes `duration_ms`; `user_agent` is added;
`requestId` and `caller` are removed (see the Decision Log — the `X-Request-Id` *header* and
its middleware stay). Keep what is already right: the monotonic clock, the `MVar` serializing
writes, and rendering the line before making one `Handle` operation.

Rewrite the exclusion predicate to use the constants rather than literals:

```haskell
import Servant.Health.Paths (healthRawPaths)

defaultRequestLogPredicate :: Request -> Bool
defaultRequestLogPredicate request = rawPathInfo request `notElem` healthRawPaths
```

If `docs/plans/64-...` already made this change, verify it rather than repeating it.

Then re-read the module against the prohibitions, mechanically rather than by memory: no
request body is read, no response body is captured, no `Authorization`/`Cookie`/`Set-Cookie`
or arbitrary header is logged, and the raw query string appears nowhere.

Acceptance: `cabal build all && cabal test all` passes; a live request with a `traceparent`
produces a log line whose `trace_id` matches the header's and whose `span_id` is the server's
child span, recorded as a transcript below; a request with telemetry disabled produces a line
with **no** `trace_id` or `span_id` keys at all; and probes produce no line.

### Milestone 5 — Configuration, documentation, and the ADR

Scope: the repository's operational documentation, `process-compose.yaml` or the equivalent
local stack, and one new file in `docs/adr/`.

Document the environment variables `en-server` now reads, and the one quirk that will
otherwise cost someone an afternoon:

```bash
OTEL_SERVICE_NAME=en
OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318   # BASE url, no /v1/traces suffix
OTEL_SEMCONV_STABILITY_OPT_IN=http
```

The endpoint quirk is the standard's own warning about the 1.0.0.0 exporter: it appends
`/v1/traces` and `/v1/metrics` itself, so a path-suffixed URL makes it append twice and every
export 404s. Say so where an operator will read it.

Then the ADR, recording two durable things: that telemetry configuration lives outside the
binary in environment variables `en`'s own configuration validation does not own, and that
the Servant instrumentation comes from a commit-pinned fork whose two commits are
upstreamable and whose absence is a type error rather than a missing attribute. Follow the
existing convention — `docs/adr/000N-<slug>.md`, frontmatter `title`, `status: accepted`,
`date`, `authors: [shinzui]`, `related:` naming this plan and
`mori://shinzui/hs-opentelemetry-instrumentation-servant`; body headed `# ADR N — <title>`
with `## Status`, `## Context`, `## Decision`, `## Consequences`. No OKF frontmatter.

Acceptance: an operator can start `en-server` with telemetry enabled by following the
documentation alone; the ADR exists and this plan's Decision Log names it.


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/en` inside the nix development shell. Baseline:

```bash
cd /Users/shinzui/Keikaku/bokuno/en
cabal build all
cabal test all
```

Confirm the two facts this plan relies on rather than trusting them:

```bash
grep -n "threaded" en-server/en-server.cabal          # -threaded must be present
grep -rn "Raw" en-servant/src                          # expect no Raw route
```

Milestone 1, then read what resolved:

```bash
$EDITOR en-server/en-server.cabal cabal.project
cabal build all
python3 -c 'import json; p=json.load(open("dist-newstyle/cache/plan.json")); \
  print(sorted({(u["pkg-name"], u["pkg-version"]) for u in p["install-plan"] \
  if "opentelemetry" in u.get("pkg-name","")}))'
```

For Milestones 3 and 4 you need somewhere for OTLP to go. Any OTLP receiver that prints what
it gets will do; the point is to read span names and attributes, not to keep the data.

```bash
export OTEL_SERVICE_NAME=en
export OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318
export OTEL_SEMCONV_STABILITY_OPT_IN=http
just start-server

curl -s -X POST http://127.0.0.1:8080/v1/check \
  -H 'content-type: application/json' \
  -H 'traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01' \
  -d '{...}'
```

Every commit carries all three trailers:

```text
feat(en-server): trace requests by Servant route

Own the tracer and meter provider lifetimes in main, install the WAI
instrumentation outermost with the Servant route naming directly inside it,
and correlate the access log to the server span.

MasterPlan: docs/masterplans/11-bring-en-into-conformance-with-the-haskell-jitsurei-pattern-catalog.md
ExecPlan: docs/plans/65-instrument-en-with-opentelemetry-and-a-conformant-production-request-log.md
Intention: intention_01m0xaavwqeznrgzs3j67m0q21
```


## Validation and Acceptance

### The span carries its route

With the server running against a collector and `OTEL_SEMCONV_STABILITY_OPT_IN=http` set,
send a request to a `MultiVerb` endpoint with a `traceparent` header. In the collector,
expect one server span with:

| Property | Expected |
| --- | --- |
| span name | `POST v1/check` — servant shape, **no leading slash** |
| `http.route` | `v1/check` |
| `http.request.method` | `POST` (stable name) |
| `http.method` | `POST` (legacy, emitted unconditionally — harmless duplication) |
| `http.framework` | `servant` |
| trace id | `4bf92f3577b34da6a3ce929d0e0e4736` — the caller's, not a fresh one |

A span named bare `POST` with no `http.route` is the failure this milestone exists to
prevent: it means `openTelemetryServantMiddleware` is not seeing the WAI span, which means
the middleware ordering is wrong. A **fresh** trace id rather than the caller's means W3C
propagation is not working, which means the WAI middleware is not outermost.

Send a request to a path that matches no route (`/nope`). Expect a span named bare `POST`
with **no** `http.route` — that is the correct outcome, since unrouted scanner paths must
never become span names.

### The log line joins to the span

```bash
curl -s -X POST http://127.0.0.1:8080/v1/check \
  -H 'traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01' \
  -H 'user-agent: curl/8.20.0' -d '{...}'
```

Expected on `en-server`'s stdout — one line, exactly these keys:

```json
{"duration_ms":3.4,"method":"POST","path":"/v1/check","span_id":"10a3e37aac7ffcd5","status":200,"time":"2026-08-25T19:11:41.355741Z","trace_id":"4bf92f3577b34da6a3ce929d0e0e4736","user_agent":"curl/8.20.0"}
```

The `trace_id` must equal the one in the `traceparent`. The `span_id` must be the server's
own child span, **not** the `00f067aa0ba902b7` from the header. No `requestId`, no `caller`,
no `Authorization`, no query string.

Now restart with telemetry disabled and repeat. Expected: the same line **without** the
`trace_id` and `span_id` keys — absent, not zero-valued. Zeros here would be worse than
nothing, because they look like correlation and join to no span.

### Data minimization holds

```bash
curl -s "http://127.0.0.1:8080/v1/check?token=SUPERSECRET" \
  -H 'authorization: Bearer alsosecret' -H 'cookie: session=nope' -d '{...}'
```

Then grep the server's output. `SUPERSECRET`, `alsosecret`, and `session=nope` must appear
**nowhere**. The query string in particular is the one the standard singles out, because
credentials and one-time tokens routinely arrive there despite API rules — and `path` is
`rawPathInfo`, which excludes it.

### Probes stay quiet

```bash
for i in $(seq 1 20); do curl -s -o /dev/null http://127.0.0.1:8080/health/ready; done
```

Expected: zero new log lines. The probes still answer, and Kubernetes still records their
results; what the standard excludes is turning twenty successful probes into twenty access
lines that bury real traffic.

### Shutdown flushes

Send a request, then stop the server promptly with SIGTERM. The span for that request must
still arrive at the collector — that is what `forceFlushTracerProvider` before
`shutdownTracerProvider` buys, and skipping the flush loses whatever the batch processor was
holding. A span that never arrives means the bracket is wrong.

### Nothing regressed

`cabal build all && cabal test all` passes. `just start-server` works with telemetry both
enabled and disabled. `GET /metrics` still serves Prometheus text — this plan adds
OpenTelemetry metrics alongside it and removes nothing.


## Idempotence and Recovery

Every step is an ordinary source edit. Nothing touches the database, no migration is added,
and no persistent state is read that is also written. `cabal build all` and `cabal test all`
are pure functions of the tree, and re-running any step converges.

Commit at each milestone boundary. `git checkout -- .` discards uncommitted work;
`git reset --hard HEAD` returns to the last commit.

Four specific recovery notes.

**If Milestone 1's solve fails**, revert `en-server/en-server.cabal` and `cabal.project`
together and diagnose with `cabal build all -v2` before trying again. Per ADR 2, do not reach
for `allow-newer` or a widened bound first: the solver can succeed after a relaxed bound and
the compile then fail on a missing instance, which is much harder to diagnose than a plain
solver error. The likeliest conflict is between the OpenTelemetry cohort and the existing
`crypton >= 1.1` constraint, so check that pair first.

**If the server fails to start with a message about the batch processor**, `-threaded` is
missing from whichever executable is running. It is present on `en-server` today; a test
suite that initializes a provider needs it too.

**If spans stop arriving after a middleware edit**, the ordering is the first thing to check,
not the exporter. `otelMiddleware` must be leftmost and
`openTelemetryServantMiddleware` directly inside it. Reverting Milestone 3's single commit
restores a working stack.

**If telemetry misbehaves in a way you cannot quickly diagnose**, the disabled mode from
Milestone 2 is the escape hatch: `en-server` runs and serves with telemetry off, so a
production incident never needs a rollback of this whole plan.


## Interfaces and Dependencies

### Libraries

Six packages are added to `en-server`'s executable stanza. Five are released and pinned by
version; one is a fork pinned by commit in `cabal.project`.

- **`hs-opentelemetry-api ==1.0.*`** — the tracer, span, and context types.
- **`hs-opentelemetry-sdk ==1.0.*`** — the provider implementations and the batch span
  processor that requires the threaded runtime.
- **`hs-opentelemetry-exporter-otlp ==1.0.*`** — the OTLP exporter.
- **`hs-opentelemetry-instrumentation-wai ==1.0.*`** — `newOpenTelemetryWaiMiddleware`, which
  extracts W3C context from the incoming headers, creates the server span, attaches its
  context for the request, places that context in the request vault for `requestContext`,
  injects context into the response headers, records the stable HTTP metrics, and marks 5xx
  spans as errors. Its attach/detach bracket is what stops Warp keep-alive threads leaking
  one request's context into the next.
- **`hs-opentelemetry-instrumentation-servant ==0.3.*`**, from the fork — see below.

Keep the API, SDK, exporter, propagator, semantic-conventions, and WAI instrumentation on one
compatible cohort. The Servant instrumentation is versioned independently.

The fork pin, added to `cabal.project` alongside the existing `biscuit-haskell` stanza:

```cabal
source-repository-package
  type:     git
  location: https://github.com/shinzui/hs-opentelemetry-instrumentation-servant.git
  tag:      5e99a7857032484abc669076704dee4335e7d0ad
```

That commit is the tip of the fork's `main`, two commits ahead of upstream `04141b2b`, and
its Mori handle is `mori://shinzui/hs-opentelemetry-instrumentation-servant`. The two commits
add `HasEndpoint` instances for `MultiVerb` and `AuthProtect` (without which the middleware
call site is a **type error** against `en`'s API) and widen `hs-opentelemetry-api` to
`>=0.3 && <1.1`. Both are upstreamable and the branch is kept PR-ready.

**Record every resolved version here when Milestone 1 lands**, per the MasterPlan's rule that
each child plan proves its cohort before writing code. `en`'s closure is bound by
`crypton >= 1.1` and a forked `biscuit-haskell` under
[ADR 2](../adr/0002-crypton-1-1-binds-en-s-dependency-closure-through-a-biscuit-haskell-fork.md).

No package is removed. `wai-extra` stays if something else in the tree uses it; the production
logging standard does not require it, and `en` does not use its `RequestLogger`.

### Types and functions that must exist, by milestone

At the end of **Milestone 2**, in `en-server/app/Telemetry.hs`:

```haskell
withTelemetry :: TelemetryConfig -> ((Maybe TracerProvider, Middleware) -> IO a) -> IO a
  -- brackets both providers, installs them globally, and constructs the WAI middleware
  -- AFTER both installs. With telemetry disabled, yields (Nothing, id).

instrumentationLibrary :: OTel.InstrumentationLibrary
```

At the end of **Milestone 3**, `en-server/app/Main.hs` composes the stack in the order given
above, and its explanatory comment describes that order rather than the previous one.

At the end of **Milestone 4**, in `en-server/app/Observability.hs`:

```haskell
correlationFields :: Request -> IO [Pair]
  -- [] when no server span is in the request vault; never fabricated zero ids

defaultRequestLogPredicate :: Request -> Bool
  -- built from Servant.Health.Paths.healthRawPaths
```

### Modules that must not change

`en-servant`'s API type and handlers. This plan instruments the server; it changes no route,
no response, and no wire shape, so `docs/api/openapi.json` must be **unchanged** by it. If
`just openapi` reports drift after any milestone here, something has gone wrong.

`En.Servant.Seam`'s exports and `En.Servant.API`'s exports of `app` and its re-export
umbrella — `nagare` and `kikan-en` import those directly. Note that embedded hosts serving
`app` themselves get **no** telemetry from this plan, because the instrumentation lives in
`en-server`'s stack rather than inside `app`. That is the right boundary — an embedding host
owns its own provider lifetime and would not want `en` initializing a global provider behind
its back — but it should be stated in the ADR so it is a decision rather than an omission.
