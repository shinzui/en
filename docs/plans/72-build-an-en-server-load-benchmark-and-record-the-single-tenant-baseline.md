---
id: 72
slug: build-an-en-server-load-benchmark-and-record-the-single-tenant-baseline
title: "Build an en-server load benchmark and record the single-tenant baseline"
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
      at: 2026-11-13T00:54:04Z
      mode: "implement"
      note: "Benchmark, harness, A/B verdict, baseline script and interference preview implemented; baseline recorded for gate G0"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-13T03:42:23Z
      mode: "update"
      note: "Link the lookup-recursion fix plan 77"
---

# Build an en-server load benchmark and record the single-tenant baseline

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

En's owner will only let `en-server` serve several tenants from one process if doing so causes
no performance degradation. Today nothing can test that claim: the repository has
micro-benchmarks for the engine (`en-core/bench`) and for token encoding (`en-postgres/bench`),
but nothing that measures a running `en-server` answering HTTP requests against PostgreSQL.

After this plan, one command drives a real `en-server` process with a fixed set of workloads and
reports throughput and latency; a second command compares two `en-server` binaries and prints
`PASS` or `REGRESSION` per workload using a noise band it measures itself; a script rebuilds the
reference ("baseline") binary from a recorded commit; and a third command previews how much one
caller slows another inside a single process today. That preview, with the recorded baseline, is
what the owner uses to decide whether the tenant work proceeds at all (gate G0 in
`docs/masterplans/12-serve-several-isolated-tenants-from-one-en-server.md`).

Nothing in this plan changes the `en-server` executable or any library.


## Progress

- [x] Milestone 1: `cabal run en-server-loadbench -- run --smoke` starts PostgreSQL and
      `en-server`, runs every workload with zero request errors, and prints a result table.
      (2026-11-13: six rows, zero errors, about 28 s; `run --smoke --break-auth` exits 1 naming
      `check-cached` with `HTTP 401`; an unknown argument exits 2 with the usage text.)
- [x] Milestone 2: `en-server-loadbench ab` compares two binaries and prints a verdict; comparing
      the baseline binary with itself prints `PASS` on every workload; the baseline binary is
      rebuilt by `en-server/loadbench/build-baseline.sh` from the recorded commit.
      (2026-11-13: `build-baseline.sh 5361988` built `.dev/loadbench/en-server-baseline`; the
      self-comparison at 30-second windows printed `RESULT: PASS (6 workloads, 5 rounds)` with
      throughput noise 9.4–16.5%, above the 10% target, see Outcomes; the `EN_POOL_SIZE=1`
      candidate printed `REGRESSION` on every workload, `check-direct` throughput −86.2%. The
      fresh-build A/B was dropped by decision, see Decision Log.)
- [x] Milestone 3: `en-server-loadbench interference` reports shared-process and
      separate-process slowdown; the full baseline and the preview are recorded in this plan and
      reported to the owner for gate G0.
      (2026-11-13: both topologies reported, plus a pool-64 diagnostic; record under Outcomes and
      in `en-server/loadbench/results/`; reported to the owner, G0 decision pending.)


## Surprises & Discoveries

- Observation: `lookup` does not follow a self-recursive userset past its first level, while
  `check` does. With `relation member: user, group#member` on `group`, a space granted to an
  outer group whose member is the user's inner group is `allowed` by `POST /v1/check` but
  absent from `POST /v1/lookup` (the first fixture returned 10 spaces where 105 were
  reachable).
  Evidence: `evalRelation` in `en-core/src/En/Lookup.hs` returns an empty result for a
  `Subproblem {subject, objectType, relation}` already in `visited` unless a recursive *arrow*
  step is being skipped; the userset branch of `evalThis` re-enters `group#member` for the same
  subject, which is that subproblem. This is an engine correctness defect outside this
  initiative's scope (the MasterPlan excludes changes to `en-core`). The fixture keeps lookups to
  one level of groups and puts the two-level grants on a separate `folder` type, so the
  benchmark's expected answers do not change when the defect is fixed. The fix is planned in
  `docs/plans/77-make-lookup-follow-recursive-usersets-the-way-check-does.md`.
  Update (2026-11-13): fixed by that plan. With the first 5,000 spaces granted to the outer
  group instead, `cabal run -v0 en-server-loadbench -- run --smoke` passes with
  `lookupExpectedCount = 105` and no lookup errors. The fixture was left as it is so the
  recorded baseline's workload does not change.

