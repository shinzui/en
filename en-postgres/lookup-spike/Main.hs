{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE MultilineStrings #-}
{-# LANGUAGE NoFieldSelectors #-}

module Main (main) where

import Control.Exception (bracket)
import Control.Monad (forM)
import Data.Functor.Contravariant ((>$<))
import Data.Generics.Labels ()
import Data.Int (Int64)
import Data.List (sort)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Data.Traversable (for)
import En.Prelude hiding (index)
import EphemeralPg qualified as Pg
import GHC.Clock (getMonotonicTimeNSec)
import Hasql.Connection qualified as Connection
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Errors qualified as Hasql
import Hasql.Session qualified as Session
import Hasql.Statement (Statement)
import Hasql.Statement qualified as Statement
import System.Environment (getArgs)
import Text.Read (readMaybe)

data Scenario = Scenario
  { relationships :: !Int64,
    depth :: !Int64,
    guestSharing :: !Bool,
    shape :: !Text,
    largeReachable :: !Bool
  }
  deriving stock (Eq, Generic, Show)

data LabelStats = LabelStats
  { spaces :: !Int64,
    classes :: !Int64
  }
  deriving stock (Eq, Generic, Show)

data AntiPatternStats = AntiPatternStats
  { rows :: !Int64,
    capped :: !Bool
  }
  deriving stock (Eq, Generic, Show)

data Measurement = Measurement
  { scenario :: !Scenario,
    actualRelationships :: !Int64,
    labelStats :: !LabelStats,
    lookupP50Ms :: !Double,
    lookupP95Ms :: !Double,
    readP50Ms :: !Double,
    readP95Ms :: !Double,
    antiP50Ms :: !Double,
    antiP95Ms :: !Double,
    antiPatternStats :: !AntiPatternStats
  }
  deriving stock (Eq, Generic, Show)

data Timed a = Timed
  { elapsedMs :: !Double,
    value :: !a
  }
  deriving stock (Eq, Generic, Show)

data Percentiles = Percentiles
  { p50 :: !Double,
    p95 :: !Double
  }
  deriving stock (Eq, Generic, Show)

main :: IO ()
main = do
  activityRows <- activityRowsFromArgs
  result <- Pg.with \database ->
    bracket (acquire database) Connection.release \connection -> do
      runScript connection resetSql
      run connection populateActivitiesStatement (activityRows, maxSpaceId)
      measurements <- for scenarios (measureScenario connection)
      Text.putStrLn (renderResults activityRows measurements)
  case result of
    Left err -> fail ("ephemeral-pg failed to start: " <> Text.unpack (Pg.renderStartError err))
    Right () -> pure ()

maxSpaceId :: Int64
maxSpaceId = 20000

sampleRuns :: Int
sampleRuns = 50

antiSampleRuns :: Int
antiSampleRuns = 30

largeReachableSpaces :: Int64
largeReachableSpaces = 1000

scenarios :: [Scenario]
scenarios =
  [ Scenario relationships depth guestSharing shape False
  | relationships <- [1000, 10000, 100000],
    depth <- [1, 3, 6],
    guestSharing <- [False, True],
    shape <- ["union", "intersection-exclusion"]
  ]
    <> [ Scenario 100000 3 True "union" True,
         Scenario 100000 3 True "intersection-exclusion" True
       ]

activityRowsFromArgs :: IO Int64
activityRowsFromArgs = do
  args <- getArgs
  pure $
    case args of
      raw : _ -> maybe 1000000 (max 1) (readMaybe raw)
      [] -> 1000000

measureScenario :: Connection.Connection -> Scenario -> IO Measurement
measureScenario connection scenario = do
  actualRelationships <- run connection populateRelationshipsStatement scenario
  runScript connection analyzeSql
  lookupRuns <- measuredRuns sampleRuns \_ -> run connection (lookupLabelsStatement (scenario ^. #shape)) ()
  readRuns <- measuredRuns sampleRuns \_ -> run connection (readPathStatement (scenario ^. #shape)) ()
  antiRuns <- measuredRuns antiSampleRuns \_ -> run connection (antiPatternStatement (scenario ^. #shape)) ()
  let labelStats = last lookupRuns ^. #value
      antiPatternStats = last antiRuns ^. #value
      Percentiles {p50 = lookupP50Ms, p95 = lookupP95Ms} = percentiles ((view #elapsedMs) <$> lookupRuns)
      Percentiles {p50 = readP50Ms, p95 = readP95Ms} = percentiles ((view #elapsedMs) <$> readRuns)
      Percentiles {p50 = antiP50Ms, p95 = antiP95Ms} = percentiles ((view #elapsedMs) <$> antiRuns)
  pure
    Measurement
      { scenario,
        actualRelationships,
        labelStats,
        lookupP50Ms,
        lookupP95Ms,
        readP50Ms,
        readP95Ms,
        antiP50Ms,
        antiP95Ms,
        antiPatternStats
      }

timedRuns :: Int -> (Int -> IO a) -> IO [Timed a]
timedRuns count action =
  forM [1 .. count] \index -> do
    start <- getMonotonicTimeNSec
    result <- action index
    end <- getMonotonicTimeNSec
    pure Timed {elapsedMs = fromIntegral (end - start) / 1000000, value = result}

measuredRuns :: Int -> (Int -> IO a) -> IO [Timed a]
measuredRuns count action =
  drop 1 <$> timedRuns (count + 1) action

percentiles :: [Double] -> Percentiles
percentiles values =
  let sorted = sort values
   in Percentiles
        { p50 = percentile sorted 0.50,
          p95 = percentile sorted 0.95
        }

percentile :: [Double] -> Double -> Double
percentile [] _ = 0
percentile sorted quantile =
  let index = ceiling (quantile * fromIntegral (length sorted)) - 1
   in sorted !! max 0 (min (length sorted - 1) index)

acquire :: Pg.Database -> IO Connection.Connection
acquire database =
  Connection.acquire (Pg.connectionSettings database) >>= \case
    Right connection -> pure connection
    Left err -> fail ("Could not connect to PostgreSQL: " <> show err)

run :: Connection.Connection -> Statement params result -> params -> IO result
run connection statement params =
  Connection.use connection (Session.statement params statement) >>= \case
    Right result -> pure result
    Left err -> fail ("PostgreSQL statement failed: " <> Text.unpack (Hasql.toDetailedText err))

runScript :: Connection.Connection -> Text -> IO ()
runScript connection sql =
  Connection.use connection (Session.script sql) >>= \case
    Right () -> pure ()
    Left err -> fail ("PostgreSQL script failed: " <> Text.unpack (Hasql.toDetailedText err))

resetSql :: Text
resetSql =
  """
  DROP TABLE IF EXISTS spike_activity_relation_tuple;
  DROP TABLE IF EXISTS spike_activity;
  DROP TABLE IF EXISTS spike_relation_tuple;

  CREATE UNLOGGED TABLE spike_relation_tuple
    ( object_type text NOT NULL
    , object_id bigint NOT NULL
    , relation text NOT NULL
    , subject_type text NOT NULL
    , subject_id bigint NOT NULL
    , subject_relation text NULL
    );

  CREATE UNLOGGED TABLE spike_activity
    ( id bigserial PRIMARY KEY
    , space bigint NOT NULL
    , visibility_class bigint NOT NULL
    , occurred_at timestamptz NOT NULL
    );

  CREATE UNLOGGED TABLE spike_activity_relation_tuple
    ( object_id bigint NOT NULL
    , subject_type text NOT NULL
    , subject_id bigint NOT NULL
    , subject_relation text NOT NULL
    );

  CREATE INDEX spike_relation_subject_idx
    ON spike_relation_tuple (subject_type, subject_id, coalesce(subject_relation, ''), object_type, relation);

  CREATE INDEX spike_relation_object_idx
    ON spike_relation_tuple (object_type, object_id, relation);

  CREATE INDEX spike_activity_filter_idx
    ON spike_activity (space, visibility_class, occurred_at DESC);

  CREATE INDEX spike_activity_relation_subject_idx
    ON spike_activity_relation_tuple (subject_type, subject_id, subject_relation, object_id);
  """

populateActivitiesStatement :: Statement (Int64, Int64) ()
populateActivitiesStatement =
  Statement.preparable
    """
    WITH inserted AS (
      INSERT INTO spike_activity (space, visibility_class, occurred_at)
      SELECT
          ((series - 1) % $2) + 1,
          ((series - 1) % 4) + 1,
          now() - (series || ' seconds')::interval
      FROM generate_series(1, $1) AS series
      RETURNING id, space
    )
    INSERT INTO spike_activity_relation_tuple (object_id, subject_type, subject_id, subject_relation)
    SELECT id, 'space', space, 'view'
    FROM inserted
    """
    ( ((\(activityRows, _) -> activityRows) >$< Encoders.param (Encoders.nonNullable Encoders.int8))
        <> ((\(_, maximumSpaceId) -> maximumSpaceId) >$< Encoders.param (Encoders.nonNullable Encoders.int8))
    )
    Decoders.noResult

populateRelationshipsStatement :: Statement Scenario Int64
populateRelationshipsStatement =
  Statement.preparable
    """
    WITH deleted AS (
      DELETE FROM spike_relation_tuple
    ),
    params AS (
      SELECT
          $1::bigint AS target_relationships,
          greatest(1, $2::bigint) AS requested_depth,
          $3::boolean AS guest_sharing,
          $4::text AS shape,
          $5::boolean AS large_reachable
    ),
    sizes AS (
      SELECT
          target_relationships,
          least($6::bigint, greatest(24::bigint, target_relationships / 5)) AS generated_spaces,
          24::bigint AS hot_spaces,
          least($6::bigint, $7::bigint) AS large_spaces,
          requested_depth,
          greatest(1::bigint, (24 + requested_depth - 1) / requested_depth) AS roots,
          guest_sharing,
          shape,
          large_reachable
      FROM params
    ),
    direct_members AS (
      INSERT INTO spike_relation_tuple
        (object_type, object_id, relation, subject_type, subject_id, subject_relation)
      SELECT 'space', root_id, 'member', 'user', 1, NULL
      FROM sizes, generate_series(1, roots) AS root_id
      RETURNING 1
    ),
    guest_org_member AS (
      INSERT INTO spike_relation_tuple
        (object_type, object_id, relation, subject_type, subject_id, subject_relation)
      SELECT 'org', 1, 'member', 'user', 1, NULL
      FROM sizes
      WHERE guest_sharing
      RETURNING 1
    ),
    guest_spaces AS (
      INSERT INTO spike_relation_tuple
        (object_type, object_id, relation, subject_type, subject_id, subject_relation)
      SELECT 'space', space_id, 'guest_org', 'org', 1, 'member'
      FROM sizes, generate_series(1, hot_spaces) AS space_id
      WHERE guest_sharing
      RETURNING 1
    ),
    parent_edges AS (
      INSERT INTO spike_relation_tuple
        (object_type, object_id, relation, subject_type, subject_id, subject_relation)
      SELECT 'space', child_id, 'parent', 'space', child_id - roots, 'view'
      FROM sizes, generate_series(roots + 1, hot_spaces) AS child_id
      RETURNING 1
    ),
    class_edges AS (
      INSERT INTO spike_relation_tuple
        (object_type, object_id, relation, subject_type, subject_id, subject_relation)
      SELECT 'space', space_id, 'visibility_class', 'visibility_class', class_id, NULL
      FROM sizes,
           generate_series(1, generated_spaces) AS space_id,
           generate_series(1, 4) AS class_id
      RETURNING 1
    ),
    blocked_edges AS (
      INSERT INTO spike_relation_tuple
        (object_type, object_id, relation, subject_type, subject_id, subject_relation)
      SELECT 'space', space_id, 'blocked', 'user', 1, NULL
      FROM sizes, generate_series(1, hot_spaces) AS space_id
      WHERE shape = 'intersection-exclusion'
        AND space_id % 2 = 0
      RETURNING 1
    ),
    large_reachable_edges AS (
      INSERT INTO spike_relation_tuple
        (object_type, object_id, relation, subject_type, subject_id, subject_relation)
      SELECT 'space', space_id, 'member', 'user', 1, NULL
      FROM sizes, generate_series(1, large_spaces) AS space_id
      WHERE large_reachable
      RETURNING 1
    ),
    inserted_count AS (
      SELECT count(*)::bigint AS n FROM direct_members
      UNION ALL SELECT count(*)::bigint FROM guest_org_member
      UNION ALL SELECT count(*)::bigint FROM guest_spaces
      UNION ALL SELECT count(*)::bigint FROM parent_edges
      UNION ALL SELECT count(*)::bigint FROM class_edges
      UNION ALL SELECT count(*)::bigint FROM blocked_edges
      UNION ALL SELECT count(*)::bigint FROM large_reachable_edges
    ),
    filler_budget AS (
      SELECT greatest(0::bigint, target_relationships - sum(n)) AS filler_rows
      FROM sizes, inserted_count
      GROUP BY target_relationships
    ),
    filler_edges AS (
      INSERT INTO spike_relation_tuple
        (object_type, object_id, relation, subject_type, subject_id, subject_relation)
      SELECT
          'space',
          (1000000 + filler_id),
          'member',
          'user',
          (1000000 + filler_id),
          NULL
      FROM filler_budget, generate_series(1, filler_rows) AS filler_id
      RETURNING 1
    )
    SELECT
        ((SELECT coalesce(sum(n), 0)::bigint FROM inserted_count)
      + (SELECT count(*)::bigint FROM filler_edges))::bigint
    """
    ( ((\params -> (params ^. #relationships)) >$< Encoders.param (Encoders.nonNullable Encoders.int8))
        <> ((\params -> (params ^. #depth)) >$< Encoders.param (Encoders.nonNullable Encoders.int8))
        <> ((\params -> (params ^. #guestSharing)) >$< Encoders.param (Encoders.nonNullable Encoders.bool))
        <> ((\params -> (params ^. #shape)) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\params -> (params ^. #largeReachable)) >$< Encoders.param (Encoders.nonNullable Encoders.bool))
        <> ((\_ -> maxSpaceId) >$< Encoders.param (Encoders.nonNullable Encoders.int8))
        <> ((\_ -> largeReachableSpaces) >$< Encoders.param (Encoders.nonNullable Encoders.int8))
    )
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

analyzeSql :: Text
analyzeSql =
  """
  ANALYZE spike_relation_tuple;
  ANALYZE spike_activity;
  ANALYZE spike_activity_relation_tuple;
  """

lookupLabelsStatement :: Text -> Statement () LabelStats
lookupLabelsStatement shape =
  Statement.preparable
    (lookupLabelsSql shape)
    Encoders.noParams
    ( Decoders.singleRow
        ( LabelStats
            <$> Decoders.column (Decoders.nonNullable Decoders.int8)
            <*> Decoders.column (Decoders.nonNullable Decoders.int8)
        )
    )

readPathStatement :: Text -> Statement () Int64
readPathStatement shape =
  Statement.preparable
    ( lookupLabelsCteFor shape
        <> """
           SELECT count(*)::bigint
           FROM (
             SELECT activity.id
             FROM spike_activity activity
             WHERE activity.space IN (SELECT space_id FROM reachable_spaces)
               AND activity.visibility_class IN (SELECT visibility_class FROM reachable_classes)
             ORDER BY activity.occurred_at DESC
             LIMIT 50
           ) page
           """
    )
    Encoders.noParams
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

antiPatternStatement :: Text -> Statement () AntiPatternStats
antiPatternStatement shape =
  Statement.preparable
    ( lookupLabelsCteFor shape
        <> """
           SELECT count(*)::bigint, count(*) = 1001
           FROM (
             SELECT activity_tuple.object_id
             FROM spike_activity_relation_tuple activity_tuple
             JOIN reachable_spaces
               ON reachable_spaces.space_id = activity_tuple.subject_id
             WHERE activity_tuple.subject_type = 'space'
               AND activity_tuple.subject_relation = 'view'
             LIMIT 1001
           ) capped_visible_activities
           """
    )
    Encoders.noParams
    ( Decoders.singleRow
        ( AntiPatternStats
            <$> Decoders.column (Decoders.nonNullable Decoders.int8)
            <*> Decoders.column (Decoders.nonNullable Decoders.bool)
        )
    )

lookupLabelsSql :: Text -> Text
lookupLabelsSql shape =
  lookupLabelsCteFor shape
    <> """
       SELECT
           (SELECT count(*)::bigint FROM reachable_spaces),
           (SELECT count(*)::bigint FROM reachable_classes)
       """

lookupLabelsCteFor :: Text -> Text
lookupLabelsCteFor shape =
  lookupLabelsCte (shape == "intersection-exclusion")

lookupLabelsCte :: Bool -> Text
lookupLabelsCte excludeBlocked =
  """
  WITH RECURSIVE
  direct_spaces(space_id) AS (
    SELECT relation_tuple.object_id
    FROM spike_relation_tuple relation_tuple
    WHERE relation_tuple.object_type = 'space'
      AND relation_tuple.relation = 'member'
      AND relation_tuple.subject_type = 'user'
      AND relation_tuple.subject_id = 1
      AND relation_tuple.subject_relation IS NULL
    UNION
    SELECT relation_tuple.object_id
    FROM spike_relation_tuple relation_tuple
    JOIN spike_relation_tuple membership
      ON membership.object_type = 'org'
     AND membership.object_id = relation_tuple.subject_id
     AND membership.relation = 'member'
     AND membership.subject_type = 'user'
     AND membership.subject_id = 1
    WHERE relation_tuple.object_type = 'space'
      AND relation_tuple.relation = 'guest_org'
      AND relation_tuple.subject_type = 'org'
  ),
  reachable_spaces_raw(space_id) AS (
    SELECT space_id FROM direct_spaces
    UNION
    SELECT child.object_id
    FROM spike_relation_tuple child
    JOIN reachable_spaces_raw parent
      ON parent.space_id = child.subject_id
    WHERE child.object_type = 'space'
      AND child.relation = 'parent'
      AND child.subject_type = 'space'
      AND child.subject_relation = 'view'
  ),
  reachable_spaces(space_id) AS (
    SELECT raw.space_id
    FROM reachable_spaces_raw raw
  """
    <> blockedFilter
    <> """
       ),
       reachable_classes(visibility_class) AS (
         SELECT DISTINCT class_edge.subject_id
         FROM spike_relation_tuple class_edge
         JOIN reachable_spaces
           ON reachable_spaces.space_id = class_edge.object_id
         WHERE class_edge.object_type = 'space'
           AND class_edge.relation = 'visibility_class'
           AND class_edge.subject_type = 'visibility_class'
       )
       """
  where
    blockedFilter
      | excludeBlocked =
          """

          WHERE NOT EXISTS (
            SELECT 1
            FROM spike_relation_tuple blocked
            WHERE blocked.object_type = 'space'
              AND blocked.object_id = raw.space_id
              AND blocked.relation = 'blocked'
              AND blocked.subject_type = 'user'
              AND blocked.subject_id = 1
              AND blocked.subject_relation IS NULL
          )
          """
      | otherwise = ""

renderResults :: Int64 -> [Measurement] -> Text
renderResults activityRows measurements =
  Text.unlines $
    [ "# en lookup spike results",
      "",
      "Activity rows: " <> showText activityRows <> ". Activity relation rows for the anti-pattern: " <> showText activityRows <> ".",
      "",
      "| relationships | depth | guest | shape | large reachable | actual tuples | spaces | classes | lookup p50 ms | lookup p95 ms | read p50 ms | read p95 ms | anti p50 ms | anti p95 ms | anti capped |",
      "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"
    ]
      <> fmap renderMeasurement measurements

renderMeasurement :: Measurement -> Text
renderMeasurement measurement =
  let Scenario {relationships, depth, guestSharing, shape, largeReachable} = (measurement ^. #scenario)
      LabelStats {spaces, classes} = (measurement ^. #labelStats)
      AntiPatternStats {capped} = (measurement ^. #antiPatternStats)
   in Text.intercalate
        " | "
        [ "| " <> showText relationships,
          showText depth,
          boolText guestSharing,
          shape,
          boolText largeReachable,
          showText (measurement ^. #actualRelationships),
          showText spaces,
          showText classes,
          fixed (measurement ^. #lookupP50Ms),
          fixed (measurement ^. #lookupP95Ms),
          fixed (measurement ^. #readP50Ms),
          fixed (measurement ^. #readP95Ms),
          fixed (measurement ^. #antiP50Ms),
          fixed (measurement ^. #antiP95Ms),
          boolText capped <> " |"
        ]

showText :: (Show a) => a -> Text
showText =
  Text.pack . show

boolText :: Bool -> Text
boolText True = "true"
boolText False = "false"

fixed :: Double -> Text
fixed value =
  Text.pack (show rounded)
  where
    rounded :: Double
    rounded = fromIntegral (round (value * 100) :: Int64) / 100
