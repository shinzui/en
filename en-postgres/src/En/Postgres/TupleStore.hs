{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE MultilineStrings #-}
{-# LANGUAGE NoFieldSelectors #-}

-- | PostgreSQL-backed 'TupleStore'.
module En.Postgres.TupleStore
  ( runTupleStorePostgres,
    runTupleStorePostgresWithOptimizedRevisionCache,
    runTupleStorePostgresWithOptimizedRevisionCacheHandle,
    reapDeletedTuplesSession,
    reapDeletedTuplesBatchSession,
    pruneTransactionsBatchSession,
    sessionErrorToEnError,
  )
where

import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as AesonKey
import Data.Aeson.KeyMap qualified as AesonKeyMap
import Data.Aeson.Types qualified as Aeson
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Functor.Contravariant ((>$<))
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Scientific (floatingOrInteger)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Data.Word (Word64)
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, throwError)
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
  )
import En.Error (EnError (..))
import En.Postgres.Database (Database, runSession)
import En.Postgres.Revision
  ( ConsistencyConfig (..),
    OptimizedRevisionCache,
    OptimizedRevisionConfig,
    PgSnapshot (..),
    TokenPayload (..),
    encodeToken,
    lookupOptimizedRevisionCache,
    newOptimizedRevisionCache,
    parsePgSnapshot,
    renderPgSnapshot,
    revisionToPgSnapshot,
    storeOptimizedRevisionCache,
  )
import En.RelationshipPagination (relationshipSortFingerprint)
import En.Revision
  ( ConsistencyToken (..),
    Revision (..),
    SchemaHash (..),
  )
import En.Schema (CaveatName (..), ObjectType (..), RelationName (..))
import En.Tuple
  ( CaveatPayload (..),
    CaveatValue (..),
    ObjectRef (..),
    Subject (..),
    Tuple (..),
    TupleCaveat (..),
  )
import Hasql.Decoders qualified as Decoders
import Hasql.DynamicStatements.Snippet (Snippet)
import Hasql.DynamicStatements.Snippet qualified as Snippet
import Hasql.Encoders qualified as Encoders
import Hasql.Errors qualified as Hasql
import Hasql.Session (Session)
import Hasql.Session qualified as Session
import Hasql.Statement (Statement)
import Hasql.Statement qualified as Statement
import Numeric (readDec)
import Relay.Pagination (Connection, CursorError (..), PageRequest)
import Relay.Pagination.Hasql
  ( KeyColumn (..),
    SortDirection (..),
    SortSpec (..),
    int8Key,
    paginate,
    sortSpecFingerprint,
    textKey,
  )

runTupleStorePostgres ::
  (Database :> es, Error EnError :> es) =>
  ConsistencyConfig ->
  Eff (TupleStore : es) a ->
  Eff es a
runTupleStorePostgres config =
  interpretTupleStorePostgres config uncachedOptimizedRevision

runTupleStorePostgresWithOptimizedRevisionCache ::
  (Database :> es, IOE :> es, Error EnError :> es) =>
  ConsistencyConfig ->
  OptimizedRevisionConfig ->
  Eff (TupleStore : es) a ->
  Eff es a
runTupleStorePostgresWithOptimizedRevisionCache config optimizedConfig action = do
  cache <- liftIO (newOptimizedRevisionCache optimizedConfig getCurrentTime)
  interpretTupleStorePostgres config (cachedOptimizedRevision cache) action

runTupleStorePostgresWithOptimizedRevisionCacheHandle ::
  (Database :> es, IOE :> es, Error EnError :> es) =>
  ConsistencyConfig ->
  OptimizedRevisionCache ->
  Eff (TupleStore : es) a ->
  Eff es a
runTupleStorePostgresWithOptimizedRevisionCacheHandle config cache =
  interpretTupleStorePostgres config (cachedOptimizedRevision cache)

interpretTupleStorePostgres ::
  (Database :> es, Error EnError :> es) =>
  ConsistencyConfig ->
  Eff es Revision ->
  Eff (TupleStore : es) a ->
  Eff es a
interpretTupleStorePostgres config readOptimizedRevision =
  interpret_ \case
    ReadObjectRelation revision object relation limit cursor -> do
      cursorId <- resolveCursor cursor
      orThrow =<< runSession (readObjectRelationSession revision object relation limit cursorId)
    ReadStartingWithUser revision query -> do
      cursorId <- resolveCursor query.queryCursor
      orThrow =<< runSession (readStartingWithUserSession revision query cursorId)
    ReadAllTuples revision limit cursor -> do
      cursorId <- resolveCursor cursor
      orThrow =<< runSession (readAllTuplesSession revision limit cursorId)
    ProbeTuples revision object relation subjects ->
      orThrow =<< runSession (probeTuplesSession revision object relation subjects)
    ReadRelationships revision relationshipFilter limit cursor -> do
      cursorId <- resolveCursor cursor
      orThrow =<< runSession (readRelationshipsSession revision relationshipFilter limit cursorId)
    ReadRelationshipPage revision token relationshipFilter pageRequest ->
      orThrow =<< runSession (relationshipPageSession revision token relationshipFilter pageRequest)
    CountRelationships revision relationshipFilter ->
      orThrow =<< runSession (countRelationshipsSession revision relationshipFilter)
    DeleteRelationships relationshipFilter -> do
      (count, anchor) <- orThrow =<< runSession (deleteRelationshipsSession config relationshipFilter)
      token <- mintToken config anchor
      pure (count, token)
    ReadChanges start end relationshipFilter limit cursor -> do
      cursorId <- resolveCursor cursor
      startXmin <- either throwError pure (windowStartXmin start)
      orThrow =<< runSession (readChangesSession start end startXmin relationshipFilter limit cursorId)
    ApplyTupleWrites request -> do
      outcome <- orThrow =<< runSession (applyTupleWritesSession config request)
      anchor <- either (throwError . WritePreconditionFailed) pure outcome
      mintToken config anchor
    HeadRevision ->
      orThrow =<< runSession headRevisionSession
    OptimizedRevision ->
      readOptimizedRevision
    OldestRetainedXid ->
      orThrow =<< runSession (oldestRetainedXidSession config.gcWindow)
    AdvanceGcHorizon ->
      orThrow =<< runSession (advanceGcHorizonSession config.gcWindow)
    ReapDeletedTuples horizon ->
      orThrow =<< runSession (reapDeletedTuplesSession horizon)
  where
    orThrow =
      either (throwError . sessionErrorToEnError) pure

-- | Preserve dependency outages as retryable store failures while classifying
-- decoder/schema/driver mismatches as bugs in en. 'Hasql.isTransient' is too coarse
-- here: it marks every statement error non-transient, including PostgreSQL's
-- @deadlock_detected@ and other server-side arbitration failures that callers may retry.
sessionErrorToEnError :: Hasql.SessionError -> EnError
sessionErrorToEnError sessionError =
  let details = Hasql.toDetailedText sessionError
   in case sessionError of
        Hasql.ConnectionSessionError _ -> StoreError details
        Hasql.StatementSessionError _ _ _ _ _ (Hasql.ServerStatementError _) -> StoreError details
        Hasql.StatementSessionError {} -> InternalError details
        Hasql.ScriptSessionError {} -> StoreError details
        Hasql.MissingTypesSessionError _ -> InternalError details
        Hasql.DriverSessionError _ -> InternalError details

-- | Resolve a caller's cursor to the row id it names, rejecting a malformed one.
--
-- Absent means "from the start"; malformed means the caller is not resuming a page
-- this store issued, and continuing would silently restart the scan and duplicate
-- its results. Resolved here rather than inside the session so the read sessions
-- stay infallible and the fault stays typed.
resolveCursor :: (Error EnError :> es) => Maybe StoreCursor -> Eff es Int64
resolveCursor =
  maybe (pure 0) (either throwError pure . decodeCursor)

-- | Mint the write token for a committed transaction's anchor.
--
-- Minting happens here, outside the write 'Session', because a snapshot that does
-- not parse is not a database error and hasql offers a 'Session' no ergonomic
-- channel for one. Failing loudly matters: the alternative is handing the caller a
-- token that cannot see the write it was minted for.
mintToken :: (Error EnError :> es) => ConsistencyConfig -> Anchor -> Eff es ConsistencyToken
mintToken config anchor =
  either (throwError . InternalError . ("could not mint write token: " <>)) pure (tokenFromAnchor config anchor)

uncachedOptimizedRevision ::
  (Database :> es, Error EnError :> es) =>
  Eff es Revision
uncachedOptimizedRevision =
  orThrow =<< runSession headRevisionSession
  where
    orThrow =
      either (throwError . sessionErrorToEnError) pure

cachedOptimizedRevision ::
  (Database :> es, IOE :> es, Error EnError :> es) =>
  OptimizedRevisionCache ->
  Eff es Revision
cachedOptimizedRevision cache = do
  cached <- liftIO (lookupOptimizedRevisionCache cache)
  case cached of
    Just revision -> pure revision
    Nothing -> do
      revision <- uncachedOptimizedRevision
      liftIO (storeOptimizedRevisionCache cache revision)
      pure revision

-- | Apply one atomic write request, returning the transaction's anchor.
--
-- The transaction checks every precondition, applies the deletes, applies the
-- writes, and commits. A failing precondition rolls back and returns @Left@
-- describing it: nothing was written and no token is minted.
--
-- The caller mints the token from the anchor (see 'mintToken'), so a snapshot that
-- does not parse can be a typed error rather than a silently degraded token.
--
-- Deletes run before writes so that "replace the grant on this key" is one natural
-- request rather than a self-cancelling one.
--
-- Writes have touch semantics. A live tuple's identity is (object, relation,
-- subject); its caveat is an attribute of the grant, not part of its identity. So a
-- write either inserts, does nothing (the live row is already byte-identical), or
-- retires the differing live row and inserts the replacement — all inside this
-- session's single transaction, so no observer ever sees both rows live.
--
-- The whole request travels in a constant number of statements regardless of how
-- many tuples it names: each column of the batch is sent as one PostgreSQL array
-- and expanded server-side with @unnest@. A write costs @BEGIN@, the anchor, the
-- retire, the insert, the convergence check, and @COMMIT@ — six round trips for any
-- number of tuples, eight on the rare contended retry. A delete costs four.
applyTupleWritesSession :: ConsistencyConfig -> TupleWriteRequest -> Session (Either Text Anchor)
applyTupleWritesSession config request = do
  Session.script beginScript
  anchor <- Session.statement schemaHashText anchorTransactionStatement
  failure <- firstPreconditionFailure request.preconditions
  case failure of
    Just description -> do
      Session.script rollbackScript
      pure (Left description)
    Nothing -> do
      batchDeleteTuples anchor.xid request.deletes
      batchTouchTuples anchor.xid (dedupeWrites request.writes)
      Session.script commitScript
      pure (Right anchor)
  where
    SchemaHash schemaHashText = config.schemaHash

-- | Keep the last write for each identity, in request order.
--
-- The same key appearing twice in one call resolves last-wins, as it did when
-- writes were applied one statement at a time. Applied sequentially the loser left
-- a row stamped @deleted_xid = created_xid@, visible at no revision; the batch
-- never inserts it. The two are indistinguishable to every reader at every
-- revision.
--
-- Deduplicating is not a nicety here. @ON CONFLICT DO NOTHING@ over a multi-row
-- insert keeps whichever conflicting row it happens to reach first, so a batch
-- carrying one identity twice would resolve arbitrary-wins rather than last-wins.
dedupeWrites :: [Tuple] -> [Tuple]
dedupeWrites tuples =
  [tuple | (index, tuple) <- indexed, Map.lookup (tupleIdentity tuple) lastIndex == Just index]
  where
    indexed = zip [0 :: Int ..] tuples
    lastIndex = Map.fromList [(tupleIdentity tuple, index) | (index, tuple) <- indexed]

