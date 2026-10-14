{-# LANGUAGE MultilineStrings #-}

-- | Grant generations at exact owner snapshots. Metadata callers must validate
-- the token after the read so concurrent retention advances fail closed.
module En.Postgres.GrantGeneration
  ( GrantGeneration,
    grantGenerationText,
    grantGenerationAtSession,
    grantGenerationLookupSql,
    pruneGrantGenerationsSql,
    grantGenerationForToken,
    pruneGrantGenerationsBatchSession,
  )
where

import Data.Functor.Contravariant ((>$<))
import Data.Generics.Labels ()
import Data.Int (Int64)
import Data.Text qualified as Text
import Data.Word (Word64)
import Effectful (Eff, (:>))
import Effectful.Error.Static (Error, throwError)
import En.Effect.ConsistencyStore (ConsistencyStore)
import En.Effect.ConsistencyStore qualified as ConsistencyStore
import En.Error (EnError (..))
import En.Postgres.Database (Database, runSession)
import En.Prelude
import En.Revision (ConsistencyToken, Revision (..))
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
        grantGenerationLookupSql
        (E.param (E.nonNullable E.text))
        (D.singleRow (D.column (D.nullable D.int8)))

-- | One statement snapshot for all seeks. Commit-ordered visibility is a prefix.
-- Try at most 33 newest rows; otherwise bisect the numeric interval. A missing
-- successor shrinks the upper bound and is never treated as an invisible key.
-- Every step halves the interval or better, so nonnegative Int64 keys need at
-- most 64 steps. Subtraction before addition avoids midpoint overflow. The upper
-- endpoint is invisible (fast path failed), so generation + 1 cannot overflow.
-- The spike verifies actual index plans; keep PostgreSQL statistics current.
grantGenerationLookupSql :: Text
grantGenerationLookupSql =
  """
  SELECT COALESCE(
    (SELECT generation FROM (
       SELECT generation, created_xid FROM en_grant_generation
       ORDER BY generation DESC LIMIT 33
     ) recent
     WHERE pg_visible_in_snapshot(created_xid, $1::pg_snapshot)
     ORDER BY generation DESC LIMIT 1),
    (WITH RECURSIVE search(lo, hi, answer) AS (
       SELECT
         (SELECT generation FROM en_grant_generation ORDER BY generation LIMIT 1),
         (SELECT generation FROM en_grant_generation ORDER BY generation DESC LIMIT 1) - 1,
         NULL::bigint
       UNION ALL
       SELECT
         CASE WHEN candidate.visible THEN candidate.generation + 1 ELSE search.lo END,
         CASE WHEN candidate.visible THEN search.hi ELSE midpoint.value - 1 END,
         CASE WHEN candidate.visible THEN candidate.generation ELSE search.answer END
       FROM search
       CROSS JOIN LATERAL (SELECT search.lo + (search.hi-search.lo)/2 AS value) midpoint
       LEFT JOIN LATERAL (
         SELECT generation, pg_visible_in_snapshot(created_xid,$1::pg_snapshot) AS visible
         FROM en_grant_generation
         WHERE generation >= midpoint.value AND generation <= search.hi
         ORDER BY generation LIMIT 1
       ) candidate ON true
       WHERE search.lo <= search.hi
     ) SELECT answer FROM search WHERE lo > hi LIMIT 1)
  )
  """

-- | The horizon must already be durably advanced by owner maintenance. Keep the
-- newest generation below it: every valid snapshot sees that floor. Never reap
-- rows at/above the horizon. Bounds and SKIP LOCKED allow concurrent workers.
pruneGrantGenerationsBatchSession :: Word64 -> Int -> Session Int64
pruneGrantGenerationsBatchSession horizon batch =
  Session.statement (Text.pack (show horizon), fromIntegral (max 0 batch)) pruneStatement
  where
    pruneStatement =
      Statement.preparable
        pruneGrantGenerationsSql
        ((fst >$< E.param (E.nonNullable E.text)) <> (snd >$< E.param (E.nonNullable E.int8)))
        (D.singleRow (D.column (D.nonNullable D.int8)))

pruneGrantGenerationsSql :: Text
pruneGrantGenerationsSql =
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

-- | Decode the token already minted by the check without another horizon read.
-- Resolve metadata at its revision, never at a later head. Validate
-- retention again after the read so concurrent collection cannot validate a
-- snapshot at one horizon and return metadata after that horizon has advanced.
grantGenerationForToken :: (ConsistencyStore :> es, Database :> es, Error EnError :> es) => ConsistencyToken -> Eff es (Maybe Text)
grantGenerationForToken token = do
  metadata <- ConsistencyStore.decodeToken token
  result <- runSession (grantGenerationAtSession (metadata ^. #revision))
  value <- case result of
    Right (Just generation) -> pure generation
    Right Nothing -> throwError (StoreError "grant generation history unavailable")
    Left _ -> throwError (StoreError "grant generation read failed")
  ConsistencyStore.validateToken metadata
  pure (Just (grantGenerationText value))
