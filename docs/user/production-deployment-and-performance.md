# Production Deployment and Performance

This guide describes how to run `en` in production and how to keep
authorization checks from becoming a runtime fan-out across every
microservice.

The short version:

- Put authorization checks at enforcement points, not at every internal hop.
- Embed `en-core` in Haskell services when that keeps the path simpler.
- Run a dedicated service only when you need a shared HTTP boundary.
- Use `lookup` to build small read filters for list endpoints.
- Keep high-volume domain facts in the owning service database.
- Use consistency tokens precisely; do not make every read fully consistent.

`en` follows the same broad deployment lessons as SpiceDB and OpenFGA, but is
sized as a Haskell toolkit for one organization on PostgreSQL rather than a
globally distributed authorization product.

## Deployment Shapes

`en` has two production shapes.

### Embedded Library

Use embedded mode when the protected service is Haskell and can depend on the
same schema and tuple store libraries as the rest of the application:

```haskell
graph <- either (fail . show) pure (compile schema)

let config =
        ConsistencyConfig
            { datastoreId = DatastoreId "primary-en"
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

The embedded path avoids an HTTP hop and lets the host service own request
timeouts, connection pools, metrics, and failure behavior. It is usually the
right choice for Haskell services that already run near the application
database.

Use embedded mode when:

- The caller is Haskell.
- The service owns the protected resource or is a primary enforcement point.
- You want one process-level request budget rather than a service-to-service
  authorization call.
- You can deploy schema changes with the application code.

### Dedicated Service

Use a dedicated service when non-Haskell callers need the same authorization
model or when you want a single network boundary for authorization decisions.

`en-server` can load a domain-specific schema from a text file at startup. Write
the schema in the same language accepted by the `[schema| ... |]` quasi-quoter,
set `EN_SCHEMA_PATH=/path/to/schema.en`, and start the prebuilt server. The
server reads, parses, validates, hashes, and compiles that schema before it
connects to PostgreSQL or binds the HTTP port. If the file is missing,
malformed, or invalid, startup fails closed rather than serving the built-in
demo model.

```shell
EN_DATABASE_URL='postgresql://user@localhost:5432/en' \
EN_SCHEMA_PATH=/etc/en/schema.en \
EN_PORT=8080 \
  en-server
```

When `EN_SCHEMA_PATH` is unset, `en-server` logs a warning and serves the small
demo schema. That fallback is useful for local smoke tests, not production.
Haskell applications may still choose the embedded-library path when compiling
the schema into the host application is simpler than operating a shared HTTP
service.

Treat the dedicated service as a read-path dependency. It should be deployed
like a database-adjacent infrastructure service: low network latency to
PostgreSQL, bounded request concurrency, explicit health checks, and alerting
on latency and error rate.

## Enforcement Boundaries

Do not make every microservice call `en` for every internal request. That
creates latency fan-out and couples unrelated service-to-service calls to the
authorization graph.

Prefer this rule:

- The user-facing API, backend-for-frontend, or resource-owning service enforces
  user-to-object authorization.
- Downstream services trust the narrowed request plus service identity when they
  are performing work on behalf of the already-authorized service.
- A downstream service calls `en` only when it independently owns a protected
  resource or applies a different authorization decision.

For example, a document service should check whether `user:alice` can view
`document:roadmap`. A thumbnail service called by the document service should
not repeat that same object check unless thumbnails are independently exposed
as protected objects.

This keeps authorization centralized in meaning, but not sprayed across every
runtime hop.

### Carrying a decision downstream with Biscuit

When a gateway has already made an `en` decision and needs to forward the request
through several services, the optional `en-biscuit` package can turn that
`Allowed` decision into a short-lived, signed Biscuit token that downstream
services verify locally — avoiding a repeat `en` call for the same
subject/object/scope. Biscuit does not authenticate the caller (Shomei does) and
is not a permission store; it carries a bounded proof of one decision. See
[Biscuit decision tokens](biscuit-decision-tokens.md) for the full flow, the
minting/verification API, and the rules for when a downstream must still call
`en`.

## Tuple Ownership

The service that owns a domain event should usually own the write that changes
authorization relationships.

Examples:

- An organization service writes `organization:acme#member@user:alice`.
- A project service writes `project:alpha#owner@user:bob`.
- A sharing workflow writes `document:roadmap#viewer@group:finance#member`.
- A delegation workflow writes caveated grants such as time-bounded access.

