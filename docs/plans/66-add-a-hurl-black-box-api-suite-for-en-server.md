---
id: 66
slug: add-a-hurl-black-box-api-suite-for-en-server
title: "Add a Hurl black-box API suite for en-server"
kind: exec-plan
created_at: 2026-08-25T20:39:46Z
intention: "intention_01m0xaavwqeznrgzs3j67m0q21"
master_plan: "docs/masterplans/11-bring-en-into-conformance-with-the-haskell-jitsurei-pattern-catalog.md"
---

# Add a Hurl black-box API suite for en-server

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

`en` has good in-process tests. `en-servant/test/Main.hs` serves the application through
`Network.Wai.Test` and asserts routing, error shapes, and the generated OpenAPI document, and
those tests are fast, deterministic, and thorough about domain behavior.

They also cannot see the thing an operator cares about most: **whether the packaged
executable, started the way production starts it, actually works.** A `Wai.Test` request
never binds a socket. It never runs `en-server`'s middleware stack — authentication, rate
limiting, request logging, metrics — because that stack is assembled in
`en-server/app/Main.hs`, outside the application the tests exercise. It never reads
configuration, never opens a connection pool, and never proves that a real HTTP client
speaking real HTTP over a real socket gets the bytes the type says it should.

What `en` has instead is `just test-server`: a shell target that `curl`s three endpoints in
sequence and pipes them through `jq`. It is a genuine smoke test and it has clearly earned
its keep, but it is one flow, its assertions are `test "$decision" = "allowed"`, and adding a
case means extending a 20-line shell pipeline built from nested quoting.

After this plan, `en` has a checked-in black-box suite that runs against a really listening
server:

```bash
just hurl
```

```text
en-servant/test/hurl/health.hurl: Success (4 request(s) in 31 ms)
en-servant/test/hurl/openapi.hurl: Success (2 request(s) in 12 ms)
en-servant/test/hurl/relationships.hurl: Success (9 request(s) in 88 ms)
en-servant/test/hurl/checks.hurl: Success (7 request(s) in 61 ms)
en-servant/test/hurl/perimeter/perimeter.hurl: Success (6 request(s) in 44 ms)
--------------------------------------------------------------------------------
Executed files:  5
Succeeded files: 5 (100.0%)
```

Each request block asserts the **public contract** — the status, the media type, and the
stable machine-readable fields — rather than that some 2xx arrived. Failures and security
boundaries are covered as first-class cases, not as an afterthought: a malformed body, an
unknown relation, a missing credential, an invalid credential, a read-only key on a write
path. Write flows live in an opt-in file so the default suite stays read-only and safe to
point at any environment.


## Progress

- [x] (2026-08-25T19:17:14-07:00) Milestone 1 — Make Hurl available as a project tool (`pkgs.hurl` in the dev shell) and
      create the suite skeleton: directory, `README.md`, `vars.env`, `run.sh`, and a `just
      hurl` target. One trivial `health.hurl` proves the runner works end to end.
- [x] (2026-08-25T19:20:08-07:00) Milestone 2 — Cover the read surface in resource-family files: `health.hurl`,
      `openapi.hurl`, `checks.hurl`, `lookups.hurl`, `expands.hurl`, `schema.hurl`. Every
      file independent; every block asserting status, media type, and stable fields.
- [x] (2026-08-25T19:23:21-07:00) Milestone 3 — Cover failures reachable against the standard
      demo host: malformed bodies, unknown routes and relations, invalid cursors, method
      mismatches, and a transactionally rolled-back precondition failure. Assert
      `application/problem+json` and the stable `code`, never prose; keep the alternate-schema
      resolution-budget branch in the deterministic Haskell suite.
- [x] (2026-08-25T19:26:41-07:00) Milestone 4 — Add the opt-in `relationships.hurl` write flow (write, read back, delete)
      and the opt-in `perimeter/perimeter.hurl` suite covering authentication boundaries
      against a separately configured server.
- [x] (2026-08-25T19:30:41-07:00) Milestone 5 — Wire the suite into the repository's normal task interface and into CI
      without hiding failures; retire or reduce `just test-server`; document the suite's
      fixture contract in its `README.md`.


## Surprises & Discoveries

- Discovery (2026-08-25, while planning): **`just test-server` is already the thing this plan
  replaces, and it encodes a fixture contract nobody wrote down.** It deletes a specific tuple
  (`space:project-x#viewer@user:alice`), writes it back, captures the returned consistency
  token with `jq`, and then checks `user:alice` has `view` on `space:project-x` at that token,
  asserting the decision is `allowed`. That flow assumes a schema in which `space` has a
  `viewer` relation and a `view` permission derived from it, and it assumes the default API
  key `dev-secret-0123456789`. Both assumptions are load-bearing and neither is documented
  anywhere. Milestone 5's `README.md` is where they get written down, and the delete-first
  step is worth copying: it is what makes the flow idempotent across re-runs.

- Discovery (2026-08-25, while planning): **`en`'s consistency tokens make a naive
  read-after-write assertion flaky, and Hurl's retry is the wrong fix for it.** `en` answers
  writes with a token that pins a database revision, and a read that supplies that token sees
  the write. A read *without* the token may not. So the correct Hurl pattern here is to
  capture the token from the write response and send it on the subsequent read — an
  assertion about `en`'s actual consistency contract — rather than to bolt `retry: 10` onto
  the read and paper over it. Retries belong to genuinely eventually-consistent read models;
  `en` is not one, and using a retry here would hide a real regression in token handling.

