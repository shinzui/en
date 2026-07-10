{- | Every environment variable @en-server@ reads, parsed and validated in one place.

Configuration is read once, wholly, before anything else happens: no port is bound, no
connection is opened, and no schema is loaded until every variable has been accepted.
A rejected value names itself, its value, and the form expected.

Parsing is pure. 'loadServerConfig' snapshots the environment into a map and hands it to
'parseServerConfig', so the rules are testable without a process to configure. Failures
come back as 'Left', not as an exception: @Main@ renders the message to stderr and exits
with status 1, rather than letting a @fail@-in-@IO@ surface as
@en-server: Uncaught exception … user error (…)@ wrapped around an otherwise good
message.

Warnings travel alongside the config rather than being printed where they are found, so
that a configuration that ultimately fails to parse does not first emit advice about a
setting that will never take effect.
-}
module Config (
    ServerConfig (..),
    StoreConfig (..),
    PoolConfig (..),
    TlsConfig (..),
    BiscuitConfig (..),
    loadServerConfig,
    loadStoreConfig,
    validateGcWindow,
    knownVariables,
    storeVariables,
) where

import Data.Bifunctor (first)
import Data.ByteString qualified as ByteString
import Data.Char (toLower)
import Data.List (isPrefixOf)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import En.Budget (EvaluationBudget (..))
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Session (Session)
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import System.Environment (lookupEnv)
import Text.Read (readMaybe)

import Auth.Biscuit (SecretKey)
import En.Biscuit.Keys (IssuerKeyId, parseSigningKeyText)
import Maintenance (MaintenanceConfig (..))
import Middleware (ApiKey (..), AuthConfig (..), KeyRole (..), RateLimitConfig (..))

data PoolConfig = PoolConfig
    { size :: !Int
    , acquisitionTimeoutMs :: !Int
    , idlenessTimeoutMs :: !Int
    , maxLifetimeMs :: !Int
    }

-- | Both files or neither; exactly one is a configuration error.
data TlsConfig = TlsConfig
    { certFile :: !FilePath
    , keyFile :: !FilePath
    }

{- | Issuer configuration for @POST \/v1\/grants@, present only when
@EN_BISCUIT_ISSUER_SECRET_KEY@ is set.

The key material is parsed once, at startup: a malformed key aborts before the
port binds rather than surfacing on the first mint. The active schema hash the
grants are stamped with is /not/ here — the handler reads it from the request-time
schema snapshot, so a @SIGHUP@ reload cannot mint under a hash the check did not
evaluate under.
-}
data BiscuitConfig = BiscuitConfig
    { issuerKeyId :: !IssuerKeyId
    , issuerSecretKey :: !SecretKey
    -- ^ Never logged.
    , defaultTtlSeconds :: !Int
    , maxTtlSeconds :: !Int
    }

{- | What it takes to open the store and speak to it correctly.

Split out of 'ServerConfig' because @en-server import@ and @en-server export@ bind
no port and serve no request: demanding API keys, a rate limit, or TLS material
from an operator running a bulk load would be configuration theatre, and refusing
to start without them -- which 'loadServerConfig' rightly does -- would refuse a
command that has nothing to authenticate.
-}
data StoreConfig = StoreConfig
    { databaseUrl :: !Text
    , gcWindow :: !Text
    -- ^ A PostgreSQL interval. Only PostgreSQL can validate it; see 'validateGcWindow'.
    , schemaPath :: !(Maybe FilePath)
    -- ^ Reading and parsing the file stays in @Main@; this is only the path.
    , pool :: !PoolConfig
    }

