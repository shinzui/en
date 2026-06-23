module Main (
    main,
) where

import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text

import En.Check (BatchPair (..), CaveatObligation (..), CheckDecision (..), check, checkMany)
import En.Conformance.Kikan
import En.Effect.ConsistencyStore (ConsistencyStore (..))
import En.Effect.TupleStore (
    PageState (..),
    StoreCursor (..),
    TuplePage (..),
    TupleRow (..),
    TupleRowId (..),
    TupleStore (..),
    UsersetQuery (..),
 )
import En.Error (EnError (..))
import En.Expand (ExpandCursor (..), ExpandLimit (..), ExpandNode (..), ExpandRequest (..), ExpandState (..), ExpandTree (..))
import En.Expand qualified as Expand
import En.Lookup (
    Deadline (..),
    LookupCursor (..),
    LookupCursorState (..),
    LookupLimit (..),
    LookupObject (..),
    LookupPage (..),
    LookupRequest (..),
    LookupState (..),
    decodeLookupCursor,
    encodeLookupCursor,
    noDeadline,
 )
import En.Lookup qualified as Lookup
import En.Reachability (
    EntryKind,
    EntryPoint (..),
    ReachabilityGraph (..),
    RelationRef (..),
    SubjectSelector (..),
    compile,
 )
import En.Reachability qualified as Reachability
import En.Revision (Consistency (..), Revision (..))
import En.Schema (
    AllowedSubject (..),
    CaveatCompare (..),
    CaveatDefinition (..),
    CaveatName (..),
    CaveatOperand (..),
    CaveatParameterName (..),
    CaveatParameterType (..),
    CaveatPredicate (..),
    CaveatSource (..),
    ObjectType (..),
    Relation (..),
    RelationName (..),
    Rewrite (..),
    Schema (..),
    schemaHash,
    validate,
 )
import En.Schema.Builder qualified as Schema
import En.Tuple (
    CaveatContext (..),
    CaveatPayload (..),
    CaveatValue (..),
    ObjectRef (..),
    Subject (..),
    Tuple (..),
    TupleCaveat (..),
 )

