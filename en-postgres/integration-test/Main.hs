{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE MultilineStrings #-}

module Main (main) where

import Data.Foldable (traverse_)
import Data.Functor.Contravariant ((>$<))
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, defaultTimeLocale, parseTimeOrError)
import Data.Word (Word64)
import Numeric (readDec)

import En.Check (CheckDecision (..), check)
import En.Effect.ConsistencyStore (ConsistencyStore (..), TokenMetadata (..))
import En.Effect.TupleStore (PageState (..), TuplePage (..), TupleRow (..), TupleStore (..), UsersetQuery (..))
import En.Error (EnError (..))
import En.Lookup (LookupCursor (..), LookupLimit (..), LookupObject (..), LookupPage (..), LookupRequest (..), LookupState (..))
import En.Lookup qualified as Lookup
import En.Postgres.Revision (ConsistencyConfig (..), PgSnapshot (..), comparePgSnapshot, parsePgSnapshot, postgresConsistencyStore, renderPgSnapshot, tokenMetadataFromPayload, transactionVisible)
import En.Postgres.TupleStore (postgresTupleStoreIO)
import En.Reachability (compile)
import En.Revision (Consistency (..), DatastoreId (..), Revision (..), RevisionOrder (..))
import En.Schema (AllowedSubject (..), ObjectType (..), Relation (..), RelationName (..), Rewrite (..), Schema (..))
import En.Schema qualified as Schema
import En.Tuple (CaveatContext (..), ObjectRef (..), Subject (..), Tuple (..))
import EphemeralPg qualified as Pg
import Hasql.Connection qualified as Connection
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Session qualified as Session
import Hasql.Statement (Statement)
import Hasql.Statement qualified as Statement

main :: IO ()
main = do
    result <- Pg.with \database -> do
        connection <- acquire database
        resetSchema connection
        runTupleStoreScenario connection
        Connection.release connection
    case result of
        Left err -> fail ("ephemeral-pg failed to start: " <> Text.unpack (Pg.renderStartError err))
        Right () -> pure ()

acquire :: Pg.Database -> IO Connection.Connection
acquire database =
    Connection.acquire (Pg.connectionSettings database) >>= \case
        Right connection -> pure connection
        Left err -> fail ("Could not connect to PostgreSQL: " <> show err)

resetSchema :: Connection.Connection -> IO ()
resetSchema connection =
    Connection.use connection (Session.script schemaSql) >>= \case
        Right () -> pure ()
        Left err -> fail ("Could not reset schema: " <> show err)

