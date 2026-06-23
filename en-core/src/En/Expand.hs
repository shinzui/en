{- | Forward expansion for review and audit UIs.

Expand answers "who can reach this object relation?" as a bounded tree. Later
plans fill in traversal; this plan fixes the public result shape.
-}
module En.Expand (
    ExpandCursor (..),
    ExpandLimit (..),
    ExpandRequest (..),
    ExpandState (..),
    ExpandNode (..),
    ExpandTree (..),
    expand,
) where

import Data.Text (Text)

import En.Effect.TupleStore (TupleRow, TupleStore)
import En.Reachability (ReachabilityGraph)
import En.Revision (Consistency)
import En.Schema (CaveatName, RelationName)
import En.Tuple (CaveatContext, ObjectRef, Subject)

newtype ExpandCursor = ExpandCursor
    { cursorEncoding :: Text
    }
    deriving stock (Eq, Ord, Show)

newtype ExpandLimit = ExpandLimit
    { unExpandLimit :: Int
    }
    deriving stock (Eq, Ord, Show)

data ExpandRequest = ExpandRequest
    { object :: !ObjectRef
    , permission :: !RelationName
    , context :: !CaveatContext
    , limit :: !ExpandLimit
    , cursor :: !(Maybe ExpandCursor)
    }
    deriving stock (Eq, Show)

data ExpandState
    = ExpandExhausted
    | ExpandHasMore !ExpandCursor
    | ExpandTruncated !ExpandCursor
    deriving stock (Eq, Ord, Show)

data ExpandNode
    = ExpandSubject !Subject !(Maybe TupleRow)
    | ExpandUserset !ObjectRef !RelationName ![ExpandNode]
    | ExpandCaveated !CaveatName ![ExpandNode]
    deriving stock (Eq, Show)

data ExpandTree = ExpandTree
    { root :: !ObjectRef
    , permission :: !RelationName
    , children :: ![ExpandNode]
    , state :: !ExpandState
    }
    deriving stock (Eq, Show)

expand ::
    TupleStore m ->
    ReachabilityGraph ->
    Consistency ->
    ExpandRequest ->
    m ExpandTree
expand =
    error "TODO(en): expand; see docs/spec/0001-en-overview.md"
