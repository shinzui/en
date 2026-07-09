{-# LANGUAGE TypeOperators #-}

module Main (main) where

import Data.Aeson (FromJSON, ToJSON, decode, encode)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy (ByteString)
import Data.Functor ((<&>))
import Data.List qualified as List
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
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
import En.Decision (ResidualDecision)
import En.Effect.ConsistencyStore (ConsistencyStore)
import En.Effect.TupleStore (TupleStore)
import En.Error (EnError (..))
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
    EnResult (..),
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
import En.Servant.OpenApi (enOpenApi)
import En.Servant.Seam (
    EnFault (..),
    ErrorEnvelopeWire (..),
    enErrorToFault,
    faultToServerError,
 )
import En.Tuple (ObjectRef (..))

main :: IO ()
main = do
    wireContractTests
    errorModelTests
    openApiDocumentTests

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
                , deadlineDefaultMillis = 3000
                , deadlineMaxMillis = 30000
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
    assertEqual
        "batch endpoint returns decisions in order"
        (Right (EnOk BatchCheckResponseWire{decisions = [AllowedWire, DeniedWire]}))
        =<< runHandler (batch request)

    -- checkMany now hands the transport an Either per pair. The wire contract is
    -- unchanged: a pair the engine could not evaluate is reported as a denial,
    -- and it does not take the healthy pairs down with it. A per-pair error
    -- channel is docs/plans/35's to design.
    let failingPairRequest =
            request
                { pairs =
                    [ pair "alice" "view" "project-x"
                    , pair "alice" "no-such-permission" "project-x"
                    , pair "bob" "view" "project-x"
                    ]
                }
    assertEqual
        "an unevaluable pair fails closed without affecting the others"
        (Right (EnOk BatchCheckResponseWire{decisions = [AllowedWire, DeniedWire, DeniedWire]}))
        =<< runHandler (batch failingPairRequest)

    -- The oversized batch is a returned value, not a thrown ServerError: that is the
    -- point of the MultiVerb response list.
    let smallEnv = env{maxBatchSize = 1}
        oversized = request{pairs = [pair "alice" "view" "project-x", pair "bob" "view" "project-x"]}
    assertEqual
        "oversized batch returns a typed batch_too_large"
        (Just "batch_too_large")
        =<< clientErrorCodeOf (batchHandler smallEnv oversized)

    assertEqual
        "an unknown permission returns a typed unknown_relation"
        (Just "unknown_relation")
        =<< clientErrorCodeOf
            ( checkHandler
                env
                CheckRequestWire
                    { consistency = MinimizeLatencyWire
                    , context = CaveatContextWire Map.empty
                    , subject = SubjectIdWire ObjectRefWire{objectType = "user", objectId = "alice"}
                    , permission = "not_a_permission"
                    , object = ObjectRefWire{objectType = "space", objectId = "project-x"}
                    }
            )

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
    assertEqual "cached check endpoint returns Allowed first" (Right (EnOk CheckResponseWire{decision = AllowedWire})) =<< runHandler (checkEndpoint checkRequest)
    checkStatsAfterFirst <- cacheStats cachedCheckEnv.cacheDecisions
    assertEqual "cached check endpoint returns Allowed second" (Right (EnOk CheckResponseWire{decision = AllowedWire})) =<< runHandler (checkEndpoint checkRequest)
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
    assertOk "cached lookup endpoint returns a page first" =<< runHandler (lookupEndpoint lookupRequest)
    lookupStatsAfterFirst <- cacheStats cachedLookupEnv.cacheDecisions
    assertOk "cached lookup endpoint returns a page second" =<< runHandler (lookupEndpoint lookupRequest)
    lookupStatsAfterSecond <- cacheStats cachedLookupEnv.cacheDecisions
    assertBool "cached lookup endpoint uses decision cache for confirmations" (lookupStatsAfterSecond.hits > lookupStatsAfterFirst.hits)

    -- The server owns the lookup budget, not the caller. A `deadlineMaxMillis` of zero
    -- is an already-expired budget, so if the clamp reaches the engine the page reports
    -- `truncated` no matter how much time the client asked for.
    --
    -- The two runs differ only in `deadlineMaxMillis`, and `limit = 1` against a subject
    -- with two auditable spaces guarantees a next page -- which is what makes the
    -- distinction observable at all. `pageLookup` reports `hasMore` when the budget
    -- survives and `truncated` when it does not; an exhausted page would say neither.
    let greedyRequest = lookupRequest{deadlineMillis = Just 86400000, limit = 1}
        clampedEnv = env{deadlineMaxMillis = 0}
    assertEqual
        "the server clamps a client-supplied lookup deadline"
        (Right True)
        =<< fmap (fmap isTruncated) (runHandler (lookupHandler clampedEnv greedyRequest))
    assertEqual
        "the same request under the default ceiling keeps its budget"
        (Right True)
        =<< fmap (fmap hasMore) (runHandler (lookupHandler env greedyRequest))

{- | The generated document describes the API that is actually served.

Checks the two properties that silently rot: the path set, and that every operation
declares its error responses. The response statuses come from each operation's
'MultiVerb' response list, so this fails the moment an endpoint is added without one.
-}
openApiDocumentTests :: IO ()
openApiDocumentTests = do
    document <- either fail pure (Aeson.eitherDecode (encode enOpenApi))

    assertEqual
        "openapi document lists exactly the served operations"
        [ "/v1/batch-check"
        , "/v1/check"
        , "/v1/expand"
        , "/v1/lookup"
        , "/v1/relationships"
        , "/v1/relationships/delete"
        ]
        (List.sort (objectKeys (document `at` "paths")))

    mapM_
        ( \path ->
            assertEqual
                ("operation " <> Text.unpack path <> " documents its error responses")
                ["200", "400", "422", "503"]
                (List.sort (objectKeys (document `at` "paths" `at` Key.fromText path `at` "post" `at` "responses")))
        )
        [ "/v1/batch-check"
        , "/v1/check"
        , "/v1/expand"
        , "/v1/lookup"
        , "/v1/relationships"
        , "/v1/relationships/delete"
        ]

    assertBool
        "openapi document defines the error envelope"
        ("ErrorEnvelopeWire" `elem` objectKeys (document `at` "components" `at` "schemas"))
  where
    at :: Aeson.Value -> Key.Key -> Aeson.Value
    at (Aeson.Object o) key = maybe Aeson.Null id (KeyMap.lookup key o)
    at _ _ = Aeson.Null

    objectKeys :: Aeson.Value -> [Text]
    objectKeys (Aeson.Object o) = Key.toText <$> KeyMap.keys o
    objectKeys _ = []

{- | Pin the engine-error mapping: status, stable code, and retryability.

These three are the client's contract. A client decides whether to retry from
@retryable@ alone, and branches on @code@ — never on the message text, which is prose
and may change.
-}
errorModelTests :: IO ()
errorModelTests = do
    mapsTo "UnknownRelation" (UnknownRelation "audit") (400, "unknown_relation", False)
    mapsTo "SchemaViolation" (SchemaViolation "subject type not permitted") (400, "schema_violation", False)
    mapsTo "MissingCaveatContext" (MissingCaveatContext ["now"]) (400, "missing_caveat_context", False)
    mapsTo "InvalidConsistencyToken" (InvalidConsistencyToken "bad token") (400, "invalid_consistency_token", False)
    mapsTo "ResolutionLimitExceeded" ResolutionLimitExceeded (422, "resolution_limit_exceeded", False)
    mapsTo "CycleDetected" (CycleDetected "space:recursive#view") (422, "cycle_detected", False)
    mapsTo "StoreError" (StoreError secretDetail) (503, "store_error", True)

    -- The 503 message must never carry the SQL text and bound parameters that
    -- Hasql.toDetailedText puts in StoreError; the operator gets those on stderr.
    assertBool
        "store_error envelope hides the store's detail"
        (not (secretDetail `Text.isInfixOf` (envelopeOf (enErrorToFault (StoreError secretDetail))).message))

    assertEqual
        "unknown_relation names the offending relation"
        "unknown relation or permission: audit"
        (envelopeOf (enErrorToFault (UnknownRelation "audit"))).message

    golden
        "ErrorEnvelopeWire"
        "{\"code\":\"store_error\",\"message\":\"the tuple store failed; retry later\",\"retryable\":true}"
        (envelopeOf (enErrorToFault (StoreError secretDetail)))
  where
    secretDetail = "SELECT * FROM relation_tuple WHERE object_id = $1 -- 'alice'"

    mapsTo :: String -> EnError -> (Int, Text, Bool) -> IO ()
    mapsTo label err expected =
        assertEqual ("error mapping: " <> label) expected (statusCodeRetryable (enErrorToFault err))

    statusCodeRetryable :: EnFault -> (Int, Text, Bool)
    statusCodeRetryable fault =
        (errHTTPCode (faultToServerError fault), envelope.code, envelope.retryable)
      where
        envelope = envelopeOf fault

envelopeOf :: EnFault -> ErrorEnvelopeWire
envelopeOf = \case
    BadRequestFault envelope -> envelope
    UnprocessableFault envelope -> envelope
    UnavailableFault envelope -> envelope

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
    cache <- newCache CacheConfig{enabled = True, maxEntries = 100} :: IO (Cache SubproblemKey ResidualDecision)
    pure CheckCacheEnv{cacheDatastoreId = DatastoreId "test", cacheDecisions = cache}

batchHandler :: Env TestEffects -> BatchCheckRequestWire -> Handler (EnResult BatchCheckResponseWire)
batchHandler env =
    batch
  where
    _write
        :<|> _delete
        :<|> _check
        :<|> batch
        :<|> _lookup
        :<|> _expand = server env

checkHandler :: Env TestEffects -> CheckRequestWire -> Handler (EnResult CheckResponseWire)
checkHandler env =
    checkEndpoint
  where
    _write
        :<|> _delete
        :<|> checkEndpoint
        :<|> _batch
        :<|> _lookup
        :<|> _expand = server env

lookupHandler :: Env TestEffects -> LookupRequestWire -> Handler (EnResult LookupPageWire)
lookupHandler env =
    lookupEndpoint
  where
    _write
        :<|> _delete
        :<|> _check
        :<|> _batch
        :<|> lookupEndpoint
        :<|> _expand = server env

-- | Did the engine stop early because its deadline had elapsed?
isTruncated :: EnResult LookupPageWire -> Bool
isTruncated = \case
    EnOk page ->
        case page.state of
            LookupTruncatedWire _ -> True
            _ -> False
    _ -> False

-- | Did the engine leave a next page with budget to spare?
hasMore :: EnResult LookupPageWire -> Bool
hasMore = \case
    EnOk page ->
        case page.state of
            LookupHasMoreWire _ -> True
            _ -> False
    _ -> False

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

{- | The @code@ of a handler's 400 response, if it produced one.

'Nothing' covers every other outcome — success, a non-400 fault, or a thrown
'ServerError' — so a test asserting @Just "…"@ pins both the status and the code.
-}
clientErrorCodeOf :: Handler (EnResult a) -> IO (Maybe Text)
clientErrorCodeOf handler =
    runHandler handler <&> \case
        Right (EnClientError envelope) -> Just envelope.code
        _ -> Nothing

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

{- | The handler neither threw nor returned a fault.

Weaker than 'assertEqual' on the payload, and used where the payload is a page whose
exact contents are not the property under test — but strictly stronger than checking
for 'Right', which an 'EnClientError' would also satisfy.
-}
assertOk :: (Show err, Show value) => String -> Either err (EnResult value) -> IO ()
assertOk _ (Right (EnOk _)) = pure ()
assertOk label (Right fault) =
    fail (label <> "\nexpected EnOk, got: " <> show fault)
assertOk label (Left err) =
    fail (label <> "\nexpected Right, got Left: " <> show err)
