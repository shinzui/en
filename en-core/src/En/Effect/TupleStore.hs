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
    readAllTuples,
    probeTuples,
    applyTupleWrites,
    writeTuples,
    deleteTuples,
    headRevision,
    optimizedRevision,
    oldestRetainedXid,
    reapDeletedTuples,
    TupleFilter (..),
    SubjectRelationFilter (..),
    Precondition (..),
    TupleWriteRequest (..),
    exactTupleFilter,
    renderPrecondition,
    UsersetQuery (..),
    StoreCursor (..),
    TupleRowId (..),
    TupleRow (..),
    TuplePage (..),
    PageState (..),
) where

import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Word (Word64)
import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)

import En.Revision (ConsistencyToken, Revision)
import En.Schema (ObjectType (..), RelationName (..))
import En.Tuple (ObjectRef (..), Subject (..), Tuple (..))

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

{- | How a filter constrains a tuple's subject relation.

Three-valued rather than @Maybe RelationName@ because "any relation" and "no
relation" are different questions and a concrete subject and a userset over it
can be live at the same time. Were @Nothing@ to mean "any", the exact filter for
@space:x#member\@user:alice@ would also match @space:x#member\@user:alice#admin@,
and a must-exist precondition would pass while the grant it names was gone. This
is the shape SpiceDB's @optionalRelation@ wrapper encodes.
-}
data SubjectRelationFilter
    = -- | Matches concrete subjects, wildcards, and usersets alike.
      AnySubjectRelation
    | -- | Matches only subjects carrying no relation: concrete subjects and wildcards.
      NoSubjectRelation
    | -- | Matches only usersets over exactly this relation.
      ExactSubjectRelation !RelationName
    deriving stock (Eq, Show)

{- | A filter over live tuples.

A 'Nothing' field matches anything. 'objectType' is mandatory: every field being
optional would admit a filter that scans the whole table, and a precondition is
evaluated inside a write transaction where a sequential scan is a lock held over
the whole relation.
-}
data TupleFilter = TupleFilter
    { objectType :: !ObjectType
    , objectId :: !(Maybe Text)
    , relation :: !(Maybe RelationName)
    , subjectType :: !(Maybe ObjectType)
    , subjectId :: !(Maybe Text)
    , subjectRelation :: !SubjectRelationFilter
    }
    deriving stock (Eq, Show)

{- | A fact the write transaction re-verifies before applying any change.

This is Zanzibar's /lock tuple/: a writer names the facts its decision depended
on, and the store refuses the write if they no longer hold. Without it, two
administrators reading the same state and writing conflicting conclusions both
succeed, and the system lands in a state neither intended.
-}
data Precondition
    = TupleMustExist !TupleFilter
    | TupleMustNotExist !TupleFilter
    deriving stock (Eq, Show)

{- | One atomic write request.

Preconditions are checked first, so a rejected request provably performed no
work. Deletes are applied before writes, which makes "replace the grant on this
key" a single natural request; the reverse order would have the delete retire the
write that just landed.
-}
data TupleWriteRequest = TupleWriteRequest
    { preconditions :: ![Precondition]
    , writes :: ![Tuple]
    , deletes :: ![Tuple]
    }
    deriving stock (Eq, Show)

{- | The filter matching exactly one tuple's identity, and nothing else.

The identity is (object, relation, subject) — the same key
@relation_tuple_live_unique@ enforces — so this is the filter to use for
"this exact grant must (not) exist".
-}
exactTupleFilter :: Tuple -> TupleFilter
exactTupleFilter tuple =
    TupleFilter
        { objectType = tuple.object.objectType
        , objectId = Just tuple.object.objectId
        , relation = Just tuple.relation
        , subjectType = Just subjectObject.objectType
        , subjectId = Just subjectObject.objectId
        , subjectRelation = subjectRelationFilter
        }
  where
    (subjectObject, subjectRelationFilter) =
        case tuple.subject of
            SubjectId object -> (object, NoSubjectRelation)
            SubjectSet object relationName -> (object, ExactSubjectRelation relationName)
            SubjectWildcard objectType -> (ObjectRef{objectType, objectId = "*"}, NoSubjectRelation)

