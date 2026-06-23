---
id: 2
slug: implement-postgresql-tuple-store-and-consistency-tokens
title: "Implement PostgreSQL tuple store and consistency tokens"
kind: exec-plan
created_at: 2026-06-23T04:05:49Z
intention: "intention_01kvsbcvsfepaafp5x44ykby47"
master_plan: "docs/masterplans/1-build-en-rebac-authorization-toolkit.md"
---

# Implement PostgreSQL tuple store and consistency tokens

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan gives `en` durable relationship storage and the read-your-writes guarantee required by kikan C13. After it is complete, code can write relationship tuples to PostgreSQL, receive an opaque consistency token, and perform reads at a resolved MVCC snapshot so a dependent `check` or `lookup` observes its own writes. The behavior is visible through tests that write tuples, delete tuples, decode tokens, and prove snapshot reads include or exclude rows according to `created_xid` and `deleted_xid`.


## Progress

- [x] Add codd-managed SQL migrations for `relation_tuple` and `en_transaction`. Completed 2026-06-23T04:44:44Z.
- [x] Define indexes for forward reads, reverse `readStartingWithUser` reads, deletion, and cursor pagination. Completed 2026-06-23T04:44:44Z.
- [x] Implement `PgSnapshot` parsing, rendering, partial-order comparison, and tests. Completed 2026-06-23T04:44:44Z.
- [x] Implement consistency-token encoding and decoding with datastore id, schema hash, revision payload, and validation errors. Completed 2026-06-23T04:44:44Z.
- [ ] Implement `MinimizeLatency`, `FullyConsistent`, `AtLeastAsFresh`, and `AtExactSnapshot` revision resolution.
- [ ] Implement hasql-backed write, delete, and read operations for the final EP-1 store interface.
- [ ] Add integration tests against a temporary PostgreSQL database or the repository's established Postgres test harness.
- [x] Run `cabal build all` and the relevant test command for the completed revision slice. Completed 2026-06-23T04:44:44Z.


## Surprises & Discoveries

- The first snapshot comparison implementation treated future transaction visibility symmetrically. That made `10:30:` compare before `10:20:` because transaction 21 is visible in the newer snapshot but outside the older snapshot's horizon. The fixed rule requires the candidate snapshot to have at least the required `xmax` and preserve visibility for transactions visible within the required snapshot's horizon. Evidence:

```text
cabal test en-postgres-revision-tests
1 of 1 test suites (1 of 1 test cases) passed.
```


## Decision Log

- Decision: Use PostgreSQL `pg_snapshot` as the concrete revision, not a monotonically increasing sequence number.
  Rationale: `docs/spec/0001-en-overview.md` makes the new-enemy guarantee depend on Postgres MVCC snapshot visibility and a partial revision order.
  Date: 2026-06-23
- Decision: Keep the first token codec as a versioned opaque text envelope owned by `En.Postgres.Revision`.
  Rationale: The core interface only exposes `ConsistencyToken` as opaque text. This lets token validation and revision resolution proceed without committing the wire encoding to later Servant/API work; if a base64 protobuf payload is still required for compatibility, it can replace this private codec without changing `en-core`.
  Date: 2026-06-23


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This plan depends on `docs/plans/1-stabilize-core-authorization-interfaces.md`. It must implement the final store and consistency interfaces from that plan, not the scaffold signatures currently in `en-core/src/En/Effect/TupleStore.hs`.

The current storage-related files are `en-migrations/src/En/Migrations.hs`, `en-postgres/src/En/Postgres/TupleStore.hs`, and `en-postgres/src/En/Postgres/Revision.hs`. The migration module currently only points at `db/migrations`; that directory does not yet contain the schema. The Postgres tuple store currently has a placeholder `postgresTupleStore :: IO (TupleStore IO)`.

The design in `docs/spec/0001-en-overview.md` says each live tuple row is visible at revision `R` when PostgreSQL reports `created_xid` visible in snapshot `R` and `deleted_xid` not visible in snapshot `R`. Writes insert rows and deletes stamp a deletion xid instead of physically deleting rows. A separate `en_transaction` row records the write xid and snapshot for token anchoring.