runTupleStoreScenario :: Connection.Connection -> IO ()
runTupleStoreScenario connection = do
    let config =
            ConsistencyConfig
                { datastoreId = DatastoreId "test-datastore"
                , schemaHash = Schema.schemaHash checkSchema
                , gcWindow = "24 hours"
                }
        store = postgresTupleStoreIO connection config
        consistencyStore =
            postgresConsistencyStore config (pure testTime) store.optimizedRevision store.headRevision store.oldestRetainedXid
        projectX = ObjectRef (ObjectType "space") "project-x"
        projectY = ObjectRef (ObjectType "space") "project-y"
        projectPublic = ObjectRef (ObjectType "space") "public"
        tuple =
            Tuple
                { object = projectX
                , relation = RelationName "viewer"
                , subject = SubjectId (ObjectRef (ObjectType "user") "alice")
                , caveat = Nothing
                }
        tuple2 =
            Tuple
                { object = projectY
                , relation = RelationName "viewer"
                , subject = tuple.subject
                , caveat = Nothing
                }
        query =
            UsersetQuery
                { queryType = ObjectType "space"
                , queryRelation = RelationName "viewer"
                , querySubjects = [SubjectId (ObjectRef (ObjectType "user") "alice")]
                , queryLimit = 10
                , queryCursor = Nothing
                }
        lookupRequest cursor =
            LookupRequest
                { subject = tuple.subject
                , permission = RelationName "view"
                , objectType = ObjectType "space"
                , context = CaveatContext Map.empty
                , limit = LookupLimit 1
                , cursor = cursor
                }
    writeToken <- store.writeTuples [tuple, tuple2]
    TokenMetadata{revision = writeRevision} <- either (fail . show) pure (tokenMetadataFromPayload writeToken)
    headAfterWrite <- store.headRevision
    writeSnapshot <- either (fail . Text.unpack) pure (parsePgSnapshot writeRevision.revisionEncoding)
    headAfterWriteSnapshot <- either (fail . Text.unpack) pure (parsePgSnapshot headAfterWrite.revisionEncoding)
    assertEqual "write token is not fresher than immediate head revision" True (writeSnapshot.xmax <= headAfterWriteSnapshot.xmax)
    TuplePage{rows = rowsAtWrite, state = stateAtWrite} <- store.readStartingWithUser writeRevision query
    assertEqual "write token read sees tuple count" 2 (length rowsAtWrite)
    assertEqual "write token read is exhausted" Exhausted stateAtWrite
    runSnapshotOracleScenario connection
    graph <- either (fail . show) pure (compile checkSchema)
    checkDecision <- check consistencyStore store graph (AtLeastAsFresh writeToken) (CaveatContext Map.empty) tuple.subject (RelationName "view") projectX
    assertEqual "postgres-backed check sees written tuple" (Right Allowed) checkDecision
    lookupFirstPage <- Lookup.lookup consistencyStore store graph (AtLeastAsFresh writeToken) (lookupRequest Nothing)
    assertEqual
        "postgres-backed lookup returns first cursor page"
        ( Right
            LookupPage
                { objects = [LookupObject{object = projectX, decision = Allowed}]
                , state = LookupHasMore (LookupCursor "1")
                }
        )
        lookupFirstPage
    lookupSecondPage <- Lookup.lookup consistencyStore store graph (AtLeastAsFresh writeToken) (lookupRequest (Just (LookupCursor "1")))
    assertEqual
        "postgres-backed lookup resumes from cursor"
        ( Right
            LookupPage
                { objects = [LookupObject{object = projectY, decision = Allowed}]
                , state = LookupExhausted
                }
        )
        lookupSecondPage
    deleteToken <- store.deleteTuples [tuple, tuple2]
    TokenMetadata{revision = deleteRevision} <- either (fail . show) pure (tokenMetadataFromPayload deleteToken)
    TuplePage{rows = rowsAtOldRevision} <- store.readStartingWithUser writeRevision query
    TuplePage{rows = rowsAtDelete} <- store.readStartingWithUser deleteRevision query
    assertEqual "old revision still sees deleted tuple" 2 (length rowsAtOldRevision)
    assertEqual "delete revision hides tuple" 0 (length rowsAtDelete)
    let deletedXids = traverse (parseTupleDeletedXid . (.deletedAt)) rowsAtOldRevision
    deletedHorizon <- maybe (fail "deleted tuple rows did not carry deleted_xid") (pure . (+ 1) . maximum) deletedXids
    reaped <- store.reapDeletedTuples deletedHorizon
    assertEqual "reaper removes safely old soft-deleted tuples" 2 reaped
    reapedAgain <- store.reapDeletedTuples deletedHorizon
    assertEqual "reaper is idempotent" 0 reapedAgain
    staleStore <-
        let staleConfig = config{gcWindow = "0 seconds"}
         in pure (postgresTupleStoreIO connection staleConfig)
    let staleConsistencyStore =
            postgresConsistencyStore config{gcWindow = "0 seconds"} (pure testTime) staleStore.optimizedRevision staleStore.headRevision staleStore.oldestRetainedXid
    staleResult <- staleConsistencyStore.resolveConsistency (AtExactSnapshot writeToken)
    assertEqual
        "stale snapshot token is rejected after GC horizon advances"
        (Left (InvalidConsistencyToken "token is older than the garbage-collection window"))
        staleResult
    let publicTuple =
            Tuple
                { object = projectPublic
                , relation = RelationName "viewer"
                , subject = SubjectWildcard (ObjectType "user")
                , caveat = Nothing
                }
        publicQuery =
            UsersetQuery
                { queryType = ObjectType "space"
                , queryRelation = RelationName "viewer"
                , querySubjects = [SubjectWildcard (ObjectType "user")]
                , queryLimit = 10
                , queryCursor = Nothing
                }
    publicToken <- store.writeTuples [publicTuple]
    TokenMetadata{revision = publicRevision} <- either (fail . show) pure (tokenMetadataFromPayload publicToken)
    TuplePage{rows = publicRows, state = publicState} <- store.readStartingWithUser publicRevision publicQuery
    assertEqual "postgres tuple store round-trips wildcard rows" [publicTuple] ((.tuple) <$> publicRows)
    assertEqual "postgres wildcard read is exhausted" Exhausted publicState

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual
    | expected == actual = pure ()
    | otherwise =
        fail $
            label
                <> "\nexpected: "
                <> show expected
                <> "\nactual:   "
                <> show actual

