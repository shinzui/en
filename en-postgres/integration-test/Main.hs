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
import En.Postgres.TupleStore (pruneTransactionsBatchSession, reapDeletedTuplesBatchSession, runTupleStorePostgres)
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
        runProbeScenario connection
        runMaintenanceBatchScenario connection
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
    {- Cursor validation against the real PostgreSQL validator, not a test double.
    Flipping one character inside the cursor's token field preserves the field's
    length prefix, so the cursor still parses -- and is then refused by `decodeToken`,
    which is the only thing standing between a client and a read at a revision of its
    choosing. A retired v1 cursor is refused at the parse step, before any token is
    consulted, because its revision field was exactly that. -}
    let LookupCursor projectXCursorText = projectXCursor
        corruptedTokenCursor = LookupCursor (Text.replace ":en1." ":xn1." projectXCursorText)
    assertEqual
        "postgres-backed lookup rejects a cursor whose token was tampered with"
        (Left (InvalidConsistencyToken "TokenBadPrefix"))
        =<< runPg connection config (Lookup.lookup graph (AtLeastAsFresh writeToken) (lookupRequest (Just corruptedTokenCursor)))
    assertEqual
        "postgres-backed lookup rejects a retired v1 cursor"
        (Left (InvalidConsistencyToken "lookup cursor"))
        =<< runPg connection config (Lookup.lookup graph (AtLeastAsFresh writeToken) (lookupRequest (Just (LookupCursor "lookup-v1|13:test-revision|0:|0:"))))
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

