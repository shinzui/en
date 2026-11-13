{-# LANGUAGE OverloadedRecordDot #-}

-- | Drive a real @en-server@ process against disposable PostgreSQL.
--
-- This module deliberately depends on none of the server's own sources: it treats the
-- server as a black box reached through its executable, its environment and its HTTP
-- port. That is what lets the load benchmark compare two differently built binaries by
-- path, and what lets the isolation tests prove behaviour of the shipped artefact rather
-- than of modules linked into a test.
--
-- PostgreSQL comes from @ephemeral-pg@ (mori://shinzui/ephemeral-pg). One instance can
-- hold several databases; 'createMigratedDatabase' adds one by name and applies the same
-- migration plan @en-migrate up@ applies.
module ServerHarness
  ( -- * The server binary
    locateServerBinary,

    -- * PostgreSQL
    PostgresInstance,
    startPostgres,
    stopPostgres,
    restartPostgres,
    withPostgres,
    postgresDatabase,
    createMigratedDatabase,
    createEmptyDatabase,
    migrateDatabaseUrl,
    runDatabaseScript,
    queryDatabaseText,

    -- * Server processes
    ServerSpec (..),
    serverSpec,
    RunningServer,
    baseUrl,
    serverPort,
    capturedLines,
    signalServer,
    withServer,
    runServerCommand,
    baseEnvironment,
  )
where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar)
import Control.Exception (SomeException, bracket, finally, mask, onException, throwIO, try)
import Control.Monad (forM_, unless, when)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Maybe (catMaybes)
import Data.Monoid (Last (..))
import Data.Sequence (Seq)
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Database.PostgreSQL.Migrate (defaultRunOptions, runMigrationPlan)
import En.Migrations (enMigrationPlan)
import EphemeralPg qualified as Pg
import GHC.Clock (getMonotonicTimeNSec)
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Network.HTTP.Client qualified as Http
import Network.HTTP.Types (statusCode)
import Network.Socket qualified as Socket
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.IO (Handle, IOMode (WriteMode), hClose, hIsEOF, hSetBinaryMode, openFile)
import System.Posix.Signals (Signal, sigKILL, signalProcess)
import System.Posix.User (getEffectiveUserID)
import System.Process qualified as Process
import System.Timeout (timeout)

-- * The server binary

-- | Where the server binary comes from: @EN_SERVER_BIN@, else
-- @cabal list-bin en-server:exe:en-server@ (the package has several components, so the
-- bare package name is ambiguous to @list-bin@).
locateServerBinary :: IO FilePath
locateServerBinary =
  lookupEnv "EN_SERVER_BIN" >>= \case
    Just path | not (null path) -> pure path
    _ -> do
      (code, out, err) <- Process.readProcessWithExitCode "cabal" ["list-bin", "-v0", "en-server:exe:en-server"] ""
      case (code, lines out) of
        (ExitSuccess, path : _) -> pure path
        _ -> fail ("could not locate en-server with `cabal list-bin en-server`: " <> err)

-- * PostgreSQL

-- | An ephemeral PostgreSQL instance whose lifetime the caller controls.
--
-- The handle is kept in an 'IORef' because a restart yields a new process handle for the
-- same data directory, and every database URL handed out earlier must stay valid.
newtype PostgresInstance = PostgresInstance (IORef Pg.Database)

-- | Start an instance under a stable per-user temporary root, so that the next run can
-- reap clusters a crashed run abandoned (see the ephemeral-pg guide
-- temporary-roots-and-stale-cleanup.md, mori://shinzui/ephemeral-pg; artifact URI pending).
startPostgres :: IO PostgresInstance
startPostgres = do
  uid <- getEffectiveUserID
  let root = "/tmp/ephpg-en-" <> show uid
  createDirectoryIfMissing True root
  let config = Pg.defaultConfig {Pg.temporaryRoot = Last (Just root)}
  Pg.start config >>= \case
    Left err -> fail ("ephemeral-pg failed to start: " <> Text.unpack (Pg.renderStartError err))
    Right database -> PostgresInstance <$> newIORef database

-- | Stop the instance and remove its data directory.
stopPostgres :: PostgresInstance -> IO ()
stopPostgres (PostgresInstance ref) = readIORef ref >>= Pg.stop

-- | Stop and start the PostgreSQL server, keeping its data. Connections held across the
-- restart are broken, as they would be in production.
restartPostgres :: PostgresInstance -> IO PostgresInstance
restartPostgres instance'@(PostgresInstance ref) = do
  database <- readIORef ref
  Pg.restart database >>= \case
    Left err -> fail ("ephemeral-pg failed to restart: " <> Text.unpack (Pg.renderStartError err))
    Right restarted -> do
      atomicModifyIORef' ref (const (restarted, ()))
      pure instance'

withPostgres :: (PostgresInstance -> IO a) -> IO a
withPostgres = bracket startPostgres stopPostgres

-- | The underlying ephemeral-pg handle, for callers that need its socket or port.
postgresDatabase :: PostgresInstance -> IO Pg.Database
postgresDatabase (PostgresInstance ref) = readIORef ref

-- | Create a database by name in the instance, apply @enMigrationPlan@, return its URL.
createMigratedDatabase :: PostgresInstance -> Text -> IO Text
createMigratedDatabase instance' name = do
  url <- createEmptyDatabase instance' name
  migrateDatabaseUrl url
  pure url

-- | Create a database by name without migrating it, and return its connection string.
--
-- The name is restricted to lower-case letters, digits and underscores so it can be
-- quoted into @CREATE DATABASE@ without an escaping routine.
createEmptyDatabase :: PostgresInstance -> Text -> IO Text
createEmptyDatabase instance' name = do
  unless (validName name) (fail ("invalid database name: " <> Text.unpack name))
  database <- postgresDatabase instance'
  bracket (acquire (Pg.connectionSettings database)) Connection.release \connection ->
    Connection.use connection (Session.script ("CREATE DATABASE \"" <> name <> "\"")) >>= \case
      Right () -> pure ()
      Left err -> fail ("could not create database " <> Text.unpack name <> ": " <> show err)
  pure (databaseUrl database name)
  where
    validName candidate =
      not (Text.null candidate)
        && Text.all (\c -> c == '_' || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) candidate

-- | Apply the migration plan @en-migrate up@ applies to the database at this URL.
migrateDatabaseUrl :: Text -> IO ()
migrateDatabaseUrl url = do
  plan <- either (\planError -> fail ("en migration plan is invalid: " <> show planError)) pure enMigrationPlan
  runMigrationPlan defaultRunOptions (Settings.connectionString url) plan >>= \case
    Right _ -> pure ()
    Left migrationError -> fail ("could not migrate " <> Text.unpack url <> ": " <> show migrationError)

-- | Run a SQL script (one or more statements, no results) against the database at this
-- URL on a connection of its own. @VACUUM@ is allowed: the script is not wrapped in a
-- transaction.
runDatabaseScript :: Text -> Text -> IO ()
runDatabaseScript url sql =
  bracket (acquire (Settings.connectionString url)) Connection.release \connection ->
    Connection.use connection (Session.script sql) >>= \case
      Right () -> pure ()
      Left err -> fail ("could not run script against " <> Text.unpack url <> ": " <> show err)

-- | Run a query returning one row of one column, cast to text in SQL
-- (@SELECT generation::text FROM …@), against the database at this URL.
queryDatabaseText :: Text -> Text -> IO Text
queryDatabaseText url sql =
  bracket (acquire (Settings.connectionString url)) Connection.release \connection ->
    Connection.use connection (Session.statement () statement) >>= \case
      Right value -> pure value
      Left err -> fail ("could not query " <> Text.unpack url <> ": " <> show err)
  where
    statement =
      Statement.unpreparable
        sql
        Encoders.noParams
        (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.text)))

