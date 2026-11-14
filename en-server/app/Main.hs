module Main (main) where

import Config (BiscuitConfig (..), ServerConfig (..), SharedConfig (..), Tenancy (..), TenantConfig (..), TenantName (..), TlsConfig (..), loadServerConfig, loadStoreConfig, loadTenantStoreConfig, parseTenantNames, renderTenantName)
import Control.Concurrent.Async (withAsync)
import Control.Concurrent.MVar (newMVar, withMVar)
import Control.Exception (SomeException, bracket, try)
import Control.Monad (foldM)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as LazyByteString
import Data.ByteString.Lazy.Char8 qualified as LazyChar8
import Data.Char (isSpace)
import Data.Foldable (for_, traverse_)
import Data.Generics.Labels ()
import Data.IORef (readIORef)
import Data.List (sortOn)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Data.Traversable (for)
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Error.Static (Error, runErrorNoCallStack)
import En.Biscuit.Keys (IssuerKeyId (..))
import En.Effect.TupleStore (PageState (..), StoreCursor, TuplePage (..), TupleStore)
import En.Effect.TupleStore qualified as TupleStore
import En.Error (EnError)
import En.Postgres.Database (Database, runDatabasePool)
import En.Postgres.Revision (ConsistencyConfig (..))
import En.Postgres.TupleStore (runTupleStorePostgres)
import En.Prelude
import En.Revision (ConsistencyToken (..), Revision (..))
import En.Schema (schemaHash)
import En.SchemaCheck (checkTupleAgainstSchema, renderTupleOrphan, renderWriteRefusal, validateTuplesAgainstSchema)
import En.Servant.API (tupleFromWire, tupleToWire)
import En.Servant.OpenApi (probesApplication, servedProxy)
import En.Tuple (Tuple)
import Hasql.Pool qualified as Pool
import Maintenance (describeMaintenance, runMaintenanceLoop)
import Metrics (scrapeResponse)
import Middleware (ApiKey (..), AuthConfig (..), TenantRoute (..), authMiddleware, describeRateLimit, scrapeOnly, tenantAuthMiddleware)
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp qualified as Warp
import Network.Wai.Handler.WarpTLS qualified as WarpTLS
import Observability (newRequestLogger)
import OpenTelemetry.Instrumentation.Servant (openTelemetryServantMiddleware)
import OpenTelemetry.Instrumentation.Servant.Internal (HasEndpoint (..))
import Relay.Pagination.Servant (RelayPage)
import Servant.API qualified as Servant
import System.Environment (getArgs, lookupEnv)
import System.Exit (ExitCode (ExitFailure), exitSuccess, exitWith)
import System.IO (BufferMode (BlockBuffering, LineBuffering), hSetBuffering, stderr, stdout)
import System.Posix.Signals (Handler (Catch), installHandler, sigHUP, sigINT, sigTERM)
import Telemetry (withTelemetry)
import Tenant
  ( LoadedSchema (..),
    Runner (..),
    SlotState (..),
    TenantSlot (..),
    TenantStack (..),
    buildStack,
    configFailure,
    legacyApplication,
    loadCandidateSchema,
    openSlot,
    openStore,
    releaseSlot,
    releaseStack,
    reloadStack,
    renderSchemaHash,
    runSlot,
    showText,
    slotApplication,
    slotProbes,
    slotSource,
    toStderr,
    toStdout,
  )
import Text.Read (readMaybe)

-- RelayPage only parses query parameters before delegating to the terminal route, so
-- OpenTelemetry discovers the same method and path as it does without the combinator.
instance (HasEndpoint sub) => HasEndpoint (RelayPage defaultSize maxSize Servant.:> sub) where
  getEndpoint _ = getEndpoint (Proxy @sub)

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
  | Import (Maybe TenantName) FilePath Int
  | Export (Maybe TenantName)
  | CheckSchema (Maybe TenantName) FilePath

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
      runServe serverConfig
    -- A subcommand's stdout carries data -- the export stream, the import's
    -- token line -- so every diagnostic the shared prologue emits goes to stderr.
    Just (Import tenant path batchSize) -> withSubcommandStore tenant (runImport path batchSize)
    Just (Export tenant) -> withSubcommandStore tenant runExport
    -- The candidate is read and validated before the store config is even loaded, so a
    -- typo in a schema file costs no database round trip and no misleading "serving the
    -- built-in demo schema" warning from a command that serves nothing.
    Just (CheckSchema tenant path) -> do
      candidate <- loadCandidateSchema path >>= either candidateFailure pure
      withSubcommandStore tenant (runCheckSchema candidate)

