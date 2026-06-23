-- | Revisions and consistency tokens — the read-your-writes / "new enemy" machinery.
module En.Revision (
    Revision (..),
    RevisionOrder (..),
    compareRevision,
    DatastoreId (..),
    SchemaHash (..),
    ConsistencyToken (..),
    Consistency (..),
) where

import Data.Text (Text)

{- | An opaque datastore revision. For the PostgreSQL datastore this wraps a
@pg_snapshot@ (xmin:xmax:xip); see @En.Postgres.Revision@. Revisions form a
/partial/ order — two concurrent snapshots may be incomparable — so en
deliberately gives 'Revision' no 'Ord' instance; use 'compareRevision'.
-}
newtype Revision = Revision
    { revisionEncoding :: Text
    -- ^ datastore-specific opaque encoding (placeholder)
    }
    deriving stock (Eq, Show)

newtype DatastoreId = DatastoreId Text
    deriving stock (Eq, Ord, Show)

newtype SchemaHash = SchemaHash Text
    deriving stock (Eq, Ord, Show)

{- | The four-valued comparison of two revisions. 'RConcurrent' is the case a naive
total order would get wrong — and thereby break the new-enemy guarantee.
-}
data RevisionOrder = RBefore | RAfter | REqual | RConcurrent
    deriving stock (Eq, Show)

-- | Partial-order comparison. Datastore-specific (PostgreSQL snapshot visibility).
compareRevision :: Revision -> Revision -> RevisionOrder
compareRevision =
    error "TODO(en): datastore partial order; see En.Postgres.Revision + docs/spec/0001-en-overview.md"

{- | The opaque token handed back on write and presented on read for
read-your-writes. Zanzibar's Zookie / SpiceDB's ZedToken.
-}
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
