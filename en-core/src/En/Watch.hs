{-# LANGUAGE NoFieldSelectors #-}

-- | The vocabulary of the watch feed: where a subscription starts, and what one poll
-- returns.
--
-- Datastore-neutral by construction. The cursor is opaque 'Text' here and its codec, its
-- validation, and the window orchestration live in the store that mints it — for PostgreSQL,
-- "En.Postgres.Watch". These types exist in en-core so that the HTTP seam
-- ("En.Servant.Seam") can carry a watch operation without naming a PostgreSQL type, which is
-- what lets a host that serves no feed (@en-example@) and a test that fakes one
-- (@en-servant/test/Main.hs@) build without the store.
module En.Watch
  ( WatchStart (..),
    WatchBatch (..),
    watchUnsupported,
  )
where

import Data.Text (Text)
import Effectful (Eff, (:>))
import Effectful.Error.Static (Error, throwError)
import En.Effect.TupleStore (RelationshipFilter, TupleChange)
import En.Error (EnError (..))
import En.Revision (ConsistencyToken)

-- | Where a poll's revision window begins.
--
-- 'StartFromToken' takes an ordinary consistency token rather than a watch cursor, so
-- "every change since my write" and "every change since the snapshot this decision token
-- records" are one call. It is validated as a token — schema hash included — because it is
-- one.
data WatchStart
  = -- | Subscribe from the current head. The first poll returns no changes, only a cursor.
    StartFromNow
  | -- | Resume from a cursor a previous poll returned.
    StartFromCursor !Text
  | -- | Start from the revision an ordinary consistency token pins.
    StartFromToken !Text
  deriving stock (Eq, Show)

-- | One poll's answer: the changes in the window, and where to resume.
--
-- 'cursor' is always present, including for an empty batch — a consumer that polls a caught-up
-- feed must still be able to poll again. 'checkedAt' is the token of the revision the window
-- ended at, following the convention every other read response carries.
data WatchBatch = WatchBatch
  { changes :: ![TupleChange],
    cursor :: !Text,
    checkedAt :: !ConsistencyToken
  }
  deriving stock (Eq, Show)

-- | The watch operation for a host that serves no feed.
--
-- Every 'En.Servant.Seam.Env' must supply one, and an embedded host that never routes to
-- @\/v1\/watch@ has nothing real to supply. Failing loudly beats a batch of no changes and a
-- cursor that never advances, which a consumer would read as "caught up" forever.
watchUnsupported :: (Error EnError :> es) => WatchStart -> Maybe RelationshipFilter -> Int -> Eff es WatchBatch
watchUnsupported _start _relationshipFilter _limit =
  throwError (StoreError "this host does not serve the watch feed")
