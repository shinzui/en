-- | Fail-closed authorization helper for Servant handlers.
module En.Servant.Authorize (
    requirePermission,
) where

import Servant (Handler, err403, throwError)

import En.Check (CheckDecision (..))
import En.Revision (Consistency)
import En.Schema (RelationName)
import En.Servant.Seam (Env (..), jsonError, runEngine)
import En.Tuple (CaveatContext, ObjectRef, Subject)

requirePermission ::
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
            ( env.checkOperation
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
