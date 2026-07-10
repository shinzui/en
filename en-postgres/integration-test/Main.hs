{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE MultilineStrings #-}

module Main (main) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryReadMVar)
import Control.Exception (finally)
import Data.Either (isRight)
import Data.Foldable (traverse_)
import Data.Functor.Contravariant ((>$<))
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.List (nub, sort)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64)
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Effectful.Dispatch.Dynamic (interpose, passthrough)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Numeric (readDec)

import En.Check (CheckDecision (..), CheckOutcome (..), check)
import En.Conformance.Kikan (matchesRelationshipFilter)
import En.Effect.ConsistencyStore (ConsistencyStore, ResolvedConsistency (..), TokenMetadata (..))
import En.Effect.ConsistencyStore qualified as ConsistencyStore
import En.Effect.TupleStore (
    ChangeKind (..),
    ChangePage (..),
    PageState (..),
    Precondition (..),
    RelationshipFilter (..),
    StoreCursor (..),
    SubjectRelationFilter (..),
    TupleChange (..),
    TuplePage (..),
    TupleRow (..),
    TupleStore (..),
    TupleWriteRequest (..),
    UsersetQuery (..),
    exactTupleFilter,
 )
import En.Effect.TupleStore qualified as TupleStore
import En.Error (EnError (..))
import En.Lookup (LookupCursor (..), LookupLimit (..), LookupObject (..), LookupPage (..), LookupRequest (..), LookupState (..))
import En.Lookup qualified as Lookup
import En.Postgres.Database (Database, runDatabaseConnection)
import En.Postgres.Revision (ConsistencyConfig (..), PgSnapshot (..), comparePgSnapshot, parsePgSnapshot, renderPgSnapshot, runConsistencyStorePostgres, tokenMetadataFromPayload, transactionVisible)
import En.Postgres.TupleStore (pruneTransactionsBatchSession, reapDeletedTuplesBatchSession, runTupleStorePostgres)
import En.Postgres.Watch qualified as Watch
import En.Reachability (ReachabilityGraph, compile)
import En.Revision (Consistency (..), ConsistencyToken (..), DatastoreId (..), Revision (..), RevisionOrder (..))
import En.Schema (AllowedSubject (..), CaveatName (..), ObjectType (..), Relation (..), RelationName (..), Rewrite (..), Schema (..))
import En.Schema qualified as Schema
import En.Tuple (CaveatContext (..), CaveatPayload (..), CaveatValue (..), ObjectRef (..), Subject (..), Tuple (..), TupleCaveat (..))
import En.Watch (WatchBatch (..), WatchStart (..))
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
        runTouchSemanticsScenario connection
        runBatchWriteScenario connection
        runPreconditionScenario connection
        runWriteRaceScenario database connection
        runBatchTouchRaceScenario database connection
        runDecodeStrictnessScenario connection
        runSnapshotRepeatabilityScenario database connection
        runMaintenanceBatchScenario connection
        runConsistencyFetchCountScenario connection
        resetSchema connection
        runReadAllTuplesScenario connection
        resetSchema connection
        runRelationshipFilterScenario connection
        resetSchema connection
        runWatchWindowScenario connection
        resetSchema connection
        runWatchFeedScenario connection
        resetSchema connection
        runMigrationDedupeScenario connection
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
    {- A minted token survives the round trip through the real PostgreSQL codec and
    the real garbage-collection-window check. 'mintToken' is the inverse of
    'decodeToken', so what it produces for a revision the datastore just resolved
    must decode back to that revision and validate against this datastore's identity,
    schema hash, and GC horizon. If it did not, every @checkedAt@ below would be an
    opaque string a client could not spend. -}
    mintRoundTrip <- runPg connection config do
        ResolvedConsistency{revision} <- ConsistencyStore.resolveConsistency FullyConsistent
        minted <- ConsistencyStore.mintToken revision
        metadata <- ConsistencyStore.decodeToken minted
        ConsistencyStore.validateToken metadata
        pure (revision, metadata.revision)
    case mintRoundTrip of
        Right (resolved, decoded) ->
            assertEqual "a minted token decodes and validates back to its revision" resolved decoded
        other -> fail ("minting a token for a resolved revision failed: " <> show other)

    let graph = compile validCheckSchema
    checkOutcome <- runPg connection config (check graph (AtLeastAsFresh writeToken) (CaveatContext Map.empty) tuple.subject (RelationName "view") projectX)
    assertEqual "postgres-backed check sees written tuple" (Right Allowed) (fmap (.decision) checkOutcome)
    {- E3, end to end against PostgreSQL: the token a check reports is a token a later
    read accepts as its freshness bound. This is the write -> check -> lookup chain a
    client builds "read your own reads" out of, and the one an @EnGrant@ needs in order
    to record the snapshot its decision was made at. -}
    checkedAtToken <- either (\err -> fail ("check failed: " <> show err)) (pure . (.checkedAt)) checkOutcome
    assertEqual
        "a check's checkedAt token is accepted as a later read's freshness bound"
        (Right Allowed)
        . fmap (.decision)
        =<< runPg connection config (check graph (AtLeastAsFresh checkedAtToken) (CaveatContext Map.empty) tuple.subject (RelationName "view") projectX)

    lookupFirstPage <- runPg connection config (Lookup.lookup graph (AtLeastAsFresh writeToken) (lookupRequest Nothing))
    projectXCursor <- expectLookupHasMore "postgres-backed lookup returns first cursor page" [LookupObject{object = projectX, decision = Allowed}] lookupFirstPage
    firstPageToken <- either (\err -> fail ("lookup failed: " <> show err)) (pure . (.checkedAt)) lookupFirstPage
    lookupSecondPage <- runPg connection config (Lookup.lookup graph (AtLeastAsFresh writeToken) (lookupRequest (Just projectXCursor)))
    assertEqual
        "postgres-backed lookup resumes from cursor"
        ( Right
            LookupPage
                { objects = [LookupObject{object = projectY, decision = Allowed}]
                , state = LookupExhausted
                , checkedAt = firstPageToken
                }
        )
        lookupSecondPage
    {- The resumed page reports the token the first page did, and it does so because the
    cursor carries that very token and the continuation reads at the revision the
    /validated/ token names. One lookup, one snapshot, however many pages. -}
    assertEqual
        "a resumed lookup page reports the first page's token"
        (Right firstPageToken)
        (fmap (.checkedAt) lookupSecondPage)
    -- And a lookup's own token is spendable, exactly as a check's is.
    assertEqual
        "a lookup page's checkedAt token is accepted as a later read's freshness bound"
        (Right Allowed)
        . fmap (.decision)
        =<< runPg connection config (check graph (AtLeastAsFresh firstPageToken) (CaveatContext Map.empty) tuple.subject (RelationName "view") projectX)
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

{- | Touch semantics: what a write that collides with a live grant means.

Scenarios 1 and 2 are the two authorization-correctness traps of finding C1 in
@docs/reviews/2026-07-07-architecture-performance-review.md@. Against the
pre-plan write path scenario 1 reads back the /old/ expiry (the replacement was
dropped by @ON CONFLICT DO NOTHING@ while the caller got a success token) and
scenario 2 reads back two live rows (the caveated grant was inserted alongside
the unconditional one it was meant to tighten, so the tightening did nothing).

Each sub-scenario uses its own object so the reads cannot see each other's rows.
-}
runTouchSemanticsScenario :: Connection.Connection -> IO ()
runTouchSemanticsScenario connection = do
    validCheckSchema <- either (fail . show) pure (Schema.validateSchema checkSchema)
    let config =
            ConsistencyConfig
                { datastoreId = DatastoreId "test-datastore"
                , schemaHash = Schema.schemaHash validCheckSchema
                , gcWindow = "24 hours"
                }
        viewer = RelationName "viewer"
        alice = SubjectId (ObjectRef (ObjectType "user") "touch-alice")
        spaceRef name = ObjectRef (ObjectType "space") name
        grant object caveat = Tuple{object, relation = viewer, subject = alice, caveat}
        untilCaveat expiry =
            TupleCaveat
                { name = CaveatName "within_autonomy"
                , payload = CaveatPayload (Map.fromList [("until", ValueTimestamp expiry)])
                }
        july = read "2026-07-01 00:00:00 UTC"
        december = read "2026-12-31 00:00:00 UTC"
        readAt revision object =
            (.rows) <$> runPgOrFail connection config (TupleStore.readObjectRelation revision object viewer 10 Nothing)
        writeAt tuples = do
            token <- runPgOrFail connection config (TupleStore.writeTuples tuples)
            TokenMetadata{revision} <- either (fail . show) pure (tokenMetadataFromPayload token)
            pure revision

    -- 1. A rewrite with a different payload takes effect, and the old token still
    --    sees the grant it was minted against.
    let payloadSpace = spaceRef "touch-payload"
    julyRevision <- writeAt [grant payloadSpace (Just (untilCaveat july))]
    decemberRevision <- writeAt [grant payloadSpace (Just (untilCaveat december))]
    rowsAtDecember <- readAt decemberRevision payloadSpace
    assertEqual "payload update leaves one live row" 1 (length rowsAtDecember)
    assertEqual
        "payload update takes effect at the write's token"
        [Just (untilCaveat december)]
        ((.tuple.caveat) <$> rowsAtDecember)
    rowsAtJuly <- readAt julyRevision payloadSpace
    assertEqual
        "the pre-rewrite token still sees the pre-rewrite payload"
        [Just (untilCaveat july)]
        ((.tuple.caveat) <$> rowsAtJuly)

    -- 2. Adding a caveat to an unconditional grant replaces it rather than
    --    coexisting with it.
    let tightenSpace = spaceRef "touch-tighten"
    _ <- writeAt [grant tightenSpace Nothing]
    tightenedRevision <- writeAt [grant tightenSpace (Just (untilCaveat july))]
    rowsAtTightened <- readAt tightenedRevision tightenSpace
    assertEqual "caveat tightening leaves one live row" 1 (length rowsAtTightened)
    assertEqual
        "caveat tightening retires the unconditional grant"
        [Just (untilCaveat july)]
        ((.tuple.caveat) <$> rowsAtTightened)

    -- 3. An identical rewrite is a no-op that does not churn the row.
    let idempotentSpace = spaceRef "touch-idempotent"
        idempotentTuple = grant idempotentSpace (Just (untilCaveat july))
    firstRevision <- writeAt [idempotentTuple]
    secondRevision <- writeAt [idempotentTuple]
    rowsAtFirst <- readAt firstRevision idempotentSpace
    rowsAtSecond <- readAt secondRevision idempotentSpace
    assertEqual "identical rewrite leaves one live row" 1 (length rowsAtSecond)
    assertEqual
        "identical rewrite does not replace the row"
        ((.rowId) <$> rowsAtFirst)
        ((.rowId) <$> rowsAtSecond)

    -- 4. The same identity written twice in one call resolves last-wins.
    let lastWinsSpace = spaceRef "touch-last-wins"
    lastWinsRevision <-
        writeAt
            [ grant lastWinsSpace (Just (untilCaveat july))
            , grant lastWinsSpace (Just (untilCaveat december))
            ]
    rowsAtLastWins <- readAt lastWinsRevision lastWinsSpace
    assertEqual "same key twice in one call leaves one live row" 1 (length rowsAtLastWins)
    assertEqual
        "same key twice in one call keeps the last write"
        [Just (untilCaveat december)]
        ((.tuple.caveat) <$> rowsAtLastWins)

    -- 5. A delete targets the identity, ignoring the caveat the caller supplies.
    let deleteSpace = spaceRef "touch-delete"
    _ <- writeAt [grant deleteSpace (Just (untilCaveat december))]
    deleteToken <- runPgOrFail connection config (TupleStore.deleteTuples [grant deleteSpace Nothing])
    TokenMetadata{revision = deleteRevision} <- either (fail . show) pure (tokenMetadataFromPayload deleteToken)
    rowsAtDelete <- readAt deleteRevision deleteSpace
    assertEqual "delete ignores the request's caveat and retires the grant" 0 (length rowsAtDelete)

