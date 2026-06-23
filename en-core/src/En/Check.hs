-- | Forward evaluation: does a subject have a permission on an object?
module En.Check (
    CheckDecision (..),
    CaveatObligation (..),
    check,
) where

import Data.Text (Text)

import En.Effect.TupleStore (TupleStore)
import En.Reachability (ReachabilityGraph)
import En.Revision (Consistency)
import En.Schema (CaveatName, RelationName)
import En.Tuple (CaveatContext, ObjectRef, Subject)

-- | A caveat that could not be reduced to an unconditional answer.
data CaveatObligation = CaveatObligation
    { caveat :: !CaveatName
    , missingContext :: ![Text]
    }
    deriving stock (Eq, Show)

{- | Three-valued authorization result. 'Conditional' means the graph path exists
but one or more caveats need request context before the caller may treat it as
allowed.
-}
data CheckDecision
    = Allowed
    | Denied
    | Conditional ![CaveatObligation]
    deriving stock (Eq, Show)

{- | Does @subject@ have @permission@ on @object@? Forward evaluation over the
reachability graph and the tuple store.
-}
check ::
    TupleStore m ->
    ReachabilityGraph ->
    Consistency ->
    CaveatContext ->
    Subject ->
    RelationName ->
    ObjectRef ->
    m CheckDecision
check =
    error "TODO(en): forward check; see docs/spec/0001-en-overview.md"
