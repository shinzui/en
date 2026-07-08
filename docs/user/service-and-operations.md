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

Authentication, rate limiting, and TLS add seven more variables, documented under
[Authentication, rate limiting, and TLS](#authentication-rate-limiting-and-tls).
At least one API key is required for startup.

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
curl -X POST https://en.internal:8080/check \
  -H 'Authorization: Bearer a-long-random-read-secret' \
  -H 'content-type: application/json' \
  -d '{ ... }'
```

Three failures are reported with a machine-readable `code`:

| Status | `code` | Cause |
| --- | --- | --- |
| `401` | `unauthenticated` | No `Authorization` header, a non-bearer scheme, or an unknown secret. The response carries `WWW-Authenticate: Bearer` |
| `403` | `permission_denied` | A read-only key called `POST /tuples` or `DELETE /tuples` |
| `429` | `rate_limited` | The caller exhausted its token bucket. The response carries `Retry-After` |

```text
$ curl -si localhost:8080/check -H 'content-type: application/json' -d '{}'
HTTP/1.1 401 Unauthorized
Content-Type: application/json
WWW-Authenticate: Bearer

{"code":"unauthenticated","error":"missing or invalid API key"}
```

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
| `POST` | `/tuples` | `WriteTuplesRequestWire` | `WriteTuplesResponseWire` |
| `DELETE` | `/tuples` | `DeleteTuplesRequestWire` | `WriteTuplesResponseWire` |
| `POST` | `/check` | `CheckRequestWire` | `CheckResponseWire` |
| `POST` | `/lookup` | `LookupRequestWire` | `LookupPageWire` |
| `POST` | `/expand` | `ExpandRequestWire` | `ExpandTreeWire` |

The current wire types use derived Aeson encodings from the Haskell
constructors in `En.Servant.API`. Prefer the typed Haskell client from
`en-client` until the project commits to a stable hand-designed JSON format.

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

It returns `()` on `Allowed`, throws `403` on `Denied` or `Conditional`, and
throws `500` on engine errors.

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
- Monitor `check` and `lookup` latency. Once adopted, `en` is on the read path
  for protected list and object endpoints.
- Prefer `MinimizeLatency` and `AtLeastAsFresh` for request traffic; use
  `FullyConsistent` sparingly.
- Treat lookup and expand cursors as opaque.
- Keep relation tuples low-cardinality and slow-changing. Store high-volume
  domain facts in the owning service and use `lookup` to produce small filter
  sets.
