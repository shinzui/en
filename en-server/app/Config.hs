-- | Every environment variable @en-server@ reads, parsed and validated in one place.
--
-- Configuration is read once, wholly, before anything else happens: no port is bound, no
-- connection is opened, and no schema is loaded until every variable has been accepted.
-- A rejected value names itself, its value, and the form expected.
--
-- Parsing is pure. 'loadServerConfig' snapshots the environment into a map and hands it to
-- 'parseServerConfig', so the rules are testable without a process to configure. Failures
-- come back as 'Left', not as an exception: @Main@ renders the message to stderr and exits
-- with status 1, rather than letting a @fail@-in-@IO@ surface as
-- @en-server: Uncaught exception … user error (…)@ wrapped around an otherwise good
-- message.
--
-- Warnings travel alongside the config rather than being printed where they are found, so
-- that a configuration that ultimately fails to parse does not first emit advice about a
-- setting that will never take effect.
module Config
  ( ServerConfig (..),
    SharedConfig (..),
    Tenancy (..),
    TenantName (..),
    TenantConfig (..),
    renderTenantName,
    tenantVariable,
    tenantVariableSuffixes,
    StoreConfig (..),
    PoolConfig (..),
    TlsConfig (..),
    BiscuitConfig (..),
    loadServerConfig,
    loadStoreConfig,
    loadTenantStoreConfig,
    parseServerConfig,
    parseTenantStoreConfig,
    parseTenantNames,
    validateGcWindow,
    knownVariables,
    storeVariables,
  )
where

import Auth.Biscuit (SecretKey)
import Data.Bifunctor (first)
import Data.ByteString qualified as ByteString
import Data.Char (isAsciiLower, isDigit, toLower, toUpper)
import Data.Foldable (traverse_)
import Data.Generics.Labels ()
import Data.List (isPrefixOf, sortOn)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import En.Biscuit.Keys (IssuerKeyId, parseSigningKeyText)
import En.Budget (EvaluationBudget (..))
import En.Prelude
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Session (Session)
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Maintenance (MaintenanceConfig (..))
import Middleware (ApiKey (..), AuthConfig (..), KeyRole (..), RateLimitConfig (..))
import System.Environment (getEnvironment, lookupEnv)
import Telemetry (TelemetryConfig (..))
import Text.Read (readMaybe)

data PoolConfig = PoolConfig
  { size :: !Int,
    acquisitionTimeoutMs :: !Int,
    idlenessTimeoutMs :: !Int,
    maxLifetimeMs :: !Int
  }
  deriving stock (Generic)

-- | Both files or neither; exactly one is a configuration error.
data TlsConfig = TlsConfig
  { certFile :: !FilePath,
    keyFile :: !FilePath
  }
  deriving stock (Generic)

-- | Issuer configuration for @POST \/v1\/grants@, present only when
-- @EN_BISCUIT_ISSUER_SECRET_KEY@ is set.
--
-- The key material is parsed once, at startup: a malformed key aborts before the
-- port binds rather than surfacing on the first mint. The active schema hash the
-- grants are stamped with is /not/ here — the handler reads it from the request-time
-- schema snapshot, so a @SIGHUP@ reload cannot mint under a hash the check did not
-- evaluate under.
data BiscuitConfig = BiscuitConfig
  { issuerKeyId :: !IssuerKeyId,
    -- | Never logged.
    issuerSecretKey :: !SecretKey,
    defaultTtlSeconds :: !Int,
    maxTtlSeconds :: !Int
  }
  deriving stock (Generic)

-- | What it takes to open the store and speak to it correctly.
--
-- Split out of 'ServerConfig' because @en-server import@ and @en-server export@ bind
-- no port and serve no request: demanding API keys, a rate limit, or TLS material
-- from an operator running a bulk load would be configuration theatre, and refusing
-- to start without them -- which 'loadServerConfig' rightly does -- would refuse a
-- command that has nothing to authenticate.
data StoreConfig = StoreConfig
  { databaseUrl :: !Text,
    -- | A PostgreSQL interval. Only PostgreSQL can validate it; see 'validateGcWindow'.
    gcWindow :: !Text,
    -- | Reading and parsing the file stays in @Main@; this is only the path.
    schemaPath :: !(Maybe FilePath),
    pool :: !PoolConfig
  }
  deriving stock (Generic)

-- | A tenant's name, as declared in @EN_TENANTS@: @[a-z][a-z0-9-]{0,30}@.
newtype TenantName = TenantName Text
  deriving stock (Eq, Ord, Show)