-- | The identity @relation_tuple_live_unique@ keys on: everything but the caveat.
--
-- An absent subject relation is normalized to @\"\"@ so this agrees with the SQL
-- predicate, which compares @coalesce(subject_relation, '')@.
tupleIdentity :: Tuple -> (Text, Text, Text, Text, Text, Text)
tupleIdentity tuple =
  let (subjectObject, subjectRelation) = flattenSubject tuple.subject
   in ( unObjectType tuple.object.objectType,
        tuple.object.objectId,
        unRelationName tuple.relation,
        unObjectType subjectObject.objectType,
        subjectObject.objectId,
        maybe "" unRelationName subjectRelation
      )

-- | Retire the live grants the request names, whatever caveats they carry.
--
-- An empty request sends nothing: an @unnest@ of empty arrays would match no row,
-- at the cost of a round trip to discover it.
batchDeleteTuples :: Text -> [Tuple] -> Session ()
batchDeleteTuples _ [] = pure ()
batchDeleteTuples writeXid tuples =
  Session.statement (batchParams writeXid tuples) batchDeleteTupleStatement

-- | Apply touch semantics to a whole batch.
--
-- Each attempt retires every live row that shares a batch entry's identity but
-- carries a different caveat, inserts the batch, then asks which entries still lack
-- a byte-identical live row. An entry that has one is satisfied — whether this
-- statement inserted it or it was already there — so that single set-oriented
-- question subsumes the per-tuple \"inserted, or already identical?\" pair.
--
-- The convergence check must observe the rows. Inferring satisfaction from
-- @rowsAffected@ — \"nothing to retire and nothing to insert, so it was already
-- there\" — is unsound under @READ COMMITTED@, where each statement takes its own
-- snapshot: a concurrent transaction committing a /different/ caveat between the
-- retire and the insert makes both report zero, and the caller's write is silently
-- dropped. That is exactly the bug touch semantics exist to remove.
--
-- A second attempt re-reads and retires the racer's now-committed rows. If even
-- that does not converge, the final insert omits @ON CONFLICT@ so PostgreSQL raises
-- @unique_violation@ and the write fails loudly instead of being dropped. Only the
-- unconverged entries are retried: the rest already hold their rows, and an insert
-- of a satisfied entry would raise the very violation that signals failure.
batchTouchTuples :: Text -> [Tuple] -> Session ()
batchTouchTuples _ [] = pure ()
batchTouchTuples writeXid tuples = do
  unconverged <- attempt tuples
  case unconverged of
    [] -> pure ()
    contended -> do
      stillUnconverged <- attempt contended
      case stillUnconverged of
        [] -> pure ()
        doomed -> do
          let params = batchParams writeXid doomed
          Session.statement params batchTouchReplaceStatement
          Session.statement params batchInsertTupleStrictStatement
  where
    attempt batch = do
      let params = batchParams writeXid batch
      Session.statement params batchTouchReplaceStatement
      Session.statement params batchInsertTupleStatement
      ordinals <- Session.statement params batchUnconvergedStatement
      pure (selectOrdinals batch ordinals)

-- | The batch entries at the given one-based ordinals, in batch order.
selectOrdinals :: [Tuple] -> [Int64] -> [Tuple]
selectOrdinals batch ordinals =
  [tuple | (index, tuple) <- zip [1 ..] batch, index `Set.member` wanted]
  where
    wanted = Set.fromList ordinals

-- | The first precondition that does not hold, rendered; 'Nothing' when all hold.
--
-- Checking stops at the first failure: the request is already doomed, and every
-- further check would only take locks the impending @ROLLBACK@ must release.
firstPreconditionFailure :: [Precondition] -> Session (Maybe Text)
firstPreconditionFailure = \case
  [] -> pure Nothing
  precondition : rest -> do
    held <- preconditionHolds precondition
    if held
      then firstPreconditionFailure rest
      else pure (Just (renderPrecondition precondition))

-- | Whether a precondition holds inside the write transaction.
--
-- A must-exist check locks the row it found with @FOR UPDATE@. Without a lock the
-- check could pass while a concurrent transaction soft-deletes the row and commits
-- — gap E1 exactly. With one, a second transaction guarding on the same row blocks
-- at this @SELECT@ until the first commits, then re-evaluates the row under
-- @READ COMMITTED@ (EvalPlanQual), finds @deleted_xid@ now set, matches nothing,
-- and fails its precondition.
--
-- The lock is exclusive rather than shared even though this statement only reads.
-- @FOR SHARE@ would let both racing transactions pass the check — share locks are
-- compatible — and then deadlock them against each other when each tried to upgrade
-- to the exclusive lock its @UPDATE@ needs. PostgreSQL would abort one with
-- @deadlock_detected@, which is an outage-shaped 'En.Error.StoreError' rather than
-- the arbitration loss that actually occurred.
--
-- A filter matching several rows locks only the first (@LIMIT 1@). If that row is
-- concurrently retired, the check reports failure even though another matching row
-- survives. That is a spurious refusal, never a spurious success: this is a safety
-- guard, and it fails closed.
--
-- A must-not-exist check cannot lock what is not there. It relies on
-- @relation_tuple_live_unique@ to turn a racing insert of the same identity into a
-- loud unique-violation rather than a silent duplicate. Fail-closed either way.
preconditionHolds :: Precondition -> Session Bool
preconditionHolds = \case
  TupleMustExist tupleFilter ->
    isJust <$> Session.statement (tupleFilterParams tupleFilter) lockMatchingLiveTupleStatement
  TupleMustNotExist tupleFilter ->
    not <$> Session.statement (tupleFilterParams tupleFilter) matchingLiveTupleExistsStatement

headRevisionSession :: Session Revision
headRevisionSession =
  Revision <$> Session.statement () currentSnapshotStatement

oldestRetainedXidSession :: Text -> Session Word64
oldestRetainedXidSession window =
  fromIntegral <$> Session.statement window oldestRetainedXidStatement

-- | Advance the durable garbage-collection horizon to @GREATEST(mark, fresh)@ and
-- return the new high-water mark.
--
-- The reaper runs this once per pass to fix the horizon it will reap and prune at,
-- before it destroys anything. Its @UPDATE@ is committed in its own session, so any
-- later 'oldestRetainedXidSession' — on this or any other replica — reads a mark at
-- least as high as every reap already performed. See @docs/plans/60@ Milestone 4.
advanceGcHorizonSession :: Text -> Session Word64
advanceGcHorizonSession window =
  fromIntegral <$> Session.statement window advanceGcHorizonStatement

-- | Physically delete every soft-deleted tuple behind @horizon@ in one statement.
--
-- Retained for embedded consumers and the integration test. Background maintenance
-- should prefer 'reapDeletedTuplesBatchSession': one unbounded @DELETE@ holds row locks
-- for its whole duration and emits its write-ahead log in a single burst, both
-- proportional to the size of the backlog.
reapDeletedTuplesSession :: Word64 -> Session Int64
reapDeletedTuplesSession horizon =
  Session.statement (Text.pack (show horizon)) reapDeletedTuplesStatement

-- | Physically delete at most @batch@ soft-deleted tuples whose delete is behind
-- @horizon@, returning how many were removed.
--
-- A tuple deleted before the garbage-collection horizon cannot be seen by any
-- consistency token that still validates (see @validateTokenMetadata@ in
-- "En.Postgres.Revision", which rejects tokens whose snapshot @xmax@ is at or below the
-- horizon), so its row can be removed.
--
-- Callers loop until a call returns fewer than @batch@. Each call is its own
-- transaction, so locks are released between batches and an interrupted loop leaves
-- every completed batch committed.
reapDeletedTuplesBatchSession :: Word64 -> Int -> Session Int64
reapDeletedTuplesBatchSession horizon batch =
  Session.statement (Text.pack (show horizon), fromIntegral batch) reapDeletedTuplesBatchStatement

-- | Delete at most @batch@ @en_transaction@ rows behind @horizon@, returning how many
-- were removed.
--
-- Rows are selected by @xid < horizon@ rather than by re-deriving a cutoff from
-- @created_at@, so the pruner, the reaper, and token validation share one horizon and
-- cannot disagree. @horizon@ is @GREATEST(high-water mark, min(xid) over the retention
-- window)@ ('advanceGcHorizonStatement'): normally the @min(xid)@ term governs and no
-- in-window anchor is selected, but when the mark sits above a fresh in-window
-- @min(xid)@ — the non-monotone case Milestone 4 clamps away — an in-window anchor
-- below the mark may be pruned. That is safe: the mark already treats every xid below
-- it as behind the horizon, so token validation would already reject any snapshot that
-- needs such an anchor to be in flight, and the anchor no longer protects anything.
pruneTransactionsBatchSession :: Word64 -> Int -> Session Int64
pruneTransactionsBatchSession horizon batch =
  Session.statement (Text.pack (show horizon), fromIntegral batch) pruneTransactionsBatchStatement

readStartingWithUserSession :: Revision -> UsersetQuery -> Int64 -> Session TuplePage
readStartingWithUserSession revision query cursorId = do
  let limitPlusOne = fromIntegral (max 0 query.queryLimit + 1)
  rows <- Session.statement (readParams revision query limitPlusOne cursorId) readStartingWithUserStatement
  pure (pageFromRows cursorId query.queryLimit rows)

readObjectRelationSession :: Revision -> ObjectRef -> RelationName -> Int -> Int64 -> Session TuplePage
readObjectRelationSession revision object relation limit cursorId = do
  let limitPlusOne = fromIntegral (max 0 limit + 1)
  rows <- Session.statement (objectReadParams revision object relation limitPlusOne cursorId) readObjectRelationStatement
  pure (pageFromRows cursorId limit rows)

readAllTuplesSession :: Revision -> Int -> Int64 -> Session TuplePage
readAllTuplesSession revision limit cursorId = do
  let limitPlusOne = fromIntegral (max 0 limit + 1)
  rows <- Session.statement (allReadParams revision limitPlusOne cursorId) readAllTuplesStatement
  pure (pageFromRows cursorId limit rows)

readRelationshipsSession :: Revision -> RelationshipFilter -> Int -> Int64 -> Session TuplePage
readRelationshipsSession revision relationshipFilter limit cursorId = do
  let limitPlusOne = fromIntegral (max 0 limit + 1)
  rows <- Session.statement () (readRelationshipsStatement revision relationshipFilter limitPlusOne cursorId)
  pure (pageFromRows cursorId limit rows)

data RelationshipPageRow = RelationshipPageRow
  { snapshotToken :: !Text,
    tupleRow :: !TupleRow
  }

relationshipSortSpec :: SortSpec RelationshipPageRow
relationshipSortSpec =
  SortSpec
    ( KeyColumn
        { columnExpr = "snapshot_token",
          sortDir = Asc,
          extract = (.snapshotToken),
          codec = textKey
        }
        :| [ KeyColumn
               { columnExpr = "id",
                 sortDir = Asc,
                 extract = (.tupleRow.pageKey),
                 codec = int8Key
               }
           ]
    )

relationshipPageSession ::
  Revision ->
  ConsistencyToken ->
  RelationshipFilter ->
  PageRequest ->
  Session (Either CursorError (Connection TupleRow))