main :: IO ()
main = do
    let _ = sampleTuple
        _ = sampleUsersetQuery
        _ = sampleTuplePage
        _ = sampleDecision
        _ = sampleLookupRequest
        _ = sampleLookupPage
        _ = sampleExpandRequest
        _ = sampleExpandTree
        _ = sampleCaveatDefinition
    assertEqual "kikan-shaped fixture validates" (Right ()) (validate kikanSchema)
    assertEqual "builder schema equals manual schema" kikanSchemaManual kikanSchema
    assertEqual "builder schema hash matches manual schema hash" (schemaHash kikanSchemaManual) (schemaHash kikanSchema)
    assertEqual "builder anyOf constructs a non-empty union" (Union [This, ComputedUserset (RelationName "owner")]) (Schema.anyOf Schema.this [Schema.computed "owner"])
    assertEqual "builder allOf constructs a non-empty intersection" (Intersection [This, ComputedUserset (RelationName "owner")]) (Schema.allOf Schema.this [Schema.computed "owner"])
    graph <- either (fail . show) pure (compile kikanSchema)
    assertEqual "graph stores schema hash" (schemaHash kikanSchema) graph.hash
    assertEqual "schema hash is stable across map insertion order" (schemaHash kikanSchema) (schemaHash kikanSchemaReordered)
    assertBool "space view has a direct user entrypoint" (hasEntry (relationRef "space" "view") (SubjectSelector (ObjectType "user") Nothing False) Reachability.Direct False graph)
    assertBool "space view has a guest-org userset entrypoint" (hasEntry (relationRef "space" "view") (SubjectSelector (ObjectType "org") (Just (RelationName "member")) False) Reachability.Direct False graph)
    assertBool "space view has a recursive parent entrypoint" (hasEntry (relationRef "space" "view") (SubjectSelector (ObjectType "space") (Just (RelationName "view")) False) Reachability.Direct True graph)
    assertBool "space audit relation is conditional" (hasEntry (relationRef "space" "audit") (SubjectSelector (ObjectType "user") Nothing False) Reachability.Conditional False graph)
    assertBool "space member-minus-owner relation is conditional" (hasEntry (relationRef "space" "member_not_owner") (SubjectSelector (ObjectType "user") Nothing False) Reachability.Conditional False graph)
    assertValidationFails "This requires allowed subjects" (schemaWithRelation "space" "viewer" Set.empty This)
    assertValidationFails "ComputedUserset rejects unknown relation" (schemaWithRelation "space" "viewer" userSubject (ComputedUserset (RelationName "missing")))
    assertValidationFails "TupleToUserset rejects incompatible arrows" invalidTupleToUsersetSchema
    assertValidationFails "TupleToUserset rejects wildcard-only arrows" invalidWildcardTupleToUsersetSchema
    assertValidationFails "Union rejects empty branches" (schemaWithRelation "space" "viewer" userSubject (Union []))
    assertValidationFails "Intersection rejects empty branches" (schemaWithRelation "space" "viewer" userSubject (Intersection []))
    assertValidationFails "Exclusion validates both branches" (schemaWithRelation "space" "viewer" userSubject (Exclusion This (ComputedUserset (RelationName "missing"))))
    assertValidationFails "Caveated rejects unknown caveat" (schemaWithRelation "space" "viewer" userSubject (Caveated (CaveatName "missing") This))
    assertValidationFails "wildcard allowed subjects cannot be usersets" invalidWildcardUsersetSchema
    assertValidationFails "unproductive rewrite cycles are rejected" unproductiveCycleSchema
    assertEqual "owner can view a space" (Right Allowed) =<< check consistencyStore tupleStore graph MinimizeLatency requestContext (SubjectId user) (RelationName "view") space
    assertEqual "non-member cannot view a space" (Right Denied) =<< check consistencyStore tupleStore graph MinimizeLatency requestContext (SubjectId bob) (RelationName "view") space
    assertEqual "agency org member can view guest space" (Right Allowed) =<< check consistencyStore tupleStore graph MinimizeLatency requestContext (SubjectId agencyUser) (RelationName "view") guestSpace
    assertEqual "guest org view does not grant act" (Right Denied) =<< check consistencyStore tupleStore graph MinimizeLatency requestContext (SubjectId agencyUser) (RelationName "act") guestSpace
    assertEqual "userset subject grants member relation" (Right Allowed) =<< check consistencyStore tupleStore graph MinimizeLatency requestContext (SubjectId agencyUser) (RelationName "member") usersetMemberSpace
    assertEqual "parent recursion grants view" (Right Allowed) =<< check consistencyStore tupleStore graph MinimizeLatency requestContext (SubjectId user) (RelationName "view") childSpace
    assertEqual "intersection requires every branch" (Right Denied) =<< check consistencyStore tupleStore graph MinimizeLatency requestContext (SubjectId user) (RelationName "audit") space
    assertEqual "intersection allows owner plus member" (Right Allowed) =<< check consistencyStore tupleStore graph MinimizeLatency requestContext (SubjectId memberOwner) (RelationName "audit") auditedSpace
    assertEqual "exclusion allows member who is not owner" (Right Allowed) =<< check consistencyStore tupleStore graph MinimizeLatency requestContext (SubjectId memberOnly) (RelationName "member_not_owner") exclusionSpace
    assertEqual "exclusion rejects owner" (Right Denied) =<< check consistencyStore tupleStore graph MinimizeLatency requestContext (SubjectId memberOwner) (RelationName "member_not_owner") exclusionSpace
    let mixedBatch =
            [ BatchPair (SubjectId user) (RelationName "view") space
            , BatchPair (SubjectId bob) (RelationName "view") space
            , BatchPair (SubjectId user) (RelationName "audit") space
            , BatchPair (SubjectId memberOwner) (RelationName "member_not_owner") exclusionSpace
            ]
    assertEqual "batch agrees with single checks in input order" (Right [Allowed, Denied, Denied, Denied]) =<< checkMany consistencyStore tupleStore graph MinimizeLatency requestContext mixedBatch
    resolveCount <- newIORef 0
    assertEqual "batch with counted consistency still returns decisions" (Right [Allowed, Denied, Denied, Denied]) =<< checkMany (countingConsistencyStore resolveCount consistencyStore) tupleStore graph MinimizeLatency requestContext mixedBatch
    assertEqual "batch resolves consistency once" 1 =<< readIORef resolveCount
    let overlappingBatch =
            [ BatchPair (SubjectId user) (RelationName "view") space
            , BatchPair (SubjectId user) (RelationName "owner") space
            , BatchPair (SubjectId user) (RelationName "member") space
            ]
    batchReadCount <- newIORef 0
    assertEqual "overlapping batch returns decisions" (Right [Allowed, Allowed, Denied]) =<< checkMany consistencyStore (countingTupleStore batchReadCount tupleStore) graph MinimizeLatency requestContext overlappingBatch
    batchReads <- readIORef batchReadCount
    independentReadCount <- newIORef 0
    let independentStore = countingTupleStore independentReadCount tupleStore
    independentResults <-
        traverse
            ( \pair ->
                check consistencyStore independentStore graph MinimizeLatency requestContext pair.subject pair.permission pair.object
            )
            overlappingBatch
    assertEqual "independent overlapping checks return decisions" [Right Allowed, Right Allowed, Right Denied] independentResults
    independentReads <- readIORef independentReadCount
    assertBool "batch shares subproblem reads" (batchReads < independentReads)
    let badReadSpace = ObjectRef{objectType = ObjectType "space", objectId = "bad-read"}
        badReadBatch =
            [ BatchPair (SubjectId user) (RelationName "view") space
            , BatchPair (SubjectId user) (RelationName "view") badReadSpace
            , BatchPair (SubjectId bob) (RelationName "view") space
            ]
    assertEqual "batch fails closed per pair" (Right [Allowed, Denied, Denied]) =<< checkMany consistencyStore (erroringTupleStore badReadSpace tupleStore) graph MinimizeLatency requestContext badReadBatch
    assertEqual "delegation caveat allows matching autonomy and time" (Right Allowed) =<< check consistencyStore tupleStore graph MinimizeLatency requestContext (SubjectId user) (RelationName "view") intention
    assertEqual "delegation caveat denies higher autonomy" (Right Denied) =<< check consistencyStore tupleStore graph MinimizeLatency adminContext (SubjectId user) (RelationName "view") intention
    assertEqual "delegation caveat is conditional with missing context" (Right (Conditional [CaveatObligation{caveat = CaveatName "within_autonomy", missingContext = ["requested_autonomy"]}])) =<< check consistencyStore tupleStore graph MinimizeLatency missingAutonomyContext (SubjectId user) (RelationName "view") intention
    assertEqual "expired delegation caveat denies access" (Right Denied) =<< check consistencyStore tupleStore graph MinimizeLatency expiredContext (SubjectId user) (RelationName "view") intention
    minLevelGraph <- either (fail . show) pure (compile minLevelSchema)
    let minLevelStore = inMemoryTupleStore [minLevelTuple]
    assertEqual "generic integer caveat allows sufficient clearance" (Right Allowed) =<< check consistencyStore minLevelStore minLevelGraph MinimizeLatency minLevelAllowedContext (SubjectId user) (RelationName "view") minLevelDocument
    assertEqual "generic integer caveat denies insufficient clearance" (Right Denied) =<< check consistencyStore minLevelStore minLevelGraph MinimizeLatency minLevelDeniedContext (SubjectId user) (RelationName "view") minLevelDocument
    assertEqual "generic integer caveat reports missing context" (Right (Conditional [CaveatObligation{caveat = CaveatName "min_level", missingContext = ["clearance"]}])) =<< check consistencyStore minLevelStore minLevelGraph MinimizeLatency (CaveatContext Map.empty) (SubjectId user) (RelationName "view") minLevelDocument
    let cursorState = LookupCursorState{version = 1, revision = testRevision, lastObject = Just childSpace}
    assertEqual "lookup cursor codec round-trips" (Right cursorState) (decodeLookupCursor (encodeLookupCursor cursorState))
    publicGraph <- either (fail . show) pure (compile publicSchema)
    let publicStore = inMemoryTupleStore [publicTuple]
    assertBool "public view has a wildcard user entrypoint" (hasEntry (relationRef "space" "view") (SubjectSelector (ObjectType "user") Nothing True) Reachability.Direct False publicGraph)
    assertEqual "wildcard subject grants concrete users" (Right Allowed) =<< check consistencyStore publicStore publicGraph MinimizeLatency requestContext (SubjectId bob) (RelationName "view") publicSpace
    assertEqual "wildcard subject does not match userset subjects" (Right Denied) =<< check consistencyStore publicStore publicGraph MinimizeLatency requestContext (SubjectSet guestOrg (RelationName "member")) (RelationName "view") publicSpace
    assertEqual "lookup includes public wildcard rows for concrete users" (Right (lookupPage [allowed publicSpace] LookupExhausted)) =<< Lookup.lookup consistencyStore publicStore publicGraph MinimizeLatency (lookupRequest (SubjectId bob) (RelationName "view") (ObjectType "space") requestContext (LookupLimit 10) Nothing)
    publicExpansion <- Expand.expand consistencyStore publicStore publicGraph MinimizeLatency (expandRequest publicSpace (RelationName "view") requestContext (ExpandLimit 20) Nothing)
    assertBool "expand renders wildcard subjects" (treeHasSubject (SubjectWildcard (ObjectType "user")) publicExpansion)
    streamingGraph <- either (fail . show) pure (compile streamingSchema)
    let streamingStore = inMemoryTupleStore streamingTuples
        expectedFolders = allowed <$> sort folders
    streamedFolders <- collectAllLookupPages noDeadline consistencyStore streamingStore streamingGraph (lookupRequest (SubjectId paginator) (RelationName "viewer") (ObjectType "folder") requestContext (LookupLimit 500) Nothing)
    assertLookupObjects "streaming lookup returns every reachable folder across pages" expectedFolders streamedFolders
    assertLookupObjects "streaming lookup returns the same set with small pages" expectedFolders =<< collectAllLookupPages noDeadline consistencyStore streamingStore streamingGraph (lookupRequest (SubjectId paginator) (RelationName "viewer") (ObjectType "folder") requestContext (LookupLimit 100) Nothing)
    truncatedDeadlineRef <- newIORef 0
    truncatedPage <- Lookup.lookupWithDeadline (budgetedDeadline truncatedDeadlineRef) consistencyStore streamingStore streamingGraph MinimizeLatency (lookupRequest (SubjectId paginator) (RelationName "viewer") (ObjectType "folder") requestContext (LookupLimit 500) Nothing)
    truncatedCursor <- expectLookupTruncated "deadline-bounded lookup truncates with a cursor" truncatedPage
    resumedFolders <- collectAllLookupPages noDeadline consistencyStore streamingStore streamingGraph (lookupRequest (SubjectId paginator) (RelationName "viewer") (ObjectType "folder") requestContext (LookupLimit 500) (Just truncatedCursor))
    assertLookupObjects "deadline cursor resumes remaining lookup results" (drop 500 expectedFolders) resumedFolders
    crowdedExpansion <- Expand.expand consistencyStore (inMemoryTupleStore expandTuples) streamingGraph MinimizeLatency (expandRequest crowdedFolder (RelationName "viewer") requestContext (ExpandLimit 1500) Nothing)
    assertEqual "expand drains multi-page object rows before applying result cap" (Right (1000, ExpandTruncated (ExpandCursor "1000"))) (fmap (\tree -> (length tree.children, tree.state)) crowdedExpansion)
    assertEqual "recursive graph respects depth limit" (Left ResolutionLimitExceeded) =<< check consistencyStore recursiveTupleStore graph MinimizeLatency requestContext (SubjectId user) (RelationName "view") recursiveSpace
    assertEqual "lookup returns direct and recursive view spaces" (Right (lookupPage [allowed childSpace, allowed space] LookupExhausted)) =<< Lookup.lookup consistencyStore tupleStore graph MinimizeLatency (lookupRequest (SubjectId user) (RelationName "view") (ObjectType "space") requestContext (LookupLimit 10) Nothing)
    assertEqual "lookup follows userset subjects" (Right (lookupPage [allowed guestSpace, allowed sharedItem, allowed usersetMemberSpace] LookupExhausted)) =<< Lookup.lookup consistencyStore tupleStore graph MinimizeLatency (lookupRequest (SubjectId agencyUser) (RelationName "view") (ObjectType "space") requestContext (LookupLimit 10) Nothing)
    assertEqual "lookup confirms intersection candidates" (Right (lookupPage [allowed auditedSpace, allowed exclusionSpace] LookupExhausted)) =<< Lookup.lookup consistencyStore tupleStore graph MinimizeLatency (lookupRequest (SubjectId memberOwner) (RelationName "audit") (ObjectType "space") requestContext (LookupLimit 10) Nothing)
    assertEqual "lookup omits denied intersection candidates" (Right (lookupPage [] LookupExhausted)) =<< Lookup.lookup consistencyStore tupleStore graph MinimizeLatency (lookupRequest (SubjectId memberOnly) (RelationName "audit") (ObjectType "space") requestContext (LookupLimit 10) Nothing)
    assertEqual "lookup confirms exclusion candidates" (Right (lookupPage [allowed exclusionSpace] LookupExhausted)) =<< Lookup.lookup consistencyStore tupleStore graph MinimizeLatency (lookupRequest (SubjectId memberOnly) (RelationName "member_not_owner") (ObjectType "space") requestContext (LookupLimit 10) Nothing)
    assertEqual "lookup preserves caveat obligations" (Right (lookupPage [conditional intention [CaveatObligation{caveat = CaveatName "within_autonomy", missingContext = ["requested_autonomy"]}]] LookupExhausted)) =<< Lookup.lookup consistencyStore tupleStore graph MinimizeLatency (lookupRequest (SubjectId user) (RelationName "view") (ObjectType "intention") missingAutonomyContext (LookupLimit 10) Nothing)
    let childCursor = encodeLookupCursor LookupCursorState{version = 1, revision = testRevision, lastObject = Just childSpace}
    assertEqual "lookup paginates deterministically first page" (Right (lookupPage [allowed childSpace] (LookupHasMore childCursor))) =<< Lookup.lookup consistencyStore tupleStore graph MinimizeLatency (lookupRequest (SubjectId user) (RelationName "view") (ObjectType "space") requestContext (LookupLimit 1) Nothing)
    assertEqual "lookup paginates deterministically second page" (Right (lookupPage [allowed space] LookupExhausted)) =<< Lookup.lookup consistencyStore tupleStore graph MinimizeLatency (lookupRequest (SubjectId user) (RelationName "view") (ObjectType "space") requestContext (LookupLimit 1) (Just childCursor))
    spaceExpansion <- Expand.expand consistencyStore tupleStore graph MinimizeLatency (expandRequest space (RelationName "view") requestContext (ExpandLimit 20) Nothing)
    assertBool "expand includes direct owner subject" (treeHasSubject (SubjectId user) spaceExpansion)
    childExpansion <- Expand.expand consistencyStore tupleStore graph MinimizeLatency (expandRequest childSpace (RelationName "view") requestContext (ExpandLimit 20) Nothing)
    assertBool "expand includes parent userset" (treeHasUserset space (RelationName "view") childExpansion)
    usersetExpansion <- Expand.expand consistencyStore tupleStore graph MinimizeLatency (expandRequest usersetMemberSpace (RelationName "member") requestContext (ExpandLimit 20) Nothing)
    assertBool "expand expands userset subjects" (treeHasSubject (SubjectId agencyUser) usersetExpansion)
    intentionExpansion <- Expand.expand consistencyStore tupleStore graph MinimizeLatency (expandRequest intention (RelationName "view") requestContext (ExpandLimit 20) Nothing)
    assertBool "expand includes caveat markers" (treeHasCaveat (CaveatName "within_autonomy") intentionExpansion)
    assertEqual "expand paginates top-level children" (Right (ExpandHasMore (ExpandCursor "1"))) =<< fmap (fmap expandState) (Expand.expand consistencyStore tupleStore graph MinimizeLatency (expandRequest auditedSpace (RelationName "audit") requestContext (ExpandLimit 1) Nothing))
    pure ()