- Observation: planner statistics dominate `lookup`. Right after seeding, `lookup` ran at about
  500 req/s with 4 threads; after `VACUUM ANALYZE` it ran at about 2,500 req/s with 8 threads.
  Without an explicit analyze, autovacuum decides when statistics appear, which makes rounds
  disagree (70% round-to-round spread in an early A/B smoke run).
  Evidence: smoke runs before and after adding `VACUUM ANALYZE` to every round.

- Observation: the benchmark machine saturates `check-direct` at about 13,700 req/s with 16
  client threads; 32 threads (the default) adds queueing latency, not throughput. `check-last-key`
  at 32 threads came out well below `check-direct` in one short exploratory run (8,549 vs 13,712
  req/s) but not at 8 or 16 threads; the full run below decides whether the 64-entry key scan
  costs anything measurable.
  Evidence: `run --threads 8|16|32 --warmup-seconds 1 --measure-seconds 4` against the baseline.

- Observation: inside one process a busy caller starves an idle one far beyond what a second
  process on the same machine does, and a bigger connection pool removes only part of it. With
  the default pool of 10 the victim kept 2.9% of its throughput (p99 ×32) in a shared process
  against 61% (p99 ×1.9) across two processes; with `EN_POOL_SIZE=64` it kept 5.6% (p99 ×9.2)
  against 67% (p99 ×2.0).
  Evidence: `interference` and `interference --server-env EN_POOL_SIZE=64`, Outcomes below. The
  likely remaining causes are that one process shares its capacity per in-flight request (8
  victim threads against 64 aggressor threads), where the operating system shares CPU between
  two processes roughly per process; that the runtime's garbage collection stops every thread;
  and that the request logger serializes every log line through one lock. The tenant design in
  the MasterPlan gives each tenant its own pool and caches, but not its own share of CPU, so
  gate G3 is at risk unless tenants also get an admission bound. This is the main input to G0.

- Observation: `cabal list-bin en-server` is ambiguous once the package has a second executable;
  the harness asks for `en-server:exe:en-server`.


## Decision Log

- Decision: The second Milestone 2 acceptance check (`build-baseline.sh`, then `ab` of the
  baseline against a freshly built `en-server` from the same commit) is dropped; it was started
  and stopped after 15 minutes. Default measurement windows are 30 seconds, and every `ab`,
  `run` and `interference` starts with one discarded warm-up round (`--warmup-rounds`, default
  1, 0 with `--smoke`).
  Rationale: the two binaries are built from identical sources, so the check only repeated the
  self-comparison at 45 minutes' cost; the owner agreed to cut it (see the MasterPlan's Decision
  Log, which also reduces gate G1 to two runs of 3 rounds). The first round against a freshly
  seeded database was slower for both binaries on every workload (`write` about 3,700 against
  8,400 req/s afterwards); 30-second windows with that round discarded brought the self-
  comparison's throughput noise from 11–61% to 9–17%.
  Date: 2026-11-13

- Decision: Nested-group checks run against a `folder` object type, not `space`, and the
  schema fixture gains that type.
  Rationale: `lookup` does not follow self-recursive usersets past one level (see Surprises &
  Discoveries). Keeping `lookup`'s answer to one level of groups makes its expected count (105)
  independent of that defect, while `check-nested` still resolves through two levels of
  membership.
  Date: 2026-11-13

- Decision: Every round starts with `VACUUM ANALYZE` on the database it measures, and so does
  every interference round.
  Rationale: without it, whether autovacuum has produced statistics yet decides `lookup`'s
  query plan and dominates the round-to-round noise.
  Date: 2026-11-13

