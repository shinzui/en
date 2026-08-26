-- | Fail-closed authorization helper for Servant handlers.
module En.Servant.Authorize
  ( requirePermission,
  )
where

import Data.Generics.Labels ()
import En.Check (CheckDecision (..))
import En.Prelude
import En.Revision (Consistency)
import En.Schema (RelationName)
import En.Servant.Seam (Env (..), permissionDenied, runEngine)
import En.Tuple (CaveatContext, ObjectRef, Subject)
import Servant (Handler, throwError)

requirePermission ::
  Env es ->
  Consistency ->
  CaveatContext ->
  Subject ->
  RelationName ->
  ObjectRef ->
  Handler ()
requirePermission env@Env {readActiveSchema, checkOperation} consistency context subject permission object = do
  active <- liftIO readActiveSchema
  -- A gate wants the answer, not the snapshot it was answered at. The token is
  -- for callers who will chain a later read against this one.
  outcome <-
    runEngine
      env
      active
      ( checkOperation
          (active ^. #graph)
          consistency
          context
          subject
          permission
          object
      )
  case (outcome ^. #decision) of
    Allowed -> pure ()
    Denied -> throwError (permissionDenied "permission denied")
    Conditional _ ->
      throwError
        (permissionDenied "permission is conditional; supply the missing caveat context")
