-- | Request correlation and structured request logging for @en-server@.
--
-- Two middlewares. 'requestIdMiddleware' gives every request an id, echoed to the client
-- in @X-Request-Id@ as a client-facing diagnostic affordance. 'newRequestLogger' emits
-- exactly one bounded JSON object per handled request and correlates it with the active
-- server span when telemetry is enabled.
--
-- Both are hand-rolled rather than taken from @wai-extra@'s 'RequestLogger'. Its
-- @formatAsJSON@ serializes every request header and redacts only @Cookie@, which would
-- write each caller's @Authorization: Bearer \<secret\>@ to stdout on every request; and
-- its @CustomOutputFormatWithDetails@ carrier buffers the whole request body and
-- accumulates the entire response into an @IORef Builder@ before responding. Neither is
-- acceptable on an authorization hot path, and neither is configurable away. What is
-- actually wanted here — time, method, path, status, duration, user agent, and trace
-- correlation — is the function below.
--
-- In tenant mode the line also names the tenant and the caller, and 'tenantSpanMiddleware'
-- puts the tenant on the server span. Legacy mode's line is unchanged
-- (docs/plans/75-carry-the-tenant-through-logs-metrics-traces-and-readiness.md).
module Observability
  ( requestIdHeaderName,
    requestIdMiddleware,
    newRequestLogger,
    tenantSpanMiddleware,
    tenantSpanAttribute,
  )
where

import Control.Concurrent.MVar (newMVar, withMVar)
import Data.Aeson (Value, encode, object, (.=))
import Data.Aeson.Types (Pair)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy.Char8 qualified as LazyChar8
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID.V4
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Network.HTTP.Types (HeaderName, Status (..), hUserAgent)
import Network.Wai (Middleware, Request (..), mapResponseHeaders, responseStatus)
import OpenTelemetry.Context qualified as OTel.Context
import OpenTelemetry.Instrumentation.Wai (requestContext)
import OpenTelemetry.Trace.Core qualified as OTel
import OpenTelemetry.Trace.Id (Base (Base16), spanIdBaseEncodedText, traceIdBaseEncodedText)
import Servant.Health.Paths qualified as Health
import System.IO (stdout)

-- | Correlation id, accepted from an upstream proxy or minted here.
requestIdHeaderName :: HeaderName
requestIdHeaderName = "X-Request-Id"

-- | Probes fire every few seconds and would drown the log. They are also the two
-- paths with nothing to correlate.
defaultRequestLogPredicate :: Request -> Bool
defaultRequestLogPredicate request =
  rawPathInfo request `notElem` Health.healthRawPaths

-- | Attach a request id to the request (for the logger and handlers) and to the
-- response (for the client).
--
-- An inbound @X-Request-Id@ is reused so a diagnostic token survives a reverse proxy,
-- but only after 'sanitizeRequestId' vets it: the value is reflected in the response
-- header, so control characters and unbounded input are not accepted. A rejected value
-- is replaced, not an error — the request itself is fine.
requestIdMiddleware :: Middleware
requestIdMiddleware inner request respond = do
  requestId <-
    case sanitizeRequestId =<< lookup requestIdHeaderName (requestHeaders request) of
      Just supplied -> pure supplied
      Nothing -> UUID.toASCIIBytes <$> UUID.V4.nextRandom
  let tagged =
        request
          { requestHeaders =
              (requestIdHeaderName, requestId)
                : filter ((/= requestIdHeaderName) . fst) (requestHeaders request)
          }
  inner tagged (respond . mapResponseHeaders ((requestIdHeaderName, requestId) :))

-- | Accept a bounded run of printable, non-space ASCII. This admits the usual
-- opaque tokens (UUIDs, hex, base64url) and excludes control characters — notably
-- @\\r@ and @\\n@ — and unbounded values.
sanitizeRequestId :: ByteString -> Maybe ByteString
sanitizeRequestId value
  | ByteString.null value = Nothing
  | ByteString.length value > 128 = Nothing
  | ByteString.all printableAscii value = Just value
  | otherwise = Nothing
  where
    printableAscii byte = byte > 0x20 && byte < 0x7F

-- | One JSON line per handled request, on stdout.
--
-- The lock is created once, for the process; the result specializes the middleware per
-- stack. With no tenant (legacy mode) the line is exactly what it has always been. With a
-- tenant, the line gains @tenant@ and @caller@, the caller read from the @X-En-Caller@
-- header authentication set (a client-supplied value never survives authentication). The
-- tenant's fields are built once here, not per request.
--
-- The 'MVar' serializes writes: two concurrent requests completing together would
-- otherwise interleave inside a single 'ByteString' write. Duration is measured on the
-- monotonic clock, so an NTP step cannot produce a negative latency.
newRequestLogger :: IO (Maybe Text.Text -> Middleware)
newRequestLogger = do
  lock <- newMVar ()
  pure \tenant ->
    let identity = case tenant of
          Nothing -> const []
          Just name -> \request ->
            [ "tenant" .= name,
              "caller" .= (Text.decodeUtf8Lenient <$> lookup callerHeaderName (requestHeaders request))
            ]
     in \inner request respond ->
          if defaultRequestLogPredicate request
            then do
              start <- getMonotonicTimeNSec
              inner request \response -> do
                received <- respond response
                end <- getMonotonicTimeNSec
                now <- getCurrentTime
                correlation <- correlationFields request
                let line =
                      logLine
                        (Text.pack (iso8601Show now))
                        request
                        (responseStatus response)
                        (end - start)
                        (identity request <> correlation)
                withMVar lock \() ->
                  LazyChar8.hPutStrLn stdout (encode line)
                pure received
            else inner request respond

-- | Set by authentication to the verified key's name; see "Middleware".
callerHeaderName :: HeaderName
callerHeaderName = "X-En-Caller"

-- | The shape every en-server request log line takes.
logLine :: Text.Text -> Request -> Status -> Word64 -> [Pair] -> Value
logLine timestamp request status elapsedNs extra =
  object $
    [ "time" .= timestamp,
      "method" .= decode (requestMethod request),
      "path" .= decode (rawPathInfo request),
      "status" .= statusCode status,
      "duration_ms" .= (fromIntegral elapsedNs / 1e6 :: Double),
      "user_agent" .= (decode <$> lookup hUserAgent (requestHeaders request))
    ]
      <> extra
  where
    decode = Text.decodeUtf8Lenient

-- | The span attribute that names the tenant a request was served for.
tenantSpanAttribute :: Text.Text
tenantSpanAttribute = "en.tenant"

-- | Put the tenant on the request's server span, when telemetry created one. With
-- telemetry disabled there is no span and this only passes the request on.
tenantSpanMiddleware :: Text.Text -> Middleware
tenantSpanMiddleware tenant inner request respond = do
  case requestContext request >>= OTel.Context.lookupSpan of
    Nothing -> pure ()
    Just span' -> OTel.addAttribute span' tenantSpanAttribute tenant
  inner request respond

-- | Correlate a log line only with a valid server span. Invalid contexts have all-zero
-- identifiers and would look joinable while pointing to no exported trace.
correlationFields :: Request -> IO [Pair]
correlationFields request =
  case requestContext request >>= OTel.Context.lookupSpan of
    Nothing -> pure []
    Just span' -> do
      context <- OTel.getSpanContext span'
      pure
        if OTel.isValid context
          then
            [ "trace_id" .= traceIdBaseEncodedText Base16 (OTel.traceId context),
              "span_id" .= spanIdBaseEncodedText Base16 (OTel.spanId context)
            ]
          else []
