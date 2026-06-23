module Main (
    main,
) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, defaultTimeLocale, parseTimeOrError)

import En.Check (CaveatObligation (..), CheckDecision (..), check)
import En.Effect.ConsistencyStore (ConsistencyStore (..), ResolvedConsistency (..), TokenMetadata (TokenMetadata))
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
import En.Expand (ExpandLimit (..), ExpandRequest (..), ExpandState (..), ExpandTree (..))
import En.Lookup (
    LookupCursor (..),
    LookupLimit (..),
    LookupObject (..),
    LookupPage (..),
    LookupRequest (..),
    LookupState (..),
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
import En.Revision (Consistency (..), ConsistencyToken (..), DatastoreId (..), Revision (..), SchemaHash (..))
import En.Schema (
    AllowedSubject (..),
    CaveatDefinition (..),
    CaveatName (..),
    CaveatParameterName (..),
    CaveatParameterType (..),
    ObjectType (..),
    Relation (..),
    RelationName (..),
    Rewrite (..),
    Schema (..),
    schemaHash,
    validate,
 )
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
    graph <- either (fail . show) pure (compile kikanSchema)
    assertEqual "graph stores schema hash" (schemaHash kikanSchema) graph.hash
    assertEqual "schema hash is stable across map insertion order" (schemaHash kikanSchema) (schemaHash kikanSchemaReordered)
    assertBool "space view has a direct user entrypoint" (hasEntry (relationRef "space" "view") (SubjectSelector (ObjectType "user") Nothing) Reachability.Direct False graph)
    assertBool "space view has a guest-org userset entrypoint" (hasEntry (relationRef "space" "view") (SubjectSelector (ObjectType "org") (Just (RelationName "member"))) Reachability.Direct False graph)
    assertBool "space view has a recursive parent entrypoint" (hasEntry (relationRef "space" "view") (SubjectSelector (ObjectType "space") (Just (RelationName "view"))) Reachability.Direct True graph)
    assertBool "space audit relation is conditional" (hasEntry (relationRef "space" "audit") (SubjectSelector (ObjectType "user") Nothing) Reachability.Conditional False graph)
    assertBool "space member-minus-owner relation is conditional" (hasEntry (relationRef "space" "member_not_owner") (SubjectSelector (ObjectType "user") Nothing) Reachability.Conditional False graph)
    assertBool "intention delegate relation is caveated" (hasCaveatedEntry (relationRef "intention" "delegate") (CaveatName "within_autonomy") graph)
    assertValidationFails "This requires allowed subjects" (schemaWithRelation "space" "viewer" Set.empty This)
    assertValidationFails "ComputedUserset rejects unknown relation" (schemaWithRelation "space" "viewer" userSubject (ComputedUserset (RelationName "missing")))
    assertValidationFails "TupleToUserset rejects incompatible arrows" invalidTupleToUsersetSchema
    assertValidationFails "Union rejects empty branches" (schemaWithRelation "space" "viewer" userSubject (Union []))
    assertValidationFails "Intersection rejects empty branches" (schemaWithRelation "space" "viewer" userSubject (Intersection []))
    assertValidationFails "Exclusion validates both branches" (schemaWithRelation "space" "viewer" userSubject (Exclusion This (ComputedUserset (RelationName "missing"))))
    assertValidationFails "Caveated rejects unknown caveat" (schemaWithRelation "space" "viewer" userSubject (Caveated (CaveatName "missing") This))
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
    assertEqual "delegation caveat allows matching autonomy and time" (Right Allowed) =<< check consistencyStore tupleStore graph MinimizeLatency requestContext (SubjectId user) (RelationName "view") intention
    assertEqual "delegation caveat denies higher autonomy" (Right Denied) =<< check consistencyStore tupleStore graph MinimizeLatency adminContext (SubjectId user) (RelationName "view") intention
    assertEqual "delegation caveat is conditional with missing context" (Right (Conditional [CaveatObligation{caveat = CaveatName "within_autonomy", missingContext = ["requested_autonomy"]}])) =<< check consistencyStore tupleStore graph MinimizeLatency missingAutonomyContext (SubjectId user) (RelationName "view") intention
    assertEqual "expired delegation caveat denies access" (Right Denied) =<< check consistencyStore tupleStore graph MinimizeLatency expiredContext (SubjectId user) (RelationName "view") intention
    assertEqual "recursive graph respects depth limit" (Left ResolutionLimitExceeded) =<< check consistencyStore recursiveTupleStore graph MinimizeLatency requestContext (SubjectId user) (RelationName "view") recursiveSpace
    assertEqual "lookup returns direct and recursive view spaces" (Right (lookupPage [allowed childSpace, allowed space] LookupExhausted)) =<< Lookup.lookup consistencyStore tupleStore graph MinimizeLatency (lookupRequest (SubjectId user) (RelationName "view") (ObjectType "space") requestContext (LookupLimit 10) Nothing)
    assertEqual "lookup follows userset subjects" (Right (lookupPage [allowed guestSpace, allowed usersetMemberSpace] LookupExhausted)) =<< Lookup.lookup consistencyStore tupleStore graph MinimizeLatency (lookupRequest (SubjectId agencyUser) (RelationName "view") (ObjectType "space") requestContext (LookupLimit 10) Nothing)
    assertEqual "lookup confirms intersection candidates" (Right (lookupPage [allowed auditedSpace, allowed exclusionSpace] LookupExhausted)) =<< Lookup.lookup consistencyStore tupleStore graph MinimizeLatency (lookupRequest (SubjectId memberOwner) (RelationName "audit") (ObjectType "space") requestContext (LookupLimit 10) Nothing)
    assertEqual "lookup omits denied intersection candidates" (Right (lookupPage [] LookupExhausted)) =<< Lookup.lookup consistencyStore tupleStore graph MinimizeLatency (lookupRequest (SubjectId memberOnly) (RelationName "audit") (ObjectType "space") requestContext (LookupLimit 10) Nothing)
    assertEqual "lookup confirms exclusion candidates" (Right (lookupPage [allowed exclusionSpace] LookupExhausted)) =<< Lookup.lookup consistencyStore tupleStore graph MinimizeLatency (lookupRequest (SubjectId memberOnly) (RelationName "member_not_owner") (ObjectType "space") requestContext (LookupLimit 10) Nothing)
    assertEqual "lookup preserves caveat obligations" (Right (lookupPage [conditional intention [CaveatObligation{caveat = CaveatName "within_autonomy", missingContext = ["requested_autonomy"]}]] LookupExhausted)) =<< Lookup.lookup consistencyStore tupleStore graph MinimizeLatency (lookupRequest (SubjectId user) (RelationName "view") (ObjectType "intention") missingAutonomyContext (LookupLimit 10) Nothing)
    assertEqual "lookup paginates deterministically first page" (Right (lookupPage [allowed childSpace] (LookupHasMore (LookupCursor "1")))) =<< Lookup.lookup consistencyStore tupleStore graph MinimizeLatency (lookupRequest (SubjectId user) (RelationName "view") (ObjectType "space") requestContext (LookupLimit 1) Nothing)
    assertEqual "lookup paginates deterministically second page" (Right (lookupPage [allowed space] LookupExhausted)) =<< Lookup.lookup consistencyStore tupleStore graph MinimizeLatency (lookupRequest (SubjectId user) (RelationName "view") (ObjectType "space") requestContext (LookupLimit 1) (Just (LookupCursor "1")))
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
                , (CaveatParameterName "until", ParameterTimestamp)
                ]
        }