Write tuple changes transactionally with the domain change when possible. If
that is not possible, make tuple writes idempotent and build a reconciliation
job that can repair missing or stale tuples from the source of truth.

Schemas should fail closed. If a tuple write is missed, the result should be
less access, not accidental access.

## PostgreSQL

Production deployments should use `en-postgres` and run the migrations from
`en-migrations` before serving traffic.

Keep these values stable:

- `datastoreId`: identifies the backing authorization datastore. Changing it
  invalidates existing consistency tokens.
- `schemaHash`: derived from the active schema. Changing the schema changes the
  hash, and old tokens from another schema hash are rejected.

The PostgreSQL store uses `pg_snapshot` revisions and xid-based soft deletion.
Reads at a resolved revision must be served by the tuple store paired with the
same consistency store that produced or decoded the token.

Operationally:

- Put `en` close to PostgreSQL in network terms.
- Size the Postgres connection pool explicitly.
- Separate read-heavy `en` traffic from unrelated application contention when
  possible.
- Monitor slow queries and tuple table growth.
- Keep tuple cardinality bounded by modeling only relationship facts, not every
  high-volume domain object fact.

## Consistency Modes

Every read takes a `Consistency` value. Choose it per request.

| Mode | Production use |
| --- | --- |
| `MinimizeLatency` | Default for ordinary request traffic that can tolerate a recent optimized revision. |
| `AtLeastAsFresh token` | Use after writes when the user must see the effect of their own change. |
| `AtExactSnapshot token` | Use for short pagination windows or repeatable reads at one snapshot. |
| `FullyConsistent` | Use sparingly for operations that truly require the current head revision. |

Prefer `MinimizeLatency` and `AtLeastAsFresh` on normal request paths. They are
the modes that make caching and revision sharing effective.

Avoid making `FullyConsistent` the default. It pushes every request to the head
revision and reduces the chance that repeated checks can share work.

After writes, return or carry the consistency token through the user workflow:

```haskell
token <- tupleStore.writeTuples tuples

decision <-
    check
        consistencyStore
        tupleStore
        graph
        (AtLeastAsFresh token)
        context
        subject
        permission
        object
```

## List Endpoints

List endpoints are where ReBAC systems most often become slow. Avoid one
`check` per row.

Use `lookup` when the reachable object set is small enough to become a database
predicate:

1. Call `lookup` for the subject, permission, and object type.
2. Keep objects whose decision is `Allowed`.
3. Apply those object ids, spaces, folders, or labels as a filter in the owning
   service database.
4. Page and sort in the owning service database.

For example, if activities are stored in a service table and visibility is
derived from spaces:

```sql
SELECT *
FROM activity
WHERE space_id = ANY(:reachable_spaces)
ORDER BY occurred_at DESC
LIMIT 50
```

Do not write every activity row into `en` just so `lookup` can enumerate
activities. Store the activity's high-volume facts in the activity service and
use `en` to answer the small graph question: which spaces, folders, projects,
or visibility labels can the subject reach?

Use `check` for object detail endpoints and mutations:

- `GET /documents/:id`: check `view` on that document.
- `PATCH /documents/:id`: check `edit` on that document.
- `POST /projects/:id/archive`: check `archive` on that project.

Use `lookup` for broad reads:

- `GET /documents`: lookup reachable folders or documents, then query the
  document database.
- `GET /activity`: lookup reachable spaces or visibility labels, then query the
  activity database.
- `GET /inbox`: lookup reachable workspaces or queues, then query the inbox
  database.

## High-Cardinality Data

`en` should store low-cardinality, slow-changing relationship facts:

- Memberships.
- Ownership.
- Sharing grants.
- Delegations.
- Parent-child containment.
- Organization, team, project, folder, or space links.

Do not put high-cardinality, high-churn facts into `en`:

- Activity rows.
- Search documents.
- Event stream entries.
- Per-view read marks.
- Rapidly changing status fields.
- Facts that change on every ingest or background job.

Those facts belong in the owning service with normal indexes. `en` should
produce a small authorization filter that the owning service applies to those
indexes.

## Batching

When a UI or API already has a bounded page of candidate objects, batch checks
are preferable to many single checks.

`en` exposes single `check`, `lookup`, and `batch-check` operations. If a
workload needs repeated checks for tables, dashboards, or mixed object pages,
prefer `batch-check` over many independent service calls.

A production `checkMany` should:

