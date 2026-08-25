{-# LANGUAGE TypeOperators #-}

module Main (main) where

import Auth.Biscuit (toPublic)
import Data.Aeson (FromJSON, ToJSON, decode, encode)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Lazy (ByteString)
import Data.Foldable qualified as Foldable
import Data.Functor ((<&>))
import Data.List qualified as List
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.OpenApi (ToSchema, validateToJSON)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (encodeUtf8)
import Data.Time (UTCTime (..), fromGregorian, getCurrentTime, secondsToDiffTime)
import Effectful (Eff, IOE, runEff)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import En.Biscuit.Grant (Audience (..))
import En.Biscuit.Keys (parseSigningKeyText, singleKey)
import En.Biscuit.Verify (VerifiedGrant (..), VerifyRequest (..), verifyGrant)
import En.Budget (defaultEvaluationBudget)
import En.Cache (Cache, CacheConfig (..), CacheStats (..), SubproblemKey, cacheStats, newCache)
import En.Check (CheckCacheEnv (..), check, checkCached)
import En.Conformance.Kikan
  ( fixtureTuples,
    inMemoryToken,
    kikanGraph,
    memberOwner,
    runConsistencyStoreInMemory,
    runTupleStoreInMemory,
    testRevision,
  )
import En.Decision (ResidualDecision)
import En.Effect.ConsistencyStore (ConsistencyStore, mintToken)
import En.Effect.TupleStore (ChangePage (..), RelationshipFilter, TupleStore, headRevision, readChanges)
import En.Error (EnError (..))
import En.Lookup qualified as Lookup
import En.LookupSubjects qualified as LookupSubjects
import En.Postgres.Revision (tokenMetadataFromPayload)
import En.Reachability (ReachabilityGraph (..))
import En.Revision (ConsistencyToken (..), DatastoreId (..), SchemaHash (..))
import En.Schema (ObjectType (..), RelationName (..))
import En.Servant.API
  ( BatchCheckPairWire (..),
    BatchCheckRequestWire (..),
    BatchCheckResponseWire (..),
    CaveatContextWire (..),
    CaveatObligationWire (..),
    CaveatPayloadWire (..),
    CaveatValueWire (..),
    ChangeKindWire (..),
    CheckDecisionWire (..),
    CheckRequestWire (..),
    CheckResponseWire (..),
    ConsistencyWire (..),
    DeleteRelationshipsRequestWire (..),
    DeleteRelationshipsResponseWire (..),
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
    LookupSubjectWire (..),
    LookupSubjectsPageWire (..),
    LookupSubjectsRequestWire (..),
    LookupSubjectsStateWire (..),
    MintGrantRequestWire (..),
    MintGrantResponseWire (..),
    ObjectRefWire (..),
    PreconditionWire (..),
    ReadRelationshipsRequestWire (..),
    ReadRelationshipsResponseWire (..),
    RelationshipFilterWire (..),
    RelationshipsStateWire (..),
    SchemaInfoWire (..),
    SubjectRelationFilterWire (..),
    SubjectWire (..),
    TupleCaveatWire (..),
    TupleChangeWire (..),
    TupleFilterWire (..),
    TupleWire (..),
    WatchRequestWire (..),
    WatchResponseWire (..),
    WriteTuplesRequestWire (..),
    WriteTuplesResponseWire (..),
    app,
    batchCheckHandler,
    checkHandler,
    deleteRelationshipsHandler,
    deleteTuplesHandler,
    expandHandler,
    lookupHandler,
    lookupSubjectsHandler,
    mintGrantHandler,
    readRelationshipsHandler,
    schemaHandler,
    watchHandler,
    writeTuplesHandler,
  )
import En.Servant.OpenApi (enOpenApi)
import En.Servant.Problem
  ( ProblemDetails (..),
    ProblemSpec (..),
    problem,
    problemCatalog,
    specInvalidRequest,
  )
import En.Servant.Seam
  ( ActiveSchema (..),
    EnFault (..),
    MintEnv (..),
    enErrorToFault,
    faultToServerError,
  )
import En.Tuple (ObjectRef (..), Subject (..))
import En.Watch (WatchBatch (..), WatchStart (..))
import Network.HTTP.Types (methodDelete, methodPost, statusCode)
import Network.Wai (Application, Request (..), defaultRequest)
import Network.Wai.Test (SRequest (..), SResponse (..), runSession, setPath, srequest)
import Servant (Handler, ServerError (..), runHandler)

main :: IO ()
main = do
  problemMachineryTests
  wireContractTests
  errorModelTests
  openApiDocumentTests
  toJsonMatchesToSchema

  let env =
        Env
          { runPorts = \_active ->
              runEff
                . runErrorNoCallStack
                . runTupleStoreInMemory fixtureTuples
                . runConsistencyStoreInMemory,
            readActiveSchema = pure testActiveSchema,
            checkOperation = check,
            lookupWithDeadlineOperation = Lookup.lookupWithDeadline,
            lookupSubjectsWithDeadlineOperation = LookupSubjects.lookupSubjectsWithDeadline,
            watchOperation = stubWatch,
            budget = defaultEvaluationBudget,
            maxBatchSize = 10,
            deadlineDefaultMillis = 3000,
            deadlineMaxMillis = 30000,
            mint = Nothing
          }
      batch = batchCheckHandler env
      request =
        BatchCheckRequestWire
          { consistency = MinimizeLatencyWire,
            context = CaveatContextWire Map.empty,
            pairs =
              [ pair "alice" "view" "project-x",
                pair "bob" "view" "project-x"
              ]
          }
  assertEqual
    "batch endpoint returns decisions in order"
    (Right (EnOk BatchCheckResponseWire {decisions = [AllowedWire, DeniedWire], checkedAt = testCheckedAt}))
    =<< runHandler (batch request)

  -- checkMany now hands the transport an Either per pair. The wire contract is
  -- unchanged: a pair the engine could not evaluate is reported as a denial,
  -- and it does not take the healthy pairs down with it. A per-pair error
  -- channel is docs/plans/35's to design.
  let failingPairRequest =
        request
          { pairs =
              [ pair "alice" "view" "project-x",
                pair "alice" "no-such-permission" "project-x",
                pair "bob" "view" "project-x"
              ]
          }
  assertEqual
    "an unevaluable pair fails closed without affecting the others"
    (Right (EnOk BatchCheckResponseWire {decisions = [AllowedWire, DeniedWire, DeniedWire], checkedAt = testCheckedAt}))
    =<< runHandler (batch failingPairRequest)

  -- The oversized batch is a returned value, not a thrown ServerError: that is the
  -- point of the MultiVerb response list.
  let smallEnv = env {maxBatchSize = 1}
      oversized = request {pairs = [pair "alice" "view" "project-x", pair "bob" "view" "project-x"]}
  assertEqual
    "oversized batch returns a typed batch_too_large"
    (Just "batch_too_large")
    =<< clientErrorCodeOf (batchCheckHandler smallEnv oversized)

  assertEqual
    "an unknown permission returns a typed unknown_relation"
    (Just "unknown_relation")
    =<< clientErrorCodeOf
      ( checkHandler
          env
          CheckRequestWire
            { consistency = MinimizeLatencyWire,
              context = CaveatContextWire Map.empty,
              subject = SubjectIdWire ObjectRefWire {objectType = "user", objectId = "alice"},
              permission = "not_a_permission",
              object = ObjectRefWire {objectType = "space", objectId = "project-x"}
            }
      )

  -- B10 on the wire: `audit` is `owner AND member`. Before operator nodes the client
  -- received a flat pair of usersets, byte-identical to what `act` (an OR of the same
  -- two) produces — so an access review could not tell a conjunction from a disjunction.
  let auditedSpaceRef = ObjectRefWire {objectType = "space", objectId = "audited-space"}
      memberOwnerSubject = SubjectIdWire ObjectRefWire {objectType = "user", objectId = "member-owner"}
      conjunct relation = ExpandUsersetWire auditedSpaceRef relation [ExpandSubjectWire memberOwnerSubject]
      auditRequest =
        ExpandRequestWire
          { consistency = MinimizeLatencyWire,
            object = auditedSpaceRef,
            permission = "audit",
            context = CaveatContextWire Map.empty,
            limit = 20,
            cursor = Nothing
          }
  assertEqual
    "expand endpoint returns the audit conjunction as one intersection node"
    ( Right
        ( EnOk
            ExpandTreeWire
              { root = auditedSpaceRef,
                permission = "audit",
                children = [ExpandIntersectionWire [conjunct "owner", conjunct "member"]],
                state = ExpandExhaustedWire,
                checkedAt = testCheckedAt
              }
        )
    )
    =<< runHandler (expandHandler env auditRequest)
  -- And the same tree as the bytes a real client parses, not merely as a Haskell value.
  runHandler (expandHandler env auditRequest) >>= \case
    Right (EnOk tree) ->
      assertEqual
        "the audit tree a client receives, byte for byte"
        "{\"root\":{\"objectType\":\"space\",\"objectId\":\"audited-space\"},\"permission\":\"audit\",\"children\":[{\"kind\":\"intersection\",\"children\":[{\"kind\":\"userset\",\"object\":{\"objectType\":\"space\",\"objectId\":\"audited-space\"},\"relation\":\"owner\",\"children\":[{\"kind\":\"subject\",\"subject\":{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"member-owner\"}}]},{\"kind\":\"userset\",\"object\":{\"objectType\":\"space\",\"objectId\":\"audited-space\"},\"relation\":\"member\",\"children\":[{\"kind\":\"subject\",\"subject\":{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"member-owner\"}}]}]}],\"state\":{\"status\":\"exhausted\"},\"checkedAt\":\"in-memory:test:test-revision\"}"
        (encode tree)
    other -> fail ("expand endpoint did not answer: " <> show other)

  cachedCheckEnv <- newCheckCacheEnv
  let cachedEnv =
        env
          { checkOperation = checkCached cachedCheckEnv,
            lookupWithDeadlineOperation = Lookup.lookupWithDeadlineCached cachedCheckEnv
          }
      checkEndpoint = checkHandler cachedEnv
      checkRequest =
        CheckRequestWire
          { consistency = MinimizeLatencyWire,
            context = CaveatContextWire Map.empty,
            subject = SubjectIdWire ObjectRefWire {objectType = "user", objectId = "alice"},
            permission = "view",
            object = ObjectRefWire {objectType = "space", objectId = "project-x"}
          }
  assertEqual "cached check endpoint returns Allowed first" (Right (EnOk CheckResponseWire {decision = AllowedWire, checkedAt = testCheckedAt})) =<< runHandler (checkEndpoint checkRequest)
  checkStatsAfterFirst <- cacheStats cachedCheckEnv.cacheDecisions
  assertEqual "cached check endpoint returns Allowed second" (Right (EnOk CheckResponseWire {decision = AllowedWire, checkedAt = testCheckedAt})) =<< runHandler (checkEndpoint checkRequest)
  checkStatsAfterSecond <- cacheStats cachedCheckEnv.cacheDecisions
  assertBool "cached check endpoint uses decision cache" (checkStatsAfterSecond.hits > checkStatsAfterFirst.hits)

  {- E3, the headline property: a read's token is accepted as a later read's
  freshness bound. Check, take the token the response says it was decided at, and
  ask for a lookup at least as fresh as it. The chain closes, which is what a caller
  needs in order to build "read your own writes, then read your own reads". -}
  checkedToken <-
    runHandler (checkHandler env checkRequest) >>= \case
      Right (EnOk response) -> pure response.checkedAt
      other -> fail ("check endpoint did not answer: " <> show other)
  assertOk "a lookup at least as fresh as a check's token is served"
    =<< runHandler
      ( lookupHandler
          env
          LookupRequestWire
            { consistency = AtLeastAsFreshWire checkedToken,
              subject = SubjectIdWire (objectToWire memberOwner),
              permission = "audit",
              objectType = "space",
              context = CaveatContextWire Map.empty,
              limit = 10,
              cursor = Nothing,
              deadlineMillis = Nothing
            }
      )

  cachedLookupEnv <- newCheckCacheEnv
  let lookupCachedEnv =
        env
          { checkOperation = checkCached cachedLookupEnv,
            lookupWithDeadlineOperation = Lookup.lookupWithDeadlineCached cachedLookupEnv
          }
      lookupEndpoint = lookupHandler lookupCachedEnv
      lookupRequest =
        LookupRequestWire
          { consistency = MinimizeLatencyWire,
            subject = SubjectIdWire (objectToWire memberOwner),
            permission = "audit",
            objectType = "space",
            context = CaveatContextWire Map.empty,
            limit = 10,
            cursor = Nothing,
            deadlineMillis = Nothing
          }
  assertOk "cached lookup endpoint returns a page first" =<< runHandler (lookupEndpoint lookupRequest)
  lookupStatsAfterFirst <- cacheStats cachedLookupEnv.cacheDecisions
  assertOk "cached lookup endpoint returns a page second" =<< runHandler (lookupEndpoint lookupRequest)
  lookupStatsAfterSecond <- cacheStats cachedLookupEnv.cacheDecisions
  assertBool "cached lookup endpoint uses decision cache for confirmations" (lookupStatsAfterSecond.hits > lookupStatsAfterFirst.hits)

  {- The wire carries a cursor as opaque text and hands it to the engine unread, so
  the engine's cursor validation is what protects the endpoint. A retired v1 cursor
  -- whose revision field a client could choose freely -- and an unparsable one are
  both malformed /cursors/, so they surface as a 400 under `invalid_cursor`, the same
  code a malformed watch cursor gets (docs/plans/60, M2). `enErrorToFault` maps
  `InvalidCursor` to a client fault. -}
  assertEqual
    "a retired v1 lookup cursor is a client error"
    (Just "invalid_cursor")
    =<< clientErrorCodeOf (lookupEndpoint lookupRequest {cursor = Just "lookup-v1|13:test-revision|0:|0:"})
  assertEqual
    "an unparsable lookup cursor is a client error"
    (Just "invalid_cursor")
    =<< clientErrorCodeOf (lookupEndpoint lookupRequest {cursor = Just "not-a-cursor"})

  -- The server owns the lookup budget, not the caller. A `deadlineMaxMillis` of zero
  -- is an already-expired budget, so if the clamp reaches the engine the page reports
  -- `truncated` no matter how much time the client asked for.
  --
  -- The two runs differ only in `deadlineMaxMillis`, and `limit = 1` against a subject
  -- with two auditable spaces guarantees a next page -- which is what makes the
  -- distinction observable at all. `pageLookup` reports `hasMore` when the budget
  -- survives and `truncated` when it does not; an exhausted page would say neither.
  -- Spelled out rather than updated from `lookupRequest`: `deadlineMillis` and `limit`
  -- no longer name a unique record now that `LookupSubjectsRequestWire` carries both,
  -- and GHC's type-directed disambiguation of such an update is on its way out.
  let greedyRequest =
        LookupRequestWire
          { consistency = MinimizeLatencyWire,
            subject = SubjectIdWire (objectToWire memberOwner),
            permission = "audit",
            objectType = "space",
            context = CaveatContextWire Map.empty,
            limit = 1,
            cursor = Nothing,
            deadlineMillis = Just 86400000
          }
      clampedEnv = env {deadlineMaxMillis = 0}
  assertEqual
    "the server clamps a client-supplied lookup deadline"
    (Right True)
    =<< fmap (fmap isTruncated) (runHandler (lookupHandler clampedEnv greedyRequest))
  assertEqual
    "the same request under the default ceiling keeps its budget"
    (Right True)
    =<< fmap (fmap hasMore) (runHandler (lookupHandler env greedyRequest))

  lookupSubjectsTests env
  writePreconditionTests env
  mintGrantTests env
  routingTests env

-- | The RFC 9457 machinery in isolation. This deliberately uses a throwaway API
-- rather than changing a production route: the WAI response, generated client, and
-- OpenAPI generator must all agree before the real response lists migrate.
problemMachineryTests :: IO ()
problemMachineryTests = do
  let sample = problem specInvalidRequest "the request did not pass validation"
  assertEqual
    "problem details round-trip through their shared codec"
    (Just sample)
    (decode (encode sample))
  assertEqual
    "problem details use the six RFC-plus-extension wire keys"
    ["code", "detail", "retryable", "status", "title", "type"]
    (List.sort (valueObjectKeys (either error id (Aeson.eitherDecode (encode sample)))))

  let catalogCodes = map (.code) problemCatalog
      retryableCodes = List.sort [spec.code | spec <- problemCatalog, spec.retryable]
  assertEqual
    "the problem catalog has one stable specification per code"
    (Set.size (Set.fromList catalogCodes))
    (length catalogCodes)
  assertEqual
    "only dependency outages and rate limits are retryable"
    ["rate_limited", "store_error"]
    retryableCodes

valueObjectKeys :: Aeson.Value -> [Text]
valueObjectKeys (Aeson.Object objectValue) = Key.toText <$> KeyMap.keys objectValue
valueObjectKeys _ = []

-- | @\/v1\/lookup-subjects@ over the wire, against the in-memory store.
--
-- The algorithm's correctness — operators, caveats, wildcards — is pinned by the
-- conformance suite in @en-core/conformance/Main.hs@. What is pinned here is everything
-- between the socket and the engine: the exact bytes a client receives, the four ways a
-- request is rejected before evaluation, the decision cache the server wires in, and the
-- deadline ceiling the server owns rather than the caller.
lookupSubjectsTests :: Env TestEffects -> IO ()
lookupSubjectsTests env = do
  -- Group nesting: `space:userset-member-space#member` grants the userset
  -- `org:acme#member`, and `agency-alice` is a member of it. The answer is the flat
  -- concrete user, not the userset that led to her.
  runHandler (lookupSubjectsHandler env groupNesting) >>= \case
    Right (EnOk page) ->
      assertEqual
        "the sharing-dialog answer a client receives, byte for byte"
        "{\"subjects\":[{\"subject\":{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"agency-alice\"},\"decision\":{\"result\":\"allowed\"}}],\"state\":{\"status\":\"exhausted\"},\"checkedAt\":\"in-memory:test:test-revision\"}"
        (encode page)
    other -> fail ("lookup-subjects endpoint did not answer: " <> show other)

  assertEqual
    "an empty subjectType is a client error"
    (Just "invalid_request")
    =<< clientErrorCodeOf (lookupSubjectsHandler env groupNesting {subjectType = ""})
  assertEqual
    "an empty permission is a client error"
    (Just "invalid_request")
    =<< clientErrorCodeOf (lookupSubjectsHandler env groupNesting {permission = ""})
  -- A zero limit would answer with an empty page whose cursor equals the caller's own,
  -- so a client draining pages would spin forever without advancing.
  assertEqual
    "a non-positive limit is a client error"
    (Just "invalid_request")
    =<< clientErrorCodeOf (lookupSubjectsHandler env groupNesting {limit = 0})
  -- The wire hands the cursor to the engine unread, so the engine's validation is what
  -- protects the endpoint. A malformed cursor is `InvalidCursor`, which `enErrorToFault`
  -- maps to a 400 under `invalid_cursor` (docs/plans/60, M2).
  assertEqual
    "an unparsable lookup-subjects cursor is a client error"
    (Just "invalid_cursor")
    =<< clientErrorCodeOf (lookupSubjectsHandler env groupNesting {cursor = Just "not-a-cursor"})

  -- `audit = owner & member` is an intersection, so every candidate costs a confirming
  -- check. Those confirmations are what the decision cache serves on the second call.
  cachedSubjectsCache <- newCheckCacheEnv
  let cachedSubjectsEnv =
        env {lookupSubjectsWithDeadlineOperation = LookupSubjects.lookupSubjectsWithDeadlineCached cachedSubjectsCache}
      auditRequest :: LookupSubjectsRequestWire
      auditRequest = groupNesting {object = auditedSpace, permission = "audit"}
  assertOk "cached lookup-subjects returns a page first" =<< runHandler (lookupSubjectsHandler cachedSubjectsEnv auditRequest)
  statsAfterFirst <- cacheStats cachedSubjectsCache.cacheDecisions
  assertOk "cached lookup-subjects returns a page second" =<< runHandler (lookupSubjectsHandler cachedSubjectsEnv auditRequest)
  statsAfterSecond <- cacheStats cachedSubjectsCache.cacheDecisions
  assertBool
    "cached lookup-subjects uses the decision cache for confirmations"
    (statsAfterSecond.hits > statsAfterFirst.hits)

  -- The server owns the time budget. A `deadlineMaxMillis` of zero is an already-expired
  -- one, so if the clamp reaches the engine the page reports `truncated` however much
  -- time the client asked for. `space:exclusion-space#member` has two members and
  -- `limit = 1` guarantees a next page, which is what makes the distinction observable.
  let greedyRequest :: LookupSubjectsRequestWire
      greedyRequest =
        groupNesting
          { object = exclusionSpace,
            permission = "member",
            limit = 1,
            deadlineMillis = Just 86400000
          }
      clampedEnv = env {deadlineMaxMillis = 0}
  assertEqual
    "the server clamps a client-supplied lookup-subjects deadline"
    (Right True)
    =<< fmap (fmap subjectsTruncated) (runHandler (lookupSubjectsHandler clampedEnv greedyRequest))
  assertEqual
    "the same request under the default ceiling keeps its budget"
    (Right True)
    =<< fmap (fmap subjectsHasMore) (runHandler (lookupSubjectsHandler env greedyRequest))
  where
    groupNesting =
      LookupSubjectsRequestWire
        { consistency = MinimizeLatencyWire,
          object = ObjectRefWire {objectType = "space", objectId = "userset-member-space"},
          permission = "view",
          subjectType = "user",
          context = CaveatContextWire Map.empty,
          limit = 10,
          cursor = Nothing,
          deadlineMillis = Nothing
        }
    auditedSpace = ObjectRefWire {objectType = "space", objectId = "audited-space"}
    exclusionSpace = ObjectRefWire {objectType = "space", objectId = "exclusion-space"}

-- | Did the lookup-subjects traversal stop early because its deadline had elapsed?
subjectsTruncated :: EnResult LookupSubjectsPageWire -> Bool
subjectsTruncated = \case
  EnOk page ->
    case page.state of
      SubjectsTruncatedWire _ -> True
      _ -> False
  _ -> False

-- | Did it leave a next page with budget to spare?
subjectsHasMore :: EnResult LookupSubjectsPageWire -> Bool
subjectsHasMore = \case
  EnOk page ->
    case page.state of
      SubjectsHasMoreWire _ -> True
      _ -> False
  _ -> False

-- | Preconditions over the wire, against the in-memory store.
--
-- Three properties: a body written before preconditions existed still decodes and
-- still writes; a precondition that does not hold refuses the write with @412@ and
-- a stable code; and a precondition that does hold lets the write through.
--
-- `fixtureTuples` has @space:project-x#owner\@user:alice@ and no @viewer@ grant for
-- bob, which is what makes the must-exist and must-not-exist cases both expressible
-- without seeding anything.
writePreconditionTests :: Env TestEffects -> IO ()
writePreconditionTests env = do
  legacyBody <-
    maybe (fail "a legacy write body no longer decodes") pure $
      decode
        "{\"tuples\":[{\"object\":{\"objectType\":\"space\",\"objectId\":\"project-x\"},\"relation\":\"owner\",\"subject\":{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"bob\"},\"caveat\":null}]}"
  assertEqual
    "a write body without the new fields still decodes to an unguarded request"
    (WriteTuplesRequestWire {tuples = legacyBody.tuples, deletes = Nothing, preconditions = Nothing})
    legacyBody
  assertOk "a legacy write body still writes" =<< runHandler (writeTuplesHandler env legacyBody)

  -- alice IS an owner of project-x, so requiring her absence must refuse the write.
  assertEqual
    "a write whose must-not-exist precondition is violated is refused"
    (Just "write_precondition_failed")
    =<< preconditionCodeOf
      ( writeTuplesHandler
          env
          WriteTuplesRequestWire
            { tuples = [bobOwnerTuple],
              deletes = Nothing,
              preconditions = Just [TupleMustNotExistWire (ownerFilter "alice")]
            }
      )

  -- ... and requiring her presence must let it through.
  assertOk "a write whose must-exist precondition holds is applied"
    =<< runHandler
      ( writeTuplesHandler
          env
          WriteTuplesRequestWire
            { tuples = [bobOwnerTuple],
              deletes = Nothing,
              preconditions = Just [TupleMustExistWire (ownerFilter "alice")]
            }
      )

  -- The delete endpoint carries preconditions too.
  assertEqual
    "a delete whose must-exist precondition fails is refused"
    (Just "write_precondition_failed")
    =<< preconditionCodeOf
      ( deleteTuplesHandler
          env
          DeleteTuplesRequestWire
            { tuples = [bobOwnerTuple],
              preconditions = Just [TupleMustExistWire (ownerFilter "nobody")]
            }
      )

  -- A filter naming no object type cannot be index-served, so it is a client error.
  assertEqual
    "a precondition filter with an empty objectType is a client error"
    (Just "invalid_request")
    =<< clientErrorCodeOf
      ( writeTuplesHandler
          env
          WriteTuplesRequestWire
            { tuples = [],
              deletes = Nothing,
              preconditions = Just [TupleMustExistWire (ownerFilter "alice") {objectType = ""}]
            }
      )

  relationshipEndpointTests env
  watchEndpointTests env
  schemaEndpointTests env
  where
    bobOwnerTuple =
      TupleWire
        { object = ObjectRefWire {objectType = "space", objectId = "project-x"},
          relation = "owner",
          subject = SubjectIdWire ObjectRefWire {objectType = "user", objectId = "bob"},
          caveat = Nothing
        }
    ownerFilter subjectId =
      TupleFilterWire
        { objectType = "space",
          objectId = Just "project-x",
          relation = Just "owner",
          subjectType = Just "user",
          subjectId = Just subjectId,
          subjectRelation = Just NoSubjectRelationWire
        }

-- | The third OpenAPI conformance property: every wire DTO's 'ToJSON' produces JSON that
-- validates against its own hand-written 'ToSchema'.
--
-- en is precisely the case this guards — both its aeson and its schema are hand-written (the
-- aeson in the slices, the schema as orphans in "En.Servant.OpenApi"), so a field renamed on one
-- side only is invisible until a generated client fails to decode. 'validateToJSON' returns the
-- list of ways an encoded value violates its schema; it must be empty for every DTO. The
-- 'ToSchema' instances arrive via the (instance-bearing) import of "En.Servant.OpenApi".
toJsonMatchesToSchema :: IO ()
toJsonMatchesToSchema = do
  conforms "ObjectRefWire" objRef
  conforms "SubjectWire/id" subj
  conforms "SubjectWire/set" (SubjectSetWire objRef "member")
  conforms "SubjectWire/wildcard" (SubjectWildcardWire "user")
  conforms "CaveatValueWire" (ValueTextWire "hello")
  conforms "CaveatPayloadWire" payload
  conforms "CaveatContextWire" ctx
  conforms "TupleCaveatWire" caveat
  conforms "TupleWire" tuple
  conforms "ConsistencyWire/minimize" MinimizeLatencyWire
  conforms "ConsistencyWire/atLeastAsFresh" (AtLeastAsFreshWire "tok")
  conforms "CheckRequestWire" checkRequest
  conforms "CaveatObligationWire" obligation
  conforms "CheckDecisionWire/allowed" AllowedWire
  conforms "CheckDecisionWire/conditional" (ConditionalWire [obligation])
  conforms "CheckResponseWire" CheckResponseWire {decision = AllowedWire, checkedAt = "tok"}
  conforms "MintGrantRequestWire" mintRequest
  conforms "MintGrantResponseWire" MintGrantResponseWire {token = "en.tok", expiresAt = noon, revocationIds = ["ab"], checkedAt = "tok"}
  conforms "BatchCheckPairWire" batchPair
  conforms "BatchCheckRequestWire" BatchCheckRequestWire {consistency = MinimizeLatencyWire, context = ctx, pairs = [batchPair]}
  conforms "BatchCheckResponseWire" BatchCheckResponseWire {decisions = [AllowedWire], checkedAt = "tok"}
  conforms "LookupRequestWire" lookupRequest
  conforms "LookupObjectWire" lookupObject
  conforms "LookupStateWire/exhausted" LookupExhaustedWire
  conforms "LookupStateWire/hasMore" (LookupHasMoreWire "c")
  conforms "LookupPageWire" LookupPageWire {objects = [lookupObject], state = LookupExhaustedWire, checkedAt = "tok"}
  conforms "LookupSubjectsRequestWire" lookupSubjectsRequest
  conforms "LookupSubjectWire" lookupSubject
  conforms "LookupSubjectsStateWire" SubjectsExhaustedWire
  conforms "LookupSubjectsPageWire" LookupSubjectsPageWire {subjects = [lookupSubject], state = SubjectsExhaustedWire, checkedAt = "tok"}
  conforms "ExpandRequestWire" expandRequest
  conforms "ExpandNodeWire/subject" (ExpandSubjectWire subj)
  conforms "ExpandNodeWire/union" (ExpandUnionWire [ExpandSubjectWire subj])
  conforms "ExpandStateWire" ExpandExhaustedWire
  conforms "ExpandTreeWire" ExpandTreeWire {root = objRef, permission = "view", children = [], state = ExpandExhaustedWire, checkedAt = "tok"}
  conforms "SubjectRelationFilterWire" NoSubjectRelationWire
  conforms "TupleFilterWire" tupleFilter
  conforms "RelationshipFilterWire" relFilter
  conforms "ReadRelationshipsRequestWire" ReadRelationshipsRequestWire {consistency = MinimizeLatencyWire, filter = relFilter, limit = 100, cursor = Nothing}
  conforms "RelationshipsStateWire" RelationshipsExhaustedWire
  conforms "ReadRelationshipsResponseWire" ReadRelationshipsResponseWire {relationships = [tuple], state = RelationshipsExhaustedWire, checkedAt = "tok"}
  conforms "DeleteRelationshipsRequestWire" DeleteRelationshipsRequestWire {filter = relFilter, dryRun = True}
  conforms "DeleteRelationshipsResponseWire" DeleteRelationshipsResponseWire {dryRun = True, count = 3, token = Nothing}
  conforms "WatchRequestWire" WatchRequestWire {cursor = Nothing, startToken = Nothing, filter = Just relFilter, limit = 100}
  conforms "ChangeKindWire" TouchWire
  conforms "TupleChangeWire" TupleChangeWire {kind = TouchWire, tuple = tuple}
  conforms "WatchResponseWire" WatchResponseWire {changes = [TupleChangeWire {kind = TouchWire, tuple = tuple}], cursor = "c", checkedAt = "tok"}
  conforms "SchemaInfoWire" SchemaInfoWire {source = "object user {}\n", hash = "fnv1a64:abc", origin = "builtin-demo", loadedAt = noon}
  conforms "PreconditionWire" (TupleMustExistWire tupleFilter)
  conforms "WriteTuplesRequestWire" WriteTuplesRequestWire {tuples = [tuple], deletes = Nothing, preconditions = Nothing}
  conforms "DeleteTuplesRequestWire" DeleteTuplesRequestWire {tuples = [tuple], preconditions = Nothing}
  conforms "WriteTuplesResponseWire" WriteTuplesResponseWire {token = "en.tok"}
  conforms "ProblemDetails" (problem specInvalidRequest "unknown relation")
  where
    noon = UTCTime (fromGregorian 2026 7 7) (secondsToDiffTime (12 * 3600))
    objRef = ObjectRefWire {objectType = "space", objectId = "project-x"}
    userRef = ObjectRefWire {objectType = "user", objectId = "alice"}
    subj = SubjectIdWire userRef
    ctx = CaveatContextWire Map.empty
    payload = CaveatPayloadWire (Map.fromList [("now", ValueTextWire "v")])
    caveat = TupleCaveatWire {name = "business_hours", payload = payload}
    tuple = TupleWire {object = objRef, relation = "viewer", subject = subj, caveat = Nothing}
    obligation = CaveatObligationWire {caveat = "business_hours", missingContext = ["now"]}
    batchPair = BatchCheckPairWire {subject = subj, permission = "view", object = objRef}
    lookupObject = LookupObjectWire {object = objRef, decision = AllowedWire}
    lookupSubject = LookupSubjectWire {subject = subj, decision = AllowedWire}
    tupleFilter =
      TupleFilterWire
        { objectType = "space",
          objectId = Just "project-x",
          relation = Just "viewer",
          subjectType = Just "user",
          subjectId = Just "alice",
          subjectRelation = Just NoSubjectRelationWire
        }
    relFilter = subjectFilterWire "user" "alice"
    checkRequest =
      CheckRequestWire
        { consistency = MinimizeLatencyWire,
          context = ctx,
          subject = subj,
          permission = "view",
          object = objRef
        }
    mintRequest =
      MintGrantRequestWire
        { consistency = MinimizeLatencyWire,
          context = ctx,
          subject = subj,
          permission = "view",
          object = objRef,
          audience = "doc-service",
          ttlSeconds = Just 120,
          requestId = Just "req-1"
        }
    lookupRequest =
      LookupRequestWire
        { consistency = MinimizeLatencyWire,
          subject = subj,
          permission = "view",
          objectType = "space",
          context = ctx,
          limit = 10,
          cursor = Nothing,
          deadlineMillis = Nothing
        }
    lookupSubjectsRequest =
      LookupSubjectsRequestWire
        { consistency = MinimizeLatencyWire,
          object = objRef,
          permission = "view",
          subjectType = "user",
          context = ctx,
          limit = 10,
          cursor = Nothing,
          deadlineMillis = Nothing
        }
    expandRequest =
      ExpandRequestWire
        { consistency = MinimizeLatencyWire,
          object = objRef,
          permission = "view",
          context = ctx,
          limit = 10,
          cursor = Nothing
        }

    conforms :: (ToJSON a, ToSchema a) => String -> a -> IO ()
    conforms label value = case validateToJSON value of
      [] -> pure ()
      errs -> fail (label <> " does not match its schema: " <> show errs)

-- | End-to-end routing and the problem-document hook, driven through the real WAI
-- 'Application' rather than by calling handlers directly.
--
-- The handler-level tests above call each handler as a function, so they never exercise
-- Servant's routing or the problem formatters installed by 'app'. This drives 'app env'
-- over the socket-facing surface: it proves each path reaches its own handler (a misroute
-- would 404), that a well-formed request returns its typed 200 body, and — the point of the
-- milestone — that the two pre-handler error hooks still speak 'ProblemDetails'. A
-- malformed body is rejected by servant's body parser before any handler runs, so only
-- 'bodyParserErrorFormatter' can turn it into a problem document; an unmatched path is rejected by
-- routing, so only 'notFoundErrorFormatter' can. Neither is reachable from a handler test.
--
-- en has no live misordering hazard to guard here — every route carries a distinct request
-- body type (and the two bodyless verbs distinct shapes), so a transposition is already a
-- compile error. What this pins is the observable HTTP behavior, so the Milestone 3 module
-- move cannot silently change it.
routingTests :: Env TestEffects -> IO ()
routingTests env = do
  let application = app env

      aliceViewProjectX =
        CheckRequestWire
          { consistency = MinimizeLatencyWire,
            context = CaveatContextWire Map.empty,
            subject = SubjectIdWire ObjectRefWire {objectType = "user", objectId = "alice"},
            permission = "view",
            object = ObjectRefWire {objectType = "space", objectId = "project-x"}
          }

  -- POST /v1/check routes to the check handler and answers the typed decision.
  checkResponse <- postJson application "/v1/check" (encode aliceViewProjectX)
  assertEqual "POST /v1/check returns 200" 200 (statusCode checkResponse.simpleStatus)
  assertEqual
    "POST /v1/check decodes to CheckResponseWire and alice may view project-x"
    (Just AllowedWire)
    (fmap (.decision) (decode checkResponse.simpleBody :: Maybe CheckResponseWire))

  let unknownPermission =
        CheckRequestWire
          { consistency = MinimizeLatencyWire,
            context = CaveatContextWire Map.empty,
            subject = SubjectIdWire ObjectRefWire {objectType = "user", objectId = "alice"},
            permission = "not_a_permission",
            object = ObjectRefWire {objectType = "space", objectId = "project-x"}
          }
  typedFailure <- postJson application "/v1/check" (encode unknownPermission)
  assertEqual "a typed check failure is a 400" 400 (statusCode typedFailure.simpleStatus)
  assertEqual
    "a real MultiVerb failure is served as application/problem+json"
    (Just "application/problem+json")
    (lookup "Content-Type" typedFailure.simpleHeaders)
  assertEqual
    "a real MultiVerb failure carries the typed stable code"
    (Just "unknown_relation")
    (fmap (.code) (decode typedFailure.simpleBody :: Maybe ProblemDetails))

  -- POST /v1/lookup routes and returns a page.
  let aliceViewSpaces =
        LookupRequestWire
          { consistency = MinimizeLatencyWire,
            subject = SubjectIdWire ObjectRefWire {objectType = "user", objectId = "alice"},
            permission = "view",
            objectType = "space",
            context = CaveatContextWire Map.empty,
            limit = 10,
            cursor = Nothing,
            deadlineMillis = Nothing
          }
  lookupResponse <- postJson application "/v1/lookup" (encode aliceViewSpaces)
  assertEqual "POST /v1/lookup returns 200" 200 (statusCode lookupResponse.simpleStatus)
  assertBool
    "POST /v1/lookup decodes to LookupPageWire"
    (isJust (decode lookupResponse.simpleBody :: Maybe LookupPageWire))

  -- POST /v1/relationships routes to the write handler (the in-memory store accepts writes).
  let writeBody =
        WriteTuplesRequestWire
          { tuples =
              [ TupleWire
                  { object = ObjectRefWire {objectType = "space", objectId = "project-x"},
                    relation = "viewer",
                    subject = SubjectIdWire ObjectRefWire {objectType = "user", objectId = "bob"},
                    caveat = Nothing
                  }
              ],
            deletes = Nothing,
            preconditions = Nothing
          }
  writeResponse <- postJson application "/v1/relationships" (encode writeBody)
  assertEqual "POST /v1/relationships routes to the write handler (200, not 404)" 200 (statusCode writeResponse.simpleStatus)

  -- POST /v1/expand routes.
  let expandBody =
        ExpandRequestWire
          { consistency = MinimizeLatencyWire,
            object = ObjectRefWire {objectType = "space", objectId = "project-x"},
            permission = "view",
            context = CaveatContextWire Map.empty,
            limit = 10,
            cursor = Nothing
          }
  expandResponse <- postJson application "/v1/expand" (encode expandBody)
  assertEqual "POST /v1/expand returns 200" 200 (statusCode expandResponse.simpleStatus)

  -- POST /v1/batch-check routes.
  let batchBody =
        BatchCheckRequestWire
          { consistency = MinimizeLatencyWire,
            context = CaveatContextWire Map.empty,
            pairs = [pair "alice" "view" "project-x"]
          }
  batchResponse <- postJson application "/v1/batch-check" (encode batchBody)
  assertEqual "POST /v1/batch-check returns 200" 200 (statusCode batchResponse.simpleStatus)

  {- The point of the milestone: a malformed body comes back as a machine-readable
  problem, proving envelopeFormatters' bodyParserErrorFormatter survived the refactor. -}
  malformed <- postJson application "/v1/check" "not json at all"
  assertEqual "a malformed body is a 400" 400 (statusCode malformed.simpleStatus)
  assertEqual
    "a malformed body returns ProblemDetails with code malformed_request_body"
    (Just "malformed_request_body")
    (fmap (.code) (decode malformed.simpleBody :: Maybe ProblemDetails))
  assertEqual
    "a malformed body uses application/problem+json"
    (Just "application/problem+json")
    (lookup "Content-Type" malformed.simpleHeaders)
  assertEqual
    "a malformed body's status member matches its HTTP status"
    (Just 400)
    (fmap (.status) (decode malformed.simpleBody :: Maybe ProblemDetails))

  -- An unmatched path comes back as a 404 problem, proving notFoundErrorFormatter.
  notThere <- postJson application "/v1/no-such-path" "{}"
  assertEqual "an unknown path is a 404" 404 (statusCode notThere.simpleStatus)
  assertEqual
    "an unknown path returns ProblemDetails with code not_found"
    (Just "not_found")
    (fmap (.code) (decode notThere.simpleBody :: Maybe ProblemDetails))
  assertEqual
    "an unknown path uses application/problem+json"
    (Just "application/problem+json")
    (lookup "Content-Type" notThere.simpleHeaders)
  assertEqual
    "an unknown path's status member matches its HTTP status"
    (Just 404)
    (fmap (.status) (decode notThere.simpleBody :: Maybe ProblemDetails))

  methodMismatch <-
    runSession
      ( srequest
          SRequest
            { simpleRequest = setPath defaultRequest {requestMethod = methodDelete} "/v1/relationships",
              simpleRequestBody = ""
            }
      )
      application
  assertEqual "DELETE /v1/relationships is a 405" 405 (statusCode methodMismatch.simpleStatus)
  assertEqual
    "the method mismatch returns the stable problem code"
    (Just "method_not_allowed")
    (fmap (.code) (decode methodMismatch.simpleBody :: Maybe ProblemDetails))
  assertEqual
    "the method mismatch uses application/problem+json"
    (Just "application/problem+json")
    (lookup "Content-Type" methodMismatch.simpleHeaders)
  assertEqual
    "the method mismatch body's status member matches its HTTP status"
    (Just 405)
    (fmap (.status) (decode methodMismatch.simpleBody :: Maybe ProblemDetails))

-- | @POST <path>@ with a JSON body, driven through the WAI 'Application'.
postJson :: Application -> BS.ByteString -> ByteString -> IO SResponse
postJson application path body =
  runSession
    ( srequest
        SRequest
          { simpleRequest =
              setPath
                defaultRequest
                  { requestMethod = methodPost,
                    requestHeaders = [("Content-Type", "application/json")]
                  }
                path,
            simpleRequestBody = body
          }
    )
    application

-- | The generated document describes the API that is actually served.
--
-- Checks the two properties that silently rot: the path set, and that every operation
-- declares its error responses. The response statuses come from each operation's
-- 'MultiVerb' response list, so this fails the moment an endpoint is added without one.
openApiDocumentTests :: IO ()
openApiDocumentTests = do
  document <- either fail pure (Aeson.eitherDecode (encode enOpenApi))

  assertEqual
    "openapi document lists exactly the served operations"
    (List.sort ("/v1/schema" : "/v1/grants" : postPaths))
    (List.sort (objectKeys (document `at` "paths")))

  mapM_
    ( \path ->
        assertEqual
          ("operation " <> Text.unpack path <> " documents its error responses")
          ["200", "400", "412", "422", "500", "503"]
          (List.sort (objectKeys (document `at` "paths" `at` Key.fromText path `at` "post" `at` "responses")))
    )
    postPaths

  -- GET /v1/schema reads an IORef. It has no EnResponses alternatives to document,
  -- and asserting that is what keeps a later refactor from quietly giving it some.
  assertEqual
    "the schema endpoint is a GET with only a 200"
    ["200"]
    (List.sort (objectKeys (document `at` "paths" `at` "/v1/schema" `at` "get" `at` "responses")))

  -- POST /v1/grants throws its authorization outcomes (404 disabled, 403 not-allowed) and
  -- its input faults as ServerErrors carrying ProblemDetails, rather than declaring
  -- them as MultiVerb alternatives. The document therefore shows only the 200 and the 400
  -- that servant-openapi derives from the JSON request body itself — not the 412/422/503
  -- every EnResponses operation carries. See 'En.Servant.API.mintGrantHandler'.
  assertEqual
    "the grants endpoint is a POST with only a 200 and the body-parse 400"
    ["200", "400"]
    (List.sort (objectKeys (document `at` "paths" `at` "/v1/grants" `at` "post" `at` "responses")))

  assertBool
    "openapi document defines RFC 9457 problem details"
    ("ProblemDetails" `elem` objectKeys (document `at` "components" `at` "schemas"))

  mapM_
    ( \name ->
        assertBool
          ("openapi document defines " <> Text.unpack name)
          (name `elem` objectKeys (document `at` "components" `at` "schemas"))
    )
    [ "RelationshipFilterWire",
      "ReadRelationshipsRequestWire",
      "ReadRelationshipsResponseWire",
      "RelationshipsStateWire",
      "DeleteRelationshipsRequestWire",
      "DeleteRelationshipsResponseWire",
      "WatchRequestWire",
      "ChangeKindWire",
      "TupleChangeWire",
      "WatchResponseWire",
      "SchemaInfoWire",
      "MintGrantRequestWire",
      "MintGrantResponseWire"
    ]

  -- `limit` is the only required field of a watch request. A schema that also required
  -- `cursor` would tell a code generator that a first poll is impossible.
  assertEqual
    "a watch request requires only its limit"
    ["limit"]
    (asTextList (document `at` "components" `at` "schemas" `at` "WatchRequestWire" `at` "required"))

  -- The "cursor or startToken, never both" rule cannot be expressed in `required` either.
  assertBool
    "the watch request schema documents its start-position rule"
    ( "startToken"
        `Text.isInfixOf` asText (document `at` "components" `at` "schemas" `at` "WatchRequestWire" `at` "description")
    )

  -- The filter's anchoring grammar cannot be expressed in `required`, so it must reach
  -- the reader through the description. Losing it makes the 400 look arbitrary.
  assertBool
    "the relationship filter schema documents its anchoring rule"
    ( "objectType"
        `Text.isInfixOf` asText (document `at` "components" `at` "schemas" `at` "RelationshipFilterWire" `at` "description")
    )

  -- dryRun is required. A schema that made it optional would tell a code generator to
  -- emit a field a caller can leave out of the most destructive call in the API.
  assertEqual
    "delete-by-filter requires both filter and dryRun"
    ["dryRun", "filter"]
    ( List.sort
        (asTextList (document `at` "components" `at` "schemas" `at` "DeleteRelationshipsRequestWire" `at` "required"))
    )
  where
    -- Every operation but GET /v1/schema, which has no request body and cannot fault.
    postPaths =
      [ "/v1/batch-check",
        "/v1/check",
        "/v1/expand",
        "/v1/lookup",
        "/v1/lookup-subjects",
        "/v1/relationships",
        "/v1/relationships/delete",
        "/v1/relationships/delete-by-filter",
        "/v1/relationships/query",
        "/v1/watch"
      ]

    asText :: Aeson.Value -> Text
    asText (Aeson.String text) = text
    asText _ = ""

    asTextList :: Aeson.Value -> [Text]
    asTextList (Aeson.Array values) = asText <$> Foldable.toList values
    asTextList _ = []

    at :: Aeson.Value -> Key.Key -> Aeson.Value
    at (Aeson.Object o) key = maybe Aeson.Null id (KeyMap.lookup key o)
    at _ _ = Aeson.Null

    objectKeys :: Aeson.Value -> [Text]
    objectKeys (Aeson.Object o) = Key.toText <$> KeyMap.keys o
    objectKeys _ = []

-- | A 'RelationshipFilterWire' built positionally, in field order: object type, object
-- id, relation, subject type, subject id, subject relation, caveat name.
--
-- A constructor application rather than a record update over an empty filter, because
-- 'TupleFilterWire' declares five of the same field names and GHC cannot disambiguate an
-- update whose every field is shared.
relationshipFilterWire ::
  Maybe Text ->
  Maybe Text ->
  Maybe Text ->
  Maybe Text ->
  Maybe Text ->
  Maybe SubjectRelationFilterWire ->
  Maybe Text ->
  RelationshipFilterWire
relationshipFilterWire objectType objectId relation subjectType subjectId subjectRelation caveatName =
  RelationshipFilterWire
    { objectType,
      objectId,
      relation,
      subjectType,
      subjectId,
      subjectRelation,
      caveatName
    }

emptyFilterWire :: RelationshipFilterWire
emptyFilterWire =
  relationshipFilterWire Nothing Nothing Nothing Nothing Nothing Nothing Nothing

subjectFilterWire :: Text -> Text -> RelationshipFilterWire
subjectFilterWire subjectType subjectId =
  relationshipFilterWire Nothing Nothing Nothing (Just subjectType) (Just subjectId) Nothing Nothing

-- | @GET \/v1\/schema@ reports the snapshot 'Env.readActiveSchema' hands it.
--
-- The hash is not a field of 'ActiveSchema'; it is @graph.hash@, so this also pins that the
-- endpoint reports the hash of the graph it is actually serving rather than one carried
-- alongside it. A reload swaps the graph, and the reported hash follows by construction.
schemaEndpointTests :: Env TestEffects -> IO ()
schemaEndpointTests env = do
  let SchemaHash expectedHash = testActiveSchema.graph.hash
  assertEqual
    "the schema endpoint reports the active snapshot"
    ( Right
        SchemaInfoWire
          { source = testActiveSchema.source,
            hash = expectedHash,
            origin = testActiveSchema.origin,
            loadedAt = testActiveSchema.loadedAt
          }
    )
    =<< runHandler (schemaHandler env)

-- | The watch endpoint's wire surface, over 'stubWatch'.
--
-- The store behind it reports every matching tuple as a touch, so what these assert is the
-- handler's own work: that a start position is well-formed, that a filter is validated by the
-- same grammar the relationship read uses, that the limit is positive and clamped, and that a
-- batch always carries a cursor. The window's semantics belong to PostgreSQL and are asserted
-- there.
watchEndpointTests :: Env TestEffects -> IO ()
watchEndpointTests env = do
  let poll cursor startToken watchFilter limit =
        watchHandler env WatchRequestWire {cursor, startToken, filter = watchFilter, limit}

      okPoll label cursor startToken watchFilter limit =
        runHandler (poll cursor startToken watchFilter limit) >>= \case
          Right (EnOk response) -> pure response
          other -> fail (label <> "\nexpected EnOk, got: " <> show other)

      identify response =
        [ (change.kind, change.tuple.object.objectType, change.tuple.object.objectId, change.tuple.relation)
        | change <- response.changes
        ]

  fromNow <- okPoll "poll from now" Nothing Nothing Nothing 100
  assertBool "a batch always carries a cursor" (not (Text.null fromNow.cursor))
  assertEqual "a batch carries the token of the snapshot it ends at" testCheckedAt fromNow.checkedAt

  -- A filter scopes the subscription, through the very grammar the relationship read uses.
  scoped <- okPoll "poll alice's grants" Nothing Nothing (Just (subjectFilterWire "user" "alice")) 100
  assertEqual
    "a filtered subscription reports only the grants its filter names"
    [ (TouchWire, "space", "project-x", "owner"),
      (TouchWire, "intention", "42", "delegate")
    ]
    (identify scoped)

  -- The limit is clamped to the server's page bound, not rejected above it.
  let smallEnv = env {maxBatchSize = 1}
  clamped <-
    runHandler (watchHandler smallEnv WatchRequestWire {cursor = Nothing, startToken = Nothing, filter = Nothing, limit = 100}) >>= \case
      Right (EnOk response) -> pure response
      other -> fail ("expected a clamped page, got: " <> show other)
  assertEqual "a limit above the server's bound is clamped, not rejected" 1 (length clamped.changes)

  {- Exactly one start position. Supplying two is the mistake worth naming: a caller that
  passes both a cursor and a token does not know where it wants to start, and choosing for
  it would silently skip or replay a window of revocations. -}
  assertEqual
    "cursor and startToken together are a client error"
    (Just "invalid_request")
    =<< clientErrorCodeOf (poll (Just "enwatch1.test.at.test-revision..") (Just "en1.token") Nothing 100)
  assertEqual
    "an empty cursor is a client error, not an implicit start-from-now"
    (Just "invalid_request")
    =<< clientErrorCodeOf (poll (Just "") Nothing Nothing 100)
  assertEqual
    "an empty startToken is a client error"
    (Just "invalid_request")
    =<< clientErrorCodeOf (poll Nothing (Just "") Nothing 100)
  assertEqual
    "a zero limit is a client error, because a drain over it would never advance"
    (Just "invalid_request")
    =<< clientErrorCodeOf (poll Nothing Nothing Nothing 0)
  assertEqual
    "an unanchored subscription filter is a client error, exactly as it is for a read"
    (Just "invalid_request")
    =<< clientErrorCodeOf (poll Nothing Nothing (Just emptyFilterWire) 100)

-- | The relationship query and delete-by-filter endpoints, against the in-memory store.
--
-- Each 'runPorts' call reinterprets 'runTupleStoreInMemory' over the fixture, so the store
-- is fresh per handler call and a deletion is not observable by a later read. That the
-- delete really retires rows — and that a pre-delete snapshot still sees them — is asserted
-- against PostgreSQL, in @en-postgres/integration-test/Main.hs@; here the question is only
-- whether the wire surface says the right things.
relationshipEndpointTests :: Env TestEffects -> IO ()
relationshipEndpointTests env = do
  let query relationshipFilter limit cursor =
        readRelationshipsHandler
          env
          ReadRelationshipsRequestWire
            { consistency = MinimizeLatencyWire,
              filter = relationshipFilter,
              limit,
              cursor
            }

      -- The fixture's two grants naming alice: space:project-x#owner and
      -- intention:42#delegate, in that row order.
      aliceGrants =
        [ ("space", "project-x", "owner"),
          ("intention", "42", "delegate")
        ]

      identify response =
        [ (wire.object.objectType, wire.object.objectId, wire.relation)
        | wire <- response.relationships
        ]

      okQuery label relationshipFilter limit cursor =
        runHandler (query relationshipFilter limit cursor) >>= \case
          Right (EnOk response) -> pure response
          other -> fail (label <> "\nexpected EnOk, got: " <> show other)

  aliceAll <- okQuery "query alice" (subjectFilterWire "user" "alice") 100 Nothing
  assertEqual "query returns every grant naming the subject" aliceGrants (identify aliceAll)
  assertEqual "a complete page is exhausted" RelationshipsExhaustedWire aliceAll.state

  -- Keyset pagination: the cursor resumes, it does not restart.
  firstPage <- okQuery "query alice, page 1" (subjectFilterWire "user" "alice") 1 Nothing
  assertEqual "the first page carries the requested limit" (take 1 aliceGrants) (identify firstPage)
  cursor <-
    case firstPage.state of
      RelationshipsHasMoreWire next -> pure next
      other -> fail ("expected the first page to have more, got " <> show other)
  secondPage <- okQuery "query alice, page 2" (subjectFilterWire "user" "alice") 1 (Just cursor)
  assertEqual "the second page resumes rather than restarts" (drop 1 aliceGrants) (identify secondPage)
  assertEqual "the second page is exhausted" RelationshipsExhaustedWire secondPage.state

  -- A caveat name is a residual predicate, and it is anchored by the subject.
  caveated <-
    okQuery
      "query alice's caveated grants"
      (relationshipFilterWire Nothing Nothing Nothing (Just "user") (Just "alice") Nothing (Just "within_autonomy"))
      100
      Nothing
  assertEqual
    "a caveat-name constraint selects only the caveated grant"
    [("intention", "42", "delegate")]
    (identify caveated)

  -- The grammar, on the wire. Each of these is a 400, not an expensive answer.
  assertEqual
    "a filter anchored on neither end is a client error"
    (Just "invalid_request")
    =<< clientErrorCodeOf (query emptyFilterWire 100 Nothing)
  assertEqual
    "a filter whose objectId names no objectType is a client error"
    (Just "invalid_request")
    =<< clientErrorCodeOf
      (query (relationshipFilterWire Nothing (Just "project-x") Nothing (Just "user") Nothing Nothing Nothing) 100 Nothing)
  assertEqual
    "a filter whose subjectId names no subjectType is a client error"
    (Just "invalid_request")
    =<< clientErrorCodeOf
      (query (relationshipFilterWire (Just "space") Nothing Nothing Nothing (Just "alice") Nothing Nothing) 100 Nothing)
  assertEqual
    "an empty-string constraint is a client error, not an absent one"
    (Just "invalid_request")
    =<< clientErrorCodeOf
      (query (relationshipFilterWire Nothing Nothing Nothing (Just "") Nothing Nothing Nothing) 100 Nothing)
  -- A zero limit returns an empty page whose cursor is the caller's own, so a drain
  -- loop over it would spin forever.
  assertEqual
    "a non-positive limit is a client error"
    (Just "invalid_request")
    =<< clientErrorCodeOf (query (subjectFilterWire "user" "alice") 0 Nothing)

  -- Delete-by-filter: a dry run counts and writes nothing; a real delete returns a token.
  runHandler (deleteRelationshipsHandler env DeleteRelationshipsRequestWire {filter = subjectFilterWire "user" "alice", dryRun = True}) >>= \case
    Right (EnOk response) ->
      assertEqual
        "a dry run reports the match count and mints no token"
        DeleteRelationshipsResponseWire {dryRun = True, count = 2, token = Nothing}
        response
    other -> fail ("dry run\nexpected EnOk, got: " <> show other)

  runHandler (deleteRelationshipsHandler env DeleteRelationshipsRequestWire {filter = subjectFilterWire "user" "alice", dryRun = False}) >>= \case
    Right (EnOk response) -> do
      assertEqual "a real delete reports the same count" 2 response.count
      assertBool "a real delete mints a token" (response.token /= Nothing)
      assertBool "a real delete says it was not a dry run" (not response.dryRun)
    other -> fail ("delete\nexpected EnOk, got: " <> show other)

  assertEqual
    "delete-by-filter rejects an unanchored filter before deleting anything"
    (Just "invalid_request")
    =<< clientErrorCodeOf (deleteRelationshipsHandler env DeleteRelationshipsRequestWire {filter = emptyFilterWire, dryRun = False})

-- | Pin the engine-error mapping: status, stable code, and retryability.
--
-- These three are the client's contract. A client decides whether to retry from
-- @retryable@ alone, and branches on @code@ — never on the message text, which is prose
-- and may change.
errorModelTests :: IO ()
errorModelTests = do
  mapsTo "UnknownRelation" (UnknownRelation "audit") (400, "unknown_relation", False)
  mapsTo "SchemaViolation" (SchemaViolation "subject type not permitted") (400, "schema_violation", False)
  mapsTo "MissingCaveatContext" (MissingCaveatContext ["now"]) (400, "missing_caveat_context", False)
  mapsTo "MalformedConsistencyToken" (MalformedConsistencyToken "not an en consistency token") (400, "malformed_consistency_token", False)
  mapsTo "ConsistencyTokenExpired" (ConsistencyTokenExpired "token is older than the garbage-collection window") (400, "consistency_token_expired", False)
  mapsTo "InvalidConsistencyToken" (InvalidConsistencyToken "bad token") (400, "invalid_consistency_token", False)
  mapsTo "InvalidCursor" (InvalidCursor "not-a-cursor") (400, "invalid_cursor", False)
  mapsTo "ResolutionLimitExceeded" ResolutionLimitExceeded (422, "resolution_limit_exceeded", False)
  mapsTo "CycleDetected" (CycleDetected "space:recursive#view") (422, "cycle_detected", False)
  mapsTo
    "WritePreconditionFailed"
    (WritePreconditionFailed "must-exist: space:project-x#member@user:alice")
    (412, "write_precondition_failed", False)
  mapsTo "InternalError" (InternalError secretDetail) (500, "internal_error", False)
  mapsTo "StoreError" (StoreError secretDetail) (503, "store_error", True)

  {- A precondition failure is an arbitration loss, not an outage. Retrying the same
  request without re-reading the state it was guarded on will fail identically, so
  `retryable` must stay False -- a client that retried on it would spin. -}
  assertEqual
    "write_precondition_failed names the precondition that did not hold"
    "write precondition did not hold: must-exist: space:project-x#member@user:alice"
    (problemOf (enErrorToFault (WritePreconditionFailed "must-exist: space:project-x#member@user:alice"))).detail

  -- The 503 message must never carry the SQL text and bound parameters that
  -- Hasql.toDetailedText puts in StoreError; the operator gets those on stderr.
  assertBool
    "store_error problem hides the store's detail"
    (not (secretDetail `Text.isInfixOf` (problemOf (enErrorToFault (StoreError secretDetail))).detail))
  assertBool
    "internal_error problem hides the implementation detail"
    (not (secretDetail `Text.isInfixOf` (problemOf (enErrorToFault (InternalError secretDetail))).detail))

  assertEqual
    "unknown_relation names the offending relation"
    "unknown relation or permission: audit"
    (problemOf (enErrorToFault (UnknownRelation "audit"))).detail

  golden
    "ProblemDetails"
    "{\"code\":\"store_error\",\"detail\":\"the tuple store failed; retry later\",\"retryable\":true,\"status\":503,\"title\":\"Store unavailable\",\"type\":\"about:blank\"}"
    (problemOf (enErrorToFault (StoreError secretDetail)))

  {- The regression guard for docs/plans/60, M2: a malformed consistency token must reach
  the wire as prose, never as the name of the internal 'En.Postgres.Revision.TokenDecodeError'
  constructor that classified it. Each of these strings trips a different decode branch; every
  resulting problem must carry a stable code and detail free of any internal constructor
  name. `TokenBad` alone catches every decode constructor; the `EnError` token names catch a
  `show`-the-error regression at the mapping layer. -}
  Foldable.traverse_
    assertNoConstructorLeak
    [ "xn1.a.b.c.d", -- TokenBadPrefix
      "en1.a.b.c", -- TokenBadFieldCount
      "en1.%zz.schema.10:20:.", -- TokenBadEscape
      "en1.primary.schema.not-a-snapshot.", -- TokenBadSnapshot
      "en1.primary.schema.10:20:.not-a-date" -- TokenBadExpiry
    ]
  where
    secretDetail = "SELECT * FROM relation_tuple WHERE object_id = $1 -- 'alice'"

    assertNoConstructorLeak tokenText =
      case tokenMetadataFromPayload (ConsistencyToken tokenText) of
        Right _ -> assertBool ("expected " <> Text.unpack tokenText <> " to be rejected as malformed") False
        Left err -> do
          let details = problemOf (enErrorToFault err)
          assertEqual
            ("a malformed token is a stable malformed_consistency_token: " <> Text.unpack tokenText)
            "malformed_consistency_token"
            details.code
          Foldable.traverse_
            ( \forbidden ->
                assertBool
                  ("response body for " <> Text.unpack tokenText <> " must not leak the internal name " <> Text.unpack forbidden <> "; got: " <> Text.unpack details.detail)
                  (not (forbidden `Text.isInfixOf` details.detail))
            )
            ["TokenBad", "MalformedConsistencyToken", "ConsistencyTokenExpired", "InvalidConsistencyToken"]

    mapsTo :: String -> EnError -> (Int, Text, Bool) -> IO ()
    mapsTo label err expected =
      assertEqual ("error mapping: " <> label) expected (statusCodeRetryable (enErrorToFault err))

    statusCodeRetryable :: EnFault -> (Int, Text, Bool)
    statusCodeRetryable fault =
      (errHTTPCode (faultToServerError fault), details.code, details.retryable)
      where
        details = problemOf fault

problemOf :: EnFault -> ProblemDetails
problemOf = \case
  BadRequestFault details -> details
  PreconditionFailedFault details -> details
  UnprocessableFault details -> details
  InternalFault details -> details
  UnavailableFault details -> details

-- | Freeze the JSON wire contract of every type in "En.Servant.API".
--
-- Each type gets an exact-bytes golden encoding, a decode round-trip, and — for sum
-- types — a negative decode proving an unknown discriminator is rejected rather than
-- silently defaulted. The golden bytes are the API's public contract; changing one is a
-- breaking change for every client and must be versioned by path.
wireContractTests :: IO ()
wireContractTests = do
  golden "ObjectRefWire" "{\"objectType\":\"space\",\"objectId\":\"project-x\"}" projectX

  golden "SubjectWire/id" "{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"alice\"}" aliceSubject
  golden
    "SubjectWire/set"
    "{\"kind\":\"set\",\"objectType\":\"group\",\"objectId\":\"eng\",\"relation\":\"member\"}"
    (SubjectSetWire ObjectRefWire {objectType = "group", objectId = "eng"} "member")
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
      { consistency = MinimizeLatencyWire,
        context = emptyContext,
        subject = aliceSubject,
        permission = "view",
        object = projectX
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
    CaveatObligationWire {caveat = "business_hours", missingContext = ["now"]}
  golden "CheckResponseWire" "{\"decision\":{\"result\":\"allowed\"},\"checkedAt\":\"tok\"}" CheckResponseWire {decision = AllowedWire, checkedAt = "tok"}

  golden
    "BatchCheckPairWire"
    "{\"subject\":{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"alice\"},\"permission\":\"view\",\"object\":{\"objectType\":\"space\",\"objectId\":\"project-x\"}}"
    viewPair
  golden
    "BatchCheckRequestWire"
    "{\"consistency\":{\"mode\":\"minimizeLatency\"},\"context\":{\"values\":{}},\"pairs\":[{\"subject\":{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"alice\"},\"permission\":\"view\",\"object\":{\"objectType\":\"space\",\"objectId\":\"project-x\"}}]}"
    BatchCheckRequestWire {consistency = MinimizeLatencyWire, context = emptyContext, pairs = [viewPair]}
  golden
    "BatchCheckResponseWire"
    "{\"decisions\":[{\"result\":\"allowed\"},{\"result\":\"denied\"}],\"checkedAt\":\"tok\"}"
    BatchCheckResponseWire {decisions = [AllowedWire, DeniedWire], checkedAt = "tok"}

  golden
    "LookupRequestWire"
    "{\"consistency\":{\"mode\":\"minimizeLatency\"},\"subject\":{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"alice\"},\"permission\":\"view\",\"objectType\":\"space\",\"context\":{\"values\":{}},\"limit\":10,\"cursor\":null,\"deadlineMillis\":null}"
    LookupRequestWire
      { consistency = MinimizeLatencyWire,
        subject = aliceSubject,
        permission = "view",
        objectType = "space",
        context = emptyContext,
        limit = 10,
        cursor = Nothing,
        deadlineMillis = Nothing
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
    "{\"objects\":[{\"object\":{\"objectType\":\"space\",\"objectId\":\"project-x\"},\"decision\":{\"result\":\"allowed\"}}],\"state\":{\"status\":\"exhausted\"},\"checkedAt\":\"tok\"}"
    LookupPageWire {objects = [allowedObject], state = LookupExhaustedWire, checkedAt = "tok"}

  golden
    "LookupSubjectsRequestWire"
    "{\"consistency\":{\"mode\":\"minimizeLatency\"},\"object\":{\"objectType\":\"space\",\"objectId\":\"project-x\"},\"permission\":\"view\",\"subjectType\":\"user\",\"context\":{\"values\":{}},\"limit\":10,\"cursor\":null,\"deadlineMillis\":null}"
    LookupSubjectsRequestWire
      { consistency = MinimizeLatencyWire,
        object = projectX,
        permission = "view",
        subjectType = "user",
        context = emptyContext,
        limit = 10,
        cursor = Nothing,
        deadlineMillis = Nothing
      }
  golden
    "LookupSubjectWire"
    "{\"subject\":{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"alice\"},\"decision\":{\"result\":\"allowed\"}}"
    allowedSubject
  -- A wildcard grant rides 'SubjectWildcardWire', so it is distinguishable from a
  -- concrete subject with no new discriminator. A client that renders `kind: "id"`
  -- would print the literal `*` as a user id if the two shared a shape.
  golden
    "LookupSubjectWire/wildcard"
    "{\"subject\":{\"kind\":\"wildcard\",\"objectType\":\"user\"},\"decision\":{\"result\":\"allowed\"}}"
    LookupSubjectWire {subject = SubjectWildcardWire "user", decision = AllowedWire}
  golden "LookupSubjectsStateWire/exhausted" "{\"status\":\"exhausted\"}" SubjectsExhaustedWire
  golden "LookupSubjectsStateWire/hasMore" "{\"status\":\"hasMore\",\"cursor\":\"c1\"}" (SubjectsHasMoreWire "c1")
  golden "LookupSubjectsStateWire/truncated" "{\"status\":\"truncated\",\"cursor\":\"c2\"}" (SubjectsTruncatedWire "c2")
  rejects "LookupSubjectsStateWire" (decode "{\"status\":\"partial\"}" :: Maybe LookupSubjectsStateWire)
  golden
    "LookupSubjectsPageWire"
    "{\"subjects\":[{\"subject\":{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"alice\"},\"decision\":{\"result\":\"allowed\"}}],\"state\":{\"status\":\"exhausted\"},\"checkedAt\":\"tok\"}"
    LookupSubjectsPageWire {subjects = [allowedSubject], state = SubjectsExhaustedWire, checkedAt = "tok"}

  golden
    "ExpandRequestWire"
    "{\"consistency\":{\"mode\":\"fullyConsistent\"},\"object\":{\"objectType\":\"space\",\"objectId\":\"project-x\"},\"permission\":\"view\",\"context\":{\"values\":{}},\"limit\":10,\"cursor\":null}"
    ExpandRequestWire
      { consistency = FullyConsistentWire,
        object = projectX,
        permission = "view",
        context = emptyContext,
        limit = 10,
        cursor = Nothing
      }
  golden
    "ExpandNodeWire/subject"
    "{\"kind\":\"subject\",\"subject\":{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"alice\"}}"
    (ExpandSubjectWire aliceSubject)
  golden
    "ExpandNodeWire/userset"
    "{\"kind\":\"userset\",\"object\":{\"objectType\":\"group\",\"objectId\":\"eng\"},\"relation\":\"member\",\"children\":[]}"
    (ExpandUsersetWire ObjectRefWire {objectType = "group", objectId = "eng"} "member" [])
  golden
    "ExpandNodeWire/caveated"
    "{\"kind\":\"caveated\",\"caveat\":\"business_hours\",\"children\":[]}"
    (ExpandCaveatedWire "business_hours" [])
  golden
    "ExpandNodeWire/union"
    "{\"kind\":\"union\",\"children\":[{\"kind\":\"subject\",\"subject\":{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"alice\"}}]}"
    (ExpandUnionWire [ExpandSubjectWire aliceSubject])
  golden
    "ExpandNodeWire/intersection"
    "{\"kind\":\"intersection\",\"children\":[{\"kind\":\"subject\",\"subject\":{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"alice\"}}]}"
    (ExpandIntersectionWire [ExpandSubjectWire aliceSubject])
  -- The two sides are distinct keys, so no encoder can quietly merge them.
  golden
    "ExpandNodeWire/exclusion"
    "{\"kind\":\"exclusion\",\"granted\":[{\"kind\":\"subject\",\"subject\":{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"alice\"}}],\"subtracted\":[]}"
    (ExpandExclusionWire [ExpandSubjectWire aliceSubject] [])
  rejects "ExpandNodeWire" (decode "{\"kind\":\"group\"}" :: Maybe ExpandNodeWire)
  golden "ExpandStateWire/exhausted" "{\"status\":\"exhausted\"}" ExpandExhaustedWire
  golden "ExpandStateWire/hasMore" "{\"status\":\"hasMore\",\"cursor\":\"c1\"}" (ExpandHasMoreWire "c1")
  golden "ExpandStateWire/truncated" "{\"status\":\"truncated\",\"cursor\":\"c2\"}" (ExpandTruncatedWire "c2")
  rejects "ExpandStateWire" (decode "{\"status\":\"partial\"}" :: Maybe ExpandStateWire)
  golden
    "ExpandTreeWire"
    "{\"root\":{\"objectType\":\"space\",\"objectId\":\"project-x\"},\"permission\":\"view\",\"children\":[],\"state\":{\"status\":\"exhausted\"},\"checkedAt\":\"tok\"}"
    ExpandTreeWire {root = projectX, permission = "view", children = [], state = ExpandExhaustedWire, checkedAt = "tok"}

  {- A request carrying no preconditions and no deletes must serialize to exactly the
  bytes it did before those fields existed: the optional fields are omitted, not
  encoded as null. This is one half of the backward-compatibility contract; the other
  half -- that such a body still decodes -- is `legacyRequestBodyTests`. -}
  golden
    "WriteTuplesRequestWire"
    "{\"tuples\":[{\"object\":{\"objectType\":\"space\",\"objectId\":\"project-x\"},\"relation\":\"viewer\",\"subject\":{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"alice\"},\"caveat\":null}]}"
    WriteTuplesRequestWire {tuples = [viewerTuple], deletes = Nothing, preconditions = Nothing}
  golden
    "DeleteTuplesRequestWire"
    "{\"tuples\":[{\"object\":{\"objectType\":\"space\",\"objectId\":\"project-x\"},\"relation\":\"viewer\",\"subject\":{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"alice\"},\"caveat\":null}]}"
    DeleteTuplesRequestWire {tuples = [viewerTuple], preconditions = Nothing}
  golden "WriteTuplesResponseWire" "{\"token\":\"en1.abc\"}" WriteTuplesResponseWire {token = "en1.abc"}

  golden
    "SubjectRelationFilterWire/any"
    "{\"match\":\"any\"}"
    AnySubjectRelationWire
  golden
    "SubjectRelationFilterWire/none"
    "{\"match\":\"none\"}"
    NoSubjectRelationWire
  golden
    "SubjectRelationFilterWire/exact"
    "{\"match\":\"exact\",\"relation\":\"member\"}"
    (ExactSubjectRelationWire "member")
  rejects
    "SubjectRelationFilterWire"
    (decode "{\"match\":\"whatever\"}" :: Maybe SubjectRelationFilterWire)

  -- An unconstrained field is an absent key, never a null one.
  golden
    "TupleFilterWire/broad"
    "{\"objectType\":\"space\"}"
    TupleFilterWire
      { objectType = "space",
        objectId = Nothing,
        relation = Nothing,
        subjectType = Nothing,
        subjectId = Nothing,
        subjectRelation = Nothing
      }
  -- The offboarding filter: anchored on the subject alone, every other field absent.
  golden
    "RelationshipFilterWire/subject"
    "{\"subjectType\":\"user\",\"subjectId\":\"alice\"}"
    (subjectFilterWire "user" "alice")
  golden
    "RelationshipFilterWire/full"
    "{\"objectType\":\"space\",\"objectId\":\"project-x\",\"relation\":\"member\",\"subjectType\":\"user\",\"subjectId\":\"alice\",\"subjectRelation\":{\"match\":\"none\"},\"caveatName\":\"business_hours\"}"
    ( relationshipFilterWire
        (Just "space")
        (Just "project-x")
        (Just "member")
        (Just "user")
        (Just "alice")
        (Just NoSubjectRelationWire)
        (Just "business_hours")
    )
  -- The empty object decodes: it is a well-formed filter that the *grammar* rejects,
  -- not a malformed body. The 400 comes from relationshipFilterFromWire, and says why.
  assertEqual
    "RelationshipFilterWire decodes an empty object as a wholly unconstrained filter"
    (Just emptyFilterWire)
    (decode "{}")

  golden
    "ReadRelationshipsRequestWire"
    "{\"consistency\":{\"mode\":\"fullyConsistent\"},\"filter\":{\"subjectType\":\"user\",\"subjectId\":\"alice\"},\"limit\":100,\"cursor\":null}"
    ReadRelationshipsRequestWire
      { consistency = FullyConsistentWire,
        filter = subjectFilterWire "user" "alice",
        limit = 100,
        cursor = Nothing
      }

  golden "RelationshipsStateWire/exhausted" "{\"status\":\"exhausted\"}" RelationshipsExhaustedWire
  golden
    "RelationshipsStateWire/hasMore"
    "{\"status\":\"hasMore\",\"cursor\":\"42\"}"
    (RelationshipsHasMoreWire "42")
  rejects
    "RelationshipsStateWire"
    (decode "{\"status\":\"truncated\",\"cursor\":\"42\"}" :: Maybe RelationshipsStateWire)

  golden
    "ReadRelationshipsResponseWire"
    "{\"relationships\":[{\"object\":{\"objectType\":\"space\",\"objectId\":\"project-x\"},\"relation\":\"viewer\",\"subject\":{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"alice\"},\"caveat\":null}],\"state\":{\"status\":\"exhausted\"},\"checkedAt\":\"tok\"}"
    ReadRelationshipsResponseWire
      { relationships = [viewerTuple],
        state = RelationshipsExhaustedWire,
        checkedAt = "tok"
      }

  golden
    "DeleteRelationshipsRequestWire"
    "{\"filter\":{\"subjectType\":\"user\",\"subjectId\":\"alice\"},\"dryRun\":true}"
    DeleteRelationshipsRequestWire {filter = subjectFilterWire "user" "alice", dryRun = True}
  -- dryRun has no default: the most destructive call in the API states its intent or
  -- does not decode.
  assertEqual
    "DeleteRelationshipsRequestWire refuses a body that omits dryRun"
    Nothing
    (decode "{\"filter\":{\"subjectType\":\"user\",\"subjectId\":\"alice\"}}" :: Maybe DeleteRelationshipsRequestWire)

  golden
    "DeleteRelationshipsResponseWire/dryRun"
    "{\"dryRun\":true,\"count\":3,\"token\":null}"
    DeleteRelationshipsResponseWire {dryRun = True, count = 3, token = Nothing}
  golden
    "DeleteRelationshipsResponseWire/deleted"
    "{\"dryRun\":false,\"count\":3,\"token\":\"en1.abc\"}"
    DeleteRelationshipsResponseWire {dryRun = False, count = 3, token = Just "en1.abc"}

  golden
    "WatchRequestWire/fromNow"
    "{\"cursor\":null,\"startToken\":null,\"filter\":null,\"limit\":100}"
    WatchRequestWire {cursor = Nothing, startToken = Nothing, filter = Nothing, limit = 100}
  golden
    "WatchRequestWire/resumed"
    "{\"cursor\":\"enwatch1.store.at.100:120:..\",\"startToken\":null,\"filter\":{\"subjectType\":\"user\",\"subjectId\":\"alice\"},\"limit\":50}"
    WatchRequestWire
      { cursor = Just "enwatch1.store.at.100:120:..",
        startToken = Nothing,
        filter = Just (subjectFilterWire "user" "alice"),
        limit = 50
      }
  -- Omitted is the same as null for every optional field: a first poll sends only a limit.
  assertEqual
    "WatchRequestWire decodes a body carrying only a limit"
    (Just WatchRequestWire {cursor = Nothing, startToken = Nothing, filter = Nothing, limit = 100})
    (decode "{\"limit\":100}")

  golden "ChangeKindWire/touch" "\"touch\"" TouchWire
  golden "ChangeKindWire/delete" "\"delete\"" DeleteWire
  rejects "ChangeKindWire" (decode "\"rewritten\"" :: Maybe ChangeKindWire)

  golden
    "TupleChangeWire"
    "{\"kind\":\"delete\",\"tuple\":{\"object\":{\"objectType\":\"space\",\"objectId\":\"project-x\"},\"relation\":\"viewer\",\"subject\":{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"alice\"},\"caveat\":null}}"
    TupleChangeWire {kind = DeleteWire, tuple = viewerTuple}

  -- checkedAt is last, as it is in every other read response.
  golden
    "WatchResponseWire"
    "{\"changes\":[{\"kind\":\"touch\",\"tuple\":{\"object\":{\"objectType\":\"space\",\"objectId\":\"project-x\"},\"relation\":\"viewer\",\"subject\":{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"alice\"},\"caveat\":null}}],\"cursor\":\"enwatch1.store.at.100:120:..\",\"checkedAt\":\"en1.abc\"}"
    WatchResponseWire
      { changes = [TupleChangeWire {kind = TouchWire, tuple = viewerTuple}],
        cursor = "enwatch1.store.at.100:120:..",
        checkedAt = "en1.abc"
      }
  golden
    "WatchResponseWire/caughtUp"
    "{\"changes\":[],\"cursor\":\"enwatch1.store.at.100:120:..\",\"checkedAt\":\"en1.abc\"}"
    WatchResponseWire {changes = [], cursor = "enwatch1.store.at.100:120:..", checkedAt = "en1.abc"}

  -- No `checkedAt`: this response describes the server's model, not a tuple-store snapshot.
  golden
    "SchemaInfoWire"
    "{\"source\":\"object user {}\\n\",\"hash\":\"fnv1a64:abc\",\"origin\":\"/etc/en/blog.en\",\"loadedAt\":\"2026-07-07T12:00:00Z\"}"
    SchemaInfoWire
      { source = "object user {}\n",
        hash = "fnv1a64:abc",
        origin = "/etc/en/blog.en",
        loadedAt = noon
      }

  golden
    "PreconditionWire/mustExist"
    "{\"kind\":\"mustExist\",\"filter\":{\"objectType\":\"space\",\"objectId\":\"project-x\",\"relation\":\"member\",\"subjectType\":\"user\",\"subjectId\":\"alice\",\"subjectRelation\":{\"match\":\"none\"}}}"
    (TupleMustExistWire (exactFilterWire "member" "alice"))
  roundTrip
    "PreconditionWire/mustNotExist"
    (TupleMustNotExistWire (exactFilterWire "member" "alice"))
  rejects
    "PreconditionWire"
    (decode "{\"kind\":\"mustProbablyExist\",\"filter\":{\"objectType\":\"space\"}}" :: Maybe PreconditionWire)

  -- A caveated tuple exercises the payload nesting the simpler goldens skip.
  roundTrip
    "TupleWire/caveated"
    TupleWire
      { object = projectX,
        relation = "viewer",
        subject = aliceSubject,
        caveat = Just businessHoursCaveat
      }
  roundTrip "CheckResponseWire/conditional" CheckResponseWire {decision = conditionalDecision, checkedAt = "tok"}
  where
    noon = UTCTime (fromGregorian 2026 7 7) (secondsToDiffTime (12 * 3600))
    projectX = ObjectRefWire {objectType = "space", objectId = "project-x"}
    aliceSubject = SubjectIdWire ObjectRefWire {objectType = "user", objectId = "alice"}
    emptyContext = CaveatContextWire Map.empty
    businessHoursPayload = CaveatPayloadWire (Map.fromList [("now", ValueTimestampWire noon)])
    businessHoursCaveat = TupleCaveatWire {name = "business_hours", payload = businessHoursPayload}
    viewerTuple =
      TupleWire
        { object = projectX,
          relation = "viewer",
          subject = aliceSubject,
          caveat = Nothing
        }
    exactFilterWire relation subjectId =
      TupleFilterWire
        { objectType = "space",
          objectId = Just "project-x",
          relation = Just relation,
          subjectType = Just "user",
          subjectId = Just subjectId,
          subjectRelation = Just NoSubjectRelationWire
        }
    conditionalDecision =
      ConditionalWire [CaveatObligationWire {caveat = "business_hours", missingContext = ["now"]}]
    viewPair = BatchCheckPairWire {subject = aliceSubject, permission = "view", object = projectX}
    allowedObject = LookupObjectWire {object = projectX, decision = AllowedWire}
    allowedSubject = LookupSubjectWire {subject = aliceSubject, decision = AllowedWire}

-- | The @checkedAt@ every handler in this suite reports.
--
-- 'runConsistencyStoreInMemory' resolves every read to 'testRevision' and mints the
-- token for it, so this is what a read response's token must be. Derived rather than
-- written out so it cannot drift from what the interpreter actually mints.
testCheckedAt :: Text
testCheckedAt =
  let ConsistencyToken token = inMemoryToken (DatastoreId "test") testRevision
   in token

-- | Assert the exact encoded bytes, then that the value survives a decode of them.
-- Exact bytes are meaningful because every 'ToJSON' instance defines 'toEncoding'
-- explicitly, which fixes field order.
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
  cache <- newCache CacheConfig {enabled = True, maxEntries = 100} :: IO (Cache SubproblemKey ResidualDecision)
  pure CheckCacheEnv {cacheDatastoreId = DatastoreId "test", cacheDecisions = cache}

-- | The handlers are imported directly from their vertical slices ('En.Tuple.Api',
-- 'En.Check.Api', 'En.Lookup.Api', 'En.Expand.Api', 'En.Schema.Api'), re-exported through
-- 'En.Servant.API'. Before the slice split this suite destructured @server env@ into a
-- 'Handlers' record to name each one; now each handler is a top-level export, so a test calls
-- it by name. @batchCheck@ is the one whose slice name differs from the old wrapper name
-- (@batchHandler@); tests call 'batchCheckHandler' directly.

-- | A watch feed over the in-memory store, standing in for 'En.Postgres.Watch.watch'.
--
-- The real orchestration parses revisions as PostgreSQL snapshots, and this store's one
-- revision is the text @test-revision@ — so the handler tests cannot call it, which is exactly
-- why 'Env.watchOperation' is a field. What is under test here is the handler: request
-- validation, the limit clamp, and the wire shape. The window's semantics are integration-
-- tested against a real PostgreSQL in @en-postgres/integration-test/Main.hs@.
--
-- The cursor is a constant. A drain loop is not being tested; a cursor being /present/ on
-- every response is.

-- | The schema every handler test is served under.
--
-- A constant, so 'Env.readActiveSchema' is @pure@ and no test can observe a reload. The
-- reload machinery itself belongs to @en-server@; what this suite pins is that a handler
-- takes its graph from the snapshot rather than from 'Env'.
testActiveSchema :: ActiveSchema
testActiveSchema =
  ActiveSchema
    { graph = kikanGraph,
      source = "object user {}\n",
      origin = "test-fixture",
      loadedAt = testLoadedAt
    }

testLoadedAt :: UTCTime
testLoadedAt =
  UTCTime (fromGregorian 2026 7 10) (secondsToDiffTime 0)

stubWatch :: WatchStart -> Maybe RelationshipFilter -> Int -> Eff TestEffects WatchBatch
stubWatch _start relationshipFilter limit = do
  revision <- headRevision
  checkedAt <- mintToken revision
  page <- readChanges revision revision relationshipFilter limit Nothing
  pure WatchBatch {changes = page.changes, cursor = "enwatch1.test.at.test-revision..", checkedAt}

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
    { subject = SubjectIdWire ObjectRefWire {objectType = "user", objectId = userId},
      permission = permission,
      object = ObjectRefWire {objectType = "space", objectId = objectId}
    }

objectToWire :: ObjectRef -> ObjectRefWire
objectToWire ObjectRef {objectType = ObjectType objectType, objectId} =
  ObjectRefWire {objectType, objectId}

-- | The @code@ of a handler's 400 response, if it produced one.
--
-- 'Nothing' covers every other outcome — success, a non-400 fault, or a thrown
-- 'ServerError' — so a test asserting @Just "…"@ pins both the status and the code.
clientErrorCodeOf :: Handler (EnResult a) -> IO (Maybe Text)
clientErrorCodeOf handler =
  runHandler handler <&> \case
    Right (EnClientError envelope) -> Just envelope.code
    _ -> Nothing

-- | The stable code of a 412, or 'Nothing' if the handler answered anything else.
preconditionCodeOf :: Handler (EnResult a) -> IO (Maybe Text)
preconditionCodeOf handler =
  runHandler handler <&> \case
    Right (EnPreconditionFailed envelope) -> Just envelope.code
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

-- | The handler neither threw nor returned a fault.
--
-- Weaker than 'assertEqual' on the payload, and used where the payload is a page whose
-- exact contents are not the property under test — but strictly stronger than checking
-- for 'Right', which an 'EnClientError' would also satisfy.
assertOk :: (Show err, Show value) => String -> Either err (EnResult value) -> IO ()
assertOk _ (Right (EnOk _)) = pure ()
assertOk label (Right fault) =
  fail (label <> "\nexpected EnOk, got: " <> show fault)
assertOk label (Left err) =
  fail (label <> "\nexpected Right, got Left: " <> show err)

-- | The deterministic issuer signing key from @en-biscuit/test/Main.hs@, in the
-- EP-55 @"\<id\>:\<64 hex\>"@ format 'parseSigningKeyText' consumes. A fixed key so
-- the test is reproducible; production uses a freshly generated one.
testSigningKey :: Text
testSigningKey = "1:a2c4ead323536b925f3488ee83e0888b79c2761405ca7c0c9a018c7c1905eecc"

-- | The HTTP status and stable @code@ of a thrown 'ServerError', or 'Nothing' if
-- the handler returned a value instead of throwing. @POST \/v1\/grants@ signals its
-- non-200 outcomes by throwing rather than through an 'EnResult', so this is how the
-- mint tests pin both the status and the code at once.
thrownProblem :: Either ServerError a -> Maybe (Int, Text)
thrownProblem = \case
  Left err -> do
    details <- decode err.errBody :: Maybe ProblemDetails
    pure (err.errHTTPCode, details.code)
  Right _ -> Nothing

-- | @POST \/v1\/grants@ over the wire, against the in-memory store.
--
-- Pins the endpoint contract without a live server: an 'Allowed' request mints a
-- token that 'verifyGrant' accepts for the same subject/operation/resource/audience
-- and whose recovered consistency token equals the response's @checkedAt@; a
-- 'Denied' request throws 403 and no token; a @ttlSeconds@ above the maximum and a
-- non-concrete subject are 400; and a server with no issuer configured
-- (@mint = Nothing@) throws 404. Milestone 3 adds the live end-to-end proof.
mintGrantTests :: Env TestEffects -> IO ()
mintGrantTests baseEnv = do
  (keyId, secret) <- either (fail . Text.unpack) pure (parseSigningKeyText testSigningKey)
  let public = toPublic secret
      keySet = singleKey keyId public
      mintEnv =
        baseEnv
          { mint =
              Just
                MintEnv
                  { issuerSecretKey = secret,
                    issuerKeyId = keyId,
                    defaultTtl = 300,
                    maxTtl = 3600
                  }
          }
      grantsFor e = mintGrantHandler e
      request =
        MintGrantRequestWire
          { consistency = MinimizeLatencyWire,
            context = CaveatContextWire Map.empty,
            subject = SubjectIdWire ObjectRefWire {objectType = "user", objectId = "alice"},
            permission = "view",
            object = ObjectRefWire {objectType = "space", objectId = "project-x"},
            audience = "document-service",
            ttlSeconds = Just 120,
            requestId = Just "req-mint-1"
          }

  -- Allowed -> 200 with a token that verifies locally.
  response <-
    runHandler (grantsFor mintEnv request) >>= \case
      Right r -> pure r
      Left err -> fail ("mint: expected 200, got a thrown error " <> show err)
  assertEqual "mint: checkedAt is the snapshot the check evaluated at" testCheckedAt response.checkedAt
  assertBool "mint: at least one revocation id" (not (null response.revocationIds))

  now <- getCurrentTime
  let verifyRequest =
        VerifyRequest
          { expectedSubject = SubjectId (ObjectRef (ObjectType "user") "alice"),
            expectedAudience = Audience "document-service",
            operation = RelationName "view",
            resource = ObjectRef (ObjectType "space") "project-x",
            serviceName = Audience "document-service",
            acceptedSchemaHashes = Set.singleton testActiveSchema.graph.hash,
            now = now,
            revoked = const (pure False),
            revokedBlockIds = const (pure False)
          }
  verifyGrant keySet (encodeUtf8 response.token) verifyRequest >>= \case
    Right grant -> do
      let ConsistencyToken recovered = grant.consistencyToken
      assertEqual
        "mint: the token verifies and its consistency token is the response's checkedAt"
        response.checkedAt
        recovered
    Left err -> fail ("mint: the minted token should verify locally, got " <> show err)

  -- Denied -> 403, no token.
  denied <-
    runHandler
      (grantsFor mintEnv request {subject = SubjectIdWire ObjectRefWire {objectType = "user", objectId = "bob"}})
  assertEqual
    "mint: a Denied decision is 403 decision_not_allowed"
    (Just (403, "decision_not_allowed"))
    (thrownProblem denied)

  -- ttlSeconds above the configured maximum -> 400 (rejected, not clamped).
  tooLong <- runHandler (grantsFor mintEnv request {ttlSeconds = Just 999999})
  assertEqual
    "mint: ttlSeconds above the maximum is 400 invalid_request"
    (Just (400, "invalid_request"))
    (thrownProblem tooLong)

  -- A non-concrete subject -> 400.
  nonConcrete <- runHandler (grantsFor mintEnv request {subject = SubjectWildcardWire "user"})
  assertEqual
    "mint: a non-concrete subject is 400 invalid_request"
    (Just (400, "invalid_request"))
    (thrownProblem nonConcrete)

  -- mint = Nothing -> 404, and every other endpoint still works.
  disabled <- runHandler (grantsFor baseEnv request)
  assertEqual
    "mint: a server with no issuer key answers 404 not_found"
    (Just (404, "not_found"))
    (thrownProblem disabled)
