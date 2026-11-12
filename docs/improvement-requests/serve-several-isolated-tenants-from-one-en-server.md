---
type: Improvement Request
title: Serve several isolated tenants from one En server
description: >-
  Let one en-server process serve several tenants, each with its own schema, datastore, API keys, consistency tokens, grant generation and changes feed, selected by the caller's key, so a platform's En can host an application's authorization model beside its own without either tenant reading, writing or invalidating the other's state.
timestamp: "2026-11-12T22:51:59Z"
generated:
  by: process:claude-code
  at: "2026-11-12T22:51:59Z"
requestId: IR-2
status: proposed
origin: mori://shinzui/mori
originPlan: mori://shinzui/mori/plans/302-migrate-the-shared-registry-from-legacy-tokens-to-shomei-and-en-with-a-team-pilot
acceptanceCriteria:
  - id: AC-1
    statement: >-
      A server started without tenant configuration behaves exactly as today: one schema from EN_SCHEMA_PATH, one datastore, keys from EN_API_KEYS_READ_WRITE and EN_API_KEYS_READ_ONLY, and unchanged routes, wire types, token encoding, datastore id and schema hash.
    verification: >-
      The existing en-core, en-servant and en-server suites pass unchanged, and a server upgraded from the previous release against its existing database keeps its datastore id, accepts consistency tokens it minted before the upgrade, and serves the same /v1/schema hash.
  - id: AC-2
    statement: >-
      One process serves at least two tenants with different schemas. A request is evaluated, written and read only within the tenant its API key belongs to; there is no request field through which a caller can name another tenant, and a key belongs to exactly one tenant.
    verification: >-
      An en-server integration test starts one process with tenants A and B whose schemas define different object types. With A's keys it writes and checks tuples of A's types; a write of an object type that only B's schema defines is refused as unknown under A's schema; lookup, relationship query, the changes feed and /v1/schema under A's keys never return B's tuples, changes or schema text, and the same holds with the roles reversed.
  - id: AC-3
    statement: >-
      Each tenant has its own datastore id and schema hash, and a consistency token, lookup cursor or changes-feed cursor minted for one tenant is rejected by every other tenant.
    verification: >-
      The integration test presents a token and a cursor minted under A to B's routes and receives the existing invalid-token problem; the two tenants report distinct datastore ids and schema hashes.
  - id: AC-4
    statement: >-
      Tenant lifecycles are independent. Reloading or forcing one tenant's schema invalidates only that tenant's tokens, check-schema validates one tenant's stored tuples against its candidate schema, and one tenant's writes, garbage collection and grant generation never advance or move another tenant's.
    verification: >-
      The test reloads A's schema with a compatible edit and shows B's previously minted token still validates; it writes to A and shows B's grant generation and GC horizon unchanged; en-server check-schema run for A reports only A's tuples.
  - id: AC-5
    statement: >-
      A tenant's tuples and metadata live in storage that can be migrated, backed up and restored without touching another tenant's, and a fault in one tenant's storage (unreachable, unmigrated, wrong datastore id) makes only that tenant unavailable.
    verification: >-
      The test stops A's storage and shows A's routes fail closed with the existing unavailable problem while B continues to answer checks; per-tenant migrations run through en-migrations; the operations guide documents per-tenant backup and restore.
  - id: AC-6
    statement: >-
      A read-only key stays read-only within its tenant, a read-write key cannot write outside its tenant, the caller identity propagated to logs, metrics and rate limiting carries the tenant, and readiness reports each tenant's state.
    verification: >-
      Middleware tests cover a read-only key refused on a write route of its own tenant, and request-log and metrics assertions show the tenant beside the caller name; the readiness probe names a tenant whose storage is unavailable.
  - id: AC-7
    statement: >-
      docs/user/service-and-operations.md documents tenant configuration, key assignment, per-tenant schema reload and check-schema, migrations, backup and restore, and the isolation guarantees and their limits (shared process, CPU and memory), and docs/api/openapi.json is regenerated if the public surface changes.
    verification: >-
      The documented configuration example starts a two-tenant server that passes the AC-2 checks when followed literally.
reviews:
  - kind: model
    reviewer: process:claude-code
    reviewed_at: "2026-11-12T22:51:59Z"
    document_timestamp: "2026-11-12T22:51:59Z"
    scope: content-and-metadata
    outcome: commented
    provider: anthropic
    model: claude-opus-5-5
    effort: unspecified
    context: >-
      Author review against en master 5e475d5 (en-servant/src/En/Servant/Seam.hs,
      en-server/app/Middleware.hs, en-core/src/En/Cache.hs,
      en-migrations/migrations/0001-en-bootstrap.sql, docs/plans/26 and 54), Nagare v0.20.0's
      cluster/bootstrap/en/service.yaml, and Mori's En adapter configuration. No independent
      verification attestation is claimed.
---

# Serve several isolated tenants from one En server

**Authored by:** a `claude-code` session planning the shared Mori registry's move to Shomei and En
for `mori://shinzui/mori`, on behalf of
`mori://shinzui/mori/plans/302-migrate-the-shared-registry-from-legacy-tokens-to-shomei-and-en-with-a-team-pilot`.
Source evidence is from En at `5e475d5` (2026-10-29) and Nagare at `v0.20.0`.