sampleTuple :: Tuple
sampleTuple =
    Tuple
        { object = intention
        , relation = RelationName "delegate"
        , subject = SubjectId user
        , caveat = Just autonomyCaveat
        }

sampleUsersetQuery :: UsersetQuery
sampleUsersetQuery =
    UsersetQuery
        { queryType = ObjectType "intention"
        , queryRelation = RelationName "delegate"
        , querySubjects = [SubjectId user]
        , queryLimit = 100
        , queryCursor = Just (StoreCursor "after-row-10")
        }

sampleTuplePage :: TuplePage
sampleTuplePage =
    TuplePage
        { rows =
            [ TupleRow
                { rowId = TupleRowId "tuple-1"
                , tuple = sampleTuple
                , createdAt = Revision "snapshot-created"
                , deletedAt = Nothing
                }
            ]
        , state = HasMore (StoreCursor "after-row-1")
        }

sampleDecision :: CheckDecision
sampleDecision =
    Conditional
        [ CaveatObligation
            { caveat = CaveatName "within_autonomy"
            , missingContext = ["requested_autonomy"]
            }
        ]

sampleLookupRequest :: LookupRequest
sampleLookupRequest =
    LookupRequest
        { subject = SubjectId user
        , permission = RelationName "view"
        , objectType = ObjectType "space"
        , context = requestContext
        , limit = LookupLimit 50
        , cursor = Nothing
        }

