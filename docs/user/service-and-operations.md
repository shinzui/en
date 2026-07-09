# Service and Operations

`en` can be embedded as Haskell libraries or run as a standalone Servant
service. The embedded path gives the host application direct control over the
schema and stores; the service path exposes the same operations over HTTP.

For production deployment topology, enforcement boundaries, caching, batching,
and list-endpoint performance guidance, see
[Production deployment and performance](production-deployment-and-performance.md).

## PostgreSQL store

Use `en-postgres` when storing real tuples:

```haskell
import Data.Time (getCurrentTime)
import En.Postgres.Revision
import En.Postgres.TupleStore
import En.Reachability (compile)
import En.Revision (DatastoreId (..))
import En.Schema qualified as Schema

graph <- either (fail . show) pure (compile schema)

let config =
        ConsistencyConfig
            { datastoreId = DatastoreId "my-en-datastore"
            , schemaHash = Schema.schemaHash schema
            }
    tupleStore = postgresTupleStoreIO connection config
    consistencyStore =
        postgresConsistencyStore
            config
            getCurrentTime
            tupleStore.optimizedRevision
            tupleStore.headRevision
```

The PostgreSQL implementation stores revisions as `pg_snapshot` values and
tokens encode the datastore id, schema hash, revision, and optional expiry.

Before writing tuples, run the migrations from `en-migrations`. The demo server
prints the migrations directory on startup if the database is missing the
required schema.

## Standalone server

`en-server` starts an HTTP service. Set `EN_SCHEMA_PATH` to load your
application schema from a text file at startup:

```shell
EN_DATABASE_URL='postgresql://user@localhost:5432/en' \
EN_SCHEMA_PATH=/etc/en/schema.en \
EN_PORT=8080 \
  en-server
```

Environment variables:

| Variable | Required | Meaning |
| --- | --- | --- |
| `EN_DATABASE_URL` | yes | PostgreSQL connection string passed to Hasql |
| `EN_SCHEMA_PATH` | no | Path to a text schema file. When set, the server loads, parses, validates, hashes, and compiles this schema at startup. When unset, the server warns and serves the built-in demo schema. |
| `EN_PORT` | no | HTTP port, default `8080` |
| `EN_GC_WINDOW` | no | Consistency-token garbage-collection window, default `24 hours` |
| `EN_OPTIMIZED_REVISION_CACHE_TTL_MS` | no | Positive TTL in milliseconds for the optimized-revision cache; missing or `0` disables it |
| `EN_TUPLE_READ_CACHE_MAX_ENTRIES` | no | Positive maximum tuple-read cache entries; missing or `0` disables it |
| `EN_DECISION_CACHE_MAX_ENTRIES` | no | Positive maximum decision/subproblem cache entries; missing or `0` disables it |
| `EN_POOL_SIZE` | no | Maximum pooled PostgreSQL connections, default `10`. Must be at least `1` |
| `EN_POOL_ACQUISITION_TIMEOUT_MS` | no | How long a request waits for a free connection before failing, default `10000` |
| `EN_POOL_IDLENESS_TIMEOUT_MS` | no | Close a connection unused for this long, default `600000` (10 minutes) |
| `EN_POOL_MAX_LIFETIME_MS` | no | Close a connection older than this regardless of use, default `3600000` (1 hour) |
| `EN_MAINTENANCE_INTERVAL_SECONDS` | no | Seconds between background maintenance passes, default `600`. `0` disables maintenance |
| `EN_MAINTENANCE_BATCH_SIZE` | no | Rows deleted per maintenance statement, default `1000`. Must be at least `1` |