- Discovery (2026-08-25, while planning): **the dev shell already carries `jq` and
  `process-compose` but not `hurl`.** `nix/haskell.nix` lists the tool set, and
  `nix/haskell.nix:3` documents that extra dev packages should be set through
  `haskellProject.extraDevPackages` from `./flake.module.nix` rather than by editing that file
  — so Milestone 1 follows that instruction rather than appending to the list directly.

- Discovery (2026-08-25, Milestone 1): **the workstation has an unrelated container bound
  specifically to `127.0.0.1:8080`, while the supervised `en-server` binds the wildcard
  address on the same port.** A request to the suite's standard localhost default therefore
  reached Redpanda Console rather than en. Validation used a second `en-server` on port 18080
  and Hurl's command-line `base_url` override; the checked-in `127.0.0.1:8080` default remains
  correct for an ordinary checkout. Evidence: the overridden run executed six files and the
  live probe request, with `Succeeded files: 6 (100.0%)`.

- Discovery (2026-08-25, Milestone 3): **expand silently normalizes invalid pagination input
  instead of returning the errors its sibling list endpoints return.** A live request with
  `limit: 0` answered 200 because `En.Expand.pageNodes` clamps the raw limit with `max 0`; a
  request with `cursor: "not-a-cursor"` also answered 200 because `decodeCursor` falls back to
  offset zero. `lookup` rejects the same invented cursor as `invalid_cursor`. EP-67 is already
  responsible for replacing all three bespoke cursor contracts with typed Relay cursors, so
  this suite records the asymmetry without changing Haskell under a test-only plan.

- Discovery (2026-08-25, Milestone 5): **the runner fails honestly for both contract and
  process failures.** Temporarily changing the healthy status assertion to
  `__intentional_failure__` produced exit 4 and reported `actual: string <ok>` beside the
  expected value. With the port-18080 server stopped, all six safe families failed with
  connection errors and `just hurl` exited 3. Restoring the assertion and targeting the
  authenticated port-18081 server returned `Succeeded files: 6 (100.0%)` across 15 requests.

(Add further entries as work proceeds.)


## Decision Log

- Decision: Put the suite at `en-servant/test/hurl/`, beside the package that owns the API
  type, rather than at the repository root or under `en-server`.
  Rationale: the standard says to keep black-box assets "beside the API package, not mixed
  into unit-test fixtures". `en-servant` owns the routes the suite asserts, so a contributor
  changing a route finds the matching `.hurl` block in the same package. `en-server` was the
  alternative — it owns the executable the suite actually talks to — but the suite asserts the
  *contract*, and the contract lives in `en-servant`. The runner script is what knows about
  the server.
  Date: 2026-08-25

- Decision: Keep the default suite read-only and put every write in an opt-in
  `relationships.hurl` that the default `run.sh` invocation does not execute.
  Rationale: the standard's rule, and it earns its keep here specifically. `en` is an
  authorization service; a suite that writes tuples changes who can do what. Keeping the
  default read-only means the suite can be pointed at a shared or staging environment without
  a conversation first. The opt-in file names its fixture identities explicitly so two
  parallel runs cannot collide.
  Date: 2026-08-25

- Decision: List safe files by name in `run.sh` rather than globbing `*.hurl`.
  Rationale: the standard calls this out, and the failure mode is quiet: a contributor adds
  `dangerous-scenario.hurl` next to the others and a glob silently pulls it into the default
  suite, which then mutates state in whatever environment it was pointed at. An explicit list
  makes inclusion a deliberate edit that shows up in review.
  Date: 2026-08-25

- Decision: Assert stable `code` values and media types, never prose messages.
  Rationale: `en`'s twenty error codes are the contract a client branches on, and the
  problem-details work in
  `docs/plans/61-adopt-rfc-9457-problem-details-and-close-the-api-conformance-audit.md`
  carries every one of them forward verbatim precisely so clients need not change. `detail`
  prose is explicitly request-specific and editable. A suite asserting prose would break on
  every wording improvement and would give a false sense of contract coverage.
  Date: 2026-08-25

- Decision: Inject the local-development credential into the safe runner with Hurl's
  `--secret` option, allowing `EN_API_KEY` to override the repository's existing demo key,
  and allow `EN_SERVER_URL` to override the tracked `base_url` default.
  Rationale: five of the six safe resource families exercise authenticated reads, but the
  standard forbids putting credentials in `vars.env`. The repository already publishes the
  non-production demo key in `process-compose.yaml` and `just test-server`; passing it through
  `--secret` preserves diagnostic redaction while keeping `just hurl` useful after
  `just process-up`. Environment overrides let the same read-only runner target an ephemeral
  CI service or a local alternate port without editing tracked files.
  Date: 2026-08-25

- Decision: Leave `resolution_limit_exceeded` in the deterministic engine and HTTP fault-map
  tests rather than manufacture it in the default Hurl suite.
  Rationale: the built-in demo schema has one direct `viewer` relation and cannot exhaust the
  traversal depth budget. A live 422 case would require a second server with an alternate
  recursive schema plus a seeded relationship chain, moving domain combinatorics into Hurl in
  direct conflict with this plan's layer boundary. The safe suite instead covers framework,
  schema, cursor, and transaction-precondition failures that only a real process can prove;
  `en-core/test/Main.hs` retains the deep-chain behavior test and `en-servant/test/Main.hs`
  retains the exact `(422, "resolution_limit_exceeded", false)` wire mapping.
  Date: 2026-08-25

