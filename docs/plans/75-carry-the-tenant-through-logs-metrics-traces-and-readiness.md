---
id: 75
slug: carry-the-tenant-through-logs-metrics-traces-and-readiness
title: "Carry the tenant through logs, metrics, traces and readiness"
kind: exec-plan
created_at: 2026-11-12T23:20:49Z
intention: "intention_01m7910hcdejsv2zfwyrxptjkb"
master_plan: "docs/masterplans/12-serve-several-isolated-tenants-from-one-en-server.md"
provenance:
  created_by:
    model: "claude-fable-5-2"
    harness: "claude-code"
    at: 2026-11-12T23:20:49Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-13T02:19:34Z
      mode: "update"
      note: "Gate G1 reduced to EP-2 M1 and EP-5 with 3 rounds; smoke benchmark elsewhere; list-bin target fixed"
---

# Carry the tenant through logs, metrics, traces and readiness

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

When one `en-server` process serves several tenants (independent authorization owners, each
with its own schema, database and API keys, selected by the caller's key), an operator must be
able to tell which tenant a request, a metric or an outage belongs to, and one tenant must not
be able to observe another through those same channels.

After this plan, in a server started with `EN_TENANTS`: every request log line carries the
tenant and the caller name; every metric series carries a `tenant` label; `GET /metrics` with a
tenant's key shows only that tenant's series, while an operator's dedicated scrape key shows all
tenants; each server trace span carries the tenant; and the availability of every tenant is
visible as a metric and in the log, with `/health/ready` naming a tenant when none can serve. A
server started without `EN_TENANTS` produces exactly the log lines and metrics it does today.

This completes acceptance criterion AC-6 of
[IR-2](../improvement-requests/serve-several-isolated-tenants-from-one-en-server.md): "the caller
identity propagated to logs, metrics and rate limiting carries the tenant, and readiness reports
each tenant's state".


## Progress

- [ ] Milestone 1: in tenant mode the request log line has `tenant` and `caller` fields and the
      server span has an `en.tenant` attribute; legacy-mode log lines are unchanged.
- [ ] Milestone 2: metric series carry a `tenant` label; a tenant key scrapes only its own
      tenant; an `EN_METRICS_KEYS` key scrapes all tenants and nothing else; legacy-mode
      `/metrics` output is unchanged.
- [ ] Milestone 3: per-tenant availability is reported by an `en_tenant_available` metric and by
      log lines on every change; the readiness behaviour is covered by tests and recorded in an
      ADR; `just loadbench-smoke` exits 0.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: A tenant's key sees only that tenant's metrics. A process-wide view needs a separate
  operator scrape key, `EN_METRICS_KEYS`, which authorizes `GET /metrics` and no other route.
  Rationale: Request counts and cache statistics of another tenant are information about that
  tenant. Operators still need one scrape target, and a key that can do nothing but scrape adds
  no authority over any tenant's data.
  Date: 2026-11-12

- Decision: Legacy mode's request log and metrics output do not change at all, not even by
  adding the `caller` field.
  Rationale: IR-2 AC-1 requires a server without tenant configuration to behave exactly as
  today, and an unchanged request path keeps the performance gate trivially satisfied.
  Date: 2026-11-12

- Decision: When some tenants are unavailable and at least one is healthy, `/health/ready`
  answers 200 with the ordinary healthy body, and the unavailable tenants are named by the
  `en_tenant_available` metric and by log lines. `/health/ready` names a tenant only when it
  answers 503, which happens when no tenant can serve.
  Rationale: Readiness withdraws the whole pod, so failing it for one tenant would take down the
  healthy ones (IR-2 AC-5 forbids that). The `servant-health` library owns the probe wire type
  ([ADR 4](../adr/0004-en-s-health-probe-surface-is-owned-by-servant-health.md)) and its passing
  verdict carries no check name, so a 200 cannot name a degraded tenant. IR-2 AC-6's verification
  says "the readiness probe names a tenant whose storage is unavailable"; this plan satisfies it
  in the total-outage case and through the metric otherwise, and records the difference for the
  owner. A "degraded but passing" verdict in `mori://shinzui/servant-health` would close the gap
  and is noted as a possible follow-up, not a requirement of this plan.
  Date: 2026-11-12


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

`en` is a relationship-based authorization toolkit in Haskell (GHC 9.12.4, `cabal`; enter the
development shell with `nix develop` or `direnv allow`). `en-server` is its standalone HTTP
service. This plan changes only the `en-server` package.

This is a child of `docs/masterplans/12-serve-several-isolated-tenants-from-one-en-server.md`.
Two earlier children must be Complete first:
`docs/plans/73-serve-tenants-selected-by-api-key-each-from-its-own-isolated-stack.md` and
`docs/plans/74-give-each-tenant-an-independent-lifecycle-and-contain-its-storage-faults.md`. What
they left in place:

- Tenants are declared with `EN_TENANTS` and `EN_TENANT_<NAME>_…` variables, parsed in
  `en-server/app/Config.hs`, which rejects unrecognized tenant variables. Without `EN_TENANTS`
  the server is in **legacy mode**.
- `en-server/app/Tenant.hs` defines the **tenant stack** (one per tenant: connection pool,
  schema, caches, rate limiter, metrics registry, and the tenant's inner HTTP application) and
  the **tenant slot** that wraps it with an availability state: available, or unavailable with a
  reason. A slot's application answers 503 `store_error` while unavailable. A function there
  returns each tenant's name and current health. Legacy mode has one stack, no slot and no
  tenant name.
- `en-server/app/Middleware.hs` authenticates the bearer key, answers 401 or 403 itself, sets
  the `X-En-Caller` header to the key's name, and in tenant mode calls the application paired
  with the key. Each tenant has its own rate-limit buckets.
- Each tenant's inner chain is, outermost first: rate limiter, request id, request logger,
  metrics recorder, metrics route, then the servant application. Process-wide middleware
  outside authentication is OpenTelemetry and Servant route telemetry.
- `/health/ready` in tenant mode is healthy when at least one tenant is healthy and otherwise
  returns `Unhealthy` named `postgres:<tenant>`.
- The suite `en-server-tenant-tests` (`en-server/test/TenantSpec.hs`) runs a two-tenant server
  (alpha and beta, one ephemeral PostgreSQL instance each) through the harness
  `en-server/test-support/ServerHarness.hs`, which can stop a PostgreSQL instance and return the
  lines the server printed.
- `en-server-loadbench ab` compares the baseline binary `.dev/loadbench/en-server-baseline` with
  a candidate and ends with `RESULT: PASS` or names regressions; see
  `docs/plans/72-build-an-en-server-load-benchmark-and-record-the-single-tenant-baseline.md`.

The observability code this plan edits:

- `en-server/app/Observability.hs`. `newRequestLogger` returns a middleware that writes one JSON
  object per request to stdout (`time`, `method`, `path`, `status`, `duration_ms`, `user_agent`,
  and `trace_id` and `span_id` when a valid server span exists). It holds one lock so concurrent
  lines do not interleave, and it skips the probe paths. It does not log the caller today.
  `correlationFields` shows how to reach the request's span with `requestContext` and
  `OTel.Context.lookupSpan`.
- `en-server/app/Metrics.hs`. `Metrics` is a registry of request counters keyed by path group
  and status class. `metricsMiddleware` records into it; `metricsRoute` serves `GET /metrics` in
  the Prometheus text format, adding cache statistics read at scrape time. The `family` helper
  writes one `# HELP`/`# TYPE` header followed by all samples of a metric family, which the
  format requires to be contiguous. `/metrics` requires a key like any other route.
- Telemetry providers are process-wide and owned by `en-server`, per
  [ADR 5](../adr/0005-telemetry-configuration-and-provider-lifetimes-belong-to-the-standalone-host.md);
  tenants share them.

The Prometheus text format in one sentence: each line is `name{label="value",…} number`, and all
lines of one metric name must appear together under one header. A **gauge** is a metric whose
value can go up and down; the existing families are all counters.


## Plan of Work

### Milestone 1: logs and traces

Change `newRequestLogger` in `en-server/app/Observability.hs` so the lock is still created once
but the middleware can be specialized per tenant: it returns a function from an optional tenant
name to a middleware. With a tenant name, the line gains `"tenant"` and `"caller"` fields, the
caller read from the `X-En-Caller` header that authentication set. With no tenant name (legacy
mode) the line is byte-for-byte what it is today. In the same per-tenant position, add the
attribute `en.tenant` to the request's server span when one exists; do nothing when telemetry is
disabled. Use the span attribute function of `hs-opentelemetry-api` (find its source with
`mori registry show`; do not guess the name).

Requests refused by authentication (401, 403) never reach the logger today and still do not.

### Milestone 2: metrics

Give the registry's renderer an optional tenant name. In tenant mode every sample of
`en_http_requests_total`, `en_http_request_duration_seconds_sum`,
`en_http_request_duration_seconds_count` and the four `en_cache_*_total` families carries
`tenant="<name>"` in addition to its existing labels. Tenant names match `[a-z][a-z0-9-]{0,30}`,
so they need no escaping. In legacy mode the output is unchanged.

Move the metrics recorder and the metrics route so they sit on the tenant slot, outside the
availability switch, so that an unavailable tenant's `GET /metrics` still answers and its 503
responses are counted.

`GET /metrics` with a tenant's key renders only that tenant's registry and caches. Add the
process-wide variable `EN_METRICS_KEYS`, a comma-separated list of `name:secret` entries with the
same format and 16-byte minimum as the other key lists. It is accepted only in tenant mode; its
secrets must differ from every tenant key; add it to the recognized variables. In
`en-server/app/Middleware.hs`, a request authenticated by one of these keys may call
`GET /metrics` and nothing else; any other route answers 403 with the existing
permission-denied problem. Its response renders every tenant: each family is declared once and
followed by all tenants' samples, which means the all-tenant renderer merges registries per
family rather than concatenating per-tenant documents.

### Milestone 3: availability reporting and readiness

Add the gauge family `en_tenant_available{tenant="<name>"}` with value 1 when the tenant is
healthy and 0 otherwise, computed at scrape time from the health function in
`en-server/app/Tenant.hs`. A tenant key sees its own tenant's sample; an operator key sees all.
Declare it with `# TYPE … gauge`; the `family` helper currently hard-codes `counter`, so give it
the type as a parameter.

Make sure every availability change is logged once: plan 74 already logs
`[tenant <name>] UNAVAILABLE: <reason>` and `[tenant <name>] AVAILABLE` for initialization. Add
a log line when a previously healthy tenant starts failing its ping and when it recovers, driven
by the per-tenant failure trackers of the readiness check, so an outage that begins after
startup also leaves a named trace in the log.

Write the ADR `docs/adr/NNNN-a-partially-available-en-server-stays-ready.md`, using the next
unused number in `docs/adr/` and the format of the existing records (front matter `title`,
`status`, `date`, `authors`, `related`; sections Status, Context, Decision, Consequences). It
records the readiness decision from this plan's Decision Log, the consequence that a rollout
cannot be gated on one tenant's storage, and that operators alert on `en_tenant_available`.

Add the cases under Validation and run `just loadbench-smoke` (gate G1 itself is run only by
EP-2 Milestone 1 and EP-5; see the MasterPlan).


## Concrete Steps

All commands run from the repository root inside the development shell.

```bash
cabal build all
cabal test en-server-config-tests
cabal test en-server-middleware-test
cabal test en-server-tenant-tests
```

A tenant-mode request log line:

```json
{"time":"2026-11-20T10:00:00Z","method":"POST","path":"/v1/check","status":200,"duration_ms":0.82,"user_agent":"curl/8.7.1","tenant":"alpha","caller":"alpha-writer"}
```

An operator scrape with alpha's database stopped:

```bash
curl -s localhost:8080/metrics -H 'Authorization: Bearer ops-scrape-secret-0123456789'
```

```text
# HELP en_http_requests_total Total HTTP requests handled, by path group and status class.
# TYPE en_http_requests_total counter
en_http_requests_total{path="check",status="5xx",tenant="alpha"} 3
en_http_requests_total{path="check",status="2xx",tenant="beta"} 12
…
# HELP en_tenant_available Whether the tenant's storage is serving (1) or not (0).
# TYPE en_tenant_available gauge
en_tenant_available{tenant="alpha"} 0
en_tenant_available{tenant="beta"} 1
```

The smoke benchmark:

```bash
just loadbench-smoke
treefmt
```

Every commit carries these trailers:

```text
MasterPlan: docs/masterplans/12-serve-several-isolated-tenants-from-one-en-server.md
ExecPlan: docs/plans/75-carry-the-tenant-through-logs-metrics-traces-and-readiness.md
Intention: intention_01m7910hcdejsv2zfwyrxptjkb
```


## Validation and Acceptance

`cabal test en-server-tenant-tests` passes these added cases against one process serving alpha
and beta:

- A check with alpha's key produces exactly one log line whose `tenant` is `alpha` and whose
  `caller` is the key's name; a check with beta's key produces one with `tenant` `beta`. A
  client-supplied `X-En-Caller` header does not change the logged caller.
- `GET /metrics` with alpha's key contains series with `tenant="alpha"` and no line containing
  `tenant="beta"`; after calling only beta, alpha's scrape is unchanged apart from its own
  `metrics` path counter.
- `GET /metrics` with the operator key contains both tenants' series, each family header
  appearing once. The operator key is answered 403 on `POST /v1/check` and on
  `POST /v1/relationships`.
- With alpha's PostgreSQL stopped: the operator scrape shows `en_tenant_available{tenant="alpha"} 0`
  and `…{tenant="beta"} 1`; alpha's own scrape still answers and shows its own gauge at 0; the
  log contains a line naming alpha as unavailable; `GET /health/ready` answers 200. With both
  stopped, `GET /health/ready` answers 503 and its body's `check` is `postgres:alpha`.
- Legacy mode: a server without `EN_TENANTS` logs a line with exactly today's fields (no
  `tenant`, no `caller`), and its `/metrics` output has no `tenant` label and no
  `en_tenant_available` family. Assert this by comparing field sets, not just by absence of one
  field.

`cabal test en-server-config-tests` covers `EN_METRICS_KEYS`: accepted in tenant mode, rejected
in legacy mode, rejected when a secret collides with a tenant key or is too short.

The tracing attribute is verified by a unit-level case that builds a request carrying a span and
asserts the attribute is set, or, if the SDK makes that impractical in a test, by running with
`EN_TELEMETRY_ENABLED=true` against a local collector and recording the observed span in this
plan's Surprises & Discoveries.

The A/B command ends with `RESULT: PASS`; paste the verdict table into Progress.


## Idempotence and Recovery

The changes are additive in tenant mode and absent in legacy mode, so they can be committed
milestone by milestone and each reverted alone. Tests own their PostgreSQL instances and can be
re-run. If the smoke benchmark, or later gate G1, regresses, look for work added to the legacy request path: legacy mode must
call the logger and metrics code with no tenant name and take no new branch per request beyond
that.


## Interfaces and Dependencies

No new library; the span attribute comes from `hs-opentelemetry-api`, already a dependency of
`en-server`. `en-server/app/Observability.hs` changes `newRequestLogger` to yield a per-tenant
middleware; `en-server/app/Metrics.hs` gains tenant-labelled rendering, an all-tenant renderer
and gauge support; `en-server/app/Config.hs` gains `EN_METRICS_KEYS`; `en-server/app/Middleware.hs`
gains the scrape-only key class. The final child plan,
`docs/plans/76-prove-tenant-isolation-and-performance-then-document-tenant-operations.md`,
documents the log fields, the labels, the scrape key and the readiness behaviour, and needs no
further code from this plan.
