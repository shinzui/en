-- | Liveness and readiness probes for @en-server@.
--
-- These describe the /process/, not the versioned wire contract, so they live here
-- rather than in @en-servant@'s API type: they are outside @\/v1@ and absent from the
-- OpenAPI document.
--
-- The split is the one an orchestrator relies on. @\/healthz@ answers "is this process
-- able to serve HTTP at all" and so is an unconditional 200 — tying it to PostgreSQL
-- would make Kubernetes restart every replica during a database outage, which helps
-- nothing. @\/readyz@ answers "should a load balancer send this instance traffic right
-- now" and so pings PostgreSQL, because that is en's only hard runtime dependency.
--
-- Both paths are exempt from authentication and rate limiting (see "Middleware"), since
-- a probe cannot conveniently carry credentials. @\/metrics@ is deliberately not exempt.
module Health
  ( healthRoutes,
  )
where

import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy qualified as Lazy
import Data.Text (Text)
import Network.HTTP.Types (Status, hContentType, methodGet, status200, status503)
import Network.Wai (Middleware, Request (..), Response, responseLBS)

-- | Serve @GET \/healthz@ and @GET \/readyz@; pass everything else inward.
--
-- The readiness action is supplied by the caller so this module stays free of the
-- effect stack: @Main@ builds it from @En.Postgres.Database.runSession@, which routes
-- through the connection pool rather than holding a raw connection.
healthRoutes :: IO Bool -> Middleware
healthRoutes checkReady inner request respond
  | requestMethod request /= methodGet = inner request respond
  | otherwise =
      case pathInfo request of
        ["healthz"] -> respond alive
        ["readyz"] -> do
          ready <- checkReady
          respond (if ready then alive else notReady)
        _ -> inner request respond

alive :: Response
alive =
  jsonResponse status200 (encode (object ["status" .= ("ok" :: Text)]))

-- | The @{code, message, retryable}@ envelope every other en response uses, with
-- the same @store_error@ code a request would get while the store is unreachable.
notReady :: Response
notReady =
  jsonResponse status503 $
    encode
      ( object
          [ "code" .= ("store_error" :: Text),
            "message" .= ("database unreachable" :: Text),
            "retryable" .= True
          ]
      )

jsonResponse :: Status -> Lazy.ByteString -> Response
jsonResponse status =
  responseLBS status [(hContentType, "application/json")]