sampleLookupPage :: LookupPage
sampleLookupPage =
    LookupPage
        { objects = [allowed space]
        , state = LookupTruncated (LookupCursor "cursor")
        }

sampleExpandRequest :: ExpandRequest
sampleExpandRequest =
    ExpandRequest
        { object = space
        , permission = RelationName "view"
        , context = requestContext
        , limit = ExpandLimit 25
        , cursor = Nothing
        }

sampleExpandTree :: ExpandTree
sampleExpandTree =
    ExpandTree
        { root = space
        , permission = RelationName "view"
        , children = []
        , state = ExpandExhausted
        }

sampleCaveatDefinition :: CaveatDefinition
sampleCaveatDefinition =
    CaveatDefinition
        { name = CaveatName "within_autonomy"
        , parameters =
            Map.fromList
                [ (CaveatParameterName "requested_autonomy", ParameterEnum ["read", "act"])
                , (CaveatParameterName "autonomy", ParameterEnum ["read", "act", "admin"])
                , (CaveatParameterName "current_time", ParameterTimestamp)
                , (CaveatParameterName "until", ParameterTimestamp)
                ]
        , predicate =
            PredAnd
                [ PredCompare
                    CmpLe
                    (OperandParam FromContext (CaveatParameterName "requested_autonomy"))
                    (OperandParam FromPayload (CaveatParameterName "autonomy"))
                , PredCompare
                    CmpLe
                    (OperandParam FromContext (CaveatParameterName "current_time"))
                    (OperandParam FromPayload (CaveatParameterName "until"))
                ]
        }

