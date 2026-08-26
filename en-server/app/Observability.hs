-- | Request correlation and structured request logging for @en-server@.
--
-- Two middlewares. 'requestIdMiddleware' gives every request an id, echoed to the client
-- in @X-Request-Id@ so a client's error report can be matched against a server log line.
-- 'newRequestLogger' emits exactly one JSON object per handled request.
--
-- Both are hand-rolled rather than taken from @wai-extra@'s 'RequestLogger'. Its
-- @formatAsJSON@ serializes every request header and redacts only @Cookie@, which would
-- write each caller's @Authorization: Bearer \<secret\>@ to stdout on every request; and
-- its @CustomOutputFormatWithDetails@ carrier buffers the whole request body and
-- accumulates the entire response into an @IORef Builder@ before responding. Neither is
-- acceptable on an authorization hot path, and neither is configurable away. What is
-- actually wanted here — time, id, caller, method, path, status, duration — is the
-- function below.
module Observability
  ( requestIdHeaderName,
    requestIdMiddleware,
    newRequestLogger,
  )
where

import Control.Concurrent.MVar (newMVar, withMVar)
import Data.Aeson (Value, encode, object, (.=))
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
import Network.HTTP.Types (HeaderName, Status (..))
import Network.Wai (Middleware, Request (..), mapResponseHeaders, responseStatus)
import Servant.Health.Paths qualified as Health
import System.IO (stdout)

-- | Correlation id, accepted from an upstream proxy or minted here.
requestIdHeaderName :: HeaderName
requestIdHeaderName = "X-Request-Id"

-- | Caller identity, written by "Middleware".@authMiddleware@ after it verifies a
-- bearer key. Absent when authentication is disabled.
callerHeaderName :: HeaderName
callerHeaderName = "X-En-Caller"

-- | Probes fire every few seconds and would drown the log. They are also the two
-- paths with nothing to correlate.
isProbePath :: Request -> Bool
isProbePath request =
  rawPathInfo request `elem` Health.healthRawPaths

-- | Attach a request id to the request (for the logger and handlers) and to the
-- response (for the client).
--
-- An inbound @X-Request-Id@ is reused so a trace survives a reverse proxy, but only
-- after 'sanitizeRequestId' vets it: the value lands in a log line, and a caller that
-- can inject newlines into a log line can forge log entries. A rejected value is
-- replaced, not an error — the request itself is fine.
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
-- The 'MVar' serializes writes: two concurrent requests completing together would
-- otherwise interleave inside a single 'ByteString' write. Duration is measured on the
-- monotonic clock, so an NTP step cannot produce a negative latency.
newRequestLogger :: IO Middleware
newRequestLogger = do
  lock <- newMVar ()
  pure \inner request respond ->
    if isProbePath request
      then inner request respond
      else do
        start <- getMonotonicTimeNSec
        inner request \response -> do
          received <- respond response
          end <- getMonotonicTimeNSec
          now <- getCurrentTime
          let line =
                logLine
                  (Text.pack (iso8601Show now))
                  request
                  (responseStatus response)
                  (end - start)
          withMVar lock \() ->
            LazyChar8.hPutStrLn stdout (encode line)
          pure received

-- | The shape every en-server request log line takes.
logLine :: Text.Text -> Request -> Status -> Word64 -> Value
logLine timestamp request status elapsedNs =
  object
    [ "time" .= timestamp,
      "requestId" .= headerText requestIdHeaderName,
      "caller" .= headerText callerHeaderName,
      "method" .= decode (requestMethod request),
      "path" .= decode (rawPathInfo request),
      "status" .= status.statusCode,
      "durationMs" .= (fromIntegral elapsedNs / 1e6 :: Double)
    ]
  where
    decode = Text.decodeUtf8Lenient
    headerText name = decode <$> lookup name (requestHeaders request)