{- | Render a precondition for an error message, e.g.
@must-exist: space:project-x#member\@user:alice@. An unconstrained field prints
as @*@; an unconstrained subject relation prints as a trailing @#*@, which
distinguishes it from a subject required to carry none.
-}
renderPrecondition :: Precondition -> Text
renderPrecondition = \case
    TupleMustExist tupleFilter -> "must-exist: " <> renderFilter tupleFilter
    TupleMustNotExist tupleFilter -> "must-not-exist: " <> renderFilter tupleFilter
  where
    renderFilter tupleFilter =
        unObjectType tupleFilter.objectType
            <> ":"
            <> anyOr tupleFilter.objectId
            <> "#"
            <> anyOr (unRelationName <$> tupleFilter.relation)
            <> "@"
            <> anyOr (unObjectType <$> tupleFilter.subjectType)
            <> ":"
            <> anyOr tupleFilter.subjectId
            <> renderSubjectRelation tupleFilter.subjectRelation

    renderSubjectRelation = \case
        AnySubjectRelation -> "#*"
        NoSubjectRelation -> ""
        ExactSubjectRelation relationName -> "#" <> unRelationName relationName

    anyOr = fromMaybe "*"

    unObjectType (ObjectType text) = text
    unRelationName (RelationName text) = text

{- | The store effect. Reads take a 'Revision' (the resolved consistency snapshot);
writes return a 'ConsistencyToken' for read-your-writes.
-}
data TupleStore :: Effect where
    ReadObjectRelation :: Revision -> ObjectRef -> RelationName -> Int -> Maybe StoreCursor -> TupleStore m TuplePage
    ReadStartingWithUser :: Revision -> UsersetQuery -> TupleStore m TuplePage
    {- | Every tuple live at @revision@, ordered by internal row id and
    keyset-paginated: the whole graph, page by page.

    The engine never issues this — a check or a lookup that scanned the store
    would be a bug — but bulk export does, and so does any consumer migrating
    the graph out. Anchoring every page to one caller-held 'Revision' makes the
    drain a consistent snapshot: writers may proceed throughout, and none of
    their rows appear.

    Ordering is by row id rather than by any tuple field so the scan is a
    primary-key range scan needing no index of its own.
    -}
    ReadAllTuples :: Revision -> Int -> Maybe StoreCursor -> TupleStore m TuplePage
    {- | Point-membership probe: the live tuples at @revision@ on
    @object#relation@ whose subject is one of the given candidates.

    Callers pass a small candidate set (typically the concrete subject plus
    its type wildcard), so the result needs no pagination. Several rows can
    match one candidate when the same grant exists under different caveat
    names, which is why this returns a list rather than a @Maybe@.
    -}
    ProbeTuples :: Revision -> ObjectRef -> RelationName -> [Subject] -> TupleStore m [TupleRow]
    {- | The one write operation: check preconditions, apply deletes, apply
    writes — atomically, minting a single token.

    Plain writes and deletes are degenerate requests (see 'writeTuples' and
    'deleteTuples'), so every interpreter implements the transactional
    semantics exactly once. A failing precondition raises
    'En.Error.WritePreconditionFailed' and mints no token.
    -}
    ApplyTupleWrites :: TupleWriteRequest -> TupleStore m ConsistencyToken
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

readAllTuples :: (TupleStore :> es) => Revision -> Int -> Maybe StoreCursor -> Eff es TuplePage
readAllTuples revision limit cursor =
    send (ReadAllTuples revision limit cursor)

probeTuples :: (TupleStore :> es) => Revision -> ObjectRef -> RelationName -> [Subject] -> Eff es [TupleRow]
probeTuples revision object relation subjects =
    send (ProbeTuples revision object relation subjects)

applyTupleWrites :: (TupleStore :> es) => TupleWriteRequest -> Eff es ConsistencyToken
applyTupleWrites =
    send . ApplyTupleWrites

-- | An unguarded write: 'applyTupleWrites' with no preconditions and no deletes.
writeTuples :: (TupleStore :> es) => [Tuple] -> Eff es ConsistencyToken
writeTuples tuples =
    applyTupleWrites TupleWriteRequest{preconditions = [], writes = tuples, deletes = []}

-- | An unguarded delete: 'applyTupleWrites' with no preconditions and no writes.
deleteTuples :: (TupleStore :> es) => [Tuple] -> Eff es ConsistencyToken
deleteTuples tuples =
    applyTupleWrites TupleWriteRequest{preconditions = [], writes = [], deletes = tuples}

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
