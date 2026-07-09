---
id: 34
slug: pool-database-connections-in-en-server
title: "Pool database connections in en-server"
kind: exec-plan
created_at: 2026-07-07T15:24:43Z
master_plan: "docs/masterplans/6-production-harden-the-en-service.md"
---

# Pool database connections in en-server

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today the standalone service `en-server` acquires exactly one PostgreSQL connection at
startup (`Connection.acquire` in `en-server/app/Main.hs`) and threads it through every
request. hasql's `Connection` is internally an `MVar` around one libpq socket, so all
concurrent Warp request handlers serialize on it — a hard throughput ceiling no amount of
`-N` threading can lift. Worse, if that one connection drops (PostgreSQL restart,
failover, idle timeout), every subsequent request fails forever; the
`bracket (pure connection) Connection.release` wrapped around `Warp.run` is inert because
acquisition happens before the bracket and `Warp.run` never returns. This is finding A2
(HIGH) of `docs/reviews/2026-07-07-architecture-performance-review.md`.

After this change, `en-server` runs its `Database` effect against a `hasql-pool` `Pool`:
concurrent requests each borrow their own connection, pool size and timeouts are
configured from the environment, and a PostgreSQL restart no longer bricks the server —
stale pooled connections are discarded on first failure and fresh ones are established
automatically, which this plan proves by restarting PostgreSQL under a running server
and watching the smoke test pass again without touching the server process. The plan is
child EP-34 of `docs/masterplans/6-production-harden-the-en-service.md` and defines the
`Database` runner that EP-36's readiness probe and EP-37's maintenance loop consume.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1 (2026-07-08): `runDatabasePool` runner added to
  `en-postgres/src/En/Postgres/Database.hs`; `hasql-pool ^>=1.4` added to
  `en-postgres/en-postgres.cabal`; `cabal build en-postgres` green (cabal resolved
  `hasql-pool-1.4.2` from Hackage against the pinned `hasql-1.10.3.5`, no
  `cabal.project` constraint needed). `cabal test en-postgres` passes both suites
  (`en-postgres-revision-tests`, `en-postgres-integration-tests`).
- [x] M2 (2026-07-08): `en-server/app/Main.hs` acquires a `Pool` from env-configured
  settings, performs a fail-fast startup ping, replaces the inert bracket with a
  reachable `finally`, and releases the pool on exit; `en-server/en-server.cabal` gains
  `hasql-pool ^>=1.4`. `cabal build all` green.
- [x] M2 (2026-07-08): pool settings documented in `docs/user/service-and-operations.md`
  (`EN_POOL_SIZE`, `EN_POOL_ACQUISITION_TIMEOUT_MS`, `EN_POOL_IDLENESS_TIMEOUT_MS`,
  `EN_POOL_MAX_LIFETIME_MS`), plus a "Connection pooling" section covering sizing and
  restart behavior.
- [x] M2 (2026-07-08): acceptance 1 (`just start-and-test` → `server smoke test passed:
  AllowedWire`), acceptance 2 (bogus `EN_DATABASE_URL` exits 1 with the migrations hint,
  port never bound), acceptance 5 (`EN_POOL_SIZE=0` exits 1; `EN_POOL_SIZE=25` logs the
  pool line) all verified.
- [x] M3 (2026-07-08): reconnect-after-restart validated twice against the same server
  process (pid 39010, never restarted). Recovery costs `2 × (established connections)`
  failed requests, not the `EN_POOL_SIZE` the Decision Log assumed; transcript and
  mechanism in Outcomes and Surprises & Discoveries.
- [x] M3 (2026-07-08): concurrency sanity check recorded — 50/50 `200`, and 3 concurrent
  PostgreSQL backends observed under a 400-request parallel load (the single-connection
  design pinned this at 1). Required fixing the plan's own `xargs -I{}` command.
- [x] M3 (2026-07-08): acceptance 6 (no consumer regressions) — `cabal build all`,
  `cabal test en-servant`, `cabal test en-core` all pass.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **`hasql-pool` needed no `cabal.project` constraint.** The plan hedged that
  `hasql-pool` 1.4.2 requires `hasql >=1.10 && <1.11`; cabal resolved it from Hackage
  against the existing `hasql-1.10.3.5` with no pin and no other closure change:

  ```text
   - hasql-pool-1.4.2 (lib) (requires build)
  ```

