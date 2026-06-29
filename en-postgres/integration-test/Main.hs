{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE MultilineStrings #-}

module Main (main) where

import Data.Foldable (traverse_)
import Data.Functor.Contravariant ((>$<))
import Data.Int (Int64)
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64)
import Effectful (Eff, IOE, runEff)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Numeric (readDec)

import En.Check (CheckDecision (..), check)
import En.Effect.ConsistencyStore (ConsistencyStore, TokenMetadata (..))
import En.Effect.ConsistencyStore qualified as ConsistencyStore
import En.Effect.TupleStore (PageState (..), TuplePage (..), TupleRow (..), TupleStore, UsersetQuery (..))
import En.Effect.TupleStore qualified as TupleStore
import En.Error (EnError (..))
import En.Lookup (LookupCursor (..), LookupLimit (..), LookupObject (..), LookupPage (..), LookupRequest (..), LookupState (..))
import En.Lookup qualified as Lookup
import En.Postgres.Database (Database, runDatabaseConnection)
import En.Postgres.Revision (ConsistencyConfig (..), PgSnapshot (..), comparePgSnapshot, parsePgSnapshot, renderPgSnapshot, runConsistencyStorePostgres, tokenMetadataFromPayload, transactionVisible)
import En.Postgres.TupleStore (runTupleStorePostgres)
import En.Reachability (ReachabilityGraph, compile)
import En.Revision (Consistency (..), DatastoreId (..), Revision (..), RevisionOrder (..))
import En.Schema (AllowedSubject (..), CaveatName (..), ObjectType (..), Relation (..), RelationName (..), Rewrite (..), Schema (..))
import En.Schema qualified as Schema
import En.Tuple (CaveatContext (..), CaveatPayload (..), CaveatValue (..), ObjectRef (..), Subject (..), Tuple (..), TupleCaveat (..))
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
    validCheckSchema <- either (fail . show) pure (Schema.validateSchema checkSchema)
    let config =
            ConsistencyConfig
                { datastoreId = DatastoreId "test-datastore"
                , schemaHash = Schema.schemaHash validCheckSchema
                , gcWindow = "24 hours"
                }
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
    writeToken <- runPgOrFail connection config (TupleStore.writeTuples [tuple, tuple2])
    TokenMetadata{revision = writeRevision} <- either (fail . show) pure (tokenMetadataFromPayload writeToken)
    headAfterWrite <- runPgOrFail connection config TupleStore.headRevision
    writeSnapshot <- either (fail . Text.unpack) pure (parsePgSnapshot writeRevision.revisionEncoding)
    headAfterWriteSnapshot <- either (fail . Text.unpack) pure (parsePgSnapshot headAfterWrite.revisionEncoding)
    assertEqual "write token is not fresher than immediate head revision" True (writeSnapshot.xmax <= headAfterWriteSnapshot.xmax)
    TuplePage{rows = rowsAtWrite, state = stateAtWrite} <- runPgOrFail connection config (TupleStore.readStartingWithUser writeRevision query)
    assertEqual "write token read sees tuple count" 2 (length rowsAtWrite)
    assertEqual "write token read is exhausted" Exhausted stateAtWrite
    runSnapshotOracleScenario connection
    let graph = compile validCheckSchema
    checkDecision <- runPg connection config (check graph (AtLeastAsFresh writeToken) (CaveatContext Map.empty) tuple.subject (RelationName "view") projectX)
    assertEqual "postgres-backed check sees written tuple" (Right Allowed) checkDecision
    lookupFirstPage <- runPg connection config (Lookup.lookup graph (AtLeastAsFresh writeToken) (lookupRequest Nothing))
    projectXCursor <- expectLookupHasMore "postgres-backed lookup returns first cursor page" [LookupObject{object = projectX, decision = Allowed}] lookupFirstPage
    lookupSecondPage <- runPg connection config (Lookup.lookup graph (AtLeastAsFresh writeToken) (lookupRequest (Just projectXCursor)))
    assertEqual
        "postgres-backed lookup resumes from cursor"
        ( Right
            LookupPage
                { objects = [LookupObject{object = projectY, decision = Allowed}]
                , state = LookupExhausted
                }
        )
        lookupSecondPage
    deleteToken <- runPgOrFail connection config (TupleStore.deleteTuples [tuple, tuple2])
    TokenMetadata{revision = deleteRevision} <- either (fail . show) pure (tokenMetadataFromPayload deleteToken)
    TuplePage{rows = rowsAtOldRevision} <- runPgOrFail connection config (TupleStore.readStartingWithUser writeRevision query)
    TuplePage{rows = rowsAtDelete} <- runPgOrFail connection config (TupleStore.readStartingWithUser deleteRevision query)
    assertEqual "old revision still sees deleted tuple" 2 (length rowsAtOldRevision)
    assertEqual "delete revision hides tuple" 0 (length rowsAtDelete)
    let deletedXids = traverse (parseTupleDeletedXid . (.deletedAt)) rowsAtOldRevision
    deletedHorizon <- maybe (fail "deleted tuple rows did not carry deleted_xid") (pure . (+ 1) . maximum) deletedXids
    reaped <- runPgOrFail connection config (TupleStore.reapDeletedTuples deletedHorizon)
    assertEqual "reaper removes safely old soft-deleted tuples" 2 reaped
    reapedAgain <- runPgOrFail connection config (TupleStore.reapDeletedTuples deletedHorizon)
    assertEqual "reaper is idempotent" 0 reapedAgain
    let staleConfig = config{gcWindow = "0 seconds"}
    staleResult <- runPg connection staleConfig (ConsistencyStore.resolveConsistency (AtExactSnapshot writeToken))
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
    publicToken <- runPgOrFail connection config (TupleStore.writeTuples [publicTuple])
    TokenMetadata{revision = publicRevision} <- either (fail . show) pure (tokenMetadataFromPayload publicToken)
    TuplePage{rows = publicRows, state = publicState} <- runPgOrFail connection config (TupleStore.readStartingWithUser publicRevision publicQuery)
    assertEqual "postgres tuple store round-trips wildcard rows" [publicTuple] ((.tuple) <$> publicRows)
    assertEqual "postgres wildcard read is exhausted" Exhausted publicState
    let caveatedTuple =
            Tuple
                { object = ObjectRef (ObjectType "space") "caveated"
                , relation = RelationName "viewer"
                , subject = SubjectId (ObjectRef (ObjectType "user") "typed-caveat")
                , caveat =
                    Just
                        TupleCaveat
                            { name = CaveatName "within_autonomy"
                            , payload =
                                CaveatPayload
                                    ( Map.fromList
                                        [ ("autonomy", ValueEnum "act")
                                        , ("enabled", ValueBool True)
                                        , ("label", ValueText "delegation")
                                        , ("level", ValueInteger 3)
                                        , ("until", ValueTimestamp (read "2026-07-01 00:00:00 UTC"))
                                        ]
                                    )
                            }
                }
        caveatedQuery =
            UsersetQuery
                { queryType = ObjectType "space"
                , queryRelation = RelationName "viewer"
                , querySubjects = [caveatedTuple.subject]
                , queryLimit = 10
                , queryCursor = Nothing
                }
    caveatedToken <- runPgOrFail connection config (TupleStore.writeTuples [caveatedTuple])
    TokenMetadata{revision = caveatedRevision} <- either (fail . show) pure (tokenMetadataFromPayload caveatedToken)
    TuplePage{rows = caveatedRows, state = caveatedState} <- runPgOrFail connection config (TupleStore.readStartingWithUser caveatedRevision caveatedQuery)
    assertEqual "postgres tuple store round-trips typed caveat payloads" [caveatedTuple] ((.tuple) <$> caveatedRows)
    assertEqual "postgres caveated read is exhausted" Exhausted caveatedState
    let pgFolders =
            [ ObjectRef
                { objectType = ObjectType "folder"
                , objectId = "pg-folder-" <> showText index
                }
            | index <- [1 :: Int .. 1500]
            ]
        pgFolderTuples =
            [ Tuple
                { object = folder
                , relation = RelationName "viewer"
                , subject = SubjectId (ObjectRef (ObjectType "user") "paginator")
                , caveat = Nothing
                }
            | folder <- pgFolders
            ]
        pgLookupRequest cursor =
            LookupRequest
                { subject = SubjectId (ObjectRef (ObjectType "user") "paginator")
                , permission = RelationName "viewer"
                , objectType = ObjectType "folder"
                , context = CaveatContext Map.empty
                , limit = LookupLimit 400
                , cursor = cursor
                }
    pgToken <- runPgOrFail connection config (TupleStore.writeTuples pgFolderTuples)
    pgObjects <- collectLookupObjects connection config graph (AtLeastAsFresh pgToken) pgLookupRequest Nothing
    assertEqual "postgres-backed lookup drains multi-page storage reads" (sort pgFolders) pgObjects

