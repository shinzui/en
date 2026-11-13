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
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCaseSteps)

main :: IO ()
main =
  defaultMain $
    testGroup
      "en-server tenancy"
      [ upgradeTest,
        isolationTest,
        rateLimitTest,
        storageSeparationTest
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
withTwoTenants extra action =
  withSystemTempDirectory "en-tenant-tests" \directory ->
    withPostgres \alphaPostgres ->
      withPostgres \betaPostgres -> do
        alphaUrl <- createMigratedDatabase alphaPostgres "en_alpha"
        betaUrl <- createMigratedDatabase betaPostgres "en_beta"
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
