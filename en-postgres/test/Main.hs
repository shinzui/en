{-# LANGUAGE DuplicateRecordFields #-}

module Main (main) where

import Data.Either (isLeft)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text qualified as Text
import Data.Time (UTCTime, addUTCTime, defaultTimeLocale, parseTimeOrError)

import En.Effect.ConsistencyStore (ResolvedConsistency (..), TokenMetadata (..))
import En.Error (EnError (..))
import En.Postgres.Revision (
    ConsistencyConfig (..),
    OptimizedRevisionConfig (..),
    PgSnapshot (..),
    TokenPayload (..),
    comparePgSnapshot,
    decodeToken,
    encodeToken,
    newOptimizedRevisionReader,
    parsePgSnapshot,
    renderPgSnapshot,
    resolveConsistencyRequest,
    revisionFromPgSnapshot,
    transactionVisible,
    validateTokenMetadata,
 )
import En.Revision (
    Consistency (..),
    ConsistencyToken (..),
    DatastoreId (..),
    Revision (..),
    RevisionOrder (..),
    SchemaHash (..),
 )

main :: IO ()
main = do
    testOptimizedRevisionReader
    assertEqual
        "pg_snapshot parses and renders canonically"
        (Right PgSnapshot{xmin = 10, xmax = 20, xip = [12, 15]})
        (parsePgSnapshot "10:20:15,12,12")
    assertEqual
        "pg_snapshot renders sorted xip"
        "10:20:12,15"
        (renderPgSnapshot PgSnapshot{xmin = 10, xmax = 20, xip = [15, 12]})
    assertEqual
        "old transaction is visible"
        True
        (transactionVisible 9 PgSnapshot{xmin = 10, xmax = 20, xip = [12]})
    assertEqual
        "in-flight transaction is not visible"
        False
        (transactionVisible 12 PgSnapshot{xmin = 10, xmax = 20, xip = [12]})
    assertEqual
        "future transaction is not visible"
        False
        (transactionVisible 20 PgSnapshot{xmin = 10, xmax = 20, xip = []})
    assertEqual
        "later snapshot compares after earlier snapshot"
        RAfter
        ( comparePgSnapshot
            PgSnapshot{xmin = 10, xmax = 30, xip = []}
            PgSnapshot{xmin = 10, xmax = 20, xip = []}
        )
    assertEqual
        "incomparable snapshots compare concurrent"
        RConcurrent
        ( comparePgSnapshot
            PgSnapshot{xmin = 10, xmax = 20, xip = [11]}
            PgSnapshot{xmin = 10, xmax = 20, xip = [12]}
        )
    assertEqual
        "xmax-gap snapshot compares before later snapshot"
        RBefore
        ( comparePgSnapshot
            PgSnapshot{xmin = 10, xmax = 15, xip = []}
            PgSnapshot{xmin = 20, xmax = 25, xip = []}
        )
    let payload =
            TokenPayload
                { datastoreId = DatastoreId "primary"
                , schemaHash = SchemaHash "schema:hash"
                , revision = revisionFromPgSnapshot PgSnapshot{xmin = 10, xmax = 20, xip = [12]}
                , expiresAt = Nothing
                }
    assertEqual "token codec round-trips payload" (Right payload) (decodeToken (encodeToken payload))
    assertEqual "token decoder rejects bad snapshots" True (isLeft (decodeToken (ConsistencyToken "en1.primary.schema.bad")))
    assertEqual
        "exact snapshot resolves to token revision"
        (Right ResolvedConsistency{consistency = AtExactSnapshot (encodeToken payload), revision = payload.revision})
        (resolveConsistencyRequest optimizedRevision headRevision metadataFromToken validateMetadata (AtExactSnapshot (encodeToken payload)))
    assertEqual
        "fully consistent resolves to head revision"
        (Right ResolvedConsistency{consistency = FullyConsistent, revision = headRevision})
        (resolveConsistencyRequest optimizedRevision headRevision metadataFromToken validateMetadata FullyConsistent)
    assertEqual
        "at least as fresh uses optimized revision when it is after the token"
        (Right ResolvedConsistency{consistency = AtLeastAsFresh (encodeToken payload), revision = optimizedRevision})
        (resolveConsistencyRequest optimizedRevision headRevision metadataFromToken validateMetadata (AtLeastAsFresh (encodeToken payload)))
    let concurrentPayload =
            TokenPayload
                { datastoreId = payload.datastoreId
                , schemaHash = payload.schemaHash
                , revision = Revision "10:20:11"
                , expiresAt = payload.expiresAt
                }
        concurrentOptimized = Revision "10:20:12"
    assertEqual
        "at least as fresh honors token revision when optimized is concurrent"
        (Right ResolvedConsistency{consistency = AtLeastAsFresh (encodeToken concurrentPayload), revision = concurrentPayload.revision})
        (resolveConsistencyRequest concurrentOptimized headRevision metadataFromToken validateMetadata (AtLeastAsFresh (encodeToken concurrentPayload)))
    assertEqual
        "wrong datastore is rejected"
        (Left (InvalidConsistencyToken "token datastore does not match this en datastore"))
        (validateTokenMetadata config now 0 metadataWithWrongDatastore)
    assertEqual
        "wrong schema hash is rejected"
        (Left (InvalidConsistencyToken "token schema hash does not match the active schema"))
        (validateTokenMetadata config now 0 metadataWithWrongSchema)
    assertEqual
        "expired token is rejected"
        (Left (InvalidConsistencyToken "token is expired"))
        (validateTokenMetadata config now 0 expiredMetadata)
    assertEqual
        "token older than GC horizon is rejected"
        (Left (InvalidConsistencyToken "token is older than the garbage-collection window"))
        (validateTokenMetadata config now 20 metadata)
  where
    config =
        ConsistencyConfig
            { datastoreId = DatastoreId "primary"
            , schemaHash = SchemaHash "schema:hash"
            , gcWindow = "24 hours"
            }
    now = parseUtc "2026-06-23T00:00:00Z"
    optimizedRevision = Revision "10:30:"
    headRevision = Revision "10:40:"
    metadata =
        TokenMetadata
            { token = ConsistencyToken "token"
            , revision = Revision "10:20:12"
            , datastoreId = DatastoreId "primary"
            , schemaHash = SchemaHash "schema:hash"
            , expiresAt = Nothing
            }
    metadataWithWrongDatastore =
        TokenMetadata
            { token = metadata.token
            , revision = metadata.revision
            , datastoreId = DatastoreId "other"
            , schemaHash = metadata.schemaHash
            , expiresAt = metadata.expiresAt
            }
    metadataWithWrongSchema =
        TokenMetadata
            { token = metadata.token
            , revision = metadata.revision
            , datastoreId = metadata.datastoreId
            , schemaHash = SchemaHash "other"
            , expiresAt = metadata.expiresAt
            }
    expiredMetadata =
        TokenMetadata
            { token = metadata.token
            , revision = metadata.revision
            , datastoreId = metadata.datastoreId
            , schemaHash = metadata.schemaHash
            , expiresAt = Just now
            }
    metadataFromToken token =
        case decodeToken token of
            Right tokenPayload ->
                Right
                    TokenMetadata
                        { token = token
                        , revision = tokenPayload.revision
                        , datastoreId = tokenPayload.datastoreId
                        , schemaHash = tokenPayload.schemaHash
                        , expiresAt = tokenPayload.expiresAt
                        }
            Left err -> Left (InvalidConsistencyToken (showText err))
    validateMetadata =
        validateTokenMetadata config now 0

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

parseUtc :: String -> UTCTime
parseUtc =
    parseTimeOrError True defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"

showText :: (Show a) => a -> Text.Text
showText =
    Text.pack . show

testOptimizedRevisionReader :: IO ()
testOptimizedRevisionReader = do
    baseTime <- pure (parseUtc "2026-06-23T00:00:00Z")
    clockRef <- newIORef baseTime
    callsRef <- newIORef (0 :: Int)
    cachedReader <-
        newOptimizedRevisionReader
            OptimizedRevisionConfig{enabled = True, ttl = 10}
            (readIORef clockRef)
            (nextRevision callsRef)
    first <- cachedReader
    second <- cachedReader
    assertEqual "optimized revision cache reuses within ttl" first second
    assertEqual "optimized revision cache reads once within ttl" 1 =<< readIORef callsRef
    writeIORef clockRef (addUTCTime 11 baseTime)
    third <- cachedReader
    assertEqual "optimized revision cache refreshes after ttl" (Revision "10:22:") third
    assertEqual "optimized revision cache increments after expiry" 2 =<< readIORef callsRef

    disabledCallsRef <- newIORef (0 :: Int)
    disabledReader <-
        newOptimizedRevisionReader
            OptimizedRevisionConfig{enabled = False, ttl = 10}
            (readIORef clockRef)
            (nextRevision disabledCallsRef)
    disabledFirst <- disabledReader
    disabledSecond <- disabledReader
    assertEqual "disabled optimized revision cache returns fresh first revision" (Revision "10:21:") disabledFirst
    assertEqual "disabled optimized revision cache returns fresh second revision" (Revision "10:22:") disabledSecond
    assertEqual "disabled optimized revision cache reads every time" 2 =<< readIORef disabledCallsRef

nextRevision :: IORef Int -> IO Revision
nextRevision callsRef = do
    modifyIORef' callsRef (+ 1)
    calls <- readIORef callsRef
    pure (Revision ("10:" <> Text.pack (show (20 + calls)) <> ":"))
