CREATE TABLE en_transaction
  ( xid xid8 PRIMARY KEY
  , snapshot pg_snapshot NOT NULL DEFAULT pg_current_snapshot()
  , schema_hash text NOT NULL
  , created_at timestamptz NOT NULL DEFAULT now()
  );

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

CREATE UNIQUE INDEX relation_tuple_live_unique
  ON relation_tuple
    ( object_type
    , object_id
    , relation
    , subject_type
    , subject_id
    , coalesce(subject_relation, '')
    , coalesce(caveat_name, '')
    )
  WHERE deleted_xid IS NULL;

CREATE INDEX relation_tuple_object_live_idx
  ON relation_tuple (object_type, object_id, relation, id)
  WHERE deleted_xid IS NULL;

CREATE INDEX relation_tuple_subject_live_idx
  ON relation_tuple
    (subject_type, subject_id, coalesce(subject_relation, ''), object_type, relation, id)
  WHERE deleted_xid IS NULL;

CREATE INDEX relation_tuple_created_xid_idx
  ON relation_tuple (created_xid);

CREATE INDEX relation_tuple_deleted_xid_idx
  ON relation_tuple (deleted_xid)
  WHERE deleted_xid IS NOT NULL;
