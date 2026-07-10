module Main (main) where

import Control.Concurrent.Async (withAsync)
import Control.Exception (IOException, finally, try)
import Control.Monad (foldM, guard)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as LazyByteString
import Data.ByteString.Lazy.Char8 qualified as LazyChar8
import Data.Char (isSpace)
import Data.Foldable (traverse_)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Data.Time (DiffTime, getCurrentTime)
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID.V4
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp qualified as Warp
import Network.Wai.Handler.WarpTLS qualified as WarpTLS
import System.Environment (getArgs)
import System.Exit (ExitCode (ExitFailure), exitFailure, exitWith)
import System.IO (BufferMode (BlockBuffering, LineBuffering), hSetBuffering, stderr, stdout)
import System.Posix.Signals (Handler (Catch), installHandler, sigINT, sigTERM)
import Text.Read (readMaybe)

import Config (PoolConfig (..), ServerConfig (..), StoreConfig (..), TlsConfig (..), loadServerConfig, loadStoreConfig, validateGcWindow)
import En.Cache (Cache, CacheConfig (..), SubproblemKey, TupleReadKey, cacheStats, newCache)
import En.Check (CheckCacheEnv (..), checkCachedWithBudget, checkWithBudget)
import En.Decision (ResidualDecision)
import En.Effect.CachedTupleStore (cachedTupleStore)
import En.Effect.TupleStore (PageState (..), StoreCursor, TuplePage (..), TupleRow (..), TupleStore)
import En.Effect.TupleStore qualified as TupleStore
import En.Error (EnError)
import En.Lookup qualified as Lookup
import En.LookupSubjects qualified as LookupSubjects
import En.Migrations (migrationsDir)
import En.Postgres.Database (Database, runDatabasePool, runSession)
import En.Postgres.Datastore (resolveDatastoreIdSession)
import En.Postgres.Revision (ConsistencyConfig (..), OptimizedRevisionCache, OptimizedRevisionConfig (..), newOptimizedRevisionCache, runConsistencyStorePostgres)
import En.Postgres.TupleStore (runTupleStorePostgres, runTupleStorePostgresWithOptimizedRevisionCacheHandle)
import En.Postgres.Watch qualified as Watch
import En.Reachability (compile)
import En.Revision (ConsistencyToken (..), DatastoreId (..), Revision (..), SchemaHash (..))
import En.Schema (Schema, ValidSchema, schemaHash, validateSchema)
import En.Schema.Builder qualified as Schema
import En.Schema.Parse (parseSchema)
import En.Servant.API (tupleFromWire, tupleToWire)
import En.Servant.OpenApi (appWithOpenApi)
import En.Servant.Seam (AppEffects, Env (..))
import En.Tuple (Tuple)
import Hasql.Connection.Settings qualified as Settings
import Hasql.Errors qualified as Hasql
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as Pool.Config
import Hasql.Session (Session)
import Hasql.Session qualified as Session
import Health (healthRoutes)
import Maintenance (describeMaintenance, runMaintenanceLoop)
import Metrics (metricsMiddleware, metricsRoute, newMetrics)
import Middleware (authMiddleware, describeRateLimit, rateLimitMiddleware)
import Observability (newRequestLogger, requestIdMiddleware)

{- | The three ways to run this binary.

Bulk import and export are subcommands rather than HTTP endpoints. The API is
unauthenticated today, so a bulk-write endpoint would widen that exposure,
whereas a subcommand runs with database credentials the operator already holds,
needs no new wire contract, and composes with @gzip@, @pv@, and redirects.
-}
data Command
    = Serve
    | Import FilePath Int
    | Export

-- | Tuples per import transaction when @--batch-size@ is not given.
defaultBatchSize :: Int
defaultBatchSize = 5000

main :: IO ()
main = do
    -- stdout is a pipe under every supervisor, and GHC block-buffers pipes. Without
    -- this, startup lines -- including the "authentication is DISABLED" warning --
    -- sit in a buffer that SIGTERM discards, and every request log line is delayed.
    hSetBuffering stdout LineBuffering
    args <- getArgs
    case parseCommand args of
        Nothing -> usage
        Just Serve -> do
            (serverConfig, warnings) <- loadServerConfig >>= either configFailure pure
            traverse_ toStdout warnings
            withStore toStdout serverConfig.store (runServe serverConfig)
        -- A subcommand's stdout carries data -- the export stream, the import's
        -- token line -- so every diagnostic the shared prologue emits goes to stderr.
        Just (Import path batchSize) -> withSubcommandStore (runImport path batchSize)
        Just Export -> withSubcommandStore runExport

