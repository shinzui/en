-- | The configuration rules of @en-server@, exercised through the pure parser.
--
-- One case per rule of tenant mode in
-- docs/plans/73-serve-tenants-selected-by-api-key-each-from-its-own-isolated-stack.md
-- (Milestone 2), plus the proof that an environment unsetVar @EN_TENANTS@ parses exactly as
-- it always has.
module Main (main) where

import Config
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import En.Prelude
import Middleware (AuthConfig (..), KeyRole (..))
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertEqual, assertFailure, testCase)

main :: IO ()
main =
  defaultMain $
    testGroup
      "en-server configuration"
      [ testGroup "legacy mode" legacyCases,
        testGroup "tenant mode accepts" acceptCases,
        testGroup "tenant mode rejects" rejectCases,
        testGroup "subcommand store for --tenant" subcommandCases
      ]

subcommandCases :: [TestTree]
subcommandCases =
  [ testCase "reads only the named tenant's store, needing no keys" do
      store <-
        expectRight . parseTenantStoreConfig (TenantName "beta") . Map.fromList $
          unsetVar "EN_TENANT_BETA_API_KEYS_READ_WRITE" twoTenants <> [("EN_TENANT_BETA_POOL_SIZE", "2")]
      assertEqual "database" "postgresql://localhost/en_beta" (store ^. #databaseUrl)
      assertEqual "schema" (Just "/etc/en/beta.en") (store ^. #schemaPath)
      assertEqual "pool" 2 (store ^. #pool . #size),
    testCase "an undeclared tenant names the declared ones" do
      expectFailure ["Unknown tenant gamma", "alpha, beta"] $
        parseTenantStoreConfig (TenantName "gamma") (Map.fromList twoTenants),
    testCase "--tenant without EN_TENANTS" do
      expectFailure ["--tenant needs EN_TENANTS"] $
        parseTenantStoreConfig (TenantName "alpha") (Map.fromList legacyEnvironment)
  ]

-- * Legacy mode

legacyEnvironment :: [(String, String)]
legacyEnvironment =
  [ ("EN_DATABASE_URL", "postgresql://localhost/en"),
    ("EN_SCHEMA_PATH", "/etc/en/app.en"),
    ("EN_API_KEYS_READ_WRITE", "deployer:deployer-secret-0123456789"),
    ("EN_API_KEYS_READ_ONLY", "reader:reader-secret-0123456789"),
    ("EN_POOL_SIZE", "12")
  ]

legacyCases :: [TestTree]
legacyCases =
  [ testCase "an environment without EN_TENANTS is one store, as before" do
      (config, warnings) <- expectRight (parse legacyEnvironment)
      assertEqual "warnings" [] warnings
      case config ^. #tenancy of
        Tenants _ -> assertFailure "parsed as tenant mode"
        SingleStore tenant -> do
          assertEqual "database" "postgresql://localhost/en" (tenant ^. #store . #databaseUrl)
          assertEqual "schema" (Just "/etc/en/app.en") (tenant ^. #store . #schemaPath)
          assertEqual "pool size" 12 (tenant ^. #store . #pool . #size)
          assertEqual "gc window" "24 hours" (tenant ^. #store . #gcWindow)
          assertEqual "keys" [("deployer", ReadWrite), ("reader", ReadOnly)] (keySummary (tenant ^. #auth))
      assertEqual "port" 8080 (config ^. #shared . #port),
    testCase "legacy mode still requires EN_DATABASE_URL first" do
      expectFailure ["Missing EN_DATABASE_URL"] (parse (drop 1 legacyEnvironment)),
    testCase "a per-tenant variable without EN_TENANTS is refused" do
      expectFailure ["EN_TENANT_ALPHA_POOL_SIZE", "EN_TENANTS is not"] $
        parse (legacyEnvironment <> [("EN_TENANT_ALPHA_POOL_SIZE", "4")])
  ]

-- * Tenant mode

alpha, beta :: [(String, String)]
alpha =
  [ ("EN_TENANT_ALPHA_DATABASE_URL", "postgresql://localhost/en_alpha"),
    ("EN_TENANT_ALPHA_SCHEMA_PATH", "/etc/en/alpha.en"),
    ("EN_TENANT_ALPHA_API_KEYS_READ_WRITE", "writer:alpha-writer-0123456789"),
    ("EN_TENANT_ALPHA_API_KEYS_READ_ONLY", "reader:alpha-reader-0123456789")
  ]
beta =
  [ ("EN_TENANT_BETA_DATABASE_URL", "postgresql://localhost/en_beta"),
    ("EN_TENANT_BETA_SCHEMA_PATH", "/etc/en/beta.en"),
    ("EN_TENANT_BETA_API_KEYS_READ_WRITE", "writer:beta-writer-0123456789")
  ]

twoTenants :: [(String, String)]
twoTenants = ("EN_TENANTS", "alpha,beta") : alpha <> beta

acceptCases :: [TestTree]
acceptCases =
  [ testCase "two tenants, in declaration order, each with its own store and keys" do
      tenants <- expectTenants (parse twoTenants)
      assertEqual "names" [TenantName "alpha", TenantName "beta"] (map fst tenants)
      (a, b) <- twoOf tenants
      assertEqual "alpha database" "postgresql://localhost/en_alpha" (a ^. #store . #databaseUrl)
      assertEqual "alpha schema" (Just "/etc/en/alpha.en") (a ^. #store . #schemaPath)
      assertEqual "alpha keys" [("writer", ReadWrite), ("reader", ReadOnly)] (keySummary (a ^. #auth))
      assertEqual "beta keys" [("writer", ReadWrite)] (keySummary (b ^. #auth))
      assertEqual "default pool size" 10 (a ^. #store . #pool . #size)
      assertEqual "default gc window" "24 hours" (b ^. #store . #gcWindow)
      assertBool "no minting" (isNothing (a ^. #biscuit)),
    testCase "a key name may repeat across tenants (a caller is tenant and name)" do
      -- Both tenants above name a key "writer".
      void (expectTenants (parse twoTenants)),
    testCase "per-tenant pool size and GC window override the process-wide defaults" do
      tenants <-
        expectTenants . parse $
          twoTenants
            <> [ ("EN_POOL_SIZE", "20"),
                 ("EN_GC_WINDOW", "7 days"),
                 ("EN_TENANT_BETA_POOL_SIZE", "3"),
                 ("EN_TENANT_BETA_GC_WINDOW", "2 hours")
               ]
      (a, b) <- twoOf tenants
      assertEqual "alpha pool" 20 (a ^. #store . #pool . #size)
      assertEqual "beta pool" 3 (b ^. #store . #pool . #size)
      assertEqual "alpha gc" "7 days" (a ^. #store . #gcWindow)
      assertEqual "beta gc" "2 hours" (b ^. #store . #gcWindow),
    testCase "a hyphenated name maps to an underscored segment" do
      tenants <-
        expectTenants . parse $
          [ ("EN_TENANTS", "team-a"),
            ("EN_TENANT_TEAM_A_DATABASE_URL", "postgresql://localhost/en_team_a"),
            ("EN_TENANT_TEAM_A_SCHEMA_PATH", "/etc/en/team-a.en"),
            ("EN_TENANT_TEAM_A_API_KEYS_READ_ONLY", "reader:team-a-reader-0123456789")
          ]
      assertEqual "names" [TenantName "team-a"] (map fst tenants),
    testCase "names and keys are trimmed like the legacy lists" do
      tenants <- expectTenants (parse (("EN_TENANTS", " alpha , beta ") : alpha <> beta))
      assertEqual "names" [TenantName "alpha", TenantName "beta"] (map fst tenants),
    testCase "schema reload force is per tenant, defaulting to the process-wide value" do
      tenants <- expectTenants (parse (twoTenants <> [("EN_SCHEMA_RELOAD_FORCE", "true"), ("EN_TENANT_BETA_SCHEMA_RELOAD_FORCE", "false")]))
      (a, b) <- twoOf tenants
      assertBool "alpha inherits true" (a ^. #schemaReloadForce)
      assertBool "beta overrides to false" (not (b ^. #schemaReloadForce)),
    testCase "legacy mode keeps EN_SCHEMA_RELOAD_FORCE" do
      (config, _) <- expectRight (parse (legacyEnvironment <> [("EN_SCHEMA_RELOAD_FORCE", "true")]))
      case config ^. #tenancy of
        SingleStore tenant -> assertBool "force" (tenant ^. #schemaReloadForce)
        Tenants _ -> assertFailure "parsed as tenant mode",
    testCase "process-wide settings still apply" do
      (config, _) <- expectRight (parse (twoTenants <> [("EN_PORT", "9000"), ("EN_RATE_LIMIT_RPS", "5")]))
      assertEqual "port" 9000 (config ^. #shared . #port)
      assertEqual "rate" 5 (config ^. #shared . #rateLimit . #ratePerSecond)
  ]

rejectCases :: [TestTree]
rejectCases =
  [ testCase "an empty EN_TENANTS" do
      expectFailure ["EN_TENANTS", "empty tenant name"] (parse [("EN_TENANTS", "")]),
    testCase "a stray comma" do
      expectFailure ["EN_TENANTS", "stray comma"] (parse (("EN_TENANTS", "alpha,") : alpha)),
    testCase "a name with an upper-case letter" do
      expectFailure ["EN_TENANTS", "\"Alpha\""] (parse [("EN_TENANTS", "Alpha")]),
    testCase "a name starting with a digit" do
      expectFailure ["EN_TENANTS", "\"1alpha\""] (parse [("EN_TENANTS", "1alpha")]),
    testCase "a name with an underscore" do
      expectFailure ["EN_TENANTS", "\"al_pha\""] (parse [("EN_TENANTS", "al_pha")]),
    testCase "a name longer than 31 characters" do
      expectFailure ["EN_TENANTS"] (parse [("EN_TENANTS", replicate 32 'a')]),
    testCase "a duplicated name" do
      expectFailure ["EN_TENANTS", "duplicate", "alpha"] (parse (("EN_TENANTS", "alpha,alpha") : alpha)),
    testGroup
      "a legacy variable beside EN_TENANTS"
      [ testCase name do
          expectFailure [Text.pack name, "EN_TENANTS is set"] (parse ((name, value) : twoTenants))
      | (name, value) <-
          [ ("EN_DATABASE_URL", "postgresql://localhost/en"),
            ("EN_SCHEMA_PATH", "/etc/en/app.en"),
            ("EN_API_KEYS_READ_WRITE", "deployer:deployer-secret-0123456789"),
            ("EN_API_KEYS_READ_ONLY", "reader:reader-secret-0123456789"),
            ("EN_AUTH_DISABLED", "true"),
            ("EN_BISCUIT_ISSUER_SECRET_KEY", "ed25519-private/0000")
          ]
      ],
    testCase "a tenant without a database URL" do
      expectFailure ["EN_TENANT_BETA_DATABASE_URL", "tenant beta"] (parse (unsetVar "EN_TENANT_BETA_DATABASE_URL" twoTenants)),
    testCase "a tenant without a schema path" do
      expectFailure ["EN_TENANT_ALPHA_SCHEMA_PATH", "tenant alpha"] (parse (unsetVar "EN_TENANT_ALPHA_SCHEMA_PATH" twoTenants)),
    testCase "a tenant without any key" do
      expectFailure ["Tenant beta has no API key", "EN_TENANT_BETA_API_KEYS_READ_WRITE"] $
        parse (unsetVar "EN_TENANT_BETA_API_KEYS_READ_WRITE" twoTenants),
    testCase "a malformed key entry names the tenant's variable" do
      expectFailure ["EN_TENANT_BETA_API_KEYS_READ_WRITE", "no ':' separator"] $
        parse (replace "EN_TENANT_BETA_API_KEYS_READ_WRITE" "no-separator" twoTenants),
    testCase "a duplicate key name within one tenant" do
      expectFailure ["Duplicate API key name", "EN_TENANT_ALPHA_API_KEYS_READ_WRITE", "writer"] $
        parse (replace "EN_TENANT_ALPHA_API_KEYS_READ_ONLY" "writer:alpha-other-0123456789" twoTenants),
    testCase "the same secret in two tenants" do
      expectFailure ["same API key secret", "tenant alpha", "tenant beta"] $
        parse (replace "EN_TENANT_BETA_API_KEYS_READ_WRITE" "writer:alpha-writer-0123456789" twoTenants),
    testCase "the same secret twice in one tenant" do
      expectFailure ["same API key secret", "tenant alpha"] $
        parse (replace "EN_TENANT_ALPHA_API_KEYS_READ_ONLY" "reader:alpha-writer-0123456789" twoTenants),
    testCase "a rejected secret is never printed" do
      case parse (replace "EN_TENANT_BETA_API_KEYS_READ_WRITE" "writer:alpha-writer-0123456789" twoTenants) of
        Right _ -> assertFailure "expected a failure"
        Left message -> assertBool "secret in message" (not ("alpha-writer-0123456789" `Text.isInfixOf` message)),
    testCase "two tenants with the same database URL" do
      expectFailure ["EN_TENANT_ALPHA_DATABASE_URL", "EN_TENANT_BETA_DATABASE_URL", "same URL"] $
        parse (replace "EN_TENANT_BETA_DATABASE_URL" "postgresql://localhost/en_alpha" twoTenants),
    testCase "a misspelt per-tenant variable" do
      expectFailure ["Unknown variable EN_TENANT_ALPHA_DATABSE_URL"] $
        parse (twoTenants <> [("EN_TENANT_ALPHA_DATABSE_URL", "postgresql://localhost/x")]),
    testCase "a per-tenant variable for an undeclared tenant" do
      expectFailure ["Unknown variable EN_TENANT_GAMMA_DATABASE_URL", "alpha, beta"] $
        parse (twoTenants <> [("EN_TENANT_GAMMA_DATABASE_URL", "postgresql://localhost/en_gamma")]),
    testCase "an invalid per-tenant reload force" do
      expectFailure ["EN_TENANT_ALPHA_SCHEMA_RELOAD_FORCE=yes", "true or false"] (parse (twoTenants <> [("EN_TENANT_ALPHA_SCHEMA_RELOAD_FORCE", "yes")])),
    testCase "an invalid per-tenant pool size" do
      expectFailure ["EN_TENANT_ALPHA_POOL_SIZE=0", "positive"] (parse (twoTenants <> [("EN_TENANT_ALPHA_POOL_SIZE", "0")])),
    testCase "a malformed per-tenant issuer key" do
      expectFailure ["Invalid EN_TENANT_ALPHA_BISCUIT_ISSUER_SECRET_KEY"] $
        parse (twoTenants <> [("EN_TENANT_ALPHA_BISCUIT_ISSUER_SECRET_KEY", "not-a-key")])
  ]

-- * Helpers

twoOf :: [(TenantName, TenantConfig)] -> IO (TenantConfig, TenantConfig)
twoOf = \case
  [(_, a), (_, b)] -> pure (a, b)
  other -> assertFailure ("expected two tenants, got " <> show (length other))

parse :: [(String, String)] -> Either Text (ServerConfig, [Text])
parse = parseServerConfig . Map.fromList

unsetVar :: String -> [(String, String)] -> [(String, String)]
unsetVar name = filter ((/= name) . fst)

replace :: String -> String -> [(String, String)] -> [(String, String)]
replace name value environment = (name, value) : unsetVar name environment

keySummary :: AuthConfig -> [(Text, KeyRole)]
keySummary = \case
  AuthDisabled -> []
  AuthKeys keys -> [(key ^. #keyName, key ^. #keyRole) | key <- keys]

expectRight :: Either Text a -> IO a
expectRight = either (assertFailure . ("unexpected failure: " <>) . Text.unpack) pure

expectTenants :: Either Text (ServerConfig, [Text]) -> IO [(TenantName, TenantConfig)]
expectTenants result = do
  (config, _) <- expectRight result
  case config ^. #tenancy of
    Tenants tenants -> pure (NonEmpty.toList tenants)
    SingleStore _ -> assertFailure "parsed as legacy mode"

-- | The parse fails, and its message mentions every fragment.
expectFailure :: [Text] -> Either Text a -> Assertion
expectFailure fragments = \case
  Right _ -> assertFailure ("expected a failure mentioning " <> show fragments)
  Left message ->
    for_ fragments \fragment ->
      assertBool
        ("message does not mention " <> show fragment <> ":\n" <> Text.unpack message)
        (fragment `Text.isInfixOf` message)
  where
    for_ items f = mapM_ f items
