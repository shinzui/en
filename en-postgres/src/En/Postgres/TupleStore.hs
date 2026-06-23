-- | PostgreSQL-backed 'TupleStore'.
--
-- Reads are MVCC point-in-time: a row is alive at revision @R@ iff
-- @pg_visible_in_snapshot(created_xid, R)@ and NOT
-- @pg_visible_in_snapshot(deleted_xid, R)@. Writes insert new rows (and stamp
-- @deleted_xid@ on delete), never updating in place — that is what makes
-- snapshot reads possible. See @docs/spec/0001-en-overview.md@ (Consistency).
module En.Postgres.TupleStore
  ( postgresTupleStore
  ) where

import En.Effect.TupleStore (TupleStore)

-- | Construct a hasql-backed 'TupleStore'. (Connection/pool arguments are added
-- with the implementation.)
postgresTupleStore :: IO (TupleStore IO)
postgresTupleStore =
  error "TODO(en): hasql-backed TupleStore over relation_tuple; see docs/spec/0001-en-overview.md"