{- | The batched write path, where per-tuple statements cannot hide a mistake.

One @unnest@ statement applies the whole request, so every tuple's touch outcome
is decided by the /same/ statement rather than by its own. Three things can go
wrong there that no single-tuple test would notice.

A batch whose entries need different outcomes — one already identical, one
carrying a new caveat, one absent entirely — is the shape that catches an
off-by-one in the convergence check's ordinality mapping: the retry would insert
a satisfied entry and raise @unique_violation@, or skip an unsatisfied one and
drop the write. Scenario 2 mixes all three in one call.

A batch carrying one identity twice must still resolve last-wins.
@ON CONFLICT DO NOTHING@ keeps whichever conflicting row the executor reaches
first, so without client-side deduplication scenario 3 resolves arbitrary-wins,
and does so nondeterministically enough to pass on most runs.

Scenario 1 is the plain volume case: it fails outright if the arrays are
transposed wrongly, since the columns would be zipped into the wrong rows.
-}
runBatchWriteScenario :: Connection.Connection -> IO ()
runBatchWriteScenario connection = do
    config <- testConfig
    let viewer = RelationName "viewer"
        alice = SubjectId (ObjectRef (ObjectType "user") "batch-alice")
        spaceRef name = ObjectRef (ObjectType "space") name
        grant object caveat = Tuple{object, relation = viewer, subject = alice, caveat}
        untilCaveat expiry =
            TupleCaveat
                { name = CaveatName "within_autonomy"
                , payload = CaveatPayload (Map.fromList [("until", ValueTimestamp expiry)])
                }
        july = read "2026-07-01 00:00:00 UTC"
        december = read "2026-12-31 00:00:00 UTC"
        readAt revision object =
            (.rows) <$> runPgOrFail connection config (TupleStore.readObjectRelation revision object viewer 10 Nothing)
        writeAt tuples = do
            token <- runPgOrFail connection config (TupleStore.writeTuples tuples)
            TokenMetadata{revision} <- either (fail . show) pure (tokenMetadataFromPayload token)
            pure revision

    -- 1. A hundred tuples in one call are all readable at the returned token.
    let hundred =
            [ grant (spaceRef ("batch-volume-" <> Text.pack (show index))) Nothing
            | index <- [1 :: Int .. 100]
            ]
    volumeRevision <- writeAt hundred
    volumePage <-
        runPgOrFail connection config $
            TupleStore.readStartingWithUser
                volumeRevision
                UsersetQuery
                    { queryType = ObjectType "space"
                    , queryRelation = viewer
                    , querySubjects = [alice]
                    , queryLimit = 200
                    , queryCursor = Nothing
                    }
    assertEqual "a hundred-tuple batch writes a hundred live rows" 100 (length volumePage.rows)
    assertEqual
        "every tuple in the batch survives its columns' transposition"
        (sort ((.object.objectId) <$> hundred))
        (sort ((.tuple.object.objectId) <$> volumePage.rows))

    -- 2. One batch whose entries need three different touch outcomes.
    let identicalSpace = spaceRef "batch-mixed-identical"
        replacedSpace = spaceRef "batch-mixed-replaced"
        createdSpace = spaceRef "batch-mixed-created"
    seedRevision <-
        writeAt
            [ grant identicalSpace (Just (untilCaveat july))
            , grant replacedSpace (Just (untilCaveat july))
            ]
    seededIdenticalRows <- readAt seedRevision identicalSpace
    mixedRevision <-
        writeAt
            [ grant identicalSpace (Just (untilCaveat july))
            , grant replacedSpace (Just (untilCaveat december))
            , grant createdSpace Nothing
            ]
    identicalRows <- readAt mixedRevision identicalSpace
    replacedRows <- readAt mixedRevision replacedSpace
    createdRows <- readAt mixedRevision createdSpace
    assertEqual
        "an identical entry in a mixed batch does not churn its row"
        ((.rowId) <$> seededIdenticalRows)
        ((.rowId) <$> identicalRows)
    assertEqual "a replaced entry in a mixed batch leaves one live row" 1 (length replacedRows)
    assertEqual
        "a replaced entry in a mixed batch takes the new caveat"
        [Just (untilCaveat december)]
        ((.tuple.caveat) <$> replacedRows)
    assertEqual
        "a new entry in a mixed batch is created"
        [Nothing]
        ((.tuple.caveat) <$> createdRows)

    -- 3. A duplicate identity inside a larger batch still resolves last-wins.
    let duplicateSpace = spaceRef "batch-duplicate"
        bystanderSpace = spaceRef "batch-duplicate-bystander"
    duplicateRevision <-
        writeAt
            [ grant duplicateSpace (Just (untilCaveat july))
            , grant bystanderSpace Nothing
            , grant duplicateSpace (Just (untilCaveat december))
            ]
    duplicateRows <- readAt duplicateRevision duplicateSpace
    bystanderRows <- readAt duplicateRevision bystanderSpace
    assertEqual "a duplicate identity in one batch leaves one live row" 1 (length duplicateRows)
    assertEqual
        "a duplicate identity in one batch keeps the last write"
        [Just (untilCaveat december)]
        ((.tuple.caveat) <$> duplicateRows)
    assertEqual "deduplication does not drop the batch's other entries" 1 (length bystanderRows)

    -- 4. Four copies of one identity. Three would survive without deduplication:
    --    each attempt inserts the earliest surviving copy and drops the rest, so
    --    the retry ladder walks the batch down to the last copy and lands on
    --    last-wins anyway. Four is where that accident stops. The convergence
    --    check hands the fallback two copies of one identity, and the fallback's
    --    insert omits @ON CONFLICT@ by design, so PostgreSQL raises
    --    @unique_violation@ and a legitimate write becomes a StoreError.
    let quadrupleSpace = spaceRef "batch-quadruple"
        marchCaveat = untilCaveat (read "2026-03-01 00:00:00 UTC")
        aprilCaveat = untilCaveat (read "2026-04-01 00:00:00 UTC")
    quadrupleRevision <-
        writeAt
            [ grant quadrupleSpace (Just marchCaveat)
            , grant quadrupleSpace (Just aprilCaveat)
            , grant quadrupleSpace (Just (untilCaveat july))
            , grant quadrupleSpace (Just (untilCaveat december))
            ]
    quadrupleRows <- readAt quadrupleRevision quadrupleSpace
    assertEqual "four copies of one identity leave one live row" 1 (length quadrupleRows)
    assertEqual
        "four copies of one identity keep the last write"
        [Just (untilCaveat december)]
        ((.tuple.caveat) <$> quadrupleRows)

