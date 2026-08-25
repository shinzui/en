{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- | A mutable, historical tuple store for tests and databaseless demos.
--
-- This is /not a production store/. Its state disappears with the process, separate
-- application instances cannot agree on it, and its total-order counter only models
-- PostgreSQL's @pg_snapshot@ revision semantics inside one process. Use
-- @En.Postgres.TupleStore@ for production deployments.
--
-- Unlike the pure fixed-fixture interpreter in "En.Conformance.Kikan", this module
-- retains row history, so writes and deletes are visible at honest exact snapshots.
module En.Store.InMemory
  ( InMemoryWorld,
    newInMemoryWorld,
    runTupleStoreInMemory,
    runConsistencyStoreInMemory,
    runInMemoryStores,
  )
where

import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.List (find)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Unique (hashUnique, newUnique)
import Data.Word (Word64)
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, throwError)
import En.Effect.ConsistencyStore
  ( ConsistencyStore (..),
    ResolvedConsistency (..),
    TokenMetadata (..),
  )
import En.Effect.TupleStore
  ( ChangeKind (..),
    ChangePage (..),
    PageState (..),
    Precondition (..),
    RelationshipFilter (..),
    StoreCursor (..),
    SubjectRelationFilter (..),
    TupleChange (..),
    TupleFilter (..),
    TuplePage (..),
    TupleRow (..),
    TupleRowId (..),
    TupleStore (..),
    TupleWriteRequest (..),
    UsersetQuery (..),
    renderPrecondition,
    widenTupleFilter,
  )
import En.Error (EnError (..))
import En.Revision
  ( Consistency (..),
    ConsistencyToken (..),
    DatastoreId (..),
    Revision (..),
    SchemaHash (..),
  )
import En.Schema (CaveatName, RelationName)
import En.Tuple (ObjectRef (..), Subject (..), Tuple (..), TupleCaveat (..))

data InMemoryRow = InMemoryRow
  { memoryRowId :: !Word64,
    memoryTuple :: !Tuple,
    memoryCreatedAt :: !Word64,
    memoryDeletedAt :: !(Maybe Word64)
  }

data InMemoryState = InMemoryState
  { memoryRows :: !(Map Word64 InMemoryRow),
    memoryHead :: !Word64,
    memoryNextRowId :: !Word64,
    memoryGcHorizon :: !Word64
  }

-- | One isolated in-memory datastore. The representation is intentionally hidden so
-- callers cannot violate revision, row-id, or garbage-collection invariants.
data InMemoryWorld = InMemoryWorld
  { memoryWorldId :: !Text,
    memoryState :: !(IORef InMemoryState)
  }

-- | Allocate an empty, isolated store.
newInMemoryWorld :: IO InMemoryWorld
newInMemoryWorld = do
  unique <- newUnique
  memoryState <-
    newIORef
      InMemoryState
        { memoryRows = Map.empty,
          memoryHead = 0,
          memoryNextRowId = 1,
          memoryGcHorizon = 0
        }
  pure
    InMemoryWorld
      { memoryWorldId = showText (hashUnique unique),
        memoryState
      }

-- | Interpret the complete current 'TupleStore' contract over one mutable world.
--
-- Mutating requests use one 'atomicModifyIORef'' so concurrent test threads see the
-- whole request or none of it.
runTupleStoreInMemory ::
  (IOE :> es, Error EnError :> es) =>
  InMemoryWorld ->
  Eff (TupleStore : es) a ->
  Eff es a