lookupRequest :: Subject -> RelationName -> ObjectType -> CaveatContext -> LookupLimit -> Maybe LookupCursor -> LookupRequest
lookupRequest subject permission objectType context limit cursor =
    LookupRequest{subject, permission, objectType, context, limit, cursor}

lookupPage :: [LookupObject] -> LookupState -> LookupPage
lookupPage objects state =
    LookupPage{objects, state}

collectAllLookupPages ::
    Deadline IO ->
    ConsistencyStore IO ->
    TupleStore IO ->
    ReachabilityGraph ->
    LookupRequest ->
    IO [LookupObject]
collectAllLookupPages deadline cStore tStore graph request = do
    page <- Lookup.lookupWithDeadline deadline cStore tStore graph MinimizeLatency request
    case page of
        Left err -> fail ("lookup failed while collecting pages: " <> show err)
        Right LookupPage{objects, state} ->
            case state of
                LookupExhausted -> pure objects
                LookupHasMore cursor -> appendNext objects cursor
                LookupTruncated cursor -> appendNext objects cursor
  where
    appendNext objects cursor = do
        rest <- collectAllLookupPages deadline cStore tStore graph (requestWithCursor request cursor)
        pure (objects <> rest)

requestWithCursor :: LookupRequest -> LookupCursor -> LookupRequest
requestWithCursor request cursor =
    LookupRequest
        { subject = request.subject
        , permission = request.permission
        , objectType = request.objectType
        , context = request.context
        , limit = request.limit
        , cursor = Just cursor
        }