- **The pool startup log confirms the block-buffered-stdout bug that EP-33 recorded.**
  Running with `EN_POOL_SIZE=25` and stdout redirected to a file, then killed by
  `timeout`'s SIGTERM, produced a log with no `Connection pool:` line at all. The same
  invocation under a pty (`script -q /dev/null`) prints it:

  ```text
  en-server listening on :8098
  Connection pool: size=25, acquisitionTimeoutMs=10000, idlenessTimeoutMs=600000, maxLifetimeMs=3600000
  ```

  This is the `hSetBuffering stdout LineBuffering` fix that the master plan assigns to
  EP-36. It affects *this* plan's operator story too: an operator who redirects
  `en-server`'s stdout cannot see the pool configuration they just set. Nothing to fix
  here — recording that M2's log line is correct and merely invisible under redirection
  until EP-36 lands.

- **`optionalNonNegativeIntEnv`'s shape did not fit the pool knobs.** The plan said to
  add "a variant taking a default value". Every pool knob additionally rejects `0`
  (a zero-size pool serves nothing; a zero acquisition timeout expires before it can be
  waited on), whereas the existing cache variables *use* `0` as their disable switch. So
  the new helper is `optionalPositiveIntEnv :: String -> Int -> IO Int` — default **and**
  a `>= 1` floor — rather than a defaulting variant of the non-negative parser. Both
  helpers now coexist in `Main.hs`.

- **A stale connection fails *twice*, not once, so restart recovery costs
  `2 × (established connections)` failed requests.** The Decision Log's
  "converges within at most `EN_POOL_SIZE` failed requests" is wrong. Measured with
  `EN_POOL_SIZE=5`: 3 established connections → 6 failed requests; 5 established
  connections → 10 failed requests, recovering on the 11th, then 20/20 `200`s. Exactly
  `2n`, twice, is not a coincidence. The mechanism is in
  `hasql-pool`'s `Hasql.Pool.SessionErrorDestructors.requiresConnectionDiscard`, which
  discards a connection only for `ConnectionSessionError`, `MissingTypesSessionError`,
  or a `ScriptSessionError`/`StatementSessionError` carrying SQLSTATE `0A000`/`XX000`.
  The *first* session on a stale connection returns neither — it returns a
  `StatementSessionError` whose payload is self-contradictory:

  ```text
  {"error":"StoreError \"Unexpected number of rows
    sql: SELECT pg_current_snapshot()::text
    prepared: true
    expectedMin: 1
    expectedMax: 1
    actual: 1\""}
  ```

  `expectedMin: 1, expectedMax: 1, actual: 1` should be a *success*. Because it is not a
  discardable error, `hasql-pool` returns the dead connection to the pool. Only the
  *second* session on it surfaces the connection-level truth and triggers the discard:

  ```text
  {"error":"StoreError \"Connection error
    reason: no connection to the server\""}
  ```

  Consequences recorded rather than fixed here (the plan's purpose — surviving a restart
  without a process restart — is met, proven twice with the original pid still serving):
  - `docs/user/service-and-operations.md` now documents the real bound and both texts.
  - **EP-35 must classify errors by `SessionError` constructor, never by message text.**
    The first post-restart failure *reads* like a row-decoding bug but is a transient,
    retryable connection failure. A `retryable` flag derived from the message would get
    this exactly backwards. `Hasql.Errors.isTransient` already answers correctly
    (`ConnectionSessionError _ -> True`), but it answers `False` for this first error —
    so EP-35 should not lean on it alone either.
  - **EP-36's readiness probe will observe this.** A probe that runs one session can draw
    a stale connection and report unready while the server is fine, or (worse) consume
    the "free" first failure and mask it from a real request. Readiness should tolerate a
    single failure before flipping.

- **Each `runSession` is a separate `Pool.use`, so one HTTP request spans several
  connections.** `En.Postgres.TupleStore` and `En.Postgres.Revision` call `runSession`
  once per logical step (head revision, then object/relation reads, then writes), and the
  `Database` effect maps each call to one pool acquisition. Under the old
  single-connection runner every session in a request shared a connection; now they do
  not. This is *safe by design* — en pins reads to an explicit revision and evaluates
  visibility with `pg_visible_in_snapshot`, so correctness never depended on a shared
  session snapshot — but it is a real semantic change and it is why a single failing
  request can burn more than one stale connection. **EP-37's maintenance loop must not
  assume its `oldestRetainedXidSession` and `reapDeletedTuplesSession` share a snapshot
  or a connection**; they never did share a transaction, and now they do not even share a
  socket. Anything needing session-local state (advisory locks, `SET LOCAL`, temp tables)
  cannot be expressed as two `runSession` calls.

- **`just test-server` masks database failures and cannot prove restart recovery.** Its
  first request is `curl -sS -X DELETE .../tuples >/dev/null` with no `--fail` and no
  status check, so a `500` there is silently swallowed — absorbing one or two stale
  connections before the assertions begin. That is why the smoke test passed on its first
  post-restart attempt while direct `/check` probes were still returning `500`. The
  restart proof in this plan therefore rests on the direct probe loop, not on
  `just test-server`. Left as-is (fixing the Justfile is out of scope), but any later
  plan that leans on `just test-server` as a health signal should know it under-reports.