type PostgresEffects = '[ConsistencyStore, TupleStore, Error EnError, Database, IOE]

runPg :: Connection.Connection -> ConsistencyConfig -> Eff PostgresEffects a -> IO (Either EnError a)
runPg connection config =
    runEff
        . runDatabaseConnection connection
        . runErrorNoCallStack
        . runTupleStorePostgres config
        . runConsistencyStorePostgres config

runPgOrFail :: Connection.Connection -> ConsistencyConfig -> Eff PostgresEffects a -> IO a
runPgOrFail connection config action =
    runPg connection config action >>= either (fail . show) pure

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

expectLookupHasMore :: String -> [LookupObject] -> Either EnError LookupPage -> IO LookupCursor
expectLookupHasMore label expectedObjects =
    \case
        Right LookupPage{objects, state = LookupHasMore cursor}
            | objects == expectedObjects -> pure cursor
        other -> fail (label <> "\nexpected objects with LookupHasMore, got: " <> show other)

collectLookupObjects ::
    Connection.Connection ->
    ConsistencyConfig ->
    ReachabilityGraph ->
    Consistency ->
    (Maybe LookupCursor -> LookupRequest) ->
    Maybe LookupCursor ->
    IO [ObjectRef]
collectLookupObjects connection config graph consistency mkRequest cursor = do
    page <- runPg connection config (Lookup.lookup graph consistency (mkRequest cursor))
    case page of
        Left err -> fail ("lookup failed while collecting postgres pages: " <> show err)
        Right LookupPage{objects, state} -> do
            let current = (.object) <$> objects
            case state of
                LookupExhausted -> pure current
                LookupHasMore next -> (current <>) <$> collectLookupObjects connection config graph consistency mkRequest (Just next)
                LookupTruncated next -> (current <>) <$> collectLookupObjects connection config graph consistency mkRequest (Just next)

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

showText :: (Show a) => a -> Text
showText =
    Text.pack . show

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
                ,
                    ( ObjectType "folder"
                    , Map.fromList
                        [ relationEntry "viewer" userSubject This
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