data ServerConfig = ServerConfig
    { store :: !StoreConfig
    , port :: !Int
    , optimizedRevisionTtlMs :: !Int
    , tupleReadMaxEntries :: !Int
    , decisionMaxEntries :: !Int
    , maxBatchSize :: !Int
    , deadlineDefaultMillis :: !Int
    , deadlineMaxMillis :: !Int
    , budget :: !EvaluationBudget
    {- ^ Static evaluation bounds for check, lookup, and expand. Distinct from the
    deadline above, which is a clock rather than a bound: raising the depth budget
    buys a slow lookup no more time.
    -}
    , auth :: !AuthConfig
    , biscuit :: !(Maybe BiscuitConfig)
    {- ^ Issuer configuration for @POST \/v1\/grants@. 'Nothing' when
    @EN_BISCUIT_ISSUER_SECRET_KEY@ is unset, which disables the endpoint. When it
    is set, caller authentication must be active or startup is refused — a
    minting endpoint on an unauthenticated server would hand bearer tokens to
    anyone.
    -}
    , rateLimit :: !RateLimitConfig
    , maintenance :: !MaintenanceConfig
    , tls :: !(Maybe TlsConfig)
    , schemaReloadForce :: !Bool
    {- ^ Activate a schema on @SIGHUP@ even when it strands live grants.

    Off by default: a reload that orphans grants is refused, with the report in the log.
    An operator removing a feature legitimately wants its grants dead, and this is how
    they say so — explicitly, in the process environment, before the signal arrives.
    -}
    }

{- | Every variable the server reads. Kept exhaustive so the documented configuration
reference can be checked against it.
-}
knownVariables :: [String]
knownVariables =
    [ "EN_API_KEYS_READ_ONLY"
    , "EN_API_KEYS_READ_WRITE"
    , "EN_AUTH_DISABLED"
    , "EN_BISCUIT_DEFAULT_TTL_SECONDS"
    , "EN_BISCUIT_ISSUER_SECRET_KEY"
    , "EN_BISCUIT_MAX_TTL_SECONDS"
    , "EN_DATABASE_URL"
    , "EN_DECISION_CACHE_MAX_ENTRIES"
    , "EN_GC_WINDOW"
    , "EN_LOOKUP_DEADLINE_DEFAULT_MS"
    , "EN_LOOKUP_DEADLINE_MAX_MS"
    , "EN_MAINTENANCE_BATCH_SIZE"
    , "EN_MAINTENANCE_INTERVAL_SECONDS"
    , "EN_MAX_BATCH_SIZE"
    , "EN_MAX_DEPTH"
    , "EN_OPTIMIZED_REVISION_CACHE_TTL_MS"
    , "EN_PAGE_LIMIT"
    , "EN_POOL_ACQUISITION_TIMEOUT_MS"
    , "EN_POOL_IDLENESS_TIMEOUT_MS"
    , "EN_POOL_MAX_LIFETIME_MS"
    , "EN_POOL_SIZE"
    , "EN_PORT"
    , "EN_RATE_LIMIT_BURST"
    , "EN_RATE_LIMIT_RPS"
    , "EN_RESULT_CAP"
    , "EN_SCHEMA_PATH"
    , "EN_SCHEMA_RELOAD_FORCE"
    , "EN_TLS_CERT_FILE"
    , "EN_TLS_KEY_FILE"
    , "EN_TUPLE_READ_CACHE_MAX_ENTRIES"
    ]

{- | The subset of 'knownVariables' the store itself reads.

Everything a bulk import or export needs, and nothing a request-serving process
adds. Kept as a projection of 'knownVariables' rather than a second list so a new
store variable cannot be added to one and forgotten in the other.
-}
storeVariables :: [String]
storeVariables =
    filter isStoreVariable knownVariables
  where
    isStoreVariable name =
        name `elem` ["EN_DATABASE_URL", "EN_GC_WINDOW", "EN_SCHEMA_PATH"]
            || "EN_POOL_" `isPrefixOf` name

-- | Snapshot the environment, then parse it. Returns the config and any warnings.
loadServerConfig :: IO (Either Text (ServerConfig, [Text]))
loadServerConfig = do
    present <- catMaybes <$> traverse readVariable knownVariables
    pure (parseServerConfig (Map.fromList present))
  where
    readVariable name = fmap ((,) name) <$> lookupEnv name