## What is asked

Let one `en-server` process serve several **tenants**. A tenant is an independent authorization
owner: its own schema, its own datastore (tuples, transactions, datastore id, GC horizon, grant
generation), its own API keys, and therefore its own consistency tokens, cursors and changes
feed. The tenant of a request is the tenant of the key that authenticated it, so a client needs no
new field, route or wire type: a client of today's single-tenant server works unchanged against its
tenant on a shared server, given that tenant's keys, schema hash and datastore id. A server with no
tenant configuration keeps today's behaviour exactly.

## Why

The Nagare platform runs one En in `nagare-system` as part of its auth plane, loaded with
Nagare's access model from `EN_SCHEMA_PATH=/etc/en/schema/app.en`
(`cluster/bootstrap/en/service.yaml` in `mori://shinzui/nagare` at v0.20.0, artifact-level URI
pending). Applications on the platform that want relationship-based authorization of their own
must today run a second En: its own deployment, database, migrations, keys, backups and upgrade
path. Mori is the first such application. Its shared registry authorizes registry, namespace and
project access through En with a Mori-owned model, `mori-api/access/registry.en` in
`mori://shinzui/mori`, and it pins that model: Mori refuses to serve unless the En it talks to
reports exactly the embedded model's schema hash and the configured datastore id
(`MORI_EN_SCHEMA_HASH`, `MORI_EN_DATASTORE_ID`). The registry is being deployed to the
`tan-ng-labs` Nagare intranet (`mori://shinzui/mori/plans/329-deploy-the-shared-mori-registry-to-tan-ng-labs-on-an-app-owned-labs-postgres-database`).

Neither of the shortcuts works today:

- **Merging Mori's definitions into the platform schema.** The served hash would no longer be
  Mori's, so Mori refuses it. Worse, keys are server-wide: `data KeyRole = ReadOnly | ReadWrite`
  in `en-server/app/Middleware.hs` scopes nothing but writes, so Mori's write key could also write
  Nagare's `app:<host>` access grants and admit anyone to any intranet site. Every change to Mori's
  model would also become a platform release.
- **Pointing Mori at the platform En as is.** One process compiles one `ReachabilityGraph`
  (`ActiveSchema` in `en-servant/src/En/Servant/Seam.hs`; plan 26 records one schema per process
  as a deliberate limit and multi-schema serving as an explicit follow-up), and one database holds
  one datastore: `en_datastore_metadata`, `en_grant_generation_head` and the GC horizon are
  singleton tables, and `relation_tuple` has no owner column
  (`en-migrations/migrations/0001-en-bootstrap.sql`).

Much of the isolation needed already exists per datastore. Consistency tokens embed and validate a
datastore id and schema hash, the decision cache keys on both (`DecisionKey` in
`en-core/src/En/Cache.hs`), and `Env.runPorts` evaluates each request under one schema snapshot.
Several of these per-datastore guards inside one process would give tenant isolation without
inventing a new trust boundary.

## Proposed behaviour

This is the shape the consumer needs; the design is En's.

- **Tenant configuration.** An operator declares tenants at startup, each with a name, a schema
  path, a database URL and its read-only and read-write keys. Without that declaration the server
  runs as today (AC-1). Adding or removing a tenant may require a restart; reloading one tenant's
  schema must not (AC-4).
- **Storage per tenant.** The smallest change that satisfies AC-5 appears to be one PostgreSQL
  database per tenant, each migrated by `en-migrations` and carrying today's tables unchanged, so the
  singleton tables, token validation and GC keep their current proofs per tenant. On Nagare this
  maps directly onto one app database per tenant on a shared server. A tenant column across the
  existing tables is the alternative, with a larger proof burden for GC, generations and the
  changes feed.
- **Routing by key.** The authentication middleware resolves the key to `(tenant, role)`, and every
  later stage (schema snapshot, store interpreters, caches, changes feed, rate limiter, request
  log) runs under that tenant. A caller cannot select a tenant any other way (AC-2, AC-6).
- **Per-tenant operations.** `GET /v1/schema` returns the caller's tenant schema; reload and
  `check-schema` take a tenant; readiness reports each tenant (AC-4, AC-6).

Not asked: tenant administration over HTTP, creating tenants at runtime, cross-tenant relations or
subjects, or quotas beyond the existing rate limiter.

## Consumer

Mori's ExecPlan 302 cuts the shared registry over from Mori-minted grants to En decisions. It keeps
both hosting options open and is not held behind this request: if a released En with tenants is
pinned by the Nagare auth plane before 302's first milestone, Mori runs as a tenant of the platform
En; otherwise 302 deploys a dedicated En for Mori, and moving to a platform tenant later is a grant
export (`mori registry access export-en`) plus a configuration change. Hosting tenants on the
platform En would additionally need a Nagare change to declare tenants and their app databases in
its auth-plane bootstrap; that belongs to `mori://shinzui/nagare` and is not part of this request.
