{-# LANGUAGE TypeOperators #-}

module Main (main) where

import Data.Aeson (FromJSON, ToJSON, decode, encode)
import Data.ByteString.Lazy (ByteString)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
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
    CaveatObligationWire (..),
    CaveatPayloadWire (..),
    CaveatValueWire (..),
    CheckDecisionWire (..),
    CheckRequestWire (..),
    CheckResponseWire (..),
    ConsistencyWire (..),
    DeleteTuplesRequestWire (..),
    Env (..),
    ExpandNodeWire (..),
    ExpandRequestWire (..),
    ExpandStateWire (..),
    ExpandTreeWire (..),
    LookupObjectWire (..),
    LookupPageWire (..),
    LookupRequestWire (..),
    LookupStateWire (..),
    ObjectRefWire (..),
    SubjectWire (..),
    TupleCaveatWire (..),
    TupleWire (..),
    WriteTuplesRequestWire (..),
    WriteTuplesResponseWire (..),
    server,
 )
import En.Tuple (ObjectRef (..))

main :: IO ()
main = do
    wireContractTests

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

{- | Freeze the JSON wire contract of every type in "En.Servant.API".

Each type gets an exact-bytes golden encoding, a decode round-trip, and — for sum
types — a negative decode proving an unknown discriminator is rejected rather than
silently defaulted. The golden bytes are the API's public contract; changing one is a
breaking change for every client and must be versioned by path.
-}
wireContractTests :: IO ()
wireContractTests = do
    golden "ObjectRefWire" "{\"objectType\":\"space\",\"objectId\":\"project-x\"}" projectX

    golden "SubjectWire/id" "{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"alice\"}" aliceSubject
    golden
        "SubjectWire/set"
        "{\"kind\":\"set\",\"objectType\":\"group\",\"objectId\":\"eng\",\"relation\":\"member\"}"
        (SubjectSetWire ObjectRefWire{objectType = "group", objectId = "eng"} "member")
    golden "SubjectWire/wildcard" "{\"kind\":\"wildcard\",\"objectType\":\"user\"}" (SubjectWildcardWire "user")
    rejects "SubjectWire" (decode "{\"kind\":\"nobody\",\"objectType\":\"user\"}" :: Maybe SubjectWire)

    golden "CaveatValueWire/text" "{\"type\":\"text\",\"value\":\"hello\"}" (ValueTextWire "hello")
    golden "CaveatValueWire/bool" "{\"type\":\"bool\",\"value\":true}" (ValueBoolWire True)
    golden "CaveatValueWire/integer" "{\"type\":\"integer\",\"value\":42}" (ValueIntegerWire 42)
    golden
        "CaveatValueWire/timestamp"
        "{\"type\":\"timestamp\",\"value\":\"2026-07-07T12:00:00Z\"}"
        (ValueTimestampWire noon)
    golden "CaveatValueWire/enum" "{\"type\":\"enum\",\"value\":\"read\"}" (ValueEnumWire "read")
    rejects "CaveatValueWire" (decode "{\"type\":\"blob\",\"value\":\"x\"}" :: Maybe CaveatValueWire)

    golden
        "CaveatPayloadWire"
        "{\"values\":{\"now\":{\"type\":\"timestamp\",\"value\":\"2026-07-07T12:00:00Z\"}}}"
        businessHoursPayload
    golden "CaveatContextWire" "{\"values\":{}}" emptyContext

    golden
        "TupleCaveatWire"
        "{\"name\":\"business_hours\",\"payload\":{\"values\":{\"now\":{\"type\":\"timestamp\",\"value\":\"2026-07-07T12:00:00Z\"}}}}"
        businessHoursCaveat
    golden
        "TupleWire"
        "{\"object\":{\"objectType\":\"space\",\"objectId\":\"project-x\"},\"relation\":\"viewer\",\"subject\":{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"alice\"},\"caveat\":null}"
        viewerTuple
    assertEqual
        "TupleWire decodes an absent caveat as Nothing"
        (Just viewerTuple)
        ( decode
            "{\"object\":{\"objectType\":\"space\",\"objectId\":\"project-x\"},\"relation\":\"viewer\",\"subject\":{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"alice\"}}"
        )

    golden "ConsistencyWire/minimizeLatency" "{\"mode\":\"minimizeLatency\"}" MinimizeLatencyWire
    golden "ConsistencyWire/fullyConsistent" "{\"mode\":\"fullyConsistent\"}" FullyConsistentWire
    golden
        "ConsistencyWire/atLeastAsFresh"
        "{\"mode\":\"atLeastAsFresh\",\"token\":\"en1.abc\"}"
        (AtLeastAsFreshWire "en1.abc")
    golden
        "ConsistencyWire/atExactSnapshot"
        "{\"mode\":\"atExactSnapshot\",\"token\":\"en1.abc\"}"
        (AtExactSnapshotWire "en1.abc")
    rejects "ConsistencyWire" (decode "{\"mode\":\"freshest\"}" :: Maybe ConsistencyWire)

    golden
        "CheckRequestWire"
        "{\"consistency\":{\"mode\":\"minimizeLatency\"},\"context\":{\"values\":{}},\"subject\":{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"alice\"},\"permission\":\"view\",\"object\":{\"objectType\":\"space\",\"objectId\":\"project-x\"}}"
        CheckRequestWire
            { consistency = MinimizeLatencyWire
            , context = emptyContext
            , subject = aliceSubject
            , permission = "view"
            , object = projectX
            }

    golden "CheckDecisionWire/allowed" "{\"result\":\"allowed\"}" AllowedWire
    golden "CheckDecisionWire/denied" "{\"result\":\"denied\"}" DeniedWire
    golden
        "CheckDecisionWire/conditional"
        "{\"result\":\"conditional\",\"obligations\":[{\"caveat\":\"business_hours\",\"missingContext\":[\"now\"]}]}"
        conditionalDecision
    rejects "CheckDecisionWire" (decode "{\"result\":\"maybe\"}" :: Maybe CheckDecisionWire)

    golden
        "CaveatObligationWire"
        "{\"caveat\":\"business_hours\",\"missingContext\":[\"now\"]}"
        CaveatObligationWire{caveat = "business_hours", missingContext = ["now"]}
    golden "CheckResponseWire" "{\"decision\":{\"result\":\"allowed\"}}" CheckResponseWire{decision = AllowedWire}

    golden
        "BatchCheckPairWire"
        "{\"subject\":{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"alice\"},\"permission\":\"view\",\"object\":{\"objectType\":\"space\",\"objectId\":\"project-x\"}}"
        viewPair
    golden
        "BatchCheckRequestWire"
        "{\"consistency\":{\"mode\":\"minimizeLatency\"},\"context\":{\"values\":{}},\"pairs\":[{\"subject\":{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"alice\"},\"permission\":\"view\",\"object\":{\"objectType\":\"space\",\"objectId\":\"project-x\"}}]}"
        BatchCheckRequestWire{consistency = MinimizeLatencyWire, context = emptyContext, pairs = [viewPair]}
    golden
        "BatchCheckResponseWire"
        "{\"decisions\":[{\"result\":\"allowed\"},{\"result\":\"denied\"}]}"
        BatchCheckResponseWire{decisions = [AllowedWire, DeniedWire]}

    golden
        "LookupRequestWire"
        "{\"consistency\":{\"mode\":\"minimizeLatency\"},\"subject\":{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"alice\"},\"permission\":\"view\",\"objectType\":\"space\",\"context\":{\"values\":{}},\"limit\":10,\"cursor\":null,\"deadlineMillis\":null}"
        LookupRequestWire
            { consistency = MinimizeLatencyWire
            , subject = aliceSubject
            , permission = "view"
            , objectType = "space"
            , context = emptyContext
            , limit = 10
            , cursor = Nothing
            , deadlineMillis = Nothing
            }
    golden
        "LookupObjectWire"
        "{\"object\":{\"objectType\":\"space\",\"objectId\":\"project-x\"},\"decision\":{\"result\":\"allowed\"}}"
        allowedObject
    golden "LookupStateWire/exhausted" "{\"status\":\"exhausted\"}" LookupExhaustedWire
    golden "LookupStateWire/hasMore" "{\"status\":\"hasMore\",\"cursor\":\"c1\"}" (LookupHasMoreWire "c1")
    golden "LookupStateWire/truncated" "{\"status\":\"truncated\",\"cursor\":\"c2\"}" (LookupTruncatedWire "c2")
    rejects "LookupStateWire" (decode "{\"status\":\"partial\"}" :: Maybe LookupStateWire)
    golden
        "LookupPageWire"
        "{\"objects\":[{\"object\":{\"objectType\":\"space\",\"objectId\":\"project-x\"},\"decision\":{\"result\":\"allowed\"}}],\"state\":{\"status\":\"exhausted\"}}"
        LookupPageWire{objects = [allowedObject], state = LookupExhaustedWire}

    golden
        "ExpandRequestWire"
        "{\"consistency\":{\"mode\":\"fullyConsistent\"},\"object\":{\"objectType\":\"space\",\"objectId\":\"project-x\"},\"permission\":\"view\",\"context\":{\"values\":{}},\"limit\":10,\"cursor\":null}"
        ExpandRequestWire
            { consistency = FullyConsistentWire
            , object = projectX
            , permission = "view"
            , context = emptyContext
            , limit = 10
            , cursor = Nothing
            }
    golden
        "ExpandNodeWire/subject"
        "{\"kind\":\"subject\",\"subject\":{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"alice\"}}"
        (ExpandSubjectWire aliceSubject)
    golden
        "ExpandNodeWire/userset"
        "{\"kind\":\"userset\",\"object\":{\"objectType\":\"group\",\"objectId\":\"eng\"},\"relation\":\"member\",\"children\":[]}"
        (ExpandUsersetWire ObjectRefWire{objectType = "group", objectId = "eng"} "member" [])
    golden
        "ExpandNodeWire/caveated"
        "{\"kind\":\"caveated\",\"caveat\":\"business_hours\",\"children\":[]}"
        (ExpandCaveatedWire "business_hours" [])
    rejects "ExpandNodeWire" (decode "{\"kind\":\"group\"}" :: Maybe ExpandNodeWire)
    golden "ExpandStateWire/exhausted" "{\"status\":\"exhausted\"}" ExpandExhaustedWire
    golden "ExpandStateWire/hasMore" "{\"status\":\"hasMore\",\"cursor\":\"c1\"}" (ExpandHasMoreWire "c1")
    golden "ExpandStateWire/truncated" "{\"status\":\"truncated\",\"cursor\":\"c2\"}" (ExpandTruncatedWire "c2")
    rejects "ExpandStateWire" (decode "{\"status\":\"partial\"}" :: Maybe ExpandStateWire)
    golden
        "ExpandTreeWire"
        "{\"root\":{\"objectType\":\"space\",\"objectId\":\"project-x\"},\"permission\":\"view\",\"children\":[],\"state\":{\"status\":\"exhausted\"}}"
        ExpandTreeWire{root = projectX, permission = "view", children = [], state = ExpandExhaustedWire}

    golden
        "WriteTuplesRequestWire"
        "{\"tuples\":[{\"object\":{\"objectType\":\"space\",\"objectId\":\"project-x\"},\"relation\":\"viewer\",\"subject\":{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"alice\"},\"caveat\":null}]}"
        WriteTuplesRequestWire{tuples = [viewerTuple]}
    golden
        "DeleteTuplesRequestWire"
        "{\"tuples\":[{\"object\":{\"objectType\":\"space\",\"objectId\":\"project-x\"},\"relation\":\"viewer\",\"subject\":{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"alice\"},\"caveat\":null}]}"
        DeleteTuplesRequestWire{tuples = [viewerTuple]}
    golden "WriteTuplesResponseWire" "{\"token\":\"en1.abc\"}" WriteTuplesResponseWire{token = "en1.abc"}

    -- A caveated tuple exercises the payload nesting the simpler goldens skip.
    roundTrip
        "TupleWire/caveated"
        TupleWire
            { object = projectX
            , relation = "viewer"
            , subject = aliceSubject
            , caveat = Just businessHoursCaveat
            }
    roundTrip "CheckResponseWire/conditional" CheckResponseWire{decision = conditionalDecision}
  where
    noon = UTCTime (fromGregorian 2026 7 7) (secondsToDiffTime (12 * 3600))
    projectX = ObjectRefWire{objectType = "space", objectId = "project-x"}
    aliceSubject = SubjectIdWire ObjectRefWire{objectType = "user", objectId = "alice"}
    emptyContext = CaveatContextWire Map.empty
    businessHoursPayload = CaveatPayloadWire (Map.fromList [("now", ValueTimestampWire noon)])
    businessHoursCaveat = TupleCaveatWire{name = "business_hours", payload = businessHoursPayload}
    viewerTuple =
        TupleWire
            { object = projectX
            , relation = "viewer"
            , subject = aliceSubject
            , caveat = Nothing
            }
    conditionalDecision =
        ConditionalWire [CaveatObligationWire{caveat = "business_hours", missingContext = ["now"]}]
    viewPair = BatchCheckPairWire{subject = aliceSubject, permission = "view", object = projectX}
    allowedObject = LookupObjectWire{object = projectX, decision = AllowedWire}

{- | Assert the exact encoded bytes, then that the value survives a decode of them.
Exact bytes are meaningful because every 'ToJSON' instance defines 'toEncoding'
explicitly, which fixes field order.
-}
golden :: (Eq a, Show a, ToJSON a, FromJSON a) => String -> ByteString -> a -> IO ()
golden label expected value = do
    assertEqual ("golden encoding: " <> label) expected (encode value)
    assertEqual ("round-trip: " <> label) (Just value) (decode expected)

roundTrip :: (Eq a, Show a, ToJSON a, FromJSON a) => String -> a -> IO ()
roundTrip label value =
    assertEqual ("round-trip: " <> label) (Just value) (decode (encode value))

-- | An unknown discriminator must fail the decode, never fall through to a default.
rejects :: (Show a) => String -> Maybe a -> IO ()
rejects label = \case
    Nothing -> pure ()
    Just value -> fail (label <> " accepted an unknown discriminator: " <> show value)

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