relationshipPageSession revision token relationshipFilter pageRequest
  | actualFingerprint /= relationshipSortFingerprint =
      pure
        ( Left
            FingerprintMismatch
              { expected = relationshipSortFingerprint,
                actual = actualFingerprint
              }
        )
  | otherwise =
      case paginate relationshipSortSpec pageRequest baseQuery relationshipPageRowDecoder of
        Left cursorError -> pure (Left cursorError)
        Right statement -> Right . fmap (.tupleRow) <$> Session.statement () statement
  where
    actualFingerprint = sortSpecFingerprint relationshipSortSpec
    baseQuery = relationshipPageBase revision token relationshipFilter

relationshipPageBase :: Revision -> ConsistencyToken -> RelationshipFilter -> Snippet
relationshipPageBase revision (ConsistencyToken token) relationshipFilter =
  "SELECT "
    <> Snippet.param token
    <> "::text AS snapshot_token, id, object_type, object_id, relation, subject_type, subject_id, subject_relation, caveat_name, caveat_payload, created_xid::text, deleted_xid::text "
    <> "FROM relation_tuple WHERE pg_visible_in_snapshot(created_xid, "
    <> Snippet.param revision.revisionEncoding
    <> "::text::pg_snapshot) AND (deleted_xid IS NULL OR NOT pg_visible_in_snapshot(deleted_xid, "
    <> Snippet.param revision.revisionEncoding
    <> "::text::pg_snapshot))"
    <> foldMap (" AND " <>) (relationshipFilterSnippets relationshipFilter)

relationshipFilterSnippets :: RelationshipFilter -> [Snippet]
relationshipFilterSnippets relationshipFilter =
  concat
    [ column "object_type" (unObjectType <$> relationshipFilter.objectType),
      column "object_id" relationshipFilter.objectId,
      column "relation" (unRelationName <$> relationshipFilter.relation),
      column "subject_type" (unObjectType <$> relationshipFilter.subjectType),
      column "subject_id" relationshipFilter.subjectId,
      subjectRelation relationshipFilter.subjectRelation,
      column "caveat_name" (unCaveatName <$> relationshipFilter.caveatName)
    ]
  where
    column name =
      foldMap (\value -> [Snippet.sql name <> " = " <> Snippet.param value])

    subjectRelation = \case
      AnySubjectRelation -> []
      NoSubjectRelation -> ["coalesce(subject_relation, '') = ''"]
      ExactSubjectRelation relationName ->
        ["coalesce(subject_relation, '') = " <> Snippet.param (unRelationName relationName)]

relationshipPageRowDecoder :: Decoders.Row RelationshipPageRow
relationshipPageRowDecoder =
  RelationshipPageRow
    <$> Decoders.column (Decoders.nonNullable Decoders.text)
    <*> tupleRowDecoder

countRelationshipsSession :: Revision -> RelationshipFilter -> Session Int64
countRelationshipsSession revision relationshipFilter =
  Session.statement () (countRelationshipsStatement revision relationshipFilter)

readChangesSession :: Revision -> Revision -> Word64 -> Maybe RelationshipFilter -> Int -> Int64 -> Session ChangePage
readChangesSession start end startXmin relationshipFilter limit cursorId = do
  let limitPlusOne = fromIntegral (max 0 limit + 1)
  rows <- Session.statement () (readChangesStatement start end startXmin relationshipFilter limitPlusOne cursorId)
  pure (changePageFromRows cursorId limit rows)

-- | The window-start snapshot's @xmin@: the sargable bound the window query needs.
--
-- Every transaction below a snapshot's @xmin@ is visible in it, so no row created or deleted
-- by such a transaction can have /become/ visible inside a window starting there. The bound
-- is therefore free of information — it excludes nothing the visibility predicates would
-- have kept — and it is what turns each arm of the query from a sequential scan into a range
-- scan over @relation_tuple_created_xid_idx@ or @relation_tuple_deleted_xid_idx@.
--
-- A revision that is not a snapshot is a client fault, not a store failure: it reached here
-- from a watch cursor or a consistency token the caller supplied.
windowStartXmin :: Revision -> Either EnError Word64
windowStartXmin revision =
  case revisionToPgSnapshot revision of
    Left err -> Left (MalformedConsistencyToken ("watch window start is not a PostgreSQL snapshot: " <> err))
    Right snapshot -> Right snapshot.xmin

-- | Match and retire in one transaction, returning the count and the anchor.
--
-- The count and the anchor's token therefore describe the same set of rows. Read the
-- matches in one transaction and delete them in another and they need not: a grant
-- committed between the two is counted and not deleted, or deleted and not counted, and
-- the operator who ran a dry run is told a number that was never true.
--
-- No @ROLLBACK@ path, unlike 'applyTupleWritesSession': there are no preconditions to fail.
-- A SQL error aborts the session and the transaction with it.
deleteRelationshipsSession :: ConsistencyConfig -> RelationshipFilter -> Session (Int64, Anchor)
deleteRelationshipsSession config relationshipFilter = do
  Session.script beginScript
  anchor <- Session.statement schemaHashText anchorTransactionStatement
  count <- Session.statement () (deleteRelationshipsStatement anchor.xid relationshipFilter)
  Session.script commitScript
  pure (count, anchor)
  where
    SchemaHash schemaHashText = config.schemaHash

-- | The @WHERE@ fragments a filter contributes, numbered from @start@, paired with the
-- encoder that binds their values.
--
-- The values are baked into the encoder — every parameter is @const@ over the statement's
-- @()@ input — so the /text/ this returns depends only on which fields are present, not on
-- what they hold. hasql caches prepared statements by text, so the cache sees one entry per
-- filter /shape/, and 'validateRelationshipFilter' bounds the shapes to those with an
-- anchor.
--
-- An absent field contributes nothing at all. It is emphatically not sent as a
-- @($n::text IS NULL OR column = $n)@ guard, which is the obvious way to keep one fixed
-- statement per operation and the reason this function exists. PostgreSQL can only see
-- through such a guard while it is building a /custom/ plan, where the parameter is
-- substituted as a constant and the disjunction folds away. hasql prepares its statements,
-- so after five executions PostgreSQL is free to build a generic plan — and under a generic
-- plan the guard is opaque, @object_type@ can no longer become an index condition, and
-- @relation_tuple_object_hist_idx@ is abandoned for a sequential scan. The endpoint would
-- degrade on its sixth call, in production, silently. Composing the predicate makes the
-- anchored columns equality quals under every plan type.
--
-- @subject_relation@ is always compared through @coalesce(subject_relation, '')@, matching
-- the expression @relation_tuple_subject_hist_idx@ is built on; comparing the bare column
-- would make the index unusable for the very filters it exists to serve.
compileFilter :: Int -> RelationshipFilter -> ([Text], Encoders.Params ())
compileFilter start relationshipFilter =
  let (_, predicates, encoder) = foldl' step (start, [], mempty) clauses
   in (reverse predicates, encoder)
  where
    step (index, predicates, encoder) (render, binding) =
      case binding of
        Nothing -> (index, render index : predicates, encoder)
        Just value -> (index + 1, render index : predicates, encoder <> constTextParam value)

    -- Each clause renders itself given the index its parameter will occupy, and says
    -- what value (if any) to bind there. A clause binding 'Nothing' spends no index.
    clauses :: [(Int -> Text, Maybe Text)]
    clauses =
      concat
        [ column "object_type" (unObjectType <$> relationshipFilter.objectType),
          column "object_id" relationshipFilter.objectId,
          column "relation" (unRelationName <$> relationshipFilter.relation),
          column "subject_type" (unObjectType <$> relationshipFilter.subjectType),
          column "subject_id" relationshipFilter.subjectId,
          subjectRelationClause relationshipFilter.subjectRelation,
          column "caveat_name" (unCaveatName <$> relationshipFilter.caveatName)
        ]

    column name =
      foldMap (\value -> [(\index -> name <> " = " <> placeholder index, Just value)])

    subjectRelationClause = \case
      AnySubjectRelation -> []
      NoSubjectRelation -> [(const "coalesce(subject_relation, '') = ''", Nothing)]
      ExactSubjectRelation relationName ->
        [ ( \index -> "coalesce(subject_relation, '') = " <> placeholder index,
            Just (unRelationName relationName)
          )
        ]

    placeholder index = "$" <> Text.pack (show index) <> "::text"

-- | A parameter whose value is fixed when the statement is built. See 'compileFilter'.
constTextParam :: Text -> Encoders.Params ()
constTextParam value =
  const value >$< Encoders.param (Encoders.nonNullable Encoders.text)

constInt8Param :: Int64 -> Encoders.Params ()
constInt8Param value =
  const value >$< Encoders.param (Encoders.nonNullable Encoders.int8)

-- | A page of filter-matching tuples live at the revision, keyset-paginated by row id.
--
-- 'readObjectRelationStatement' with the object and relation predicates replaced by the
-- filter's, and the same @pg_visible_in_snapshot@ visibility pair every read uses — so a
-- page taken long after the revision was resolved still excludes every row committed since.
--
-- Which index serves it depends on the filter's anchor: @relation_tuple_object_hist_idx@
-- for an @objectType@ anchor, @relation_tuple_subject_hist_idx@ for a @subjectType@ one.
-- @relation@ and @caveat_name@ lead no index and are always residual predicates, applied to
-- rows the anchor already narrowed. See docs/plans/50 for the measured plans.
readRelationshipsStatement :: Revision -> RelationshipFilter -> Int64 -> Int64 -> Statement () [TupleRow]
readRelationshipsStatement revision relationshipFilter limitPlusOne cursorId =
  Statement.preparable sql encoder (Decoders.rowList tupleRowDecoder)
  where
    (predicates, filterEncoder) = compileFilter 4 relationshipFilter
    sql =
      Text.unlines $
        [ "SELECT id, object_type, object_id, relation, subject_type, subject_id, subject_relation,",
          "       caveat_name, caveat_payload, created_xid::text, deleted_xid::text",
          "FROM relation_tuple",
          "WHERE id > $2",
          "  AND pg_visible_in_snapshot(created_xid, $1::pg_snapshot)",
          "  AND (deleted_xid IS NULL OR NOT pg_visible_in_snapshot(deleted_xid, $1::pg_snapshot))"
        ]
          <> fmap ("  AND " <>) predicates
          <> [ "ORDER BY id ASC",
               "LIMIT $3"
             ]
    encoder =
      constTextParam revision.revisionEncoding
        <> constInt8Param cursorId
        <> constInt8Param limitPlusOne
        <> filterEncoder

-- | How many tuples live at the revision match the filter.
--
-- 'readRelationshipsStatement' without the cursor, the limit, or the ordering. The count is
-- deliberately unbounded by a page: it answers "how many grants would this delete revoke?",
-- and a page-bounded answer to that question is a lie.
countRelationshipsStatement :: Revision -> RelationshipFilter -> Statement () Int64
countRelationshipsStatement revision relationshipFilter =
  Statement.preparable
    sql
    encoder
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))
  where
    (predicates, filterEncoder) = compileFilter 2 relationshipFilter
    sql =
      Text.unlines $
        [ "SELECT count(*)",
          "FROM relation_tuple",
          "WHERE pg_visible_in_snapshot(created_xid, $1::pg_snapshot)",
          "  AND (deleted_xid IS NULL OR NOT pg_visible_in_snapshot(deleted_xid, $1::pg_snapshot))"
        ]
          <> fmap ("  AND " <>) predicates
    encoder = constTextParam revision.revisionEncoding <> filterEncoder

