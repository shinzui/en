module Main (main) where

import Control.Exception (bracket)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Data.Time (getCurrentTime)
import Network.Wai.Handler.Warp qualified as Warp
import System.Environment (lookupEnv)
import Text.Read (readMaybe)

import En.Effect.TupleStore (TupleStore (..))
import En.Migrations (migrationsDir)
import En.Postgres.Revision (ConsistencyConfig (..), postgresConsistencyStore)
import En.Postgres.TupleStore (postgresTupleStoreIO)
import En.Reachability (compile)
import En.Revision (DatastoreId (..))
import En.Schema (AllowedSubject (..), ObjectType (..), Relation (..), RelationName (..), Rewrite (..), Schema (..))
import En.Schema qualified as Schema
import En.Servant.API (EnServer (..), app)
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings

main :: IO ()
main = do
    databaseUrl <- requiredEnv "EN_DATABASE_URL"
    port <- maybe 8080 parsePort <$> lookupEnv "EN_PORT"
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
                , schemaHash = Schema.schemaHash demoSchema
                }
        tupleStore = postgresTupleStoreIO connection config
        consistencyStore =
            postgresConsistencyStore config getCurrentTime tupleStore.optimizedRevision tupleStore.headRevision
        serverEnv =
            EnServer
                { consistencyStore
                , tupleStore
                , graph
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
    Schema
        { objectTypes =
            Map.fromList
                [ (ObjectType "user", Map.empty)
                ,
                    ( ObjectType "space"
                    , Map.fromList
                        [ relationEntry "viewer" userSubject This
                        , relationEntry "view" Set.empty (ComputedUserset (RelationName "viewer"))
                        ]
                    )
                ]
        , caveats = Map.empty
        }

relationEntry :: Text -> Set.Set AllowedSubject -> Rewrite -> (RelationName, Relation)
relationEntry name allowedSubjects rewrite =
    ( RelationName name
    , Relation
        { relationName = RelationName name
        , allowedSubjects = allowedSubjects
        , rewrite = rewrite
        }
    )

userSubject :: Set.Set AllowedSubject
userSubject =
    Set.singleton AllowedSubject{objectType = ObjectType "user", relation = Nothing}