{- | As 'loadServerConfig', but reading only what the store needs.

The serving variables are not merely ignored, they are never read: an operator
running @en-server import@ against a production database should not have to
supply the API keys of a server they are not starting.
-}
loadStoreConfig :: IO (Either Text (StoreConfig, [Text]))
loadStoreConfig = do
    present <- catMaybes <$> traverse readVariable storeVariables
    pure (parseStoreConfig (Map.fromList present))
  where
    readVariable name = fmap ((,) name) <$> lookupEnv name

parseStoreConfig :: Map String String -> Either Text (StoreConfig, [Text])
parseStoreConfig environment = do
    databaseUrl <- required "EN_DATABASE_URL" databaseUrlHint
    gcWindow <- Text.pack <$> withDefault "EN_GC_WINDOW" "24 hours" nonEmptyString
    schemaPath <- optional "EN_SCHEMA_PATH" nonEmptyString
    pool <- parsePool environment
    pure
        ( StoreConfig
            { databaseUrl = Text.pack databaseUrl
            , gcWindow
            , schemaPath
            , pool
            }
        , schemaWarnings schemaPath
        )
  where
    required :: String -> Text -> Either Text String
    required = requiredIn environment

    optional :: forall a. String -> Parser a -> Either Text (Maybe a)
    optional = optionalIn environment

    withDefault :: forall a. String -> a -> Parser a -> Either Text a
    withDefault = withDefaultIn environment

parseServerConfig :: Map String String -> Either Text (ServerConfig, [Text])
parseServerConfig environment = do
    (store, storeWarnings) <- parseStoreConfig environment
    port <- withDefault "EN_PORT" 8080 (bounded 1 65535)
    optimizedRevisionTtlMs <- withDefault "EN_OPTIMIZED_REVISION_CACHE_TTL_MS" 0 nonNegative
    tupleReadMaxEntries <- withDefault "EN_TUPLE_READ_CACHE_MAX_ENTRIES" 0 nonNegative
    decisionMaxEntries <- withDefault "EN_DECISION_CACHE_MAX_ENTRIES" 0 nonNegative
    maxBatchSize <- withDefault "EN_MAX_BATCH_SIZE" 1000 positive
    deadlineDefaultMillis <- withDefault "EN_LOOKUP_DEADLINE_DEFAULT_MS" 3000 positive
    deadlineMaxMillis <- withDefault "EN_LOOKUP_DEADLINE_MAX_MS" 30000 positive
    checkDeadlineOrdering deadlineDefaultMillis deadlineMaxMillis
    budget <- parseBudget environment
    tls <- parseTls environment
    rateLimit <- parseRateLimit environment
    maintenance <- parseMaintenance environment
    schemaReloadForce <- withDefault "EN_SCHEMA_RELOAD_FORCE" False boolean
    (auth, authWarnings) <- parseAuth environment
    biscuit <- parseBiscuit environment
    checkMintingAuthGate auth biscuit
    pure
        ( ServerConfig
            { store
            , port
            , optimizedRevisionTtlMs
            , tupleReadMaxEntries
            , decisionMaxEntries
            , maxBatchSize
            , deadlineDefaultMillis
            , deadlineMaxMillis
            , budget
            , auth
            , biscuit
            , rateLimit
            , maintenance
            , tls
            , schemaReloadForce
            }
        , authWarnings <> storeWarnings
        )
  where
    withDefault :: forall a. String -> a -> Parser a -> Either Text a
    withDefault = withDefaultIn environment

schemaWarnings :: Maybe FilePath -> [Text]
schemaWarnings = \case
    Just _ -> []
    Nothing ->
        [ "WARNING: EN_SCHEMA_PATH not set; serving the built-in demo schema. Set EN_SCHEMA_PATH=/path/to/schema.en to serve your own model."
        ]

