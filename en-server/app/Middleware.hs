{- | Bearer-key authentication for @en-server@.

en-server answers authorization questions, so every caller must prove it is
allowed to ask. Keys come from the environment in two tiers: read-write keys
may call every endpoint, read-only keys may call only the query endpoints.

The credential check lives behind 'authMiddleware' so that a future verifier
(mTLS client certificates, or a shomei identity token) replaces the body of
'authenticate' without touching any handler.
-}
module Middleware (
    KeyRole (..),
    ApiKey (..),
    AuthConfig (..),
    RateLimitConfig (..),
    loadAuthConfig,
    loadRateLimitConfig,
    authMiddleware,
    rateLimitMiddleware,
    describeRateLimit,
) where

import Data.Aeson (encode, object, (.=))
import Data.ByteArray (constEq)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as Char8
import Data.ByteString.Lazy qualified as Lazy
import Data.Char (toLower)
import Data.IORef (atomicModifyIORef', newIORef)
import Data.List (find)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Text.IO qualified as Text
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Network.HTTP.Types (HeaderName, hAuthorization, hContentType, methodPost, status401, status403, status429)
import Network.Wai (Middleware, Request (..), Response, responseLBS)
import System.Environment (lookupEnv)
import Text.Read (readMaybe)

-- | What a key is allowed to do. 'ReadOnly' keys are rejected on write routes.
data KeyRole = ReadOnly | ReadWrite
    deriving stock (Eq, Show)

data ApiKey = ApiKey
    { keyName :: !Text
    -- ^ Caller identity, e.g. @ci-deployer@. Propagated to inner middleware.
    , keySecret :: !ByteString
    -- ^ The bearer secret presented in the @Authorization@ header.
    , keyRole :: !KeyRole
    }

data AuthConfig
    = -- | Local development only; every caller may read and write.
      AuthDisabled
    | AuthKeys ![ApiKey]

{- | Header carrying the verified caller identity to inner middleware and
handlers. Any client-supplied value is stripped before this is set.
-}
callerHeaderName :: HeaderName
callerHeaderName = "X-En-Caller"

{- | Bucket shared by every request that reached the limiter without an
authenticated identity: probes, and all traffic under 'AuthDisabled'.
-}
anonymousCaller :: Text
anonymousCaller = "anonymous"

{- | Paths that never require a key: orchestrator liveness and readiness probes
cannot conveniently carry credentials. @/metrics@ is deliberately not exempt.
-}
isExemptPath :: Request -> Bool
isExemptPath request =
    pathInfo request `elem` [["healthz"], ["readyz"]]

{- | Routes that mutate the relationship graph, and so require a 'ReadWrite' key.

Any new write route must be added here, or a read-only key silently gains write
access. The prefix match on @v1\/relationships@ covers both the write route and
its @delete@ sub-route.
-}
isWriteRequest :: Request -> Bool
isWriteRequest request =
    case pathInfo request of
        "v1" : "relationships" : _ -> requestMethod request == methodPost
        _ -> False

{- | Read @EN_API_KEYS_READ_WRITE@, @EN_API_KEYS_READ_ONLY@, and
@EN_AUTH_DISABLED@. Fails closed: with no keys and no explicit opt-out this
aborts startup before the port is bound.
-}
loadAuthConfig :: IO AuthConfig
loadAuthConfig = do
    readWrite <- keysFromEnv "EN_API_KEYS_READ_WRITE" ReadWrite
    readOnly <- keysFromEnv "EN_API_KEYS_READ_ONLY" ReadOnly
    disabled <- authDisabledRequested
    case readWrite <> readOnly of
        [] | disabled -> do
            Text.putStrLn
                "WARNING: authentication is DISABLED (EN_AUTH_DISABLED=true). Every caller may read and write. Never run this way outside local development."
            pure AuthDisabled
        [] -> fail noKeysConfigured
        keys -> do
            rejectDuplicateNames keys
            if disabled
                then do
                    Text.putStrLn
                        "WARNING: EN_AUTH_DISABLED=true is ignored because API keys are configured; authentication stays enabled."
                    pure (AuthKeys keys)
                else pure (AuthKeys keys)

authDisabledRequested :: IO Bool
authDisabledRequested =
    maybe False ((== "true") . map toLower) <$> lookupEnv "EN_AUTH_DISABLED"

noKeysConfigured :: String
noKeysConfigured =
    unlines
        [ "No API keys configured; refusing to start an unauthenticated authorization service."
        , "Set EN_API_KEYS_READ_WRITE and/or EN_API_KEYS_READ_ONLY to a comma-separated list"
        , "of name:secret entries, where each secret is at least 16 bytes. For example:"
        , ""
        , "    EN_API_KEYS_READ_WRITE='deployer:S3cret-value-at-least-16'"
        , "    EN_API_KEYS_READ_ONLY='reader:another-secret-at-least-16'"
        , ""
        , "For local development only, set EN_AUTH_DISABLED=true to serve without authentication."
        ]

{- | Parse one @name:secret@ list. A malformed entry aborts startup rather than
being skipped: authentication configuration must never partially parse.
-}
keysFromEnv :: String -> KeyRole -> IO [ApiKey]
keysFromEnv name role =
    lookupEnv name >>= \case
        Nothing -> pure []
        Just raw
            | Text.null (Text.strip (Text.pack raw)) -> pure []
            | otherwise ->
                traverse
                    (parseKeyEntry name role)
                    (map Text.strip (Text.splitOn "," (Text.pack raw)))

parseKeyEntry :: String -> KeyRole -> Text -> IO ApiKey
parseKeyEntry envName role entry
    | Text.null entry = invalid "empty entry (check for a stray comma)"
    | otherwise =
        case Text.breakOn ":" entry of
            (_, "") -> invalid ("entry " <> show entry <> " has no ':' separator")
            (name, rest)
                | Text.null name -> invalid ("entry " <> show entry <> " has an empty name")
                | otherwise -> do
                    let secret = Text.drop 1 rest
                        secretBytes = Text.encodeUtf8 secret
                    if Char8.length secretBytes < minimumSecretBytes
                        then
                            invalid $
                                "secret for name "
                                    <> show name
                                    <> " is shorter than "
                                    <> show minimumSecretBytes
                                    <> " bytes"
                        else
                            pure
                                ApiKey
                                    { keyName = name
                                    , keySecret = secretBytes
                                    , keyRole = role
                                    }
  where
    invalid reason = fail ("Invalid " <> envName <> ": " <> reason)

minimumSecretBytes :: Int
minimumSecretBytes = 16

{- | Names identify callers in logs and rate-limit buckets, so they must be
unique across both tiers.
-}
rejectDuplicateNames :: [ApiKey] -> IO ()
rejectDuplicateNames keys =
    case duplicates of
        [] -> pure ()
        names ->
            fail $
                "Duplicate API key name(s) across EN_API_KEYS_READ_WRITE and EN_API_KEYS_READ_ONLY: "
                    <> Text.unpack (Text.intercalate ", " names)
  where
    duplicates = reverse (snd (foldl' step (Set.empty, []) keys))
    step (seen, dups) key
        | Set.member key.keyName seen = (seen, key.keyName : dups)
        | otherwise = (Set.insert key.keyName seen, dups)

{- | Reject every request that does not present a configured bearer key, and
every write attempted with a 'ReadOnly' key.

On success the request is passed inward with 'callerHeaderName' rewritten to
the verified key name; any client-supplied value is removed first so it
cannot be forged.
-}
authMiddleware :: AuthConfig -> Middleware
authMiddleware AuthDisabled = id
authMiddleware (AuthKeys keys) = \application request respond ->
    if isExemptPath request
        then application request respond
        else case authenticate keys request of
            Nothing -> respond unauthenticated
            Just key
                | key.keyRole == ReadOnly && isWriteRequest request ->
                    respond readOnlyKey
                | otherwise ->
                    application (withCaller key.keyName request) respond

-- | Constant-time credential check. Returns the matching key, if any.
authenticate :: [ApiKey] -> Request -> Maybe ApiKey
authenticate keys request = do
    header <- lookup hAuthorization (requestHeaders request)
    presented <- bearerSecret header
    find (\key -> constEq key.keySecret presented) keys

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
    responseLBS
        status401
        [ (hContentType, "application/json")
        , ("WWW-Authenticate", "Bearer")
        ]
        (errorBody "unauthenticated" "missing or invalid API key" False)

readOnlyKey :: Response
readOnlyKey =
    responseLBS
        status403
        [(hContentType, "application/json")]
        (errorBody "permission_denied" "this API key is read-only" False)

-- * Rate limiting

{- | A token bucket per caller: 'burst' is the bucket capacity, 'ratePerSecond'
the refill rate. A 'ratePerSecond' of zero disables limiting entirely.
-}
data RateLimitConfig = RateLimitConfig
    { ratePerSecond :: !Double
    , burst :: !Double
    }

{- | Token count and the monotonic timestamp it was last computed at. Never a
wall-clock time: wall clocks jump backwards and would mint free tokens.
-}
data Bucket = Bucket
    { tokens :: !Double
    , lastRefillNs :: !Word64
    }

-- | Read @EN_RATE_LIMIT_RPS@ and @EN_RATE_LIMIT_BURST@. Both default to 0 (off).
loadRateLimitConfig :: IO RateLimitConfig
loadRateLimitConfig = do
    rps <- optionalNonNegativeDoubleEnv "EN_RATE_LIMIT_RPS"
    configuredBurst <- optionalNonNegativeDoubleEnv "EN_RATE_LIMIT_BURST"
    let effectiveBurst = if configuredBurst > 0 then configuredBurst else rps
    if rps > 0 && effectiveBurst < 1
        then
            fail $
                "Invalid EN_RATE_LIMIT_BURST: a bucket capacity of "
                    <> show effectiveBurst
                    <> " can never admit a request. Set EN_RATE_LIMIT_BURST to at least 1."
        else pure RateLimitConfig{ratePerSecond = rps, burst = effectiveBurst}

optionalNonNegativeDoubleEnv :: String -> IO Double
optionalNonNegativeDoubleEnv name =
    lookupEnv name >>= \case
        Nothing -> pure 0
        Just value ->
            case readMaybe value of
                Just parsed | parsed >= 0 -> pure parsed
                _ -> fail ("Invalid " <> name <> ": expected a non-negative number")

describeRateLimit :: RateLimitConfig -> Text
describeRateLimit config
    | config.ratePerSecond <= 0 = "disabled"
    | otherwise =
        "enabled, rps="
            <> Text.pack (show config.ratePerSecond)
            <> ", burst="
            <> Text.pack (show config.burst)

{- | Throttle each caller independently. Runs inside 'authMiddleware' so it can
read the verified identity from 'callerHeaderName'.

Allocates the shared bucket map, hence the 'IO' wrapper.
-}
rateLimitMiddleware :: RateLimitConfig -> IO Middleware
rateLimitMiddleware config
    | config.ratePerSecond <= 0 = pure id
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

{- | Refill the caller's bucket for the elapsed time, then spend one token if
one is available.
-}
admit :: RateLimitConfig -> Text -> Word64 -> Map Text Bucket -> (Map Text Bucket, Bool)
admit config caller now buckets =
    if refilled >= 1
        then (Map.insert caller (Bucket (refilled - 1) now) buckets, True)
        else (Map.insert caller (Bucket refilled now) buckets, False)
  where
    bucket = Map.findWithDefault (Bucket config.burst now) caller buckets
    elapsedSeconds = fromIntegral (now - bucket.lastRefillNs) / 1e9
    refilled = min config.burst (bucket.tokens + elapsedSeconds * config.ratePerSecond)

callerOf :: Request -> Text
callerOf request =
    maybe
        anonymousCaller
        Text.decodeUtf8Lenient
        (lookup callerHeaderName (requestHeaders request))

rateLimited :: Response
rateLimited =
    responseLBS
        status429
        [ (hContentType, "application/json")
        , ("Retry-After", "1")
        ]
        (errorBody "rate_limited" "rate limit exceeded" True)

{- | The same @{code, message, retryable}@ envelope that @en-servant@ emits.

Written out here rather than reused from 'En.Servant.Seam.ErrorEnvelopeWire' because
these responses are produced by WAI middleware, outside Servant: there is no
'Servant.ServerError' to attach, and no handler to return from. The field order and
names must match, so a change to the envelope changes both.

A rate limit is the one middleware rejection worth retrying: the caller's bucket
refills. A missing key and a read-only key do not fix themselves.
-}
errorBody :: Text -> Text -> Bool -> Lazy.ByteString
errorBody code message retryable =
    encode (object ["code" .= code, "message" .= message, "retryable" .= retryable])
