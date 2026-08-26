-- | Bearer-key authentication for @en-server@.
--
-- en-server answers authorization questions, so every caller must prove it is
-- allowed to ask. Keys come from the environment in two tiers: read-write keys
-- may call every endpoint, read-only keys may call only the query endpoints.
--
-- The credential check lives behind 'authMiddleware' so that a future verifier
-- (mTLS client certificates, or a shomei identity token) replaces the body of
-- 'authenticate' without touching any handler.
module Middleware
  ( KeyRole (..),
    ApiKey (..),
    AuthConfig (..),
    RateLimitConfig (..),
    authMiddleware,
    rateLimitMiddleware,
    describeRateLimit,
  )
where

import Data.ByteArray (constEq)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as Char8
import Data.Char (toLower)
import Data.Generics.Labels ()
import Data.IORef (atomicModifyIORef', newIORef)
import Data.List (find)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Word (Word64)
import En.Prelude
import En.Servant.Problem
  ( problemResponse,
    specPermissionDenied,
    specRateLimited,
    specUnauthenticated,
  )
import GHC.Clock (getMonotonicTimeNSec)
import Network.HTTP.Types (HeaderName, hAuthorization, methodPost)
import Network.Wai (Middleware, Request (..), Response)
import Servant.Health.Paths qualified as Health

-- | What a key is allowed to do. 'ReadOnly' keys are rejected on write routes.
data KeyRole = ReadOnly | ReadWrite
  deriving stock (Eq, Show)

data ApiKey = ApiKey
  { -- | Caller identity, e.g. @ci-deployer@. Propagated to inner middleware.
    keyName :: !Text,
    -- | The bearer secret presented in the @Authorization@ header.
    keySecret :: !ByteString,
    keyRole :: !KeyRole
  }
  deriving stock (Generic)

data AuthConfig
  = -- | Local development only; every caller may read and write.
    AuthDisabled
  | AuthKeys ![ApiKey]
  deriving stock (Generic)

-- | Header carrying the verified caller identity to inner middleware and
-- handlers. Any client-supplied value is stripped before this is set.
callerHeaderName :: HeaderName
callerHeaderName = "X-En-Caller"

-- | Bucket shared by every request that reached the limiter without an
-- authenticated identity: probes, and all traffic under 'AuthDisabled'.
anonymousCaller :: Text
anonymousCaller = "anonymous"

-- | Paths that never require a key: orchestrator liveness and readiness probes
-- cannot conveniently carry credentials. @/metrics@ is deliberately not exempt.
isExemptPath :: Request -> Bool
isExemptPath request =
  rawPathInfo request `elem` Health.healthRawPaths

-- | Routes that mutate the relationship graph, and so require a 'ReadWrite' key.
--
-- Any new write route must be added here, or a read-only key silently gains write
-- access. The prefix match on @v1\/relationships@ covers both the write route and
-- its @delete@ sub-route.
isWriteRequest :: Request -> Bool
isWriteRequest request =
  case pathInfo request of
    "v1" : "relationships" : _ -> requestMethod request == methodPost
    _ -> False

-- | Reject every request that does not present a configured bearer key, and
-- every write attempted with a 'ReadOnly' key.
--
-- On success the request is passed inward with 'callerHeaderName' rewritten to
-- the verified key name; any client-supplied value is removed first so it
-- cannot be forged.
authMiddleware :: AuthConfig -> Middleware
authMiddleware AuthDisabled = id
authMiddleware (AuthKeys keys) = \application request respond ->
  if isExemptPath request
    then application request respond
    else case authenticate keys request of
      Nothing -> respond unauthenticated
      Just key
        | (key ^. #keyRole) == ReadOnly && isWriteRequest request ->
            respond readOnlyKey
        | otherwise ->
            application (withCaller (key ^. #keyName) request) respond

-- | Constant-time credential check. Returns the matching key, if any.
authenticate :: [ApiKey] -> Request -> Maybe ApiKey
authenticate keys request = do
  header <- lookup hAuthorization (requestHeaders request)
  presented <- bearerSecret header
  find (\key -> constEq (key ^. #keySecret) presented) keys

-- | @Bearer \<secret\>@, with a case-insensitive scheme per RFC 7235.
bearerSecret :: ByteString -> Maybe ByteString
bearerSecret raw =
  case Char8.words raw of
    [scheme, secret] | Char8.map toLower scheme == "bearer" -> Just secret
    _ -> Nothing

withCaller :: Text -> Request -> Request
withCaller name request =
  request
    { requestHeaders =
        (callerHeaderName, Text.encodeUtf8 name)
          : filter ((/= callerHeaderName) . fst) (requestHeaders request)
    }

unauthenticated :: Response
unauthenticated =
  problemResponse specUnauthenticated "missing or invalid API key"

readOnlyKey :: Response
readOnlyKey =
  problemResponse specPermissionDenied "this API key is read-only"

-- * Rate limiting

-- | A token bucket per caller: 'burst' is the bucket capacity, 'ratePerSecond'
-- the refill rate. A 'ratePerSecond' of zero disables limiting entirely.
data RateLimitConfig = RateLimitConfig
  { ratePerSecond :: !Double,
    burst :: !Double
  }
  deriving stock (Generic)

-- | Token count and the monotonic timestamp it was last computed at. Never a
-- wall-clock time: wall clocks jump backwards and would mint free tokens.
data Bucket = Bucket
  { tokens :: !Double,
    lastRefillNs :: !Word64
  }
  deriving stock (Generic)

describeRateLimit :: RateLimitConfig -> Text
describeRateLimit config
  | (config ^. #ratePerSecond) <= 0 = "disabled"
  | otherwise =
      "enabled, rps="
        <> Text.pack (show (config ^. #ratePerSecond))
        <> ", burst="
        <> Text.pack (show (config ^. #burst))

-- | Throttle each caller independently. Runs inside 'authMiddleware' so it can
-- read the verified identity from 'callerHeaderName'.
--
-- Allocates the shared bucket map, hence the 'IO' wrapper.
rateLimitMiddleware :: RateLimitConfig -> IO Middleware
rateLimitMiddleware config
  | (config ^. #ratePerSecond) <= 0 = pure id
  | otherwise = do
      buckets <- newIORef Map.empty
      pure \application request respond ->
        if isExemptPath request
          then application request respond
          else do
            now <- getMonotonicTimeNSec
            admitted <-
              atomicModifyIORef' buckets (admit config (callerOf request) now)
            if admitted
              then application request respond
              else respond rateLimited

-- | Refill the caller's bucket for the elapsed time, then spend one token if
-- one is available.
admit :: RateLimitConfig -> Text -> Word64 -> Map Text Bucket -> (Map Text Bucket, Bool)
admit config caller now buckets =
  if refilled >= 1
    then (Map.insert caller (Bucket (refilled - 1) now) buckets, True)
    else (Map.insert caller (Bucket refilled now) buckets, False)
  where
    bucket = Map.findWithDefault (Bucket (config ^. #burst) now) caller buckets
    elapsedSeconds = fromIntegral (now - (bucket ^. #lastRefillNs)) / 1e9
    refilled = min (config ^. #burst) ((bucket ^. #tokens) + elapsedSeconds * (config ^. #ratePerSecond))

callerOf :: Request -> Text
callerOf request =
  maybe
    anonymousCaller
    Text.decodeUtf8Lenient
    (lookup callerHeaderName (requestHeaders request))

rateLimited :: Response
rateLimited =
  problemResponse specRateLimited "rate limit exceeded"
