-- | The PostgreSQL revision: a @pg_snapshot@ (xmin:xmax:xip), compared as a
-- partial order, plus the consistency-token codec.
module En.Postgres.Revision
  ( PgSnapshot (..)
  ) where

import Data.Word (Word64)

-- | A PostgreSQL MVCC snapshot — the concrete payload behind 'En.Revision.Revision'.
-- Ordering is by snapshot visibility (who has more information about settled
-- transactions), NOT by timestamp or txid — hence a /partial/ order with a
-- "concurrent" outcome. The @xip@ list must stay sorted.
data PgSnapshot = PgSnapshot
  { xmin :: Word64
  , xmax :: Word64
  , xip  :: [Word64]
  }
  deriving stock (Eq, Show)

-- TODO(en): partial-order compare (-> En.Revision.RevisionOrder), the
-- quantized "optimized revision" SQL, and the base64-proto token codec.
-- See docs/spec/0001-en-overview.md.
