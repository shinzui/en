---
title: "Request-path changes are judged by an A/B against a preserved baseline binary"
status: accepted
date: 2026-11-13
authors: [shinzui]
related:
  - docs/masterplans/12-serve-several-isolated-tenants-from-one-en-server.md
  - docs/plans/72-build-an-en-server-load-benchmark-and-record-the-single-tenant-baseline.md
  - docs/plans/76-prove-tenant-isolation-and-performance-then-document-tenant-operations.md
  - docs/adr/0009-tenancy-is-a-property-of-the-standalone-host.md
---

# ADR 11 — Request-path changes are judged by an A/B against a preserved baseline binary

## Status

Accepted, 2026-11-13. The instrument was built by
[ExecPlan 72](../plans/72-build-an-en-server-load-benchmark-and-record-the-single-tenant-baseline.md)
and used for the gates of
[MasterPlan 12](../masterplans/12-serve-several-isolated-tenants-from-one-en-server.md).

## Context

The owner accepted multi-tenancy only on the condition that single-tenant use pays no
performance tax. "No slower" is not checkable by reading code, and absolute throughput on a
development desktop drifts by more than the effects being judged: plan 72 measured
round-to-round throughput noise of 9–17% on the same binary. A claim of no regression needs a
fixed reference, the same machine, paired measurement, and a rule written down before the
run. It must also not depend on the machine being idle: a development desktop is shared with
builds, virtual machines and other sessions, and MasterPlan 12's first tenant-mode gate run
failed on that alone (load average about 20, `schema-read` -7.4% against a 7.0% tolerance,
while the same binary compared with itself across modes showed no cost).

## Decision

A change that can affect `en-server`'s request path (middleware, authentication, routing,
logging, metrics, the handlers' wiring) is judged by `en-server-loadbench ab`:

- **A preserved baseline binary.** `.dev/loadbench/en-server-baseline`, built by
  `en-server/loadbench/build-baseline.sh <commit>` from a recorded commit (for MasterPlan 12,
  `09a7d6b`, the last commit before tenant code). The baseline is rebased only by a recorded
  decision, never to make a run pass.
- **Paired, simultaneous rounds.** Baseline and candidate run at the same time, each against its
  own identically seeded database, and every workload drives both servers over the same
  wall-clock window. Load from outside the benchmark falls on both servers of a pair and
  cancels in their ratio. The databases swap between the binaries every round, and one
  discarded warm-up round precedes the measured ones. Three measured rounds is the standard for
  a gate.
- **A fixed core budget.** Each server runs with `GHCRTS=-N4` (`--server-cores`). Unlimited, the
  two servers and the load generator each claimed every core, and GHC's parallel collector
  stalls whenever one of its threads is descheduled, which turned background load into
  throughput swings of up to 28%.
- **Seven workloads**, including `schema-read` (`GET /v1/schema`, answered from memory), which
  isolates the HTTP and middleware path that database-bound workloads cannot resolve.
- **The verdict rule** in `en-server/loadbench/Verdict.hs` (`pairedVerdictFor`): per workload,
  take each round's candidate/baseline throughput ratio; the tolerance is the larger of the
  ratios' spread, `(max - min) / median`, and 3%; a median ratio below `1 - tolerance` is a
  `REGRESSION`. Latency is printed as information only, because at
  saturation p50 restates throughput.
- **Tenant mode is judged the same way.** `--candidate-tenants N` runs the candidate in tenant
  mode, the measured database as one tenant with the baseline's settings beside `N - 1` idle
  tenants, and refuses to measure a server that is not in that mode.
- **An instrument change is validated both ways** before a long run is trusted: the baseline
  against itself passes, and a deliberately crippled candidate (`EN_POOL_SIZE=1`) fails.
- The earlier design, one binary after the other with nothing limited, remains as
  `ab --sequential` for comparison with results recorded before this decision.

Smaller changes that do not touch the request path run `just loadbench-smoke` as a functional
check.

## Consequences

- A gate does not need an idle machine; it needs only enough free cores for two four-core
  servers and the load generator.
- The figures measure en-server on four cores, not on the whole machine. That is closer to a
  production pod than the earlier unlimited figures, and the gate judges a ratio, not an
  absolute rate.
- A full gate takes about 20 minutes, half the sequential design's time, because both
  binaries are measured at once.
- `schema-read` cannot show a difference in the paired design. Both servers settle at the same
  rate (about 4 ms per request per connection) whether they have one, two or four cores, and
  the same server alone is two to three times faster; the shared limit was not found, and it
  is neither PostgreSQL (the route reads memory), the load generator's core count, nor
  loopback bandwidth (the body is 238 bytes). Until it is found, `schema-read` is judged by the
  sequential design, and a paired run's `schema-read` line is not evidence. The other six
  workloads were validated: a half-core candidate fails them by 35-45% and `EN_POOL_SIZE=1`
  fails the five database workloads (and `write`) by 58-82%, with noise under 5% at a load
  average of 20.
- The cost of in-process interference between tenants is measured by a different command,
  `interference`, and reported rather than gated (MasterPlan 12, gate G3).
