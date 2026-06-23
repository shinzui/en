module Main (
    main,
) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Time (UTCTime, defaultTimeLocale, parseTimeOrError)

import En.Check (CaveatObligation (..), CheckDecision (..))
import En.Effect.TupleStore (
    PageState (..),
    StoreCursor (..),
    TuplePage (..),
    TupleRow (..),
    TupleRowId (..),
    UsersetQuery (..),
 )
import En.Expand (ExpandLimit (..), ExpandRequest (..), ExpandState (..), ExpandTree (..))
import En.Lookup (
    LookupCursor (..),
    LookupLimit (..),
    LookupPage (..),
    LookupRequest (..),
    LookupState (..),
 )
import En.Reachability (
    EntryKind,
    EntryPoint (..),
    ReachabilityGraph (..),
    RelationRef (..),
    SubjectSelector (..),
    compile,
 )
import En.Reachability qualified as Reachability
import En.Revision (Revision (..))
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
        { objects = [space]
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
                        , relationEntry "member" userSubject This
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

user :: ObjectRef
user =
    ObjectRef
        { objectType = ObjectType "user"
        , objectId = "alice"
        }

space :: ObjectRef
space =
    ObjectRef
        { objectType = ObjectType "space"
        , objectId = "project-x"
        }

intention :: ObjectRef
intention =
    ObjectRef
        { objectType = ObjectType "intention"
        , objectId = "42"
        }

currentTime :: UTCTime
currentTime =
    parseUtc "2026-06-23T00:00:00Z"

expiry :: UTCTime
expiry =
    parseUtc "2026-07-01T00:00:00Z"

parseUtc :: String -> UTCTime
parseUtc =
    parseTimeOrError True defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"

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
