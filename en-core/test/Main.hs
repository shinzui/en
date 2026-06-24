{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}

module Main (
    main,
) where

import Data.Either (isLeft, isRight)
import Data.Foldable (traverse_)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (Eff, IOE, liftIO, runEff)
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, runErrorNoCallStack)

import En.Cache (
    Cache,
    CacheConfig (..),
    CacheStats (..),
    DecisionKey (..),
    SubproblemKey,
    TupleReadKey (..),
    cacheStats,
    insertCache,
    lookupCache,
    newCache,
 )
import En.Check (BatchPair (..), CaveatObligation (..), CheckCacheEnv (..), CheckDecision (..))
import En.Check qualified as Check
import En.Conformance.Kikan
import En.Effect.CachedTupleStore (cachedTupleStore)
import En.Effect.ConsistencyStore (ConsistencyStore (..), ResolvedConsistency (..), TokenMetadata (TokenMetadata))
import En.Effect.TupleStore (
    PageState (..),
    StoreCursor (..),
    TuplePage (..),
    TupleRow (..),
    TupleRowId (..),
    TupleStore (..),
    UsersetQuery (..),
    headRevision,
    optimizedRevision,
    readObjectRelation,
    readStartingWithUser,
    writeTuples,
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
    compileSchema,
 )
import En.Reachability qualified as Reachability
import En.Revision (Consistency (..), ConsistencyToken (..), DatastoreId (..), Revision (..), SchemaHash (..))
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
    ValidSchema,
    schemaHash,
    unValidSchema,
    validate,
    validateSchema,
 )
import En.Schema.Builder qualified as Schema
import En.Schema.TH (mkValidSchema)
import En.Tuple (
    CaveatContext (..),
    CaveatPayload (..),
    CaveatValue (..),
    ObjectRef (..),
    Subject (..),
    Tuple (..),
    TupleCaveat (..),
 )