{- | The lookup ceiling must not sit below the default, or every request that omits
@deadlineMillis@ would be clamped to a budget the operator never intended.
-}
checkDeadlineOrdering :: Int -> Int -> Either Text ()
checkDeadlineOrdering defaultMillis maxMillis
    | defaultMillis <= maxMillis = Right ()
    | otherwise =
        Left $
            "Invalid EN_LOOKUP_DEADLINE_MAX_MS="
                <> Text.pack (show maxMillis)
                <> ": it is below EN_LOOKUP_DEADLINE_DEFAULT_MS="
                <> Text.pack (show defaultMillis)
                <> ". Every lookup would be clamped below its own default."

{- | The engine's static evaluation bounds.

All three are @positive@: a zero depth budget answers nothing, a zero read batch
never advances a cursor, and a zero result cap returns an empty page while
claiming truncation. Defaults match 'En.Budget.defaultEvaluationBudget', so an
unset environment behaves exactly as en did when these were source constants.
-}
parseBudget :: Map String String -> Either Text EvaluationBudget
parseBudget environment = do
    maxDepth <- withDefault "EN_MAX_DEPTH" 25 positive
    pageLimit <- withDefault "EN_PAGE_LIMIT" 1000 positive
    resultCap <- withDefault "EN_RESULT_CAP" 1000 positive
    pure EvaluationBudget{maxDepth, pageLimit, resultCap}
  where
    withDefault :: forall a. String -> a -> Parser a -> Either Text a
    withDefault = withDefaultIn environment

parsePool :: Map String String -> Either Text PoolConfig
parsePool environment = do
    size <- withDefault "EN_POOL_SIZE" 10 positive
    acquisitionTimeoutMs <- withDefault "EN_POOL_ACQUISITION_TIMEOUT_MS" 10000 positive
    idlenessTimeoutMs <- withDefault "EN_POOL_IDLENESS_TIMEOUT_MS" 600000 positive
    maxLifetimeMs <- withDefault "EN_POOL_MAX_LIFETIME_MS" 3600000 positive
    pure PoolConfig{size, acquisitionTimeoutMs, idlenessTimeoutMs, maxLifetimeMs}
  where
    withDefault :: forall a. String -> a -> Parser a -> Either Text a
    withDefault = withDefaultIn environment

parseTls :: Map String String -> Either Text (Maybe TlsConfig)
parseTls environment = do
    cert <- optional "EN_TLS_CERT_FILE" nonEmptyString
    key <- optional "EN_TLS_KEY_FILE" nonEmptyString
    case (cert, key) of
        (Nothing, Nothing) -> Right Nothing
        (Just certFile, Just keyFile) -> Right (Just TlsConfig{certFile, keyFile})
        _ ->
            Left "Invalid TLS configuration: set both EN_TLS_CERT_FILE and EN_TLS_KEY_FILE, or neither."
  where
    optional :: forall a. String -> Parser a -> Either Text (Maybe a)
    optional = optionalIn environment

parseRateLimit :: Map String String -> Either Text RateLimitConfig
parseRateLimit environment = do
    ratePerSecond <- withDefault "EN_RATE_LIMIT_RPS" 0 nonNegativeDouble
    configuredBurst <- withDefault "EN_RATE_LIMIT_BURST" 0 nonNegativeDouble
    let burst = if configuredBurst > 0 then configuredBurst else ratePerSecond
    if ratePerSecond > 0 && burst < 1
        then
            Left $
                "Invalid EN_RATE_LIMIT_BURST="
                    <> Text.pack (show burst)
                    <> ": a bucket capacity below 1 can never admit a request."
        else Right RateLimitConfig{ratePerSecond, burst}
  where
    withDefault :: forall a. String -> a -> Parser a -> Either Text a
    withDefault = withDefaultIn environment

