-- Trim the partial "live" indexes (docs/plans/49, finding C9 of
-- docs/reviews/2026-07-07-architecture-performance-review.md).
--
-- Both are maintained on every insert and every soft-delete, and neither buys a
-- plan that relation_tuple's surviving indexes do not already serve. Verified by
-- an EXPLAIN (ANALYZE, BUFFERS) sweep of every statement in
-- en-postgres/src/En/Postgres/TupleStore.hs against a 250,019-row table
-- (200,006 live, 4,006 objects, ANALYZEd), corroborated by pg_stat_user_indexes
-- deltas across a workload driven through en-server. Dropping both cuts a
-- 20,000-row insert from 0.573 s to 0.378 s.
--
-- relation_tuple_object_live_idx (object_type, object_id, relation, id):
--   strictly subsumed by relation_tuple_live_unique, whose key begins with the
--   same three columns under the same WHERE deleted_xid IS NULL predicate. Every
--   object-scoped precondition filter binds a prefix of those columns, so the
--   unique index answers it -- frequently as an Index Only Scan. Recorded zero
--   idx_scan even under a workload containing exactly the query it was built for.
--   Its one unique capability, id-ordering within an object key, has no consumer:
--   the read path spells visibility as pg_visible_in_snapshot(created_xid, ...),
--   never as deleted_xid IS NULL, and the planner cannot use a partial index
--   predicated on the latter to satisfy the former.
--
-- relation_tuple_subject_live_idx (subject_type, subject_id,
--   coalesce(subject_relation,''), object_type, relation, id):
--   *was* chosen, for the subject-scoped precondition filters added by
--   docs/plans/46 (matchingLiveTupleExistsStatement, lockMatchingLiveTupleStatement
--   -- a TupleFilter may omit objectId while objectType stays mandatory). It is
--   dropped anyway: with it gone the planner reaches relation_tuple_subject_hist_idx
--   with a byte-identical Index Cond, the same buffer count, and lower latency
--   (0.018 ms vs 0.059 ms on a miss). Chosen is not needed.
--
-- Deliberately NOT dropped:
--   relation_tuple_created_xid_idx -- serves no statement today, retained by
--     coordination with docs/plans/53-add-a-watch-changelog-api.md, whose changelog
--     window bounds each arm with `created_xid >= $start_xmin::xid8` to make this
--     index load-bearing. See the Decision Logs of docs/plans/49 and docs/plans/53.
--     If that plan abandons the design, it owns the drop.
--   relation_tuple_deleted_xid_idx -- serves the reaper (reapDeletedTuplesStatement,
--     reapDeletedTuplesBatchStatement); confirmed by the same sweep.
--
-- Reversible: an index carries no data, so recovery is
--   CREATE INDEX CONCURRENTLY relation_tuple_object_live_idx
--     ON relation_tuple (object_type, object_id, relation, id)
--     WHERE deleted_xid IS NULL;
--   CREATE INDEX CONCURRENTLY relation_tuple_subject_live_idx
--     ON relation_tuple
--       (subject_type, subject_id, coalesce(subject_relation, ''), object_type, relation, id)
--     WHERE deleted_xid IS NULL;

DROP INDEX IF EXISTS relation_tuple_object_live_idx;

DROP INDEX IF EXISTS relation_tuple_subject_live_idx;

-- Record the reservation on the SQL side, so a reader inspecting the live schema
-- learns why an index nothing queries is still here (docs/plans/49, docs/plans/53).
COMMENT ON INDEX relation_tuple_created_xid_idx IS
  'Reserved for the watch/changelog feed (docs/plans/53-add-a-watch-changelog-api.md); serves no statement today. See docs/plans/49-trim-dead-indexes-and-resolve-consistency-lazily.md.';