- **The plan's own concurrency command was broken.** `xargs -P 16 -I{}` substitutes the
  `{}` placeholder into the JSON body — `"context":{"values":{}}` became
  `"context":{"values":1}` — and all 50 requests returned `400`, which looks exactly like
  a pooling failure. Corrected to `-I@@` in Concrete Steps. With that fixed, 50/50 return
  `200`, and sampling `pg_stat_activity` during a 400-request run shows 3 concurrent
  `en-server` backends where the single-connection design pinned it at 1.

- **Warp's TLS/plaintext branch had to be lifted out of `main`.** Attaching
  `` `finally` Pool.release pool `` to a multi-line `case tlsConfig of` inside the
  `bracket`'s lambda made the precedence unreadable. The branch is now a top-level
  `serve :: Maybe TlsConfig -> Int -> Wai.Application -> IO ()`, and `main` ends with the
  single line `serve tlsConfig port wrappedApp \`finally\` Pool.release pool`. This adds
  `import Network.Wai qualified as Wai` to `Main.hs`. **EP-36 takes note**: graceful
  shutdown replaces `Warp.run`/`WarpTLS.runTLS` inside `serve`, not in `main`.


## Decision Log

Record every decision made while working on the plan.

- Decision: Use `hasql-pool` (version 1.4.x, which requires `hasql >=1.10 && <1.11`,
  matching the `hasql-1.10.3.5` this project already builds against) rather than a
  generic pool (`resource-pool`) or hand-rolled pooling.
  Rationale: `hasql-pool` is the hasql-native pool: it understands hasql's error types
  well enough to discard a connection only on connection-level failures (a constraint
  violation returns the connection to the pool), establishes connections lazily, ages
  and idles them out on a background reaper thread, and bounds acquisition waiting with
  a timeout. Its source and reference documentation were read at
  `/Users/shinzui/Keikaku/hub/haskell/hasql-project/hasql-pool` (registered in mori as
  `hasql/hasql`, package `hasql-pool`); the API used below (`Hasql.Pool.acquire/use/release`,
  `Hasql.Pool.Config.settings` with `size`, `acquisitionTimeout`, `agingTimeout`,
  `idlenessTimeout`, `staticConnectionSettings`) is the 1.4.2 surface.
  Date: 2026-07-07
- Decision: Keep the `Database` effect's operation signature unchanged
  (`RunSession :: Session a -> Database m (Either SessionError a)`) and map
  `hasql-pool`'s `UsageError` into `SessionError` inside the new runner, instead of
  widening the effect to a new error type.
  Rationale: The effect is consumed by `en-postgres/src/En/Postgres/TupleStore.hs`
  (which folds any `SessionError` into `EnError`'s `StoreError` via
  `Hasql.Errors.toDetailedText`) and by the integration test. hasql's `SessionError`
  already has a constructor for exactly the two pool-only failures we must represent:
  `ConnectionSessionError Text` means "the connection was lost or unusable", which is
  what both `ConnectionUsageError` (establishment failed) and
  `AcquisitionTimeoutUsageError` (pool exhausted) amount to from a caller's perspective.
  Mapping keeps every consumer and both existing runners source-compatible; widening the
  effect would ripple through en-servant's `AppEffects` for no behavioral gain.
  Date: 2026-07-07
- Decision: Keep `runDatabaseConnection` (the single-connection runner) alongside the
  new `runDatabasePool`.
  Rationale: `en-postgres/integration-test/Main.hs` deliberately runs against one
  connection (it must control transaction interleaving for the snapshot-oracle tests),
  and embedded consumers may prefer owning a connection. Additive change, zero risk.
  Date: 2026-07-07
- Decision: Ping the database through the pool once at startup and fail fast if the
  ping fails.
  Rationale: `Hasql.Pool.acquire` establishes connections lazily, so a bad
  `EN_DATABASE_URL` would otherwise surface only on the first request. The current
  single-connection code fails at startup with a helpful message pointing at the codd
  migrations directory; this plan preserves that operator experience by running
  `SELECT 1` through `Pool.use` before binding the port.
  Date: 2026-07-07