validatedKikanTH :: ValidSchema
validatedKikanTH =
    $$(mkValidSchema kikanSchema)

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
    testCacheOperations
    testCachedTupleStore
    validKikan <- either (fail . show) pure (validateSchema kikanSchema)
    validKikanManual <- either (fail . show) pure (validateSchema kikanSchemaManual)
    validKikanReordered <- either (fail . show) pure (validateSchema kikanSchemaReordered)
    assertEqual "kikan-shaped fixture validates" (Right ()) (validate kikanSchema)
    assertEqual "builder schema equals manual schema" kikanSchemaManual kikanSchema
    assertEqual "builder schema hash matches manual schema hash" (schemaHash validKikanManual) (schemaHash validKikan)
    assertEqual "compile-time validated schema equals builder fixture" kikanSchema (unValidSchema validatedKikanTH)
    assertBool "validateSchema produces evidence for a valid schema" (isRight (validateSchema kikanSchema))
    assertBool "validateSchema rejects an invalid schema (no evidence)" (isLeft (validateSchema unproductiveCycleSchema))
    assertEqual "builder anyOf constructs a non-empty union" (Union [This, ComputedUserset (RelationName "owner")]) (Schema.anyOf Schema.this [Schema.computed "owner"])
    assertEqual "builder allOf constructs a non-empty intersection" (Intersection [This, ComputedUserset (RelationName "owner")]) (Schema.allOf Schema.this [Schema.computed "owner"])
    let graph = compile validKikan
    assertEqual "compileSchema round-trips identically to compile . validateSchema" (Right graph) (compileSchema kikanSchema)
    testDecisionCache graph
    assertEqual "graph stores schema hash" (schemaHash validKikan) graph.hash
    assertEqual "schema hash is stable across map insertion order" (schemaHash validKikan) (schemaHash validKikanReordered)
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
    assertLeftEq
        "duplicate relation is reported"
        (SchemaViolation "duplicate relation declared: space#owner")
        ( Schema.object
            "space"
            [ Schema.relation "owner" [Schema.subject "user"] Schema.this
            , Schema.relation "owner" [Schema.subject "user"] Schema.this
            ]
        )
    assertLeftEq
        "duplicate object type is reported"
        (SchemaViolation "duplicate object type declared: space")
        ( do
            spaceA <- Schema.object "space" [Schema.relation "owner" [Schema.subject "user"] Schema.this]
            spaceB <- Schema.object "space" [Schema.relation "member" [Schema.subject "user"] Schema.this]
            userObject <- Schema.object "user" []
            Schema.build [userObject, spaceA, spaceB]
        )
    assertLeftEq
        "duplicate caveat is reported"
        (SchemaViolation "duplicate caveat declared: within_window")
        ( do
            userObject <- Schema.object "user" []
            firstCaveat <- Schema.caveat "within_window" [Schema.parameter "until" ParameterTimestamp]
            secondCaveat <- Schema.caveat "within_window" [Schema.parameter "from" ParameterTimestamp]
            Schema.buildWithCaveats [firstCaveat, secondCaveat] [userObject]
        )
    assertLeftEq
        "duplicate caveat parameter is reported"
        (SchemaViolation "duplicate caveat parameter declared: within_window.until")
        ( Schema.caveat
            "within_window"
            [ Schema.parameter "until" ParameterTimestamp
            , Schema.parameter "until" ParameterTimestamp
            ]
        )
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
    let independentStore :: TupleInterpreter
        independentStore = countingTupleStore independentReadCount tupleStore
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
    minLevelGraph <- either (fail . show) pure (compileSchema minLevelSchema)
    let minLevelStore = runTupleStoreInMemory [minLevelTuple]
    assertEqual "generic integer caveat allows sufficient clearance" (Right Allowed) =<< check consistencyStore minLevelStore minLevelGraph MinimizeLatency minLevelAllowedContext (SubjectId user) (RelationName "view") minLevelDocument
    assertEqual "generic integer caveat denies insufficient clearance" (Right Denied) =<< check consistencyStore minLevelStore minLevelGraph MinimizeLatency minLevelDeniedContext (SubjectId user) (RelationName "view") minLevelDocument
    assertEqual "generic integer caveat reports missing context" (Right (Conditional [CaveatObligation{caveat = CaveatName "min_level", missingContext = ["clearance"]}])) =<< check consistencyStore minLevelStore minLevelGraph MinimizeLatency (CaveatContext Map.empty) (SubjectId user) (RelationName "view") minLevelDocument
    let cursorState = LookupCursorState{version = 1, revision = testRevision, lastObject = Just childSpace}
    assertEqual "lookup cursor codec round-trips" (Right cursorState) (decodeLookupCursor (encodeLookupCursor cursorState))
    publicGraph <- either (fail . show) pure (compileSchema publicSchema)
    let publicStore = runTupleStoreInMemory [publicTuple]
    assertBool "public view has a wildcard user entrypoint" (hasEntry (relationRef "space" "view") (SubjectSelector (ObjectType "user") Nothing True) Reachability.Direct False publicGraph)
    assertEqual "wildcard subject grants concrete users" (Right Allowed) =<< check consistencyStore publicStore publicGraph MinimizeLatency requestContext (SubjectId bob) (RelationName "view") publicSpace
    assertEqual "wildcard subject does not match userset subjects" (Right Denied) =<< check consistencyStore publicStore publicGraph MinimizeLatency requestContext (SubjectSet guestOrg (RelationName "member")) (RelationName "view") publicSpace
    assertEqual "lookup includes public wildcard rows for concrete users" (Right (lookupPage [allowed publicSpace] LookupExhausted)) =<< lookupEngine noDeadline consistencyStore publicStore publicGraph MinimizeLatency (lookupRequest (SubjectId bob) (RelationName "view") (ObjectType "space") requestContext (LookupLimit 10) Nothing)
    publicExpansion <- expandEngine consistencyStore publicStore publicGraph MinimizeLatency (expandRequest publicSpace (RelationName "view") requestContext (ExpandLimit 20) Nothing)
    assertBool "expand renders wildcard subjects" (treeHasSubject (SubjectWildcard (ObjectType "user")) publicExpansion)
    streamingGraph <- either (fail . show) pure (compileSchema streamingSchema)
    let streamingStore = runTupleStoreInMemory streamingTuples
        expectedFolders = allowed <$> sort folders
    streamedFolders <- collectAllLookupPages noDeadline consistencyStore streamingStore streamingGraph (lookupRequest (SubjectId paginator) (RelationName "viewer") (ObjectType "folder") requestContext (LookupLimit 500) Nothing)
    assertLookupObjects "streaming lookup returns every reachable folder across pages" expectedFolders streamedFolders
    assertLookupObjects "streaming lookup returns the same set with small pages" expectedFolders =<< collectAllLookupPages noDeadline consistencyStore streamingStore streamingGraph (lookupRequest (SubjectId paginator) (RelationName "viewer") (ObjectType "folder") requestContext (LookupLimit 100) Nothing)
    truncatedDeadlineRef <- newIORef 0
    truncatedPage <- lookupEngine (budgetedDeadline truncatedDeadlineRef) consistencyStore streamingStore streamingGraph MinimizeLatency (lookupRequest (SubjectId paginator) (RelationName "viewer") (ObjectType "folder") requestContext (LookupLimit 500) Nothing)
    truncatedCursor <- expectLookupTruncated "deadline-bounded lookup truncates with a cursor" truncatedPage
    resumedFolders <- collectAllLookupPages noDeadline consistencyStore streamingStore streamingGraph (lookupRequest (SubjectId paginator) (RelationName "viewer") (ObjectType "folder") requestContext (LookupLimit 500) (Just truncatedCursor))
    assertLookupObjects "deadline cursor resumes remaining lookup results" (drop 500 expectedFolders) resumedFolders
    crowdedExpansion <- expandEngine consistencyStore (runTupleStoreInMemory expandTuples) streamingGraph MinimizeLatency (expandRequest crowdedFolder (RelationName "viewer") requestContext (ExpandLimit 1500) Nothing)
    assertEqual "expand drains multi-page object rows before applying result cap" (Right (1000, ExpandTruncated (ExpandCursor "1000"))) (fmap (\tree -> (length tree.children, tree.state)) crowdedExpansion)
    assertEqual "recursive graph respects depth limit" (Left ResolutionLimitExceeded) =<< check consistencyStore recursiveTupleStore graph MinimizeLatency requestContext (SubjectId user) (RelationName "view") recursiveSpace
    assertEqual "lookup returns direct and recursive view spaces" (Right (lookupPage [allowed childSpace, allowed space] LookupExhausted)) =<< lookupEngine noDeadline consistencyStore tupleStore graph MinimizeLatency (lookupRequest (SubjectId user) (RelationName "view") (ObjectType "space") requestContext (LookupLimit 10) Nothing)
    assertEqual "lookup follows userset subjects" (Right (lookupPage [allowed guestSpace, allowed sharedItem, allowed usersetMemberSpace] LookupExhausted)) =<< lookupEngine noDeadline consistencyStore tupleStore graph MinimizeLatency (lookupRequest (SubjectId agencyUser) (RelationName "view") (ObjectType "space") requestContext (LookupLimit 10) Nothing)
    assertEqual "lookup confirms intersection candidates" (Right (lookupPage [allowed auditedSpace, allowed exclusionSpace] LookupExhausted)) =<< lookupEngine noDeadline consistencyStore tupleStore graph MinimizeLatency (lookupRequest (SubjectId memberOwner) (RelationName "audit") (ObjectType "space") requestContext (LookupLimit 10) Nothing)
    assertEqual "lookup omits denied intersection candidates" (Right (lookupPage [] LookupExhausted)) =<< lookupEngine noDeadline consistencyStore tupleStore graph MinimizeLatency (lookupRequest (SubjectId memberOnly) (RelationName "audit") (ObjectType "space") requestContext (LookupLimit 10) Nothing)
    assertEqual "lookup confirms exclusion candidates" (Right (lookupPage [allowed exclusionSpace] LookupExhausted)) =<< lookupEngine noDeadline consistencyStore tupleStore graph MinimizeLatency (lookupRequest (SubjectId memberOnly) (RelationName "member_not_owner") (ObjectType "space") requestContext (LookupLimit 10) Nothing)
    assertEqual "lookup preserves caveat obligations" (Right (lookupPage [conditional intention [CaveatObligation{caveat = CaveatName "within_autonomy", missingContext = ["requested_autonomy"]}]] LookupExhausted)) =<< lookupEngine noDeadline consistencyStore tupleStore graph MinimizeLatency (lookupRequest (SubjectId user) (RelationName "view") (ObjectType "intention") missingAutonomyContext (LookupLimit 10) Nothing)
    let childCursor = encodeLookupCursor LookupCursorState{version = 1, revision = testRevision, lastObject = Just childSpace}
    assertEqual "lookup paginates deterministically first page" (Right (lookupPage [allowed childSpace] (LookupHasMore childCursor))) =<< lookupEngine noDeadline consistencyStore tupleStore graph MinimizeLatency (lookupRequest (SubjectId user) (RelationName "view") (ObjectType "space") requestContext (LookupLimit 1) Nothing)
    assertEqual "lookup paginates deterministically second page" (Right (lookupPage [allowed space] LookupExhausted)) =<< lookupEngine noDeadline consistencyStore tupleStore graph MinimizeLatency (lookupRequest (SubjectId user) (RelationName "view") (ObjectType "space") requestContext (LookupLimit 1) (Just childCursor))
    spaceExpansion <- expandEngine consistencyStore tupleStore graph MinimizeLatency (expandRequest space (RelationName "view") requestContext (ExpandLimit 20) Nothing)
    assertBool "expand includes direct owner subject" (treeHasSubject (SubjectId user) spaceExpansion)
    childExpansion <- expandEngine consistencyStore tupleStore graph MinimizeLatency (expandRequest childSpace (RelationName "view") requestContext (ExpandLimit 20) Nothing)
    assertBool "expand includes parent userset" (treeHasUserset space (RelationName "view") childExpansion)
    usersetExpansion <- expandEngine consistencyStore tupleStore graph MinimizeLatency (expandRequest usersetMemberSpace (RelationName "member") requestContext (ExpandLimit 20) Nothing)
    assertBool "expand expands userset subjects" (treeHasSubject (SubjectId agencyUser) usersetExpansion)
    intentionExpansion <- expandEngine consistencyStore tupleStore graph MinimizeLatency (expandRequest intention (RelationName "view") requestContext (ExpandLimit 20) Nothing)
    assertBool "expand includes caveat markers" (treeHasCaveat (CaveatName "within_autonomy") intentionExpansion)
    assertEqual "expand paginates top-level children" (Right (ExpandHasMore (ExpandCursor "1"))) =<< fmap (fmap expandState) (expandEngine consistencyStore tupleStore graph MinimizeLatency (expandRequest auditedSpace (RelationName "audit") requestContext (ExpandLimit 1) Nothing))
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

