{-# LANGUAGE DataKinds #-}

-- | Lookup and check must agree on recursive schemas.
--
-- An object is in a lookup's result exactly when a check of it is allowed (or
-- conditional, with the same obligations). These fixtures recurse through the same
-- object type -- nested groups, mutually nested groups and teams, arrows through a
-- computed permission, a recursive arrow over nested groups, a recursion through an
-- exclusion, cyclic data and a caveated cycle -- which is where a lookup that treats a
-- revisited subproblem as empty silently returns a short answer.
--
-- Every case collects its mismatches instead of failing at the first one, so a single
-- run reports every disagreement. See
-- docs/plans/77-make-lookup-follow-recursive-usersets-the-way-check-does.md.
module RecursiveLookup
  ( testRecursiveLookup,
  )
where

import Data.Generics.Labels ()
import Data.List (intercalate)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Traversable (for)
import Effectful (Eff, runPureEff)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import En.Budget (EvaluationBudget (..), defaultEvaluationBudget)
import En.Check (CaveatObligation (..), CheckDecision (..))
import En.Check qualified as Check
import En.Conformance.Kikan (runConsistencyStoreInMemory, runTupleStoreInMemory)
import En.Effect.ConsistencyStore (ConsistencyStore)
import En.Effect.TupleStore (TupleStore)
import En.Error (EnError (..))
import En.Lookup (LookupLimit (..), LookupObject (..), LookupPage (..), LookupRequest (..), LookupState (..), noDeadline)
import En.Lookup qualified as Lookup
import En.LookupSubjects (LookupSubject (..), LookupSubjectsPage (..), LookupSubjectsRequest (..), LookupSubjectsState (..))
import En.LookupSubjects qualified as LookupSubjects
import En.Prelude
import En.Reachability (ReachabilityGraph, compileSchema)
import En.Revision (Consistency (..))
import En.Schema (CaveatName (..), ObjectType (..), RelationName (..))
import En.Schema.Parse qualified as SchemaParse
import En.Tuple (CaveatContext (..), CaveatPayload (..), CaveatValue (..), ObjectRef (..), Subject (..), Tuple (..), TupleCaveat (..))

testRecursiveLookup :: IO ()
testRecursiveLookup = do
  failures <-
    concat
      <$> sequence
        [ nestedGroupCases,
          cyclicDataCases,
          indirectArrowCases,
          recursiveArrowOverGroupsCases,
          multiTypeArrowCases,
          exclusionCases,
          caveatedCycleCases,
          caveatedNestedGroupCases,
          depthBudgetCases
        ]
  unless (null failures) $
    fail ("recursive lookup disagrees with check:\n" <> intercalate "\n" (fmap ("  - " <>) failures))

-- Milestone 1 fixture: three levels of direct recursion (alice), two turns of mutual
-- recursion through teams (bob), one space per group, and one direct grant.

nestedGroupSchemaText :: Text
nestedGroupSchemaText =
  Text.unlines
    [ "object user {}",
      "object team {",
      "  relation member: user, group#member",
      "}",
      "object group {",
      "  relation member: user, group#member, team#member",
      "}",
      "object space {",
      "  relation viewer: user, group#member",
      "  permission view = viewer",
      "}"
    ]

nestedGroupTuples :: [Tuple]
nestedGroupTuples =
  fmap
    tuple
    [ "group:g1#member@user:alice",
      "group:g2#member@group:g1#member",
      "group:g3#member@group:g2#member",
      "team:t1#member@user:bob",
      "group:g4#member@team:t1#member",
      "team:t2#member@group:g4#member",
      "group:g5#member@team:t2#member",
      "space:s0#viewer@user:alice",
      "space:s1#viewer@group:g1#member",
      "space:s2#viewer@group:g2#member",
      "space:s3#viewer@group:g3#member",
      "space:s4#viewer@group:g4#member",
      "space:s5#viewer@group:g5#member"
    ]

