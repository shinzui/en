module En.Conformance.Kikan (
    kikanSchema,
    kikanGraph,
    runTupleStoreInMemory,
    pageTuples,
    tupleRow,
    runConsistencyStoreInMemory,
    fixtureTuples,
    agencyTuples,
    autonomyCaveat,
    requestContext,
    laterRequestContext,
    adminContext,
    missingAutonomyContext,
    expiredContext,
    user,
    bob,
    agencyUser,
    memberOnly,
    memberOwner,
    space,
    guestSpace,
    usersetMemberSpace,
    childSpace,
    auditedSpace,
    exclusionSpace,
    recursiveSpace,
    guestOrg,
    sharedClass,
    internalClass,
    sharedItem,
    internalItem,
    intention,
    testRevision,
) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, defaultTimeLocale, parseTimeOrError)
import Effectful (Eff)
import Effectful.Dispatch.Dynamic (interpret_)

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
import En.Error (EnError)
import En.Reachability (ReachabilityGraph, compileSchema)
import En.Revision (ConsistencyToken (..), DatastoreId (..), Revision (..), SchemaHash (..))
import En.Schema (CaveatName (..), CaveatParameterType (..), ObjectType (..), RelationName (..), Schema)
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

kikanSchema :: Schema
kikanSchema =
    fixtureSchemaOrError $ do
        withinAutonomy <-
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
        userObject <- Schema.object "user" []
        org <-
            Schema.object
                "org"
                [ Schema.relation "member" [Schema.subject "user"] Schema.this
                ]
        visibilityClass <-
            Schema.object
                "visibility_class"
                [ Schema.relation "viewer" [Schema.subject "user"] Schema.this
                ]
        spaceObject <-
            Schema.object
                "space"
                [ Schema.relation "owner" [Schema.subject "user"] Schema.this
                , Schema.relation "member" [Schema.subject "user", Schema.userset "org" "member"] Schema.this
                , Schema.relation "guest_org" [Schema.subject "org"] Schema.this
                , Schema.relation "parent" [Schema.subject "space"] Schema.this
                , Schema.relation "visibility_class" [Schema.subject "visibility_class"] Schema.this
                , Schema.permission
                    "view"
                    ( Schema.anyOf
                        (Schema.computed "owner")
                        [ Schema.computed "member"
                        , Schema.arrow "guest_org" "member"
                        , Schema.arrow "parent" "view"
                        , Schema.arrow "visibility_class" "viewer"
                        ]
                    )
                , Schema.permission
                    "act"
                    ( Schema.anyOf
                        (Schema.computed "owner")
                        [Schema.computed "member"]
                    )
                , Schema.permission
                    "audit"
                    ( Schema.allOf
                        (Schema.computed "owner")
                        [Schema.computed "member"]
                    )
                , Schema.permission
                    "member_not_owner"
                    (Schema.minus (Schema.computed "member") (Schema.computed "owner"))
                ]
        intentionObject <-
            Schema.object
                "intention"
                [ Schema.relation "delegate" [Schema.subject "user"] Schema.this
                , Schema.permission "view" (Schema.computed "delegate")
                ]
        Schema.buildWithCaveats [withinAutonomy] [userObject, org, visibilityClass, spaceObject, intentionObject]

kikanGraph :: ReachabilityGraph
kikanGraph =
    either (error . show) id (compileSchema kikanSchema)

fixtureSchemaOrError :: Either EnError Schema -> Schema
fixtureSchemaOrError =
    either (error . ("invalid conformance schema fixture: " <>) . show) id

runTupleStoreInMemory :: [Tuple] -> Eff (TupleStore : es) a -> Eff es a
runTupleStoreInMemory tuples =
    interpret_ \case
        ReadObjectRelation _ object relation limit cursor ->
            pure (pageTuples limit cursor [tuple | tuple <- tuples, tuple.object == object, tuple.relation == relation])
        ReadStartingWithUser _ query ->
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
        ProbeTuples _ object relation subjects ->
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
                _ ->
                    let cursorIndex =
                            case visible of
                                [] -> start
                                visibleRows -> fst (last visibleRows)
                     in HasMore (StoreCursor (showText cursorIndex))
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

runConsistencyStoreInMemory :: Eff (ConsistencyStore : es) a -> Eff es a
runConsistencyStoreInMemory =
    interpret_ \case
        DecodeToken token ->
            pure (TokenMetadata token testRevision (DatastoreId "test") (SchemaHash "schema") Nothing)
        ValidateToken _ ->
            pure ()
        ResolveConsistency consistency ->
            pure
                ResolvedConsistency
                    { consistency = consistency
                    , revision = testRevision
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
    , Tuple{object = sharedClass, relation = RelationName "viewer", subject = SubjectId agencyUser, caveat = Nothing}
    , Tuple{object = sharedItem, relation = RelationName "visibility_class", subject = SubjectId sharedClass, caveat = Nothing}
    , Tuple{object = internalItem, relation = RelationName "visibility_class", subject = SubjectId internalClass, caveat = Nothing}
    , Tuple{object = intention, relation = RelationName "delegate", subject = SubjectId user, caveat = Just autonomyCaveat}
    ]

agencyTuples :: [Tuple]
agencyTuples =
    [ tuple
    | tuple <- fixtureTuples
    , tuple.object /= usersetMemberSpace
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

{- | 'requestContext' one minute later, still well before the fixture's @until@
expiry. Two requests that differ only here ask the same question and must share
one decision-cache entry -- while each still gets its own answer.
-}
laterRequestContext :: CaveatContext
laterRequestContext =
    CaveatContext
        ( Map.fromList
            [ ("requested_autonomy", ValueEnum "act")
            , ("current_time", ValueTimestamp (parseUtc "2026-06-23T00:01:00Z"))
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

sharedClass :: ObjectRef
sharedClass =
    ObjectRef
        { objectType = ObjectType "visibility_class"
        , objectId = "shared"
        }

internalClass :: ObjectRef
internalClass =
    ObjectRef
        { objectType = ObjectType "visibility_class"
        , objectId = "internal"
        }

sharedItem :: ObjectRef
sharedItem =
    ObjectRef
        { objectType = ObjectType "space"
        , objectId = "shared-item"
        }

internalItem :: ObjectRef
internalItem =
    ObjectRef
        { objectType = ObjectType "space"
        , objectId = "internal-item"
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