- Decision: Benchmark servers run with their stdout (the per-request log) sent to `/dev/null`;
  stderr is captured. The load generator runs with `-N -A64m`.
  Rationale: the server still formats and writes every log line, as in production, but the
  load generator spends no CPU reading them; a large allocation area keeps the generator's own
  minor collections out of the measured latencies. The harness keeps capturing stdout by
  default for the tests that read log lines.
  Date: 2026-11-13

- Decision: Every benchmark server carries the same 65 keys (one read-write key first, then 64
  read-only keys); `check-last-key` presents the 64th read-only key. Profiles are measured
  cached-first, then plain, so `write` is the last workload against the database.
  Rationale: one key configuration for every workload means only `check-last-key` pays for the
  scan, and a server per profile instead of per workload keeps a round short.
  Date: 2026-11-13

- Decision: `interference` takes a `--server-env KEY=VALUE` diagnostic option applied to every
  server it starts.
  Rationale: the shared-process slowdown could be the shared connection pool or the shared
  runtime; running the preview once more with `EN_POOL_SIZE=64` separates the two for the
  owner's G0 decision without changing the default measurement.
  Date: 2026-11-13

- Decision: The benchmark spawns the `en-server` executable as a child process and talks to it
  over HTTP, rather than linking the server's modules into the benchmark.
  Rationale: The claim to test is about the shipped binary, including its runtime-system flags
  (`-threaded -with-rtsopts=-N`), Warp, the middleware chain and the connection pool. It also
  lets two differently built binaries be compared by path.
  Date: 2026-11-12

- Decision: The load generator is written in Haskell inside the repository rather than taken
  from an external tool.
  Rationale: The development shell provides `hurl` but no load generator, and the benchmark must
  orchestrate PostgreSQL, seeding and two server binaries anyway. One executable keeps the
  procedure reproducible with `cabal run`.
  Date: 2026-11-12

- Decision: The verdict rule uses a tolerance equal to the larger of a fixed floor and the
  round-to-round spread measured in the same run, and the benchmark is not added to the CI gate.
  Rationale: A fixed threshold alone either hides small regressions or fails on noise. Shared CI
  runners are too noisy for a process-level A/B; the gate is run on a quiet developer machine
  and its output is recorded in the plan that ran it.
  Date: 2026-11-12


## Outcomes & Retrospective

All three milestones are done. Every record below comes from the commit this plan lands in,
with `en-server` itself unchanged from the baseline commit.

**Baseline.** Commit `5361988d5a783f7b90216f140189ed15c3483836`, built by
`en-server/loadbench/build-baseline.sh 5361988`. Machine: Apple M5 Ultra, 36 cores (12
performance, 24 efficiency), 256 GiB, macOS 27.2; PostgreSQL 18.6 (ephemeral-pg 0.3.1.0); GHC
9.12.4. The machine was a working developer desktop (a virtual machine, a browser and editors
were running), not an idle one. Defaults: 32 client threads, 5 s warm-up, 30 s measurement, one
discarded warm-up round. `en-server/loadbench/results/baseline.json`:

```text
workload              req/s    p50_ms    p95_ms    p99_ms  errors
check-direct          11183     2.783     4.051     5.249       0
check-nested           4526     7.056     8.170     9.676       0
check-cached          17303     1.565     3.027     4.012       0
lookup                 3095     9.695    17.447    21.997       0
check-last-key        10192     3.019     4.253     5.638       0
write                  8840     3.025     7.833    11.231       0
```

At 32 threads the server is saturated (check-direct peaks at about 13,700 req/s with 16
threads), so these latencies include queueing. `check-last-key` is within noise of
`check-direct`: scanning 65 keys costs nothing this benchmark can see.

**Self-comparison** (baseline against itself, 5 rounds,
`en-server/loadbench/results/self-comparison.json`): `RESULT: PASS`; throughput and p50 medians within
±5.6% of their twins, p99 medians within ±11.3%. Noise per workload, throughput / p50 / p99:

