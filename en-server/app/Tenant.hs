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
    buildRuntime,
    legacyApplication,
    releaseStack,
    reloadStack,
    stackSay,

    -- * Tenant slots: a stack, or the reason there is none
    SlotState (..),
    TenantSlot (..),
    openSlot,
    runSlot,
    slotApplication,
    slotSource,
    slotProbes,
    tenantAvailability,
    releaseSlot,

    -- * Opening a store without serving it
    LoadedSchema (..),
    OpenedStore (..),
    StoreFault (..),
    openStore,
    loadStoreSchema,
    connectStore,
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
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (mapConcurrently)
import Control.Exception (IOException, try)
import Data.Foldable (traverse_)
import Data.Generics.Labels ()
import Data.IORef (IORef, atomicModifyIORef', atomicWriteIORef, newIORef, readIORef)
import Data.Maybe (listToMaybe)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Data.Time (DiffTime)
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID.V4
import Effectful (Eff, IOE, runEff)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import En.Cache (Cache, CacheConfig (..), CacheStats, SubproblemKey, TupleReadKey, cacheStats, newCache)
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
import En.Servant.Problem (problemResponse, specStoreError)
import En.Servant.Seam (ActiveSchema (..), AppEffects, Env (..), MintEnv (..))
import Hasql.Connection.Settings qualified as Settings
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Errors qualified as Hasql
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as Pool.Config
import Hasql.Session (Session)
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Maintenance (runMaintenanceLoop)
import Metrics (Metrics, Source (..), metricsMiddleware, metricsRoute, newMetrics, scrapeRoute)
import Middleware (rateLimitMiddleware)
import Network.Wai qualified as Wai
import Observability (requestIdMiddleware, tenantSpanMiddleware)
import Servant.Health (ProbeCheck, ProbeVerdict (..))
import Servant.Health.Check (boolCheck, newFailureTracker, safeCheck, withProbeTimeout)
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
    -- | The servant application alone. The middleware between it and authentication is
    --     added by 'legacyApplication' in legacy mode and by the tenant's slot in tenant
    --     mode, where it must outlive the stack (see 'openSlot').
    servantApplication :: !Wai.Application,
    -- | The stack's cache counters, read at scrape time.
    caches :: ![(Text, IO CacheStats)]
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

-- | Why a store could not be opened.
data StoreFault
  = -- | The database's state: unreachable, unmigrated, or not the database the operator
    --     pinned. It can change without a restart, so a tenant waits and retries.
    StoreUnavailable !Text.Text
  | -- | The operator's input, such as an invalid GC window. It never fixes itself.
    StoreMisconfigured !Text.Text

renderStoreFault :: StoreFault -> Text.Text
renderStoreFault = \case
  StoreUnavailable message -> message
  StoreMisconfigured message -> message

-- | Validate the schema, open the pool, and resolve this database's identity --
-- everything the server and the subcommands need and none of them should do differently.
--
-- Diagnostics travel through @say@ rather than 'Text.putStrLn' so that a command
-- whose stdout is a data stream can route them to stderr. Every failure exits 1 before
-- anything is served. The caller releases the pool.
openStore :: (Text.Text -> IO ()) -> StoreConfig -> IO OpenedStore
openStore say storeConfig = do
  loadedSchema <- loadStoreSchema say storeConfig
  connectStore say storeConfig Nothing loadedSchema >>= \case
    Left fault -> configFailure (renderStoreFault fault)
    Right (pool, consistency) -> pure OpenedStore {loadedSchema, pool, consistency}

-- | Read and validate the store's schema file. A failure exits 1: the schema is
-- deployment input, and failing the start is what stops a rollout before it replaces a
-- healthy process.
loadStoreSchema :: (Text.Text -> IO ()) -> StoreConfig -> IO LoadedSchema
loadStoreSchema say storeConfig = do
  (schemaSource, sourceText, rawSchema) <- loadSchema (storeConfig ^. #schemaPath)
  validSchema <-
    either (configFailure . ("Invalid schema: " <>) . Text.pack . show) pure (validateSchema rawSchema)
  say (describeSchemaSource schemaSource)
  say ("Schema hash: " <> renderSchemaHash (schemaHash validSchema))
  pure LoadedSchema {source = sourceText, origin = schemaOrigin schemaSource, validSchema}

-- | Open the pool and establish the database's identity, or say why not. On a fault
-- the pool is released.
--
-- With a pin (the variable that set it, and the expected id) the id is only read, never
-- minted: a URL pointed at the wrong database must not stamp an identity into it.
connectStore ::
  (Text.Text -> IO ()) ->
  StoreConfig ->
  Maybe (Text.Text, Text.Text) ->
  LoadedSchema ->
  IO (Either StoreFault (Pool.Pool, ConsistencyConfig))
connectStore say storeConfig pin loadedSchema = do
  let validSchema = loadedSchema ^. #validSchema
      poolConfig = (storeConfig ^. #pool)
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
      fault outcome = Pool.release pool >> pure (Left outcome)
  -- Pool connections are established lazily, so a bad EN_DATABASE_URL would
  -- otherwise surface only on the first request rather than at startup.
  runDbSession (Session.script "SELECT 1") >>= \case
    Left err ->
      fault . StoreUnavailable $
        "Could not reach PostgreSQL through EN_DATABASE_URL. "
          <> err
          <> "\n"
          <> migrationHint
    Right () ->
      -- Only PostgreSQL can adjudicate its own interval grammar, so this waits for a
      -- reachable database -- but it still runs before the port binds.
      validateGcWindow runDbSession (storeConfig ^. #gcWindow) >>= \case
        Left err -> fault (StoreMisconfigured err)
        Right () ->
          identify runDbSession >>= \case
            Left outcome -> fault outcome
            Right datastoreIdText -> do
              say ("Datastore id: " <> datastoreIdText)
              let consistency =
                    ConsistencyConfig
                      { datastoreId = DatastoreId datastoreIdText,
                        schemaHash = schemaHash validSchema,
                        gcWindow = (storeConfig ^. #gcWindow)
                      }
              pure (Right (pool, consistency))
  where
    identify :: (forall a. Session a -> IO (Either Text.Text a)) -> IO (Either StoreFault Text.Text)
    identify runDbSession = case pin of
      Nothing -> resolveDatastoreId runDbSession
      Just (variable, expected) ->
        runDbSession (Session.statement () readDatastoreIdStatement) >>= \case
          Left err -> pure (Left (missingIdentity err))
          Right Nothing ->
            pure . Left . StoreUnavailable $
              "This database has no datastore id yet, and "
                <> variable
                <> " is set, so none is minted. Start the tenant once without the pin, or point it at the database that holds "
                <> expected
                <> "."
          Right (Just actual)
            | actual == expected -> pure (Right actual)
            | otherwise ->
                pure . Left . StoreUnavailable $
                  "This database's datastore id is " <> actual <> ", but " <> variable <> " is " <> expected <> "."

-- | Read the database's identity without minting one.
readDatastoreIdStatement :: Statement.Statement () (Maybe Text.Text)
readDatastoreIdStatement =
  Statement.preparable
    "SELECT datastore_id FROM en_datastore_metadata"
    Encoders.noParams
    (Decoders.rowMaybe (Decoders.column (Decoders.nonNullable Decoders.text)))

missingIdentity :: Text.Text -> StoreFault
missingIdentity err =
  StoreUnavailable $
    "Could not resolve this database's datastore identity: "
      <> err
      <> "\nThis database's migrations are missing or out of date. "
      <> migrationHint

-- | Open one datastore and build everything a request against it needs.
buildStack :: SharedConfig -> Maybe TenantName -> TenantConfig -> IO TenantStack
buildStack shared name tenantConfig = do
  OpenedStore {loadedSchema, pool, consistency} <-
    openStore (toStdout . (prefixFor name <>)) (tenantConfig ^. #store)
  buildRuntime shared name tenantConfig loadedSchema pool consistency

-- | Every middleware between authentication and a servant application, outermost first:
-- rate limiter, request id, the request logger (with whatever identity the caller adds),
-- the metrics recorder, and the metrics route.
--
-- Authentication remains outside rate limiting so buckets are per verified caller.
-- Request ids sit inside the limiter, so a throttled request costs no UUID. The metrics
-- layer is innermost, so it cannot see the 401/403/429 the outer middlewares
-- short-circuit, which stay countable at the proxy.
--
-- The rate limiter is built here, so every caller of this function (one per datastore)
-- has its own buckets.
newServingChain :: SharedConfig -> Wai.Middleware -> Metrics -> Wai.Middleware -> IO Wai.Middleware
newServingChain shared logger metrics route = do
  rateLimit <- rateLimitMiddleware (shared ^. #rateLimit)
  pure (rateLimit . requestIdMiddleware . logger . metricsMiddleware metrics . route)

-- | Legacy mode's application: the one stack's servant application inside the serving
-- chain, with its own metrics registry and a request logger that adds no identity. This
-- is the request path en-server has always had.
legacyApplication :: SharedConfig -> Wai.Middleware -> TenantStack -> IO Wai.Application
legacyApplication shared requestLogger stack = do
  metrics <- newMetrics
  chain <- newServingChain shared requestLogger metrics (metricsRoute metrics (stack ^. #caches))
  pure (chain (stack ^. #servantApplication))

-- | @[tenant NAME] @, or nothing for legacy mode's one stack.
prefixFor :: Maybe TenantName -> Text.Text
prefixFor = maybe "" (\(TenantName tenant) -> "[tenant " <> tenant <> "] ")

-- | Everything a request needs, over a store that is already open and identified.
buildRuntime ::
  SharedConfig ->
  Maybe TenantName ->
  TenantConfig ->
  LoadedSchema ->
  Pool.Pool ->
  ConsistencyConfig ->
  IO TenantStack
buildRuntime shared name tenantConfig loadedSchema pool config = do
  let logPrefix = prefixFor name
      storeConfig = tenantConfig ^. #store
  loadedAt <- getCurrentTime
  activeSchemaRef <-
    newIORef
      ActiveSchema
        { graph = compile (loadedSchema ^. #validSchema),
          validSchema = (loadedSchema ^. #validSchema),
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
        -- Serves `appWithOpenApi`, not `app`: the former adds GET /v1/openapi.json and the
        -- ErrorFormatters that make body-parse and 404 errors speak the error envelope.
        servantApplication = appWithOpenApiProbes serverEnv livenessProbe readinessProbe,
        caches =
          [ ("tuple_read", cacheStats tupleReadCache),
            ("decision", cacheStats decisionCache)
          ]
      }

-- * Tenant slots

-- | A tenant has a stack, or the reason it has none and since when.
data SlotState
  = Available !TenantStack
  | Unavailable !Text.Text !UTCTime

-- | One tenant in tenant mode: its configuration, the schema it was started with, whether
-- its store is open, and what must outlive any one stack -- its rate-limit buckets and
-- metrics registry, held by its serving chain.
data TenantSlot = TenantSlot
  { name :: !TenantName,
    config :: !TenantConfig,
    -- | Read at startup. A tenant that recovers later is served under it; @SIGHUP@ reloads
    --     available tenants only.
    loadedSchema :: !LoadedSchema,
    state :: !(IORef SlotState),
    -- | Whether the tenant's last readiness ping passed. An open store whose database
    --     stopped answering is still 'Available' -- its requests fail with store errors and
    --     it recovers by itself -- so this, not 'state' alone, says whether it can serve.
    serving :: !(IORef Bool),
    metrics :: !Metrics,
    -- | The serving chain around the availability switch; see 'openSlot'.
    application :: !Wai.Application
  }
  deriving stock (Generic)

slotPrefix :: TenantSlot -> Text.Text
slotPrefix slot = prefixFor (Just (slot ^. #name))

slotSay :: TenantSlot -> Text.Text -> IO ()
slotSay slot message = toStdout (slotPrefix slot <> message)

-- | Load the tenant's schema (a failure exits 1) and try to open its store. A store that is
-- unreachable, unmigrated or not the pinned database leaves the tenant unavailable instead
-- of stopping the process; a misconfiguration such as an invalid GC window exits 1.
--
-- The serving chain (rate limiter, request id, tenant span attribute, request logger with
-- the tenant and caller, metrics recorder and route) wraps the availability switch rather
-- than a stack. So an unavailable tenant's 503 is logged and counted under its name, its
-- @GET \/metrics@ still answers, and its buckets and counters survive a recovery, which
-- builds a new stack. The tenant's identity is bound here, once, never looked up per
-- request.
openSlot :: SharedConfig -> (Maybe Text.Text -> Wai.Middleware) -> TenantName -> TenantConfig -> IO TenantSlot
openSlot shared requestLogger name tenantConfig = do
  let prefix = prefixFor (Just name)
      say = toStdout . (prefix <>)
      TenantName tenant = name
  schema <- loadStoreSchema say (tenantConfig ^. #store)
  initial <-
    connectStore say (tenantConfig ^. #store) (pinFor name tenantConfig) schema >>= \case
      Right (pool, consistency) -> Available <$> buildRuntime shared (Just name) tenantConfig schema pool consistency
      Left (StoreMisconfigured message) -> configFailure (prefix <> message)
      Left (StoreUnavailable reason) -> do
        say ("UNAVAILABLE: " <> oneLine reason)
        Unavailable reason <$> getCurrentTime
  state <- newIORef initial
  serving <- newIORef case initial of
    Available _ -> True
    Unavailable {} -> False
  metrics <- newMetrics
  let unserved =
        TenantSlot
          { name,
            config = tenantConfig,
            loadedSchema = schema,
            state,
            serving,
            metrics,
            application = availabilitySwitch state
          }
  chain <-
    newServingChain
      shared
      (tenantSpanMiddleware tenant . requestLogger (Just tenant))
      metrics
      (scrapeRoute [slotSource unserved])
  pure unserved {application = chain (availabilitySwitch state)}

pinFor :: TenantName -> TenantConfig -> Maybe (Text.Text, Text.Text)
pinFor name tenantConfig =
  (Text.pack (tenantVariable name "EXPECTED_DATASTORE_ID"),) <$> (tenantConfig ^. #expectedDatastoreId)

oneLine :: Text.Text -> Text.Text
oneLine = Text.unwords . Text.lines

-- | The tenant's background work, for the life of the server: its maintenance loop when it
-- is available, otherwise retry opening its store (after 5 seconds, then doubling to 60)
-- until it is, then its maintenance loop.
--
-- A recovered store whose datastore id another available tenant already reports stays
-- unavailable: it is the same database reached through a different URL.
runSlot :: SharedConfig -> [TenantSlot] -> TenantSlot -> IO ()
runSlot shared slots slot =
  readIORef (slot ^. #state) >>= \case
    Available stack -> maintain stack
    Unavailable {} -> recover 5 >>= maintain
  where
    maintain stack =
      let Runner runAppNow = stack ^. #runNow
       in runMaintenanceLoop (stack ^. #logPrefix) (shared ^. #maintenance) runAppNow

    recover :: Int -> IO TenantStack
    recover delaySeconds = do
      threadDelay (delaySeconds * 1_000_000)
      let next = recover (min 60 (delaySeconds * 2))
          tenantConfig = slot ^. #config
      connectStore (slotSay slot) (tenantConfig ^. #store) (pinFor (slot ^. #name) tenantConfig) (slot ^. #loadedSchema) >>= \case
        Left fault -> do
          stillUnavailable (renderStoreFault fault)
          next
        Right (pool, consistency) -> do
          clash <- datastoreClash (consistency ^. #datastoreId)
          case clash of
            Just other -> do
              Pool.release pool
              stillUnavailable
                ( "Tenant "
                    <> renderName other
                    <> " already serves this database (datastore id "
                    <> renderDatastoreId (consistency ^. #datastoreId)
                    <> "). Each tenant needs its own database."
                )
              next
            Nothing -> do
              stack <- buildRuntime shared (Just (slot ^. #name)) tenantConfig (slot ^. #loadedSchema) pool consistency
              atomicWriteIORef (slot ^. #serving) True
              atomicWriteIORef (slot ^. #state) (Available stack)
              slotSay slot "AVAILABLE"
              pure stack

    -- Log a reason only when it changes, so a long outage is one line, not one a minute.
    stillUnavailable reason = do
      changed <- atomicModifyIORef' (slot ^. #state) \case
        Unavailable previous since
          | previous == reason -> (Unavailable previous since, False)
          | otherwise -> (Unavailable reason since, True)
        other -> (other, False)
      when changed (slotSay slot ("UNAVAILABLE: " <> oneLine reason))

    datastoreClash datastoreId = do
      others <- traverse (\other -> (other ^. #name,) <$> readIORef (other ^. #state)) (filter ((/= slot ^. #name) . (^. #name)) slots)
      pure (listToMaybe [name | (name, Available stack) <- others, stack ^. #consistency . #datastoreId == datastoreId])

    renderName (TenantName tenant) = tenant
    renderDatastoreId (DatastoreId value) = value

-- | The application paired with a tenant's keys: its serving chain around its stack's
-- servant application, or around the store-unavailable problem a store failure produces.
slotApplication :: TenantSlot -> Wai.Application
slotApplication slot = slot ^. #application

-- | The stack's servant application, or the store-unavailable problem. One read of the
-- slot per request.
availabilitySwitch :: IORef SlotState -> Wai.Application
availabilitySwitch state request respond =
  readIORef state >>= \case
    Available stack -> (stack ^. #servantApplication) request respond
    Unavailable {} -> respond tenantUnavailable

tenantUnavailable :: Wai.Response
tenantUnavailable = problemResponse specStoreError "this tenant's store is unavailable; retry later"

-- | The tenant as a metrics scrape sees it: its registry and caches under its name, and
-- whether it can serve. A tenant whose store is not open has no caches to report.
slotSource :: TenantSlot -> Source
slotSource slot =
  Source
    { tenant = Just tenant,
      metrics = slot ^. #metrics,
      caches =
        readIORef (slot ^. #state) >>= \case
          Available stack -> traverse (\(cache, readStats) -> (cache,) <$> readStats) (stack ^. #caches)
          Unavailable {} -> pure [],
      available = Just (slotServing slot)
    }
  where
    TenantName tenant = slot ^. #name

-- | The store is open and its last readiness ping passed.
slotServing :: TenantSlot -> IO Bool
slotServing slot =
  readIORef (slot ^. #state) >>= \case
    Available _ -> readIORef (slot ^. #serving)
    Unavailable {} -> pure False

-- | Every tenant's name and whether it can serve, in declaration order: its store is open
-- and, as of the last readiness check, its database answers.
tenantAvailability :: [TenantSlot] -> IO [(TenantName, Bool)]
tenantAvailability = traverse \slot -> (slot ^. #name,) <$> slotServing slot

-- | The process's probes in tenant mode.
--
-- Liveness reads every tenant's in-memory state. Readiness pings every tenant's pool (an
-- unavailable tenant fails), tracking each tenant's failure onset separately, and passes
-- while at least one tenant can serve: readiness removes the whole process from traffic,
-- and failing it for one tenant would take every healthy tenant down too. When none can
-- serve it reports the first tenant's failure, named @postgres:\<tenant\>@.
--
-- Each check of an open store also records whether it passed. A change is logged, once:
-- @UNAVAILABLE@ when a serving tenant's database stops answering, @AVAILABLE@ when it
-- answers again. So an outage that begins after startup leaves a named line in the log,
-- and @en_tenant_available@ follows it. (A store that is not open is the worker's to
-- report; see 'runSlot'.)
slotProbes :: [TenantSlot] -> IO (ProbeCheck, ProbeCheck)
slotProbes slots = do
  trackLiveness <- newFailureTracker
  trackers <- traverse (const newFailureTracker) slots
  let responsive = traverse_ (readIORef . (^. #state)) slots >> pure True
      liveness =
        trackLiveness
          ( withProbeTimeout
              2_000_000
              "liveness"
              (safeCheck "liveness" (boolCheck "liveness" responsive))
          )
      tenantCheck track slot =
        let checkName = "postgres:" <> renderTenant (slot ^. #name)
         in track (safeCheck checkName (boolCheck checkName (slotReady slot)))
      checks = zipWith tenantCheck trackers slots
      readiness = do
        verdicts <- mapConcurrently id checks
        pure case filter (/= Healthy) verdicts of
          failed
            | length failed < length verdicts -> Healthy
            | first : _ <- failed -> first
            | otherwise -> Healthy
  pure (liveness, readiness)
  where
    renderTenant (TenantName tenant) = tenant
    slotReady slot =
      readIORef (slot ^. #state) >>= \case
        Available stack -> do
          ready <- stack ^. #checkReady
          recordServing slot ready
          pure ready
        Unavailable {} -> pure False

-- | Record a readiness result for an open store, logging a change.
recordServing :: TenantSlot -> Bool -> IO ()
recordServing slot ready = do
  changed <- atomicModifyIORef' (slot ^. #serving) \previous -> (ready, previous /= ready)
  when changed $
    slotSay slot $
      if ready
        then "AVAILABLE"
        else "UNAVAILABLE: its database did not answer the readiness check; requests answer 503 store_error until it does."

-- | Release the slot's pool, if it has one.
releaseSlot :: TenantSlot -> IO ()
releaseSlot slot =
  readIORef (slot ^. #state) >>= \case
    Available stack -> releaseStack stack
    Unavailable {} -> pure ()

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
                validSchema = (candidate ^. #validSchema),
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
resolveDatastoreId :: (forall a. Session a -> IO (Either Text.Text a)) -> IO (Either StoreFault Text.Text)
resolveDatastoreId runDbSession = do
  candidate <- UUID.toText <$> UUID.V4.nextRandom
  runDbSession (resolveDatastoreIdSession candidate) >>= \case
    Right value -> pure (Right value)
    Left err -> pure (Left (missingIdentity err))

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
