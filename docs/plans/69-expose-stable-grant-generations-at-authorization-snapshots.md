---
id: 69
slug: expose-stable-grant-generations-at-authorization-snapshots
title: "Expose stable grant generations at authorization snapshots"
kind: exec-plan
created_at: 2026-09-08T17:00:54Z
master_plan: "mori://shinzui/koyomi/masterplans/1-bootstrap-koyomi-as-a-native-organizational-calendar-service"
---

# Expose stable grant generations at authorization snapshots

This living ExecPlan supports `mori://shinzui/koyomi/masterplans/1-bootstrap-koyomi-as-a-native-organizational-calendar-service`. Keep progress and evidence current until storage, wire metadata and consumer integration all pass.

## Purpose / Big Picture

Consumers need to tell whether grants changed between independent authorization checks. Schema hashes miss tuple mutations; PostgreSQL snapshots also change for unrelated database transactions. Expose an owner-backed grant generation at the exact checked snapshot, so consumers can reject mixed permission generations without rejecting their own cursor writes.

## Progress

- [x] (2026-09-08) Inspect both mutation paths and their existing `en_transaction` anchors; design commit-ordered generation history.
- [x] (2026-09-08) Add the migration, snapshot reader and bounded retention primitive. Migration and PostgreSQL integration tests prove rollback, commit ordering, historical reads and unrelated-write stability. The actual Koyomi/En HTTPS gate also verifies all 96 grant/revocation transactions receive generations.
- [ ] Attach attributable generation metadata to actual check responses, update wire/OpenAPI/client fixtures and prove missing/stale metadata fails explicitly.
- [ ] Integrate history pruning into bounded owner maintenance with correct counts and retention safety.
- [ ] Verify the actual owner service and Koyomi's evidence adapter, including cursor writes and intervening revocation.

## Surprises & Discoveries

Both `applyTupleWritesSession` and `deleteRelationshipsSession` in `en-postgres/src/En/Postgres/TupleStore.hs` insert/update an `en_transaction` anchor inside the grant transaction. A deferred trigger on this anchor can stamp successful write transactions without duplicating bookkeeping across callers. The schema fingerprint in `En.Schema` is FNV-1a-64, not a grant revision or signature.

## Decision Log

- Decision (2026-09-08): Stamp a monotonic grant generation with a deferred constraint trigger on the existing write anchor. An incremented singleton row is locked until commit, making generation order agree with successful commit order even when transaction IDs were allocated in another order. Rollback also rolls back the generation. Successful no-op write requests may conservatively advance it.
- Decision (2026-09-08): Retain generation rows with their owner write XID and resolve visibility using the same PostgreSQL snapshot semantics as tuples. Keep the newest generation below a validated garbage-collection horizon as a floor; only older rows below that horizon may be pruned in bounded batches. A snapshot predating initialization has no generation and must fail unavailable.
- Decision (2026-09-08): Keep `en1` snapshot tokens intact. Add explicit check-response generation metadata tied to `checkedAt`; schema and datastore identities remain part of the consumer's composite policy identity. A generation alone is not a signed proof or cached permission.

## Outcomes & Retrospective

The storage milestone passes owner migration/PostgreSQL acceptance, the all-package build, formatting and the real consumer service gate. Its initial test fixture needed an explicit xid8-to-bigint cast for the existing retention horizon; the test now reads the durable horizon before pruning. Implementation of wire metadata, maintenance and consumer evidence remains in progress. No consumer may treat schema-only values or unrelated PostgreSQL transaction positions as stable grant generations. Storage primitives alone do not complete this plan; live wire metadata, maintenance and consumer acceptance are mandatory.

## Context and Orientation

