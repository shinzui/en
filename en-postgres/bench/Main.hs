module Main (main) where

import En.Postgres.Revision (PgSnapshot (..), TokenPayload (..), comparePgSnapshot, decodeToken, encodeToken)
import En.Revision (ConsistencyToken, DatastoreId (..), Revision (..), SchemaHash (..))
import Test.Tasty.Bench (bench, bgroup, defaultMain, whnf)

main :: IO ()
main =
  defaultMain
    [ bgroup
        "consistency"
        [ bench "encodeToken" $ whnf encodeToken sampleTokenPayload,
          bench "decodeToken" $ whnf decodeToken sampleEncodedToken,
          bench "comparePgSnapshot" $ whnf (uncurry comparePgSnapshot) (snapshotA, snapshotB)
        ]
    ]

sampleTokenPayload :: TokenPayload
sampleTokenPayload =
  TokenPayload
    { datastoreId = DatastoreId "bench",
      schemaHash = SchemaHash "schema",
      revision = Revision "1:20:7,11",
      expiresAt = Nothing
    }

sampleEncodedToken :: ConsistencyToken
sampleEncodedToken =
  encodeToken sampleTokenPayload

snapshotA :: PgSnapshot
snapshotA =
  PgSnapshot {xmin = 1, xmax = 20, xip = [7, 11]}

snapshotB :: PgSnapshot
snapshotB =
  PgSnapshot {xmin = 1, xmax = 25, xip = [7, 11, 21]}