-- | Soft-delete every live row the filter matches, returning how many.
--
-- The predicate is @deleted_xid IS NULL@ rather than a snapshot test: a delete acts on the
-- live state, not on some caller's older view of it. That is also why this statement takes
-- no revision.
--
-- Two of the indexes that once served exactly this shape — the partial
-- @relation_tuple_object_live_idx@ and @relation_tuple_subject_live_idx@ — were dropped by
-- docs/plans/49 as dead, on an argument that considered only snapshot-visible /reads/. What
-- remains is @relation_tuple_live_unique@, itself partial on @deleted_xid IS NULL@ and
-- leading with @object_type@, which serves an object-anchored delete; a subject-anchored one
-- rides @relation_tuple_subject_hist_idx@ and applies @deleted_xid IS NULL@ as a residual.
-- See docs/plans/50 for the measured plans.
--
-- @LIMIT@ cannot appear on an @UPDATE@, and none is wanted: a delete-by-filter that stopped
-- early would report a count for a revocation it did not finish.
deleteRelationshipsStatement :: Text -> RelationshipFilter -> Statement () Int64
deleteRelationshipsStatement writeXid relationshipFilter =
  Statement.preparable
    sql
    encoder
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))
  where
    (predicates, filterEncoder) = compileFilter 2 relationshipFilter
    sql =
      Text.unlines $
        [ "WITH deleted AS (",
          "  UPDATE relation_tuple",
          "  SET deleted_xid = $1::xid8",
          "  WHERE deleted_xid IS NULL"
        ]
          <> fmap ("    AND " <>) predicates
          <> [ "  RETURNING id",
               ")",
               "SELECT count(*) FROM deleted"
             ]
    encoder = constTextParam writeXid <> filterEncoder

-- | Every row whose live-set membership changed in the window @(start, end]@, one keyset
-- page at a time.
--
-- A row's creation /became visible/ in the window exactly when it is visible in @end@ and not
-- in @start@, and likewise for its deletion; the live set at either end is the rows whose
-- creation is visible there and whose deletion is not. So the two arms of the @OR@ are the
-- two ways a row can differ between the ends, and the two booleans the statement selects say
-- which happened. Classification is 'changePageFromRows'' job, because "created and deleted
-- inside one window" is a row that satisfies both and must contribute nothing.
--
-- @created_xid >= $3::xid8@ and its @deleted_xid@ twin are 'windowStartXmin''s bound. Without
-- them each arm reads the whole table on every poll. With them, @relation_tuple_created_xid_idx@
-- and the partial @relation_tuple_deleted_xid_idx@ each serve their arm, and the planner
-- combines them under a @BitmapOr@.
--
-- The filter's predicates are composed rather than sent as @($n IS NULL OR column = $n)@
-- guards, for the reason 'compileFilter' gives at length: such a guard is opaque to a generic
-- plan, and hasql prepares its statements.
readChangesStatement :: Revision -> Revision -> Word64 -> Maybe RelationshipFilter -> Int64 -> Int64 -> Statement () [ChangeRow]
readChangesStatement start end startXmin relationshipFilter limitPlusOne cursorId =
  Statement.preparable sql encoder (Decoders.rowList changeRowDecoder)
  where
    (predicates, filterEncoder) = maybe ([], mempty) (compileFilter 6) relationshipFilter
    sql =
      Text.unlines $
        [ "SELECT id, object_type, object_id, relation, subject_type, subject_id, subject_relation,",
          "       caveat_name, caveat_payload, created_xid::text, deleted_xid::text,",
          "       ( pg_visible_in_snapshot(created_xid, $2::pg_snapshot)",
          "         AND NOT pg_visible_in_snapshot(created_xid, $1::pg_snapshot) ) AS created_in_window,",
          "       ( deleted_xid IS NOT NULL",
          "         AND pg_visible_in_snapshot(deleted_xid, $2::pg_snapshot)",
          "         AND NOT pg_visible_in_snapshot(deleted_xid, $1::pg_snapshot) ) AS deleted_in_window",
          "FROM relation_tuple",
          "WHERE id > $4",
          "  AND ( ( created_xid >= $3::xid8",
          "          AND pg_visible_in_snapshot(created_xid, $2::pg_snapshot)",
          "          AND NOT pg_visible_in_snapshot(created_xid, $1::pg_snapshot) )",
          "     OR ( deleted_xid IS NOT NULL",
          "          AND deleted_xid >= $3::xid8",
          "          AND pg_visible_in_snapshot(deleted_xid, $2::pg_snapshot)",
          "          AND NOT pg_visible_in_snapshot(deleted_xid, $1::pg_snapshot) ) )"
        ]
          <> fmap ("  AND " <>) predicates
          <> [ "ORDER BY id ASC",
               "LIMIT $5"
             ]
    encoder =
      constTextParam start.revisionEncoding
        <> constTextParam end.revisionEncoding
        -- As in 'reapDeletedTuplesStatement': hasql has no @xid8@ encoder, and an
        -- @xid8@ does not fit a signed @int8@ near wraparound, so it travels as text.
        <> constTextParam (Text.pack (show startXmin))
        <> constInt8Param cursorId
        <> constInt8Param limitPlusOne
        <> filterEncoder

-- | A row of 'readChangesStatement': the tuple, and the two visibility facts about it.
type ChangeRow = (TupleRow, Bool, Bool)

changeRowDecoder :: Decoders.Row ChangeRow
changeRowDecoder =
  (,,)
    <$> tupleRowDecoder
    <*> Decoders.column (Decoders.nonNullable Decoders.bool)
    <*> Decoders.column (Decoders.nonNullable Decoders.bool)

-- | Classify the fetched rows into events, and say where the next page resumes.
--
-- Paging is decided on the /fetched/ rows and not on the emitted events, which is why this
-- cannot reuse 'pageFromRows'. A row created and deleted inside the window emits nothing, so
-- a page can hold fewer events than its limit and still have more to give; the resumption
-- cursor must name the last row the statement returned regardless of whether it produced an
-- event, or the next page would re-read it.
--
-- The classification is the 'ChangeKind' Haddock's rule. A row whose creation and deletion
-- both became visible here is a net no-op for the live set and is skipped: no consumer of
-- this feed — cache invalidation, index sync, revocation — has anything to do about a grant
-- that appeared and vanished between two snapshots it never observed.
changePageFromRows :: Int64 -> Int -> [ChangeRow] -> ChangePage
changePageFromRows cursorId limit rows =
  let (visibleRows, extraRows) = splitAt (max 0 limit) rows
      pageState =
        case extraRows of
          [] -> Exhausted
          _ : _ ->
            case reverse visibleRows of
              [] -> HasMore (StoreCursor (Text.pack (show cursorId)))
              (lastRow, _, _) : _ -> HasMore (StoreCursor lastRow.rowId.rowIdEncoding)
   in ChangePage {changes = concatMap classify visibleRows, state = pageState}
  where
    classify (row, createdInWindow, deletedInWindow)
      | deletedInWindow && createdInWindow = []
      | deletedInWindow = [TupleChange {kind = ChangeDelete, tuple = row.tuple, rowId = row.rowId}]
      | otherwise = [TupleChange {kind = ChangeTouch, tuple = row.tuple, rowId = row.rowId}]

-- | Answer a point-membership question with one indexed read.
--
-- An empty candidate set cannot match anything, so it short-circuits without a
-- round trip rather than sending an empty @unnest@.
probeTuplesSession :: Revision -> ObjectRef -> RelationName -> [Subject] -> Session [TupleRow]
probeTuplesSession _ _ _ [] =
  pure []
probeTuplesSession revision object relation subjects =
  Session.statement (probeParams revision object relation subjects) probeTuplesStatement

-- | Split the @limit + 1@ fetched rows into a page and the cursor that resumes it.
--
-- The cursor is the last returned row's id, because the read statements resume with
-- @id > cursor@. A page that returns no rows — only reachable at @limit <= 0@ —
-- therefore has to hand back the caller's own cursor: naming the first unreturned
-- row would skip that row forever, losing it from an otherwise complete scan.
pageFromRows :: Int64 -> Int -> [TupleRow] -> TuplePage
pageFromRows cursorId limit rows =
  let (visibleRows, extraRows) = splitAt (max 0 limit) rows
      pageState =
        case extraRows of
          [] -> Exhausted
          _ : _ ->
            case visibleRows of
              [] -> HasMore (StoreCursor (Text.pack (show cursorId)))
              _ -> HasMore (StoreCursor (last visibleRows).rowId.rowIdEncoding)
   in TuplePage {rows = visibleRows, state = pageState}

data Anchor = Anchor
  { xid :: !Text,
    snapshot :: !Text
  }
  deriving stock (Eq, Show)

tokenFromAnchor :: ConsistencyConfig -> Anchor -> Either Text ConsistencyToken
tokenFromAnchor config anchor = do
  snapshot <- writeVisibleSnapshot anchor
  pure
    ( encodeToken
        TokenPayload
          { datastoreId = config.datastoreId,
            schemaHash = config.schemaHash,
            revision = Revision snapshot,
            expiresAt = Nothing
          }
    )

-- | The anchor's snapshot, adjusted so it sees the write and nothing else new.
--
-- Read-your-writes needs the write's own xid visible, and @pg_current_snapshot()@
-- was taken before that xid committed, so @xmax@ has to be raised past it.
--
-- But @xmax@ is the latest /completed/ xid plus one, so other transactions that had
-- been assigned an xid without committing can sit anywhere in
-- @[snapshot.xmax, xid)@. Raising @xmax@ over them without a word declares them
-- visible — not immediately (they contribute no rows while uncommitted) but the
-- moment they commit, at which point two reads at this one token disagree. A
-- snapshot names a fixed state of the world; its meaning cannot depend on when it
-- is read. So every xid in the raised gap except our own is listed in-progress,
-- which is exactly what it was when the anchor was taken.
--
-- @xmin@ is deliberately untouched: raising it would declare xids below it visible,
-- and the comparator only asks @xmax@ and @xip@ whether a transaction is in doubt.
-- 'renderPgSnapshot' sorts and dedupes @xip@. When @xid < snapshot.xmax@ the gap is
-- empty and this reduces to filtering our own xid out of @xip@.
writeVisibleSnapshot :: Anchor -> Either Text Text
writeVisibleSnapshot anchor =
  case (parsePgSnapshot anchor.snapshot, parseWord64 anchor.xid) of
    (Right snapshot, Just xid) ->
      let raisedXmax = max snapshot.xmax (succBounded xid)
          gap = [txid | txid <- [snapshot.xmax .. raisedXmax - 1], txid /= xid]
       in Right
            ( renderPgSnapshot
                snapshot
                  { xmax = raisedXmax,
                    xip = filter (/= xid) snapshot.xip <> gap
                  }
            )
    (Left err, _) -> Left ("write anchor snapshot did not parse: " <> err)
    (_, Nothing) -> Left ("write anchor xid did not parse: " <> anchor.xid)

succBounded :: Word64 -> Word64
succBounded value
  | value == maxBound = maxBound
  | otherwise = value + 1

beginScript :: Text
beginScript =
  """
  BEGIN
  """

commitScript :: Text
commitScript =
  """
  COMMIT
  """

rollbackScript :: Text
rollbackScript =
  """
  ROLLBACK
  """

anchorTransactionStatement :: Statement Text Anchor
anchorTransactionStatement =
  Statement.preparable
    """
    WITH anchor AS (
      INSERT INTO en_transaction (xid, snapshot, schema_hash)
      VALUES (pg_current_xact_id(), pg_current_snapshot(), $1)
      ON CONFLICT (xid) DO UPDATE SET schema_hash = EXCLUDED.schema_hash
      RETURNING xid::text, snapshot::text
    )
    SELECT xid, snapshot FROM anchor
    """
    (Encoders.param (Encoders.nonNullable Encoders.text))
    ( Decoders.singleRow
        ( Anchor
            <$> Decoders.column (Decoders.nonNullable Decoders.text)
            <*> Decoders.column (Decoders.nonNullable Decoders.text)
        )
    )