renderTenantName :: TenantName -> Text
renderTenantName (TenantName name) = name

-- | @EN_TENANT_\<SEGMENT\>_\<suffix\>@, where the segment is the name upper-cased with @-@
-- replaced by @_@. Names cannot contain @_@, so two names never share a segment.
tenantVariable :: TenantName -> String -> String
tenantVariable (TenantName name) suffix =
  "EN_TENANT_" <> map segmentChar (Text.unpack name) <> "_" <> suffix
  where
    segmentChar '-' = '_'
    segmentChar c = toUpper c

-- | Every per-tenant setting, as the suffix after @EN_TENANT_\<SEGMENT\>_@. A variable with
-- the @EN_TENANT_@ prefix that is not one of these for a declared tenant fails startup, so a
-- typo cannot be silently ignored.
tenantVariableSuffixes :: [String]
tenantVariableSuffixes =
  [ "API_KEYS_READ_ONLY",
    "API_KEYS_READ_WRITE",
    "BISCUIT_ISSUER_SECRET_KEY",
    "DATABASE_URL",
    "EXPECTED_DATASTORE_ID",
    "GC_WINDOW",
    "POOL_SIZE",
    "SCHEMA_PATH",
    "SCHEMA_RELOAD_FORCE"
  ]

-- | Everything that belongs to one datastore: where it lives, which schema it serves, who
-- may call it, and whether it mints grants. Legacy mode has exactly one, read from the
-- unprefixed variables.
data TenantConfig = TenantConfig
  { store :: !StoreConfig,
    auth :: !AuthConfig,
    -- | Issuer configuration for @POST \/v1\/grants@. 'Nothing' when
    --     @EN_BISCUIT_ISSUER_SECRET_KEY@ is unset, which disables the endpoint. When it
    --     is set, caller authentication must be active or startup is refused — a
    --     minting endpoint on an unauthenticated server would hand bearer tokens to
    --     anyone.
    biscuit :: !(Maybe BiscuitConfig),
    -- | Activate this store's schema on @SIGHUP@ even when it strands live grants. In
    --     tenant mode @EN_TENANT_\<NAME\>_SCHEMA_RELOAD_FORCE@, defaulting to
    --     @EN_SCHEMA_RELOAD_FORCE@.
    schemaReloadForce :: !Bool,
    -- | Tenant mode's @EN_TENANT_\<NAME\>_EXPECTED_DATASTORE_ID@: the datastore id this
    --     tenant's database must already report. It is compared, never assigned; legacy
    --     mode has none.
    expectedDatastoreId :: !(Maybe Text)
  }
  deriving stock (Generic)

-- | How many datastores this process serves.
--
-- Legacy mode is not a one-entry tenant table: it is its own constructor, so the server it
-- selects can dispatch to its single stack directly, with no tenant lookup on the request
-- path.
data Tenancy
  = SingleStore !TenantConfig
  | -- | @EN_TENANTS@ is set: each tenant in declaration order, each with its own keys.
    Tenants !(NonEmpty (TenantName, TenantConfig))
  deriving stock (Generic)

data ServerConfig = ServerConfig
  { shared :: !SharedConfig,
    tenancy :: !Tenancy
  }
  deriving stock (Generic)

-- | The settings that belong to the process rather than to a datastore. Where one names
-- a per-datastore resource (a cache, a rate-limit bucket map, a maintenance loop), every
-- datastore gets its own resource of that size.
data SharedConfig = SharedConfig
  { port :: !Int,
    optimizedRevisionTtlMs :: !Int,
    tupleReadMaxEntries :: !Int,
    decisionMaxEntries :: !Int,
    maxBatchSize :: !Int,
    deadlineDefaultMillis :: !Int,
    deadlineMaxMillis :: !Int,
    -- | Static evaluation bounds for check, lookup, and expand. Distinct from the
    --     deadline above, which is a clock rather than a bound: raising the depth budget
    --     buys a slow lookup no more time.
    budget :: !EvaluationBudget,
    rateLimit :: !RateLimitConfig,
    maintenance :: !MaintenanceConfig,
    -- | Whether this process initializes the OpenTelemetry SDK. Exporter and sampler
    --     configuration remains under the SDK's standard @OTEL_*@ variables.
    telemetry :: !TelemetryConfig,
    tls :: !(Maybe TlsConfig),
    -- | Activate a schema on @SIGHUP@ even when it strands live grants.
    --
    --     Off by default: a reload that orphans grants is refused, with the report in the log.
    --     An operator removing a feature legitimately wants its grants dead, and this is how
    --     they say so — explicitly, in the process environment, before the signal arrives.
    schemaReloadForce :: !Bool
  }
  deriving stock (Generic)