{- | The point-membership probe against real storage.

Seeds a relation wider than one read page (1500 rows), then proves the four
properties @check@ relies on: a present subject comes back with its caveat name
and payload intact, an absent subject comes back empty, a subject and its type
wildcard can be probed together in one call, and a soft-deleted grant is invisible
at revisions after the delete while remaining visible at revisions before it.

Finally it asks PostgreSQL how it intends to answer the probe. The probe must
be served by an index; a sequential scan over a wide relation would reintroduce
the very cost the probe exists to remove.
-}
runProbeScenario :: Connection.Connection -> IO ()
runProbeScenario connection = do
    validCheckSchema <- either (fail . show) pure (Schema.validateSchema checkSchema)
    let config =
            ConsistencyConfig
                { datastoreId = DatastoreId "test-datastore"
                , schemaHash = Schema.schemaHash validCheckSchema
                , gcWindow = "24 hours"
                }
        wideFolder = ObjectRef (ObjectType "folder") "probe-wide"
        viewer = RelationName "viewer"
        userRef name = ObjectRef (ObjectType "user") name
        member = SubjectId (userRef "probe-member")
        absent = SubjectId (userRef "probe-absent")
        caveatedSubject = SubjectId (userRef "probe-caveated")
        probeCaveat =
            TupleCaveat
                { name = CaveatName "within_autonomy"
                , payload = CaveatPayload (Map.fromList [("autonomy", ValueEnum "act"), ("level", ValueInteger 3)])
                }
        grant subject caveat = Tuple{object = wideFolder, relation = viewer, subject, caveat}
        fillerTuples =
            [ grant (SubjectId (userRef ("probe-filler-" <> showText index))) Nothing
            | index <- [1 :: Int .. 1500]
            ]
        memberTuple = grant member Nothing
        caveatedTuple = grant caveatedSubject (Just probeCaveat)
        publicSpace = ObjectRef (ObjectType "space") "probe-public"
        wildcardTuple = Tuple{object = publicSpace, relation = viewer, subject = SubjectWildcard (ObjectType "user"), caveat = Nothing}
        concreteTuple = Tuple{object = publicSpace, relation = viewer, subject = member, caveat = Nothing}

    seedToken <- runPgOrFail connection config (TupleStore.writeTuples (memberTuple : caveatedTuple : wildcardTuple : concreteTuple : fillerTuples))
    TokenMetadata{revision = seedRevision} <- either (fail . show) pure (tokenMetadataFromPayload seedToken)

    presentRows <- runPgOrFail connection config (TupleStore.probeTuples seedRevision wideFolder viewer [member])
    assertEqual "probe finds a member of a relation wider than one page" [memberTuple] ((.tuple) <$> presentRows)

    absentRows <- runPgOrFail connection config (TupleStore.probeTuples seedRevision wideFolder viewer [absent])
    assertEqual "probe returns nothing for an absent subject" [] ((.tuple) <$> absentRows)

    emptyCandidates <- runPgOrFail connection config (TupleStore.probeTuples seedRevision wideFolder viewer [])
    assertEqual "probe with no candidates returns nothing" [] ((.tuple) <$> emptyCandidates)

    caveatedRows <- runPgOrFail connection config (TupleStore.probeTuples seedRevision wideFolder viewer [caveatedSubject])
    assertEqual "probe carries the caveat name and payload" [Just probeCaveat] ((.tuple.caveat) <$> caveatedRows)

    wildcardRows <- runPgOrFail connection config (TupleStore.probeTuples seedRevision publicSpace viewer [member, SubjectWildcard (ObjectType "user")])
    assertEqual "probe matches a subject and its type wildcard in one call" (sort [concreteTuple, wildcardTuple]) (sort ((.tuple) <$> wildcardRows))

    deleteToken <- runPgOrFail connection config (TupleStore.deleteTuples [memberTuple])
    TokenMetadata{revision = deleteRevision} <- either (fail . show) pure (tokenMetadataFromPayload deleteToken)
    rowsBeforeDelete <- runPgOrFail connection config (TupleStore.probeTuples seedRevision wideFolder viewer [member])
    rowsAfterDelete <- runPgOrFail connection config (TupleStore.probeTuples deleteRevision wideFolder viewer [member])
    assertEqual "probe at the pre-delete revision still sees the grant" [memberTuple] ((.tuple) <$> rowsBeforeDelete)
    assertEqual "probe at the post-delete revision hides the grant" [] ((.tuple) <$> rowsAfterDelete)

    runSessionOrFail connection (Session.script "ANALYZE relation_tuple")
    planLines <- runSessionOrFail connection (Session.statement () explainProbeStatement)
    let plan = Text.unlines planLines
    assertBool ("probe is served by an index, not a sequential scan; plan was:\n" <> Text.unpack plan) (Text.isInfixOf "Index Scan" plan || Text.isInfixOf "Bitmap Index Scan" plan)

{- | Ask the planner how it would answer a probe. Mirrors 'probeTuplesStatement'
with literal parameters, since @EXPLAIN@ of a prepared statement would report a
generic plan rather than the one the probe's actual bindings produce.
-}
explainProbeStatement :: Statement () [Text]
explainProbeStatement =
    Statement.preparable
        """
        EXPLAIN (COSTS OFF)
        SELECT id FROM relation_tuple
        WHERE object_type = 'folder' AND object_id = 'probe-wide' AND relation = 'viewer'
          AND (subject_type, subject_id, coalesce(subject_relation, '')) IN
              (SELECT * FROM unnest(ARRAY['user'], ARRAY['probe-member'], ARRAY['']))
        """
        Encoders.noParams
        (Decoders.rowList (Decoders.column (Decoders.nonNullable Decoders.text)))

