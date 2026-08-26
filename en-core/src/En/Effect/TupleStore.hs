{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoFieldSelectors #-}

-- | The tuple-store effect: the storage interface the engine evaluates against.
--
-- Expressed as an effectful effect so a consumer or test can supply an in-memory
-- or PostgreSQL interpreter following shomei's @Shomei.Effect.*@ convention.
module En.Effect.TupleStore
  ( TupleStore (..),
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
    advanceGcHorizon,
    reapDeletedTuples,
    TupleFilter (..),
    SubjectRelationFilter (..),
    RelationshipFilter (..),
    anyRelationshipFilter,
    widenTupleFilter,
    validateRelationshipFilter,
    readRelationships,
    readRelationshipPage,
    countRelationships,
    deleteRelationships,
    ChangeKind (..),
    TupleChange (..),
    ChangePage (..),
    readChanges,
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
  )
where

import Data.Generics.Labels ()
import Data.Int (Int64)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Word (Word64)
import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)
import En.Prelude
import En.Revision (ConsistencyToken, Revision)
import En.Schema (CaveatName (..), ObjectType (..), RelationName (..))
import En.Tuple (ObjectRef (..), Subject (..), Tuple (..))
import GHC.Generics (Generic)
import Relay.Pagination (Connection, CursorError, PageRequest)

newtype StoreCursor = StoreCursor
  { cursorEncoding :: Text
  }
  deriving stock (Eq, Generic, Ord, Show)

newtype TupleRowId = TupleRowId
  { rowIdEncoding :: Text
  }
  deriving stock (Eq, Generic, Ord, Show)

data PageState
  = Exhausted
  | HasMore !StoreCursor
  | Truncated !StoreCursor
  deriving stock (Eq, Ord, Show)

data TupleRow = TupleRow
  { pageKey :: !Int64,
    rowId :: !TupleRowId,
    tuple :: !Tuple,
    createdAt :: !Revision,
    deletedAt :: !(Maybe Revision)
  }
  deriving stock (Eq, Generic, Show)

data TuplePage = TuplePage
  { rows :: ![TupleRow],
    state :: !PageState
  }
  deriving stock (Eq, Generic, Show)

-- | The reverse-lookup query the engine issues against storage: "objects of
-- @queryType@ on @queryRelation@ whose subject is one of @querySubjects@."
-- This single primitive — Zanzibar's @ReadStartingWithUser@ — backs both
-- 'En.Check.check' and 'En.Lookup.lookup'.
data UsersetQuery = UsersetQuery
  { queryType :: !ObjectType,
    queryRelation :: !RelationName,
    querySubjects :: ![Subject],
    queryLimit :: !Int,
    queryCursor :: !(Maybe StoreCursor)
  }
  deriving stock (Eq, Generic, Show)

-- | How a filter constrains a tuple's subject relation.
--
-- Three-valued rather than @Maybe RelationName@ because "any relation" and "no
-- relation" are different questions and a concrete subject and a userset over it
-- can be live at the same time. Were @Nothing@ to mean "any", the exact filter for
-- @space:x#member\@user:alice@ would also match @space:x#member\@user:alice#admin@,
-- and a must-exist precondition would pass while the grant it names was gone. This
-- is the shape SpiceDB's @optionalRelation@ wrapper encodes.
data SubjectRelationFilter
  = -- | Matches concrete subjects, wildcards, and usersets alike.
    AnySubjectRelation
  | -- | Matches only subjects carrying no relation: concrete subjects and wildcards.
    NoSubjectRelation
  | -- | Matches only usersets over exactly this relation.
    ExactSubjectRelation !RelationName
  deriving stock (Eq, Show)

