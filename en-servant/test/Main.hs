{-# LANGUAGE TypeOperators #-}

module Main (main) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Servant (Handler, ServerError (..), runHandler, type (:<|>) (..))

import En.Conformance.Kikan (consistencyStore, fixtureTuples, inMemoryTupleStore, kikanGraph)
import En.Servant.API (
    BatchCheckPairWire (..),
    BatchCheckRequestWire (..),
    BatchCheckResponseWire (..),
    CaveatContextWire (..),
    CheckDecisionWire (..),
    ConsistencyWire (..),
    EnServer (..),
    ObjectRefWire (..),
    SubjectWire (..),
    server,
 )

main :: IO ()
main = do
    let env =
            EnServer
                { consistencyStore
                , tupleStore = inMemoryTupleStore fixtureTuples
                , graph = kikanGraph
                , maxBatchSize = 10
                }
        batch = batchHandler env
        request =
            BatchCheckRequestWire
                { consistency = MinimizeLatencyWire
                , context = CaveatContextWire Map.empty
                , pairs =
                    [ pair "alice" "view" "project-x"
                    , pair "bob" "view" "project-x"
                    ]
                }
    assertEqual "batch endpoint returns decisions in order" (Right BatchCheckResponseWire{decisions = [AllowedWire, DeniedWire]}) =<< runHandler (batch request)

    let smallEnv = env{maxBatchSize = 1}
        oversized = request{pairs = [pair "alice" "view" "project-x", pair "bob" "view" "project-x"]}
    assertEqual "oversized batch returns 400" (Just 400) =<< httpCodeOf (batchHandler smallEnv oversized)

batchHandler :: EnServer -> BatchCheckRequestWire -> Handler BatchCheckResponseWire
batchHandler env =
    batch
  where
    _write
        :<|> _delete
        :<|> _check
        :<|> batch
        :<|> _lookup
        :<|> _expand = server env

pair :: Text -> Text -> Text -> BatchCheckPairWire
pair userId permission objectId =
    BatchCheckPairWire
        { subject = SubjectIdWire ObjectRefWire{objectType = "user", objectId = userId}
        , permission = permission
        , object = ObjectRefWire{objectType = "space", objectId = objectId}
        }

httpCodeOf :: Handler a -> IO (Maybe Int)
httpCodeOf handler =
    either (Just . errHTTPCode) (const Nothing) <$> runHandler handler

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