- Decision: Do not add automatic retry of sessions that fail with connection-level
  errors; accept that the first request(s) after a PostgreSQL restart may fail while
  stale pooled connections are flushed.
  Rationale: `hasql-pool` discards a connection when a session fails with a
  connection-level error but does not re-execute the session — and blind re-execution
  would be wrong for writes (the transaction may or may not have committed).
  Fail-and-discard converges within at most `EN_POOL_SIZE` failed requests, clients
  already must handle 5xx, and EP-35
  (`docs/plans/35-version-the-wire-contract-and-type-the-error-model.md`) marks store
  errors as `retryable` in the typed error envelope so clients can retry safely at
  their layer. Validation below encodes this honestly.
  Date: 2026-07-07
  **Amended 2026-07-08 (M3):** the decision stands, but its convergence bound was
  wrong. Measured cost is `2 × (established connections)` failed requests, not
  `EN_POOL_SIZE` — each stale connection fails twice before `hasql-pool` discards it.
  See Surprises & Discoveries. The decision not to auto-retry is unchanged and is now
  *more* consequential, so `docs/user/service-and-operations.md` documents the real
  bound and both error texts an operator will see.
- Decision: Add `optionalPositiveIntEnv :: String -> Int -> IO Int` (default plus a
  `>= 1` floor) rather than a defaulting variant of `optionalNonNegativeIntEnv`.
  Rationale: The plan called for "a variant taking a default value", but all four pool
  knobs must also reject `0`, which the existing cache variables use as their disable
  switch. One helper cannot serve both meanings of zero. The error text is
  `Invalid EN_POOL_SIZE: expected a positive integer`, matching the surrounding style.
  Date: 2026-07-08
- Decision: Extract the TLS/plaintext branch from `main` into a top-level `serve`.
  Rationale: `finally` binding over a multi-line `case` inside `main` obscured what the
  release attaches to. `serve` makes `main`'s last line read exactly as intended, and
  gives EP-36 one obvious place to add graceful shutdown.
  Date: 2026-07-08
- Decision: Pool sizing default is 10 connections.
  Rationale: `hasql-pool`'s default of 3 is too small for a Warp server running with
  `-N`; 10 matches the "match your concurrent database-touching threads" guidance in the
  hasql-pool reference while staying well under PostgreSQL's default `max_connections`
  of 100 even with several en-server replicas. Operators tune with `EN_POOL_SIZE`.
  Date: 2026-07-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Complete (2026-07-08).** Finding A2 is fixed. `en-server` interprets the `Database`
effect against a `hasql-pool` `Pool`; concurrent requests are served from distinct
PostgreSQL backends; a `pg_ctl restart` no longer bricks the process; the inert bracket
is gone, replaced by a `finally` that will become load-bearing when EP-36 adds graceful
shutdown.

Against the Purpose section's two claims:

*"Concurrent requests each borrow their own connection."* Verified. Sampling
`pg_stat_activity` during 400 parallel `/check` requests (`-P 32`) showed 3 concurrent
`en-server` backends; 50/50 parallel requests return `200`. The old runner held exactly
one `Connection` — an `MVar` around one libpq socket — so this count was structurally
pinned at 1. The pool grows lazily, so it stops at 3 rather than `EN_POOL_SIZE=5`;
en's sessions are short enough that 5 are never needed at once at this load.

*"A PostgreSQL restart no longer bricks the server."* Verified twice, same server pid
throughout:

```text
=== backends before restart ===
5
=== pg_ctl restart ===
waiting for server to shut down.... done
server stopped
waiting for server to start.... done
server started
=== server process still alive? ===
39010 S+   .../en-server
=== probes after restart ===
probes 1-5:  500  StoreError "Unexpected number of rows … actual: 1"
probes 6-10: 500  StoreError "Connection error / reason: no connection to the server"
probe 11:    200
=== 20 more probes ===
200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200
```

The old single-connection design failed *every* request forever after this point. That
contrast is the proof the finding is fixed.

**The one substantive gap, honestly stated.** Recovery is twice as expensive as this
plan predicted when it was written. Each stale connection fails two requests, not one,
because `hasql-pool` only discards a connection on a connection-level error and the
first session on a dead socket reports a statement-level one (with the actively
misleading text `expectedMin: 1, expectedMax: 1, actual: 1`). The measured law is
`2 × (established connections)` — confirmed at both 3 and 5 connections. The Decision Log
entry that predicted `EN_POOL_SIZE` has been amended in place rather than quietly
corrected, and `docs/user/service-and-operations.md` documents the real bound and both
error strings so an operator reading a post-restart log is not misled into hunting a
decoding bug. The decision *not* to auto-retry still stands — blind re-execution is
unsafe for writes — but it now costs more, and EP-35's `retryable` classification must
key off the `SessionError` constructor rather than the message.

Two findings escape this plan's scope and are logged for siblings: each `runSession` is
its own `Pool.use`, so a single request spans several connections (EP-37 must not assume
a shared snapshot); and `just test-server` swallows the HTTP status of its opening
`DELETE`, so it cannot be trusted as a restart-recovery signal.