testCacheOperations :: IO ()
testCacheOperations = do
    cache <- newCache CacheConfig{enabled = True, maxEntries = 2} :: IO (Cache Text Int)
    assertEqual "cache miss returns Nothing" Nothing =<< lookupCache cache "missing"
    insertCache cache "a" 1
    assertEqual "cache hit returns inserted value" (Just 1) =<< lookupCache cache "a"
    insertCache cache "b" 2
    insertCache cache "c" 3
    assertEqual "bounded cache evicts oldest entry" Nothing =<< lookupCache cache "a"
    assertEqual
        "cache stats count hits, misses, inserts, and evictions"
        CacheStats{hits = 1, misses = 2, inserts = 3, evictions = 1}
        =<< cacheStats cache

    disabledCache <- newCache CacheConfig{enabled = False, maxEntries = 2} :: IO (Cache Text Int)
    insertCache disabledCache "a" 1
    assertEqual "disabled cache always misses" Nothing =<< lookupCache disabledCache "a"
    assertEqual
        "disabled cache records misses but not inserts"
        CacheStats{hits = 0, misses = 1, inserts = 0, evictions = 0}
        =<< cacheStats disabledCache

    decisionCache <- newCache CacheConfig{enabled = True, maxEntries = 10} :: IO (Cache DecisionKey Text)
    let baseKey = sampleDecisionKey
    insertCache decisionCache baseKey "cached"
    assertEqual "decision cache hits identical key" (Just "cached") =<< lookupCache decisionCache baseKey
    assertEqual "decision key separates schema hash" Nothing =<< lookupCache decisionCache (sampleDecisionKeyWith (SchemaHash "schema:other") testRevision requestContext)
    assertEqual "decision key separates revision" Nothing =<< lookupCache decisionCache (sampleDecisionKeyWith (SchemaHash "schema:kikan") (Revision "revision:other") requestContext)
    assertEqual "decision key separates caveat context" Nothing =<< lookupCache decisionCache (sampleDecisionKeyWith (SchemaHash "schema:kikan") testRevision adminContext)

    let objectKey = ObjectRelationReadKey (Revision "r1") space (RelationName "view") 10 Nothing
    assertBool "tuple read key separates cursor" (objectKey /= ObjectRelationReadKey (Revision "r1") space (RelationName "view") 10 (Just (StoreCursor "after")))
    assertBool "tuple read key separates read shape" (objectKey /= StartingWithUserReadKey (Revision "r1") sampleUsersetQuery)

