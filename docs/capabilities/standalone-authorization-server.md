---
title: "Standalone authorization server"
type: Capability
description: "A deployable HTTP service over the libraries with startup-validated configuration, API-key auth, rate limiting, optional TLS, health and readiness probes, Prometheus metrics, JSON request logging, graceful shutdown, and background GC."
generated:
  by: anthropic/claude-opus-5
  at: "2026-08-24T14:35:00Z"
capabilityId: CAP-20
provider: mori://shinzui/en
status: shipped
stability: experimental
since: unreleased
packages:
  - en-server
interface:
  - en-server serve
requires:
  - CAP-13
  - CAP-18
evidence:
  - kind: module
    resource: en-server/app/Config.hs
    proves: Every environment variable is parsed and validated at startup — deadline ordering, pool, TLS, rate limit, maintenance, auth, and Biscuit TTL ordering — with unknown-variable warnings and a refusal to enable minting without caller authentication.
  - kind: module
    resource: en-server/app/Middleware.hs
    proves: Constant-time bearer-key authentication, read-only keys rejected on write routes, exempt probe paths, and a token-bucket rate limiter keyed by caller.
  - kind: module
    resource: en-server/app/Metrics.hs
    proves: A Prometheus endpoint publishing per-path/per-status request counts and latency totals plus cache statistics.
  - kind: guide
    resource: docs/user/service-and-operations.md
    proves: "Running the server: configuration, pooling, probes, shutdown, logging, metrics, background maintenance, auth, rate limiting, and TLS."
---

# Standalone authorization server

`en-server` is a thin application layer that wires [the engine](check-decisions-with-caveats.md)
over [the PostgreSQL store](postgres-tuple-store.md) and serves
[the Servant API](servant-http-api.md). It ships with a built-in demo schema so it starts
without configuration, and takes a real one via `EN_SCHEMA_PATH`.

What it adds beyond the API:

- **Configuration validated at startup.** Misordered deadlines, a TTL maximum below the default,
  or minting enabled without caller authentication all refuse to start rather than serving.
- **Authentication and rate limiting.** Bearer API keys compared in constant time, with
  read-only keys rejected on write routes, and a per-caller token bucket.
- **Probes.** Liveness always answers; readiness reflects store reachability.
- **Observability.** Prometheus metrics including cache stats, optional OpenTelemetry spans
  named by Servant route and exported over OTLP, and bounded JSON request logs carrying the
  active trace and span identifiers. Probe paths are excluded.
- **Graceful shutdown** on signal, and a **background maintenance loop** that reclaims
  tombstoned rows in bounded batches and advances the GC horizon.

## Limits

- Authentication is static API keys from configuration. There is no key-management API, no
  rotation endpoint, and no per-key scoping beyond read-only vs read-write.
- Rate limiting is per-process, so N replicas permit N times the configured rate.
- The GC horizon the maintenance loop advances is what bounds
  [consistency token](consistency-tokens-and-snapshot-reads.md) lifetime — tuning it too
  aggressively invalidates tokens still in flight.
