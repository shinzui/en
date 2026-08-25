-- | Prometheus metrics for @en-server@.
--
-- A recording middleware ('metricsMiddleware') that counts requests and accumulates
-- latency, a scrape route ('metricsRoute') that renders them, and the engine's cache
-- counters read live at scrape time.
--
-- Hand-rolled rather than built on @prometheus-client@ + @wai-middleware-prometheus@:
-- the surface needed is monotonic counters and a latency sum\/count per label pair, the
-- text exposition format is a dozen lines of rendering, and the cache counters already
-- live in "En.Cache" — a client library would have to shadow them in its own registry.
-- If histograms or quantiles are ever wanted, @prometheus-client@ is the upgrade path.
--
-- @\/metrics@ is not exempt from authentication: a scraper presents a read-only bearer
-- key like any other caller.
module Metrics
  ( Metrics,
    newMetrics,
    metricsMiddleware,
    metricsRoute,
  )
where

import Data.ByteString.Builder (Builder, byteString, intDec, string7, toLazyByteString)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text.Encoding qualified as Text
import Data.Word (Word64)
-- Fields imported, not just the type: @En.Cache@ sets NoFieldSelectors, so the
-- @HasField@ instances behind @stats.hits@ exist only where the names are in scope.
import En.Cache (CacheStats (..))
import GHC.Clock (getMonotonicTimeNSec)
import Network.HTTP.Types (Status (..), hContentType, methodGet, status200)
import Network.Wai (Middleware, Request (..), responseLBS, responseStatus)
import Numeric (showFFloat)

data RequestStats = RequestStats
  { count :: !Int,
    totalDurationNs :: !Word64
  }

-- | Counters keyed by (path group, status class). Both label values are drawn from
-- fixed sets, so the series count is bounded no matter what a caller requests.
newtype Metrics = Metrics (IORef (Map (Text, Text) RequestStats))

newMetrics :: IO Metrics
newMetrics = Metrics <$> newIORef Map.empty

-- | Count each request and add its latency to the running total for its labels.
metricsMiddleware :: Metrics -> Middleware
metricsMiddleware (Metrics ref) inner request respond = do
  start <- getMonotonicTimeNSec
  inner request \response -> do
    received <- respond response
    end <- getMonotonicTimeNSec
    let key = (pathGroup request, statusClass (responseStatus response))
        observation = RequestStats {count = 1, totalDurationNs = end - start}
    atomicModifyIORef' ref \stats ->
      (Map.insertWith mergeStats key observation stats, ())
    pure received
  where
    mergeStats new old =
      RequestStats
        { count = old.count + new.count,
          totalDurationNs = old.totalDurationNs + new.totalDurationNs
        }

-- | Serve @GET \/metrics@ in the Prometheus text exposition format.
--
-- Cache statistics are read at scrape time rather than mirrored into 'Metrics', so
-- there is exactly one copy of each counter.
metricsRoute :: Metrics -> [(Text, IO CacheStats)] -> Middleware
metricsRoute (Metrics ref) caches inner request respond
  | requestMethod request == methodGet,
    pathInfo request == ["metrics"] = do
      requests <- readIORef ref
      cacheStats <- traverse (\(name, readStats) -> (,) name <$> readStats) caches
      respond $
        responseLBS
          status200
          [(hContentType, "text/plain; version=0.0.4; charset=utf-8")]
          (toLazyByteString (render requests cacheStats))
  | otherwise = inner request respond

-- | The first path segment below any version prefix, restricted to the routes en
-- actually serves. An unrecognized path becomes @other@ — without this, a caller could
-- mint an unbounded number of time series by requesting random paths that 404.
pathGroup :: Request -> Text
pathGroup request =
  case dropVersion (pathInfo request) of
    segment : _ | Set.member segment knownPaths -> segment
    _ -> "other"
  where
    dropVersion ("v1" : rest) = rest
    dropVersion path = path

knownPaths :: Set.Set Text
knownPaths =
  Set.fromList
    [ "batch-check",
      "check",
      "expand",
      "healthz",
      "lookup",
      "metrics",
      "openapi.json",
      "readyz",
      "relationships"
    ]

statusClass :: Status -> Text
statusClass status =
  case status.statusCode `div` 100 of
    1 -> "1xx"
    2 -> "2xx"
    3 -> "3xx"
    4 -> "4xx"
    5 -> "5xx"
    _ -> "other"

render :: Map (Text, Text) RequestStats -> [(Text, CacheStats)] -> Builder
render requests caches =
  mconcat
    [ family
        "en_http_requests_total"
        "Total HTTP requests handled, by path group and status class."
        [(requestLabels labels, intDec stats.count) | (labels, stats) <- observations],
      family
        "en_http_request_duration_seconds_sum"
        "Total time spent handling HTTP requests, in seconds."
        [(requestLabels labels, seconds stats.totalDurationNs) | (labels, stats) <- observations],
      family
        "en_http_request_duration_seconds_count"
        "Number of HTTP request durations observed."
        [(requestLabels labels, intDec stats.count) | (labels, stats) <- observations],
      cacheFamily "en_cache_hits_total" "Cache lookups served from the cache." (.hits),
      cacheFamily "en_cache_misses_total" "Cache lookups that fell through to the store." (.misses),
      cacheFamily "en_cache_inserts_total" "Entries written into the cache." (.inserts),
      cacheFamily "en_cache_evictions_total" "Entries evicted from the cache." (.evictions)
    ]
  where
    observations = Map.toList requests
    requestLabels (path, status) = [("path", path), ("status", status)]
    cacheFamily name description field =
      family
        name
        description
        [([("cache", cache)], intDec (field stats)) | (cache, stats) <- caches]

-- | A @# HELP@\/@# TYPE@ header followed by its samples. Prometheus requires every
-- sample of a family to be contiguous and the family to be declared once, so the header
-- is emitted even when there are no samples yet.
family :: Builder -> Builder -> [([(Text, Text)], Builder)] -> Builder
family name description samples =
  "# HELP "
    <> name
    <> " "
    <> description
    <> "\n# TYPE "
    <> name
    <> " counter\n"
    <> foldMap sample samples
  where
    sample (labels, value) =
      name <> renderLabels labels <> " " <> value <> "\n"

-- | Label values here are drawn from fixed sets ('knownPaths', 'statusClass', and the
-- cache names @Main@ passes), so none can contain a quote, backslash, or newline and no
-- escaping is required.
renderLabels :: [(Text, Text)] -> Builder
renderLabels [] = mempty
renderLabels labels =
  "{" <> mconcat (intersperseCommas (map renderLabel labels)) <> "}"
  where
    renderLabel (name, value) = text name <> "=\"" <> text value <> "\""
    intersperseCommas [] = []
    intersperseCommas (x : xs) = x : concatMap (\y -> [",", y]) xs

text :: Text -> Builder
text = byteString . Text.encodeUtf8

seconds :: Word64 -> Builder
seconds nanoseconds =
  string7 (showFFloat (Just 6) (fromIntegral nanoseconds / 1e9 :: Double) "")
