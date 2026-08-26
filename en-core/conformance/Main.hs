{-# LANGUAGE DataKinds #-}

module Main (main) where

import Data.Generics.Labels ()
import Data.List (sort)
import Effectful (Eff, runPureEff)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import En.Check (CheckDecision (..), CheckOutcome (..), check)
import En.Conformance.Kikan
import En.Decision (CaveatObligation (..))
import En.Effect.ConsistencyStore (ConsistencyStore)
import En.Effect.TupleStore (TupleStore)
import En.Error (EnError (..))
import En.Lookup (LookupLimit (..), LookupObject (..), LookupPage (..), LookupRequest (..), LookupState (..))
import En.Lookup qualified as Lookup
import En.LookupSubjects
  ( LookupSubject (..),
    LookupSubjectsCursor (..),
    LookupSubjectsCursorState (..),
    LookupSubjectsPage (..),
    LookupSubjectsRequest (..),
    LookupSubjectsState (..),
    encodeLookupSubjectsCursor,
    lookupSubjects,
  )
import En.Prelude qualified as Lens
import En.Reachability (ReachabilityGraph, compileSchema)
import En.Revision (Consistency (..), ConsistencyToken, DatastoreId (..))
import En.Schema (CaveatName (..), ObjectType (..), RelationName (..), Schema)
import En.Schema.Builder qualified as Schema
import En.Tuple (CaveatContext, ObjectRef (..), Subject (..), Tuple (..))

main :: IO ()
main = do
  assertEqual "guest can view a shared item" (Right Allowed) (checkDecision (SubjectId agencyUser) view sharedItem)
  assertEqual "guest cannot view an internal item" (Right Denied) (checkDecision (SubjectId agencyUser) view internalItem)
  assertEqual "guest cannot act on the shared space" (Right Denied) (checkDecision (SubjectId agencyUser) act guestSpace)
  assertEqual "non-guest cannot view the project" (Right Denied) (checkDecision (SubjectId bob) view sharedItem)
  assertEqual "a check reports the snapshot it was decided at" (Right conformanceToken) (fmap (Lens.view (#checkedAt)) (runEngine (check kikanGraph MinimizeLatency requestContext (SubjectId agencyUser) view sharedItem)))
  assertEqual
    "guest view reaches exactly the shared subset"
    (Right (lookupPage (allowed <$> sort [guestSpace, sharedItem]) LookupExhausted))
    (runEngine (Lookup.lookup kikanGraph MinimizeLatency (lookupRequest (SubjectId agencyUser) view (ObjectType "space") (LookupLimit 10))))
  assertEqual
    "guest act reaches nothing"
    (Right (lookupPage [] LookupExhausted))
    (runEngine (Lookup.lookup kikanGraph MinimizeLatency (lookupRequest (SubjectId agencyUser) act (ObjectType "space") (LookupLimit 10))))
  lookupSubjectsTests
  where
    view = RelationName "view"
    act = RelationName "act"
    checkDecision subject permission object =
      fmap (Lens.view (#decision)) (runEngine (check kikanGraph MinimizeLatency requestContext subject permission object))

-- | The properties that distinguish a real lookup-subjects from a client-side flattening
-- of the expand tree.
--
-- Each of the first four fails against a flattener. Group nesting resolves through a
-- userset to a flat concrete member rather than emitting the userset itself. A caveated
-- grant reports the obligations that remain rather than "there is a caveat somewhere below".
-- An exclusion omits the subjects it subtracts, which a flattener reports as granted. An
-- intersection returns only the subjects satisfying every conjunct, which a flattener
-- unions. The fifth pins wildcard handling, and the last two pin paging and cursor
-- validation.
lookupSubjectsTests :: IO ()
lookupSubjectsTests = do
  assertEqual
    "group nesting resolves to the flat concrete member"
    (Right (subjectsPage [allowedSubject (SubjectId agencyUser)] SubjectsExhausted))
    (fixtureLookupSubjects requestContext usersetMemberSpace view userType 10 Nothing)

  assertEqual
    "a satisfied caveat allows the delegate outright"
    (Right (subjectsPage [allowedSubject (SubjectId user)] SubjectsExhausted))
    (fixtureLookupSubjects requestContext intention view userType 10 Nothing)

  assertEqual
    "an unsatisfied caveat names the context the delegate still needs"
    ( Right
        ( subjectsPage
            [ LookupSubject
                { subject = SubjectId user,
                  decision =
                    Conditional
                      [ CaveatObligation
                          { caveat = CaveatName "within_autonomy",
                            missingContext = ["requested_autonomy"]
                          }
                      ]
                }
            ]
            SubjectsExhausted
        )
    )
    (fixtureLookupSubjects missingAutonomyContext intention view userType 10 Nothing)

  assertEqual
    "an exclusion omits the subject its subtrahend grants"
    (Right (subjectsPage [allowedSubject (SubjectId memberOnly)] SubjectsExhausted))
    (fixtureLookupSubjects requestContext exclusionSpace (RelationName "member_not_owner") userType 10 Nothing)

  assertEqual
    "an intersection returns only the subject satisfying every conjunct"
    (Right (subjectsPage [allowedSubject (SubjectId memberOwner)] SubjectsExhausted))
    (fixtureLookupSubjects requestContext auditedSpace (RelationName "audit") userType 10 Nothing)

  -- The kikan schema declares no wildcard subject, so this scenario brings its own.
  assertEqual
    "a wildcard grant is its own entry, never expanded into concrete subjects"
    ( Right
        ( subjectsPage
            [ allowedSubject (SubjectId (ObjectRef userType "alice")),
              allowedSubject (SubjectWildcard userType)
            ]
            SubjectsExhausted
        )
    )
    ( runEngineWith
        wildcardTuples
        ( lookupSubjects
            wildcardGraph
            MinimizeLatency
            (subjectsRequest requestContext readme view userType 10 Nothing)
        )
    )

  -- Walking the cursor visits each subject exactly once, in ascending order, and ends
  -- exhausted. The two members differ only in their last word, so a codec that
  -- truncated or mis-ordered the watermark would show up here.
  let firstPage = fixtureLookupSubjects requestContext exclusionSpace member userType 1 Nothing
  assertEqual
    "a limited page emits the smallest subject and offers a cursor"
    (Right [allowedSubject (SubjectId memberOnly)])
    (fmap (Lens.view (#subjects)) firstPage)
  case firstPage of
    Right LookupSubjectsPage {state = SubjectsHasMore cursor} -> do
      assertEqual
        "resuming from the cursor emits the remaining subject and exhausts"
        (Right (subjectsPage [allowedSubject (SubjectId memberOwner)] SubjectsExhausted))
        (fixtureLookupSubjects requestContext exclusionSpace member userType 1 (Just cursor))
    other ->
      fail ("expected a has-more page with a cursor, got: " <> show other)

  assertEqual
    "a malformed cursor is refused"
    (Left (InvalidCursor "not-a-cursor"))
    ( fmap
        (Lens.view (#subjects))
        (fixtureLookupSubjects requestContext exclusionSpace member userType 1 (Just (LookupSubjectsCursor "not-a-cursor")))
    )

  -- A cursor pins the snapshot a continuation reads at, so a forged one would read at
  -- a revision the client chose. The token inside it is validated like any other.
  assertEqual
    "a cursor bearing another datastore's token is refused"
    (Left (InvalidConsistencyToken "token datastore does not match this en datastore"))
    ( fmap
        (Lens.view (#subjects))
        ( runEngineStrict
            fixtureTuples
            ( lookupSubjects
                kikanGraph
                MinimizeLatency
                (subjectsRequest requestContext exclusionSpace member userType 1 (Just foreignCursor))
            )
        )
    )
  where
    view = RelationName "view"
    member = RelationName "member"

foreignCursor :: LookupSubjectsCursor
foreignCursor =
  encodeLookupSubjectsCursor
    LookupSubjectsCursorState
      { version = 1,
        token = inMemoryToken (DatastoreId "somewhere-else") testRevision,
        lastSubject = Nothing
      }

userType :: ObjectType
userType =
  ObjectType "user"

readme :: ObjectRef
readme =
  ObjectRef {objectType = ObjectType "doc", objectId = "readme"}

-- | A minimal schema declaring a wildcard subject, which @kikanSchema@ does not:
-- @doc@ has a @reader@ relation admitting both a concrete user and @user:*@.
wildcardSchema :: Schema
wildcardSchema =
  either (error . ("invalid wildcard schema fixture: " <>) . show) id do
    userObject <- Schema.object "user" []
    docObject <-
      Schema.object
        "doc"
        [ Schema.relation "reader" [Schema.subject "user", Schema.wildcardSubject "user"] Schema.this,
          Schema.permission "view" (Schema.computed "reader")
        ]
    Schema.build [userObject, docObject]

wildcardGraph :: ReachabilityGraph
wildcardGraph =
  either (error . show) id (compileSchema wildcardSchema)

wildcardTuples :: [Tuple]
wildcardTuples =
  [ Tuple {object = readme, relation = RelationName "reader", subject = SubjectWildcard userType, caveat = Nothing},
    Tuple {object = readme, relation = RelationName "reader", subject = SubjectId (ObjectRef userType "alice"), caveat = Nothing}
  ]

runEngine :: Eff '[ConsistencyStore, TupleStore, Error EnError] a -> Either EnError a
runEngine =
  runEngineWith agencyTuples

-- | 'runEngine' over a caller-chosen tuple set, for the fixtures @agencyTuples@ omits.
runEngineWith :: [Tuple] -> Eff '[ConsistencyStore, TupleStore, Error EnError] a -> Either EnError a
runEngineWith tuples =
  runPureEff . runErrorNoCallStack . runTupleStoreInMemory tuples . runConsistencyStoreInMemory

-- | 'runEngineWith' under a consistency store that actually validates tokens.
--
-- The permissive interpreter accepts any token text, so it would certify a forged cursor as
-- valid — the very hole cursor validation exists to close.
runEngineStrict :: [Tuple] -> Eff '[ConsistencyStore, TupleStore, Error EnError] a -> Either EnError a
runEngineStrict tuples =
  runPureEff
    . runErrorNoCallStack
    . runTupleStoreInMemory tuples
    . runConsistencyStoreInMemoryStrict (DatastoreId "test")

-- | The token 'runConsistencyStoreInMemory' mints for the one revision it ever
-- resolves to. Every read under this suite reports it as its @checkedAt@.
conformanceToken :: ConsistencyToken
conformanceToken =
  inMemoryToken (DatastoreId "test") testRevision

-- This is the bounded label-set a consumer applies as a predicate over its own
-- store; lookup is not enumerating high-cardinality application rows.
lookupRequest :: Subject -> RelationName -> ObjectType -> LookupLimit -> LookupRequest
lookupRequest subject permission objectType limit =
  LookupRequest {subject, permission, objectType, context = requestContext, limit, cursor = Nothing}

lookupPage :: [LookupObject] -> LookupState -> LookupPage
lookupPage objects state =
  LookupPage {objects, state, checkedAt = conformanceToken}

allowed :: ObjectRef -> LookupObject
allowed object =
  LookupObject {object, decision = Allowed}

subjectsRequest :: CaveatContext -> ObjectRef -> RelationName -> ObjectType -> Int -> Maybe LookupSubjectsCursor -> LookupSubjectsRequest
subjectsRequest context object permission subjectType limit cursor =
  LookupSubjectsRequest {object, permission, subjectType, context, limit, cursor}

-- | Run a lookup-subjects against the full kikan fixture set, which @agencyTuples@ trims.
fixtureLookupSubjects :: CaveatContext -> ObjectRef -> RelationName -> ObjectType -> Int -> Maybe LookupSubjectsCursor -> Either EnError LookupSubjectsPage
fixtureLookupSubjects context object permission subjectType limit cursor =
  runEngineWith
    fixtureTuples
    (lookupSubjects kikanGraph MinimizeLatency (subjectsRequest context object permission subjectType limit cursor))

subjectsPage :: [LookupSubject] -> LookupSubjectsState -> LookupSubjectsPage
subjectsPage subjects state =
  LookupSubjectsPage {subjects, state, checkedAt = conformanceToken}

allowedSubject :: Subject -> LookupSubject
allowedSubject subject =
  LookupSubject {subject, decision = Allowed}

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