nestedGroupCases :: IO [String]
nestedGroupCases = do
  graph <- graphFrom nestedGroupSchemaText
  let tuples = nestedGroupTuples
      users = [ref "user:alice", ref "user:bob"]
  agreements <-
    sequence
      ( [agreement graph tuples emptyContext person "view" "space" | person <- users]
          <> [agreement graph tuples emptyContext person "member" "group" | person <- users]
          <> [agreement graph tuples emptyContext person "member" "team" | person <- users]
      )
  expected <-
    sequence
      [ expectObjects "alice views spaces" graph tuples (ref "user:alice") "view" "space" ["space:s0", "space:s1", "space:s2", "space:s3"],
        expectObjects "bob views spaces" graph tuples (ref "user:bob") "view" "space" ["space:s4", "space:s5"],
        expectObjects "alice is a member of groups" graph tuples (ref "user:alice") "member" "group" ["group:g1", "group:g2", "group:g3"],
        expectObjects "bob is a member of groups" graph tuples (ref "user:bob") "member" "group" ["group:g4", "group:g5"],
        expectPaged "alice views spaces one per page" graph tuples (ref "user:alice") "view" "space" ["space:s0", "space:s1", "space:s2", "space:s3"]
      ]
  let reverseSide =
        expectSubjects "users who can view space:s3" graph tuples (ref "space:s3") "view" "user" [SubjectId (ref "user:alice")]
  pure (concat agreements <> concat expected <> reverseSide)

-- Cyclic data: g3 is also a member of g1. The lookup must terminate with the same answer.
cyclicDataCases :: IO [String]
cyclicDataCases = do
  graph <- graphFrom nestedGroupSchemaText
  let tuples = nestedGroupTuples <> [tuple "group:g1#member@group:g3#member"]
  agreed <- agreement graph tuples emptyContext (ref "user:alice") "view" "space"
  expected <- expectObjects "cyclic data: alice views spaces" graph tuples (ref "user:alice") "view" "space" ["space:s0", "space:s1", "space:s2", "space:s3"]
  pure (agreed <> expected)

-- An arrow that recurses through a computed permission rather than directly.
indirectArrowCases :: IO [String]
indirectArrowCases = do
  graph <-
    graphFrom $
      Text.unlines
        [ "object user {}",
          "object folder {",
          "  relation parent: folder",
          "  relation viewer: user",
          "  permission inherited = parent->view",
          "  permission view = viewer | inherited",
          "}"
        ]
  let tuples =
        fmap
          tuple
          [ "folder:f1#viewer@user:alice",
            "folder:f2#parent@folder:f1",
            "folder:f3#parent@folder:f2"
          ]
  agreed <- agreement graph tuples emptyContext (ref "user:alice") "view" "folder"
  expected <- expectObjects "indirect arrow: alice views folders" graph tuples (ref "user:alice") "view" "folder" ["folder:f1", "folder:f2", "folder:f3"]
  pure (agreed <> expected)

-- A directly recursive arrow whose seeds come through nested groups.
recursiveArrowOverGroupsCases :: IO [String]
recursiveArrowOverGroupsCases = do
  graph <-
    graphFrom $
      Text.unlines
        [ "object user {}",
          "object group {",
          "  relation member: user, group#member",
          "}",
          "object folder {",
          "  relation parent: folder",
          "  relation viewer: user, group#member",
          "  permission view = viewer | parent->view",
          "}"
        ]
  let tuples =
        fmap
          tuple
          [ "group:g1#member@user:alice",
            "group:g2#member@group:g1#member",
            "folder:f1#viewer@group:g1#member",
            "folder:f2#viewer@group:g2#member",
            "folder:f3#parent@folder:f1"
          ]
  agreed <- agreement graph tuples emptyContext (ref "user:alice") "view" "folder"
  expected <- expectObjects "recursive arrow over nested groups: alice views folders" graph tuples (ref "user:alice") "view" "folder" ["folder:f1", "folder:f2", "folder:f3"]
  pure (agreed <> expected)

-- A directly recursive arrow whose tupleset also accepts another type: a folder
-- reached through an org parent must seed the folder-to-folder recursion too.
multiTypeArrowCases :: IO [String]
multiTypeArrowCases = do
  graph <-
    graphFrom $
      Text.unlines
        [ "object user {}",
          "object org {",
          "  relation viewer: user",
          "  permission view = viewer",
          "}",
          "object folder {",
          "  relation parent: folder, org",
          "  relation viewer: user",
          "  permission view = viewer | parent->view",
          "}"
        ]
  let tuples =
        fmap
          tuple
          [ "org:o1#viewer@user:alice",
            "folder:f1#parent@org:o1",
            "folder:f2#parent@folder:f1",
            "folder:f3#parent@folder:f2"
          ]
  agreed <- agreement graph tuples emptyContext (ref "user:alice") "view" "folder"
  expected <- expectObjects "arrow over two tupleset types: alice views folders" graph tuples (ref "user:alice") "view" "folder" ["folder:f1", "folder:f2", "folder:f3"]
  pure (agreed <> expected)

