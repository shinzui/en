{-# LANGUAGE OverloadedRecordDot #-}

-- | Workload definitions and the closed-loop measurement engine.
--
-- A workload is one kind of request repeated in a loop. Each of a fixed number of client
-- threads sends its next request as soon as the previous one returns, so throughput is
-- whatever the server sustains. Several workloads can run at once ('runGroups'), which is
-- how the interference preview, and later the tenant scenarios, put a victim and an
-- aggressor on the machine together under one clock.
--
-- Latency is timed on the monotonic clock. Requests that start during warm-up are sent
-- but not recorded; a request is recorded when it starts inside the measurement window.
-- Any non-2xx response or transport error is counted, and a result with errors is
-- invalid: the caller refuses to report it.
module Workload
  ( LoadSettings (..),
    defaultLoadSettings,
    smokeLoadSettings,
    Target (..),
    RequestSpec (..),
    Workload (..),
    benchWorkloads,
    checkDirect,
    checkNested,
    lookupWorkload,
    LoadGroup (..),
    WorkloadResult (..),
    runGroups,
    runWorkload,
    verifyWorkload,
    percentile,
  )
where

import Control.Concurrent.Async (forConcurrently, mapConcurrently)
import Control.Exception (SomeException, displayException, evaluate, try)
import Data.Aeson (FromJSON, ToJSON, Value (..), (.:))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector.Algorithms.Intro qualified as Intro
import Data.Vector.Unboxed qualified as Vector
import Data.Vector.Unboxed.Mutable qualified as MVector
import Data.Word (Word64)
import Fixture (Credential (..), ServerProfile (..), lookupExpectedCount, userCount)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Generics (Generic)
import Network.HTTP.Client qualified as Http
import Network.HTTP.Types (hAuthorization, hContentType, statusCode)

data LoadSettings = LoadSettings
  { threads :: !Int,
    warmupSeconds :: !Double,
    measureSeconds :: !Double
  }
  deriving stock (Show)

-- | 32 client threads, 5 seconds of warm-up and 30 of measurement per workload.
--
-- 30 rather than the 20 first planned: at 20 seconds a binary compared with itself showed
-- 11-61% round-to-round throughput spread, at 30 seconds (with a discarded warm-up round)
-- 9-17%. See docs/plans/72-build-an-en-server-load-benchmark-and-record-the-single-tenant-baseline.md.
defaultLoadSettings :: LoadSettings
defaultLoadSettings = LoadSettings {threads = 32, warmupSeconds = 5, measureSeconds = 30}

-- | 4 threads, 1 second and 3 seconds: enough to prove every workload works.
smokeLoadSettings :: LoadSettings
smokeLoadSettings = LoadSettings {threads = 4, warmupSeconds = 1, measureSeconds = 3}

-- | Where a workload's requests go and which key they present.
data Target = Target
  { targetUrl :: !Text,
    secret :: !ByteString
  }

-- | One request: a path under the base URL and a JSON body, always POSTed.
data RequestSpec = RequestSpec
  { path :: !Text,
    body :: !LazyByteString.ByteString
  }

data Workload = Workload
  { name :: !Text,
    -- | The server configuration the workload is measured against.
    profile :: !ServerProfile,
    credential :: !Credential,
    -- | The request a thread sends: thread index, then that thread's sequence number.
    makeRequest :: Int -> Int -> RequestSpec,
    -- | What a correct response looks like, checked once before measuring so a
    --     workload cannot silently measure an error or the wrong question.
    expectation :: Value -> Either Text ()
  }

-- | The six workloads of a @run@, in the order they are reported.
--
-- @write@ is last because it grows the database. The salt makes its tuples new on every
-- round of an A/B run, which reuses one database per binary.
benchWorkloads :: Text -> [Workload]
benchWorkloads writeSalt =
  [ checkDirect,
    checkNested,
    checkDirect {name = "check-cached", profile = CachedProfile},
    lookupWorkload,
    checkDirect {name = "check-last-key", credential = LastReadOnlyKey},
    writeWorkload writeSalt
  ]

-- | A user and a space whose direct viewer the user is. Users rotate so the decision
-- cache, when enabled, holds one entry per user rather than one entry in total.
checkDirect :: Workload
checkDirect =
  Workload
    { name = "check-direct",
      profile = PlainProfile,
      credential = PrimaryKey,
      makeRequest = \thread n ->
        let user = rotate thread n
         in checkRequest "space" "s" user user,
      expectation = expectAllowed
    }

-- | A check that resolves through two levels of group membership: the folder grants
-- @view@ to an outer group, whose member is the user's inner group.
checkNested :: Workload
checkNested =
  Workload
    { name = "check-nested",
      profile = PlainProfile,
      credential = PrimaryKey,
      makeRequest = \thread n ->
        let user = rotate thread n
         in checkRequest "folder" "f" user ((user `mod` 50) + 50 * (n `mod` 20)),
      expectation = expectAllowed
    }

lookupWorkload :: Workload
lookupWorkload =
  Workload
    { name = "lookup",
      profile = PlainProfile,
      credential = PrimaryKey,
      makeRequest = \thread n ->
        RequestSpec
          { path = "/v1/lookup",
            body =
              render $
                "{\"consistency\":{\"mode\":\"minimizeLatency\"},\"subject\":"
                  <> userSubject (rotate thread n)
                  <> ",\"permission\":\"view\",\"objectType\":\"space\",\"context\":{\"values\":{}},\"limit\":1000,\"cursor\":null,\"deadlineMillis\":null}"
          },
      expectation = expectObjectCount lookupExpectedCount
    }

-- | One new tuple per request, for a user outside the seeded set so that the graph
-- the read workloads measure never changes.
writeWorkload :: Text -> Workload
writeWorkload salt =
  Workload
    { name = "write",
      profile = PlainProfile,
      credential = PrimaryKey,
      makeRequest = \thread n ->
        RequestSpec
          { path = "/v1/relationships",
            body =
              render $
                "{\"tuples\":[{\"object\":{\"objectType\":\"space\",\"objectId\":\"w-"
                  <> Builder.byteString (encodeText salt)
                  <> "-"
                  <> Builder.intDec thread
                  <> "-"
                  <> Builder.intDec n
                  <> "\"},\"relation\":\"viewer\",\"subject\":{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"writer-"
                  <> Builder.intDec thread
                  <> "\"},\"caveat\":null}]}"
          },
      expectation = expectField "token"
    }

rotate :: Int -> Int -> Int
rotate thread n = (thread * 7919 + n) `mod` userCount

checkRequest :: Builder.Builder -> Builder.Builder -> Int -> Int -> RequestSpec
checkRequest objectType prefix user objectNumber =
  RequestSpec
    { path = "/v1/check",
      body =
        render $
          "{\"consistency\":{\"mode\":\"minimizeLatency\"},\"context\":{\"values\":{}},\"subject\":"
            <> userSubject user
            <> ",\"permission\":\"view\",\"object\":{\"objectType\":\""
            <> objectType
            <> "\",\"objectId\":\""
            <> prefix
            <> Builder.intDec objectNumber
            <> "\"}}"
    }

userSubject :: Int -> Builder.Builder
userSubject user =
  "{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"u" <> Builder.intDec user <> "\"}"

render :: Builder.Builder -> LazyByteString.ByteString
render = Builder.toLazyByteString

encodeText :: Text -> ByteString
encodeText = LazyByteString.toStrict . Builder.toLazyByteString . Builder.stringUtf8 . Text.unpack

expectAllowed :: Value -> Either Text ()
expectAllowed value =
  case Aeson.parseEither (Aeson.withObject "check" \o -> (o .: "decision") >>= Aeson.withObject "decision" (.: "result")) value of
    Right ("allowed" :: Text) -> Right ()
    Right other -> Left ("decision was " <> other <> ", expected allowed")
    Left err -> Left (Text.pack err)

expectObjectCount :: Int -> Value -> Either Text ()
expectObjectCount expected value =
  case Aeson.parseEither (Aeson.withObject "lookup" (.: "objects")) value of
    Right (objects :: [Value])
      | length objects == expected -> Right ()
      | otherwise ->
          Left
            ( "lookup returned "
                <> Text.pack (show (length objects))
                <> " objects, expected "
                <> Text.pack (show expected)
                <> "; response: "
                <> Text.pack (reverse (take 400 (reverse (show value))))
            )
    Left err -> Left (Text.pack err)

expectField :: Aeson.Key -> Value -> Either Text ()
expectField key value =
  case Aeson.parseEither (Aeson.withObject "response" (.: key)) value of
    Right (_ :: Value) -> Right ()
    Left err -> Left (Text.pack err)

-- | One workload running on its own threads against its own target, as part of a group
-- that shares one warm-up and one measurement window.
data LoadGroup = LoadGroup
  { label :: !Text,
    groupWorkload :: !Workload,
    target :: !Target,
    groupThreads :: !Int
  }

data WorkloadResult = WorkloadResult
  { workload :: !Text,
    requests :: !Int,
    seconds :: !Double,
    requestsPerSecond :: !Double,
    p50Ms :: !Double,
    p95Ms :: !Double,
    p99Ms :: !Double,
    errors :: !Int,
    firstError :: !(Maybe Text)
  }
  deriving stock (Generic, Show)
  deriving anyclass (ToJSON, FromJSON)

-- | Send one request and check the response is what the workload claims to measure.
verifyWorkload :: Http.Manager -> Target -> Workload -> IO (Either Text ())
verifyWorkload manager target' workload' = do
  request <- buildRequest target' (makeRequest workload' 0 0)
  outcome <- try (Http.httpLbs request manager) :: IO (Either SomeException (Http.Response LazyByteString.ByteString))
  pure case outcome of
    Left err -> Left (Text.pack (displayException err))
    Right response
      | status <- statusCode (Http.responseStatus response),
        status < 200 || status >= 300 ->
          Left ("HTTP " <> Text.pack (show status) <> ": " <> Text.pack (show (Http.responseBody response)))
      | otherwise ->
          case Aeson.eitherDecode (Http.responseBody response) of
            Left err -> Left (Text.pack err)
            Right value -> expectation workload' value

