module Main (main) where

import Config (BiscuitConfig (..), PoolConfig (..), ServerConfig (..), StoreConfig (..), TlsConfig (..), loadServerConfig, loadStoreConfig, validateGcWindow)
import Control.Concurrent.Async (withAsync)
import Control.Concurrent.MVar (newMVar, withMVar)
import Control.Exception (IOException, finally, try)
import Control.Monad (foldM, guard)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as LazyByteString
import Data.ByteString.Lazy.Char8 qualified as LazyChar8
import Data.Char (isSpace)
import Data.Foldable (traverse_)
import Data.IORef (IORef, atomicWriteIORef, newIORef, readIORef)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Data.Time (DiffTime, getCurrentTime)
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID.V4
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Effectful.Error.Static (Error, runErrorNoCallStack)
import En.Biscuit.Keys (IssuerKeyId (..))
import En.Cache (Cache, CacheConfig (..), SubproblemKey, TupleReadKey, cacheStats, newCache)
import En.Check (CheckCacheEnv (..), checkCachedWithBudget, checkWithBudget)
import En.Decision (ResidualDecision)
import En.Effect.CachedTupleStore (cachedTupleStore)
import En.Effect.TupleStore (PageState (..), StoreCursor, TuplePage (..), TupleRow (..), TupleStore)
import En.Effect.TupleStore qualified as TupleStore
import En.Error (EnError)
import En.Lookup qualified as Lookup
import En.LookupSubjects qualified as LookupSubjects
import En.Postgres.Database (Database, runDatabasePool, runSession)
import En.Postgres.Datastore (resolveDatastoreIdSession)
import En.Postgres.Revision (ConsistencyConfig (..), OptimizedRevisionCache, OptimizedRevisionConfig (..), newOptimizedRevisionCache, runConsistencyStorePostgres)
import En.Postgres.TupleStore (runTupleStorePostgres, runTupleStorePostgresWithOptimizedRevisionCacheHandle)
import En.Postgres.Watch qualified as Watch
-- @ReachabilityGraph (..)@ brings its @hash@ field into scope, which is what lets GHC solve
-- the @HasField@ constraint behind @active.graph.hash@.
import En.Reachability (ReachabilityGraph (..), compile)
import En.Revision (ConsistencyToken (..), DatastoreId (..), Revision (..), SchemaHash (..))
import En.Schema (Schema, ValidSchema, schemaHash, validateSchema)
import En.Schema.Parse (parseSchema)
import En.SchemaCheck (OrphanReport (..), renderTupleOrphan, validateTuplesAgainstSchema)
import En.Servant.API (tupleFromWire, tupleToWire)
import En.Servant.OpenApi (appWithOpenApiProbes)
import En.Servant.Probes (mkProbes)
import En.Servant.Seam (ActiveSchema (..), AppEffects, Env (..), MintEnv (..))
import En.Tuple (Tuple)
import Hasql.Connection.Settings qualified as Settings
import Hasql.Errors qualified as Hasql
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as Pool.Config
import Hasql.Session (Session)
import Hasql.Session qualified as Session
import Maintenance (describeMaintenance, runMaintenanceLoop)
import Metrics (metricsMiddleware, metricsRoute, newMetrics)
import Middleware (authMiddleware, describeRateLimit, rateLimitMiddleware)
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp qualified as Warp
import Network.Wai.Handler.WarpTLS qualified as WarpTLS
import Observability (newRequestLogger, requestIdMiddleware)
import System.Environment (getArgs)
import System.Exit (ExitCode (ExitFailure), exitFailure, exitSuccess, exitWith)
import System.IO (BufferMode (BlockBuffering, LineBuffering), hSetBuffering, stderr, stdout)
import System.Posix.Signals (Handler (Catch), installHandler, sigHUP, sigINT, sigTERM)
import Telemetry (withTelemetry)
import Text.Read (readMaybe)

