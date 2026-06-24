{-# LANGUAGE TypeOperators #-}

module Main (main) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Effectful (IOE, runEff)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Servant (Handler, ServerError (..), runHandler, type (:<|>) (..))

import En.Cache (Cache, CacheConfig (..), CacheStats (..), SubproblemKey, cacheStats, newCache)
import En.Check (CheckCacheEnv (..), CheckDecision, check, checkCached)
import En.Conformance.Kikan (
    fixtureTuples,
    kikanGraph,
    memberOwner,
    runConsistencyStoreInMemory,
    runTupleStoreInMemory,
 )
import En.Effect.ConsistencyStore (ConsistencyStore)
import En.Effect.TupleStore (TupleStore)
import En.Error (EnError)
import En.Lookup qualified as Lookup
import En.Revision (DatastoreId (..))
import En.Schema (ObjectType (..))
import En.Servant.API (
    BatchCheckPairWire (..),
    BatchCheckRequestWire (..),
    BatchCheckResponseWire (..),
    CaveatContextWire (..),
    CheckDecisionWire (..),
    CheckRequestWire (..),
    CheckResponseWire (..),
    ConsistencyWire (..),
    Env (..),
    LookupPageWire,
    LookupRequestWire (..),
    ObjectRefWire (..),
    SubjectWire (..),
    server,
 )
import En.Tuple (ObjectRef (..))

main :: IO ()
main = do
    let env =
            Env
                { runPorts =
                    runEff
                        . runErrorNoCallStack
                        . runTupleStoreInMemory fixtureTuples
                        . runConsistencyStoreInMemory
                , graph = kikanGraph
                , checkOperation = check
                , lookupWithDeadlineOperation = Lookup.lookupWithDeadline
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

    cachedCheckEnv <- newCheckCacheEnv
    let cachedEnv =
            env
                { checkOperation = checkCached cachedCheckEnv
                , lookupWithDeadlineOperation = Lookup.lookupWithDeadlineCached cachedCheckEnv
                }
        checkEndpoint = checkHandler cachedEnv
        checkRequest =
            CheckRequestWire
                { consistency = MinimizeLatencyWire
                , context = CaveatContextWire Map.empty
                , subject = SubjectIdWire ObjectRefWire{objectType = "user", objectId = "alice"}
                , permission = "view"
                , object = ObjectRefWire{objectType = "space", objectId = "project-x"}
                }
    assertEqual "cached check endpoint returns Allowed first" (Right CheckResponseWire{decision = AllowedWire}) =<< runHandler (checkEndpoint checkRequest)
    checkStatsAfterFirst <- cacheStats cachedCheckEnv.cacheDecisions
    assertEqual "cached check endpoint returns Allowed second" (Right CheckResponseWire{decision = AllowedWire}) =<< runHandler (checkEndpoint checkRequest)
    checkStatsAfterSecond <- cacheStats cachedCheckEnv.cacheDecisions
    assertBool "cached check endpoint uses decision cache" (checkStatsAfterSecond.hits > checkStatsAfterFirst.hits)

    cachedLookupEnv <- newCheckCacheEnv
    let lookupCachedEnv =
            env
                { checkOperation = checkCached cachedLookupEnv
                , lookupWithDeadlineOperation = Lookup.lookupWithDeadlineCached cachedLookupEnv
                }
        lookupEndpoint = lookupHandler lookupCachedEnv
        lookupRequest =
            LookupRequestWire
                { consistency = MinimizeLatencyWire
                , subject = SubjectIdWire (objectToWire memberOwner)
                , permission = "audit"
                , objectType = "space"
                , context = CaveatContextWire Map.empty
                , limit = 10
                , cursor = Nothing
                , deadlineMillis = Nothing
                }
    assertRight "cached lookup endpoint returns a page first" =<< runHandler (lookupEndpoint lookupRequest)
    lookupStatsAfterFirst <- cacheStats cachedLookupEnv.cacheDecisions
    assertRight "cached lookup endpoint returns a page second" =<< runHandler (lookupEndpoint lookupRequest)
    lookupStatsAfterSecond <- cacheStats cachedLookupEnv.cacheDecisions
    assertBool "cached lookup endpoint uses decision cache for confirmations" (lookupStatsAfterSecond.hits > lookupStatsAfterFirst.hits)

type TestEffects = '[ConsistencyStore, TupleStore, Error EnError, IOE]

newCheckCacheEnv :: IO CheckCacheEnv
newCheckCacheEnv = do
    cache <- newCache CacheConfig{enabled = True, maxEntries = 100} :: IO (Cache SubproblemKey CheckDecision)
    pure CheckCacheEnv{cacheDatastoreId = DatastoreId "test", cacheDecisions = cache}

batchHandler :: Env TestEffects -> BatchCheckRequestWire -> Handler BatchCheckResponseWire
batchHandler env =
    batch
  where
    _write
        :<|> _delete
        :<|> _check
        :<|> batch
        :<|> _lookup
        :<|> _expand = server env

checkHandler :: Env TestEffects -> CheckRequestWire -> Handler CheckResponseWire
checkHandler env =
    checkEndpoint
  where
    _write
        :<|> _delete
        :<|> checkEndpoint
        :<|> _batch
        :<|> _lookup
        :<|> _expand = server env

lookupHandler :: Env TestEffects -> LookupRequestWire -> Handler LookupPageWire
lookupHandler env =
    lookupEndpoint
  where
    _write
        :<|> _delete
        :<|> _check
        :<|> _batch
        :<|> lookupEndpoint
        :<|> _expand = server env

pair :: Text -> Text -> Text -> BatchCheckPairWire
pair userId permission objectId =
    BatchCheckPairWire
        { subject = SubjectIdWire ObjectRefWire{objectType = "user", objectId = userId}
        , permission = permission
        , object = ObjectRefWire{objectType = "space", objectId = objectId}
        }

objectToWire :: ObjectRef -> ObjectRefWire
objectToWire ObjectRef{objectType = ObjectType objectType, objectId} =
    ObjectRefWire{objectType, objectId}

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

assertBool :: String -> Bool -> IO ()
assertBool label condition
    | condition = pure ()
    | otherwise = fail label

assertRight :: (Show err) => String -> Either err value -> IO ()
assertRight _ (Right _) = pure ()
assertRight label (Left err) =
    fail (label <> "\nexpected Right, got Left: " <> show err)