sampleDecisionKey :: DecisionKey
sampleDecisionKey =
    sampleDecisionKeyWith (SchemaHash "schema:kikan") testRevision requestContext

sampleDecisionKeyWith :: SchemaHash -> Revision -> CaveatContext -> DecisionKey
sampleDecisionKeyWith keySchemaHash keyRevision keyContext =
    DecisionKey
        { datastoreId = DatastoreId "primary"
        , schemaHash = keySchemaHash
        , revision = keyRevision
        , subject = SubjectId user
        , permission = RelationName "view"
        , object = space
        , context = keyContext
        }

testCachedTupleStore :: IO ()
testCachedTupleStore = do
    readCount <- newIORef 0
    cache <- newCache CacheConfig{enabled = True, maxEntries = 10}
    result <-
        runEff
            ( runErrorNoCallStack
                ( interpretFixtureTupleStore (Just readCount) Nothing fixtureTuples
                    . cachedTupleStore cache
                    $ do
                        firstObjectRead <- readObjectRelation (Revision "r1") space (RelationName "view") 10 Nothing
                        secondObjectRead <- readObjectRelation (Revision "r1") space (RelationName "view") 10 Nothing
                        otherRevisionRead <- readObjectRelation (Revision "r2") space (RelationName "view") 10 Nothing
                        otherLimitRead <- readObjectRelation (Revision "r1") space (RelationName "view") 1 Nothing
                        firstUsersetRead <- readStartingWithUser (Revision "r1") sampleUsersetQuery
                        secondUsersetRead <- readStartingWithUser (Revision "r1") sampleUsersetQuery
                        writeToken <- writeTuples []
                        headRev <- headRevision
                        optimizedRev <- optimizedRevision
                        pure
                            ( firstObjectRead == secondObjectRead
                            , otherRevisionRead
                            , otherLimitRead
                            , firstUsersetRead == secondUsersetRead
                            , writeToken
                            , headRev
                            , optimizedRev
                            )
                )
            )
    assertEqual
        "cached tuple store returns cached pages and forwards non-read operations"
        (Right (True, sampleObjectPage 10 Nothing, sampleObjectPage 1 Nothing, True, ConsistencyToken "in-memory-write", testRevision, testRevision))
        result
    assertEqual "cached tuple store reads underlying store only on misses" 4 =<< readIORef readCount

    disabledReadCount <- newIORef 0
    disabledCache <- newCache CacheConfig{enabled = False, maxEntries = 10}
    disabledResult <-
        runEff
            ( runErrorNoCallStack
                ( interpretFixtureTupleStore (Just disabledReadCount) Nothing fixtureTuples
                    . cachedTupleStore disabledCache
                    $ do
                        firstObjectRead <- readObjectRelation (Revision "r1") space (RelationName "view") 10 Nothing
                        secondObjectRead <- readObjectRelation (Revision "r1") space (RelationName "view") 10 Nothing
                        pure (firstObjectRead == secondObjectRead)
                )
            )
    assertEqual "disabled tuple read cache preserves results" (Right True) disabledResult
    assertEqual "disabled tuple read cache does not suppress reads" 2 =<< readIORef disabledReadCount

