---
id: 38
slug: validate-configuration-and-persist-datastore-identity
title: "Validate configuration and persist datastore identity"
kind: exec-plan
created_at: 2026-07-07T15:24:43Z
master_plan: "docs/masterplans/6-production-harden-the-en-service.md"
---

# Validate configuration and persist datastore identity

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Every en consistency token embeds a *datastore id* so that a token minted by one en
deployment is rejected by another (`validateTokenMetadata` in
`en-postgres/src/En/Postgres/Revision.hs` fails with "token datastore does not match
this en datastore"). But `en-server/app/Main.hs` hardcodes
`DatastoreId "en-server"` — so *every* deployment claims the same identity, and two
en-servers pointed at different databases mint mutually acceptable tokens whose embedded
PostgreSQL snapshots are meaningless in the other database. That silently defeats the
cross-datastore guard (finding A6, MED, of
`docs/reviews/2026-07-07-architecture-performance-review.md`). The same finding notes
`EN_GC_WINDOW` is passed to SQL as raw text with no validation (a typo like `24 hoursss`
surfaces as a runtime `StoreError` on the first read, not at startup), and that after a
dump/restore the xid8 counter of a new cluster restarts, making old tokens validate
against nonsense — with nothing detecting it. Finding A7 adds that the client-supplied
lookup deadline is unbounded upward (`deadlineMillis: 86400000` pins a worker for a
day), the 3000 ms default is baked into `en-servant/src/En/Servant/API.hs`, and
`maxBatchSize = 1000` is hardcoded in `Main.hs`. Findings A8/A9 are documentation
dishonesty: `en-servant/en-servant.cabal` and `README.md` advertise a
`RequirePermission`/`Authorize` *combinator* when the implementation is a plain handler
helper, and the README claims codd-managed migrations while the dev workflow applies
them with guarded `psql`.

After this change: a migration creates a datastore-metadata table; on first startup
against a database, `en-server` mints a random UUID, persists it there, and every later
startup reads the same id — two deployments can never share an identity, and the ops
docs tie the xid8-restore hazard to a concrete recovery action (rotate the persisted id,
invalidating all old tokens). All environment parsing moves into one validated
`ServerConfig` record that fails fast at startup with a message naming the variable, the
offending value, and the expected form — including PostgreSQL-checked `EN_GC_WINDOW`
syntax. The lookup-deadline default and maximum clamp and the batch-size cap become
configuration threaded into the en-servant handlers. And the package/README wording is
corrected to match what the code does. This is child EP-38 of
`docs/masterplans/6-production-harden-the-en-service.md`, owner of the shared
`ServerConfig` record the sibling plans read their knobs through.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1 (2026-07-08): `en-server/app/Config.hs` with `ServerConfig` and
  `loadServerConfig`; all env parsing in `Main.hs`, `Middleware.hs`, and
  `Maintenance.hs` migrated onto it (23 variables; `Main.hs` has zero `lookupEnv`
  calls); fail-fast messages verified per variable; `EN_GC_WINDOW` validated against
  PostgreSQL at startup. Configuration failures now exit `1` cleanly instead of
  surfacing as an uncaught `IOException` — the wart EP-33 assigned to this plan.
- [x] M2 (2026-07-08): migration `20260709023019_datastore-metadata.sql` creating
  `en_datastore_metadata`; Justfile guard added; `En.Postgres.Datastore` with
  `resolveDatastoreIdSession`; `Main.hs` mints/reads the persisted id; `uuid` was
  already a dependency (EP-36 added it for request ids).
- [x] M2 (2026-07-08): restart/reuse behavior verified (same id across restarts; a
  second database mints a different id; a token minted under another identity is
  rejected with `invalid_consistency_token`). Missing-migration startup failure and the
  rotation drill also verified.
- [x] M3 (2026-07-08): `Env` in `en-servant/src/En/Servant/Seam.hs` gains
  `deadlineDefaultMillis`/`deadlineMaxMillis`; `lookupDeadline` in
  `en-servant/src/En/Servant/API.hs` clamps; `EN_LOOKUP_DEADLINE_DEFAULT_MS`,
  `EN_LOOKUP_DEADLINE_MAX_MS`, `EN_MAX_BATCH_SIZE` wired; en-servant clamp test added
  and mutation-checked. `en-example` updated for the new `Env` fields.
- [x] M4 (2026-07-08): `en-servant/en-servant.cabal` description and `README.md` rows
  corrected (helper, not combinator); migration-workflow wording made honest; xid8
  restore hazard + id-rotation runbook documented in
  `docs/user/service-and-operations.md`; full configuration reference updated and
  cross-checked against the source.
- [x] Final validation transcript recorded in Outcomes.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **Warnings had to move with the parsers.** `loadAuthConfig` printed
  `WARNING: authentication is DISABLED` as a side effect of parsing. Once parsing became
  pure, that had nowhere to go — and printing it from `Config.hs` would have been worse:
  a configuration that later fails to parse would first emit advice about a setting that
  never takes effect. `loadServerConfig` returns `(ServerConfig, [Text])` and `Main`
  prints the warnings only after the whole config is accepted.

- **The monomorphism restriction bites `where`-bound partial applications.** Writing
  `withDefault = withDefaultIn environment` in a `where` clause monomorphizes it to the
  first use site, so `EN_PORT`'s `Parser Int` poisoned `EN_GC_WINDOW`'s `Parser String`.
  Each such binding needs an explicit `forall a.` signature. Cost one compile cycle;
  worth knowing before writing the next parser module.

- **`Pool.UsageError`'s `Show` instance nests four constructors around PostgreSQL's own
  sentence.** The first `EN_GC_WINDOW` failure read
  `SessionUsageError (StatementSessionError 1 0 "SELECT ($1::interval) …" [...] True
  (ServerStatementError (ServerError "22007" "invalid input syntax for type interval:
  \"24 hoursss\"" …)))`. `Hasql.Errors.toDetailedText` renders the useful part;
  `renderUsageError` in `Main.hs` dispatches on the three `UsageError` constructors so
  an acquisition timeout says so in prose. Any plan surfacing a hasql error to an
  operator should do the same rather than `show`.

- **The plan's clamp test would have passed vacuously.** M3 proposed asserting that a
  lookup with `deadlineMaxMillis = 0` returns a truncated page. It does not:
  `pageLookup` in `en-core/src/En/Lookup.hs` reports `LookupTruncated` only when
  `hasMore && not hasBudget`, and returns `LookupExhausted` whenever the result set fits
  the limit — *regardless of the budget*. The fixture's page fit, so the first version of
  the test failed. The working test sets `limit = 1` against a subject with two auditable
  spaces, which forces `hasMore`; the two runs then differ only in the budget, and the
  states differ (`truncated` versus `hasMore`). Mutation-checked: replacing
  `min env.deadlineMaxMillis (max 0 requested)` with `max 0 requested` fails it.

- **`uuid` was already a dependency.** The plan's Interfaces section says to add it; EP-36
  had already done so for request ids. No cabal change was needed.

- **`Statement.preparable` takes `Text`.** Same trap EP-37 hit; noted again because
  `Config.hs`'s interval-validation statement is the third place it appears.

- **A second `Env` consumer existed outside the plan's list.**
  `en-example/src/En/Example/Host.hs` constructs `Env` and broke on the two new fields.
  The plan named only `en-server/app/Main.hs` and `en-servant/test/Main.hs`. Anything
  adding a field to `Env` should grep the workspace, not the plan.


## Decision Log

Record every decision made while working on the plan.

- Decision: Persist datastore identity in a single-row table
  `en_datastore_metadata`, minted as a random UUIDv4 on first startup via
  `INSERT … ON CONFLICT DO NOTHING` followed by `SELECT`.
  Rationale: The identity must live *with the data it identifies* — that is the whole
  point (SpiceDB does the same with its datastore metadata). Minting in the server
  rather than in the migration keeps the migration pure DDL (codd-friendly,
  deterministic, no extension dependency for `gen_random_uuid()`); the
  insert-then-select dance makes two servers racing at first startup converge on one id
  (the loser's insert is a no-op and both read the winner's row). A
  `singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton)` column enforces
  exactly-one-row at the schema level.
  Date: 2026-07-07
- Decision: No environment override for the datastore id.
  Rationale: An `EN_DATASTORE_ID` override would reintroduce finding A6 the first time
  two deployments copy one systemd unit. The only supported way to change identity is
  deleting the metadata row (the documented restore runbook), which is deliberate,
  audited, and invalidates outstanding tokens — the safe failure mode.
  Date: 2026-07-07
- Decision: Validate `EN_GC_WINDOW` by asking PostgreSQL
  (`SELECT ($1::interval) > '0'::interval` at startup) rather than parsing interval
  syntax in Haskell.
  Rationale: The value's only consumer is PostgreSQL (`… now() - $1::interval` in
  `oldestRetainedXidStatement`), and PostgreSQL's interval grammar is large; a Haskell
  reimplementation would drift. One startup round trip gives exact-authority validation
  plus a positivity check (a zero/negative window would immediately GC every token).
  This runs after the database connection exists, which is still "fail fast": before
  the port binds and before any request is served.
  Date: 2026-07-07
