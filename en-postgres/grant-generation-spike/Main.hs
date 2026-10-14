{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE MultilineStrings #-}

-- This executable deliberately accepts no database URL: every destructive fixture
-- and disabled-trigger counterfactual runs inside the bracketed ephemeral cluster.
module Main (main) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import Control.Exception (SomeException, bracket, try)
import Control.Monad (forM, forM_, replicateM, replicateM_, unless, when)
import Data.Aeson hiding (Options)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BL
import Data.Functor.Contravariant ((>$<))
import Data.Int (Int64)
import Data.List (nub, sort)
import Data.Monoid (Last (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Data.Version (showVersion)
import Database.PostgreSQL.Migrate (defaultRunOptions, runMigrationPlan)
import En.Migrations (enMigrationPlan)
import En.Postgres.GrantGeneration
import En.Revision (Revision (..))
import EphemeralPg qualified as Pg
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Generics (Generic)
import Hasql.Connection qualified as C
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Session qualified as S
import Hasql.Statement qualified as Q
import System.Directory (createDirectoryIfMissing, renameFile)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitFailure)
import System.IO (BufferMode (LineBuffering), hClose, hFlush, hSetBuffering, openBinaryTempFile, stdout)
import System.Info (arch, compilerName, compilerVersion, os)
import System.Posix.User (getEffectiveUserID)
import System.Process (readProcessWithExitCode)

-- All raw times are milliseconds. Complete plans are retained, not just the
-- displayed summary: PostgreSQL's parent buffer counts include child work.
data Cell = Cell
  { key :: String,
    samplesMs :: [Double],
    details :: Value,
    plans :: [Value]
  }
  deriving (Generic, Show, Eq, ToJSON, FromJSON)

data Report = Report
  { version :: Int,
    complete :: Bool,
    correctness :: Bool,
    environment :: Value,
    source :: Value,
    policy :: Value,
    cells :: [Cell],
    failures :: [String]
  }
  deriving (Generic, Show, ToJSON, FromJSON)

data Options = Options {smoke :: Bool, baseline :: Bool, output :: Maybe FilePath, comparison :: Maybe FilePath}

parseOptions :: [String] -> IO Options
parseOptions = go (Options False False Nothing Nothing)
  where
    go o []
      | baseline o && comparison o /= Nothing = fail "--baseline and --compare are incompatible"
      | otherwise = pure o
    go o ("--smoke" : xs) | not (smoke o) = go o {smoke = True} xs
    go o ("--baseline" : xs) | not (baseline o) = go o {baseline = True} xs
    go o ("--json" : path : xs) | output o == Nothing = go o {output = Just path} xs
    go o ("--compare" : path : xs) | comparison o == Nothing = go o {comparison = Just path} xs
    go _ xs = fail ("unknown, repeated, or incomplete arguments: " <> show xs)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  options <- getArgs >>= parseOptions
  before <- traverse readReport (comparison options)
  src <- sourceInfo
  uid <- getEffectiveUserID
  let root = "/tmp/ephpg-en-generation-" <> show uid
  createDirectoryIfMissing True root
  result <- Pg.withConfig (Pg.defaultConfig {Pg.temporaryRoot = Last (Just root)}) \db -> do
    migrate db
    bracket (acquire db) C.release \conn -> do
      env <- environmentInfo conn
      let sampleCount = if smoke options then 10 else 50
          sizes = if smoke options then [1000, 5000, 10000] else [1000, 10000, 100000, 500000, 1000000]
          writeSizes = if smoke options then [1000, 10000] else [1000, 1000000]
          pruneSizes = if smoke options then [10000] else [10000, 100000, 1000000]
          samplePolicy =
            object
              [ "smoke" .= smoke options,
                "readSamples" .= sampleCount,
                "writeRounds" .= (if smoke options then 1 else 5 :: Int),
                "transactionsPerWriter" .= (if smoke options then 10 else 100 :: Int),
                "warmups" .= (1 :: Int),
                "units" .= ("milliseconds" :: String),
                "schema" .= ("en/0001-en-bootstrap,en/0002-grant-generations" :: String),
                "fixtureSeed" .= (1000000000 :: Int64)
              ]
      transactionalCheck db conn
      readCells <- concat <$> mapM (readMatrix conn sampleCount) sizes
      sparse <- sparseMatrix conn sampleCount
      writes <- sequence [writeCell db conn options n width enabled | n <- writeSizes, width <- [1, 8, 32], enabled <- [True, False]]
      prunes <- mapM (pruneCell conn) pruneSizes
      mixedPruningCheck conn
      let allCells = readCells <> sparse <> writes <> prunes
          limitErrors = concatMap (limits (smoke options)) allCells <> doublingErrors (smoke options) allCells
          candidate = Report 1 True True env src samplePolicy allCells []
          compareErrors = maybe [] (compareReports candidate) before
          enforced = (if baseline options then [] else limitErrors) <> compareErrors
          finalReport = candidate {failures = enforced}
      forM_ limitErrors \err -> putStrLn ((if baseline options then "BASELINE LIMIT: " else "LIMIT: ") <> err)
      forM_ before (renderComparison candidate)
      forM_ compareErrors (putStrLn . ("COMPARE: " <>))
      forM_ (output options) \path -> writeReport path finalReport
      if null enforced
        then putStrLn "PASS: generation performance matrix preserved exact visibility, commit order, rollback and retained floor"
        else putStrLn "FAIL: complete, correctness-valid matrix exceeded performance/comparison gates"
      pure (null enforced)
  case result of
    Left err -> fail (T.unpack (Pg.renderStartError err))
    Right passed -> unless passed exitFailure

readReport :: FilePath -> IO Report
readReport path = BL.readFile path >>= either fail pure . eitherDecode

-- Rename only a complete artifact. An interrupted/correctness-invalid run has no
-- replacement artifact; a complete performance failure explicitly records failures.
writeReport :: FilePath -> Report -> IO ()
writeReport path report = do
  let directory = reverse (dropWhile (/= '/') (reverse path))
  (temporary, handle) <- openBinaryTempFile (if null directory then "." else directory) ".en-generation.json"
  BL.hPut handle (encode report)
  hFlush handle
  hClose handle
  renameFile temporary path

acquire :: Pg.Database -> IO C.Connection
acquire db = C.acquire (Pg.connectionSettings db) >>= either (fail . show) pure

migrate :: Pg.Database -> IO ()
migrate db = do
  plan <- either (fail . show) pure enMigrationPlan
  runMigrationPlan defaultRunOptions (Pg.connectionSettings db) plan >>= either (fail . show) (const (pure ()))

session :: C.Connection -> S.Session a -> IO a
session conn action = C.use conn action >>= either (fail . show) pure

script :: C.Connection -> Text -> IO ()
script conn = session conn . S.script

query :: C.Connection -> Text -> D.Result a -> IO a
query conn sql decoder = session conn (S.statement () (Q.preparable sql E.noParams decoder))

textResult :: D.Result Text
textResult = D.singleRow (D.column (D.nonNullable D.text))

integerResult :: D.Result Int64
integerResult = D.singleRow (D.column (D.nonNullable D.int8))

jsonResult :: D.Result Value
jsonResult = D.singleRow (D.column (D.nonNullable D.json))

explain :: C.Connection -> Text -> Text -> IO Value
explain conn sql snapshot = session conn (S.statement snapshot (Q.preparable ("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " <> sql) (E.param (E.nonNullable E.text)) jsonResult))

originalSql :: Text
originalSql = "SELECT generation FROM en_grant_generation WHERE pg_visible_in_snapshot(created_xid,$1::pg_snapshot) ORDER BY generation DESC LIMIT 1"

reference :: C.Connection -> Text -> IO (Maybe Text)
reference conn snapshot = fmap (fmap (T.pack . ("gg1_" <>) . show)) $ session conn (S.statement snapshot (Q.preparable originalSql (E.param (E.nonNullable E.text)) (D.rowMaybe (D.column (D.nonNullable D.int8)))))

showT :: (Show a) => a -> Text
showT = T.pack . show

seedBase :: Int64
seedBase = 1000000000

-- Synthetic XIDs follow a visibility prefix; real writer XIDs are checked to be
-- below seedBase and fixture families reset before use.
seed :: C.Connection -> Int64 -> IO ()
seed conn count = do
  script conn ("TRUNCATE en_grant_generation, en_transaction; INSERT INTO en_grant_generation SELECT g, (" <> showT seedBase <> "+g)::text::xid8 FROM generate_series(0," <> showT (count - 1) <> ") g; UPDATE en_grant_generation_head SET generation=" <> showT (count - 1) <> "; ANALYZE en_grant_generation;")

snapshotAt :: Int64 -> Text
snapshotAt rank = let end = showT (seedBase + rank + 1) in end <> ":" <> end <> ":"

readMatrix :: C.Connection -> Int -> Int64 -> IO [Cell]
readMatrix conn sampleCount count = do
  seed conn count
  storage <- query conn "SELECT json_build_object('totalBytes',pg_total_relation_size('en_grant_generation'),'tableBytes',pg_table_size('en_grant_generation'),'indexBytes',pg_indexes_size('en_grant_generation'))" jsonResult
  putStrLn ("generation-storage history=" <> show count <> " " <> show storage)
  let scenarios = [("head", count - 1), ("distance32", count - 33), ("midpoint", count `div` 2), ("floor", 0)]
  forM scenarios \(label, expected) -> readCell conn sampleCount ("read/dense/" <> show count <> "/" <> label) count count (snapshotAt expected) expected storage

readCell :: C.Connection -> Int -> String -> Int64 -> Int64 -> Text -> Int64 -> Value -> IO Cell
readCell conn sampleCount name count spanSize snapshot expected extra = do
  let lookupAction = do
        actual <- session conn (grantGenerationAtSession (Revision snapshot))
        ref <- reference conn snapshot
        let wanted = Just ("gg1_" <> showT expected)
        ensure (fmap grantGenerationText actual == wanted && ref == wanted) (name <> ": incorrect exact visibility")
      measuredLookup = do
        actual <- session conn (grantGenerationAtSession (Revision snapshot))
        ensure (fmap grantGenerationText actual == Just ("gg1_" <> showT expected)) (name <> ": incorrect timed result")
  lookupAction
  raw <- measured sampleCount measuredLookup
  plan <- explain conn grantGenerationLookupSql snapshot
  let stats = planStats plan
      cell = Cell name raw (object ["fixture" .= ("synthetic-prefix" :: String), "rowCount" .= count, "numericSpan" .= spanSize, "snapshot" .= snapshot, "expected" .= expected, "actual" .= expected, "storage" .= extra, "planStats" .= stats]) [plan]
  render cell
  pure cell

sparseMatrix :: C.Connection -> Int -> IO [Cell]
sparseMatrix conn samples =
  concat <$> forM fixtures \(label, keys) -> do
    script conn "TRUNCATE en_grant_generation, en_transaction;"
    forM_ (zip [0 ..] keys) \(rank, generation) -> script conn ("INSERT INTO en_grant_generation VALUES (" <> showT generation <> ", '" <> showT (seedBase + rank) <> "');")
    script conn "ANALYZE en_grant_generation;"
    forM [(rank, generation) | (rank, generation) <- zip [0 ..] keys, rank `elem` nub [0, 1, 2, fromIntegral (length keys `div` 2), max 0 (fromIntegral (length keys) - 34), fromIntegral (length keys) - 1]] \(rank, generation) -> readCell conn samples ("read/sparse/" <> label <> "/" <> show rank) (fromIntegral (length keys)) (last keys - firstValue keys + 1) (snapshotAt rank) generation Null
  where
    -- max key leaves span representable as Int64 while exercising 63-bit arithmetic.
    fixtures :: [(String, [Int64])]
    fixtures = [("holes", [0, 2, 3] <> [19, 21 .. 2019] <> [10000]), ("single-floor", [1000]), ("int64-span", [0 .. 999] <> [4611686018427387903, 9223372036854775806])]

anchorSql :: Text
anchorSql = "INSERT INTO en_transaction (xid,snapshot,schema_hash) VALUES (pg_current_xact_id(),pg_current_snapshot(),'generation-spike');"

-- Cross-check production generations against the reference while an earlier XID
-- remains active. Returned commit responses alone never establish commit order.
transactionalCheck :: Pg.Database -> C.Connection -> IO ()
transactionalCheck db conn = do
  script conn "TRUNCATE en_grant_generation,en_transaction; UPDATE en_grant_generation_head SET generation=0; INSERT INTO en_grant_generation VALUES (0,pg_current_xact_id());"
  xid <- query conn "SELECT pg_current_xact_id()::text::bigint" integerResult
  ensure (xid < seedBase) "real XIDs overlap synthetic fixture"
  let snap = query conn "SELECT pg_current_snapshot()::text" textResult
      check snapshot expected = do
        actual <- session conn (grantGenerationAtSession (Revision snapshot))
        ref <- reference conn snapshot
        ensure (fmap grantGenerationText actual == Just expected && ref == Just expected) "transactional prefix/reference mismatch"
  initial <- snap
  bracket (acquire db) C.release \earlier -> do
    script earlier ("BEGIN; " <> anchorSql)
    script conn ("BEGIN; " <> anchorSql <> " COMMIT;")
    middle <- snap
    check middle "gg1_1"
    check initial "gg1_0"
    script earlier "COMMIT;"
    snap >>= flip check "gg1_2"
    check middle "gg1_1"
  script conn ("BEGIN; " <> anchorSql <> " ROLLBACK;")
  snap >>= flip check "gg1_2"
  putStrLn "generation-correctness fixture=transactional reversed-XIDs/xip/rollback PASS"

writeCell :: Pg.Database -> C.Connection -> Options -> Int64 -> Int -> Bool -> IO Cell
writeCell db conn options count width enabled = do
  let txCount = if smoke options then 10 else 100
      rounds = if smoke options then 1 else 5
      name = "write/" <> show count <> "/" <> show width <> "/" <> if enabled then "enabled" else "disabled"
      setup = do
        seed conn count
        script conn ("ALTER TABLE en_transaction " <> (if enabled then "ENABLE" else "DISABLE") <> " TRIGGER en_transaction_grant_generation;")
      runRound = do
        setup
        start <- getMonotonicTimeNSec
        gates <- replicateM width newEmptyMVar
        ready <- newEmptyMVar
        results <- forM gates \gate -> do
          result <- newEmptyMVar
          _ <- forkIO do
            acquired <- try @SomeException (acquire db)
            case acquired of
              Left err -> do
                putMVar ready (Left err)
                putMVar result (Left err)
              Right connection -> do
                value <- try @SomeException $ bracket (pure connection) C.release \writer -> do
                  putMVar ready (Right ())
                  takeMVar gate
                  fmap concat $ forM [1 .. txCount] \i -> do
                    script writer ("BEGIN; " <> anchorSql)
                    if i `mod` 10 == 0
                      then script writer "ROLLBACK;" >> pure []
                      else do
                        (elapsed, ()) <- timed (script writer "COMMIT;")
                        pure [elapsed]
                putMVar result value
          pure result
        replicateM_ width (takeMVar ready >>= either (fail . show) pure)
        forM_ gates (`putMVar` ())
        times <- concat <$> mapM (\result -> takeMVar result >>= either (fail . show) pure) results
        end <- getMonotonicTimeNSec
        let committed = width * (txCount - txCount `div` 10)
        actual <- query conn ("SELECT count(*) FROM en_grant_generation WHERE generation >= " <> showT count) integerResult
        headValue <- query conn "SELECT generation FROM en_grant_generation_head" integerResult
        ensure (actual == if enabled then fromIntegral committed else 0) (name <> ": generation count/rollback failure")
        ensure (headValue == count - 1 + if enabled then fromIntegral committed else 0) (name <> ": head discontinuity")
        anchors <- query conn "SELECT count(*) FROM en_transaction" integerResult
        matched <- query conn "SELECT count(*) FROM en_transaction t JOIN en_grant_generation g ON g.created_xid=t.xid" integerResult
        ensure (anchors == fromIntegral committed && matched == if enabled then anchors else 0) (name <> ": committed XID/generation bijection failed")
        -- Unique XIDs, matching anchors, row count and head establish exactly one
        -- contiguous counter per commit, with no rows from rolled-back XIDs.
        pure (times, fromIntegral (end - start) / 1000000)
  _ <- runRound
  results <- replicateM rounds runRound
  script conn "ALTER TABLE en_transaction ENABLE TRIGGER en_transaction_grant_generation;"
  let commits = concatMap fst results
      durations = map snd results
      committed = length commits
      cell =
        Cell
          name
          commits
          ( object
              [ "fixture" .= ("transactional" :: String),
                "trigger" .= (if enabled then "production" else "disabled-counterfactual" :: String),
                "history" .= count,
                "concurrency" .= width,
                "committed" .= committed,
                "rollbacks" .= (rounds * width * (txCount `div` 10)),
                "workloadSamplesMs" .= durations,
                "writesPerSecond" .= (fromIntegral committed * 1000 / sum durations :: Double)
              ]
          )
          []
  render cell
  pure cell

pruneCell :: C.Connection -> Int64 -> IO Cell
pruneCell conn count = do
  seed conn count
  let horizon = fromIntegral (seedBase + count)
      prune = session conn (pruneGrantGenerationsBatchSession horizon 1000)
      loop acc total = do
        (elapsed, removed) <- timed prune
        ensure (removed >= 0 && removed <= 1000) "pruning exceeded batch bound"
        if removed == 0 then pure (reverse (elapsed : acc), total) else loop (elapsed : acc) (total + removed)
  (raw, removed) <- loop [] 0
  ensure (removed == count - 1) "pruning lost floor or failed to drain"
  survivors <- query conn "SELECT count(*) FROM en_grant_generation" integerResult
  ensure (survivors == 1) "pruning survivor count"
  actual <- session conn (grantGenerationAtSession (Revision (snapshotAt (count - 1))))
  ensure (fmap grantGenerationText actual == Just ("gg1_" <> showT (count - 1))) "pruned floor lookup failed"
  -- EXPLAIN DELETE executes mutations. Reset a separate run, and sample the
  -- first, midpoint and empty plan without changing the latency run's counts.
  seed conn count
  let prunePlan = session conn (S.statement (showT horizon, 1000 :: Int64) (Q.preparable ("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " <> pruneGrantGenerationsSql) ((fst >$< E.param (E.nonNullable E.text)) <> (snd >$< E.param (E.nonNullable E.int8))) jsonResult))
  firstPlan <- prunePlan
  replicateM_ (max 0 (fromIntegral count `div` 2000 - 1)) prune
  middlePlan <- prunePlan
  let drain = prune >>= \n -> when (n > 0) drain
  drain
  emptyPlan <- prunePlan
  let cell =
        Cell
          ("prune/" <> show count)
          raw
          ( object
              [ "fixture" .= ("synthetic-prefix" :: String),
                "history" .= count,
                "batch" .= (1000 :: Int),
                "removed" .= removed,
                "survivors" .= survivors,
                "floor" .= (count - 1),
                "statements" .= length raw,
                "firstMs" .= firstValue raw,
                "finalEmptyMs" .= last raw,
                "planStats" .= map planStats [firstPlan, middlePlan, emptyPlan]
              ]
          )
          [firstPlan, middlePlan, emptyPlan]
  render cell
  pure cell

mixedPruningCheck :: C.Connection -> IO ()
mixedPruningCheck conn = do
  script conn "TRUNCATE en_grant_generation; INSERT INTO en_grant_generation VALUES (0,'10'),(2,'50'),(3,'20'),(8,'100'),(9,'80');"
  removed <- session conn (pruneGrantGenerationsBatchSession 60 1000)
  keys <- query conn "SELECT string_agg(generation::text,',' ORDER BY generation) FROM en_grant_generation" textResult
  ensure (removed == 2 && keys == "3,8,9") "mixed/reordered-XID horizon did not preserve floor and above-horizon rows"

ensure :: Bool -> String -> IO ()
ensure condition message = unless condition (fail message)

timed :: IO a -> IO (Double, a)
timed action = do
  start <- getMonotonicTimeNSec
  result <- action
  end <- getMonotonicTimeNSec
  pure (fromIntegral (end - start) / 1000000, result)

measured :: Int -> IO a -> IO [Double]
measured n action = do
  _ <- action
  replicateM n (fst <$> timed action)

firstValue :: (Num a) => [a] -> a
firstValue [] = 0
firstValue (value : _) = value

percentile :: Double -> [Double] -> Double
percentile _ [] = 0
percentile quantile values = sort values !! max 0 (ceiling (quantile * fromIntegral (length values)) - 1)

field :: Key -> Value -> Value
field name (Object fields) = maybe Null id (KM.lookup name fields)
field _ _ = Null

number :: Value -> Double
number (Number n) = realToFrac n
number _ = 0

planNodes :: Value -> [Value]
planNodes (Array values) = concatMap planNodes (V.toList values)
planNodes value@(Object _) = value : concatMap planNodes [field "Plan" value, field "Plans" value]
planNodes _ = []

planStats :: Value -> Value
planStats plan =
  object
    [ "indexSeeks" .= seeks,
      "iterations" .= iterations,
      "rowsRemovedByFilter" .= sum [number (field "Rows Removed by Filter" n) * number (field "Actual Loops" n) | n <- nodes],
      "sharedHits" .= number (field "Shared Hit Blocks" root),
      "sharedReads" .= number (field "Shared Read Blocks" root),
      "operators" .= map (field "Node Type") nodes
    ]
  where
    nodes = filter ((/= Null) . field "Node Type") (planNodes plan)
    root = case nodes of n : _ -> n; _ -> Null
    seeks = sum [number (field "Actual Loops" n) | n <- nodes, field "Node Type" n `elem` [String "Index Scan", String "Index Only Scan"]]
    iterations = maximum (0 : [number (field "Actual Loops" n) | n <- nodes, field "Node Type" n == String "WorkTable Scan"])

render :: Cell -> IO ()
render cell =
  putStrLn
    ( key cell
        <> " samples="
        <> show (length (samplesMs cell))
        <> " p50_ms="
        <> show (percentile 0.5 (samplesMs cell))
        <> " p95_ms="
        <> show (percentile 0.95 (samplesMs cell))
        <> extra
    )
  where
    d = details cell
    value name = show (field name d)
    stats = field "planStats" d
    extra
      | take 5 (key cell) == "read/" =
          " fixture=synthetic-prefix expected="
            <> value "expected"
            <> " actual="
            <> value "actual"
            <> " rows_removed="
            <> show (field "rowsRemovedByFilter" stats)
            <> " shared_hits="
            <> show (field "sharedHits" stats)
            <> " shared_reads="
            <> show (field "sharedReads" stats)
            <> " iterations="
            <> show (field "iterations" stats)
            <> " index_seeks="
            <> show (field "indexSeeks" stats)
            <> " operator="
            <> show (field "operators" stats)
      | take 6 (key cell) == "write/" =
          " fixture=transactional trigger="
            <> value "trigger"
            <> " committed="
            <> value "committed"
            <> " rollbacks="
            <> value "rollbacks"
            <> " writes_per_second="
            <> value "writesPerSecond"
      | otherwise =
          " fixture=synthetic-prefix removed="
            <> value "removed"
            <> " survivors="
            <> value "survivors"
            <> " floor="
            <> value "floor"
            <> " first_ms="
            <> value "firstMs"
            <> " final_empty_ms="
            <> value "finalEmptyMs"
            <> " statements="
            <> value "statements"
            <> " buffer_curve="
            <> show (case field "planStats" d of Array xs -> map (field "sharedHits") (V.toList xs); _ -> [])

-- Integer arithmetic proves the span bound even next to Int64's maximum.
spanBound :: Int64 -> Int
spanBound size = go 0 (1 :: Integer)
  where
    go n power
      | power >= toInteger size = n + 1
      | otherwise = go (n + 1) (power * 2)

limits :: Bool -> Cell -> [String]
limits smokeMode cell
  | take 5 (key cell) /= "read/" = []
  | otherwise = seekErrors <> shapeErrors <> latencyErrors
  where
    largeHistory = number (field "rowCount" (details cell)) > 1000
    stats = field "planStats" (details cell)
    spanSize = case fromJSON (field "numericSpan" (details cell)) of Success value -> value; Error _ -> 0 :: Int64
    bound = spanBound spanSize
    iterations = number (field "iterations" stats)
    seeks = number (field "indexSeeks" stats)
    seekErrors = [key cell <> ": iterations/seeks exceed numeric span bound: " <> show (iterations, seeks, bound) | iterations > fromIntegral bound || seeks > fromIntegral (2 * bound + 4) || (largeHistory && number (field "rowsRemovedByFilter" stats) > fromIntegral (33 + 2 * bound))]
    shapeErrors = [key cell <> ": unbounded scan/sort in lookup plan" | largeHistory, any (\n -> field "Node Type" n `elem` [String "Seq Scan", String "Sort"] && number (field "Actual Rows" n) * number (field "Actual Loops" n) > 64) (concatMap planNodes (plans cell))]
    limit = if any (`isSuffix` key cell) ["/head", "/distance32"] then 5 else 25
    latencyErrors = [key cell <> ": p95 " <> show p95 <> " ms exceeds " <> show limit | not smokeMode && field "rowCount" (details cell) == toJSON (1000000 :: Int64) && p95 >= limit]
    p95 = percentile 0.95 (samplesMs cell)
    isSuffix suffix value = reverse suffix == take (length suffix) (reverse value)

doublingErrors :: Bool -> [Cell] -> [String]
doublingErrors small allCells = concatMap check ["midpoint", "floor"]
  where
    sizes = if small then (5000, 10000) else (500000, 1000000) :: (Int, Int)
    iterations n label = [number (field "iterations" (field "planStats" (details cell))) | cell <- allCells, key cell == "read/dense/" <> show n <> "/" <> label]
    check label = case (iterations (fst sizes) label, iterations (snd sizes) label) of
      ([a], [b]) -> ["dense doubling added more than one iteration: " <> show (label, a, b) | b > a + 1]
      _ -> ["incomplete dense doubling fixture: " <> label]

renderComparison :: Report -> Report -> IO ()
renderComparison after before = forM_ (cells after) \cell ->
  case filter ((== key cell) . key) (cells before) of
    [old] ->
      putStrLn
        ( "delta "
            <> key cell
            <> " p95_ms="
            <> show (percentile 0.95 (samplesMs old))
            <> " -> "
            <> show (percentile 0.95 (samplesMs cell))
            <> " throughput="
            <> show (field "writesPerSecond" (details old), field "writesPerSecond" (details cell))
            <> " storage="
            <> show (field "storage" (details old), field "storage" (details cell))
            <> " buffers="
            <> show (field "sharedHits" (field "planStats" (details old)), field "sharedHits" (field "planStats" (details cell)))
        )
    _ -> pure ()

compareReports :: Report -> Report -> [String]
compareReports after before = validity <> concatMap compareCell (cells after)
  where
    validity = ["incompatible/incomplete baseline artifact" | version before /= version after || not (complete before && correctness before) || environment before /= environment after || policy before /= policy after || map key (cells before) /= map key (cells after) || any incompleteCell (cells before)]
    compareCell cell = case filter ((== key cell) . key) (cells before) of
      [old] ->
        let a = percentile 0.95 (samplesMs cell); b = percentile 0.95 (samplesMs old)
         in [key cell <> ": correctness/fixture mismatch" | any (\name -> field name (details old) /= field name (details cell)) ["fixture", "snapshot", "expected", "actual", "rowCount", "numericSpan", "committed", "rollbacks", "trigger", "removed", "survivors", "floor"]]
              <> [key cell <> ": p95 regression " <> show b <> " -> " <> show a <> " ms (>25%)" | a > b * 1.25]
              <> [key cell <> ": workload p95 regression (>25%)" | let oldWork = field "workloadSamplesMs" (details old); newWork = field "workloadSamplesMs" (details cell), workP95 newWork > 1.25 * workP95 oldWork]
      _ -> ["missing/duplicate scenario: " <> key cell]
    incompleteCell cell = null (samplesMs cell) || length (samplesMs cell) /= expectedSamples cell
    expectedSamples cell
      | take 5 (key cell) == "read/" = round (number (field "readSamples" (policy before)))
      | take 6 (key cell) == "write/" = round (number (field "committed" (details cell)))
      | take 6 (key cell) == "prune/" = round (number (field "statements" (details cell)))
      | otherwise = 0
    workP95 (Array values) = percentile 0.95 (map number (V.toList values))
    workP95 _ = 0

command :: String -> [String] -> IO String
command executable args = do
  result <- try @SomeException (readProcessWithExitCode executable args "")
  pure case result of Right (ExitSuccess, value, _) -> value; _ -> "unavailable"

sourceInfo :: IO Value
sourceInfo = do
  revision <- command "git" ["rev-parse", "HEAD"]
  dirty <- command "git" ["status", "--porcelain"]
  pure (object ["revision" .= revision, "dirty" .= not (null dirty)])

environmentInfo :: C.Connection -> IO Value
environmentInfo conn = do
  host <- command "hostname" []
  cpu <- command "sysctl" ["-n", "machdep.cpu.brand_string"]
  operatingSystem <- command "uname" ["-sr"]
  database <- query conn "SELECT json_build_object('version',version(),'settings',(SELECT json_object_agg(name,setting) FROM pg_settings WHERE name IN ('shared_buffers','work_mem','synchronous_commit','fsync','full_page_writes','max_connections','jit','random_page_cost','effective_cache_size')))" jsonResult
  pure (object ["host" .= host, "cpu" .= cpu, "os" .= operatingSystem, "architecture" .= arch, "platform" .= os, "compiler" .= (compilerName <> "-" <> showVersion compilerVersion), "postgresql" .= database])