sampleObjectPage :: Int -> Maybe StoreCursor -> TuplePage
sampleObjectPage limit cursor =
    pageTuples limit cursor [tuple | tuple <- fixtureTuples, tuple.object == space, tuple.relation == RelationName "view"]

testDecisionCache :: ReachabilityGraph -> IO ()
testDecisionCache graph = do
    allowedReadCount <- newIORef 0
    allowedEnv <- newCheckCacheEnv
    assertEqual "cached allowed check returns Allowed first" (Right Allowed) =<< checkCachedEngine consistencyStore (countingTupleStore allowedReadCount tupleStore) allowedEnv graph MinimizeLatency requestContext (SubjectId user) (RelationName "view") space
    allowedReadsAfterFirst <- readIORef allowedReadCount
    assertBool "cached allowed check reads on first miss" (allowedReadsAfterFirst > 0)
    assertEqual "cached allowed check returns Allowed second" (Right Allowed) =<< checkCachedEngine consistencyStore (countingTupleStore allowedReadCount tupleStore) allowedEnv graph MinimizeLatency requestContext (SubjectId user) (RelationName "view") space
    assertEqual "cached allowed check suppresses second read" allowedReadsAfterFirst =<< readIORef allowedReadCount

    deniedReadCount <- newIORef 0
    deniedEnv <- newCheckCacheEnv
    assertEqual "cached denied check returns Denied first" (Right Denied) =<< checkCachedEngine consistencyStore (countingTupleStore deniedReadCount tupleStore) deniedEnv graph MinimizeLatency requestContext (SubjectId bob) (RelationName "view") space
    deniedReadsAfterFirst <- readIORef deniedReadCount
    assertEqual "cached denied check returns Denied second" (Right Denied) =<< checkCachedEngine consistencyStore (countingTupleStore deniedReadCount tupleStore) deniedEnv graph MinimizeLatency requestContext (SubjectId bob) (RelationName "view") space
    assertEqual "cached denied check suppresses second read" deniedReadsAfterFirst =<< readIORef deniedReadCount

    conditionalReadCount <- newIORef 0
    conditionalEnv <- newCheckCacheEnv
    let conditionalDecision = Conditional [CaveatObligation{caveat = CaveatName "within_autonomy", missingContext = ["requested_autonomy"]}]
    assertEqual "cached conditional check returns Conditional first" (Right conditionalDecision) =<< checkCachedEngine consistencyStore (countingTupleStore conditionalReadCount tupleStore) conditionalEnv graph MinimizeLatency missingAutonomyContext (SubjectId user) (RelationName "view") intention
    conditionalReadsAfterFirst <- readIORef conditionalReadCount
    assertEqual "cached conditional check returns Conditional second" (Right conditionalDecision) =<< checkCachedEngine consistencyStore (countingTupleStore conditionalReadCount tupleStore) conditionalEnv graph MinimizeLatency missingAutonomyContext (SubjectId user) (RelationName "view") intention
    assertEqual "cached conditional check suppresses second read" conditionalReadsAfterFirst =<< readIORef conditionalReadCount
    assertEqual "decision key separates caveat context through checkCached" (Right Allowed) =<< checkCachedEngine consistencyStore (countingTupleStore conditionalReadCount tupleStore) conditionalEnv graph MinimizeLatency requestContext (SubjectId user) (RelationName "view") intention
    readsAfterContextMiss <- readIORef conditionalReadCount
    assertBool "different caveat context misses decision cache" (readsAfterContextMiss > conditionalReadsAfterFirst)

    separationReadCount <- newIORef 0
    separationEnv <- newCheckCacheEnv
    assertEqual "cached check baseline for revision/schema separation" (Right Allowed) =<< checkCachedEngine consistencyStore (countingTupleStore separationReadCount tupleStore) separationEnv graph MinimizeLatency requestContext (SubjectId user) (RelationName "view") space
    separationReadsAfterFirst <- readIORef separationReadCount
    assertEqual "decision key separates revision through checkCached" (Right Allowed) =<< checkCachedEngine (fixedRevisionConsistencyStore (Revision "revision:other")) (countingTupleStore separationReadCount tupleStore) separationEnv graph MinimizeLatency requestContext (SubjectId user) (RelationName "view") space
    separationReadsAfterRevisionMiss <- readIORef separationReadCount
    assertBool "different revision misses decision cache" (separationReadsAfterRevisionMiss > separationReadsAfterFirst)
    let graphWithOtherHash = graph{hash = SchemaHash "schema:other"}
    assertEqual "decision key separates schema hash through checkCached" (Right Allowed) =<< checkCachedEngine consistencyStore (countingTupleStore separationReadCount tupleStore) separationEnv graphWithOtherHash MinimizeLatency requestContext (SubjectId user) (RelationName "view") space
    assertBool "different schema hash misses decision cache" =<< ((> separationReadsAfterRevisionMiss) <$> readIORef separationReadCount)

    lookupEnv@CheckCacheEnv{cacheDecisions} <- newCheckCacheEnv
    let lookupAudit =
            lookupRequest (SubjectId memberOwner) (RelationName "audit") (ObjectType "space") requestContext (LookupLimit 10) Nothing
    assertEqual "cached lookup confirms candidates first" (Right (lookupPage [allowed auditedSpace, allowed exclusionSpace] LookupExhausted)) =<< lookupCachedEngine consistencyStore tupleStore lookupEnv graph MinimizeLatency lookupAudit
    lookupStatsAfterFirst <- cacheStats cacheDecisions
    assertEqual "cached lookup confirms candidates second" (Right (lookupPage [allowed auditedSpace, allowed exclusionSpace] LookupExhausted)) =<< lookupCachedEngine consistencyStore tupleStore lookupEnv graph MinimizeLatency lookupAudit
    lookupStatsAfterSecond <- cacheStats cacheDecisions
    assertBool "cached lookup reuses decision cache for confirmations" (lookupStatsAfterSecond.hits > lookupStatsAfterFirst.hits)