```text
check-direct     10.5%  9.3%  25.2%
check-nested      9.4%  4.9%  55.7%
check-cached     11.5%  9.0%  18.5%
lookup           12.5% 10.1%  37.3%
check-last-key   10.9% 12.1%  23.8%
write            16.5% 12.7%  32.9%
```

This is above the 10% throughput target on four workloads. Lengthening the window from 20 to
30 seconds and discarding the first round took it from 11–61% to these figures; the remaining
spread moves whole rounds at once (one round slower on every workload), which is background
load on the machine rather than sampling error. On this machine the gates therefore resolve a
regression of roughly 10–17% in throughput and more in p99; a quieter machine is needed to
resolve less. 30 seconds is now the default.

**The rule can fail.** `ab --candidate-env EN_POOL_SIZE=1 --rounds 3 --measure-seconds 10`
(`en-server/loadbench/results/pool-size-1.json`): `REGRESSION` on all six workloads,
`check-direct` throughput 8,982 → 1,238 req/s (−86.2%).

**Interference preview** (3 rounds plus a warm-up round per topology, 30 s windows; victim
`check-direct` with 8 threads; aggressor `check-nested` and `lookup` with 32 threads each;
`en-server/loadbench/results/interference.json` and `interference-pool64.json`):

```text
pool       topology              alone_req/s  alone_p99  loaded_req/s  loaded_p99  tput_ratio  p99_ratio
10 (dflt)  shared-process              10747      2.108           311      67.529       0.029     32.035
10 (dflt)  separate-processes          10366      2.547          6339       4.959       0.612      1.947
64         shared-process              12467      1.740           699      16.001       0.056      9.196
64         separate-processes          11742      1.881          7871       3.795       0.670      2.018
```

Sharing a process today costs an idle caller twenty to thirty times more than sharing a machine
does. A per-tenant pool alone (the 64-connection row is the closest available stand-in) leaves
most of that gap. What this means for the tenant design is in Surprises & Discoveries and in the
MasterPlan's G0 report.

**Other findings.** `lookup` does not follow self-recursive usersets past one level, while
`check` does (Surprises & Discoveries); the fix is planned in
`docs/plans/77-make-lookup-follow-recursive-usersets-the-way-check-does.md` (now fixed), and the
fixture is built so the benchmark does not depend on it. Planner statistics dominate
`lookup` unless every round starts with `VACUUM ANALYZE`.

**Friction.** No friction entries were recorded under this plan; the small costs met (an
ambiguous `cabal list-bin` target, a GNU `sed` on a BSD-style command line) were below the
threshold in `agents/skills/exec-plan/FRICTION.md`.

**ADRs.** None written. The decisions here (process-level A/B against a preserved baseline,
not in CI) are task-local until EP-5's distillation decides whether they are durable.


## Context and Orientation

`en` is a relationship-based authorization toolkit written in Haskell (GHC 9.12.4, built with
`cabal`; enter the development shell with `nix develop` or `direnv allow` at the repository
root). The packages are listed in `cabal.project`. The one that matters here is `en-server`, the
standalone HTTP service:

- `en-server/en-server.cabal` declares one executable, `en-server` (sources in
  `en-server/app/`), and one test suite, `en-server-middleware-test`. There is no library; the
  test suite compiles `app/Middleware.hs` directly by listing `app` in its `hs-source-dirs`.
- `en-server/app/Main.hs` is the entry point. With no arguments it serves the HTTP API; it also
  has `import`, `export` and `check-schema` subcommands.
- `en-server/app/Config.hs` reads every setting from environment variables. The ones this plan
  uses: `EN_DATABASE_URL` (PostgreSQL connection string, required), `EN_SCHEMA_PATH` (schema
  file), `EN_API_KEYS_READ_WRITE` and `EN_API_KEYS_READ_ONLY` (comma-separated `name:secret`
  entries, each secret at least 16 bytes), `EN_PORT`, `EN_POOL_SIZE` (default 10),
  `EN_DECISION_CACHE_MAX_ENTRIES` and `EN_TUPLE_READ_CACHE_MAX_ENTRIES` (both default 0, meaning
  disabled), and `EN_MAINTENANCE_INTERVAL_SECONDS` (default 600).
