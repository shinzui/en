---
id: 11
slug: bring-en-into-conformance-with-the-haskell-jitsurei-pattern-catalog
title: "Bring en into conformance with the haskell-jitsurei pattern catalog"
kind: master-plan
created_at: 2026-08-25T20:39:24Z
intention: "intention_01m0xaavwqeznrgzs3j67m0q21"
---

# Bring en into conformance with the haskell-jitsurei pattern catalog

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

`en` is a Haskell implementation of relationship-based authorization in the style of
Google Zanzibar: it stores relationship *tuples* (facts like "user:alice is `viewer` of
space:project-x") and answers questions about them over HTTP — `check`, `lookup`,
`expand`, a `watch` changelog, a grant-minting endpoint, and the writes that create and
delete tuples. It is one service in a fleet of Haskell services that share a written set
of conventions.

Those conventions are recorded in a separate repository, the fleet's **Haskell pattern
catalog**, whose canonical Mori project handle is `mori://shinzui/haskell-jitsurei`. A
"pattern catalog" here means exactly that: a set of prescriptive documents, each owning
one concern, that every service in the fleet is expected to satisfy. `en` currently
satisfies two of them and diverges from six, in ways that range from a missing cabal
stanza to an entire absent subsystem.

After this initiative, an operator or a client integrating with `en` gets these
concretely observable things that they cannot get today:

- **One error decoder for the whole fleet.** Every failure `en` returns is an RFC 9457
  problem document under `application/problem+json`, not the bespoke
  `{code, message, retryable}` object under `application/json` it invented for itself.
- **Probes an orchestrator can actually rely on.** `GET /health/live` and
  `GET /health/ready` at the fleet-standard paths, served from the released
  `servant-health` package, with a typed probe body naming the failing check and when it
  started failing — rather than `en`'s hand-written `/healthz` and `/readyz`.
- **A distributed trace.** A request arriving with a `traceparent` header produces a span
  named by its **Servant route** (`POST v1/relationships/write`, not bare `POST`),
  carrying through to the PostgreSQL work it does, exported over OTLP; and every access
  log line carries the matching `trace_id` and `span_id`.
- **A black-box acceptance suite.** A checked-in Hurl suite that runs against a really
  listening `en-server` — proving the packaged executable binds its socket, applies its
  production middleware stack, authenticates, and serializes correctly, which no
  in-process `Wai.Test` request can prove.
- **Pagination a generated client understands.** `en`'s four unbounded list endpoints
  return a Relay `Connection` with typed opaque cursors, replacing the bespoke
  `{status: "hasMore" | "truncated", cursor}` envelope, and each ships a conformance test
  proving that walking the pages skips no row and duplicates none.

And one thing that is invisible from outside but is the reason a fleet has conventions at
all: **`en`'s Haskell reads like the rest of the fleet's Haskell.** Every package uses the
GHC2024 language edition with the same four baseline extensions, every record is read and
updated through `generic-lens` `#label` syntax and lens operators, and a single
`En.Prelude` module carries the imports that appear in nearly every file.

### What is explicitly excluded

**CLI conformance.** The catalog carries thirteen CLI standards — `--version` with a git
SHA, shell completions, help topics, option groups, hierarchical configuration, and more.
`en` ships three executables (`en-server`, `en-migrate`, `en-verify-grant`), so those
standards do apply to it in principle. They are deliberately out of scope: `en`'s
executables are operator tools rather than the product surface, and folding thirteen more
standards in would roughly double the initiative without touching the API alignment that
prompted it. Recorded here so the gap is deferred rather than forgotten.

**Keiro and the transactional outbox.** The OpenTelemetry standard devotes two sections to
passing a tracer into `keiro` and continuing trace context across an outbox. `en` uses
neither — it has no command bus and no outbox — so those sections have nothing to apply
to. This is an absence of subject matter, not a deviation.

**The catalog's own governance.** `patterns/governance/review-policy.md` governs how the
catalog's documents are reviewed and timestamped. It binds contributors to that
repository, not consumers of it.


## Decomposition Strategy

The initiative was decomposed by **the concern each catalog standard owns**, because that
is how the standards themselves are drawn: each one names a single subsystem, states its
rule in the first paragraph, and is independently satisfiable. A decomposition by file or
package would have cut across every standard at once — `en-server/app/Main.hs` alone is
touched by the health, observability, and logging work — and would have produced plans
that could not be verified in isolation.

Seven child plans result. Six are new; the seventh already existed and is adopted into
this initiative rather than rewritten, for reasons recorded in the Decision Log.

They fall into four waves. The waves exist because two of the plans are *sweeps* — they
touch nearly every file in the repository — and running a sweep concurrently with
targeted work guarantees merge conflicts on files neither plan is really about.

**Wave 1 (baseline).** `docs/plans/63-adopt-the-fleet-haskell-core-standards-across-every-en-package.md`
makes every package's cabal stanza identical and conformant, adds the `lens` and
`generic-lens` dependencies and the `En.Prelude` module, and turns on
`-Werror=missing-fields`. It changes no behavior and migrates no call site; it is the
groundwork the last wave consumes. It runs first because `-Werror=missing-fields` is what
makes the `NamedRoutes` guarantee real — that adding a route breaks the build until a
handler exists — and three later plans add routes.

**Wave 2 (the service surface).** Three plans that each replace one externally visible
subsystem: `docs/plans/61-adopt-rfc-9457-problem-details-and-close-the-api-conformance-audit.md`
(error bodies), `docs/plans/64-serve-kubernetes-health-probes-from-servant-health.md`
(probes), and
`docs/plans/65-instrument-en-with-opentelemetry-and-a-conformant-production-request-log.md`
(traces and access logs). Error bodies go first because the other two both reference the
problem-details contract: the health plan must record its probe body as an *exemption*
from it, and the observability plan's access-log shape is defined against it.

**Wave 3 (contract and pagination).**
`docs/plans/66-add-a-hurl-black-box-api-suite-for-en-server.md` writes the black-box suite,
which can only assert a contract that exists — so it follows wave 2. Then
`docs/plans/67-adopt-relay-pagination-for-en-s-list-endpoints.md` performs the one
deliberately breaking wire change in the initiative, last among the API plans, so it lands
on a tree that is otherwise already conformant and so the Hurl suite written just before it
is available to prove the migration end to end.

**Wave 4 (the idiom sweep).**
`docs/plans/68-migrate-en-s-records-to-generic-lens-label-syntax-and-a-custom-prelude.md`
rewrites roughly 1,400 record reads and 219 record updates across 80 modules. It is last
for two reasons. It conflicts with everything, so running it against a settled tree is the
only way to keep the diffs reviewable. And every earlier plan adds code; having them land
first means the sweep converts that new code too, rather than leaving the tree in two
idioms and requiring a second pass.

### Alternatives considered

**One plan per catalog document (eight plans).** Rejected because production request
logging cannot be verified independently of OpenTelemetry — the standard's log line
carries `trace_id` and `span_id` read from the WAI span's request-vault context, so a
logging plan without a tracer provider has nothing to correlate against. The two are one
plan, `docs/plans/65-...`.

**Merging the two idiom plans into one.** Rejected because `docs/plans/63-...` is a
zero-behavior-change cabal and scaffolding plan that should land immediately and benefits
every later plan, while `docs/plans/68-...` is a 30,000-line sweep that must land last.
Fusing them would force the whole initiative to wait on the sweep.

**Excluding the record-idiom work entirely and recording a deviation ADR.** Considered
seriously and rejected by the initiative's owner on 2026-08-25; see the Decision Log.

### Architecture Decision Records consulted

`en`'s ADRs live in `docs/adr/` as ordinary Markdown files (frontmatter `title`, `status`,
`date`, `authors`, `related`; body headed `# ADR N — <title>`). `mori.dhall` declares one
OKF bundle, `docs/capabilities`, and **no** bundle at `docs/adr` — so the shared
profile-governed ADR workflow does not apply here and the established filesystem
convention is authoritative. New ADRs from this initiative follow that convention and
continue the `ADR-N` numbering from 3.