{- | Preconditions, sequentially: what a guarded write means on its own.

Four properties. A guarded revoke succeeds once and then refuses to succeed
again, which is the sequential shadow of gap E1 — before preconditions the second
revoke returned a token having done nothing. A failed precondition writes
nothing. Writes and deletes mix in one atomic request under one token. And the
explicit @ROLLBACK@ leaves the connection usable, which every later assertion in
this function silently depends on.
-}
runPreconditionScenario :: Connection.Connection -> IO ()
runPreconditionScenario connection = do
    config <- testConfig
    let alice = SubjectId (ObjectRef (ObjectType "user") "precondition-alice")
        viewer = RelationName "viewer"
        spaceRef name = ObjectRef (ObjectType "space") name
        grant object caveat = Tuple{object, relation = viewer, subject = alice, caveat}
        readAt revision object =
            (.rows) <$> runPgOrFail connection config (TupleStore.readObjectRelation revision object viewer 10 Nothing)
        headRows object = do
            revision <- runPgOrFail connection config TupleStore.headRevision
            readAt revision object

    -- 1. A guarded revoke succeeds once, then refuses.
    let revokeSpace = spaceRef "precondition-revoke"
        revokeTuple = grant revokeSpace Nothing
        guardedRevoke =
            TupleStore.applyTupleWrites
                TupleWriteRequest
                    { preconditions = [TupleMustExist (exactTupleFilter revokeTuple)]
                    , writes = []
                    , deletes = [revokeTuple]
                    }
    _ <- runPgOrFail connection config (TupleStore.writeTuples [revokeTuple])
    firstRevoke <- runPg connection config guardedRevoke
    assertBool
        ("the first guarded revoke succeeds; got " <> show firstRevoke)
        (either (const False) (const True) firstRevoke)
    secondRevoke <- runPg connection config guardedRevoke
    assertBool
        ("the second guarded revoke fails its precondition; got " <> show secondRevoke)
        (isPreconditionFailure secondRevoke)
    assertEqual "the revoked grant stays revoked" 0 . length =<< headRows revokeSpace

    -- 2. A failed precondition writes nothing -- and leaves the connection healthy.
    let unwrittenSpace = spaceRef "precondition-unwritten"
        unwrittenTuple = grant unwrittenSpace Nothing
        absentTuple = grant (spaceRef "precondition-absent") Nothing
    refused <-
        runPg
            connection
            config
            ( TupleStore.applyTupleWrites
                TupleWriteRequest
                    { preconditions = [TupleMustExist (exactTupleFilter absentTuple)]
                    , writes = [unwrittenTuple]
                    , deletes = []
                    }
            )
    assertBool
        ("a write guarded on an absent tuple is refused; got " <> show refused)
        (isPreconditionFailure refused)
    assertEqual "a refused write leaves no row behind" 0 . length =<< headRows unwrittenSpace

    -- 3. Writes and deletes mix in one request under one token.
    let mixedOld = spaceRef "precondition-mixed-old"
        mixedNew = spaceRef "precondition-mixed-new"
        oldTuple = grant mixedOld Nothing
        newTuple = grant mixedNew Nothing
    _ <- runPgOrFail connection config (TupleStore.writeTuples [oldTuple])
    mixedToken <-
        runPgOrFail
            connection
            config
            ( TupleStore.applyTupleWrites
                TupleWriteRequest{preconditions = [], writes = [newTuple], deletes = [oldTuple]}
            )
    TokenMetadata{revision = mixedRevision} <- either (fail . show) pure (tokenMetadataFromPayload mixedToken)
    assertEqual "the mixed request's token sees the new grant" 1 . length =<< readAt mixedRevision mixedNew
    assertEqual "the mixed request's token does not see the old grant" 0 . length =<< readAt mixedRevision mixedOld

    -- 4. A must-not-exist precondition guards against clobbering an existing grant.
    let guardSpace = spaceRef "precondition-guard"
        guardTuple = grant guardSpace Nothing
    _ <- runPgOrFail connection config (TupleStore.writeTuples [guardTuple])
    clobber <-
        runPg
            connection
            config
            ( TupleStore.applyTupleWrites
                TupleWriteRequest
                    { preconditions = [TupleMustNotExist (exactTupleFilter guardTuple)]
                    , writes = [guardTuple]
                    , deletes = []
                    }
            )
    assertBool
        ("a write guarded on the grant's absence is refused when it exists; got " <> show clobber)
        (isPreconditionFailure clobber)

{- | Preconditions, concurrently: gap E1 itself.

Two administrators, each on its own connection, issue the same must-exist-guarded
revoke. Exactly one must win.

Forking two threads does not by itself make them race: the first finishes its
whole transaction before the second reaches the row, and the test passes without
ever contending for a lock -- it passes just as happily against a @FOR SHARE@
implementation, which is broken. So a third connection takes the row's lock
first, both racers are observed to /block/ on it, and only then is the lock
released. From that moment the two are genuinely contending.

With @FOR UPDATE@, one racer takes the lock, retires the grant and commits, while
the other waits at its own @SELECT@, re-evaluates the row under @READ COMMITTED@,
finds @deleted_xid@ set, and fails its precondition. With @FOR SHARE@ both would
acquire compatible share locks, both would pass the check, and both would then
deadlock upgrading to the exclusive lock their @UPDATE@ needs -- so one comes
back with a @deadlock_detected@ 'StoreError' and the precondition assertion
below fails. That is the difference this scenario exists to detect.
-}
runWriteRaceScenario :: Pg.Database -> Connection.Connection -> IO ()
runWriteRaceScenario database connection = do
    config <- testConfig
    leftConnection <- acquire database
    rightConnection <- acquire database
    blocker <- acquire database
    let racedSpace = ObjectRef (ObjectType "space") "race-revoke"
        racedTuple =
            Tuple
                { object = racedSpace
                , relation = RelationName "viewer"
                , subject = SubjectId (ObjectRef (ObjectType "user") "race-alice")
                , caveat = Nothing
                }
        guardedRevoke =
            TupleStore.applyTupleWrites
                TupleWriteRequest
                    { preconditions = [TupleMustExist (exactTupleFilter racedTuple)]
                    , writes = []
                    , deletes = [racedTuple]
                    }
    _ <- runPgOrFail connection config (TupleStore.writeTuples [racedTuple])

    -- Hold the raced row's lock so neither racer can get past its precondition.
    runSessionOrFail blocker (Session.script "BEGIN")
    lockedRow <- runSessionOrFail blocker (Session.statement () lockRacedRowStatement)
    assertEqual "the blocker locks the raced grant" 1 (length lockedRow)

    leftResult <- newEmptyMVar
    rightResult <- newEmptyMVar
    _ <- forkIO (putMVar leftResult =<< runPg leftConnection config guardedRevoke)
    _ <- forkIO (putMVar rightResult =<< runPg rightConnection config guardedRevoke)

    -- Long enough that a racer which was going to finish would have finished.
    threadDelay 500_000
    pendingLeft <- tryReadMVar leftResult
    pendingRight <- tryReadMVar rightResult
    assertEqual
        ("both racers block while the raced row is locked; got " <> show (pendingLeft, pendingRight))
        (Nothing, Nothing)
        (pendingLeft, pendingRight)

    -- Release the lock without changing the row: now the two contend with each other.
    runSessionOrFail blocker (Session.script "ROLLBACK")
    outcomes <- traverse takeMVar [leftResult, rightResult]

    assertEqual
        ("exactly one racing revoke receives a token; got " <> show outcomes)
        1
        (length (filter isRight outcomes))
    assertEqual
        ("exactly one racing revoke fails its precondition; got " <> show outcomes)
        1
        (length (filter isPreconditionFailure outcomes))

    headRevision <- runPgOrFail connection config TupleStore.headRevision
    TuplePage{rows = survivingRows} <-
        runPgOrFail connection config (TupleStore.readObjectRelation headRevision racedSpace (RelationName "viewer") 10 Nothing)
    assertEqual "the raced grant is revoked exactly once" 0 (length survivingRows)

    traverse_ Connection.release [leftConnection, rightConnection, blocker]

{- | Draining the whole graph at one revision: the primitive bulk export is built on.

Runs against a freshly reset schema, because 'TupleStore.readAllTuples' returns
every live tuple in the store and any row an earlier scenario left behind would
be indistinguishable from a paging bug.

Two properties. The drain is /complete/: 1,500 tuples written in one batch come
back across four pages of 400 with no row seen twice and no row missed, ending
'Exhausted' rather than at a cursor that resumes forever. And the drain is a
/snapshot/: a tuple written after the revision was captured is invisible to a
page fetched afterwards, so an export that takes minutes still describes the
graph as it stood when it began, rather than smearing concurrent writers across
its pages.
-}
runReadAllTuplesScenario :: Connection.Connection -> IO ()
runReadAllTuplesScenario connection = do
    config <- testConfig
    let viewer = RelationName "viewer"
        alice = SubjectId (ObjectRef (ObjectType "user") "drain-alice")
        drainTuples =
            [ Tuple
                { object = ObjectRef{objectType = ObjectType "space", objectId = "drain-" <> showText index}
                , relation = viewer
                , subject = alice
                , caveat = Nothing
                }
            | index <- [1 :: Int .. 1500]
            ]
        drainFrom revision =
            let step cursor seen = do
                    TuplePage{rows, state} <- runPgOrFail connection config (TupleStore.readAllTuples revision 400 cursor)
                    let seenNow = seen <> ((.tuple) <$> rows)
                    case state of
                        Exhausted -> pure seenNow
                        HasMore next -> step (Just next) seenNow
                        Truncated next -> step (Just next) seenNow
             in step Nothing []

    writeToken <- runPgOrFail connection config (TupleStore.writeTuples drainTuples)
    TokenMetadata{revision = drainRevision} <- either (fail . show) pure (tokenMetadataFromPayload writeToken)

    drained <- drainFrom drainRevision
    assertEqual "the drain returns every live tuple" 1500 (length drained)
    assertEqual "the drain returns no tuple twice" 1500 (Set.size (Set.fromList drained))
    assertEqual "the drain returns exactly what was written" (sort drainTuples) (sort drained)

    -- A writer proceeding during the export contributes nothing to it.
    _ <-
        runPgOrFail
            connection
            config
            ( TupleStore.writeTuples
                [ Tuple
                    { object = ObjectRef{objectType = ObjectType "space", objectId = "drain-latecomer"}
                    , relation = viewer
                    , subject = alice
                    , caveat = Nothing
                    }
                ]
            )
    drainedAgain <- drainFrom drainRevision
    assertEqual "a tuple written after the revision is invisible to the drain" 1500 (length drainedAgain)

    headRevision <- runPgOrFail connection config TupleStore.headRevision
    drainedAtHead <- drainFrom headRevision
    assertEqual "the latecomer is visible at a later revision" 1501 (length drainedAtHead)