- The HTTP routes are under `/v1`: `POST /v1/check`, `POST /v1/lookup`,
  `POST /v1/relationships` (write) and others. Request bodies are shown in
  `en-servant/test/hurl/checks.hurl`, `lookups.hurl` and `relationships.hurl`, and described in
  `docs/user/queries-and-writes.md`. `GET /health/ready` answers 200 without a key once the
  server can reach PostgreSQL. Every other route needs `Authorization: Bearer <secret>`.
- The schema language is described in `docs/user/modeling.md`. A minimal schema is the built-in
  demo in `en-server/app/Main.hs` (`demoSchemaSource`).
- The database schema is applied by the `en-migrations` package. Tests obtain a disposable
  PostgreSQL with the `ephemeral-pg` library and migrate it with `En.Migrations.enMigrationPlan`;
  the pattern to copy is `migrateDatabase` and the `Pg.withConfig` call in
  `en-postgres/integration-test/Main.hs`. `ephemeral-pg` also exports `start`, `stop`, `restart`
  and `connectionString`. Find its source and guides with `mori registry show shinzui/ephemeral-pg --full`
  and `mori registry docs shinzui/ephemeral-pg`; never search `/nix/store`.
- A precedent for a measurement executable with percentiles and a `--smoke` mode is
  `en-postgres/grant-generation-spike/Main.hs`.

Terms used in this plan. A **workload** is one kind of request repeated in a loop. A **closed
loop** means each of a fixed number of client threads sends its next request as soon as the
previous one returns, so throughput is whatever the server sustains. A **round** is one warm-up
followed by one timed measurement of every workload against one freshly started server. **A/B**
means measuring two binaries in alternation so that drift in the machine affects both. The
**baseline binary** is `en-server` built from the commit recorded by this plan, before any
tenant code exists. **p50, p95, p99** are latency percentiles: the sorted sample at
`ceiling (q * sampleCount)`, one-based.

Relevant ADRs: [ADR 3](../adr/0003-the-in-memory-store-is-for-tests-and-demos-only.md) says the
in-memory store is for tests and demos only, which is why this benchmark always runs against
real PostgreSQL. No other ADR bears on this plan.

This plan is the first child of
`docs/masterplans/12-serve-several-isolated-tenants-from-one-en-server.md` and has no
prerequisites. Two things it creates are consumed by the later child plans and must keep the
shapes given under Interfaces and Dependencies: the harness module and the benchmark executable.


## Plan of Work

### Milestone 1: a harness and a single-server run

Create `en-server/test-support/ServerHarness.hs`, a module with no dependency on the server's own
sources. It provides: starting and stopping an ephemeral PostgreSQL instance; creating a named
database inside an instance, applying `enMigrationPlan` to it, and returning its connection URL;
spawning an `en-server` binary with a given environment on a free TCP port, waiting up to 60
seconds for `GET /health/ready` to return 200, capturing stdout and stderr line by line, and
terminating it with `SIGTERM` on exit (failing with the captured output if it never became
ready); and running a subcommand of the binary to completion, returning its exit code and
output. The binary path comes from the `EN_SERVER_BIN` environment variable when set, otherwise
from `cabal list-bin en-server`.

Add an executable `en-server-loadbench` to `en-server/en-server.cabal` with
`hs-source-dirs: loadbench, test-support`, `-threaded` and `-with-rtsopts=-N`. Its `run`
subcommand starts PostgreSQL, creates and migrates one database, seeds it, starts the server and
measures these workloads in order:

- `check-direct`: `POST /v1/check` at `minimizeLatency` for a subject with a direct grant.
- `check-nested`: a check that resolves through two levels of group membership.
- `check-cached`: `check-direct` against a server started with both caches enabled
  (`EN_DECISION_CACHE_MAX_ENTRIES=10000`, `EN_TUPLE_READ_CACHE_MAX_ENTRIES=10000`).