Three ADRs exist and two bear on this work:

- [ADR 2 — crypton 1.1 binds en's dependency closure through a biscuit-haskell fork](../adr/0002-crypton-1-1-binds-en-s-dependency-closure-through-a-biscuit-haskell-fork.md)
  is the one every child plan must respect. Cabal resolves exactly one version of a package
  for the whole project, and `en`'s closure is already tightly bound: `pg-migrate` requires
  `crypton >= 1.1`, which forces a forked `biscuit-haskell` pinned by
  `source-repository-package` in `cabal.project`. **Every plan in this initiative adds a
  dependency cohort** — `lens`/`generic-lens`, `servant-health`, the five-package
  OpenTelemetry cohort plus a forked Servant instrumentation package, four
  `relay-pagination` packages — and each one is a chance to break that closure. Every child
  plan therefore begins by proving its cohort resolves with `cabal build all` before writing
  code.
- [ADR 1 — en's schema is an append-only pg-migrate component](../adr/0001-en-s-schema-is-an-append-only-pg-migrate-component.md)
  binds `docs/plans/67-...` specifically. Relay keyset pagination needs a **total** database
  order, which in practice means an index that matches the sort specification exactly. Adding
  one is a schema change, and under ADR 1 that means a new append-only migration in
  `en-migrations`, never an edit to an existing migration file.

[ADR 3 — the in-memory store is for tests and demos only](../adr/0003-the-in-memory-store-is-for-tests-and-demos-only.md)
was read and does not constrain this initiative, but it is the reason
`docs/plans/66-...` runs its Hurl suite against a PostgreSQL-backed `en-server` rather
than the in-memory store: the in-memory interpreter is explicitly not a production
surface, and a black-box suite exists to test the production surface.

No cross-repository ADR was found that governs this work. `mori registry concepts` was
searched for the catalog's own decisions; the catalog publishes standards, not ADRs.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 63 | Adopt the fleet Haskell core standards across every en package | docs/plans/63-adopt-the-fleet-haskell-core-standards-across-every-en-package.md | None | None | Not Started |
| 61 | Adopt RFC 9457 problem details and close the API conformance audit | docs/plans/61-adopt-rfc-9457-problem-details-and-close-the-api-conformance-audit.md | None | EP-63 | Not Started |
| 64 | Serve Kubernetes health probes from servant-health | docs/plans/64-serve-kubernetes-health-probes-from-servant-health.md | EP-61 | EP-63 | Not Started |
| 65 | Instrument en with OpenTelemetry and a conformant production request log | docs/plans/65-instrument-en-with-opentelemetry-and-a-conformant-production-request-log.md | EP-64 | EP-63 | Not Started |
| 66 | Add a Hurl black-box API suite for en-server | docs/plans/66-add-a-hurl-black-box-api-suite-for-en-server.md | EP-61, EP-64 | EP-65 | Not Started |
| 67 | Adopt Relay pagination for en's list endpoints | docs/plans/67-adopt-relay-pagination-for-en-s-list-endpoints.md | EP-61 | EP-66 | Not Started |
| 68 | Migrate en's records to generic-lens label syntax and a custom prelude | docs/plans/68-migrate-en-s-records-to-generic-lens-label-syntax-and-a-custom-prelude.md | EP-63 | EP-61, EP-64, EP-65, EP-66, EP-67 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their `#` prefix (e.g., EP-63).


## Dependency Graph

Read the hard dependencies as "the later plan's code would not compile, or would be
provably wrong, without the earlier plan's artifacts."

**EP-63 depends on nothing** and can start immediately. It is the only plan with no
prerequisite.

**EP-61 hard-depends on nothing.** It is already fully written and self-contained, and its
Milestone 1 adds `http-media` and the OpenAPI cohort bounds to
`en-servant/en-servant.cabal` on its own. Its soft dependency on EP-63 is real but weak:
if EP-63 lands first, EP-61 writes its new `En.Servant.Problem` module against a cabal
stanza that already has the baseline extensions, and `-Werror=missing-fields` guards the
response-record growth in its Milestones 2 through 4. If EP-61 lands first, nothing breaks;
EP-63 simply sweeps one more package.

**EP-64 hard-depends on EP-61.** Two reasons, and only the second is a compile-time one.
The health standard requires the probe body to be recorded as a named *exemption* from the
problem-details conformance test — so the test it exempts itself from must exist, and that
test is EP-61's Milestone 6. And EP-64 deletes `en-server/app/Health.hs`, whose `/readyz`
failure body EP-61's Milestone 5 converts; running them in the other order means EP-61
converts a module EP-64 has already removed, and its Milestone 5 no longer type-checks
against the tree.

**EP-65 hard-depends on EP-64.** The standard requires the access log's path predicate to
be built from `Servant.Health.Paths.healthRawPaths` rather than from string literals, so
the exclusion cannot drift from the actual routes. That constant comes from the
`servant-health` package EP-64 introduces. Written before EP-64, the predicate would have
to name `/healthz` and `/readyz` literally and then be rewritten.

**EP-66 hard-depends on EP-61 and EP-64.** A black-box suite asserts a contract; it can
only assert the one that exists. Its `health.hurl` file asserts the `servant-health` probe
body at `/health/live` and `/health/ready`, and every error assertion across the suite
asserts `application/problem+json` with an RFC 9457 body. Written earlier, the whole suite
would be rewritten twice.

**EP-67 hard-depends on EP-61.** The Relay standard defines `RelayPageError` as a
*recorded exemption* from the RFC 9457 default — a paginated endpoint answers 400 with
`RelayPageError`, not a problem document, and exempts those routes by name in the
problem-details conformance test. That exemption mechanism is EP-61's. EP-67's soft
dependency on EP-66 is about proof rather than compilation: EP-67 is the initiative's one
breaking wire change, and having the Hurl suite already in place means the migration can be
demonstrated against a live server rather than argued from unit tests.

**EP-68 hard-depends on EP-63** for the `En.Prelude` module and the `lens` /
`generic-lens` dependencies it migrates call sites onto, and soft-depends on **every other
plan** purely for sequencing. Nothing in EP-68 needs the others' artifacts; it is placed
last so it sweeps a settled tree exactly once.

### What can run in parallel

Very little, and that is deliberate. EP-63 can run alongside EP-61 — they touch disjoint
files, EP-63 editing only `.cabal` stanzas and adding one new module, EP-61 editing
`en-servant/src/` and `en-server/app/`. Beyond that pair the chain is essentially serial,
because each service-surface plan hands the next one a constant, a test, or a module the
next one consumes. A contributor picking up work should take the first row in the registry
whose hard dependencies are all Complete.


## Integration Points

**`en-server/app/Main.hs`'s middleware stack.** Touched by EP-64, EP-65, and EP-67, and
the single most contended file in the initiative. Today it composes, outermost first:
`authMiddleware`, `rateLimit`, `requestIdMiddleware`, `requestLogger`,
`metricsMiddleware`, `healthRoutes`, `metricsRoute`, wrapping `appWithOpenApi serverEnv`.
**EP-64 owns the removal** of the WAI-level `healthRoutes` layer, because the probes move
into the servant API record. **EP-65 owns the final ordering**, which the OpenTelemetry
standard fixes exactly: the OTel WAI middleware must be leftmost, `openTelemetryServantMiddleware`
directly inside it, and the request logger inside that — otherwise the logger runs before a
server span exists and cannot correlate, and the Servant instrumentation has no span to
annotate. EP-64 must therefore leave the stack in a state EP-65 can reorder rather than
rebuild: remove the health layer, change nothing else. EP-65's plan carries the final
composition verbatim.

**The problem-details conformance test's exemption list.** Defined by EP-61 in
`en-servant/test/Main.hs` as part of its Milestone 6. Two later plans **add entries** and
neither may weaken the test: EP-64 exempts the two `servant-health` probe routes (a probe
report describes current state and is not an error document), and EP-67 exempts the
paginated routes (which answer 400 with `RelayPageError`, a released wire contract that
predates and outranks the fleet default). Each exemption must name routes explicitly —
never a predicate that could silently grow — and each must be justified in its own plan's
Decision Log. EP-64 additionally supplies the route names from
`Servant.Health.Paths.healthRawPaths` rather than string literals, so the exemption and the
mounted route cannot drift apart.

**`En.Prelude`.** Created by EP-63 in the `en-core` package and exposed from it; consumed
by EP-68 across every module. EP-63 defines the export list and the `PackageImports`
per-file pragma; EP-68 may **add** re-exports it needs but must not remove any, and must
never import `Data.Generics.Labels` into the prelude — that orphan `IsLabel` instance
belongs in each module that uses `#label`, for the reason the catalog records: re-exporting
it forces the generic-lens reading of `#label` onto every module and cannot be undone at a
use site.

**`en-servant/en-servant.cabal`'s dependency list.** Grown by EP-61 (`http-media`, plus
version bounds on the OpenAPI cohort), EP-64 (`servant-health`), and EP-67 (three
`relay-pagination` packages). Under ADR 2 the risk is shared and cumulative rather than
per-plan: each addition can perturb a closure already pinned by `crypton >= 1.1` and a
forked `biscuit-haskell`. Every plan's first milestone therefore proves its own cohort
resolves — `cabal build all` succeeding is the gate — and records the resolved versions
from `dist-newstyle/cache/plan.json` in its Interfaces and Dependencies section, so a later
plan hitting a conflict can see what the earlier one pinned.

**The generated OpenAPI artifact, `docs/api/openapi.json`.** A build product regenerated by
`cabal run en-openapi` and drift-checked by `just openapi`. EP-61, EP-64, and EP-67 all
change it. The rule for all three: never hand-edit it, regenerate it as its own commit
separate from the type change that caused it, and read the resulting diff rather than
skimming it — it is the artifact a non-Haskell client generator consumes.

**`en`'s external consumers.** `kikan-en` imports `app`, `Env`, and `AppEffects` from
`En.Servant.API` and `En.Servant.Seam` directly; `nagare` pins `en` by a
`source-repository-package` git tag. EP-61 already records that neither names an error
type, so the error-body change cannot break them. EP-67 is different in kind: it changes
response *shapes* on four endpoints, which is exactly what a consumer decodes. EP-67 owns
the compatibility question and must answer it explicitly in its own Decision Log rather
than inheriting EP-61's answer.

### Cross-plan decisions that should become ADRs

Four are anticipated. Each is recorded here so the responsible plan knows it owes an ADR,
per the distillation rule in `.claude/skills/exec-plan/ADR.md`.

- **The health-probe surface is `servant-health`'s, not en's** (EP-64). A durable
  architecture boundary: the 200/503 `AsUnion` mapping lives in one tested package and is
  never re-implemented in a service. Worth an ADR because the tempting future change —
  "just inline the two routes, it is three lines" — is precisely the one the standard
  forbids, and the reason is not obvious from the call site.
- **Telemetry configuration lives outside the binary** (EP-65). `en` gains a dependency on
  environment-variable configuration (`OTEL_EXPORTER_OTLP_ENDPOINT`,
  `OTEL_SEMCONV_STABILITY_OPT_IN=http`) that its own config validation does not own. That
  boundary, and the forked Servant instrumentation pin it requires, are durable.
- **`en`'s list endpoints paginate the Relay way** (EP-67), including the deliberate
  breaking change and what it costs `nagare`.
- **`en`'s record idiom is generic-lens `#label`** (EP-68), superseding the
  `NoFieldSelectors` / `OverloadedRecordDot` idiom the tree uses today. Durable because it
  governs every module written from then on, and because the two idioms are individually
  coherent — a future contributor needs to know which one won and why.


## Progress

Milestone-level progress across all child plans. Each child plan owns the granular
checklist; this is the at-a-glance view of the initiative.

- [ ] EP-63: Uniform `common` stanzas and GHC2024 across all eight packages
- [ ] EP-63: `-Werror=missing-fields` and the postpositive-import cleanup
- [ ] EP-63: `En.Prelude` and the `lens` / `generic-lens` dependencies, no call sites migrated
- [ ] EP-61: Problem-details machinery in isolation, proven by a three-legged spike
- [ ] EP-61: The servant surface converted; `ErrorEnvelopeWire` deleted
- [ ] EP-61: A 500 for genuine internal faults, distinguished from a 503 dependency outage
- [ ] EP-61: `POST /v1/grants` declares its statuses
- [ ] EP-61: `en-server` middleware and readiness converted
- [ ] EP-61: The OpenAPI half closed — media types, security scheme, conformance tests
- [ ] EP-61: Documents of record updated
- [ ] EP-64: `servant-health` mounted; `/health/live` and `/health/ready` serving
- [ ] EP-64: Probe checks wired (`safeCheck`, `withProbeTimeout`, `sequenceChecks`, failure trackers)
- [ ] EP-64: Test-kit contract test passing; old `Health.hs` deleted; probes exempted from the problem-details test
- [ ] EP-65: OpenTelemetry provider lifetimes owned in `main`, exporting over OTLP
- [ ] EP-65: Servant route naming, with the middleware stack in the required order
- [ ] EP-65: The request logger conformed — bounded fields, trace correlation, probe exclusion
- [ ] EP-66: Hurl available as a project tool and the suite skeleton runnable
- [ ] EP-66: Resource-family files covering health, OpenAPI, and the read surface
- [ ] EP-66: Opt-in mutating and perimeter scenarios, wired into CI without hiding failures
- [ ] EP-67: Relay cohort resolving; the total database order and its migration
- [ ] EP-67: The four list endpoints converted to `Connection` / `RelayPageError`
- [ ] EP-67: Conformance tests proving no row is skipped or duplicated; consumers notified
- [ ] EP-68: `en-core` and `en-postgres` migrated to `#label` and lens operators
- [ ] EP-68: `en-servant`, `en-client`, and `en-biscuit` migrated
- [ ] EP-68: `en-server`, `en-example`, `en-migrations`, and every test suite migrated


## Surprises & Discoveries

Cross-plan insights, dependency changes, scope adjustments, and unexpected interactions
between child plans. Concise evidence.

- Discovery (2026-08-25, while decomposing): **`en`'s hand-written request logger already
  independently reached the standard's central conclusion.** The production request-logging
  standard's main negative rule is "do not promote `wai-extra`'s JSON formatter", because
  `formatAsJSON` serializes every request header while redacting only `Cookie` — writing
  each caller's `Authorization: Bearer <secret>` to stdout — and its
  `CustomOutputFormatWithDetails` carrier buffers the entire request and response bodies.
  The Haddock at the top of `en-server/app/Observability.hs` states exactly that reasoning
  and rejects `wai-extra` for exactly those two reasons. EP-65 is therefore a much smaller
  plan than the standard's length suggests: the field set needs aligning and trace
  correlation needs adding, but the hard call was already made correctly and independently.

- Discovery (2026-08-25, while decomposing): **`en-server` is already built for the
  OpenTelemetry SDK.** The standard requires `-threaded` on every executable that
  initializes a tracer provider, because the SDK's batch span processor fails at runtime
  without it (`The hs-opentelemetry batch processor does not work without the -threaded GHC
  flag!`). `en-server/en-server.cabal` already carries
  `ghc-options: -threaded -rtsopts -with-rtsopts=-N`. One less thing for EP-65 to discover
  the hard way.

- Discovery (2026-08-25, while decomposing): **`shinzui/relay-pagination` is registered in
  Mori with an `Experimental` lifecycle**, while every other package this initiative adopts
  is `Active`. The pagination standard itself is unqualified and names four released
  0.1.x packages, so the standard and the registry disagree about maturity. This is why
  EP-67 opens by re-verifying the packages' released versions and lifecycle before
  committing to them, and why it is sequenced last: it is the plan most likely to need
  rescoping on contact.

- Discovery (2026-08-25, while decomposing): **`en`'s probes are WAI-level, not servant
  routes.** `en-server/app/Health.hs` answers `/healthz` and `/readyz` from a `Middleware`
  that inspects `pathInfo` and never reaches the servant application, and its own Haddock
  explains the choice: the probes describe the process rather than the versioned wire
  contract, so they sit outside `/v1` and outside the OpenAPI document. Adopting
  `servant-health` reverses that judgment — the probes become routes on the API record and
  therefore appear in the generated document. EP-64 owns arguing that reversal rather than
  performing it silently.


## Decision Log

- Decision: Adopt the catalog's record idiom in full — `generic-lens` `#label` syntax, lens
  operators over record-update syntax, and an `En.Prelude` custom prelude — rather than
  keeping `en`'s `NoFieldSelectors` / `OverloadedRecordDot` idiom and recording a deviation.
  Rationale: this was the initiative owner's explicit choice on 2026-08-25, made against a
  measured picture of the cost: roughly 1,400 record-access sites and 219 record-update
  sites across 80 modules and about 31,000 lines, in a tree with no `generic-lens` or `lens`
  dependency anywhere today. The alternative offered was a deviation ADR keeping en's
  current idiom, which is internally consistent and used uniformly. The owner chose full
  adoption, so the tree ends in one idiom that matches the fleet rather than two idioms that
  each read well locally. The cost is contained by splitting the work in two — scaffolding
  in EP-63, the sweep in EP-68 — and by sequencing the sweep last, so it converts the code
  the other six plans add instead of racing them.
  Date: 2026-08-25

- Decision: Adopt the existing
  `docs/plans/61-adopt-rfc-9457-problem-details-and-close-the-api-conformance-audit.md` as a
  child of this MasterPlan by adding a `master_plan` field to its frontmatter, rather than
  creating a new child plan for error bodies.
  Rationale: EP-61 was authored on 2026-07-22 out of the conformance audit at the end of
  `docs/plans/59-convert-en-servant-to-namedroutes-and-vertical-slices.md`, and revised on
  2026-08-25 against the current catalog. It is complete, self-contained, unstarted, and
  already covers the error-body standard end to end across seven milestones. Recreating it
  would discard a revision made hours earlier and would leave two plans describing the same
  work. The MasterPlan skill's normal flow creates children through `init-plan.ts`, which
  writes `master_plan` into new frontmatter; for an existing plan the equivalent is to add
  the field. The registry references it by path like any other child.
  Date: 2026-08-25

- Decision: Sequence the Relay pagination work last among the API plans and give it its own
  full child plan, rather than folding it into the error-body work or deferring it.
  Rationale: this was the owner's choice on 2026-08-25 among three options — a full plan
  sequenced last, an audit-only plan that stops before implementing, and a recorded
  exemption. It is the initiative's only deliberately breaking wire change, affecting four
  endpoints that `nagare` decodes, so it wants to land once, deliberately, on a tree that is
  otherwise already conformant, with the Hurl suite from EP-66 available to demonstrate it
  against a live server. Sequencing it last also means that if the `Experimental` lifecycle
  of `shinzui/relay-pagination` turns out to be a real obstacle, the discovery costs the
  initiative nothing already delivered.
  Date: 2026-08-25

- Decision: Exclude CLI conformance from this initiative and record it as deferred rather
  than as a deviation.
  Rationale: the owner's choice on 2026-08-25. The catalog's thirteen CLI standards do apply
  to `en-server`, `en-migrate`, and `en-verify-grant` in principle, but those are operator
  tools rather than the product surface, and including them would roughly double an
  initiative whose motivation was API alignment. "Deferred" rather than "deviating" is the
  accurate label: nothing here decides that `en` should not eventually conform, only that it
  is not this initiative's work. Recorded in Vision & Scope so it survives this document.
  Date: 2026-08-25

- Decision: Accept that `docs/plans/61-...`'s Milestone 5 converts the `/readyz` failure
  body to a problem document, and that `docs/plans/64-...` then deletes that endpoint
  entirely a wave later.
  Rationale: this looks like waste and is worth naming rather than hiding. Three ways out
  were considered. Editing EP-61 to drop its `/readyz` work would re-open a plan revised
  hours earlier and would leave `en` serving one endpoint in the old error dialect while
  every other surface converted — the two-dialect outcome EP-61 exists to prevent, and which
  its own Decision Log rejects by name. Running EP-64 before EP-61 fails for a harder
  reason: EP-64's probe routes must be exempted from a conformance test EP-61 creates.
  Deferring EP-61's Milestone 5 would fragment a plan that is written as a hard cutover
  where GHC's error list is the migration checklist. The waste is one small function body
  that lives for one wave, and the alternative costs correctness or coherence. EP-64's plan
  states this explicitly so its implementer does not mistake the deletion for a mistake.
  Date: 2026-08-25

- Decision: Require every child plan to prove its dependency cohort resolves — `cabal build
  all` succeeding — as its first milestone, before writing code, and to record the resolved
  versions from `dist-newstyle/cache/plan.json` in its Interfaces and Dependencies section.
  Rationale: [ADR 2](../adr/0002-crypton-1-1-binds-en-s-dependency-closure-through-a-biscuit-haskell-fork.md)
  documents that `en`'s dependency closure is already tightly bound — `pg-migrate` forces
  `crypton >= 1.1`, which forces a forked `biscuit-haskell` pinned in `cabal.project` — and
  that relaxing a bound alone is not enough, because the solver succeeds and the compile then
  fails on a missing instance. Five of the seven child plans add a new cohort to that
  closure. Discovering a conflict after a milestone of code is written is the expensive
  ordering; discovering it in the first commit is cheap. Recording resolved versions makes a
  later plan's conflict diagnosable rather than mysterious.
  Date: 2026-08-25

- Decision: Decompose by catalog concern into four sequential waves rather than by package,
  and accept that the initiative is close to serial.
  Rationale: the standards are themselves drawn by concern, each independently satisfiable
  and independently verifiable, which is exactly the decomposition property MASTERPLAN.md
  asks for. A package-shaped decomposition would have put `en-server/app/Main.hs` in three
  plans at once. The near-serial ordering is a real cost in wall-clock time and was accepted
  deliberately: two of the seven plans are whole-tree sweeps, and every hard dependency in
  the graph is a case where the later plan consumes a constant, a test, or a module the
  earlier one defines. Only EP-63 and EP-61 are genuinely parallelizable, and the registry
  says so.
  Date: 2026-08-25


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision. Before marking the MasterPlan complete,
distill durable project context from this MasterPlan and its child ExecPlans into
`docs/adr/`. Keep task-local execution and coordination details here.

(To be filled during and after implementation.)