-- A recursion through an exclusion: the one shape where the paging window can see a
-- round of the fixpoint.
exclusionSchemaText :: Text
exclusionSchemaText =
  Text.unlines
    [ "object user {}",
      "object group {",
      "  relation member: user, group#active",
      "  relation banned: user",
      "  permission active = member but not banned",
      "}"
    ]

exclusionTuples :: [Tuple]
exclusionTuples =
  fmap
    tuple
    [ "group:g1#member@user:alice",
      "group:g2#member@group:g1#active",
      "group:g3#member@group:g2#active",
      "group:g4#member@group:g3#active"
    ]

exclusionCases :: IO [String]
exclusionCases = do
  graph <- graphFrom exclusionSchemaText
  let banned = exclusionTuples <> [tuple "group:g3#banned@user:alice"]
      groups = ["group:g1", "group:g2", "group:g3", "group:g4"]
  results <-
    sequence
      [ agreement graph exclusionTuples emptyContext (ref "user:alice") "active" "group",
        expectObjects "exclusion: alice is active in groups" graph exclusionTuples (ref "user:alice") "active" "group" groups,
        expectPaged "exclusion: alice is active in groups, one per page" graph exclusionTuples (ref "user:alice") "active" "group" groups,
        agreement graph banned emptyContext (ref "user:alice") "active" "group",
        expectObjects "exclusion with a ban: alice is active in groups" graph banned (ref "user:alice") "active" "group" ["group:g1", "group:g2"],
        expectPaged "exclusion with a ban: alice is active in groups, one per page" graph banned (ref "user:alice") "active" "group" ["group:g1", "group:g2"]
      ]
  pure (concat results)

