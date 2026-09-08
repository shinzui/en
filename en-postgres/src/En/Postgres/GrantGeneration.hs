{-# LANGUAGE MultilineStrings #-}

-- | Grant generations at exact owner snapshots. Callers must first validate the
-- token's datastore, schema and retained-history horizon.
module En.Postgres.GrantGeneration
  ( GrantGeneration,
    grantGenerationText,
    grantGenerationAtSession,
    pruneGrantGenerationsBatchSession,
  )
where

import Data.Functor.Contravariant ((>$<))
import Data.Int (Int64)
import Data.Text qualified as Text
import Data.Word (Word64)
import En.Prelude
import En.Revision (Revision (..))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Session (Session)
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement

newtype GrantGeneration = GrantGeneration Int64 deriving stock (Eq, Show)

grantGenerationText :: GrantGeneration -> Text
grantGenerationText (GrantGeneration value) = "gg1_" <> Text.pack (show value)

grantGenerationAtSession :: Revision -> Session (Maybe GrantGeneration)
grantGenerationAtSession (Revision revision) =
  fmap GrantGeneration <$> Session.statement revision lookupStatement
  where
    lookupStatement =
      Statement.preparable
        """
        SELECT generation FROM en_grant_generation
        WHERE pg_visible_in_snapshot(created_xid, $1::pg_snapshot)
        ORDER BY generation DESC LIMIT 1
        """
        (E.param (E.nonNullable E.text))
        (D.rowMaybe (D.column (D.nonNullable D.int8)))

-- | The horizon must already be durably advanced by owner maintenance. Keep the
-- newest generation below it: every valid snapshot sees that floor. Never reap
-- rows at/above the horizon. Bounds and SKIP LOCKED allow concurrent workers.
pruneGrantGenerationsBatchSession :: Word64 -> Int -> Session Int64
pruneGrantGenerationsBatchSession horizon batch =
  Session.statement (Text.pack (show horizon), fromIntegral (max 0 batch)) pruneStatement
  where
    pruneStatement =
      Statement.preparable
        """
        WITH floor AS (
          SELECT max(generation) AS generation FROM en_grant_generation
          WHERE created_xid < $1::xid8
        ), victims AS (
          SELECT g.generation FROM en_grant_generation g, floor
          WHERE g.created_xid < $1::xid8 AND g.generation < floor.generation
          ORDER BY g.generation LIMIT $2 FOR UPDATE OF g SKIP LOCKED
        ), removed AS (
          DELETE FROM en_grant_generation g USING victims v
          WHERE g.generation = v.generation RETURNING 1
        ) SELECT count(*) FROM removed
        """
        ((fst >$< E.param (E.nonNullable E.text)) <> (snd >$< E.param (E.nonNullable E.int8)))
        (D.singleRow (D.column (D.nonNullable D.int8)))
