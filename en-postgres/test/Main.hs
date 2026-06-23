module Main (main) where

import Data.Either (isLeft)

import En.Postgres.Revision (
    PgSnapshot (..),
    TokenPayload (..),
    comparePgSnapshot,
    decodeToken,
    encodeToken,
    parsePgSnapshot,
    renderPgSnapshot,
    revisionFromPgSnapshot,
    transactionVisible,
 )
import En.Revision (
    ConsistencyToken (..),
    DatastoreId (..),
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