- Decision: `ServerConfig` lives in `en-server/app/Config.hs` (application layer), not
  in a library package, and absorbs sibling plans' variables as they land.
  Rationale: Restated from the master plan's Integration Points: EP-38 defines the
  shared ServerConfig-style record; EP-33 (auth/rate-limit/TLS vars), EP-34 (pool
  vars), EP-36, and EP-37 (maintenance vars) read their knobs through it when it
  exists, or add individually-parsed vars that EP-38 absorbs. The record is
  application configuration — en-core/en-servant must stay usable embedded with no env
  coupling, so the library packages receive plain typed values (fields on `Env`), never
  env names.
  Date: 2026-07-07
- Decision: Deadline policy: default 3000 ms (`EN_LOOKUP_DEADLINE_DEFAULT_MS`), maximum
  clamp 30000 ms (`EN_LOOKUP_DEADLINE_MAX_MS`); client requests above the max are
  silently clamped to the max, not rejected.
  Rationale: The review's A7 complaint is a *hostage* problem — an unbounded
  client-supplied budget holds a worker. Clamping preserves every well-behaved client
  while capping abuse; rejecting would break clients that ask for "as long as you'll
  give me", a reasonable request. 3000 ms preserves today's behavior as the default
  (plan 16 intended it configurable; the constant currently sits at
  `API.hs` line ~401). The default must be `<=` the max — validated in
  `loadServerConfig`. Check/batch-check/expand deadline budgets (also raised by A7)
  are engine work owned by `docs/masterplans/7-fix-the-en-evaluation-engine.md`
  (`docs/plans/44-make-evaluation-budgets-configurable-and-trim-hot-path-overhead.md`)
  and are out of scope here.
  Date: 2026-07-07
