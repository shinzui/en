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
- [ ] M2: `en-server/app/Main.hs` acquires a `Pool` from env-configured settings,
  performs a fail-fast startup ping, removes the inert bracket, and releases the pool
  on exit; `en-server/en-server.cabal` gains `hasql-pool`.
- [ ] M2: pool settings documented in `docs/user/service-and-operations.md`
  (`EN_POOL_SIZE`, `EN_POOL_ACQUISITION_TIMEOUT_MS`, `EN_POOL_IDLENESS_TIMEOUT_MS`,
  `EN_POOL_MAX_LIFETIME_MS`).
- [ ] M3: reconnect-after-restart validated: smoke test passes, PostgreSQL restarted via
  `pg_ctl`, smoke test passes again against the same server process; transcript
  recorded in Outcomes.
- [ ] M3: concurrency sanity check (parallel curl loop) recorded.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


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
- Decision: Pool sizing default is 10 connections.
  Rationale: `hasql-pool`'s default of 3 is too small for a Warp server running with
  `-N`; 10 matches the "match your concurrent database-touching threads" guidance in the
  hasql-pool reference while staying well under PostgreSQL's default `max_connections`
  of 100 even with several en-server replicas. Operators tune with `EN_POOL_SIZE`.
  Date: 2026-07-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


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

Concurrency sanity check (server still running):

```bash
seq 1 50 | xargs -P 16 -I{} curl -s -o /dev/null -w "%{http_code}\n" \
  localhost:8080/check \
  -H 'content-type: application/json' \
  -d '{"consistency":{"tag":"MinimizeLatencyWire"},"context":{"values":{}},"subject":{"tag":"SubjectIdWire","contents":{"objectType":"user","objectId":"alice"}},"permission":"view","object":{"objectType":"space","objectId":"project-x"}}' \
  | sort | uniq -c
```

Expected:

```text
  50 200
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
