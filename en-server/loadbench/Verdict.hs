{-# LANGUAGE OverloadedRecordDot #-}

-- | The A/B verdict rule.
--
-- This rule is an interface: the gates of
-- docs/masterplans/12-serve-several-isolated-tenants-from-one-en-server.md quote it.
--
-- For each workload and each of three metrics (throughput, p50, p99), take the median over
-- rounds for each binary. The noise of a metric is the larger, over the two binaries, of
-- @(max - min) / median@ across that binary's rounds. The tolerance is the larger of the
-- noise and a floor: 3% for throughput and p50, 10% for p99. The workload is a REGRESSION
-- if the candidate's median throughput is below the baseline's by more than the
-- tolerance, or its median p50 or p99 is above the baseline's by more than the tolerance;
-- otherwise it is a PASS.
module Verdict
  ( Metric (..),
    metricName,
    metricOf,
    allMetrics,
    MetricComparison (..),
    compareMetric,
    WorkloadVerdict (..),
    verdictFor,
    median,
    spread,
  )
where

import Data.Aeson (ToJSON)
import Data.List (sort)
import Data.Text (Text)
import GHC.Generics (Generic)
import Workload (WorkloadResult (..))

data Metric = Throughput | P50 | P99
  deriving stock (Eq, Show, Enum, Bounded)

allMetrics :: [Metric]
allMetrics = [minBound .. maxBound]

metricName :: Metric -> Text
metricName = \case
  Throughput -> "req/s"
  P50 -> "p50_ms"
  P99 -> "p99_ms"

metricOf :: Metric -> WorkloadResult -> Double
metricOf = \case
  Throughput -> requestsPerSecond
  P50 -> p50Ms
  P99 -> p99Ms

floorFor :: Metric -> Double
floorFor = \case
  Throughput -> 0.03
  P50 -> 0.03
  P99 -> 0.10

data MetricComparison = MetricComparison
  { metric :: !Text,
    baselineMedian :: !Double,
    candidateMedian :: !Double,
    -- | @(candidate - baseline) / baseline@.
    delta :: !Double,
    noise :: !Double,
    tolerance :: !Double,
    regression :: !Bool
  }
  deriving stock (Generic, Show)
  deriving anyclass (ToJSON)

compareMetric :: Metric -> [Double] -> [Double] -> MetricComparison
compareMetric which baselineRounds candidateRounds =
  MetricComparison
    { metric = metricName which,
      baselineMedian = base,
      candidateMedian = cand,
      delta,
      noise,
      tolerance,
      regression
    }
  where
    base = median baselineRounds
    cand = median candidateRounds
    delta = if base == 0 then 0 else (cand - base) / base
    noise = max (spread baselineRounds) (spread candidateRounds)
    tolerance = max noise (floorFor which)
    regression = case which of
      Throughput -> cand < base * (1 - tolerance)
      _ -> cand > base * (1 + tolerance)

data WorkloadVerdict = WorkloadVerdict
  { workload :: !Text,
    comparisons :: ![MetricComparison],
    passed :: !Bool
  }
  deriving stock (Generic, Show)
  deriving anyclass (ToJSON)

-- | Compare one workload's rounds; each list holds that binary's result per round.
verdictFor :: Text -> [WorkloadResult] -> [WorkloadResult] -> WorkloadVerdict
verdictFor name baselineRounds candidateRounds =
  WorkloadVerdict
    { workload = name,
      comparisons,
      passed = not (any (\c -> c.regression) comparisons)
    }
  where
    comparisons =
      [ compareMetric which (map (metricOf which) baselineRounds) (map (metricOf which) candidateRounds)
      | which <- allMetrics
      ]

-- | The middle value; the mean of the middle two for an even count.
median :: [Double] -> Double
median values =
  case sort values of
    [] -> 0
    sorted ->
      let n = length sorted
       in if odd n
            then sorted !! (n `div` 2)
            else (sorted !! (n `div` 2 - 1) + sorted !! (n `div` 2)) / 2

-- | @(max - min) / median@: zero for fewer than two rounds.
spread :: [Double] -> Double
spread values
  | length values < 2 = 0
  | median values == 0 = 0
  | otherwise = (maximum values - minimum values) / median values