Authentication, rate limiting, and TLS add seven more variables, documented under
[Authentication, rate limiting, and TLS](#authentication-rate-limiting-and-tls).
At least one API key is required for startup.

### Connection pooling

`en-server` serves every request from a pool of PostgreSQL connections, so
concurrent requests do not serialize on a single socket. Connections are
established lazily, but the server runs one `SELECT 1` through the pool before it
binds the port, so an unreachable `EN_DATABASE_URL` fails startup rather than the
first request.

Size the pool to the concurrent database-touching work you expect, and keep
`EN_POOL_SIZE` times your replica count comfortably under PostgreSQL's
`max_connections` (default `100`). `EN_POOL_MAX_LIFETIME_MS` defaults to one hour
so connections cycle through server-side configuration changes.

A PostgreSQL restart no longer requires restarting `en-server`: the pool discards
connections killed by the restart and establishes fresh ones on demand. Recovery
is not instantaneous, and it costs more requests than one might expect.

Each connection left stale by the restart fails **twice** before the pool drops
it. The first session on a stale connection reports a misleading statement-level
error, which `hasql-pool` does not treat as grounds for discarding the
connection, so it returns to the pool:

```text
{"error":"StoreError \"Unexpected number of rows\n  sql: SELECT pg_current_snapshot()::text\n  expectedMin: 1\n  expectedMax: 1\n  actual: 1\"}
```

(`expectedMin: 1, expectedMax: 1, actual: 1` is self-contradictory — read it as
"the connection died", not as a decoding bug.) The second session on that same
connection reports the connection-level error, and the pool discards it:

```text
{"error":"StoreError \"Connection error\n  reason: no connection to the server\""}
```

So a restart costs roughly `2 × (established connections)` failed requests — with
five established connections, ten `500`s, recovering on the eleventh. Note that a
single API request runs several database sessions, and each borrows its own
pooled connection, so one failing request may burn more than one stale
connection. Established connections are usually fewer than `EN_POOL_SIZE`, since
the pool grows lazily under load.

Clients must retry `5xx` responses. A burst of the two errors above immediately
after a database restart is expected; sustained occurrences are not. Also expect
`timed out acquiring a pooled database connection` when the pool is exhausted for
longer than `EN_POOL_ACQUISITION_TIMEOUT_MS` — that one means `EN_POOL_SIZE` is
too small for the offered load, not that the database is down.

With `EN_SCHEMA_PATH` set, startup logs the loaded path and the active schema
hash:

```text
Loaded schema from /etc/en/schema.en
Schema hash: fnv1a64:...
```

If the schema file is missing, malformed, or invalid, startup exits non-zero
before binding the HTTP port. Changing the schema changes the schema hash, so
old consistency tokens from a previous schema hash are rejected by the existing
token validation path.

When `EN_SCHEMA_PATH` is unset, the built-in schema is intentionally small:

- Object types: `user`, `space`
- Direct relation: `space#viewer`
- Permission: `space#view = viewer`

Treat the built-in schema as a local smoke-test fallback. Production service
deployments should set `EN_SCHEMA_PATH`; Haskell applications that do not need a
shared HTTP boundary can still embed `en-core` directly.

### Health and readiness probes

Two unauthenticated endpoints, for orchestrators:

| Path | Meaning | Responses |
| --- | --- | --- |
| `GET /healthz` | Liveness: the process can serve HTTP | Always `200 {"status":"ok"}` |
| `GET /readyz` | Readiness: the process should receive traffic | `200 {"status":"ok"}`, or `503` with the error envelope |

They are the only paths exempt from authentication and rate limiting, since a
probe cannot conveniently carry credentials.

`/healthz` never consults PostgreSQL. Liveness means "restart me if this stops
answering", and restarting every replica during a database outage helps nothing.
It answers `200` while the database is down.

`/readyz` runs a `SELECT 1` through the connection pool. While PostgreSQL is
unreachable it returns the same envelope a request would get:

```json
{"code": "store_error", "message": "database unreachable", "retryable": true}
```

The probe pings twice before reporting unready. As described under "Connection
pooling", the first session on a connection left stale by a restart fails at the
statement level and is returned to the pool rather than discarded; a single-shot
probe would flap to unready against a healthy database and would spend a failure
that a real request could have absorbed. Readiness recovers on the first probe
after PostgreSQL comes back, with no `en-server` restart.

### Graceful shutdown

`SIGTERM` and `SIGINT` both mean: stop accepting connections, let in-flight
requests finish, release the connection pool, exit `0`. The drain is capped at 30
seconds. A request already being served completes normally; a connection opened
after the signal is refused.

```text
en-server: drained in-flight requests; shutting down
```

`SIGINT` is handled explicitly rather than left to the GHC runtime, whose default
throws to the main thread and aborts in-flight requests.

### Request logging

Every request that reaches a handler produces exactly one JSON object on stdout:

```json
{"time":"2026-07-09T01:29:12.087595Z","requestId":"test-123","caller":"dev","method":"POST","path":"/v1/check","status":200,"durationMs":2.399}
```

`caller` is the authenticated key name, or `null` when `EN_AUTH_DISABLED=true`.
Durations come from the monotonic clock, so a clock step cannot produce a negative
latency. Neither headers nor bodies are logged: en's request bodies name subjects
and objects, and its `Authorization` header carries a bearer secret.

Probe requests to `/healthz` and `/readyz` are not logged — they fire every few
seconds and have nothing to correlate. The `401`, `403`, and `429` responses that
authentication and rate limiting short-circuit are also not logged, because those
middlewares run outside the logger; count them at your proxy.

Each response carries an `X-Request-Id` header. An inbound `X-Request-Id` is
reused so a trace survives a reverse proxy, provided it is at most 128 bytes of
printable non-space ASCII; anything else is replaced with a fresh UUID. **If
`en-server` is reachable by untrusted clients, strip the header at the edge** —
a caller that chooses its own request id can make two requests look like one.

### Metrics

`GET /metrics` serves the Prometheus text exposition format. It is **not** exempt
from authentication: give the scraper a read-only key.

```shell
curl -sS -H "Authorization: Bearer $EN_API_KEY" localhost:8080/metrics
```

| Metric | Type | Labels |
| --- | --- | --- |
| `en_http_requests_total` | counter | `path`, `status` |
| `en_http_request_duration_seconds_sum` | counter | `path`, `status` |
| `en_http_request_duration_seconds_count` | counter | `path`, `status` |
| `en_cache_hits_total` | counter | `cache` |
| `en_cache_misses_total` | counter | `cache` |
| `en_cache_inserts_total` | counter | `cache` |
| `en_cache_evictions_total` | counter | `cache` |

`path` is the route below the version prefix (`check`, `batch-check`, `lookup`,
`expand`, `relationships`, `openapi.json`, `healthz`, `readyz`, `metrics`), or
`other` for anything unrecognized — so a caller cannot mint unbounded time series
by requesting random paths. `status` is the status class (`2xx`, `4xx`, `5xx`).
`cache` is `decision` or `tuple_read`; both report zeros while the corresponding
cache is disabled.

Divide `..._duration_seconds_sum` by `..._duration_seconds_count` for mean latency.
There are no histograms, so there are no quantiles; if you need them, the counters
are cheap to replace with `prometheus-client`.

All counters are in-process and reset when the process restarts, which is what
Prometheus expects. They are per-replica: aggregate across replicas at query time.

### Background maintenance

en never physically deletes on the write path. Deleting a relationship sets the row's
`deleted_xid` — a soft delete, so a read at an older snapshot still sees it — and
every write inserts one bookkeeping row into `en_transaction`. Both would accumulate
without bound.

`en-server` therefore runs a maintenance pass every `EN_MAINTENANCE_INTERVAL_SECONDS`
(default 600). Each pass computes the **garbage-collection horizon** — the oldest
transaction id still protected by `EN_GC_WINDOW` — and then deletes, in batches of
`EN_MAINTENANCE_BATCH_SIZE`:

- soft-deleted `relation_tuple` rows whose `deleted_xid` is behind the horizon, and
- `en_transaction` rows whose `xid` is behind the horizon.

Nothing inside the retention window is ever removed, so a consistency token that still
validates can always be resolved. The horizon comes from the same query token
validation uses, so the reaper, the pruner, and token validation cannot disagree.

Each pass logs one line:

```text
maintenance: horizon=27332 reaped=38510 pruned=0 batches=40
```

A pass that fails — most plausibly because PostgreSQL is restarting — logs
`maintenance: pass failed: …` and the schedule continues.

Every batch is its own transaction. This bounds the row locks and the write-ahead log a
single statement produces, and it makes the pass interruptible: `SIGTERM` during a pass
cancels it immediately (the server does not wait for it to finish), every batch already
committed stays committed, and the next pass — in this process or the next one — picks
up the remainder.

Pruning `en_transaction` is not merely housekeeping. Resolving consistency runs a
`min(xid)` over the retention window on **every read**, and PostgreSQL answers it by
walking the `xid` primary key until it reaches the first row inside the window. Rows
behind the horizon are exactly the rows it must skip. With a 50,000-row backlog that
scan touched 606 buffers and took 4.7 ms per read; with the backlog drained it touches
2 buffers and takes 0.04 ms. **Do not run with `EN_MAINTENANCE_INTERVAL_SECONDS=0` in
production**: read latency will grow linearly with your lifetime write count. Disable it
only for one-shot environments and debugging.

Two consequences of `EN_GC_WINDOW` worth stating plainly. It is simultaneously the
retention window for garbage and the validity window for consistency tokens — shrinking
it to make maintenance more aggressive also invalidates tokens sooner. And if no write
occurs for a full window, `en_transaction` legitimately drains to zero; the horizon then
falls back to `pg_snapshot_xmin(pg_current_snapshot())`, which is the same value the
query would have returned with the old rows still present.

## Authentication, rate limiting, and TLS

`en-server` authenticates every request. It will not start without either a
configured API key or an explicit opt-out, because an authorization service that
answers anonymous callers lets anyone grant themselves any permission.

| Variable | Required | Meaning |
| --- | --- | --- |
| `EN_API_KEYS_READ_WRITE` | see below | Comma-separated `name:secret` entries whose holders may call every endpoint |
| `EN_API_KEYS_READ_ONLY` | see below | Comma-separated `name:secret` entries whose holders may call only the query endpoints |
| `EN_AUTH_DISABLED` | no | `true` serves without authentication. Local development only; ignored when any key is configured |
| `EN_RATE_LIMIT_RPS` | no | Sustained requests per second allowed per caller. Missing or `0` disables rate limiting |
| `EN_RATE_LIMIT_BURST` | no | Token-bucket capacity per caller, at least `1`. Defaults to `EN_RATE_LIMIT_RPS` |
| `EN_TLS_CERT_FILE` | no | PEM certificate path. Must be set together with `EN_TLS_KEY_FILE` |
| `EN_TLS_KEY_FILE` | no | PEM private key path. Must be set together with `EN_TLS_CERT_FILE` |

At least one of `EN_API_KEYS_READ_WRITE` and `EN_API_KEYS_READ_ONLY` is required
unless `EN_AUTH_DISABLED=true`. Each secret must be at least 16 bytes, and names
must be unique across both lists. A malformed entry aborts startup rather than
being skipped: authentication configuration never partially parses.

```shell
EN_DATABASE_URL='postgresql://user@localhost:5432/en' \
EN_API_KEYS_READ_WRITE='deployer:a-long-random-write-secret' \
EN_API_KEYS_READ_ONLY='web-api:a-long-random-read-secret,reporting:another-read-secret' \
EN_RATE_LIMIT_RPS=200 \
EN_RATE_LIMIT_BURST=400 \
  en-server
```

Callers present their secret as a bearer token:

```shell
curl -X POST https://en.internal:8080/v1/check \
  -H 'Authorization: Bearer a-long-random-read-secret' \
  -H 'content-type: application/json' \
  -d '{ ... }'
```

Three failures are reported with a machine-readable `code`:

| Status | `code` | Cause |
| --- | --- | --- |
| `401` | `unauthenticated` | No `Authorization` header, a non-bearer scheme, or an unknown secret. The response carries `WWW-Authenticate: Bearer` |
| `403` | `permission_denied` | A read-only key called a write route under `/v1/relationships` |
| `429` | `rate_limited` | The caller exhausted its token bucket. The response carries `Retry-After` |

```text
$ curl -si localhost:8080/v1/check -H 'content-type: application/json' -d '{}'
HTTP/1.1 401 Unauthorized
Content-Type: application/json
WWW-Authenticate: Bearer

{"code":"unauthenticated","message":"missing or invalid API key","retryable":false}
```

These use the same `{code, message, retryable}` envelope as every other error. Of the
three, only `rate_limited` is retryable — the caller's token bucket refills, whereas a
missing or read-only key does not fix itself.

Rate limiting is a per-caller token bucket, keyed by the key *name*, so one
noisy caller cannot exhaust another's budget. It is a per-process limiter:
running several `en-server` replicas multiplies the effective limit by the
replica count. Requests to `/healthz` and `/readyz` are exempt from both
authentication and rate limiting so orchestrator probes need no credentials.

Keys are read once at startup. **Rotating or revoking a key requires a restart.**

### Transport security

Bearer keys are only as secret as the transport that carries them. Never let
them traverse a plaintext network.

The recommended posture is to terminate TLS at a reverse proxy (nginx, Caddy, or
an ingress controller) in front of `en-server`, keeping certificate rotation out
of en's process. When nothing sits in front of it, `en-server` serves TLS
directly if given a certificate and key:

```shell
EN_TLS_CERT_FILE=/etc/en/tls.crt \
EN_TLS_KEY_FILE=/etc/en/tls.key \
  en-server
```

Setting exactly one of the two aborts startup. With neither set, the server logs
that it is serving plaintext HTTP and expects a proxy to terminate TLS.

### Extending the credential check

The static key list is the baseline mechanism, not the ceiling. Authentication
is a WAI middleware wrapping the whole application, so a stronger verifier —
mTLS client certificates, or a verified shomei identity — replaces the
credential check inside that middleware without touching any handler or route.

## Servant API

`en-servant` exposes these endpoints:

| Method | Path | Request type | Response type |
| --- | --- | --- | --- |
| `POST` | `/v1/relationships` | `WriteTuplesRequestWire` | `WriteTuplesResponseWire` |
| `POST` | `/v1/relationships/delete` | `DeleteTuplesRequestWire` | `WriteTuplesResponseWire` |
| `POST` | `/v1/check` | `CheckRequestWire` | `CheckResponseWire` |
| `POST` | `/v1/batch-check` | `BatchCheckRequestWire` | `BatchCheckResponseWire` |
| `POST` | `/v1/lookup` | `LookupRequestWire` | `LookupPageWire` |
| `POST` | `/v1/expand` | `ExpandRequestWire` | `ExpandTreeWire` |

Deletion is a `POST` to `/v1/relationships/delete` rather than a `DELETE` carrying
a request body, because HTTP intermediaries are permitted to drop a `DELETE` body.

### API versioning

The wire contract is versioned by path, and `/v1` is current. The JSON encodings
are hand-written and stable: every sum type carries a named string discriminator
rather than a Haskell constructor name.

| Type | Discriminator | Values |
| --- | --- | --- |
| subject | `kind` | `id`, `set`, `wildcard` |
| consistency | `mode` | `minimizeLatency`, `fullyConsistent`, `atLeastAsFresh`, `atExactSnapshot` |
| decision | `result` | `allowed`, `denied`, `conditional` |
| page state | `status` | `exhausted`, `hasMore`, `truncated` |
| caveat value | `type` | `text`, `bool`, `integer`, `timestamp`, `enum` |
| expand node | `kind` | `subject`, `userset`, `caveated` |

An unrecognized discriminator value is rejected with `400 malformed_request_body`;
it never falls through to a default.

**This was a one-time breaking change.** Earlier builds served the same operations
on unversioned paths (`POST /tuples`, `DELETE /tuples`, `POST /check`, …) with
aeson's generic sum encoding, so a subject was written `{"tag":"SubjectIdWire",
"contents":{…}}` and a decision read back as `{"tag":"AllowedWire"}`. Those paths
now return `404`. Future breaking changes ship as `/v2` served alongside `/v1`,
rather than mutating an existing operation.

A worked exchange, writing a tuple and then checking against the token it returns:

```shell
curl -sS -X POST localhost:8080/v1/relationships \
  -H 'Authorization: Bearer a-long-random-write-secret' \
  -H 'content-type: application/json' \
  -d '{"tuples":[{"object":{"objectType":"space","objectId":"project-x"},
                  "relation":"viewer",
                  "subject":{"kind":"id","objectType":"user","objectId":"alice"},
                  "caveat":null}]}'