budgetedDeadline :: IORef Int -> Deadline IO
budgetedDeadline ref =
    Deadline $
        atomicModifyIORef'
            ref
            ( \remaining ->
                let hasBudget = remaining > 0
                 in (remaining - 1, hasBudget)
            )

expectLookupTruncated :: String -> Either EnError LookupPage -> IO LookupCursor
expectLookupTruncated label =
    \case
        Right LookupPage{state = LookupTruncated cursor} -> pure cursor
        other -> fail (label <> "\nexpected LookupTruncated, got: " <> show other)

expandRequest :: ObjectRef -> RelationName -> CaveatContext -> ExpandLimit -> Maybe ExpandCursor -> ExpandRequest
expandRequest object permission context limit cursor =
    ExpandRequest{object, permission, context, limit, cursor}

expandState :: ExpandTree -> ExpandState
expandState ExpandTree{state} =
    state

allowed :: ObjectRef -> LookupObject
allowed object =
    LookupObject{object, decision = Allowed}

conditional :: ObjectRef -> [CaveatObligation] -> LookupObject
conditional object obligations =
    LookupObject{object, decision = Conditional obligations}

treeHasSubject :: Subject -> Either EnError ExpandTree -> Bool
treeHasSubject subject =
    either (const False) (any (nodeHasSubject subject) . (.children))

nodeHasSubject :: Subject -> ExpandNode -> Bool
nodeHasSubject subject =
    \case
        ExpandSubject found _ -> found == subject
        ExpandUserset _ _ children -> any (nodeHasSubject subject) children
        ExpandCaveated _ children -> any (nodeHasSubject subject) children

treeHasUserset :: ObjectRef -> RelationName -> Either EnError ExpandTree -> Bool
treeHasUserset object relation =
    either (const False) (any (nodeHasUserset object relation) . (.children))

nodeHasUserset :: ObjectRef -> RelationName -> ExpandNode -> Bool
nodeHasUserset object relation =
    \case
        ExpandSubject _ _ -> False
        ExpandUserset foundObject foundRelation children ->
            (foundObject == object && foundRelation == relation)
                || any (nodeHasUserset object relation) children
        ExpandCaveated _ children -> any (nodeHasUserset object relation) children

treeHasCaveat :: CaveatName -> Either EnError ExpandTree -> Bool
treeHasCaveat caveat =
    either (const False) (any (nodeHasCaveat caveat) . (.children))

nodeHasCaveat :: CaveatName -> ExpandNode -> Bool
nodeHasCaveat caveat =
    \case
        ExpandSubject _ _ -> False
        ExpandUserset _ _ children -> any (nodeHasCaveat caveat) children
        ExpandCaveated found children ->
            found == caveat || any (nodeHasCaveat caveat) children

kikanSchemaManual :: Schema
kikanSchemaManual =
    Schema
        { objectTypes =
            Map.fromList
                [ (ObjectType "user", Map.empty)
                ,
                    ( ObjectType "org"
                    , Map.fromList
                        [ relationEntry "member" userSubject This
                        ]
                    )
                ,
                    ( ObjectType "visibility_class"
                    , Map.fromList
                        [ relationEntry "viewer" userSubject This
                        ]
                    )
                ,
                    ( ObjectType "space"
                    , Map.fromList
                        [ relationEntry "owner" userSubject This
                        , relationEntry "member" (userSubject <> orgMemberSubject) This
                        , relationEntry "guest_org" orgSubject This
                        , relationEntry "parent" spaceSubject This
                        , relationEntry "visibility_class" visibilityClassSubject This
                        , relationEntry
                            "view"
                            Set.empty
                            ( Union
                                [ ComputedUserset (RelationName "owner")
                                , ComputedUserset (RelationName "member")
                                , TupleToUserset (RelationName "guest_org") (RelationName "member")
                                , TupleToUserset (RelationName "parent") (RelationName "view")
                                , TupleToUserset (RelationName "visibility_class") (RelationName "viewer")
                                ]
                            )
                        , relationEntry
                            "act"
                            Set.empty
                            ( Union
                                [ ComputedUserset (RelationName "owner")
                                , ComputedUserset (RelationName "member")
                                ]
                            )
                        , relationEntry
                            "audit"
                            Set.empty
                            ( Intersection
                                [ ComputedUserset (RelationName "owner")
                                , ComputedUserset (RelationName "member")
                                ]
                            )
                        , relationEntry
                            "member_not_owner"
                            Set.empty
                            ( Exclusion
                                (ComputedUserset (RelationName "member"))
                                (ComputedUserset (RelationName "owner"))
                            )
                        ]
                    )
                ,
                    ( ObjectType "intention"
                    , Map.fromList
                        [ relationEntry "delegate" userSubject This
                        , relationEntry "view" Set.empty (ComputedUserset (RelationName "delegate"))
                        ]
                    )
                ]
        , caveats =
            Map.fromList
                [ (CaveatName "within_autonomy", sampleCaveatDefinition)
                ]
        }

kikanSchemaReordered :: Schema
kikanSchemaReordered =
    kikanSchema
        { objectTypes = Map.fromList (reverse (Map.toList kikanSchema.objectTypes))
        , caveats = Map.fromList (reverse (Map.toList kikanSchema.caveats))
        }

