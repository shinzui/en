---
title: "telemetry configuration and provider lifetimes belong to the standalone host"
status: accepted
date: 2026-08-25
authors: [shinzui]
related:
  - docs/plans/65-instrument-en-with-opentelemetry-and-a-conformant-production-request-log.md
  - docs/masterplans/11-bring-en-into-conformance-with-the-haskell-jitsurei-pattern-catalog.md
  - mori://shinzui/hs-opentelemetry-instrumentation-servant
  - mori://shinzui/haskell-jitsurei/docs/api-opentelemetry-integration
---

# ADR 5 — telemetry configuration and provider lifetimes belong to the standalone host

## Status

Accepted, 2026-08-25. Implemented by
[ExecPlan 65](../plans/65-instrument-en-with-opentelemetry-and-a-conformant-production-request-log.md).

## Context

The fleet OpenTelemetry pattern requires a process-wide tracer provider, meter provider,
WAI server spans, Servant route naming, OTLP export, and trace-correlated request logs. The
providers have process lifetimes: globals must be installed before middleware is constructed,
and traces must be force-flushed before provider shutdown. That ownership cannot live safely
inside `en-servant`. Embedded applications import its builders and own their own process,
telemetry pipeline, and global providers; initializing globals behind their back would make
library composition order-dependent.

The released `hs-opentelemetry-instrumentation-servant-0.3.0.0` also cannot instrument en's
actual API. Its dependency bound excludes `hs-opentelemetry-api-1.0`, and it lacks
`HasEndpoint` instances for `MultiVerb` and `AuthProtect`. The first problem prevents the
OpenTelemetry cohort from resolving; the second appears as a type error at the middleware
call site rather than as a span that silently lacks a route.

The two narrow fixes exist as separate upstreamable commits in
`mori://shinzui/hs-opentelemetry-instrumentation-servant`: one widens the API dependency to
the 1.0 cohort, and one adds the missing endpoint instances. The en project pins the combined
fork commit `5e99a7857032484abc669076704dee4335e7d0ad` until an upstream release contains both.

## Decision

The standalone `en-server` executable owns telemetry initialization and shutdown. Its
`Telemetry.withTelemetry` bracket installs both global providers, then constructs the WAI
middleware. On exit it force-flushes traces before shutting down the tracer and meter
providers. The WAI middleware is outermost, the Servant middleware immediately inside it,
and both use the surface represented by the same `servedProxy` passed to `serveWithContext`.

`EN_TELEMETRY_ENABLED` is en's only service-specific telemetry setting. It is validated at
startup, defaults to `false`, and selects either real providers and middleware or the exact
disabled value `(Nothing, id)`. Export destinations, service identity, sampling,
propagation, resources, metrics, and SDK disabling remain standard `OTEL_*` environment
variables interpreted by the SDK. They live outside en's configuration model and are not
duplicated or validated by the binary.

The Servant instrumentation remains a commit-pinned `source-repository-package` from
`mori://shinzui/hs-opentelemetry-instrumentation-servant`. The pin is load-bearing until a
released upstream package both accepts the API 1.0 cohort and provides the endpoint instances
required by en's API.

## Consequences

Operators opt into telemetry explicitly and otherwise get no provider, exporter attempts, or
trace fields in request logs. With telemetry enabled, the SDK's normal `OTEL_*` namespace is
the configuration contract; in particular the OTLP endpoint is a base URL because the
1.0.0.0 exporter appends signal paths itself.

The packaged server exports route-named spans and bounded request logs whose trace and span
identifiers join to the server span. `X-Request-Id` remains a client-facing response header
but is not part of that log schema.

Applications embedding `en-servant` receive no automatic instrumentation from this decision.
Their host must own provider lifetime and middleware placement. This is intentional: en's
library surface cannot initialize or replace process-wide providers.

Dropping or advancing the Servant fork pin requires re-running the actual middleware build and
collector-backed route-name proof. A successful dependency solve alone does not prove that
`MultiVerb` and `AuthProtect` remain instrumentable.
