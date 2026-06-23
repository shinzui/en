module Main (main) where

import Control.Exception (bracket)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Effectful (Eff, runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Network.Wai.Handler.Warp qualified as Warp
import System.Environment (lookupEnv)
import Text.Read (readMaybe)

import En.Error (EnError)
import En.Migrations (migrationsDir)
import En.Postgres.Database (runDatabaseConnection)
import En.Postgres.Revision (ConsistencyConfig (..), runConsistencyStorePostgres)
import En.Postgres.TupleStore (runTupleStorePostgres)
import En.Reachability (compile)
import En.Revision (DatastoreId (..))
import En.Schema (Schema, schemaHash)
import En.Schema.Builder qualified as Schema
import En.Servant.API (app)
import En.Servant.Seam (AppEffects, Env (..))
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings

main :: IO ()
main = do
    databaseUrl <- requiredEnv "EN_DATABASE_URL"
    port <- maybe 8080 parsePort <$> lookupEnv "EN_PORT"
    gcWindow <- maybe "24 hours" Text.pack <$> lookupEnv "EN_GC_WINDOW"
    graph <- either (fail . ("Invalid built-in demo schema: " <>) . show) pure (compile demoSchema)
    connection <-
        Connection.acquire (Settings.connectionString (Text.pack databaseUrl)) >>= \case
            Right value -> pure value
            Left err ->
                fail $
                    "Could not connect to PostgreSQL with EN_DATABASE_URL. "
                        <> show err
                        <> "\nRun the codd migrations in "
                        <> migrationsDir
                        <> " before starting en-server."
    let config =
            ConsistencyConfig
                { datastoreId = DatastoreId "en-server"
                , schemaHash = schemaHash demoSchema
                , gcWindow = gcWindow
                }
        runAppIO :: Eff AppEffects a -> IO (Either EnError a)
        runAppIO =
            runEff
                . runDatabaseConnection connection
                . runErrorNoCallStack
                . runTupleStorePostgres config
                . runConsistencyStorePostgres config
        serverEnv =
            Env
                { runPorts = runAppIO
                , graph
                , maxBatchSize = 1000
                }
    Text.putStrLn ("en-server listening on :" <> Text.pack (show port))
    Text.putStrLn ("Using built-in demo schema; run migrations from " <> Text.pack migrationsDir <> " before writes.")
    bracket (pure connection) Connection.release \_ ->
        Warp.run port (app serverEnv)

requiredEnv :: String -> IO String
requiredEnv name =
    lookupEnv name >>= \case
        Just value | not (null value) -> pure value
        _ ->
            fail $
                "Missing "
                    <> name
                    <> ". Set it to a PostgreSQL connection string, e.g. "
                    <> name
                    <> "='postgresql://user@localhost:5432/en'."

parsePort :: String -> Int
parsePort value =
    case readMaybe value of
        Just port | port > 0 -> port
        _ -> 8080

demoSchema :: Schema
demoSchema =
    Schema.build
        [ Schema.object "user" []
        , Schema.object
            "space"
            [ Schema.relation "viewer" [Schema.subject "user"] Schema.this
            , Schema.permission "view" (Schema.computed "viewer")
            ]
        ]
