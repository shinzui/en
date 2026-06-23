{- | Pointer to the codd-managed SQL migrations for en's PostgreSQL schema.

The schema (to be added) defines, at minimum:

  * @relation_tuple@ — (object_type, object_id, relation, subject_type,
    subject_id, subject_relation, caveat_name) plus @created_xid xid8@ and
    @deleted_xid xid8@ (@NULL@ = live) for MVCC soft-delete.
  * @en_transaction@ — one row per write, carrying @xid xid8@ and
    @snapshot pg_snapshot DEFAULT pg_current_snapshot()@ to anchor revisions.

See @docs/spec/0001-en-overview.md@ (Consistency).
-}
module En.Migrations (
    migrationsDir,
) where

-- | Path (relative to this package) to the codd migration SQL files.
migrationsDir :: FilePath
migrationsDir = "db/migrations"