`en-postgres/src/En/Postgres/TupleStore.hs` commits all owner grant mutations and creates their durable transaction anchors. `En.Postgres.Revision` resolves fully consistent and exact-snapshot reads. `en-servant/src/En/Check/Api.hs` encodes single-check responses, while `en-server/app/Main.hs` binds the live schema and PostgreSQL interpreter. `en-server/app/Maintenance.hs` supervises bounded garbage collection. `en-migrations/migrations/manifest` embeds the append-only SQL plan. [ADR 1](../adr/0001-en-s-schema-is-an-append-only-pg-migrate-component.md) requires new migration files rather than edits to installed SQL. No existing ADR defines stable grant generations; the new decision is recorded in [ADR 8](../adr/0008-grant-generations-follow-committed-owner-writes.md).

## Plan of Work

### Milestone 1: Commit-ordered storage and exact reads

Append `0002-grant-generations.sql` to the manifest. Initialize a singleton counter at zero and a generation-history row stamped with the migration XID. A deferred trigger on `en_transaction` updates the counter and inserts one history row per committed owner write XID. The lock must remain held through commit. Add `En.Postgres.GrantGeneration` with an opaque generation value, an exact-revision lookup and a bounded pruning session. Test it with the real migration plan and PostgreSQL. Demonstrate that an unrelated committed transaction changes the snapshot but not the generation, rolled-back anchors do not advance it, out-of-order XID allocation still produces commit-ordered generations, and old snapshots resolve the earlier generation.

### Milestone 2: Attributable wire metadata

Extend single-check success metadata with the generation read at the result's exact revision under the same datastore/schema binding. Integrate the reader through the server seam; do not take a later independent head generation. Missing history, owner mismatch and expired snapshots must remain typed unavailability. Update wire codecs, OpenAPI generation, source tests and the actual HTTP fixture. Preserve older snapshot-token behavior and identify any additive response compatibility implications explicitly.

### Milestone 3: Retention and consumer acceptance

Integrate bounded generation pruning after the owner's durable horizon is advanced, keeping the newest visible floor and every potentially live newer row. Expose honest counts and test retry/concurrency. Extend the real En service acceptance in `mori://shinzui/koyomi` (project-relative path `scripts/test-en-owner.sh`; artifact-level URI pending) and then construct Koyomi authorization evidence from validated snapshot and generation metadata. Prove that calendar cursor writes do not invalidate generations while owner revocation does.

## Concrete Steps

Run owner commands from the Mori-resolved `mori://shinzui/en` project root:

```bash
nix develop -c cabal test en-migrations en-postgres:en-postgres-integration-tests --test-show-details=direct
nix develop -c cabal build all
nix fmt -- --fail-on-change
```

Record the executed command and result. Run the live consumer gate from `mori://shinzui/koyomi`:

```bash
nix develop -c just test-en-owner
```

Every required fixture must fail when its source, database or service is unavailable; no skip is success.

## Validation and Acceptance

Storage acceptance must cover zero baseline; committed/rolled-back anchors; an XID allocated earlier but committed later; unchanged generation after unrelated SQL writes; old-snapshot visibility; missing history before initialization; bounded pruning with a preserved floor; and repeated pruning safety. HTTP acceptance must prove generation is attached to the exact decision snapshot, changes after grant deletion, survives unrelated database work and fails unavailable when missing. Consumer acceptance must show real allowed/denied decisions, same-generation multi-proof reads and cursor invalidation after grant changes. Compile-only evidence cannot close these requirements.

## Idempotence and Recovery

Keep existing migration bytes unchanged. Tests use ephemeral databases or the consumer gate's named temporary database. Migration reruns must be idempotent through pg-migrate. Rollback must restore the head counter and history atomically with grants. Treat the generation schema as required once the owner code uses it; do not silently fall back to schema hashes or snapshot text on an old database. Preserve all unrelated working-tree changes and commit on the current branch.

## Interfaces and Dependencies

Use existing Hasql sessions and the released pg-migrate API already selected by this owner; no new dependency bounds are needed. `En.Postgres.GrantGeneration` must expose an opaque `GrantGeneration`, a text renderer, `grantGenerationAtSession :: Revision -> Session (Maybe GrantGeneration)`, and a bounded horizon-based pruning session. Only the authoritative owner may derive this generation. The final HTTP contract must carry its association with `checkedAt`, and Koyomi must validate datastore/schema binding before making authorization evidence.