-- | A libpq keyword/value connection string, the form @EN_DATABASE_URL@ accepts.
databaseUrl :: Pg.Database -> Text -> Text
databaseUrl database name =
  Text.unwords
    [ "host=" <> Text.pack database.socketDirectory,
      "port=" <> Text.pack (show database.port),
      "dbname=" <> name,
      "user=" <> database.user
    ]

acquire :: Settings.Settings -> IO Connection.Connection
acquire settings =
  Connection.acquire settings >>= \case
    Right connection -> pure connection
    Left err -> fail ("could not connect to PostgreSQL: " <> show err)

-- * Server processes

data ServerSpec = ServerSpec
  { binary :: FilePath,
    -- | The complete environment of the child; @EN_PORT@ is added by the harness.
    environment :: [(String, String)],
    -- | Wait for @GET /health/ready@ to answer 200 before handing the server over.
    waitForReady :: Bool,
    -- | Keep the child's stdout lines. The request log writes one line per request, so a
    --     load run discards stdout rather than spend benchmark CPU reading it; stderr,
    --     where startup failures go, is always kept.
    captureStdout :: Bool
  }

-- | A spec that waits for readiness and captures both streams.
serverSpec :: FilePath -> [(String, String)] -> ServerSpec
serverSpec binary environment =
  ServerSpec {binary, environment, waitForReady = True, captureStdout = True}