-- | Every variable the server reads. Kept exhaustive so the documented configuration
-- reference can be checked against it.
knownVariables :: [String]
knownVariables =
  [ "EN_API_KEYS_READ_ONLY",
    "EN_API_KEYS_READ_WRITE",
    "EN_AUTH_DISABLED",
    "EN_BISCUIT_DEFAULT_TTL_SECONDS",
    "EN_BISCUIT_ISSUER_SECRET_KEY",
    "EN_BISCUIT_MAX_TTL_SECONDS",
    "EN_DATABASE_URL",
    "EN_DECISION_CACHE_MAX_ENTRIES",
    "EN_GC_WINDOW",
    "EN_LOOKUP_DEADLINE_DEFAULT_MS",
    "EN_LOOKUP_DEADLINE_MAX_MS",
    "EN_MAINTENANCE_BATCH_SIZE",
    "EN_MAINTENANCE_INTERVAL_SECONDS",
    "EN_MAX_BATCH_SIZE",
    "EN_MAX_DEPTH",
    "EN_OPTIMIZED_REVISION_CACHE_TTL_MS",
    "EN_PAGE_LIMIT",
    "EN_POOL_ACQUISITION_TIMEOUT_MS",
    "EN_POOL_IDLENESS_TIMEOUT_MS",
    "EN_POOL_MAX_LIFETIME_MS",
    "EN_POOL_SIZE",
    "EN_PORT",
    "EN_RATE_LIMIT_BURST",
    "EN_RATE_LIMIT_RPS",
    "EN_RESULT_CAP",
    "EN_SCHEMA_PATH",
    "EN_SCHEMA_RELOAD_FORCE",
    "EN_TELEMETRY_ENABLED",
    "EN_TENANTS",
    "EN_TLS_CERT_FILE",
    "EN_TLS_KEY_FILE",
    "EN_TUPLE_READ_CACHE_MAX_ENTRIES"
  ]

-- | The subset of 'knownVariables' the store itself reads.
--
-- Everything a bulk import or export needs, and nothing a request-serving process
-- adds. Kept as a projection of 'knownVariables' rather than a second list so a new
-- store variable cannot be added to one and forgotten in the other.
storeVariables :: [String]
storeVariables =
  filter isStoreVariable knownVariables
  where
    isStoreVariable name =
      name `elem` ["EN_DATABASE_URL", "EN_GC_WINDOW", "EN_SCHEMA_PATH"]
        || "EN_POOL_" `isPrefixOf` name

-- | Snapshot the environment, then parse it. Returns the config and any warnings.
--
-- Per-tenant variable names are not known in advance, so every variable beginning
-- @EN_TENANT_@ is snapshotted too; the parser rejects those that belong to no declared
-- tenant.
loadServerConfig :: IO (Either Text (ServerConfig, [Text]))
loadServerConfig = do
  present <- catMaybes <$> traverse readVariable knownVariables
  tenantVariables <- filter (("EN_TENANT_" `isPrefixOf`) . fst) <$> getEnvironment
  pure (parseServerConfig (Map.fromList (present <> tenantVariables)))
  where
    readVariable name = fmap ((,) name) <$> lookupEnv name

-- | As 'loadServerConfig', but reading only what the store needs.
--
-- The serving variables are not merely ignored, they are never read: an operator
-- running @en-server import@ against a production database should not have to
-- supply the API keys of a server they are not starting.
loadStoreConfig :: IO (Either Text (StoreConfig, [Text]))
loadStoreConfig = do
  present <- catMaybes <$> traverse readVariable storeVariables
  pure (parseStoreConfig (Map.fromList present))
  where
    readVariable name = fmap ((,) name) <$> lookupEnv name

-- | One tenant's store, for the subcommands run with @--tenant NAME@.
--
-- Reads @EN_TENANTS@, that tenant's @EN_TENANT_\<NAME\>_*@ store variables and the
-- process-wide pool and GC defaults, and nothing a serving process adds: no keys, no rate
-- limit, no TLS, exactly as 'loadStoreConfig' for legacy mode.
loadTenantStoreConfig :: TenantName -> IO (Either Text StoreConfig)
loadTenantStoreConfig name = do
  environment <- getEnvironment
  let wanted variable = variable `elem` storeVariables || variable == "EN_TENANTS" || "EN_TENANT_" `isPrefixOf` variable
  pure (parseTenantStoreConfig name (Map.fromList (filter (wanted . fst) environment)))