{- | The shared prologue of the bulk subcommands.

Reads 'loadStoreConfig' rather than 'loadServerConfig': a command that binds no
port has no API keys, rate limit, or TLS material to configure, and
'loadServerConfig' fails closed without them -- correctly, for a server.
-}
withSubcommandStore :: (ValidSchema -> Pool.Pool -> ConsistencyConfig -> IO ()) -> IO ()
withSubcommandStore action = do
    (storeConfig, warnings) <- loadStoreConfig >>= either configFailure pure
    traverse_ toStderr warnings
    withStore toStderr storeConfig action

parseCommand :: [String] -> Maybe Command
parseCommand = \case
    [] -> Just Serve
    ["export"] -> Just Export
    ("import" : rest) -> parseImport Nothing defaultBatchSize rest
    _ -> Nothing
  where
    parseImport path batchSize = \case
        [] -> Import <$> path <*> Just batchSize
        ("--file" : value : rest) -> parseImport (Just value) batchSize rest
        ("--batch-size" : value : rest) -> do
            parsed <- readMaybe value
            guard (parsed > 0)
            parseImport path parsed rest
        _ -> Nothing

usage :: IO a
usage = do
    traverse_
        (Text.hPutStrLn stderr)
        [ "usage:"
        , "  en-server                                     serve the HTTP API"
        , "  en-server import --file PATH [--batch-size N] import newline-delimited-JSON tuples"
        , "  en-server export                              write every live tuple as newline-delimited JSON"
        , ""
        , "All three read EN_DATABASE_URL and the optional EN_SCHEMA_PATH."
        ]
    exitWith (ExitFailure 2)

toStdout :: Text.Text -> IO ()
toStdout = Text.putStrLn

toStderr :: Text.Text -> IO ()
toStderr = Text.hPutStrLn stderr

{- | Validate the schema, open the pool, and resolve this database's identity --
everything all three commands need and none of them should do differently.

Diagnostics travel through @say@ rather than 'Text.putStrLn' so that a command
whose stdout is a data stream can route them to stderr.
-}
withStore :: (Text.Text -> IO ()) -> StoreConfig -> (ValidSchema -> Pool.Pool -> ConsistencyConfig -> IO ()) -> IO ()
withStore say storeConfig action = do
    (schemaSource, rawSchema) <- loadSchema storeConfig.schemaPath
    validSchema <-
        either (configFailure . ("Invalid schema: " <>) . Text.pack . show) pure (validateSchema rawSchema)
    say (describeSchemaSource schemaSource)
    say ("Schema hash: " <> renderSchemaHash (schemaHash validSchema))
    let poolConfig = storeConfig.pool
    pool <-
        Pool.acquire $
            Pool.Config.settings
                [ Pool.Config.size poolConfig.size
                , Pool.Config.acquisitionTimeout (millisToDiffTime poolConfig.acquisitionTimeoutMs)
                , Pool.Config.idlenessTimeout (millisToDiffTime poolConfig.idlenessTimeoutMs)
                , Pool.Config.agingTimeout (millisToDiffTime poolConfig.maxLifetimeMs)
                , Pool.Config.staticConnectionSettings
                    (Settings.connectionString storeConfig.databaseUrl)
                ]
    let runDbSession :: Session a -> IO (Either Text.Text a)
        runDbSession session =
            either (Left . renderUsageError) Right <$> Pool.use pool session
    -- Pool connections are established lazily, so a bad EN_DATABASE_URL would
    -- otherwise surface only on the first request rather than at startup.
    runDbSession (Session.script "SELECT 1") >>= \case
        Right () -> pure ()
        Left err ->
            configFailure $
                "Could not reach PostgreSQL through EN_DATABASE_URL. "
                    <> err
                    <> "\nApply the migrations in "
                    <> Text.pack migrationsDir
                    <> " before starting en-server."
    -- Only PostgreSQL can adjudicate its own interval grammar, so this waits for a
    -- reachable database -- but it still runs before the port binds.
    validateGcWindow runDbSession storeConfig.gcWindow >>= either configFailure pure
    datastoreIdText <- resolveDatastoreId runDbSession
    say ("Datastore id: " <> datastoreIdText)
    let config =
            ConsistencyConfig
                { datastoreId = DatastoreId datastoreIdText
                , schemaHash = schemaHash validSchema
                , gcWindow = storeConfig.gcWindow
                }
    action validSchema pool config `finally` Pool.release pool

