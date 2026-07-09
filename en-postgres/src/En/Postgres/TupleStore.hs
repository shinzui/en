{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE MultilineStrings #-}
{-# LANGUAGE NoFieldSelectors #-}

-- | PostgreSQL-backed 'TupleStore'.
module En.Postgres.TupleStore (
    runTupleStorePostgres,
    runTupleStorePostgresWithOptimizedRevisionCache,
    runTupleStorePostgresWithOptimizedRevisionCacheHandle,
    reapDeletedTuplesSession,
    reapDeletedTuplesBatchSession,
    pruneTransactionsBatchSession,
) where

import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as AesonKey
import Data.Aeson.KeyMap qualified as AesonKeyMap
import Data.Aeson.Types qualified as Aeson
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (traverse_)
import Data.Functor.Contravariant ((>$<))
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Scientific (floatingOrInteger)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Data.Word (Word64)
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, throwError)

import En.Effect.TupleStore (
    PageState (..),
    StoreCursor (..),
    TuplePage (..),
    TupleRow (..),
    TupleRowId (..),
    TupleStore (..),
    UsersetQuery (..),
 )
import En.Error (EnError (..))
import En.Postgres.Database (Database, runSession)
import En.Postgres.Revision (
    ConsistencyConfig (..),
    OptimizedRevisionCache,
    OptimizedRevisionConfig,
    PgSnapshot (..),
    TokenPayload (..),
    encodeToken,
    lookupOptimizedRevisionCache,
    newOptimizedRevisionCache,
    parsePgSnapshot,
    renderPgSnapshot,
    storeOptimizedRevisionCache,
 )
import En.Revision (
    ConsistencyToken,
    Revision (..),
    SchemaHash (..),
 )
import En.Schema (CaveatName (..), ObjectType (..), RelationName (..))
import En.Tuple (
    CaveatPayload (..),
    CaveatValue (..),
    ObjectRef (..),
    Subject (..),
    Tuple (..),
    TupleCaveat (..),
 )
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Errors qualified as Hasql
import Hasql.Session (Session)
import Hasql.Session qualified as Session
import Hasql.Statement (Statement)
import Hasql.Statement qualified as Statement
import Numeric (readDec)

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
        ReadObjectRelation revision object relation limit cursor ->
            orThrow =<< runSession (readObjectRelationSession revision object relation limit cursor)
        ReadStartingWithUser revision query ->
            orThrow =<< runSession (readStartingWithUserSession revision query)
        ProbeTuples revision object relation subjects ->
            orThrow =<< runSession (probeTuplesSession revision object relation subjects)
        WriteTuples tuples ->
            orThrow =<< runSession (writeTuplesSession config tuples)
        DeleteTuples tuples ->
            orThrow =<< runSession (deleteTuplesSession config tuples)
        HeadRevision ->
            orThrow =<< runSession headRevisionSession
        OptimizedRevision ->
            readOptimizedRevision
        OldestRetainedXid ->
            orThrow =<< runSession (oldestRetainedXidSession config.gcWindow)
        ReapDeletedTuples horizon ->
            orThrow =<< runSession (reapDeletedTuplesSession horizon)
  where
    orThrow =
        either (throwError . StoreError . Hasql.toDetailedText) pure

uncachedOptimizedRevision ::
    (Database :> es, Error EnError :> es) =>
    Eff es Revision
uncachedOptimizedRevision =
    orThrow =<< runSession headRevisionSession
  where
    orThrow =
        either (throwError . StoreError . Hasql.toDetailedText) pure

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

{- | Write each tuple with touch semantics, then mint a token for the write.

A live tuple's identity is (object, relation, subject); its caveat is an
attribute of the grant, not part of its identity. So a write either inserts,
does nothing (the live row is already byte-identical), or retires the differing
live row and inserts the replacement — all inside this session's single
transaction, so no observer ever sees both rows live.

The same key appearing twice in one call resolves last-wins: the second tuple's
touch retires the first tuple's row, stamping @deleted_xid = created_xid@, which
is visible at no revision.
-}
writeTuplesSession :: ConsistencyConfig -> [Tuple] -> Session ConsistencyToken
writeTuplesSession config tuples = do
    Session.script beginScript
    anchor <- Session.statement schemaHashText anchorTransactionStatement
    traverse_ (touchTuple anchor.xid) tuples
    Session.script commitScript
    pure (tokenFromAnchor config anchor)
  where
    SchemaHash schemaHashText = config.schemaHash

{- | Apply touch semantics to one tuple.

Each attempt retires a live row that shares the tuple's identity but carries a
different caveat, then inserts. An insert that affects no row means /some/ live
row already holds the identity; that is a legitimate no-op only when the row is
byte-identical, which is checked rather than assumed.

Both statements run at their own @READ COMMITTED@ snapshot, so a concurrent
transaction that commits a differing caveat between them can make the pair
observe "nothing to retire" and "conflict" at once — the silent-drop bug this
protocol exists to remove, in racing form. A second attempt re-reads and retires
the racer's now-committed row. If even that does not converge, the final insert
omits @ON CONFLICT@ so PostgreSQL raises @unique_violation@ and the write fails
loudly instead of being dropped.
-}
touchTuple :: Text -> Tuple -> Session ()
touchTuple writeXid tuple = do
    converged <- attempt
    if converged
        then pure ()
        else do
            convergedOnRetry <- attempt
            if convergedOnRetry
                then pure ()
                else do
                    _ <- Session.statement params touchReplaceStatement
                    Session.statement params insertTupleStrictStatement
  where
    params = tupleInsertParams writeXid tuple

    attempt = do
        _ <- Session.statement params touchReplaceStatement
        inserted <- Session.statement params insertTupleStatement
        if inserted == 1
            then pure True
            else Session.statement params identicalLiveTupleStatement

deleteTuplesSession :: ConsistencyConfig -> [Tuple] -> Session ConsistencyToken
deleteTuplesSession config tuples = do
    Session.script beginScript
    anchor <- Session.statement schemaHashText anchorTransactionStatement
    traverse_ (\tuple -> Session.statement (tupleDeleteParams anchor.xid tuple) deleteTupleStatement) tuples
    Session.script commitScript
    pure (tokenFromAnchor config anchor)
  where
    SchemaHash schemaHashText = config.schemaHash

headRevisionSession :: Session Revision
headRevisionSession =
    Revision <$> Session.statement () currentSnapshotStatement

oldestRetainedXidSession :: Text -> Session Word64
oldestRetainedXidSession window =
    fromIntegral <$> Session.statement window oldestRetainedXidStatement

{- | Physically delete every soft-deleted tuple behind @horizon@ in one statement.

Retained for embedded consumers and the integration test. Background maintenance
should prefer 'reapDeletedTuplesBatchSession': one unbounded @DELETE@ holds row locks
for its whole duration and emits its write-ahead log in a single burst, both
proportional to the size of the backlog.
-}
reapDeletedTuplesSession :: Word64 -> Session Int64
reapDeletedTuplesSession horizon =
    Session.statement (Text.pack (show horizon)) reapDeletedTuplesStatement

{- | Physically delete at most @batch@ soft-deleted tuples whose delete is behind
@horizon@, returning how many were removed.

A tuple deleted before the garbage-collection horizon cannot be seen by any
consistency token that still validates (see @validateTokenMetadata@ in
"En.Postgres.Revision", which rejects tokens whose snapshot @xmax@ is at or below the
horizon), so its row can be removed.

Callers loop until a call returns fewer than @batch@. Each call is its own
transaction, so locks are released between batches and an interrupted loop leaves
every completed batch committed.
-}
reapDeletedTuplesBatchSession :: Word64 -> Int -> Session Int64
reapDeletedTuplesBatchSession horizon batch =
    Session.statement (Text.pack (show horizon), fromIntegral batch) reapDeletedTuplesBatchStatement

{- | Delete at most @batch@ @en_transaction@ rows behind @horizon@, returning how many
were removed.

Rows are selected by @xid < horizon@ rather than by re-deriving a cutoff from
@created_at@, so the pruner, the reaper, and token validation share one horizon and
cannot disagree. Because @horizon@ is @min(xid)@ over the rows inside the retention
window, no row inside the window is ever selected: every such row has
@xid >= horizon@ by construction.
-}
pruneTransactionsBatchSession :: Word64 -> Int -> Session Int64
pruneTransactionsBatchSession horizon batch =
    Session.statement (Text.pack (show horizon), fromIntegral batch) pruneTransactionsBatchStatement

readStartingWithUserSession :: Revision -> UsersetQuery -> Session TuplePage
readStartingWithUserSession revision query = do
    let limitPlusOne = fromIntegral (max 0 query.queryLimit + 1)
        cursorId = maybe 0 decodeCursor query.queryCursor
    rows <- Session.statement (readParams revision query limitPlusOne cursorId) readStartingWithUserStatement
    pure (pageFromRows query.queryLimit rows)

readObjectRelationSession :: Revision -> ObjectRef -> RelationName -> Int -> Maybe StoreCursor -> Session TuplePage
readObjectRelationSession revision object relation limit maybeCursor = do
    let limitPlusOne = fromIntegral (max 0 limit + 1)
        cursorId = maybe 0 decodeCursor maybeCursor
    rows <- Session.statement (objectReadParams revision object relation limitPlusOne cursorId) readObjectRelationStatement
    pure (pageFromRows limit rows)

{- | Answer a point-membership question with one indexed read.

An empty candidate set cannot match anything, so it short-circuits without a
round trip rather than sending an empty @unnest@.
-}
probeTuplesSession :: Revision -> ObjectRef -> RelationName -> [Subject] -> Session [TupleRow]
probeTuplesSession _ _ _ [] =
    pure []
probeTuplesSession revision object relation subjects =
    Session.statement (probeParams revision object relation subjects) probeTuplesStatement

pageFromRows :: Int -> [TupleRow] -> TuplePage
pageFromRows limit rows =
    let (visibleRows, extraRows) = splitAt (max 0 limit) rows
        pageState =
            case extraRows of
                [] -> Exhausted
                nextRow : _ ->
                    let cursorRow =
                            case visibleRows of
                                [] -> nextRow
                                _ -> last visibleRows
                     in HasMore (StoreCursor cursorRow.rowId.rowIdEncoding)
     in TuplePage{rows = visibleRows, state = pageState}

data Anchor = Anchor
    { xid :: !Text
    , snapshot :: !Text
    }
    deriving stock (Eq, Show)

tokenFromAnchor :: ConsistencyConfig -> Anchor -> ConsistencyToken
tokenFromAnchor config anchor =
    encodeToken
        TokenPayload
            { datastoreId = config.datastoreId
            , schemaHash = config.schemaHash
            , revision = Revision (writeVisibleSnapshot anchor)
            , expiresAt = Nothing
            }

writeVisibleSnapshot :: Anchor -> Text
writeVisibleSnapshot anchor =
    case (parsePgSnapshot anchor.snapshot, parseWord64 anchor.xid) of
        (Right snapshot, Just xid) ->
            renderPgSnapshot
                snapshot
                    { xmax = max snapshot.xmax (succBounded xid)
                    , xip = filter (/= xid) snapshot.xip
                    }
        _ -> anchor.snapshot

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

oldestRetainedXidStatement :: Statement Text Int64
oldestRetainedXidStatement =
    Statement.preparable
        """
        SELECT coalesce(min(xid), pg_snapshot_xmin(pg_current_snapshot()))::text::bigint
        FROM en_transaction
        WHERE created_at >= now() - $1::interval
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

{- | Victims are chosen by primary key in a CTE, then deleted by joining back on it.
@LIMIT@ cannot appear directly on a @DELETE@.

@relation_tuple_deleted_xid_idx@ (a partial index on @deleted_xid@ where it is not
null) serves the victim scan.
-}
reapDeletedTuplesBatchStatement :: Statement (Text, Int64) Int64
reapDeletedTuplesBatchStatement =
    Statement.preparable
        """
        WITH victims AS (
          SELECT id FROM relation_tuple
          WHERE deleted_xid IS NOT NULL
            AND deleted_xid < $1::xid8
          LIMIT $2
        ), reaped AS (
          DELETE FROM relation_tuple t
          USING victims v
          WHERE t.id = v.id
          RETURNING t.id
        )
        SELECT count(*) FROM reaped
        """
        (horizonAndBatchEncoder)
        (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

-- | Victims are chosen by @en_transaction@'s primary key, @xid@.
pruneTransactionsBatchStatement :: Statement (Text, Int64) Int64
pruneTransactionsBatchStatement =
    Statement.preparable
        """
        WITH victims AS (
          SELECT xid FROM en_transaction
          WHERE xid < $1::xid8
          LIMIT $2
        ), pruned AS (
          DELETE FROM en_transaction t
          USING victims v
          WHERE t.xid = v.xid
          RETURNING t.xid
        )
        SELECT count(*) FROM pruned
        """
        (horizonAndBatchEncoder)
        (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

{- | The horizon travels as text and is cast to @xid8@ in SQL, matching
'reapDeletedTuplesStatement': hasql has no @xid8@ encoder, and an @xid8@ does not fit
a signed @int8@ near wraparound.
-}
horizonAndBatchEncoder :: Encoders.Params (Text, Int64)
horizonAndBatchEncoder =
    (fst >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> (snd >$< Encoders.param (Encoders.nonNullable Encoders.int8))

data TupleInsertParams = TupleInsertParams
    { createdXid :: !Text
    , objectType :: !Text
    , objectId :: !Text
    , relation :: !Text
    , subjectType :: !Text
    , subjectId :: !Text
    , subjectRelation :: !(Maybe Text)
    , caveatName :: !(Maybe Text)
    , caveatPayload :: !(Maybe LazyByteString.ByteString)
    }

tupleInsertParams :: Text -> Tuple -> TupleInsertParams
tupleInsertParams createdXid tuple =
    let (subjectObject, subjectRelation) = flattenSubject tuple.subject
        (maybeCaveatName, maybePayload) = flattenCaveat tuple.caveat
     in TupleInsertParams
            { createdXid = createdXid
            , objectType = unObjectType tuple.object.objectType
            , objectId = tuple.object.objectId
            , relation = unRelationName tuple.relation
            , subjectType = unObjectType subjectObject.objectType
            , subjectId = subjectObject.objectId
            , subjectRelation = unRelationName <$> subjectRelation
            , caveatName = unCaveatName <$> maybeCaveatName
            , caveatPayload = Aeson.encode . caveatPayloadToJson <$> maybePayload
            }

{- | Retire the live row that shares the tuple's identity but carries a different
caveat, returning how many rows were retired (0 or 1, bounded by
@relation_tuple_live_unique@).

@IS DISTINCT FROM@ is null-safe, so an uncaveated row compares as different from
a caveated one; @jsonb@ inequality is structural, so re-encoding an equal payload
with different key order or whitespace does not count as a change. A live row
identical to the tuple therefore matches nothing here and keeps its original
@created_xid@ — an idempotent rewrite does not churn history.
-}
touchReplaceStatement :: Statement TupleInsertParams Int64
touchReplaceStatement =
    Statement.preparable
        """
        UPDATE relation_tuple
        SET deleted_xid = $1::xid8
        WHERE object_type = $2
          AND object_id = $3
          AND relation = $4
          AND subject_type = $5
          AND subject_id = $6
          AND coalesce(subject_relation, '') = coalesce($7, '')
          AND deleted_xid IS NULL
          AND (caveat_name IS DISTINCT FROM $8
               OR caveat_payload IS DISTINCT FROM $9::jsonb)
        """
        tupleInsertEncoder
        Decoders.rowsAffected

{- | Insert the tuple, tolerating a conflict with an identical live row.

After 'touchReplaceStatement' the only live row that can still conflict is one
byte-identical to the tuple, so @DO NOTHING@ means "already present" rather than
"silently dropped" — except under the cross-transaction race 'touchTuple'
documents, which is why the caller verifies rather than assumes.
-}
insertTupleStatement :: Statement TupleInsertParams Int64
insertTupleStatement =
    Statement.preparable
        """
        INSERT INTO relation_tuple
          (object_type, object_id, relation, subject_type, subject_id, subject_relation, caveat_name, caveat_payload, created_xid)
        VALUES ($2, $3, $4, $5, $6, $7, $8, $9, $1::xid8)
        ON CONFLICT DO NOTHING
        """
        tupleInsertEncoder
        Decoders.rowsAffected

{- | Insert the tuple, letting a conflict raise.

'touchTuple' falls back to this when its bounded retry has not converged: a
@unique_violation@ surfaces as 'En.Error.StoreError', which is the honest report
of a write that could not be applied. The alternative — one more @DO NOTHING@ —
would drop the caller's write and return a success token.
-}
insertTupleStrictStatement :: Statement TupleInsertParams ()
insertTupleStrictStatement =
    Statement.preparable
        """
        INSERT INTO relation_tuple
          (object_type, object_id, relation, subject_type, subject_id, subject_relation, caveat_name, caveat_payload, created_xid)
        VALUES ($2, $3, $4, $5, $6, $7, $8, $9, $1::xid8)
        """
        tupleInsertEncoder
        Decoders.noResult

-- | Whether a live row byte-identical to the tuple exists, caveat included.
identicalLiveTupleStatement :: Statement TupleInsertParams Bool
identicalLiveTupleStatement =
    Statement.preparable
        """
        SELECT EXISTS (
          SELECT 1 FROM relation_tuple
          WHERE object_type = $2
            AND object_id = $3
            AND relation = $4
            AND subject_type = $5
            AND subject_id = $6
            AND coalesce(subject_relation, '') = coalesce($7, '')
            AND deleted_xid IS NULL
            AND caveat_name IS NOT DISTINCT FROM $8
            AND caveat_payload IS NOT DISTINCT FROM $9::jsonb
        )
        """
        tupleInsertEncoder
        (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.bool)))

{- | Shared by every touch statement so their parameter positions cannot drift
apart. @$1@ is the write transaction's xid; @$2@–@$9@ are the tuple's columns.
-}
tupleInsertEncoder :: Encoders.Params TupleInsertParams
tupleInsertEncoder =
    ((\params -> params.createdXid) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\params -> params.objectType) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\params -> params.objectId) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\params -> params.relation) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\params -> params.subjectType) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\params -> params.subjectId) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\params -> params.subjectRelation) >$< Encoders.param (Encoders.nullable Encoders.text))
        <> ((\params -> params.caveatName) >$< Encoders.param (Encoders.nullable Encoders.text))
        <> ((\params -> params.caveatPayload) >$< Encoders.param (Encoders.nullable Encoders.jsonbLazyBytes))

data TupleDeleteParams = TupleDeleteParams
    { deletedXid :: !Text
    , objectType :: !Text
    , objectId :: !Text
    , relation :: !Text
    , subjectType :: !Text
    , subjectId :: !Text
    , subjectRelation :: !(Maybe Text)
    }

tupleDeleteParams :: Text -> Tuple -> TupleDeleteParams
tupleDeleteParams deletedXid tuple =
    let (subjectObject, subjectRelation) = flattenSubject tuple.subject
     in TupleDeleteParams
            { deletedXid = deletedXid
            , objectType = unObjectType tuple.object.objectType
            , objectId = tuple.object.objectId
            , relation = unRelationName tuple.relation
            , subjectType = unObjectType subjectObject.objectType
            , subjectId = subjectObject.objectId
            , subjectRelation = unRelationName <$> subjectRelation
            }

{- | Retire the live grant for an identity, whatever caveat it carries.

The request's caveat is ignored. With one live row per identity, matching on
@caveat_name@ would mean a caller who supplies yesterday's caveat name deletes
nothing and is told it succeeded — the same silent no-op that touch semantics
removes from the write path.
-}
deleteTupleStatement :: Statement TupleDeleteParams ()
deleteTupleStatement =
    Statement.preparable
        """
        UPDATE relation_tuple
        SET deleted_xid = $1::xid8
        WHERE object_type = $2
          AND object_id = $3
          AND relation = $4
          AND subject_type = $5
          AND subject_id = $6
          AND coalesce(subject_relation, '') = coalesce($7, '')
          AND deleted_xid IS NULL
        """
        ( ((\params -> params.deletedXid) >$< Encoders.param (Encoders.nonNullable Encoders.text))
            <> ((\params -> params.objectType) >$< Encoders.param (Encoders.nonNullable Encoders.text))
            <> ((\params -> params.objectId) >$< Encoders.param (Encoders.nonNullable Encoders.text))
            <> ((\params -> params.relation) >$< Encoders.param (Encoders.nonNullable Encoders.text))
            <> ((\params -> params.subjectType) >$< Encoders.param (Encoders.nonNullable Encoders.text))
            <> ((\params -> params.subjectId) >$< Encoders.param (Encoders.nonNullable Encoders.text))
            <> ((\params -> params.subjectRelation) >$< Encoders.param (Encoders.nullable Encoders.text))
        )
        Decoders.noResult

data ReadParams = ReadParams
    { revision :: !Text
    , objectType :: !Text
    , relation :: !Text
    , subjectTypes :: ![Text]
    , subjectIds :: ![Text]
    , subjectRelations :: ![Text]
    , limit :: !Int64
    , cursor :: !Int64
    }

readParams :: Revision -> UsersetQuery -> Int64 -> Int64 -> ReadParams
readParams revision query limitPlusOne cursorId =
    let keys = subjectKeys query.querySubjects
     in ReadParams
            { revision = revision.revisionEncoding
            , objectType = unObjectType query.queryType
            , relation = unRelationName query.queryRelation
            , subjectTypes = (\(subjectType, _, _) -> subjectType) <$> keys
            , subjectIds = (\(_, subjectId, _) -> subjectId) <$> keys
            , subjectRelations = (\(_, _, subjectRelation) -> subjectRelation) <$> keys
            , limit = limitPlusOne
            , cursor = cursorId
            }

data ObjectReadParams = ObjectReadParams
    { revision :: !Text
    , objectType :: !Text
    , objectId :: !Text
    , relation :: !Text
    , limit :: !Int64
    , cursor :: !Int64
    }

objectReadParams :: Revision -> ObjectRef -> RelationName -> Int64 -> Int64 -> ObjectReadParams
objectReadParams revision object relation limitPlusOne cursorId =
    ObjectReadParams
        { revision = revision.revisionEncoding
        , objectType = unObjectType object.objectType
        , objectId = object.objectId
        , relation = unRelationName relation
        , limit = limitPlusOne
        , cursor = cursorId
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

data ProbeParams = ProbeParams
    { revision :: !Text
    , objectType :: !Text
    , objectId :: !Text
    , relation :: !Text
    , subjectTypes :: ![Text]
    , subjectIds :: ![Text]
    , subjectRelations :: ![Text]
    }

probeParams :: Revision -> ObjectRef -> RelationName -> [Subject] -> ProbeParams
probeParams revision object relation subjects =
    let keys = subjectKeys subjects
     in ProbeParams
            { revision = revision.revisionEncoding
            , objectType = unObjectType object.objectType
            , objectId = object.objectId
            , relation = unRelationName relation
            , subjectTypes = (\(subjectType, _, _) -> subjectType) <$> keys
            , subjectIds = (\(_, subjectId, _) -> subjectId) <$> keys
            , subjectRelations = (\(_, _, subjectRelation) -> subjectRelation) <$> keys
            }

{- | The probe carries no @LIMIT@: its result is bounded by the candidate-set
size times the number of distinct caveat names a grant can carry, which is
small by construction. Served by @relation_tuple_object_hist_idx@ (equality on
object_type, object_id, relation) or @relation_tuple_subject_hist_idx@; the
partial @*_live_idx@ indexes cannot serve it, because visibility is read
through @pg_visible_in_snapshot@ rather than @deleted_xid IS NULL@.
-}
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
        <*> Decoders.column (Decoders.nullable (Decoders.jsonbBytes Right))
        <*> Decoders.column (Decoders.nonNullable Decoders.text)
        <*> Decoders.column (Decoders.nullable Decoders.text)

rowFromColumns ::
    Int64 ->
    Text ->
    Text ->
    Text ->
    Text ->
    Text ->
    Maybe Text ->
    Maybe Text ->
    Maybe ByteString.ByteString ->
    Text ->
    Maybe Text ->
    TupleRow
rowFromColumns idValue objectType objectId relation subjectType subjectId subjectRelation caveatName caveatPayload createdXid deletedXid =
    TupleRow
        { rowId = TupleRowId (Text.pack (show idValue))
        , tuple =
            Tuple
                { object = ObjectRef{objectType = ObjectType objectType, objectId = objectId}
                , relation = RelationName relation
                , subject =
                    case (subjectRelation, subjectId) of
                        (Nothing, "*") -> SubjectWildcard (ObjectType subjectType)
                        (Nothing, _) -> SubjectId subjectObject
                        (Just relationName, _) -> SubjectSet subjectObject (RelationName relationName)
                , caveat = decodeTupleCaveat caveatName caveatPayload
                }
        , createdAt = Revision createdXid
        , deletedAt = Revision <$> deletedXid
        }
  where
    subjectObject = ObjectRef{objectType = ObjectType subjectType, objectId = subjectId}

decodeTupleCaveat :: Maybe Text -> Maybe ByteString.ByteString -> Maybe TupleCaveat
decodeTupleCaveat Nothing _ = Nothing
decodeTupleCaveat (Just caveatName) maybePayload =
    Just
        TupleCaveat
            { name = CaveatName caveatName
            , payload =
                CaveatPayload $
                    case maybePayload >>= Aeson.decodeStrict >>= decodeCaveatPayload of
                        Just decoded -> decoded
                        Nothing -> Map.empty
            }

flattenSubject :: Subject -> (ObjectRef, Maybe RelationName)
flattenSubject =
    \case
        SubjectId objectRef -> (objectRef, Nothing)
        SubjectSet objectRef relationName -> (objectRef, Just relationName)
        SubjectWildcard objectType -> (ObjectRef{objectType, objectId = "*"}, Nothing)

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
        [ "type" Aeson..= valueType
        , "value" Aeson..= value
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

decodeCursor :: StoreCursor -> Int64
decodeCursor (StoreCursor cursorText) =
    case reads (Text.unpack cursorText) of
        [(value, "")] -> value
        _ -> 0

unObjectType :: ObjectType -> Text
unObjectType (ObjectType text) = text

unRelationName :: RelationName -> Text
unRelationName (RelationName text) = text

unCaveatName :: CaveatName -> Text
unCaveatName (CaveatName text) = text
