module En.Conformance.Kikan (
    kikanSchema,
    kikanGraph,
    runTupleStoreInMemory,
    tupleKey,
    touchTuple,
    deleteTupleByKey,
    matchesFilter,
    preconditionHolds,
    runConsistencyStoreInMemoryStrict,
    inMemoryToken,
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

import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, defaultTimeLocale, parseTimeOrError)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret_, reinterpret_)
import Effectful.Error.Static (Error, throwError)
import Effectful.State.Static.Local (evalState, get, modify)

import En.Effect.ConsistencyStore (ConsistencyStore (..), ResolvedConsistency (..), TokenMetadata (..))
import En.Effect.TupleStore (
    PageState (..),
    Precondition (..),
    StoreCursor (..),
    SubjectRelationFilter (..),
    TupleFilter (..),
    TuplePage (..),
    TupleRow (..),
    TupleRowId (..),
    TupleStore (..),
    TupleWriteRequest (..),
    UsersetQuery (..),
    renderPrecondition,
 )
import En.Error (EnError (..))
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

{- | The in-memory tuple store.

Writes and deletes mutate the tuple set with the same touch semantics the
PostgreSQL store implements (see "En.Postgres.TupleStore"): a tuple's identity is
its 'tupleKey', and a write replaces whatever grant that key currently holds. The
store has no revisions, so every read sees the current state — which is exactly
the "a read at the write's token sees the write" behavior the conformance suites
assert.

The state lives in 'Effectful.State.Static.Local', which runs under 'runPureEff',
so the interpreter stays pure for @en-core/conformance/Main.hs@.
-}
runTupleStoreInMemory :: (Error EnError :> es) => [Tuple] -> Eff (TupleStore : es) a -> Eff es a
runTupleStoreInMemory initialTuples =
    reinterpret_ (evalState initialTuples) \case
        ReadObjectRelation _ object relation limit cursor -> do
            tuples <- get
            pure (pageTuples limit cursor [tuple | tuple <- tuples, tuple.object == object, tuple.relation == relation])
        ReadStartingWithUser _ query -> do
            tuples <- get
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
        ReadAllTuples _ limit cursor -> do
            tuples <- get
            pure (pageTuples limit cursor tuples)
        ProbeTuples _ object relation subjects -> do
            tuples <- get
            pure
                [ tupleRow index tuple
                | (index, tuple) <- zip [1 ..] tuples
                , tuple.object == object
                , tuple.relation == relation
                , tuple.subject `elem` subjects
                ]
        ApplyTupleWrites request -> do
            tuples <- get
            case find (not . preconditionHolds tuples) request.preconditions of
                Just failed ->
                    throwError (WritePreconditionFailed (renderPrecondition failed))
                Nothing -> do
                    modify (\current -> foldl' (flip deleteTupleByKey) current request.deletes)
                    modify (\current -> foldl' (flip touchTuple) current request.writes)
                    pure (ConsistencyToken "in-memory-write")
        HeadRevision ->
            pure testRevision
        OptimizedRevision ->
            pure testRevision
        OldestRetainedXid ->
            pure 0
        ReapDeletedTuples _ ->
            pure 0

-- | The touch identity of a tuple: everything except the caveat.
tupleKey :: Tuple -> (ObjectRef, RelationName, Subject)
tupleKey tuple =
    (tuple.object, tuple.relation, tuple.subject)

{- | Apply one write with touch semantics: retire whatever grant shares the
tuple's key, whatever its caveat, then append the new grant.

An identical rewrite is a no-op that preserves the tuple's position, mirroring
the PostgreSQL store leaving an identical live row's @created_xid@ untouched.
-}
touchTuple :: Tuple -> [Tuple] -> [Tuple]
touchTuple tuple tuples
    | tuple `elem` tuples = tuples
    | otherwise = deleteTupleByKey tuple tuples <> [tuple]

{- | Apply a delete by key: remove the grant sharing the tuple's key, ignoring
the request's caveat. Mirrors the PostgreSQL delete's re-keying.
-}
deleteTupleByKey :: Tuple -> [Tuple] -> [Tuple]
deleteTupleByKey tuple =
    filter (\candidate -> tupleKey candidate /= tupleKey tuple)

-- | Whether a precondition holds over the given tuples.
preconditionHolds :: [Tuple] -> Precondition -> Bool
preconditionHolds tuples = \case
    TupleMustExist tupleFilter -> any (matchesFilter tupleFilter) tuples
    TupleMustNotExist tupleFilter -> not (any (matchesFilter tupleFilter) tuples)

{- | Whether a tuple matches a filter.

The subject is flattened exactly as the PostgreSQL store stores it: a wildcard
becomes the object id @*@ with no relation, and a userset carries its relation.
Otherwise a filter would mean one thing in memory and another in the database.
-}
matchesFilter :: TupleFilter -> Tuple -> Bool
matchesFilter tupleFilter tuple =
    tupleFilter.objectType == tuple.object.objectType
        && matchesMaybe tupleFilter.objectId tuple.object.objectId
        && matchesMaybe tupleFilter.relation tuple.relation
        && matchesMaybe tupleFilter.subjectType subjectObject.objectType
        && matchesMaybe tupleFilter.subjectId subjectObject.objectId
        && matchesSubjectRelation tupleFilter.subjectRelation subjectRelationName
  where
    (subjectObject, subjectRelationName) =
        case tuple.subject of
            SubjectId object -> (object, Nothing)
            SubjectSet object relationName -> (object, Just relationName)
            SubjectWildcard objectType -> (ObjectRef{objectType, objectId = "*"}, Nothing)

    matchesMaybe expected actual = maybe True (== actual) expected

    matchesSubjectRelation expected actual =
        case expected of
            AnySubjectRelation -> True
            NoSubjectRelation -> isNothing actual
            ExactSubjectRelation relationName -> actual == Just relationName

{- | Page a filtered tuple list by a row-ordinal cursor.

The cursor is the ordinal of the last row emitted, so a continuation resumes at
@drop start tuples@. Dropping from the /zipped/ list instead -- which this did
until 2026-07-09 -- makes the next cursor @2 * start@ rather than
@start + limit@, so a relation wider than two pages silently skips rows and
reports 'Exhausted' as if it had read them all.
-}
pageTuples :: Int -> Maybe StoreCursor -> [Tuple] -> TuplePage
pageTuples limit cursor tuples =
    let start =
            maybe 0 decodeTestCursor cursor
        indexed =
            zip [start + 1 ..] (drop start tuples)
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

{- | The permissive in-memory consistency store.

It accepts every token and always resolves to 'testRevision'. 'MintToken' emits
'inMemoryToken', and 'DecodeToken' reverses that encoding when it recognizes it so
a minted token round-trips to the revision it pins. Anything else it does not
recognize still decodes -- permissively -- to 'testRevision', which keeps the many
tests that pass literal token text working.

Use 'runConsistencyStoreInMemoryStrict' when a test needs a validator that can say
no.
-}
runConsistencyStoreInMemory :: Eff (ConsistencyStore : es) a -> Eff es a
runConsistencyStoreInMemory =
    interpret_ \case
        DecodeToken token ->
            pure
                TokenMetadata
                    { token
                    , revision = maybe testRevision snd (parseInMemoryToken token)
                    , datastoreId = maybe inMemoryDatastore fst (parseInMemoryToken token)
                    , schemaHash = SchemaHash "schema"
                    , expiresAt = Nothing
                    }
        ValidateToken _ ->
            pure ()
        ResolveConsistency consistency ->
            pure
                ResolvedConsistency
                    { consistency = consistency
                    , revision = testRevision
                    }
        MintToken revision ->
            pure (inMemoryToken inMemoryDatastore revision)

{- | An in-memory consistency store that actually validates.

'DecodeToken' rejects any text it did not mint, and 'ValidateToken' rejects a
token minted by a different datastore. This is what a cursor-validation test needs:
the permissive interpreter above accepts a forged cursor and would certify the very
hole it is meant to prove closed.

Both rejections raise 'InvalidConsistencyToken' through the ambient @Error EnError@,
which is how 'En.Postgres.Revision.runConsistencyStorePostgres' surfaces them too.
-}
runConsistencyStoreInMemoryStrict ::
    (Error EnError :> es) =>
    DatastoreId ->
    Eff (ConsistencyStore : es) a ->
    Eff es a
runConsistencyStoreInMemoryStrict datastoreId =
    interpret_ \case
        DecodeToken token ->
            case parseInMemoryToken token of
                Nothing ->
                    throwError (InvalidConsistencyToken "token is not an in-memory token")
                Just (tokenDatastore, revision) ->
                    pure
                        TokenMetadata
                            { token
                            , revision
                            , datastoreId = tokenDatastore
                            , schemaHash = SchemaHash "schema"
                            , expiresAt = Nothing
                            }
        ValidateToken metadata
            | metadata.datastoreId /= datastoreId ->
                throwError (InvalidConsistencyToken "token datastore does not match this en datastore")
            | otherwise ->
                pure ()
        ResolveConsistency consistency ->
            pure ResolvedConsistency{consistency, revision = testRevision}
        MintToken revision ->
            pure (inMemoryToken datastoreId revision)

inMemoryDatastore :: DatastoreId
inMemoryDatastore =
    DatastoreId "test"

{- | @in-memory:\<datastore\>:\<revision\>@. Deliberately trivial: it carries the two
things a cursor test must be able to vary -- who minted it, and what revision it
pins.
-}
inMemoryToken :: DatastoreId -> Revision -> ConsistencyToken
inMemoryToken (DatastoreId datastoreId) revision =
    ConsistencyToken ("in-memory:" <> datastoreId <> ":" <> revision.revisionEncoding)

parseInMemoryToken :: ConsistencyToken -> Maybe (DatastoreId, Revision)
parseInMemoryToken (ConsistencyToken tokenText) = do
    body <- Text.stripPrefix "in-memory:" tokenText
    let (datastoreId, rest) = Text.breakOn ":" body
    revisionText <- Text.stripPrefix ":" rest
    pure (DatastoreId datastoreId, Revision revisionText)

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
