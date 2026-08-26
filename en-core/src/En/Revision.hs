-- | Revisions and consistency tokens — the read-your-writes / "new enemy" machinery.
module En.Revision
  ( Revision (..),
    RevisionOrder (..),
    DatastoreId (..),
    SchemaHash (..),
    ConsistencyToken (..),
    Consistency (..),
  )
where

import Data.Text (Text)
import GHC.Generics (Generic)

-- | An opaque datastore revision. For the PostgreSQL datastore this wraps a
-- @pg_snapshot@ (xmin:xmax:xip); see @En.Postgres.Revision@. Revisions form a
-- /partial/ order — two concurrent snapshots may be incomparable — so en
-- deliberately gives 'Revision' no 'Ord' instance. Datastore-specific packages
-- provide their own comparators.
newtype Revision = Revision
  { -- | datastore-specific opaque encoding (placeholder)
    revisionEncoding :: Text
  }
  deriving stock (Eq, Generic, Show)

newtype DatastoreId = DatastoreId Text
  deriving stock (Eq, Ord, Show)

newtype SchemaHash = SchemaHash Text
  deriving stock (Eq, Ord, Show)

-- | The four-valued comparison of two revisions. 'RConcurrent' is the case a naive
-- total order would get wrong — and thereby break the new-enemy guarantee.
data RevisionOrder = RBefore | RAfter | REqual | RConcurrent
  deriving stock (Eq, Show)

-- | The opaque token handed back on write and presented on read for
-- read-your-writes. Zanzibar's Zookie / SpiceDB's ZedToken.
newtype ConsistencyToken = ConsistencyToken Text
  deriving stock (Eq, Show)

-- | The requested freshness of a read.
data Consistency
  = -- | quantized/cached revision; fastest, may be stale
    MinimizeLatency
  | -- | max(optimized, token); read-your-writes
    AtLeastAsFresh ConsistencyToken
  | -- | exactly the token's revision
    AtExactSnapshot ConsistencyToken
  | -- | head revision; freshest, uncacheable
    FullyConsistent
  deriving stock (Eq, Show)
