{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | Consistency resolution boundary.
--
-- Storage implementations decode tokens, validate datastore/schema identity,
-- check the garbage-collection window, and choose the concrete snapshot used by
-- a read. The core algorithms depend on this boundary rather than knowing how a
-- PostgreSQL @pg_snapshot@ token is encoded.
module En.Effect.ConsistencyStore
  ( TokenMetadata (..),
    ResolvedConsistency (..),
    ConsistencyStore (..),
    decodeToken,
    validateToken,
    resolveConsistency,
    mintToken,
  )
where

import Data.Time (UTCTime)
import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)
import En.Revision
  ( Consistency,
    ConsistencyToken,
    DatastoreId,
    Revision,
    SchemaHash,
  )

-- | Decoded, validated token contents.
data TokenMetadata = TokenMetadata
  { token :: !ConsistencyToken,
    revision :: !Revision,
    datastoreId :: !DatastoreId,
    schemaHash :: !SchemaHash,
    expiresAt :: !(Maybe UTCTime)
  }
  deriving stock (Eq, Show)

-- | A read consistency request after token validation and freshness selection.
data ResolvedConsistency = ResolvedConsistency
  { consistency :: !Consistency,
    revision :: !Revision
  }
  deriving stock (Eq, Show)

data ConsistencyStore :: Effect where
  DecodeToken :: ConsistencyToken -> ConsistencyStore m TokenMetadata
  ValidateToken :: TokenMetadata -> ConsistencyStore m ()
  ResolveConsistency :: Consistency -> ConsistencyStore m ResolvedConsistency
  -- | Mint a token pinning the given revision, stamped with this datastore's
  --     identity and schema hash and expiring with the garbage-collection window.
  --
  --     This is the inverse of 'DecodeToken', and only the datastore can perform
  --     it: the token encoding belongs to the storage layer, so an engine that
  --     assembled its own "token-equivalent" would fork the format and, worse,
  --     would not be checkable by 'ValidateToken'. Anything that wants to hand a
  --     revision back to a client and later trust it on the way in -- a lookup
  --     cursor, a read response's @checked_at@ -- mints here.
  MintToken :: Revision -> ConsistencyStore m ConsistencyToken

type instance DispatchOf ConsistencyStore = Dynamic

decodeToken :: (ConsistencyStore :> es) => ConsistencyToken -> Eff es TokenMetadata
decodeToken =
  send . DecodeToken

validateToken :: (ConsistencyStore :> es) => TokenMetadata -> Eff es ()
validateToken =
  send . ValidateToken

resolveConsistency :: (ConsistencyStore :> es) => Consistency -> Eff es ResolvedConsistency
resolveConsistency =
  send . ResolveConsistency

mintToken :: (ConsistencyStore :> es) => Revision -> Eff es ConsistencyToken
mintToken =
  send . MintToken