- Resolve consistency once for the whole batch.
- Deduplicate identical `(subject, permission, object, context)` checks.
- Reuse the compiled graph.
- Run bounded concurrency.
- Return one decision per input item.
- Report aggregate datastore query counts and latency.

This mirrors the shape used by OpenFGA's BatchCheck implementation: deduplicate
by cache key, execute with a maximum concurrency, then map duplicate inputs back
to their original correlation ids.

## Caching

`en` ships bounded in-process caches for three layers:

- Optimized revision cache: shares the `MinimizeLatency` revision for a bounded
  time window.
- Tuple-read cache: caches object-relation and reverse-userset read pages at a
  resolved revision.
- Decision/subproblem cache: caches repeated `check` work and `lookup`
  confirmation checks at a resolved revision.

The standalone `en-server` enables these caches with environment variables.
Missing values and `0` disable the cache.

| Variable | Meaning |
| --- | --- |
| `EN_OPTIMIZED_REVISION_CACHE_TTL_MS` | Positive TTL in milliseconds for sharing optimized revisions. |
| `EN_TUPLE_READ_CACHE_MAX_ENTRIES` | Maximum tuple-read cache entries. |
| `EN_DECISION_CACHE_MAX_ENTRIES` | Maximum decision/subproblem cache entries for `/v1/check` and `/v1/lookup` confirmations. |

Malformed cache values fail startup. At startup, `en-server` logs whether each
cache is disabled or enabled and its configured size/window.

Decision cache keys include:

- Datastore id.
- Schema hash.
- Resolved revision.
- Subject.
- Permission or relation.
- Object.
- Caveat context that affects the answer.

Tuple-read cache keys include the resolved revision and the read shape. Cache
entries must not outlive the revision or schema assumptions that made them
correct. A decision computed at one schema hash must not be reused under another
schema hash.

`FullyConsistent` still resolves the current head revision. `AtLeastAsFresh`
first resolves a revision that satisfies the supplied token; cache reuse only
happens after that resolution and only for the resolved revision. Cache settings
therefore affect latency and memory, not authorization semantics.

The caches are per process and per service instance. There is no distributed
invalidation, distributed cache, Watch API, or materialized authorization index
in this repository yet. Load balancing affects hit rate; a small, stable pool
of larger instances can have better cache behavior than a large pool of tiny
instances.

The `/v1/batch-check` endpoint uses `checkMany`, which resolves consistency once
and shares subproblem work within the request. It does not yet use the
cross-request decision cache directly. It still benefits from the optimized
revision and tuple-read caches when those are enabled.

If using embedded mode, cache ownership belongs to the host service. Be careful
not to create subtly different cache semantics in every caller. The library
exposes cache statistics for embedded instrumentation; the standalone server
currently logs cache configuration at startup but does not expose a metrics
endpoint.

## Materialized Authorization Indexes

Live `lookup` is for bounded enumeration. It is not the right tool when:

- A subject can access thousands or millions of objects of a type.
- The user needs arbitrary search and sort across a huge result set.
- The accessible set must be intersected with high-volume domain filters.
- Paginating through all accessible ids before querying the domain database
  would be slower than the user's request budget.

For those workloads, maintain a local authorization projection in the owning
service:

1. Consume relationship changes or rebuild from the domain source of truth.
2. Flatten the relationships needed for the service's search path.
3. Query the local projection together with the domain table.
4. Run final `check` calls on returned candidates when the projection is
   asynchronous or lossy.

This is a future extension point for `en`; the current repository does not yet
provide a Watch API or materialized reverse index. Until it does, build
projections from the owning service's domain events or reconciliation jobs.

## Schema Design for Performance

Schema shape has direct runtime cost.

Prefer:

- Shallow containment graphs.
- `Union` for additive access.
- `ComputedUserset` for aliases on the same object.
- `TupleToUserset` for parent, group, folder, project, and organization links.
- Container-level permissions that produce small lookup results.

Use carefully:

- `Intersection`.
- `Exclusion`.
- Deep recursive relations.
- Wildcards.
- Caveats on very hot paths.

`check` can usually handle complex rewrites for one object. `lookup` is more
sensitive because it must enumerate candidates. Intersections and exclusions
often require candidate confirmation, buffering, or additional checks. Model
frequent list filters around relations that reverse cleanly.

Validate schemas in CI and at application startup. Treat schema changes like
database migrations: review them, test them with representative tuples, and
measure their effect on `check` and `lookup` latency.

## Timeouts and Limits

Every production call path should have explicit budgets:

- Request deadline.
- Maximum lookup page size.
- Maximum expand size.
- Maximum recursion depth.
- Maximum tuple read page size.
- Maximum batch size for any future `checkMany`.
- Maximum caveat context size.

Fail closed on authorization uncertainty. If the engine returns `Denied`,
`Conditional` without sufficient context, times out, or reports an engine error
on a protected operation, do not allow the operation.

For list endpoints, decide how to handle truncation before launch. Common
choices are:

- Return the visible page and continue with an opaque cursor.
- Refuse workflows that require complete enumeration.
- Move the endpoint to a materialized projection.

## Observability

Track `en` as a read-path dependency.

Metrics to collect:

- `check` count, latency, and error rate.
- `lookup` count, latency, page size, and truncation rate.
- `expand` count and latency.
- Tuple write and delete count.
- Consistency mode usage.
- Postgres query count and latency.
- Cache hit rate, if caches are added.
- Conditional decision count.
- Denied decision count.
- Timeout count.

Useful labels:

- Object type.
- Permission or relation.
- Consistency mode.
- Embedded vs service caller.
- Schema hash.
- Outcome: allowed, denied, conditional, error.

Avoid labels with raw object ids or user ids; they are high-cardinality and may
be sensitive.

Logs should include request ids, consistency mode, schema hash, operation name,
and structured engine errors. Do not log full caveat contexts unless they are
known to be safe.

## Availability and Failure Behavior

Authorization failures should be boring and predictable.

For protected writes and object reads:

- Fail closed if `en` is unavailable.
- Use short request deadlines.
- Surface a retryable service error rather than silently allowing access.

For list endpoints:

- Prefer returning an error over returning unfiltered data.
- If a cached or materialized projection is used, document its staleness window.
- Make empty-list semantics explicit. An authorization failure should not be
  indistinguishable from "the user has no resources" unless that is an
  intentional product decision.

For administrative break-glass flows:

- Keep them outside ordinary `en` checks or model them explicitly.
- Audit every use.
- Keep the path small and manually controlled.

## Security

`en` is authorization, not authentication. Compose it after identity has already
been established by `shomei` or another authentication layer.

Production service deployments should:

- Authenticate callers.
- Authorize which services may write tuples.
- Restrict tuple writes to the domain owner or a controlled orchestration path.
- Use TLS for service traffic.
- Avoid exposing raw `en` write APIs to browsers.
- Treat consistency tokens and cursors as opaque.
- Validate caveat context supplied by clients.

Do not put broad object-level permissions into long-lived JWTs as the main
authorization mechanism. JWT claims are useful for coarse authentication and
service identity; object-level ReBAC changes should be checked against the
relationship graph or a documented short-lived projection.

## Deployment Checklist

Before serving production traffic:

- [ ] Production schema is loaded from `EN_SCHEMA_PATH` or embedded in the host
      service, then compiled and validated at startup.
- [ ] `en-migrations` have run against the target PostgreSQL database.
- [ ] `datastoreId` is stable and environment-specific.
- [ ] Schema rollout plan handles `schemaHash` changes and old tokens.
- [ ] Every protected endpoint has an enforcement owner.
- [ ] List endpoints use `lookup`, database filters, batching, or projections;
      they do not perform unbounded N+1 checks.
- [ ] High-cardinality domain facts remain in the owning service database.
- [ ] Request deadlines and lookup limits are configured.
- [ ] Metrics and logs distinguish `Allowed`, `Denied`, `Conditional`, timeout,
      and engine error outcomes.
- [ ] Protected operations fail closed.
- [ ] Tuple writers are authenticated and authorized.
- [ ] Load tests cover representative schemas and relationship cardinalities.

## Reference Patterns

The local SpiceDB and OpenFGA checkouts are useful reference points:

- SpiceDB uses per-request consistency, ZedTokens, dispatch caches, schema
  caches, lookup-resource chunk caches, and explicit request limits.
- OpenFGA documents check query caches, iterator caches, ListObjects iterator
  caches, a cache controller, and immutable authorization model/type-system
  caches.
- OpenFGA's BatchCheck implementation deduplicates checks and runs bounded
  concurrency.
- OpenFGA's ListObjects server path wires deadlines, maximum results,
  concurrency, throttling, cache settings, and pipeline settings as first-class
  operational knobs.

`en` should borrow these operational patterns where they fit, while staying
honest about its current scope: typed Haskell schemas, PostgreSQL, bounded live
lookup, and no built-in materialized authorization index yet.