- `lookup`: `POST /v1/lookup` returning about 100 objects.
- `check-last-key`: `check-direct` against a server configured with 64 read-only keys, using the
  last one. Tenants add keys, and `authenticate` in `en-server/app/Middleware.hs` scans the list
  linearly, so this workload exposes any cost of a longer scan.
- `write`: `POST /v1/relationships` writing one new tuple per request. It runs last because it
  grows the database.

Put the schema in `en-server/loadbench/fixtures/bench.en` (object types `user`, `group` with a
`member` relation, and `space` with a `viewer` relation that accepts users and group members,
and a `view` permission). Seed with the server's own `import` subcommand from a generated
newline-delimited JSON file: 10,000 spaces, 1,000 users, 100 groups, sized so `lookup` returns
about 100 objects. Disable background maintenance during measurement
(`EN_MAINTENANCE_INTERVAL_SECONDS=0`) so a maintenance pass cannot land inside one round.

Defaults: 32 client threads, 5 seconds of warm-up and 20 seconds of measurement per workload.
`--smoke` uses 4 threads, 1 second and 3 seconds. Time requests on the monotonic clock
(`GHC.Clock.getMonotonicTimeNSec`). Any non-2xx response or transport error makes the round
invalid and the command exit non-zero. Print one table row per workload with requests per
second, p50, p95, p99 and error count, and write the same data to a JSON file given by `--json`.
Reject unknown arguments.

Acceptance: the smoke run exits 0 and prints six rows with zero errors.

### Milestone 2: A/B comparison and the baseline binary

Add `en-server/loadbench/build-baseline.sh <commit>`. It checks the commit out into a temporary
git worktree under `.dev/loadbench/`, builds `en-server` there, copies the binary to
`.dev/loadbench/en-server-baseline`, writes the commit hash to `.dev/loadbench/baseline.sha`, and
removes the worktree. Ensure `.dev/` is ignored by git (add it to `.gitignore` if it is not).

Add the `ab` subcommand: `en-server-loadbench ab --baseline PATH --candidate PATH [--rounds N]`
(default 5 rounds). It uses one PostgreSQL instance with one identically seeded database per
binary, never runs the two servers at the same time, and alternates them in the order
baseline, candidate, candidate, baseline, and so on, so slow drift cancels.

The verdict rule is part of this plan's interface and the later plans quote it. For each workload
and each of three metrics (throughput, p50, p99), take the median over rounds for each binary.
The **noise** of a metric is the larger, over the two binaries, of `(max - min) / median` across
that binary's rounds. The **tolerance** is the larger of the noise and a floor: 3% for
throughput and p50, 10% for p99. The workload is a `REGRESSION` if the candidate's median
throughput is below the baseline's by more than the tolerance, or its median p50 or p99 is above
the baseline's by more than the tolerance; otherwise it is a `PASS`. The command prints both
medians, the relative difference, the noise and the verdict for every workload, exits 0 only if
every workload passes, and writes the full per-round data to `--json`.

Validate the instrument by comparing the baseline binary with itself. That run must print `PASS`
everywhere, and its noise should be below 10% for throughput. If it is not, the machine is too
busy or the rounds are too short; lengthen `--measure-seconds` until it is, and record the
setting that worked as the default for the gates.

Add `Justfile` recipes `loadbench-smoke` and `loadbench-ab baseline candidate`.

Acceptance: the self-comparison passes; `build-baseline.sh` followed by `ab` against a freshly
built `en-server` from the same commit passes.

### Milestone 3: the interference preview and the report

Add the `interference` subcommand. It measures one "victim" caller running `check-direct` with 8
client threads in two conditions, alone and while an "aggressor" caller runs `check-nested` and
`lookup` with 64 client threads, in two topologies:

- **shared process**: one baseline server, both callers using different API keys against the
  same database. This is the closest thing today's server has to two tenants in one process.
- **separate processes**: two baseline servers on the same machine, each with its own database,
  the victim on one and the aggressor on the other. This is what running a second En costs.

