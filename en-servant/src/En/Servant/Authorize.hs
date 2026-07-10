-- | Fail-closed authorization helper for Servant handlers.
module En.Servant.Authorize (
    requirePermission,
) where

import Servant (Handler, throwError)

import En.Check (CheckDecision (..), CheckOutcome (..))
import En.Revision (Consistency)
import En.Schema (RelationName)
import En.Servant.Seam (Env (..), permissionDenied, runEngine)
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
    -- A gate wants the answer, not the snapshot it was answered at. The token is
    -- for callers who will chain a later read against this one.
    outcome <-
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
    case outcome.decision of
        Allowed -> pure ()
        Denied -> throwError (permissionDenied "permission denied")
        Conditional _ ->
            throwError
                (permissionDenied "permission is conditional; supply the missing caveat context")