parseMaintenance :: Map String String -> Either Text MaintenanceConfig
parseMaintenance environment = do
    intervalSeconds <- withDefault "EN_MAINTENANCE_INTERVAL_SECONDS" 600 nonNegative
    batchSize <- withDefault "EN_MAINTENANCE_BATCH_SIZE" 1000 positive
    pure MaintenanceConfig{intervalSeconds, batchSize}
  where
    withDefault :: forall a. String -> a -> Parser a -> Either Text a
    withDefault = withDefaultIn environment

{- | Read both key tiers. Fails closed: with no keys and no explicit opt-out this aborts
startup before the port is bound.
-}
parseAuth :: Map String String -> Either Text (AuthConfig, [Text])
parseAuth environment = do
    readWrite <- parseKeyList "EN_API_KEYS_READ_WRITE" ReadWrite
    readOnly <- parseKeyList "EN_API_KEYS_READ_ONLY" ReadOnly
    disabled <- withDefaultIn environment "EN_AUTH_DISABLED" False boolean
    case readWrite <> readOnly of
        [] | disabled -> Right (AuthDisabled, [authDisabledWarning])
        [] -> Left noKeysConfigured
        keys -> do
            rejectDuplicateNames keys
            pure
                ( AuthKeys keys
                , [authIgnoredWarning | disabled]
                )
  where
    parseKeyList name role =
        case Map.lookup name environment of
            Nothing -> Right []
            Just raw
                | Text.null (Text.strip (Text.pack raw)) -> Right []
                | otherwise ->
                    traverse
                        (parseKeyEntry name role)
                        (map Text.strip (Text.splitOn "," (Text.pack raw)))

{- | Parse the issuer configuration for @POST \/v1\/grants@.

Absent @EN_BISCUIT_ISSUER_SECRET_KEY@ — or an empty one, treated as absent as the
key lists are — disables minting ('Nothing'). A present but malformed key aborts
startup: a half-configured issuer must never serve. The TTL bounds default to
300s and 3600s and the maximum must not sit below the default.
-}
parseBiscuit :: Map String String -> Either Text (Maybe BiscuitConfig)
parseBiscuit environment =
    case Map.lookup "EN_BISCUIT_ISSUER_SECRET_KEY" environment of
        Nothing -> Right Nothing
        Just raw
            | Text.null (Text.strip (Text.pack raw)) -> Right Nothing
            | otherwise -> do
                (issuerKeyId, issuerSecretKey) <-
                    first
                        (\reason -> "Invalid EN_BISCUIT_ISSUER_SECRET_KEY: " <> reason)
                        (parseSigningKeyText (Text.pack raw))
                defaultTtlSeconds <- withDefault "EN_BISCUIT_DEFAULT_TTL_SECONDS" 300 positive
                maxTtlSeconds <- withDefault "EN_BISCUIT_MAX_TTL_SECONDS" 3600 positive
                if maxTtlSeconds < defaultTtlSeconds
                    then Left (ttlOrderingError defaultTtlSeconds maxTtlSeconds)
                    else
                        Right
                            ( Just
                                BiscuitConfig
                                    { issuerKeyId
                                    , issuerSecretKey
                                    , defaultTtlSeconds
                                    , maxTtlSeconds
                                    }
                            )
  where
    withDefault :: forall a. String -> a -> Parser a -> Either Text a
    withDefault = withDefaultIn environment

ttlOrderingError :: Int -> Int -> Text
ttlOrderingError defaultTtl maxTtl =
    "Invalid EN_BISCUIT_MAX_TTL_SECONDS="
        <> Text.pack (show maxTtl)
        <> ": it is below EN_BISCUIT_DEFAULT_TTL_SECONDS="
        <> Text.pack (show defaultTtl)
        <> ". A default token lifetime above its own maximum is a contradiction."

