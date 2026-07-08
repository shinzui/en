module Main (main) where

import Control.Exception (IOException, bracket, try)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Data.Time (getCurrentTime)
import Effectful (Eff, IOE, runEff)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Network.Wai.Handler.Warp qualified as Warp
import System.Environment (lookupEnv)
import Text.Read (readMaybe)

import En.Cache (Cache, CacheConfig (..), SubproblemKey, TupleReadKey, newCache)
import En.Check (CheckCacheEnv (..), CheckDecision, check, checkCached)
import En.Effect.CachedTupleStore (cachedTupleStore)
import En.Effect.TupleStore (TuplePage, TupleStore)
import En.Error (EnError)
import En.Lookup qualified as Lookup
import En.Migrations (migrationsDir)
import En.Postgres.Database (Database, runDatabaseConnection)
import En.Postgres.Revision (ConsistencyConfig (..), OptimizedRevisionCache, OptimizedRevisionConfig (..), newOptimizedRevisionCache, runConsistencyStorePostgres)
import En.Postgres.TupleStore (runTupleStorePostgres, runTupleStorePostgresWithOptimizedRevisionCacheHandle)
import En.Reachability (compile)
import En.Revision (DatastoreId (..), SchemaHash (..))
import En.Schema (Schema, schemaHash, validateSchema)
import En.Schema.Builder qualified as Schema
import En.Schema.Parse (parseSchema)
import En.Servant.API (app)
import En.Servant.Seam (AppEffects, Env (..))
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Middleware (authMiddleware, loadAuthConfig)