# {"token":"en1.…"}

curl -sS -X POST localhost:8080/v1/check \
  -H 'Authorization: Bearer a-long-random-read-secret' \
  -H 'content-type: application/json' \
  -d '{"consistency":{"mode":"atLeastAsFresh","token":"en1.…"},
       "context":{"values":{}},
       "subject":{"kind":"id","objectType":"user","objectId":"alice"},
       "permission":"view",
       "object":{"objectType":"space","objectId":"project-x"}}'
# {"decision":{"result":"allowed"}}
```

### Machine-readable description

`GET /v1/openapi.json` serves an OpenAPI 3.1 document describing every operation, its
request and response schemas, and its error responses. It requires a bearer key like
any other endpoint (only `/healthz` and `/readyz` are exempt), and it does not describe
itself — `paths` contains exactly the six authorization operations.

```shell
curl -sS -H "Authorization: Bearer $EN_API_KEY" localhost:8080/v1/openapi.json \
  | jq -r '.paths | keys[]'
```

Each operation documents `200`, `400`, `422`, and `503`. Those statuses are not
hand-written prose: they are response alternatives of the operation's type in
`En.Servant.API`, so the document cannot drift from what the server returns.

### Error responses

Every error — engine, validation, body-decode, or authentication — is one JSON object:

```json
{"code": "invalid_consistency_token", "message": "…", "retryable": false}
```

Branch on `code`, which is stable. Never branch on `message`, which is prose and may
change. `retryable` is the whole retry policy: it is `true` only for `store_error`.

| Status | `code` | Meaning |
| --- | --- | --- |
| `400` | `unknown_relation` | The permission or relation is not in the active schema |
| `400` | `schema_violation` | A tuple referenced a subject or object the schema forbids |
| `400` | `missing_caveat_context` | A caveat needed context the request did not supply |
| `400` | `invalid_consistency_token` | The token is malformed or outside the GC window |
| `400` | `invalid_request` | A field failed validation (e.g. an empty `relation`) |
| `400` | `batch_too_large` | The batch exceeded the configured maximum |
| `400` | `malformed_request_body` | The body was not valid JSON, or a discriminator was unrecognized |
| `401` | `unauthenticated` | Missing, malformed, or unknown bearer key |
| `403` | `permission_denied` | A read-only key attempted a write |
| `404` | `not_found` | No such endpoint |
| `422` | `resolution_limit_exceeded` | The traversal exceeded its depth or breadth bound |
| `429` | `rate_limited` | The caller exhausted its token bucket. **Retryable** |
| `503` | `store_error` | The tuple store failed. **Retryable** |

A `503 store_error` never carries the underlying SQL or bound parameters; those go to
the server's stderr for the operator. A PostgreSQL restart surfaces as a short burst of
retryable `503`s (see "Connection pooling" above) rather than as a server that must be
restarted.

Two responses fall outside the envelope, because Servant raises them before any handler
runs and before the error formatter is reached: `405 Method Not Allowed` (wrong verb for
a real path) and `415 Unsupported Media Type` (a `Content-Type` other than
`application/json`). Both have empty bodies. Each means the client is calling the API
incorrectly, not that a runtime condition occurred.

The typed Haskell client in `en-client` is derived from the same Servant API type,
so it tracks this surface automatically. Point its `BaseUrl` at the host root; the
`/v1` prefix lives in the API type, not the base URL. Every operation returns an
`EnResult`, so engine faults arrive as values to pattern-match rather than as an opaque
`ClientError`:

```haskell
result <- runClientM (enClient.check request) clientEnv
case result of
    Right (EnOk response) -> useDecision response.decision
    Right (EnUnavailable envelope) | envelope.retryable -> retryLater
    Right (EnClientError envelope) -> reportBug envelope.code
    Right other -> reportBug (Text.pack (show other))
    Left transportError -> reportTransport transportError