{- | Refuse to start a server that mints grants but authenticates no caller.

A grant-minting endpoint on an unauthenticated server would hand signed bearer
tokens to anyone with network reach, so this is a hard startup failure, never a
warning (docs/plans/33, docs/plans/57).
-}
checkMintingAuthGate :: AuthConfig -> Maybe BiscuitConfig -> Either Text ()
checkMintingAuthGate auth = \case
    Nothing -> Right ()
    Just _ -> case auth of
        AuthKeys _ -> Right ()
        AuthDisabled -> Left mintingWithoutAuthError

mintingWithoutAuthError :: Text
mintingWithoutAuthError =
    Text.unlines
        [ "EN_BISCUIT_ISSUER_SECRET_KEY is set but caller authentication is not enabled."
        , "A grant-minting endpoint on an unauthenticated server would hand bearer"
        , "tokens to anyone. Enable authentication (docs/plans/33) or unset the key."
        ]

authDisabledWarning :: Text
authDisabledWarning =
    "WARNING: authentication is DISABLED (EN_AUTH_DISABLED=true). Every caller may read and write. Never run this way outside local development."

authIgnoredWarning :: Text
authIgnoredWarning =
    "WARNING: EN_AUTH_DISABLED=true is ignored because API keys are configured; authentication stays enabled."

noKeysConfigured :: Text
noKeysConfigured =
    Text.unlines
        [ "No API keys configured; refusing to start an unauthenticated authorization service."
        , "Set EN_API_KEYS_READ_WRITE and/or EN_API_KEYS_READ_ONLY to a comma-separated list"
        , "of name:secret entries, where each secret is at least 16 bytes. For example:"
        , ""
        , "    EN_API_KEYS_READ_WRITE='deployer:S3cret-value-at-least-16'"
        , "    EN_API_KEYS_READ_ONLY='reader:another-secret-at-least-16'"
        , ""
        , "For local development only, set EN_AUTH_DISABLED=true to serve without authentication."
        ]

{- | Parse one @name:secret@ entry. A malformed entry aborts startup rather than being
skipped: authentication configuration must never partially parse.
-}
parseKeyEntry :: String -> KeyRole -> Text -> Either Text ApiKey
parseKeyEntry envName role entry
    | Text.null entry = invalid "empty entry (check for a stray comma)"
    | otherwise =
        case Text.breakOn ":" entry of
            (_, "") -> invalid ("entry " <> quoted entry <> " has no ':' separator")
            (name, rest)
                | Text.null name -> invalid ("entry " <> quoted entry <> " has an empty name")
                | otherwise ->
                    -- Bytes, not characters: the secret is compared as a ByteString.
                    let secretBytes = Text.encodeUtf8 (Text.drop 1 rest)
                     in if ByteString.length secretBytes < minimumSecretBytes
                            then
                                invalid $
                                    "secret for name "
                                        <> quoted name
                                        <> " is shorter than "
                                        <> Text.pack (show minimumSecretBytes)
                                        <> " bytes"
                            else Right ApiKey{keyName = name, keySecret = secretBytes, keyRole = role}
  where
    invalid reason = Left ("Invalid " <> Text.pack envName <> ": " <> reason)
    quoted value = "\"" <> value <> "\""

minimumSecretBytes :: Int
minimumSecretBytes = 16

