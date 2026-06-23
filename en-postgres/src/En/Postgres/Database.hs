{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | The PostgreSQL database effect: a thin effectful wrapper over a hasql connection.
module En.Postgres.Database (
    Database (..),
    runSession,
    runDatabaseConnection,
) where

import Effectful (Dispatch (..), DispatchOf, Eff, Effect, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret_, send)
import Hasql.Connection (Connection)
import Hasql.Connection qualified as Connection
import Hasql.Errors (SessionError)
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