Lesson worth carrying: two of this plan's prewritten validation commands were wrong in
ways that impersonate the bug under test. `xargs -I{}` rewrote the JSON body and produced
50 × `400`, which reads exactly like a broken pool. Redirecting stdout hid every startup
line, which reads exactly like a server that never configured its pool. Both cost real
time. Validation commands deserve the same skepticism as the code they validate.


## Context and Orientation

en is a Haskell workspace at `/Users/shinzui/Keikaku/bokuno/en`, built with `cabal`
(GHC 9.12.4; see `cabal.project`). Database access is abstracted behind a tiny
*effectful* effect — an interface that can be given different interpreters — defined in
`en-postgres/src/En/Postgres/Database.hs`:

```haskell
data Database :: Effect where
    RunSession :: Session a -> Database m (Either SessionError a)

runDatabaseConnection :: (IOE :> es) => Connection -> Eff (Database : es) a -> Eff es a
```

A `Session` (from the `hasql` package) is a batch of SQL statements to execute on one
connection; `SessionError` (from `Hasql.Errors`) is hasql's error sum, whose
constructors include `ConnectionSessionError Text` for "the connection died mid-use".
Every PostgreSQL-touching part of en — the tuple store interpreter in
`en-postgres/src/En/Postgres/TupleStore.hs` and the consistency store in
`en-postgres/src/En/Postgres/Revision.hs` — issues its SQL through `runSession`, so
swapping how sessions reach PostgreSQL is a change to the *interpreter only*: one new
function, and one call site in `en-server/app/Main.hs`.

`Main.hs` today does, in order: read env vars, load/validate the schema, then
`Connection.acquire (Settings.connectionString (Text.pack databaseUrl))`, failing with a
message that tells the operator to run the codd migrations from
`en-migrations/db/migrations`. It builds `runAppIO`, the natural transformation the
Servant seam uses (`runEff (runDatabaseConnection connection (…))`), prints startup
lines, and ends with `bracket (pure connection) Connection.release \_ -> Warp.run port
(app serverEnv)` — the inert bracket finding A2 calls out (acquisition is outside the
bracket, and `Warp.run` never returns normally, so the release is unreachable except on
exception).

`hasql-pool` provides `Hasql.Pool.Pool` with `acquire :: Config -> IO Pool`,
`use :: Pool -> Session a -> IO (Either UsageError a)`, and `release :: Pool -> IO ()`.
`UsageError` is `ConnectionUsageError ConnectionError | SessionUsageError SessionError |
AcquisitionTimeoutUsageError`. Config is built by
`Hasql.Pool.Config.settings :: [Setting] -> Config` with settings `size` (default 3),
`acquisitionTimeout` (`DiffTime`, default 10s), `agingTimeout` (max connection lifetime,
default 1 day), `idlenessTimeout` (default 10 min), and `staticConnectionSettings`
(taking the same `Hasql.Connection.Settings.Settings` value `Main.hs` already builds
with `Settings.connectionString`). Connections are created lazily on first `use`;
`release` closes idle connections and marks in-use ones for disposal, and the pool
remains usable afterwards.

The development database is managed by process-compose (`process-compose.yaml` defines
only a `postgres` process today) through `just` recipes in `Justfile`: `just process-up`
starts it detached with a unix socket under the repo's `db/` directory, `just
process-down` stops it, `just run-migrations` applies the SQL files with guarded `psql`,
and `just test-server` is the curl smoke test. The dev shell exports `PGDATA`, `PGHOST`,
`PGLOG`, `PG_CONNECTION_STRING`, and `EN_DATABASE_URL`. PostgreSQL can be restarted in
place with `pg_ctl` (available in the dev shell) — that is how M3 proves reconnect
behavior.

Integration points restated from the master plan
(`docs/masterplans/6-production-harden-the-en-service.md`): this plan owns the
redefinition of the `Database` runner; EP-36's readiness probe and EP-37's maintenance
session must call through the `Database` effect using whatever runner this plan defines
(they must not hold a raw `Connection`). `en-server/app/Main.hs` is shared with EP-33,
EP-36, EP-37, and EP-38, so keep this plan's `Main.hs` diff small and land it whole. Any
env vars this plan adds are later absorbed by EP-38's `ServerConfig`
(`docs/plans/38-validate-configuration-and-persist-datastore-identity.md`); the variable
names below are the contract EP-38 keeps.


## Plan of Work

Three milestones: add the runner (library change, independently testable), rewire the
server (application change), then prove the operational property the whole plan exists
for (restart survival and concurrency).


### Milestone 1: A pool-backed Database runner in en-postgres

Scope: `en-postgres` learns to interpret the `Database` effect against a pool. At the
end, `runDatabasePool` exists, compiles, and the package's existing tests still pass.

Edit `en-postgres/en-postgres.cabal`: add `hasql-pool` to the library's
`build-depends` (constraint `^>=1.4`, compatible with the pinned `hasql` 1.10 line).

Edit `en-postgres/src/En/Postgres/Database.hs`: export a second runner and keep the
first —

```haskell
-- added imports
import Data.Bifunctor (first)
import Hasql.Errors (SessionError (..))
import Hasql.Errors qualified as Errors
import Hasql.Pool qualified as Pool