currentSnapshotStatement :: Statement () Text
currentSnapshotStatement =
  Statement.preparable
    """
    SELECT pg_current_snapshot()::text
    """
    Encoders.noParams
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.text)))

-- | The garbage-collection horizon token validation reads: the greater of the
-- durable high-water mark ('en_gc_horizon') and the freshly computed horizon.
--
-- The fresh term is @coalesce(min(xid), pg_snapshot_xmin(pg_current_snapshot()))@
-- over @en_transaction@ rows inside @EN_GC_WINDOW@ — the @min(xid)@ branch rises as
-- rows age out, and the @coalesce@ fallback answers on an empty window. That fallback
-- can /fall/, because a long-running open transaction pins @pg_snapshot_xmin@ low
-- (see @docs/plans/60@ Milestone 4, and @runHorizonMonotonicityScenario@). Clamping
-- up to the high-water mark is what makes the served horizon monotone: the mark holds
-- the greatest horizon ever published, so this query never returns a value below one
-- the reaper already reaped at.
--
-- This statement only /reads/ the mark; the reaper advances it
-- ('advanceGcHorizonStatement'). Keeping validation write-free keeps the read path —
-- every @atExactSnapshot@ and @atLeastAsFresh@ request — off the single-row lock the
-- @UPDATE@ takes.
oldestRetainedXidStatement :: Statement Text Int64
oldestRetainedXidStatement =
  Statement.preparable
    """
    SELECT GREATEST(
             (SELECT horizon FROM en_gc_horizon),
             coalesce(min(xid), pg_snapshot_xmin(pg_current_snapshot()))::text::bigint
           )
    FROM en_transaction
    WHERE created_at >= now() - $1::interval
    """
    (Encoders.param (Encoders.nonNullable Encoders.text))
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

-- | Advance the durable high-water mark to @GREATEST(mark, fresh)@ and return the
-- new value, in one statement.
--
-- @fresh@ is the same term 'oldestRetainedXidStatement' computes; @GREATEST@ makes the
-- advance monotone regardless of how two racing reapers interleave — each takes the
-- single row's lock, and neither can lower it. The reaper reaps and prunes at exactly
-- the returned value, and because this @UPDATE@ commits before the reap runs, token
-- validation's read of the mark is always bounded below by every reap already done.
advanceGcHorizonStatement :: Statement Text Int64
advanceGcHorizonStatement =
  Statement.preparable
    """
    WITH fresh AS (
      SELECT coalesce(min(xid), pg_snapshot_xmin(pg_current_snapshot()))::text::bigint AS horizon
      FROM en_transaction
      WHERE created_at >= now() - $1::interval
    )
    UPDATE en_gc_horizon g
    SET horizon = GREATEST(g.horizon, fresh.horizon)
    FROM fresh
    RETURNING g.horizon
    """
    (Encoders.param (Encoders.nonNullable Encoders.text))
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

reapDeletedTuplesStatement :: Statement Text Int64
reapDeletedTuplesStatement =
  Statement.preparable
    """
    WITH reaped AS (
      DELETE FROM relation_tuple
      WHERE deleted_xid IS NOT NULL
        AND deleted_xid < $1::xid8
      RETURNING id
    )
    SELECT count(*) FROM reaped
    """
    (Encoders.param (Encoders.nonNullable Encoders.text))
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

-- | Victims are chosen in a CTE, then deleted by joining back on their @ctid@.
-- @LIMIT@ cannot appear directly on a @DELETE@, so the join back is unavoidable.
--
-- @relation_tuple_deleted_xid_idx@ (a partial index on @deleted_xid@ where it is not
-- null) serves the victim scan.
--
-- The join back is on @ctid@, the physical tuple address, and not on the primary key.
-- Keyed on @id@, PostgreSQL hash-joins the thousand victims against a sequential scan
-- of the whole table: it prices a thousand cached primary-key probes above one scan
-- (estimated 6903 against 6684) and picks the scan. That is 27 ms per batch on a
-- 250,000-row table, and 'reapDeletedTuplesBatchSession' is drained in a loop, so a
-- backlog of @B@ rows costs @B/batch@ sequential scans — quadratic in table size, and
-- the reaper is exactly the thing that runs when the table is large. Keyed on @ctid@
-- the plan is a nested loop over a @Tid Scan@, 1.1 ms for the same batch.
--
-- The @ctid@ form is self-correcting rather than immune. A tid lookup fetches one page,
-- so the nested loop's cost barely grows with the table while the sequential scan's
-- grows linearly; the planner therefore takes the tid path exactly when the table is
-- big enough for the scan to hurt. On a small table it still hash-joins — which is why
-- the integration fixture cannot assert the plan shape, and why this statement's cost
-- is argued from an @EXPLAIN@ against a populated database (see
-- @docs/plans/49-trim-dead-indexes-and-resolve-consistency-lazily.md@).
--
-- A @ctid@ is only safe to carry across a statement boundary if the tuple cannot move,
-- and here it cannot. Both writers that set @deleted_xid@
-- ('batchTouchReplaceStatement', 'batchDeleteTupleStatement') restrict their @UPDATE@
-- to rows where @deleted_xid IS NULL@, so a soft-deleted row is never updated again and
-- never migrates to a new tuple address. Nor can @VACUUM@ recycle the line pointer
-- underneath us: the victim CTE and the @DELETE@ execute inside one statement under one
-- snapshot, and vacuum cannot reclaim a tuple that snapshot can still see. A racing
-- second reaper is likewise harmless — it deletes the row first, and this statement's
-- @Tid Scan@ simply finds nothing there, exactly as the @id@ join would have.
reapDeletedTuplesBatchStatement :: Statement (Text, Int64) Int64
reapDeletedTuplesBatchStatement =
  Statement.preparable
    """
    WITH victims AS (
      SELECT ctid FROM relation_tuple
      WHERE deleted_xid IS NOT NULL
        AND deleted_xid < $1::xid8
      LIMIT $2
    ), reaped AS (
      DELETE FROM relation_tuple t
      USING victims v
      WHERE t.ctid = v.ctid
      RETURNING t.id
    )
    SELECT count(*) FROM reaped
    """
    (horizonAndBatchEncoder)
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

-- | Victims are chosen by @en_transaction@'s primary key, @xid@, and deleted by
-- joining back on their @ctid@.
--
-- The same planner trap 'reapDeletedTuplesBatchStatement' documents, and the same fix:
-- joined on @xid@ this hash-joins a thousand victims against a sequential scan of the
-- whole table (21 ms per batch once @en_transaction@ holds 250,000 rows, which it
-- reaches at one row per write transaction), and joined on @ctid@ it is a @Tid Scan@ at
-- 1.9 ms. @en_transaction@ rows are inserted once and never updated, so their tuple
-- addresses are stable for the same reason.
pruneTransactionsBatchStatement :: Statement (Text, Int64) Int64
pruneTransactionsBatchStatement =
  Statement.preparable
    """
    WITH victims AS (
      SELECT ctid FROM en_transaction
      WHERE xid < $1::xid8
      LIMIT $2
    ), pruned AS (
      DELETE FROM en_transaction t
      USING victims v
      WHERE t.ctid = v.ctid
      RETURNING t.xid
    )
    SELECT count(*) FROM pruned
    """
    (horizonAndBatchEncoder)
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

-- | The horizon travels as text and is cast to @xid8@ in SQL, matching
-- 'reapDeletedTuplesStatement': hasql has no @xid8@ encoder, and an @xid8@ does not fit
-- a signed @int8@ near wraparound.
horizonAndBatchEncoder :: Encoders.Params (Text, Int64)
horizonAndBatchEncoder =
  (fst >$< Encoders.param (Encoders.nonNullable Encoders.text))
    <> (snd >$< Encoders.param (Encoders.nonNullable Encoders.int8))

data TupleInsertParams = TupleInsertParams
  { createdXid :: !Text,
    objectType :: !Text,
    objectId :: !Text,
    relation :: !Text,
    subjectType :: !Text,
    subjectId :: !Text,
    subjectRelation :: !(Maybe Text),
    caveatName :: !(Maybe Text),
    caveatPayload :: !(Maybe LazyByteString.ByteString)
  }

tupleInsertParams :: Text -> Tuple -> TupleInsertParams
tupleInsertParams createdXid tuple =
  let (subjectObject, subjectRelation) = flattenSubject tuple.subject
      (maybeCaveatName, maybePayload) = flattenCaveat tuple.caveat
   in TupleInsertParams
        { createdXid = createdXid,
          objectType = unObjectType tuple.object.objectType,
          objectId = tuple.object.objectId,
          relation = unRelationName tuple.relation,
          subjectType = unObjectType subjectObject.objectType,
          subjectId = subjectObject.objectId,
          subjectRelation = unRelationName <$> subjectRelation,
          caveatName = unCaveatName <$> maybeCaveatName,
          caveatPayload = Aeson.encode . caveatPayloadToJson <$> maybePayload
        }

-- | One batch's columns, each as a PostgreSQL array.
--
-- The arrays are parallel: index @i@ of every array describes tuple @i@. A
-- statement rebuilds the rowset server-side with @unnest@ over all eight, which is
-- why they must be transposed from the tuple list rather than built independently.
data BatchParams = BatchParams
  { writeXid :: !Text,
    objectTypes :: ![Text],
    objectIds :: ![Text],
    relations :: ![Text],
    subjectTypes :: ![Text],
    subjectIds :: ![Text],
    subjectRelations :: ![Maybe Text],
    caveatNames :: ![Maybe Text],
    caveatPayloads :: ![Maybe LazyByteString.ByteString]
  }

batchParams :: Text -> [Tuple] -> BatchParams
batchParams writeXid tuples =
  let rows = tupleInsertParams writeXid <$> tuples
   in BatchParams
        { writeXid = writeXid,
          objectTypes = (\row -> row.objectType) <$> rows,
          objectIds = (\row -> row.objectId) <$> rows,
          relations = (\row -> row.relation) <$> rows,
          subjectTypes = (\row -> row.subjectType) <$> rows,
          subjectIds = (\row -> row.subjectId) <$> rows,
          subjectRelations = (\row -> row.subjectRelation) <$> rows,
          caveatNames = (\row -> row.caveatName) <$> rows,
          caveatPayloads = (\row -> row.caveatPayload) <$> rows
        }

-- | The @FROM@ clause every batch statement rebuilds its rowset from.
--
-- Spelled once and spliced into each statement, because the eight parameter
-- positions and the eight column names must agree across all of them, and a reader
-- checking that they do should not have to compare four transcriptions. The
-- parameter numbers are fixed: statements that also take the write xid put it last,
-- so this fragment always begins at @$1@.
--
-- Fragments are joined with 'Text.unlines' rather than @<>@ so that no splice can
-- run two SQL tokens together.
batchRowsetFrom :: Text
batchRowsetFrom =
  """
  FROM unnest($1::text[], $2::text[], $3::text[], $4::text[], $5::text[],
              $6::text[], $7::text[], $8::jsonb[])
    AS w(object_type, object_id, relation, subject_type, subject_id,
         subject_relation, caveat_name, caveat_payload)
  """