- Decision: Give the Hurl write flow its own `space:hurl-write-flow#viewer@user:hurl-alice`
  fixture identity rather than reusing `just test-server`'s `space:project-x` tuple.
  Rationale: Hurl executes files in parallel and contributors may also run the legacy smoke
  target independently. A distinct identity prevents one flow's delete-first setup from
  revoking the other flow's grant between write and read-back. The Hurl flow remains
  idempotent: two consecutive four-request runs both passed, and the captured write token was
  supplied to the public check instead of hiding consistency with a retry.
  Date: 2026-08-25

- Decision: Retire `just test-server` and make `just start-and-test` orchestrate the safe Hurl
  suite after polling `/health/ready`.
  Rationale: `relationships.hurl` strictly supersedes the old curl pipeline's delete, write,
  token capture, and check flow, while the safe Hurl runner adds the non-mutating contract
  coverage CI should execute by default. Keeping both would duplicate a smoke contract with
  different fixture identities and no clear owner. Readiness, rather than liveness, is the
  correct orchestration gate because the suite immediately exercises PostgreSQL-backed reads.
  Date: 2026-08-25

(Add further entries as work proceeds.)


## Outcomes & Retrospective

The plan is complete. `en-servant/test/hurl/` now carries six independent safe resource
families (15 live requests), an idempotent four-request write flow, and a five-request
authentication-perimeter flow. Every body-bearing response pins its media type and stable
wire fields; failure cases pin machine codes rather than prose. `flake.module.nix` supplies
Hurl and hurlfmt 8.0.1 reproducibly, `just hurl` targets an already-running server, and
`just start-and-test` owns local orchestration through the readiness gate.

The old curl-and-jq `just test-server` recipe is gone. The new GitHub Actions workflow starts
the packaged executable and PostgreSQL through process-compose, runs the safe suite, prints
server logs on failure, and tears services down under `always()`. The suite README documents
the schema assumptions, independent default families, secret injection, unique stateful
fixture, re-run behavior, and perimeter prerequisites.

Validation covered more than the green path: every safe file passed independently; the write
flow passed twice consecutively at its captured consistency token; the perimeter suite passed
against distinct read-write and read-only credentials without echoing them; a deliberately
false assertion exited non-zero with the actual and expected values; and a stopped server made
all families fail at the socket boundary. `just openapi`, workflow YAML parsing, and the Nix
pre-commit and tree-format checks pass. As at the EP-65 baseline, `cabal test all` passes seven
suites and only the Biscuit suite times out under concurrent load; `cabal test en-biscuit`
passes in isolation. The broader `nix flake check` reaches the same pre-existing default-package
failure recorded by EP-65: `cabal2nix` is pointed at a multi-package root with no root `.cabal`
file. The one substantive contract discovery—expand's
permissive zero-limit and malformed-cursor behavior—is handed to EP-67, which already owns the
Relay pagination cutover.

ADR distillation found no new project architecture decision. The durable production-store
boundary remains in ADR 3, health ownership remains in ADR 4, and the black-box suite's layout,
fixtures, and CI lifecycle are test-operational details fully owned by the catalog standard,
this plan, and the suite README.


## Context and Orientation

### What this repository is

`en` is a Haskell implementation of relationship-based authorization (ReBAC) in the style of
Google Zanzibar. It stores relationship *tuples* — facts like "user:alice is `viewer` of
space:project-x" — and answers questions about them over HTTP: `check` (may this subject do
this?), `lookup` (which objects may this subject reach?), `expand` (show the subject tree
behind a permission), a `watch` changelog, a grant-minting endpoint, and the writes that
create and delete tuples. It is built with `cabal` and GHC 9.12.4 and developed inside a nix
shell.

Three of its eight packages matter here. **`en-servant`** owns the HTTP API type and its
tests. **`en-server`** is the standalone executable and its middleware stack.
**`en-postgres`** owns the database interpreters.

### Terms used in this plan

**Hurl** is a command-line HTTP test tool. A `.hurl` file is a plain-text sequence of request
blocks, each with optional `[Asserts]` and `[Captures]` sections. `hurl --test` runs files as
a test suite and exits non-zero on failure. `hurlfmt --check` verifies formatting without
rewriting. Hurl is an external executable, **not** a cabal dependency — no Haskell module
imports it.

**Black-box testing** here means talking to the service the way a client does: over a socket,
against a running process, with no access to its internals.

**A resource family** is one `.hurl` file per group of related endpoints — `checks.hurl` for
the check endpoints, `relationships.hurl` for the write endpoints — rather than one file per
status code or one monolithic file for the whole API.

**A capture** binds a value from one response into a variable that later requests *in the
same file* can use. Files are independent: `--test` runs them in parallel, so nothing may
depend on a capture or mutation from another file.

**An RFC 9457 problem document** is the fleet's standard error body, served as
`application/problem+json`, with `type`, `title`, `status`, `detail`, plus the extension
fields `code` (the stable machine key clients branch on) and `retryable`.

**A consistency token** is `en`'s opaque string pinning a database revision. A write returns
one; a read that supplies it is guaranteed to see that write. This matters for the write-flow
assertions.

### The rule this plan implements

Recorded canonically at
`mori://shinzui/haskell-jitsurei/docs/api-hurl-integration-testing` (resolve it with
`mori path`; today it lands at `patterns/api/hurl-integration-testing.md` in the working copy
at `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei`). Restated:

> Every HTTP service keeps a Hurl suite that runs against a real listening server.

The three test layers, and what each is for — this is the part that decides what goes in the
suite and what stays in Haskell:

| Layer | Owns |
| --- | --- |
| In-process Haskell tests | Handler behavior, dependency injection, error branches, route-to-handler wiring, deterministic database fixtures |
| Generated OpenAPI checks | The route type's declared statuses, parameters, schemas, media types; regeneration and linting |
| Hurl against a live server | Process startup, socket binding, middleware, authentication, CORS, serialization, headers, end-to-end read/write visibility |

**Do not move detailed domain combinatorics or large JSON snapshots into Hurl.** Those stay
fast and deterministic in Haskell. Conversely, a `Wai.Test` request alone is not proof that
the packaged executable listens with the production middleware and configuration.

The specific obligations:

- Provide Hurl through the reproducible development environment (`pkgs.hurl` in the nix
  shell), not as an unrecorded global binary. Never in `build-depends`.
- Use a resource-family layout, one file per family. Requests within a file are sequential and
  may use captures; **different files must be independent**, because `--test` runs files in
  parallel.
- The checked-in `vars.env` holds only non-secret defaults. Real credentials come from
  `--secret` or `--secrets-file`.
- The default runner targets an **already-running** server. Starting the executable, waiting
  for readiness, seeding state, collecting logs, and stopping it belong to a higher-level
  orchestration step. This keeps the suite usable against either a locally started process or
  an ephemeral CI service.
- List safe files **by name**; a `*.hurl` glob silently pulls in new stateful scenarios.
- Assert the public contract — status, media type, stable machine-readable codes — not prose
  messages that may be edited.
- Cover failures and security boundaries for each family: malformed parameters, missing
  resources, unsupported media types or invalid bodies, unauthenticated and unauthorized
  requests, pagination boundaries, and redaction of credentials.
- Keep the default suite read-only where practical; put command endpoints in an explicit
  opt-in file. Prove a write through a subsequent **public read**, never by querying the
  database behind the service.
- Do not add unconditional sleeps. For a genuinely eventually-consistent read, use
  entry-level `retry:`; do not apply global retries to hide startup races — the orchestration
  layer waits for `/health/ready` first.
- The suite's `README.md` is part of the test contract: how to start the server and provision
  its database, the required fixture cardinality and identities, which files the default
  runner executes, which mutate state or need a different server, how secrets are supplied,
  and whether re-running each opt-in flow is idempotent or needs cleanup.

One security note the standard makes explicitly: Hurl redacts secret values from its
diagnostic logs by exact matching, but **does not alter HTTP response bodies** written to
stdout and may preserve them in a JSON report. So a test server must never echo credentials,
and CI must treat response reports as potentially sensitive.

The examples in the standard were checked with `hurl` and `hurlfmt` 8.0.1 on 2026-07-30;
re-check the upstream release before requiring syntax from a newer version.

### Where `en` stands today

There is no Hurl suite: `find . -name '*.hurl'` returns nothing and `hurl` is not in the dev
shell.

What exists is `just test-server`, a shell target that runs one flow with `curl` and `jq`:
delete `space:project-x#viewer@user:alice`, write it back, capture the returned token, then
`check` that `user:alice` has `view` on `space:project-x` at that token and assert the
decision is `allowed`. It authenticates with `Authorization: Bearer ${EN_API_KEY:-dev-secret-0123456789}`
and targets `${EN_SERVER_URL:-http://localhost:${EN_PORT:-8080}}`.

The surrounding orchestration already exists and is what this plan's runner assumes:
`just process-up` starts PostgreSQL through `process-compose`, `just run-migrations` applies
the schema with `en-migrate`, and `just start-server` runs `en-server` and polls a health
endpoint until it answers.

The dev shell's tool list is in `nix/haskell.nix` (`pkgs.postgresql`, `pkgs.postgresql.dev`,
`pkgs.openssl.dev`, `pkgs.jq`, `pkgs.process-compose`), and that file's own header says extra
dev packages should be set through `haskellProject.extraDevPackages` from
`./flake.module.nix` rather than by editing it.

`en-servant/test/Main.hs` holds the in-process suite: routing tests through
`Network.Wai.Test`, the error-model table pinning `(status, code, retryable)` for every engine
error, golden wire tests, and the OpenAPI document conformance tests.

### Relevant Architecture Decision Records

`en`'s ADRs live in `docs/adr/` as ordinary Markdown files. `mori.dhall` declares one OKF
bundle, `docs/capabilities`, and none at `docs/adr`, so the repository's filesystem
convention is authoritative.

[ADR 3 — the in-memory store is for tests and demos only](../adr/0003-the-in-memory-store-is-for-tests-and-demos-only.md)
is why this suite runs against a PostgreSQL-backed `en-server` rather than the faster
in-memory store. The ADR records that the in-memory interpreter is explicitly not a production
surface; a black-box suite exists to test the production surface, so using the in-memory store
here would test the wrong thing while looking like it tested the right one.

[ADR 1](../adr/0001-en-s-schema-is-an-append-only-pg-migrate-component.md) matters only
indirectly: the suite's fixtures depend on a migrated database, which is why the orchestration
step runs `just run-migrations` before the suite.

[ADR 2](../adr/0002-crypton-1-1-binds-en-s-dependency-closure-through-a-biscuit-haskell-fork.md)
does not constrain this plan at all, and that is worth stating: **this plan adds no Haskell
dependency.** Hurl is an external binary in the nix shell, so `en`'s cabal closure is
untouched. This is the only child plan in its initiative with no cohort to prove.

### How this plan relates to the others in its initiative

This is a child of
`docs/masterplans/11-bring-en-into-conformance-with-the-haskell-jitsurei-pattern-catalog.md`.

