-- | Black-box proofs about tenancy in @en-server@: the shipped binary is started against
-- disposable PostgreSQL and spoken to over HTTP.
--
-- See docs/plans/73-serve-tenants-selected-by-api-key-each-from-its-own-isolated-stack.md
-- and docs/masterplans/12-serve-several-isolated-tenants-from-one-en-server.md (gate G4).
--
-- Requests are raw JSON over HTTP rather than the typed client, so each case exercises the
-- wire exactly as any client would and can add the stray headers and fields a typed
-- client would refuse to send.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM_, replicateM, unless)
import Data.Aeson (Value, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as Aeson
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (find, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Network.HTTP.Client qualified as Http
import Network.HTTP.Types (Header, statusCode)
import ServerHarness
import System.Directory (doesFileExist)
import System.Environment (lookupEnv, setEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Signals (sigHUP)
import System.Timeout (timeout)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCaseSteps)

main :: IO ()
main = do
  -- Each case starts two PostgreSQL instances, and each instance holds a System V shared
  -- memory segment. macOS allows 32 system-wide (kern.sysv.shmmni), so running a case per
  -- core exhausts them and initdb fails with "could not create shared memory segment: No
  -- space left on device". Three cases at a time, unless the caller says otherwise.
  lookupEnv "TASTY_NUM_THREADS" >>= \case
    Just _ -> pure ()
    Nothing -> setEnv "TASTY_NUM_THREADS" "3"
  defaultMain $
    testGroup
      "en-server tenancy"
      [ upgradeTest,
        isolationTest,
        rateLimitTest,
        storageSeparationTest,
        testGroup
          "independent lifecycles"
          [ reloadTest,
            reloadContainmentTest,
            grantGenerationTest,
            garbageCollectionTest
          ],
        testGroup
          "storage faults are contained"
          [ outageWhileRunningTest,
            unreachableAtStartupTest,
            unmigratedTest,
            wrongDatastoreIdTest,
            pinnedDatastoreIdTest,
            totalOutageTest,
            legacyStartupFailureTest
          ],
        testGroup
          "tenant-aware subcommands"
          [ subcommandTest,
            subcommandSelectionTest
          ]
      ]

-- * AC-1: a server without tenant configuration upgrades in place

-- | Start the baseline binary (built before any tenant code existed) against a fresh
-- database, write once, then start the binary under test against the same database and
-- show the datastore id, the schema hash and the earlier consistency token all carry over.
upgradeTest :: TestTree
upgradeTest = testCaseSteps "upgrade from the baseline binary keeps identity and tokens" \step ->
  lookupEnv "EN_BASELINE_BIN" >>= \case
    Nothing -> step "skipped: EN_BASELINE_BIN is not set"
    Just "" -> step "skipped: EN_BASELINE_BIN is empty"
    Just baseline -> do
      -- `cabal test` runs the suite from the package directory, so a path relative to
      -- the repository root would silently point elsewhere.
      exists <- doesFileExist baseline
      unless exists $
        assertFailure
          ( "EN_BASELINE_BIN="
              <> baseline
              <> " does not exist from "
              <> "the package directory cabal runs this suite in; pass an absolute path, e.g. "
              <> "EN_BASELINE_BIN=\"$PWD/.dev/loadbench/en-server-baseline\""
          )
      candidate <- locateServerBinary
      withSystemTempDirectory "en-tenant-tests" \directory ->
        withPostgres \postgres -> do
          url <- createMigratedDatabase postgres "upgrade"
          let schemaPath = directory </> "upgrade.en"
          writeFile schemaPath (Text.unpack upgradeSchema)
          base <- baseEnvironment
          let environment =
                base
                  <> [ ("EN_DATABASE_URL", Text.unpack url),
                       ("EN_SCHEMA_PATH", schemaPath),
                       ("EN_API_KEYS_READ_WRITE", "upgrader:" <> Text.unpack upgradeSecret)
                     ]
          manager <- Http.newManager Http.defaultManagerSettings

          step ("starting the baseline binary " <> baseline)
          (before, token) <- withServer (serverSpec baseline environment) \server -> do
            let client = Client manager server upgradeSecret
            identity <- serverIdentity client ""
            token <- writeTuple client ("space", "s1", "viewer", "ann") >>= expectStatus 200 >>= field "token"
            pure (identity, token :: Text)

          step ("starting the candidate binary " <> candidate)
          withServer (serverSpec candidate environment) \server -> do
            let client = Client manager server upgradeSecret
            after <- serverIdentity client ""
            assertEqual "datastore id" (identityDatastoreId before) (identityDatastoreId after)
            assertEqual "schema hash (startup line)" (identityStartupHash before) (identityStartupHash after)
            assertEqual "schema hash (GET /v1/schema)" (identitySchemaHash before) (identitySchemaHash after)
            result <- check client (atLeastAsFresh token) ("space", "s1", "view", "ann") >>= expectStatus 200 >>= decisionOf
            assertEqual "check under the pre-upgrade token" "allowed" result

upgradeSchema :: Text
upgradeSchema =
  Text.unlines
    [ "object user {}",
      "",
      "object space {",
      "  relation viewer: user",
      "  permission view = viewer",
      "}"
    ]

upgradeSecret :: Text
upgradeSecret = "upgrade-secret-0123456789"

-- * The two-tenant fixture

-- | @document@ exists only in alpha, @repo@ only in beta, and @team@ in both, so a case
-- can test both "unknown type" and "same type, separate data".
alphaSchema, betaSchema :: Text
alphaSchema =
  Text.unlines
    [ "object user {}",
      "object team {",
      "  relation member: user",
      "  permission membership = member",
      "}",
      "object document {",
      "  relation viewer: user",
      "  permission view = viewer",
      "}"
    ]
betaSchema =
  Text.unlines
    [ "object user {}",
      "object team {",
      "  relation member: user",
      "  permission membership = member",
      "}",
      "object repo {",
      "  relation reader: user",
      "  permission read = reader",
      "}"
    ]

alphaWriter, alphaReader, betaWriter :: Text
alphaWriter = "alpha-writer-secret-0123456789"
alphaReader = "alpha-reader-secret-0123456789"
betaWriter = "beta-writer-secret-0123456789"

data Fixture = Fixture
  { alphaPostgres :: PostgresInstance,
    betaPostgres :: PostgresInstance,
    server :: RunningServer,
    alphaSchemaPath :: FilePath,
    betaSchemaPath :: FilePath,
    alphaUrl :: Text,
    betaUrl :: Text,
    -- | The server's binary and complete environment, for running subcommands.
    serverBinary :: FilePath,
    serverEnvironment :: [(String, String)],
    alpha :: Client,
    alphaReadOnly :: Client,
    beta :: Client
  }

-- | Two PostgreSQL instances (not two databases in one, so a case can stop one), a
-- migrated database in each, two schema files, and one server serving both tenants.
--
-- Both tenants name their read-write key @writer@: a caller is the pair of tenant and key
-- name, so the names may repeat.
withTwoTenants :: [(String, String)] -> (Fixture -> IO a) -> IO a
withTwoTenants = withTwoTenantsUsing defaultSetup

-- | How alpha's database is prepared before the server starts.
data Setup = Setup
  { -- | Apply En's migrations to alpha's database (otherwise it is left empty).
    alphaMigrated :: Bool,
    -- | Runs after both databases exist and before the server starts: alpha's instance and
    --     database URL.
    beforeStart :: PostgresInstance -> Text -> IO ()
  }

defaultSetup :: Setup
defaultSetup = Setup {alphaMigrated = True, beforeStart = \_ _ -> pure ()}

withTwoTenantsUsing :: Setup -> [(String, String)] -> (Fixture -> IO a) -> IO a
withTwoTenantsUsing setup extra action =
  withSystemTempDirectory "en-tenant-tests" \directory ->
    withPostgres \alphaPostgres ->
      withPostgres \betaPostgres -> do
        alphaUrl <-
          if alphaMigrated setup
            then createMigratedDatabase alphaPostgres "en_alpha"
            else createEmptyDatabase alphaPostgres "en_alpha"
        betaUrl <- createMigratedDatabase betaPostgres "en_beta"
        beforeStart setup alphaPostgres alphaUrl
        let alphaPath = directory </> "alpha.en"
            betaPath = directory </> "beta.en"
        writeFile alphaPath (Text.unpack alphaSchema)
        writeFile betaPath (Text.unpack betaSchema)
        base <- baseEnvironment
        binary <- locateServerBinary
        let environment =
              base
                <> [ ("EN_TENANTS", "alpha,beta"),
                     ("EN_TENANT_ALPHA_DATABASE_URL", Text.unpack alphaUrl),
                     ("EN_TENANT_ALPHA_SCHEMA_PATH", alphaPath),
                     ("EN_TENANT_ALPHA_API_KEYS_READ_WRITE", "writer:" <> Text.unpack alphaWriter),
                     ("EN_TENANT_ALPHA_API_KEYS_READ_ONLY", "reader:" <> Text.unpack alphaReader),
                     ("EN_TENANT_BETA_DATABASE_URL", Text.unpack betaUrl),
                     ("EN_TENANT_BETA_SCHEMA_PATH", betaPath),
                     ("EN_TENANT_BETA_API_KEYS_READ_WRITE", "writer:" <> Text.unpack betaWriter)
                   ]
                <> extra
        manager <- Http.newManager Http.defaultManagerSettings
        withServer (serverSpec binary environment) \server ->
          action
            Fixture
              { alphaPostgres,
                betaPostgres,
                server,
                alphaSchemaPath = alphaPath,
                betaSchemaPath = betaPath,
                alphaUrl,
                betaUrl,
                serverBinary = binary,
                serverEnvironment = environment,
                alpha = Client manager server alphaWriter,
                alphaReadOnly = Client manager server alphaReader,
                beta = Client manager server betaWriter
              }

-- * AC-2, AC-3 and the key-role half of AC-6

isolationTest :: TestTree
isolationTest = testCaseSteps "two tenants in one process cannot see each other" \step ->
  withTwoTenants [] \fixture -> do
    let a = alpha fixture
        b = beta fixture

    step "each tenant writes and checks its own type"
    tokenA <- writeTuple a ("document", "d1", "viewer", "ann") >>= expectStatus 200 >>= field "token"
    decisionA <- check a (atLeastAsFresh tokenA) ("document", "d1", "view", "ann") >>= expectStatus 200 >>= decisionOf
    assertEqual "alpha checks its document" "allowed" decisionA
    tokenB <- writeTuple b ("repo", "r1", "reader", "bob") >>= expectStatus 200 >>= field "token"
    decisionB <- check b (atLeastAsFresh tokenB) ("repo", "r1", "read", "bob") >>= expectStatus 200 >>= decisionOf
    assertEqual "beta checks its repo" "allowed" decisionB

    -- En does not validate written tuples against the schema in any mode (that is what
    -- `check-schema` and reload's orphan report are for), so a tuple of a type only the other
    -- tenant defines is accepted. Isolation requires that it stay in the writer's database
    -- and be evaluated under the writer's schema, never reach the other tenant.
    step "a type only the other tenant defines stays in the writer's store, under the writer's schema"
    forM_ [(a, b, ("repo", "r9", "reader", "ann"), "read"), (b, a, ("document", "d9", "viewer", "bob"), "view")] \(writer, other, tuple@(objectType, objectId, _, user), permission) -> do
      strayToken <- writeTuple writer tuple >>= expectStatus 200 >>= field "token"
      queryBySubject other user >>= expectStatus 200 >>= expectNoMention [objectId]
      writerRows <- queryWith writer (atLeastAsFresh strayToken) user >>= expectStatus 200
      assertBool "the stray tuple is in the writer's store" (mentions objectId writerRows)
      check writer (atLeastAsFresh strayToken) (objectType, objectId, permission, user)
        >>= expectProblemAmong 400 ["unknown_relation", "schema_violation", "invalid_request"]

    step "a shared type keeps separate data in every read route and the changes feed"
    forM_ [(a, b, "t-alpha", "carol"), (b, a, "t-beta", "dave")] \(writer, reader, team, user) -> do
      startCursor <- watchFrom reader Nothing >>= expectStatus 200 >>= field "cursor"
      writerCursor <- watchFrom writer Nothing >>= expectStatus 200 >>= field "cursor"
      _ <- writeTuple writer ("team", team, "member", user) >>= expectStatus 200
      decision <- check reader fullyConsistent ("team", team, "membership", user) >>= expectStatus 200 >>= decisionOf
      assertEqual ("the other tenant's check of " <> Text.unpack team) "denied" decision
      lookupObjects reader fullyConsistent "team" user Nothing >>= expectStatus 200 >>= expectNoMention [team]
      lookupSubjects reader ("team", team, "membership") >>= expectStatus 200 >>= expectNoMention [user]
      queryBySubject reader user >>= expectStatus 200 >>= expectNoMention [team, user]
      expand reader ("team", team, "membership") >>= expectStatus 200 >>= expectNoMention [user]
      changes <- watchFrom reader (Just startCursor) >>= expectStatus 200 >>= field "changes"
      assertEqual ("the other tenant's changes feed after " <> Text.unpack team) ([] :: [Value]) changes
      -- The writer's own feed does see it, so the empty feed above is not vacuous.
      ownChanges <- watchFrom writer (Just writerCursor) >>= expectStatus 200 >>= field "changes"
      assertBool ("the writer's own feed shows " <> Text.unpack team) (not (null (ownChanges :: [Value])))

    step "each tenant serves its own schema text, hash and datastore id"
    identityA <- serverIdentity a "[tenant alpha] "
    identityB <- serverIdentity b "[tenant beta] "
    schemaA <- getSchema a
    schemaB <- getSchema b
    assertBool "alpha's source names document" ("object document" `Text.isInfixOf` schemaA)
    assertBool "alpha's source does not name repo" (not ("repo" `Text.isInfixOf` schemaA))
    assertBool "beta's source names repo" ("object repo" `Text.isInfixOf` schemaB)
    assertBool "beta's source does not name document" (not ("document" `Text.isInfixOf` schemaB))
    assertBool "schema hashes differ" (identitySchemaHash identityA /= identitySchemaHash identityB)
    assertEqual "alpha's served hash is its startup hash" (identityStartupHash identityA) (identitySchemaHash identityA)
    assertBool "datastore ids differ" (identityDatastoreId identityA /= identityDatastoreId identityB)

    step "tokens and cursors minted under one tenant are rejected by the other"
    forM_ [(a, b, "alpha"), (b, a, "beta")] \(minter, other, name) -> do
      token <- writeTuple minter ("team", name <> "-1", "member", "erin") >>= expectStatus 200 >>= field "token"
      _ <- writeTuple minter ("team", name <> "-2", "member", "erin") >>= expectStatus 200
      check other (atLeastAsFresh token) ("team", "t", "membership", "erin") >>= expectProblem 400 "invalid_consistency_token"
      lookupObjects other (atLeastAsFresh token) "team" "erin" Nothing >>= expectProblem 400 "invalid_consistency_token"
      queryWith other (atLeastAsFresh token) "erin" >>= expectProblem 400 "invalid_consistency_token"
      page <- lookupObjectsLimit minter fullyConsistent "team" "erin" 1 >>= expectStatus 200
      continuation <- field "state" page >>= field "cursor"
      lookupObjects other minimizeLatency "team" "erin" (Just continuation)
        >>= expectProblemAmong 400 ["invalid_cursor", "invalid_consistency_token"]
      watchCursor <- watchFrom minter Nothing >>= expectStatus 200 >>= field "cursor"
      watchFrom other (Just watchCursor)
        >>= expectProblemAmong 400 ["invalid_cursor", "invalid_consistency_token"]

    step "only the key selects the tenant: headers and body fields naming the other are ignored"
    let misleading = [("X-En-Tenant", "beta"), ("X-En-Caller", "writer"), ("X-En-Datastore", "beta")]
    viaHeaders <- requestWith a misleading "GET" "/v1/schema" Nothing >>= expectStatus 200 >>= field "source"
    assertBool "served alpha's schema" ("object document" `Text.isInfixOf` viaHeaders)
    let checkWithTenantField =
          Aeson.object
            [ "consistency" .= fullyConsistent,
              "context" .= Aeson.object ["values" .= Aeson.object []],
              "subject" .= subjectRef "user" "ann",
              "permission" .= ("view" :: Text),
              "object" .= objectRef "document" "d1",
              "tenant" .= ("beta" :: Text),
              "datastoreId" .= identityDatastoreId identityB
            ]
    viaBody <- requestWith a misleading "POST" "/v1/check" (Just checkWithTenantField) >>= expectStatus 200 >>= decisionOf
    assertEqual "evaluated under alpha" "allowed" viaBody

    step "a read-only key stays read-only within its tenant"
    writeTuple (alphaReadOnly fixture) ("document", "d2", "viewer", "ann") >>= expectProblem 403 "permission_denied"
    readOnlyDecision <- check (alphaReadOnly fixture) fullyConsistent ("document", "d1", "view", "ann") >>= expectStatus 200 >>= decisionOf
    assertEqual "read-only key checks" "allowed" readOnlyDecision

    step "each tenant's metrics count only its own requests"
    before <- requestCounts a
    _ <- replicateM 5 (check b fullyConsistent ("repo", "r1", "read", "bob") >>= expectStatus 200)
    after <- requestCounts a
    assertEqual "alpha's request counters after only beta was called" before after

    step "no key, or an unknown key, is 401; liveness needs no key"
    requestWith (a {secret = ""}) [] "GET" "/v1/schema" Nothing >>= expectProblem 401 "unauthenticated"
    requestWith (a {secret = "unknown-secret-0123456789"}) [] "GET" "/v1/schema" Nothing >>= expectProblem 401 "unauthenticated"
    (liveStatus, _) <- requestWith (a {secret = ""}) [] "GET" "/health/live" Nothing
    assertEqual "liveness without a key" 200 liveStatus

-- | Two callers named identically in two tenants do not share a rate-limit bucket.
rateLimitTest :: TestTree
rateLimitTest = testCaseSteps "rate-limit buckets are per tenant" \step ->
  withTwoTenants [("EN_RATE_LIMIT_RPS", "0.01"), ("EN_RATE_LIMIT_BURST", "1")] \fixture -> do
    step "exhaust alpha's writer"
    _ <- getSchemaReply (alpha fixture) >>= expectStatus 200
    getSchemaReply (alpha fixture) >>= expectProblem 429 "rate_limited"
    step "beta's writer, of the same name, is still admitted"
    _ <- getSchemaReply (beta fixture) >>= expectStatus 200
    pure ()

-- | With beta's PostgreSQL stopped, every alpha route still answers and beta's answer 503:
-- the direct proof that no alpha request touches beta's storage.
storageSeparationTest :: TestTree
storageSeparationTest = testCaseSteps "a tenant keeps serving while the other's PostgreSQL is stopped" \step ->
  withTwoTenants [] \fixture -> do
    let a = alpha fixture
        b = beta fixture
    _ <- writeTuple a ("document", "d1", "viewer", "ann") >>= expectStatus 200
    _ <- writeTuple a ("team", "t1", "member", "ann") >>= expectStatus 200
    step "stop beta's PostgreSQL"
    stopPostgres (betaPostgres fixture)

    step "every alpha route still succeeds"
    token <- writeTuple a ("document", "d2", "viewer", "ann") >>= expectStatus 200 >>= field "token"
    _ <- deleteTuple a ("document", "d2", "viewer", "ann") >>= expectStatus 200
    _ <- deleteByFilter a "document" "d-none" >>= expectStatus 200
    _ <- queryBySubject a "ann" >>= expectStatus 200
    _ <- check a (atLeastAsFresh token) ("document", "d1", "view", "ann") >>= expectStatus 200
    _ <- batchCheck a ("document", "d1", "view", "ann") >>= expectStatus 200
    _ <- lookupObjects a fullyConsistent "document" "ann" Nothing >>= expectStatus 200
    _ <- lookupSubjects a ("document", "d1", "view") >>= expectStatus 200
    _ <- expand a ("document", "d1", "view") >>= expectStatus 200
    _ <- watchFrom a Nothing >>= expectStatus 200
    _ <- getSchemaReply a >>= expectStatus 200

    step "beta's storage-backed routes answer 503 store_error"
    writeTuple b ("repo", "r1", "reader", "bob") >>= expectProblem 503 "store_error"
    check b fullyConsistent ("repo", "r1", "read", "bob") >>= expectProblem 503 "store_error"
    lookupObjects b fullyConsistent "repo" "bob" Nothing >>= expectProblem 503 "store_error"

-- * AC-4: independent lifecycles

-- | A compatible edit to one tenant's schema, then @SIGHUP@: only that tenant's schema and
-- tokens change.
reloadTest :: TestTree
reloadTest = testCaseSteps "a schema reload swaps one tenant and invalidates only its tokens" \step ->
  withTwoTenants [] \fixture -> do
    let a = alpha fixture
        b = beta fixture
    tokenA <- writeTuple a ("team", "t1", "member", "ann") >>= expectStatus 200 >>= field "token"
    tokenB <- writeTuple b ("team", "t1", "member", "bob") >>= expectStatus 200 >>= field "token"
    beforeA <- schemaInfo a
    beforeB <- schemaInfo b

    step "append a relation to alpha's schema and send SIGHUP"
    appendFile (alphaSchemaPath fixture) "object folder {\n  relation viewer: user\n  permission view = viewer\n}\n"
    signalServer (server fixture) sigHUP
    afterA <- awaitSchemaChange a beforeA

    step "beta's schema, load time and tokens are untouched"
    afterB <- schemaInfo b
    assertEqual "beta's schema" beforeB afterB
    assertBool "alpha's hash changed" (fst afterA /= fst beforeA)
    decisionB <- check b (atLeastAsFresh tokenB) ("team", "t1", "membership", "bob") >>= expectStatus 200 >>= decisionOf
    assertEqual "beta's pre-reload token still validates" "allowed" decisionB
    check a (atLeastAsFresh tokenA) ("team", "t1", "membership", "ann") >>= expectProblem 400 "invalid_consistency_token"

-- | One @SIGHUP@ with a broken file for alpha and a good edit for beta: alpha keeps serving
-- its previous schema, beta is reloaded.
reloadContainmentTest :: TestTree
reloadContainmentTest = testCaseSteps "a failed reload of one tenant does not stop the other's" \step ->
  withTwoTenants [] \fixture -> do
    let a = alpha fixture
        b = beta fixture
    beforeA <- schemaInfo a
    beforeB <- schemaInfo b
    step "break alpha's file, edit beta's, send one SIGHUP"
    writeFile (alphaSchemaPath fixture) "object user {\n  this is not a schema\n"
    appendFile (betaSchemaPath fixture) "object folder {\n  relation viewer: user\n  permission view = viewer\n}\n"
    signalServer (server fixture) sigHUP
    _ <- awaitSchemaChange b beforeB
    step "alpha still serves its previous schema and its refusal is logged under its name"
    afterA <- schemaInfo a
    assertEqual "alpha's schema" beforeA afterA
    output <- capturedLines (server fixture)
    assertBool
      ("no prefixed refusal for alpha in:\n" <> Text.unpack (Text.unlines output))
      (any (\line -> "[tenant alpha] schema reload failed" `Text.isInfixOf` line) output)

-- | Writes under alpha advance alpha's grant generation and never beta's.
grantGenerationTest :: TestTree
grantGenerationTest = testCaseSteps "one tenant's writes never move another tenant's grant generation" \_step ->
  withTwoTenants [] \fixture -> do
    let generation url = queryDatabaseText url "SELECT generation::text FROM en_grant_generation_head"
    _ <- writeTuple (beta fixture) ("team", "b1", "member", "bob") >>= expectStatus 200
    alphaBefore <- generation (alphaUrl fixture)
    betaBefore <- generation (betaUrl fixture)
    forM_ ["a1", "a2", "a3"] \team ->
      writeTuple (alpha fixture) ("team", team, "member", "ann") >>= expectStatus 200
    alphaAfter <- generation (alphaUrl fixture)
    betaAfter <- generation (betaUrl fixture)
    assertEqual "beta's generation" betaBefore betaAfter
    assertBool ("alpha's generation advanced: " <> show (alphaBefore, alphaAfter)) (readInt alphaAfter > readInt alphaBefore)

-- | Each tenant's maintenance loop reaps only its own database, under its own GC window:
-- alpha (1 second) reaps its deleted row; beta (1 hour) keeps its own.
garbageCollectionTest :: TestTree
garbageCollectionTest = testCaseSteps "garbage collection runs per tenant, under each tenant's window" \step ->
  withTwoTenants
    [ ("EN_MAINTENANCE_INTERVAL_SECONDS", "1"),
      ("EN_TENANT_ALPHA_GC_WINDOW", "1 second"),
      ("EN_TENANT_BETA_GC_WINDOW", "1 hour")
    ]
    \fixture -> do
      let rows url = readInt <$> queryDatabaseText url "SELECT count(*)::text FROM relation_tuple"
      step "each tenant writes, then deletes, one relationship"
      forM_ [(alpha fixture, "ann"), (beta fixture, "bob")] \(client, user) -> do
        _ <- writeTuple client ("team", "gc", "member", user) >>= expectStatus 200
        deleteTuple client ("team", "gc", "member", user) >>= expectStatus 200
      betaRows <- rows (betaUrl fixture)
      assertEqual "beta keeps its soft-deleted row" 1 betaRows
      step "alpha's maintenance reaps alpha's row"
      awaitCondition 30 "alpha's deleted row to be reaped" ((== 0) <$> rows (alphaUrl fixture))
      step "beta's row is still there, and each tenant logged its own passes"
      betaRowsAfter <- rows (betaUrl fixture)
      assertEqual "beta's rows after alpha's reaping" 1 betaRowsAfter
      output <- capturedLines (server fixture)
      let passes tenant = filter (("[tenant " <> tenant <> "] maintenance: horizon=") `Text.isPrefixOf`) output
      assertBool "alpha logged a pass that reaped" (any (" reaped=1 " `Text.isInfixOf`) (passes "alpha"))
      assertBool "beta logged its own passes" (not (null (passes "beta")))
      assertBool "beta reaped nothing" (all (" reaped=0 " `Text.isInfixOf`) (passes "beta"))

-- * AC-5: storage faults are contained

-- | Alpha's database goes away while the server runs: alpha answers 503, beta and readiness
-- are unaffected, and alpha recovers by itself when its database returns.
outageWhileRunningTest :: TestTree
outageWhileRunningTest = testCaseSteps "an outage while running affects only that tenant, which recovers" \step ->
  withTwoTenants [] \fixture -> do
    let a = alpha fixture
        b = beta fixture
    _ <- writeTuple a ("team", "t1", "member", "ann") >>= expectStatus 200
    step "take alpha's database out of service"
    setDatabaseAccepting (alphaPostgres fixture) "en_alpha" False
    -- The first request on a pooled connection the outage closed is classified by
    -- en-postgres as an internal error (500) rather than a store error (503); see plan 74's
    -- Surprises & Discoveries. Containment requires that alpha fails closed throughout and
    -- settles on the retryable store error once its stale connections are gone.
    awaitCondition 30 "alpha to answer 503 store_error" do
      reply@(status, _) <- check a fullyConsistent ("team", "t1", "membership", "ann")
      assertBool ("alpha must fail closed during its outage, got " <> show reply) (status >= 500)
      pure (status == 503)
    output <- capturedLines (server fixture)
    forM_ (take 1 (filter ("en: internal error:" `Text.isInfixOf`) output)) \line ->
      step ("server logged, before settling: " <> Text.unpack (Text.take 300 line))
    check a fullyConsistent ("team", "t1", "membership", "ann") >>= expectProblem 503 "store_error"
    writeTuple a ("team", "t2", "member", "ann") >>= expectProblem 503 "store_error"
    _ <- writeTuple b ("team", "t1", "member", "bob") >>= expectStatus 200
    _ <- check b fullyConsistent ("team", "t1", "membership", "bob") >>= expectStatus 200
    expectReady a 200
    step "bring it back: alpha serves again with no restart"
    setDatabaseAccepting (alphaPostgres fixture) "en_alpha" True
    awaitCondition 30 "alpha to serve again" ((== 200) . fst <$> check a fullyConsistent ("team", "t1", "membership", "ann"))

-- | Alpha's database refuses connections when the server starts: the server starts anyway,
-- alpha is unavailable (with authentication intact), and recovers when the database returns.
unreachableAtStartupTest :: TestTree
unreachableAtStartupTest = testCaseSteps "a tenant unreachable at startup starts unavailable and recovers" \step ->
  withTwoTenantsUsing
    defaultSetup {beforeStart = \postgres _ -> setDatabaseAccepting postgres "en_alpha" False}
    []
    \fixture -> do
      let a = alpha fixture
      step "the server started; alpha is unavailable, beta serves"
      expectLogLine fixture "[tenant alpha] UNAVAILABLE: Could not reach PostgreSQL"
      check a fullyConsistent ("team", "t1", "membership", "ann") >>= expectProblem 503 "store_error"
      writeTuple (alphaReadOnly fixture) ("team", "t1", "member", "ann") >>= expectProblem 403 "permission_denied"
      requestWith (a {secret = "unknown-secret-0123456789"}) [] "GET" "/v1/schema" Nothing >>= expectProblem 401 "unauthenticated"
      _ <- writeTuple (beta fixture) ("team", "t1", "member", "bob") >>= expectStatus 200
      step "alpha's database returns; alpha becomes available without a restart"
      setDatabaseAccepting (alphaPostgres fixture) "en_alpha" True
      awaitCondition 30 "alpha to become available" (hasLogLine fixture "[tenant alpha] AVAILABLE")
      _ <- writeTuple a ("team", "t1", "member", "ann") >>= expectStatus 200
      pure ()

-- | Alpha points at a database without En's tables: unavailable, naming the migrations;
-- migrating it brings alpha up without a restart.
unmigratedTest :: TestTree
unmigratedTest = testCaseSteps "an unmigrated tenant database is unavailable until migrated" \step ->
  withTwoTenantsUsing defaultSetup {alphaMigrated = False} [] \fixture -> do
    expectLogLine fixture "[tenant alpha] UNAVAILABLE: Could not resolve this database's datastore identity"
    expectLogLine fixture "migrations are missing or out of date"
    check (alpha fixture) fullyConsistent ("team", "t1", "membership", "ann") >>= expectProblem 503 "store_error"
    _ <- writeTuple (beta fixture) ("team", "t1", "member", "bob") >>= expectStatus 200
    step "apply En's migrations to alpha's database"
    migrateDatabaseUrl (alphaUrl fixture)
    awaitCondition 30 "alpha to become available" (hasLogLine fixture "[tenant alpha] AVAILABLE")
    _ <- writeTuple (alpha fixture) ("team", "t1", "member", "ann") >>= expectStatus 200
    pure ()

-- | A pin that does not match keeps alpha unavailable, names both ids, and never writes to
-- alpha's database.
wrongDatastoreIdTest :: TestTree
wrongDatastoreIdTest = testCaseSteps "a mismatched datastore id pin keeps the tenant unavailable and its database untouched" \_step ->
  withTwoTenantsUsing
    defaultSetup {beforeStart = \_ url -> runDatabaseScript url "INSERT INTO en_datastore_metadata (datastore_id) VALUES ('alpha-actual-id')"}
    [("EN_TENANT_ALPHA_EXPECTED_DATASTORE_ID", "alpha-expected-id")]
    \fixture -> do
      expectLogLine fixture "[tenant alpha] UNAVAILABLE: This database's datastore id is alpha-actual-id, but EN_TENANT_ALPHA_EXPECTED_DATASTORE_ID is alpha-expected-id."
      check (alpha fixture) fullyConsistent ("team", "t1", "membership", "ann") >>= expectProblem 503 "store_error"
      _ <- writeTuple (beta fixture) ("team", "t1", "member", "bob") >>= expectStatus 200
      metadata <- queryDatabaseText (alphaUrl fixture) "SELECT string_agg(datastore_id, ',')::text FROM en_datastore_metadata"
      assertEqual "alpha's metadata is untouched" "alpha-actual-id" metadata

-- | The matching pin serves, and an empty database is never stamped when a pin is set.
pinnedDatastoreIdTest :: TestTree
pinnedDatastoreIdTest = testCaseSteps "a matching datastore id pin serves" \_step ->
  withTwoTenantsUsing
    defaultSetup {beforeStart = \_ url -> runDatabaseScript url "INSERT INTO en_datastore_metadata (datastore_id) VALUES ('alpha-actual-id')"}
    [("EN_TENANT_ALPHA_EXPECTED_DATASTORE_ID", "alpha-actual-id")]
    \fixture -> do
      expectLogLine fixture "[tenant alpha] Datastore id: alpha-actual-id"
      _ <- writeTuple (alpha fixture) ("team", "t1", "member", "ann") >>= expectStatus 200
      pure ()

-- | Every tenant down: readiness fails naming a tenant check; liveness passes.
totalOutageTest :: TestTree
totalOutageTest = testCaseSteps "readiness fails only when no tenant can serve" \step ->
  withTwoTenants [] \fixture -> do
    step "alpha down, beta up: ready"
    setDatabaseAccepting (alphaPostgres fixture) "en_alpha" False
    expectReady (alpha fixture) 200
    step "both down: not ready, naming a tenant; still live"
    setDatabaseAccepting (betaPostgres fixture) "en_beta" False
    (status, body) <- requestWith ((alpha fixture) {secret = ""}) [] "GET" "/health/ready" Nothing
    assertEqual "readiness" 503 status
    assertBool ("names postgres:alpha: " <> show body) ("postgres:alpha" `Text.isInfixOf` Text.decodeUtf8 (LazyByteString.toStrict body))
    (liveStatus, _) <- requestWith ((alpha fixture) {secret = ""}) [] "GET" "/health/live" Nothing
    assertEqual "liveness" 200 liveStatus

-- | Without @EN_TENANTS@ an unreachable database still stops the server, as it always has.
legacyStartupFailureTest :: TestTree
legacyStartupFailureTest = testCaseSteps "legacy mode still exits when its database is unreachable" \_step ->
  withPostgres \postgres -> do
    url <- createMigratedDatabase postgres "en_legacy"
    setDatabaseAccepting postgres "en_legacy" False
    base <- baseEnvironment
    binary <- locateServerBinary
    let environment =
          base
            <> [ ("EN_DATABASE_URL", Text.unpack url),
                 ("EN_API_KEYS_READ_WRITE", "writer:" <> Text.unpack alphaWriter),
                 ("EN_PORT", "18999")
               ]
    outcome <- timeout 60_000_000 (runServerCommand (serverSpec binary environment) [])
    case outcome of
      Nothing -> assertFailure "the legacy server did not exit"
      Just (code, _, err) -> do
        assertEqual "exit" (ExitFailure 1) code
        assertBool ("today's message: " <> Text.unpack err) ("Could not reach PostgreSQL through EN_DATABASE_URL" `Text.isInfixOf` err)

expectReady :: Client -> Int -> IO ()
expectReady client expected = do
  (status, body) <- requestWith (client {secret = ""}) [] "GET" "/health/ready" Nothing
  assertEqual ("GET /health/ready: " <> show body) expected status

hasLogLine :: Fixture -> Text -> IO Bool
hasLogLine fixture fragment = any (fragment `Text.isInfixOf`) <$> capturedLines (server fixture)

expectLogLine :: Fixture -> Text -> IO ()
expectLogLine fixture fragment = do
  found <- hasLogLine fixture fragment
  output <- capturedLines (server fixture)
  assertBool ("no log line containing " <> show fragment <> " in:\n" <> Text.unpack (Text.unlines output)) found

-- * AC-4: tenant-aware subcommands

-- | @check-schema@, @export@ and @import@ with @--tenant@ see one tenant's store only.
subcommandTest :: TestTree
subcommandTest = testCaseSteps "check-schema, export and import act on one tenant's store" \step ->
  withSystemTempDirectory "en-tenant-subcommands" \directory ->
    withTwoTenants [] \fixture -> do
      let run arguments = runServerCommand (serverSpec (serverBinary fixture) (serverEnvironment fixture)) arguments
      forM_ ["a1", "a2", "a3"] \team -> writeTuple (alpha fixture) ("team", team, "member", "ann") >>= expectStatus 200
      forM_ ["b1", "b2"] \team -> writeTuple (beta fixture) ("team", team, "member", "bob") >>= expectStatus 200

      step "check-schema --tenant alpha counts only alpha's relationships"
      let candidate = directory </> "no-team.en"
      writeFile candidate "object user {}\nobject document {\n  relation viewer: user\n  permission view = viewer\n}\n"
      (checked, checkOut, _) <- run ["check-schema", "--tenant", "alpha", candidate]
      assertEqual "check-schema exit (strands grants)" (ExitFailure 1) checked
      assertBool ("alpha's three orphans in:\n" <> Text.unpack checkOut) ("3 orphan(s) across 3 live tuple(s)" `Text.isInfixOf` checkOut)
      assertBool "no beta relationship in the report" (not (any (`Text.isInfixOf` checkOut) ["b1", "b2", "bob"]))

      step "export --tenant beta prints only beta's relationships"
      (exported, exportOut, _) <- run ["export", "--tenant", "beta"]
      assertEqual "export exit" ExitSuccess exported
      assertEqual "beta's relationships" 2 (length (Text.lines exportOut))
      assertBool "no alpha relationship exported" (not (any (`Text.isInfixOf` exportOut) ["a1", "a2", "a3", "ann"]))

      step "import --tenant alpha writes only to alpha"
      let file = directory </> "import.ndjson"
      LazyByteString.writeFile file (Aeson.encode (tupleJson ("document", "imported", "viewer", "zed")) <> "\n")
      (imported, importOut, importErr) <- run ["import", "--tenant", "alpha", "--file", file]
      assertEqual ("import exit: " <> Text.unpack importErr) ExitSuccess imported
      token <- maybe (assertFailure ("no token line in " <> show importOut)) pure (Text.stripPrefix "token: " =<< lastLine importOut)
      decision <- check (alpha fixture) (atLeastAsFresh token) ("document", "imported", "view", "zed") >>= expectStatus 200 >>= decisionOf
      assertEqual "alpha sees the import" "allowed" decision
      queryBySubject (beta fixture) "zed" >>= expectStatus 200 >>= expectNoMention ["zed", "imported"]
  where
    lastLine text = case reverse (filter (not . Text.null) (Text.lines text)) of
      line : _ -> Just line
      [] -> Nothing

-- | The rules for choosing a tenant: required in tenant mode, must be declared, and
-- meaningless without @EN_TENANTS@. Each is exit 2, like any unusable command line.
subcommandSelectionTest :: TestTree
subcommandSelectionTest = testCaseSteps "subcommands refuse a missing, unknown or unexpected --tenant" \step ->
  withTwoTenants [] \fixture -> do
    let run environment arguments = runServerCommand (serverSpec (serverBinary fixture) environment) arguments
    step "no --tenant in tenant mode lists the tenants"
    (missing, _, missingErr) <- run (serverEnvironment fixture) ["export"]
    assertEqual "exit" (ExitFailure 2) missing
    assertBool ("names the tenants: " <> Text.unpack missingErr) ("--tenant (alpha, beta)" `Text.isInfixOf` missingErr)
    step "an undeclared tenant"
    (unknown, _, unknownErr) <- run (serverEnvironment fixture) ["export", "--tenant", "gamma"]
    assertEqual "exit" (ExitFailure 2) unknown
    assertBool ("names gamma: " <> Text.unpack unknownErr) ("Unknown tenant gamma" `Text.isInfixOf` unknownErr)
    step "--tenant without EN_TENANTS"
    base <- baseEnvironment
    let legacy = base <> [("EN_DATABASE_URL", Text.unpack (alphaUrl fixture))]
    (unexpected, _, unexpectedErr) <- run legacy ["export", "--tenant", "alpha"]
    assertEqual "exit" (ExitFailure 2) unexpected
    assertBool ("explains: " <> Text.unpack unexpectedErr) ("--tenant needs EN_TENANTS" `Text.isInfixOf` unexpectedErr)

-- | The served schema's hash and load time.
schemaInfo :: Client -> IO (Text, Text)
schemaInfo client = do
  info <- getSchemaReply client >>= expectStatus 200
  (,) <$> field "hash" info <*> field "loadedAt" info

-- | Wait for the client's tenant to serve a different schema than @before@.
awaitSchemaChange :: Client -> (Text, Text) -> IO (Text, Text)
awaitSchemaChange client before = do
  awaitCondition 10 "the schema to be reloaded" ((/= before) <$> schemaInfo client)
  schemaInfo client

-- | Poll every 100 ms for up to @seconds@.
awaitCondition :: Int -> String -> IO Bool -> IO ()
awaitCondition seconds description condition = go (seconds * 10)
  where
    go :: Int -> IO ()
    go remaining = do
      done <- condition
      unless done $
        if remaining <= 0
          then assertFailure ("timed out waiting for " <> description)
          else threadDelay 100_000 >> go (remaining - 1)

readInt :: Text -> Int
readInt = read . Text.unpack

-- * Identity

data Identity = Identity
  { identityDatastoreId :: Text,
    identityStartupHash :: Text,
    identitySchemaHash :: Text
  }

-- | The datastore id and schema hash a server printed at startup (under a tenant's log
-- prefix, or none in legacy mode), and the hash the client's tenant serves.
serverIdentity :: Client -> Text -> IO Identity
serverIdentity client prefix = do
  output <- capturedLines (clientServer client)
  datastoreId <- startupValue (prefix <> "Datastore id: ") output
  startupHash <- startupValue (prefix <> "Schema hash: ") output
  served <- getSchemaReply client >>= expectStatus 200 >>= field "hash"
  pure Identity {identityDatastoreId = datastoreId, identityStartupHash = startupHash, identitySchemaHash = served}

startupValue :: Text -> [Text] -> IO Text
startupValue prefix output =
  case find (prefix `Text.isPrefixOf`) output of
    Just line -> pure (Text.drop (Text.length prefix) line)
    Nothing -> assertFailure ("no startup line beginning " <> show prefix <> " in:\n" <> Text.unpack (Text.unlines output))

-- * Requests

-- | A caller: one server, one secret.
data Client = Client
  { clientManager :: Http.Manager,
    clientServer :: RunningServer,
    secret :: Text
  }

type Reply = (Int, LazyByteString.ByteString)

type Relationship = (Text, Text, Text, Text)

atLeastAsFresh :: Text -> Value
atLeastAsFresh token = Aeson.object ["mode" .= ("atLeastAsFresh" :: Text), "token" .= token]

fullyConsistent, minimizeLatency :: Value
fullyConsistent = Aeson.object ["mode" .= ("fullyConsistent" :: Text)]
minimizeLatency = Aeson.object ["mode" .= ("minimizeLatency" :: Text)]

emptyContext :: Value
emptyContext = Aeson.object ["values" .= Aeson.object []]

objectRef :: Text -> Text -> Value
objectRef objectType objectId =
  Aeson.object ["objectType" .= objectType, "objectId" .= objectId]

subjectRef :: Text -> Text -> Value
subjectRef objectType objectId =
  Aeson.object ["kind" .= ("id" :: Text), "objectType" .= objectType, "objectId" .= objectId]

tupleJson :: Relationship -> Value
tupleJson (objectType, objectId, relation, user) =
  Aeson.object
    [ "object" .= objectRef objectType objectId,
      "relation" .= relation,
      "subject" .= subjectRef "user" user
    ]

writeTuple :: Client -> Relationship -> IO Reply
writeTuple client tuple = post client "/v1/relationships" (Aeson.object ["tuples" .= [tupleJson tuple]])

deleteTuple :: Client -> Relationship -> IO Reply
deleteTuple client tuple = post client "/v1/relationships/delete" (Aeson.object ["tuples" .= [tupleJson tuple]])

deleteByFilter :: Client -> Text -> Text -> IO Reply
deleteByFilter client objectType objectId =
  post client "/v1/relationships/delete-by-filter" $
    Aeson.object
      [ "filter" .= Aeson.object ["objectType" .= objectType, "objectId" .= objectId],
        "dryRun" .= False
      ]

check :: Client -> Value -> (Text, Text, Text, Text) -> IO Reply
check client consistency (objectType, objectId, permission, user) =
  post client "/v1/check" $
    Aeson.object
      [ "consistency" .= consistency,
        "context" .= emptyContext,
        "subject" .= subjectRef "user" user,
        "permission" .= permission,
        "object" .= objectRef objectType objectId
      ]

batchCheck :: Client -> (Text, Text, Text, Text) -> IO Reply
batchCheck client (objectType, objectId, permission, user) =
  post client "/v1/batch-check" $
    Aeson.object
      [ "consistency" .= fullyConsistent,
        "context" .= emptyContext,
        "pairs"
          .= [ Aeson.object
                 [ "subject" .= subjectRef "user" user,
                   "permission" .= permission,
                   "object" .= objectRef objectType objectId
                 ]
             ]
      ]

lookupObjects :: Client -> Value -> Text -> Text -> Maybe Text -> IO Reply
lookupObjects client consistency objectType user cursor =
  post client "/v1/lookup" (lookupBody consistency objectType user 10 cursor)

lookupObjectsLimit :: Client -> Value -> Text -> Text -> Int -> IO Reply
lookupObjectsLimit client consistency objectType user limit =
  post client "/v1/lookup" (lookupBody consistency objectType user limit Nothing)

lookupBody :: Value -> Text -> Text -> Int -> Maybe Text -> Value
lookupBody consistency objectType user limit cursor =
  Aeson.object
    [ "consistency" .= consistency,
      "subject" .= subjectRef "user" user,
      "permission" .= permissionFor objectType,
      "objectType" .= objectType,
      "context" .= emptyContext,
      "limit" .= limit,
      "cursor" .= cursor,
      "deadlineMillis" .= (Nothing :: Maybe Int)
    ]
  where
    permissionFor = \case
      "document" -> "view"
      "repo" -> "read"
      _ -> "membership" :: Text

lookupSubjects :: Client -> (Text, Text, Text) -> IO Reply
lookupSubjects client (objectType, objectId, permission) =
  post client "/v1/lookup-subjects" $
    Aeson.object
      [ "consistency" .= fullyConsistent,
        "object" .= objectRef objectType objectId,
        "permission" .= permission,
        "subjectType" .= ("user" :: Text),
        "context" .= emptyContext,
        "limit" .= (10 :: Int),
        "cursor" .= (Nothing :: Maybe Text),
        "deadlineMillis" .= (Nothing :: Maybe Int)
      ]

expand :: Client -> (Text, Text, Text) -> IO Reply
expand client (objectType, objectId, permission) =
  post client "/v1/expand" $
    Aeson.object
      [ "consistency" .= fullyConsistent,
        "object" .= objectRef objectType objectId,
        "permission" .= permission,
        "context" .= emptyContext,
        "limit" .= (10 :: Int),
        "cursor" .= (Nothing :: Maybe Text)
      ]

queryBySubject :: Client -> Text -> IO Reply
queryBySubject client = queryWith client fullyConsistent

queryWith :: Client -> Value -> Text -> IO Reply
queryWith client consistency user =
  post client "/v1/relationships/query" $
    Aeson.object
      [ "consistency" .= consistency,
        "filter" .= Aeson.object ["subjectType" .= ("user" :: Text), "subjectId" .= user]
      ]

-- | Open the changes feed now ('Nothing'), or resume it from a cursor.
watchFrom :: Client -> Maybe Text -> IO Reply
watchFrom client cursor =
  post client "/v1/watch" $
    Aeson.object
      [ "cursor" .= cursor,
        "startToken" .= (Nothing :: Maybe Text),
        "filter" .= (Nothing :: Maybe Value),
        "limit" .= (100 :: Int)
      ]

getSchemaReply :: Client -> IO Reply
getSchemaReply client = requestWith client [] "GET" "/v1/schema" Nothing

getSchema :: Client -> IO Text
getSchema client = getSchemaReply client >>= expectStatus 200 >>= field "source"

-- | The client's tenant's request counters, minus the scrape path itself.
requestCounts :: Client -> IO [Text]
requestCounts client = do
  (status, body) <- requestWith client [] "GET" "/metrics" Nothing
  assertEqual "GET /metrics" 200 status
  pure . sort $
    [ line
    | line <- Text.lines (Text.decodeUtf8 (LazyByteString.toStrict body)),
      "en_http_requests_total{" `Text.isPrefixOf` line,
      not ("path=\"metrics\"" `Text.isInfixOf` line)
    ]

post :: Client -> Text -> Value -> IO Reply
post client path body = requestWith client [] "POST" path (Just body)

requestWith :: Client -> [Header] -> Text -> Text -> Maybe Value -> IO Reply
requestWith client extraHeaders method path body = do
  request <- Http.parseRequest (Text.unpack (baseUrl (clientServer client) <> path))
  let authorization =
        [("Authorization", "Bearer " <> Text.encodeUtf8 (secret client)) | not (Text.null (secret client))]
      contentType = [("Content-Type", "application/json") | Just _ <- [body]]
  response <-
    Http.httpLbs
      request
        { Http.method = Text.encodeUtf8 method,
          Http.requestHeaders = authorization <> contentType <> extraHeaders,
          Http.requestBody = maybe mempty (Http.RequestBodyLBS . Aeson.encode) body
        }
      (clientManager client)
  pure (statusCode (Http.responseStatus response), Http.responseBody response)

-- * Assertions

expectStatus :: Int -> Reply -> IO Value
expectStatus expected (status, body) = do
  unless (status == expected) $
    assertFailure ("expected HTTP " <> show expected <> ", got " <> show status <> ": " <> show body)
  either (assertFailure . ("response is not JSON: " <>)) pure (Aeson.eitherDecode body)

expectProblem :: Int -> Text -> Reply -> IO ()
expectProblem expected code = expectProblemAmong expected [code]

-- | The status and one of the problem codes.
expectProblemAmong :: Int -> [Text] -> Reply -> IO ()
expectProblemAmong expected codes reply = do
  problem <- expectStatus expected reply
  code <- field "code" problem
  unless (code `elem` codes) $
    assertFailure ("expected problem code " <> show codes <> ", got " <> show code <> ": " <> show problem)

mentions :: Text -> Value -> Bool
mentions word value = word `Text.isInfixOf` Text.decodeUtf8 (LazyByteString.toStrict (Aeson.encode value))

-- | None of the words appears anywhere in the response.
expectNoMention :: [Text] -> Value -> IO ()
expectNoMention words' value =
  forM_ words' \word ->
    assertBool
      ("response mentions " <> show word <> ": " <> show value)
      (not (word `Text.isInfixOf` Text.decodeUtf8 (LazyByteString.toStrict (Aeson.encode value))))

decisionOf :: Value -> IO Text
decisionOf response = field "decision" response >>= field "result"

field :: (Aeson.FromJSON a) => Aeson.Key -> Value -> IO a
field key value =
  either (assertFailure . (("field " <> show key <> ": ") <>)) pure $
    Aeson.parseEither (Aeson.withObject "response" (.: key)) value