runSnapshotOracleScenario :: Connection.Connection -> IO ()
runSnapshotOracleScenario connection =
    traverse_ assertPair (take 240 generatedSnapshotPairs)
  where
    assertPair (left, right) = do
        oracle <- oracleCompare connection left right
        assertEqual ("snapshot comparator agrees with PostgreSQL oracle for " <> Text.unpack (renderPgSnapshot left) <> " vs " <> Text.unpack (renderPgSnapshot right)) oracle (comparePgSnapshot left right)

oracleCompare :: Connection.Connection -> PgSnapshot -> PgSnapshot -> IO RevisionOrder
oracleCompare connection left right = do
    let maxTxid = fromIntegral (max left.xmax right.xmax + 2)
    leftVisibility <- visibleRows connection left maxTxid
    rightVisibility <- visibleRows connection right maxTxid
    traverse_
        ( \(txid, visible) ->
            assertEqual
                ("transactionVisible agrees with PostgreSQL for " <> show txid <> " in " <> Text.unpack (renderPgSnapshot left))
                visible
                (transactionVisible txid left)
        )
        leftVisibility
    traverse_
        ( \(txid, visible) ->
            assertEqual
                ("transactionVisible agrees with PostgreSQL for " <> show txid <> " in " <> Text.unpack (renderPgSnapshot right))
                visible
                (transactionVisible txid right)
        )
        rightVisibility
    let leftIncludesRight = and [not rightVisible || leftVisible | ((_, leftVisible), (_, rightVisible)) <- zip leftVisibility rightVisibility]
        rightIncludesLeft = and [not leftVisible || rightVisible | ((_, leftVisible), (_, rightVisible)) <- zip leftVisibility rightVisibility]
    pure $
        case (leftIncludesRight, rightIncludesLeft) of
            (True, True) -> REqual
            (True, False) -> RAfter
            (False, True) -> RBefore
            (False, False) -> RConcurrent

visibleRows :: Connection.Connection -> PgSnapshot -> Int64 -> IO [(Word64, Bool)]
visibleRows connection snapshot maxTxid =
    Connection.use connection (Session.statement (renderPgSnapshot snapshot, maxTxid) snapshotVisibilityStatement) >>= \case
        Right rows -> traverse decode rows
        Left err -> fail ("Could not query pg_visible_in_snapshot oracle: " <> show err)
  where
    decode (txidText, visible) =
        case parseWord64 txidText of
            Just txid -> pure (txid, visible)
            Nothing -> fail ("PostgreSQL returned non-Word64 txid: " <> Text.unpack txidText)

snapshotVisibilityStatement :: Statement (Text, Int64) [(Text, Bool)]
snapshotVisibilityStatement =
    Statement.preparable
        """
        SELECT txid::text, pg_visible_in_snapshot(txid::text::xid8, $1::pg_snapshot)
        FROM generate_series(1, $2::bigint) AS txid
        """
        ( (fst >$< Encoders.param (Encoders.nonNullable Encoders.text))
            <> (snd >$< Encoders.param (Encoders.nonNullable Encoders.int8))
        )
        ( Decoders.rowList
            ( (,)
                <$> Decoders.column (Decoders.nonNullable Decoders.text)
                <*> Decoders.column (Decoders.nonNullable Decoders.bool)
            )
        )

generatedSnapshotPairs :: [(PgSnapshot, PgSnapshot)]
generatedSnapshotPairs =
    edgePairs <> zip generatedSnapshots (drop 7 generatedSnapshots)
  where
    edgePairs =
        [ (PgSnapshot{xmin = 10, xmax = 15, xip = []}, PgSnapshot{xmin = 20, xmax = 25, xip = []})
        , (PgSnapshot{xmin = 10, xmax = 20, xip = [11]}, PgSnapshot{xmin = 10, xmax = 20, xip = [12]})
        ]
    generatedSnapshots =
        snapshotFromSeed <$> iterate lcg 1

