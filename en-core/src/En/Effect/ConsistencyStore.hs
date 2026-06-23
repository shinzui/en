{- | Consistency resolution boundary.

Storage implementations decode tokens, validate datastore/schema identity,
check the garbage-collection window, and choose the concrete snapshot used by
a read. The core algorithms depend on this boundary rather than knowing how a
PostgreSQL @pg_snapshot@ token is encoded.
-}
module En.Effect.ConsistencyStore (
    TokenMetadata (..),
    ResolvedConsistency (..),
    ConsistencyStore (..),
) where

import Data.Time (UTCTime)

import En.Error (EnError)
import En.Revision (
    Consistency,
    ConsistencyToken,
    DatastoreId,
    Revision,
    SchemaHash,
 )

-- | Decoded, validated token contents.
data TokenMetadata = TokenMetadata
    { token :: !ConsistencyToken
    , revision :: !Revision
    , datastoreId :: !DatastoreId
    , schemaHash :: !SchemaHash
    , expiresAt :: !(Maybe UTCTime)
    }
    deriving stock (Eq, Show)

-- | A read consistency request after token validation and freshness selection.
data ResolvedConsistency = ResolvedConsistency
    { consistency :: !Consistency
    , revision :: !Revision
    }
    deriving stock (Eq, Show)

data ConsistencyStore m = ConsistencyStore
    { decodeToken :: ConsistencyToken -> m (Either EnError TokenMetadata)
    , validateToken :: TokenMetadata -> m (Either EnError ())
    , resolveConsistency :: Consistency -> m (Either EnError ResolvedConsistency)
    }