invalidTupleToUsersetSchema :: Schema
invalidTupleToUsersetSchema =
    Schema
        { objectTypes =
            Map.fromList
                [ (ObjectType "user", Map.empty)
                ,
                    ( ObjectType "space"
                    , Map.fromList
                        [ relationEntry "viewer" userSubject This
                        , relationEntry "bad" Set.empty (TupleToUserset (RelationName "viewer") (RelationName "member"))
                        ]
                    )
                ]
        , caveats = Map.empty
        }

invalidWildcardUsersetSchema :: Schema
invalidWildcardUsersetSchema =
    Schema
        { objectTypes =
            Map.fromList
                [ (ObjectType "user", Map.empty)
                ,
                    ( ObjectType "space"
                    , Map.fromList
                        [ relationEntry
                            "viewer"
                            (Set.singleton AllowedSubject{objectType = ObjectType "user", relation = Just (RelationName "member"), wildcard = True})
                            This
                        ]
                    )
                ]
        , caveats = Map.empty
        }

invalidWildcardTupleToUsersetSchema :: Schema
invalidWildcardTupleToUsersetSchema =
    Schema
        { objectTypes =
            Map.fromList
                [
                    ( ObjectType "user"
                    , Map.fromList
                        [ relationEntry "member" userSubject This
                        ]
                    )
                ,
                    ( ObjectType "space"
                    , Map.fromList
                        [ relationEntry
                            "viewer"
                            (Set.singleton AllowedSubject{objectType = ObjectType "user", relation = Nothing, wildcard = True})
                            This
                        , relationEntry "bad" Set.empty (TupleToUserset (RelationName "viewer") (RelationName "member"))
                        ]
                    )
                ]
        , caveats = Map.empty
        }

unproductiveCycleSchema :: Schema
unproductiveCycleSchema =
    Schema
        { objectTypes =
            Map.fromList
                [
                    ( ObjectType "space"
                    , Map.fromList
                        [ relationEntry "a" Set.empty (ComputedUserset (RelationName "b"))
                        , relationEntry "b" Set.empty (ComputedUserset (RelationName "a"))
                        ]
                    )
                ]
        , caveats = Map.empty
        }