- Decision: Fix the overselling wording (A8) rather than implement a type-level
  combinator.
  Rationale: The review itself calls the helper design defensible; the untracked plan
  `docs/plans/27-per-action-authorization-for-agent-tool-and-sink-dispatch.md` suggests
  the combinator question is being handled elsewhere. Honest packaging is the cheap,
  correct fix: describe `requirePermission` as a fail-closed `Handler` helper invoked
  by call discipline.
  Date: 2026-07-07
- Decision: For A9, document the actual migration workflow instead of adding a codd
  invocation.
  Rationale: The dev shell does not provide a codd binary; the migrations are
  codd-compatible plain SQL applied by guarded `psql` in `Justfile:run-migrations`, and
  `en-server` intentionally does not verify migration state at startup (the M2 metadata
  read now *implicitly* verifies the new table exists, failing with a pointer to the
  migrations directory — a strict improvement). The README/docs must say exactly this
  rather than implying a managed codd pipeline that does not exist in-tree.
  Date: 2026-07-07

- Decision: `loadServerConfig` returns `Either Text (ServerConfig, [Text])`, and every
  configuration failure exits `1` through `configFailure` instead of `fail`.
  Rationale: EP-33 recorded that config errors surfaced as
  `en-server: Uncaught exception … user error (…)` wrapped around an otherwise good
  message, and assigned the fix here. `fail` in `IO` throws an `IOException`; nothing is
  bound or opened at that point, so there is nothing to unwind and an exception buys
  nothing. Warnings ride along in the tuple rather than being printed during parsing, so
  a config that later fails never first advises the operator about a setting that will
  not take effect.
  Date: 2026-07-08

- Decision: Absorb EP-33's and EP-37's parsers into `Config.hs`, leaving their *types*
  and behavior in `Middleware.hs` and `Maintenance.hs`.
  Rationale: The master plan promised one record the siblings read their knobs through.
  Moving `loadAuthConfig`, `loadRateLimitConfig`, and `loadMaintenanceConfig` into
  `Config.hs` gives one entry point, one error style, and one place to audit against the
  documented configuration reference — `knownVariables` is exhaustive and the docs sweep
  checks it. The types stay with their consumers, so `Config` imports `Middleware` and
  `Maintenance` and neither imports `Config`. Recorded alternative: leave each loader in
  place and have `loadServerConfig` call them (rejected — three error styles, and `fail`
  survives in two of them).
  Date: 2026-07-08

- Decision: Parse from a snapshot `Map String String` rather than calling `lookupEnv`
  inside the parsers.
  Rationale: It makes `parseServerConfig` pure and therefore testable without a process,
  it forces `knownVariables` to be exhaustive (which the docs sweep then checks against
  the source), and it removes any question of the environment changing mid-parse. The
  distinction between an absent variable and an empty one survives, because
  `Map.lookup` returns `Just ""` for `EN_PORT=`.
  Date: 2026-07-08

- Decision: `en-server` renders `Pool.UsageError` through `Hasql.Errors.toDetailedText`
  rather than `show`.
  Rationale: `show` nests four hasql constructors around the one sentence PostgreSQL
  wrote, which is the sentence the operator needs. An acquisition timeout gets prose of
  its own, since hasql has no message for it.
  Date: 2026-07-08


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

Completed 2026-07-08 in one commit. All four milestones landed as specified; the only
deviations were corrections (the clamp test as written could not fail — see Surprises).

**Against the original purpose.** Two en deployments can no longer mint interchangeable
tokens: identity is minted once per database and lives in it. All 23 environment
variables are validated before the port binds, each failure naming its variable and
value, and the process exits cleanly rather than throwing. The lookup deadline has a
server-owned ceiling and the batch cap is configurable. The package descriptions say
what the code does.

### Validation transcript

Configuration validation (M1). Each aborts before binding the port, exit `1`:

```text
EN_PORT=abc                    en-server: Invalid EN_PORT=abc: expected an integer in 1..65535
EN_PORT=70000                  en-server: Invalid EN_PORT=70000: expected an integer in 1..65535
EN_MAX_BATCH_SIZE=0            en-server: Invalid EN_MAX_BATCH_SIZE=0: expected a positive integer
EN_LOOKUP_DEADLINE_MAX_MS=100  en-server: Invalid EN_LOOKUP_DEADLINE_MAX_MS=100: it is below
                               EN_LOOKUP_DEADLINE_DEFAULT_MS=3000. Every lookup would be clamped
                               below its own default.
EN_RATE_LIMIT_RPS=-1           en-server: Invalid EN_RATE_LIMIT_RPS=-1: expected a non-negative number
EN_TLS_CERT_FILE=/tmp/x        en-server: Invalid TLS configuration: set both EN_TLS_CERT_FILE and
                               EN_TLS_KEY_FILE, or neither.
(unset EN_DATABASE_URL)        en-server: Missing EN_DATABASE_URL: a PostgreSQL connection string, …
```

`EN_GC_WINDOW`, adjudicated by PostgreSQL after the database is reachable and before the
port binds:

```text
$ EN_GC_WINDOW='24 hoursss' en-server
en-server: Invalid EN_GC_WINDOW=24 hoursss: PostgreSQL rejected it: …
  message: invalid input syntax for type interval: "24 hoursss"
Expected a positive PostgreSQL interval, e.g. '24 hours' or '7 days'.
$ echo $?
1

$ EN_GC_WINDOW='0 seconds' en-server
en-server: Invalid EN_GC_WINDOW=0 seconds: it is not a positive interval
```

