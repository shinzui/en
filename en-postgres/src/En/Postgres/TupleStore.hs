{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE MultilineStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE NoFieldSelectors #-}

-- | PostgreSQL-backed 'TupleStore'.
module En.Postgres.TupleStore (
    PostgresSessionRunner (..),
    hasqlConnectionRunner,
    postgresTupleStore,
    postgresTupleStoreIO,
    reapDeletedTuples,
) where

import Control.Exception (throwIO)
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
import Data.Word (Word64)

import En.Effect.TupleStore (
    PageState (..),
    StoreCursor (..),
    TuplePage (..),
    TupleRow (..),
    TupleRowId (..),
    TupleStore (..),
    UsersetQuery (..),
 )
import En.Postgres.Revision (
    ConsistencyConfig (..),
    PgSnapshot (..),
    TokenPayload (..),
    encodeToken,
    parsePgSnapshot,
    renderPgSnapshot,
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
import Hasql.Connection (Connection)
import Hasql.Connection qualified as Connection
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Errors qualified as Hasql
import Hasql.Session (Session)
import Hasql.Session qualified as Session
import Hasql.Statement (Statement)
import Hasql.Statement qualified as Statement
import Numeric (readDec)

-- | An effect-polymorphic runner for Hasql sessions.
newtype PostgresSessionRunner m = PostgresSessionRunner
    { run :: forall a. Session a -> m a
    }

hasqlConnectionRunner :: Connection -> PostgresSessionRunner IO
hasqlConnectionRunner connection =
    PostgresSessionRunner (runStoreSession connection)

-- | Construct a tuple store from any effect that can run Hasql sessions.
postgresTupleStore :: PostgresSessionRunner m -> ConsistencyConfig -> TupleStore m
postgresTupleStore (PostgresSessionRunner run) config =
    TupleStore
        { readObjectRelation = \revision object relation limit cursor ->
            run (readObjectRelationSession revision object relation limit cursor)
        , readStartingWithUser = \revision query ->
            run (readStartingWithUserSession revision query)
        , writeTuples = \tuples ->
            run (writeTuplesSession config tuples)
        , deleteTuples = \tuples ->
            run (deleteTuplesSession config tuples)
        , headRevision =
            run headRevisionSession
        , optimizedRevision =
            run headRevisionSession
        , oldestRetainedXid =
            run (oldestRetainedXidSession config.gcWindow)
        , reapDeletedTuples = \horizon ->
            run (reapDeletedTuples horizon)
        }

-- | Convenience constructor for the common direct-connection IO case.
postgresTupleStoreIO :: Connection -> ConsistencyConfig -> TupleStore IO
postgresTupleStoreIO connection =
    postgresTupleStore (hasqlConnectionRunner connection)

runStoreSession :: Connection -> Session a -> IO a
runStoreSession connection session =
    Connection.use connection session >>= \case
        Right value -> pure value
        Left err -> throwIO (userError (Text.unpack (Hasql.toDetailedText err)))

writeTuplesSession :: ConsistencyConfig -> [Tuple] -> Session ConsistencyToken
writeTuplesSession config tuples = do
    Session.script beginScript
    anchor <- Session.statement schemaHashText anchorTransactionStatement
    traverse_ (\tuple -> Session.statement (tupleInsertParams anchor.xid tuple) insertTupleStatement) tuples
    Session.script commitScript
    pure (tokenFromAnchor config anchor)
  where
    SchemaHash schemaHashText = config.schemaHash

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

reapDeletedTuples :: Word64 -> Session Int64
reapDeletedTuples horizon =
    Session.statement (Text.pack (show horizon)) reapDeletedTuplesStatement

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

insertTupleStatement :: Statement TupleInsertParams ()
insertTupleStatement =
    Statement.preparable
        """
        INSERT INTO relation_tuple
          (object_type, object_id, relation, subject_type, subject_id, subject_relation, caveat_name, caveat_payload, created_xid)
        VALUES ($2, $3, $4, $5, $6, $7, $8, $9, $1::xid8)
        ON CONFLICT DO NOTHING
        """
        ( ((\params -> params.createdXid) >$< Encoders.param (Encoders.nonNullable Encoders.text))
            <> ((\params -> params.objectType) >$< Encoders.param (Encoders.nonNullable Encoders.text))
            <> ((\params -> params.objectId) >$< Encoders.param (Encoders.nonNullable Encoders.text))
            <> ((\params -> params.relation) >$< Encoders.param (Encoders.nonNullable Encoders.text))
            <> ((\params -> params.subjectType) >$< Encoders.param (Encoders.nonNullable Encoders.text))
            <> ((\params -> params.subjectId) >$< Encoders.param (Encoders.nonNullable Encoders.text))
            <> ((\params -> params.subjectRelation) >$< Encoders.param (Encoders.nullable Encoders.text))
            <> ((\params -> params.caveatName) >$< Encoders.param (Encoders.nullable Encoders.text))
            <> ((\params -> params.caveatPayload) >$< Encoders.param (Encoders.nullable Encoders.jsonbLazyBytes))
        )
        Decoders.noResult

data TupleDeleteParams = TupleDeleteParams
    { deletedXid :: !Text
    , objectType :: !Text
    , objectId :: !Text
    , relation :: !Text
    , subjectType :: !Text
    , subjectId :: !Text
    , subjectRelation :: !(Maybe Text)
    , caveatName :: !(Maybe Text)
    }

tupleDeleteParams :: Text -> Tuple -> TupleDeleteParams
tupleDeleteParams deletedXid tuple =
    let (subjectObject, subjectRelation) = flattenSubject tuple.subject
        (maybeCaveatName, _) = flattenCaveat tuple.caveat
     in TupleDeleteParams
            { deletedXid = deletedXid
            , objectType = unObjectType tuple.object.objectType
            , objectId = tuple.object.objectId
            , relation = unRelationName tuple.relation
            , subjectType = unObjectType subjectObject.objectType
            , subjectId = subjectObject.objectId
            , subjectRelation = unRelationName <$> subjectRelation
            , caveatName = unCaveatName <$> maybeCaveatName
            }

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
          AND coalesce(caveat_name, '') = coalesce($8, '')
          AND deleted_xid IS NULL
        """
        ( ((\params -> params.deletedXid) >$< Encoders.param (Encoders.nonNullable Encoders.text))
            <> ((\params -> params.objectType) >$< Encoders.param (Encoders.nonNullable Encoders.text))
            <> ((\params -> params.objectId) >$< Encoders.param (Encoders.nonNullable Encoders.text))
            <> ((\params -> params.relation) >$< Encoders.param (Encoders.nonNullable Encoders.text))
            <> ((\params -> params.subjectType) >$< Encoders.param (Encoders.nonNullable Encoders.text))
            <> ((\params -> params.subjectId) >$< Encoders.param (Encoders.nonNullable Encoders.text))
            <> ((\params -> params.subjectRelation) >$< Encoders.param (Encoders.nullable Encoders.text))
            <> ((\params -> params.caveatName) >$< Encoders.param (Encoders.nullable Encoders.text))
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
                    case subjectRelation of
                        Nothing -> SubjectId subjectObject
                        Just relationName -> SubjectSet subjectObject (RelationName relationName)
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
        ValueText value -> Aeson.toJSON value
        ValueBool value -> Aeson.toJSON value
        ValueInteger value -> Aeson.toJSON value
        ValueTimestamp value -> Aeson.toJSON value
        ValueEnum value -> Aeson.toJSON value

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
