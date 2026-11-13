{-# LANGUAGE OverloadedRecordDot #-}

-- | @en-server-loadbench@: drive a real @en-server@ process over HTTP.
--
-- Three subcommands:
--
-- * @run@ measures every workload against one binary and prints a table.
-- * @ab@ measures two binaries in alternation and prints PASS or REGRESSION per workload
--   under the rule in "Verdict".
-- * @interference@ measures how much a busy caller slows an idle one, inside one process
--   and across two processes on the same machine.
--
-- Every command creates its own temporary PostgreSQL instance, seeds its databases with
-- the server's own @import@ subcommand, and removes everything on exit. Run it from the
-- repository root: the schema fixture is read from @en-server/loadbench/fixtures@.
--
-- See docs/plans/72-build-an-en-server-load-benchmark-and-record-the-single-tenant-baseline.md.
module Main (main) where

import Control.Monad (forM, forM_, unless, when)
import Data.Aeson (ToJSON, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Foldable (traverse_)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Fixture
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Generics (Generic)
import Network.HTTP.Client qualified as Http
import ServerHarness
import System.Directory (doesFileExist, makeAbsolute)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitFailure, exitWith)
import System.FilePath ((</>))
import System.IO (BufferMode (LineBuffering), hPutStrLn, hSetBuffering, stderr, stdout)
import System.IO.Temp (withSystemTempDirectory)
import Text.Printf (printf)
import Text.Read (readMaybe)
import Verdict
import Workload

-- * Command line

data Options = Options
  { smoke :: !Bool,
    threadsOverride :: !(Maybe Int),
    warmupOverride :: !(Maybe Double),
    measureOverride :: !(Maybe Double),
    rounds :: !(Maybe Int),
    -- | Discarded rounds per binary (per topology for @interference@) before the
    --     measured ones. The first round against a freshly seeded database is reliably
    --     slower -- PostgreSQL's caches and the new relations are still warming -- so it
    --     is run and thrown away. Default 1, or 0 with @--smoke@.
    warmupRounds :: !(Maybe Int),
    jsonPath :: !(Maybe FilePath),
    server :: !(Maybe FilePath),
    baseline :: !(Maybe FilePath),
    candidate :: !(Maybe FilePath),
    candidateEnv :: ![(String, String)],
    -- | Extra variables for every server @interference@ starts; a diagnostic knob.
    serverEnv :: ![(String, String)],
    -- | Hidden test flag: present a wrong key and skip the pre-flight check, to show
    --     that errors in the measurement loop fail the run rather than count as successes.
    breakAuth :: !Bool
  }

emptyOptions :: Options
emptyOptions =
  Options
    { smoke = False,
      threadsOverride = Nothing,
      warmupOverride = Nothing,
      measureOverride = Nothing,
      rounds = Nothing,
      warmupRounds = Nothing,
      jsonPath = Nothing,
      server = Nothing,
      baseline = Nothing,
      candidate = Nothing,
      candidateEnv = [],
      serverEnv = [],
      breakAuth = False
    }

data Command = Run | Ab | Interference

parseArgs :: [String] -> Either String (Command, Options)
parseArgs = \case
  "run" : rest -> (Run,) <$> options rest
  "ab" : rest -> (Ab,) <$> options rest
  "interference" : rest -> (Interference,) <$> options rest
  _ -> Left "expected a subcommand: run, ab or interference"
  where
    options = go emptyOptions
    go o = \case
      [] -> Right o
      "--smoke" : xs -> go o {smoke = True} xs
      "--break-auth" : xs -> go o {breakAuth = True} xs
      "--threads" : v : xs -> number "--threads" v >>= \n -> go o {threadsOverride = Just n} xs
      "--warmup-seconds" : v : xs -> real "--warmup-seconds" v >>= \n -> go o {warmupOverride = Just n} xs
      "--measure-seconds" : v : xs -> real "--measure-seconds" v >>= \n -> go o {measureOverride = Just n} xs
      "--rounds" : v : xs -> number "--rounds" v >>= \n -> go o {rounds = Just n} xs
      "--warmup-rounds" : v : xs -> case readMaybe v of
        Just n | n >= (0 :: Int) -> go o {warmupRounds = Just n} xs
        _ -> Left ("--warmup-rounds expects a non-negative integer, got " <> v)
      "--json" : v : xs -> go o {jsonPath = Just v} xs
      "--server" : v : xs -> go o {server = Just v} xs
      "--baseline" : v : xs -> go o {baseline = Just v} xs
      "--candidate" : v : xs -> go o {candidate = Just v} xs
      "--candidate-env" : v : xs -> keyValue "--candidate-env" v >>= \kv -> go o {candidateEnv = candidateEnv o <> [kv]} xs
      "--server-env" : v : xs -> keyValue "--server-env" v >>= \kv -> go o {serverEnv = serverEnv o <> [kv]} xs
      other : _ -> Left ("unknown argument: " <> other)
    keyValue flag v = case break (== '=') v of
      (key, '=' : value) | not (null key) -> Right (key, value)
      _ -> Left (flag <> " expects KEY=VALUE, got " <> v)
    number flag v = case readMaybe v of
      Just n | n > (0 :: Int) -> Right n
      _ -> Left (flag <> " expects a positive integer, got " <> v)
    real flag v = case readMaybe v of
      Just n | n > (0 :: Double) -> Right n
      _ -> Left (flag <> " expects a positive number, got " <> v)

usage :: String
usage =
  unlines
    [ "usage:",
      "  en-server-loadbench run [--server PATH] [--smoke] [--json PATH]",
      "  en-server-loadbench ab --baseline PATH --candidate PATH [--rounds N] [--server-env KEY=VALUE]... [--candidate-env KEY=VALUE]... [--smoke] [--json PATH]",
      "  en-server-loadbench interference [--server PATH] [--rounds N] [--server-env KEY=VALUE]... [--smoke] [--json PATH]",
      "",
      "common options: --threads N --warmup-seconds S --measure-seconds S --warmup-rounds N",
      "--server defaults to EN_SERVER_BIN, else `cabal list-bin en-server`. Run from the repository root."
    ]

warmupRoundCount :: Options -> Int
warmupRoundCount o = fromMaybe (if smoke o then 0 else 1) (warmupRounds o)

loadSettings :: Options -> LoadSettings
loadSettings o =
  let base = if smoke o then smokeLoadSettings else defaultLoadSettings
   in base
        { threads = fromMaybe (threads base) (threadsOverride o),
          warmupSeconds = fromMaybe (warmupSeconds base) (warmupOverride o),
          measureSeconds = fromMaybe (measureSeconds base) (measureOverride o)
        }

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  args <- getArgs
  case parseArgs args of
    Left err -> do
      hPutStrLn stderr ("en-server-loadbench: " <> err)
      hPutStrLn stderr usage
      exitWith (ExitFailure 2)
    Right (command, o) -> case command of
      Run -> runCommand o
      Ab -> abCommand o
      Interference -> interferenceCommand o

-- * Shared setup

data Bench = Bench
  { postgres :: !PostgresInstance,
    schemaPath :: !FilePath,
    seedFile :: !FilePath,
    inherited :: ![(String, String)]
  }

withBench :: (Bench -> IO a) -> IO a
withBench action = do
  schemaPath <- makeAbsolute schemaFixturePath
  present <- doesFileExist schemaPath
  unless present (die' ("schema fixture not found at " <> schemaPath <> "; run from the repository root"))
  inherited <- baseEnvironment
  withSystemTempDirectory "en-loadbench" \dir -> do
    let seedFile = dir </> "seed.ndjson"
    writeSeedFile seedFile
    withPostgres \postgres -> action Bench {postgres, schemaPath, seedFile, inherited}

-- | Create, migrate and seed a database with the given binary's own @import@.
prepareDatabase :: Bench -> FilePath -> Text -> IO Text
prepareDatabase bench binary name = do
  url <- createMigratedDatabase (postgres bench) name
  let spec = serverSpec binary (inherited bench <> serverEnvironment PlainProfile url (schemaPath bench))
  (code, _, err) <- runServerCommand spec ["import", "--file", seedFile bench]
  case code of
    ExitSuccess -> pure url
    _ -> die' ("seeding " <> Text.unpack name <> " with " <> binary <> " failed:\n" <> Text.unpack err)

-- | The spec for one benchmark server: stdout (the per-request log) is discarded so
-- the load generator spends no CPU reading it.
benchServer :: Bench -> FilePath -> [(String, String)] -> ServerProfile -> Text -> ServerSpec
benchServer bench binary overrides profile url =
  (serverSpec binary (override (inherited bench <> serverEnvironment profile url (schemaPath bench))))
    { captureStdout = False
    }
  where
    override env = filter ((`notElem` map fst overrides) . fst) env <> overrides

targetFor :: Bool -> RunningServer -> Credential -> Target
targetFor broken running credential =
  Target
    { targetUrl = baseUrl running,
      secret = if broken then "deliberately-wrong-secret" else credentialSecret credential
    }

-- | Measure every workload once against one binary, starting one server per profile.
--
-- The cached profile runs first and the plain profile last, so that @write@, which grows
-- the database, is the final workload against it. Results come back in report order.
measureRound :: Bench -> Options -> FilePath -> [(String, String)] -> Text -> IO [WorkloadResult]
measureRound bench o binary overrides url = do
  -- Fresh planner statistics and a vacuumed heap before every round: otherwise
  -- autovacuum, woken by the seed or by the previous round's writes, lands inside some
  -- rounds and not others.
  runDatabaseScript url "VACUUM ANALYZE"
  salt <- Text.pack . show <$> getMonotonicTimeNSec
  let workloads = benchWorkloads salt
      settings = loadSettings o
      byProfile wanted = [w | w <- workloads, profile w == wanted]
  measured <- forM [CachedProfile, PlainProfile] \p ->
    withServer (benchServer bench binary overrides p url) \running ->
      forM (byProfile p) \w -> do
        let target' = targetFor (breakAuth o) running (credential w)
        unless (breakAuth o) do
          manager <- newVerifyManager
          verifyWorkload manager target' w >>= \case
            Right () -> pure ()
            Left err -> die' ("workload " <> Text.unpack (name w) <> " does not measure what it claims: " <> Text.unpack err)
        result <- runWorkload settings target' w
        when (errors result > 0) $
          die'
            ( "workload "
                <> Text.unpack (name w)
                <> " had "
                <> show (errors result)
                <> " failed request(s); the round is invalid. First error: "
                <> Text.unpack (fromMaybe "" (firstError result))
            )
        pure result
  let order = Map.fromList (zip (map name workloads) [0 :: Int ..])
  pure (sortOn (\r -> Map.findWithDefault 0 r.workload order) (concat measured))

-- * run

runCommand :: Options -> IO ()
runCommand o = do
  binary <- maybe locateServerBinary pure (server o)
  results <- withBench \bench -> do
    url <- prepareDatabase bench binary "bench"
    forM_ [1 .. warmupRoundCount o] \r -> do
      hPutStrLn stderr ("warm-up round " <> show r <> " (discarded)")
      _ <- measureRound bench o binary [] url
      pure ()
    measureRound bench o binary [] url
  printResults results
  forM_ (jsonPath o) \path ->
    Aeson.encodeFile path $
      object
        [ "command" .= ("run" :: Text),
          "binary" .= binary,
          "settings" .= settingsJson (loadSettings o),
          "seedTuples" .= seedTupleCount,
          "workloads" .= results
        ]

printResults :: [WorkloadResult] -> IO ()
printResults results = do
  printf "%-16s %10s %9s %9s %9s %7s\n" ("workload" :: String) ("req/s" :: String) ("p50_ms" :: String) ("p95_ms" :: String) ("p99_ms" :: String) ("errors" :: String)
  forM_ results \r ->
    printf "%-16s %10.0f %9.3f %9.3f %9.3f %7d\n" (Text.unpack r.workload) r.requestsPerSecond r.p50Ms r.p95Ms r.p99Ms r.errors

settingsJson :: LoadSettings -> Aeson.Value
settingsJson s =
  object
    [ "threads" .= threads s,
      "warmupSeconds" .= warmupSeconds s,
      "measureSeconds" .= measureSeconds s
    ]

-- * ab

data AbRun = AbRun
  { binaryLabel :: !Text,
    roundIndex :: !Int,
    results :: ![WorkloadResult]
  }
  deriving stock (Generic)
  deriving anyclass (ToJSON)

abCommand :: Options -> IO ()
abCommand o = do
  baselinePath <- maybe (die' "ab needs --baseline PATH") pure (baseline o)
  candidatePath <- maybe (die' "ab needs --candidate PATH") pure (candidate o)
  let roundCount = fromMaybe 5 (rounds o)
  runs <- withBench \bench -> do
    -- Two identically seeded databases. Each round swaps which binary uses which, so a
    -- fixed difference between the two databases (physical layout, cache state) lands on
    -- both binaries equally instead of on one of them for the whole run.
    databaseA <- prepareDatabase bench baselinePath "bench_a"
    databaseB <- prepareDatabase bench candidatePath "bench_b"
    let databaseFor which r
          | even r == (which == "baseline") = databaseA
          | otherwise = databaseB
        baselineUrl = databaseFor "baseline" (0 :: Int)
        candidateUrl = databaseFor "candidate" (0 :: Int)
    forM_ [1 .. warmupRoundCount o] \r ->
      forM_ [(baselinePath, serverEnv o, baselineUrl), (candidatePath, serverEnv o <> candidateEnv o, candidateUrl)] \(binary, overrides, url) -> do
        hPutStrLn stderr ("warm-up round " <> show r <> " (discarded): " <> binary)
        _ <- measureRound bench o binary overrides url
        pure ()
    collected <- newIORef []
    -- Baseline, candidate, candidate, baseline, ...: slow drift in the machine lands on
    -- both binaries equally.
    forM_ [0 .. roundCount - 1] \r -> do
      let order = if even r then ["baseline", "candidate"] else ["candidate", "baseline"]
      forM_ order \which -> do
        let url = databaseFor which r
            (binary, overrides) =
              if which == "baseline"
                then (baselinePath, serverEnv o)
                else (candidatePath, serverEnv o <> candidateEnv o)
        hPutStrLn stderr ("round " <> show (r + 1) <> "/" <> show roundCount <> ": " <> Text.unpack which)
        measured <- measureRound bench o binary overrides url
        modifyIORef' collected (<> [AbRun {binaryLabel = which, roundIndex = r, results = measured}])
    readIORef collected
  let names = case runs of
        firstRun : _ -> map (\r -> r.workload) (results firstRun)
        [] -> []
      roundsOf which name' =
        [ result
        | run <- runs,
          binaryLabel run == which,
          result <- results run,
          result.workload == name'
        ]
      verdicts = [verdictFor name' (roundsOf "baseline" name') (roundsOf "candidate" name') | name' <- names]
      allPassed = all passed verdicts
  printVerdicts verdicts
  printf
    "RESULT: %s (%d workloads, %d rounds)\n"
    (if allPassed then "PASS" else "REGRESSION" :: String)
    (length verdicts)
    roundCount
  forM_ (jsonPath o) \path ->
    Aeson.encodeFile path $
      object
        [ "command" .= ("ab" :: Text),
          "baseline" .= baselinePath,
          "candidate" .= candidatePath,
          "candidateEnv" .= map (\(k, v) -> k <> "=" <> v) (candidateEnv o),
          "serverEnv" .= map (\(k, v) -> k <> "=" <> v) (serverEnv o),
          "settings" .= settingsJson (loadSettings o),
          "rounds" .= roundCount,
          "warmupRounds" .= warmupRoundCount o,
          "runs" .= runs,
          "verdicts" .= verdicts,
          "result" .= (if allPassed then "PASS" else "REGRESSION" :: Text)
        ]
  unless allPassed exitFailure

printVerdicts :: [WorkloadVerdict] -> IO ()
printVerdicts verdicts = do
  printf
    "%-16s %-8s %11s %11s %8s %7s %10s  %s\n"
    ("workload" :: String)
    ("metric" :: String)
    ("baseline" :: String)
    ("candidate" :: String)
    ("delta" :: String)
    ("noise" :: String)
    ("tolerance" :: String)
    ("verdict" :: String)
  forM_ verdicts \v ->
    forM_ (comparisons v) \c ->
      printf
        "%-16s %-8s %11.3f %11.3f %+7.1f%% %6.1f%% %9.1f%%  %s\n"
        (Text.unpack v.workload)
        (Text.unpack c.metric)
        c.baselineMedian
        c.candidateMedian
        (100 * c.delta)
        (100 * c.noise)
        (100 * c.tolerance)
        (verdictLabel c)

verdictLabel :: MetricComparison -> String
verdictLabel c
  | not c.gating = if c.regression then "info (worse)" else "info"
  | c.regression = "REGRESSION"
  | otherwise = "PASS"

-- * interference

-- | One topology's victim figures, alone and under load.
data TopologyResult = TopologyResult
  { topology :: !Text,
    aloneRequestsPerSecond :: !Double,
    aloneP99Ms :: !Double,
    loadedRequestsPerSecond :: !Double,
    loadedP99Ms :: !Double,
    -- | Loaded throughput over alone throughput: 1.0 means unaffected.
    throughputRatio :: !Double,
    -- | Loaded p99 over alone p99: 1.0 means unaffected.
    p99Ratio :: !Double,
    aggressorRequestsPerSecond :: !Double
  }
  deriving stock (Generic, Show)
  deriving anyclass (ToJSON)

data InterferenceRound = InterferenceRound
  { topologyName :: !Text,
    roundNumber :: !Int,
    alone :: ![WorkloadResult],
    loaded :: ![WorkloadResult]
  }
  deriving stock (Generic)
  deriving anyclass (ToJSON)

victimThreads, aggressorThreadsPerWorkload :: Int
victimThreads = 8
aggressorThreadsPerWorkload = 32

interferenceCommand :: Options -> IO ()
interferenceCommand o = do
  binary <- maybe locateServerBinary pure (server o)
  let roundCount = fromMaybe 3 (rounds o)
      settings = loadSettings o
  roundsRun <- withBench \bench -> do
    sharedUrl <- prepareDatabase bench binary "interference_shared"
    victimUrl <- prepareDatabase bench binary "interference_victim"
    aggressorUrl <- prepareDatabase bench binary "interference_aggressor"
    let spec = benchServer bench binary (serverEnv o) PlainProfile
        victim running = victimGroup (targetFor False running victimCredential)
        aggressors running =
          [ aggressorGroup "aggressor-check-nested" checkNested (targetFor False running aggressorCredential),
            aggressorGroup "aggressor-lookup" lookupWorkload (targetFor False running aggressorCredential)
          ]
        analyze = traverse_ (`runDatabaseScript` "VACUUM ANALYZE")
        shared r =
          analyze [sharedUrl] >> withServer (spec sharedUrl) \running -> do
            soloResults <- runGroups settings [victim running]
            loadedResults <- runGroups settings (victim running : aggressors running)
            pure InterferenceRound {topologyName = "shared-process", roundNumber = r, alone = soloResults, loaded = loadedResults}
        separate r =
          analyze [victimUrl, aggressorUrl] >> withServer (spec victimUrl) \victimServer ->
            withServer (spec aggressorUrl) \aggressorServer -> do
              soloResults <- runGroups settings [victim victimServer]
              loadedResults <- runGroups settings (victim victimServer : aggressors aggressorServer)
              pure InterferenceRound {topologyName = "separate-processes", roundNumber = r, alone = soloResults, loaded = loadedResults}
    forM_ [1 .. warmupRoundCount o] \r -> do
      hPutStrLn stderr ("interference warm-up round " <> show r <> " (discarded)")
      _ <- shared (-r)
      _ <- separate (-r)
      pure ()
    fmap concat $ forM [0 .. roundCount - 1] \r -> do
      hPutStrLn stderr ("interference round " <> show (r + 1) <> "/" <> show roundCount)
      let order = if even r then [shared, separate] else [separate, shared]
      forM order \measure -> do
        result <- measure r
        let failures = [w | w <- alone result <> loaded result, errors w > 0]
        unless (null failures) $
          die' ("interference run had failed requests: " <> show (map (\w -> (w.workload, w.errors, w.firstError)) failures))
        pure result
  let summaries = map (summarizeTopology roundsRun) ["shared-process", "separate-processes"]
  printf
    "%-20s %12s %10s %12s %10s %10s %9s %13s\n"
    ("topology" :: String)
    ("alone_req/s" :: String)
    ("alone_p99" :: String)
    ("loaded_req/s" :: String)
    ("loaded_p99" :: String)
    ("tput_ratio" :: String)
    ("p99_ratio" :: String)
    ("aggressor_r/s" :: String)
  forM_ summaries \t ->
    printf
      "%-20s %12.0f %10.3f %12.0f %10.3f %10.3f %9.3f %13.0f\n"
      (Text.unpack t.topology)
      t.aloneRequestsPerSecond
      t.aloneP99Ms
      t.loadedRequestsPerSecond
      t.loadedP99Ms
      t.throughputRatio
      t.p99Ratio
      t.aggressorRequestsPerSecond
  case summaries of
    [sharedSummary, separateSummary] ->
      printf
        "shared-process vs separate-processes: victim throughput ratio %.3f vs %.3f, p99 ratio %.3f vs %.3f\n"
        sharedSummary.throughputRatio
        separateSummary.throughputRatio
        sharedSummary.p99Ratio
        separateSummary.p99Ratio
    _ -> pure ()
  forM_ (jsonPath o) \path ->
    Aeson.encodeFile path $
      object
        [ "command" .= ("interference" :: Text),
          "binary" .= binary,
          "serverEnv" .= map (\(k, v) -> k <> "=" <> v) (serverEnv o),
          "settings" .= settingsJson settings,
          "victimThreads" .= victimThreads,
          "aggressorThreadsPerWorkload" .= aggressorThreadsPerWorkload,
          "rounds" .= roundsRun,
          "summary" .= summaries
        ]
  where
    victimGroup target' =
      LoadGroup {label = "victim", groupWorkload = checkDirect {credential = victimCredential}, target = target', groupThreads = victimThreads}
    aggressorGroup label' w target' =
      LoadGroup {label = label', groupWorkload = w {credential = aggressorCredential}, target = target', groupThreads = aggressorThreadsPerWorkload}

-- | Medians over rounds of the victim's figures, and of the aggressors' total throughput.
summarizeTopology :: [InterferenceRound] -> Text -> TopologyResult
summarizeTopology roundsRun which =
  TopologyResult
    { topology = which,
      aloneRequestsPerSecond = aloneRps,
      aloneP99Ms = aloneP99,
      loadedRequestsPerSecond = loadedRps,
      loadedP99Ms = loadedP99,
      throughputRatio = if aloneRps == 0 then 0 else loadedRps / aloneRps,
      p99Ratio = if aloneP99 == 0 then 0 else loadedP99 / aloneP99,
      aggressorRequestsPerSecond = median [sum (map requestsPerSecond (drop 1 (loaded r))) | r <- mine]
    }
  where
    mine = [r | r <- roundsRun, topologyName r == which]
    victimOf = take 1
    aloneRps = median [requestsPerSecond v | r <- mine, v <- victimOf (alone r)]
    aloneP99 = median [p99Ms v | r <- mine, v <- victimOf (alone r)]
    loadedRps = median [requestsPerSecond v | r <- mine, v <- victimOf (loaded r)]
    loadedP99 = median [p99Ms v | r <- mine, v <- victimOf (loaded r)]

-- * Helpers

newVerifyManager :: IO Http.Manager
newVerifyManager = Http.newManager Http.defaultManagerSettings

die' :: String -> IO a
die' message = do
  hPutStrLn stderr ("en-server-loadbench: " <> message)
  exitFailure
