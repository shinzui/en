module Main (main) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Middleware
import Network.HTTP.Types (hAuthorization, status200, status403)
import Network.Wai (defaultRequest, pathInfo, requestHeaders, requestMethod, responseLBS, responseStatus)
import Network.Wai.Internal (ResponseReceived (..))
import Test.Tasty (defaultMain, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

main :: IO ()
main =
  defaultMain $
    testGroup
      "read-only route classification"
      [ testCase "query, watch, and check pass with a read-only key" $
          mapM_ (\path -> statusAt path >>= (@?= status200)) [["v1", "relationships", "query"], ["v1", "watch"], ["v1", "check"]],
        testCase "write, delete, delete-by-filter, and unknown relationship POST remain forbidden" $
          mapM_ (\path -> statusAt path >>= (@?= status403)) [["v1", "relationships"], ["v1", "relationships", "delete"], ["v1", "relationships", "delete-by-filter"], ["v1", "relationships", "future-write"]]
      ]
  where
    statusAt path = do
      result <- newEmptyMVar
      let app = authMiddleware (AuthKeys [ApiKey "reader" "test-only-key" ReadOnly]) (\_ respond -> respond (responseLBS status200 [] ""))
      _ <- app (defaultRequest {pathInfo = path, requestMethod = "POST", requestHeaders = [(hAuthorization, "Bearer test-only-key")]}) (\response -> putMVar result (responseStatus response) >> pure ResponseReceived)
      takeMVar result