-- A cycle of caveated memberships, so convergence of decisions is tested and not only
-- of object sets. The caveat is the @min_rank@ caveat of the caveated-group cases in
-- Main.hs, and the empty context leaves it unresolved.
caveatedCycleCases :: IO [String]
caveatedCycleCases = do
  graph <-
    graphFrom $
      Text.unlines
        [ "caveat min_rank(rank: integer, floor: integer) {",
          "  context.rank >= payload.floor",
          "}",
          "caveat min_level(clearance: integer, level: integer) {",
          "  context.clearance >= payload.level",
          "}",
          "object user {}",
          "object group {",
          "  relation member: user, group#member",
          "}"
        ]
  let level value =
        Just TupleCaveat {name = CaveatName "min_level", payload = CaveatPayload (Map.fromList [("level", ValueInteger value)])}
      rank floor' =
        Just TupleCaveat {name = CaveatName "min_rank", payload = CaveatPayload (Map.fromList [("floor", ValueInteger floor')])}
      tuples =
        [ tuple "group:a#member@user:alice",
          tuple "group:a#member@group:b#member" & #caveat .~ rank 1,
          tuple "group:b#member@group:a#member" & #caveat .~ rank 2,
          tuple "group:c#member@group:b#member" & #caveat .~ rank 3
        ]
  agreed <- agreement graph tuples emptyContext (ref "user:alice") "member" "group"
  -- With the root grant itself conditional, on a caveat the cycle does not use, lookup
  -- carries a's decision around the cycle a -> b -> a and lists the cycle's caveat on a
  -- as well; check prunes that walk. The objects and every Allowed/Denied answer agree,
  -- and lookup's obligations contain check's: it may ask for more context, never grant
  -- more. See the Decision Log of plan 77.
  conditionalRoot <-
    agreementWith
      LookupObligationsContainCheck
      graph
      ((tuple "group:a#member@user:alice" & #caveat .~ level 3) : drop 1 tuples)
      emptyContext
      (ref "user:alice")
      "member"
      "group"
  let found = runLookup defaultEvaluationBudget graph tuples emptyContext (ref "user:alice") "member" "group" (LookupLimit 100)
      expectedObjects =
        [ LookupObject (ref "group:a") Allowed,
          LookupObject (ref "group:b") (Conditional [CaveatObligation (CaveatName "min_rank") ["rank"]]),
          LookupObject (ref "group:c") (Conditional [CaveatObligation (CaveatName "min_rank") ["rank"]])
        ]
      direct =
        case found of
          Right LookupPage {objects, state = LookupExhausted}
            | objects == expectedObjects -> []
          other -> ["caveated cycle: expected " <> show expectedObjects <> ", got " <> show other]
  pure (agreed <> conditionalRoot <> direct)

-- Both edges of a two-level path are caveated, on different caveats, and the request
-- supplies neither. Check reports both obligations; lookup must too, rather than
-- taking the group membership's decision as 'Allowed'. Not recursive, but the same
-- agreement contract.
caveatedNestedGroupCases :: IO [String]
caveatedNestedGroupCases = do
  graph <-
    graphFrom $
      Text.unlines
        [ "caveat min_level(clearance: integer, level: integer) {",
          "  context.clearance >= payload.level",
          "}",
          "caveat min_rank(rank: integer, floor: integer) {",
          "  context.rank >= payload.floor",
          "}",
          "object user {}",
          "object org {",
          "  relation member: user",
          "}",
          "object space {",
          "  relation member: user, org#member",
          "}"
        ]
  let caveated name parameter value =
        Just TupleCaveat {name = CaveatName name, payload = CaveatPayload (Map.fromList [(parameter, ValueInteger value)])}
      tuples =
        [ tuple "space:s1#member@org:o1#member" & #caveat .~ caveated "min_level" "level" 3,
          tuple "org:o1#member@user:alice" & #caveat .~ caveated "min_rank" "floor" 2
        ]
  agreement graph tuples emptyContext (ref "user:alice") "member" "space"

-- A recursion deeper than the budget is an error, never a short page.
depthBudgetCases :: IO [String]
depthBudgetCases = do
  graph <- graphFrom nestedGroupSchemaText
  let budget = defaultEvaluationBudget {maxDepth = 5}
      chain :: Int -> [Tuple]
      chain n =
        tuple "group:c1#member@user:alice"
          : [ tuple ("group:c" <> showText (level + 1) <> "#member@group:c" <> showText level <> "#member")
            | level <- [1 .. n - 1]
            ]
            <> [tuple ("space:deep#viewer@group:c" <> showText n <> "#member")]
      shallow = runLookup budget graph (chain 3) emptyContext (ref "user:alice") "view" "space" (LookupLimit 10)
      deepChain = runLookup budget graph (chain 10) emptyContext (ref "user:alice") "view" "space" (LookupLimit 10)
      shallowFailures =
        case shallow of
          Right LookupPage {objects = [LookupObject {object}], state = LookupExhausted}
            | object == ref "space:deep" -> []
          other -> ["depth budget 5: a chain of three groups should resolve, got " <> show other]
      deepFailures =
        case deepChain of
          Left ResolutionLimitExceeded -> []
          other -> ["depth budget 5: a chain of ten groups should fail with ResolutionLimitExceeded, got " <> show other]
  pure (shallowFailures <> deepFailures)

-- * Agreement

-- | Compare lookup's answer with a check of every object of the type in the fixture.
-- Pairs where either side exceeds the resolution budget are skipped and named: both
-- sides fail loudly there, and their budgets are counted differently.
agreement :: ReachabilityGraph -> [Tuple] -> CaveatContext -> ObjectRef -> Text -> Text -> IO [String]
agreement =
  agreementWith ExactObligations

-- | How 'Conditional' obligations must compare.
data ObligationAgreement
  = -- | The same set on both sides.
    ExactObligations
  | -- | Lookup's set contains check's. For an object on a caveated cycle, lookup also
    -- lists caveats met only on walks that revisit the object, which check prunes.
    LookupObligationsContainCheck

agreementWith :: ObligationAgreement -> ReachabilityGraph -> [Tuple] -> CaveatContext -> ObjectRef -> Text -> Text -> IO [String]
agreementWith obligationAgreement graph tuples context person permission objectType = do
  let candidates = objectsOfType (ObjectType objectType) tuples
      label = renderRef person <> " " <> Text.unpack permission <> " " <> Text.unpack objectType
  case lookupAll defaultEvaluationBudget graph tuples context person permission objectType of
    Left ResolutionLimitExceeded -> do
      putStrLn ("skipped agreement for " <> label <> ": lookup exceeded the resolution budget")
      pure []
    Left err -> pure ["lookup failed for " <> label <> ": " <> show err]
    Right found -> do
      let fromLookup = Map.fromList [(object, normalized) | LookupObject {object, decision} <- found, Just normalized <- [normalize decision]]
      checked <-
        fmap concat . for candidates $ \object ->
          case runCheck graph tuples context person permission object of
            Left ResolutionLimitExceeded -> do
              putStrLn ("skipped agreement for " <> label <> " on " <> renderRef object <> ": check exceeded the resolution budget")
              pure []
            Left err -> pure [Left (renderRef object <> ": check failed: " <> show err)]
            Right decision -> pure [Right (object, normalize decision)]
      let checkErrors = [message | Left message <- checked]
          fromCheck = Map.fromList [(object, decision) | Right (object, Just decision) <- checked]
          checkedObjects = Set.fromList [object | Right (object, _) <- checked]
          omitted = Map.keys (Map.difference fromCheck fromLookup)
          extra = [object | object <- Map.keys (Map.difference fromLookup fromCheck), Set.member object checkedObjects]
          different =
            [ renderRef object <> " (check " <> show checkDecision <> ", lookup " <> show lookupDecision <> ")"
            | (object, (checkDecision, lookupDecision)) <- Map.toList (Map.intersectionWith (,) fromCheck fromLookup),
              not (decisionsAgree checkDecision lookupDecision)
            ]
          decisionsAgree checkDecision lookupDecision =
            case (obligationAgreement, checkDecision, lookupDecision) of
              (LookupObligationsContainCheck, Just checkObligations, Just lookupObligations) ->
                Set.isSubsetOf checkObligations lookupObligations
              _ -> checkDecision == lookupDecision
      pure $
        fmap (("lookup/check disagree for " <> label <> ": ") <>) $
          checkErrors
            <> ["check allows " <> renderRefs omitted <> " that lookup omits" | not (null omitted)]
            <> ["lookup returns " <> renderRefs extra <> " that check denies" | not (null extra)]
            <> ["decisions differ for " <> intercalate ", " different | not (null different)]

-- | 'Nothing' for denied; obligations compared as a set, because their order is an
-- artefact of traversal order and not part of the answer.
normalize :: CheckDecision -> Maybe (Maybe (Set CaveatObligation))
normalize =
  \case
    Denied -> Nothing
    Allowed -> Just Nothing
    Conditional obligations -> Just (Just (Set.fromList obligations))

expectObjects :: String -> ReachabilityGraph -> [Tuple] -> ObjectRef -> Text -> Text -> [Text] -> IO [String]
expectObjects label graph tuples person permission objectType expected =
  pure $
    case runLookup defaultEvaluationBudget graph tuples emptyContext person permission objectType (LookupLimit 100) of
      Right LookupPage {objects, state = LookupExhausted}
        | objects == fmap (\object -> LookupObject (ref object) Allowed) expected -> []
        | otherwise -> [label <> ": expected " <> show expected <> ", got " <> renderObjects objects]
      other -> [label <> ": expected one exhausted page, got " <> show other]

-- | Page with a limit of one: one object per page, in key order, ending exhausted.
expectPaged :: String -> ReachabilityGraph -> [Tuple] -> ObjectRef -> Text -> Text -> [Text] -> IO [String]
expectPaged label graph tuples person permission objectType expected =
  pure (go Nothing (fmap ref expected))
  where
    go cursor remaining =
      case runLookupWith (request person permission objectType emptyContext (LookupLimit 1) cursor) of
        Left err -> [label <> ": page failed: " <> show err]
        Right LookupPage {objects, state} ->
          case (remaining, objects, state) of
            ([], [], LookupExhausted) -> []
            ([wanted], [LookupObject {object}], LookupExhausted)
              | object == wanted -> []
            (wanted : rest, [LookupObject {object}], LookupHasMore next)
              | object == wanted -> go (Just next) rest
            _ -> [label <> ": expected " <> renderRefs remaining <> " next, got " <> renderObjects objects <> " with " <> show state]
    runLookupWith =
      runEngine tuples . Lookup.lookupWithDeadlineAndBudget defaultEvaluationBudget noDeadline graph MinimizeLatency

expectSubjects :: String -> ReachabilityGraph -> [Tuple] -> ObjectRef -> Text -> Text -> [Subject] -> [String]
expectSubjects label graph tuples object permission subjectType expected =
  case runEngine tuples (LookupSubjects.lookupSubjects graph MinimizeLatency subjectsRequest) of
    Right LookupSubjectsPage {subjects, state = SubjectsExhausted}
      | fmap (\LookupSubject {subject} -> subject) subjects == expected -> []
    other -> [label <> ": expected " <> show expected <> ", got " <> show other]
  where
    subjectsRequest =
      LookupSubjectsRequest
        { object,
          permission = RelationName permission,
          subjectType = ObjectType subjectType,
          context = emptyContext,
          limit = 100,
          cursor = Nothing
        }

-- * Engine

runEngine :: [Tuple] -> Eff '[ConsistencyStore, TupleStore, Error EnError] a -> Either EnError a
runEngine tuples =
  runPureEff . runErrorNoCallStack . runTupleStoreInMemory tuples . runConsistencyStoreInMemory

runLookup :: EvaluationBudget -> ReachabilityGraph -> [Tuple] -> CaveatContext -> ObjectRef -> Text -> Text -> LookupLimit -> Either EnError LookupPage
runLookup budget graph tuples context person permission objectType limit =
  runEngine tuples (Lookup.lookupWithDeadlineAndBudget budget noDeadline graph MinimizeLatency (request person permission objectType context limit Nothing))

-- | Every object of every page.
lookupAll :: EvaluationBudget -> ReachabilityGraph -> [Tuple] -> CaveatContext -> ObjectRef -> Text -> Text -> Either EnError [LookupObject]
lookupAll budget graph tuples context person permission objectType =
  go Nothing
  where
    go cursor = do
      LookupPage {objects, state} <-
        runEngine tuples (Lookup.lookupWithDeadlineAndBudget budget noDeadline graph MinimizeLatency (request person permission objectType context (LookupLimit 100) cursor))
      case state of
        LookupExhausted -> Right objects
        LookupHasMore next -> (objects <>) <$> go (Just next)
        LookupTruncated _ -> Left (InvalidCursor "lookup truncated without a deadline")

runCheck :: ReachabilityGraph -> [Tuple] -> CaveatContext -> ObjectRef -> Text -> ObjectRef -> Either EnError CheckDecision
runCheck graph tuples context person permission object =
  (view #decision) <$> runEngine tuples (Check.check graph MinimizeLatency context (SubjectId person) (RelationName permission) object)

request :: ObjectRef -> Text -> Text -> CaveatContext -> LookupLimit -> Maybe Lookup.LookupCursor -> LookupRequest
request person permission objectType context limit cursor =
  LookupRequest
    { subject = SubjectId person,
      permission = RelationName permission,
      objectType = ObjectType objectType,
      context,
      limit,
      cursor
    }

-- * Fixture helpers

graphFrom :: Text -> IO ReachabilityGraph
graphFrom text =
  either (fail . ("invalid recursive-lookup schema: " <>) . show) pure (SchemaParse.parseSchema text >>= compileSchema)

emptyContext :: CaveatContext
emptyContext =
  CaveatContext Map.empty

-- | @type:id@.
ref :: Text -> ObjectRef
ref text =
  case Text.splitOn ":" text of
    [objectType, objectId] -> ObjectRef {objectType = ObjectType objectType, objectId}
    _ -> error ("malformed object reference in fixture: " <> Text.unpack text)

-- | @type:id#relation@subject@, where the subject is @type:id@ or @type:id#relation@.
tuple :: Text -> Tuple
tuple text =
  case Text.splitOn "@" text of
    [resource, subjectText] ->
      case Text.splitOn "#" resource of
        [object, relation] ->
          Tuple
            { object = ref object,
              relation = RelationName relation,
              subject =
                case Text.splitOn "#" subjectText of
                  [subjectObject] -> SubjectId (ref subjectObject)
                  [subjectObject, subjectRelation] -> SubjectSet (ref subjectObject) (RelationName subjectRelation)
                  _ -> malformed,
              caveat = Nothing
            }
        _ -> malformed
    _ -> malformed
  where
    malformed :: a
    malformed = error ("malformed tuple in fixture: " <> Text.unpack text)

objectsOfType :: ObjectType -> [Tuple] -> [ObjectRef]
objectsOfType objectType tuples =
  Set.toAscList . Set.fromList $
    filter
      ((== objectType) . (view #objectType))
      ( concat
          [ (current ^. #object)
              : case (current ^. #subject) of
                SubjectId object -> [object]
                SubjectSet object _ -> [object]
                SubjectWildcard _ -> []
          | current <- tuples
          ]
      )

renderRef :: ObjectRef -> String
renderRef ObjectRef {objectType = ObjectType objectType, objectId} =
  Text.unpack (objectType <> ":" <> objectId)

renderRefs :: [ObjectRef] -> String
renderRefs objects =
  "[" <> intercalate "," (fmap renderRef objects) <> "]"

renderObjects :: [LookupObject] -> String
renderObjects objects =
  renderRefs [object | LookupObject {object} <- objects]

showText :: (Show a) => a -> Text
showText =
  Text.pack . show