-- | A filter over live tuples.
--
-- A 'Nothing' field matches anything. 'objectType' is mandatory: every field being
-- optional would admit a filter that scans the whole table, and a precondition is
-- evaluated inside a write transaction where a sequential scan is a lock held over
-- the whole relation.
data TupleFilter = TupleFilter
  { objectType :: !ObjectType,
    objectId :: !(Maybe Text),
    relation :: !(Maybe RelationName),
    subjectType :: !(Maybe ObjectType),
    subjectId :: !(Maybe Text),
    subjectRelation :: !SubjectRelationFilter
  }
  deriving stock (Eq, Generic, Show)

-- | A filter over stored tuples, for the operator-facing read and delete-by-filter
-- operations.
--
-- 'TupleFilter' widened in exactly two directions, and no others (see 'widenTupleFilter').
-- 'objectType' is optional, because "every grant naming @user:alice@, whatever it is on" is
-- the offboarding query this filter exists to answer. 'caveatName' is added, because
-- "every grant held under caveat @within_autonomy@" is an audit an operator asks and no
-- other filter can express.
--
-- Not every inhabitant is legal: 'validateRelationshipFilter' enforces the anchoring
-- grammar, and every consumer must construct through it. The rules are not taste. Reads
-- here are snapshot-visible, so they are served by @relation_tuple_object_hist_idx@
-- (leading @object_type@) or @relation_tuple_subject_hist_idx@ (leading @subject_type@),
-- and a filter constraining neither column is a sequential scan of the whole table with no
-- bound but its size. Offering that shape over HTTP is offering a denial of service.
--
-- 'subjectRelation' is a 'SubjectRelationFilter' rather than a @Maybe RelationName@ for the
-- reason that type's own Haddock gives: @Nothing@-means-any cannot say "the subject carries
-- no relation", so it conflates @user:alice@ with @user:alice#admin@ — two grants that can
-- be live at once.
data RelationshipFilter = RelationshipFilter
  { objectType :: !(Maybe ObjectType),
    objectId :: !(Maybe Text),
    relation :: !(Maybe RelationName),
    subjectType :: !(Maybe ObjectType),
    subjectId :: !(Maybe Text),
    subjectRelation :: !SubjectRelationFilter,
    caveatName :: !(Maybe CaveatName)
  }
  deriving stock (Eq, Generic, Show)

-- | The filter constraining nothing. Illegal on its own — 'validateRelationshipFilter'
-- rejects it — and useful only as the base a caller overrides fields on.
anyRelationshipFilter :: RelationshipFilter
anyRelationshipFilter =
  RelationshipFilter
    { objectType = Nothing,
      objectId = Nothing,
      relation = Nothing,
      subjectType = Nothing,
      subjectId = Nothing,
      subjectRelation = AnySubjectRelation,
      caveatName = Nothing
    }

