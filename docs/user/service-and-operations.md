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

`en-server` starts an HTTP service with a built-in demo schema:

```shell
EN_DATABASE_URL='postgresql://user@localhost:5432/en' EN_PORT=8080 en-server
```

Environment variables:

| Variable | Required | Meaning |
| --- | --- | --- |
| `EN_DATABASE_URL` | yes | PostgreSQL connection string passed to Hasql |
| `EN_PORT` | no | HTTP port, default `8080` |

The built-in schema is intentionally small:

- Object types: `user`, `space`
- Direct relation: `space#viewer`
- Permission: `space#view = viewer`

Applications with domain-specific schemas should normally embed `en-core` and
`en-servant` or provide their own service executable rather than relying on the
demo schema.

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