schemaWithRelation :: Text -> Text -> Set.Set AllowedSubject -> Rewrite -> Schema
schemaWithRelation objectType relationName allowedSubjects rewrite =
    Schema
        { objectTypes =
            Map.fromList
                [ (ObjectType "user", Map.empty)
                ,
                    ( ObjectType objectType
                    , Map.fromList
                        [ relationEntry relationName allowedSubjects rewrite
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

orgSubject :: Set.Set AllowedSubject
orgSubject =
    Set.singleton AllowedSubject{objectType = ObjectType "org", relation = Nothing, wildcard = False}

orgMemberSubject :: Set.Set AllowedSubject
orgMemberSubject =
    Set.singleton AllowedSubject{objectType = ObjectType "org", relation = Just (RelationName "member"), wildcard = False}

spaceSubject :: Set.Set AllowedSubject
spaceSubject =
    Set.singleton AllowedSubject{objectType = ObjectType "space", relation = Nothing, wildcard = False}

visibilityClassSubject :: Set.Set AllowedSubject
visibilityClassSubject =
    Set.singleton AllowedSubject{objectType = ObjectType "visibility_class", relation = Nothing, wildcard = False}

relationRef :: Text -> Text -> RelationRef
relationRef objectType relation =
    RelationRef{objectType = ObjectType objectType, relation = RelationName relation}

hasEntry :: RelationRef -> SubjectSelector -> EntryKind -> Bool -> ReachabilityGraph -> Bool
hasEntry target source kind recursive graph =
    any
        ( \entry ->
            entry.source == source
                && entry.kind == kind
                && entry.recursive == recursive
        )
        (Map.findWithDefault [] target graph.entries)

tupleStore :: TupleStore IO
tupleStore =
    inMemoryTupleStore fixtureTuples

recursiveTupleStore :: TupleStore IO
recursiveTupleStore =
    inMemoryTupleStore
        [ Tuple
            { object = recursiveSpace
            , relation = RelationName "parent"
            , subject = SubjectId recursiveSpace
            , caveat = Nothing
            }
        ]

countingConsistencyStore :: IORef Int -> ConsistencyStore IO -> ConsistencyStore IO
countingConsistencyStore count store =
    store
        { resolveConsistency = \consistency -> do
            modifyIORef' count (+ 1)
            store.resolveConsistency consistency
        }

countingTupleStore :: IORef Int -> TupleStore IO -> TupleStore IO
countingTupleStore count store =
    store
        { readObjectRelation = \revision object relation limit cursor -> do
            modifyIORef' count (+ 1)
            store.readObjectRelation revision object relation limit cursor
        , readStartingWithUser = \revision query -> do
            modifyIORef' count (+ 1)
            store.readStartingWithUser revision query
        }

erroringTupleStore :: ObjectRef -> TupleStore IO -> TupleStore IO
erroringTupleStore badObject store =
    store
        { readObjectRelation = \revision object relation limit cursor ->
            if object == badObject
                then pure TuplePage{rows = [], state = HasMore (StoreCursor "injected-error")}
                else store.readObjectRelation revision object relation limit cursor
        }

minLevelSchema :: Schema
minLevelSchema =
    Schema.buildWithCaveats
        [ Schema.caveatWith
            "min_level"
            [ Schema.parameter "clearance" ParameterInteger
            , Schema.parameter "level" ParameterInteger
            ]
            (Schema.cmpGe (Schema.ctxParam "clearance") (Schema.payloadParam "level"))
        ]
        [ Schema.object "user" []
        , Schema.object
            "document"
            [ Schema.relation "viewer" [Schema.subject "user"] Schema.this
            , Schema.permission "view" (Schema.computed "viewer")
            ]
        ]

minLevelTuple :: Tuple
minLevelTuple =
    Tuple
        { object = minLevelDocument
        , relation = RelationName "viewer"
        , subject = SubjectId user
        , caveat =
            Just
                TupleCaveat
                    { name = CaveatName "min_level"
                    , payload = CaveatPayload (Map.fromList [("level", ValueInteger 3)])
                    }
        }

minLevelAllowedContext :: CaveatContext
minLevelAllowedContext =
    CaveatContext (Map.fromList [("clearance", ValueInteger 5)])

minLevelDeniedContext :: CaveatContext
minLevelDeniedContext =
    CaveatContext (Map.fromList [("clearance", ValueInteger 2)])

minLevelDocument :: ObjectRef
minLevelDocument =
    ObjectRef
        { objectType = ObjectType "document"
        , objectId = "classified"
        }

publicSchema :: Schema
publicSchema =
    Schema.build
        [ Schema.object "user" []
        , Schema.object
            "org"
            [Schema.relation "member" [Schema.subject "user"] Schema.this]
        , Schema.object
            "space"
            [ Schema.relation "viewer" [Schema.wildcardSubject "user"] Schema.this
            , Schema.permission "view" (Schema.computed "viewer")
            ]
        ]

publicTuple :: Tuple
publicTuple =
    Tuple
        { object = publicSpace
        , relation = RelationName "viewer"
        , subject = SubjectWildcard (ObjectType "user")
        , caveat = Nothing
        }

publicSpace :: ObjectRef
publicSpace =
    ObjectRef
        { objectType = ObjectType "space"
        , objectId = "public"
        }

streamingSchema :: Schema
streamingSchema =
    Schema.build
        [ Schema.object "user" []
        , Schema.object
            "folder"
            [Schema.relation "viewer" [Schema.subject "user"] Schema.this]
        ]

streamingTuples :: [Tuple]
streamingTuples =
    [ Tuple
        { object = folder
        , relation = RelationName "viewer"
        , subject = SubjectId paginator
        , caveat = Nothing
        }
    | folder <- folders
    ]

folders :: [ObjectRef]
folders =
    [ ObjectRef
        { objectType = ObjectType "folder"
        , objectId = "folder-" <> showText index
        }
    | index <- [1 :: Int .. 1200]
    ]

paginator :: ObjectRef
paginator =
    ObjectRef
        { objectType = ObjectType "user"
        , objectId = "paginator"
        }

expandTuples :: [Tuple]
expandTuples =
    [ Tuple
        { object = crowdedFolder
        , relation = RelationName "viewer"
        , subject =
            SubjectId
                ObjectRef
                    { objectType = ObjectType "user"
                    , objectId = "expand-user-" <> showText index
                    }
        , caveat = Nothing
        }
    | index <- [1 :: Int .. 1200]
    ]

crowdedFolder :: ObjectRef
crowdedFolder =
    ObjectRef
        { objectType = ObjectType "folder"
        , objectId = "crowded"
        }

showText :: (Show a) => a -> Text
showText =
    Text.pack . show

assertValidationFails :: String -> Schema -> IO ()
assertValidationFails label schema =
    case validate schema of
        Left _ -> pure ()
        Right () -> fail (label <> "\nexpected validation failure")

assertBool :: String -> Bool -> IO ()
assertBool label actual
    | actual = pure ()
    | otherwise = fail (label <> "\nexpected True\nactual:   False")

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

assertLookupObjects :: String -> [LookupObject] -> [LookupObject] -> IO ()
assertLookupObjects label expected actual
    | expected == actual = pure ()
    | otherwise =
        fail $
            label
                <> "\nexpected count: "
                <> show (length expected)
                <> "\nactual count:   "
                <> show (length actual)
                <> "\nfirst mismatch: "
                <> show (firstMismatch expected actual)
  where
    firstMismatch [] [] = Nothing
    firstMismatch [] (found : _) = Just (Nothing, Just found)
    firstMismatch (wanted : _) [] = Just (Just wanted, Nothing)
    firstMismatch (wanted : wantRest) (found : foundRest)
        | wanted == found = firstMismatch wantRest foundRest
        | otherwise = Just (Just wanted, Just found)
