-- | One datastore's complete runtime: the tenant stack.
--
-- Everything @en-server@ holds once per datastore lives here: the connection pool, the
-- datastore identity, the active schema, the three caches, the rate-limit buckets, the
-- metrics registry, and the WAI application that serves requests once they are
-- authenticated. A server without @EN_TENANTS@ builds exactly one stack; a server with it
-- builds one per tenant (docs/plans/73-serve-tenants-selected-by-api-key-each-from-its-own-isolated-stack.md).
--
-- Isolation between tenants is by construction rather than by checks: a stack's handlers
-- hold one 'Env', that 'Env' holds one pool, and every consistency token, watch cursor and
-- cache key it mints or reads already binds that pool's datastore id and schema hash. No
-- module below this one receives a tenant name.
module Tenant
  ( -- * Configuration
    TenantName (..),
    TenantConfig (..),

    -- * The stack
    TenantStack (..),
    Runner (..),
    buildStack,
    releaseStack,
    reloadStack,
    stackSay,

    -- * Opening a store without serving it
    LoadedSchema (..),
    OpenedStore (..),
    openStore,
    loadCandidateSchema,

    -- * Shared helpers
    configFailure,
    renderSchemaHash,
    showText,
    toStdout,
    toStderr,
  )
where

import Config (BiscuitConfig (..), SharedConfig (..), StoreConfig (..), TenantConfig (..), TenantName (..), tenantVariable, validateGcWindow)
import Control.Exception (IOException, try)
import Data.Foldable (traverse_)
import Data.Generics.Labels ()
import Data.IORef (IORef, atomicWriteIORef, newIORef, readIORef)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Data.Time (DiffTime)
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID.V4
import Effectful (Eff, IOE, runEff)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import En.Cache (Cache, CacheConfig (..), SubproblemKey, TupleReadKey, cacheStats, newCache)
import En.Check (CheckCacheEnv (..), checkCachedWithBudget, checkWithBudget)
import En.Decision (ResidualDecision)
import En.Effect.CachedTupleStore (cachedTupleStore)
import En.Effect.TupleStore (TuplePage (..), TupleStore)
import En.Effect.TupleStore qualified as TupleStore
import En.Error (EnError)
import En.Lookup qualified as Lookup
import En.LookupSubjects qualified as LookupSubjects
import En.Postgres.Database (Database, runDatabasePool, runSession)
import En.Postgres.Datastore (resolveDatastoreIdSession)
import En.Postgres.GrantGeneration qualified as GrantGeneration
import En.Postgres.Revision (ConsistencyConfig (..), OptimizedRevisionCache, OptimizedRevisionConfig (..), newOptimizedRevisionCache, runConsistencyStorePostgres)
import En.Postgres.TupleStore (runTupleStorePostgres, runTupleStorePostgresWithOptimizedRevisionCacheHandle)
import En.Postgres.Watch qualified as Watch
import En.Prelude
import En.Reachability (compile)
import En.Revision (DatastoreId (..), SchemaHash (..))
import En.Schema (Schema, ValidSchema, schemaHash, validateSchema)
import En.Schema.Parse (parseSchema)
import En.SchemaCheck (renderTupleOrphan, validateTuplesAgainstSchema)
import En.Servant.OpenApi (appWithOpenApiProbes)
import En.Servant.Probes (mkProbes)
import En.Servant.Seam (ActiveSchema (..), AppEffects, Env (..), MintEnv (..))
import Hasql.Connection.Settings qualified as Settings
import Hasql.Errors qualified as Hasql
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as Pool.Config
import Hasql.Session (Session)
import Hasql.Session qualified as Session
import Metrics (metricsMiddleware, metricsRoute, newMetrics)
import Middleware (rateLimitMiddleware)
import Network.Wai qualified as Wai
import Observability (requestIdMiddleware)
import Servant.Health (ProbeCheck)
import System.Exit (exitFailure)
import System.IO (stderr)

-- | Run an engine action against a stack's pool under the schema active right now.
--
-- A newtype so that the polymorphic function can sit in a record with a 'Generic'
-- instance.
newtype Runner = Runner (forall a. Eff AppEffects a -> IO (Either EnError a))