data RunningServer = RunningServer
  { port :: !Int,
    outputLines :: !(IORef (Seq Text)),
    processHandle :: !(IORef (Maybe Process.ProcessHandle))
  }

-- | Send a signal to the running server, e.g. @sigHUP@ to reload its schemas.
signalServer :: RunningServer -> Signal -> IO ()
signalServer server signal =
  readIORef (processHandle server) >>= \case
    Nothing -> fail "the server has not been started"
    Just handle -> Process.getPid handle >>= mapM_ (signalProcess signal)

baseUrl :: RunningServer -> Text
baseUrl server = "http://127.0.0.1:" <> Text.pack (show (port server))

serverPort :: RunningServer -> Int
serverPort = port

-- | The lines the server has printed so far, stdout and stderr interleaved in arrival
-- order (stderr lines are prefixed with @stderr: @).
capturedLines :: RunningServer -> IO [Text]
capturedLines server = foldr (:) [] <$> readIORef (outputLines server)

-- | The variables a child needs from the parent to behave like a shell-launched process:
-- a locale (GHC picks its text encoding from it), a search path and a temporary directory.
baseEnvironment :: IO [(String, String)]
baseEnvironment =
  catMaybes <$> traverse inherit ["PATH", "HOME", "LANG", "LC_ALL", "TMPDIR"]
  where
    inherit name = fmap (name,) <$> lookupEnv name

-- | Start the server on a free port, run the action, then stop it with SIGTERM.
--
-- When the spec asks for readiness, this waits up to 60 seconds for @GET /health/ready@
-- to answer 200, and fails with the captured output if the process exits first or the
-- deadline passes.
withServer :: ServerSpec -> (RunningServer -> IO a) -> IO a
withServer spec action = do
  freePort <- findFreePort
  outputLines <- newIORef Seq.empty
  processHandle <- newIORef Nothing
  let server = RunningServer {port = freePort, outputLines, processHandle}
      env = ("EN_PORT", show freePort) : filter ((/= "EN_PORT") . fst) (environment spec)
  mask \restore -> do
    (handle, stdoutDone, stderrDone) <- spawn spec env outputLines
    atomicModifyIORef' processHandle (const (Just handle, ()))
    let stop = stopProcess handle >> readMVar stdoutDone >> readMVar stderrDone
    result <-
      restore
        ( do
            when (waitForReady spec) (awaitReady server handle)
            action server
        )
        `onException` stop
    stop
    pure result

-- | Run @en-server <args>@ to completion: exit code, stdout, stderr.
runServerCommand :: ServerSpec -> [String] -> IO (ExitCode, Text, Text)
runServerCommand spec args = do
  let process =
        (Process.proc (binary spec) args)
          { Process.env = Just (environment spec),
            Process.std_in = Process.NoStream
          }
  (code, out, err) <- Process.readCreateProcessWithExitCode process ""
  pure (code, Text.pack out, Text.pack err)

