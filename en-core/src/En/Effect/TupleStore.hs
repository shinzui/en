{- | The tuple-store effect: the storage interface the engine evaluates against.

Expressed as a record of functions so a consumer or test can supply an in-memory
or PostgreSQL implementation. (Integration with a concrete effect system follows
shomei's @Shomei.Effect.*@ convention; refined as the engine lands.)
-}
module En.Effect.TupleStore (
    TupleStore (..),
    UsersetQuery (..),
    StoreCursor (..),
    TupleRowId (..),
    TupleRow (..),
    TuplePage (..),
    PageState (..),
) where

import Data.Text (Text)

import En.Revision (ConsistencyToken, Revision)
import En.Schema (ObjectType, RelationName)
import En.Tuple (Subject, Tuple)

newtype StoreCursor = StoreCursor
    { cursorEncoding :: Text
    }
    deriving stock (Eq, Ord, Show)

newtype TupleRowId = TupleRowId
    { rowIdEncoding :: Text
    }
    deriving stock (Eq, Ord, Show)

data PageState
    = Exhausted
    | HasMore !StoreCursor
    | Truncated !StoreCursor
    deriving stock (Eq, Ord, Show)

data TupleRow = TupleRow
    { rowId :: !TupleRowId
    , tuple :: !Tuple
    , createdAt :: !Revision
    , deletedAt :: !(Maybe Revision)
    }
    deriving stock (Eq, Show)

data TuplePage = TuplePage
    { rows :: ![TupleRow]
    , state :: !PageState
    }
    deriving stock (Eq, Show)

{- | The reverse-lookup query the engine issues against storage: "objects of
@queryType@ on @queryRelation@ whose subject is one of @querySubjects@."
This single primitive — Zanzibar's @ReadStartingWithUser@ — backs both
'En.Check.check' and 'En.Lookup.lookup'.
-}
data UsersetQuery = UsersetQuery
    { queryType :: !ObjectType
    , queryRelation :: !RelationName
    , querySubjects :: ![Subject]
    , queryLimit :: !Int
    , queryCursor :: !(Maybe StoreCursor)
    }
    deriving stock (Eq, Show)

{- | The store effect. Reads take a 'Revision' (the resolved consistency snapshot);
writes return a 'ConsistencyToken' for read-your-writes.
-}
data TupleStore m = TupleStore
    { readStartingWithUser :: Revision -> UsersetQuery -> m TuplePage
    , writeTuples :: [Tuple] -> m ConsistencyToken
    , deleteTuples :: [Tuple] -> m ConsistencyToken
    , headRevision :: m Revision
    , optimizedRevision :: m Revision
    }