-- | Interpret 'Database' against a hasql-pool 'Pool'. Pool-level failures
-- (connection establishment, acquisition timeout) are reported as
-- 'ConnectionSessionError' so consumers see one error type.
runDatabasePool :: (IOE :> es) => Pool.Pool -> Eff (Database : es) a -> Eff es a
runDatabasePool pool =
    interpret_ \case
        RunSession session ->
            liftIO (first usageToSessionError <$> Pool.use pool session)

usageToSessionError :: Pool.UsageError -> SessionError
usageToSessionError = \case
    Pool.SessionUsageError err -> err
    Pool.ConnectionUsageError err ->
        ConnectionSessionError ("pool connection failure: " <> Errors.toDetailedText err)
    Pool.AcquisitionTimeoutUsageError ->
        ConnectionSessionError "timed out acquiring a pooled database connection"
```

(The `ConnectionSessionError` payload rendering works because `ConnectionError` is an
`IsError` instance in `Hasql.Errors`, so `toDetailedText` applies.) Note precisely what
flows where: a `SessionUsageError` passes through untouched, so statement failures keep
their full context; the two pool-only cases become `ConnectionSessionError`, which
`En.Postgres.TupleStore`'s `orThrow` then renders into `EnError`'s `StoreError` exactly
as it does for any other session failure today. No consumer changes.

Acceptance: `cabal build en-postgres` succeeds; `cabal test en-postgres` passes. The
integration test still uses `runDatabaseConnection` and is untouched.


### Milestone 2: en-server acquires a pool with env-configured settings

Scope: `Main.hs` swaps the single connection for the pool, gains four tuning variables,
pings the database at startup, and gets a real bracket. At the end the server behaves
identically on the happy path but serves concurrent requests from separate connections.

Edit `en-server/en-server.cabal`: add `hasql-pool` to the executable's `build-depends`.

Edit `en-server/app/Main.hs`. Replace the `Connection.acquire …` block with:

1. Parse pool settings using the existing `optionalNonNegativeIntEnv` pattern (add a
   variant taking a default value): `EN_POOL_SIZE` (default 10, must be >= 1),
   `EN_POOL_ACQUISITION_TIMEOUT_MS` (default 10000),
   `EN_POOL_IDLENESS_TIMEOUT_MS` (default 600000, i.e. 10 minutes),
   `EN_POOL_MAX_LIFETIME_MS` (default 3600000, i.e. 1 hour — deliberately shorter than
   hasql-pool's 1-day default so connections cycle through server-side configuration
   changes; maps to `agingTimeout`). Milliseconds convert to `DiffTime` with
   `fromRational (toRational ms / 1000)`, matching the conversion style already used for
   the optimized-revision TTL.
2. Acquire the pool:

   ```haskell
   pool <-
       Pool.acquire $
           Config.settings
               [ Config.size poolSize
               , Config.acquisitionTimeout acquisitionTimeout
               , Config.idlenessTimeout idlenessTimeout
               , Config.agingTimeout maxLifetime
               , Config.staticConnectionSettings
                   (Settings.connectionString (Text.pack databaseUrl))
               ]
   ```

   with `import Hasql.Pool qualified as Pool` and
   `import Hasql.Pool.Config qualified as Config` (the `Hasql.Pool.Config` module
   re-exports the setting constructors `size`, `acquisitionTimeout`, `agingTimeout`,
   `idlenessTimeout`, `staticConnectionSettings` alongside `settings`).
3. Ping fail-fast, preserving today's helpful startup error:

   ```haskell
   Pool.use pool (Session.script "SELECT 1") >>= \case
       Right () -> pure ()
       Left err ->
           fail $
               "Could not reach PostgreSQL through EN_DATABASE_URL. "
                   <> show err
                   <> "\nRun the codd migrations in "
                   <> migrationsDir
                   <> " before starting en-server."
   ```

   (`Session.script` avoids pulling encoder/decoder imports into `Main.hs`; add
   `import Hasql.Session qualified as Session`.)
4. Change the runner: `runDatabaseConnection connection` becomes `runDatabasePool pool`
   inside `runAppIO` (one-line change; the import switches from
   `runDatabaseConnection` to `runDatabasePool`). Drop the now-unused
   `Hasql.Connection` import.
5. Replace the inert final bracket with a reachable release, and log the pool
   configuration with the other startup lines:

   ```haskell
   Text.putStrLn ("Connection pool: size=" <> Text.pack (show poolSize)
       <> ", acquisitionTimeoutMs=" <> Text.pack (show acquisitionTimeoutMs)
       <> ", idlenessTimeoutMs=" <> Text.pack (show idlenessTimeoutMs)
       <> ", maxLifetimeMs=" <> Text.pack (show maxLifetimeMs))
   Warp.run port (app serverEnv) `finally` Pool.release pool
   ```

   (`finally` from `Control.Exception`, replacing the current `bracket` import if
   nothing else uses it. `Warp.run` still never returns normally until EP-36 adds
   graceful shutdown — at which point this `finally` becomes load-bearing, which is why
   it goes in now rather than pretending with an unreachable bracket.)

Document the four variables in the configuration table of
`docs/user/service-and-operations.md`.

Acceptance: `cabal build en-server` succeeds; with the dev database up,
`just start-and-test` passes unchanged; starting with a bogus `EN_DATABASE_URL` exits
non-zero at the ping with the migrations-hint message and never binds the port.


### Milestone 3: Prove restart survival and concurrent throughput

Scope: no code — validation of the operational property, with transcripts captured into
this plan's Outcomes section. This is the milestone that demonstrates finding A2 is
actually fixed rather than merely refactored.

Reconnect proof: with the server running, restart PostgreSQL underneath it using
`pg_ctl` (the same tool process-compose drives), then re-run the smoke test against the
same server process. Exact commands and expected output are in Concrete Steps. The
acceptance subtlety, per the Decision Log: requests that land on a stale pooled
connection fail once with a 500 (`StoreError` wrapping `ConnectionSessionError`) and the
pool discards that connection, so the smoke test may need one retry — but the server
process itself must recover with no restart, which the old single-connection design
could never do (it failed every request forever).

Concurrency sanity check: fire 50 parallel checks and observe all succeed. This does not
benchmark (out of scope) — it demonstrates that concurrent requests no longer serialize
on one `MVar`; before this plan the same loop completes strictly sequentially.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/en`, inside the
nix dev shell (direnv loads it; it exports `PGDATA`, `PGHOST`, `PGLOG`,
`PG_CONNECTION_STRING`, and `EN_DATABASE_URL`).