For each topology report the victim's throughput and p99 alone and under load, and the ratio
between them. The interesting figure is how much worse the shared-process ratio is than the
separate-process ratio. With tenants, each tenant gets its own connection pool and caches, so
the tenant design should do no worse than the shared-process figure and is required by gate G3
to match the separate-process figure within tolerance.

Then run the full default `run` against the baseline binary and record, in this plan's Outcomes
& Retrospective: the baseline commit hash, the machine (CPU model, core count, memory, operating
system), the PostgreSQL and GHC versions, the result table, the self-comparison noise per
workload, and the interference table. Check the JSON files in under
`en-server/loadbench/results/`. Report the same summary to the owner; the owner's decision is
gate G0 in the MasterPlan, and the next child plan does not start without it.

Acceptance: the `interference` command exits 0 with both topologies reported, and the record
described above exists in this plan and in `en-server/loadbench/results/`.


## Concrete Steps

All commands run from the repository root inside the development shell.

```bash
cabal build en-server en-server-loadbench
cabal run -v0 en-server-loadbench -- run --smoke
```

Expected shape of the output (numbers will differ):

```text
workload         req/s     p50_ms   p95_ms   p99_ms   errors
check-direct     5210      0.71     1.42     2.10     0
check-nested     3105      1.20     2.31     3.95     0
check-cached     9120      0.39     0.80     1.31     0
lookup           410       9.40     15.2     21.7     0
check-last-key   5150      0.72     1.45     2.15     0
write            1480      2.60     4.90     7.80     0
```

Build the baseline and validate the instrument:

```bash
en-server/loadbench/build-baseline.sh "$(git rev-parse HEAD)"
cabal run -v0 en-server-loadbench -- ab \
  --baseline .dev/loadbench/en-server-baseline \
  --candidate .dev/loadbench/en-server-baseline \
  --json .dev/loadbench/self.json
```

```text
workload       metric      baseline   candidate   delta    noise   tolerance   verdict
check-direct   req/s       5210       5188        -0.4%    2.1%    3.0%        PASS
check-direct   p99_ms      2.10       2.14        +1.9%    6.0%    10.0%       PASS
…
RESULT: PASS (6 workloads, 5 rounds)
```

Run the preview and the full baseline:

```bash
cabal run -v0 en-server-loadbench -- interference \
  --server .dev/loadbench/en-server-baseline --json en-server/loadbench/results/interference.json
cabal run -v0 en-server-loadbench -- run \
  --server .dev/loadbench/en-server-baseline --json en-server/loadbench/results/baseline.json
```

Format and check before committing:

```bash
treefmt
cabal build all
cabal test en-server-middleware-test
```

Commit with the trailers this initiative requires:

```text
MasterPlan: docs/masterplans/12-serve-several-isolated-tenants-from-one-en-server.md
ExecPlan: docs/plans/72-build-an-en-server-load-benchmark-and-record-the-single-tenant-baseline.md
Intention: intention_01m7910hcdejsv2zfwyrxptjkb
```


## Validation and Acceptance

The plan is accepted when all of the following hold on a quiet machine:

`cabal run -v0 en-server-loadbench -- run --smoke` exits 0 and reports zero errors on six
workloads. Deliberately breaking a request (for example pointing the benchmark at a wrong API
key with a hidden `--break-auth` test flag, or by temporarily editing a request path) makes the
command exit non-zero and name the workload, which shows that errors are not silently counted as
successes.

The self-comparison prints `RESULT: PASS`. To show the verdict rule can fail, run `ab` once with
the candidate server started with `EN_POOL_SIZE=1` (expose this as `--candidate-env KEY=VALUE`);
the `check-direct` throughput verdict must be `REGRESSION`.

`interference` reports both topologies, and the record described in Milestone 3 is present.

The existing suites are unaffected: `cabal build all` succeeds without warnings and
`cabal test en-server-middleware-test` passes.


## Idempotence and Recovery

