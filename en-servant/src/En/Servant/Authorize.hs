-- | Fail-closed authorization helper for Servant handlers.
module En.Servant.Authorize (
    requirePermission,
) where

import Effectful qualified
import Effectful.Error.Static (Error)
import Servant (Handler, err403, throwError)

import En.Check (CheckDecision (..), check)
import En.Effect.ConsistencyStore (ConsistencyStore)
import En.Effect.TupleStore (TupleStore)
import En.Error (EnError)
import En.Revision (Consistency)
import En.Schema (RelationName)
import En.Servant.Seam (Env (..), jsonError, runEngine)
import En.Tuple (CaveatContext, ObjectRef, Subject)

requirePermission ::
    (ConsistencyStore Effectful.:> es, TupleStore Effectful.:> es, Error EnError Effectful.:> es) =>
    Env es ->
    Consistency ->
    CaveatContext ->
    Subject ->
    RelationName ->
    ObjectRef ->
    Handler ()
requirePermission env consistency context subject permission object = do
    decision <-
        runEngine
            env
            ( check
                env.graph
                consistency
                context
                subject
                permission
                object
            )
    case decision of
        Allowed -> pure ()
        Denied -> throwError (jsonError err403 "permission denied")
        Conditional _ -> throwError (jsonError err403 "permission is conditional")
