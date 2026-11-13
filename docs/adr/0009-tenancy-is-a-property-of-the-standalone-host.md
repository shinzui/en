---
title: "Tenancy is a property of the standalone host"
status: accepted
date: 2026-11-13
authors: [shinzui]
related:
  - docs/masterplans/12-serve-several-isolated-tenants-from-one-en-server.md
  - docs/plans/73-serve-tenants-selected-by-api-key-each-from-its-own-isolated-stack.md
  - docs/improvement-requests/serve-several-isolated-tenants-from-one-en-server.md
  - mori://shinzui/mori/plans/302-migrate-the-shared-registry-from-legacy-tokens-to-shomei-and-en-with-a-team-pilot
---

# ADR 9 — Tenancy is a property of the standalone host

## Context

IR-2 asks one `en-server` process to serve several independent authorization owners
(tenants), each with its own schema, datastore and API keys, without any tenant reading,
writing, validating against or invalidating another's state. The owner accepted it on two
conditions: complete isolation, and no performance tax on single-tenant use.

Every guard such isolation needs already exists per datastore. Consistency tokens and
watch cursors embed and validate a datastore id (and tokens a schema hash), the decision
cache keys on both, and each request is evaluated under one schema snapshot. The database
keeps datastore identity, the garbage-collection horizon and the grant-generation counter
in singleton tables, and `relation_tuple` has no owner column.

## Decision

Tenancy lives only in `en-server`, the standalone host.

- **One single-datastore stack per tenant.** `en-server/app/Tenant.hs` builds, for each
  tenant, everything that exists once per datastore: connection pool, datastore id, active
  schema, the three caches, rate-limit buckets, metrics registry, maintenance loop, `Env`
  and the WAI application inside authentication. The same function builds the one stack
  of a server without tenants.
- **One PostgreSQL database per tenant**, each migrated by `en-migrate` and carrying the
  unchanged tables. A tenant column was rejected: it would put a tenant filter on every
  hot-path statement, require re-proving garbage collection, grant-generation ordering and
  the changes feed, and turn per-tenant backup into a row filter instead of a `pg_dump`.
  Two tenants on one database (same URL, or the same datastore id through different URLs)
  are refused at startup.
- **Routing by key only.** Each configured key is paired with its tenant's application, and
  the authentication middleware calls the application of the key that matched. No header,
  path segment or body field can select a tenant, and the per-request work is the same
  single scan over the key list that authentication already did. A secret may belong to
  only one key of one tenant.
- **The engine, the store and the servant layer stay tenant-unaware.** No function in
  `en-core`, `en-postgres` or `en-servant` receives a tenant name; `en-servant` gains only a
  probes-only application for a host that serves several `Env`s from one listener.
- **Legacy mode is one implicit stack, not a one-entry tenant table.** Without
  `EN_TENANTS` the configuration type itself is a different constructor, and the server
  wraps its one stack in the unchanged `authMiddleware`.

## Consequences

- Isolation of data, tokens, cursors, caches, rate limits, schema lifecycle, garbage
  collection and grant generations follows from construction and is proven by the
  black-box suite `en-server-tenant-tests`, including every route of one tenant answering
  while the other tenant's PostgreSQL is stopped.
- Tenants still share the process's CPU cores, garbage-collected heap, listener and TLS
  configuration. A busy tenant slows its neighbours far more than a busy second process
  would; this is measured and documented rather than prevented, and a deployment that
  needs performance isolation runs a dedicated `en-server` per tenant.
- Database connections and memory grow with the number of tenants, since each has its own
  pool and caches.
- A tenant's store faults are contained (docs/plans/74): a tenant whose database is
  unreachable, unmigrated or not the one pinned by `EN_TENANT_<NAME>_EXPECTED_DATASTORE_ID`
  starts unavailable, answers 503 `store_error` with authentication intact, and is retried
  until it recovers, while the others serve. A bad schema file or an invalid GC window still
  stops the process: those are deployment input. Legacy mode still exits on any startup
  fault.
- Embedded hosts of `en-core` are unaffected; an embedding application that wants several
  tenants composes several `Env`s itself.
- Adding, removing or re-keying a tenant requires a restart. Per-tenant HTTP
  administration is deliberately out of scope.