It **hard-depends on two plans**, because a black-box suite can only assert a contract that
exists, and writing it earlier would mean rewriting it twice:

- `docs/plans/61-adopt-rfc-9457-problem-details-and-close-the-api-conformance-audit.md` —
  every error assertion in this suite asserts `application/problem+json` and an RFC 9457 body
  with a stable `code`. Before that plan, `en` answers errors with
  `{code, message, retryable}` under `application/json`.
- `docs/plans/64-serve-kubernetes-health-probes-from-servant-health.md` — `health.hurl`
  asserts the `servant-health` probe body at `/health/live` and `/health/ready`. Before that
  plan the paths are `/healthz` and `/readyz` with a different body.

It **soft-depends on**
`docs/plans/65-instrument-en-with-opentelemetry-and-a-conformant-production-request-log.md`:
asserting that a `traceparent` header is honoured is a natural black-box case, but the suite
does not need it to exist.

`docs/plans/67-adopt-relay-pagination-for-en-s-list-endpoints.md` **soft-depends on this
plan** — it is the initiative's one breaking wire change, and having this suite in place means
the migration can be demonstrated against a live server rather than argued from unit tests.
Expect EP-67 to rewrite this suite's pagination assertions; that is its job, not a defect here.

### Build and test commands

Work from `/Users/shinzui/Keikaku/bokuno/en` inside the nix development shell.

```bash
cd /Users/shinzui/Keikaku/bokuno/en
just process-up          # PostgreSQL via process-compose
just run-migrations      # apply the schema with en-migrate
just start-server        # run en-server, wait for its health endpoint
just hurl                # this plan's new target
```


## Plan of Work

### Milestone 1 — The tool, the skeleton, and one passing file

Scope: the nix dev shell, a new `en-servant/test/hurl/` directory, and one `just` target.
This milestone deliberately ends with a nearly empty suite, because the thing being verified
is the *runner*, and a runner that works with one file works with twenty.

Add `pkgs.hurl` to the dev shell. `nix/haskell.nix`'s own header says extra dev packages
belong in `haskellProject.extraDevPackages` set from `./flake.module.nix` rather than in that
file's list, so follow that instruction. Confirm with `hurl --version` and `hurlfmt --version`
inside a fresh shell; record the versions in Interfaces and Dependencies. Do **not** add
`hurl` to any `build-depends`: no Haskell module imports it, and ordinary library consumers
do not need a test client.

Create the layout:

```text
en-servant/test/hurl/
├── README.md
├── vars.env
├── run.sh
├── health.hurl
├── openapi.hurl
├── checks.hurl
├── lookups.hurl
├── expands.hurl
├── schema.hurl
├── relationships.hurl        # opt-in: mutates state
└── perimeter/
    ├── README.md
    └── perimeter.hurl        # opt-in: needs a differently configured server
```

`vars.env` holds only non-secret defaults:

```properties
base_url=http://127.0.0.1:8080
```

`run.sh` is deliberately boring and explicit — it targets an **already-running** server and
does not try to start one:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

hurlfmt --check \
  health.hurl \
  openapi.hurl \
  checks.hurl \
  lookups.hurl \
  expands.hurl \
  schema.hurl \
  relationships.hurl \
  perimeter/perimeter.hurl

hurl --test --variables-file vars.env \
  health.hurl \
  openapi.hurl \
  checks.hurl \
  lookups.hurl \
  expands.hurl \
  schema.hurl
```

Note what that does and does not do: `hurlfmt --check` covers **every** file including the
opt-in ones, so formatting cannot rot in a file the default suite skips, while `hurl --test`
runs only the safe list. `set -euo pipefail` plus Hurl's non-zero test exit makes the script
directly usable as a CI gate.

Expose it through the repository's normal task interface, matching the `justfile`'s existing
group annotations:

```just
# Run the safe black-box API suite against an already-running en-server.
[group("testing")]
hurl:
  en-servant/test/hurl/run.sh
