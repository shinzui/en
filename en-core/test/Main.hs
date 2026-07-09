{-# LANGUAGE DataKinds #-}
{-# LANGUAGE QuasiQuotes #-}
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
import Data.Time (UTCTime)
import Data.Time.Format.ISO8601 (iso8601ParseM)
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
import En.Decision qualified as Decision
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
    probeTuples,
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
import En.Schema.Parse qualified as SchemaParse
import En.Schema.Render (renderMarkdown, renderMermaid)
import En.Schema.TH (mkValidSchema, schema)
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

quotedSchemaFixture :: Schema
quotedSchemaFixture =
    testSchemaOrError $ do
        userObject <- Schema.object "user" []
        spaceObject <-
            Schema.object
                "space"
                [ Schema.relation "owner" [Schema.subject "user"] Schema.this
                , Schema.relation "parent" [Schema.subject "space"] Schema.this
                , Schema.permission "view" (Schema.anyOf (Schema.computed "owner") [Schema.arrow "parent" "view"])
                ]
        Schema.build [userObject, spaceObject]

quotedSchemaTH :: ValidSchema
quotedSchemaTH =
    [schema|
object user {}
object space {
  relation owner: user
  relation parent: space
  permission view = owner | parent->view
}
|]

handleStringSchema :: Either EnError Schema
handleStringSchema = do
    userObject <- Schema.object "user" []
    documentObject <-
        Schema.object
            "document"
            [ Schema.relation "owner" [Schema.subject "user"] Schema.this
            , Schema.permission "view" (Schema.computed "owner")
            ]
    Schema.build [userObject, documentObject]

handleReferenceSchema :: Either EnError Schema
handleReferenceSchema = do
    userObject <- Schema.object "user" []
    let (ownerRelation, owner) =
            Schema.relationH "owner" [Schema.subject "user"] Schema.this
    documentObject <-
        Schema.object
            "document"
            [ ownerRelation
            , Schema.permission "view" (Schema.computed owner)
            ]
    Schema.build [userObject, documentObject]

-- Negative compile fixture: a permission may not be a bare `this`.
-- Uncommenting the next definition must fail with a type error like:
--   Couldn't match expected type `Schema.PermissionRewrite`
--     with actual type `Rewrite`
-- badPermission :: Schema.SchemaRelation
-- badPermission = Schema.permission "view" Schema.this

expectedKikanMarkdown :: Text
expectedKikanMarkdown =
    Text.intercalate
        "\n"
        [ "# Schema reference"
        , ""
        , "## intention"
        , ""
        , "- **delegate** — subjects: user; rule: directly assigned"
        , "- **view** — subjects: (none); rule: delegate"
        , ""
        , "## org"
        , ""
        , "- **member** — subjects: user; rule: directly assigned"
        , ""
        , "## space"
        , ""
        , "- **act** — subjects: (none); rule: owner ∪ member"
        , "- **audit** — subjects: (none); rule: owner ∩ member"
        , "- **guest_org** — subjects: org; rule: directly assigned"
        , "- **member** — subjects: org#member, user; rule: directly assigned"
        , "- **member_not_owner** — subjects: (none); rule: member ∖ owner"
        , "- **owner** — subjects: user; rule: directly assigned"
        , "- **parent** — subjects: space; rule: directly assigned"
        , "- **view** — subjects: (none); rule: owner ∪ member ∪ guest_org→member ∪ parent→view ∪ visibility_class→viewer"
        , "- **visibility_class** — subjects: visibility_class; rule: directly assigned"
        , ""
        , "## user"
        , ""
        , "(no relations)"
        , ""
        , "## visibility_class"
        , ""
        , "- **viewer** — subjects: user; rule: directly assigned"
        , ""
        , "## Caveats"
        , ""
        , "- **within_autonomy** — parameters: autonomy: enum[act, admin, read], current_time: timestamp, requested_autonomy: enum[act, read], until: timestamp"
        ]

expectedKikanMermaid :: Text
expectedKikanMermaid =
    Text.unlines
        [ "flowchart LR"
        , "  object_intention[\"intention\"]"
        , "  object_org[\"org\"]"
        , "  object_space[\"space\"]"
        , "  object_user[\"user\"]"
        , "  object_visibility_class[\"visibility_class\"]"
        , "  object_intention -->|delegate| object_user"
        , "  object_intention -->|\"view = delegate\"| object_intention"
        , "  object_org -->|member| object_user"
        , "  object_space -->|\"act = owner ∪ member\"| object_space"
        , "  object_space -->|\"audit = owner ∩ member\"| object_space"
        , "  object_space -->|guest_org| object_org"
        , "  object_space -->|\"member (org#member)\"| object_org"
        , "  object_space -->|member| object_user"
        , "  object_space -->|\"member_not_owner = member ∖ owner\"| object_space"
        , "  object_space -->|owner| object_user"
        , "  object_space -->|parent| object_space"
        , "  object_space -->|\"view = owner ∪ member ∪ guest_org→member ∪ parent→view ∪ visibility_class→viewer\"| object_space"
        , "  object_space -->|visibility_class| object_visibility_class"
        , "  object_visibility_class -->|viewer| object_user"
        ]

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
    assertEqual "schema quasi-quoter builds compact schema" quotedSchemaFixture (unValidSchema quotedSchemaTH)
    testSchemaParserDirect
    testSchemaParserCaveats
    assertEqual "handle form equals string form" handleStringSchema handleReferenceSchema
    assertEqual "renderMarkdown emits stable kikan reference" expectedKikanMarkdown (renderMarkdown kikanSchema)
    assertEqual "renderMermaid emits stable kikan diagram" expectedKikanMermaid (renderMermaid kikanSchema)
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
    assertEqual "batch agrees with single checks in input order" (Right [Right Allowed, Right Denied, Right Denied, Right Denied]) =<< checkMany consistencyStore tupleStore graph MinimizeLatency requestContext mixedBatch
    resolveCount <- newIORef 0
    assertEqual "batch with counted consistency still returns decisions" (Right [Right Allowed, Right Denied, Right Denied, Right Denied]) =<< checkMany (countingConsistencyStore resolveCount consistencyStore) tupleStore graph MinimizeLatency requestContext mixedBatch
    assertEqual "batch resolves consistency once" 1 =<< readIORef resolveCount
    let overlappingBatch =
            [ BatchPair (SubjectId user) (RelationName "view") space
            , BatchPair (SubjectId user) (RelationName "owner") space
            , BatchPair (SubjectId user) (RelationName "member") space
            ]
    batchReadCount <- newIORef 0
    assertEqual "overlapping batch returns decisions" (Right [Right Allowed, Right Allowed, Right Denied]) =<< checkMany consistencyStore (countingTupleStore batchReadCount tupleStore) graph MinimizeLatency requestContext overlappingBatch
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
    assertEqual "batch surfaces the failing pair and leaves the others intact" (Right [Right Allowed, Left (UnknownRelation "space#injected-missing-relation"), Right Denied]) =<< checkMany consistencyStore (erroringTupleStore badReadSpace tupleStore) graph MinimizeLatency requestContext badReadBatch
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
    assertEqual "probe returns the matching row" (Right [tupleRow 1 (Tuple{object = space, relation = RelationName "owner", subject = SubjectId user, caveat = Nothing})]) =<< probe consistencyStore tupleStore space (RelationName "owner") [SubjectId user]
    assertEqual "probe returns nothing for a non-member" (Right []) =<< probe consistencyStore tupleStore space (RelationName "owner") [SubjectId bob]
    assertEqual "probe carries the caveat name and payload" (Right [Just autonomyCaveat]) =<< fmap (fmap (fmap (\row -> row.tuple.caveat))) (probe consistencyStore tupleStore intention (RelationName "delegate") [SubjectId user])
    let wideStore = runTupleStoreInMemory wideTuples
    assertEqual "wide relation: direct member checks Allowed" (Right Allowed) =<< check consistencyStore wideStore streamingGraph MinimizeLatency requestContext (SubjectId wideMember) (RelationName "viewer") wideFolder
    assertEqual "wide relation: non-member checks Denied" (Right Denied) =<< check consistencyStore wideStore streamingGraph MinimizeLatency requestContext (SubjectId bob) (RelationName "viewer") wideFolder
    wideReadCount <- newIORef 0
    assertEqual "wide relation member check is Allowed under a counting store" (Right Allowed) =<< check consistencyStore (countingStoreFor wideReadCount wideTuples) streamingGraph MinimizeLatency requestContext (SubjectId wideMember) (RelationName "viewer") wideFolder
    wideReads <- readIORef wideReadCount
    assertEqual "wide relation member check costs one probe, not a scan" 1 wideReads
    groupGraph <- either (fail . show) pure (compileSchema groupSchema)
    groupReadCount <- newIORef 0
    assertEqual "membership through one of many groups is Allowed" (Right Allowed) =<< check consistencyStore (countingStoreFor groupReadCount manyGroupTuples) groupGraph MinimizeLatency requestContext (SubjectId groupUser) (RelationName "member") manyGroupSpace
    groupReads <- readIORef groupReadCount
    assertBool ("nested-group membership issues fewer reads than there are groups, got " <> show groupReads) (groupReads < length groupOrgs)
    assertEqual "nested-group membership costs a probe, a drain, and one batched query" 3 groupReads
    assertEqual "membership through a group the user is not in is Denied" (Right Denied) =<< check consistencyStore (runTupleStoreInMemory manyGroupTuples) groupGraph MinimizeLatency requestContext (SubjectId bob) (RelationName "member") manyGroupSpace
    assertEqual
        "caveats on both edges of a nested-group path compose into both obligations"
        (Right (Conditional [CaveatObligation{caveat = CaveatName "min_level", missingContext = ["clearance"]}, CaveatObligation{caveat = CaveatName "min_rank", missingContext = ["rank"]}]))
        =<< check consistencyStore (runTupleStoreInMemory caveatedGroupTuples) groupGraph MinimizeLatency (CaveatContext Map.empty) (SubjectId groupUser) (RelationName "member") caveatedGroupSpace
    cyclicGraph <- either (fail . show) pure (compileSchema cyclicSchema)
    let cyclicStore = runTupleStoreInMemory cyclicTuples
    assertEqual "cycle does not poison an unrelated union branch" (Right Allowed) =<< check consistencyStore cyclicStore cyclicGraph MinimizeLatency requestContext (SubjectId carol) (RelationName "view") docD
    assertEqual "cycle-only path returns Denied, not an error" (Right Denied) =<< check consistencyStore cyclicStore cyclicGraph MinimizeLatency requestContext (SubjectId dave) (RelationName "view") docD
    roomGraph <- either (fail . show) pure (compileSchema roomSchema)
    let roomStore = runTupleStoreInMemory roomTuples
    assertEqual "exclusion over conditional base evaluates the subtrahend" (Right Denied) =<< check consistencyStore roomStore roomGraph MinimizeLatency missingAutonomyContext (SubjectId erin) (RelationName "enter") roomR
    assertEqual "conditional base with no ban stays Conditional" (Right (Conditional [CaveatObligation{caveat = CaveatName "within_autonomy", missingContext = ["requested_autonomy"]}])) =<< check consistencyStore roomStore roomGraph MinimizeLatency missingAutonomyContext (SubjectId frank) (RelationName "enter") roomR
    assertEqual
        "conditional base and conditional ban merge both obligations"
        (Right (Conditional [CaveatObligation{caveat = CaveatName "within_autonomy", missingContext = ["requested_autonomy"]}, CaveatObligation{caveat = CaveatName "min_clearance", missingContext = ["clearance"]}]))
        =<< check consistencyStore (runTupleStoreInMemory caveatedBanTuples) roomGraph MinimizeLatency missingAutonomyContext (SubjectId erin) (RelationName "enter") roomR
    assertEqual "self-parent cycle yields Denied via cycle-as-empty" (Right Denied) =<< check consistencyStore recursiveTupleStore graph MinimizeLatency requestContext (SubjectId user) (RelationName "view") recursiveSpace
    deepChainGraph <- either (fail . show) pure (compileSchema deepChainSchema)
    assertEqual "acyclic chain deeper than the depth budget still errors" (Left ResolutionLimitExceeded) =<< check consistencyStore (runTupleStoreInMemory deepChainTuples) deepChainGraph MinimizeLatency requestContext (SubjectId user) (RelationName "view") (deepSpace 1)
    assertEqual "expand reports a cycle rather than hiding the branch" (Left (CycleDetected "space:recursive-space#view")) =<< expandEngine consistencyStore recursiveTupleStore graph MinimizeLatency (expandRequest recursiveSpace (RelationName "view") requestContext (ExpandLimit 10) Nothing)
    taintGraph <- either (fail . show) pure (compileSchema taintSchema)
    assertEqual "a cycle-tainted decision is not memoized across batch pairs" (Right [Right Allowed, Right Allowed]) =<< checkMany consistencyStore (runTupleStoreInMemory taintTuples) taintGraph MinimizeLatency requestContext [BatchPair (SubjectId carol) (RelationName "x") taintNode, BatchPair (SubjectId carol) (RelationName "y") taintNode]
    unionShortCircuitReads <- newIORef 0
    assertEqual "owner check is Allowed" (Right Allowed) =<< check consistencyStore (countingTupleStore unionShortCircuitReads tupleStore) graph MinimizeLatency requestContext (SubjectId user) (RelationName "view") space
    shortCircuitReads <- readIORef unionShortCircuitReads
    assertEqual "union stops at the first branch that proves Allowed" 1 shortCircuitReads
    assertEqual "union is Allowed-absorbing" Allowed (Decision.union [Conditional [obligation "a" ["x"]], Allowed])
    assertEqual "union keeps obligations when nothing is Allowed" (Conditional [obligation "a" ["x"]]) (Decision.union [Conditional [obligation "a" ["x"]], Denied])
    assertEqual "exclusion: Denied base ignores the subtrahend" Denied (Decision.exclusionDecisions Denied Allowed)
    assertEqual "exclusion: unconditional subtraction denies a conditional base" Denied (Decision.exclusionDecisions (Conditional [obligation "a" ["x"]]) Allowed)
    assertEqual "exclusion: Allowed base with Denied subtrahend allows" Allowed (Decision.exclusionDecisions Allowed Denied)
    assertEqual "exclusion: Allowed base carries the subtrahend's obligations" (Conditional [obligation "b" ["y"]]) (Decision.exclusionDecisions Allowed (Conditional [obligation "b" ["y"]]))
    assertEqual "exclusion: conditional base with Denied subtrahend stays conditional" (Conditional [obligation "a" ["x"]]) (Decision.exclusionDecisions (Conditional [obligation "a" ["x"]]) Denied)
    assertEqual "exclusion: two conditionals merge and deduplicate" (Conditional [obligation "a" ["x"], obligation "b" ["y"]]) (Decision.exclusionDecisions (Conditional [obligation "a" ["x"]]) (Conditional [obligation "a" ["x"], obligation "b" ["y"]]))
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

testSchemaParserDirect :: IO ()
testSchemaParserDirect = do
    let compactSchemaText =
            Text.unlines
                [ "object user {}"
                , "object space {"
                , "  relation owner: user"
                , "  relation parent: space"
                , "  permission view = owner | parent->view"
                , "}"
                ]
    assertEqual "parseSchema parses compact schema text" (Right quotedSchemaFixture) (SchemaParse.parseSchema compactSchemaText)
    parsed <- either (fail . show) pure (SchemaParse.parseSchema compactSchemaText)
    assertBool "parseSchema output validates" (isRight (validateSchema parsed))
    assertBool "parseSchema rejects malformed permissions" (isLeft (SchemaParse.parseSchema "object space {\n  permission view owner\n}"))
    assertBool "parseSchema rejects objects missing closing braces" (isLeft (SchemaParse.parseSchema "object space {\n  relation owner: user"))
    assertLeftEq
        "parseSchema reports schema assembly errors"
        (SchemaViolation "duplicate relation declared: space#owner")
        ( SchemaParse.parseSchema $
            Text.unlines
                [ "object user {}"
                , "object space {"
                , "  relation owner: user"
                , "  relation owner: user"
                , "}"
                ]
        )
    assertEqual "parseSchema supports intersection, exclusion, and grouped rewrites" (Right rewriteOperatorSchema) (SchemaParse.parseSchema rewriteOperatorSchemaText)
    assertBool "parseSchema rejects unbalanced rewrite grouping" (isLeft (SchemaParse.parseSchema "object user {}\nobject space {\n  relation a: user\n  permission view = (a | a\n}"))

rewriteOperatorSchemaText :: Text
rewriteOperatorSchemaText =
    Text.unlines
        [ "object user {}"
        , "object space {"
        , "  relation editor: user"
        , "  relation active: user"
        , "  relation banned: user"
        , "  relation a: user"
        , "  relation b: user"
        , "  relation c: user"
        , "  permission audit = editor & active"
        , "  permission member_not_banned = editor but not banned"
        , "  permission grouped = (a | b) & c"
        , "}"
        ]

rewriteOperatorSchema :: Schema
rewriteOperatorSchema =
    testSchemaOrError $ do
        userObject <- Schema.object "user" []
        spaceObject <-
            Schema.object
                "space"
                [ Schema.relation "editor" [Schema.subject "user"] Schema.this
                , Schema.relation "active" [Schema.subject "user"] Schema.this
                , Schema.relation "banned" [Schema.subject "user"] Schema.this
                , Schema.relation "a" [Schema.subject "user"] Schema.this
                , Schema.relation "b" [Schema.subject "user"] Schema.this
                , Schema.relation "c" [Schema.subject "user"] Schema.this
                , Schema.permission "audit" (Schema.allOf (Schema.computed "editor") [Schema.computed "active"])
                , Schema.permission "member_not_banned" (Schema.minus (Schema.computed "editor") (Schema.computed "banned"))
                , Schema.permission "grouped" (Schema.allOf (Schema.anyOf (Schema.computed "a") [Schema.computed "b"]) [Schema.computed "c"])
                ]
        Schema.build [userObject, spaceObject]

testSchemaParserCaveats :: IO ()
testSchemaParserCaveats = do
    assertEqual "parseSchema supports caveats and caveated rewrites" (Right caveatParserSchema) (SchemaParse.parseSchema caveatParserSchemaText)
    assertBool "parseSchema caveat output validates" (isRight (SchemaParse.parseSchema caveatParserSchemaText >>= validateSchema))
    assertBool "parseSchema validation rejects unknown caveat references" (isLeft (SchemaParse.parseSchema unknownCaveatSchemaText >>= validateSchema))
    assertBool "parseSchema validation rejects unknown caveat parameters" (isLeft (SchemaParse.parseSchema unknownCaveatParameterSchemaText >>= validateSchema))

caveatParserSchemaText :: Text
caveatParserSchemaText =
    Text.unlines
        [ "caveat request_allowed(allowed: bool) {"
        , "  context.allowed == true"
        , "}"
        , "caveat complex(flag: bool, clearance: integer, level: integer, now: timestamp, mode: enum[read, act], name: text) {"
        , "  true & context.clearance >= payload.level & context.clearance > 0 & context.level < 10 & context.level <= 7 & context.name != \"blocked\" & context.now <= timestamp(\"2026-06-24T12:00:00Z\") & context.mode in [enum(\"read\"), enum(\"act\")] & !(context.flag == false) | context.name == \"admin\""
        , "}"
        , "object user {}"
        , "object document {"
        , "  relation viewer: user"
        , "  permission view = viewer with request_allowed"
        , "}"
        ]

caveatParserSchema :: Schema
caveatParserSchema =
    testSchemaOrError $ do
        requestAllowed <-
            Schema.caveatWith
                "request_allowed"
                [Schema.parameter "allowed" ParameterBool]
                (Schema.cmpEq (Schema.ctxParam "allowed") (Schema.litBool True))
        complex <-
            Schema.caveatWith
                "complex"
                [ Schema.parameter "flag" ParameterBool
                , Schema.parameter "clearance" ParameterInteger
                , Schema.parameter "level" ParameterInteger
                , Schema.parameter "now" ParameterTimestamp
                , Schema.parameter "mode" (ParameterEnum ["read", "act"])
                , Schema.parameter "name" ParameterText
                ]
                ( Schema.predOr
                    [ Schema.predAnd
                        [ Schema.predTrue
                        , Schema.cmpGe (Schema.ctxParam "clearance") (Schema.payloadParam "level")
                        , Schema.cmpGt (Schema.ctxParam "clearance") (Schema.litInteger 0)
                        , Schema.cmpLt (Schema.ctxParam "level") (Schema.litInteger 10)
                        , Schema.cmpLe (Schema.ctxParam "level") (Schema.litInteger 7)
                        , Schema.cmpNe (Schema.ctxParam "name") (Schema.litText "blocked")
                        , Schema.cmpLe (Schema.ctxParam "now") (Schema.litTimestamp testTimestamp)
                        , Schema.predMember (Schema.ctxParam "mode") [ValueEnum "read", ValueEnum "act"]
                        , Schema.predNot (Schema.cmpEq (Schema.ctxParam "flag") (Schema.litBool False))
                        ]
                    , Schema.cmpEq (Schema.ctxParam "name") (Schema.litText "admin")
                    ]
                )
        userObject <- Schema.object "user" []
        documentObject <-
            Schema.object
                "document"
                [ Schema.relation "viewer" [Schema.subject "user"] Schema.this
                , Schema.permission "view" (Schema.caveated "request_allowed" (Schema.computed "viewer"))
                ]
        Schema.buildWithCaveats [requestAllowed, complex] [userObject, documentObject]

testTimestamp :: UTCTime
testTimestamp =
    case iso8601ParseM "2026-06-24T12:00:00Z" of
        Just value -> value
        Nothing -> error "invalid test timestamp"

unknownCaveatSchemaText :: Text
unknownCaveatSchemaText =
    Text.unlines
        [ "object user {}"
        , "object document {"
        , "  relation viewer: user"
        , "  permission view = viewer with missing_caveat"
        , "}"
        ]

unknownCaveatParameterSchemaText :: Text
unknownCaveatParameterSchemaText =
    Text.unlines
        [ "caveat bad(allowed: bool) {"
        , "  context.missing == true"
        , "}"
        , "object user {}"
        ]

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

probe ::
    ConsistencyInterpreter ->
    TupleInterpreter ->
    ObjectRef ->
    RelationName ->
    [Subject] ->
    IO (Either EnError [TupleRow])
probe cStore tStore object relation subjects =
    runEngine cStore tStore (probeTuples testRevision object relation subjects)

checkMany ::
    ConsistencyInterpreter ->
    TupleInterpreter ->
    ReachabilityGraph ->
    Consistency ->
    CaveatContext ->
    [BatchPair] ->
    IO (Either EnError [Either EnError CheckDecision])
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

-- | Like 'countingTupleStore', but over a caller-supplied fixture.
countingStoreFor :: IORef Int -> [Tuple] -> TupleInterpreter
countingStoreFor count =
    interpretFixtureTupleStore (Just count) Nothing

{- | A store that makes every read of @badObject@ fail the check for that object.

The failure is injected as a row pointing at a relation the schema does not
define, so the evaluator returns @Left (UnknownRelation …)@ /as a value/. That
matters: 'checkMany' turns a returned @Left@ into a per-pair @Denied@, whereas an
error thrown through the @Error EnError@ effect would escape and fail the whole
batch.

An earlier version injected the failure by returning @HasMore@ forever and
relying on the (now deleted) @ensureExhausted@ to reject an unexhausted page.
That could not survive an evaluator that drains pages: the drain loop would
follow the cursor forever.
-}
erroringTupleStore :: ObjectRef -> TupleInterpreter -> TupleInterpreter
erroringTupleStore badObject _ =
    interpretFixtureTupleStore Nothing (Just badObject) fixtureTuples

missingRelation :: RelationName
missingRelation =
    RelationName "injected-missing-relation"

injectedErrorRows :: ObjectRef -> RelationName -> TuplePage
injectedErrorRows badObject relation =
    TuplePage
        { rows =
            [ tupleRow
                1
                Tuple
                    { object = badObject
                    , relation
                    , subject = SubjectSet badObject missingRelation
                    , caveat = Nothing
                    }
            ]
        , state = Exhausted
        }

interpretFixtureTupleStore :: Maybe (IORef Int) -> Maybe ObjectRef -> [Tuple] -> TupleInterpreter
interpretFixtureTupleStore countRef errorObject tuples =
    interpret_ \case
        ReadObjectRelation _ object relation limit cursor -> do
            countRead
            if Just object == errorObject
                then pure (injectedErrorRows object relation)
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
        ProbeTuples _ object relation subjects -> do
            countRead
            if Just object == errorObject
                then pure []
                else
                    pure
                        [ tupleRow index tuple
                        | (index, tuple) <- zip [1 ..] tuples
                        , tuple.object == object
                        , tuple.relation == relation
                        , tuple.subject `elem` subjects
                        ]
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

{- | Two groups that contain each other. This is legal data, not corrupt data:
@group:a#member@group:b#member@ and its mirror simply say the two groups share
their membership.

The union defining @doc#view@ puts the cyclic @team@ branch first, so a check
that answers correctly cannot be doing so merely by reaching an earlier branch.
-}
cyclicSchema :: Schema
cyclicSchema =
    testSchemaOrError $ do
        userObject <- Schema.object "user" []
        groupObject <-
            Schema.object
                "group"
                [Schema.relation "member" [Schema.subject "user", Schema.userset "group" "member"] Schema.this]
        docObject <-
            Schema.object
                "doc"
                [ Schema.relation "viewer" [Schema.subject "user"] Schema.this
                , Schema.relation "team" [Schema.userset "group" "member"] Schema.this
                , Schema.permission "view" (Schema.anyOf (Schema.computed "team") [Schema.computed "viewer"])
                ]
        Schema.build [userObject, groupObject, docObject]

groupA :: ObjectRef
groupA =
    ObjectRef{objectType = ObjectType "group", objectId = "a"}

groupB :: ObjectRef
groupB =
    ObjectRef{objectType = ObjectType "group", objectId = "b"}

docD :: ObjectRef
docD =
    ObjectRef{objectType = ObjectType "doc", objectId = "d"}

carol :: ObjectRef
carol =
    ObjectRef{objectType = ObjectType "user", objectId = "carol"}

-- | @dave@ has no tuples: his only route to @doc:d@ runs through the cycle.
dave :: ObjectRef
dave =
    ObjectRef{objectType = ObjectType "user", objectId = "dave"}

cyclicTuples :: [Tuple]
cyclicTuples =
    [ Tuple{object = groupA, relation = RelationName "member", subject = SubjectSet groupB (RelationName "member"), caveat = Nothing}
    , Tuple{object = groupB, relation = RelationName "member", subject = SubjectSet groupA (RelationName "member"), caveat = Nothing}
    , Tuple{object = docD, relation = RelationName "team", subject = SubjectSet groupA (RelationName "member"), caveat = Nothing}
    , Tuple{object = docD, relation = RelationName "viewer", subject = SubjectId carol, caveat = Nothing}
    ]

{- | @x = y or direct@ and @y = x@: a two-permission cycle where @x@ also has a
branch that genuinely grants.

Evaluating @x@ descends into @y@, which cuts back to @x@ and so contributes
'Denied' -- an answer true only inside that stack, since @y@ evaluated on its own
is 'Allowed' by way of @x@'s @direct@ branch. If that stack-local 'Denied' is
memoized, a later pair of the same batch asking about @y@ reads it and is wrongly
denied. This fixture is the regression test for that.
-}
taintSchema :: Schema
taintSchema =
    testSchemaOrError $ do
        userObject <- Schema.object "user" []
        nodeObject <-
            Schema.object
                "node"
                [ Schema.relation "direct" [Schema.subject "user"] Schema.this
                , Schema.permission "x" (Schema.anyOf (Schema.computed "y") [Schema.computed "direct"])
                , Schema.permission "y" (Schema.computed "x")
                ]
        Schema.build [userObject, nodeObject]

taintNode :: ObjectRef
taintNode =
    ObjectRef{objectType = ObjectType "node", objectId = "n"}

taintTuples :: [Tuple]
taintTuples =
    [ Tuple{object = taintNode, relation = RelationName "direct", subject = SubjectId carol, caveat = Nothing}
    ]

{- | A chain of 26 distinct spaces, each the parent of the next: acyclic, but
deeper than @maxDepth@ (25). This is what keeps the depth budget under test once
cycles stop producing errors of their own.
-}
deepChainSchema :: Schema
deepChainSchema =
    testSchemaOrError $ do
        userObject <- Schema.object "user" []
        spaceObject <-
            Schema.object
                "space"
                [ Schema.relation "owner" [Schema.subject "user"] Schema.this
                , Schema.relation "parent" [Schema.subject "space"] Schema.this
                , Schema.permission "view" (Schema.anyOf (Schema.computed "owner") [Schema.arrow "parent" "view"])
                ]
        Schema.build [userObject, spaceObject]

deepChainLength :: Int
deepChainLength =
    26

deepSpace :: Int -> ObjectRef
deepSpace index =
    ObjectRef{objectType = ObjectType "space", objectId = "deep-" <> showText index}

-- | @deep-1@ is the deepest; @deep-26@ is the root and holds the owner grant.
deepChainTuples :: [Tuple]
deepChainTuples =
    [ Tuple
        { object = deepSpace index
        , relation = RelationName "parent"
        , subject = SubjectId (deepSpace (index + 1))
        , caveat = Nothing
        }
    | index <- [1 .. deepChainLength - 1]
    ]
        <> [ Tuple
                { object = deepSpace deepChainLength
                , relation = RelationName "owner"
                , subject = SubjectId user
                , caveat = Nothing
                }
           ]

{- | @enter = allowed - banned@, where the @allowed@ grant is caveated and the
@banned@ grant is not. A subject who is provably banned must be denied even when
the base could not be settled without more request context.
-}
roomSchema :: Schema
roomSchema =
    testSchemaOrError $ do
        autonomy <-
            Schema.caveatWith
                "within_autonomy"
                [ Schema.parameter "requested_autonomy" (ParameterEnum ["read", "act"])
                , Schema.parameter "autonomy" (ParameterEnum ["read", "act", "admin"])
                , Schema.parameter "current_time" ParameterTimestamp
                , Schema.parameter "until" ParameterTimestamp
                ]
                ( Schema.predAnd
                    [ Schema.cmpLe (Schema.ctxParam "requested_autonomy") (Schema.payloadParam "autonomy")
                    , Schema.cmpLe (Schema.ctxParam "current_time") (Schema.payloadParam "until")
                    ]
                )
        clearance <-
            Schema.caveatWith
                "min_clearance"
                [ Schema.parameter "clearance" ParameterInteger
                , Schema.parameter "level" ParameterInteger
                ]
                (Schema.cmpGe (Schema.ctxParam "clearance") (Schema.payloadParam "level"))
        userObject <- Schema.object "user" []
        roomObject <-
            Schema.object
                "room"
                [ Schema.relation "allowed" [Schema.subject "user"] Schema.this
                , Schema.relation "banned" [Schema.subject "user"] Schema.this
                , Schema.permission "enter" (Schema.minus (Schema.computed "allowed") (Schema.computed "banned"))
                ]
        Schema.buildWithCaveats [autonomy, clearance] [userObject, roomObject]

roomR :: ObjectRef
roomR =
    ObjectRef{objectType = ObjectType "room", objectId = "r"}

erin :: ObjectRef
erin =
    ObjectRef{objectType = ObjectType "user", objectId = "erin"}

frank :: ObjectRef
frank =
    ObjectRef{objectType = ObjectType "user", objectId = "frank"}

{- | @erin@ is conditionally allowed and unconditionally banned; @frank@ is
conditionally allowed and not banned at all.
-}
roomTuples :: [Tuple]
roomTuples =
    [ Tuple{object = roomR, relation = RelationName "allowed", subject = SubjectId erin, caveat = Just autonomyCaveat}
    , Tuple{object = roomR, relation = RelationName "banned", subject = SubjectId erin, caveat = Nothing}
    , Tuple{object = roomR, relation = RelationName "allowed", subject = SubjectId frank, caveat = Just autonomyCaveat}
    ]

-- | As 'roomTuples', but @erin@'s ban is itself caveated, on a different caveat.
caveatedBanTuples :: [Tuple]
caveatedBanTuples =
    [ Tuple{object = roomR, relation = RelationName "allowed", subject = SubjectId erin, caveat = Just autonomyCaveat}
    , Tuple{object = roomR, relation = RelationName "banned", subject = SubjectId erin, caveat = Just banCaveat}
    ]

{- | A second caveat with a distinct name and a distinct missing context key, so
that merging the base's obligation with the subtrahend's yields two entries
rather than one deduplicated entry.
-}
banCaveat :: TupleCaveat
banCaveat =
    TupleCaveat
        { name = CaveatName "min_clearance"
        , payload = CaveatPayload (Map.fromList [("level", ValueInteger 1)])
        }

{- | A space shared with many organisations, where the checked user belongs to
exactly one of them. Answering "is this user a member?" by recursing into each
organisation costs one store read per organisation; asking storage once which
organisations contain the user costs one read for all of them.

The second caveat exists so a grant can be gated on two independent conditions,
one on each edge of the two-level path (space to org, org to user).
-}
groupSchema :: Schema
groupSchema =
    testSchemaOrError $ do
        minLevel <-
            Schema.caveatWith
                "min_level"
                [ Schema.parameter "clearance" ParameterInteger
                , Schema.parameter "level" ParameterInteger
                ]
                (Schema.cmpGe (Schema.ctxParam "clearance") (Schema.payloadParam "level"))
        minRank <-
            Schema.caveatWith
                "min_rank"
                [ Schema.parameter "rank" ParameterInteger
                , Schema.parameter "floor" ParameterInteger
                ]
                (Schema.cmpGe (Schema.ctxParam "rank") (Schema.payloadParam "floor"))
        userObject <- Schema.object "user" []
        orgObject <-
            Schema.object
                "org"
                [Schema.relation "member" [Schema.subject "user"] Schema.this]
        spaceObject <-
            Schema.object
                "space"
                [Schema.relation "member" [Schema.subject "user", Schema.userset "org" "member"] Schema.this]
        Schema.buildWithCaveats [minLevel, minRank] [userObject, orgObject, spaceObject]

groupUser :: ObjectRef
groupUser =
    ObjectRef{objectType = ObjectType "user", objectId = "group-user"}

manyGroupSpace :: ObjectRef
manyGroupSpace =
    ObjectRef{objectType = ObjectType "space", objectId = "many-groups"}

groupOrgs :: [ObjectRef]
groupOrgs =
    [ ObjectRef{objectType = ObjectType "org", objectId = "org-" <> showText index}
    | index <- [1 :: Int .. 20]
    ]

{- | The user belongs only to the last organisation, so a per-group recursion
would probe all twenty before finding the grant.
-}
manyGroupTuples :: [Tuple]
manyGroupTuples =
    [ Tuple
        { object = manyGroupSpace
        , relation = RelationName "member"
        , subject = SubjectSet org (RelationName "member")
        , caveat = Nothing
        }
    | org <- groupOrgs
    ]
        <> [ Tuple
                { object = last groupOrgs
                , relation = RelationName "member"
                , subject = SubjectId groupUser
                , caveat = Nothing
                }
           ]

caveatedGroupSpace :: ObjectRef
caveatedGroupSpace =
    ObjectRef{objectType = ObjectType "space", objectId = "caveated-groups"}

caveatedOrg :: ObjectRef
caveatedOrg =
    ObjectRef{objectType = ObjectType "org", objectId = "caveated"}

-- | Both edges of the two-level path are caveated, on different caveats.
caveatedGroupTuples :: [Tuple]
caveatedGroupTuples =
    [ Tuple
        { object = caveatedGroupSpace
        , relation = RelationName "member"
        , subject = SubjectSet caveatedOrg (RelationName "member")
        , caveat = Just TupleCaveat{name = CaveatName "min_level", payload = CaveatPayload (Map.fromList [("level", ValueInteger 3)])}
        }
    , Tuple
        { object = caveatedOrg
        , relation = RelationName "member"
        , subject = SubjectId groupUser
        , caveat = Just TupleCaveat{name = CaveatName "min_rank", payload = CaveatPayload (Map.fromList [("floor", ValueInteger 2)])}
        }
    ]

{- | One folder whose @viewer@ relation is wider than a single store page
(@pageLimit@ is 1000 in "En.Check"), used to prove that a check on a wide
relation answers instead of erroring. @wideMember@ sits past the first page,
so reading only page one cannot find it.
-}
wideFolder :: ObjectRef
wideFolder =
    ObjectRef
        { objectType = ObjectType "folder"
        , objectId = "wide"
        }

wideMember :: ObjectRef
wideMember =
    ObjectRef
        { objectType = ObjectType "user"
        , objectId = "wide-member"
        }

wideTuples :: [Tuple]
wideTuples =
    [ Tuple
        { object = wideFolder
        , relation = RelationName "viewer"
        , subject = SubjectId member
        , caveat = Nothing
        }
    | member <- wideMembers
    ]

wideMembers :: [ObjectRef]
wideMembers =
    fmap filler [1 .. 1199] <> [wideMember] <> fmap filler [1200 .. 1500]
  where
    filler index =
        ObjectRef
            { objectType = ObjectType "user"
            , objectId = "wide-filler-" <> showText (index :: Int)
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

obligation :: Text -> [Text] -> CaveatObligation
obligation name missing =
    CaveatObligation{caveat = CaveatName name, missingContext = missing}

assertValidationFails :: String -> Schema -> IO ()
assertValidationFails label candidate =
    case validate candidate of
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