-- | 'batchRowsetFrom' with the extra column @WITH ORDINALITY@ appends.
batchRowsetFromWithOrdinality :: Text
batchRowsetFromWithOrdinality =
  """
  FROM unnest($1::text[], $2::text[], $3::text[], $4::text[], $5::text[],
              $6::text[], $7::text[], $8::jsonb[]) WITH ORDINALITY
    AS w(object_type, object_id, relation, subject_type, subject_id,
         subject_relation, caveat_name, caveat_payload, ordinality)
  """

-- | The predicate matching the live row that holds a batch entry's identity.
--
-- Written against the alias @r@ — the relation being /probed/ — because every batch
-- statement reaches @relation_tuple@ through a @LATERAL@ subquery driven by the
-- unnested batch, never as a bare join. See 'lateralProbe'.
batchIdentityMatch :: Text
batchIdentityMatch =
  """
  r.object_type = w.object_type
    AND r.object_id = w.object_id
    AND r.relation = w.relation
    AND r.subject_type = w.subject_type
    AND r.subject_id = w.subject_id
    AND coalesce(r.subject_relation, '') = coalesce(w.subject_relation, '')
    AND r.deleted_xid IS NULL
  """

-- | Probe @relation_tuple@ for one batch entry's live row, inside a @LATERAL@.
--
-- Every batch statement must find its rows this way rather than by joining
-- @relation_tuple@ against the unnested batch directly. A @Function Scan@ carries
-- no statistics, so the planner guesses at the batch's shape; past roughly a
-- thousand entries it abandons the nested loop over 'relation_tuple_live_unique'
-- and picks a merge join instead, keyed on whichever index it can scan in order.
--
-- That index is @relation_tuple_subject_hist_idx@, whose columns are the subject
-- and the object /type/ — not the object id. So the merge condition matches every
-- pair of rows that share a subject, and @object_id@ is demoted to a join filter.
-- For a bulk import, where thousands of objects share one subject, that is the
-- cross product: measured at 500,000,000 filtered pairs and 56 seconds for a single
-- 5,000-tuple statement against a 100,000-row table, against 14 milliseconds for
-- the @LATERAL@ form. The crossover sat between batches of 1,000 and 2,000 — with
-- @EN_MAX_BATCH_SIZE@ defaulting to 1,000, an operator raising it slightly would
-- have bought a table scan per write.
--
-- The @LATERAL@ removes the choice: the unnested batch is always the outer
-- relation, and each entry probes the unique index once. @LIMIT 1@ is exact rather
-- than defensive — @relation_tuple_live_unique@ admits one live row per identity —
-- and it is also what keeps the planner from flattening the subquery back into the
-- join this exists to prevent.
lateralProbe :: Text -> Text
lateralProbe extraPredicate =
  Text.unlines
    [ "SELECT r.id FROM relation_tuple r WHERE",
      batchIdentityMatch,
      extraPredicate,
      "LIMIT 1"
    ]

-- | Retire every live row that shares a batch entry's identity but carries a
-- different caveat.
--
-- @IS DISTINCT FROM@ is null-safe, so an uncaveated row compares as different from
-- a caveated one; @jsonb@ inequality is structural, so re-encoding an equal payload
-- with different key order or whitespace does not count as a change. A live row
-- identical to its batch entry therefore matches nothing here and keeps its
-- original @created_xid@ — an idempotent rewrite does not churn history.
--
-- @relation_tuple_live_unique@ bounds each entry to at most one matching live row,
-- and 'dedupeWrites' bounds each live row to at most one matching entry, so no
-- target row is reached twice.
batchTouchReplaceStatement :: Statement BatchParams ()
batchTouchReplaceStatement =
  Statement.preparable
    ( Text.unlines
        [ "UPDATE relation_tuple AS t SET deleted_xid = $9::xid8 FROM (",
          "SELECT victim.id",
          batchRowsetFrom,
          "CROSS JOIN LATERAL (",
          lateralProbe
            """
            AND (r.caveat_name IS DISTINCT FROM w.caveat_name
                 OR r.caveat_payload IS DISTINCT FROM w.caveat_payload)
            """,
          ") AS victim",
          ") AS victims",
          "WHERE t.id = victims.id"
        ]
    )
    batchWriteEncoder
    Decoders.noResult

-- | Insert the batch, tolerating conflicts with identical live rows.
--
-- After 'batchTouchReplaceStatement' the only live row that can still conflict with
-- an entry is one byte-identical to it, so @DO NOTHING@ means "already present"
-- rather than "silently dropped" — except under the cross-transaction race
-- 'batchTouchTuples' documents, which is why the caller verifies rather than
-- assumes.
batchInsertTupleStatement :: Statement BatchParams ()
batchInsertTupleStatement =
  Statement.preparable
    (Text.unlines [batchInsertSql, "ON CONFLICT DO NOTHING"])
    batchWriteEncoder
    Decoders.noResult

-- | Insert the batch, letting a conflict raise.
--
-- 'batchTouchTuples' falls back to this when its bounded retry has not converged: a
-- @unique_violation@ surfaces as 'En.Error.StoreError', which is the honest report
-- of a write that could not be applied. The alternative — one more @DO NOTHING@ —
-- would drop the caller's write and return a success token.
batchInsertTupleStrictStatement :: Statement BatchParams ()
batchInsertTupleStrictStatement =
  Statement.preparable
    batchInsertSql
    batchWriteEncoder
    Decoders.noResult

batchInsertSql :: Text
batchInsertSql =
  Text.unlines
    [ """
      INSERT INTO relation_tuple
        (object_type, object_id, relation, subject_type, subject_id, subject_relation, caveat_name, caveat_payload, created_xid)
      SELECT w.object_type, w.object_id, w.relation, w.subject_type, w.subject_id,
             w.subject_relation, w.caveat_name, w.caveat_payload, $9::xid8
      """,
      batchRowsetFrom
    ]

-- | The one-based ordinals of the batch entries that no live row satisfies.
--
-- An entry is satisfied when a live row holds its identity /and/ its caveat. The
-- entry's own insert produces such a row, and so does a pre-existing identical row,
-- so this one question answers both halves of the touch protocol at once.
--
-- @WITH ORDINALITY@ numbers the unnested rows so the caller can map an unsatisfied
-- entry back to the tuple that produced it without shipping the tuple's columns
-- home again.
--
-- Spelled as a @LEFT JOIN LATERAL@ that keeps the misses rather than as
-- @NOT EXISTS@, for the reason 'lateralProbe' gives: the planner turns the latter
-- into a hash anti join that builds a hash of every live row in the table, however
-- few entries the batch holds.
batchUnconvergedStatement :: Statement BatchParams [Int64]
batchUnconvergedStatement =
  Statement.preparable
    ( Text.unlines
        [ "SELECT w.ordinality",
          batchRowsetFromWithOrdinality,
          "LEFT JOIN LATERAL (",
          lateralProbe
            """
            AND r.caveat_name IS NOT DISTINCT FROM w.caveat_name
            AND r.caveat_payload IS NOT DISTINCT FROM w.caveat_payload
            """,
          ") AS satisfied ON TRUE",
          "WHERE satisfied.id IS NULL",
          "ORDER BY w.ordinality"
        ]
    )
    batchColumnsEncoder
    (Decoders.rowList (Decoders.column (Decoders.nonNullable Decoders.int8)))

-- | Retire the live grant for each batch identity, whatever caveat it carries.
--
-- The request's caveats are ignored, and so are the caveat arrays: this statement
-- takes only the six identity columns. With one live row per identity, matching on
-- @caveat_name@ would mean a caller who supplies yesterday's caveat name deletes
-- nothing and is told it succeeded — the same silent no-op that touch semantics
-- removes from the write path.
--
-- A duplicate identity in one batch names the same target row twice; @UPDATE …
-- FROM@ reaches it once, and the @deleted_xid@ it would assign is the same either
-- way. Deletes therefore need no deduplication.
--
-- Driven from the unnested batch through a @LATERAL@ probe for the reason
-- 'lateralProbe' gives.
batchDeleteTupleStatement :: Statement BatchParams ()
batchDeleteTupleStatement =
  Statement.preparable
    """
    UPDATE relation_tuple AS t
    SET deleted_xid = $7::xid8
    FROM (
      SELECT victim.id
      FROM unnest($1::text[], $2::text[], $3::text[], $4::text[], $5::text[], $6::text[])
        AS w(object_type, object_id, relation, subject_type, subject_id, subject_relation)
      CROSS JOIN LATERAL (
        SELECT r.id
        FROM relation_tuple r
        WHERE r.object_type = w.object_type
          AND r.object_id = w.object_id
          AND r.relation = w.relation
          AND r.subject_type = w.subject_type
          AND r.subject_id = w.subject_id
          AND coalesce(r.subject_relation, '') = coalesce(w.subject_relation, '')
          AND r.deleted_xid IS NULL
        LIMIT 1
      ) AS victim
    ) AS victims
    WHERE t.id = victims.id
    """
    batchDeleteEncoder
    Decoders.noResult

-- | The batch's eight column arrays, @$1@–@$8@.
--
-- Statements that also write take the xid as @$9@ (see 'batchWriteEncoder'); the
-- convergence check reads nothing new and stops here. An unreferenced parameter has
-- no inferable type, so it cannot simply be sent and ignored.
batchColumnsEncoder :: Encoders.Params BatchParams
batchColumnsEncoder =
  ((\params -> params.objectTypes) >$< Encoders.param (Encoders.nonNullable textArrayEncoder))
    <> ((\params -> params.objectIds) >$< Encoders.param (Encoders.nonNullable textArrayEncoder))
    <> ((\params -> params.relations) >$< Encoders.param (Encoders.nonNullable textArrayEncoder))
    <> ((\params -> params.subjectTypes) >$< Encoders.param (Encoders.nonNullable textArrayEncoder))
    <> ((\params -> params.subjectIds) >$< Encoders.param (Encoders.nonNullable textArrayEncoder))
    <> ((\params -> params.subjectRelations) >$< Encoders.param (Encoders.nonNullable nullableTextArrayEncoder))
    <> ((\params -> params.caveatNames) >$< Encoders.param (Encoders.nonNullable nullableTextArrayEncoder))
    <> ((\params -> params.caveatPayloads) >$< Encoders.param (Encoders.nonNullable nullableJsonbArrayEncoder))

-- | 'batchColumnsEncoder' plus the write transaction's xid as @$9@.
batchWriteEncoder :: Encoders.Params BatchParams
batchWriteEncoder =
  batchColumnsEncoder
    <> ((\params -> params.writeXid) >$< Encoders.param (Encoders.nonNullable Encoders.text))

-- | The six identity arrays, @$1@–@$6@, plus the write transaction's xid as @$7@.
batchDeleteEncoder :: Encoders.Params BatchParams
batchDeleteEncoder =
  ((\params -> params.objectTypes) >$< Encoders.param (Encoders.nonNullable textArrayEncoder))
    <> ((\params -> params.objectIds) >$< Encoders.param (Encoders.nonNullable textArrayEncoder))
    <> ((\params -> params.relations) >$< Encoders.param (Encoders.nonNullable textArrayEncoder))
    <> ((\params -> params.subjectTypes) >$< Encoders.param (Encoders.nonNullable textArrayEncoder))
    <> ((\params -> params.subjectIds) >$< Encoders.param (Encoders.nonNullable textArrayEncoder))
    <> ((\params -> params.subjectRelations) >$< Encoders.param (Encoders.nonNullable nullableTextArrayEncoder))
    <> ((\params -> params.writeXid) >$< Encoders.param (Encoders.nonNullable Encoders.text))