```

Write one real block in `health.hurl` and leave the other files as valid empty stubs. Then
run the whole thing against a live server and watch it pass.

Acceptance: `hurl --version` works in a fresh dev shell; `just hurl` runs green against a
started server; `git diff --stat` shows the new directory, the flake change, and one `just`
target.

### Milestone 2 — The read surface, family by family

Scope: `health.hurl`, `openapi.hurl`, `checks.hurl`, `lookups.hurl`, `expands.hurl`,
`schema.hurl`.

Every block asserts status, media type, and the stable fields a client depends on. The shape:

```hurl
POST {{base_url}}/v1/check
Authorization: Bearer {{api_key}}
Content-Type: application/json
{
  "subject": {"kind": "id", "objectType": "user", "objectId": "alice"},
  "permission": "view",
  "object": {"objectType": "space", "objectId": "project-x"},
  "context": {"values": {}},
  "consistency": {"mode": "minimizeLatency"}
}
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.decision.result" == "allowed"
jsonpath "$.checkedAt" exists
```

Three rules to hold to. **Assert the contract, not incidental data**: `decision.result` is a
contract; the exact `checkedAt` token value is not, so assert that it exists rather than
what it is. **Keep files independent**: `--test` runs them in parallel, so `checks.hurl` may
not depend on anything `relationships.hurl` wrote. And **keep domain combinatorics in
Haskell**: `en-servant/test/Main.hs` and `en-core`'s suites already cover the evaluation
algebra exhaustively; this suite proves the wire, not the engine. A good rule of thumb is one
representative success per endpoint plus its failures, not a matrix.

`health.hurl` asserts both probes answer 200 with the `servant-health` body shape (`status`,
`check`, `failingSince`) under `application/json`, and — importantly — that they answer
**without** an `Authorization` header, which is the middleware exemption working.

`openapi.hurl` asserts `GET /v1/openapi.json` returns 200 with an OpenAPI 3.1 document. Assert
`$.openapi` starts with `3.1` and that a known operation id is present; do not snapshot the
document, which is what the in-process drift check already does better.

Acceptance: `just hurl` green; each file independently runnable
(`hurl --test --variables-file vars.env checks.hurl`); no file depends on another.

### Milestone 3 — Failures and error codes

Scope: failure blocks added to each family file.

A happy path is not enough. For each family, cover the relevant failures from the standard's
list. For `en` concretely:

- **A malformed request body** — expect `400`, `application/problem+json`, code
  `malformed_request_body`.
- **An unknown path** — expect `404` with code `not_found`, which proves `en`'s
  `ErrorFormatters` hook is installed in the *packaged* server, something `Wai.Test` cannot
  confirm.
- **An unknown relation or permission** — expect the engine's stable code
  (`unknown_relation`), which proves the fault-to-status mapping survives the real stack.
- **A method mismatch** — `DELETE /v1/relationships` is a declared path that `en` deliberately
  does not serve, because deletion is `POST /v1/relationships/delete`. Expect `405` with a
  problem body explaining what to call instead; that behavior comes from a WAI middleware
  installed inside `En.Servant.API.app`, which is exactly the kind of thing only a black-box
  test observes.

Assert the media type and the stable machine-readable code, never a prose message:

```hurl
POST {{base_url}}/v1/check
Authorization: Bearer {{api_key}}
Content-Type: application/json
`not json at all`
HTTP 400
[Asserts]
header "Content-Type" contains "application/problem+json"
jsonpath "$.status" == 400
jsonpath "$.code" == "malformed_request_body"
jsonpath "$.retryable" == false
```

(Hurl spells a raw request body as a triple-backtick block; it is written above with single
backticks only so this plan's own Markdown fence does not terminate early. Use Hurl's real
triple-backtick syntax in the `.hurl` file.)

Where `en`'s contract deliberately uses a different error type, **assert that type** rather
than coercing the endpoint to the problem-details convention — the test should make an
exemption visible. Today that applies to the `servant-health` probe body; after
`docs/plans/67-...` it will also apply to `RelayPageError`.

Acceptance: `just hurl` green; every asserted `code` also appears in `en`'s error catalog
(cross-check against `en-servant/test/Main.hs`'s error-model table), so the suite and the
in-process tests agree about the vocabulary.

### Milestone 4 — Writes and the perimeter, both opt-in

Scope: `relationships.hurl` and `perimeter/perimeter.hurl`, neither in the default run list.

**`relationships.hurl`** proves a write is visible through a subsequent **public read** —
never by querying the database behind the service. Copy the shape of `just test-server`,
including its delete-first step, which is what makes the flow idempotent across re-runs:

```hurl
# Delete first so a re-run starts from a known state.
POST {{base_url}}/v1/relationships/delete
Authorization: Bearer {{api_key}}
Content-Type: application/json
{ "tuples": [ ... ] }
HTTP 200

# Write, and capture the consistency token the response returns.
POST {{base_url}}/v1/relationships
Authorization: Bearer {{api_key}}
Content-Type: application/json
{ "tuples": [ ... ] }
HTTP 200
[Captures]
token: jsonpath "$.token"

# Read at that token. This asserts en's actual consistency contract:
# a read supplying a write's token is guaranteed to observe that write.
POST {{base_url}}/v1/check
Authorization: Bearer {{api_key}}
Content-Type: application/json
{ "consistency": {"mode": "atLeastAsFresh", "token": "{{token}}"}, ... }
HTTP 200
[Asserts]
jsonpath "$.decision.result" == "allowed"
```

**Do not** reach for `retry:` here (see Surprises & Discoveries). `en` is not an eventually
consistent read model; supplying the token is the contract, and a retry would hide a real
regression in token handling behind a delay. Reserve `retry:` for a genuinely asynchronous
surface — the `watch` changelog is the one candidate in `en`, and only if a block needs to
observe a change appear.

Give the file distinct fixture identities from anything else that might run in parallel, and
document in the `README.md` whether re-running needs cleanup.

**`perimeter/perimeter.hurl`** needs a differently configured server — one with
authentication actually enabled — so it gets its own directory and its own `README.md`
explaining how to start that server. Cover: the public probes answering without credentials;
a missing credential (`401`, `WWW-Authenticate: Bearer`); an invalid credential (`401`); a
valid credential succeeding; and a read-only key on a write path (`403`, code
`permission_denied`). Supply the real credential as a secret, never through the tracked
`vars.env`:

```bash
hurl --test --variables-file vars.env \
  --secret api_key="$EN_API_KEY" \
  perimeter/perimeter.hurl