-- | The shared prologue of the bulk subcommands.
--
-- Reads 'loadStoreConfig' rather than 'loadServerConfig': a command that binds no
-- port has no API keys, rate limit, or TLS material to configure, and
-- 'loadServerConfig' fails closed without them -- correctly, for a server.
--
-- A subcommand acts on one datastore. In tenant mode @--tenant NAME@ chooses it, and the
-- command reads only that tenant's store variables. A missing, unknown or unexpected
-- @--tenant@ exits 2, like any other unusable command line.
withSubcommandStore :: Maybe TenantName -> (LoadedSchema -> Pool.Pool -> ConsistencyConfig -> IO ()) -> IO ()
withSubcommandStore tenant action = do
  tenants <- lookupEnv "EN_TENANTS"
  (storeConfig, say) <- case (tenants, tenant) of
    (Nothing, Nothing) -> do
      (storeConfig, warnings) <- loadStoreConfig >>= either configFailure pure
      traverse_ toStderr warnings
      pure (storeConfig, toStderr)
    (Just declared, Nothing) ->
      candidateFailure
        ( "EN_TENANTS is set; choose a tenant with --tenant ("
            <> either (const (Text.pack declared)) (Text.intercalate ", " . map renderTenantName . NonEmpty.toList) (parseTenantNames declared)
            <> ")"
        )
    (_, Just name) -> do
      storeConfig <- loadTenantStoreConfig name >>= either candidateFailure pure
      pure (storeConfig, toStderr . (("[tenant " <> renderTenantName name <> "] ") <>))
  bracket (openStore say storeConfig) (Pool.release . (^. #pool)) \opened ->
    action (opened ^. #loadedSchema) (opened ^. #pool) (opened ^. #consistency)

parseCommand :: [String] -> Maybe Command
parseCommand arguments = do
  (tenant, rest) <- extractTenant arguments
  case rest of
    [] | isNothing tenant -> Just Serve
    ["export"] -> Just (Export tenant)
    ["check-schema", path] -> Just (CheckSchema tenant path)
    ("import" : options) -> (\build -> build tenant) <$> parseImport Nothing defaultBatchSize options
    _ -> Nothing
  where
    -- @--tenant NAME@ may appear anywhere after the subcommand, at most once.
    extractTenant = \case
      [] -> Just (Nothing, [])
      ("--tenant" : name : rest) -> do
        (again, remaining) <- extractTenant rest
        guard (isNothing again)
        Just (Just (TenantName (Text.pack name)), remaining)
      ["--tenant"] -> Nothing
      (other : rest) -> fmap (other :) <$> extractTenant rest

    parseImport path batchSize = \case
      [] -> (\file tenant -> Import tenant file batchSize) <$> path
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
      "  en-server import --file PATH [--batch-size N] [--tenant NAME]  import newline-delimited-JSON tuples",
      "  en-server export [--tenant NAME]                               write every live tuple as newline-delimited JSON",
      "  en-server check-schema [--tenant NAME] PATH                    report which live tuples PATH would strand",
      "",
      "All four read EN_DATABASE_URL and the optional EN_SCHEMA_PATH. With EN_TENANTS set,",
      "the subcommands require --tenant NAME and read that tenant's EN_TENANT_<NAME>_* store.",
      "check-schema exits 0 when the candidate strands nothing, 1 when it strands grants,",
      "and 2 when the candidate itself cannot be read, parsed, or validated."
    ]
  exitWith (ExitFailure 2)

-- | Build the stack, start telemetry, and serve until SIGTERM or SIGINT.
--
-- Without @EN_TENANTS@ there is one implicit stack, and the request path is exactly the
-- one en-server has always had: telemetry, then 'authMiddleware' over the configured keys,
-- then the stack's own application. No tenant table is consulted.
runServe :: ServerConfig -> IO ()
runServe serverConfig = do
  let shared = serverConfig ^. #shared
  -- One logger for the process: its lock serializes writes to the one stdout.
  requestLogger <- newRequestLogger
  case serverConfig ^. #tenancy of
    SingleStore tenantConfig ->
      bracket (buildStack shared Nothing tenantConfig) releaseStack \stack ->
        withTelemetry (shared ^. #telemetry) \(tracerProvider, otelMiddleware) -> do
          application <- legacyApplication shared (requestLogger Nothing) stack
          printServingLines shared stack (tenantConfig ^. #biscuit)
          installReloadHandler [stack]
          let servantTelemetryMiddleware =
                maybe id (\provider -> openTelemetryServantMiddleware provider servedProxy) tracerProvider
              -- Outermost first. The WAI telemetry layer creates and attaches the server
              -- span; the Servant layer directly inside it annotates that span with the
              -- matched route. Authentication remains outside the stack's rate limiter so
              -- buckets are per verified caller; the request logger inside the stack is
              -- inside both telemetry layers and can therefore correlate its line with the
              -- server span.
              wrappedApp =
                otelMiddleware
                  . servantTelemetryMiddleware
                  . authMiddleware (tenantConfig ^. #auth)
                  $ application
          withMaintenance shared [stack] $
            serve (shared ^. #tls) (shared ^. #port) wrappedApp
    Tenants tenants metricsKeys ->
      withSlots shared requestLogger (NonEmpty.toList tenants) \slots -> do
        rejectSharedDatastores slots
        withTelemetry (shared ^. #telemetry) \(tracerProvider, otelMiddleware) -> do
          printTenantServingLines shared slots metricsKeys
          installSlotReloadHandler slots
          (livenessProbe, readinessProbe) <- slotProbes slots
          let servantTelemetryMiddleware =
                maybe id (\provider -> openTelemetryServantMiddleware provider servedProxy) tracerProvider
              -- Every configured key, paired with the application of its tenant's slot. The
              -- key that authenticates a request is the only thing that selects a tenant.
              --
              -- An operator's scrape key is paired with every tenant's metrics, rendered
              -- together, and may call nothing else.
              operatorScrape _ respond = scrapeResponse (map slotSource slots) >>= respond
              routes =
                [ TenantRoute {routeKey = key, routeApplication = slotApplication slot}
                | slot <- slots,
                  AuthKeys keys <- [slot ^. #config . #auth],
                  key <- keys
                ]
                  <> [TenantRoute {routeKey = key, routeApplication = scrapeOnly operatorScrape} | key <- metricsKeys]
              wrappedApp =
                otelMiddleware
                  . servantTelemetryMiddleware
                  $ tenantAuthMiddleware (probesApplication livenessProbe readinessProbe) routes
          withSlotWorkers shared slots $
            serve (shared ^. #tls) (shared ^. #port) wrappedApp

-- | Open one slot per tenant, in declaration order, and release every pool afterwards.
--
-- A tenant whose schema file is unusable, or whose store is misconfigured, exits 1 naming
-- the tenant. A tenant whose store is unreachable, unmigrated or not the pinned database
-- starts unavailable; its worker ('runSlot') keeps trying.
withSlots ::
  SharedConfig ->
  (Maybe Text.Text -> Wai.Middleware) ->
  [(TenantName, TenantConfig)] ->
  ([TenantSlot] -> IO a) ->
  IO a
withSlots shared requestLogger tenants action =
  foldr
    ( \(name, config) inner opened ->
        bracket (openSlot shared requestLogger name config) releaseSlot \slot ->
          inner (opened <> [slot])
    )
    action
    tenants
    []

-- | Two tenants whose URLs differ but reach one database would share tuples, tokens and
-- garbage collection; the datastore id is what tells. Checked among the tenants available
-- at startup; a tenant that recovers later is checked by its worker.
rejectSharedDatastores :: [TenantSlot] -> IO ()
rejectSharedDatastores slots = do
  available <- fmap concat . for slots $ \slot ->
    readIORef (slot ^. #state) <&> \case
      Available stack -> [(stack ^. #consistency . #datastoreId, slot ^. #name)]
      Unavailable {} -> []
  case adjacentClashes (sortOn fst available) of
    [] -> pure ()
    (a, b) : _ ->
      configFailure $
        "Tenants "
          <> renderTenantName a
          <> " and "
          <> renderTenantName b
          <> " reach the same database (one datastore id through different URLs). Each tenant needs its own database."
  where
    adjacentClashes = \case
      (idA, a) : rest@((idB, b) : _)
        | idA == idB -> (a, b) : adjacentClashes rest
        | otherwise -> adjacentClashes rest
      _ -> []

-- | Run each slot's worker beside the action: maintenance for an available tenant, recovery
-- then maintenance for an unavailable one. Cancelled when `serve` returns.
withSlotWorkers :: SharedConfig -> [TenantSlot] -> IO () -> IO ()
withSlotWorkers shared slots action =
  foldr
    (\slot inner -> withAsync (runSlot shared slots slot) \_worker -> inner)
    action
    slots

-- | 'installReloadHandler' for tenant mode: an unavailable tenant is skipped with a line.
installSlotReloadHandler :: [TenantSlot] -> IO ()
installSlotReloadHandler slots = do
  reloadGuard <- newMVar ()
  let reloadSlot slot =
        readIORef (slot ^. #state) >>= \case
          Available stack -> reloadContained stack
          Unavailable {} -> toStdout ("[tenant " <> renderTenantName (slot ^. #name) <> "] SIGHUP: unavailable, not reloading.")
  _ <-
    installHandler
      sigHUP
      (Catch (withMVar reloadGuard \() -> traverse_ reloadSlot slots))
      Nothing
  pure ()

-- | Run each stack's maintenance loop beside the action.
--
-- `serve` returns when SIGTERM drains the server, at which point `withAsync` cancels the
-- maintenance threads and the caller's `bracket` releases the pools. Every maintenance
-- batch is its own committed transaction, so cancelling mid-pass loses only the batch in
-- flight; the next start resumes from what was committed.
withMaintenance :: SharedConfig -> [TenantStack] -> IO () -> IO ()
withMaintenance shared stacks action =
  foldr
    ( \stack inner ->
        let Runner runAppNow = stack ^. #runNow
         in withAsync (runMaintenanceLoop (stack ^. #logPrefix) (shared ^. #maintenance) runAppNow) \_maintenance -> inner
    )
    action
    stacks

-- | Reload every stack on @SIGHUP@.
--
-- One writer, serialized. Two SIGHUPs in flight would otherwise race to
-- `atomicWriteIORef`, and the loser's orphan report would describe a schema that is
-- not the one now serving.
--
-- Each stack is reloaded on its own: a stack whose reload throws is logged, and the next
-- stack is still reloaded. ('reloadStack' already turns every expected failure into a
-- refusal; this catches the unexpected.)
installReloadHandler :: [TenantStack] -> IO ()
installReloadHandler stacks = do
  reloadGuard <- newMVar ()
  _ <-
    installHandler
      sigHUP
      (Catch (withMVar reloadGuard \() -> traverse_ reloadContained stacks))
      Nothing
  pure ()

-- | Tenant mode's startup lines: the process-wide settings once, then each tenant's.
printTenantServingLines :: SharedConfig -> [TenantSlot] -> [ApiKey] -> IO ()
printTenantServingLines shared slots metricsKeys = do
  Text.putStrLn ("en-server listening on :" <> Text.pack (show (shared ^. #port)))
  Text.putStrLn ("Tenants: " <> Text.intercalate ", " [renderTenantName (slot ^. #name) | slot <- slots])
  Text.putStrLn
    ( "Metrics scrape keys (every tenant, GET /metrics only): "
        <> if null metricsKeys then "none" else Text.intercalate ", " [key ^. #keyName | key <- metricsKeys]
    )
  Text.putStrLn ("Optimized revision cache (per tenant): " <> describeMillisCache (shared ^. #optimizedRevisionTtlMs))
  Text.putStrLn ("Tuple-read cache (per tenant): " <> describeEntryCache (shared ^. #tupleReadMaxEntries))
  Text.putStrLn ("Decision cache (per tenant): " <> describeEntryCache (shared ^. #decisionMaxEntries))
  Text.putStrLn ("Rate limit (per tenant and caller): " <> describeRateLimit (shared ^. #rateLimit))
  Text.putStrLn ("Background maintenance (per tenant): " <> describeMaintenance (shared ^. #maintenance))
  Text.putStrLn
    ( "Lookup deadline: defaultMs="
        <> Text.pack (show (shared ^. #deadlineDefaultMillis))
        <> ", maxMs="
        <> Text.pack (show (shared ^. #deadlineMaxMillis))
        <> "; max batch size: "
        <> Text.pack (show (shared ^. #maxBatchSize))
    )
  for_ slots \slot -> do
    let config = slot ^. #config
        say = Text.putStrLn . (("[tenant " <> renderTenantName (slot ^. #name) <> "] ") <>)
        poolConfig = config ^. #store . #pool
    say
      ( "Connection pool: size="
          <> Text.pack (show (poolConfig ^. #size))
          <> ", acquisitionTimeoutMs="
          <> Text.pack (show (poolConfig ^. #acquisitionTimeoutMs))
          <> ", idlenessTimeoutMs="
          <> Text.pack (show (poolConfig ^. #idlenessTimeoutMs))
          <> ", maxLifetimeMs="
          <> Text.pack (show (poolConfig ^. #maxLifetimeMs))
      )
    say ("API keys: " <> describeKeys (config ^. #auth))
    say ("Biscuit grant minting: " <> describeMinting (config ^. #biscuit))
    say ("Schema reload: SIGHUP" <> describeReloadSource (config ^. #store . #schemaPath) (config ^. #schemaReloadForce))
    traverse_ (\expected -> say ("Expected datastore id: " <> expected)) (config ^. #expectedDatastoreId)
  where
    describeKeys = \case
      AuthDisabled -> "none"
      AuthKeys keys -> Text.intercalate ", " [key ^. #keyName | key <- keys]

-- | The startup lines that describe what is being served.
printServingLines :: SharedConfig -> TenantStack -> Maybe BiscuitConfig -> IO ()
printServingLines shared stack biscuit = do
  let poolConfig = (stack ^. #store . #pool)
  Text.putStrLn ("en-server listening on :" <> Text.pack (show (shared ^. #port)))
  Text.putStrLn
    ( "Connection pool: size="
        <> Text.pack (show (poolConfig ^. #size))
        <> ", acquisitionTimeoutMs="
        <> Text.pack (show (poolConfig ^. #acquisitionTimeoutMs))
        <> ", idlenessTimeoutMs="
        <> Text.pack (show (poolConfig ^. #idlenessTimeoutMs))
        <> ", maxLifetimeMs="
        <> Text.pack (show (poolConfig ^. #maxLifetimeMs))
    )
  Text.putStrLn ("Optimized revision cache: " <> describeMillisCache (shared ^. #optimizedRevisionTtlMs))
  Text.putStrLn ("Tuple-read cache: " <> describeEntryCache (shared ^. #tupleReadMaxEntries))
  Text.putStrLn ("Decision cache: " <> describeEntryCache (shared ^. #decisionMaxEntries))
  Text.putStrLn ("Rate limit: " <> describeRateLimit (shared ^. #rateLimit))
  Text.putStrLn ("Biscuit grant minting: " <> describeMinting biscuit)
  Text.putStrLn ("Background maintenance: " <> describeMaintenance (shared ^. #maintenance))
  Text.putStrLn
    ( "Lookup deadline: defaultMs="
        <> Text.pack (show (shared ^. #deadlineDefaultMillis))
        <> ", maxMs="
        <> Text.pack (show (shared ^. #deadlineMaxMillis))
        <> "; max batch size: "
        <> Text.pack (show (shared ^. #maxBatchSize))
    )
  Text.putStrLn ("Schema reload: SIGHUP" <> describeReloadSource (stack ^. #store . #schemaPath) (shared ^. #schemaReloadForce))

-- | The @Biscuit grant minting:@ startup line.
--
-- Logs the key id and TTL bounds so an operator can confirm which issuer is active,
-- but never the secret key material.
describeMinting :: Maybe BiscuitConfig -> Text.Text
describeMinting = \case
  Nothing -> "disabled"
  Just cfg ->
    let IssuerKeyId keyId = (cfg ^. #issuerKeyId)
     in "enabled (key id "
          <> showText keyId
          <> ", defaultTtl="
          <> showText (cfg ^. #defaultTtlSeconds)
          <> "s, maxTtl="
          <> showText (cfg ^. #maxTtlSeconds)
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
--
-- A line whose tuple the loaded schema cannot interpret is refused the same way, with the
-- same rule an HTTP write applies ('En.SchemaCheck.checkTupleAgainstSchema'): every line of a
-- batch is decoded and checked before the batch is written, so the refused line's batch is
-- not stored.
runImport :: FilePath -> Int -> LoadedSchema -> Pool.Pool -> ConsistencyConfig -> IO ()
runImport path batchSize loadedSchema pool config = do
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
        Right wire -> do
          tuple <- either (lineFailure lineNumber) pure (tupleFromWire wire)
          case checkTupleAgainstSchema (loadedSchema ^. #validSchema) tuple of
            Nothing -> pure tuple
            Just orphan -> lineFailure lineNumber (renderWriteRefusal orphan)

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
    liftIO (toStderr ("exporting at revision " <> (revision ^. #revisionEncoding)))
    drainFrom revision Nothing 0
  exported <- either (storeFailure "export") pure outcome
  toStderr ("exported " <> showText exported <> " tuples")
  where
    drainFrom :: (TupleStore :> es, IOE :> es) => Revision -> Maybe StoreCursor -> Int -> Eff es Int
    drainFrom revision cursor exported = do
      TuplePage {rows, state} <- TupleStore.readAllTuples revision exportPageSize cursor
      liftIO (traverse_ (LazyChar8.putStrLn . Aeson.encode . tupleToWire . (^. #tuple)) rows)
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
  let candidateHash = renderSchemaHash (schemaHash (candidate ^. #validSchema))
  outcome <- runStoreIO pool config do
    revision <- TupleStore.headRevision
    liftIO (toStderr ("checking at revision " <> (revision ^. #revisionEncoding)))
    validateTuplesAgainstSchema (candidate ^. #validSchema) revision
  report <- either (storeFailure "check-schema") pure outcome
  traverse_ (Text.putStrLn . renderTupleOrphan) (report ^. #orphans)
  let orphanCount = length (report ^. #orphans)
      summary =
        showText orphanCount
          <> " orphan(s) across "
          <> showText (report ^. #scanned)
          <> " live tuple(s); candidate schema "
          <> candidateHash
  if orphanCount == 0
    then do
      Text.putStrLn (summary <> " fits them all.")
      exitSuccess
    else do
      Text.putStrLn (summary <> " would strand them.")
      exitWith (ExitFailure 1)

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

-- | 'reloadStack', with any unexpected exception logged instead of escaping the handler.
reloadContained :: TenantStack -> IO ()
reloadContained stack =
  try @SomeException (reloadStack stack) >>= \case
    Right () -> pure ()
    Left err -> toStderr ("en-server: " <> (stack ^. #logPrefix) <> "schema reload failed unexpectedly: " <> showText err)

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
      Text.putStrLn ("Serving TLS directly (EN_TLS_CERT_FILE=" <> Text.pack (tls ^. #certFile) <> ")")
      WarpTLS.runTLS
        (WarpTLS.tlsSettings (tls ^. #certFile) (tls ^. #keyFile))
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

describeMillisCache :: Int -> Text.Text
describeMillisCache ttlMs
  | ttlMs <= 0 = "disabled"
  | otherwise = "enabled, ttlMs=" <> Text.pack (show ttlMs)

describeEntryCache :: Int -> Text.Text
describeEntryCache maxEntries
  | maxEntries <= 0 = "disabled"
  | otherwise = "enabled, maxEntries=" <> Text.pack (show maxEntries)