```

```haskell
import En.Client
import Servant.Client (ClientM)

runCheck :: CheckRequestWire -> ClientM CheckResponseWire
runCheck request =
    enClient.check request
```

## Authorization helper for host routes

Servant applications can use `requirePermission` to fail closed in handlers:

```haskell
requirePermission
    authorizationEnv
    consistency
    context
    subject
    (RelationName "view")
    object
```

It returns `()` on `Allowed` and throws a `403` with code `permission_denied` on
`Denied` or `Conditional`. Engine errors are thrown as the same envelope and status
that the en endpoints return them with — `400`, `422`, or `503` — not as a blanket
`500`.

## Operational guidance

- Never expose `en-server` on a plaintext network. Terminate TLS at a reverse
  proxy or set `EN_TLS_CERT_FILE`/`EN_TLS_KEY_FILE`.
- Keys are read at startup, so rotating or revoking one requires a restart. Give
  each caller its own named key so a single revocation does not disrupt others.
- Grant `EN_API_KEYS_READ_ONLY` to every caller that only asks questions; reserve
  read-write keys for the services that write relationships.
- Compile and validate the active schema during startup.
- Keep `datastoreId` stable for a PostgreSQL datastore. Changing it invalidates
  existing consistency tokens.
- Changing the schema changes `schemaHash`; old tokens from another schema hash
  are rejected.
- Point liveness at `/healthz` and readiness at `/readyz`; never point liveness at
  a database-dependent probe.
- Send `SIGTERM` to deploy. Give the process at least 30 seconds to drain before
  `SIGKILL`, matching the shutdown cap.
- Leave background maintenance enabled. Watch the `reaped` and `pruned` counts in its
  log line: a `reaped` that stays at the batch size every pass means the backlog is
  growing faster than the interval drains it, so shorten the interval or raise the
  batch size.
- Monitor `check` and `lookup` latency, from `/metrics` or from the `durationMs`
  field of the request log. Once adopted, `en` is on the read path for protected
  list and object endpoints.
- Prefer `MinimizeLatency` and `AtLeastAsFresh` for request traffic; use
  `FullyConsistent` sparingly.
- Treat lookup and expand cursors as opaque.
- Keep relation tuples low-cardinality and slow-changing. Store high-volume
  domain facts in the owning service and use `lookup` to produce small filter
  sets.
