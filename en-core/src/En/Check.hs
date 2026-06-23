-- | Forward evaluation: does a subject have a permission on an object?
module En.Check
  ( check
  ) where

import En.Effect.TupleStore (TupleStore)
import En.Reachability (ReachabilityGraph)
import En.Revision (Consistency)
import En.Schema (RelationName)
import En.Tuple (ObjectRef, Subject)

-- | Does @subject@ have @permission@ on @object@? Forward evaluation over the
-- reachability graph and the tuple store. (Caveated results carry their
-- missing-context obligations; that refinement lands with the caveat evaluator.)
check
  :: Monad m
  => TupleStore m
  -> ReachabilityGraph
  -> Consistency
  -> Subject
  -> RelationName
  -> ObjectRef
  -> m Bool
check =
  error "TODO(en): forward check; see docs/spec/0001-en-overview.md"