Identity lifecycle (M2). Two consecutive starts against one database, then a second
database:

```text
first  start: Datastore id: 76efe58d-24e3-4ee2-8242-99050e3c348a
second start: Datastore id: 76efe58d-24e3-4ee2-8242-99050e3c348a
in database : Datastore id: 76efe58d-24e3-4ee2-8242-99050e3c348a
row count   : 1

database one: 76efe58d-24e3-4ee2-8242-99050e3c348a
database two: f10d966e-7857-49d2-8034-5b1594e8c671
token minted on database two: en1.f10d966e-7857-49d2-8…
```

Replaying database two's token against database one — the guard finding A6 said was
defeated:

```text
{"code":"invalid_consistency_token","message":"token datastore does not match this en datastore","retryable":false}
status=400
```

…while a locally minted token still resolves (`just test-server` → `allowed`). Startup
against a database missing the migration, with the port never bound:

```text
  message: relation "en_datastore_metadata" does not exist
Is the en_datastore_metadata migration from db/migrations applied?
exit=1
not bound (good)
```

Rotation drill (the restore runbook):

```text
before rotation: 76efe58d-24e3-4ee2-8242-99050e3c348a
DELETE 1
after rotation : 0c9c482f-6b7f-49d4-b106-c4c65a3ae6e5
=> identity rotated
```

Deadlines and batch cap (M3), against a running server:

```text
$ time curl … -d '{… "deadlineMillis": 86400000}'   # /v1/lookup
lookup status=200
0.027 total                                         # not a day of budget

$ curl … /v1/batch-check  (2 pairs, EN_MAX_BATCH_SIZE=1)
{"code":"batch_too_large","message":"batch exceeds the maximum of 1 pairs","retryable":false}
status=400
```

The en-servant suite's clamp test asserts the same property at the handler layer, and
was mutation-checked (removing `min env.deadlineMaxMillis` fails it).

Documentation sweep (M4):

```text
$ rg -niE 'combinator' README.md en-servant/en-servant.cabal
(clean)
$ every EN_* read by en-server/app, checked against the docs table
source variables: 23
(all documented)
$ grep -c 'en_datastore_metadata|xid8' docs/user/service-and-operations.md
6
$ grep -c lookupEnv en-server/app/Main.hs
0
$ grep -rn '"en-server"' en-server/app/
(none)
```

Regressions (acceptance 6): `cabal build all` clean; `cabal test en-core`,
`cabal test en-postgres`, `cabal test en-servant` all PASS; `just start-and-test`
passes, and the supervised server logs its identity, deadlines, and batch cap.

### Gaps

- **`parseServerConfig` is pure and testable, but has no tests.** The validation table
  was exercised by running the binary. A unit test over `Map String String` would be
  cheap and would catch a regression in a parser without a database. Not added: this
  plan had no test suite for `en-server`, and adding one is a larger change than the
  finding warranted.