-- | Pure part of 'loadTenantStoreConfig'. The name must be one @EN_TENANTS@ declares.
parseTenantStoreConfig :: TenantName -> Map String String -> Either Text StoreConfig
parseTenantStoreConfig name environment = do
  declared <- case Map.lookup "EN_TENANTS" environment of
    Nothing -> Left "--tenant needs EN_TENANTS: without it there is one store, read from EN_DATABASE_URL."
    Just raw -> parseTenantNames raw
  unless (name `elem` declared) $
    Left $
      "Unknown tenant "
        <> renderTenantName name
        <> "; EN_TENANTS declares "
        <> Text.intercalate ", " (renderTenantName <$> NonEmpty.toList declared)
        <> "."
  defaultPool <- parsePool environment
  defaultGcWindow <- Text.pack <$> withDefaultIn environment "EN_GC_WINDOW" "24 hours" nonEmptyString
  databaseUrl <- requiredIn environment (tenantVariable name "DATABASE_URL") ("a PostgreSQL connection string for tenant " <> renderTenantName name <> ".")
  schemaPath <- requiredIn environment (tenantVariable name "SCHEMA_PATH") ("the schema file tenant " <> renderTenantName name <> " serves.")
  poolSize <- withDefaultIn environment (tenantVariable name "POOL_SIZE") (defaultPool ^. #size) positive
  gcWindow <- Text.pack <$> withDefaultIn environment (tenantVariable name "GC_WINDOW") (Text.unpack defaultGcWindow) nonEmptyString
  pure
    StoreConfig
      { databaseUrl = Text.pack databaseUrl,
        gcWindow,
        schemaPath = Just schemaPath,
        pool = defaultPool & #size .~ poolSize
      }

parseStoreConfig :: Map String String -> Either Text (StoreConfig, [Text])
parseStoreConfig environment = do
  databaseUrl <- required "EN_DATABASE_URL" databaseUrlHint
  gcWindow <- Text.pack <$> withDefault "EN_GC_WINDOW" "24 hours" nonEmptyString
  schemaPath <- optional "EN_SCHEMA_PATH" nonEmptyString
  pool <- parsePool environment
  pure
    ( StoreConfig
        { databaseUrl = Text.pack databaseUrl,
          gcWindow,
          schemaPath,
          pool
        },
      schemaWarnings schemaPath
    )
  where
    required :: String -> Text -> Either Text String
    required = requiredIn environment

    optional :: forall a. String -> Parser a -> Either Text (Maybe a)
    optional = optionalIn environment

    withDefault :: forall a. String -> a -> Parser a -> Either Text a
    withDefault = withDefaultIn environment

-- | Parse a snapshot of the environment. @EN_TENANTS@ selects tenant mode; without it the
-- server is in legacy mode and reads exactly the variables it always has.
parseServerConfig :: Map String String -> Either Text (ServerConfig, [Text])
parseServerConfig environment
  | Map.member "EN_TENANTS" environment = parseTenantServerConfig environment
  | otherwise = do
      rejectTenantVariablesWithoutTenants environment
      (store, storeWarnings) <- parseStoreConfig environment
      shared <- parseSharedConfig environment
      (auth, authWarnings) <- parseAuth environment
      biscuit <- parseBiscuit "EN_BISCUIT_ISSUER_SECRET_KEY" environment
      checkMintingAuthGate auth biscuit
      pure
        ( ServerConfig
            { shared,
              tenancy = SingleStore TenantConfig {store, auth, biscuit, schemaReloadForce = shared ^. #schemaReloadForce, expectedDatastoreId = Nothing}
            },
          authWarnings <> storeWarnings
        )

parseSharedConfig :: Map String String -> Either Text SharedConfig
parseSharedConfig environment = do
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
  telemetryEnabled <- withDefault "EN_TELEMETRY_ENABLED" False boolean
  schemaReloadForce <- withDefault "EN_SCHEMA_RELOAD_FORCE" False boolean
  pure
    SharedConfig
      { port,
        optimizedRevisionTtlMs,
        tupleReadMaxEntries,
        decisionMaxEntries,
        maxBatchSize,
        deadlineDefaultMillis,
        deadlineMaxMillis,
        budget,
        rateLimit,
        maintenance,
        telemetry = if telemetryEnabled then TelemetryEnabled else TelemetryDisabled,
        tls,
        schemaReloadForce
      }
  where
    withDefault :: forall a. String -> a -> Parser a -> Either Text a
    withDefault = withDefaultIn environment

-- * Tenant mode

-- | The variables that configure legacy mode's one store, its keys and its issuer. Each
-- has a per-tenant replacement, and setting one beside @EN_TENANTS@ is refused rather than
-- applied to some or all tenants.
legacyOnlyVariables :: [String]
legacyOnlyVariables =
  [ "EN_DATABASE_URL",
    "EN_SCHEMA_PATH",
    "EN_API_KEYS_READ_WRITE",
    "EN_API_KEYS_READ_ONLY",
    "EN_AUTH_DISABLED",
    "EN_BISCUIT_ISSUER_SECRET_KEY"
  ]

parseTenantServerConfig :: Map String String -> Either Text (ServerConfig, [Text])
parseTenantServerConfig environment = do
  traverse_ rejectLegacyVariable legacyOnlyVariables
  names <- parseTenantNames (Map.findWithDefault "" "EN_TENANTS" environment)
  rejectUnknownTenantVariables names environment
  shared <- parseSharedConfig environment
  defaultPool <- parsePool environment
  defaultGcWindow <- Text.pack <$> withDefaultIn environment "EN_GC_WINDOW" "24 hours" nonEmptyString
  tenants <- traverse (\name -> (name,) <$> parseTenant environment shared defaultPool defaultGcWindow name) names
  rejectSharedSecrets tenants
  rejectSharedDatabases tenants
  pure (ServerConfig {shared, tenancy = Tenants tenants}, [])
  where
    rejectLegacyVariable name
      | Map.member name environment =
          Left $
            "EN_TENANTS is set, so "
              <> Text.pack name
              <> " must not be: in tenant mode every store, schema, key and issuer is configured per tenant with EN_TENANT_<NAME>_* variables."
      | otherwise = Right ()

parseTenantNames :: String -> Either Text (NonEmpty TenantName)
parseTenantNames raw = do
  names <- traverse validName (map Text.strip (Text.splitOn "," (Text.pack raw)))
  nonEmpty <- case names of
    [] -> Left "Invalid EN_TENANTS: expected a comma-separated list of tenant names"
    first' : rest -> Right (first' :| rest)
  case duplicatesOf (NonEmpty.toList nonEmpty) of
    [] -> Right (TenantName <$> nonEmpty)
    duplicated -> Left ("Invalid EN_TENANTS: duplicate tenant name(s) " <> Text.intercalate ", " duplicated)
  where
    validName name
      | Text.null name =
          Left ("Invalid EN_TENANTS=" <> Text.pack raw <> ": empty tenant name (check for a stray comma)")
      | otherwise = case Text.uncons name of
          Just (first', rest)
            | isAsciiLower first'
                && Text.length name <= 31
                && Text.all (\c -> isAsciiLower c || isDigit c || c == '-') rest ->
                Right name
          _ ->
            Left $
              "Invalid EN_TENANTS: tenant name \""
                <> name
                <> "\" must be a lower-case letter followed by at most 30 lower-case letters, digits or '-'"

-- | Every @EN_TENANT_@ variable must be one of 'tenantVariableSuffixes' for a declared tenant.
rejectUnknownTenantVariables :: NonEmpty TenantName -> Map String String -> Either Text ()
rejectUnknownTenantVariables names environment =
  case filter (not . declared) (filter ("EN_TENANT_" `isPrefixOf`) (Map.keys environment)) of
    [] -> Right ()
    unknown : _ ->
      Left $
        "Unknown variable "
          <> Text.pack unknown
          <> ": it is not a setting of any tenant in EN_TENANTS ("
          <> Text.intercalate ", " (renderTenantName <$> NonEmpty.toList names)
          <> "). Per-tenant settings are EN_TENANT_<NAME>_ followed by one of "
          <> Text.intercalate ", " (Text.pack <$> tenantVariableSuffixes)
          <> "."
  where
    declared variable =
      or [variable == tenantVariable name suffix | name <- NonEmpty.toList names, suffix <- tenantVariableSuffixes]

-- | Per-tenant variables are meaningless without @EN_TENANTS@; refuse rather than ignore.
rejectTenantVariablesWithoutTenants :: Map String String -> Either Text ()
rejectTenantVariablesWithoutTenants environment =
  case filter ("EN_TENANT_" `isPrefixOf`) (Map.keys environment) of
    [] -> Right ()
    variable : _ ->
      Left $
        Text.pack variable
          <> " is set but EN_TENANTS is not. Declare the tenants with EN_TENANTS=name,... or remove the per-tenant variables."

parseTenant :: Map String String -> SharedConfig -> PoolConfig -> Text -> TenantName -> Either Text TenantConfig
parseTenant environment shared defaultPool defaultGcWindow name = do
  databaseUrl <- requiredIn environment (variable "DATABASE_URL") ("a PostgreSQL connection string for tenant " <> tenant <> ".")
  schemaPath <- requiredIn environment (variable "SCHEMA_PATH") ("the schema file tenant " <> tenant <> " serves.")
  poolSize <- withDefaultIn environment (variable "POOL_SIZE") (defaultPool ^. #size) positive
  gcWindow <- Text.pack <$> withDefaultIn environment (variable "GC_WINDOW") (Text.unpack defaultGcWindow) nonEmptyString
  readWrite <- parseKeyListIn environment (variable "API_KEYS_READ_WRITE") ReadWrite
  readOnly <- parseKeyListIn environment (variable "API_KEYS_READ_ONLY") ReadOnly
  keys <- case readWrite <> readOnly of
    [] ->
      Left $
        "Tenant "
          <> tenant
          <> " has no API key: set "
          <> Text.pack (variable "API_KEYS_READ_WRITE")
          <> " and/or "
          <> Text.pack (variable "API_KEYS_READ_ONLY")
          <> ". A key is the only way a request reaches its tenant."
    keys -> Right keys
  rejectDuplicateNames
    (Text.pack (variable "API_KEYS_READ_WRITE") <> " and " <> Text.pack (variable "API_KEYS_READ_ONLY"))
    keys
  biscuit <- parseBiscuit (variable "BISCUIT_ISSUER_SECRET_KEY") environment
  schemaReloadForce <- withDefaultIn environment (variable "SCHEMA_RELOAD_FORCE") (shared ^. #schemaReloadForce) boolean
  expectedDatastoreId <- fmap Text.pack <$> optionalIn environment (variable "EXPECTED_DATASTORE_ID") nonEmptyString
  pure
    TenantConfig
      { store =
          StoreConfig
            { databaseUrl = Text.pack databaseUrl,
              gcWindow,
              schemaPath = Just schemaPath,
              pool = defaultPool & #size .~ poolSize
            },
        auth = AuthKeys keys,
        biscuit,
        schemaReloadForce,
        expectedDatastoreId
      }
  where
    variable = tenantVariable name
    tenant = renderTenantName name

-- | A secret selects a tenant, so it must belong to exactly one tenant and one key. The
-- message names tenants and keys, never the secret.
rejectSharedSecrets :: NonEmpty (TenantName, TenantConfig) -> Either Text ()
rejectSharedSecrets tenants =
  case clashes of
    [] -> Right ()
    ((tenantA, keyA), (tenantB, keyB)) : _ ->
      Left $
        "The same API key secret is configured for key "
          <> keyA
          <> " of tenant "
          <> renderTenantName tenantA
          <> " and key "
          <> keyB
          <> " of tenant "
          <> renderTenantName tenantB
          <> ". A secret must belong to exactly one key of one tenant."
  where
    owned =
      [ (key ^. #keySecret, (name, key ^. #keyName))
      | (name, config) <- NonEmpty.toList tenants,
        AuthKeys keys <- [config ^. #auth],
        key <- keys
      ]
    clashes = adjacentClashes (sortOn fst owned)
    adjacentClashes = \case
      (secretA, ownerA) : rest@((secretB, ownerB) : _)
        | secretA == secretB -> (ownerA, ownerB) : adjacentClashes rest
        | otherwise -> adjacentClashes rest
      _ -> []

-- | Two tenants on one database would share tuples, tokens and garbage collection. This
-- catches the same URL text; the server also refuses two tenants that resolve to the same
-- datastore id through different URLs.
rejectSharedDatabases :: NonEmpty (TenantName, TenantConfig) -> Either Text ()
rejectSharedDatabases tenants =
  case [(a, b) | (i, (a, urlA)) <- numbered, (j, (b, urlB)) <- numbered, i < j, urlA == urlB] of
    [] -> Right ()
    (a, b) : _ ->
      Left $
        Text.pack (tenantVariable a "DATABASE_URL")
          <> " and "
          <> Text.pack (tenantVariable b "DATABASE_URL")
          <> " are the same URL. Each tenant needs its own database."
  where
    numbered =
      zip [0 :: Int ..] [(name, config ^. #store . #databaseUrl) | (name, config) <- NonEmpty.toList tenants]

duplicatesOf :: [Text] -> [Text]
duplicatesOf values = reverse (snd (foldl' step (Set.empty, []) values))
  where
    step (seen, dups) value
      | Set.member value seen = (seen, value : dups)
      | otherwise = (Set.insert value seen, dups)

schemaWarnings :: Maybe FilePath -> [Text]
schemaWarnings = \case
  Just _ -> []
  Nothing ->
    [ "WARNING: EN_SCHEMA_PATH not set; serving the built-in demo schema. Set EN_SCHEMA_PATH=/path/to/schema.en to serve your own model."
    ]

-- | The lookup ceiling must not sit below the default, or every request that omits
-- @deadlineMillis@ would be clamped to a budget the operator never intended.
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

-- | The engine's static evaluation bounds.
--
-- All three are @positive@: a zero depth budget answers nothing, a zero read batch
-- never advances a cursor, and a zero result cap returns an empty page while
-- claiming truncation. Defaults match 'En.Budget.defaultEvaluationBudget', so an
-- unset environment behaves exactly as en did when these were source constants.
parseBudget :: Map String String -> Either Text EvaluationBudget
parseBudget environment = do
  maxDepth <- withDefault "EN_MAX_DEPTH" 25 positive
  pageLimit <- withDefault "EN_PAGE_LIMIT" 1000 positive
  resultCap <- withDefault "EN_RESULT_CAP" 1000 positive
  pure EvaluationBudget {maxDepth, pageLimit, resultCap}
  where
    withDefault :: forall a. String -> a -> Parser a -> Either Text a
    withDefault = withDefaultIn environment

parsePool :: Map String String -> Either Text PoolConfig
parsePool environment = do
  size <- withDefault "EN_POOL_SIZE" 10 positive
  acquisitionTimeoutMs <- withDefault "EN_POOL_ACQUISITION_TIMEOUT_MS" 10000 positive
  idlenessTimeoutMs <- withDefault "EN_POOL_IDLENESS_TIMEOUT_MS" 600000 positive
  maxLifetimeMs <- withDefault "EN_POOL_MAX_LIFETIME_MS" 3600000 positive
  pure PoolConfig {size, acquisitionTimeoutMs, idlenessTimeoutMs, maxLifetimeMs}
  where
    withDefault :: forall a. String -> a -> Parser a -> Either Text a
    withDefault = withDefaultIn environment

parseTls :: Map String String -> Either Text (Maybe TlsConfig)
parseTls environment = do
  cert <- optional "EN_TLS_CERT_FILE" nonEmptyString
  key <- optional "EN_TLS_KEY_FILE" nonEmptyString
  case (cert, key) of
    (Nothing, Nothing) -> Right Nothing
    (Just certFile, Just keyFile) -> Right (Just TlsConfig {certFile, keyFile})
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
    else Right RateLimitConfig {ratePerSecond, burst}
  where
    withDefault :: forall a. String -> a -> Parser a -> Either Text a
    withDefault = withDefaultIn environment

parseMaintenance :: Map String String -> Either Text MaintenanceConfig
parseMaintenance environment = do
  intervalSeconds <- withDefault "EN_MAINTENANCE_INTERVAL_SECONDS" 600 nonNegative
  batchSize <- withDefault "EN_MAINTENANCE_BATCH_SIZE" 1000 positive
  pure MaintenanceConfig {intervalSeconds, batchSize}
  where
    withDefault :: forall a. String -> a -> Parser a -> Either Text a
    withDefault = withDefaultIn environment

-- | Read both key tiers. Fails closed: with no keys and no explicit opt-out this aborts
-- startup before the port is bound.
parseAuth :: Map String String -> Either Text (AuthConfig, [Text])
parseAuth environment = do
  readWrite <- parseKeyListIn environment "EN_API_KEYS_READ_WRITE" ReadWrite
  readOnly <- parseKeyListIn environment "EN_API_KEYS_READ_ONLY" ReadOnly
  disabled <- withDefaultIn environment "EN_AUTH_DISABLED" False boolean
  case readWrite <> readOnly of
    [] | disabled -> Right (AuthDisabled, [authDisabledWarning])
    [] -> Left noKeysConfigured
    keys -> do
      rejectDuplicateNames "EN_API_KEYS_READ_WRITE and EN_API_KEYS_READ_ONLY" keys
      pure
        ( AuthKeys keys,
          [authIgnoredWarning | disabled]
        )

-- | A comma-separated list of @name:secret@ entries. Absent or blank is an empty list.
parseKeyListIn :: Map String String -> String -> KeyRole -> Either Text [ApiKey]
parseKeyListIn environment name role =
  case Map.lookup name environment of
    Nothing -> Right []
    Just raw
      | Text.null (Text.strip (Text.pack raw)) -> Right []
      | otherwise ->
          traverse
            (parseKeyEntry name role)
            (map Text.strip (Text.splitOn "," (Text.pack raw)))

-- | Parse the issuer configuration for @POST \/v1\/grants@.
--
-- Absent @EN_BISCUIT_ISSUER_SECRET_KEY@ — or an empty one, treated as absent as the
-- key lists are — disables minting ('Nothing'). A present but malformed key aborts
-- startup: a half-configured issuer must never serve. The TTL bounds default to
-- 300s and 3600s and the maximum must not sit below the default.
parseBiscuit :: String -> Map String String -> Either Text (Maybe BiscuitConfig)
parseBiscuit keyVariable environment =
  case Map.lookup keyVariable environment of
    Nothing -> Right Nothing
    Just raw
      | Text.null (Text.strip (Text.pack raw)) -> Right Nothing
      | otherwise -> do
          (issuerKeyId, issuerSecretKey) <-
            first
              (\reason -> "Invalid " <> Text.pack keyVariable <> ": " <> reason)
              (parseSigningKeyText (Text.pack raw))
          defaultTtlSeconds <- withDefault "EN_BISCUIT_DEFAULT_TTL_SECONDS" 300 positive
          maxTtlSeconds <- withDefault "EN_BISCUIT_MAX_TTL_SECONDS" 3600 positive
          if maxTtlSeconds < defaultTtlSeconds
            then Left (ttlOrderingError defaultTtlSeconds maxTtlSeconds)
            else
              Right
                ( Just
                    BiscuitConfig
                      { issuerKeyId,
                        issuerSecretKey,
                        defaultTtlSeconds,
                        maxTtlSeconds
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

-- | Refuse to start a server that mints grants but authenticates no caller.
--
-- A grant-minting endpoint on an unauthenticated server would hand signed bearer
-- tokens to anyone with network reach, so this is a hard startup failure, never a
-- warning (docs/plans/33, docs/plans/57).
checkMintingAuthGate :: AuthConfig -> Maybe BiscuitConfig -> Either Text ()
checkMintingAuthGate auth = \case
  Nothing -> Right ()
  Just _ -> case auth of
    AuthKeys _ -> Right ()
    AuthDisabled -> Left mintingWithoutAuthError

mintingWithoutAuthError :: Text
mintingWithoutAuthError =
  Text.unlines
    [ "EN_BISCUIT_ISSUER_SECRET_KEY is set but caller authentication is not enabled.",
      "A grant-minting endpoint on an unauthenticated server would hand bearer",
      "tokens to anyone. Enable authentication (docs/plans/33) or unset the key."
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
    [ "No API keys configured; refusing to start an unauthenticated authorization service.",
      "Set EN_API_KEYS_READ_WRITE and/or EN_API_KEYS_READ_ONLY to a comma-separated list",
      "of name:secret entries, where each secret is at least 16 bytes. For example:",
      "",
      "    EN_API_KEYS_READ_WRITE='deployer:S3cret-value-at-least-16'",
      "    EN_API_KEYS_READ_ONLY='reader:another-secret-at-least-16'",
      "",
      "For local development only, set EN_AUTH_DISABLED=true to serve without authentication."
    ]

-- | Parse one @name:secret@ entry. A malformed entry aborts startup rather than being
-- skipped: authentication configuration must never partially parse.
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
                    else Right ApiKey {keyName = name, keySecret = secretBytes, keyRole = role}
  where
    invalid reason = Left ("Invalid " <> Text.pack envName <> ": " <> reason)
    quoted value = "\"" <> value <> "\""

minimumSecretBytes :: Int
minimumSecretBytes = 16

-- | Names identify callers in logs and rate-limit buckets, so they must be unique within
-- the keys of one store (in tenant mode, a caller is the pair of tenant and key name).
rejectDuplicateNames :: Text -> [ApiKey] -> Either Text ()
rejectDuplicateNames scope keys =
  case duplicatesOf (map (^. #keyName) keys) of
    [] -> Right ()
    names ->
      Left $
        "Duplicate API key name(s) across "
          <> scope
          <> ": "
          <> Text.intercalate ", " names

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

-- | Ask PostgreSQL whether @EN_GC_WINDOW@ is a positive interval.
--
-- Its only consumer is PostgreSQL (@now() - $1::interval@ in the horizon query), whose
-- interval grammar is large; reimplementing it in Haskell would drift. One round trip
-- buys exact-authority validation and a positivity check -- a zero or negative window
-- would put every consistency token behind the garbage-collection horizon immediately.
--
-- This runs after the database is reachable but before the port is bound, so it is still
-- a startup failure and not a first-request surprise.
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