Build and unit-test after M1:

```bash
cabal build en-postgres
cabal test en-postgres
```

Expected: compilation succeeds; the `en-postgres` test suite prints its passing
assertions.

Bring up the database and run the full smoke path after M2:

```bash
just process-up
just start-and-test
```

Expected final line:

```text
server smoke test passed: AllowedWire
```

Restart-survival transcript (M3). Terminal 1 — start the server and leave it running:

```bash
just run-migrations
EN_DATABASE_URL="$PG_CONNECTION_STRING" cabal run en-server
```

Terminal 2 — verify, restart PostgreSQL, verify again:

```bash
just test-server
pg_ctl restart -D "$PGDATA" -w -l "$PGLOG" -o "--unix_socket_directories='$PGHOST'" -o "-c listen_addresses=''"
just test-server || just test-server
```

Expected transcript in terminal 2:

```text
server smoke test passed: AllowedWire
waiting for server to shut down.... done
server stopped
waiting for server to start.... done
server started
server smoke test passed: AllowedWire
```

(The `|| just test-server` retry absorbs the at-most-`EN_POOL_SIZE` requests that flush
stale connections; if the first post-restart run passes, the retry never executes.
Terminal 1 must show no crash and require no restart. If process-compose's supervisor
flags the postgres process after the out-of-band restart, `just process-down && just
process-up` restores its view; the proof stands either way.)

Concurrency sanity check (server still running). Note the `-I@@` placeholder: **do not
use `xargs -I{}` here**, because `xargs` substitutes `{}` inside the JSON body
(`"values":{}` becomes `"values":1`) and every request returns 400.

```bash
seq 1 50 | xargs -P 16 -I@@ curl -s -o /dev/null -w "%{http_code}\n" \
  localhost:8080/check \
  -H 'Authorization: Bearer dev-secret-0123456789' \
  -H 'content-type: application/json' \
  -d '{"consistency":{"tag":"MinimizeLatencyWire"},"context":{"values":{}},"subject":{"tag":"SubjectIdWire","contents":{"objectType":"user","objectId":"alice"}},"permission":"view","object":{"objectType":"space","objectId":"project-x"}}' \
  | sort | uniq -c
```

Expected:

