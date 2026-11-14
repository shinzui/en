---
title: "A partially available en-server stays ready"
status: accepted
date: 2026-11-13
authors: [shinzui]
related:
  - docs/masterplans/12-serve-several-isolated-tenants-from-one-en-server.md
  - docs/plans/74-give-each-tenant-an-independent-lifecycle-and-contain-its-storage-faults.md
  - docs/plans/75-carry-the-tenant-through-logs-metrics-traces-and-readiness.md
  - docs/improvement-requests/serve-several-isolated-tenants-from-one-en-server.md
  - docs/adr/0004-en-s-health-probe-surface-is-owned-by-servant-health.md
  - docs/adr/0009-tenancy-is-a-property-of-the-standalone-host.md
  - mori://shinzui/servant-health
---

# ADR 10 — A partially available en-server stays ready

## Status

Accepted, 2026-11-13. Implemented by
[ExecPlan 74](../plans/74-give-each-tenant-an-independent-lifecycle-and-contain-its-storage-faults.md)
(readiness) and
[ExecPlan 75](../plans/75-carry-the-tenant-through-logs-metrics-traces-and-readiness.md)
(reporting). The owner confirmed this wording on 2026-11-13, as the deliberate difference
from IR-2 AC-6's "the readiness probe names a tenant whose storage is unavailable".

## Context

A server started with `EN_TENANTS` serves several tenants, each from its own PostgreSQL
database ([ADR 9](0009-tenancy-is-a-property-of-the-standalone-host.md)). One tenant's
database can be down while the others are healthy. IR-2 requires that such a fault never makes
another tenant unavailable (AC-5), and that readiness report each tenant's state (AC-6).

Readiness is a property of the whole process: Kubernetes withdraws a pod whose readiness fails,
for every tenant at once. The probe's wire type belongs to `mori://shinzui/servant-health`
([ADR 4](0004-en-s-health-probe-surface-is-owned-by-servant-health.md)). Its verdict is
`Healthy | Unhealthy name since`, so a passing response cannot name a degraded check.

## Decision

- `GET /health/ready` answers 200 while at least one tenant can serve, and 503 only when none
  can. The 503 names the first tenant's failing check, `postgres:<tenant>`. Liveness does not
  depend on any database.
- Which tenants can serve is reported outside the probe, by two channels an operator already
  scrapes and reads:
  - the gauge `en_tenant_available{tenant="<name>"}`, 1 or 0, on `GET /metrics`. A tenant's key
    sees its own tenant's sample; an `EN_METRICS_KEYS` operator key sees every tenant's.
  - one log line per change, `[tenant <name>] UNAVAILABLE: <reason>` and
    `[tenant <name>] AVAILABLE`, whether the tenant could not open its store (at startup or
    while retrying) or its open store stopped answering the readiness ping.
- A tenant can serve when its store is open and its last readiness ping passed. The gauge is
  read from that state at scrape time; a scrape never pings a database.
- Legacy mode (no `EN_TENANTS`) is unchanged: its one database decides readiness, and it has no
  `en_tenant_available` family.

## Consequences

- A single tenant's outage never withdraws the pod, so the healthy tenants keep serving through
  it. In exchange, a rollout cannot be gated on one tenant's storage: a new pod whose only
  reachable tenant is one of several becomes ready.
- Operators alert on `en_tenant_available == 0` (per tenant), not on readiness. Readiness
  failing means every tenant is down.
- An outage of an open store is noticed when readiness next pings it, so the gauge and the log
  line lag an outage by up to one probe period. A deployment that does not probe readiness sees
  only the open-store transitions (startup and recovery) and the tenant's 503s.
- IR-2 AC-6's verification asks that "the readiness probe names a tenant whose storage is
  unavailable". The probe does so only when no tenant can serve; otherwise the gauge and the log
  name it. A "degraded but passing" verdict in `mori://shinzui/servant-health` would let a 200
  name a degraded tenant; it is a possible follow-up there, not a requirement of En.
