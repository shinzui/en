-- The garbage-collection horizon's durable high-water mark
-- (docs/plans/60-correct-the-consistency-token-validation-boundary-and-its-error-surface.md,
-- Milestone 4).
--
-- The horizon is oldestRetainedXid: the reaper physically deletes a soft-deleted
-- tuple whose deleted_xid < horizon, and token validation rejects any snapshot
-- under which a row already reaped could still be live. For that to be sound the
-- horizon must never move backwards: reaping at time T1 destroys rows below
-- H(T1), and a token validated at T2 > T1 reasons about H(T2), so the argument
-- needs H(T1) <= H(T2).
--
-- It does not hold on its own. oldestRetainedXidStatement computed
-- coalesce(min(xid), pg_snapshot_xmin(pg_current_snapshot())) over en_transaction
-- rows inside EN_GC_WINDOW. The min(xid) branch rises as rows age out, but the
-- coalesce fallback need not: a long-running open transaction that has been
-- assigned an xid pins pg_snapshot_xmin low, so once every anchor ages out of the
-- window the horizon can drop from the earlier min(xid) down to that pinned value.
-- Rows reaped under the higher earlier horizon are then judged "still live" by a
-- token validated under the lower later horizon -- the exact answer the check
-- exists to prevent, reached through time rather than through the snapshot
-- (confirmed live: runHorizonMonotonicityScenario in en-postgres/integration-test).
--
-- This table is that missing guarantee. It holds one row: the greatest horizon
-- ever served. The reaper advances it (SET horizon = GREATEST(horizon, fresh))
-- and returns the new value before it reaps, and token validation reads
-- GREATEST(horizon, fresh). Because the reaper publishes the mark before it
-- destroys anything, validation on any replica is bounded below by every reap any
-- replica has already performed, so reaping and validation can never disagree
-- about what is safe -- which a per-process value could not guarantee across a
-- multi-replica deployment.
--
-- The mark only ever clamps the served horizon *up*, so it never reintroduces the
-- false-reject Milestone 1 fixed: every value it can hold is a past freshly
-- computed horizon, each bounded above by its own snapshot's xmax and therefore by
-- the current one, so a token minted from a current head revision still validates.
--
-- The singleton column enforces exactly-one-row at the schema level, mirroring
-- en_datastore_metadata: the primary key admits one `true` and the check
-- constraint forbids `false`. The row is seeded here (horizon 0) so the reaper and
-- validation always find it; GREATEST lifts 0 to the first real horizon on the
-- first pass.
CREATE TABLE en_gc_horizon
  ( singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton)
  , horizon bigint NOT NULL DEFAULT 0
  );

INSERT INTO en_gc_horizon (singleton, horizon) VALUES (true, 0);