-- | A 'TupleFilter' flattened for the wire.
--
-- The subject-relation constraint travels as a mode plus an optional name rather
-- than a nullable name, because SQL @NULL@ cannot distinguish "unconstrained" from
-- "the subject must carry no relation" — the distinction 'SubjectRelationFilter'
-- exists to make.
data TupleFilterParams = TupleFilterParams
  { objectType :: !Text,
    objectId :: !(Maybe Text),
    relation :: !(Maybe Text),
    subjectType :: !(Maybe Text),
    subjectId :: !(Maybe Text),
    subjectRelationMode :: !Text,
    subjectRelationName :: !(Maybe Text)
  }

tupleFilterParams :: TupleFilter -> TupleFilterParams
tupleFilterParams tupleFilter =
  TupleFilterParams
    { objectType = unObjectType tupleFilter.objectType,
      objectId = tupleFilter.objectId,
      relation = unRelationName <$> tupleFilter.relation,
      subjectType = unObjectType <$> tupleFilter.subjectType,
      subjectId = tupleFilter.subjectId,
      subjectRelationMode = mode,
      subjectRelationName = name
    }
  where
    (mode, name) =
      case tupleFilter.subjectRelation of
        AnySubjectRelation -> ("any", Nothing)
        NoSubjectRelation -> ("none", Nothing)
        ExactSubjectRelation relationName -> ("exact", Just (unRelationName relationName))

tupleFilterEncoder :: Encoders.Params TupleFilterParams
tupleFilterEncoder =
  ((\params -> params.objectType) >$< Encoders.param (Encoders.nonNullable Encoders.text))
    <> ((\params -> params.objectId) >$< Encoders.param (Encoders.nullable Encoders.text))
    <> ((\params -> params.relation) >$< Encoders.param (Encoders.nullable Encoders.text))
    <> ((\params -> params.subjectType) >$< Encoders.param (Encoders.nullable Encoders.text))
    <> ((\params -> params.subjectId) >$< Encoders.param (Encoders.nullable Encoders.text))
    <> ((\params -> params.subjectRelationMode) >$< Encoders.param (Encoders.nonNullable Encoders.text))
    <> ((\params -> params.subjectRelationName) >$< Encoders.param (Encoders.nullable Encoders.text))

-- | Find one live row the filter matches and hold an exclusive lock on it until
-- the write transaction ends.
--
-- The lock is the whole point: it serializes the transactions that guard on this
-- row, so exactly one of two racing writers wins. See 'preconditionHolds' for why
-- it must be @FOR UPDATE@ and not @FOR SHARE@.
--
-- The filter predicate is spelled out here and again in
-- 'matchingLiveTupleExistsStatement' rather than shared as a spliced fragment. The
-- two must agree, and a reader checking that they do would rather read two whole
-- statements than reassemble them.
lockMatchingLiveTupleStatement :: Statement TupleFilterParams (Maybe Int64)
lockMatchingLiveTupleStatement =
  Statement.preparable
    """
    SELECT id
    FROM relation_tuple
    WHERE object_type = $1
      AND ($2::text IS NULL OR object_id = $2)
      AND ($3::text IS NULL OR relation = $3)
      AND ($4::text IS NULL OR subject_type = $4)
      AND ($5::text IS NULL OR subject_id = $5)
      AND ( $6 = 'any'
            OR ($6 = 'none' AND subject_relation IS NULL)
            OR ($6 = 'exact' AND subject_relation = $7) )
      AND deleted_xid IS NULL
    LIMIT 1
    FOR UPDATE
    """
    tupleFilterEncoder
    (Decoders.rowMaybe (Decoders.column (Decoders.nonNullable Decoders.int8)))

-- | Whether any live row matches the filter.
--
-- Absent rows cannot be locked, so a must-not-exist precondition takes no lock. A
-- racing insert of the same identity is caught instead by
-- @relation_tuple_live_unique@, which turns it into a unique-violation rather than
-- a silent duplicate.
matchingLiveTupleExistsStatement :: Statement TupleFilterParams Bool
matchingLiveTupleExistsStatement =
  Statement.preparable
    """
    SELECT EXISTS (
      SELECT 1
      FROM relation_tuple
      WHERE object_type = $1
        AND ($2::text IS NULL OR object_id = $2)
        AND ($3::text IS NULL OR relation = $3)
        AND ($4::text IS NULL OR subject_type = $4)
        AND ($5::text IS NULL OR subject_id = $5)
        AND ( $6 = 'any'
              OR ($6 = 'none' AND subject_relation IS NULL)
              OR ($6 = 'exact' AND subject_relation = $7) )
        AND deleted_xid IS NULL
    )
    """
    tupleFilterEncoder
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.bool)))

data ReadParams = ReadParams
  { revision :: !Text,
    objectType :: !Text,
    relation :: !Text,
    subjectTypes :: ![Text],
    subjectIds :: ![Text],
    subjectRelations :: ![Text],
    limit :: !Int64,
    cursor :: !Int64
  }

readParams :: Revision -> UsersetQuery -> Int64 -> Int64 -> ReadParams
readParams revision query limitPlusOne cursorId =
  let keys = subjectKeys query.querySubjects
   in ReadParams
        { revision = revision.revisionEncoding,
          objectType = unObjectType query.queryType,
          relation = unRelationName query.queryRelation,
          subjectTypes = (\(subjectType, _, _) -> subjectType) <$> keys,
          subjectIds = (\(_, subjectId, _) -> subjectId) <$> keys,
          subjectRelations = (\(_, _, subjectRelation) -> subjectRelation) <$> keys,
          limit = limitPlusOne,
          cursor = cursorId
        }

data ObjectReadParams = ObjectReadParams
  { revision :: !Text,
    objectType :: !Text,
    objectId :: !Text,
    relation :: !Text,
    limit :: !Int64,
    cursor :: !Int64
  }

objectReadParams :: Revision -> ObjectRef -> RelationName -> Int64 -> Int64 -> ObjectReadParams
objectReadParams revision object relation limitPlusOne cursorId =
  ObjectReadParams
    { revision = revision.revisionEncoding,
      objectType = unObjectType object.objectType,
      objectId = object.objectId,
      relation = unRelationName relation,
      limit = limitPlusOne,
      cursor = cursorId
    }

readObjectRelationStatement :: Statement ObjectReadParams [TupleRow]
readObjectRelationStatement =
  Statement.preparable
    """
    SELECT id, object_type, object_id, relation, subject_type, subject_id, subject_relation,
           caveat_name, caveat_payload, created_xid::text, deleted_xid::text
    FROM relation_tuple
    WHERE object_type = $2
      AND object_id = $3
      AND relation = $4
      AND id > $6
      AND pg_visible_in_snapshot(created_xid, $1::pg_snapshot)
      AND (deleted_xid IS NULL OR NOT pg_visible_in_snapshot(deleted_xid, $1::pg_snapshot))
    ORDER BY id ASC
    LIMIT $5
    """
    readObjectRelationEncoder
    (Decoders.rowList tupleRowDecoder)

readObjectRelationEncoder :: Encoders.Params ObjectReadParams
readObjectRelationEncoder =
  ((\params -> params.revision) >$< Encoders.param (Encoders.nonNullable Encoders.text))
    <> ((\params -> params.objectType) >$< Encoders.param (Encoders.nonNullable Encoders.text))
    <> ((\params -> params.objectId) >$< Encoders.param (Encoders.nonNullable Encoders.text))
    <> ((\params -> params.relation) >$< Encoders.param (Encoders.nonNullable Encoders.text))
    <> ((\params -> params.limit) >$< Encoders.param (Encoders.nonNullable Encoders.int8))
    <> ((\params -> params.cursor) >$< Encoders.param (Encoders.nonNullable Encoders.int8))

data AllReadParams = AllReadParams
  { revision :: !Text,
    limit :: !Int64,
    cursor :: !Int64
  }

allReadParams :: Revision -> Int64 -> Int64 -> AllReadParams
allReadParams revision limitPlusOne cursorId =
  AllReadParams
    { revision = revision.revisionEncoding,
      limit = limitPlusOne,
      cursor = cursorId
    }

-- | Every tuple live at the revision, one keyset page at a time.
--
-- 'readObjectRelationStatement' without the object and relation predicates. What is
-- left is a range scan over @relation_tuple@'s primary key, so the drain needs no
-- index of its own and none of the ones docs/plans/49 is reviewing.
--
-- Visibility is the same @pg_visible_in_snapshot@ pair every read uses, so a page
-- taken long after the revision was resolved still excludes every row committed
-- since — which is what makes a paged export a snapshot rather than a smear.
readAllTuplesStatement :: Statement AllReadParams [TupleRow]
readAllTuplesStatement =
  Statement.preparable
    """
    SELECT id, object_type, object_id, relation, subject_type, subject_id, subject_relation,
           caveat_name, caveat_payload, created_xid::text, deleted_xid::text
    FROM relation_tuple
    WHERE id > $3
      AND pg_visible_in_snapshot(created_xid, $1::pg_snapshot)
      AND (deleted_xid IS NULL OR NOT pg_visible_in_snapshot(deleted_xid, $1::pg_snapshot))
    ORDER BY id ASC
    LIMIT $2
    """
    ( ((\params -> params.revision) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\params -> params.limit) >$< Encoders.param (Encoders.nonNullable Encoders.int8))
        <> ((\params -> params.cursor) >$< Encoders.param (Encoders.nonNullable Encoders.int8))
    )
    (Decoders.rowList tupleRowDecoder)

data ProbeParams = ProbeParams
  { revision :: !Text,
    objectType :: !Text,
    objectId :: !Text,
    relation :: !Text,
    subjectTypes :: ![Text],
    subjectIds :: ![Text],
    subjectRelations :: ![Text]
  }

probeParams :: Revision -> ObjectRef -> RelationName -> [Subject] -> ProbeParams
probeParams revision object relation subjects =
  let keys = subjectKeys subjects
   in ProbeParams
        { revision = revision.revisionEncoding,
          objectType = unObjectType object.objectType,
          objectId = object.objectId,
          relation = unRelationName relation,
          subjectTypes = (\(subjectType, _, _) -> subjectType) <$> keys,
          subjectIds = (\(_, subjectId, _) -> subjectId) <$> keys,
          subjectRelations = (\(_, _, subjectRelation) -> subjectRelation) <$> keys
        }

-- | The probe carries no @LIMIT@: its result is bounded by the candidate-set
-- size times the number of distinct caveat names a grant can carry, which is
-- small by construction. Served by @relation_tuple_object_hist_idx@ (equality on
-- object_type, object_id, relation) or @relation_tuple_subject_hist_idx@; the
-- partial @*_live_idx@ indexes cannot serve it, because visibility is read
-- through @pg_visible_in_snapshot@ rather than @deleted_xid IS NULL@.
probeTuplesStatement :: Statement ProbeParams [TupleRow]
probeTuplesStatement =
  Statement.preparable
    """
    SELECT id, object_type, object_id, relation, subject_type, subject_id, subject_relation,
           caveat_name, caveat_payload, created_xid::text, deleted_xid::text
    FROM relation_tuple
    WHERE object_type = $2
      AND object_id = $3
      AND relation = $4
      AND (subject_type, subject_id, coalesce(subject_relation, '')) IN (
        SELECT * FROM unnest($5::text[], $6::text[], $7::text[])
      )
      AND pg_visible_in_snapshot(created_xid, $1::pg_snapshot)
      AND (deleted_xid IS NULL OR NOT pg_visible_in_snapshot(deleted_xid, $1::pg_snapshot))
    ORDER BY id ASC
    """
    probeEncoder
    (Decoders.rowList tupleRowDecoder)

