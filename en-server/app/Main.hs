module Main (main) where

import Config (BiscuitConfig (..), ServerConfig (..), SharedConfig (..), Tenancy (..), TlsConfig (..), loadServerConfig, loadStoreConfig)
import Control.Concurrent.Async (withAsync)
import Control.Concurrent.MVar (newMVar, withMVar)
import Control.Exception (bracket)
import Control.Monad (foldM)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as LazyByteString
import Data.ByteString.Lazy.Char8 qualified as LazyChar8
import Data.Char (isSpace)
import Data.Foldable (traverse_)
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
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
import En.SchemaCheck (renderTupleOrphan, validateTuplesAgainstSchema)
import En.Servant.API (tupleFromWire, tupleToWire)
import En.Servant.OpenApi (servedProxy)
import En.Tuple (Tuple)
import Hasql.Pool qualified as Pool
import Maintenance (describeMaintenance, runMaintenanceLoop)
import Middleware (authMiddleware, describeRateLimit)
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp qualified as Warp
import Network.Wai.Handler.WarpTLS qualified as WarpTLS
import Observability (newRequestLogger)
import OpenTelemetry.Instrumentation.Servant (openTelemetryServantMiddleware)
import OpenTelemetry.Instrumentation.Servant.Internal (HasEndpoint (..))
import Relay.Pagination.Servant (RelayPage)
import Servant.API qualified as Servant
import System.Environment (getArgs)
import System.Exit (ExitCode (ExitFailure), exitSuccess, exitWith)
import System.IO (BufferMode (BlockBuffering, LineBuffering), hSetBuffering, stderr, stdout)
import System.Posix.Signals (Handler (Catch), installHandler, sigHUP, sigINT, sigTERM)
import Telemetry (withTelemetry)
import Tenant
  ( LoadedSchema (..),
    Runner (..),
    TenantStack (..),
    buildStack,
    configFailure,
    loadCandidateSchema,
    openStore,
    releaseStack,
    reloadStack,
    renderSchemaHash,
    showText,
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
      runServe serverConfig
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

-- | The shared prologue of the bulk subcommands.
--
-- Reads 'loadStoreConfig' rather than 'loadServerConfig': a command that binds no
-- port has no API keys, rate limit, or TLS material to configure, and
-- 'loadServerConfig' fails closed without them -- correctly, for a server.
withSubcommandStore :: (LoadedSchema -> Pool.Pool -> ConsistencyConfig -> IO ()) -> IO ()
withSubcommandStore action = do
  (storeConfig, warnings) <- loadStoreConfig >>= either configFailure pure
  traverse_ toStderr warnings
  bracket (openStore toStderr storeConfig) (Pool.release . (^. #pool)) \opened ->
    action (opened ^. #loadedSchema) (opened ^. #pool) (opened ^. #consistency)

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
      bracket (buildStack shared requestLogger Nothing tenantConfig) releaseStack \stack ->
        withTelemetry (shared ^. #telemetry) \(tracerProvider, otelMiddleware) -> do
          printServingLines shared stack (tenantConfig ^. #biscuit)
          installReloadHandler shared [stack]
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
                  $ (stack ^. #application)
          withMaintenance shared [stack] $
            serve (shared ^. #tls) (shared ^. #port) wrappedApp

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
         in withAsync (runMaintenanceLoop (shared ^. #maintenance) runAppNow) \_maintenance -> inner
    )
    action
    stacks

-- | Reload every stack on @SIGHUP@.
--
-- One writer, serialized. Two SIGHUPs in flight would otherwise race to
-- `atomicWriteIORef`, and the loser's orphan report would describe a schema that is
-- not the one now serving.
installReloadHandler :: SharedConfig -> [TenantStack] -> IO ()
installReloadHandler shared stacks = do
  reloadGuard <- newMVar ()
  _ <-
    installHandler
      sigHUP
      (Catch (withMVar reloadGuard \() -> traverse_ (reloadStack shared) stacks))
      Nothing
  pure ()

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