{- | Bounded-work maintenance: batched reap and batched prune.

Seeds a backlog larger than the batch size, drains it, and proves three properties the
background maintenance loop depends on: no call removes more than its batch, the drained
counts sum to the backlog, and rows at or after the horizon survive. The horizon is a
literal (@1000@) rather than a derived one so the boundary rows can be placed exactly on
it -- @< horizon@ must exclude a row whose xid equals the horizon.
-}
runMaintenanceBatchScenario :: Connection.Connection -> IO ()
runMaintenanceBatchScenario connection = do
    runSessionOrFail connection (Session.script maintenanceSeedSql)

    reapCounts <-
        drainBatches batchSize \batch ->
            runSessionOrFail connection (reapDeletedTuplesBatchSession horizon batch)
    assertEqual "no reap batch exceeds the batch size" True (all (<= fromIntegral batchSize) reapCounts)
    assertEqual "reap batches sum to the soft-deleted backlog" 25 (sum reapCounts)
    assertEqual "reap drains in ceil(25/10) batches" 3 (length reapCounts)
    drainedReap <- runSessionOrFail connection (reapDeletedTuplesBatchSession horizon batchSize)
    assertEqual "a drained reap backlog returns zero" 0 drainedReap
    survivingTuples <- runSessionOrFail connection (Session.statement () (countStatement "SELECT count(*) FROM relation_tuple"))
    assertEqual "reap spares the live tuple and the one deleted at the horizon" 2 survivingTuples

    pruneCounts <-
        drainBatches batchSize \batch ->
            runSessionOrFail connection (pruneTransactionsBatchSession horizon batch)
    assertEqual "no prune batch exceeds the batch size" True (all (<= fromIntegral batchSize) pruneCounts)
    assertEqual "prune batches sum to the transaction backlog" 25 (sum pruneCounts)
    drainedPrune <- runSessionOrFail connection (pruneTransactionsBatchSession horizon batchSize)
    assertEqual "a drained prune backlog returns zero" 0 drainedPrune
    survivingTransactions <- runSessionOrFail connection (Session.statement () (countStatement "SELECT count(*) FROM en_transaction"))
    assertEqual "prune spares transactions at and after the horizon" 2 survivingTransactions
  where
    horizon = 1000
    batchSize = 10

{- | Run @step@ with the batch size until it reports a short batch, collecting each
count. This is the loop the maintenance thread runs.
-}
drainBatches :: Int -> (Int -> IO Int64) -> IO [Int64]
drainBatches batch step = go []
  where
    go acc = do
        removed <- step batch
        let acc' = acc <> [removed]
        if removed < fromIntegral batch
            then pure acc'
            else go acc'

runSessionOrFail :: Connection.Connection -> Session.Session a -> IO a
runSessionOrFail connection session =
    Connection.use connection session >>= either (fail . show) pure

countStatement :: Text -> Statement () Int64
countStatement sql =
    Statement.preparable
        sql
        Encoders.noParams
        (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

{- | 25 reapable tuples, one deleted exactly at the horizon, one live; likewise 25
prunable transactions plus two at or after the horizon.
-}
maintenanceSeedSql :: Text
maintenanceSeedSql =
    """
    TRUNCATE relation_tuple, en_transaction;

    INSERT INTO relation_tuple
      (object_type, object_id, relation, subject_type, subject_id, created_xid, deleted_xid)
    SELECT 'space', 'reapable-' || g, 'viewer', 'user', 'alice', '1'::xid8, g::text::xid8
    FROM generate_series(1, 25) g;

    INSERT INTO relation_tuple
      (object_type, object_id, relation, subject_type, subject_id, created_xid, deleted_xid)
    VALUES ('space', 'at-horizon', 'viewer', 'user', 'alice', '1'::xid8, '1000'::xid8);

    INSERT INTO relation_tuple
      (object_type, object_id, relation, subject_type, subject_id, created_xid, deleted_xid)
    VALUES ('space', 'live', 'viewer', 'user', 'alice', '1'::xid8, NULL);

    INSERT INTO en_transaction (xid, schema_hash)
    SELECT g::text::xid8, 'test' FROM generate_series(1, 25) g;

    INSERT INTO en_transaction (xid, schema_hash)
    VALUES ('1000'::xid8, 'test'), ('1001'::xid8, 'test');
    """

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

assertBool :: String -> Bool -> IO ()
assertBool label = \case
    True -> pure ()
    False -> fail label

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