probeEncoder :: Encoders.Params ProbeParams
probeEncoder =
  ((\params -> params.revision) >$< Encoders.param (Encoders.nonNullable Encoders.text))
    <> ((\params -> params.objectType) >$< Encoders.param (Encoders.nonNullable Encoders.text))
    <> ((\params -> params.objectId) >$< Encoders.param (Encoders.nonNullable Encoders.text))
    <> ((\params -> params.relation) >$< Encoders.param (Encoders.nonNullable Encoders.text))
    <> ((\params -> params.subjectTypes) >$< Encoders.param (Encoders.nonNullable textArrayEncoder))
    <> ((\params -> params.subjectIds) >$< Encoders.param (Encoders.nonNullable textArrayEncoder))
    <> ((\params -> params.subjectRelations) >$< Encoders.param (Encoders.nonNullable textArrayEncoder))

readStartingWithUserStatement :: Statement ReadParams [TupleRow]
readStartingWithUserStatement =
  Statement.preparable
    """
    SELECT id, object_type, object_id, relation, subject_type, subject_id, subject_relation,
           caveat_name, caveat_payload, created_xid::text, deleted_xid::text
    FROM relation_tuple
    WHERE object_type = $2
      AND relation = $3
      AND id > $8
      AND pg_visible_in_snapshot(created_xid, $1::pg_snapshot)
      AND (deleted_xid IS NULL OR NOT pg_visible_in_snapshot(deleted_xid, $1::pg_snapshot))
      AND (subject_type, subject_id, coalesce(subject_relation, '')) IN (
        SELECT * FROM unnest($4::text[], $5::text[], $6::text[])
      )
    ORDER BY id ASC
    LIMIT $7
    """
    readStartingWithUserEncoder
    (Decoders.rowList tupleRowDecoder)

readStartingWithUserEncoder :: Encoders.Params ReadParams
readStartingWithUserEncoder =
  ((\params -> params.revision) >$< Encoders.param (Encoders.nonNullable Encoders.text))
    <> ((\params -> params.objectType) >$< Encoders.param (Encoders.nonNullable Encoders.text))
    <> ((\params -> params.relation) >$< Encoders.param (Encoders.nonNullable Encoders.text))
    <> ((\params -> params.subjectTypes) >$< Encoders.param (Encoders.nonNullable textArrayEncoder))
    <> ((\params -> params.subjectIds) >$< Encoders.param (Encoders.nonNullable textArrayEncoder))
    <> ((\params -> params.subjectRelations) >$< Encoders.param (Encoders.nonNullable textArrayEncoder))
    <> ((\params -> params.limit) >$< Encoders.param (Encoders.nonNullable Encoders.int8))
    <> ((\params -> params.cursor) >$< Encoders.param (Encoders.nonNullable Encoders.int8))

textArrayEncoder :: Encoders.Value [Text]
textArrayEncoder =
  Encoders.foldableArray (Encoders.nonNullable Encoders.text)

-- | A @text[]@ whose elements may be SQL @NULL@.
--
-- The array itself is never null; its elements are. @subject_relation@ and
-- @caveat_name@ are both genuinely absent for most tuples, and an absent element
-- must arrive as @NULL@ rather than @''@ so the @coalesce@ and @IS DISTINCT FROM@
-- predicates mean what the per-row statements meant.
nullableTextArrayEncoder :: Encoders.Value [Maybe Text]
nullableTextArrayEncoder =
  Encoders.foldableArray (Encoders.nullable Encoders.text)

-- | A @jsonb[]@ whose elements may be SQL @NULL@: an uncaveated tuple has no payload.
nullableJsonbArrayEncoder :: Encoders.Value [Maybe LazyByteString.ByteString]
nullableJsonbArrayEncoder =
  Encoders.foldableArray (Encoders.nullable Encoders.jsonbLazyBytes)

tupleRowDecoder :: Decoders.Row TupleRow
tupleRowDecoder =
  rowFromColumns
    <$> Decoders.column (Decoders.nonNullable Decoders.int8)
    <*> Decoders.column (Decoders.nonNullable Decoders.text)
    <*> Decoders.column (Decoders.nonNullable Decoders.text)
    <*> Decoders.column (Decoders.nonNullable Decoders.text)
    <*> Decoders.column (Decoders.nonNullable Decoders.text)
    <*> Decoders.column (Decoders.nonNullable Decoders.text)
    <*> Decoders.column (Decoders.nullable Decoders.text)
    <*> Decoders.column (Decoders.nullable Decoders.text)
    <*> Decoders.column (Decoders.nullable caveatPayloadDecoder)
    <*> Decoders.column (Decoders.nonNullable Decoders.text)
    <*> Decoders.column (Decoders.nullable Decoders.text)

-- | Decode @caveat_payload@ all the way to its typed form, failing the statement
-- when it cannot.
--
-- A payload that no longer decodes is a corrupted authorization fact. Reading it as
-- an /empty/ payload — the previous behavior — does not degrade the answer, it
-- changes it: the caveat evaluator sees a grant whose parameters are all missing
-- and either demands them from the caller or evaluates a different condition than
-- the one that was written. Storage that cannot answer faithfully must refuse to
-- answer.
--
-- The check lives in the column decoder because that is the choke point every read
-- of the column passes through; a @Left@ here becomes a hasql @SessionError@, which
-- 'interpretTupleStorePostgres' already surfaces as 'En.Error.StoreError'.
caveatPayloadDecoder :: Decoders.Value (Map.Map Text CaveatValue)
caveatPayloadDecoder =
  Decoders.jsonbBytes
    ( \bytes ->
        case Aeson.decodeStrict bytes >>= decodeCaveatPayload of
          Just decoded -> Right decoded
          Nothing -> Left "undecodable caveat_payload"
    )

rowFromColumns ::
  Int64 ->
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  Maybe Text ->
  Maybe Text ->
  Maybe (Map.Map Text CaveatValue) ->
  Text ->
  Maybe Text ->
  TupleRow
rowFromColumns idValue objectType objectId relation subjectType subjectId subjectRelation caveatName caveatPayload createdXid deletedXid =
  TupleRow
    { pageKey = idValue,
      rowId = TupleRowId (Text.pack (show idValue)),
      tuple =
        Tuple
          { object = ObjectRef {objectType = ObjectType objectType, objectId = objectId},
            relation = RelationName relation,
            subject =
              case (subjectRelation, subjectId) of
                (Nothing, "*") -> SubjectWildcard (ObjectType subjectType)
                (Nothing, _) -> SubjectId subjectObject
                (Just relationName, _) -> SubjectSet subjectObject (RelationName relationName),
            caveat = decodeTupleCaveat caveatName caveatPayload
          },
      createdAt = Revision createdXid,
      deletedAt = Revision <$> deletedXid
    }
  where
    subjectObject = ObjectRef {objectType = ObjectType subjectType, objectId = subjectId}

-- | Pair a caveat name with its payload.
--
-- A SQL @NULL@ payload is a caveat with no write-time arguments — a legitimately
-- empty payload, not a missing one. An /undecodable/ payload never reaches here:
-- 'caveatPayloadDecoder' has already failed the statement.
decodeTupleCaveat :: Maybe Text -> Maybe (Map.Map Text CaveatValue) -> Maybe TupleCaveat
decodeTupleCaveat Nothing _ = Nothing
decodeTupleCaveat (Just caveatName) maybePayload =
  Just
    TupleCaveat
      { name = CaveatName caveatName,
        payload = CaveatPayload (fromMaybe Map.empty maybePayload)
      }

flattenSubject :: Subject -> (ObjectRef, Maybe RelationName)
flattenSubject =
  \case
    SubjectId objectRef -> (objectRef, Nothing)
    SubjectSet objectRef relationName -> (objectRef, Just relationName)
    SubjectWildcard objectType -> (ObjectRef {objectType, objectId = "*"}, Nothing)

flattenCaveat :: Maybe TupleCaveat -> (Maybe CaveatName, Maybe CaveatPayload)
flattenCaveat =
  \case
    Nothing -> (Nothing, Nothing)
    Just tupleCaveat -> (Just tupleCaveat.name, Just tupleCaveat.payload)

subjectKeys :: [Subject] -> [(Text, Text, Text)]
subjectKeys =
  fmap
    ( \subject ->
        let (objectRef, subjectRelation) = flattenSubject subject
         in (unObjectType objectRef.objectType, objectRef.objectId, maybe "" unRelationName subjectRelation)
    )

caveatPayloadToJson :: CaveatPayload -> Aeson.Value
caveatPayloadToJson (CaveatPayload values) =
  Aeson.object (fmap caveatEntry (Map.toList values))
  where
    caveatEntry (key, value) =
      AesonKey.fromText key Aeson..= caveatValueToJson value

caveatValueToJson :: CaveatValue -> Aeson.Value
caveatValueToJson =
  \case
    ValueText value -> taggedCaveatValue "text" value
    ValueBool value -> taggedCaveatValue "bool" value
    ValueInteger value -> taggedCaveatValue "integer" value
    ValueTimestamp value -> taggedCaveatValue "timestamp" value
    ValueEnum value -> taggedCaveatValue "enum" value

taggedCaveatValue :: (Aeson.ToJSON a) => Text -> a -> Aeson.Value
taggedCaveatValue valueType value =
  Aeson.object
    [ "type" Aeson..= valueType,
      "value" Aeson..= value
    ]

decodeCaveatPayload :: Aeson.Value -> Maybe (Map.Map Text CaveatValue)
decodeCaveatPayload =
  Aeson.parseMaybe
    ( Aeson.withObject
        "CaveatPayload"
        ( \object ->
            traverse decodeCaveatValue (Map.fromList [(AesonKey.toText key, value) | (key, value) <- AesonKeyMap.toList object])
        )
    )

decodeCaveatValue :: Aeson.Value -> Aeson.Parser CaveatValue
decodeCaveatValue =
  \case
    Aeson.Object object ->
      case AesonKeyMap.lookup "type" object of
        Just (Aeson.String "text") -> ValueText <$> object Aeson..: "value"
        Just (Aeson.String "bool") -> ValueBool <$> object Aeson..: "value"
        Just (Aeson.String "integer") -> ValueInteger <$> object Aeson..: "value"
        Just (Aeson.String "timestamp") -> ValueTimestamp <$> object Aeson..: "value"
        Just (Aeson.String "enum") -> ValueEnum <$> object Aeson..: "value"
        Just _ -> fail "unsupported tagged caveat value type"
        Nothing -> fail "tagged caveat value missing type"
    Aeson.String value -> pure (ValueText value)
    Aeson.Bool value -> pure (ValueBool value)
    Aeson.Number value ->
      case floatingOrInteger value of
        Right integer -> pure (ValueInteger integer)
        Left (_double :: Double) -> fail "expected integer caveat number"
    _ -> fail "unsupported caveat value"

parseWord64 :: Text -> Maybe Word64
parseWord64 text =
  case readDec (Text.unpack text) of
    [(value, "")] -> Just value
    _ -> Nothing

-- | The row id a cursor names. Only this store's own encoding is accepted.
decodeCursor :: StoreCursor -> Either EnError Int64
decodeCursor (StoreCursor cursorText) =
  case reads (Text.unpack cursorText) of
    [(value, "")] -> Right value
    _ -> Left (InvalidCursor cursorText)

unObjectType :: ObjectType -> Text
unObjectType (ObjectType text) = text

unRelationName :: RelationName -> Text
unRelationName (RelationName text) = text

unCaveatName :: CaveatName -> Text
unCaveatName (CaveatName text) = text