-- | Every 'TupleFilter' is a legal 'RelationshipFilter': it constrains @objectType@, so
-- it is anchored by construction, and it constrains no caveat.
--
-- This is what keeps the two types' matching semantics from drifting. Filter matching is
-- written once against 'RelationshipFilter'; 'TupleFilter' matching is that function
-- after this widening. A field added to one type and forgotten in the other stops
-- compiling here.
widenTupleFilter :: TupleFilter -> RelationshipFilter
widenTupleFilter tupleFilter =
  RelationshipFilter
    { objectType = Just (tupleFilter ^. #objectType),
      objectId = (tupleFilter ^. #objectId),
      relation = (tupleFilter ^. #relation),
      subjectType = (tupleFilter ^. #subjectType),
      subjectId = (tupleFilter ^. #subjectId),
      subjectRelation = (tupleFilter ^. #subjectRelation),
      -- A precondition names a grant's identity, and a caveat is an attribute of the
      -- grant rather than part of that identity, so 'TupleFilter' constrains none.
      caveatName = Nothing
    }

-- | Enforce the anchoring grammar, returning the reason on rejection.
--
-- Three rules, each of which corresponds to an index this store actually has:
--
-- * At least one of @objectType@ or @subjectType@ is present. Neither means no index
--   prefix, which means a sequential scan.
--
-- * @objectId@ requires @objectType@. @relation_tuple_object_hist_idx@ leads with
--   @object_type@; an @objectId@ without it is a residual predicate over the whole table.
--
-- * @subjectId@ and a non-'AnySubjectRelation' @subjectRelation@ require @subjectType@,
--   for the same reason against @relation_tuple_subject_hist_idx@. (This is also SpiceDB's
--   rule: its @SubjectFilter.optionalSubjectId@ is only meaningful under a @subjectType@.)
--
-- @relation@ and @caveatName@ are deliberately unrestricted. Neither leads any index, so
-- both are always residual predicates evaluated after an index scan the other fields
-- anchored — a documented cost, paid on a row set the grammar has already bounded, not an
-- unbounded one. Auditing "every grant on @user:alice@ under caveat @within_autonomy@" is a
-- real question, and it is subject-anchored.
validateRelationshipFilter :: RelationshipFilter -> Either Text RelationshipFilter
validateRelationshipFilter relationshipFilter
  | unanchored =
      Left "filter must constrain objectType or subjectType"
  | danglingObjectId =
      Left "filter objectId requires objectType"
  | danglingSubjectId =
      Left "filter subjectId requires subjectType"
  | danglingSubjectRelation =
      Left "filter subjectRelation requires subjectType"
  | otherwise =
      Right relationshipFilter
  where
    hasObjectType = isJust (relationshipFilter ^. #objectType)
    hasSubjectType = isJust (relationshipFilter ^. #subjectType)

    unanchored = not hasObjectType && not hasSubjectType
    danglingObjectId = isJust (relationshipFilter ^. #objectId) && not hasObjectType
    danglingSubjectId = isJust (relationshipFilter ^. #subjectId) && not hasSubjectType
    danglingSubjectRelation =
      case (relationshipFilter ^. #subjectRelation) of
        AnySubjectRelation -> False
        _ -> not hasSubjectType

-- | What happened to a tuple's membership of the live set across a revision window.
--
-- Two kinds, not three. A tuple whose caveat was rewritten is a 'ChangeDelete' of the old
-- row and a 'ChangeTouch' of the new one, because the store retires and re-inserts rather
-- than updating in place — and that is the honest report: a consumer holding a decision
-- derived from the old caveat must discard it.
data ChangeKind
  = -- | The tuple became live: it is in the live set at the window's end and was not at its start.
    ChangeTouch
  | -- | The tuple stopped being live: it was in the live set at the window's start and is not at its end.
    ChangeDelete
  deriving stock (Eq, Ord, Show)

-- | One tuple's change, carrying the storage row it happened to.
--
-- 'rowId' is the row's identity, not the tuple's: a grant retired and rewritten under a new
-- caveat produces two rows and therefore two 'rowId's. It is here because it is the key the
-- window pages on, so a consumer that persists it can reason about where in a drain it is.
data TupleChange = TupleChange
  { kind :: !ChangeKind,
    tuple :: !Tuple,
    rowId :: !TupleRowId
  }
  deriving stock (Eq, Generic, Show)

-- | One page of a revision window's changes.
--
-- The changes are the /set difference/ of the live tuple set between two snapshots, so they
-- carry no order among themselves; 'rowId' order is a pagination key, not an event order.
-- Transaction ids are assigned at transaction start and visibility flips at commit, and
-- those two orders need not agree, so no faithful total order of events exists to report.
data ChangePage = ChangePage
  { changes :: ![TupleChange],
    state :: !PageState
  }
  deriving stock (Eq, Generic, Show)

-- | A fact the write transaction re-verifies before applying any change.
--
-- This is Zanzibar's /lock tuple/: a writer names the facts its decision depended
-- on, and the store refuses the write if they no longer hold. Without it, two
-- administrators reading the same state and writing conflicting conclusions both
-- succeed, and the system lands in a state neither intended.
data Precondition
  = TupleMustExist !TupleFilter
  | TupleMustNotExist !TupleFilter
  deriving stock (Eq, Show)

-- | One atomic write request.
--
-- Preconditions are checked first, so a rejected request provably performed no
-- work. Deletes are applied before writes, which makes "replace the grant on this
-- key" a single natural request; the reverse order would have the delete retire the
-- write that just landed.
data TupleWriteRequest = TupleWriteRequest
  { preconditions :: ![Precondition],
    writes :: ![Tuple],
    deletes :: ![Tuple]
  }
  deriving stock (Eq, Generic, Show)

-- | The filter matching exactly one tuple's identity, and nothing else.
--
-- The identity is (object, relation, subject) — the same key
-- @relation_tuple_live_unique@ enforces — so this is the filter to use for
-- "this exact grant must (not) exist".
exactTupleFilter :: Tuple -> TupleFilter
exactTupleFilter tuple =
  TupleFilter
    { objectType = (tuple ^. #object . #objectType),
      objectId = Just (tuple ^. #object . #objectId),
      relation = Just (tuple ^. #relation),
      subjectType = Just (subjectObject ^. #objectType),
      subjectId = Just (subjectObject ^. #objectId),
      subjectRelation = subjectRelationFilter
    }
  where
    (subjectObject, subjectRelationFilter) =
      case (tuple ^. #subject) of
        SubjectId object -> (object, NoSubjectRelation)
        SubjectSet object relationName -> (object, ExactSubjectRelation relationName)
        SubjectWildcard objectType -> (ObjectRef {objectType, objectId = "*"}, NoSubjectRelation)

-- | Render a precondition for an error message, e.g.
-- @must-exist: space:project-x#member\@user:alice@. An unconstrained field prints
-- as @*@; an unconstrained subject relation prints as a trailing @#*@, which
-- distinguishes it from a subject required to carry none.
renderPrecondition :: Precondition -> Text
renderPrecondition = \case
  TupleMustExist tupleFilter -> "must-exist: " <> renderFilter tupleFilter
  TupleMustNotExist tupleFilter -> "must-not-exist: " <> renderFilter tupleFilter
  where
    renderFilter tupleFilter =
      unObjectType (tupleFilter ^. #objectType)
        <> ":"
        <> anyOr (tupleFilter ^. #objectId)
        <> "#"
        <> anyOr (unRelationName <$> (tupleFilter ^. #relation))
        <> "@"
        <> anyOr (unObjectType <$> (tupleFilter ^. #subjectType))
        <> ":"
        <> anyOr (tupleFilter ^. #subjectId)
        <> renderSubjectRelation (tupleFilter ^. #subjectRelation)

    renderSubjectRelation = \case
      AnySubjectRelation -> "#*"
      NoSubjectRelation -> ""
      ExactSubjectRelation relationName -> "#" <> unRelationName relationName

    anyOr = fromMaybe "*"

    unObjectType (ObjectType text) = text
    unRelationName (RelationName text) = text

-- | The store effect. Reads take a 'Revision' (the resolved consistency snapshot);
-- writes return a 'ConsistencyToken' for read-your-writes.
data TupleStore :: Effect where
  ReadObjectRelation :: Revision -> ObjectRef -> RelationName -> Int -> Maybe StoreCursor -> TupleStore m TuplePage
  ReadStartingWithUser :: Revision -> UsersetQuery -> TupleStore m TuplePage
  -- | Every tuple live at @revision@, ordered by internal row id and
  --     keyset-paginated: the whole graph, page by page.
  --
  --     The engine never issues this — a check or a lookup that scanned the store
  --     would be a bug — but bulk export does, and so does any consumer migrating
  --     the graph out. Anchoring every page to one caller-held 'Revision' makes the
  --     drain a consistent snapshot: writers may proceed throughout, and none of
  --     their rows appear.
  --
  --     Ordering is by row id rather than by any tuple field so the scan is a
  --     primary-key range scan needing no index of its own.
  ReadAllTuples :: Revision -> Int -> Maybe StoreCursor -> TupleStore m TuplePage
  -- | Point-membership probe: the live tuples at @revision@ on
  --     @object#relation@ whose subject is one of the given candidates.
  --
  --     Callers pass a small candidate set (typically the concrete subject plus
  --     its type wildcard), so the result needs no pagination. Several rows can
  --     match one candidate when the same grant exists under different caveat
  --     names, which is why this returns a list rather than a @Maybe@.
  ProbeTuples :: Revision -> ObjectRef -> RelationName -> [Subject] -> TupleStore m [TupleRow]
  -- | The one write operation: check preconditions, apply deletes, apply
  --     writes — atomically, minting a single token.
  --
  --     Plain writes and deletes are degenerate requests (see 'writeTuples' and
  --     'deleteTuples'), so every interpreter implements the transactional
  --     semantics exactly once. A failing precondition raises
  --     'En.Error.WritePreconditionFailed' and mints no token.
  ApplyTupleWrites :: TupleWriteRequest -> TupleStore m ConsistencyToken
  -- | The tuples live at @revision@ matching a validated 'RelationshipFilter',
  --     ordered by internal row id and keyset-paginated.
  --
  --     The engine never issues this either. It answers the operator's question — "what
  --     grants exist for @user:alice@?" — that neither 'ReadObjectRelation' (wrong
  --     direction) nor 'ReadStartingWithUser' (needs an object type /and/ relation) can
  --     put. Anchoring every page to one caller-held 'Revision' makes a paged listing a
  --     consistent snapshot, exactly as it does for 'ReadAllTuples'.
  ReadRelationships :: Revision -> RelationshipFilter -> Int -> Maybe StoreCursor -> TupleStore m TuplePage
  -- | Relay keyset page over the relationship listing. The consistency token is
  --     included in every minted cursor so continuation pages reuse the exact
  --     snapshot rather than re-resolving the request body.
  ReadRelationshipPage :: Revision -> ConsistencyToken -> RelationshipFilter -> PageRequest -> TupleStore m (Either CursorError (Connection TupleRow))
  -- | How many tuples live at @revision@ match the filter.
  --
  --     The dry-run primitive of 'DeleteRelationships'. It is a separate operation rather
  --     than a paged read the caller counts, because "how many grants would this revoke?"
  --     must not itself be bounded by a page.
  CountRelationships :: Revision -> RelationshipFilter -> TupleStore m Int64
  -- | Soft-delete every /currently live/ tuple matching the filter, atomically,
  --     returning how many were retired and the token that sees the retirement.
  --
  --     Takes no 'Revision': like 'ApplyTupleWrites', it acts on the live state inside its
  --     own transaction. Matching and deleting are one operation, and not a read the caller
  --     follows with a delete, because two transactions cannot agree on what they saw: a
  --     grant written between them would be counted and not deleted, or deleted and not
  --     counted. The returned count and token therefore describe the same set of rows.
  DeleteRelationships :: RelationshipFilter -> TupleStore m (Int64, ConsistencyToken)
  -- | Every tuple whose live-set membership changed between the two revisions,
  --     optionally narrowed by a filter, ordered by row id and keyset-paginated.
  --
  --     The changelog the watch feed is built from. It needs no new table: a store that
  --     soft-deletes already records when each row entered and left the live set, so
  --     "what changed between these two snapshots" is a question about the tuples
  --     themselves. The revisions are a half-open window @(start, end]@, and a row whose
  --     creation /and/ deletion both became visible inside it contributes nothing: the
  --     live set is the same at both ends, and reporting a phantom pair would force every
  --     consumer to order events the store cannot order.
  ReadChanges :: Revision -> Revision -> Maybe RelationshipFilter -> Int -> Maybe StoreCursor -> TupleStore m ChangePage
  HeadRevision :: TupleStore m Revision
  OptimizedRevision :: TupleStore m Revision
  OldestRetainedXid :: TupleStore m Word64
  -- | Advance the durable garbage-collection horizon to
  --     @GREATEST(mark, freshly computed)@ and return the new value. Distinct from
  --     'OldestRetainedXid', which only /reads/ the clamped horizon: this is the
  --     write the reaper issues to publish its horizon before it destroys anything,
  --     so validation can never fall below a horizon reaping already acted on. See
  --     @docs/plans/60@ Milestone 4.
  AdvanceGcHorizon :: TupleStore m Word64
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

-- | A page of tuples matching the filter, live at the revision.
--
-- The filter must have come from 'validateRelationshipFilter'. Nothing in the type
-- enforces that, and no interpreter re-checks it: the grammar is a bound on cost, so it
-- belongs at the edge where a caller's filter arrives, not on every internal read.
readRelationships :: (TupleStore :> es) => Revision -> RelationshipFilter -> Int -> Maybe StoreCursor -> Eff es TuplePage
readRelationships revision relationshipFilter limit cursor =
  send (ReadRelationships revision relationshipFilter limit cursor)

readRelationshipPage ::
  (TupleStore :> es) =>
  Revision ->
  ConsistencyToken ->
  RelationshipFilter ->
  PageRequest ->
  Eff es (Either CursorError (Connection TupleRow))
readRelationshipPage revision token relationshipFilter pageRequest =
  send (ReadRelationshipPage revision token relationshipFilter pageRequest)

-- | How many tuples live at the revision match the filter. See 'readRelationships'.
countRelationships :: (TupleStore :> es) => Revision -> RelationshipFilter -> Eff es Int64
countRelationships revision relationshipFilter =
  send (CountRelationships revision relationshipFilter)

-- | Retire every live tuple matching the filter. See 'readRelationships'.
deleteRelationships :: (TupleStore :> es) => RelationshipFilter -> Eff es (Int64, ConsistencyToken)
deleteRelationships =
  send . DeleteRelationships

-- | A page of the changes between two revisions. See 'ReadChanges'.
--
-- The filter, when present, must have come from 'validateRelationshipFilter', for the reason
-- 'readRelationships' gives.
readChanges :: (TupleStore :> es) => Revision -> Revision -> Maybe RelationshipFilter -> Int -> Maybe StoreCursor -> Eff es ChangePage
readChanges start end relationshipFilter limit cursor =
  send (ReadChanges start end relationshipFilter limit cursor)

-- | An unguarded write: 'applyTupleWrites' with no preconditions and no deletes.
writeTuples :: (TupleStore :> es) => [Tuple] -> Eff es ConsistencyToken
writeTuples tuples =
  applyTupleWrites TupleWriteRequest {preconditions = [], writes = tuples, deletes = []}

-- | An unguarded delete: 'applyTupleWrites' with no preconditions and no writes.
deleteTuples :: (TupleStore :> es) => [Tuple] -> Eff es ConsistencyToken
deleteTuples tuples =
  applyTupleWrites TupleWriteRequest {preconditions = [], writes = [], deletes = tuples}

headRevision :: (TupleStore :> es) => Eff es Revision
headRevision =
  send HeadRevision

optimizedRevision :: (TupleStore :> es) => Eff es Revision
optimizedRevision =
  send OptimizedRevision

oldestRetainedXid :: (TupleStore :> es) => Eff es Word64
oldestRetainedXid =
  send OldestRetainedXid

-- | Advance the durable garbage-collection horizon and return the new high-water
-- mark. The reaper calls this to fix the horizon it will reap and prune at; token
-- validation calls 'oldestRetainedXid', which reads the same durable mark. See
-- 'AdvanceGcHorizon'.
advanceGcHorizon :: (TupleStore :> es) => Eff es Word64
advanceGcHorizon =
  send AdvanceGcHorizon

reapDeletedTuples :: (TupleStore :> es) => Word64 -> Eff es Int64
reapDeletedTuples =
  send . ReapDeletedTuples