```

Note the security caveat from the standard: Hurl redacts secrets from its diagnostic logs by
exact matching but **does not alter response bodies** written to stdout, and may keep them in
a JSON report. `en` must never echo a credential in a response — verify that while writing
these blocks, since a suite is a good place to notice it — and CI must treat any Hurl report
artifact as potentially sensitive.

`en` serves no CORS headers today, so the standard's CORS cases have nothing to assert.
Record that in the perimeter `README.md` as a deliberate absence rather than an oversight.

Acceptance: both files pass when invoked explicitly; neither is in `run.sh`'s `hurl --test`
list; both are in its `hurlfmt --check` list; the write flow is idempotent across two
consecutive runs.

### Milestone 5 — CI, orchestration, and the fixture contract

Scope: the CI configuration, the `justfile`, and `en-servant/test/hurl/README.md`.

The runner targets an already-running server, so CI needs an orchestration step around it:
start PostgreSQL, migrate, start `en-server`, **wait for `/health/ready`**, run the suite,
collect the server log, stop everything. Waiting on readiness is what removes the need for
global retries; do not substitute a sleep. `just start-server` already polls a health
endpoint, so the pieces exist.

Do not let the suite's failure be swallowed. `run.sh`'s `set -euo pipefail` and Hurl's
non-zero exit are sufficient on their own — the failure mode to avoid is a CI step that pipes
the output somewhere and loses the status.

Then decide what happens to `just test-server`. It is now a strict subset of
`relationships.hurl`. Removing it is the tidy answer; keeping it as a fast dependency-free
smoke check that needs no Hurl is the conservative one. Either is defensible — **pick one and
record it here**, rather than leaving two overlapping smoke tests with no stated relationship.

Finally, write `en-servant/test/hurl/README.md`. The standard makes it part of the test
contract, and it must state: how to start the server and provision its database (the `just`
targets); **the required fixture cardinality and identities** — the schema must define
`space` with a `viewer` relation and a `view` permission, and the tuple
`space:project-x#viewer@user:alice` is the flow's subject; which files the default runner
executes; which mutate state or need a differently configured server; how secrets are supplied
(`--secret`, never `vars.env`); and whether re-running each opt-in flow is idempotent or needs
cleanup. Those fixture assumptions are currently undocumented and encoded only in
`just test-server`'s shell — writing them down is a real deliverable, not boilerplate.

Acceptance: a fresh checkout can run the suite by following `README.md` alone; CI fails when
a `.hurl` assertion fails (prove it by breaking one deliberately and watching the pipeline go
red); the `just test-server` decision is recorded in the Decision Log.


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/en` inside the nix development shell.

```bash
cd /Users/shinzui/Keikaku/bokuno/en
just process-up
just run-migrations
just start-server &
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/health/ready   # 200
```

After Milestone 1's flake change, re-enter the shell and confirm the tool:

```bash
hurl --version
hurlfmt --version
```

Run the suite, and run one file at a time while writing it:

```bash
just hurl
hurl --test --variables-file en-servant/test/hurl/vars.env en-servant/test/hurl/checks.hurl
```

When a block fails, `--verbose` shows the actual response beside the assertion:

```bash
hurl --test --verbose --variables-file en-servant/test/hurl/vars.env \
  en-servant/test/hurl/checks.hurl