spawn :: ServerSpec -> [(String, String)] -> IORef (Seq Text) -> IO (Process.ProcessHandle, MVar (), MVar ())
spawn spec env outputLines = do
  devNull <-
    if captureStdout spec
      then pure Nothing
      else Just <$> openFile "/dev/null" WriteMode
  let process =
        (Process.proc (binary spec) [])
          { Process.env = Just env,
            Process.std_in = Process.NoStream,
            Process.std_out = maybe Process.CreatePipe Process.UseHandle devNull,
            Process.std_err = Process.CreatePipe
          }
  (_, out, err, handle) <- Process.createProcess process
  forM_ devNull hClose
  stdoutDone <- newEmptyMVar
  stderrDone <- newEmptyMVar
  case out of
    Just h -> drain h "" outputLines stdoutDone
    Nothing -> putMVar stdoutDone ()
  case err of
    Just h -> drain h "stderr: " outputLines stderrDone
    Nothing -> putMVar stderrDone ()
  pure (handle, stdoutDone, stderrDone)

-- | Read a stream line by line into the shared buffer until end of file. The buffer
-- keeps the most recent lines only, so a long run cannot grow it without bound.
drain :: Handle -> Text -> IORef (Seq Text) -> MVar () -> IO ()
drain handle prefix outputLines done = do
  hSetBinaryMode handle False
  _ <-
    forkIO $
      let loop = do
            eof <- hIsEOF handle
            unless eof do
              line <- Text.hGetLine handle
              atomicModifyIORef' outputLines \buffer ->
                (Seq.drop (Seq.length buffer + 1 - maxCapturedLines) buffer Seq.|> (prefix <> line), ())
              loop
       in ((try loop :: IO (Either SomeException ())) >> hClose handle) `finally` putMVar done ()
  pure ()

maxCapturedLines :: Int
maxCapturedLines = 20000

-- | SIGTERM, then up to 40 seconds for the graceful drain (Warp's own limit is 30), then
-- SIGKILL so that a wedged child cannot hang the caller.
stopProcess :: Process.ProcessHandle -> IO ()
stopProcess handle = do
  Process.terminateProcess handle
  exited <- timeout 40_000_000 (Process.waitForProcess handle)
  case exited of
    Just _ -> pure ()
    Nothing -> do
      Process.getPid handle >>= mapM_ (signalProcess sigKILL)
      _ <- Process.waitForProcess handle
      pure ()

awaitReady :: RunningServer -> Process.ProcessHandle -> IO ()
awaitReady server handle = do
  manager <- Http.newManager Http.defaultManagerSettings
  request <- Http.parseRequest (Text.unpack (baseUrl server <> "/health/ready"))
  started <- getMonotonicTimeNSec
  let deadline = started + 60_000_000_000
      loop = do
        Process.getProcessExitCode handle >>= \case
          Just code -> giveUp ("en-server exited with " <> show code <> " before becoming ready")
          Nothing -> pure ()
        ready <- try (Http.httpNoBody request manager) :: IO (Either SomeException (Http.Response ()))
        case ready of
          Right response | statusCode (Http.responseStatus response) == 200 -> pure ()
          _ -> do
            now <- getMonotonicTimeNSec
            if now > deadline
              then giveUp "en-server did not answer GET /health/ready with 200 within 60 seconds"
              else threadDelay 50_000 >> loop
      giveUp reason = do
        -- Give the drain threads a moment to collect the last lines the child wrote.
        threadDelay 200_000
        output <- capturedLines server
        throwIO (userError (reason <> "; output:\n" <> Text.unpack (Text.unlines output)))
  loop

-- | Ask the kernel for an unused port, then release it for the child to bind.
findFreePort :: IO Int
findFreePort =
  bracket (Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol) Socket.close \socket -> do
    Socket.bind socket (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
    fromIntegral <$> Socket.socketPort socket