{- | The relationship fixture: two object types, every subject shape, and a caveat.

Each row exists to be distinguished from the others by some filter below. Without the
wildcard the @subjectId = "*"@ flattening goes untested; without the userset the
@coalesce(subject_relation, '')@ comparison the subject index is built on goes untested;
without the caveated grant the residual @caveat_name@ predicate goes untested.
-}
relationshipFixture :: [Tuple]
relationshipFixture =
    [ Tuple projectX (RelationName "owner") (SubjectId alice) Nothing
    , Tuple projectX (RelationName "viewer") (SubjectWildcard (ObjectType "user")) Nothing
    , Tuple projectX (RelationName "member") (SubjectSet acmeOrg (RelationName "member")) Nothing
    , Tuple projectY (RelationName "owner") (SubjectId alice) Nothing
    , Tuple readmeDoc (RelationName "viewer") (SubjectId alice) Nothing
    , Tuple readmeDoc (RelationName "viewer") (SubjectId bob) Nothing
    , Tuple delegation (RelationName "delegate") (SubjectId alice) (Just delegationCaveat)
    ]
  where
    projectX = ObjectRef (ObjectType "space") "project-x"
    projectY = ObjectRef (ObjectType "space") "project-y"
    readmeDoc = ObjectRef (ObjectType "doc") "readme"
    delegation = ObjectRef (ObjectType "intention") "42"
    acmeOrg = ObjectRef (ObjectType "org") "acme"
    alice = ObjectRef (ObjectType "user") "alice"
    bob = ObjectRef (ObjectType "user") "bob"
    delegationCaveat =
        TupleCaveat
            { name = CaveatName "within_autonomy"
            , payload = CaveatPayload (Map.fromList [("autonomy", ValueEnum "act")])
            }

{- | A 'RelationshipFilter' built positionally, in field order.

A constructor application rather than a record update over 'anyRelationshipFilter',
because @objectType@ and friends name fields of several types in scope in this module.
-}
relationshipFilter ::
    Maybe Text ->
    Maybe Text ->
    Maybe Text ->
    Maybe Text ->
    Maybe Text ->
    SubjectRelationFilter ->
    Maybe Text ->
    RelationshipFilter
relationshipFilter objectType objectId relation subjectType subjectId subjectRelation caveatName =
    RelationshipFilter
        { objectType = ObjectType <$> objectType
        , objectId
        , relation = RelationName <$> relation
        , subjectType = ObjectType <$> subjectType
        , subjectId
        , subjectRelation
        , caveatName = CaveatName <$> caveatName
        }

-- | Every filter shape the grammar admits that this fixture can distinguish.
relationshipFilterCases :: [(String, RelationshipFilter)]
relationshipFilterCases =
    [ ("object type", relationshipFilter (Just "space") Nothing Nothing Nothing Nothing AnySubjectRelation Nothing)
    , ("object type and id", relationshipFilter (Just "space") (Just "project-x") Nothing Nothing Nothing AnySubjectRelation Nothing)
    , ("object type, id, and relation", relationshipFilter (Just "space") (Just "project-x") (Just "owner") Nothing Nothing AnySubjectRelation Nothing)
    , ("object type and relation, residual", relationshipFilter (Just "space") Nothing (Just "owner") Nothing Nothing AnySubjectRelation Nothing)
    , ("subject", relationshipFilter Nothing Nothing Nothing (Just "user") (Just "alice") AnySubjectRelation Nothing)
    , ("wildcard subject", relationshipFilter Nothing Nothing Nothing (Just "user") (Just "*") AnySubjectRelation Nothing)
    , ("userset subject", relationshipFilter Nothing Nothing Nothing (Just "org") (Just "acme") (ExactSubjectRelation (RelationName "member")) Nothing)
    , ("subject carrying no relation", relationshipFilter Nothing Nothing Nothing (Just "user") (Just "alice") NoSubjectRelation Nothing)
    , ("subject with a caveat residual", relationshipFilter Nothing Nothing Nothing (Just "user") (Just "alice") AnySubjectRelation (Just "within_autonomy"))
    , ("object type with a caveat residual", relationshipFilter (Just "intention") Nothing Nothing Nothing Nothing AnySubjectRelation (Just "within_autonomy"))
    , ("both anchors", relationshipFilter (Just "doc") Nothing Nothing (Just "user") (Just "alice") AnySubjectRelation Nothing)
    ]

{- | Filter shapes this fixture deliberately leaves empty.

Asserted separately from 'relationshipFilterCases', which requires every case to match
something: a read that silently returned nothing would satisfy an expected-empty
assertion and a vacuous agreement assertion alike, so the two properties cannot be
checked by one list.
-}
emptyRelationshipFilterCases :: [(String, RelationshipFilter)]
emptyRelationshipFilterCases =
    [ ("an uncaveated object type under a caveat constraint", relationshipFilter (Just "space") Nothing Nothing Nothing Nothing AnySubjectRelation (Just "within_autonomy"))
    , ("a userset constraint on a concrete subject", relationshipFilter Nothing Nothing Nothing (Just "user") (Just "alice") (ExactSubjectRelation (RelationName "member")) Nothing)
    , ("a subject that holds nothing", relationshipFilter Nothing Nothing Nothing (Just "user") (Just "nobody") AnySubjectRelation Nothing)
    , ("a relation nobody holds on this type", relationshipFilter (Just "doc") Nothing (Just "owner") Nothing Nothing AnySubjectRelation Nothing)
    ]

{- | Filtered reads, counts, and delete-by-filter, against the real store.

The read assertions are made against 'matchesRelationshipFilter' — the in-memory matcher
the conformance store uses — rather than against hand-written expected sets. The two
implementations are independent (one compiles SQL, one walks a list), so agreeing on
every shape of the fixture is evidence that the filter means one thing, not two. A
hand-written expectation would only prove the SQL matches what its author believed.
-}
runRelationshipFilterScenario :: Connection.Connection -> IO ()
runRelationshipFilterScenario connection = do
    config <- testConfig
    writeToken <- runPgOrFail connection config (TupleStore.writeTuples relationshipFixture)
    TokenMetadata{revision = seeded} <- either (fail . show) pure (tokenMetadataFromPayload writeToken)

    let drain revision requested =
            let step cursor seen = do
                    TuplePage{rows, state} <-
                        runPgOrFail connection config (TupleStore.readRelationships revision requested 100 cursor)
                    let seenNow = seen <> ((.tuple) <$> rows)
                    case state of
                        Exhausted -> pure seenNow
                        HasMore next -> step (Just next) seenNow
                        Truncated next -> step (Just next) seenNow
             in step Nothing []

        expectedFor requested =
            [tuple | tuple <- relationshipFixture, matchesRelationshipFilter requested tuple]

    traverse_
        ( \(label, requested) -> do
            let expected = expectedFor requested
            stored <- drain seeded requested
            assertEqual
                ("the store and the in-memory matcher agree on the " <> label <> " filter")
                (sort expected)
                (sort stored)
            assertBool
                ("the " <> label <> " filter matches something, so the agreement is not vacuous")
                (not (null expected))
            count <- runPgOrFail connection config (TupleStore.countRelationships seeded requested)
            assertEqual
                ("countRelationships equals the read cardinality for the " <> label <> " filter")
                (fromIntegral (length expected) :: Int64)
                count
        )
        relationshipFilterCases

    traverse_
        ( \(label, requested) -> do
            assertEqual
                ("the in-memory matcher agrees that " <> label <> " matches nothing")
                []
                (expectedFor requested)
            stored <- drain seeded requested
            assertEqual ("the store returns no row for " <> label) [] stored
            count <- runPgOrFail connection config (TupleStore.countRelationships seeded requested)
            assertEqual ("the store counts zero rows for " <> label) 0 count
        )
        emptyRelationshipFilterCases

    -- Keyset pagination across the four grants naming alice.
    let aliceFilter = relationshipFilter Nothing Nothing Nothing (Just "user") (Just "alice") AnySubjectRelation Nothing
    firstPage <- runPgOrFail connection config (TupleStore.readRelationships seeded aliceFilter 2 Nothing)
    assertEqual "the first page carries the requested limit" 2 (length firstPage.rows)
    nextCursor <-
        case firstPage.state of
            HasMore cursor -> pure cursor
            other -> fail ("expected the first page to have more, got " <> show other)
    secondPage <- runPgOrFail connection config (TupleStore.readRelationships seeded aliceFilter 2 (Just nextCursor))
    assertEqual "the second page carries the remaining rows" 2 (length secondPage.rows)
    assertEqual "the second page is exhausted" Exhausted secondPage.state
    assertEqual
        "the two pages together are the whole match set, without repetition"
        (sort (expectedFor aliceFilter))
        (sort (((.tuple) <$> firstPage.rows) <> ((.tuple) <$> secondPage.rows)))

    -- Offboard alice: the count and the token describe the same set of rows.
    (deletedCount, deleteToken) <- runPgOrFail connection config (TupleStore.deleteRelationships aliceFilter)
    assertEqual "delete-by-filter retires every live match" 4 deletedCount
    TokenMetadata{revision = afterDelete} <- either (fail . show) pure (tokenMetadataFromPayload deleteToken)

    afterRows <- drain afterDelete aliceFilter
    assertEqual "a read at the delete's token no longer sees the retired grants" [] afterRows

    beforeRows <- drain seeded aliceFilter
    assertEqual
        "a read at the pre-delete snapshot still sees them: the delete is soft"
        (sort (expectedFor aliceFilter))
        (sort beforeRows)

    survivors <- runPgOrFail connection config (TupleStore.readAllTuples afterDelete 100 Nothing)
    assertEqual
        "the grants the filter did not name survive"
        (sort [tuple | tuple <- relationshipFixture, not (matchesRelationshipFilter aliceFilter tuple)])
        (sort ((.tuple) <$> survivors.rows))

    -- Idempotent in effect: nothing is left live for the filter to retire.
    (again, _) <- runPgOrFail connection config (TupleStore.deleteRelationships aliceFilter)
    assertEqual "re-running the same delete retires nothing" 0 again

