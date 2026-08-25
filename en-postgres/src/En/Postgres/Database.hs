{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | The PostgreSQL database effect: a thin effectful wrapper over a hasql connection.
module En.Postgres.Database
  ( Database (..),
    runSession,
    runDatabaseConnection,
    runDatabasePool,
  )
where

import Data.Bifunctor (first)
import Effectful (Dispatch (..), DispatchOf, Eff, Effect, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret_, send)
import Hasql.Connection (Connection)
import Hasql.Connection qualified as Connection
import Hasql.Errors (SessionError (..))
import Hasql.Errors qualified as Errors
import Hasql.Pool qualified as Pool
import Hasql.Session (Session)

data Database :: Effect where
  RunSession :: Session a -> Database m (Either SessionError a)

type instance DispatchOf Database = Dynamic

runSession :: (Database :> es) => Session a -> Eff es (Either SessionError a)
runSession =
  send . RunSession

runDatabaseConnection :: (IOE :> es) => Connection -> Eff (Database : es) a -> Eff es a
runDatabaseConnection connection =
  interpret_ \case
    RunSession session ->
      liftIO (Connection.use connection session)

-- | Interpret 'Database' against a hasql-pool 'Pool'. Pool-level failures
-- (connection establishment, acquisition timeout) are reported as
-- 'ConnectionSessionError' so consumers see one error type.
runDatabasePool :: (IOE :> es) => Pool.Pool -> Eff (Database : es) a -> Eff es a
runDatabasePool pool =
  interpret_ \case
    RunSession session ->
      liftIO (first usageToSessionError <$> Pool.use pool session)

usageToSessionError :: Pool.UsageError -> SessionError
usageToSessionError = \case
  Pool.SessionUsageError err -> err
  Pool.ConnectionUsageError err ->
    ConnectionSessionError ("pool connection failure: " <> Errors.toDetailedText err)
  Pool.AcquisitionTimeoutUsageError ->
    ConnectionSessionError "timed out acquiring a pooled database connection"
