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
    loadAuthConfig,
    authMiddleware,
) where

import Data.Aeson (encode, object, (.=))
import Data.ByteArray (constEq)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as Char8
import Data.ByteString.Lazy qualified as Lazy
import Data.Char (toLower)
import Data.List (find)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Text.IO qualified as Text
import Network.HTTP.Types (HeaderName, hAuthorization, hContentType, status401)
import Network.Wai (Middleware, Request (..), Response, responseLBS)
import System.Environment (lookupEnv)

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

{- | Paths that never require a key: orchestrator liveness and readiness probes
cannot conveniently carry credentials. @/metrics@ is deliberately not exempt.
-}
isExemptPath :: Request -> Bool
isExemptPath request =
    pathInfo request `elem` [["healthz"], ["readyz"]]

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

{- | Reject every request that does not present a configured bearer key.

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
            Just key -> application (withCaller key.keyName request) respond

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
        (errorBody "missing or invalid API key" "unauthenticated")

{- | The minimal error envelope. EP-35
(@docs/plans/35-version-the-wire-contract-and-type-the-error-model.md@)
replaces this with the typed @{code, message, retryable}@ envelope.
-}
errorBody :: Text -> Text -> Lazy.ByteString
errorBody message code =
    encode (object ["error" .= message, "code" .= code])