{- | The visibility algebra of the changelog window, against a real PostgreSQL.

Everything the feed promises is a claim about @pg_visible_in_snapshot@ over @created_xid@
and @deleted_xid@, and none of it can be checked in memory: the in-memory store keeps no
history and has one revision. So this is where the contract lives.

Four claims. A write inside the window is a touch. A delete inside the window is a delete.
A grant written /and/ retired inside one window is nothing at all — the live set is
unchanged across it, and emitting a touch/delete pair would force consumers to order two
events the store cannot order. And a drain at @limit = 1@ visits every change exactly once,
including across the rows that emit no event, which is the case a paging bug hides in: the
resumption cursor names the last row /fetched/, not the last event /emitted/.
-}
runWatchWindowScenario :: Connection.Connection -> IO ()
runWatchWindowScenario connection = do
    config <- testConfig
    let space name = ObjectRef (ObjectType "space") name
        grant name = Tuple (space name) (RelationName "viewer") (SubjectId (ObjectRef (ObjectType "user") "alice")) Nothing
        kept = grant "kept"
        retired = grant "retired"
        ephemeral = grant "ephemeral"

        changesBetween start end limit =
            let step cursor seen = do
                    ChangePage{changes, state} <-
                        runPgOrFail connection config (TupleStore.readChanges start end Nothing limit cursor)
                    let seenNow = seen <> changes
                    case state of
                        Exhausted -> pure seenNow
                        HasMore next -> step (Just next) seenNow
                        Truncated next -> step (Just next) seenNow
             in step Nothing []

        event kind tuple = (kind, tuple)
        eventsOf = fmap (\change -> event change.kind change.tuple)

    before <- runPgOrFail connection config TupleStore.headRevision
    _ <- runPgOrFail connection config (TupleStore.writeTuples [kept, retired])
    afterWrites <- runPgOrFail connection config TupleStore.headRevision

    writeWindow <- changesBetween before afterWrites 100
    assertEqual
        "a write becomes a touch in the window that first sees it"
        (sort [event ChangeTouch kept, event ChangeTouch retired])
        (sort (eventsOf writeWindow))

    _ <- runPgOrFail connection config (TupleStore.deleteTuples [retired])
    afterDelete <- runPgOrFail connection config TupleStore.headRevision

    deleteWindow <- changesBetween afterWrites afterDelete 100
    assertEqual
        "a delete becomes a delete in the window that first sees it"
        [event ChangeDelete retired]
        (eventsOf deleteWindow)

    caughtUp <- changesBetween afterDelete afterDelete 100
    assertEqual "an empty window reports no changes" [] (eventsOf caughtUp)

    {- The net-no-op rule. @retired@ was written before @afterWrites@ and deleted before
    @afterDelete@, so the window spanning both sees its creation and its deletion become
    visible together, and must report neither. @kept@ still reports its touch. -}
    spanningWindow <- changesBetween before afterDelete 100
    assertEqual
        "a grant written and retired inside one window is not reported at all"
        [event ChangeTouch kept]
        (eventsOf spanningWindow)

    {- Paging across a window whose middle row emits nothing. @ephemeral@ sits between
    @kept@ and a later grant by row id, and is retired before the window closes, so a
    drain at @limit = 1@ must step over it without losing the row after it. -}
    _ <- runPgOrFail connection config (TupleStore.writeTuples [ephemeral])
    _ <- runPgOrFail connection config (TupleStore.deleteTuples [ephemeral])
    let latecomers = [grant "late-a", grant "late-b"]
    _ <- runPgOrFail connection config (TupleStore.writeTuples latecomers)
    afterLatecomers <- runPgOrFail connection config TupleStore.headRevision

    drained <- changesBetween before afterLatecomers 1
    wholeWindow <- changesBetween before afterLatecomers 100
    assertEqual
        "a drain at limit 1 sees every change exactly once, across rows that emit none"
        (sort (eventsOf wholeWindow))
        (sort (eventsOf drained))
    assertEqual
        "the drained window is the live-set delta, and nothing else"
        (sort (event ChangeTouch <$> (kept : latecomers)))
        (sort (eventsOf drained))
    assertEqual "a drain at limit 1 emits no duplicates" (length (eventsOf drained)) (length (nub (eventsOf drained)))

    -- A filter narrows the window to the grants it names, without changing their kinds.
    filtered <-
        runPgOrFail
            connection
            config
            ( TupleStore.readChanges
                before
                afterLatecomers
                (Just (relationshipFilter (Just "space") (Just "late-a") Nothing Nothing Nothing AnySubjectRelation Nothing))
                100
                Nothing
            )
    assertEqual
        "a filtered window reports only the grants the filter names"
        [event ChangeTouch (grant "late-a")]
        (eventsOf filtered.changes)

    {- The sargability claim, which no assertion above can reach: on a table of three rows
    every plan is a sequential scan, so the fixture is grown until the planner has a choice
    to make. The window is then opened /after/ the bulk, so the xmin bound excludes almost
    all of it — which is the shape a real poll has, and the shape the bound exists for. -}
    runSessionOrFail connection (Session.statement 20000 seedHistoryStatement)
    runSessionOrFail connection (Session.script "ANALYZE relation_tuple")
    explainStart <- runPgOrFail connection config TupleStore.headRevision
    _ <- runPgOrFail connection config (TupleStore.writeTuples [grant "explain-a"])
    _ <- runPgOrFail connection config (TupleStore.deleteTuples [grant "explain-a"])
    explainEnd <- runPgOrFail connection config TupleStore.headRevision
    planLines <- runSessionOrFail connection (Session.statement () (explainWatchWindowStatement explainStart explainEnd))
    let plan = Text.unlines planLines
    assertBool
        ("the window query must not sequentially scan relation_tuple; plan was:\n" <> Text.unpack plan)
        (not (Text.isInfixOf "Seq Scan" plan))
    assertBool
        ("the created_xid arm must be index-served; plan was:\n" <> Text.unpack plan)
        (Text.isInfixOf "relation_tuple_created_xid_idx" plan)
    assertBool
        ("the deleted_xid arm must be index-served; plan was:\n" <> Text.unpack plan)
        (Text.isInfixOf "relation_tuple_deleted_xid_idx" plan)