runServe :: ServerConfig -> ValidSchema -> Pool.Pool -> ConsistencyConfig -> IO ()
runServe serverConfig validSchema pool config = do
    let graph = compile validSchema
        poolConfig = serverConfig.store.pool
        optimizedRevisionTtlMs = serverConfig.optimizedRevisionTtlMs
        tupleReadMaxEntries = serverConfig.tupleReadMaxEntries
        decisionMaxEntries = serverConfig.decisionMaxEntries
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
    decisionCache <- newCache decisionConfig :: IO (Cache SubproblemKey ResidualDecision)
    let checkCacheEnv =
            CheckCacheEnv
                { cacheDatastoreId = config.datastoreId
                , cacheDecisions = decisionCache
                }
        runAppIO :: Eff AppEffects a -> IO (Either EnError a)
        runAppIO action =
            runEff
                ( runDatabasePool
                    pool
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
        -- The engine's static bounds are applied here, once, so no handler and no
        -- request can choose them. See "En.Budget".
        budget = serverConfig.budget
        checkOperation graph' consistency context subject relation object
            | decisionConfig.enabled =
                checkCachedWithBudget budget checkCacheEnv graph' consistency context subject relation object
            | otherwise =
                checkWithBudget budget graph' consistency context subject relation object
        lookupWithDeadlineOperation deadline graph' consistency request
            | decisionConfig.enabled =
                Lookup.lookupWithDeadlineCachedAndBudget budget checkCacheEnv deadline graph' consistency request
            | otherwise =
                Lookup.lookupWithDeadlineAndBudget budget deadline graph' consistency request
        lookupSubjectsWithDeadlineOperation deadline graph' consistency request
            | decisionConfig.enabled =
                LookupSubjects.lookupSubjectsWithDeadlineCachedAndBudget budget checkCacheEnv deadline graph' consistency request
            | otherwise =
                LookupSubjects.lookupSubjectsWithDeadlineAndBudget budget deadline graph' consistency request
        serverEnv =
            Env
                { runPorts = runAppIO
                , graph
                , checkOperation
                , lookupWithDeadlineOperation
                , lookupSubjectsWithDeadlineOperation
                , -- The feed reads the store and mints its own cursors; there is no
                  -- decision cache to substitute, so it is `watch` partially applied to
                  -- the datastore identity its cursors are stamped with.
                  watchOperation = Watch.watch config
                , budget
                , maxBatchSize = serverConfig.maxBatchSize
                , deadlineDefaultMillis = serverConfig.deadlineDefaultMillis
                , deadlineMaxMillis = serverConfig.deadlineMaxMillis
                }
        ping :: IO Bool
        ping = do
            result <- runAppIO (runSession (Session.script "SELECT 1"))
            pure (case result of Right (Right ()) -> True; _ -> False)
        -- Readiness goes through the Database effect, so it exercises the pool a real
        -- request would use rather than a connection held aside for probing.
        --
        -- It pings twice before reporting unready. After a PostgreSQL restart the
        -- first session on a stale pooled connection fails at the *statement* level,
        -- which hasql-pool does not treat as grounds to discard the connection; only a
        -- connection-level failure retires it. A single-shot probe would therefore flap
        -- to unready against a perfectly healthy database, and would spend the failure
        -- that a real request could have absorbed instead.
        checkReady :: IO Bool
        checkReady = do
            healthy <- ping
            if healthy then pure True else ping
    Text.putStrLn ("en-server listening on :" <> Text.pack (show serverConfig.port))
    Text.putStrLn
        ( "Connection pool: size="
            <> Text.pack (show poolConfig.size)
            <> ", acquisitionTimeoutMs="
            <> Text.pack (show poolConfig.acquisitionTimeoutMs)
            <> ", idlenessTimeoutMs="
            <> Text.pack (show poolConfig.idlenessTimeoutMs)
            <> ", maxLifetimeMs="
            <> Text.pack (show poolConfig.maxLifetimeMs)
        )
    Text.putStrLn ("Optimized revision cache: " <> describeMillisCache optimizedRevisionTtlMs)
    Text.putStrLn ("Tuple-read cache: " <> describeEntryCache tupleReadMaxEntries)
    Text.putStrLn ("Decision cache: " <> describeEntryCache decisionMaxEntries)
    Text.putStrLn ("Rate limit: " <> describeRateLimit serverConfig.rateLimit)
    Text.putStrLn ("Background maintenance: " <> describeMaintenance serverConfig.maintenance)
    Text.putStrLn
        ( "Lookup deadline: defaultMs="
            <> Text.pack (show serverConfig.deadlineDefaultMillis)
            <> ", maxMs="
            <> Text.pack (show serverConfig.deadlineMaxMillis)
            <> "; max batch size: "
            <> Text.pack (show serverConfig.maxBatchSize)
        )
    rateLimit <- rateLimitMiddleware serverConfig.rateLimit
    requestLogger <- newRequestLogger
    metrics <- newMetrics
    -- Outermost first. Authentication precedes logging so a log line can name a
    -- verified caller, and precedes rate limiting so buckets are per-caller. Request
    -- ids sit inside the limiter, so a throttled request costs no UUID. The metrics
    -- layer wraps the health routes, so probes are counted; it cannot see the 401/403/429
    -- the outer middlewares short-circuit, which stay countable at the proxy.
    --
    -- Serves `appWithOpenApi`, not `app`: the former adds GET /v1/openapi.json and the
    -- ErrorFormatters that make body-parse and 404 errors speak the error envelope.
    let wrappedApp =
            authMiddleware serverConfig.auth
                . rateLimit
                . requestIdMiddleware
                . requestLogger
                . metricsMiddleware metrics
                . healthRoutes checkReady
                . metricsRoute
                    metrics
                    [ ("tuple_read", cacheStats tupleReadCache)
                    , ("decision", cacheStats decisionCache)
                    ]
                $ appWithOpenApi serverEnv
    -- `serve` returns when SIGTERM drains the server, at which point `withAsync`
    -- cancels the maintenance thread and `withStore`'s `finally` releases the pool.
    -- Every maintenance batch is its own committed transaction, so cancelling mid-pass
    -- loses only the batch in flight; the next start resumes from what was committed.
    withAsync (runMaintenanceLoop serverConfig.maintenance runAppIO) \_maintenance ->
        serve serverConfig.tls serverConfig.port wrappedApp

{- | Run a store action against the pool: the effect stack a subcommand needs.

Neither cache layer appears. An import writes and a caching interposer would only
hold pages nothing will read again; an export reads each page exactly once.
-}
runStoreIO :: Pool.Pool -> ConsistencyConfig -> Eff '[TupleStore, Error EnError, Database, IOE] a -> IO (Either EnError a)
runStoreIO pool config action =
    runEff (runDatabasePool pool (runErrorNoCallStack (runTupleStorePostgres config action)))

{- | Stream newline-delimited-JSON tuples from a file into the store.

Each batch is one ordinary write: one transaction, one anchor, one consistency
token. A reader presenting a batch's token sees that batch whole or not at all,
and the final token -- printed to stdout as the machine-readable last line -- sees
the entire import.

The whole operation is idempotent. Touch semantics make re-writing an existing
tuple a no-op, so a crashed import is resumed by re-running it from the start:
the batches already applied cost a round trip and change nothing. This is why
import needs no checkpoint file.

The file is read lazily and consumed one batch at a time, so memory tracks the
batch size rather than the file size. That streaming is why a malformed line
aborts the import with the batches before it already committed: the alternative,
validating the whole file first, would hold every tuple in memory and forfeit the
point of streaming. The line is named in the error, and the prefix is harmless --
re-running the corrected file re-applies it as a no-op.
-}
runImport :: FilePath -> Int -> ValidSchema -> Pool.Pool -> ConsistencyConfig -> IO ()
runImport path batchSize _validSchema pool config = do
    contents <- LazyByteString.readFile path
    let numbered = zip [1 :: Int ..] (LazyChar8.lines contents)
        populated = [line | line <- numbered, not (LazyChar8.all isSpace (snd line))]
        -- An empty file still mints a token, so `token:` is always the last line.
        batches = case chunksOf batchSize populated of
            [] -> [[]]
            chunked -> chunked
    (imported, finalToken) <- foldM importBatch (0 :: Int, Nothing) batches
    toStderr ("imported " <> showText imported <> " tuples")
    case finalToken of
        Nothing -> configFailure "import produced no consistency token"
        Just (ConsistencyToken token) -> Text.putStrLn ("token: " <> token)
  where
    importBatch (imported, _) batch = do
        tuples <- traverse decodeLine batch
        outcome <- runStoreIO pool config (TupleStore.writeTuples tuples)
        token <- either (storeFailure "import") pure outcome
        let importedNow = imported + length tuples
        toStderr ("imported " <> showText importedNow)
        pure (importedNow, Just token)

    decodeLine :: (Int, LazyByteString.ByteString) -> IO Tuple
    decodeLine (lineNumber, line) =
        case Aeson.eitherDecode line of
            Left err -> lineFailure lineNumber (Text.pack err)
            Right wire -> either (lineFailure lineNumber) pure (tupleFromWire wire)

    lineFailure :: Int -> Text.Text -> IO a
    lineFailure lineNumber reason =
        configFailure (Text.pack path <> ":" <> showText lineNumber <> ": " <> reason)

{- | Write every live tuple to stdout as newline-delimited JSON.

The head revision is resolved once, and every page is read at it, so writers may
proceed throughout and the output is the graph as it stood when the export began
rather than a smear across the run. Feeding the result to 'runImport' reproduces
that graph.

stdout is switched to block buffering: it is a redirect or a pipe here, never a
terminal a human is watching line by line, and the line buffering the serving
path needs would cost a write syscall per tuple.
-}
runExport :: ValidSchema -> Pool.Pool -> ConsistencyConfig -> IO ()
runExport _validSchema pool config = do
    hSetBuffering stdout (BlockBuffering Nothing)
    outcome <- runStoreIO pool config do
        revision <- TupleStore.headRevision
        liftIO (toStderr ("exporting at revision " <> revision.revisionEncoding))
        drainFrom revision Nothing 0
    exported <- either (storeFailure "export") pure outcome
    toStderr ("exported " <> showText exported <> " tuples")
  where
    drainFrom :: (TupleStore :> es, IOE :> es) => Revision -> Maybe StoreCursor -> Int -> Eff es Int
    drainFrom revision cursor exported = do
        TuplePage{rows, state} <- TupleStore.readAllTuples revision exportPageSize cursor
        liftIO (traverse_ (LazyChar8.putStrLn . Aeson.encode . tupleToWire . (.tuple)) rows)
        let exportedNow = exported + length rows
        case state of
            Exhausted -> pure exportedNow
            HasMore next -> drainFrom revision (Just next) exportedNow
            Truncated next -> drainFrom revision (Just next) exportedNow

    exportPageSize = 5000

storeFailure :: Text.Text -> EnError -> IO a
storeFailure command err =
    configFailure (command <> " failed: " <> Text.pack (show err))

{- | Split a list into runs of at most @size@, lazily.

Laziness is the point: the import's batches are produced as the file is read, so
a file larger than memory still imports.
-}
chunksOf :: Int -> [a] -> [[a]]
chunksOf size = \case
    [] -> []
    items -> let (chunk, rest) = splitAt size items in chunk : chunksOf size rest

showText :: (Show a) => a -> Text.Text
showText = Text.pack . show

{- | Mint a candidate identity and let the database decide.

The insert is a no-op if the database already has an id, so this is idempotent across
restarts and safe against servers racing on a fresh database. A failure here almost
always means the metadata migration has not been applied -- serving with a fallback
identity would silently re-open the cross-datastore hole this table exists to close, so
it is a startup failure instead.
-}
resolveDatastoreId :: (forall a. Session a -> IO (Either Text.Text a)) -> IO Text.Text
resolveDatastoreId runDbSession = do
    candidate <- UUID.toText <$> UUID.V4.nextRandom
    runDbSession (resolveDatastoreIdSession candidate) >>= \case
        Right value -> pure value
        Left err ->
            configFailure $
                "Could not resolve this database's datastore identity: "
                    <> err
                    <> "\nIs the en_datastore_metadata migration from "
                    <> Text.pack migrationsDir
                    <> " applied?"

{- | A startup-time database failure, in prose rather than as hasql's constructors.

@show@ on a @UsageError@ nests four constructors around PostgreSQL's own sentence,
which is the only part an operator needs.
-}
renderUsageError :: Pool.UsageError -> Text.Text
renderUsageError = \case
    Pool.SessionUsageError sessionError -> Hasql.toDetailedText sessionError
    Pool.ConnectionUsageError connectionError -> Text.pack (show connectionError)
    Pool.AcquisitionTimeoutUsageError -> "timed out acquiring a pooled database connection"

{- | Render a configuration failure and exit 1.

Every configuration error used to travel through @fail@, so the operator saw
@en-server: Uncaught exception … user error (…)@ wrapped around an otherwise clear
message. Nothing is bound or opened by the time these run, so there is nothing to
unwind.
-}
configFailure :: Text.Text -> IO a
configFailure message = do
    Text.hPutStrLn stderr ("en-server: " <> message)
    exitFailure

{- | Run Warp until SIGTERM or SIGINT, then drain.

The shutdown handler receives Warp's @closeSocket@: on signal the listening socket
closes, in-flight requests run to completion (capped at 30 seconds, comfortably above
the lookup deadline), and 'Warp.runSettings' /returns/. That return is the contract
the caller's @finally@ depends on to release the connection pool -- with @Warp.run@ it
never happened, and a background maintenance thread would likewise never be cancelled.
-}
serve :: Maybe TlsConfig -> Int -> Wai.Application -> IO ()
serve tlsConfig port wrappedApp = do
    let settings =
            Warp.setPort port
                . Warp.setGracefulShutdownTimeout (Just 30)
                . Warp.setInstallShutdownHandler installShutdownHandler
                $ Warp.defaultSettings
    case tlsConfig of
        Just tls -> do
            Text.putStrLn ("Serving TLS directly (EN_TLS_CERT_FILE=" <> Text.pack tls.certFile <> ")")
            WarpTLS.runTLS
                (WarpTLS.tlsSettings tls.certFile tls.keyFile)
                settings
                wrappedApp
        Nothing -> do
            Text.putStrLn "Serving plaintext HTTP; terminate TLS at a reverse proxy or set EN_TLS_CERT_FILE/EN_TLS_KEY_FILE."
            Warp.runSettings settings wrappedApp
    Text.putStrLn "en-server: drained in-flight requests; shutting down"

{- | Replaces the RTS default for SIGINT, which throws to the main thread and aborts
in-flight requests. Both signals now mean the same thing: stop listening, then drain.
-}
installShutdownHandler :: IO () -> IO ()
installShutdownHandler closeSocket = do
    _ <- installHandler sigTERM (Catch closeSocket) Nothing
    _ <- installHandler sigINT (Catch closeSocket) Nothing
    pure ()

data SchemaSource
    = BuiltInDemoSchema
    | SchemaFile FilePath

loadSchema :: Maybe FilePath -> IO (SchemaSource, Schema)
loadSchema =
    \case
        Nothing -> pure (BuiltInDemoSchema, demoSchema)
        Just path -> do
            readResult <- try (Text.readFile path) :: IO (Either IOException Text.Text)
            contents <-
                case readResult of
                    Right value -> pure value
                    Left err ->
                        configFailure $
                            "Could not read schema file from EN_SCHEMA_PATH="
                                <> Text.pack path
                                <> ": "
                                <> Text.pack (show err)
            case parseSchema contents of
                Left err ->
                    configFailure $
                        "Failed to parse schema from EN_SCHEMA_PATH="
                            <> Text.pack path
                            <> ": "
                            <> Text.pack (show err)
                Right parsed ->
                    pure (SchemaFile path, parsed)

describeSchemaSource :: SchemaSource -> Text.Text
describeSchemaSource =
    \case
        BuiltInDemoSchema ->
            "Using built-in demo schema; run migrations from " <> Text.pack migrationsDir <> " before writes."
        SchemaFile path ->
            "Loaded schema from " <> Text.pack path

millisToDiffTime :: Int -> DiffTime
millisToDiffTime ms =
    fromRational (toRational ms / 1000)

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
