-- en's complete PostgreSQL schema.
--
-- This single migration is the fixed point of the six timestamped SQL files that
-- preceded pg-migrate adoption (see docs/plans/62). Their evolution -- the
-- caveat-free live unique index from docs/plans/45, the index trim from
-- docs/plans/49, the gc-horizon high-water mark from docs/plans/60 -- is
-- preserved in git history and in those plans. It is not replayed here, because
-- no database has ever held that history.
--
-- Append the next migration; never edit this file. Its exact bytes are the
-- checksum pg-migrate stores when a database applies it.

-- One row per write transaction. `snapshot` anchors consistency tokens: it
-- captures which transactions were in flight when the write committed, which is
-- what lets a later read reconstruct the database as of this moment.
CREATE TABLE en_transaction
  ( xid xid8 PRIMARY KEY
  , snapshot pg_snapshot NOT NULL DEFAULT pg_current_snapshot()
  , schema_hash text NOT NULL
  , created_at timestamptz NOT NULL DEFAULT now()
  );

-- Relation tuples, soft-deleted rather than removed: `deleted_xid` NULL means
-- live. Point-in-time reads test visibility with pg_visible_in_snapshot against
-- created_xid and deleted_xid, so a row removed today is still correctly visible
-- to a read anchored before its removal.
CREATE TABLE relation_tuple
  ( id bigserial PRIMARY KEY
  , object_type text NOT NULL
  , object_id text NOT NULL
  , relation text NOT NULL
  , subject_type text NOT NULL
  , subject_id text NOT NULL
  , subject_relation text NULL
  , caveat_name text NULL
  , caveat_payload jsonb NULL
  , created_xid xid8 NOT NULL
  , deleted_xid xid8 NULL
  , CHECK ((subject_relation IS NULL) OR (subject_relation <> ''))
  );

-- Touch semantics (docs/plans/45): a live tuple's identity is
-- (object, relation, subject). The caveat is an attribute of that tuple, not part
-- of its identity, so writing the same tuple with a different caveat replaces it
-- rather than adding a second live row.
CREATE UNIQUE INDEX relation_tuple_live_unique
  ON relation_tuple
    ( object_type
    , object_id
    , relation
    , subject_type
    , subject_id
    , coalesce(subject_relation, '')
    )
  WHERE deleted_xid IS NULL;

-- Historical reads scan without the live predicate, so they need unfiltered
-- indexes in both directions (object-scoped and subject-scoped).
CREATE INDEX relation_tuple_object_hist_idx
  ON relation_tuple (object_type, object_id, relation, id);

CREATE INDEX relation_tuple_subject_hist_idx
  ON relation_tuple
    (subject_type, subject_id, coalesce(subject_relation, ''), object_type, relation, id);

CREATE INDEX relation_tuple_created_xid_idx
  ON relation_tuple (created_xid);

COMMENT ON INDEX relation_tuple_created_xid_idx IS
  'Reserved for the watch/changelog feed (docs/plans/53-add-a-watch-changelog-api.md); serves no statement today. See docs/plans/49-trim-dead-indexes-and-resolve-consistency-lazily.md.';

-- Serves the reaper, which physically removes rows whose deleted_xid has fallen
-- below the garbage-collection horizon.
CREATE INDEX relation_tuple_deleted_xid_idx
  ON relation_tuple (deleted_xid)
  WHERE deleted_xid IS NOT NULL;

-- This database's persistent identity.
--
-- Every consistency token embeds a datastore id, and token validation rejects a
-- token whose id does not match the serving datastore. That guard is only worth
-- anything if distinct databases carry distinct ids.
--
-- The id is minted by the server on first startup, not here: keeping the
-- migration pure DDL leaves it deterministic and free of any dependency on
-- pgcrypto for gen_random_uuid(). The server inserts a candidate with
-- ON CONFLICT DO NOTHING and then reads back whichever id won, so servers racing
-- on first startup converge rather than fighting.
--
-- The singleton column enforces exactly-one-row at the schema level: the primary
-- key admits one `true`, and the check constraint forbids `false`.
CREATE TABLE en_datastore_metadata
  ( singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton)
  , datastore_id text NOT NULL
  , created_at timestamptz NOT NULL DEFAULT now()
  );

-- The garbage-collection horizon's durable high-water mark (docs/plans/60,
-- Milestone 4).
--
-- The horizon is oldestRetainedXid: the reaper physically deletes a soft-deleted
-- tuple whose deleted_xid < horizon, and token validation rejects any snapshot
-- under which a row already reaped could still be live. For that to be sound the
-- horizon must never move backwards -- reaping at T1 destroys rows below H(T1),
-- and a token validated at T2 > T1 reasons about H(T2), so the argument needs
-- H(T1) <= H(T2). A freshly computed horizon does not guarantee that on its own:
-- a long-running transaction holding pg_snapshot_xmin low can pull a later
-- horizon below an earlier one.
--
-- This table is that missing guarantee. It holds one row: the greatest horizon
-- ever served. The reaper advances it (SET horizon = GREATEST(horizon, fresh))
-- and returns the new value before it reaps, and token validation reads
-- GREATEST(horizon, fresh). Because the reaper publishes the mark before it
-- destroys anything, validation on any replica is bounded below by every reap any
-- replica has already performed.
--
-- The row is seeded here (horizon 0) so the reaper and validation always find it;
-- GREATEST lifts 0 to the first real horizon on the first pass.
CREATE TABLE en_gc_horizon
  ( singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton)
  , horizon bigint NOT NULL DEFAULT 0
  );

INSERT INTO en_gc_horizon (singleton, horizon) VALUES (true, 0);