## Plan of Work

Start by using Mori for dependency lookup before relying on memory for `hasql` or `codd` APIs:

```bash
mori registry search hasql
mori registry show hasql/hasql --full
mori registry search codd
mori registry show mzabani/codd --full
```

Read the relevant dependency source and local examples before writing SQL runner or hasql code. If `shomei` has a migration pattern that should be mirrored, locate it through Mori and read only the specific migration and Postgres adapter files needed.

Add SQL migrations under the migration directory used by `En.Migrations.migrationsDir`. The minimum schema is `relation_tuple` with object type/id, relation, subject type/id, optional subject relation for usersets, caveat name/payload columns, `created_xid xid8`, and `deleted_xid xid8`. The `en_transaction` table stores write xids and snapshots. Include indexes for object-to-subject and subject-to-object queries.

Implement `En.Postgres.Revision` next. It must parse and render `pg_snapshot` values, compare two snapshots using a partial order, and expose token codec helpers. The partial order must preserve `RConcurrent` so `AtLeastAsFresh` never treats concurrent snapshots as fresh enough.

Implement revision resolution. `MinimizeLatency` returns a quantized optimized revision. `FullyConsistent` returns the current head snapshot. `AtExactSnapshot` decodes and validates a token. `AtLeastAsFresh` chooses the optimized revision only when it is equal to or after the token revision; otherwise it honors the token.

Finally, implement the hasql `TupleStore`. Writes must run in transactions, insert an `en_transaction` anchor, insert or stamp tuple rows, and return a token. Reads must use the resolved revision and the `pg_visible_in_snapshot` predicate from the spec.


## Concrete Steps

Work from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/en
```

Verify package metadata:

```bash
mori show --full
```

Inspect current storage modules:

```bash
sed -n '1,220p' en-migrations/src/En/Migrations.hs
sed -n '1,240p' en-postgres/src/En/Postgres/Revision.hs
sed -n '1,240p' en-postgres/src/En/Postgres/TupleStore.hs
```

After implementing migrations and Haskell modules, run:

```bash
cabal build all
```

If a Postgres test harness is added, document and run the exact command here during implementation. A likely shape is:

```bash
cabal test en-postgres
```

The revision/token slice added a database-free test suite that must pass while the full database harness is still pending:

```bash
cabal test en-postgres-revision-tests
```


## Validation and Acceptance

Acceptance requires tests or a reproducible harness that demonstrates these behaviors: writing a tuple returns a token; reading at that token can see the tuple; deleting the tuple returns a later token; reading at the old token still sees the tuple while reading at the new token does not; invalid datastore ids, schema hashes, expired tokens, and concurrent snapshots are handled according to the core error model.

`cabal build all` must pass. If database tests require a local PostgreSQL binary or service, record the exact prerequisite and skip reason if unavailable.


## Idempotence and Recovery

Migrations should be additive and managed by codd. Do not manually edit a live database outside the migration/test harness. If a migration needs to be replaced before release, record the reason in this plan and keep the local development database reset path explicit. Avoid destructive shell commands unless the user explicitly approves them.


## Interfaces and Dependencies

Hard dependency: `docs/plans/1-stabilize-core-authorization-interfaces.md`.

Soft dependency: `docs/plans/3-implement-schema-validation-and-reachability-compilation.md`, because schema hashes become part of token validation.

This plan owns `en-migrations/src/En/Migrations.hs`, migration SQL under `en-migrations`, `en-postgres/src/En/Postgres/Revision.hs`, and `en-postgres/src/En/Postgres/TupleStore.hs`. It consumes the final store and consistency interfaces from `en-core`.


Revision note 2026-06-23: Added `intention_01kvsbcvsfepaafp5x44ykby47` to the plan frontmatter at the user's request.

Revision note 2026-06-23: Marked the migration and revision/token codec slice complete, recorded the Postgres snapshot partial-order correction, and added the `en-postgres-revision-tests` validation command.