-- | Names identify callers in logs and rate-limit buckets, so they must be unique.
rejectDuplicateNames :: [ApiKey] -> Either Text ()
rejectDuplicateNames keys =
    case duplicates of
        [] -> Right ()
        names ->
            Left $
                "Duplicate API key name(s) across EN_API_KEYS_READ_WRITE and EN_API_KEYS_READ_ONLY: "
                    <> Text.intercalate ", " names
  where
    duplicates = reverse (snd (foldl' step (Set.empty, []) keys))
    step (seen, dups) key
        | Set.member key.keyName seen = (seen, key.keyName : dups)
        | otherwise = (Set.insert key.keyName seen, dups)

-- * Variable lookup and value parsers

--
-- Each parser receives the raw value and returns either the expected form (for the
-- error message) or the parsed value. An empty string is always a failure rather than
-- an absent value: `EN_PORT=` is a mistake, not a request for the default.

type Parser a = String -> Either Text a

requiredIn :: Map String String -> String -> Text -> Either Text String
requiredIn environment name hint =
    case Map.lookup name environment of
        Just value | not (null value) -> Right value
        _ -> Left ("Missing " <> Text.pack name <> ": " <> hint)

optionalIn :: Map String String -> String -> Parser a -> Either Text (Maybe a)
optionalIn environment name parser =
    case Map.lookup name environment of
        Nothing -> Right Nothing
        Just value -> Just <$> first (invalidMessage name value) (parser value)

withDefaultIn :: Map String String -> String -> a -> Parser a -> Either Text a
withDefaultIn environment name fallback parser =
    case Map.lookup name environment of
        Nothing -> Right fallback
        Just value -> first (invalidMessage name value) (parser value)

invalidMessage :: String -> String -> Text -> Text
invalidMessage name value expected =
    "Invalid " <> Text.pack name <> "=" <> Text.pack value <> ": expected " <> expected

databaseUrlHint :: Text
databaseUrlHint =
    "a PostgreSQL connection string, e.g. EN_DATABASE_URL='postgresql://user@localhost:5432/en'."

nonEmptyString :: Parser String
nonEmptyString value
    | null value = Left "a non-empty value"
    | otherwise = Right value

nonNegative :: Parser Int
nonNegative value =
    case readMaybe value of
        Just parsed | parsed >= 0 -> Right parsed
        _ -> Left "a non-negative integer"

positive :: Parser Int
positive value =
    case readMaybe value of
        Just parsed | parsed >= 1 -> Right parsed
        _ -> Left "a positive integer"

bounded :: Int -> Int -> Parser Int
bounded low high value =
    case readMaybe value of
        Just parsed | parsed >= low && parsed <= high -> Right parsed
        _ ->
            Left $
                "an integer in "
                    <> Text.pack (show low)
                    <> ".."
                    <> Text.pack (show high)

nonNegativeDouble :: Parser Double
nonNegativeDouble value =
    case readMaybe value of
        Just parsed | parsed >= 0 -> Right parsed
        _ -> Left "a non-negative number"

boolean :: Parser Bool
boolean value =
    case map toLower value of
        "true" -> Right True
        "false" -> Right False
        _ -> Left "true or false"

{- | Ask PostgreSQL whether @EN_GC_WINDOW@ is a positive interval.

Its only consumer is PostgreSQL (@now() - $1::interval@ in the horizon query), whose
interval grammar is large; reimplementing it in Haskell would drift. One round trip
buys exact-authority validation and a positivity check -- a zero or negative window
would put every consistency token behind the garbage-collection horizon immediately.

This runs after the database is reachable but before the port is bound, so it is still
a startup failure and not a first-request surprise.
-}
validateGcWindow :: (forall a. Session a -> IO (Either Text a)) -> Text -> IO (Either Text ())
validateGcWindow runDbSession window =
    runDbSession (Session.statement window positiveIntervalStatement) >>= \case
        Left err -> pure (Left (invalidInterval ("PostgreSQL rejected it: " <> err)))
        Right False -> pure (Left (invalidInterval "it is not a positive interval"))
        Right True -> pure (Right ())
  where
    invalidInterval reason =
        "Invalid EN_GC_WINDOW="
            <> window
            <> ": "
            <> reason
            <> "\nExpected a positive PostgreSQL interval, e.g. '24 hours' or '7 days'."
    positiveIntervalStatement =
        Statement.preparable
            "SELECT ($1::interval) > '0'::interval"
            (Encoders.param (Encoders.nonNullable Encoders.text))
            (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.bool)))