Every command creates its own temporary PostgreSQL instance and removes it on exit, so runs do
not interfere and can be repeated freely. If a run is interrupted, a server or PostgreSQL child
process may be left behind; `ephemeral-pg` documents stale-instance cleanup in its guides (see
`mori registry docs shinzui/ephemeral-pg`), and a stray `en-server` can be found with
`pgrep -fl en-server`. `build-baseline.sh` is safe to re-run: it replaces the binary and the
recorded hash and removes its worktree even when the build fails. Nothing in this plan touches a
developer's own database or the `process-compose` services.


## Interfaces and Dependencies

Libraries: `ephemeral-pg` (pinned in `cabal.project`), `en-migrations` for `enMigrationPlan`,
the migration runner already used by `en-postgres`'s integration tests (copy its dependency
line from the `en-postgres-integration-tests` stanza of `en-postgres/en-postgres.cabal`),
`http-client`, `async`, `process`, `network`, `aeson`. Check current released versions with
`mori registry show` before adding bounds.

`en-server/test-support/ServerHarness.hs` must export, with these meanings (exact names may
follow the repository's conventions, but later plans rely on each capability):

```haskell
-- Where the server binary comes from: EN_SERVER_BIN, else `cabal list-bin en-server`.
locateServerBinary :: IO FilePath

-- An ephemeral PostgreSQL instance whose lifetime the caller controls.
startPostgres :: IO PostgresInstance
stopPostgres :: PostgresInstance -> IO ()
restartPostgres :: PostgresInstance -> IO PostgresInstance

-- Create a database by name in the instance, apply enMigrationPlan, return its URL.
createMigratedDatabase :: PostgresInstance -> Text -> IO Text

-- The same without migrations, and the migration step on its own, for fault tests.
createEmptyDatabase :: PostgresInstance -> Text -> IO Text
migrateDatabaseUrl :: Text -> IO ()

data ServerSpec = ServerSpec
  { binary :: FilePath,
    environment :: [(String, String)],  -- complete environment; EN_PORT is added by the harness
    waitForReady :: Bool
  }

data RunningServer -- baseUrl :: Text, and an action returning the lines printed so far

withServer :: ServerSpec -> (RunningServer -> IO a) -> IO a

-- Run `en-server <args>` to completion: exit code, stdout, stderr.
runServerCommand :: ServerSpec -> [String] -> IO (ExitCode, Text, Text)
```

As implemented (2026-11-13), the module also exports: `withPostgres` (bracketed start and
stop), `postgresDatabase` (the underlying ephemeral-pg handle), `runDatabaseScript url sql`
(one script on its own connection, outside a transaction, so `VACUUM` works),
`baseEnvironment` (the parent's `PATH`, `HOME`, `LANG`, `LC_ALL` and `TMPDIR`, which a child
needs to behave like a shell-launched process), `serverSpec binary env` (a spec that waits for
readiness and captures output), and `baseUrl`, `serverPort` and `capturedLines` on a
`RunningServer`. `ServerSpec` has a fourth field, `captureStdout :: Bool`; the benchmark sets it
to `False` because the request log writes one line per request, and stderr is always captured.
`capturedLines` returns stdout and stderr interleaved in arrival order, stderr lines prefixed
with `stderr: `, keeping the most recent 20,000. `stopPostgres` removes the data directory;
`restartPostgres` keeps it. A fault test that needs PostgreSQL *down for a while* (rather than
restarted at once) will need a new primitive, because ephemeral-pg's `stop` also cleans up.

`en-server-loadbench` must provide the subcommands `run`, `ab` and `interference`, the options
`--server`, `--baseline`, `--candidate`, `--candidate-env`, `--rounds`, `--measure-seconds`,
`--smoke` and `--json`, and the verdict rule stated in Milestone 2. The last child plan,
`docs/plans/76-prove-tenant-isolation-and-performance-then-document-tenant-operations.md`, adds
tenant scenarios to this executable, so keep workload definitions and the measurement loop in
their own module (`en-server/loadbench/Workload.hs`) rather than inline in `Main.hs`.