lookupRequest :: Subject -> RelationName -> ObjectType -> CaveatContext -> LookupLimit -> Maybe LookupCursor -> LookupRequest
lookupRequest subject permission objectType context limit cursor =
    LookupRequest{subject, permission, objectType, context, limit, cursor}

lookupPage :: [LookupObject] -> LookupState -> LookupPage
lookupPage objects state =
    LookupPage{objects, state}

allowed :: ObjectRef -> LookupObject
allowed object =
    LookupObject{object, decision = Allowed}

conditional :: ObjectRef -> [CaveatObligation] -> LookupObject
conditional object obligations =
    LookupObject{object, decision = Conditional obligations}

kikanSchema :: Schema
kikanSchema =
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
                        [ relationEntry "delegate" userSubject (Caveated (CaveatName "within_autonomy") This)
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
    Set.singleton AllowedSubject{objectType = ObjectType "user", relation = Nothing}

orgSubject :: Set.Set AllowedSubject
orgSubject =
    Set.singleton AllowedSubject{objectType = ObjectType "org", relation = Nothing}

orgMemberSubject :: Set.Set AllowedSubject
orgMemberSubject =
    Set.singleton AllowedSubject{objectType = ObjectType "org", relation = Just (RelationName "member")}

spaceSubject :: Set.Set AllowedSubject
spaceSubject =
    Set.singleton AllowedSubject{objectType = ObjectType "space", relation = Nothing}

visibilityClassSubject :: Set.Set AllowedSubject
visibilityClassSubject =
    Set.singleton AllowedSubject{objectType = ObjectType "visibility_class", relation = Nothing}

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

hasCaveatedEntry :: RelationRef -> CaveatName -> ReachabilityGraph -> Bool
hasCaveatedEntry target caveat graph =
    any
        ( \entry ->
            entry.kind == Reachability.Conditional
                && caveat `elem` entry.caveats
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

inMemoryTupleStore :: [Tuple] -> TupleStore IO
inMemoryTupleStore tuples =
    TupleStore
        { readObjectRelation = \_ object relation limit cursor ->
            pure (pageTuples limit cursor [tuple | tuple <- tuples, tuple.object == object, tuple.relation == relation])
        , readStartingWithUser = \_ query ->
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
        , writeTuples = \_ -> pure (ConsistencyToken "in-memory-write")
        , deleteTuples = \_ -> pure (ConsistencyToken "in-memory-delete")
        , headRevision = pure testRevision
        , optimizedRevision = pure testRevision
        }

pageTuples :: Int -> Maybe StoreCursor -> [Tuple] -> TuplePage
pageTuples limit cursor tuples =
    let start =
            maybe 0 decodeTestCursor cursor
        indexed =
            drop start (zip [start + 1 ..] tuples)
        (visible, extra) =
            splitAt limit indexed
        rows =
            uncurry tupleRow <$> visible
        state =
            case extra of
                [] -> Exhausted
                (nextIndex, _) : _ -> HasMore (StoreCursor (showText nextIndex))
     in TuplePage{rows, state}

tupleRow :: Int -> Tuple -> TupleRow
tupleRow index tuple =
    TupleRow
        { rowId = TupleRowId (showText index)
        , tuple = tuple
        , createdAt = testRevision
        , deletedAt = Nothing
        }

decodeTestCursor :: StoreCursor -> Int
decodeTestCursor (StoreCursor cursorText) =
    case reads (Text.unpack cursorText) of
        [(value, "")] -> value
        _ -> 0

consistencyStore :: ConsistencyStore IO
consistencyStore =
    ConsistencyStore
        { decodeToken = \token ->
            pure
                ( Right
                    (TokenMetadata token testRevision (DatastoreId "test") (SchemaHash "schema") Nothing)
                )
        , validateToken = \_ -> pure (Right ())
        , resolveConsistency = \consistency ->
            pure
                ( Right
                    ResolvedConsistency
                        { consistency = consistency
                        , revision = testRevision
                        }
                )
        }

fixtureTuples :: [Tuple]
fixtureTuples =
    [ Tuple{object = space, relation = RelationName "owner", subject = SubjectId user, caveat = Nothing}
    , Tuple{object = guestOrg, relation = RelationName "member", subject = SubjectId agencyUser, caveat = Nothing}
    , Tuple{object = guestSpace, relation = RelationName "guest_org", subject = SubjectId guestOrg, caveat = Nothing}
    , Tuple{object = usersetMemberSpace, relation = RelationName "member", subject = SubjectSet guestOrg (RelationName "member"), caveat = Nothing}
    , Tuple{object = childSpace, relation = RelationName "parent", subject = SubjectId space, caveat = Nothing}
    , Tuple{object = auditedSpace, relation = RelationName "owner", subject = SubjectId memberOwner, caveat = Nothing}
    , Tuple{object = auditedSpace, relation = RelationName "member", subject = SubjectId memberOwner, caveat = Nothing}
    , Tuple{object = exclusionSpace, relation = RelationName "member", subject = SubjectId memberOnly, caveat = Nothing}
    , Tuple{object = exclusionSpace, relation = RelationName "member", subject = SubjectId memberOwner, caveat = Nothing}
    , Tuple{object = exclusionSpace, relation = RelationName "owner", subject = SubjectId memberOwner, caveat = Nothing}
    , Tuple{object = intention, relation = RelationName "delegate", subject = SubjectId user, caveat = Just autonomyCaveat}
    ]

autonomyCaveat :: TupleCaveat
autonomyCaveat =
    TupleCaveat
        { name = CaveatName "within_autonomy"
        , payload =
            CaveatPayload
                ( Map.fromList
                    [ ("autonomy", ValueEnum "act")
                    , ("until", ValueTimestamp expiry)
                    ]
                )
        }

requestContext :: CaveatContext
requestContext =
    CaveatContext
        ( Map.fromList
            [ ("requested_autonomy", ValueEnum "act")
            , ("current_time", ValueTimestamp currentTime)
            ]
        )

adminContext :: CaveatContext
adminContext =
    CaveatContext
        ( Map.fromList
            [ ("requested_autonomy", ValueEnum "admin")
            , ("current_time", ValueTimestamp currentTime)
            ]
        )

missingAutonomyContext :: CaveatContext
missingAutonomyContext =
    CaveatContext
        ( Map.fromList
            [ ("current_time", ValueTimestamp currentTime)
            ]
        )

expiredContext :: CaveatContext
expiredContext =
    CaveatContext
        ( Map.fromList
            [ ("requested_autonomy", ValueEnum "act")
            , ("current_time", ValueTimestamp (parseUtc "2026-08-01T00:00:00Z"))
            ]
        )

user :: ObjectRef
user =
    ObjectRef
        { objectType = ObjectType "user"
        , objectId = "alice"
        }

bob :: ObjectRef
bob =
    ObjectRef
        { objectType = ObjectType "user"
        , objectId = "bob"
        }

agencyUser :: ObjectRef
agencyUser =
    ObjectRef
        { objectType = ObjectType "user"
        , objectId = "agency-alice"
        }

memberOnly :: ObjectRef
memberOnly =
    ObjectRef
        { objectType = ObjectType "user"
        , objectId = "member-only"
        }

memberOwner :: ObjectRef
memberOwner =
    ObjectRef
        { objectType = ObjectType "user"
        , objectId = "member-owner"
        }

space :: ObjectRef
space =
    ObjectRef
        { objectType = ObjectType "space"
        , objectId = "project-x"
        }

guestSpace :: ObjectRef
guestSpace =
    ObjectRef
        { objectType = ObjectType "space"
        , objectId = "guest-space"
        }

usersetMemberSpace :: ObjectRef
usersetMemberSpace =
    ObjectRef
        { objectType = ObjectType "space"
        , objectId = "userset-member-space"
        }

childSpace :: ObjectRef
childSpace =
    ObjectRef
        { objectType = ObjectType "space"
        , objectId = "child-space"
        }

auditedSpace :: ObjectRef
auditedSpace =
    ObjectRef
        { objectType = ObjectType "space"
        , objectId = "audited-space"
        }

exclusionSpace :: ObjectRef
exclusionSpace =
    ObjectRef
        { objectType = ObjectType "space"
        , objectId = "exclusion-space"
        }

recursiveSpace :: ObjectRef
recursiveSpace =
    ObjectRef
        { objectType = ObjectType "space"
        , objectId = "recursive-space"
        }

guestOrg :: ObjectRef
guestOrg =
    ObjectRef
        { objectType = ObjectType "org"
        , objectId = "acme"
        }

intention :: ObjectRef
intention =
    ObjectRef
        { objectType = ObjectType "intention"
        , objectId = "42"
        }

testRevision :: Revision
testRevision =
    Revision "test-revision"

currentTime :: UTCTime
currentTime =
    parseUtc "2026-06-23T00:00:00Z"

expiry :: UTCTime
expiry =
    parseUtc "2026-07-01T00:00:00Z"

parseUtc :: String -> UTCTime
parseUtc =
    parseTimeOrError True defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"

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
