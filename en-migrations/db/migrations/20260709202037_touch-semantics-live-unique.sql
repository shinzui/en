-- Touch semantics (docs/plans/45): a live tuple's identity is
-- (object, relation, subject); the caveat is an attribute, not identity.
--
-- 1. Resolve pre-existing duplicate live rows deterministically: per identity
--    key, the row with the highest created_xid wins (the newest write - the row
--    that touch semantics would have kept); ties on created_xid (same write
--    transaction) are broken by highest id (the later insert). Losers are
--    soft-deleted with this migration transaction's xid so point-in-time reads
--    at pre-migration revisions still see them.
WITH ranked AS (
  SELECT id,
         row_number() OVER (
           PARTITION BY object_type, object_id, relation,
                        subject_type, subject_id, coalesce(subject_relation, '')
           ORDER BY created_xid DESC, id DESC
         ) AS keep_rank
  FROM relation_tuple
  WHERE deleted_xid IS NULL
)
UPDATE relation_tuple
SET deleted_xid = pg_current_xact_id()
WHERE id IN (SELECT id FROM ranked WHERE keep_rank > 1);

-- 2. Re-key live uniqueness without the caveat name.
DROP INDEX relation_tuple_live_unique;

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
