-- | Reverse expansion: list the objects a subject can reach with a permission.
module En.Lookup
  ( lookup
  ) where

import Prelude hiding (lookup)

import En.Effect.TupleStore (TupleStore)
import En.Reachability (ReachabilityGraph)
import En.Revision (Consistency)
import En.Schema (ObjectType, RelationName)
import En.Tuple (ObjectRef, Subject)

-- | List the objects of @objectType@ on which @subject@ has @permission@:
-- reverse expansion (subject → resource) plus reach-then-check for conditional
-- entrypoints (intersection / exclusion / caveats), streamed and cursorable.
-- This is the read-filter primitive (e.g. kawa filtering the activity stream).
lookup
  :: Monad m
  => TupleStore m
  -> ReachabilityGraph
  -> Consistency
  -> Subject
  -> RelationName
  -> ObjectType
  -> m [ObjectRef]
lookup =
  error "TODO(en): reverse-expansion lookup; see docs/spec/0001-en-overview.md"