newCheckCacheEnv :: IO CheckCacheEnv
newCheckCacheEnv = do
    cache <- newCache CacheConfig{enabled = True, maxEntries = 100} :: IO (Cache SubproblemKey CheckDecision)
    pure CheckCacheEnv{cacheDatastoreId = DatastoreId "test", cacheDecisions = cache}

checkCachedEngine ::
    ConsistencyInterpreter ->
    TupleInterpreter ->
    CheckCacheEnv ->
    ReachabilityGraph ->
    Consistency ->
    CaveatContext ->
    Subject ->
    RelationName ->
    ObjectRef ->
    IO (Either EnError CheckDecision)
checkCachedEngine cStore tStore cacheEnv graph consistency context subject relation object =
    runEngine cStore tStore (Check.checkCached cacheEnv graph consistency context subject relation object)

lookupCachedEngine ::
    ConsistencyInterpreter ->
    TupleInterpreter ->
    CheckCacheEnv ->
    ReachabilityGraph ->
    Consistency ->
    LookupRequest ->
    IO (Either EnError LookupPage)
lookupCachedEngine cStore tStore cacheEnv graph consistency request =
    runEngine cStore tStore (Lookup.lookupCached cacheEnv graph consistency request)

lookupRequest :: Subject -> RelationName -> ObjectType -> CaveatContext -> LookupLimit -> Maybe LookupCursor -> LookupRequest
lookupRequest subject permission objectType context limit cursor =
    LookupRequest{subject, permission, objectType, context, limit, cursor}