{- | The feed as a consumer sees it: subscribe, write, poll, delete, poll, catch up.

This is the story `POST /v1/watch` tells, one layer below HTTP. What it proves that
'runWatchWindowScenario' cannot is that the cursor closes the loop — each poll's cursor is
the next poll's start, and the two together neither skip a change nor repeat one.

The expiry path is forced rather than waited for. A cursor whose window opens at @1:1:@
names history a real garbage-collection horizon has long since destroyed, so it exercises
the same rejection an offline consumer would meet, in a test that takes no time.
-}
runWatchFeedScenario :: Connection.Connection -> IO ()
runWatchFeedScenario connection = do
    config <- testConfig
    let space name = ObjectRef (ObjectType "space") name
        grant name = Tuple (space name) (RelationName "viewer") (SubjectId (ObjectRef (ObjectType "user") "alice")) Nothing
        watched = grant "watched"
        other = grant "other"

        poll cursorText = runPgOrFail connection config (Watch.watch config (StartFromCursor cursorText) Nothing 100)
        eventsOf batch = [(change.kind, change.tuple) | change <- batch.changes]

    subscribed <- runPgOrFail connection config (Watch.watch config StartFromNow Nothing 100)
    assertEqual "subscribing from now reports no changes" [] (eventsOf subscribed)

    _ <- runPgOrFail connection config (TupleStore.writeTuples [watched, other])
    afterWrite <- poll subscribed.cursor
    assertEqual
        "the first poll after a write reports both grants as touches"
        (sort [(ChangeTouch, watched), (ChangeTouch, other)])
        (sort (eventsOf afterWrite))

    caughtUp <- poll afterWrite.cursor
    assertEqual "polling a caught-up feed reports nothing" [] (eventsOf caughtUp)

    _ <- runPgOrFail connection config (TupleStore.deleteTuples [watched])
    afterDelete <- poll caughtUp.cursor
    assertEqual
        "the poll after a delete reports exactly that revocation"
        [(ChangeDelete, watched)]
        (eventsOf afterDelete)

    {- Idempotence: re-presenting a cursor re-reads the same window. A consumer that
    crashed after processing a batch and before persisting its cursor replays it, which is
    the at-least-once delivery this feed promises. -}
    replayed <- poll caughtUp.cursor
    assertEqual "re-presenting a cursor replays the same batch" (eventsOf afterDelete) (eventsOf replayed)

    {- The window's end is minted as @checkedAt@, so a consumer can read a store that has
    already applied everything the batch just told it about. -}
    assertEqual
        "a batch's checkedAt token is accepted as a later read's freshness bound"
        (Right 1)
        . fmap (length . (.rows))
        =<< runPg
            connection
            config
            ( do
                ResolvedConsistency{revision} <- ConsistencyStore.resolveConsistency (AtLeastAsFresh afterDelete.checkedAt)
                TupleStore.readAllTuples revision 100 Nothing
            )

    -- A drain across a window wider than one page visits every change exactly once.
    _ <- runPgOrFail connection config (TupleStore.writeTuples [grant "drain-a", grant "drain-b", grant "drain-c"])
    drained <- drainWatch connection config afterDelete.cursor
    assertEqual
        "draining a multi-page window at limit 1 reports every change exactly once"
        (sort [(ChangeTouch, grant "drain-a"), (ChangeTouch, grant "drain-b"), (ChangeTouch, grant "drain-c")])
        (sort drained)

    -- An ordinary consistency token is a start position: "everything since my write".
    writeToken <- runPgOrFail connection config (TupleStore.writeTuples [grant "since-my-write"])
    _ <- runPgOrFail connection config (TupleStore.writeTuples [grant "after-my-write"])
    let ConsistencyToken writeTokenText = writeToken
    sinceWrite <- runPgOrFail connection config (Watch.watch config (StartFromToken writeTokenText) Nothing 100)
    assertEqual
        "a consistency token starts the feed at the revision it pins"
        [(ChangeTouch, grant "after-my-write")]
        (eventsOf sinceWrite)

    -- A subscription filter narrows the feed without changing what the cursor means.
    _ <- runPgOrFail connection config (TupleStore.writeTuples [grant "filtered-in", grant "filtered-out"])
    let onlyFilteredIn = relationshipFilter (Just "space") (Just "filtered-in") Nothing Nothing Nothing AnySubjectRelation Nothing
    scoped <- runPgOrFail connection config (Watch.watch config (StartFromCursor sinceWrite.cursor) (Just onlyFilteredIn) 100)
    assertEqual
        "a filtered subscription reports only the grants its filter names"
        [(ChangeTouch, grant "filtered-in")]
        (eventsOf scoped)

    -- The two fail-closed guards, against the real store's real horizon.
    let expired = Watch.encodeWatchCursor config.datastoreId (Watch.WatchAt (Revision "1:1:"))
    assertEqual
        "a cursor whose window predates the garbage-collection horizon is refused"
        (Left (InvalidConsistencyToken "watch cursor is older than the garbage-collection window"))
        =<< runPg connection config (Watch.watch config (StartFromCursor expired) Nothing 100)

    let foreign' = Watch.encodeWatchCursor (DatastoreId "not-this-datastore") (Watch.WatchAt (Revision "1:1:"))
    assertEqual
        "a cursor minted by another datastore is refused before its horizon is even read"
        (Left (InvalidConsistencyToken "watch cursor datastore does not match this en datastore"))
        =<< runPg connection config (Watch.watch config (StartFromCursor foreign') Nothing 100)

    assertEqual
        "a cursor this store never issued is refused as a malformed cursor"
        (Left (InvalidCursor "not-a-cursor"))
        =<< runPg connection config (Watch.watch config (StartFromCursor "not-a-cursor") Nothing 100)

{- | Drain a watch feed at one change per page until it reports nothing new.

Termination is the point of the assertion this feeds: a drain ends when a poll returns no
changes, and a cursor that failed to advance would loop here forever rather than fail.
-}
drainWatch :: Connection.Connection -> ConsistencyConfig -> Text -> IO [(ChangeKind, Tuple)]
drainWatch connection config = step []
  where
    step seen cursorText = do
        batch <- runPgOrFail connection config (Watch.watch config (StartFromCursor cursorText) Nothing 1)
        case batch.changes of
            [] -> pure seen
            changes -> step (seen <> [(change.kind, change.tuple) | change <- changes]) batch.cursor

{- | Fill @relation_tuple@ with history, so the planner has a reason to prefer an index.

Every row is created by this statement's own transaction, so they share one @created_xid@
and sit below the @xmin@ of any snapshot taken afterwards — which is exactly the backlog a
poll's window bound must exclude.
-}
seedHistoryStatement :: Statement Int64 ()
seedHistoryStatement =
    Statement.preparable
        """
        INSERT INTO relation_tuple
          (object_type, object_id, relation, subject_type, subject_id, created_xid)
        SELECT 'space', 'seed-' || n, 'viewer', 'user', 'seed-user-' || n, pg_current_xact_id()
        FROM generate_series(1, $1) AS n
        """
        (Encoders.param (Encoders.nonNullable Encoders.int8))
        Decoders.noResult

{- | Ask the planner how it would answer a window query, with the bindings inlined.

@EXPLAIN@ of a prepared statement reports the generic plan, which is not the plan the
window's actual parameters produce — the same trap 'explainProbeStatement' documents.

Both @*_xid_idx@ indexes must appear, under a @BitmapOr@. They serve nothing else in the
tree (docs/plans/49's sweep measured @idx_scan = 0@ for @relation_tuple_created_xid_idx@
across a driven workload and kept it for this plan alone), so this assertion is the only
thing standing between the feed and a full scan of @relation_tuple@ on every poll. If it
ever fails, the fix is to split the @OR@ into two @UNION@ arms — not to drop the assertion.
-}
explainWatchWindowStatement :: Revision -> Revision -> Statement () [Text]
explainWatchWindowStatement start end =
    Statement.preparable
        ( Text.unlines
            [ "EXPLAIN (COSTS OFF)"
            , "SELECT id FROM relation_tuple"
            , "WHERE id > 0"
            , "  AND ( ( created_xid >= '" <> showText startXmin <> "'::xid8"
            , "          AND pg_visible_in_snapshot(created_xid, " <> snapshotLiteral end <> ")"
            , "          AND NOT pg_visible_in_snapshot(created_xid, " <> snapshotLiteral start <> ") )"
            , "     OR ( deleted_xid IS NOT NULL"
            , "          AND deleted_xid >= '" <> showText startXmin <> "'::xid8"
            , "          AND pg_visible_in_snapshot(deleted_xid, " <> snapshotLiteral end <> ")"
            , "          AND NOT pg_visible_in_snapshot(deleted_xid, " <> snapshotLiteral start <> ") ) )"
            , "ORDER BY id ASC"
            , "LIMIT 101"
            ]
        )
        Encoders.noParams
        (Decoders.rowList (Decoders.column (Decoders.nonNullable Decoders.text)))
  where
    snapshotLiteral revision = "'" <> revision.revisionEncoding <> "'::pg_snapshot"
    startXmin =
        case parsePgSnapshot start.revisionEncoding of
            Right snapshot -> snapshot.xmin
            Left _ -> 0

{- | The batched touch protocol's retry ladder, which only a race can reach.

Inside one transaction the batch always converges on its first attempt: the only
live row that can conflict with an entry after the retire statement is one
byte-identical to it, and that satisfies the entry. So the convergence check, the
ordinal bookkeeping that maps an unsatisfied entry back to its tuple, and the
second attempt are all unreachable without a concurrent writer — and a suite that
never establishes the overlap leaves the entire ladder unexercised while
reporting green.

The overlap is forced, not waited for. A racer opens a transaction and inserts a
live row for the contended identity without committing. The writer's retire
statement runs at its own @READ COMMITTED@ snapshot and cannot see that row, so
it retires nothing; the writer's insert then collides with the racer's
uncommitted row and blocks on it. The test /asserts/ the writer is blocked before
releasing the racer, so a run in which the writer sailed past cannot be mistaken
for a run in which it raced.

When the racer commits, the writer's @ON CONFLICT DO NOTHING@ drops the contended
entry — @rowsAffected@ now reports "nothing retired, nothing inserted" for a
write that was neither applied nor already present. That is finding C1 in racing
form, and inferring convergence from those counts would silently drop the write
and hand back a success token. The convergence check instead observes that no
live row carries the entry's caveat, and the second attempt retires the racer's
row and inserts the replacement.

The contended entry is deliberately the /second/ of two, so the retry acts on
ordinal 2. An off-by-one in the ordinal mapping selects no tuple, the ladder
concludes it converged, and the racer's caveat survives under the writer's token.
-}
runBatchTouchRaceScenario :: Pg.Database -> Connection.Connection -> IO ()
runBatchTouchRaceScenario database connection = do
    config <- testConfig
    writerConnection <- acquire database
    racer <- acquire database
    let viewer = RelationName "viewer"
        alice = SubjectId (ObjectRef (ObjectType "user") "batch-race-alice")
        contendedSpace = ObjectRef (ObjectType "space") "batch-race"
        bystanderSpace = ObjectRef (ObjectType "space") "batch-race-bystander"
        december =
            TupleCaveat
                { name = CaveatName "within_autonomy"
                , payload = CaveatPayload (Map.fromList [("until", ValueTimestamp (read "2026-12-31 00:00:00 UTC"))])
                }
        grant object caveat = Tuple{object, relation = viewer, subject = alice, caveat}
        -- The contended identity is the last entry, so its retry ordinal is 2.
        writerRequest = TupleStore.writeTuples [grant bystanderSpace Nothing, grant contendedSpace (Just december)]

    -- The racer plants a live row for the contended identity and holds it uncommitted.
    runSessionOrFail racer (Session.script "BEGIN")
    runSessionOrFail racer (Session.statement () insertRacingTupleStatement)

    writerResult <- newEmptyMVar
    _ <- forkIO (putMVar writerResult =<< runPg writerConnection config writerRequest)

    -- Long enough that a writer which was going to finish would have finished.
    threadDelay 500_000
    pendingWriter <- tryReadMVar writerResult
    assertEqual
        ("the writer blocks on the racer's uncommitted row; got " <> show pendingWriter)
        Nothing
        pendingWriter

    runSessionOrFail racer (Session.script "COMMIT")
    outcome <- takeMVar writerResult
    assertBool ("the writer's batch commits after the race; got " <> show outcome) (isRight outcome)

    headRevision <- runPgOrFail connection config TupleStore.headRevision
    TuplePage{rows = contendedRows} <-
        runPgOrFail connection config (TupleStore.readObjectRelation headRevision contendedSpace viewer 10 Nothing)
    TuplePage{rows = bystanderRows} <-
        runPgOrFail connection config (TupleStore.readObjectRelation headRevision bystanderSpace viewer 10 Nothing)
    assertEqual "the raced identity keeps one live row" 1 (length contendedRows)
    assertEqual
        "the writer's caveat replaces the racer's rather than being silently dropped"
        [Just december]
        ((.tuple.caveat) <$> contendedRows)
    assertEqual "the batch's uncontended entry is written too" 1 (length bystanderRows)

    traverse_ Connection.release [writerConnection, racer]

{- | Plant a live row for the contended identity, carrying a caveat the writer's
batch does not.

Written as raw SQL rather than through the store, because the row must stay
uncommitted while another transaction collides with it — which is precisely what
'En.Effect.TupleStore.applyTupleWrites' will not do.
-}
insertRacingTupleStatement :: Statement () ()
insertRacingTupleStatement =
    Statement.preparable
        """
        INSERT INTO relation_tuple
          (object_type, object_id, relation, subject_type, subject_id, subject_relation,
           caveat_name, caveat_payload, created_xid)
        VALUES ('space', 'batch-race', 'viewer', 'user', 'batch-race-alice', NULL,
                'within_autonomy',
                '{"until":{"type":"timestamp","value":"2026-01-01T00:00:00Z"}}'::jsonb,
                pg_current_xact_id())
        """
        Encoders.noParams
        Decoders.noResult

{- | Take the raced grant's row lock, as 'lockMatchingLiveTupleStatement' would.

Literal parameters rather than the real statement: this stands in for a third
writer, and the test wants it to be obvious which row is locked.
-}
lockRacedRowStatement :: Statement () [Int64]
lockRacedRowStatement =
    Statement.preparable
        """
        SELECT id FROM relation_tuple
        WHERE object_type = 'space' AND object_id = 'race-revoke' AND relation = 'viewer'
          AND subject_type = 'user' AND subject_id = 'race-alice'
          AND deleted_xid IS NULL
        FOR UPDATE
        """
        Encoders.noParams
        (Decoders.rowList (Decoders.column (Decoders.nonNullable Decoders.int8)))

{- | Storage refuses to answer rather than answering wrongly.

Three ways the store used to lie, each now a typed error or a harmless no-op: a
cursor it never issued restarted the scan from the beginning (duplicating every
row the caller had already seen); a caveat payload that no longer decodes came
back as an /empty/ payload, which is a different authorization fact rather than a
degraded one; and a zero-limit page returned no rows while advancing its cursor
past the first of them, losing that row from the scan forever.
-}
runDecodeStrictnessScenario :: Connection.Connection -> IO ()
runDecodeStrictnessScenario connection = do
    config <- testConfig
    let viewer = RelationName "viewer"
        pageSpace = ObjectRef (ObjectType "space") "decode-page"
        grant subjectId =
            Tuple
                { object = pageSpace
                , relation = viewer
                , subject = SubjectId (ObjectRef (ObjectType "user") subjectId)
                , caveat = Nothing
                }
        corruptQuery =
            UsersetQuery
                { queryType = ObjectType "space"
                , queryRelation = viewer
                , querySubjects = [SubjectId (ObjectRef (ObjectType "user") "decode-victim")]
                , queryLimit = 10
                , queryCursor = Nothing
                }

    pageToken <- runPgOrFail connection config (TupleStore.writeTuples [grant "decode-alice", grant "decode-bob"])
    TokenMetadata{revision = pageRevision} <- either (fail . show) pure (tokenMetadataFromPayload pageToken)

    -- 1. A cursor this store never issued is a client fault, not a fresh scan.
    malformed <-
        runPg connection config (TupleStore.readObjectRelation pageRevision pageSpace viewer 10 (Just (StoreCursor "not-a-number")))
    assertEqual
        "malformed cursor is rejected"
        (Left (InvalidCursor "not-a-number"))
        (fmap (.rows) malformed)

    -- 2. A payload that cannot decode fails the read instead of reading as empty.
    runSessionOrFail connection (Session.script corruptPayloadSql)
    corruptRevision <- runPgOrFail connection config TupleStore.headRevision
    corrupt <- runPg connection config (TupleStore.readStartingWithUser corruptRevision corruptQuery)
    assertBool
        ("malformed caveat payload is a StoreError; got " <> show (fmap (.rows) corrupt))
        (isStoreError corrupt)

    -- 3. A zero-limit page returns nothing and skips nothing.
    TuplePage{rows = emptyRows, state = emptyState} <-
        runPgOrFail connection config (TupleStore.readObjectRelation pageRevision pageSpace viewer 0 Nothing)
    assertEqual "limit-0 page returns no rows" 0 (length emptyRows)
    zeroCursor <- case emptyState of
        HasMore cursor -> pure cursor
        other -> fail ("limit-0 page should have more; got " <> show other)
    TuplePage{rows = resumedRows} <-
        runPgOrFail connection config (TupleStore.readObjectRelation pageRevision pageSpace viewer 10 (Just zeroCursor))
    assertEqual "limit-0 page makes no progress" 2 (length resumedRows)

{- | A live row whose @caveat_payload@ is valid @jsonb@ of the wrong shape.

The column type forbids invalid JSON, so corruption in the field can only ever be
JSON that no longer decodes to a payload — here an integer-tagged value whose
@value@ is a string.
-}
corruptPayloadSql :: Text
corruptPayloadSql =
    """
    INSERT INTO relation_tuple
      (object_type, object_id, relation, subject_type, subject_id, caveat_name, caveat_payload, created_xid)
    VALUES
      ( 'space', 'decode-corrupt', 'viewer', 'user', 'decode-victim'
      , 'within_autonomy'
      , '{"level":{"type":"integer","value":"not-a-number"}}'::jsonb
      , pg_current_xact_id()
      );
    """

{- | A write token names one state of the world, and keeps naming it.

@pg_current_snapshot()@ reports @xmax@ as one past the latest /completed/ xid, so
a transaction that was assigned an xid but had not committed when the anchor was
taken sits at or above that @xmax@. The write token raises @xmax@ past its own
xid to see its own write; unless the xids it steps over are marked in progress,
they become visible the instant they commit -- and the token means something
different before and after.

The holder connection is that transaction. It takes an xid and inserts a matching
grant /before/ the write anchor runs, so its xid lands in the gap the write token
raises over, and it commits between the two reads. Pre-fix the second read
returns both grants and this scenario fails with a 1-vs-2 diff.
-}
runSnapshotRepeatabilityScenario :: Pg.Database -> Connection.Connection -> IO ()
runSnapshotRepeatabilityScenario database connection = do
    config <- testConfig
    holder <- acquire database
    flip finally (Connection.release holder) do
        let alice = SubjectId (ObjectRef (ObjectType "user") "snapshot-alice")
            ownSpace = ObjectRef (ObjectType "space") "snapshot-own"
            ownTuple =
                Tuple
                    { object = ownSpace
                    , relation = RelationName "viewer"
                    , subject = alice
                    , caveat = Nothing
                    }
            query =
                UsersetQuery
                    { queryType = ObjectType "space"
                    , queryRelation = RelationName "viewer"
                    , querySubjects = [alice]
                    , queryLimit = 10
                    , queryCursor = Nothing
                    }

        -- A concurrent writer takes an xid and stays uncommitted.
        runSessionOrFail holder (Session.script "BEGIN")
        runSessionOrFail holder (Session.script concurrentGrantSql)

        writeToken <- runPgOrFail connection config (TupleStore.writeTuples [ownTuple])
        TokenMetadata{revision = writeRevision} <- either (fail . show) pure (tokenMetadataFromPayload writeToken)

        TuplePage{rows = beforeCommit} <- runPgOrFail connection config (TupleStore.readStartingWithUser writeRevision query)
        assertEqual "the write token sees its own write" [ownTuple] ((.tuple) <$> beforeCommit)

        runSessionOrFail holder (Session.script "COMMIT")

        TuplePage{rows = afterCommit} <- runPgOrFail connection config (TupleStore.readStartingWithUser writeRevision query)
        assertEqual
            "reads at one write token are repeatable across a concurrent commit"
            (length beforeCommit)
            (length afterCommit)
        assertEqual
            "the concurrent commit is invisible at the write token"
            ((.tuple) <$> beforeCommit)
            ((.tuple) <$> afterCommit)

-- | The concurrent writer's grant. The @INSERT@ is what assigns it an xid.
concurrentGrantSql :: Text
concurrentGrantSql =
    """
    INSERT INTO relation_tuple
      (object_type, object_id, relation, subject_type, subject_id, created_xid)
    VALUES ('space', 'snapshot-concurrent', 'viewer', 'user', 'snapshot-alice', pg_current_xact_id());
    """

isPreconditionFailure :: Either EnError a -> Bool
isPreconditionFailure = \case
    Left (WritePreconditionFailed _) -> True
    _ -> False

isStoreError :: Either EnError a -> Bool
isStoreError = \case
    Left (StoreError _) -> True
    _ -> False

-- | The 'ConsistencyConfig' every scenario shares.
testConfig :: IO ConsistencyConfig
testConfig = do
    validCheckSchema <- either (fail . show) pure (Schema.validateSchema checkSchema)
    pure
        ConsistencyConfig
            { datastoreId = DatastoreId "test-datastore"
            , schemaHash = Schema.schemaHash validCheckSchema
            , gcWindow = "24 hours"
            }

{- | The migration's duplicate-resolution rule, against the schema it will meet.

Recreates the /old/ index shape, seeds the duplicate live rows only that shape
permits, then runs the migration's SQL and asserts the newest write survived.
The SQL below must stay in sync with
@en-migrations/db/migrations/20260709202037_touch-semantics-live-unique.sql@ --
the same convention 'schemaSql' follows for the base migration.
-}
runMigrationDedupeScenario :: Connection.Connection -> IO ()
runMigrationDedupeScenario connection = do
    runSessionOrFail connection (Session.script oldLiveUniqueSql)
    runSessionOrFail connection (Session.script duplicateSeedSql)
    liveBefore <- runSessionOrFail connection (Session.statement () (countStatement "SELECT count(*) FROM relation_tuple WHERE deleted_xid IS NULL"))
    assertEqual "the old index shape admits one live row per caveat name" 3 liveBefore

    runSessionOrFail connection (Session.script dedupeAndReindexSql)
    liveAfter <- runSessionOrFail connection (Session.statement () (countStatement "SELECT count(*) FROM relation_tuple WHERE deleted_xid IS NULL"))
    assertEqual "the migration leaves one live row per identity" 1 liveAfter

    survivor <- runSessionOrFail connection (Session.statement () (textStatement "SELECT caveat_name FROM relation_tuple WHERE deleted_xid IS NULL"))
    assertEqual "the migration keeps the row with the highest created_xid" ["newest"] survivor

    retired <- runSessionOrFail connection (Session.statement () (countStatement "SELECT count(*) FROM relation_tuple WHERE deleted_xid IS NOT NULL"))
    assertEqual "the migration soft-deletes the losers rather than removing them" 2 retired

-- | The pre-migration @relation_tuple_live_unique@, keyed on the caveat name too.
oldLiveUniqueSql :: Text
oldLiveUniqueSql =
    """
    DROP INDEX relation_tuple_live_unique;

    CREATE UNIQUE INDEX relation_tuple_live_unique
      ON relation_tuple
        (object_type, object_id, relation, subject_type, subject_id, coalesce(subject_relation, ''), coalesce(caveat_name, ''))
      WHERE deleted_xid IS NULL;
    """

{- | Three live rows for one identity, distinguished only by caveat name, with
ascending @created_xid@. Only the pre-migration index shape permits this.
-}
duplicateSeedSql :: Text
duplicateSeedSql =
    """
    INSERT INTO relation_tuple
      (object_type, object_id, relation, subject_type, subject_id, caveat_name, created_xid)
    VALUES
      ('space', 'dupe', 'viewer', 'user', 'alice', 'oldest', '100'::xid8),
      ('space', 'dupe', 'viewer', 'user', 'alice', 'middle', '200'::xid8),
      ('space', 'dupe', 'viewer', 'user', 'alice', 'newest', '300'::xid8);
    """

dedupeAndReindexSql :: Text
dedupeAndReindexSql =
    """
    WITH ranked AS (
      SELECT id,
             row_number() OVER (
               PARTITION BY object_type, object_id, relation,
                            subject_type, subject_id, coalesce(subject_relation, '')
               ORDER BY created_xid DESC, id DESC
             ) AS keep_rank
      FROM relation_tuple
      WHERE deleted_xid IS NULL
    )
    UPDATE relation_tuple
    SET deleted_xid = pg_current_xact_id()
    WHERE id IN (SELECT id FROM ranked WHERE keep_rank > 1);

    DROP INDEX relation_tuple_live_unique;

    CREATE UNIQUE INDEX relation_tuple_live_unique
      ON relation_tuple
        (object_type, object_id, relation, subject_type, subject_id, coalesce(subject_relation, ''))
      WHERE deleted_xid IS NULL;
    """

textStatement :: Text -> Statement () [Text]
textStatement sql =
    Statement.preparable
        sql
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

{- | Every consistency mode fetches only what it needs (docs/plans/49, finding C3).

Before this plan @ResolveConsistency@ ran @optimizedRevision@, @headRevision@ and
@oldestRetainedXid@ unconditionally -- three store operations, and because the
interpreter maps each to one database session, three sequential round trips on
every read regardless of mode. The counts below are the enforced ceiling.

The interposer counts store /operations/, which is the honest unit: the horizon is
not cached (see 'En.Postgres.Revision.TtlCache'), and the optimized-revision cache
is absent from this stack, so one operation is one round trip here.
-}
runConsistencyFetchCountScenario :: Connection.Connection -> IO ()
runConsistencyFetchCountScenario connection = do
    validCheckSchema <- either (fail . show) pure (Schema.validateSchema checkSchema)
    let config =
            ConsistencyConfig
                { datastoreId = DatastoreId "test-datastore"
                , schemaHash = Schema.schemaHash validCheckSchema
                , gcWindow = "24 hours"
                }
    token <- runPgOrFail connection config (TupleStore.writeTuples [countingTuple])

    -- runPgCounting fails the suite on a Left, so reaching the assertion already
    -- means the mode resolved; what is under test is the fetch tally.
    let expectFetches label request expected = do
            (_, counts) <- runPgCounting connection config (ConsistencyStore.resolveConsistency request)
            assertEqual label expected counts

    expectFetches
        "MinimizeLatency resolves with a single store fetch"
        MinimizeLatency
        (Map.fromList [("OptimizedRevision", 1)])
    expectFetches
        "FullyConsistent resolves with a single store fetch"
        FullyConsistent
        (Map.fromList [("HeadRevision", 1)])
    expectFetches
        "AtExactSnapshot fetches only the garbage-collection horizon"
        (AtExactSnapshot token)
        (Map.fromList [("OldestRetainedXid", 1)])
    expectFetches
        "AtLeastAsFresh fetches the horizon and the optimized revision, never head"
        (AtLeastAsFresh token)
        (Map.fromList [("OldestRetainedXid", 1), ("OptimizedRevision", 1)])
  where
    countingTuple =
        Tuple
            { object = ObjectRef{objectType = ObjectType "document", objectId = "fetch-count"}
            , relation = RelationName "viewer"
            , subject = SubjectId ObjectRef{objectType = ObjectType "user", objectId = "counter"}
            , caveat = Nothing
            }

{- | Count the 'TupleStore' revision operations an action issues.

Mirrors the shape of 'En.Effect.CachedTupleStore.cachedTupleStore': intercept the
three operations under test, forward everything else with 'passthrough' so the
interposer stays transparent to writes and reads.
-}
countingTupleStore ::
    (TupleStore :> es, IOE :> es) =>
    IORef (Map.Map Text Int) ->
    Eff es a ->
    Eff es a
countingTupleStore counter =
    interpose \env -> \case
        HeadRevision -> bump "HeadRevision" >> passthrough env HeadRevision
        OptimizedRevision -> bump "OptimizedRevision" >> passthrough env OptimizedRevision
        OldestRetainedXid -> bump "OldestRetainedXid" >> passthrough env OldestRetainedXid
        operation -> passthrough env operation
  where
    bump name =
        liftIO (modifyIORef' counter (Map.insertWith (+) name 1))

type PostgresEffects = '[ConsistencyStore, TupleStore, Error EnError, Database, IOE]

runPg :: Connection.Connection -> ConsistencyConfig -> Eff PostgresEffects a -> IO (Either EnError a)
runPg connection config =
    runEff
        . runDatabaseConnection connection
        . runErrorNoCallStack
        . runTupleStorePostgres config
        . runConsistencyStorePostgres config

-- | 'runPg', with the store operations the action issues tallied by name.
runPgCounting ::
    Connection.Connection ->
    ConsistencyConfig ->
    Eff PostgresEffects a ->
    IO (a, Map.Map Text Int)
runPgCounting connection config action = do
    counter <- newIORef Map.empty
    result <-
        runEff
            . runDatabaseConnection connection
            . runErrorNoCallStack
            . runTupleStorePostgres config
            . countingTupleStore counter
            $ runConsistencyStorePostgres config action
    resolved <- either (fail . show) pure result
    counts <- readIORef counter
    pure (resolved, counts)

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
        (object_type, object_id, relation, subject_type, subject_id, coalesce(subject_relation, ''))
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
