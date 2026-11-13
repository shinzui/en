-- | Black-box proofs about tenancy in @en-server@: the shipped binary is started against
-- disposable PostgreSQL and spoken to over HTTP.
--
-- See docs/plans/73-serve-tenants-selected-by-api-key-each-from-its-own-isolated-stack.md
-- and docs/masterplans/12-serve-several-isolated-tenants-from-one-en-server.md (gate G4).
module Main (main) where

import Control.Monad (unless)
import Data.Aeson (Value, (.:))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as Aeson
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Network.HTTP.Client qualified as Http
import Network.HTTP.Types (statusCode)
import ServerHarness
import System.Directory (doesFileExist)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertEqual, assertFailure, testCaseSteps)

main :: IO ()
main =
  defaultMain $
    testGroup
      "en-server tenancy"
      [ upgradeTest
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
            identity <- serverIdentity manager server
            written <-
              postJson manager server "/v1/relationships" $
                Aeson.object
                  [ "tuples"
                      Aeson..= [ Aeson.object
                                   [ "object" Aeson..= objectRef "space" "s1",
                                     "relation" Aeson..= ("viewer" :: Text),
                                     "subject" Aeson..= subjectRef "user" "ann"
                                   ]
                               ]
                  ]
            token <- expectStatus 200 written >>= field "token"
            pure (identity, token :: Text)

          step ("starting the candidate binary " <> candidate)
          withServer (serverSpec candidate environment) \server -> do
            after <- serverIdentity manager server
            assertEqual "datastore id" (identityDatastoreId before) (identityDatastoreId after)
            assertEqual "schema hash (startup line)" (identityStartupHash before) (identityStartupHash after)
            assertEqual "schema hash (GET /v1/schema)" (identitySchemaHash before) (identitySchemaHash after)
            checked <-
              postJson manager server "/v1/check" $
                Aeson.object
                  [ "consistency" Aeson..= Aeson.object ["mode" Aeson..= ("atLeastAsFresh" :: Text), "token" Aeson..= token],
                    "context" Aeson..= Aeson.object ["values" Aeson..= Aeson.object []],
                    "subject" Aeson..= subjectRef "user" "ann",
                    "permission" Aeson..= ("view" :: Text),
                    "object" Aeson..= objectRef "space" "s1"
                  ]
            decision <- expectStatus 200 checked >>= field "decision"
            result <- either (assertFailure . ("decision: " <>)) pure (Aeson.parseEither (Aeson.withObject "decision" (.: "result")) decision)
            assertEqual "check under the pre-upgrade token" ("allowed" :: Text) result

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

data Identity = Identity
  { identityDatastoreId :: Text,
    identityStartupHash :: Text,
    identitySchemaHash :: Text
  }

-- | The datastore id and schema hash a server printed at startup, and the hash it serves.
serverIdentity :: Http.Manager -> RunningServer -> IO Identity
serverIdentity manager server = do
  output <- capturedLines server
  datastoreId <- startupValue "Datastore id: " output
  startupHash <- startupValue "Schema hash: " output
  schema <- getJson manager server "/v1/schema" >>= expectStatus 200
  served <- field "hash" schema
  pure Identity {identityDatastoreId = datastoreId, identityStartupHash = startupHash, identitySchemaHash = served}

startupValue :: Text -> [Text] -> IO Text
startupValue prefix output =
  case find (prefix `Text.isPrefixOf`) output of
    Just line -> pure (Text.drop (Text.length prefix) line)
    Nothing -> assertFailure ("no startup line beginning " <> show prefix <> " in:\n" <> Text.unpack (Text.unlines output))

objectRef :: Text -> Text -> Value
objectRef objectType objectId =
  Aeson.object ["objectType" Aeson..= objectType, "objectId" Aeson..= objectId]

subjectRef :: Text -> Text -> Value
subjectRef objectType objectId =
  Aeson.object ["kind" Aeson..= ("id" :: Text), "objectType" Aeson..= objectType, "objectId" Aeson..= objectId]

-- * HTTP

type Reply = (Int, LazyByteString.ByteString)

getJson :: Http.Manager -> RunningServer -> Text -> IO Reply
getJson manager server path = do
  request <- authorized server path
  send manager request

postJson :: Http.Manager -> RunningServer -> Text -> Value -> IO Reply
postJson manager server path body = do
  request <- authorized server path
  send
    manager
    request
      { Http.method = "POST",
        Http.requestBody = Http.RequestBodyLBS (Aeson.encode body),
        Http.requestHeaders = ("Content-Type", "application/json") : Http.requestHeaders request
      }

authorized :: RunningServer -> Text -> IO Http.Request
authorized server path = do
  request <- Http.parseRequest (Text.unpack (baseUrl server <> path))
  pure request {Http.requestHeaders = [("Authorization", "Bearer " <> Text.encodeUtf8 upgradeSecret)]}

send :: Http.Manager -> Http.Request -> IO Reply
send manager request = do
  response <- Http.httpLbs request manager
  pure (statusCode (Http.responseStatus response), Http.responseBody response)

expectStatus :: Int -> Reply -> IO Value
expectStatus expected (status, body) = do
  unless (status == expected) $
    assertFailure ("expected HTTP " <> show expected <> ", got " <> show status <> ": " <> show body)
  either (assertFailure . ("response is not JSON: " <>)) pure (Aeson.eitherDecode body)

field :: (Aeson.FromJSON a) => Aeson.Key -> Value -> IO a
field key value =
  either (assertFailure . (("field " <> show key <> ": ") <>)) pure $
    Aeson.parseEither (Aeson.withObject "response" (.: key)) value