lookupPage :: [LookupObject] -> LookupState -> LookupPage
lookupPage objects state =
    LookupPage{objects, state}

type TestEffects = '[ConsistencyStore, TupleStore, Error EnError, IOE]

type ConsistencyInterpreter =
    forall a. Eff TestEffects a -> Eff '[TupleStore, Error EnError, IOE] a

type TupleInterpreter =
    forall a. Eff '[TupleStore, Error EnError, IOE] a -> Eff '[Error EnError, IOE] a

runEngine :: ConsistencyInterpreter -> TupleInterpreter -> Eff TestEffects a -> IO (Either EnError a)
runEngine cStore tStore action =
    runEff (runErrorNoCallStack (tStore (cStore action)))

check ::
    ConsistencyInterpreter ->
    TupleInterpreter ->
    ReachabilityGraph ->
    Consistency ->
    CaveatContext ->
    Subject ->
    RelationName ->
    ObjectRef ->
    IO (Either EnError CheckDecision)
check cStore tStore graph consistency context subject relation object =
    runEngine cStore tStore (Check.check graph consistency context subject relation object)

checkMany ::
    ConsistencyInterpreter ->
    TupleInterpreter ->
    ReachabilityGraph ->
    Consistency ->
    CaveatContext ->
    [BatchPair] ->
    IO (Either EnError [CheckDecision])
checkMany cStore tStore graph consistency context pairs =
    runEngine cStore tStore (Check.checkMany graph consistency context pairs)

lookupEngine ::
    Deadline (Eff TestEffects) ->
    ConsistencyInterpreter ->
    TupleInterpreter ->
    ReachabilityGraph ->
    Consistency ->
    LookupRequest ->
    IO (Either EnError LookupPage)
lookupEngine deadline cStore tStore graph consistency request =
    runEngine cStore tStore (Lookup.lookupWithDeadline deadline graph consistency request)

expandEngine ::
    ConsistencyInterpreter ->
    TupleInterpreter ->
    ReachabilityGraph ->
    Consistency ->
    ExpandRequest ->
    IO (Either EnError ExpandTree)
expandEngine cStore tStore graph consistency request =
    runEngine cStore tStore (Expand.expand graph consistency request)

collectAllLookupPages ::
    Deadline (Eff TestEffects) ->
    ConsistencyInterpreter ->
    TupleInterpreter ->
    ReachabilityGraph ->
    LookupRequest ->
    IO [LookupObject]
collectAllLookupPages deadline cStore tStore graph request = do
    page <- lookupEngine deadline cStore tStore graph MinimizeLatency request
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

budgetedDeadline :: IORef Int -> Deadline (Eff TestEffects)
budgetedDeadline ref =
    Deadline $
        liftIO $
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

tupleStore :: TupleInterpreter
tupleStore =
    runTupleStoreInMemory fixtureTuples

recursiveTupleStore :: TupleInterpreter
recursiveTupleStore =
    runTupleStoreInMemory
        [ Tuple
            { object = recursiveSpace
            , relation = RelationName "parent"
            , subject = SubjectId recursiveSpace
            , caveat = Nothing
            }
        ]

consistencyStore :: ConsistencyInterpreter
consistencyStore =
    runConsistencyStoreInMemory

fixedRevisionConsistencyStore :: Revision -> ConsistencyInterpreter
fixedRevisionConsistencyStore revision =
    interpret_ \case
        DecodeToken token ->
            pure (TokenMetadata token revision (DatastoreId "test") (SchemaHash "schema") Nothing)
        ValidateToken _ ->
            pure ()
        ResolveConsistency consistency ->
            pure ResolvedConsistency{consistency, revision}

