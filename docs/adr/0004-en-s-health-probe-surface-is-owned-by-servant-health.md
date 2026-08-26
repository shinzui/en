---
title: "en's health-probe surface is owned by servant-health"
status: accepted
date: 2026-08-25
authors: [shinzui]
related:
  - docs/plans/64-serve-kubernetes-health-probes-from-servant-health.md
  - docs/masterplans/11-bring-en-into-conformance-with-the-haskell-jitsurei-pattern-catalog.md
  - mori://shinzui/servant-health
  - mori://shinzui/haskell-jitsurei/docs/api-health-endpoints
---

# ADR 4 — en's health-probe surface is owned by servant-health

## Status

Accepted, 2026-08-25. Implemented by
[ExecPlan 64](../plans/64-serve-kubernetes-health-probes-from-servant-health.md).

## Context

`en-server` previously implemented `GET /healthz` and `GET /readyz` as a WAI
middleware in `en-server/app/Health.hs`. Liveness always returned a small local JSON
object. Readiness ran en's PostgreSQL double ping and returned either that object or an
RFC 9457 problem document. The endpoints were outside the Servant API type, absent from
OpenAPI, and repeated readiness failures did not say when the failure began.

The fleet standard at
`mori://shinzui/haskell-jitsurei/docs/api-health-endpoints` instead requires
`GET /health/live` and `GET /health/ready` from the released
`mori://shinzui/servant-health` package. This is an architecture boundary rather than a
path-naming preference. Both the successful and failed alternatives carry the same
`ProbeStatus` body type, so an incorrect `AsUnion` instance that maps a passed probe to
503 and a failed probe to 200 compiles. Keeping that mapping in each service would copy a
subtle correctness hazard throughout the fleet.

Liveness and readiness also have different operational meanings. Liveness may restart a
container, so it must remain in-process and must not depend on PostgreSQL. Readiness may
remove the pod from traffic, so it checks PostgreSQL while preserving en's existing
double-ping behavior for stale pooled connections.

## Decision

The standalone service mounts `Servant.Health.HealthApi` under `/health` and delegates
response construction, the `ProbeStatus` wire contract, and the 200/503 mapping to
`servant-health`. En supplies only its checks:

- liveness reads in-process schema state and is wrapped by `safeCheck`, a two-second
  `withProbeTimeout`, and its own failure tracker;
- readiness runs the existing PostgreSQL double ping inside `boolCheck`, composes it with
  `sequenceChecks`, wraps it with `safeCheck`, and uses a separate failure tracker.

The checks are constructed once at startup. `servant-health:testkit` drives en's real
application builder and proves the two routes are not transposed. Middleware integrations
use `Servant.Health.Paths.healthRawPaths`; they do not restate path literals.

The probe report is current system state, not an API error, so the two exact routes are
exempt from the RFC 9457 problem-details media-type rule. They remain unauthenticated and
rate-limit-exempt so an orchestrator can call them. The obsolete `/healthz` and `/readyz`
routes have no compatibility aliases.

The source-compatible `server`, `app`, and `appWithOpenApi` builders retain healthy probe
defaults for embedded consumers. A host that exposes these routes as operational probes
must use `serverWithProbes`, `appWithProbes`, or `appWithOpenApiProbes` and supply checks
that describe its own runtime dependencies. The packaged `en-server` always uses the
explicit probe-aware builder.

## Consequences

The probe routes are now part of the Servant API and the generated OpenAPI document. Their
wire status vocabulary is `ok` and `failed`; a healthy report names `all`, while a failed
report names the failing check and carries a stable `failingSince` timestamp for the
consecutive failure run.

Deployment manifests must change their paths in the same rollout as the new image. An old
manifest probing `/healthz` or `/readyz` will no longer receive a probe response.

Future changes to the probe wire type or status mapping belong in
`mori://shinzui/servant-health`, not in en. En may add or change the checks it supplies,
but it must keep liveness dependency-free, preserve its PostgreSQL readiness semantics,
and pass the package's contract test.