- **Configuration reports only the first error.** An operator with three bad variables
  fixes them one restart at a time. The plan explicitly chose this ("exhaustive
  multi-error reporting is not worth the machinery here") and the choice still looks
  right, but it is a real papercut.
- **`EN_SCHEMA_PATH` file reading stays in `Main.hs`,** so a missing schema file is
  reported after the config parse rather than with it. It exits cleanly via
  `configFailure`, so the behavior is right; only the locality is odd.
- **The docs sweep is a shell command, not a test.** `knownVariables` and the docs table
  can drift, and nothing in CI notices.
- **Identity rotation is a manual runbook step.** Nothing detects that a database was
  restored into a fresh cluster; the operator must remember. Detecting it would mean
  persisting a cluster fingerprint (e.g. `pg_control_system()`'s system identifier) next
  to the datastore id and comparing at startup — a natural follow-up, and strictly
  better than a runbook, but out of scope here.

### Lessons

The plan's most valuable line was an aside: "with `deadlineMaxMillis = 0` … returns a
page whose state is `LookupTruncatedWire`-shaped rather than running unbounded". It was
wrong — `pageLookup` reports `exhausted` when the result set fits the limit, whatever the
budget — but it was *specific enough to be wrong*, so writing it exposed the gap. A vaguer
instruction ("assert the clamp works") would have produced a test that passed for the
wrong reason. The same pattern appears in EP-37, where the plan's falsifiable EXPLAIN
prediction is what caught the useless index.

Second: the plan enumerated the files that construct `Env` and missed one
(`en-example`). Plans should name the *property* to re-establish ("every `Env`
construction site compiles") rather than a list that the compiler will produce anyway.


## Context and Orientation

en is a Haskell workspace at `/Users/shinzui/Keikaku/bokuno/en` (cabal, GHC 9.12.4).
Read these before editing:

- `en-server/app/Main.hs` — the whole file. Today it parses env vars inline with three
  helper styles (`requiredEnv` for `EN_DATABASE_URL`; `parsePort`, which *silently falls
  back to 8080* on garbage — a validation bug this plan fixes; and
  `optionalNonNegativeIntEnv` for the three cache knobs). It hardcodes
  `DatastoreId "en-server"` in the `ConsistencyConfig` it builds, passes `EN_GC_WINDOW`
  (default `"24 hours"`) as raw `Text` into that config, and hardcodes
  `maxBatchSize = 1000` in the servant `Env`.
- `en-core/src/En/Revision.hs` — `DatastoreId` and `SchemaHash` are `Text` newtypes;
  `ConsistencyToken` is opaque `Text`.
- `en-postgres/src/En/Postgres/Revision.hs` — `encodeToken` embeds the datastore id,
  schema hash, revision (a rendered `pg_snapshot`, i.e. xid8 numbers), and optional
  expiry into every token; `validateTokenMetadata` rejects tokens whose datastore id or
  schema hash differ from the active config, whose expiry passed, or whose snapshot
  `xmax` is at or below the GC horizon. This is the machinery persisted identity makes
  trustworthy: distinct databases ⇒ distinct ids ⇒ cross-database tokens fail the first
  check.
- `en-servant/src/En/Servant/Seam.hs` — the `Env es` record (`runPorts`, `graph`,
  `checkOperation`, `lookupWithDeadlineOperation`, `maxBatchSize`) that `Main.hs`
  constructs and handlers read. This plan adds two fields to it.
- `en-servant/src/En/Servant/API.hs` — `lookupDeadline` (around line 397) computes the
  lookup time budget: `max 0 (maybe 3000 id maybeDeadlineMillis)` nanoseconds-converted
  against a monotonic clock. The `3000` literal and the missing upper clamp are the A7
  targets. `batchCheckHandler` reads `env.maxBatchSize`.
- `en-servant/test/Main.hs` — constructs `Env{…}` records directly (three handler
  harnesses); adding `Env` fields requires updating these constructions.
- `en-migrations/db/migrations/` — timestamped plain-SQL migrations;
  `just make-migration <name>` mints a file, `just run-migrations` applies each with a
  `to_regclass` guard. EP-37
  (`docs/plans/37-schedule-background-maintenance-for-reaping-and-transaction-pruning.md`)
  adds its own migration file; per the master plan each plan owns its file and must not
  edit the other's.
- `README.md` (packages table: the `en-servant` row) and `en-servant/en-servant.cabal`
  (`description:` block) — the A8 wording. `docs/user/service-and-operations.md` — the
  configuration reference and operations guidance this plan extends;
  `docs/user/README.md` already says "helper", the honest phrasing to converge on.

One term of art: **xid8** is PostgreSQL's 64-bit transaction id — a 32-bit epoch plus
the 32-bit xid counter — so it never wraps *within one cluster's lifetime*. But the
counter is per-cluster state: `pg_dump | pg_restore` into a fresh cluster restarts it
near zero. en tokens embed xid8-based snapshots, so after such a restore an old token's
`xmax` may compare "fresh" against a young counter (validating when it should not) or
"ancient" (rejected confusingly). Nothing can detect this *within* one identity — which
is why the runbook ties restores to identity rotation: delete the metadata row, the
next startup mints a new id, and every pre-restore token fails the datastore-id check
with a clear error instead of validating against a meaningless counter.

Master-plan integration restated: `en-server/app/Main.hs` is shared with EP-33/34/36/37
— keep the `Main.hs` diff cohesive (the config-load block plus the identity block).
`ServerConfig` is this plan's deliverable that siblings consume; when this plan lands
*after* any sibling, fold that sibling's env parsing into `loadServerConfig` unchanged
(same names, same defaults, recorded in Progress). The datastore-metadata migration is
this plan's own file, separate from EP-37's index migration.


## Plan of Work

Four milestones: the config record (M1), persisted identity (M2), deadline/batch
configurability (M3), documentation honesty (M4). M1 before M2 because identity
resolution wants the validated database URL and GC window in hand.


### Milestone 1: A validated ServerConfig

Scope: one module owns every environment variable; startup errors become precise. At
the end `Main.hs` contains no `lookupEnv` calls of its own.

Create `en-server/app/Config.hs` (add `Config` to `other-modules` in
`en-server/en-server.cabal`):

```haskell
-- en-server/app/Config.hs
data ServerConfig = ServerConfig
    { databaseUrl :: !Text
    , port :: !Int                       -- EN_PORT, 1..65535, default 8080
    , gcWindow :: !Text                  -- EN_GC_WINDOW, default "24 hours"; DB-validated
    , schemaPath :: !(Maybe FilePath)    -- EN_SCHEMA_PATH (loader stays in Main.hs)
    , optimizedRevisionTtlMs :: !Int     -- EN_OPTIMIZED_REVISION_CACHE_TTL_MS, >= 0, default 0
    , tupleReadMaxEntries :: !Int        -- EN_TUPLE_READ_CACHE_MAX_ENTRIES, >= 0, default 0
    , decisionMaxEntries :: !Int         -- EN_DECISION_CACHE_MAX_ENTRIES, >= 0, default 0
    , maxBatchSize :: !Int               -- EN_MAX_BATCH_SIZE, >= 1, default 1000
    , deadlineDefaultMillis :: !Int      -- EN_LOOKUP_DEADLINE_DEFAULT_MS, >= 1, default 3000
    , deadlineMaxMillis :: !Int          -- EN_LOOKUP_DEADLINE_MAX_MS, >= default, default 30000
    }

loadServerConfig :: IO ServerConfig
```

(If EP-33/34/37 have landed, extend the record with their fields — auth, rate limit,
TLS, pool, maintenance — moving their parsers here verbatim; the variable names and
defaults in those plans are contracts.) Parsing rules: every failure calls `fail` with
the pattern `Invalid <VAR>=<value>: expected <form>` or `Missing <VAR>: <hint>`;
`parsePort`'s silent fallback is replaced by real validation (garbage or out-of-range ⇒
startup failure — a behavior change to document in M4); collect the *first* failure
eagerly (simple `IO` sequencing is fine; exhaustive multi-error reporting is not worth
the machinery here). Cross-field check: `deadlineDefaultMillis <= deadlineMaxMillis`,
else fail naming both variables.

`EN_GC_WINDOW` validation cannot happen in pure parsing (PostgreSQL owns the grammar);
expose it as a second step, called by `Main.hs` right after database connectivity is
established (after EP-34's pool ping if landed, else after `Connection.acquire`):

```haskell
validateGcWindow :: (forall a. Session a -> IO (Either SessionError a)) -> Text -> IO ()
-- runs: SELECT ($1::interval) > '0'::interval
-- Left / Right False => fail "Invalid EN_GC_WINDOW=…: not a positive PostgreSQL interval …"
```

`Main.hs` then destructures `ServerConfig` where it previously read variables; the
existing `requiredEnv`/`optionalNonNegativeIntEnv` helpers move into `Config.hs`.

Acceptance: table-driven manual checks — each of `EN_PORT=abc`, `EN_PORT=70000`,
`EN_MAX_BATCH_SIZE=0`, `EN_LOOKUP_DEADLINE_MAX_MS=100` with default 3000, and
`EN_GC_WINDOW='24 hoursss'` aborts startup non-zero with a message naming exactly that
variable and value; the defaults path starts and serves as before.


### Milestone 2: Persisted datastore identity

Scope: identity minted once per database, hardcode removed. At the end two databases
imply two identities and the hardcoded string is gone.

Migration — create and fill (do not edit EP-37's file):

```bash
just make-migration datastore-metadata
```

```sql
-- en-migrations/db/migrations/<timestamp>_datastore-metadata.sql
CREATE TABLE en_datastore_metadata
  ( singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton)
  , datastore_id text NOT NULL
  , created_at timestamptz NOT NULL DEFAULT now()
  );
```

Add the matching `to_regclass('public.en_datastore_metadata')` guard block to
`run-migrations` in `Justfile`, in the established style.

New module `en-postgres/src/En/Postgres/Datastore.hs` (add to `exposed-modules` in
`en-postgres/en-postgres.cabal`):

```haskell
-- | Resolve this database's persistent datastore identity: insert the caller's
-- freshly minted candidate if no identity exists, then read whichever id won.
resolveDatastoreIdSession :: Text -> Session Text
```

implemented as two statements in one session:
`INSERT INTO en_datastore_metadata (datastore_id) VALUES ($1) ON CONFLICT DO NOTHING`
then `SELECT datastore_id FROM en_datastore_metadata` (single row; if the select finds
no row something is gravely wrong — error out). In `Main.hs`, after connectivity and
`validateGcWindow`:

```haskell
candidate <- Data.UUID.toText <$> Data.UUID.V4.nextRandom
datastoreIdText <- runDbSession (resolveDatastoreIdSession candidate) >>= \case
    Right value -> pure value
    Left err ->
        fail $ "Could not resolve datastore identity (is the en_datastore_metadata \
               \migration from " <> migrationsDir <> " applied?): " <> show err
Text.putStrLn ("Datastore id: " <> datastoreIdText)
let config = ConsistencyConfig { datastoreId = DatastoreId datastoreIdText, … }
```

where `runDbSession` is whatever session runner `Main.hs` has at this point
(`Pool.use pool` after EP-34; `Connection.use connection` before). Add `uuid` to
`en-server`'s `build-depends`. Delete the `DatastoreId "en-server"` literal. Note the
failure message doubles as the A9-adjacent migration-state check the review wished for:
a database missing the new migration now fails loudly at startup with a pointer to the
migrations directory instead of serving with a wrong identity.

Acceptance: first start against a migrated dev database logs `Datastore id: <uuid>`;
restarting logs the *same* uuid; `psql "$PG_CONNECTION_STRING" -tAc "SELECT
datastore_id FROM en_datastore_metadata"` shows it; a token minted before the identity
change (i.e. carrying `en-server` as its id) is rejected on a check with
`invalid_consistency_token` semantics ("token datastore does not match") — which also
demonstrates the documented consequence: **landing this milestone invalidates
previously minted tokens once per deployment**, exactly like a schema change, and the
docs must say so (M4).


### Milestone 3: Configurable deadlines and batch cap

Scope: A7's knobs become configuration flowing `ServerConfig → Env → handler`. At the
end no policy literal remains in `en-servant`.

In `en-servant/src/En/Servant/Seam.hs`, extend the record:

```haskell
data Env es = Env
    { …existing fields…
    , maxBatchSize :: !Int
    , deadlineDefaultMillis :: !Int
    , deadlineMaxMillis :: !Int
    }
```

In `en-servant/src/En/Servant/API.hs`, re-signature the deadline helper to take the
env (it currently takes only the request value) and clamp both directions:

```haskell
lookupDeadline :: (IOE Effectful.:> es) => Env es' -> Maybe Int -> Handler (Lookup.Deadline (Eff es))
-- requested = fromMaybe env.deadlineDefaultMillis maybeDeadlineMillis
-- budgetMs  = min env.deadlineMaxMillis (max 0 requested)
```

and update its one call site in `lookupHandler`. In `en-server/app/Main.hs`, populate
the three fields from `ServerConfig` (`maxBatchSize` loses its `1000` literal). In
`en-servant/test/Main.hs`, add the two new fields to every `Env{…}` construction
(`deadlineDefaultMillis = 3000, deadlineMaxMillis = 30000`), and add a behavioral test
in the file's hand-rolled style: with `deadlineMaxMillis = 0` (an
always-already-expired budget), a lookup request with `deadlineMillis = Just 86400000`
returns a page whose state is `LookupTruncatedWire`-shaped rather than running
unbounded — proving the clamp reaches the engine's deadline mechanism. (The engine
consults the deadline as "has the budget elapsed"; a zero budget makes it report
truncation immediately, which is the observable proxy for "the server, not the client,
owns the ceiling".)

Acceptance: `cabal test en-servant` passes including the clamp test; against a running
server, `POST /lookup` (or `/v1/lookup` post-EP-35) with `"deadlineMillis": 86400000`
returns promptly (well under a second on dev data) rather than reserving a day of
budget, and omitting `deadlineMillis` behaves exactly as before under the defaults.


### Milestone 4: Documentation honesty (A8, A9) and the restore runbook

Scope: words match code. Edits:

1. `en-servant/en-servant.cabal` — synopsis
   `Servant API and a fail-closed authorization helper for en`; description rewritten
   to: the en HTTP API as a Servant API type, plus `requirePermission`, a fail-closed
   `Handler` helper that gates host-route logic on `en.check` — invoked by call
   discipline, not enforced by the route's type. Keep the shomei sentence only as
   aspiration explicitly marked as such, or drop it (drop is cleaner; EP-33's Decision
   Log records shomei as an extension point).
2. `README.md` packages table — the `en-servant` row becomes
   `Servant API + a fail-closed requirePermission handler helper`. In the
   `en-migrations` row / status prose, replace the bare "codd-managed" claim with
   "codd-compatible SQL migrations (dev applies them via `just run-migrations`)".
3. `docs/user/service-and-operations.md` — extend the configuration table with every
   variable `ServerConfig` now owns (names, defaults, validation rules, including that
   invalid values abort startup — and the `EN_PORT` behavior change from
   silent-fallback to fail-fast); document the startup `Datastore id:` log line; state
   that first startup after this change rotates the effective identity and invalidates
   older tokens. Add an "Operational warning: backup/restore and datastore identity"
   subsection: restoring a dump into a *new* PostgreSQL cluster resets the xid8
   counter, so tokens minted before the restore must not be honored; because identity
   is persisted *in* the dump, the restored database would keep the old id — therefore
   the runbook step after any restore into a fresh cluster is
   `DELETE FROM en_datastore_metadata;` before starting en-server, forcing a fresh id
   so every pre-restore token fails the datastore check instead of validating against
   a reset counter. Same-cluster point-in-time recovery does not reset the counter and
   needs no rotation.

Acceptance: `rg -i 'combinator' README.md en-servant/en-servant.cabal` returns nothing
about RequirePermission; `rg 'en_datastore_metadata|xid8' docs/user/service-and-operations.md`
shows the runbook; the config table lists every `EN_*` variable the server reads
(cross-check against `rg 'EN_[A-Z_]+' en-server/app`).


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/en` in the nix dev shell.

Build/test cycle after each milestone:

```bash
cabal build all
cabal test en-servant
```

Config validation spot checks (M1):

```bash
EN_DATABASE_URL="$PG_CONNECTION_STRING" EN_PORT=abc cabal run en-server; echo "exit=$?"
EN_DATABASE_URL="$PG_CONNECTION_STRING" EN_GC_WINDOW='24 hoursss' cabal run en-server; echo "exit=$?"
```

Expected (respectively, final lines):

```text
en-server: Invalid EN_PORT=abc: expected an integer in 1..65535
exit=1
en-server: Invalid EN_GC_WINDOW=24 hoursss: not a positive PostgreSQL interval (e.g. '24 hours', '7 days')
exit=1
```

Identity lifecycle (M2):

```bash
just process-up
just run-migrations
EN_DATABASE_URL="$PG_CONNECTION_STRING" cabal run en-server &   # note the logged id
sleep 20
psql "$PG_CONNECTION_STRING" -tAc "SELECT datastore_id FROM en_datastore_metadata"
kill %1; wait
EN_DATABASE_URL="$PG_CONNECTION_STRING" cabal run en-server &   # same id logged again
```

Expected: both server starts log `Datastore id: <uuid>` with the identical uuid, which
matches the psql output. Rotation drill (the restore runbook, safe on dev data —
it only invalidates tokens):

```bash
psql "$PG_CONNECTION_STRING" -c "DELETE FROM en_datastore_metadata"
# restart en-server; it logs a NEW uuid, and a token minted before the rotation now fails:
just test-server || echo "old-token flow re-established by fresh write"
```

(The smoke test writes fresh tokens each run, so it passes; to see the rejection
directly, save a `token` from before the rotation and replay the check curl with it —
expect the invalid-token error, in EP-35's envelope if landed.)

Deadline clamp (M3), server running:

```bash
time curl -s -X POST localhost:8080/lookup -H 'content-type: application/json' \
  -d '{"consistency":{"tag":"MinimizeLatencyWire"},"subject":{"tag":"SubjectIdWire","contents":{"objectType":"user","objectId":"alice"}},"permission":"view","objectType":"space","context":{"values":{}},"limit":10,"cursor":null,"deadlineMillis":86400000}'
```

Expected: a normal lookup page in well under a second of wall time (`time` real
< 1s on dev data) — the day-long request no longer reserves a day of budget. (Use
EP-35's `/v1/lookup` path and field shapes if that plan has landed; add EP-33's auth
header if active.)

Docs sweep (M4):

```bash
rg -n "RequirePermission|Authorize combinator" README.md en-servant/en-servant.cabal
rg -n "en_datastore_metadata" docs/user/service-and-operations.md Justfile
```

Expected: first command silent (or only historical mentions in docs/plans, which are
records and stay); second shows the runbook and the Justfile guard.

Full regression:

```bash
just start-and-test
```

Expected final line: the smoke-test success message.


## Validation and Acceptance

Acceptance as observable behavior:

1. Every invalid configuration value in the M1 table aborts startup non-zero, names
   the exact variable and value, and never binds the port; valid defaults serve
   normally. `EN_GC_WINDOW` validation happens before the port binds.
2. Identity: fresh migrated database ⇒ new uuid logged and persisted; every restart
   re-logs the same uuid; two different databases yield different uuids (verify with a
   second scratch database via `createdb` + migrations); a consistency token minted
   under a previous identity is rejected as an invalid token, and the failure message
   names the datastore mismatch. `DatastoreId "en-server"` no longer appears in the
   source (`rg '"en-server"' en-server/app` → only log strings, not identity).
3. Startup against a database missing the new migration fails with the message
   pointing at `en-migrations/db/migrations` — not a hardcoded-identity fallback.
4. Deadlines: server-side ceiling governs (`deadlineMillis: 86400000` returns
   promptly); default behavior unchanged when the client omits the field; the
   en-servant suite's clamp test passes; `EN_MAX_BATCH_SIZE=2` makes a 3-pair
   batch-check return the batch-too-large 400.
5. Docs: the A8 wording is gone from `README.md` and `en-servant/en-servant.cabal`;
   `docs/user/service-and-operations.md` contains the full config reference, the
   token-invalidation note for this change, and the restore/identity-rotation runbook.
6. Regressions: `cabal build all`, `cabal test en-servant`, `cabal test en-core`,
   `just start-and-test` all pass.


## Idempotence and Recovery

The migration is guarded in dev and additive; re-running `just run-migrations` is a
no-op. Identity resolution is idempotent by construction (`ON CONFLICT DO NOTHING` +
`SELECT`): any number of concurrent or repeated startups converge on one id. The only
destructive operation in this plan is the *deliberate* `DELETE FROM
en_datastore_metadata` rotation, whose blast radius is precisely "all outstanding
consistency tokens become invalid" — the documented, intended effect; recovery from an
accidental rotation is the same as any token invalidation (clients re-write or fall
back to `MinimizeLatency`/`FullyConsistent` reads, which never carry tokens).
Config-parsing changes carry one intentional behavior break — previously-silent bad
`EN_PORT` values now abort — which is called out in the docs; recovery is fixing the
variable. All other steps are compile-test cycles, safe to repeat. If M2 must be rolled
back, dropping the table and restoring the hardcoded id is a clean revert, but note in
Surprises & Discoveries why, since it re-opens finding A6.


## Interfaces and Dependencies

New and changed interfaces (full module paths):

- New module `Config` (`en-server/app/Config.hs`, `other-modules`):
  `ServerConfig (..)`, `loadServerConfig :: IO ServerConfig`,
  `validateGcWindow :: (forall a. Session a -> IO (Either SessionError a)) -> Text -> IO ()`.
  Owns (at minimum) `EN_DATABASE_URL`, `EN_PORT`, `EN_GC_WINDOW`, `EN_SCHEMA_PATH`,
  `EN_OPTIMIZED_REVISION_CACHE_TTL_MS`, `EN_TUPLE_READ_CACHE_MAX_ENTRIES`,
  `EN_DECISION_CACHE_MAX_ENTRIES`, `EN_MAX_BATCH_SIZE`,
  `EN_LOOKUP_DEADLINE_DEFAULT_MS`, `EN_LOOKUP_DEADLINE_MAX_MS`, plus any sibling-plan
  variables already landed (EP-33 auth/rate/TLS, EP-34 pool, EP-37 maintenance — their
  plans define names and defaults; this record is where they live afterwards).
- New module `En.Postgres.Datastore` (`en-postgres/src/En/Postgres/Datastore.hs`,
  added to `exposed-modules` of `en-postgres/en-postgres.cabal`):
  `resolveDatastoreIdSession :: Text -> Hasql.Session.Session Text`.
- `En.Servant.Seam.Env` (`en-servant/src/En/Servant/Seam.hs`) gains
  `deadlineDefaultMillis :: !Int` and `deadlineMaxMillis :: !Int` — the typed values
  the library sees; env names never cross into en-servant.
- `En.Servant.API.lookupDeadline` (`en-servant/src/En/Servant/API.hs`) re-signatured
  to read the env's deadline policy and clamp to `[0, deadlineMaxMillis]`.
- New migration `en-migrations/db/migrations/<timestamp>_datastore-metadata.sql`
  (this plan's own file; EP-37's index migration is separate and untouched).
- `Justfile`: one new guard block in `run-migrations`.

Dependencies: `uuid` added to `en-server`'s `build-depends`
(`Data.UUID.toText`, `Data.UUID.V4.nextRandom`; already in the project's transitive
closure via hasql-pool/wai). No other new packages.

Documentation artifacts: `README.md`, `en-servant/en-servant.cabal`,
`docs/user/service-and-operations.md` per Milestone 4. Consumers of this plan's
outputs: every sibling in `docs/masterplans/6-production-harden-the-en-service.md`
reads knobs through `ServerConfig`; the persisted identity strengthens the token guard
that `en-biscuit` grants (which embed `ConsistencyToken`s) and the future watch API
(`docs/plans/53-add-a-watch-changelog-api.md`) rely on.