```text
  50 200
```

To observe that requests really are served from distinct connections, sample
PostgreSQL while the load runs (the count settles above 1, which the
single-connection design could never do):

```bash
psql "$PG_CONNECTION_STRING" -tAc \
  "SELECT count(*) FROM pg_stat_activity WHERE backend_type='client backend' AND application_name=''"
```

(If EP-33 has already landed, add its `Authorization: Bearer …` header to these curl
commands; if EP-35 has already landed, use its `/v1` paths and field names — the
`Justfile` smoke test is kept current by whichever plan lands, so `just test-server` is
always the authoritative form.)


## Validation and Acceptance

Acceptance is the following observable behavior:

1. Happy path unchanged: `just start-and-test` passes after the swap, proving writes,
   token-threaded checks, and deletes all work through the pool.
2. Startup fail-fast: `EN_DATABASE_URL='postgresql://localhost:1/nope' cabal run
   en-server` (any unreachable URL) exits non-zero printing `Could not reach PostgreSQL
   through EN_DATABASE_URL` and the codd-migrations hint, without binding the port —
   even though pool acquisition itself is lazy.
3. Restart survival: with a server started once, the sequence *smoke test passes →
   `pg_ctl restart` → smoke test passes (allowing one retried run)* completes with the
   original server process still running. Before this plan the second smoke test fails
   indefinitely; that contrast is the proof the finding is fixed.
4. Concurrency: 50 parallel `/check` requests all return 200.
5. Configuration: starting with `EN_POOL_SIZE=0` fails with a clear message (size must
   be at least 1); starting with `EN_POOL_SIZE=25` logs `Connection pool: size=25, …`
   at startup.
6. No consumer regressions: `cabal build all`, `cabal test en-servant`, and
   `cabal test en-core` pass.

Interpreting failures: a 500 whose logged detail contains `pool connection failure` or
`timed out acquiring a pooled database connection` is the new runner's mapping of
pool-level errors — expected transiently right after a restart, a bug if sustained.


## Idempotence and Recovery

All steps are repeatable. `cabal build`/`cabal test` are idempotent. The pool holds no
persistent state — restarting `en-server` always recovers it. `pg_ctl restart` on the
dev database is safe to run repeatedly (same data directory, same socket options as
`process-compose.yaml` uses; if process-compose marks the process failed after the
out-of-band restart, `just process-down && just process-up` restores the managed state).
No schema or data migrations are involved. If the swap misbehaves in a way that blocks
other work, the recovery path is mechanical: revert the `Main.hs` hunk to
`runDatabaseConnection` (that runner remains exported) — but record why in Surprises &
Discoveries before doing so.


## Interfaces and Dependencies

New interface in `en-postgres/src/En/Postgres/Database.hs` (module
`En.Postgres.Database`), exported alongside the existing ones:

```haskell
runDatabasePool :: (IOE :> es) => Hasql.Pool.Pool -> Eff (Database : es) a -> Eff es a
```

The `Database` effect and `runSession :: (Database :> es) => Session a -> Eff es (Either
SessionError a)` are unchanged — this is the contract EP-36
(`docs/plans/36-add-health-endpoints-graceful-shutdown-and-observability.md`, readiness
probe) and EP-37
(`docs/plans/37-schedule-background-maintenance-for-reaping-and-transaction-pruning.md`,
maintenance sessions) build on: they run their sessions through this effect against the
pool-backed runner and never hold a raw `Connection`.

Dependencies added: `hasql-pool ^>=1.4` in both `en-postgres/en-postgres.cabal`
(library) and `en-server/en-server.cabal` (executable). `hasql-pool` 1.4.2 requires
`hasql >=1.10 && <1.11`, satisfied by the `hasql-1.10.3.5` already in the build plan; it
transitively adds only `uuid` (already present in the closure). Modules used:
`Hasql.Pool` (`Pool`, `acquire`, `use`, `release`, `UsageError (..)`) and
`Hasql.Pool.Config` (`settings`, `size`, `acquisitionTimeout`, `agingTimeout`,
`idlenessTimeout`, `staticConnectionSettings`).

New runtime contract (environment variables, absorbed later by EP-38's `ServerConfig`):
`EN_POOL_SIZE` (default 10), `EN_POOL_ACQUISITION_TIMEOUT_MS` (default 10000),
`EN_POOL_IDLENESS_TIMEOUT_MS` (default 600000), `EN_POOL_MAX_LIFETIME_MS`
(default 3600000).

Files edited: `en-postgres/src/En/Postgres/Database.hs`,
`en-postgres/en-postgres.cabal`, `en-server/app/Main.hs`, `en-server/en-server.cabal`,
`docs/user/service-and-operations.md`. No files added.
