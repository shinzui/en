-- | Reverse expansion: list the objects a subject can reach with a permission.
module En.Lookup (
    LookupCursor (..),
    LookupLimit (..),
    LookupRequest (..),
    LookupState (..),
    LookupPage (..),
    lookup,
) where

import Prelude hiding (lookup)

import Data.Text (Text)

import En.Effect.TupleStore (TupleStore)
import En.Reachability (ReachabilityGraph)
import En.Revision (Consistency)
import En.Schema (ObjectType, RelationName)
import En.Tuple (CaveatContext, ObjectRef, Subject)

newtype LookupCursor = LookupCursor
    { cursorEncoding :: Text
    }
    deriving stock (Eq, Ord, Show)

newtype LookupLimit = LookupLimit
    { unLookupLimit :: Int
    }
    deriving stock (Eq, Ord, Show)

data LookupRequest = LookupRequest
    { subject :: !Subject
    , permission :: !RelationName
    , objectType :: !ObjectType
    , context :: !CaveatContext
    , limit :: !LookupLimit
    , cursor :: !(Maybe LookupCursor)
    }
    deriving stock (Eq, Show)

data LookupState
    = LookupExhausted
    | LookupHasMore !LookupCursor
    | LookupTruncated !LookupCursor
    deriving stock (Eq, Ord, Show)

data LookupPage = LookupPage
    { objects :: ![ObjectRef]
    , state :: !LookupState
    }
    deriving stock (Eq, Show)

{- | List the objects of @objectType@ on which @subject@ has @permission@:
reverse expansion (subject → resource) plus reach-then-check for conditional
entrypoints (intersection / exclusion / caveats), streamed and cursorable.
This is the read-filter primitive (e.g. kawa filtering the activity stream).
-}
lookup ::
    TupleStore m ->
    ReachabilityGraph ->
    Consistency ->
    LookupRequest ->
    m LookupPage
lookup =
    error "TODO(en): reverse-expansion lookup; see docs/spec/0001-en-overview.md"
