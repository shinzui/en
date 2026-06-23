-- | Fail-closed authorization helper for Servant handlers.
module En.Servant.Authorize (
    AuthorizationEnv (..),
    requirePermission,
) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (encode)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Servant (Handler, ServerError (..), err403, err500, throwError)

import En.Check (CheckDecision (..), check)
import En.Effect.ConsistencyStore (ConsistencyStore)
import En.Effect.TupleStore (TupleStore)
import En.Error (EnError)
import En.Reachability (ReachabilityGraph)
import En.Revision (Consistency)
import En.Schema (RelationName)
import En.Servant.API (ErrorWire (..))
import En.Tuple (CaveatContext, ObjectRef, Subject)

data AuthorizationEnv = AuthorizationEnv
    { consistencyStore :: !(ConsistencyStore IO)
    , tupleStore :: !(TupleStore IO)
    , graph :: !ReachabilityGraph
    }

requirePermission ::
    AuthorizationEnv ->
    Consistency ->
    CaveatContext ->
    Subject ->
    RelationName ->
    ObjectRef ->
    Handler ()
requirePermission env consistency context subject permission object = do
    decision <-
        liftIO
            ( check
                env.consistencyStore
                env.tupleStore
                env.graph
                consistency
                context
                subject
                permission
                object
            )
            >>= eitherEngine
    case decision of
        Allowed -> pure ()
        Denied -> throwError (jsonError err403 "permission denied")
        Conditional _ -> throwError (jsonError err403 "permission is conditional")

eitherEngine :: Either EnError a -> Handler a
eitherEngine =
    either (throwError . jsonError err500 . Text.pack . show) pure

jsonError :: ServerError -> Text -> ServerError
jsonError err message =
    err
        { errBody = encode ErrorWire{error = message}
        , errHeaders = [("Content-Type", Text.encodeUtf8 "application/json")]
        }