-- | Everything that exists once per datastore at run time.
data TenantStack = TenantStack
  { -- | 'Nothing' only for the implicit stack of legacy mode.
    name :: !(Maybe TenantName),
    -- | Prepended to every line this stack logs: empty in legacy mode, so its output is
    --     unchanged, and @[tenant NAME] @ otherwise.
    logPrefix :: !Text,
    store :: !StoreConfig,
    -- | Activate a reload that strands live grants; see 'reloadStack'.
    schemaReloadForce :: !Bool,
    pool :: !Pool.Pool,
    consistency :: !ConsistencyConfig,
    activeSchema :: !(IORef ActiveSchema),
    -- | Against whatever schema is active right now: for the maintenance loop, the
    --     readiness check and reload, none of which mints a token a client will hold.
    runNow :: !Runner,
    -- | The pool answers, retried once; see 'buildStack'.
    checkReady :: !(IO Bool),
    livenessProbe :: !ProbeCheck,
    readinessProbe :: !ProbeCheck,
    -- | The servant application wrapped in every middleware that sits inside
    --     authentication: rate limiter, request id, request logger, metrics recorder and
    --     metrics route. It expects the verified caller in @X-En-Caller@.
    application :: !Wai.Application
  }
  deriving stock (Generic)

-- | Log a line as this stack.
stackSay :: TenantStack -> Text -> IO ()
stackSay stack message = toStdout ((stack ^. #logPrefix) <> message)

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
  deriving stock (Generic)

-- | A store that is open and identified, but not yet served.
data OpenedStore = OpenedStore
  { loadedSchema :: !LoadedSchema,
    pool :: !Pool.Pool,
    consistency :: !ConsistencyConfig
  }
  deriving stock (Generic)

-- | Validate the schema, open the pool, and resolve this database's identity --
-- everything the server and the subcommands need and none of them should do differently.
--
-- Diagnostics travel through @say@ rather than 'Text.putStrLn' so that a command
-- whose stdout is a data stream can route them to stderr. Every failure exits 1 before
-- anything is served. The caller releases the pool.
openStore :: (Text.Text -> IO ()) -> StoreConfig -> IO OpenedStore
openStore say storeConfig = do
  (schemaSource, sourceText, rawSchema) <- loadSchema (storeConfig ^. #schemaPath)
  validSchema <-
    either (configFailure . ("Invalid schema: " <>) . Text.pack . show) pure (validateSchema rawSchema)
  let loadedSchema =
        LoadedSchema {source = sourceText, origin = schemaOrigin schemaSource, validSchema}
  say (describeSchemaSource schemaSource)
  say ("Schema hash: " <> renderSchemaHash (schemaHash validSchema))
  let poolConfig = (storeConfig ^. #pool)
  pool <-
    Pool.acquire $
      Pool.Config.settings
        [ Pool.Config.size (poolConfig ^. #size),
          Pool.Config.acquisitionTimeout (millisToDiffTime (poolConfig ^. #acquisitionTimeoutMs)),
          Pool.Config.idlenessTimeout (millisToDiffTime (poolConfig ^. #idlenessTimeoutMs)),
          Pool.Config.agingTimeout (millisToDiffTime (poolConfig ^. #maxLifetimeMs)),
          Pool.Config.staticConnectionSettings
            (Settings.connectionString (storeConfig ^. #databaseUrl))
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
  validateGcWindow runDbSession (storeConfig ^. #gcWindow) >>= either configFailure pure
  datastoreIdText <- resolveDatastoreId runDbSession
  say ("Datastore id: " <> datastoreIdText)
  let consistency =
        ConsistencyConfig
          { datastoreId = DatastoreId datastoreIdText,
            schemaHash = schemaHash validSchema,
            gcWindow = (storeConfig ^. #gcWindow)
          }
  pure OpenedStore {loadedSchema, pool, consistency}

-- | Open one datastore and build everything a request against it needs.
--
-- The request logger is passed in rather than built here: its lock serializes writes to
-- the one stdout every stack shares. The rate limiter and the metrics registry are built
-- here, so every stack has its own buckets and its own counters.
buildStack :: SharedConfig -> Wai.Middleware -> Maybe TenantName -> TenantConfig -> IO TenantStack
buildStack shared requestLogger name tenantConfig = do
  let logPrefix = maybe "" (\(TenantName tenant) -> "[tenant " <> tenant <> "] ") name
      storeConfig = tenantConfig ^. #store
  OpenedStore {loadedSchema, pool, consistency = config} <-
    openStore (toStdout . (logPrefix <>)) storeConfig
  loadedAt <- getCurrentTime
  activeSchemaRef <-
    newIORef
      ActiveSchema
        { graph = compile (loadedSchema ^. #validSchema),
          source = (loadedSchema ^. #source),
          origin = (loadedSchema ^. #origin),
          loadedAt
        }
  let optimizedRevisionTtlMs = (shared ^. #optimizedRevisionTtlMs)
      tupleReadMaxEntries = (shared ^. #tupleReadMaxEntries)
      decisionMaxEntries = (shared ^. #decisionMaxEntries)
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
          { cacheDatastoreId = (config ^. #datastoreId),
            cacheDecisions = decisionCache
          }
      {- Both store interpreters are built from the snapshot the caller holds, so the
      schema hash they stamp into every minted token -- and check on every presented
      one -- is the hash of the very graph the handler evaluated against. A reload that
      lands between a handler's snapshot read and its store call cannot tear them apart,
      because there is only one snapshot and the handler is holding it. -}
      runAppIO :: ActiveSchema -> Eff AppEffects a -> IO (Either EnError a)
      runAppIO active action =
        let activeConfig = config & #schemaHash .~ (active ^. #graph . #hash)
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
        | (optimizedRevisionConfig ^. #enabled) =
            runTupleStorePostgresWithOptimizedRevisionCacheHandle activeConfig cache action
        | otherwise =
            runTupleStorePostgres activeConfig action
      tupleReadLayer ::
        Cache TupleReadKey TuplePage ->
        Eff '[TupleStore, Error EnError, Database, IOE] a ->
        Eff '[TupleStore, Error EnError, Database, IOE] a
      tupleReadLayer cache action
        | (tupleReadConfig ^. #enabled) = cachedTupleStore cache action
        | otherwise = action
      -- The engine's static bounds are applied here, once, so no handler and no
      -- request can choose them. See "En.Budget".
      budget = (shared ^. #budget)
      checkOperation graph' consistency context subject relation object
        | (decisionConfig ^. #enabled) =
            checkCachedWithBudget budget checkCacheEnv graph' consistency context subject relation object
        | otherwise =
            checkWithBudget budget graph' consistency context subject relation object
      lookupWithDeadlineOperation deadline graph' consistency request
        | (decisionConfig ^. #enabled) =
            Lookup.lookupWithDeadlineCachedAndBudget budget checkCacheEnv deadline graph' consistency request
        | otherwise =
            Lookup.lookupWithDeadlineAndBudget budget deadline graph' consistency request
      lookupSubjectsWithDeadlineOperation deadline graph' consistency request
        | (decisionConfig ^. #enabled) =
            LookupSubjects.lookupSubjectsWithDeadlineCachedAndBudget budget checkCacheEnv deadline graph' consistency request
        | otherwise =
            LookupSubjects.lookupSubjectsWithDeadlineAndBudget budget deadline graph' consistency request
      serverEnv =
        Env
          { runPorts = runAppIO,
            readActiveSchema = readIORef activeSchemaRef,
            checkOperation,
            grantGenerationOperation = GrantGeneration.grantGenerationForToken,
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
            maxBatchSize = (shared ^. #maxBatchSize),
            deadlineDefaultMillis = (shared ^. #deadlineDefaultMillis),
            deadlineMaxMillis = (shared ^. #deadlineMaxMillis),
            -- The active schema hash a grant embeds is not captured here: the handler
            -- reads it from the request's `ActiveSchema` snapshot, so a SIGHUP reload
            -- cannot mint a grant under a hash its check did not evaluate under.
            mint = mintEnvFromConfig <$> (tenantConfig ^. #biscuit)
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
  rateLimit <- rateLimitMiddleware (shared ^. #rateLimit)
  metrics <- newMetrics
  -- Outermost first, continuing the chain `Main` starts with telemetry and
  -- authentication. Authentication remains outside rate limiting so buckets are per
  -- verified caller. Request ids sit inside the limiter, so a throttled request costs no
  -- UUID. The metrics layer wraps the servant application, so probes are counted; it
  -- cannot see the 401/403/429 the outer middlewares short-circuit, which stay
  -- countable at the proxy.
  --
  -- Serves `appWithOpenApi`, not `app`: the former adds GET /v1/openapi.json and the
  -- ErrorFormatters that make body-parse and 404 errors speak the error envelope.
  let application =
        rateLimit
          . requestIdMiddleware
          . requestLogger
          . metricsMiddleware metrics
          . metricsRoute
            metrics
            [ ("tuple_read", cacheStats tupleReadCache),
              ("decision", cacheStats decisionCache)
            ]
          $ appWithOpenApiProbes serverEnv livenessProbe readinessProbe
  pure
    TenantStack
      { name,
        logPrefix,
        store = storeConfig,
        schemaReloadForce = tenantConfig ^. #schemaReloadForce,
        pool,
        consistency = config,
        activeSchema = activeSchemaRef,
        runNow = Runner runAppNow,
        checkReady,
        livenessProbe,
        readinessProbe,
        application
      }

-- | Release the stack's pool. Maintenance threads must already be stopped.
releaseStack :: TenantStack -> IO ()
releaseStack stack = Pool.release (stack ^. #pool)

-- | Build the servant seam's 'MintEnv' from the parsed issuer configuration.
--
-- Only key material and TTL bounds cross over; the schema hash a grant embeds is the
-- request-time snapshot's, read in the handler.
mintEnvFromConfig :: BiscuitConfig -> MintEnv
mintEnvFromConfig cfg =
  MintEnv
    { issuerSecretKey = (cfg ^. #issuerSecretKey),
      issuerKeyId = (cfg ^. #issuerKeyId),
      defaultTtl = fromIntegral (cfg ^. #defaultTtlSeconds),
      maxTtl = fromIntegral (cfg ^. #maxTtlSeconds)
    }

-- | Re-read the stack's schema file and swap its active schema, or refuse and keep serving.
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
reloadStack :: TenantStack -> IO ()
reloadStack stack =
  case (stack ^. #store . #schemaPath) of
    Nothing -> say "SIGHUP received but no EN_SCHEMA_PATH is set; nothing to reload."
    Just path -> reloadFrom path
  where
    say = stackSay stack
    forceVariable = maybe "EN_SCHEMA_RELOAD_FORCE" (\name -> Text.pack (tenantVariable name "SCHEMA_RELOAD_FORCE")) (stack ^. #name)
    activeSchemaRef = stack ^. #activeSchema
    Runner runAppNow = stack ^. #runNow

    reloadFrom path =
      loadCandidateSchema path >>= \case
        Left err -> refuse ("schema reload failed: " <> err)
        Right candidate -> do
          active <- readIORef activeSchemaRef
          let graph = compile (candidate ^. #validSchema)
              oldHash = renderSchemaHash (active ^. #graph . #hash)
              newHash = renderSchemaHash (graph ^. #hash)
          if (graph ^. #hash) == (active ^. #graph . #hash)
            then say ("Schema unchanged (" <> newHash <> "); not reloading.")
            else
              runAppNow (validateCandidate (candidate ^. #validSchema)) >>= \case
                Left err -> refuse ("schema reload failed: could not scan the store: " <> showText err)
                Right report -> activate candidate graph oldHash newHash report

    -- Scanned under whatever schema is active: the pass mints no token and presents none,
    -- so the interpreters' schema hash never enters into it. It reads the head revision and
    -- drains it, and that is all.
    validateCandidate candidate = do
      revision <- TupleStore.headRevision
      validateTuplesAgainstSchema candidate revision

    activate candidate graph oldHash newHash report
      | not (null (report ^. #orphans)) && not (stack ^. #schemaReloadForce) = do
          say ("Schema reload refused: " <> orphanSummary newHash report)
          traverse_ (say . renderTupleOrphan) (report ^. #orphans)
          say ("reload refused; set " <> forceVariable <> "=true to activate anyway.")
      | otherwise = do
          loadedAt <- getCurrentTime
          atomicWriteIORef
            activeSchemaRef
            ActiveSchema
              { graph,
                source = (candidate ^. #source),
                origin = (candidate ^. #origin),
                loadedAt
              }
          if null (report ^. #orphans)
            then pure ()
            else do
              say ("Schema reload FORCED over " <> orphanSummary newHash report)
              traverse_ (say . renderTupleOrphan) (report ^. #orphans)
          say ("Schema reloaded from " <> (candidate ^. #origin))
          say ("Schema hash: " <> newHash <> " (was " <> oldHash <> ")")
          say "WARNING: all consistency tokens minted under the previous schema hash are now invalid."

    orphanSummary newHash report =
      showText (length (report ^. #orphans))
        <> " orphan(s) across "
        <> showText (report ^. #scanned)
        <> " live tuple(s) under candidate "
        <> newHash

    refuse message = do
      toStderr ("en-server: " <> (stack ^. #logPrefix) <> message)
      toStderr ((stack ^. #logPrefix) <> "the previous schema is still serving.")

-- | Read, parse, and validate a candidate schema without exiting, keeping its source text.
--
-- 'loadSchema' cannot be reused for either caller. Every one of its failure paths calls
-- 'configFailure', which exits 1 -- the code @check-schema@ reserves for "the candidate
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

renderSchemaHash :: SchemaHash -> Text.Text
renderSchemaHash (SchemaHash value) =
  value

showText :: (Show a) => a -> Text.Text
showText = Text.pack . show

toStdout :: Text.Text -> IO ()
toStdout = Text.putStrLn

toStderr :: Text.Text -> IO ()
toStderr = Text.hPutStrLn stderr

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