-- | The four ways to run this binary.
--
-- Bulk import and export are subcommands rather than HTTP endpoints. The API is
-- unauthenticated today, so a bulk-write endpoint would widen that exposure,
-- whereas a subcommand runs with database credentials the operator already holds,
-- needs no new wire contract, and composes with @gzip@, @pv@, and redirects.
--
-- @check-schema@ is a subcommand for a different reason: it exists to be run before
-- any process is touched, from CI or a deploy pipeline, against production data.
data Command
  = Serve
  | Import FilePath Int
  | Export
  | CheckSchema FilePath

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
    -- The candidate is read and validated before the store config is even loaded, so a
    -- typo in a schema file costs no database round trip and no misleading "serving the
    -- built-in demo schema" warning from a command that serves nothing.
    Just (CheckSchema path) -> do
      candidate <- loadCandidateSchema path >>= either candidateFailure pure
      withSubcommandStore (runCheckSchema candidate)

-- | A schema as it was read: the validated model, plus the text and origin
-- @GET \/v1\/schema@ reports.
--
-- The compiled 'En.Reachability.ReachabilityGraph' is not here. It is derived once, when an
-- 'ActiveSchema' is built, and it is what carries the schema hash from then on.
data LoadedSchema = LoadedSchema
  { source :: !Text.Text,
    origin :: !Text.Text,
    validSchema :: !ValidSchema
  }

-- | The shared prologue of the bulk subcommands.
--
-- Reads 'loadStoreConfig' rather than 'loadServerConfig': a command that binds no
-- port has no API keys, rate limit, or TLS material to configure, and
-- 'loadServerConfig' fails closed without them -- correctly, for a server.
withSubcommandStore :: (LoadedSchema -> Pool.Pool -> ConsistencyConfig -> IO ()) -> IO ()
withSubcommandStore action = do
  (storeConfig, warnings) <- loadStoreConfig >>= either configFailure pure
  traverse_ toStderr warnings
  withStore toStderr storeConfig action

parseCommand :: [String] -> Maybe Command
parseCommand = \case
  [] -> Just Serve
  ["export"] -> Just Export
  ["check-schema", path] -> Just (CheckSchema path)
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
    [ "usage:",
      "  en-server                                     serve the HTTP API",
      "  en-server import --file PATH [--batch-size N] import newline-delimited-JSON tuples",
      "  en-server export                              write every live tuple as newline-delimited JSON",
      "  en-server check-schema PATH                   report which live tuples PATH would strand",
      "",
      "All four read EN_DATABASE_URL and the optional EN_SCHEMA_PATH.",
      "check-schema exits 0 when the candidate strands nothing, 1 when it strands grants,",
      "and 2 when the candidate itself cannot be read, parsed, or validated."
    ]
  exitWith (ExitFailure 2)

toStdout :: Text.Text -> IO ()
toStdout = Text.putStrLn

toStderr :: Text.Text -> IO ()
toStderr = Text.hPutStrLn stderr

