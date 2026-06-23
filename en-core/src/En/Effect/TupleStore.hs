{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoFieldSelectors #-}

{- | The tuple-store effect: the storage interface the engine evaluates against.

Expressed as an effectful effect so a consumer or test can supply an in-memory
or PostgreSQL interpreter following shomei's @Shomei.Effect.*@ convention.
-}
module En.Effect.TupleStore (
    TupleStore (..),
    readObjectRelation,
    readStartingWithUser,
    writeTuples,
    deleteTuples,
    headRevision,
    optimizedRevision,
    oldestRetainedXid,
    reapDeletedTuples,
    UsersetQuery (..),
    StoreCursor (..),
    TupleRowId (..),
    TupleRow (..),
    TuplePage (..),
    PageState (..),
) where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Word (Word64)
import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)

import En.Revision (ConsistencyToken, Revision)
import En.Schema (ObjectType, RelationName)
import En.Tuple (ObjectRef, Subject, Tuple)

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
data TupleStore :: Effect where
    ReadObjectRelation :: Revision -> ObjectRef -> RelationName -> Int -> Maybe StoreCursor -> TupleStore m TuplePage
    ReadStartingWithUser :: Revision -> UsersetQuery -> TupleStore m TuplePage
    WriteTuples :: [Tuple] -> TupleStore m ConsistencyToken
    DeleteTuples :: [Tuple] -> TupleStore m ConsistencyToken
    HeadRevision :: TupleStore m Revision
    OptimizedRevision :: TupleStore m Revision
    OldestRetainedXid :: TupleStore m Word64
    ReapDeletedTuples :: Word64 -> TupleStore m Int64

type instance DispatchOf TupleStore = Dynamic

readObjectRelation :: (TupleStore :> es) => Revision -> ObjectRef -> RelationName -> Int -> Maybe StoreCursor -> Eff es TuplePage
readObjectRelation revision object relation limit cursor =
    send (ReadObjectRelation revision object relation limit cursor)

readStartingWithUser :: (TupleStore :> es) => Revision -> UsersetQuery -> Eff es TuplePage
readStartingWithUser revision query =
    send (ReadStartingWithUser revision query)

writeTuples :: (TupleStore :> es) => [Tuple] -> Eff es ConsistencyToken
writeTuples =
    send . WriteTuples

deleteTuples :: (TupleStore :> es) => [Tuple] -> Eff es ConsistencyToken
deleteTuples =
    send . DeleteTuples

headRevision :: (TupleStore :> es) => Eff es Revision
headRevision =
    send HeadRevision

optimizedRevision :: (TupleStore :> es) => Eff es Revision
optimizedRevision =
    send OptimizedRevision

oldestRetainedXid :: (TupleStore :> es) => Eff es Word64
oldestRetainedXid =
    send OldestRetainedXid

reapDeletedTuples :: (TupleStore :> es) => Word64 -> Eff es Int64
reapDeletedTuples =
    send . ReapDeletedTuples