snapshotFromSeed :: Word64 -> PgSnapshot
snapshotFromSeed seed =
    let xmin = 1 + seed `mod` 40
        width = 1 + (seed `div` 41) `mod` 40
        xmax = xmin + width
        candidates = [xmin .. xmax - 1]
        xip =
            [ txid
            | (index, txid) <- zip [1 ..] candidates
            , ((seed `div` (index + 3)) + txid) `mod` 5 == 0
            ]
     in PgSnapshot{xmin, xmax, xip}

lcg :: Word64 -> Word64
lcg seed =
    seed * 6364136223846793005 + 1442695040888963407

parseTupleDeletedXid :: Maybe Revision -> Maybe Word64
parseTupleDeletedXid =
    \case
        Nothing -> Nothing
        Just revision -> parseWord64 revision.revisionEncoding

parseWord64 :: Text -> Maybe Word64
parseWord64 text =
    case readDec (Text.unpack text) of
        [(value, "")] -> Just value
        _ -> Nothing

checkSchema :: Schema
checkSchema =
    Schema
        { objectTypes =
            Map.fromList
                [ (ObjectType "user", Map.empty)
                ,
                    ( ObjectType "space"
                    , Map.fromList
                        [ relationEntry "viewer" (userSubject <> wildcardUserSubject) This
                        , relationEntry "view" Set.empty (ComputedUserset (RelationName "viewer"))
                        ]
                    )
                ]
        , caveats = Map.empty
        }

relationEntry :: Text -> Set.Set AllowedSubject -> Rewrite -> (RelationName, Relation)
relationEntry name allowedSubjects rewrite =
    ( RelationName name
    , Relation
        { relationName = RelationName name
        , allowedSubjects = allowedSubjects
        , rewrite = rewrite
        }
    )

userSubject :: Set.Set AllowedSubject
userSubject =
    Set.singleton AllowedSubject{objectType = ObjectType "user", relation = Nothing, wildcard = False}

wildcardUserSubject :: Set.Set AllowedSubject
wildcardUserSubject =
    Set.singleton AllowedSubject{objectType = ObjectType "user", relation = Nothing, wildcard = True}

testTime :: UTCTime
testTime =
    parseTimeOrError True defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" "2026-06-23T00:00:00Z"

schemaSql :: Text
schemaSql =
    """
    DROP TABLE IF EXISTS relation_tuple;
    DROP TABLE IF EXISTS en_transaction;

    CREATE TABLE en_transaction
      ( xid xid8 PRIMARY KEY
      , snapshot pg_snapshot NOT NULL DEFAULT pg_current_snapshot()
      , schema_hash text NOT NULL
      , created_at timestamptz NOT NULL DEFAULT now()
      );

    CREATE TABLE relation_tuple
      ( id bigserial PRIMARY KEY
      , object_type text NOT NULL
      , object_id text NOT NULL
      , relation text NOT NULL
      , subject_type text NOT NULL
      , subject_id text NOT NULL
      , subject_relation text NULL
      , caveat_name text NULL
      , caveat_payload jsonb NULL
      , created_xid xid8 NOT NULL
      , deleted_xid xid8 NULL
      , CHECK ((subject_relation IS NULL) OR (subject_relation <> ''))
      );

    CREATE UNIQUE INDEX relation_tuple_live_unique
      ON relation_tuple
        (object_type, object_id, relation, subject_type, subject_id, coalesce(subject_relation, ''), coalesce(caveat_name, ''))
      WHERE deleted_xid IS NULL;

    CREATE INDEX relation_tuple_object_live_idx
      ON relation_tuple (object_type, object_id, relation, id)
      WHERE deleted_xid IS NULL;

    CREATE INDEX relation_tuple_subject_live_idx
      ON relation_tuple
        (subject_type, subject_id, coalesce(subject_relation, ''), object_type, relation, id)
      WHERE deleted_xid IS NULL;

    CREATE INDEX relation_tuple_object_hist_idx
      ON relation_tuple (object_type, object_id, relation, id);

    CREATE INDEX relation_tuple_subject_hist_idx
      ON relation_tuple
        (subject_type, subject_id, coalesce(subject_relation, ''), object_type, relation, id);

    CREATE INDEX relation_tuple_created_xid_idx
      ON relation_tuple (created_xid);

    CREATE INDEX relation_tuple_deleted_xid_idx
      ON relation_tuple (deleted_xid)
      WHERE deleted_xid IS NOT NULL;
    """