```

The opt-in files are invoked explicitly, never through `just hurl`:

```bash
cd en-servant/test/hurl
hurl --test --variables-file vars.env relationships.hurl
hurl --test --variables-file vars.env --secret api_key="$EN_API_KEY" perimeter/perimeter.hurl
```

Cross-check the codes the suite asserts against `en`'s own error-model table, so the two
cannot drift:

```bash
grep -o '"\$\.code" == "[a-z_]*"' en-servant/test/hurl/*.hurl | sort -u
grep -n "unknown_relation\|malformed_request_body\|not_found" en-servant/test/Main.hs | head
```

Every commit carries all three trailers:

```text
test(en-servant): black-box the read surface with Hurl

Add the resource-family suite, its runner, and a just target. The default
run is read-only and targets an already-running server; writes and the
authentication perimeter are opt-in files.

MasterPlan: docs/masterplans/11-bring-en-into-conformance-with-the-haskell-jitsurei-pattern-catalog.md
ExecPlan: docs/plans/66-add-a-hurl-black-box-api-suite-for-en-server.md
Intention: intention_01m0xaavwqeznrgzs3j67m0q21
```


## Validation and Acceptance

### The suite runs and is honest about failure

```bash
just hurl
```

Expected: every listed file `Success`, and a summary line reporting `Succeeded files: N
(100.0%)`.

Then **prove it can fail**, because a green suite you have never seen go red is not evidence.
Change one assertion to something false — `jsonpath "$.decision.result" == "denied"` on a
block that returns `allowed` — and run again. Expected: that file reports `Failure`, the
output shows the actual value beside the expected one, and `just hurl` exits non-zero.
Restore the assertion and paste the failure into Surprises & Discoveries.

### It tests the packaged server, not a test harness

This is the property that justifies the whole plan, so verify it directly rather than
inferring it. Stop `en-server` and run `just hurl`. Expected: every file fails with a
connection error, not with an assertion failure. If anything passes with the server down, the
suite is not talking to the server.

Then start the server **without** authentication configured and run
`perimeter/perimeter.hurl`. Expected: the missing-credential case fails, because the server
is not enforcing what the perimeter suite asserts. That failure is the suite correctly
noticing a configuration difference, which is exactly what a perimeter suite is for.

### The default suite is read-only

Run `just hurl` twice against a fresh database, then inspect the tuple store through the
public read endpoint. Expected: identical results both times, and no tuple present that the
suite created — because the default files never write. This is the safety property that lets
the suite be pointed at a shared environment.

Then run the opt-in write flow twice in a row:

```bash
cd en-servant/test/hurl
hurl --test --variables-file vars.env relationships.hurl
hurl --test --variables-file vars.env relationships.hurl
```

Expected: both green. The delete-first step is what makes the second run start from a known
state; if the second run fails, the flow is not idempotent and the `README.md`'s cleanup
guidance is wrong.

### Files really are independent

```bash
cd en-servant/test/hurl
for f in health.hurl openapi.hurl checks.hurl lookups.hurl expands.hurl schema.hurl; do
  hurl --test --variables-file vars.env "$f" || echo "FAILED ALONE: $f"
done
```

Expected: no output from the loop. A file that only passes when run after another has a
hidden dependency, which parallel `--test` execution will surface as a flake later.

### Errors assert codes, not prose

```bash
grep -c 'jsonpath "\$\.detail"' en-servant/test/hurl/*.hurl
```

Expected: zero matches for equality assertions on `$.detail`. `detail` is request-specific
prose the standard explicitly permits changing; asserting it produces a suite that breaks on
wording edits and gives false confidence about contract coverage. Asserting `$.detail exists`
is fine; asserting its text is not.

### No credential appears in any response

```bash
hurl --test --verbose --variables-file vars.env \
  --secret api_key="$EN_API_KEY" perimeter/perimeter.hurl 2>&1 | grep -c "$EN_API_KEY"
```

Expected: zero. Hurl redacts secrets from its own diagnostics, but not from response bodies —
so a non-zero count means `en` is echoing a credential back, which is a real finding worth
its own fix regardless of this plan.


## Idempotence and Recovery

The default suite is read-only, so running it any number of times against any environment
changes nothing. That is the main safety property of the layout, and it is why the write flow
is a separate opt-in file.

The opt-in `relationships.hurl` mutates the tuple store. It begins with a delete of the exact
tuple it is about to write, so re-running converges rather than accumulating — but it does
operate on a real database. Point it at a development or CI database, and never at a shared
environment whose authorization data matters.

Everything else is an ordinary file edit. Nothing here changes Haskell source, adds a
migration, or alters the API. `git checkout -- .` discards uncommitted work.

Three recovery notes.

**If `hurl` is not found after Milestone 1**, the dev shell has not been re-entered — the tool
comes from nix, so an existing shell will not have it. Exit and re-enter rather than
installing it globally, which is exactly what the standard forbids.

**If the suite fails wholesale after passing**, check the server before the assertions:
`curl /health/ready`, then the server's log. A suite that talks to a real process fails for
real-process reasons — the database went away, the port is taken, migrations were not applied
— far more often than for assertion reasons.

**If a file passes alone and fails under `--test`**, it has a hidden cross-file dependency.
`--jobs 1` will make it pass and is the wrong fix; the standard reserves that flag for
genuinely unavoidable shared state. Find the dependency and remove it.


## Interfaces and Dependencies

### Tools

**Hurl and hurlfmt 8.0.1**, from the nix development shell. Added via
`haskellProject.extraDevPackages` in `./flake.module.nix` per `nix/haskell.nix`'s own
instruction, not by editing that file's list directly. The standard's examples were checked
with 8.0.1 on 2026-07-30; the shell resolves that same version, and upstream still marks
8.0.1 as the latest release as of 2026-08-25. The suite uses no syntax newer than 8.0.1.

**No Haskell dependency is added.** Hurl is an external test executable; no module imports
it, and ordinary consumers of `en`'s libraries do not need a test client. This is the only
child plan in its initiative that does not have to prove a cabal cohort against
[ADR 2](../adr/0002-crypton-1-1-binds-en-s-dependency-closure-through-a-biscuit-haskell-fork.md).

### Files that must exist at the end

```text
en-servant/test/hurl/README.md              # the fixture contract; part of the test contract
en-servant/test/hurl/vars.env               # non-secret defaults only: base_url
en-servant/test/hurl/run.sh                 # hurlfmt --check on ALL files; hurl --test on safe ones
en-servant/test/hurl/health.hurl            # probes, unauthenticated
en-servant/test/hurl/openapi.hurl           # the served document
en-servant/test/hurl/checks.hurl            # check and batch-check, plus their failures
en-servant/test/hurl/lookups.hurl           # lookup and lookup-subjects, plus their failures
en-servant/test/hurl/expands.hurl           # expand, plus its failures
en-servant/test/hurl/schema.hurl            # the schema lifecycle endpoints
en-servant/test/hurl/relationships.hurl     # OPT-IN: writes; delete-first for idempotence
en-servant/test/hurl/perimeter/README.md    # how to start the differently configured server
en-servant/test/hurl/perimeter/perimeter.hurl  # OPT-IN: authentication boundaries
```

And one `just` target, `hurl`, in the `testing` group.

### What this plan must not do

**Do not move domain combinatorics into the suite.** `en-core`'s and `en-servant`'s test
suites own the evaluation algebra, the caveat evaluator, cursor validation, and the error
model table. This suite proves the wire and the process. A `.hurl` file that grows a matrix
of permission shapes is testing the wrong layer, more slowly and less precisely.

**Do not snapshot large JSON.** `en` already has golden wire tests in Haskell and an OpenAPI
drift check; both are better at that job than an assertion block.

**Do not query the database to prove a write.** The standard is explicit and the reason is
that a black-box test proving a write through a private channel proves nothing about the
public contract. Read it back through the API.

**Do not change any Haskell source.** If a `.hurl` assertion cannot be satisfied because `en`
behaves differently than expected, that is a finding: record it in Surprises & Discoveries and
decide whether the contract or the expectation is wrong. Do not quietly adjust `en` to match a
test written from a plan.


Revision note (2026-08-25): Milestone 3 now names the live-process failures the standard demo
host can exercise and explicitly leaves the alternate-schema resolution-budget case in the
deterministic Haskell suite. Implementation showed that forcing the 422 in Hurl would violate
the plan's own rule against moving domain combinatorics into the black-box layer.