countingConsistencyStore :: IORef Int -> ConsistencyInterpreter -> ConsistencyInterpreter
countingConsistencyStore count _ =
    interpret_ \case
        DecodeToken token ->
            pure (TokenMetadata token testRevision (DatastoreId "test") (SchemaHash "schema") Nothing)
        ValidateToken _ ->
            pure ()
        ResolveConsistency consistency -> do
            liftIO (modifyIORef' count (+ 1))
            pure ResolvedConsistency{consistency, revision = testRevision}

countingTupleStore :: IORef Int -> TupleInterpreter -> TupleInterpreter
countingTupleStore count _ =
    interpretFixtureTupleStore (Just count) Nothing fixtureTuples

erroringTupleStore :: ObjectRef -> TupleInterpreter -> TupleInterpreter
erroringTupleStore badObject _ =
    interpretFixtureTupleStore Nothing (Just badObject) fixtureTuples

interpretFixtureTupleStore :: Maybe (IORef Int) -> Maybe ObjectRef -> [Tuple] -> TupleInterpreter
interpretFixtureTupleStore countRef errorObject tuples =
    interpret_ \case
        ReadObjectRelation _ object relation limit cursor -> do
            countRead
            if Just object == errorObject
                then pure TuplePage{rows = [], state = HasMore (StoreCursor "injected-error")}
                else pure (pageTuples limit cursor [tuple | tuple <- tuples, tuple.object == object, tuple.relation == relation])
        ReadStartingWithUser _ query -> do
            countRead
            pure
                ( pageTuples
                    query.queryLimit
                    query.queryCursor
                    [ tuple
                    | tuple <- tuples
                    , tuple.object.objectType == query.queryType
                    , tuple.relation == query.queryRelation
                    , tuple.subject `elem` query.querySubjects
                    ]
                )
        WriteTuples _ ->
            pure (ConsistencyToken "in-memory-write")
        DeleteTuples _ ->
            pure (ConsistencyToken "in-memory-delete")
        HeadRevision ->
            pure testRevision
        OptimizedRevision ->
            pure testRevision
        OldestRetainedXid ->
            pure 0
        ReapDeletedTuples _ ->
            pure 0
  where
    countRead =
        traverse_ (\ref -> liftIO (modifyIORef' ref (+ 1))) countRef

minLevelSchema :: Schema
minLevelSchema =
    testSchemaOrError $ do
        minLevel <-
            Schema.caveatWith
                "min_level"
                [ Schema.parameter "clearance" ParameterInteger
                , Schema.parameter "level" ParameterInteger
                ]
                (Schema.cmpGe (Schema.ctxParam "clearance") (Schema.payloadParam "level"))
        userObject <- Schema.object "user" []
        documentObject <-
            Schema.object
                "document"
                [ Schema.relation "viewer" [Schema.subject "user"] Schema.this
                , Schema.permission "view" (Schema.computed "viewer")
                ]
        Schema.buildWithCaveats [minLevel] [userObject, documentObject]

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
    testSchemaOrError $ do
        userObject <- Schema.object "user" []
        org <-
            Schema.object
                "org"
                [Schema.relation "member" [Schema.subject "user"] Schema.this]
        spaceObject <-
            Schema.object
                "space"
                [ Schema.relation "viewer" [Schema.wildcardSubject "user"] Schema.this
                , Schema.permission "view" (Schema.computed "viewer")
                ]
        Schema.build [userObject, org, spaceObject]

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
    testSchemaOrError $ do
        userObject <- Schema.object "user" []
        folderObject <-
            Schema.object
                "folder"
                [Schema.relation "viewer" [Schema.subject "user"] Schema.this]
        Schema.build [userObject, folderObject]

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

testSchemaOrError :: Either EnError Schema -> Schema
testSchemaOrError =
    either (error . ("invalid test schema fixture: " <>) . show) id

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

assertLeftEq :: (Eq a, Show a) => String -> a -> Either a b -> IO ()
assertLeftEq label expected actual =
    case actual of
        Left value | value == expected -> pure ()
        Left value ->
            fail $
                label
                    <> "\nexpected: Left "
                    <> show expected
                    <> "\nactual:   "
                    <> show value
        Right _ ->
            fail $
                label
                    <> "\nexpected: Left "
                    <> show expected
                    <> "\nactual:   Right _"

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