-- | Validate the schema, open the pool, and resolve this database's identity --
-- everything all three commands need and none of them should do differently.
--
-- Diagnostics travel through @say@ rather than 'Text.putStrLn' so that a command
-- whose stdout is a data stream can route them to stderr.
withStore :: (Text.Text -> IO ()) -> StoreConfig -> (LoadedSchema -> Pool.Pool -> ConsistencyConfig -> IO ()) -> IO ()
withStore say storeConfig action = do
  (schemaSource, sourceText, rawSchema) <- loadSchema storeConfig.schemaPath
  validSchema <-
    either (configFailure . ("Invalid schema: " <>) . Text.pack . show) pure (validateSchema rawSchema)
  let loadedSchema =
        LoadedSchema {source = sourceText, origin = schemaOrigin schemaSource, validSchema}
  say (describeSchemaSource schemaSource)
  say ("Schema hash: " <> renderSchemaHash (schemaHash validSchema))
  let poolConfig = storeConfig.pool
  pool <-
    Pool.acquire $
      Pool.Config.settings
        [ Pool.Config.size poolConfig.size,
          Pool.Config.acquisitionTimeout (millisToDiffTime poolConfig.acquisitionTimeoutMs),
          Pool.Config.idlenessTimeout (millisToDiffTime poolConfig.idlenessTimeoutMs),
          Pool.Config.agingTimeout (millisToDiffTime poolConfig.maxLifetimeMs),
          Pool.Config.staticConnectionSettings
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
          <> "\n"
          <> migrationHint
  -- Only PostgreSQL can adjudicate its own interval grammar, so this waits for a
  -- reachable database -- but it still runs before the port binds.
  validateGcWindow runDbSession storeConfig.gcWindow >>= either configFailure pure
  datastoreIdText <- resolveDatastoreId runDbSession
  say ("Datastore id: " <> datastoreIdText)
  let config =
        ConsistencyConfig
          { datastoreId = DatastoreId datastoreIdText,
            schemaHash = schemaHash validSchema,
            gcWindow = storeConfig.gcWindow
          }
  action loadedSchema pool config `finally` Pool.release pool

runServe :: ServerConfig -> LoadedSchema -> Pool.Pool -> ConsistencyConfig -> IO ()
runServe serverConfig loadedSchema pool config =
  withTelemetry serverConfig.telemetry $
    const $
      runServeApplication serverConfig loadedSchema pool config

runServeApplication :: ServerConfig -> LoadedSchema -> Pool.Pool -> ConsistencyConfig -> IO ()
runServeApplication serverConfig loadedSchema pool config = do
  loadedAt <- getCurrentTime
  activeSchemaRef <-
    newIORef
      ActiveSchema
        { graph = compile loadedSchema.validSchema,
          source = loadedSchema.source,
          origin = loadedSchema.origin,
          loadedAt
        }
  let poolConfig = serverConfig.store.pool
      optimizedRevisionTtlMs = serverConfig.optimizedRevisionTtlMs
      tupleReadMaxEntries = serverConfig.tupleReadMaxEntries
      decisionMaxEntries = serverConfig.decisionMaxEntries
      optimizedRevisionConfig =
        OptimizedRevisionConfig
          { enabled = optimizedRevisionTtlMs > 0,
            ttl = fromRational (toRational optimizedRevisionTtlMs / 1000)
          }
      tupleReadConfig =
        CacheConfig
          { enabled = tupleReadMaxEntries > 0,
            maxEntries = tupleReadMaxEntries
          }
      decisionConfig =
        CacheConfig
          { enabled = decisionMaxEntries > 0,
            maxEntries = decisionMaxEntries
          }
  optimizedRevisionCache <- newOptimizedRevisionCache optimizedRevisionConfig getCurrentTime
  tupleReadCache <- newCache tupleReadConfig :: IO (Cache TupleReadKey TuplePage)
  decisionCache <- newCache decisionConfig :: IO (Cache SubproblemKey ResidualDecision)
  let checkCacheEnv =
        CheckCacheEnv
          { cacheDatastoreId = config.datastoreId,
            cacheDecisions = decisionCache
          }
      {- Both store interpreters are built from the snapshot the caller holds, so the
      schema hash they stamp into every minted token -- and check on every presented
      one -- is the hash of the very graph the handler evaluated against. A reload that
      lands between a handler's snapshot read and its store call cannot tear them apart,
      because there is only one snapshot and the handler is holding it. -}
      runAppIO :: ActiveSchema -> Eff AppEffects a -> IO (Either EnError a)
      runAppIO active action =
        let activeConfig = config {schemaHash = active.graph.hash}
         in runEff
              ( runDatabasePool
                  pool
                  ( runErrorNoCallStack
                      ( runTupleStoreLayer
                          activeConfig
                          optimizedRevisionCache
                          (tupleReadLayer tupleReadCache (runConsistencyStorePostgres activeConfig action))
                      )
                  )
              )
      -- Run against whatever schema is active right now: for the maintenance loop and
      -- the readiness probe, neither of which is a request and neither of which mints a
      -- token a client will ever hold.
      runAppNow :: Eff AppEffects a -> IO (Either EnError a)
      runAppNow action = do
        active <- readIORef activeSchemaRef
        runAppIO active action
      runTupleStoreLayer ::
        ConsistencyConfig ->
        OptimizedRevisionCache ->
        Eff (TupleStore : '[Error EnError, Database, IOE]) a ->
        Eff '[Error EnError, Database, IOE] a
      runTupleStoreLayer activeConfig cache action
        | optimizedRevisionConfig.enabled =
            runTupleStorePostgresWithOptimizedRevisionCacheHandle activeConfig cache action
        | otherwise =
            runTupleStorePostgres activeConfig action
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
          { runPorts = runAppIO,
            readActiveSchema = readIORef activeSchemaRef,
            checkOperation,
            lookupWithDeadlineOperation,
            lookupSubjectsWithDeadlineOperation,
            -- The feed reads the store and mints its own cursors; there is no
            -- decision cache to substitute, so it is `watch` partially applied to
            -- the datastore identity its cursors are stamped with.
            --
            -- The startup `config` is safe to capture here even though its schema hash
            -- goes stale on reload: `watch` reads only `datastoreId` from it, and a
            -- watch cursor deliberately carries no schema hash to check (a tuple change
            -- is schema-independent data). The tokens it mints and validates go through
            -- the `ConsistencyStore` interpreter, which `runAppIO` rebuilt from the
            -- request's snapshot.
            watchOperation = Watch.watch config,
            budget,
            maxBatchSize = serverConfig.maxBatchSize,
            deadlineDefaultMillis = serverConfig.deadlineDefaultMillis,
            deadlineMaxMillis = serverConfig.deadlineMaxMillis,
            -- The active schema hash a grant embeds is not captured here: the handler
            -- reads it from the request's `ActiveSchema` snapshot, so a SIGHUP reload
            -- cannot mint a grant under a hash its check did not evaluate under.
            mint = mintEnvFromConfig <$> serverConfig.biscuit
          }
      ping :: IO Bool
      ping = do
        result <- runAppNow (runSession (Session.script "SELECT 1"))
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
  (livenessProbe, readinessProbe) <-
    mkProbes
      (readIORef activeSchemaRef >> pure True)
      checkReady
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
  Text.putStrLn ("Biscuit grant minting: " <> describeMinting serverConfig.biscuit)
  Text.putStrLn ("Background maintenance: " <> describeMaintenance serverConfig.maintenance)
  Text.putStrLn
    ( "Lookup deadline: defaultMs="
        <> Text.pack (show serverConfig.deadlineDefaultMillis)
        <> ", maxMs="
        <> Text.pack (show serverConfig.deadlineMaxMillis)
        <> "; max batch size: "
        <> Text.pack (show serverConfig.maxBatchSize)
    )
  Text.putStrLn ("Schema reload: SIGHUP" <> describeReloadSource serverConfig.store.schemaPath serverConfig.schemaReloadForce)
  -- One writer, serialized. Two SIGHUPs in flight would otherwise race to
  -- `atomicWriteIORef`, and the loser's orphan report would describe a schema that is
  -- not the one now serving.
  reloadGuard <- newMVar ()
  _ <-
    installHandler
      sigHUP
      (Catch (withMVar reloadGuard \() -> reloadSchema serverConfig activeSchemaRef runAppNow))
      Nothing

  rateLimit <- rateLimitMiddleware serverConfig.rateLimit
  requestLogger <- newRequestLogger
  metrics <- newMetrics
  -- Outermost first. Authentication precedes logging so a log line can name a
  -- verified caller, and precedes rate limiting so buckets are per-caller. Request
  -- ids sit inside the limiter, so a throttled request costs no UUID. The metrics
  -- layer wraps the servant application, so probes are counted; it cannot see the 401/403/429
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
          . metricsRoute
            metrics
            [ ("tuple_read", cacheStats tupleReadCache),
              ("decision", cacheStats decisionCache)
            ]
          $ appWithOpenApiProbes serverEnv livenessProbe readinessProbe
  -- `serve` returns when SIGTERM drains the server, at which point `withAsync`
  -- cancels the maintenance thread and `withStore`'s `finally` releases the pool.
  -- Every maintenance batch is its own committed transaction, so cancelling mid-pass
  -- loses only the batch in flight; the next start resumes from what was committed.
  withAsync (runMaintenanceLoop serverConfig.maintenance runAppNow) \_maintenance ->
    serve serverConfig.tls serverConfig.port wrappedApp

-- | Build the servant seam's 'MintEnv' from the parsed issuer configuration.
--
-- Only key material and TTL bounds cross over; the schema hash a grant embeds is the
-- request-time snapshot's, read in the handler.
mintEnvFromConfig :: BiscuitConfig -> MintEnv
mintEnvFromConfig cfg =
  MintEnv
    { issuerSecretKey = cfg.issuerSecretKey,
      issuerKeyId = cfg.issuerKeyId,
      defaultTtl = fromIntegral cfg.defaultTtlSeconds,
      maxTtl = fromIntegral cfg.maxTtlSeconds
    }

-- | The @Biscuit grant minting:@ startup line.
--
-- Logs the key id and TTL bounds so an operator can confirm which issuer is active,
-- but never the secret key material.
describeMinting :: Maybe BiscuitConfig -> Text.Text
describeMinting = \case
  Nothing -> "disabled"
  Just cfg ->
    let IssuerKeyId keyId = cfg.issuerKeyId
     in "enabled (key id "
          <> showText keyId
          <> ", defaultTtl="
          <> showText cfg.defaultTtlSeconds
          <> "s, maxTtl="
          <> showText cfg.maxTtlSeconds
          <> "s)"

describeReloadSource :: Maybe FilePath -> Bool -> Text.Text
describeReloadSource schemaPath force =
  case schemaPath of
    Nothing -> " (no EN_SCHEMA_PATH; nothing to reload)"
    Just path ->
      " re-reads " <> Text.pack path <> forceSuffix
  where
    forceSuffix
      | force = "; EN_SCHEMA_RELOAD_FORCE=true, orphaning schemas will be ACTIVATED"
      | otherwise = "; orphaning schemas are refused"

-- | Re-read @EN_SCHEMA_PATH@ and swap the active schema, or refuse and keep serving.
--
-- Every failure mode leaves the previous 'ActiveSchema' untouched: an unreadable file, a parse
-- error, a validation error, and an orphan refusal all log and return. A running authorization
-- server must survive a bad reload rather than exit — which is the one place this diverges from
-- the fail-closed startup path, where exiting is the safe thing to do because nothing is being
-- served yet.
--
-- Nothing is needed here for in-flight requests. A request took its snapshot at its start and
-- holds it; 'atomicWriteIORef' is seen only by snapshots taken after it returns.
--
-- An unchanged file is not a reload. The swap is skipped when the candidate's hash equals the
-- active one's, which also skips the token-invalidation warning — an operator who signals twice
-- should not be told, falsely, that they have just invalidated every token in flight.
reloadSchema ::
  ServerConfig ->
  IORef ActiveSchema ->
  (forall a. Eff AppEffects a -> IO (Either EnError a)) ->
  IO ()
reloadSchema serverConfig activeSchemaRef runAppNow =
  case serverConfig.store.schemaPath of
    Nothing -> toStdout "SIGHUP received but no EN_SCHEMA_PATH is set; nothing to reload."
    Just path -> reloadFrom path
  where
    reloadFrom path =
      loadCandidateSchema path >>= \case
        Left err -> refuse ("schema reload failed: " <> err)
        Right candidate -> do
          active <- readIORef activeSchemaRef
          let graph = compile candidate.validSchema
              oldHash = renderSchemaHash active.graph.hash
              newHash = renderSchemaHash graph.hash
          if graph.hash == active.graph.hash
            then toStdout ("Schema unchanged (" <> newHash <> "); not reloading.")
            else
              runAppNow (validateCandidate candidate.validSchema) >>= \case
                Left err -> refuse ("schema reload failed: could not scan the store: " <> showText err)
                Right report -> activate candidate graph oldHash newHash report

    -- Scanned under whatever schema is active: the pass mints no token and presents none,
    -- so the interpreters' schema hash never enters into it. It reads the head revision and
    -- drains it, and that is all.
    validateCandidate candidate = do
      revision <- TupleStore.headRevision
      validateTuplesAgainstSchema candidate revision

    activate candidate graph oldHash newHash report
      | not (null report.orphans) && not serverConfig.schemaReloadForce = do
          toStdout ("Schema reload refused: " <> orphanSummary newHash report)
          traverse_ (toStdout . renderTupleOrphan) report.orphans
          toStdout "reload refused; set EN_SCHEMA_RELOAD_FORCE=true to activate anyway."
      | otherwise = do
          loadedAt <- getCurrentTime
          atomicWriteIORef
            activeSchemaRef
            ActiveSchema
              { graph,
                source = candidate.source,
                origin = candidate.origin,
                loadedAt
              }
          if null report.orphans
            then pure ()
            else do
              toStdout ("Schema reload FORCED over " <> orphanSummary newHash report)
              traverse_ (toStdout . renderTupleOrphan) report.orphans
          toStdout ("Schema reloaded from " <> candidate.origin)
          toStdout ("Schema hash: " <> newHash <> " (was " <> oldHash <> ")")
          toStdout "WARNING: all consistency tokens minted under the previous schema hash are now invalid."

    orphanSummary newHash report =
      showText (length report.orphans)
        <> " orphan(s) across "
        <> showText report.scanned
        <> " live tuple(s) under candidate "
        <> newHash

    refuse message = do
      toStderr ("en-server: " <> message)
      toStderr "the previous schema is still serving."

-- | Run a store action against the pool: the effect stack a subcommand needs.
--
-- Neither cache layer appears. An import writes and a caching interposer would only
-- hold pages nothing will read again; an export reads each page exactly once.
runStoreIO :: Pool.Pool -> ConsistencyConfig -> Eff '[TupleStore, Error EnError, Database, IOE] a -> IO (Either EnError a)
runStoreIO pool config action =
  runEff (runDatabasePool pool (runErrorNoCallStack (runTupleStorePostgres config action)))

-- | Stream newline-delimited-JSON tuples from a file into the store.
--
-- Each batch is one ordinary write: one transaction, one anchor, one consistency
-- token. A reader presenting a batch's token sees that batch whole or not at all,
-- and the final token -- printed to stdout as the machine-readable last line -- sees
-- the entire import.
--
-- The whole operation is idempotent. Touch semantics make re-writing an existing
-- tuple a no-op, so a crashed import is resumed by re-running it from the start:
-- the batches already applied cost a round trip and change nothing. This is why
-- import needs no checkpoint file.
--
-- The file is read lazily and consumed one batch at a time, so memory tracks the
-- batch size rather than the file size. That streaming is why a malformed line
-- aborts the import with the batches before it already committed: the alternative,
-- validating the whole file first, would hold every tuple in memory and forfeit the
-- point of streaming. The line is named in the error, and the prefix is harmless --
-- re-running the corrected file re-applies it as a no-op.
runImport :: FilePath -> Int -> LoadedSchema -> Pool.Pool -> ConsistencyConfig -> IO ()
runImport path batchSize _loadedSchema pool config = do
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

-- | Write every live tuple to stdout as newline-delimited JSON.
--
-- The head revision is resolved once, and every page is read at it, so writers may
-- proceed throughout and the output is the graph as it stood when the export began
-- rather than a smear across the run. Feeding the result to 'runImport' reproduces
-- that graph.
--
-- stdout is switched to block buffering: it is a redirect or a pipe here, never a
-- terminal a human is watching line by line, and the line buffering the serving
-- path needs would cost a write syscall per tuple.
runExport :: LoadedSchema -> Pool.Pool -> ConsistencyConfig -> IO ()
runExport _loadedSchema pool config = do
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
      TuplePage {rows, state} <- TupleStore.readAllTuples revision exportPageSize cursor
      liftIO (traverse_ (LazyChar8.putStrLn . Aeson.encode . tupleToWire . (.tuple)) rows)
      let exportedNow = exported + length rows
      case state of
        Exhausted -> pure exportedNow
        HasMore next -> drainFrom revision (Just next) exportedNow
        Truncated next -> drainFrom revision (Just next) exportedNow

    exportPageSize = 5000

-- | Report which live tuples a candidate schema would strand, and exit accordingly.
--
-- Read-only: it touches no process and writes no row. The point is to be run from CI or a
-- deploy pipeline against production data, /before/ the schema is put anywhere near a server.
--
-- Exit codes: 0 when the candidate strands nothing, 1 when it strands grants, 2 when the
-- candidate itself cannot be read, parsed, or validated (raised by 'loadCandidateSchema',
-- before this runs). The 2 is shared with 'usage', which is the honest grouping: both mean the
-- operator gave this command something it cannot act on, and neither says anything about the
-- state of the store.
--
-- The active schema this process loaded (from @EN_SCHEMA_PATH@, or the demo model) is
-- deliberately ignored. The question is what the /candidate/ makes of the stored data, and a
-- pipeline vetting a schema change should not have to arrange for the outgoing one to be
-- present.
runCheckSchema :: LoadedSchema -> LoadedSchema -> Pool.Pool -> ConsistencyConfig -> IO ()
runCheckSchema candidate _activeSchema pool config = do
  let candidateHash = renderSchemaHash (schemaHash candidate.validSchema)
  outcome <- runStoreIO pool config do
    revision <- TupleStore.headRevision
    liftIO (toStderr ("checking at revision " <> revision.revisionEncoding))
    validateTuplesAgainstSchema candidate.validSchema revision
  report <- either (storeFailure "check-schema") pure outcome
  traverse_ (Text.putStrLn . renderTupleOrphan) report.orphans
  let orphanCount = length report.orphans
      summary =
        showText orphanCount
          <> " orphan(s) across "
          <> showText report.scanned
          <> " live tuple(s); candidate schema "
          <> candidateHash
  if orphanCount == 0
    then do
      Text.putStrLn (summary <> " fits them all.")
      exitSuccess
    else do
      Text.putStrLn (summary <> " would strand them.")
      exitWith (ExitFailure 1)

-- | Read, parse, and validate a candidate schema without exiting, keeping its source text.
--
-- 'loadSchema' cannot be reused for either caller. Every one of its failure paths calls
-- 'configFailure', which exits 1 -- the code 'runCheckSchema' reserves for "the candidate
-- strands live grants" (a pipeline that cannot tell a typo in a schema file from a schema that
-- would destroy data is worse than no pipeline), and which a running server must never do
-- because an operator mistyped a file it was asked to reload.
loadCandidateSchema :: FilePath -> IO (Either Text.Text LoadedSchema)
loadCandidateSchema path = do
  readResult <- try (Text.readFile path) :: IO (Either IOException Text.Text)
  pure do
    source <-
      case readResult of
        Right value -> Right value
        Left err -> Left ("could not read " <> Text.pack path <> ": " <> Text.pack (show err))
    parsed <-
      case parseSchema source of
        Right value -> Right value
        Left err -> Left ("could not parse " <> Text.pack path <> ": " <> Text.pack (show err))
    case validateSchema parsed of
      Right validSchema -> Right LoadedSchema {source, origin = Text.pack path, validSchema}
      Left err -> Left ("invalid schema in " <> Text.pack path <> ": " <> Text.pack (show err))

-- | The candidate is unusable. Distinct from 'configFailure', which exits 1.
candidateFailure :: Text.Text -> IO a
candidateFailure message = do
  Text.hPutStrLn stderr ("en-server: " <> message)
  exitWith (ExitFailure 2)

storeFailure :: Text.Text -> EnError -> IO a
storeFailure command err =
  configFailure (command <> " failed: " <> Text.pack (show err))

-- | Split a list into runs of at most @size@, lazily.
--
-- Laziness is the point: the import's batches are produced as the file is read, so
-- a file larger than memory still imports.
chunksOf :: Int -> [a] -> [[a]]
chunksOf size = \case
  [] -> []
  items -> let (chunk, rest) = splitAt size items in chunk : chunksOf size rest

showText :: (Show a) => a -> Text.Text
showText = Text.pack . show

-- | Mint a candidate identity and let the database decide.
--
-- The insert is a no-op if the database already has an id, so this is idempotent across
-- restarts and safe against servers racing on a fresh database. A failure here almost
-- always means the metadata migration has not been applied -- serving with a fallback
-- identity would silently re-open the cross-datastore hole this table exists to close, so
-- it is a startup failure instead.
resolveDatastoreId :: (forall a. Session a -> IO (Either Text.Text a)) -> IO Text.Text
resolveDatastoreId runDbSession = do
  candidate <- UUID.toText <$> UUID.V4.nextRandom
  runDbSession (resolveDatastoreIdSession candidate) >>= \case
    Right value -> pure value
    Left err ->
      configFailure $
        "Could not resolve this database's datastore identity: "
          <> err
          <> "\nThis database's migrations are missing or out of date. "
          <> migrationHint

-- | A startup-time database failure, in prose rather than as hasql's constructors.
--
-- @show@ on a @UsageError@ nests four constructors around PostgreSQL's own sentence,
-- which is the only part an operator needs.
renderUsageError :: Pool.UsageError -> Text.Text
renderUsageError = \case
  Pool.SessionUsageError sessionError -> Hasql.toDetailedText sessionError
  Pool.ConnectionUsageError connectionError -> Text.pack (show connectionError)
  Pool.AcquisitionTimeoutUsageError -> "timed out acquiring a pooled database connection"

-- | Render a configuration failure and exit 1.
--
-- Every configuration error used to travel through @fail@, so the operator saw
-- @en-server: Uncaught exception … user error (…)@ wrapped around an otherwise clear
-- message. Nothing is bound or opened by the time these run, so there is nothing to
-- unwind.
configFailure :: Text.Text -> IO a
configFailure message = do
  Text.hPutStrLn stderr ("en-server: " <> message)
  exitFailure

-- | What an operator should actually run when the schema is missing or stale.
--
-- en-server deliberately neither applies nor verifies migrations itself: pg-migrate's
-- guidance is that migrations belong to an explicit deployment or administrative job,
-- not to service startup. All this does is name that job.
migrationHint :: Text.Text
migrationHint = "Apply migrations with `cabal run en-migrate -- up`."

-- | Run Warp until SIGTERM or SIGINT, then drain.
--
-- The shutdown handler receives Warp's @closeSocket@: on signal the listening socket
-- closes, in-flight requests run to completion (capped at 30 seconds, comfortably above
-- the lookup deadline), and 'Warp.runSettings' /returns/. That return is the contract
-- the caller's @finally@ depends on to release the connection pool -- with @Warp.run@ it
-- never happened, and a background maintenance thread would likewise never be cancelled.
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

-- | Replaces the RTS default for SIGINT, which throws to the main thread and aborts
-- in-flight requests. Both signals now mean the same thing: stop listening, then drain.
installShutdownHandler :: IO () -> IO ()
installShutdownHandler closeSocket = do
  _ <- installHandler sigTERM (Catch closeSocket) Nothing
  _ <- installHandler sigINT (Catch closeSocket) Nothing
  pure ()

data SchemaSource
  = BuiltInDemoSchema
  | SchemaFile FilePath

-- | Where a schema came from, as @GET \/v1\/schema@ reports it.
--
-- The demo model has no file, so it reports @builtin-demo@ rather than a path a caller could
-- mistake for one.
schemaOrigin :: SchemaSource -> Text.Text
schemaOrigin = \case
  BuiltInDemoSchema -> "builtin-demo"
  SchemaFile path -> Text.pack path

-- | Read and parse the schema, keeping the source text.
--
-- The text is kept rather than re-rendered from the parsed model: there is no
-- @Schema -> Text@ serializer for the loadable DSL, and it is the operator's own text that
-- @GET \/v1\/schema@ should return and that a candidate schema should be diffed against. The
-- built-in demo model therefore carries a hand-written source string that must stay in step
-- with 'demoSchema' — the startup path parses neither, so nothing checks it but this comment.
loadSchema :: Maybe FilePath -> IO (SchemaSource, Text.Text, Schema)
loadSchema =
  \case
    Nothing -> pure (BuiltInDemoSchema, demoSchemaSource, demoSchema)
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
          pure (SchemaFile path, contents, parsed)

describeSchemaSource :: SchemaSource -> Text.Text
describeSchemaSource =
  \case
    BuiltInDemoSchema ->
      "Using built-in demo schema; " <> migrationHint <> " before writes."
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

-- | The fallback model, as text.
--
-- This is the source of truth for the demo schema, and 'demoSchema' is derived from it by
-- the same parser a real @EN_SCHEMA_PATH@ goes through. The other direction — a model built
-- with "En.Schema.Builder" plus a hand-written string claiming to be its text — is what
-- @GET \/v1\/schema@ makes dangerous: the endpoint promises @source@ is the model the server
-- is serving, and nothing but discipline would have kept the two in step.
demoSchemaSource :: Text.Text
demoSchemaSource =
  Text.unlines
    [ "object user {}",
      "",
      "object space {",
      "  relation viewer: user",
      "  permission view = viewer",
      "}"
    ]

demoSchema :: Schema
demoSchema =
  either (error . ("invalid demo schema: " <>) . show) id (parseSchema demoSchemaSource)