runTupleStoreInMemory world =
  interpret_ \case
    ReadObjectRelation revision object relation limit cursor -> do
      revisionNumber <- requireRevision world revision
      cursorId <- requireCursor cursor
      state <- liftIO (readIORef world.memoryState)
      pure $
        tuplePage
          world
          limit
          cursorId
          [ row
          | row <- visibleRows revisionNumber state,
            row.memoryTuple.object == object,
            row.memoryTuple.relation == relation
          ]
    ReadStartingWithUser revision query -> do
      revisionNumber <- requireRevision world revision
      cursorId <- requireCursor query.queryCursor
      state <- liftIO (readIORef world.memoryState)
      pure $
        tuplePage
          world
          query.queryLimit
          cursorId
          [ row
          | row <- visibleRows revisionNumber state,
            row.memoryTuple.object.objectType == query.queryType,
            row.memoryTuple.relation == query.queryRelation,
            row.memoryTuple.subject `elem` query.querySubjects
          ]
    ReadAllTuples revision limit cursor -> do
      revisionNumber <- requireRevision world revision
      cursorId <- requireCursor cursor
      state <- liftIO (readIORef world.memoryState)
      pure (tuplePage world limit cursorId (visibleRows revisionNumber state))
    ProbeTuples revision object relation subjects -> do
      revisionNumber <- requireRevision world revision
      state <- liftIO (readIORef world.memoryState)
      pure
        [ toTupleRow world row
        | row <- visibleRows revisionNumber state,
          row.memoryTuple.object == object,
          row.memoryTuple.relation == relation,
          row.memoryTuple.subject `elem` subjects
        ]
    ApplyTupleWrites request -> do
      outcome <-
        liftIO $
          atomicModifyIORef' world.memoryState \state ->
            case applyWriteRequest request state of
              Left err -> (state, Left err)
              Right (nextState, revisionNumber) ->
                (nextState, Right (tokenAt world revisionNumber))
      either throwError pure outcome
    ReadRelationships revision relationshipFilter limit cursor -> do
      revisionNumber <- requireRevision world revision
      cursorId <- requireCursor cursor
      state <- liftIO (readIORef world.memoryState)
      pure $
        tuplePage
          world
          limit
          cursorId
          ( filter
              (matchesRelationshipFilter relationshipFilter . (.memoryTuple))
              (visibleRows revisionNumber state)
          )
    CountRelationships revision relationshipFilter -> do
      revisionNumber <- requireRevision world revision
      state <- liftIO (readIORef world.memoryState)
      pure $
        fromIntegral $
          length $
            filter
              (matchesRelationshipFilter relationshipFilter . (.memoryTuple))
              (visibleRows revisionNumber state)
    DeleteRelationships relationshipFilter ->
      liftIO $
        atomicModifyIORef' world.memoryState \state ->
          let revisionNumber = state.memoryHead + 1
              (retiredCount, rows') =
                Map.mapAccum
                  (retireMatching revisionNumber relationshipFilter)
                  0
                  state.memoryRows
              nextState =
                state
                  { memoryRows = rows',
                    memoryHead = revisionNumber
                  }
           in (nextState, (retiredCount, tokenAt world revisionNumber))
    ReadChanges start end relationshipFilter limit cursor -> do
      startNumber <- requireRevision world start
      endNumber <- requireRevision world end
      if startNumber > endNumber
        then throwError (StoreError "in-memory change window starts after it ends")
        else do
          cursorId <- requireCursor cursor
          state <- liftIO (readIORef world.memoryState)
          pure
            ( changePage
                limit
                cursorId
                [ (row.memoryRowId, change)
                | row <- Map.elems state.memoryRows,
                  maybe True (`matchesRelationshipFilter` row.memoryTuple) relationshipFilter,
                  change <- classifyChange startNumber endNumber row
                ]
            )
    HeadRevision -> do
      state <- liftIO (readIORef world.memoryState)
      pure (revisionAt world state.memoryHead)
    OptimizedRevision -> do
      -- There is no replica lag or quantization in one in-memory world.
      state <- liftIO (readIORef world.memoryState)
      pure (revisionAt world state.memoryHead)
    OldestRetainedXid ->
      (.memoryGcHorizon) <$> liftIO (readIORef world.memoryState)
    AdvanceGcHorizon ->
      liftIO $
        atomicModifyIORef' world.memoryState \state ->
          let horizon = max state.memoryGcHorizon state.memoryHead
           in (state {memoryGcHorizon = horizon}, horizon)
    ReapDeletedTuples horizon ->
      liftIO $
        atomicModifyIORef' world.memoryState \state ->
          let (reaped, retained) =
                Map.partition
                  (maybe False (< horizon) . (.memoryDeletedAt))
                  state.memoryRows
              nextState =
                state
                  { memoryRows = retained,
                    memoryGcHorizon = max state.memoryGcHorizon horizon
                  }
           in (nextState, fromIntegral (Map.size reaped))

-- | Interpret consistency tokens and requests against the same mutable world.
runConsistencyStoreInMemory ::
  (IOE :> es, Error EnError :> es) =>
  InMemoryWorld ->
  Eff (ConsistencyStore : es) a ->
  Eff es a
runConsistencyStoreInMemory world =
  interpret_ \case
    DecodeToken token ->
      either throwError pure (decodeTokenMetadata token)
    ValidateToken metadata ->
      validateMetadata world metadata
    ResolveConsistency consistency ->
      resolveInMemoryConsistency world consistency
    MintToken revision -> do
      _ <- requireRevision world revision
      pure (ConsistencyToken revision.revisionEncoding)

-- | Install both store effects over one world.
runInMemoryStores ::
  (IOE :> es, Error EnError :> es) =>
  InMemoryWorld ->
  Eff (ConsistencyStore : TupleStore : es) a ->
  Eff es a
runInMemoryStores world =
  runTupleStoreInMemory world . runConsistencyStoreInMemory world

applyWriteRequest ::
  TupleWriteRequest ->
  InMemoryState ->
  Either EnError (InMemoryState, Word64)
applyWriteRequest request state =
  case find (not . preconditionHolds liveTuples) request.preconditions of
    Just failed ->
      Left (WritePreconditionFailed (renderPrecondition failed))
    Nothing ->
      let revisionNumber = state.memoryHead + 1
          deletedRows =
            foldl'
              (flip (retireTupleKey revisionNumber))
              state.memoryRows
              request.deletes
          deduplicatedWrites = dedupeWrites request.writes
          (rows', nextRowId') =
            foldl'
              (touchTuple revisionNumber)
              (deletedRows, state.memoryNextRowId)
              deduplicatedWrites
       in Right
            ( state
                { memoryRows = rows',
                  memoryHead = revisionNumber,
                  memoryNextRowId = nextRowId'
                },
              revisionNumber
            )
  where
    liveTuples =
      [ row.memoryTuple
      | row <- Map.elems state.memoryRows,
        isNothing row.memoryDeletedAt
      ]

touchTuple ::
  Word64 ->
  (Map Word64 InMemoryRow, Word64) ->
  Tuple ->
  (Map Word64 InMemoryRow, Word64)
touchTuple revisionNumber (rows, nextRowId) tuple
  | any
      (\row -> isNothing row.memoryDeletedAt && row.memoryTuple == tuple)
      (Map.elems rows) =
      (rows, nextRowId)
  | otherwise =
      let retired = retireTupleKey revisionNumber tuple rows
          row =
            InMemoryRow
              { memoryRowId = nextRowId,
                memoryTuple = tuple,
                memoryCreatedAt = revisionNumber,
                memoryDeletedAt = Nothing
              }
       in (Map.insert nextRowId row retired, nextRowId + 1)

retireTupleKey :: Word64 -> Tuple -> Map Word64 InMemoryRow -> Map Word64 InMemoryRow
retireTupleKey revisionNumber tuple =
  Map.map \row ->
    if isNothing row.memoryDeletedAt && tupleKey row.memoryTuple == tupleKey tuple
      then row {memoryDeletedAt = Just revisionNumber}
      else row

retireMatching ::
  Word64 ->
  RelationshipFilter ->
  Int64 ->
  InMemoryRow ->
  (Int64, InMemoryRow)
retireMatching revisionNumber relationshipFilter count row
  | isNothing row.memoryDeletedAt
      && matchesRelationshipFilter relationshipFilter row.memoryTuple =
      (count + 1, row {memoryDeletedAt = Just revisionNumber})
  | otherwise =
      (count, row)

dedupeWrites :: [Tuple] -> [Tuple]
dedupeWrites tuples =
  [ tuple
  | (index, tuple) <- indexed,
    Map.lookup (tupleKey tuple) lastIndex == Just index
  ]
  where
    indexed = zip [0 :: Int ..] tuples
    lastIndex =
      Map.fromList
        [ (tupleKey tuple, index)
        | (index, tuple) <- indexed
        ]

tupleKey :: Tuple -> (ObjectRef, RelationName, Subject)
tupleKey tuple =
  (tuple.object, tuple.relation, tuple.subject)

preconditionHolds :: [Tuple] -> Precondition -> Bool
preconditionHolds tuples = \case
  TupleMustExist tupleFilter ->
    any (matchesTupleFilter tupleFilter) tuples
  TupleMustNotExist tupleFilter ->
    not (any (matchesTupleFilter tupleFilter) tuples)

matchesTupleFilter :: TupleFilter -> Tuple -> Bool
matchesTupleFilter =
  matchesRelationshipFilter . widenTupleFilter

matchesRelationshipFilter :: RelationshipFilter -> Tuple -> Bool
matchesRelationshipFilter relationshipFilter tuple =
  matchesMaybe relationshipFilter.objectType tuple.object.objectType
    && matchesMaybe relationshipFilter.objectId tuple.object.objectId
    && matchesMaybe relationshipFilter.relation tuple.relation
    && matchesMaybe relationshipFilter.subjectType subjectObject.objectType
    && matchesMaybe relationshipFilter.subjectId subjectObject.objectId
    && matchesSubjectRelation relationshipFilter.subjectRelation subjectRelation
    && matchesCaveat relationshipFilter.caveatName tuple.caveat
  where
    (subjectObject, subjectRelation) =
      case tuple.subject of
        SubjectId object -> (object, Nothing)
        SubjectSet object relation -> (object, Just relation)
        SubjectWildcard objectType ->
          ( ObjectRef {objectType, objectId = "*"},
            Nothing
          )

    matchesMaybe expected actual =
      maybe True (== actual) expected

    matchesSubjectRelation expected actual =
      case expected of
        AnySubjectRelation -> True
        NoSubjectRelation -> isNothing actual
        ExactSubjectRelation relation -> actual == Just relation

    matchesCaveat :: Maybe CaveatName -> Maybe TupleCaveat -> Bool
    matchesCaveat Nothing _ = True
    matchesCaveat (Just expected) actual =
      fmap (.name) actual == Just expected

visibleRows :: Word64 -> InMemoryState -> [InMemoryRow]
visibleRows revisionNumber state =
  [ row
  | row <- Map.elems state.memoryRows,
    row.memoryCreatedAt <= revisionNumber,
    maybe True (> revisionNumber) row.memoryDeletedAt
  ]

tuplePage :: InMemoryWorld -> Int -> Word64 -> [InMemoryRow] -> TuplePage
tuplePage world limit cursorId rows =
  let candidates = filter ((> cursorId) . (.memoryRowId)) rows
      (pageRows, extraRows) = splitAt (max 0 limit) candidates
      pageState =
        case extraRows of
          [] -> Exhausted
          _ : _ ->
            HasMore
              ( cursorAt
                  ( case reverse pageRows of
                      [] -> cursorId
                      lastRow : _ -> lastRow.memoryRowId
                  )
              )
   in TuplePage
        { rows = toTupleRow world <$> pageRows,
          state = pageState
        }

changePage :: Int -> Word64 -> [(Word64, TupleChange)] -> ChangePage
changePage limit cursorId rows =
  let candidates = filter ((> cursorId) . fst) rows
      (pageRows, extraRows) = splitAt (max 0 limit) candidates
      pageState =
        case extraRows of
          [] -> Exhausted
          _ : _ ->
            HasMore
              ( cursorAt
                  ( case reverse pageRows of
                      [] -> cursorId
                      (lastRowId, _) : _ -> lastRowId
                  )
              )
   in ChangePage
        { changes = snd <$> pageRows,
          state = pageState
        }

classifyChange ::
  Word64 ->
  Word64 ->
  InMemoryRow ->
  [TupleChange]
classifyChange start end row =
  case (visibleAt start row, visibleAt end row) of
    (False, True) ->
      [change ChangeTouch]
    (True, False) ->
      [change ChangeDelete]
    _ ->
      []
  where
    change kind =
      TupleChange
        { kind,
          tuple = row.memoryTuple,
          rowId = rowIdAt row.memoryRowId
        }

visibleAt :: Word64 -> InMemoryRow -> Bool
visibleAt revisionNumber row =
  row.memoryCreatedAt <= revisionNumber
    && maybe True (> revisionNumber) row.memoryDeletedAt

toTupleRow :: InMemoryWorld -> InMemoryRow -> TupleRow
toTupleRow world row =
  TupleRow
    { rowId = rowIdAt row.memoryRowId,
      tuple = row.memoryTuple,
      createdAt = revisionAt world row.memoryCreatedAt,
      deletedAt = revisionAt world <$> row.memoryDeletedAt
    }

rowIdAt :: Word64 -> TupleRowId
rowIdAt =
  TupleRowId . ("mem-row:" <>) . showText

cursorAt :: Word64 -> StoreCursor
cursorAt =
  StoreCursor . ("mem-row:" <>) . showText

revisionAt :: InMemoryWorld -> Word64 -> Revision
revisionAt world revisionNumber =
  Revision
    ( Text.intercalate
        ":"
        ["mem", world.memoryWorldId, showText revisionNumber]
    )

tokenAt :: InMemoryWorld -> Word64 -> ConsistencyToken
tokenAt world =
  ConsistencyToken . (.revisionEncoding) . revisionAt world

requireRevision ::
  (Error EnError :> es) =>
  InMemoryWorld ->
  Revision ->
  Eff es Word64
requireRevision world revision =
  either throwError pure (decodeRevisionFor world revision)

decodeRevisionFor :: InMemoryWorld -> Revision -> Either EnError Word64
decodeRevisionFor world revision =
  case decodeMemoryEncoding revision.revisionEncoding of
    Just (worldId, revisionNumber)
      | worldId == world.memoryWorldId ->
          Right revisionNumber
      | otherwise ->
          Left (StoreError "revision belongs to a different in-memory world")
    Nothing ->
      Left
        ( StoreError
            ("malformed in-memory revision: " <> revision.revisionEncoding)
        )

requireCursor ::
  (Error EnError :> es) =>
  Maybe StoreCursor ->
  Eff es Word64
requireCursor =
  maybe (pure 0) (either throwError pure . decodeCursor)

decodeCursor :: StoreCursor -> Either EnError Word64
decodeCursor (StoreCursor encoding) =
  case Text.stripPrefix "mem-row:" encoding >>= readWord64 of
    Just rowId -> Right rowId
    Nothing -> Left (InvalidCursor encoding)

decodeTokenMetadata :: ConsistencyToken -> Either EnError TokenMetadata
decodeTokenMetadata token@(ConsistencyToken encoding) =
  case decodeMemoryEncoding encoding of
    Nothing ->
      Left (MalformedConsistencyToken "token is not an in-memory token")
    Just (worldId, _revisionNumber) ->
      Right
        TokenMetadata
          { token,
            revision = Revision encoding,
            datastoreId = datastoreIdFor worldId,
            schemaHash = inMemorySchemaHash,
            expiresAt = Nothing
          }

validateMetadata ::
  (IOE :> es, Error EnError :> es) =>
  InMemoryWorld ->
  TokenMetadata ->
  Eff es ()
validateMetadata world metadata
  | metadata.datastoreId /= datastoreIdFor world.memoryWorldId =
      throwError
        (InvalidConsistencyToken "token datastore does not match this in-memory world")
  | metadata.schemaHash /= inMemorySchemaHash =
      throwError
        (InvalidConsistencyToken "token schema hash does not match the in-memory store")
  | otherwise = do
      revisionNumber <-
        case decodeRevisionFor world metadata.revision of
          Left _ ->
            throwError
              (MalformedConsistencyToken "token revision is not an in-memory revision")
          Right value ->
            pure value
      state <- liftIO (readIORef world.memoryState)
      if revisionNumber < state.memoryGcHorizon
        then
          throwError
            (ConsistencyTokenExpired "token is older than the in-memory garbage-collection horizon")
        else pure ()

resolveInMemoryConsistency ::
  (IOE :> es, Error EnError :> es) =>
  InMemoryWorld ->
  Consistency ->
  Eff es ResolvedConsistency
resolveInMemoryConsistency world consistency =
  case consistency of
    MinimizeLatency ->
      atHead
    FullyConsistent ->
      atHead
    AtExactSnapshot token -> do
      metadata <- either throwError pure (decodeTokenMetadata token)
      validateMetadata world metadata
      pure ResolvedConsistency {consistency, revision = metadata.revision}
    AtLeastAsFresh token -> do
      metadata <- either throwError pure (decodeTokenMetadata token)
      validateMetadata world metadata
      tokenRevision <- requireRevision world metadata.revision
      state <- liftIO (readIORef world.memoryState)
      pure
        ResolvedConsistency
          { consistency,
            revision = revisionAt world (max tokenRevision state.memoryHead)
          }
  where
    atHead = do
      state <- liftIO (readIORef world.memoryState)
      pure
        ResolvedConsistency
          { consistency,
            revision = revisionAt world state.memoryHead
          }

datastoreIdFor :: Text -> DatastoreId
datastoreIdFor =
  DatastoreId . ("in-memory:" <>)

inMemorySchemaHash :: SchemaHash
inMemorySchemaHash =
  SchemaHash "in-memory"

decodeMemoryEncoding :: Text -> Maybe (Text, Word64)
decodeMemoryEncoding encoding =
  case Text.splitOn ":" encoding of
    ["mem", worldId, revisionText] ->
      (worldId,) <$> readWord64 revisionText
    _ ->
      Nothing

readWord64 :: Text -> Maybe Word64
readWord64 text =
  case reads (Text.unpack text) of
    [(value, "")] -> Just value
    _ -> Nothing

showText :: (Show a) => a -> Text
showText =
  Text.pack . show