runWorkload :: LoadSettings -> Target -> Workload -> IO WorkloadResult
runWorkload settings target' workload' = do
  results <-
    runGroups
      settings
      [LoadGroup {label = name workload', groupWorkload = workload', target = target', groupThreads = threads settings}]
  case results of
    [result] -> pure result
    _ -> fail "runGroups returned the wrong number of results"

-- | Run every group at once under one clock and return one result per group.
--
-- Each group has its own connection manager sized to its thread count, so one group's
-- connections can never queue behind another's inside the client.
runGroups :: LoadSettings -> [LoadGroup] -> IO [WorkloadResult]
runGroups settings groups = do
  managers <- traverse (\group -> Http.newManager (managerFor (groupThreads group))) groups
  started <- getMonotonicTimeNSec
  let measureFrom = started + seconds' (warmupSeconds settings)
      measureUntil = measureFrom + seconds' (measureSeconds settings)
  forConcurrently (zip managers groups) \(manager, group) -> do
    request0 <- buildRequest (target group) (RequestSpec "/" "")
    perThread <-
      mapConcurrently
        (clientThread manager request0 (groupWorkload group) measureFrom measureUntil)
        [0 .. groupThreads group - 1]
    summarize (name (groupWorkload group)) (measureSeconds settings) perThread
  where
    seconds' s = round (s * 1e9) :: Word64

managerFor :: Int -> Http.ManagerSettings
managerFor connections =
  Http.defaultManagerSettings
    { Http.managerConnCount = connections,
      Http.managerResponseTimeout = Http.responseTimeoutMicro 60_000_000
    }

buildRequest :: Target -> RequestSpec -> IO Http.Request
buildRequest target' spec = do
  request <- Http.parseRequest (Text.unpack (targetUrl target' <> path spec))
  pure
    request
      { Http.method = "POST",
        Http.requestHeaders =
          [ (hAuthorization, "Bearer " <> secret target'),
            (hContentType, "application/json")
          ],
        Http.requestBody = Http.RequestBodyLBS (body spec)
      }

data ThreadOutcome = ThreadOutcome
  { latencies :: !(Vector.Vector Word64),
    threadErrors :: !Int,
    threadFirstError :: !(Maybe Text)
  }

-- | Loop until the window closes. Latencies go into a growable unboxed buffer so a
-- million samples cost eight megabytes and no garbage-collector pressure per sample.
clientThread :: Http.Manager -> Http.Request -> Workload -> Word64 -> Word64 -> Int -> IO ThreadOutcome
clientThread manager request0 workload' measureFrom measureUntil thread = do
  initial <- MVector.new 4096
  errorsRef <- newIORef (0 :: Int, Nothing :: Maybe Text)
  let loop buffer used n = do
        start <- getMonotonicTimeNSec
        if start >= measureUntil
          then pure (buffer, used)
          else do
            let spec = makeRequest workload' thread n
                request =
                  request0
                    { Http.path = encodeText (path spec),
                      Http.requestBody = Http.RequestBodyLBS (body spec)
                    }
            outcome <- try (Http.withResponse request manager consume) :: IO (Either SomeException (Either Text ()))
            end <- getMonotonicTimeNSec
            let failure = case outcome of
                  Left err -> Just (Text.pack (displayException err))
                  Right (Left err) -> Just err
                  Right (Right ()) -> Nothing
            -- Errors during warm-up count too: a server that fails while warming is
            -- not one whose numbers mean anything.
            case failure of
              Just err ->
                atomicModifyIORef' errorsRef \(count, firstErr) -> ((count + 1, maybe (Just err) Just firstErr), ())
              Nothing -> pure ()
            if start >= measureFrom
              then do
                buffer' <-
                  if used == MVector.length buffer
                    then MVector.grow buffer used
                    else pure buffer
                MVector.unsafeWrite buffer' used (end - start)
                loop buffer' (used + 1) (n + 1)
              else loop buffer used (n + 1)
  (buffer, used) <- loop initial 0 0
  frozen <- Vector.freeze (MVector.slice 0 used buffer)
  (count, firstErr) <- readIORef errorsRef
  pure ThreadOutcome {latencies = frozen, threadErrors = count, threadFirstError = firstErr}
  where
    consume response = do
      let status = statusCode (Http.responseStatus response)
      chunks <- Http.brConsume (Http.responseBody response)
      _ <- evaluate (sum (map (\c -> fromIntegral (LazyByteString.length (LazyByteString.fromStrict c))) chunks) :: Int)
      pure
        if status >= 200 && status < 300
          then Right ()
          else Left ("HTTP " <> Text.pack (show status) <> ": " <> Text.pack (show (mconcat chunks)))

summarize :: Text -> Double -> [ThreadOutcome] -> IO WorkloadResult
summarize workloadName windowSeconds outcomes = do
  let combined = Vector.concat (map latencies outcomes)
  sorted <- do
    mutable <- Vector.thaw combined
    Intro.sort mutable
    Vector.freeze mutable
  let count = Vector.length sorted
      toMs ns = fromIntegral ns / 1e6
      errorCount = sum (map threadErrors outcomes)
  pure
    WorkloadResult
      { workload = workloadName,
        requests = count,
        seconds = windowSeconds,
        requestsPerSecond = fromIntegral count / windowSeconds,
        p50Ms = toMs (percentile 0.50 sorted),
        p95Ms = toMs (percentile 0.95 sorted),
        p99Ms = toMs (percentile 0.99 sorted),
        errors = errorCount,
        firstError = firstJust (map threadFirstError outcomes)
      }
  where
    firstJust = foldr (\candidate rest -> maybe rest Just candidate) Nothing

-- | The sorted sample at @ceiling (q * n)@, one-based; zero for an empty sample.
percentile :: Double -> Vector.Vector Word64 -> Word64
percentile q sorted
  | Vector.null sorted = 0
  | otherwise =
      let n = Vector.length sorted
          rank = max 1 (min n (ceiling (q * fromIntegral n)))
       in sorted Vector.! (rank - 1)
