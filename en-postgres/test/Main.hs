module Main (main) where

import Data.Either (isLeft)
import Data.Text qualified as Text
import Data.Time (UTCTime, defaultTimeLocale, parseTimeOrError)

import En.Effect.ConsistencyStore (ResolvedConsistency (..), TokenMetadata (..))
import En.Error (EnError (..))
import En.Postgres.Revision (
    ConsistencyConfig (..),
    PgSnapshot (..),
    TokenPayload (..),
    comparePgSnapshot,
    decodeToken,
    encodeToken,
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
    let payload =
            TokenPayload
                { tokenDatastoreId = DatastoreId "primary"
                , tokenSchemaHash = SchemaHash "schema:hash"
                , tokenRevision = revisionFromPgSnapshot PgSnapshot{xmin = 10, xmax = 20, xip = [12]}
                , tokenExpiresAt = Nothing
                }
    assertEqual "token codec round-trips payload" (Right payload) (decodeToken (encodeToken payload))
    assertEqual "token decoder rejects bad snapshots" True (isLeft (decodeToken (ConsistencyToken "en1.primary.schema.bad")))
    assertEqual
        "exact snapshot resolves to token revision"
        (Right ResolvedConsistency{consistency = AtExactSnapshot (encodeToken payload), revision = tokenRevision payload})
        (resolveConsistencyRequest optimizedRevision headRevision metadataFromToken validateMetadata (AtExactSnapshot (encodeToken payload)))
    assertEqual
        "at least as fresh uses optimized revision when it is after the token"
        (Right ResolvedConsistency{consistency = AtLeastAsFresh (encodeToken payload), revision = optimizedRevision})
        (resolveConsistencyRequest optimizedRevision headRevision metadataFromToken validateMetadata (AtLeastAsFresh (encodeToken payload)))
    let concurrentPayload =
            payload
                { tokenRevision = Revision "10:20:11"
                }
        concurrentOptimized = Revision "10:20:12"
    assertEqual
        "at least as fresh honors token revision when optimized is concurrent"
        (Right ResolvedConsistency{consistency = AtLeastAsFresh (encodeToken concurrentPayload), revision = tokenRevision concurrentPayload})
        (resolveConsistencyRequest concurrentOptimized headRevision metadataFromToken validateMetadata (AtLeastAsFresh (encodeToken concurrentPayload)))
    assertEqual
        "wrong datastore is rejected"
        (Left (InvalidConsistencyToken "token datastore does not match this en datastore"))
        (validateTokenMetadata config now metadata{datastoreId = DatastoreId "other"})
    assertEqual
        "wrong schema hash is rejected"
        (Left (InvalidConsistencyToken "token schema hash does not match the active schema"))
        (validateTokenMetadata config now metadata{schemaHash = SchemaHash "other"})
    assertEqual
        "expired token is rejected"
        (Left (InvalidConsistencyToken "token is expired"))
        (validateTokenMetadata config now metadata{expiresAt = Just now})
  where
    config =
        ConsistencyConfig
            { expectedDatastoreId = DatastoreId "primary"
            , expectedSchemaHash = SchemaHash "schema:hash"
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
    metadataFromToken token =
        case decodeToken token of
            Right tokenPayload ->
                Right
                    TokenMetadata
                        { token = token
                        , revision = tokenPayload.tokenRevision
                        , datastoreId = tokenPayload.tokenDatastoreId
                        , schemaHash = tokenPayload.tokenSchemaHash
                        , expiresAt = tokenPayload.tokenExpiresAt
                        }
            Left err -> Left (InvalidConsistencyToken (showText err))
    validateMetadata =
        validateTokenMetadata config now

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
