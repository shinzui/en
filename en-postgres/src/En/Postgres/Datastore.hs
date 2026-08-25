{-# LANGUAGE MultilineStrings #-}

-- | This database's persistent datastore identity.
--
-- Every consistency token embeds a datastore id, and @validateTokenMetadata@ (in
-- "En.Postgres.Revision") rejects a token whose id does not match the serving datastore.
-- That check only means something if distinct databases carry distinct ids, which in turn
-- means the id has to live with the data it identifies rather than in the server's
-- configuration.
module En.Postgres.Datastore
  ( resolveDatastoreIdSession,
  )
where

import Data.Text (Text)
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Session (Session)
import Hasql.Session qualified as Session
import Hasql.Statement (Statement)
import Hasql.Statement qualified as Statement

-- | Return this database's datastore id, minting the caller's @candidate@ if the
-- database does not have one yet.
--
-- Idempotent, and safe against servers racing on a fresh database: the insert is a no-op
-- for everyone but the winner, and every caller then reads the winning row. A caller
-- whose candidate loses simply uses the id that won -- which is the point, since both are
-- serving the same data.
--
-- Errors if the row is missing after the insert, which can only mean the metadata table
-- was emptied concurrently.
resolveDatastoreIdSession :: Text -> Session Text
resolveDatastoreIdSession candidate = do
  Session.statement candidate claimDatastoreIdStatement
  Session.statement () readDatastoreIdStatement

claimDatastoreIdStatement :: Statement Text ()
claimDatastoreIdStatement =
  Statement.preparable
    """
    INSERT INTO en_datastore_metadata (datastore_id)
    VALUES ($1)
    ON CONFLICT DO NOTHING
    """
    (Encoders.param (Encoders.nonNullable Encoders.text))
    Decoders.noResult

readDatastoreIdStatement :: Statement () Text
readDatastoreIdStatement =
  Statement.preparable
    "SELECT datastore_id FROM en_datastore_metadata"
    Encoders.noParams
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.text)))