main :: IO ()
main = do
    databaseUrl <- requiredEnv "EN_DATABASE_URL"
    authConfig <- loadAuthConfig
    port <- maybe 8080 parsePort <$> lookupEnv "EN_PORT"
    gcWindow <- maybe "24 hours" Text.pack <$> lookupEnv "EN_GC_WINDOW"
    optimizedRevisionTtlMs <- optionalNonNegativeIntEnv "EN_OPTIMIZED_REVISION_CACHE_TTL_MS"
    tupleReadMaxEntries <- optionalNonNegativeIntEnv "EN_TUPLE_READ_CACHE_MAX_ENTRIES"
    decisionMaxEntries <- optionalNonNegativeIntEnv "EN_DECISION_CACHE_MAX_ENTRIES"
    (schemaSource, rawSchema) <- loadSchema
    validSchema <- either (fail . ("Invalid schema: " <>) . show) pure (validateSchema rawSchema)
    let activeSchemaHash = schemaHash validSchema
        graph = compile validSchema
    logSchemaSource schemaSource
    Text.putStrLn ("Schema hash: " <> renderSchemaHash activeSchemaHash)
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
                , schemaHash = activeSchemaHash
                , gcWindow = gcWindow
                }
        optimizedRevisionConfig =
            OptimizedRevisionConfig
                { enabled = optimizedRevisionTtlMs > 0
                , ttl = fromRational (toRational optimizedRevisionTtlMs / 1000)
                }
        tupleReadConfig =
            CacheConfig
                { enabled = tupleReadMaxEntries > 0
                , maxEntries = tupleReadMaxEntries
                }
        decisionConfig =
            CacheConfig
                { enabled = decisionMaxEntries > 0
                , maxEntries = decisionMaxEntries
                }
    optimizedRevisionCache <- newOptimizedRevisionCache optimizedRevisionConfig getCurrentTime
    tupleReadCache <- newCache tupleReadConfig :: IO (Cache TupleReadKey TuplePage)
    decisionCache <- newCache decisionConfig :: IO (Cache SubproblemKey CheckDecision)
    let checkCacheEnv =
            CheckCacheEnv
                { cacheDatastoreId = config.datastoreId
                , cacheDecisions = decisionCache
                }
        runAppIO :: Eff AppEffects a -> IO (Either EnError a)
        runAppIO action =
            runEff
                ( runDatabaseConnection
                    connection
                    ( runErrorNoCallStack
                        ( runTupleStoreLayer
                            optimizedRevisionCache
                            (tupleReadLayer tupleReadCache (runConsistencyStorePostgres config action))
                        )
                    )
                )
        runTupleStoreLayer ::
            OptimizedRevisionCache ->
            Eff (TupleStore : '[Error EnError, Database, IOE]) a ->
            Eff '[Error EnError, Database, IOE] a
        runTupleStoreLayer cache action
            | optimizedRevisionConfig.enabled =
                runTupleStorePostgresWithOptimizedRevisionCacheHandle config cache action
            | otherwise =
                runTupleStorePostgres config action
        tupleReadLayer ::
            Cache TupleReadKey TuplePage ->
            Eff '[TupleStore, Error EnError, Database, IOE] a ->
            Eff '[TupleStore, Error EnError, Database, IOE] a
        tupleReadLayer cache action
            | tupleReadConfig.enabled = cachedTupleStore cache action
            | otherwise = action
        checkOperation graph' consistency context subject relation object
            | decisionConfig.enabled =
                checkCached checkCacheEnv graph' consistency context subject relation object
            | otherwise =
                check graph' consistency context subject relation object
        lookupWithDeadlineOperation deadline graph' consistency request
            | decisionConfig.enabled =
                Lookup.lookupWithDeadlineCached checkCacheEnv deadline graph' consistency request
            | otherwise =
                Lookup.lookupWithDeadline deadline graph' consistency request
        serverEnv =
            Env
                { runPorts = runAppIO
                , graph
                , checkOperation
                , lookupWithDeadlineOperation
                , maxBatchSize = 1000
                }
    Text.putStrLn ("en-server listening on :" <> Text.pack (show port))
    Text.putStrLn ("Optimized revision cache: " <> describeMillisCache optimizedRevisionTtlMs)
    Text.putStrLn ("Tuple-read cache: " <> describeEntryCache tupleReadMaxEntries)
    Text.putStrLn ("Decision cache: " <> describeEntryCache decisionMaxEntries)
    bracket (pure connection) Connection.release \_ ->
        Warp.run port (authMiddleware authConfig (app serverEnv))

data SchemaSource
    = BuiltInDemoSchema
    | SchemaFile FilePath

loadSchema :: IO (SchemaSource, Schema)
loadSchema =
    lookupEnv "EN_SCHEMA_PATH" >>= \case
        Nothing -> do
            Text.putStrLn "WARNING: EN_SCHEMA_PATH not set; serving the built-in demo schema. Set EN_SCHEMA_PATH=/path/to/schema.en to serve your own model."
            pure (BuiltInDemoSchema, demoSchema)
        Just "" ->
            fail "Invalid EN_SCHEMA_PATH: expected a non-empty schema file path."
        Just path -> do
            readResult <- try (Text.readFile path) :: IO (Either IOException Text.Text)
            contents <-
                case readResult of
                    Right value -> pure value
                    Left err ->
                        fail $
                            "Could not read schema file from EN_SCHEMA_PATH="
                                <> path
                                <> ": "
                                <> show err
            case parseSchema contents of
                Left err ->
                    fail $
                        "Failed to parse schema from EN_SCHEMA_PATH="
                            <> path
                            <> ": "
                            <> show err
                Right parsed ->
                    pure (SchemaFile path, parsed)

logSchemaSource :: SchemaSource -> IO ()
logSchemaSource =
    \case
        BuiltInDemoSchema ->
            Text.putStrLn ("Using built-in demo schema; run migrations from " <> Text.pack migrationsDir <> " before writes.")
        SchemaFile path ->
            Text.putStrLn ("Loaded schema from " <> Text.pack path)

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

optionalNonNegativeIntEnv :: String -> IO Int
optionalNonNegativeIntEnv name =
    lookupEnv name >>= \case
        Nothing -> pure 0
        Just "" -> fail ("Invalid " <> name <> ": expected a non-negative integer")
        Just value ->
            case readMaybe value of
                Just parsed | parsed >= 0 -> pure parsed
                _ -> fail ("Invalid " <> name <> ": expected a non-negative integer")

describeMillisCache :: Int -> Text.Text
describeMillisCache ttlMs
    | ttlMs <= 0 = "disabled"
    | otherwise = "enabled, ttlMs=" <> Text.pack (show ttlMs)

describeEntryCache :: Int -> Text.Text
describeEntryCache maxEntries
    | maxEntries <= 0 = "disabled"
    | otherwise = "enabled, maxEntries=" <> Text.pack (show maxEntries)

renderSchemaHash :: SchemaHash -> Text.Text
renderSchemaHash (SchemaHash value) =
    value

demoSchema :: Schema
demoSchema =
    either (error . ("invalid demo schema: " <>) . show) id $ do
        userObject <- Schema.object "user" []
        spaceObject <-
            Schema.object
                "space"
                [ Schema.relation "viewer" [Schema.subject "user"] Schema.this
                , Schema.permission "view" (Schema.computed "viewer")
                ]
        Schema.build [userObject, spaceObject]
