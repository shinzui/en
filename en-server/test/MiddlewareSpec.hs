module Main (main) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Data.ByteString.Builder (toLazyByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf, isPrefixOf)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import En.Cache (CacheStats (..))
import Metrics
import Middleware
import Network.HTTP.Types (hAuthorization, methodGet, status200, status403)
import Network.Wai (Application, Request, Response, defaultRequest, pathInfo, requestHeaders, requestMethod, responseLBS, responseStatus, responseToStream)
import Network.Wai.Internal (ResponseReceived (..))
import Observability (tenantSpanAttribute, tenantSpanMiddleware)
import OpenTelemetry.Attributes (lookupAttribute, toAttribute)
import OpenTelemetry.Context qualified as Context
import OpenTelemetry.Instrumentation.Wai (newOpenTelemetryWaiMiddleware', requestContext)
import OpenTelemetry.Metric.Core (getMeter, noopMeterProvider)
import OpenTelemetry.Processor.Span (FlushResult (..), ShutdownResult (..), SpanProcessor (..))
import OpenTelemetry.Trace.Core (createTracerProvider, emptyTracerProviderOptions, spanGetAttributes)
import Test.Tasty (defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase, (@?=))

main :: IO ()
main =
  defaultMain $
    testGroup
      "en-server middleware"
      [ testGroup
          "read-only route classification"
          [ testCase "query, watch, and check pass with a read-only key" $
              mapM_ (\path -> statusAt path >>= (@?= status200)) [["v1", "relationships", "query"], ["v1", "watch"], ["v1", "check"]],
            testCase "write, delete, delete-by-filter, and unknown relationship POST remain forbidden" $
              mapM_ (\path -> statusAt path >>= (@?= status403)) [["v1", "relationships"], ["v1", "relationships", "delete"], ["v1", "relationships", "delete-by-filter"], ["v1", "relationships", "future-write"]]
          ],
        testGroup
          "an operator scrape key"
          [ testCase "may GET /metrics" do
              status <- responseStatus <$> run (scrapeOnly ok) (defaultRequest {pathInfo = ["metrics"], requestMethod = methodGet})
              status @?= status200,
            testCase "may call nothing else, reads included" $
              mapM_
                ( \(method, path) -> do
                    status <- responseStatus <$> run (scrapeOnly ok) (defaultRequest {pathInfo = path, requestMethod = method})
                    assertEqual (show (method, path)) status403 status
                )
                [("POST", ["v1", "check"]), ("GET", ["v1", "schema"]), ("POST", ["v1", "relationships"]), ("POST", ["metrics"])]
          ],
        testGroup
          "tenant identity"
          [ testCase "the tenant is an attribute of the request's server span" do
              let processor =
                    SpanProcessor
                      { spanProcessorOnStart = \_ _ -> pure (),
                        spanProcessorOnEnd = \_ -> pure (),
                        spanProcessorShutdown = pure ShutdownSuccess,
                        spanProcessorForceFlush = pure FlushSuccess
                      }
              provider <- createTracerProvider [processor] emptyTracerProviderOptions
              meter <- getMeter noopMeterProvider "en-server-test"
              telemetry <- newOpenTelemetryWaiMiddleware' provider meter
              seen <- newEmptyMVar
              let inner request respond = do
                    attribute <- case requestContext request >>= Context.lookupSpan of
                      Nothing -> pure Nothing
                      Just span' -> (`lookupAttribute` tenantSpanAttribute) <$> spanGetAttributes span'
                    putMVar seen attribute
                    respond (responseLBS status200 [] "")
              _ <- run (telemetry (tenantSpanMiddleware "alpha" inner)) defaultRequest
              attribute <- takeMVar seen
              attribute @?= Just (toAttribute ("alpha" :: Text)),
            testCase "without telemetry there is no span and the request passes" do
              status <- responseStatus <$> run (tenantSpanMiddleware "alpha" ok) defaultRequest
              status @?= status200
          ],
        testGroup
          "metrics rendering"
          [ testCase "legacy mode: no tenant label and no availability family" do
              registry <- newMetrics
              rendered <- scrape (metricsRoute registry [("decision", pure stats)]) registry
              assertBool "no tenant label" (not ("tenant=" `isInfixOf` rendered))
              assertBool "no availability family" (not ("en_tenant_available" `isInfixOf` rendered))
              assertBool "cache sample" ("en_cache_hits_total{cache=\"decision\"} 3\n" `isInfixOf` rendered),
            testCase "every tenant's samples under one header per family, tenant last" do
              alpha <- newMetrics
              beta <- newMetrics
              alphaUp <- newIORef True
              let sources =
                    [ Source {tenant = Just "alpha", metrics = alpha, caches = pure [("decision", stats)], available = Just (readIORef alphaUp)},
                      Source {tenant = Just "beta", metrics = beta, caches = pure [], available = Just (pure False)}
                    ]
              rendered <- scrape (scrapeRoute sources) alpha
              let headers = filter ("# TYPE " `isPrefixOf`) (lines rendered)
              assertEqual "each family declared once" (length headers) (length (dedupe headers))
              assertBool "alpha's request sample" ("en_http_requests_total{path=\"check\",status=\"2xx\",tenant=\"alpha\"} 1\n" `isInfixOf` rendered)
              assertBool "no beta request sample" (not ("status=\"2xx\",tenant=\"beta\"" `isInfixOf` rendered))
              assertBool "alpha's cache sample" ("en_cache_hits_total{cache=\"decision\",tenant=\"alpha\"} 3\n" `isInfixOf` rendered)
              assertBool "gauge type" ("# TYPE en_tenant_available gauge\n" `isInfixOf` rendered)
              assertBool "alpha available" ("en_tenant_available{tenant=\"alpha\"} 1\n" `isInfixOf` rendered)
              assertBool "beta unavailable" ("en_tenant_available{tenant=\"beta\"} 0\n" `isInfixOf` rendered)
          ]
      ]
  where
    ok :: Application
    ok _ respond = respond (responseLBS status200 [] "")

    stats = CacheStats {hits = 3, misses = 1, inserts = 1, evictions = 0}

    statusAt path = do
      let app = authMiddleware (AuthKeys [ApiKey "reader" "test-only-key" ReadOnly]) ok
      responseStatus <$> run app (defaultRequest {pathInfo = path, requestMethod = "POST", requestHeaders = [(hAuthorization, "Bearer test-only-key")]})

    -- Count one request through the recorder, then scrape.
    scrape route registry = do
      _ <- run (metricsMiddleware registry (route ok)) (defaultRequest {pathInfo = ["v1", "check"]})
      response <- run (metricsMiddleware registry (route ok)) (defaultRequest {pathInfo = ["metrics"], requestMethod = methodGet})
      Text.unpack . Text.decodeUtf8 . LazyByteString.toStrict <$> body response

    dedupe = foldr (\x seen -> if x `elem` seen then seen else x : seen) []

run :: Application -> Request -> IO Response
run app request = do
  result <- newEmptyMVar
  _ <- app request (\response -> putMVar result response >> pure ResponseReceived)
  takeMVar result

body :: Response -> IO LazyByteString.ByteString
body response = do
  let (_, _, withBody) = responseToStream response
  chunks <- newIORef mempty
  withBody \stream -> stream (\chunk -> modifyIORef' chunks (<> chunk)) (pure ())
  toLazyByteString <$> readIORef chunks
